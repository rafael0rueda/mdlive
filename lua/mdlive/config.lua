local M = {}

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
  -- Scroll the preview to follow the cursor.
  scroll_sync = true,
  -- Use the colors of the current Neovim colorscheme in the preview.
  follow_theme = true,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
