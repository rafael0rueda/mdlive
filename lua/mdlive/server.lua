-- Minimal HTTP + Server-Sent Events server built on vim.uv (no external dependencies).
local uv = vim.uv

local M = {}

---@class mdlive.ServerOpts
---@field host string
---@field port integer
---@field is_previewed fun(bufnr: integer): boolean
---@field buf_dir fun(bufnr: integer): string|nil Directory the buffer's files are served from.
---@field file_roots fun(dir: string): string[] Directories the files of `dir` may come from.
---@field on_subscribe fun(bufnr: integer) Handles a tab connecting to the buffer's preview.
---@field on_open_link fun(bufnr: integer, path: string): string|nil, string|nil Handles a clicked markdown link; returns the preview path of the opened file.
---@field on_jump fun(bufnr: integer, line: integer|nil): true|nil, string|nil Handles a double-clicked block; `line` is 0-based.
---@field on_task fun(bufnr: integer, line: integer|nil, checked: boolean|nil): true|nil, string|nil Handles a clicked task list checkbox; `line` is 0-based.
---@field on_export fun(id: integer, html: string, err: string|nil): true|nil, string|nil Handles the rendered page of a pending export.

local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local app_dir = vim.fs.joinpath(root, "app")

local max_head = 64 * 1024
-- Exports send the whole rendered page, with fonts and diagrams inlined.
local max_body = 64 * 1024 * 1024
-- A browser tab that stopped reading is dropped once this much is waiting to
-- be sent; it reconnects and gets the whole buffer again.
local max_queue = 32 * 1024 * 1024

-- Connections that have not sent a whole request by then are closed. A field
-- so the tests can shorten it.
M.request_timeout = 10000

---@class (private) mdlive.ServerState
---@field server? uv.uv_tcp_t
---@field host? string
---@field port? integer
---@field token? string
---@field heartbeat? uv.uv_timer_t
---@field handlers? mdlive.ServerOpts
---@field clients table<integer, table<uv.uv_tcp_t, true>>

---@type mdlive.ServerState
local state = {
  server = nil,
  host = nil,
  port = nil,
  -- Random per server start; every URL except the bundled /app files needs it,
  -- so other users and programs on the machine cannot read or act on previews.
  token = nil,
  heartbeat = nil,
  handlers = nil,
  clients = {}, -- [bufnr] = { [socket] = true }
}

local mime = {
  html = "text/html; charset=utf-8",
  js = "text/javascript; charset=utf-8",
  css = "text/css; charset=utf-8",
  json = "application/json",
  svg = "image/svg+xml",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  bmp = "image/bmp",
  ico = "image/x-icon",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  pdf = "application/pdf",
  md = "text/plain; charset=utf-8",
  markdown = "text/plain; charset=utf-8",
  txt = "text/plain; charset=utf-8",
  mp4 = "video/mp4",
  webm = "video/webm",
}

local function close(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function drop(sock)
  for _, set in pairs(state.clients) do
    set[sock] = nil
  end
  close(sock)
end

-- Writes to a live preview connection, dropping it if it stopped reading.
local function send(sock, payload)
  if sock:get_write_queue_size() > max_queue then
    return drop(sock)
  end
  sock:write(payload)
end

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function query_param(target, name)
  local query = "&" .. (target:match("%?([^#]*)") or "")
  local value = query:match("&" .. name .. "=([^&]*)")
  return value and url_decode(value)
end

-- Status line and headers of a response.
local function head(status, headers)
  local lines = { "HTTP/1.1 " .. status }
  headers["Connection"] = "close"
  headers["X-Content-Type-Options"] = "nosniff"
  headers["Referrer-Policy"] = "no-referrer"
  -- Other websites cannot embed these responses, e.g. to probe for local files.
  headers["Cross-Origin-Resource-Policy"] = "same-origin"
  for k, v in pairs(headers) do
    lines[#lines + 1] = k .. ": " .. v
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

local function respond(sock, status, headers, body)
  if sock:is_closing() then
    return
  end
  body = body or ""
  headers["Content-Length"] = #body
  sock:write(head(status, headers) .. body, function()
    close(sock)
  end)
end

local function text(sock, status, msg)
  respond(sock, status, { ["Content-Type"] = "text/plain; charset=utf-8" }, msg)
end

local function json(sock, status, data)
  respond(sock, status, { ["Content-Type"] = "application/json" }, vim.json.encode(data))
end

-- The preview page may only run its own bundled scripts, so HTML inside a
-- markdown file can neither execute code nor send data anywhere.
local page_policy = table.concat({
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https: http:",
  "media-src 'self' data: https: http:",
  "font-src 'self' data:",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
}, "; ")

-- Files next to the markdown are opened in a sandbox, so an .html or .svg from
-- an untrusted repository cannot run scripts that talk to this server.
local file_policy = "sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'"

-- Resolves `rel` against `dir` and returns it only if it stays inside one of
-- `roots`. Symlinks are resolved first, so a link cannot point outside them.
local function resolve(dir, rel, roots)
  local real = uv.fs_realpath(vim.fs.joinpath(dir, rel))
  if not real then
    return nil
  end
  real = vim.fs.normalize(real)
  for _, r in ipairs(roots) do
    local real_root = uv.fs_realpath(r)
    if real_root and vim.fs.relpath(vim.fs.normalize(real_root), real) then
      return real
    end
  end
end

-- The 0-based first and last byte a Range header asks for. Returns nothing for
-- the whole file (no header, or several ranges) and false for a range outside it.
local function byte_range(value, size)
  local first, last = (value or ""):match("^bytes=(%d*)-(%d*)$")
  if not first or (first == "" and last == "") then
    return nil
  end
  if first == "" then
    -- bytes=-N: the last N bytes.
    local count = tonumber(last)
    if count == 0 then
      return false
    end
    first, last = math.max(0, size - count), size - 1
  else
    first, last = tonumber(first), math.min(tonumber(last) or size - 1, size - 1)
  end
  if first > last then
    return false
  end
  return first, last
end

local chunk_size = 256 * 1024

-- Streams a file in chunks, waiting for each to be sent, so large media neither
-- blocks Neovim nor has to fit in memory. Range requests let videos seek.
local function serve_file(sock, path, headers, range)
  if not path then
    return text(sock, "404 Not Found", "Not found")
  end
  headers = headers or {}
  uv.fs_open(path, "r", 438, function(_, fd)
    if not fd then
      return text(sock, "404 Not Found", "Not found")
    end
    uv.fs_fstat(fd, function(_, stat)
      if not stat or stat.type ~= "file" or sock:is_closing() then
        uv.fs_close(fd)
        return text(sock, "404 Not Found", "Not found")
      end

      local status = "200 OK"
      local first, last = byte_range(range, stat.size)
      if first == false then
        uv.fs_close(fd)
        return respond(sock, "416 Range Not Satisfiable", { ["Content-Range"] = "bytes */" .. stat.size })
      elseif first then
        status = "206 Partial Content"
        headers["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, stat.size)
      else
        first, last = 0, stat.size - 1
      end
      local ext = (path:match("%.(%w+)$") or ""):lower()
      headers["Content-Type"] = mime[ext] or "application/octet-stream"
      headers["Cache-Control"] = "no-cache"
      headers["Accept-Ranges"] = "bytes"
      headers["Content-Length"] = ("%d"):format(last - first + 1)

      local offset = first
      local function finish()
        uv.fs_close(fd)
        close(sock)
      end
      local function send_next(write_err)
        if write_err or offset > last or sock:is_closing() then
          return finish()
        end
        uv.fs_read(fd, math.min(chunk_size, last - offset + 1), offset, function(read_err, data)
          -- Also stops when the file got shorter while being sent.
          if read_err or not data or data == "" or sock:is_closing() then
            return finish()
          end
          offset = offset + #data
          sock:write(data, send_next)
        end)
      end
      sock:write(head(status, headers), send_next)
    end)
  end)
end

local function frame(event, data)
  return "event: " .. event .. "\ndata: " .. vim.json.encode(data) .. "\n\n"
end

local function subscribe(sock, bufnr)
  sock:write(table.concat({
    "HTTP/1.1 200 OK",
    "Content-Type: text/event-stream",
    "Cache-Control: no-cache",
    "Connection: keep-alive",
    "X-Content-Type-Options: nosniff",
    "Cross-Origin-Resource-Policy: same-origin",
    "",
    "",
  }, "\r\n"))
  state.clients[bufnr] = state.clients[bufnr] or {}
  state.clients[bufnr][sock] = true
  assert(state.handlers).on_subscribe(bufnr)
end

-- Rejects requests whose Host header is not local, which blocks DNS-rebinding attacks.
local function allowed_host(value)
  if not value then
    return false
  end
  local name = value:match("^%[(.-)%]") or value:match("^([^:]+)")
  return name == "localhost" or name == "127.0.0.1" or name == "::1" or name == state.host
end

-- POST requests act in Neovim. The custom header forces a CORS preflight, which
-- this server never approves, so other websites cannot send them; the Origin
-- check is a second guard.
local function post(sock, path, target, headers, body)
  if headers["x-mdlive"] ~= "1" or headers.origin ~= "http://" .. headers.host then
    return json(sock, "403 Forbidden", { error = "forbidden" })
  end
  local h = assert(state.handlers)
  local action, digits = path:match("^/(%l+)/(%d+)$")
  if not action then
    return json(sock, "404 Not Found", { error = "not found" })
  end
  local id = tonumber(digits) --[[@as integer]]

  local result, err
  if action == "export" then
    -- /export/<id>[?error=]: the rendered page for a pending export.
    result, err = h.on_export(id, body, query_param(target, "error"))
  elseif action == "open" or action == "jump" or action == "task" then
    if not h.is_previewed(id) then
      return json(sock, "404 Not Found", { error = "no preview for this buffer" })
    end
    if action == "open" then
      -- /open/<bufnr>?path=: a relative markdown link was clicked.
      result, err = h.on_open_link(id, query_param(target, "path") or "")
    elseif action == "jump" then
      -- /jump/<bufnr>?line=: a block was double-clicked.
      local line = query_param(target, "line")
      result, err = h.on_jump(id, line and line:match("^%d+$") and tonumber(line))
    else
      -- /task/<bufnr>?line=&checked=: a task list checkbox was clicked.
      local line = query_param(target, "line")
      local checked = ({ ["1"] = true, ["0"] = false })[query_param(target, "checked") or ""]
      result, err = h.on_task(id, line and line:match("^%d+$") and tonumber(line), checked)
    end
  else
    return json(sock, "404 Not Found", { error = "not found" })
  end

  if not result then
    return json(sock, "404 Not Found", { error = err })
  end
  json(sock, "200 OK", type(result) == "string" and { url = result } or { ok = true })
end

local function handle(sock, request)
  local method, target, headers = request.method, request.target, request.headers
  if not allowed_host(headers.host) then
    return text(sock, "403 Forbidden", "Forbidden")
  end

  local path = url_decode((target:gsub("[?#].*$", "")))

  -- The bundled page scripts and styles hold nothing private.
  local asset = path:match("^/app/(.+)$")
  if asset and method == "GET" then
    return serve_file(sock, resolve(app_dir, asset, { app_dir }), nil, headers.range)
  end

  local token, rest = path:match("^/(%x+)(/.*)$")
  if not token or token ~= state.token then
    return text(sock, "404 Not Found", "Not found")
  end
  path = rest
  local h = assert(state.handlers)

  if method == "POST" then
    return post(sock, path, target, headers, request.body)
  end
  if method ~= "GET" then
    return text(sock, "405 Method Not Allowed", "Method not allowed")
  end

  if path:match("^/preview/%d+/?$") then
    local page = vim.fs.joinpath(app_dir, "index.html")
    return serve_file(sock, page, { ["Content-Security-Policy"] = page_policy }, headers.range)
  end

  local bufnr = tonumber(path:match("^/events/(%d+)$"))
  if bufnr then
    if not h.is_previewed(bufnr) then
      return text(sock, "404 Not Found", "No preview for this buffer")
    end
    return subscribe(sock, bufnr)
  end

  local b, file = path:match("^/files/(%d+)/(.+)$")
  b = tonumber(b)
  if b then
    -- Only for buffers being previewed, not every file open in Neovim.
    local dir = h.is_previewed(b) and h.buf_dir(b)
    local full = dir and resolve(dir, file, h.file_roots(dir))
    -- PDFs cannot script this origin, and browsers refuse to show them sandboxed.
    local is_pdf = full and full:lower():match("%.pdf$")
    return serve_file(sock, full, { ["Content-Security-Policy"] = not is_pdf and file_policy or nil }, headers.range)
  end

  text(sock, "404 Not Found", "Not found")
end

-- Only an export POST that already carries the token may send a body. Anything
-- else is answered without reading one, so a client that does not know the
-- token cannot make Neovim buffer up to `max_body`.
local function accepts_body(request)
  if request.method ~= "POST" or not state.token then
    return false
  end
  return (request.target or ""):match("^/(%x+)/") == state.token
end

local function parse_head(head)
  local method, target = head:match("^(%u+) (%S+) HTTP/1%.[01]\r\n")
  local headers = {}
  for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
    headers[name:lower()] = value
  end
  return { method = method, target = target, headers = headers }
end

local function on_connection(err)
  if err then
    return
  end
  local sock = assert(uv.new_tcp())
  assert(state.server):accept(sock)

  local chunks, size, request, handled = {}, 0, nil, false
  local timer = assert(uv.new_timer())
  timer:start(M.request_timeout, 0, function()
    close(timer)
    if not handled then
      handled = true
      drop(sock)
    end
  end)
  sock:read_start(function(read_err, chunk)
    if read_err or not chunk then
      close(timer)
      return drop(sock)
    end
    if handled then
      return
    end
    chunks[#chunks + 1] = chunk
    size = size + #chunk

    if not request then
      local data = table.concat(chunks)
      chunks = { data }
      local head_end = data:find("\r\n\r\n", 1, true)
      if not head_end then
        if size > max_head then
          handled = true
          close(timer)
          drop(sock)
        end
        return
      end
      request = parse_head(data:sub(1, head_end))
      request.body_start = head_end + 4
      request.length = tonumber((request.headers["content-length"] or "0"):match("^%s*(%d+)%s*$"))
      if not accepts_body(request) then
        request.length = 0
      elseif not request.length then
        request.error = "400 Bad Request"
      elseif request.length > max_body then
        request.error = "413 Content Too Large"
      end
    end
    if not request.error and size < request.body_start + request.length - 1 then
      return -- wait for the rest of the body
    end

    handled = true
    close(timer)
    if not request.error then
      request.body = table.concat(chunks):sub(request.body_start, request.body_start + request.length - 1)
    end
    chunks = nil
    -- Handlers use the Neovim API, which is not allowed inside luv callbacks.
    vim.schedule(function()
      if sock:is_closing() then
        return
      end
      if request.error or not request.method then
        return text(sock, request.error or "400 Bad Request", "Bad request")
      end
      local ok, e = pcall(handle, sock, request)
      if not ok then
        -- The message can name local paths, and a client without the token
        -- reaches this too: it goes to Neovim, not into the response.
        vim.notify("[mdlive] " .. tostring(e), vim.log.levels.ERROR)
        text(sock, "500 Internal Server Error", "Internal error")
      end
    end)
  end)
end

--- Resolves `rel` against `dir` and returns the real path, or nil when it does
--- not exist or leads outside every directory in `roots`.
---@param dir string
---@param rel string
---@param roots string[]
---@return string|nil
function M.resolve(dir, rel, roots)
  return resolve(dir, rel, roots)
end

--- Starts the server, or returns the port of the one already running.
---@param opts mdlive.ServerOpts
---@return integer|nil port
---@return string|nil err
function M.start(opts)
  if state.server then
    return state.port
  end
  local server = assert(uv.new_tcp())
  local ok, err = server:bind(opts.host, opts.port)
  if not ok then
    close(server)
    return nil, err
  end
  state.server, state.host, state.handlers = server, opts.host, opts
  state.token = assert(uv.random(16)):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end)
  ok, err = server:listen(128, on_connection)
  if not ok then
    M.stop()
    return nil, err
  end
  state.port = server:getsockname().port

  -- Comments keep idle connections alive and let us notice closed tabs.
  local heartbeat = assert(uv.new_timer())
  state.heartbeat = heartbeat
  heartbeat:start(15000, 15000, function()
    for _, set in pairs(state.clients) do
      for sock in pairs(set) do
        if not sock:is_closing() then
          send(sock, ": ping\n\n")
        end
      end
    end
  end)
  return state.port
end

--- Stops the server and closes every connection.
function M.stop()
  for _, set in pairs(state.clients) do
    for sock in pairs(set) do
      close(sock)
    end
  end
  state.clients = {}
  close(state.heartbeat)
  close(state.server)
  state.server, state.port, state.token, state.heartbeat, state.handlers = nil, nil, nil, nil, nil
end

---@return boolean
function M.is_running()
  return state.server ~= nil
end

--- Port the server listens on, nil when it is not running.
---@return integer|nil
function M.port()
  return state.port
end

--- Number of browser tabs connected to a buffer's preview.
---@param bufnr integer
---@return integer
function M.client_count(bufnr)
  local count = 0
  for sock in pairs(state.clients[bufnr] or {}) do
    if not sock:is_closing() then
      count = count + 1
    end
  end
  return count
end

--- Sends an event to every tab connected to a buffer's preview.
---@param bufnr integer|nil
---@param event string
---@param data table
function M.broadcast(bufnr, event, data)
  local set = state.clients[bufnr]
  if not set then
    return
  end
  local payload = frame(event, data)
  for sock in pairs(set) do
    if sock:is_closing() then
      set[sock] = nil
    else
      send(sock, payload)
    end
  end
end

--- Closes every browser connection for a buffer.
---@param bufnr integer
function M.disconnect(bufnr)
  for sock in pairs(state.clients[bufnr] or {}) do
    close(sock)
  end
  state.clients[bufnr] = nil
end

--- Path of a buffer's preview page, token included.
---@param bufnr integer
---@return string
function M.preview_path(bufnr)
  return ("/%s/preview/%d"):format(state.token, bufnr)
end

--- URL of a buffer's preview page.
---@param bufnr integer
---@return string
function M.url(bufnr)
  local host = assert(state.host, "the server is not running")
  if host == "0.0.0.0" or host == "::" then
    host = "127.0.0.1"
  elseif host:find(":", 1, true) then
    host = "[" .. host .. "]"
  end
  return ("http://%s:%d%s"):format(host, state.port, M.preview_path(bufnr))
end

return M
