# Changelog

All notable changes to mdlive are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and mdlive uses
[Semantic Versioning](https://semver.org/): until 1.0, a minor version (0.x.0)
can change or remove features.

## [Unreleased]

### Changed

- `enable()` and `export()` show nothing: they return `nil` and a message on
  failure, as documented, and `export()` hands the result to its callback.
  The commands and `auto_open` report as before. A mapping that calls them
  directly and should report can use `<Plug>(MdLive)` and the other
  mappings, or show what they return
- `:MdLive` says which file it previews instead of showing the URL, which
  gives access to the preview: the URL is shown when it has to be opened by
  hand, with `browser = false` or when the browser could not be started,
  and by `:MdLive url`
- `:MdLive toggle` opens the preview again when its tab was closed, instead
  of stopping a preview that shows nowhere
- `:MdLive stop` and `:MdLive toggle` say that the preview stopped, or that
  there was none
- `setup()` refuses a `host` that is a name (`localhost`) or every address
  (`0.0.0.0`, `::`), which never worked, a `port` or `debounce_ms` that is
  not a whole number in range, and `browser = true`: it warns and uses the
  default
- A wiki link to a note that is not next to the file is looked for in up
  to 20000 files and directories, so that a click cannot make Neovim wait
  on a very large directory

### Fixed

- A heading named "Status" or "Outline", or HTML with one of those ids, is
  no longer drawn as the page's status message or outline, and a link to it
  or to a heading named "Content" goes to the heading
- Scroll sync is no longer thrown off by a collapsed `<details>` block:
  the preview and the Neovim window went to the wrong place below it
- A task checkbox that was clicked in the preview shows the state of the
  buffer again when the item changes in Neovim
- `.mp3`, `.ogg`, `.wav`, `.m4a`, `.flac` and `.mov` files are served with
  their type, so `<audio>` and `<video>` can play them
- The preview shows changes made to the buffer while you are in another
  one, such as those of a formatter, an LSP rename or a file reloaded from
  disk; they only arrived once you were back in the buffer
- `:edit!` on a previewed buffer no longer stops its preview
- Follow mode keeps the tab when buffers are entered one right after the
  other, as `:bufdo` or loading a session does: the tab stayed on a buffer
  in between, and the one you ended up in had no preview
- Following to another buffer no longer scrolls its window by a few lines
- A link to a heading of the file itself (`[x](this.md#heading)`) no longer
  makes the tab stop following
- The hint of the deprecated `mdlive.toggle()` names a replacement that
  acts on the current buffer; the one it printed stopped every preview
- A `host` that is not an address is reported by `:MdLive` and
  `:checkhealth mdlive`, instead of raising an error
- When the port is taken, the message names the address and says that
  `port = 0` picks a free one
- `:MdLive stop | MdLive` opens a tab again, instead of counting the one
  that was just told to close

## [0.4.1] - 2026-10-06

### Changed

- `<style>` blocks in a Markdown file are removed from the preview and from
  exports, as on GitHub. `style` attributes still apply, and the `css` option
  styles the preview
- A Mermaid diagram can no longer set `themeCSS`, `themeVariables`,
  `fontFamily`, `altFontFamily` or `arrowMarkerAbsolute` for itself, in a
  directive or its front matter: diagrams use the colors of the preview

### Security

- A Markdown file could read the token of the preview URL: its `<style>`
  could match the URLs of the document's images and links, which contained
  the token, and send it to another server piece by piece. With the token,
  another user or program on the machine could read the previewed buffers
  and the files next to them. Those URLs are now relative to the page, so
  nothing in the page holds the token. A Mermaid diagram could do the same
  with its `themeCSS` and `arrowMarkerAbsolute` options
- A `.js` file next to the Markdown is served as text, so the page can only
  run its own bundled scripts
- A request to tick a task on a line past the end of the buffer is refused,
  instead of raising an error in Neovim
- Redirect files left in the cache directory by a Neovim that was killed are
  removed the next time a preview opens

## [0.4.0] - 2026-09-30

### Changed

- The commands are subcommands of `:MdLive`: `:MdLive stop`, `:MdLive toggle`,
  `:MdLive url` and `:MdLive[!] export [file]`. `:MdLive` alone still starts
  the preview, and `<Tab>` completes the subcommands and, after `export`, file
  names. The `<Plug>` mappings keep their names. See `:help :MdLive`

### Deprecated

- `:MdLiveStop`, `:MdLiveToggle`, `:MdLiveUrl` and `:MdLiveExport`: use the
  `:MdLive` subcommands. They still work, warn once, and will be removed in
  1.0. See `:help mdlive-deprecated`

### Fixed

- The commands can be followed by `|` and another command. `:MdLiveExport`
  took the rest of the line as the file name, and the others failed with
  E488
- The preview follows the cursor in the first moment after it loads, instead
  of ignoring cursor moves for almost a second
- Editing no longer makes the preview jump twice: the cursor position is
  sent after the edited text, instead of being placed on the old text first

## [0.3.0] - 2026-09-23

### Added

- Scrolling the preview by hand scrolls the Neovim window to the same
  place; the cursor only moves to stay in view, as with CTRL-E. The
  `scroll_editor` option turns it off
- The `css` option adds a stylesheet of your own to the preview and to
  exports. Saving it in Neovim restyles the open previews
- Wiki links: `[[note]]`, `[[note#Heading]]`, `[[note|label]]` and
  `[[#Heading]]`. Clicking one opens the note in Neovim; when it is not next
  to the file, it is found by name under the directories the preview may
  read. See `:help mdlive-wikilinks`
- Task list checkboxes in the preview can be clicked: the `[ ]` or `[x]` of
  the item changes in the buffer. See `:help mdlive-tasks`

### Changed

- Mermaid diagrams use the colors of the preview, from your colorscheme and
  the `css` option, instead of Mermaid's own light and dark themes, and are
  drawn again when those colors change

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

[Unreleased]: https://github.com/rafael0rueda/mdlive/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/rafael0rueda/mdlive/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/rafael0rueda/mdlive/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/rafael0rueda/mdlive/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rafael0rueda/mdlive/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/rafael0rueda/mdlive/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/rafael0rueda/mdlive/releases/tag/v0.1.0
