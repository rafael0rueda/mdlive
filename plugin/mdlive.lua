if vim.g.loaded_mdlive then
  return
end
vim.g.loaded_mdlive = true

-- Each command also gets a Normal mode <Plug>(Name) mapping to bind to your own keys.
local function command(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts)
  vim.keymap.set("n", "<Plug>(" .. name .. ")", "<Cmd>" .. name .. "<CR>", { desc = opts.desc })
end

command("MdLive", function()
  require("mdlive").enable(true, { buf = 0 })
end, { desc = "Open a live browser preview of the current buffer" })

command("MdLiveStop", function()
  local mdlive = require("mdlive")
  -- From a buffer without a preview, this stops every preview, such as the one following you.
  mdlive.enable(false, mdlive.is_enabled({ buf = 0 }) and { buf = 0 } or nil)
end, { desc = "Stop the live preview of the current buffer" })

command("MdLiveToggle", function()
  local mdlive = require("mdlive")
  mdlive.enable(not mdlive.is_enabled({ buf = 0 }), { buf = 0 })
end, { desc = "Toggle the live preview of the current buffer" })

command("MdLiveExport", function(args)
  require("mdlive").export(0, { path = args.args, force = args.bang })
end, { nargs = "?", bang = true, complete = "file", desc = "Export the preview of the current buffer to HTML" })
