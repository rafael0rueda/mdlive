-- :MdLive and its subcommands, and the commands they replace.
local M = {}

local function notify(msg, level)
  vim.notify("[mdlive] " .. msg, level or vim.log.levels.INFO)
end

---@class (private) mdlive.Subcommand
---@field run fun(arg: string, bang: boolean)
---@field file? boolean Takes a file name, and [!].

---@type table<string, mdlive.Subcommand>
local subcommands = {
  start = {
    run = function()
      require("mdlive").enable(true, { buf = 0 })
    end,
  },
  stop = {
    run = function()
      local mdlive = require("mdlive")
      if not mdlive.is_enabled() then
        return notify("no preview to stop")
      end
      -- From a buffer without a preview, this stops every preview, such as the one following you.
      mdlive.enable(false, mdlive.is_enabled({ buf = 0 }) and { buf = 0 } or nil)
      notify("preview stopped")
    end,
  },
  toggle = {
    run = function()
      local mdlive = require("mdlive")
      local on = mdlive.is_enabled({ buf = 0 })
      -- A preview whose tab was closed shows nowhere: open it again instead of
      -- stopping what looks stopped already.
      if on and require("mdlive.server").tabs_closed(vim.api.nvim_get_current_buf()) then
        return mdlive.enable(true, { buf = 0 })
      end
      mdlive.enable(not on, { buf = 0 })
      if on then
        notify("preview stopped")
      end
    end,
  },
  url = {
    run = function()
      local url, err = require("mdlive").url()
      if not url then
        return notify(err --[[@as string]], vim.log.levels.ERROR)
      end
      -- Over SSH, the clipboard can be the one of the machine you connect from (OSC 52).
      local copied = vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", url)
      notify(url .. (copied and " (copied to the clipboard)" or ""))
    end,
  },
  export = {
    file = true,
    run = function(arg, bang)
      local path
      if arg ~= "" then
        -- A command with a Lua completion function gets its argument as typed:
        -- expand % and ~ like :write does.
        local ok, expanded = pcall(vim.fn.expandcmd, arg)
        if not ok then
          return notify(tostring(expanded), vim.log.levels.ERROR)
        end
        path = expanded
      end
      require("mdlive").export(0, { path = path, force = bang })
    end,
  },
}

-- The subcommands, in the order completion lists them.
local names = vim.tbl_keys(subcommands)
table.sort(names)

--- Runs `:MdLive[!] [subcommand] [args]`; without a subcommand, `start`.
---@param opts { args: string, bang: boolean } The arguments the user command gets.
function M.run(opts)
  local name, arg = opts.args:match("^%s*(%S*)%s*(.-)%s*$")
  name = name ~= "" and name or "start"
  local sub = subcommands[name]
  if not sub then
    local problem = "unknown subcommand `%s`, use %s (see :help :MdLive)"
    return notify(problem:format(name, table.concat(names, ", ")), vim.log.levels.ERROR)
  end
  if not sub.file and arg ~= "" then
    return notify(("`%s` takes no argument"):format(name), vim.log.levels.ERROR)
  end
  if not sub.file and opts.bang then
    return notify("! only applies to `export`: :MdLive! export", vim.log.levels.ERROR)
  end
  sub.run(arg, opts.bang)
end

--- Completes the subcommands, then file names after `export`.
---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, cursorpos)
  -- The line can hold other commands before a |; only the last :MdLive counts.
  local args = cmdline:sub(1, cursorpos):match(".*MdLive!?%s+(.*)$") or ""
  local name = args:match("^(%S+)%s")
  if not name then
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arglead)
    end, names)
  end
  if subcommands[name] and subcommands[name].file then
    return vim.fn.getcompletion(arglead, "file")
  end
  return {}
end

--- Runs a deprecated command, such as :MdLiveStop, as the subcommand that
--- replaces it, and warns once.
---@param command string
---@param name string
---@param opts { args: string, bang: boolean } The arguments the user command gets.
function M.deprecated(command, name, opts)
  local alternative = (":MdLive%s %s"):format(opts.bang and "!" or "", name)
  vim.deprecate(":" .. command, alternative, "1.0", "mdlive", false)
  M.run({ args = name .. " " .. opts.args, bang = opts.bang })
end

return M
