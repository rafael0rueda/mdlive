# mdlive

Live browser preview of Markdown buffers. The preview updates while you type,
follows your cursor and uses the colors of your Neovim colorscheme.

- Pure Lua: the HTTP server runs inside Neovim (`vim.uv`), nothing to install
- Updates while typing (debounced), pushed with Server-Sent Events
- Scroll sync with the cursor
- Code highlighting (highlight.js) using your colorscheme's syntax colors
- Math with KaTeX (`$inline$` and `$$block$$`) and Mermaid diagrams
- Tables, task lists, heading anchors and relative images
- Relative links: markdown files open in Neovim and the preview follows them;
  other files open in a new tab
- Works offline: all browser libraries are bundled in `app/vendor`

Requires Neovim 0.11+.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "rafael0rueda/mdlive",
  ft = "markdown",
  cmd = { "MdLive", "MdLiveToggle" },
  opts = {},
}
```

Without a plugin manager, clone the repository and add it to `runtimepath`:

```sh
git clone https://github.com/rafael0rueda/mdlive ~/.local/share/nvim/site/pack/plugins/start/mdlive
```

```lua
require("mdlive").setup()
```

Or from any directory:

```lua
vim.opt.rtp:prepend("/path/to/mdlive")
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

## Security

Markdown files can contain raw HTML, so the preview treats them as untrusted,
for example a README in a repository you just cloned:

- HTML is sanitized with DOMPurify, and a Content-Security-Policy only allows
  the plugin's own scripts, so embedded scripts and event handlers never run.
- Images and linked files are served only from the Markdown file's directory
  and the current working directory, with a `sandbox` policy so an `.html` or
  `.svg` file cannot run scripts either.
- The server listens on `127.0.0.1` and rejects requests with a non-local
  `Host` header. Opening a linked file in Neovim needs a same-origin request
  with a custom header, so other websites cannot trigger it.

## Tests

```sh
nvim --headless --clean --cmd "set rtp^=." -c "luafile tests/smoke.lua"
```

## License

[MIT](LICENSE) © Rafael Rueda

### Bundled libraries

The browser libraries in `app/vendor` keep their own licenses, included in
`app/vendor/licenses`:

| Library             | Version | License               |
| ------------------- | ------- | --------------------- |
| markdown-it         | 15.0.2  | MIT                   |
| markdown-it-texmath | 1.0.0   | MIT                   |
| KaTeX               | 0.18.7  | MIT                   |
| Mermaid             | 12.0.0  | MIT                   |
| highlight.js        | 11.12.0 | BSD-3-Clause          |
| DOMPurify           | 3.4.15  | Apache-2.0 or MPL-2.0 |
