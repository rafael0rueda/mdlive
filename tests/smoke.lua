-- Run from the repository root:
--   nvim --headless --clean --cmd "set rtp^=." -c "luafile tests/smoke.lua"
local root = vim.fn.getcwd()
local failures = 0
-- The example files may be open in another Neovim (or a parallel test run);
-- swap file prompts would make switching buffers fail.
vim.o.swapfile = false

local function check(name, ok, detail)
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -> " .. tostring(detail)) or ""))
  end
end

local function finish()
  print(failures == 0 and "\nall checks passed" or ("\n" .. failures .. " check(s) failed"))
  vim.cmd(failures == 0 and "qa!" or "cq!")
end

local ok, err = xpcall(function()
  local opened
  require("mdlive").setup({
    debounce_ms = 20,
    browser = function(url)
      opened = url
    end,
  })

  vim.cmd.edit(root .. "/examples/demo.md")
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("MdLive")
  check("opens preview url", opened and opened:match("^http://127%.0%.0%.1:%d+/preview/" .. buf .. "$"), opened)
  local base = opened:match("^(http://[^/]+)")

  local function curl(path, extra, max_time)
    local args = { "curl", "-s", "--path-as-is", "-w", "\n%{http_code}", "--max-time", tostring(max_time or 3) }
    vim.list_extend(args, extra or {})
    table.insert(args, base .. path)
    local result
    vim.system(args, { text = true }, function(r)
      result = r
    end)
    return function()
      vim.wait(5000, function()
        return result ~= nil
      end, 10)
      local body, code = result.stdout:match("^(.*)\n(%d+)$")
      return tonumber(code), body or ""
    end
  end
  local function get(path, extra)
    return curl(path, extra)()
  end

  local code, body = get("/preview/" .. buf)
  check("serves index.html", code == 200 and body:find("preview.js", 1, true), code)
  check("serves app script", get("/app/preview.js") == 200)
  check("serves katex font", get("/app/vendor/katex/fonts/KaTeX_Main-Regular.woff2") == 200)
  check("serves relative image", get("/files/" .. buf .. "/assets/logo.svg") == 200)
  check("blocks app traversal", get("/app/../lua/mdlive/init.lua") == 404)
  check("blocks file traversal", get("/files/" .. buf .. "/../../../../../../etc/passwd") == 404)
  check("blocks encoded traversal", get("/files/" .. buf .. "/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/etc/passwd") == 404)
  check("rejects foreign Host header", get("/app/preview.js", { "-H", "Host: evil.example" }) == 403)

  -- Symlinks are followed only when they stay inside the allowed directories.
  local sandbox = vim.fn.tempname()
  local notes, secrets = sandbox .. "/notes", sandbox .. "/secrets"
  vim.fn.mkdir(notes, "p")
  vim.fn.mkdir(secrets, "p")
  vim.fn.writefile({ "secret" }, secrets .. "/key.txt")
  vim.fn.writefile({ "<svg xmlns='http://www.w3.org/2000/svg'/>" }, notes .. "/real.svg")
  vim.fn.writefile({ "# Notes" }, notes .. "/index.md")
  assert(vim.uv.fs_symlink(secrets, notes .. "/secrets"))
  assert(vim.uv.fs_symlink(secrets .. "/key.txt", notes .. "/key.txt"))
  assert(vim.uv.fs_symlink(notes .. "/real.svg", notes .. "/alias.svg"))
  local notes_buf = vim.fn.bufadd(notes .. "/index.md")
  check("blocks symlinked directory pointing outside", get("/files/" .. notes_buf .. "/secrets/key.txt") == 404)
  check("blocks symlinked file pointing outside", get("/files/" .. notes_buf .. "/key.txt") == 404)
  check("serves symlink pointing inside", get("/files/" .. notes_buf .. "/alias.svg") == 200)
  check("unknown buffer events 404", get("/events/99999") == 404)

  local head_only = { "-o", "/dev/null", "-D", "-" }
  local _, page_headers = get("/preview/" .. buf, head_only)
  page_headers = page_headers:lower()
  check(
    "page has content security policy",
    page_headers:find("content-security-policy: default-src 'none'; script-src 'self';", 1, true),
    page_headers
  )
  local _, file_headers = get("/files/" .. buf .. "/assets/logo.svg", head_only)
  file_headers = file_headers:lower()
  check(
    "local files are sandboxed",
    file_headers:find("content-security-policy: sandbox", 1, true)
      and file_headers:find("x-content-type-options: nosniff", 1, true),
    file_headers
  )

  -- Live stream: connect, edit the buffer, move the cursor, then read what arrived.
  local stream = curl("/events/" .. buf, { "-N" }, 1.5)
  vim.wait(300)
  opened = nil
  vim.cmd("MdLive")
  check("MdLive reuses a connected tab", opened == nil, opened)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# Edited live" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  local _, events = stream()
  vim.wait(200)
  vim.cmd("MdLive")
  check("MdLive opens a tab again once it is closed", opened ~= nil)

  check("stream sends theme", events:find("event: theme", 1, true))
  check("stream sends initial content", events:find("# mdlive demo", 1, true))
  check("stream sends edited content", events:find("# Edited live", 1, true))
  check("stream sends cursor", events:find('"line":2', 1, true), events:match("event: cursor\ndata: [^\n]*"))
  local view = events:match("event: cursor\ndata: ([^\n]*)")
  view = view and vim.json.decode(view)
  check(
    "cursor event has the visible lines",
    view and type(view.top) == "number" and view.bottom >= view.top and view.total > 0,
    vim.inspect(view)
  )

  -- TextChanged without a change to the text sends nothing new.
  local idle_stream = curl("/events/" .. buf, { "-N" }, 1)
  vim.wait(300)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  local _, idle_events = idle_stream()
  local _, content_events = idle_events:gsub("event: content", "")
  check("unchanged buffer is not sent again", content_events == 1, content_events)

  local theme = events:match("event: theme\ndata: ([^\n]*)")
  local decoded = theme and vim.json.decode(theme)
  check("theme has colors", decoded and decoded.vars and decoded.vars.fg and decoded.mode, theme)

  -- Clicking relative markdown links in the preview.
  local open = "/open/" .. buf .. "?path="
  local same_origin = { "-X", "POST", "-H", "X-MdLive: 1", "-H", "Origin: " .. base }
  check(
    "open link needs custom header",
    get(open .. "docs%2Fguide.md", { "-X", "POST", "-H", "Origin: " .. base }) == 403
  )
  check(
    "open link rejects other origins",
    get(open .. "docs%2Fguide.md", { "-X", "POST", "-H", "X-MdLive: 1", "-H", "Origin: http://evil.example" }) == 403
  )
  check("open link only opens markdown", get(open .. "assets%2Flogo.svg", same_origin) == 404)

  code, body = get(open .. "docs%2Fguide.md", same_origin)
  local guide = vim.api.nvim_get_current_buf()
  local ok_json, data = pcall(vim.json.decode, body)
  check(
    "open link opens file in neovim",
    code == 200 and vim.api.nvim_buf_get_name(guide):match("examples/docs/guide%.md$") and vim.bo[guide].buflisted,
    body
  )
  check(
    "open link returns its preview",
    ok_json and data.url == "/preview/" .. guide and require("mdlive").is_open(guide),
    body
  )
  code, body = get("/open/" .. guide .. "?path=..%2Fdemo.md", same_origin)
  check("link back reuses the demo buffer", code == 200 and vim.api.nvim_get_current_buf() == buf, body)

  -- Double-clicking a block in the preview moves the cursor to its source line.
  code, body = get("/jump/" .. buf .. "?line=15", same_origin)
  check("jump moves the cursor", code == 200 and vim.api.nvim_win_get_cursor(0)[1] == 16, body)
  check(
    "jump needs custom header",
    get("/jump/" .. buf .. "?line=1", { "-X", "POST", "-H", "Origin: " .. base }) == 403
  )

  -- :MdLiveExport: the connected tab renders the page and Neovim writes it.
  local messages = {}
  local notify = vim.notify
  vim.notify = function(msg)
    table.insert(messages, msg)
  end
  local out_dir = vim.fn.tempname()
  vim.fn.mkdir(out_dir, "p")
  local export_path = out_dir .. "/demo.html"
  local export_stream = curl("/events/" .. buf, { "-N" }, 1)
  vim.wait(300)
  vim.cmd("MdLiveExport " .. export_path)
  local _, export_events = export_stream()
  local job = export_events:match("event: export\ndata: ([^\n]*)")
  job = job and vim.json.decode(job)
  check(
    "export asks the tab for the page",
    job and job.id and job.base:match("^%.%./.*examples/$"),
    export_events:match("event: export\ndata: [^\n]*")
  )

  -- Several read chunks, to check the request body is put together.
  local page = "<!doctype html>\n" .. ("<p>exported</p>\n"):rep(20000)
  local page_file = out_dir .. "/page.html"
  local f = assert(io.open(page_file, "wb"))
  f:write(page)
  f:close()
  local send_page = vim.list_extend({ "--data-binary", "@" .. page_file }, same_origin)
  code, body = get("/export/" .. (job and job.id or 0), send_page)
  f = io.open(export_path, "rb")
  local written = f and f:read("*a")
  if f then
    f:close()
  end
  check("export writes the page", code == 200 and written == page, body)
  check("export answers each request once", get("/export/" .. (job and job.id or 0), send_page) == 404)

  messages = {}
  vim.cmd("MdLiveExport " .. export_path)
  check("export refuses to overwrite", (messages[1] or ""):find("exists", 1, true), messages[1])
  vim.notify = notify

  require("mdlive").close(guide)
  vim.wait(200)

  -- Follow mode: a connected tab switches to the markdown buffer you enter.
  opened = nil
  local follow_stream = curl("/events/" .. buf, { "-N" }, 1.5)
  vim.wait(300)
  vim.cmd.edit(root .. "/examples/docs/guide.md")
  guide = vim.api.nvim_get_current_buf()
  local _, follow_events = follow_stream()
  check(
    "follow switches the tab to the entered buffer",
    follow_events:find('event: switch\ndata: {"bufnr":' .. guide .. "}", 1, true),
    follow_events
  )
  check("follow reuses the tab", opened == nil, opened)
  check("follow drops the previous preview", require("mdlive").is_open(guide) and not require("mdlive").is_open(buf))

  -- LSP hover popups are markdown buffers in floating windows: not followed.
  local float_stream = curl("/events/" .. guide, { "-N" }, 1)
  vim.wait(300)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].filetype = "markdown"
  local float = vim.api.nvim_open_win(scratch, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
  vim.api.nvim_win_close(float, true)
  local _, float_events = float_stream()
  check(
    "follow ignores floating windows",
    not float_events:find("event: switch", 1, true) and require("mdlive").is_open(guide),
    float_events
  )

  -- :MdLiveStop from a buffer that is not previewed stops the followed preview.
  vim.cmd.enew()
  vim.cmd("MdLiveStop")
  vim.wait(400)
  check("MdLiveStop stops the followed preview from anywhere", not require("mdlive").is_open(guide))
  -- curl reports status 000 when nothing is listening.
  check("server stops with last preview", get("/app/preview.js") == 0)

  vim.cmd("checkhealth mdlive")
  -- Newer Neovim versions fill the report asynchronously.
  local function health_report()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end
  vim.wait(5000, function()
    return health_report():find("mdlive: browser", 1, true) ~= nil
  end, 20)
  local report = health_report()
  check(
    "checkhealth runs every section",
    report:find("mdlive: installation", 1, true) and report:find("mdlive: browser", 1, true),
    report
  )
  check("checkhealth reports no errors", not report:find("ERROR", 1, true), report)
end, debug.traceback)

if not ok then
  failures = failures + 1
  print("ERROR " .. err)
end
finish()
