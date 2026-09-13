-- Reads the active colorscheme and turns it into CSS variables for the preview.
local M = {}

-- { css variable, highlight groups (first one with a color wins), attribute }
local spec = {
  { "bg", { "Normal" }, "bg" },
  { "fg", { "Normal" }, "fg" },
  { "muted", { "Comment" }, "fg" },
  { "border", { "WinSeparator", "VertSplit", "FloatBorder" }, "fg" },
  { "surface", { "NormalFloat", "Pmenu", "CursorLine", "ColorColumn" }, "bg" },
  { "selection", { "Visual" }, "bg" },
  { "link", { "@markup.link.url", "Underlined", "Identifier" }, "fg" },
  { "quote", { "@markup.quote", "Comment" }, "fg" },
  { "code-inline", { "@markup.raw", "String" }, "fg" },
  { "syn-keyword", { "@keyword", "Keyword", "Statement" }, "fg" },
  { "syn-string", { "@string", "String" }, "fg" },
  { "syn-comment", { "@comment", "Comment" }, "fg" },
  { "syn-number", { "@number", "Number", "Constant" }, "fg" },
  { "syn-constant", { "@constant", "Constant" }, "fg" },
  { "syn-function", { "@function", "Function" }, "fg" },
  { "syn-type", { "@type", "Type" }, "fg" },
  { "syn-builtin", { "@function.builtin", "@variable.builtin", "Special" }, "fg" },
  { "syn-variable", { "@variable.parameter", "@variable", "Identifier" }, "fg" },
  { "syn-attribute", { "@attribute", "@property", "Identifier" }, "fg" },
  { "syn-tag", { "@tag", "Tag", "Statement" }, "fg" },
  { "syn-operator", { "@operator", "Operator" }, "fg" },
  { "syn-meta", { "@keyword.directive", "PreProc" }, "fg" },
  { "syn-added", { "Added", "DiffAdd" }, "fg" },
  { "syn-deleted", { "Removed", "DiffDelete" }, "fg" },
  -- GitHub alerts: > [!NOTE], [!TIP], ...
  { "alert-note", { "DiagnosticInfo" }, "fg" },
  { "alert-tip", { "DiagnosticOk" }, "fg" },
  { "alert-important", { "DiagnosticHint" }, "fg" },
  { "alert-warning", { "DiagnosticWarn" }, "fg" },
  { "alert-caution", { "DiagnosticError" }, "fg" },
}

for level = 1, 6 do
  local groups = {
    "@markup.heading." .. level .. ".markdown",
    "@markup.heading." .. level,
    "markdownH" .. level,
    "@markup.heading",
    "Title",
  }
  table.insert(spec, { "h" .. level, groups, "fg" })
end

local function color(groups, attr)
  for _, name in ipairs(groups) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl[attr] then
      return ("#%06x"):format(hl[attr])
    end
  end
end

---@return { mode: "dark"|"light", vars: table<string, string> }
function M.colors()
  local vars = vim.empty_dict()
  for _, item in ipairs(spec) do
    vars[item[1]] = color(item[2], item[3])
  end
  return { mode = vim.o.background, vars = vars }
end

return M
