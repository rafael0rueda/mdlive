if vim.g.loaded_mdlive then
  return
end
vim.g.loaded_mdlive = true

-- :MdLive[!] [subcommand] [args], see lua/mdlive/command.lua. It can be
-- followed by | and another command.
vim.api.nvim_create_user_command("MdLive", function(args)
  require("mdlive.command").run(args)
end, {
  nargs = "*",
  bang = true,
  bar = true,
  complete = function(...)
    return require("mdlive.command").complete(...)
  end,
  desc = "Markdown live preview: start, stop, toggle, url or export",
})

-- A Normal mode <Plug>(Name) mapping per subcommand, to bind to your own keys.
for _, map in ipairs({
  { "MdLive", "start", "Open a live browser preview of the current buffer" },
  { "MdLiveStop", "stop", "Stop the live preview of the current buffer" },
  { "MdLiveToggle", "toggle", "Toggle the live preview of the current buffer" },
  { "MdLiveUrl", "url", "Show the URL of the preview and copy it to the clipboard" },
  { "MdLiveExport", "export", "Export the preview of the current buffer to HTML" },
}) do
  vim.keymap.set("n", "<Plug>(" .. map[1] .. ")", "<Cmd>MdLive " .. map[2] .. "<CR>", { desc = map[3] })
end

-- Deprecated: the commands :MdLive's subcommands replace, removed in 1.0.
for command, name in pairs({ MdLiveStop = "stop", MdLiveToggle = "toggle", MdLiveUrl = "url" }) do
  vim.api.nvim_create_user_command(command, function(args)
    require("mdlive.command").deprecated(command, name, args)
  end, { bar = true, desc = "Deprecated: use :MdLive " .. name })
end
vim.api.nvim_create_user_command("MdLiveExport", function(args)
  require("mdlive.command").deprecated("MdLiveExport", "export", args)
end, {
  nargs = "?",
  bang = true,
  bar = true,
  -- A function rather than "file", which would expand the name before :MdLive export does.
  complete = function(arglead)
    return vim.fn.getcompletion(arglead, "file")
  end,
  desc = "Deprecated: use :MdLive export",
})
