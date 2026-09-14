local config = require("mdlive.config")
local server = require("mdlive.server")
local theme = require("mdlive.theme")

local M = {}

local previews = {} -- [bufnr] = { group = augroup id, timer = uv timer, tick = changedtick last sent }
local active = nil -- follow mode: the buffer the preview tabs are showing
local exports = {} -- [id] = { bufnr, path, base, sent }
local export_id = 0
local export_timeout = 20000
local api = vim.api

local function notify(msg, level)
  vim.notify("[mdlive] " .. msg, level or vim.log.levels.INFO)
end

local function supported()
  if vim.fn.has("nvim-0.11") == 1 then
    return true
  end
  notify("requires Neovim 0.11 or newer (see :checkhealth mdlive)", vim.log.levels.ERROR)
  return false
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
  server.broadcast(bufnr, "settings", { code_line_numbers = config.options.code_line_numbers })
end

local function send_exports(bufnr)
  for id, job in pairs(exports) do
    if job.bufnr == bufnr and not job.sent then
      job.sent = true
      server.broadcast(bufnr, "export", { id = id, base = job.base })
    end
  end
end

local function open_browser(url)
  local browser = config.options.browser
  if type(browser) == "function" then
    return browser(url)
  end
  if type(browser) == "string" then
    browser = { browser }
  end
  if type(browser) == "table" then
    local ok, err = pcall(vim.system, vim.list_extend(vim.deepcopy(browser), { url }), { detach = true })
    if not ok then
      notify("could not start browser: " .. tostring(err), vim.log.levels.ERROR)
    end
    return
  end
  local _, err = vim.ui.open(url)
  if err then
    notify(err .. " (open " .. url .. " manually)", vim.log.levels.WARN)
  end
end

local function buffer_dir(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fs.dirname(vim.fn.fnamemodify(name, ":p")) or vim.fn.getcwd()
end

local function attach(bufnr)
  local group = api.nvim_create_augroup("MdLiveBuf" .. bufnr, { clear = true })
  local timer = vim.uv.new_timer()
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
        M.close(bufnr)
      end)
    end,
  })
end

local markdown_ext = { md = true, markdown = true, mdown = true, mkd = true, mkdn = true }

-- A relative markdown link was clicked in the preview: show the file in the
-- window of the source buffer and return the preview URL for it.
local function open_link(from_buf, rel)
  local dir = buffer_dir(from_buf)
  if not dir or rel == "" then
    return nil, "invalid link"
  end
  local path = vim.fs.normalize(vim.fs.joinpath(dir, rel))
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
    local ok, err = pcall(vim.cmd, "buffer " .. target)
    if not ok then
      return nil, tostring(err)
    end
  end
  -- bufadd() creates unlisted buffers; list it like :edit would.
  vim.bo[target].buflisted = true
  if not previews[target] then
    attach(target)
  end
  return "/preview/" .. target
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

-- The browser sends back the rendered page of a pending export.
local function receive_export(id, html, err)
  local job = id and exports[id]
  if not job then
    return nil, "no export is waiting for this page"
  end
  exports[id] = nil
  if err or html == "" then
    notify("export failed: " .. (err or "the preview sent an empty page"), vim.log.levels.ERROR)
    return true
  end
  local file, open_err = io.open(job.path, "wb")
  if not file then
    notify("could not write " .. job.path .. ": " .. tostring(open_err), vim.log.levels.ERROR)
    return nil, "could not write the file"
  end
  file:write(html)
  file:close()
  notify("exported to " .. vim.fn.fnamemodify(job.path, ":~:."))
  return true
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
    buffer_dir = buffer_dir,
    open_link = open_link,
    jump = jump,
    export = receive_export,
    on_subscribe = function(bufnr)
      send_theme(bufnr)
      send_settings(bufnr)
      send_content(bufnr, true)
      send_view(bufnr)
      send_exports(bufnr)
    end,
  })
  if not port then
    notify("failed to start server: " .. tostring(err), vim.log.levels.ERROR)
  end
  return port ~= nil
end

local function buf_label(bufnr)
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
  return name ~= "" and name or "[No Name]"
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
    if active ~= from and previews[from] then
      server.disconnect(from)
      detach(from)
    end
  end, 100)
end

function M.open(bufnr)
  if not supported() then
    return
  end
  bufnr = resolve_buf(bufnr)
  if not start_server() then
    return
  end
  if config.options.follow and active and active ~= bufnr then
    if is_following() then
      follow(bufnr)
      notify("preview switched to " .. buf_label(bufnr))
      return
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
    return
  end
  open_browser(url)
  notify("previewing at " .. url)
end

function M.close(bufnr)
  -- From the commands (no buffer given), follow mode stops the followed preview from anywhere.
  if bufnr == nil and config.options.follow and not previews[api.nvim_get_current_buf()] then
    bufnr = active
  end
  bufnr = resolve_buf(bufnr)
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

function M.toggle(bufnr)
  bufnr = resolve_buf(bufnr)
  if previews[bufnr] then
    M.close(bufnr)
  else
    M.open(bufnr)
  end
end

function M.is_open(bufnr)
  return previews[resolve_buf(bufnr)] ~= nil
end

--- Writes the rendered preview of `bufnr` to a standalone HTML file. The page
--- is rendered by the browser, so the preview is opened first if needed.
--- `opts.path` defaults to the buffer's file with an .html extension, and
--- `opts.force` overwrites an existing file.
function M.export(bufnr, opts)
  if not supported() then
    return
  end
  bufnr = resolve_buf(bufnr)
  opts = opts or {}

  local path = opts.path
  if not path or path == "" then
    local name = api.nvim_buf_get_name(bufnr)
    if name == "" then
      return notify("the buffer has no name, give a file: :MdLiveExport {file}", vim.log.levels.ERROR)
    end
    path = vim.fn.fnamemodify(name, ":r") .. ".html"
  end
  path = vim.fn.fnamemodify(vim.fs.normalize(path), ":p")
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return notify(path .. " is a directory", vim.log.levels.ERROR)
  end
  if stat and not opts.force then
    return notify(vim.fn.fnamemodify(path, ":~:.") .. " exists (add ! to overwrite)", vim.log.levels.ERROR)
  end
  if vim.fn.isdirectory(vim.fs.dirname(path)) == 0 then
    return notify("directory " .. vim.fs.dirname(path) .. " does not exist", vim.log.levels.ERROR)
  end

  export_id = export_id + 1
  local id = export_id
  -- Relative images and links in the page must still work from where the file is written.
  exports[id] = { bufnr = bufnr, path = path, base = relative_url(vim.fs.dirname(path), buffer_dir(bufnr)) }
  vim.defer_fn(function()
    if exports[id] then
      exports[id] = nil
      notify("export timed out: no preview tab answered", vim.log.levels.ERROR)
    end
  end, export_timeout)

  if previews[bufnr] and server.client_count(bufnr) > 0 then
    send_exports(bufnr)
  else
    -- The export is sent once the tab connects.
    M.open(bufnr)
    if not server.is_running() then
      exports[id] = nil
    end
  end
end

function M.setup(opts)
  config.setup(opts)
  local group = api.nvim_create_augroup("MdLiveAutoOpen", { clear = true })
  if config.options.auto_open then
    api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = config.options.filetypes,
      callback = function(ev)
        if not previews[ev.buf] then
          M.open(ev.buf)
        end
      end,
    })
  end
end

local global_group = api.nvim_create_augroup("MdLive", { clear = true })
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
    local wanted = vim.tbl_contains(config.options.filetypes, vim.bo[ev.buf].filetype)
    -- Skip special buffers such as LSP hover popups, which are markdown too.
    if wanted and vim.bo[ev.buf].buftype == "" and api.nvim_win_get_config(0).relative == "" then
      follow(ev.buf)
    end
  end,
})

return M
