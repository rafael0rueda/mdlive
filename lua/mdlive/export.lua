-- Exports: the open preview tab renders the page and sends it back, and Neovim
-- writes it to disk.
local server = require("mdlive.server")

local M = {}

---@class (private) mdlive.ExportJob
---@field bufnr integer
---@field path string
---@field base string URL prefix that leads from the written file to the buffer's directory.
---@field sent? boolean
---@field callback? fun(err: string|nil, path: string|nil)

---@type table<integer, mdlive.ExportJob>
local exports = {}
local export_id = 0
local export_timeout = 20000

local function notify(msg, level)
  vim.notify("[mdlive] " .. msg, level or vim.log.levels.INFO)
end

local function url_path(path)
  return (path:gsub("[^%w%-%._~/]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

-- URL prefix that leads from directory `from` to directory `to`, such as "../docs/".
local function relative_url(from, to)
  local a = vim.split(vim.fs.normalize(from), "/", { trimempty = true })
  local b = vim.split(vim.fs.normalize(to), "/", { trimempty = true })
  if vim.fn.has("win32") == 1 and a[1] ~= b[1] then
    return vim.uri_from_fname(to) .. "/" -- another drive
  end
  local common = 0
  while common < #a and common < #b and a[common + 1] == b[common + 1] do
    common = common + 1
  end
  local parts = {}
  for _ = common + 1, #a do
    parts[#parts + 1] = ".."
  end
  for i = common + 1, #b do
    parts[#parts + 1] = b[i]
  end
  return #parts > 0 and url_path(table.concat(parts, "/")) .. "/" or ""
end

-- Ends a pending export: shows the outcome and hands it to the caller's callback.
local function finish(id, err)
  local job = exports[id]
  exports[id] = nil
  if err then
    notify(err, vim.log.levels.ERROR)
  else
    notify("exported to " .. vim.fn.fnamemodify(job.path, ":~:."))
  end
  if job.callback then
    vim.schedule(function()
      job.callback(err, job.path)
    end)
  end
end

--- The file to export the buffer to: `opts.path`, or the buffer's file with an
--- .html extension. When it cannot be written, also returns a message.
---@param bufnr integer
---@param opts mdlive.ExportOpts
---@return string|nil path
---@return string|nil err
function M.target(bufnr, opts)
  local path = opts.path
  if not path or path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return path, "the buffer has no name, give a file: :MdLiveExport {file}"
    end
    path = vim.fn.fnamemodify(name, ":r") .. ".html"
  end
  path = vim.fn.fnamemodify(vim.fs.normalize(path), ":p")
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return path, path .. " is a directory"
  end
  if stat and not opts.force then
    return path, vim.fn.fnamemodify(path, ":~:.") .. " exists (add ! to overwrite)"
  end
  if vim.fn.isdirectory(vim.fs.dirname(path)) == 0 then
    return path, "directory " .. vim.fs.dirname(path) .. " does not exist"
  end
  return path
end

--- Queues an export of the buffer to `path`, which fails if no tab answers in
--- time. `dir` is the buffer's directory, which relative files are resolved
--- against. Returns the job's id.
---@param bufnr integer
---@param path string
---@param dir string
---@param callback? fun(err: string|nil, path: string|nil)
---@return integer
function M.add(bufnr, path, dir, callback)
  export_id = export_id + 1
  local id = export_id
  exports[id] = {
    bufnr = bufnr,
    path = path,
    -- Relative images and links in the page must still work from where the file is written.
    base = relative_url(vim.fs.dirname(path), dir),
    callback = callback,
  }
  vim.defer_fn(function()
    if exports[id] then
      finish(id, "export timed out: no preview tab answered")
    end
  end, export_timeout)
  return id
end

--- Drops a queued export without calling its callback.
---@param id integer
function M.cancel(id)
  exports[id] = nil
end

--- Asks the buffer's tabs to render the exports queued for it.
---@param bufnr integer
function M.send(bufnr)
  for id, job in pairs(exports) do
    if job.bufnr == bufnr and not job.sent then
      job.sent = true
      server.broadcast(bufnr, "export", { id = id, base = job.base })
    end
  end
end

--- Writes the rendered page a tab sent back for export `id`.
---@param id integer|nil
---@param html string
---@param err string|nil
---@return true|nil ok
---@return string|nil err
function M.receive(id, html, err)
  local job = id and exports[id]
  if not job then
    return nil, "no export is waiting for this page"
  end
  if err or html == "" then
    finish(id, "export failed: " .. (err or "the preview sent an empty page"))
    return true
  end
  local file, err = io.open(job.path, "wb")
  local ok = file ~= nil
  if file then
    -- A full disk can also make the final flush in close() fail.
    local written, write_err = file:write(html)
    local closed, close_err = file:close()
    ok, err = written ~= nil and closed ~= nil, write_err or close_err
  end
  if not ok then
    finish(id, "could not write " .. job.path .. ": " .. tostring(err))
    return nil, "could not write the file"
  end
  finish(id)
  return true
end

return M
