-- :checkhealth mdlive
local M = {}

local health = vim.health

local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))

local assets = {
  "app/index.html",
  "app/preview.js",
  "app/style.css",
  "app/vendor/markdown-it.min.js",
  "app/vendor/markdown-it-footnote.min.js",
  "app/vendor/markdown-it-emoji.min.js",
  "app/vendor/highlight.min.js",
  "app/vendor/katex/katex.min.js",
  "app/vendor/katex/katex.min.css",
  "app/vendor/texmath.js",
  "app/vendor/purify.min.js",
  "app/vendor/mermaid.min.js",
}

local function check_installation()
  health.start("mdlive: installation")
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.11 or newer is required, found " .. tostring(vim.version()))
  end

  local missing = vim.tbl_filter(function(file)
    return vim.uv.fs_stat(vim.fs.joinpath(root, file)) == nil
  end, assets)
  if #missing == 0 then
    health.ok("Preview page and bundled libraries found")
  else
    health.error("Missing files in " .. root .. ": " .. table.concat(missing, ", "), {
      "Reinstall the plugin",
    })
  end
end

local function check_config()
  health.start("mdlive: configuration")
  local problems = require("mdlive.config").problems
  for _, problem in ipairs(problems) do
    health.warn((problem:gsub("^%l", string.upper)), { "Fix it in setup(), see :help mdlive-configuration" })
  end
  if #problems == 0 then
    health.ok("Options are valid")
  end
end

local function check_server()
  health.start("mdlive: server")
  local server = require("mdlive.server")
  local opts = require("mdlive.config").options
  local address = ("%s:%s"):format(opts.host, opts.port == 0 and "<free port>" or opts.port)

  if server.is_running() then
    health.ok(("Running on %s:%d"):format(opts.host, server.port()))
  else
    local tcp = assert(vim.uv.new_tcp())
    local ok, err = tcp:bind(opts.host, opts.port)
    if ok then
      ok, err = tcp:listen(1, function() end)
    end
    tcp:close()
    if ok then
      health.ok("Can listen on " .. address)
    else
      health.error(("Cannot listen on %s: %s"):format(address, tostring(err)), {
        "Choose another `host` or `port` in setup()",
      })
    end
  end

  if not vim.tbl_contains({ "127.0.0.1", "localhost", "::1" }, opts.host) then
    health.warn(("`host` is %s, not a loopback address"):format(opts.host), {
      "The preview and the files next to your markdown are reachable from the network",
    })
  end
end

-- The browser is started on a file that redirects to the preview, so the token
-- stays out of the process list. A sandboxed browser cannot read that file, and
-- Neovim only sees that it started, so say where the option is.
local function check_redirect(command)
  if not require("mdlive.config").options.browser_redirect then
    return health.warn("Preview URLs are passed on the command line, where other users can read them", {
      "Set `browser_redirect = true` in setup() unless your browser cannot open local files",
    })
  end
  local sandboxed = command ~= nil and (command:find("/snap/", 1, true) or command:find("flatpak", 1, true))
  if sandboxed then
    health.warn(("`%s` looks sandboxed and may not be able to open the file it is started on"):format(command), {
      "If the browser reports a missing file, set `browser_redirect = false` in setup()",
    })
  else
    health.ok("Preview URLs are kept out of the process list")
  end
end

local function check_browser()
  health.start("mdlive: browser")
  local browser = require("mdlive.config").options.browser
  if type(browser) == "function" then
    return health.ok("Using a custom browser function")
  end
  if type(browser) == "string" then
    browser = { browser }
  end
  if type(browser) == "table" then
    if vim.fn.executable(browser[1]) == 1 then
      health.ok("Using `" .. table.concat(browser, " ") .. "`")
    else
      health.error("`" .. tostring(browser[1]) .. "` is not executable", { "Fix the `browser` option in setup()" })
    end
    local command = vim.fn.exepath(browser[1])
    return check_redirect(command ~= "" and command or browser[1])
  end

  -- Same lookup as vim.ui.open().
  if vim.fn.has("mac") == 1 or vim.fn.has("win32") == 1 then
    health.ok("Using the system default browser")
    return check_redirect(nil)
  end
  for _, cmd in ipairs({ "xdg-open", "wslview", "explorer.exe", "lemonade" }) do
    if vim.fn.executable(cmd) == 1 then
      health.ok("Opening the system default browser with `" .. cmd .. "`")
      return check_redirect(nil)
    end
  end
  health.warn("No command found to open a browser (xdg-open, wslview, explorer.exe or lemonade)", {
    "Install xdg-utils, or set `browser` in setup()",
    "You can also open the URL printed by :MdLive yourself",
  })
end

function M.check()
  check_installation()
  check_config()
  check_server()
  check_browser()
end

return M
