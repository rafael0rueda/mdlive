-- Run from the repository root:
--   nvim --headless --clean --cmd "set rtp^=." -c "luafile tests/smoke.lua"
local root = vim.fn.getcwd()
local failures = 0
local windows = vim.fn.has("win32") == 1
-- Where curl writes a body that is not needed.
local devnull = windows and "NUL" or "/dev/null"
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
    table.insert(args, path:match("^http:") and path or base .. path)
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
  -- A stream of the buffer's events, once it is connected.
  local function connected(bufnr, seconds)
    -- The server as it runs now: its port and token change when it starts again.
    local events_url = require("mdlive.server").url(bufnr):gsub("/preview/", "/events/")
    local events_stream = curl(events_url, { "-N" }, seconds or 1)
    vim.wait(2000, function()
      return require("mdlive.server").client_count(bufnr) > 0
    end, 10)
    return events_stream
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
  local files = session .. "/files/" .. buf
  check(
    "blocks traversal with encoded separators, encoded twice or cut short by a NUL",
    get(files .. "/..%2f..%2f..%2f..%2f..%2f..%2fetc%2fpasswd") == 404
      and get(files .. "/%252e%252e/%252e%252e/%252e%252e/%252e%252e/etc/passwd") == 404
      and get(files .. "/../../../../../../etc/passwd%00/assets/logo.svg") == 404
  )
  check("serves the page at one path only", get(session .. "/preview/" .. buf .. "/") == 404)
  check("rejects foreign Host header", get("/app/preview.js", { "-H", "Host: evil.example" }) == 403)
  for _, host in ipairs({
    "localhost.evil.example",
    "127.0.0.1.evil.example",
    "evil.example:" .. base:match(":(%d+)$"),
    "",
  }) do
    check(("rejects the Host header %q"):format(host), get("/app/preview.js", { "-H", "Host: " .. host }) == 403)
  end
  check("rejects a request without a Host header", get("/app/preview.js", { "-H", "Host:" }) == 403)
  -- Through an SSH tunnel, the browser names its own end, on any port.
  check("accepts a forwarded local Host header", get("/app/preview.js", { "-H", "Host: localhost:9" }) == 200)

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
  -- Normalized: forward slashes on Windows too, as the plugin reports paths.
  local sandbox = vim.fs.normalize(vim.fn.tempname())
  local notes, secrets = sandbox .. "/notes", sandbox .. "/secrets"
  vim.fn.mkdir(notes, "p")
  vim.fn.mkdir(secrets, "p")
  vim.fn.writefile({ "secret" }, secrets .. "/key.txt")
  vim.fn.writefile({ "<svg xmlns='http://www.w3.org/2000/svg'/>" }, notes .. "/real.svg")
  vim.fn.writefile({ "# Notes" }, notes .. "/index.md")
  -- Windows needs to know a symlink points to a directory; other systems ignore it.
  assert(vim.uv.fs_symlink(secrets, notes .. "/secrets", { dir = true }))
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
  local to_cwd = ("../"):rep(20) .. vim.fs.normalize(root):gsub("^%a:", ""):sub(2)
  check(
    "serves no cwd files for a buffer outside the cwd",
    get(notes_files .. "/" .. to_cwd .. "/lua/mdlive/init.lua") == 404
  )

  -- `file_root` puts a directory of one's own choice within reach instead.
  setup({ file_root = sandbox })
  check("file_root opens up the directory it names", get(notes_files .. "/../secrets/key.txt") == 200)
  setup()
  check("the files are out of reach again without file_root", get(notes_files .. "/../secrets/key.txt") == 404)
  -- Buffer names have their symlinks resolved, and a `file_root` under a
  -- symlink (such as /tmp on macOS) still has to contain them.
  local sandbox_link = sandbox .. "-link"
  assert(vim.uv.fs_symlink(sandbox, sandbox_link, { dir = true }))
  setup({ file_root = sandbox_link })
  check("file_root may be reached through a symlink", get(notes_files .. "/../secrets/key.txt") == 200)
  setup()
  vim.uv.fs_unlink(sandbox_link)

  -- Files are streamed in chunks, and Range requests get part of them.
  local big = ("0123456789abcdef"):rep(384 * 1024) -- 6 MiB
  local big_file = assert(io.open(notes .. "/big.txt", "wb"))
  big_file:write(big)
  big_file:close()
  code, body = get(notes_files .. "/big.txt")
  check("streams a large file whole", code == 200 and body == big, { code, #body })
  local _, range_headers = get(notes_files .. "/big.txt", { "-H", "Range: bytes=10-19", "-o", devnull, "-D", "-" })
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
  -- The page may run scripts of its own origin: only the bundled ones are scripts.
  vim.fn.writefile({ "document.title = 'probe'" }, notes .. "/probe.js")
  local head_only = { "-o", devnull, "-D", "-" }
  local _, script_headers = get(notes_files .. "/probe.js", head_only)
  local _, app_headers = get("/app/preview.js", head_only)
  vim.fn.writefile({ "not really a sound" }, notes .. "/sound.mp3")
  local _, sound_headers = get(notes_files .. "/sound.mp3", head_only)
  check("audio files have their type", sound_headers:lower():find("content-type: audio/mpeg", 1, true), sound_headers)
  check(
    "a script next to the markdown is served as text",
    script_headers:lower():find("content-type: text/plain", 1, true)
      and script_headers:lower():find("x-content-type-options: nosniff", 1, true)
      and app_headers:lower():find("content-type: text/javascript", 1, true),
    script_headers
  )
  check("unknown buffer events 404", get(session .. "/events/99999") == 404)
  -- Back to the demo buffer's preview.
  vim.cmd("MdLive")

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
  local stream = connected(buf, 1.5)
  opened = nil
  vim.cmd("MdLive")
  check("MdLive reuses a connected tab", opened == nil, opened)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# Edited live" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  local _, events = stream()
  vim.wait(200)
  vim.cmd("MdLive")
  check("MdLive opens a tab again once it is closed", opened ~= nil)

  check("stream sends theme", events:find("event: theme", 1, true))
  -- The options the page renders with, from the last settings event in `stream`.
  local function settings_of(stream)
    local data
    for json in stream:gmatch("event: settings\ndata: ([^\n]*)") do
      data = vim.json.decode(json)
    end
    return data
  end
  local sent = settings_of(events)
  check(
    "stream sends settings before content",
    sent
      and sent.code_line_numbers == true
      and sent.outline == false
      and events:find("event: settings", 1, true) < (events:find("event: content", 1, true) or 0),
    events:match("event: settings\ndata: [^\n]*")
  )
  check("stream sends initial content", events:find("# mdlive demo", 1, true))
  check("stream sends edited content", events:find("# Edited live", 1, true))
  check("stream sends cursor", events:find('"line":2', 1, true), events:match("event: cursor\ndata: [^\n]*"))
  -- The cursor moved while the edit waited to be sent: its line numbers belong to the new text.
  check(
    "a cursor moved during an edit is sent after the edit",
    (events:find('"line":2', 1, true) or 0) > (events:find("# Edited live", 1, true) or math.huge),
    events
  )
  local view = events:match("event: cursor\ndata: ([^\n]*)")
  view = view and vim.json.decode(view)
  check(
    "cursor event has the visible lines",
    view and type(view.top) == "number" and view.bottom >= view.top and view.total > 0,
    vim.inspect(view)
  )

  -- Nothing new is sent while the text does not change.
  local idle_stream = connected(buf, 1)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  local _, idle_events = idle_stream()
  local _, content_events = idle_events:gsub("event: content", "")
  check("unchanged buffer is not sent again", content_events == 1, content_events)

  -- setup() again: open previews get the new options, and wrong options are reported.
  local settings_stream = connected(buf, 1)
  local warnings = {}
  local real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(warnings, msg)
  end
  setup({ code_line_numbers = false, outline = true, port = "8080", colour = true })
  vim.notify = real_notify
  local _, settings_events = settings_stream()
  sent = settings_of(settings_events)
  check(
    "setup() sends new options to open previews",
    sent and sent.code_line_numbers == false and sent.outline == true,
    settings_events:match("event: settings\ndata: [^\n]*")
  )
  local warning = table.concat(warnings, "\n")
  check(
    "setup() warns about wrong options and uses their defaults",
    warning:find("`port`", 1, true) and warning:find("`colour`", 1, true) and require("mdlive.config").options.port == 0,
    warning
  )
  -- Values of the right type that cannot work keep their default too.
  warnings = {}
  vim.notify = function(msg)
    table.insert(warnings, msg)
  end
  setup({ host = "localhost", port = 80.5, debounce_ms = -5, browser = true })
  local refused = vim.deepcopy(require("mdlive.config").options)
  local wildcard = "127.0.0.1"
  for _, every in ipairs({ "0.0.0.0", "::", "::0.0.0.0", "::FFFF:0.0.0.0", "0:0:0:0:0:0:0:0" }) do
    setup({ host = every })
    if require("mdlive.config").options.host ~= "127.0.0.1" then
      wildcard = every
    end
  end
  warning = table.concat(warnings, "\n")
  warnings = {}
  setup({ host = "::1", port = 8090, debounce_ms = 0, browser = false })
  local accepted = vim.deepcopy(require("mdlive.config").options)
  vim.notify = real_notify
  check(
    "setup() refuses a host that is a name or every address, and numbers that cannot work",
    refused.host == "127.0.0.1"
      and refused.port == 0
      and refused.debounce_ms == 150
      and refused.browser == nil
      and wildcard == "127.0.0.1"
      and warning:find("`host` should be an IP address", 1, true)
      and warning:find("`host` should be the address of one interface", 1, true)
      and warning:find("`port` should be a whole number", 1, true)
      and warning:find("`debounce_ms` should be", 1, true)
      and warning:find("`browser` should be false", 1, true),
    warning
  )
  check(
    "setup() accepts an IPv6 address, a fixed port and no delay",
    #warnings == 0 and accepted.host == "::1" and accepted.port == 8090 and accepted.debounce_ms == 0,
    vim.inspect(warnings)
  )
  setup()

  -- The `css` file is sent to open previews, again when it is saved in Neovim,
  -- and a file that cannot be read is reported.
  local css_file = vim.fs.normalize(vim.fn.tempname()) .. ".css"
  vim.fn.writefile({ ".markdown-body { max-width: 600px; }" }, css_file)
  local css_stream = connected(buf, 1.5)
  setup({ css = css_file })
  vim.cmd.split(css_file)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { ".markdown-body { max-width: 700px; }" })
  vim.cmd("silent write")
  vim.cmd("close")
  local _, css_events = css_stream()
  local styles = {}
  for json in css_events:gmatch("event: style\ndata: ([^\n]*)") do
    table.insert(styles, vim.json.decode(json).css)
  end
  check(
    "the css file is sent, and sent again when it is saved",
    vim.tbl_contains(styles, ".markdown-body { max-width: 600px; }\n")
      and styles[#styles] == ".markdown-body { max-width: 700px; }\n",
    styles
  )
  warnings = {}
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(warnings, msg)
  end
  setup({ css = css_file .. ".missing" })
  vim.notify = real_notify
  check("a css file that cannot be read is reported", table.concat(warnings):find("`css` file", 1, true), warnings)
  setup()
  vim.fn.delete(css_file)

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
  check(
    "open link rejects a missing or null origin",
    get(open .. "docs%2Fguide.md", { "-X", "POST", "-H", "X-MdLive: 1" }) == 403
      and get(open .. "docs%2Fguide.md", { "-X", "POST", "-H", "X-MdLive: 1", "-H", "Origin: null" }) == 403
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

  -- A wiki link names a note: when it is not next to the file, it is looked for
  -- by name under the directories the preview may read, and nowhere else.
  check("a plain link is not looked for by name", get(open .. "guide.md", same_origin) == 404)
  code, body = get(open .. "guide.md&wiki=1", same_origin)
  check("a wiki link finds a note by name", code == 200 and vim.api.nvim_get_current_buf() == guide, body)
  get(session .. "/open/" .. guide .. "?path=..%2Fdemo.md", same_origin)
  code, body = get(open .. "outside.md&wiki=1", same_origin)
  check("a wiki link is not looked for outside those directories", code == 404, body)
  local hidden = root .. "/.mdlive-smoke-" .. vim.fn.getpid()
  vim.fn.mkdir(hidden, "p")
  vim.fn.writefile({ "# Hidden" }, hidden .. "/hidden-note.md")
  code = get(open .. "hidden-note.md&wiki=1", same_origin)
  vim.fn.delete(hidden, "rf")
  check("a wiki link skips hidden directories", code == 404 and vim.api.nvim_get_current_buf() == buf)

  -- Double-clicking a block in the preview moves the cursor to its source line.
  code, body = get(session .. "/jump/" .. buf .. "?line=15", same_origin)
  check("jump moves the cursor", code == 200 and vim.api.nvim_win_get_cursor(0)[1] == 16, body)
  check(
    "jump needs custom header",
    get(session .. "/jump/" .. buf .. "?line=1", { "-X", "POST", "-H", "Origin: " .. base }) == 403
  )
  check("jump needs the token", get("/jump/" .. buf .. "?line=1", same_origin) == 404)
  check("jump only takes line numbers", get(session .. "/jump/" .. buf .. "?line=inf", same_origin) == 404)

  -- Scrolling the preview by hand scrolls the window; like CTRL-E, the cursor
  -- only moves to stay in view.
  local scroll = session .. "/scroll/" .. buf .. "?line="
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  code, body = get(scroll .. "30", same_origin)
  local view = vim.fn.winsaveview()
  check(
    "scrolling the preview puts its top line at the top of the window",
    code == 200 and view.topline == 31 and view.lnum >= 31,
    { body = body, topline = view.topline, lnum = view.lnum }
  )
  vim.api.nvim_win_set_cursor(0, { 36, 0 })
  get(scroll .. "32", same_origin)
  view = vim.fn.winsaveview()
  check(
    "a cursor still in view stays where it is",
    view.topline == 33 and view.lnum == 36,
    { topline = view.topline, lnum = view.lnum }
  )
  check("scroll needs custom header", get(scroll .. "1", { "-X", "POST", "-H", "Origin: " .. base }) == 403)
  check("scroll needs the token", get("/scroll/" .. buf .. "?line=1", same_origin) == 404)
  setup({ scroll_editor = false })
  check(
    "scroll_editor = false leaves the window alone",
    get(scroll .. "1", same_origin) == 404 and vim.fn.line("w0") == 33
  )
  setup()

  -- Clicking a task list checkbox ticks or clears its item in the buffer.
  local function buf_line(line)
    return vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
  end
  local task_line
  for i, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text == "- [ ] Something still to do" then
      task_line = i - 1
    end
  end
  local task = session .. "/task/" .. buf .. "?line=" .. tostring(task_line)
  code, body = get(task .. "&checked=1", same_origin)
  check("a task checkbox ticks its item", code == 200 and buf_line(task_line) == "- [x] Something still to do", body)
  check("a task already ticked in the buffer is refused", get(task .. "&checked=1", same_origin) == 404)
  code, body = get(task .. "&checked=0", same_origin)
  check("a task checkbox clears its item", code == 200 and buf_line(task_line) == "- [ ] Something still to do", body)
  local first_line = buf_line(0)
  check(
    "a line that is not a task item is refused",
    get(session .. "/task/" .. buf .. "?line=0&checked=1", same_origin) == 404 and buf_line(0) == first_line
  )
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "> - [ ] quoted task", "", "1. [X] numbered task" })
  code = get(session .. "/task/" .. buf .. "?line=" .. (line_count + 1) .. "&checked=1", same_origin)
  local code2 = get(session .. "/task/" .. buf .. "?line=" .. (line_count + 3) .. "&checked=0", same_origin)
  check(
    "tasks in blockquotes and ordered lists are ticked and cleared",
    code == 200
      and code2 == 200
      and buf_line(line_count + 1) == "> - [x] quoted task"
      and buf_line(line_count + 3) == "1. [ ] numbered task",
    { buf_line(line_count + 1), buf_line(line_count + 3) }
  )
  vim.api.nvim_buf_set_lines(buf, line_count, -1, false, {})
  vim.bo[buf].modifiable = false
  check(
    "a buffer that is not modifiable is refused",
    get(task .. "&checked=1", same_origin) == 404 and buf_line(task_line) == "- [ ] Something still to do"
  )
  vim.bo[buf].modifiable = true
  check("task needs custom header", get(task .. "&checked=1", { "-X", "POST", "-H", "Origin: " .. base }) == 403)
  check(
    "task needs the token",
    get("/task/" .. buf .. "?line=" .. tostring(task_line) .. "&checked=1", same_origin) == 404
  )
  check(
    "task needs a state",
    get(task .. "&checked=yes", same_origin) == 404 and buf_line(task_line):find("[ ]", 1, true)
  )
  check(
    "a task line past the end of the buffer is refused",
    get(session .. "/task/" .. buf .. "?line=99999999999999999999&checked=1", same_origin) == 404
      and get(session .. "/task/" .. buf .. "?line=" .. vim.api.nvim_buf_line_count(buf) .. "&checked=1", same_origin)
        == 404
  )

  -- Export: the connected tab renders the page and Neovim writes it.
  local messages = {}
  local notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(messages, msg)
  end
  local out_dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(out_dir, "p")
  local export_path = out_dir .. "/demo.html"
  local export_stream = connected(buf, 1)
  local exports_done = {}
  local function on_export_done(err, path)
    table.insert(exports_done, { err = err, path = path })
  end
  local export_started = require("mdlive").export(buf, { path = export_path }, on_export_done)
  check("export returns true once the tab is asked", export_started == true)
  local _, export_events = export_stream()
  local job = export_events:match("event: export\ndata: ([^\n]*)")
  job = job and vim.json.decode(job)
  -- On Windows, a file on another drive than the one it is exported to is
  -- linked with a file:// URL.
  local other_drive = windows and root:sub(1, 1):lower() ~= out_dir:sub(1, 1):lower()
  check(
    "export asks the tab for the page",
    job and job.id and job.base:match(other_drive and "^file:///%a:/.*examples/$" or "^%.%./.*examples/$"),
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
  vim.cmd("MdLive export " .. export_path)
  check("export refuses to overwrite", (messages[1] or ""):find("exists", 1, true), messages[1])
  -- The file name ends at |, which starts the next command.
  messages, vim.g.mdlive_bar = {}, nil
  vim.cmd("MdLive export " .. export_path .. " | let g:mdlive_bar = 1")
  check(
    ":MdLive export can be followed by another command",
    (messages[1] or ""):find("exists", 1, true) and vim.g.mdlive_bar == 1,
    messages[1]
  )
  -- % and ~ in the file name are expanded, as for :write.
  messages = {}
  vim.cmd("MdLive export %:p:h/missing/out.html")
  check(
    ":MdLive export expands % in the file name",
    (messages[1] or ""):find("missing does not exist", 1, true) and not messages[1]:find("%", 1, true),
    messages[1]
  )
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
    local full_stream = connected(buf, 1)
    messages = {}
    exports_done = {}
    require("mdlive").export(buf, { path = "/dev/full", force = true }, on_export_done)
    local _, full_events = full_stream()
    local full_job = full_events:match("event: export\ndata: ([^\n]*)")
    full_job = full_job and vim.json.decode(full_job)
    code = get(session .. "/export/" .. (full_job and full_job.id or 0), send_page)
    vim.wait(500, function()
      return #exports_done > 0
    end, 10)
    check(
      "export calls back with a failed write, and shows nothing itself",
      code == 404
        and #exports_done == 1
        and (exports_done[1].err or ""):find("could not write", 1, true)
        and #messages == 0,
      vim.inspect({ exports_done, messages })
    )

    -- The command is what reports it, instead of announcing an exported file.
    full_stream = connected(buf, 1)
    vim.cmd("MdLive! export /dev/full")
    _, full_events = full_stream()
    full_job = full_events:match("event: export\ndata: ([^\n]*)")
    full_job = full_job and vim.json.decode(full_job)
    get(session .. "/export/" .. (full_job and full_job.id or 0), send_page)
    vim.wait(500, function()
      return #messages > 0
    end, 10)
    local reported = table.concat(messages, "\n")
    check(
      ":MdLive export reports a failed write",
      #messages == 1 and reported:find("could not write", 1, true) and not reported:find("exported to", 1, true),
      reported
    )
  end
  vim.notify = notify

  require("mdlive").enable(false, { buf = guide })
  vim.wait(200)

  -- Follow mode: a connected tab switches to the markdown buffer you enter.
  opened = nil
  local follow_stream = connected(buf, 1.5)
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
  local float_stream = connected(guide, 1)
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

  -- A change made from outside the buffer, as a formatter or an LSP rename does.
  local outside_stream = connected(guide)
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(guide, -1, -1, false, { "", "changed from another buffer" })
  local _, outside_events = outside_stream()
  check(
    "a change made while in another buffer reaches the preview",
    outside_events:find("changed from another buffer", 1, true),
    outside_events:sub(-200)
  )
  vim.cmd.buffer(guide)

  -- :edit! unloads the buffer and loads it again.
  local reload_stream = connected(guide)
  vim.cmd("edit!")
  vim.wait(100)
  vim.api.nvim_buf_set_lines(guide, -1, -1, false, { "", "changed after the reload" })
  local _, reload_events = reload_stream()
  check(
    ":edit! keeps the preview, which goes on following the buffer",
    require("mdlive").is_enabled({ buf = guide })
      and not reload_events:find("event: close", 1, true)
      and not reload_events:find("changed from another buffer\n\nchanged after", 1, true)
      and reload_events:find("changed after the reload", 1, true),
    reload_events:sub(-300)
  )
  vim.cmd("edit!")

  -- Buffers entered one right after the other, before the tab had the time to
  -- reconnect: it is sent on to the last one from wherever it connects.
  vim.fn.writefile({ "# Hop" }, notes .. "/hop.md")
  local hop_buf = vim.fn.bufadd(notes .. "/hop.md")
  local hop_stream = connected(guide, 0.5)
  vim.cmd.buffer(buf)
  vim.cmd.buffer(hop_buf)
  local _, hop_events = hop_stream()
  local _, late_events = curl(session .. "/events/" .. buf, { "-N" }, 0.5)()
  check(
    "follow keeps up with buffers entered one right after the other",
    hop_events:find('event: switch\ndata: {"bufnr":' .. buf .. "}", 1, true)
      and late_events:find('event: switch\ndata: {"bufnr":' .. hop_buf .. "}", 1, true)
      and require("mdlive").is_enabled({ buf = hop_buf })
      and not require("mdlive").is_enabled({ buf = buf }),
    vim.inspect({ hop_events:sub(-80), late_events:sub(-80) })
  )

  -- Stopped and started in one go: the tab that was told to close does not count.
  local stop_stream = connected(hop_buf, 0.5)
  opened = nil
  vim.cmd("MdLive stop | MdLive")
  local _, stop_events = stop_stream()
  check(
    "a preview stopped and started at once opens a tab again",
    opened ~= nil and stop_events:find("event: close", 1, true),
    vim.inspect({ opened, stop_events:sub(-80) })
  )

  -- :MdLive stop from a buffer that is not previewed stops the followed preview (and any other).
  vim.cmd.enew()
  vim.cmd("MdLive stop")
  vim.wait(400)
  check(":MdLive stop stops the followed preview from anywhere", not require("mdlive").is_enabled({ buf = guide }))
  -- curl reports status 000 when nothing is listening.
  check("server stops with last preview", get("/app/preview.js") == 0)

  -- A fixed port that another program has: the message says which, and the way out.
  local taken = assert(vim.uv.new_tcp())
  taken:bind("127.0.0.1", 0)
  taken:listen(1, function() end)
  local taken_port = taken:getsockname().port
  setup({ port = taken_port })
  local quiet_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- the error is checked below
  vim.notify = function() end
  local started, start_err = require("mdlive").enable(true, { buf = guide })
  vim.notify = quiet_notify
  taken:close()
  check(
    "a port that is taken is reported with the address and the way out",
    not started
      and (start_err or ""):find("cannot listen on 127.0.0.1:" .. taken_port, 1, true)
      and (start_err or ""):find("port = 0", 1, true)
      and not require("mdlive").is_enabled({ buf = guide }),
    start_err
  )
  ---@diagnostic disable-next-line: missing-fields -- it fails before it needs the handlers
  local returned, port_or_nil, host_err = pcall(require("mdlive.server").start, { host = "localhost", port = 0 })
  check(
    "the server returns an error for a host that is not an address",
    returned and port_or_nil == nil and type(host_err) == "string",
    { returned, port_or_nil, host_err }
  )
  setup()

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
  -- The functions return what happened and show nothing: the commands report.
  local api_messages = {}
  local real_api_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(api_messages, msg)
  end
  local gone = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(gone, { force = true })
  enabled, enable_err = mdlive.enable(true, { buf = gone })
  check(
    "enable() returns an error for an invalid buffer",
    enabled == nil and (enable_err or ""):find("invalid buffer", 1, true),
    enable_err
  )
  mdlive.enable(false, { buf = buf })
  mdlive.enable(true, { buf = buf })
  check("enable() shows nothing, on success or failure", #api_messages == 0, vim.inspect(api_messages))
  vim.notify = real_api_notify
  check("enable() rejects arguments of the wrong type", not pcall(mdlive.enable, "yes"))

  -- Without follow mode every buffer keeps its own preview; enable(false) stops them all.
  setup({ follow = false })
  vim.cmd.buffer(guide)
  mdlive.enable(true, { buf = guide })
  check(
    "previews two buffers without follow mode",
    mdlive.is_enabled({ buf = buf }) and mdlive.is_enabled({ buf = guide })
  )
  vim.cmd("MdLive stop")
  check(
    ":MdLive stop stops only the current buffer's preview",
    mdlive.is_enabled({ buf = buf }) and not mdlive.is_enabled({ buf = guide })
  )
  vim.cmd("MdLive toggle")
  check(":MdLive toggle starts the preview", mdlive.is_enabled({ buf = guide }))
  vim.cmd("MdLive toggle")
  check(":MdLive toggle stops the preview", not mdlive.is_enabled({ buf = guide }) and mdlive.is_enabled({ buf = buf }))
  vim.cmd("MdLive start")
  check(":MdLive start starts the preview", mdlive.is_enabled({ buf = guide }))
  vim.cmd("MdLive stop")
  vim.g.mdlive_bar = nil
  vim.cmd("MdLive toggle | let g:mdlive_bar = 1")
  check(":MdLive can be followed by another command", mdlive.is_enabled({ buf = guide }) and vim.g.mdlive_bar == 1)
  vim.cmd("MdLive toggle")

  -- What the commands say, and :MdLive toggle when the tab of the preview was closed.
  local said = {}
  local real_say = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(said, msg)
  end
  vim.cmd("MdLive")
  check(
    ":MdLive names the file and keeps the URL to itself",
    said[#said] == "[mdlive] previewing guide.md",
    said[#said]
  )
  local tab = connected(guide, 0.3)
  tab()
  vim.wait(2000, function()
    return require("mdlive.server").client_count(guide) == 0
  end, 10)
  opened = nil
  vim.cmd("MdLive toggle")
  check(
    ":MdLive toggle opens the preview again when its tab was closed",
    mdlive.is_enabled({ buf = guide }) and opened ~= nil,
    opened
  )
  vim.cmd("MdLive toggle")
  check(
    ":MdLive toggle stops a preview whose tab has not connected yet",
    not mdlive.is_enabled({ buf = guide }) and said[#said] == "[mdlive] preview stopped",
    said[#said]
  )
  require("mdlive.config").options.browser = false
  vim.cmd("MdLive")
  check(
    "with browser = false, :MdLive shows the URL to open",
    said[#said] == "[mdlive] previewing guide.md at " .. require("mdlive.server").url(guide),
    said[#said]
  )
  setup({ follow = false })
  vim.cmd("MdLive stop | MdLive stop")
  check(
    ":MdLive stop says what it did",
    said[#said - 1] == "[mdlive] preview stopped" and said[#said] == "[mdlive] preview stopped",
    vim.inspect(said)
  )
  vim.cmd("MdLive stop")
  check(":MdLive stop says so when there is no preview", said[#said] == "[mdlive] no preview to stop", said[#said])
  vim.notify = real_say
  mdlive.enable(true, { buf = buf })
  vim.wait(200)

  -- Mistakes are reported and do nothing.
  local command_messages = {}
  local real_command_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(command_messages, msg)
  end
  for _, line in ipairs({ "MdLive start now", "MdLive! stop", "MdLive! toggle", "MdLive! ", "MdLive nope" }) do
    command_messages = {}
    vim.cmd(line)
    check(
      ":" .. line .. " is reported and does nothing",
      #command_messages == 1 and command_messages[1]:find("^%[mdlive%]") and not mdlive.is_enabled({ buf = guide }),
      vim.inspect(command_messages)
    )
  end
  vim.notify = real_command_notify
  check(
    "an unknown subcommand lists the right ones",
    (command_messages[1] or ""):find("unknown subcommand `nope`, use export, start, stop, toggle, url", 1, true),
    command_messages[1]
  )

  -- <Tab> completes the subcommands, then file names after export.
  check(
    ":MdLive completes the subcommands",
    vim.deep_equal(vim.fn.getcompletion("MdLive ", "cmdline"), { "export", "start", "stop", "toggle", "url" })
      and vim.deep_equal(vim.fn.getcompletion("MdLive! t", "cmdline"), { "toggle" })
      and vim.deep_equal(vim.fn.getcompletion("write | MdLive s", "cmdline"), { "start", "stop" }),
    vim.inspect(vim.fn.getcompletion("MdLive ", "cmdline"))
  )
  -- Relative to the working directory, the repository; Windows completes with backslashes.
  local completed = vim.fn.getcompletion("MdLive export examples/de", "cmdline")
  check(
    ":MdLive export completes file names",
    #completed == 1 and vim.fs.normalize(completed[1]) == "examples/demo.md",
    vim.inspect(completed)
  )
  check(
    "subcommands without a file complete nothing",
    #vim.fn.getcompletion("MdLive stop ", "cmdline") == 0,
    vim.inspect(vim.fn.getcompletion("MdLive stop ", "cmdline"))
  )

  for name, sub in pairs({
    MdLive = "start",
    MdLiveStop = "stop",
    MdLiveToggle = "toggle",
    MdLiveUrl = "url",
    MdLiveExport = "export",
  }) do
    local rhs = vim.fn.maparg("<Plug>(" .. name .. ")", "n")
    check("<Plug>(" .. name .. ") runs :MdLive " .. sub, rhs == "<Cmd>MdLive " .. sub .. "<CR>", rhs)
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

  -- Starting a browser: the preview URL carries the token, so it is not put on
  -- a command line, which every user on the machine can read.
  local argv = sandbox .. "/browser-argv.txt"
  local function browser_argument(extra)
    vim.fn.delete(argv)
    local command = { "sh", "-c", 'printf "%s" "$0" > "' .. argv .. '"' }
    setup(vim.tbl_extend("force", { browser = command }, extra or {}))
    vim.cmd.buffer(buf)
    vim.cmd("MdLive")
    vim.wait(3000, function()
      return vim.uv.fs_stat(argv) ~= nil
    end, 20)
    local argument = table.concat(vim.fn.readfile(argv), "")
    require("mdlive").enable(false)
    vim.wait(400)
    return argument
  end

  local argument = browser_argument()
  check("the browser is started on a file, not on the preview URL", argument:match("^file://") ~= nil, argument)
  local redirect = vim.uri_to_fname(argument)
  local redirect_stat = vim.uv.fs_stat(redirect)
  -- Windows has no permission bits; the file is in the user's own cache directory.
  check(
    "only its owner can read the file holding the token",
    windows or (redirect_stat and ("%o"):format(redirect_stat.mode % 512) == "600"),
    redirect_stat and ("%o"):format(redirect_stat.mode % 512)
  )
  local redirect_page = table.concat(vim.fn.readfile(redirect), "\n")
  check(
    "the file redirects to the preview",
    redirect_page:match("http://127%.0%.0%.1:%d+/%x+/preview/%d+") ~= nil,
    redirect_page
  )
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "mdlive" })
  check("the redirect file is removed when Neovim quits", vim.uv.fs_stat(redirect) == nil)

  -- A Neovim that was killed leaves its redirect file: the next one removes it.
  local cache = vim.fs.joinpath(vim.fn.stdpath("cache"), "mdlive")
  local stale, other = cache .. "/open-0123456789abcdef.html", cache .. "/notes.html"
  vim.fn.writefile({ "stale" }, stale)
  vim.fn.writefile({ "not a redirect" }, other)
  local hour_ago = os.time() - 3600
  vim.uv.fs_utime(stale, hour_ago, hour_ago)
  vim.uv.fs_utime(other, hour_ago, hour_ago)
  browser_argument()
  check("old redirect files are removed, and nothing else", vim.wait(2000, function()
    return vim.uv.fs_stat(stale) == nil
  end, 20) and vim.uv.fs_stat(other) ~= nil)
  vim.fn.delete(other)

  local before = #vim.fn.readdir(cache)
  argument = browser_argument({ browser_redirect = false })
  check(
    "browser_redirect = false hands the browser the URL itself",
    argument:match("^http://127%.0%.0%.1:%d+/%x+/preview/%d+$") ~= nil,
    argument
  )
  check("browser_redirect = false writes no file holding the token", #vim.fn.readdir(cache) == before)

  -- Writing the redirect must never keep the preview from opening: point the
  -- cache at a path below a regular file, so the directory cannot be made.
  local real_cache = vim.env.XDG_CACHE_HOME
  vim.env.XDG_CACHE_HOME = notes .. "/index.md"
  argument = browser_argument()
  vim.env.XDG_CACHE_HOME = real_cache
  check(
    "falls back to the URL when the redirect cannot be written",
    argument:match("^http://127%.0%.0%.1:%d+/%x+/preview/%d+$") ~= nil,
    argument
  )
  setup()
  vim.cmd("MdLive")
  check("a browser function is still given the preview URL itself", (opened or ""):match("^http://") ~= nil, opened)
  require("mdlive").enable(false)
  vim.wait(400)

  -- Remote use: browser = false opens nothing, and :MdLiveUrl shows the URL
  -- and copies it through the clipboard provider.
  local real_open = vim.ui.open
  local ui_opened
  ---@diagnostic disable-next-line: duplicate-set-field -- record instead of opening
  vim.ui.open = function(target)
    ui_opened = target
    return nil, nil
  end
  setup({ browser = false })
  opened = nil
  vim.cmd.buffer(buf)
  vim.cmd("MdLive")
  vim.ui.open = real_open
  check(
    "browser = false starts the preview and opens nothing",
    mdlive.is_enabled({ buf = buf }) and opened == nil and ui_opened == nil,
    ui_opened
  )
  local preview_url = require("mdlive.server").url(buf)
  check("url() returns the preview URL", mdlive.url() == preview_url and mdlive.url({ buf = buf }) == preview_url)
  local no_url, no_url_err = mdlive.url({ buf = guide })
  check("url() fails for a buffer without a preview", no_url == nil and no_url_err ~= nil, no_url_err)
  vim.cmd.buffer(guide)
  check("url() falls back to the followed preview", mdlive.url() == preview_url, mdlive.url())

  local copied
  vim.g.clipboard = {
    name = "smoke test",
    copy = {
      ["+"] = function(lines)
        copied = table.concat(lines, "\n")
      end,
      ["*"] = function() end,
    },
    paste = {
      ["+"] = function()
        return {}
      end,
      ["*"] = function()
        return {}
      end,
    },
  }
  local url_messages = {}
  local real_url_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(url_messages, msg)
  end
  vim.cmd("MdLive url")
  local shown = table.concat(url_messages, "\n")
  check(
    ":MdLive url shows the URL and copies it to the clipboard",
    shown:find(preview_url, 1, true) and copied == preview_url,
    { shown = shown, copied = copied }
  )
  require("mdlive").enable(false)
  vim.wait(400)
  url_messages = {}
  vim.cmd("MdLive url")
  vim.notify = real_url_notify
  check(
    ":MdLive url reports a buffer without a preview",
    table.concat(url_messages):find("no preview", 1, true),
    url_messages
  )
  vim.g.clipboard = nil
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
      and deprecations:find("mdlive.open() is deprecated, use mdlive.enable() instead", 1, true)
      -- The same buffer in both, or it would stop every preview.
      and deprecations:find("use mdlive.enable(not mdlive.is_enabled({ buf = 0 }), { buf = 0 }) instead", 1, true),
    deprecations
  )

  -- The commands :MdLive's subcommands replaced run them, and warn once each.
  deprecation_messages = {}
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(deprecation_messages, msg)
  end
  vim.cmd("MdLiveToggle")
  check("deprecated :MdLiveToggle starts the preview", mdlive.is_enabled({ buf = buf }))
  vim.cmd("MdLiveUrl")
  check(
    "deprecated :MdLiveUrl shows the URL",
    table.concat(deprecation_messages, "\n"):find(require("mdlive.server").url(buf), 1, true)
  )
  vim.cmd("MdLiveStop | MdLiveToggle | MdLiveStop")
  check("deprecated :MdLiveStop stops the preview", not mdlive.is_enabled({ buf = buf }))
  vim.cmd("MdLiveExport " .. sandbox .. "/missing/out.html | MdLiveExport! " .. sandbox .. "/missing/out.html")
  vim.notify = real_notify_api
  deprecations = table.concat(deprecation_messages, "\n")
  check(
    "deprecated :MdLiveExport exports to the file given",
    select(2, deprecations:gsub("missing does not exist", "")) == 2,
    deprecations
  )
  check(
    "deprecated commands warn once each",
    select(2, deprecations:gsub("is deprecated", "")) == 5
      and deprecations:find(":MdLiveStop is deprecated, use :MdLive stop instead", 1, true)
      and deprecations:find(":MdLiveExport is deprecated, use :MdLive! export instead", 1, true),
    deprecations
  )
  vim.wait(400)

  -- auto_open previews markdown files, but not LSP hover popups (markdown in a scratch buffer).
  setup({ auto_open = true })
  opened = nil
  local auto_messages = {}
  local real_auto_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field -- capture the messages
  vim.notify = function(msg)
    table.insert(auto_messages, msg)
  end
  local hover = vim.api.nvim_create_buf(false, true)
  local popup = { relative = "editor", row = 1, col = 1, width = 20, height = 3 }
  local hover_win = vim.api.nvim_open_win(hover, true, popup)
  vim.bo[hover].filetype = "markdown"
  vim.api.nvim_win_close(hover_win, true)
  check("auto_open skips LSP hover popups", opened == nil and not require("mdlive").is_enabled({ buf = hover }), opened)
  vim.cmd.edit(notes .. "/index.md")
  check(
    "auto_open previews markdown files, and says so",
    opened ~= nil
      and require("mdlive").is_enabled({ buf = notes_buf })
      and auto_messages[#auto_messages] == "[mdlive] previewing index.md",
    vim.inspect({ opened, auto_messages })
  )
  vim.notify = real_auto_notify
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
