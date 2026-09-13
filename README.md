# mdlive.nvim

Live browser preview of Markdown buffers. The preview updates while you type,
follows your cursor and uses the colors of your Neovim colorscheme.

- Pure Lua: the HTTP server runs inside Neovim (`vim.uv`), nothing to install
- Updates while typing (debounced), pushed with Server-Sent Events
- Scroll sync with the cursor
- Code highlighting (highlight.js) using your colorscheme's syntax colors
- Math with KaTeX (`$inline$` and `$$block$$`) and Mermaid diagrams
- Tables, task lists, heading anchors and relative images
- Works offline: all browser libraries are bundled in `app/vendor`

Requires Neovim 0.11+.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = "~/Workspace/Claude/plugin_nvim_markdown", -- or your git URL
  ft = "markdown",
  cmd = { "MdLive", "MdLiveToggle" },
  opts = {},
}
```

Without a plugin manager, add the directory to `runtimepath`:

```lua
vim.opt.rtp:prepend("~/Workspace/Claude/plugin_nvim_markdown")
require("mdlive").setup()
```

## Usage

| Command         | Action                                       |
| --------------- | -------------------------------------------- |
| `:MdLive`       | Start the preview and open it in the browser |
| `:MdLiveStop`   | Stop the preview of the current buffer       |
| `:MdLiveToggle` | Toggle the preview                           |

Example mapping:

```lua
vim.keymap.set("n", "<leader>mp", "<cmd>MdLiveToggle<cr>", { desc = "Markdown preview" })
```

Try it with `examples/demo.md`.

## Configuration

`setup()` is optional; these are the defaults:

```lua
require("mdlive").setup({
  host = "127.0.0.1",   -- address the server binds to
  port = 0,             -- 0 = pick a free port
  browser = nil,        -- nil = system default, "firefox", { "firefox", "--new-window" } or function(url)
  debounce_ms = 150,    -- delay after the last edit before updating
  auto_open = false,    -- open the preview when a buffer of `filetypes` is opened
  filetypes = { "markdown" },
  scroll_sync = true,   -- scroll the preview with the cursor
  follow_theme = true,  -- use the Neovim colorscheme in the preview
})
```

## How it works

```
Neovim buffer --TextChanged/CursorMoved--> Lua HTTP server --SSE--> browser
```

The browser page (`app/`) renders the Markdown with markdown-it and patches the
DOM in place, so images and diagrams that did not change are not reloaded.
Every block carries its source line, which is how the cursor position maps to
a scroll position. Theme colors are read from highlight groups (`Normal`,
`@keyword`, `@string`, `@markup.heading.1`, ...) and sent again on
`ColorScheme`.

Relative images and files are served only from the Markdown file's directory
and the current working directory, and requests with a non-local `Host` header
are rejected.

## Tests

```sh
nvim --headless --clean --cmd "set rtp^=." -c "luafile tests/smoke.lua"
```

## Bundled libraries

markdown-it 15.0.2, highlight.js 11.12.0, KaTeX 0.18.7, markdown-it-texmath
1.0.0 and Mermaid 12.0.0, each under its own MIT license.
