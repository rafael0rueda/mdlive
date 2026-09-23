# Changelog

All notable changes to mdlive are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and mdlive uses
[Semantic Versioning](https://semver.org/): until 1.0, a minor version (0.x.0)
can change or remove features.

## [Unreleased]

### Added

- Wiki links: `[[note]]`, `[[note#Heading]]`, `[[note|label]]` and
  `[[#Heading]]`. Clicking one opens the note in Neovim; when it is not next
  to the file, it is found by name under the directories the preview may
  read. See `:help mdlive-wikilinks`
- Task list checkboxes in the preview can be clicked: the `[ ]` or `[x]` of
  the item changes in the buffer. See `:help mdlive-tasks`

## [0.2.0] - 2026-09-23

### Added

- An outline of the document's headings, opened with the button at the top
  left of the preview. It marks the section at the top of the window, and a
  click scrolls to a heading. The `outline` option opens it from the start
- `browser = false` starts the preview without opening a browser, and
  `:MdLiveUrl` (with `<Plug>(MdLiveUrl)` and `mdlive.url()`) shows its URL
  and copies it to the clipboard. With a forwarded port, this previews in
  your local browser while Neovim runs over SSH: see `:help mdlive-remote`

## [0.1.1] - 2026-09-23

### Fixed

- A `file_root` reached through a symlink, such as a directory in `/tmp` on
  macOS, now gives access to its files; the preview used to refuse them
- A link whose address has a line break after its `#`, which raw HTML
  allows, no longer stops the preview from updating

## [0.1.0] - 2026-09-23

The first release.

### Added

- Live browser preview of Markdown buffers, served by an HTTP server written
  in Lua that runs inside Neovim (`vim.uv`), with no dependencies to install.
  Requires Neovim 0.11 or newer
- Updates while typing, debounced and pushed with Server-Sent Events; the
  page patches the DOM in place, so a 10,000-line document updates in about
  0.1 s
- Follow mode: one browser tab switches to the Markdown buffer you are in
- Scroll sync with the window and the cursor, and double-click in the preview
  to jump to the source line
- The colors of your Neovim colorscheme, updated on `ColorScheme`
- Code highlighting with highlight.js, line numbers and a copy button; math
  with KaTeX; Mermaid diagrams; tables, task lists, heading anchors,
  footnotes and `:emoji:` shortcodes; GitHub alerts in your diagnostic colors;
  YAML and TOML front matter as a collapsible block
- Relative links: Markdown files open in Neovim and the preview follows them;
  other files open in a new tab. Relative images, audio and video, with Range
  requests
- `:MdLiveExport` saves the preview as a standalone HTML file, with styles
  and fonts inlined
- Commands `:MdLive`, `:MdLiveStop`, `:MdLiveToggle` and `:MdLiveExport`, a
  `<Plug>` mapping for each, and no default keys
- Lua API: `setup()`, `enable()`, `is_enabled()` and `export()`
- Options: `host`, `port`, `file_root`, `browser`, `browser_redirect`,
  `debounce_ms`, `auto_open`, `filetypes`, `follow`, `scroll_sync`,
  `follow_theme` and `code_line_numbers`, checked by type
- `:help mdlive` and `:checkhealth mdlive`
- Works offline: the browser libraries are bundled in `app/vendor`

### Security

Markdown files are treated as untrusted input:

- HTML is sanitized with DOMPurify, and a Content-Security-Policy only allows
  the plugin's own scripts. Exported HTML blocks scripts too
- Preview URLs carry a random token, new each time the server starts, and the
  browser is opened through a private redirect file so the token stays out of
  the process list
- Files are served only for previewed buffers, from their directory and the
  working directory (or `file_root`), after resolving symlinks, with a
  `sandbox` policy. Clicked links go through the same check
- The server listens on `127.0.0.1`, rejects non-local `Host` headers, and
  only accepts same-origin requests with a custom header for actions in Neovim

### Deprecated

- `open()`, `close()`, `toggle()` and `is_open()` still work, warn once, and
  will be removed in 1.0. Use `enable()` and `is_enabled()`

[Unreleased]: https://github.com/rafael0rueda/mdlive/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rafael0rueda/mdlive/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/rafael0rueda/mdlive/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/rafael0rueda/mdlive/releases/tag/v0.1.0
