-- Minimal HTTP + Server-Sent Events server built on vim.uv (no external dependencies).
local uv = vim.uv

local M = {}

local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local app_dir = vim.fs.joinpath(root, "app")

local state = {
  server = nil,
  host = nil,
  port = nil,
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

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function respond(sock, status, headers, body)
  if sock:is_closing() then
    return
  end
  body = body or ""
  local lines = { "HTTP/1.1 " .. status }
  headers["Content-Length"] = #body
  headers["Connection"] = "close"
  headers["X-Content-Type-Options"] = "nosniff"
  headers["Referrer-Policy"] = "no-referrer"
  for k, v in pairs(headers) do
    lines[#lines + 1] = k .. ": " .. v
  end
  sock:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. body, function()
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

-- Resolves `rel` against `dir` and returns it only if it stays inside one of `roots`.
local function resolve(dir, rel, roots)
  local full = vim.fs.normalize(vim.fs.joinpath(dir, rel))
  for _, r in ipairs(roots) do
    if vim.fs.relpath(r, full) then
      return full
    end
  end
end

local function serve_file(sock, path, headers)
  local f = path and io.open(path, "rb")
  local body = f and f:read("*a")
  if f then
    f:close()
  end
  if not body then
    return text(sock, "404 Not Found", "Not found")
  end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  headers = headers or {}
  headers["Content-Type"] = mime[ext] or "application/octet-stream"
  headers["Cache-Control"] = "no-cache"
  respond(sock, "200 OK", headers, body)
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
    "",
    "",
  }, "\r\n"))
  state.clients[bufnr] = state.clients[bufnr] or {}
  state.clients[bufnr][sock] = true
  state.handlers.on_subscribe(bufnr)
end

-- Rejects requests whose Host header is not local, which blocks DNS-rebinding attacks.
local function allowed_host(value)
  if not value then
    return false
  end
  local name = value:match("^%[(.-)%]") or value:match("^([^:]+)")
  return name == "localhost" or name == "127.0.0.1" or name == "::1" or name == state.host
end

-- POST /open/<bufnr>?path=<relative path>: a markdown link was clicked in the preview.
-- The custom header forces a CORS preflight, which this server never approves,
-- so other websites cannot trigger it; the Origin check is a second guard.
local function open_link(sock, path, target, headers)
  local bufnr = tonumber(path:match("^/open/(%d+)$"))
  if not bufnr then
    return json(sock, "404 Not Found", { error = "not found" })
  end
  if headers["x-mdlive"] ~= "1" or headers.origin ~= "http://" .. headers.host then
    return json(sock, "403 Forbidden", { error = "forbidden" })
  end
  if not state.handlers.is_previewed(bufnr) then
    return json(sock, "404 Not Found", { error = "no preview for this buffer" })
  end
  local query = "&" .. (target:match("%?([^#]*)") or "")
  local rel = url_decode(query:match("&path=([^&]*)") or "")
  local url, err = state.handlers.open_link(bufnr, rel)
  if not url then
    return json(sock, "404 Not Found", { error = err })
  end
  json(sock, "200 OK", { url = url })
end

local function handle(sock, method, target, headers)
  if not allowed_host(headers.host) then
    return text(sock, "403 Forbidden", "Forbidden")
  end

  local path = url_decode((target:gsub("[?#].*$", "")))
  local h = state.handlers

  if method == "POST" then
    return open_link(sock, path, target, headers)
  end
  if method ~= "GET" then
    return text(sock, "405 Method Not Allowed", "Method not allowed")
  end

  if path:match("^/preview/%d+/?$") then
    return serve_file(sock, vim.fs.joinpath(app_dir, "index.html"), { ["Content-Security-Policy"] = page_policy })
  end

  local bufnr = tonumber(path:match("^/events/(%d+)$"))
  if bufnr then
    if not h.is_previewed(bufnr) then
      return text(sock, "404 Not Found", "No preview for this buffer")
    end
    return subscribe(sock, bufnr)
  end

  local asset = path:match("^/app/(.+)$")
  if asset then
    return serve_file(sock, resolve(app_dir, asset, { app_dir }))
  end

  local b, file = path:match("^/files/(%d+)/(.+)$")
  if b then
    local dir = h.buffer_dir(tonumber(b))
    local full = dir and resolve(dir, file, { dir, vim.fn.getcwd() })
    -- PDFs cannot script this origin, and browsers refuse to show them sandboxed.
    local is_pdf = full and full:lower():match("%.pdf$")
    return serve_file(sock, full, { ["Content-Security-Policy"] = not is_pdf and file_policy or nil })
  end

  text(sock, "404 Not Found", "Not found")
end

local function on_connection(err)
  if err then
    return
  end
  local sock = uv.new_tcp()
  state.server:accept(sock)

  local buf, handled = "", false
  sock:read_start(function(read_err, chunk)
    if read_err or not chunk then
      return drop(sock)
    end
    if handled then
      return
    end
    buf = buf .. chunk
    local head_end = buf:find("\r\n\r\n", 1, true)
    if not head_end then
      if #buf > 64 * 1024 then
        handled = true
        drop(sock)
      end
      return
    end
    handled = true
    local head = buf:sub(1, head_end)
    local method, target = head:match("^(%u+) (%S+) HTTP/1%.[01]\r\n")
    local headers = {}
    for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
      headers[name:lower()] = value
    end
    -- Handlers use the Neovim API, which is not allowed inside luv callbacks.
    vim.schedule(function()
      if sock:is_closing() then
        return
      end
      if not method then
        return text(sock, "400 Bad Request", "Bad request")
      end
      local ok, e = pcall(handle, sock, method, target, headers)
      if not ok then
        text(sock, "500 Internal Server Error", tostring(e))
      end
    end)
  end)
end

--- Starts the server. `opts` holds host, port and the handlers
--- is_previewed(bufnr), buffer_dir(bufnr), on_subscribe(bufnr) and
--- open_link(bufnr, relative_path) -> preview url | nil, error.
---@return integer|nil port, string|nil error
function M.start(opts)
  if state.server then
    return state.port
  end
  local server = uv.new_tcp()
  local ok, err = server:bind(opts.host, opts.port)
  if not ok then
    close(server)
    return nil, err
  end
  state.server, state.host, state.handlers = server, opts.host, opts
  ok, err = server:listen(128, on_connection)
  if not ok then
    M.stop()
    return nil, err
  end
  state.port = server:getsockname().port

  -- Comments keep idle connections alive and let us notice closed tabs.
  state.heartbeat = uv.new_timer()
  state.heartbeat:start(15000, 15000, function()
    for _, set in pairs(state.clients) do
      for sock in pairs(set) do
        if not sock:is_closing() then
          sock:write(": ping\n\n")
        end
      end
    end
  end)
  return state.port
end

function M.stop()
  for _, set in pairs(state.clients) do
    for sock in pairs(set) do
      close(sock)
    end
  end
  state.clients = {}
  close(state.heartbeat)
  close(state.server)
  state.server, state.port, state.heartbeat, state.handlers = nil, nil, nil, nil
end

function M.is_running()
  return state.server ~= nil
end

--- Number of browser tabs connected to a buffer's preview.
function M.client_count(bufnr)
  local count = 0
  for sock in pairs(state.clients[bufnr] or {}) do
    if not sock:is_closing() then
      count = count + 1
    end
  end
  return count
end

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
      sock:write(payload)
    end
  end
end

--- Closes every browser connection for a buffer.
function M.disconnect(bufnr)
  for sock in pairs(state.clients[bufnr] or {}) do
    close(sock)
  end
  state.clients[bufnr] = nil
end

function M.url(bufnr)
  local host = state.host
  if host == "0.0.0.0" or host == "::" then
    host = "127.0.0.1"
  elseif host:find(":", 1, true) then
    host = "[" .. host .. "]"
  end
  return ("http://%s:%d/preview/%d"):format(host, state.port, bufnr)
end

return M
