if vim.g.loaded_markdown_preview then
  return
end
vim.g.loaded_markdown_preview = true

local function command(name, fn, desc)
  vim.api.nvim_create_user_command(name, function()
    require("markdown_preview")[fn]()
  end, { desc = desc })
end

command("MarkdownPreview", "open", "Open a live browser preview of the current buffer")
command("MarkdownPreviewStop", "close", "Stop the live preview of the current buffer")
command("MarkdownPreviewToggle", "toggle", "Toggle the live preview of the current buffer")
