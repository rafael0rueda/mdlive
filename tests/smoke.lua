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
  require("mdlive.server").request_timeout = 1000
  -- The options the checks run with, plus `extra`.
  local function setup(extra)
    local opts = {
      debounce_ms = 20,
      browser = function(url)
        opened = url
      end,
    }
    require("mdlive").setup(vim.tbl_extend("force", opts, extra or {}))
  end
  setup()

  vim.cmd.edit(root .. "/examples/demo.md")
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("MdLive")
  check(
    "opens preview url with a token",
    opened and opened:match("^http://127%.0%.0%.1:%d+/" .. ("%x"):rep(32) .. "/preview/" .. buf .. "$"),
    opened
  )
  local base, session = opened:match("^(http://[^/]+)(/%x+)/")

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

  local code, body = get(session .. "/preview/" .. buf)
  check("serves index.html", code == 200 and body:find("preview.js", 1, true), code)
  check("serves app script", get("/app/preview.js") == 200)
  check("serves katex font", get("/app/vendor/katex/fonts/KaTeX_Main-Regular.woff2") == 200)
  check("serves relative image", get(session .. "/files/" .. buf .. "/assets/logo.svg") == 200)
  check("blocks app traversal", get("/app/../lua/mdlive/init.lua") == 404)
  check("blocks file traversal", get(session .. "/files/" .. buf .. "/../../../../../../etc/passwd") == 404)
  check(
    "blocks encoded traversal",
    get(session .. "/files/" .. buf .. "/%2e%2e/%2e%2e/%2e%2e/%2e%2e/%2e%2e/etc/passwd") == 404
  )
  check("rejects foreign Host header", get("/app/preview.js", { "-H", "Host: evil.example" }) == 403)

  -- Everything but the bundled /app files needs the token of this server start.
  check("page needs the token", get("/preview/" .. buf) == 404)
  check("files need the token", get("/files/" .. buf .. "/assets/logo.svg") == 404)
  check("events need the token", get("/events/" .. buf) == 404)
  check("rejects a wrong token", get("/" .. ("0"):rep(32) .. "/files/" .. buf .. "/assets/logo.svg") == 404)

  -- A connection that never finishes its request is closed.
  local client, client_closed = assert(vim.uv.new_tcp()), false
  client:connect("127.0.0.1", assert(tonumber(base:match(":(%d+)$"))), function(connect_err)
    if connect_err then
      client_closed = true
      return
    end
    client:write("GET /app/preview.js HTTP/1.1\r\n")
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        client_closed = true
      end
    end)
  end)
  check(
    "unfinished requests time out",
    vim.wait(3000, function()
      return client_closed
    end, 10)
  )
  client:close()

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
  check("serves no files for buffers without a preview", get(session .. "/files/" .. notes_buf .. "/real.svg") == 404)
  require("mdlive").enable(true, { buf = notes_buf })
  local notes_files = session .. "/files/" .. notes_buf
  check("blocks symlinked directory pointing outside", get(notes_files .. "/secrets/key.txt") == 404)
  check("blocks symlinked file pointing outside", get(notes_files .. "/key.txt") == 404)
  check("serves symlink pointing inside", get(notes_files .. "/alias.svg") == 200)

  -- The working directory is only a root for files inside it: this buffer is
  -- not, so the repository Neovim was started in stays out of reach.
  local to_cwd = ("../"):rep(20) .. root:sub(2)
  check(
    "serves no cwd files for a buffer outside the cwd",
    get(notes_files .. "/" .. to_cwd .. "/lua/mdlive/init.lua") == 404
  )

  -- `file_root` puts a directory of one's own choice within reach instead.
  setup({ file_root = sandbox })
  check("file_root opens up the directory it names", get(notes_files .. "/../secrets/key.txt") == 200)
  setup()
  check("the files are out of reach again without file_root", get(notes_files .. "/../secrets/key.txt") == 404)

  -- Files are streamed in chunks, and Range requests get part of them.
  local big = ("0123456789abcdef"):rep(384 * 1024) -- 6 MiB
  local big_file = assert(io.open(notes .. "/big.txt", "wb"))
  big_file:write(big)
  big_file:close()
  code, body = get(notes_files .. "/big.txt")
  check("streams a large file whole", code == 200 and body == big, { code, #body })
  local _, range_headers = get(notes_files .. "/big.txt", { "-H", "Range: bytes=10-19", "-o", "/dev/null", "-D", "-" })
  code, body = get(notes_files .. "/big.txt", { "-H", "Range: bytes=10-19" })
  check(
    "answers a range request",
    code == 206
      and body == big:sub(11, 20)
      and range_headers:lower():find("content-range: bytes 10-19/" .. #big, 1, true),
    range_headers
  )
  code, body = get(notes_files .. "/big.txt", { "-H", "Range: bytes=-5" })
  check("answers a suffix range request", code == 206 and body == big:sub(-5), body)
  check("rejects a range past the end", get(notes_files .. "/big.txt", { "-H", "Range: bytes=99999999-" }) == 416)
  vim.fn.mkdir(notes .. "/sub", "p")
  check("serves no directories", get(notes_files .. "/sub") == 404)
  check("unknown buffer events 404", get(session .. "/events/99999") == 404)
  -- Back to the demo buffer's preview.
  vim.cmd("MdLive")

  local head_only = { "-o", "/dev/null", "-D", "-" }
  local _, page_headers = get(session .. "/preview/" .. buf, head_only)
  page_headers = page_headers:lower()
  check(
    "page has content security policy",
    page_headers:find("content-security-policy: default-src 'none'; script-src 'self';", 1, true),
    page_headers
  )
  local _, file_headers = get(session .. "/files/" .. buf .. "/assets/logo.svg", head_only)
  file_headers = file_headers:lower()
  check(
    "local files are sandboxed",
    file_headers:find("content-security-policy: sandbox", 1, true)
      and file_headers:find("x-content-type-options: nosniff", 1, true)
      and file_headers:find("cross-origin-resource-policy: same-origin", 1, true),
    file_headers
  )

  -- Live stream: connect, edit the buffer, move the cursor, then read what arrived.
  local stream = curl(session .. "/events/" .. buf, { "-N" }, 1.5)
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
  check(
    "stream sends settings before content",
    (events:find('event: settings\ndata: {"code_line_numbers":true}', 1, true) or math.huge)
      < (events:find("event: content", 1, true) or 0),
    events:match("event: settings\ndata: [^\n]*")
  )
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
  local idle_stream = curl(session .. "/events/" .. buf, { "-N" }, 1)
  vim.wait(300)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  local _, idle_events = idle_stream()
  local _, content_events = idle_events:gsub("event: content", "")
  check("unchanged buffer is not sent again", content_events == 1, content_events)

  -- setup() again: open previews get the new options, and wrong options are reported.
  local settings_stream = curl(session .. "/events/" .. buf, { "-N" }, 1)
  vim.wait(300)
  local warnings = {}
  local real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(warnings, msg)
  end
  setup({ code_line_numbers = false, port = "8080", colour = true })
  vim.notify = real_notify
  local _, settings_events = settings_stream()
  check(
    "setup() sends new options to open previews",
    settings_events:find('event: settings\ndata: {"code_line_numbers":false}', 1, true),
    settings_events:match("event: settings\ndata: [^\n]*")
  )
  local warning = table.concat(warnings, "\n")
  check(
    "setup() warns about wrong options and uses their defaults",
    warning:find("`port`", 1, true) and warning:find("`colour`", 1, true) and require("mdlive.config").options.port == 0,
    warning
  )
  setup()

  local theme = events:match("event: theme\ndata: ([^\n]*)")
  local decoded = theme and vim.json.decode(theme)
  check("theme has colors", decoded and decoded.vars and decoded.vars.fg and decoded.mode, theme)

  -- Clicking relative markdown links in the preview.
  local open = session .. "/open/" .. buf .. "?path="
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
  -- A link may not reach outside the markdown's directory and the cwd, which
  -- would also make the directory it lands in serve its files.
  vim.fn.writefile({ "# Outside" }, secrets .. "/outside.md")
  local outside = vim.uri_encode(("../"):rep(20) .. secrets:sub(2) .. "/outside.md")
  code, body = get(open .. outside, same_origin)
  check("open link stays inside the allowed directories", code == 404, body)
  check(
    "open link does not add a preview for an outside file",
    vim.fn.bufnr(secrets .. "/outside.md") == -1 and not vim.api.nvim_buf_get_name(0):find("outside", 1, true)
  )

  -- A client that does not know the token cannot make Neovim wait for, and
  -- buffer, a body: the request is answered before the body is sent.
  local port = assert(tonumber(base:match(":(%d+)$")))
  local raw, status = assert(vim.uv.new_tcp()), nil
  raw:connect("127.0.0.1", port, function(connect_err)
    if connect_err then
      return
    end
    local head = "POST /nope/nope HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: %d\r\n\r\n"
    raw:write(head:format(port, 64 * 1024 * 1024))
    raw:read_start(function(_, chunk)
      status = status or (chunk and chunk:match("^HTTP/1%.1 (%d+)"))
    end)
  end)
  check("answers a body it will not read without waiting for it", vim.wait(2000, function()
    return status ~= nil
  end, 10) and status == "404", status)
  raw:close()

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
    ok_json and data.url == session .. "/preview/" .. guide and require("mdlive").is_enabled({ buf = guide }),
    body
  )
  -- guide.md is in examples/docs, the image a directory up: still under the cwd.
  check(
    "serves cwd files for a buffer inside the cwd",
    get(session .. "/files/" .. guide .. "/../assets/logo.svg") == 200
  )
  code, body = get(session .. "/open/" .. guide .. "?path=..%2Fdemo.md", same_origin)
  check("link back reuses the demo buffer", code == 200 and vim.api.nvim_get_current_buf() == buf, body)

  -- Double-clicking a block in the preview moves the cursor to its source line.
  code, body = get(session .. "/jump/" .. buf .. "?line=15", same_origin)
  check("jump moves the cursor", code == 200 and vim.api.nvim_win_get_cursor(0)[1] == 16, body)
  check(
    "jump needs custom header",
    get(session .. "/jump/" .. buf .. "?line=1", { "-X", "POST", "-H", "Origin: " .. base }) == 403
  )
  check("jump needs the token", get("/jump/" .. buf .. "?line=1", same_origin) == 404)
  check("jump only takes line numbers", get(session .. "/jump/" .. buf .. "?line=inf", same_origin) == 404)

  -- Export: the connected tab renders the page and Neovim writes it.
  local messages = {}
  local notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(messages, msg)
  end
  local out_dir = vim.fn.tempname()
  vim.fn.mkdir(out_dir, "p")
  local export_path = out_dir .. "/demo.html"
  local export_stream = curl(session .. "/events/" .. buf, { "-N" }, 1)
  vim.wait(300)
  local exports_done = {}
  local function on_export_done(err, path)
    table.insert(exports_done, { err = err, path = path })
  end
  local export_started = require("mdlive").export(buf, { path = export_path }, on_export_done)
  check("export returns true once the tab is asked", export_started == true)
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
  code, body = get(session .. "/export/" .. (job and job.id or 0), send_page)
  local exported = io.open(export_path, "rb")
  local written = exported and exported:read("*a")
  if exported then
    exported:close()
  end
  check("export writes the page", code == 200 and written == page, body)
  vim.wait(500, function()
    return #exports_done > 0
  end, 10)
  check(
    "export calls back once with the written path",
    #exports_done == 1 and exports_done[1].err == nil and exports_done[1].path == export_path,
    vim.inspect(exports_done)
  )
  check("export answers each request once", get(session .. "/export/" .. (job and job.id or 0), send_page) == 404)

  messages = {}
  vim.cmd("MdLiveExport " .. export_path)
  check("export refuses to overwrite", (messages[1] or ""):find("exists", 1, true), messages[1])
  exports_done = {}
  local refused, refused_err = require("mdlive").export(buf, { path = export_path }, on_export_done)
  vim.wait(500, function()
    return #exports_done > 0
  end, 10)
  check(
    "export returns the error and calls back with it",
    refused == nil
      and (refused_err or ""):find("exists", 1, true)
      and #exports_done == 1
      and exports_done[1].err == refused_err,
    vim.inspect({ refused_err, exports_done })
  )

  -- A write that fails is reported instead of announced as exported.
  if vim.uv.fs_stat("/dev/full") then
    local full_stream = curl(session .. "/events/" .. buf, { "-N" }, 1)
    vim.wait(300)
    messages = {}
    exports_done = {}
    require("mdlive").export(buf, { path = "/dev/full", force = true }, on_export_done)
    local _, full_events = full_stream()
    local full_job = full_events:match("event: export\ndata: ([^\n]*)")
    full_job = full_job and vim.json.decode(full_job)
    code = get(session .. "/export/" .. (full_job and full_job.id or 0), send_page)
    local reported = table.concat(messages, "\n")
    check(
      "export reports a failed write",
      code == 404 and reported:find("could not write", 1, true) and not reported:find("exported to", 1, true),
      reported
    )
    vim.wait(500, function()
      return #exports_done > 0
    end, 10)
    check(
      "export calls back with a failed write",
      #exports_done == 1 and (exports_done[1].err or ""):find("could not write", 1, true),
      vim.inspect(exports_done)
    )
  end
  vim.notify = notify

  require("mdlive").enable(false, { buf = guide })
  vim.wait(200)

  -- Follow mode: a connected tab switches to the markdown buffer you enter.
  opened = nil
  local follow_stream = curl(session .. "/events/" .. buf, { "-N" }, 1.5)
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
  check(
    "follow drops the previous preview",
    require("mdlive").is_enabled({ buf = guide }) and not require("mdlive").is_enabled({ buf = buf })
  )

  -- LSP hover popups are markdown buffers in floating windows: not followed.
  local float_stream = curl(session .. "/events/" .. guide, { "-N" }, 1)
  vim.wait(300)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].filetype = "markdown"
  local float = vim.api.nvim_open_win(scratch, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
  vim.api.nvim_win_close(float, true)
  local _, float_events = float_stream()
  check(
    "follow ignores floating windows",
    not float_events:find("event: switch", 1, true) and require("mdlive").is_enabled({ buf = guide }),
    float_events
  )

  -- :MdLiveStop from a buffer that is not previewed stops the followed preview (and any other).
  vim.cmd.enew()
  vim.cmd("MdLiveStop")
  vim.wait(400)
  check("MdLiveStop stops the followed preview from anywhere", not require("mdlive").is_enabled({ buf = guide }))
  -- curl reports status 000 when nothing is listening.
  check("server stops with last preview", get("/app/preview.js") == 0)

  opened = nil
  require("mdlive").enable(true, { buf = guide })
  check("a new server start gets a new token", opened and not opened:find(session .. "/", 1, true), opened)
  require("mdlive").enable(false, { buf = guide })
  vim.wait(200)

  -- Lua API: return values and buffer filters.
  local mdlive = require("mdlive")
  vim.cmd.buffer(buf)
  local enabled, enable_err = mdlive.enable(true, { buf = 0 })
  check("enable() returns true", enabled == true and enable_err == nil, enable_err)
  check(
    "is_enabled() with buffer 0, a buffer number and no filter",
    mdlive.is_enabled({ buf = 0 }) and mdlive.is_enabled({ buf = buf }) and mdlive.is_enabled()
  )
  local gone = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(gone, { force = true })
  enabled, enable_err = mdlive.enable(true, { buf = gone })
  check(
    "enable() returns an error for an invalid buffer",
    enabled == nil and (enable_err or ""):find("invalid buffer", 1, true),
    enable_err
  )
  check("enable() rejects arguments of the wrong type", not pcall(mdlive.enable, "yes"))

  -- Without follow mode every buffer keeps its own preview; enable(false) stops them all.
  setup({ follow = false })
  vim.cmd.buffer(guide)
  mdlive.enable(true, { buf = guide })
  check(
    "previews two buffers without follow mode",
    mdlive.is_enabled({ buf = buf }) and mdlive.is_enabled({ buf = guide })
  )
  vim.cmd("MdLiveStop")
  check(
    "MdLiveStop stops only the current buffer's preview",
    mdlive.is_enabled({ buf = buf }) and not mdlive.is_enabled({ buf = guide })
  )
  vim.cmd("MdLiveToggle")
  check("MdLiveToggle starts the preview", mdlive.is_enabled({ buf = guide }))
  vim.cmd("MdLiveToggle")
  check("MdLiveToggle stops the preview", not mdlive.is_enabled({ buf = guide }) and mdlive.is_enabled({ buf = buf }))
  for _, name in ipairs({ "MdLive", "MdLiveStop", "MdLiveToggle", "MdLiveExport" }) do
    local rhs = vim.fn.maparg("<Plug>(" .. name .. ")", "n")
    check("<Plug>(" .. name .. ") runs :" .. name, rhs == "<Cmd>" .. name .. "<CR>", rhs)
  end
  vim.cmd([[execute "normal \<Plug>(MdLiveToggle)"]])
  check("<Plug>(MdLiveToggle) starts the preview", mdlive.is_enabled({ buf = guide }))
  vim.cmd([[execute "normal \<Plug>(MdLiveToggle)"]])
  check("<Plug>(MdLiveToggle) stops the preview", not mdlive.is_enabled({ buf = guide }))
  enabled = mdlive.enable(false)
  check("enable(false) stops every preview", enabled == true and not mdlive.is_enabled())
  vim.wait(400)
  check("server stops after enable(false)", not require("mdlive.server").is_running())
  setup()

  -- The deprecated names still work and warn once each.
  local deprecation_messages = {}
  local real_notify_api = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(deprecation_messages, msg)
  end
  vim.cmd.buffer(buf)
  mdlive.open()
  check("deprecated open() starts the preview", mdlive.is_open() and mdlive.is_open(buf))
  mdlive.toggle()
  check("deprecated toggle() stops the preview", not mdlive.is_enabled({ buf = buf }))
  mdlive.open(buf)
  mdlive.close(buf)
  check("deprecated close() stops the preview", not mdlive.is_enabled())
  vim.notify = real_notify_api
  local deprecations = table.concat(deprecation_messages, "\n")
  check(
    "deprecated functions warn once each",
    select(2, deprecations:gsub("is deprecated", "")) == 4
      and deprecations:find("mdlive.open() is deprecated, use mdlive.enable() instead", 1, true),
    deprecations
  )
  vim.wait(400)

  -- auto_open previews markdown files, but not LSP hover popups (markdown in a scratch buffer).
  setup({ auto_open = true })
  opened = nil
  local hover = vim.api.nvim_create_buf(false, true)
  local popup = { relative = "editor", row = 1, col = 1, width = 20, height = 3 }
  local hover_win = vim.api.nvim_open_win(hover, true, popup)
  vim.bo[hover].filetype = "markdown"
  vim.api.nvim_win_close(hover_win, true)
  check("auto_open skips LSP hover popups", opened == nil and not require("mdlive").is_enabled({ buf = hover }), opened)
  vim.cmd.edit(notes .. "/index.md")
  check(
    "auto_open previews markdown files",
    opened ~= nil and require("mdlive").is_enabled({ buf = notes_buf }),
    opened
  )
  require("mdlive").enable(false, { buf = notes_buf })
  vim.wait(200)
  setup()

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
