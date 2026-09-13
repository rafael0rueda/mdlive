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

-- Resolves `rel` against `dir` and returns it only if it stays inside one of `roots`.
local function resolve(dir, rel, roots)
  local full = vim.fs.normalize(vim.fs.joinpath(dir, rel))
  for _, r in ipairs(roots) do
    if vim.fs.relpath(r, full) then
      return full
    end
  end
end

local function serve_file(sock, path)
  local f = path and io.open(path, "rb")
  local body = f and f:read("*a")
  if f then
    f:close()
  end
  if not body then
    return text(sock, "404 Not Found", "Not found")
  end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  respond(sock, "200 OK", {
    ["Content-Type"] = mime[ext] or "application/octet-stream",
    ["Cache-Control"] = "no-cache",
  }, body)
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

local function handle(sock, method, target, host)
  if method ~= "GET" then
    return text(sock, "405 Method Not Allowed", "Only GET is supported")
  end
  if not allowed_host(host) then
    return text(sock, "403 Forbidden", "Forbidden")
  end

  local path = url_decode((target:gsub("[?#].*$", "")))
  local h = state.handlers

  if path:match("^/preview/%d+/?$") then
    return serve_file(sock, vim.fs.joinpath(app_dir, "index.html"))
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
    return serve_file(sock, dir and resolve(dir, file, { dir, vim.fn.getcwd() }))
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
    local host = head:match("\r\n[Hh][Oo][Ss][Tt]:%s*([^\r\n]+)")
    -- Handlers use the Neovim API, which is not allowed inside luv callbacks.
    vim.schedule(function()
      if sock:is_closing() then
        return
      end
      if not method then
        return text(sock, "400 Bad Request", "Bad request")
      end
      local ok, e = pcall(handle, sock, method, target, host)
      if not ok then
        text(sock, "500 Internal Server Error", tostring(e))
      end
    end)
  end)
end

--- Starts the server. `opts` holds host, port and the handlers
--- is_previewed(bufnr), buffer_dir(bufnr) and on_subscribe(bufnr).
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
