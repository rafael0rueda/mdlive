if vim.g.loaded_mdlive then
  return
end
vim.g.loaded_mdlive = true

local function command(name, fn, desc)
  vim.api.nvim_create_user_command(name, function()
    require("mdlive")[fn]()
  end, { desc = desc })
end

command("MdLive", "open", "Open a live browser preview of the current buffer")
command("MdLiveStop", "close", "Stop the live preview of the current buffer")
command("MdLiveToggle", "toggle", "Toggle the live preview of the current buffer")

vim.api.nvim_create_user_command("MdLiveExport", function(args)
  require("mdlive").export(0, { path = args.args, force = args.bang })
end, { nargs = "?", bang = true, complete = "file", desc = "Export the preview of the current buffer to HTML" })
