local browser = require("mdlive.browser")
local config = require("mdlive.config")
local export = require("mdlive.export")
local server = require("mdlive.server")
local theme = require("mdlive.theme")

local M = {}

---@class mdlive.Filter
---@field buf? integer Buffer to act on, 0 for the current one. Without it, every preview.

---@class mdlive.ExportOpts
---@field path? string File to write, by default the buffer's file with an .html extension.
---@field force? boolean Overwrites an existing file.

---@class (private) mdlive.Preview
---@field group integer Augroup of the buffer's autocmds.
---@field timer uv.uv_timer_t Debounces sending the buffer.
---@field tick? integer Changedtick last sent.

---@type table<integer, mdlive.Preview>
local previews = {}
---@type integer|nil
local active = nil -- follow mode: the buffer the preview tabs are showing
local api = vim.api

local function notify(msg, level)
  vim.notify("[mdlive] " .. msg, level or vim.log.levels.INFO)
end

local function supported()
  if vim.fn.has("nvim-0.11") == 1 then
    return true
  end
  return nil, "requires Neovim 0.11 or newer (see :checkhealth mdlive)"
end

local function resolve_buf(bufnr)
  return (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
end

-- Sends the whole buffer; the browser re-renders it. Unless `force` is set
-- (a new tab, a renamed file), nothing is sent when the text did not change.
local function send_content(bufnr, force)
  local preview = previews[bufnr]
  if not preview then
    return
  end
  local tick = api.nvim_buf_get_changedtick(bufnr)
  if tick == preview.tick and not force then
    return
  end
  preview.tick = tick
  server.broadcast(bufnr, "content", {
    text = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
    name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t"),
  })
end

-- The window the preview scrolls with: the current one if it shows the buffer.
local function view_window(bufnr)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) == bufnr then
    return win
  end
  return vim.fn.win_findbuf(bufnr)[1]
end

-- Sends the cursor and the visible lines of `win` (0-based).
local function send_view(bufnr, win)
  win = win or view_window(bufnr)
  if not (previews[bufnr] and config.options.scroll_sync and win) then
    return
  end
  server.broadcast(bufnr, "cursor", {
    line = api.nvim_win_get_cursor(win)[1] - 1,
    top = vim.fn.line("w0", win) - 1,
    bottom = vim.fn.line("w$", win) - 1,
    total = api.nvim_buf_line_count(bufnr),
  })
end

local function send_theme(bufnr)
  local data = config.options.follow_theme and theme.colors() or vim.empty_dict()
  for b in pairs(bufnr and { [bufnr] = true } or previews) do
    server.broadcast(b, "theme", data)
  end
end

-- Options the page renders with.
local function send_settings(bufnr)
  server.broadcast(bufnr, "settings", {
    code_line_numbers = config.options.code_line_numbers,
    outline = config.options.outline,
  })
end

local function buf_dir(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fs.dirname(vim.fn.fnamemodify(name, ":p")) or vim.fn.getcwd()
end

-- Directories the preview may read files from: the markdown file's own
-- directory, plus the project it is in. The working directory counts as that
-- project only when the file is inside it, so previewing /tmp/notes.md from a
-- Neovim started in ~ does not put the whole home directory within reach.
---@param dir string
---@return string[]
local function file_roots(dir)
  local roots = { dir }
  -- Compared with symlinks resolved: buffer names already are, so a `file_root`
  -- under a symlink (/tmp on macOS) would otherwise never contain the file.
  local function real(path)
    return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
  end
  -- A `file_root` may be relative, or start with ~.
  local root = real(vim.fn.fnamemodify(config.options.file_root or vim.fn.getcwd(), ":p"))
  local real_dir = real(dir)
  if root ~= real_dir and vim.fs.relpath(root, real_dir) then
    roots[#roots + 1] = root
  end
  return roots
end

local function attach(bufnr)
  local group = api.nvim_create_augroup("mdlive.buf." .. bufnr, { clear = true })
  local timer = assert(vim.uv.new_timer())
  previews[bufnr] = { group = group, timer = timer }

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      timer:stop()
      timer:start(
        config.options.debounce_ms,
        0,
        vim.schedule_wrap(function()
          send_content(bufnr)
        end)
      )
    end,
  })
  api.nvim_create_autocmd("BufFilePost", {
    group = group,
    buffer = bufnr,
    callback = function()
      send_content(bufnr, true)
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      send_view(bufnr)
    end,
  })
  api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.schedule(function()
        M.enable(false, { buf = bufnr })
      end)
    end,
  })
end

local markdown_ext = { md = true, markdown = true, mdown = true, mkd = true, mkdn = true }

-- A relative markdown link was clicked in the preview: show the file in the
-- window of the source buffer and return the preview URL for it.
local function open_link(from_buf, rel)
  local dir = buf_dir(from_buf)
  if not dir or rel == "" then
    return nil, "invalid link"
  end
  -- Confined to the same directories as the files the preview may fetch, so a
  -- link in an untrusted document cannot reach the rest of the filesystem.
  local path = server.resolve(dir, rel, file_roots(dir))
  if not path then
    return nil, "file not found"
  end
  -- Checked after resolving: a symlink named .md must not open something else.
  if not markdown_ext[(path:match("%.(%w+)$") or ""):lower()] then
    return nil, "not a markdown file"
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "file not found"
  end

  local target = vim.fn.bufadd(path)
  local win = vim.fn.win_findbuf(from_buf)[1]
  if win then
    api.nvim_set_current_win(win)
  end
  if api.nvim_get_current_buf() ~= target then
    local ok, err = pcall(api.nvim_command, "buffer " .. target)
    if not ok then
      return nil, tostring(err)
    end
  end
  -- bufadd() creates unlisted buffers; list it like :edit would.
  vim.bo[target].buflisted = true
  if not previews[target] then
    attach(target)
  end
  return server.preview_path(target)
end

-- A block was double-clicked in the preview: move the cursor to its source line (0-based).
local function jump(bufnr, line)
  if not line then
    return nil, "invalid line"
  end
  local win = view_window(bufnr)
  if not win then
    return nil, "the buffer is not shown in any window"
  end
  line = math.max(1, math.min(math.floor(line) + 1, api.nvim_buf_line_count(bufnr)))
  local visible = line >= vim.fn.line("w0", win) and line <= vim.fn.line("w$", win)
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { line, 0 })
  if not visible then
    vim.cmd("normal! zz")
  end
  return true
end

local function start_server()
  if server.is_running() then
    return true
  end
  local port, err = server.start({
    host = config.options.host,
    port = config.options.port,
    is_previewed = function(bufnr)
      return previews[bufnr] ~= nil
    end,
    buf_dir = buf_dir,
    file_roots = file_roots,
    on_open_link = open_link,
    on_jump = jump,
    on_export = export.receive,
    on_subscribe = function(bufnr)
      send_theme(bufnr)
      send_settings(bufnr)
      send_content(bufnr, true)
      send_view(bufnr)
      export.send(bufnr)
    end,
  })
  if not port then
    return nil, "failed to start server: " .. tostring(err)
  end
  return true
end

local function buf_label(bufnr)
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
  return name ~= "" and name or "[No Name]"
end

-- Whether auto_open and follow mode should preview a buffer: a file of
-- `filetypes` in a normal window. Special buffers such as LSP hover popups are
-- markdown too.
local function wants_preview(bufnr)
  if vim.bo[bufnr].buftype ~= "" or not vim.tbl_contains(config.options.filetypes, vim.bo[bufnr].filetype) then
    return false
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if api.nvim_win_get_config(win).relative == "" then
      return true
    end
  end
  return false
end

-- Stops syncing a buffer without telling its tabs.
local function detach(bufnr)
  local preview = previews[bufnr]
  if not preview then
    return
  end
  previews[bufnr] = nil
  pcall(api.nvim_del_augroup_by_id, preview.group)
  preview.timer:stop()
  preview.timer:close()
  if active == bufnr then
    active = nil
  end
end

local function is_following()
  return config.options.follow and active ~= nil and previews[active] ~= nil and server.client_count(active) > 0
end

-- Follow mode: point the tabs showing the active buffer at `bufnr` instead.
local function follow(bufnr)
  local from = active
  if not previews[bufnr] then
    attach(bufnr)
  end
  active = bufnr
  server.broadcast(from, "switch", { bufnr = bufnr })
  -- The tabs reconnect to the new buffer; drop the old preview once the event is out.
  vim.defer_fn(function()
    if from and active ~= from and previews[from] then
      server.disconnect(from)
      detach(from)
    end
  end, 100)
end

-- Starts the preview of a buffer: opens a browser tab, or switches the followed tab to it.
local function start_preview(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid buffer " .. bufnr
  end
  local ok, err = start_server()
  if not ok then
    return nil, err
  end
  if config.options.follow and active and active ~= bufnr then
    if is_following() then
      follow(bufnr)
      notify("preview switched to " .. buf_label(bufnr))
      return true
    end
    -- The followed buffer's tab was closed; a new tab takes over.
    detach(active)
  end
  if not previews[bufnr] then
    attach(bufnr)
  end
  active = bufnr
  local url = server.url(bufnr)
  if server.client_count(bufnr) > 0 then
    notify("preview already open at " .. url)
    return true
  end
  browser.open(url)
  notify("previewing at " .. url)
  return true
end

-- Stops the preview of a buffer and tells its tabs.
local function stop_preview(bufnr)
  if not previews[bufnr] then
    return
  end
  detach(bufnr)

  server.broadcast(bufnr, "close", vim.empty_dict())
  -- Give the "close" event a moment to reach the browser before hanging up.
  vim.defer_fn(function()
    if not previews[bufnr] then
      server.disconnect(bufnr)
    end
    if next(previews) == nil then
      server.stop()
    end
  end, 100)
end

--- Starts or stops previews. `filter.buf` selects a buffer, 0 for the current
--- one. Without it, `enable(false)` stops every preview and `enable(true)`
--- previews the current buffer. `enable` defaults to true. Returns true, or nil
--- and a message on failure (the message is also shown).
---@param enable? boolean
---@param filter? mdlive.Filter
---@return true|nil ok
---@return string|nil err
function M.enable(enable, filter)
  local ok, err = supported()
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  vim.validate("enable", enable, "boolean", true)
  vim.validate("filter", filter, "table", true)
  local buf = filter and filter.buf
  vim.validate("filter.buf", buf, "number", true)

  if enable == false then
    for _, bufnr in ipairs(buf and { resolve_buf(buf) } or vim.tbl_keys(previews)) do
      stop_preview(bufnr)
    end
    return true
  end
  ok, err = start_preview(resolve_buf(buf))
  if not ok then
    notify(err, vim.log.levels.ERROR)
  end
  return ok, err
end

--- Returns whether the buffer `filter.buf` (0 for the current one) is being
--- previewed, or without it, whether any buffer is.
---@param filter? mdlive.Filter
---@return boolean
function M.is_enabled(filter)
  local buf = filter and filter.buf
  if buf == nil then
    return next(previews) ~= nil
  end
  return previews[resolve_buf(buf)] ~= nil
end

--- Returns the URL of the preview of the buffer `filter.buf` (0 for the current
--- one). Without it, the current buffer's, or in follow mode the one the tabs
--- are showing. The URL carries the token that gives access to the preview.
--- Returns nil and a message when there is no such preview.
---@param filter? mdlive.Filter
---@return string|nil url
---@return string|nil err
function M.url(filter)
  vim.validate("filter", filter, "table", true)
  local buf = filter and filter.buf
  vim.validate("filter.buf", buf, "number", true)
  local bufnr = resolve_buf(buf)
  if buf == nil and not previews[bufnr] and config.options.follow and active and previews[active] then
    bufnr = active
  end
  if not previews[bufnr] then
    return nil, "no preview for this buffer, :MdLive starts one"
  end
  return server.url(bufnr)
end

--- Writes the rendered preview of `bufnr` to a standalone HTML file. The page
--- is rendered by the browser, so the preview is opened first if needed.
--- `opts.path` defaults to the buffer's file with an .html extension, and
--- `opts.force` overwrites an existing file. Returns true once the export is
--- queued, or nil and a message (also shown). `callback(err, path)` is called
--- once, when the file is written or the export fails.
---@param bufnr? integer Buffer to export, 0 or nil for the current one.
---@param opts? mdlive.ExportOpts
---@param callback? fun(err: string|nil, path: string|nil)
---@return true|nil ok
---@return string|nil err
function M.export(bufnr, opts, callback)
  local path
  -- Every failure is shown and handed to the callback.
  local function fail(err)
    notify(err, vim.log.levels.ERROR)
    if callback then
      vim.schedule(function()
        callback(err, path)
      end)
    end
    return nil, err
  end

  local ok, err = supported()
  if not ok then
    return fail(err)
  end
  vim.validate("opts", opts, "table", true)
  vim.validate("opts.path", opts and opts.path, "string", true)
  vim.validate("opts.force", opts and opts.force, "boolean", true)
  vim.validate("callback", callback, "function", true)
  bufnr = resolve_buf(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return fail("invalid buffer " .. bufnr)
  end
  path, err = export.target(bufnr, opts or {})
  if err then
    return fail(err)
  end
  ---@cast path string

  -- A valid buffer, checked above, always has a directory.
  local id = export.add(bufnr, path, buf_dir(bufnr) --[[@as string]], callback)
  if previews[bufnr] and server.client_count(bufnr) > 0 then
    export.send(bufnr)
    return true
  end
  -- The export is sent once the tab connects.
  ok, err = start_preview(bufnr)
  if not ok then
    export.cancel(id)
    return fail(err)
  end
  return true
end

--- Sets the options (see :help mdlive-configuration) and applies them to open previews.
---@param opts? mdlive.Opts
function M.setup(opts)
  config.setup(opts)
  local group = api.nvim_create_augroup("mdlive.auto_open", { clear = true })
  if config.options.auto_open then
    api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = config.options.filetypes,
      callback = function(ev)
        if not previews[ev.buf] and wants_preview(ev.buf) then
          M.enable(true, { buf = ev.buf })
        end
      end,
    })
  end
  -- Open previews pick up the new options.
  if next(previews) then
    send_theme()
    for bufnr in pairs(previews) do
      send_settings(bufnr)
    end
  end
end

-- Deprecated names, kept working until 1.0.
local function deprecate(name, alternative)
  vim.deprecate(name, alternative, "1.0", "mdlive", false)
end

--- Deprecated: use mdlive.enable().
---@deprecated
---@param bufnr? integer
function M.open(bufnr)
  deprecate("mdlive.open()", "mdlive.enable()")
  M.enable(true, { buf = bufnr or 0 })
end

--- Deprecated: use mdlive.enable(false).
---@deprecated
---@param bufnr? integer
function M.close(bufnr)
  deprecate("mdlive.close()", "mdlive.enable(false)")
  -- Without a buffer, follow mode stops the followed preview from anywhere.
  if bufnr == nil and config.options.follow and not previews[api.nvim_get_current_buf()] then
    bufnr = active
  end
  M.enable(false, { buf = bufnr or 0 })
end

--- Deprecated: use mdlive.enable(not mdlive.is_enabled()).
---@deprecated
---@param bufnr? integer
function M.toggle(bufnr)
  deprecate("mdlive.toggle()", "mdlive.enable(not mdlive.is_enabled())")
  local filter = { buf = resolve_buf(bufnr) }
  M.enable(not M.is_enabled(filter), filter)
end

--- Deprecated: use mdlive.is_enabled().
---@deprecated
---@param bufnr? integer
---@return boolean
function M.is_open(bufnr)
  deprecate("mdlive.is_open()", "mdlive.is_enabled()")
  return M.is_enabled({ buf = bufnr or 0 })
end

local global_group = api.nvim_create_augroup("mdlive", { clear = true })
-- Redirect files are removed a few seconds after the browser starts; drop any
-- that Neovim is still holding when it quits before then.
api.nvim_create_autocmd("VimLeavePre", {
  group = global_group,
  callback = function()
    browser.remove_redirects()
  end,
})
api.nvim_create_autocmd("ColorScheme", {
  group = global_group,
  callback = function()
    send_theme()
  end,
})
api.nvim_create_autocmd("OptionSet", {
  group = global_group,
  pattern = "background",
  callback = function()
    send_theme()
  end,
})

-- Scrolling without moving the cursor (<C-e>, the mouse wheel) scrolls the preview too.
api.nvim_create_autocmd("WinScrolled", {
  group = global_group,
  callback = function()
    for key in pairs(vim.v.event) do
      local win = tonumber(key)
      if win and api.nvim_win_is_valid(win) then
        send_view(api.nvim_win_get_buf(win), win)
      end
    end
  end,
})

-- Follow mode: the preview tab moves to the markdown buffer you enter.
api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
  group = global_group,
  callback = function(ev)
    if ev.buf == active or ev.buf ~= api.nvim_get_current_buf() or not is_following() then
      return
    end
    if wants_preview(ev.buf) and api.nvim_win_get_config(0).relative == "" then
      follow(ev.buf)
    end
  end,
})

return M
