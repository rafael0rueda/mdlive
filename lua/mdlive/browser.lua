-- Opening the preview in a browser.
local config = require("mdlive.config")

local M = {}

local function notify(msg, level)
  vim.notify("[mdlive] " .. msg, level or vim.log.levels.INFO)
end

-- The preview URL carries the token, and the arguments a program is started
-- with are readable by every user on the machine (/proc/<pid>/cmdline). The
-- browser is pointed at a file only you can read, which redirects to the
-- preview, so the token never appears in a process list.
local redirect_ttl = 15000
---@type table<string, true>
local redirects = {}

local function drop_redirect(path)
  redirects[path] = nil
  vim.uv.fs_unlink(path, function() end)
end

local function escape_html(text)
  return (
    text:gsub("[&<>\"']", {
      ["&"] = "&amp;",
      ["<"] = "&lt;",
      [">"] = "&gt;",
      ['"'] = "&quot;",
      ["'"] = "&#39;",
    })
  )
end

--- Writes a page that redirects to `url`, and returns its file:// URI. Returns
--- nil when it cannot be written, so the caller falls back to the URL itself.
---@param url string
---@return string|nil
local function redirect_file(url)
  local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "mdlive")
  -- mkdir() throws when the directory cannot be created, e.g. under a cache
  -- directory that does not exist and cannot be made.
  local created, result = pcall(vim.fn.mkdir, dir, "p")
  if not created or result == 0 then
    return nil
  end
  local name = assert(vim.uv.random(8)):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end)
  local path = vim.fs.joinpath(dir, "open-" .. name .. ".html")
  -- Created exclusively and readable only by its owner: another user on the
  -- machine cannot read the token out of it.
  local fd = vim.uv.fs_open(path, "wx", tonumber("600", 8))
  if not fd then
    return nil
  end
  local href = escape_html(url)
  local page = ([[
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>mdlive</title>
    <meta http-equiv="refresh" content="0; url=%s" />
  </head>
  <body>
    <a href="%s">Open the mdlive preview</a>
    <script>location.replace(%s)</script>
  </body>
</html>
]]):format(href, href, vim.json.encode(url))
  local written = vim.uv.fs_write(fd, page)
  vim.uv.fs_close(fd)
  if not written then
    drop_redirect(path)
    return nil
  end
  redirects[path] = true
  vim.defer_fn(function()
    drop_redirect(path)
  end, redirect_ttl)
  return vim.uri_from_fname(path)
end

--- Opens `url` with the `browser` option: a function gets the URL itself, and a
--- program is started on the redirect file, or on the URL if that fails.
--- `false` opens nothing.
---@param url string
function M.open(url)
  local browser = config.options.browser
  if browser == false then
    return
  end
  if type(browser) == "function" then
    -- Runs inside Neovim: the URL is not passed to another program.
    return browser(url)
  end
  -- Everything below starts a program with the URL in its arguments. Writing
  -- the redirect must never keep the preview from opening: on any failure the
  -- URL itself is used.
  local target = url
  if config.options.browser_redirect then
    local ok, redirect = pcall(redirect_file, url)
    target = (ok and redirect) or url
  end
  if type(browser) == "string" then
    browser = { browser }
  end
  if type(browser) == "table" then
    local ok, err = pcall(vim.system, vim.list_extend(vim.deepcopy(browser), { target }), { detach = true })
    if not ok then
      notify("could not start browser: " .. tostring(err), vim.log.levels.ERROR)
    end
    return
  end
  local _, err = vim.ui.open(target)
  if err then
    notify(err .. " (open " .. url .. " manually)", vim.log.levels.WARN)
  end
end

--- Removes the redirect files that are still there, when Neovim quits before
--- their few seconds are up.
function M.remove_redirects()
  for path in pairs(redirects) do
    pcall(vim.uv.fs_unlink, path)
  end
end

return M
