local M = {}

---@class mdlive.Opts
---@field host? string Address the preview server binds to.
---@field port? integer Port of the server, 0 picks a free one.
---@field browser? string|string[]|fun(url: string) Opens the preview; nil uses the system default browser.
---@field debounce_ms? integer Milliseconds to wait after the last change before updating the preview.
---@field auto_open? boolean Starts the preview when a buffer of `filetypes` is opened.
---@field filetypes? string[] Filetypes used by `auto_open` and `follow`.
---@field follow? boolean Uses a single tab that follows the buffer you are in.
---@field scroll_sync? boolean Scrolls the preview to follow the cursor.
---@field follow_theme? boolean Uses the colors of the current colorscheme in the preview.
---@field code_line_numbers? boolean Shows line numbers on code blocks with more than one line.

---@class mdlive.Config
---@field host string
---@field port integer
---@field browser? string|string[]|fun(url: string)
---@field debounce_ms integer
---@field auto_open boolean
---@field filetypes string[]
---@field follow boolean
---@field scroll_sync boolean
---@field follow_theme boolean
---@field code_line_numbers boolean

---@type mdlive.Config
M.defaults = {
  -- Address the preview server binds to. Keep it on localhost unless you know why not.
  host = "127.0.0.1",
  -- 0 picks a free port automatically.
  port = 0,
  -- nil: system default (vim.ui.open). A string ("firefox"), a command list
  -- ({ "firefox", "--new-window" }) or a function(url) are also accepted.
  browser = nil,
  -- Wait this long after the last edit before sending the buffer to the preview.
  debounce_ms = 150,
  -- Open the preview automatically for buffers with one of `filetypes`.
  auto_open = false,
  filetypes = { "markdown" },
  -- One tab follows you: entering another buffer of `filetypes` switches the
  -- open preview to it instead of needing a tab per file.
  follow = true,
  -- Scroll the preview to follow the cursor.
  scroll_sync = true,
  -- Use the colors of the current Neovim colorscheme in the preview.
  follow_theme = true,
  -- Show line numbers on code blocks with more than one line.
  code_line_numbers = true,
}

-- Accepted type(s) of every option; also the list of known options.
---@type table<string, string[]>
M.types = {
  host = { "string" },
  port = { "number" },
  browser = { "string", "table", "function" },
  debounce_ms = { "number" },
  auto_open = { "boolean" },
  filetypes = { "table" },
  follow = { "boolean" },
  scroll_sync = { "boolean" },
  follow_theme = { "boolean" },
  code_line_numbers = { "boolean" },
}

---@type mdlive.Config
M.options = vim.deepcopy(M.defaults)

-- What was wrong with the options last given to setup(); :checkhealth shows it too.
---@type string[]
M.problems = {}

--- Merges `opts` into the defaults. Unknown options and options of the wrong
--- type are reported, and the wrong ones keep their default.
---@param opts? mdlive.Opts
function M.setup(opts)
  local options = vim.deepcopy(M.defaults)
  M.problems = {}
  for key, value in pairs(opts or {}) do
    local types = M.types[key]
    if not types then
      table.insert(M.problems, ("unknown option `%s`"):format(key))
    elseif not vim.tbl_contains(types, type(value)) then
      local problem = "option `%s` should be a %s, got %s: using the default"
      table.insert(M.problems, problem:format(key, table.concat(types, " or "), type(value)))
    else
      options[key] = value
    end
  end
  M.options = options
  if #M.problems > 0 then
    vim.notify("[mdlive] " .. table.concat(M.problems, "\n"), vim.log.levels.WARN)
  end
end

return M
