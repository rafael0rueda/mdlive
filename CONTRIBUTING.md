# Contributing to mdlive

mdlive is a Neovim plugin (0.11+) that shows a live browser preview of
Markdown buffers. An HTTP + Server-Sent Events server written in Lua runs
inside Neovim (`vim.uv`) and serves a static page (`app/`) that renders the
Markdown with markdown-it. It has no runtime dependencies: the browser
libraries are bundled in `app/vendor`.

## Layout

- `plugin/mdlive.lua`: the commands and their `<Plug>(Name)` mappings. It
  stays small; everything goes through `require("mdlive")`.
- `lua/mdlive/init.lua`: the public Lua API (`setup`, `enable`,
  `is_enabled`, `export`), buffer autocmds, follow mode, opening the browser
  and export jobs. Deprecated names (`open()`, ...) go through `deprecate()`
  and are listed under `:help mdlive-deprecated`.
- `lua/mdlive/server.lua`: the HTTP/SSE server, the token, path resolution
  (`M.resolve()`, shared by `/files` and clicked links) and the CSP headers.
- `lua/mdlive/config.lua`: the defaults and `M.types`, which is both the type
  check and the list of known options.
- `lua/mdlive/health.lua`: `:checkhealth mdlive`.
- `lua/mdlive/theme.lua`: reads highlight groups into CSS colors.
- `app/preview.js`: rendering, patching the DOM in place, scroll sync, jump to
  source and export. Blocks carry their source line in `data-line`. Mermaid
  is loaded lazily.
- `doc/mdlive.txt`: the `:help` docs. `doc/tags` is generated and ignored.
- `tests/smoke.lua`: the Neovim side (server, security checks, API, commands).
- `tests/browser.mjs` and `tests/harness.mjs`: the page in headless Chrome
  against a real Neovim, with no npm packages.
- `scripts/screenshot.mjs`: regenerates `docs/screenshot.png`.
- `scripts/vendor.mjs` and `scripts/vendor.json`: the npm packages that
  `app/vendor` comes from, pinned by version and integrity hash, and the
  SHA-256 of every file they provide.

## Checks

`make check` runs every check; run it before opening a pull request. CI
(`.github/workflows/ci.yml`) calls the same targets, so a check is changed in
the `Makefile`, not in the workflow.

- `make test`: `tests/smoke.lua` in headless Neovim
- `make browser`: `tests/browser.mjs`, needs Node 22+ and Chrome or Chromium
  (set `CHROME=/path/to/chrome` if it is not on `PATH`)
- `make lint` / `make format`: stylua
- `make typecheck`: lua-language-server with the types in `$VIMRUNTIME`
- `make helptags`: the help tags build without errors
- `make vendor-check`: every file in `app/vendor` matches
  `scripts/vendor.json`, and the README lists the bundled versions. It needs
  no network; CI also rebuilds `app/vendor` from npm with `make vendor` and
  fails if anything differs
- `make tools`: installs the stylua and lua-language-server versions pinned
  in the `Makefile` into `~/.local/bin` (`TOOLS=/other/prefix` to change it);
  versions are bumped there and CI follows

CI runs the smoke test on Neovim v0.11.0, stable and nightly, so APIs newer
than 0.11 need a fallback.

## What a change includes

- Tests and docs ship with the change, in the same pull request: a check in
  `tests/smoke.lua` and/or `tests/browser.mjs`, plus `doc/mdlive.txt` and the
  README when behavior or options change. Docs are written in present tense.
- A new option needs a default and a comment in `config.lua`, an entry in
  `M.types`, the `mdlive.Opts` and `mdlive.Config` annotations, a
  `*mdlive-config-<name>*` section in the help, and a line in the README's
  defaults block.
- Lua code has LuaCATS annotations (`---@param`, `---@class`) that stay
  accurate: the type check runs at `Warning`. Style is stylua
  (`.stylua.toml`: 2 spaces, 120 columns, double quotes, always parentheses).
- Augroups and server handlers are named following Neovim's dev guide.
- Errors go back to Lua callers as `nil, err`; the commands report them with
  `vim.notify()`, prefixed with `[mdlive]`.
- `app/preview.js` is plain JavaScript in one IIFE with `"use strict"`: no
  build step, no modules, no npm.
- A change users notice gets a line in the `## [Unreleased]` section of
  `CHANGELOG.md`, under `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`
  or `Security`.
- The libraries in `app/vendor` are not edited: they are exactly what their
  npm packages contain, licenses included. To update one, run
  `make vendor-update PACKAGE=<npm name> VERSION=<version>`, which pins the
  version and its integrity hash in `scripts/vendor.json` and rewrites its
  files, then update its version in the README's bundled libraries table.
  A new library also needs an entry in `scripts/vendor.json` and a row in
  that table.

## Security

Markdown files are untrusted input: think of a README in a repository you just
cloned. Changes to the server, paths, links or HTML keep these properties,
which the smoke and browser tests cover:

- Every URL except `/app/...` needs the random token, new each time the
  server starts. The token never ends up in the process list (see
  `browser_redirect`), in exported HTML or in error messages.
- Files are served only for buffers being previewed, and only from the
  buffer's directory and the working directory (or `file_root`) when the file
  is inside it, after resolving symlinks. Paths go through `server.resolve()`;
  there is no second path check.
- The server binds to `127.0.0.1` and rejects non-local `Host` headers.
  Endpoints that act in Neovim require same-origin requests with the custom
  header.
- Rendered HTML goes through DOMPurify, and the page's CSP allows only the
  plugin's own scripts. Served files get a `sandbox` CSP, and exported HTML
  has a CSP that blocks scripts.
- Error responses to the browser don't include Lua messages or local paths.

## Pull requests

- Branch off `main` with one topic per branch, and open the pull request
  against `main`.
- `main` is protected: every change goes through a pull request, which needs
  every CI job except Neovim nightly to pass, on a branch that is up to date
  with `main`.
- Pull requests are rebase-merged, so each commit lands on `main` as written.
  Keep commits focused, and each one passing `make check`.
- Commit messages have an imperative subject line, without a trailing period,
  that says what changed for the user. Then a blank line, a short paragraph
  on why when it isn't obvious, and `- ` bullets for the details, including
  what the tests now cover.

## Releases

mdlive follows [Semantic Versioning](https://semver.org/); until 1.0, a minor
version (0.x.0) can change or remove features. Releases are tags on `main`:

1. In a pull request, rename `## [Unreleased]` in `CHANGELOG.md` to
   `## [x.y.z] - YYYY-MM-DD`, add an empty `## [Unreleased]` above it and
   update the links at the bottom. Update the version in the README's
   `git clone --branch` line. `make release-notes VERSION=x.y.z` shows the
   notes the release will get.
2. Once it is merged, tag the merge on `main` and push the tag:
   `git tag -a vx.y.z -m "mdlive vx.y.z" && git push origin vx.y.z`.
3. The release workflow (`.github/workflows/release.yml`) checks that the tag
   is on `main` and publishes a GitHub release with that section of
   `CHANGELOG.md` as its notes.
