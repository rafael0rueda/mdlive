local config = require("mdlive.config")
local server = require("mdlive.server")
local theme = require("mdlive.theme")

local M = {}

local previews = {} -- [bufnr] = { group = augroup id, timer = uv timer }
local api = vim.api

local function notify(msg, level)
  vim.notify("[mdlive] " .. msg, level or vim.log.levels.INFO)
end

local function resolve_buf(bufnr)
  return (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
end

local function send_content(bufnr)
  if not previews[bufnr] then
    return
  end
  server.broadcast(bufnr, "content", {
    text = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
    name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t"),
  })
end

local function send_cursor(bufnr)
  if not (previews[bufnr] and config.options.scroll_sync) or api.nvim_get_current_buf() ~= bufnr then
    return
  end
  server.broadcast(bufnr, "cursor", {
    line = api.nvim_win_get_cursor(0)[1] - 1,
    total = api.nvim_buf_line_count(bufnr),
  })
end

local function send_theme(bufnr)
  local data = config.options.follow_theme and theme.colors() or vim.empty_dict()
  for b in pairs(bufnr and { [bufnr] = true } or previews) do
    server.broadcast(b, "theme", data)
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

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufFilePost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      timer:stop()
      timer:start(config.options.debounce_ms, 0, vim.schedule_wrap(function()
        send_content(bufnr)
      end))
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      send_cursor(bufnr)
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
    on_subscribe = function(bufnr)
      send_theme(bufnr)
      send_content(bufnr)
      send_cursor(bufnr)
    end,
  })
  if not port then
    notify("failed to start server: " .. tostring(err), vim.log.levels.ERROR)
  end
  return port ~= nil
end

function M.open(bufnr)
  bufnr = resolve_buf(bufnr)
  if not start_server() then
    return
  end
  if not previews[bufnr] then
    attach(bufnr)
  end
  local url = server.url(bufnr)
  open_browser(url)
  notify("previewing at " .. url)
end

function M.close(bufnr)
  bufnr = resolve_buf(bufnr)
  local preview = previews[bufnr]
  if not preview then
    return
  end
  previews[bufnr] = nil
  pcall(api.nvim_del_augroup_by_id, preview.group)
  preview.timer:stop()
  preview.timer:close()

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

return M
