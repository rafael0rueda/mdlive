# mdlive

Neovim plugin (0.11+) that shows a live browser preview of Markdown buffers.
An HTTP + Server-Sent Events server written in Lua runs inside Neovim
(`vim.uv`) and serves a static page (`app/`) that renders the Markdown with
markdown-it. No runtime dependencies: the browser libraries are bundled in
`app/vendor`.

## Layout

- `plugin/mdlive.lua`: commands and their `<Plug>(Name)` mappings. Keep it
  small; everything goes through `require("mdlive")`.
- `lua/mdlive/init.lua`: public Lua API (`setup`, `enable`, `is_enabled`,
  `export`), buffer autocmds, follow mode, opening the browser, export jobs.
  Deprecated names (`open()`, ...) go through `deprecate()` and are listed
  under `:help mdlive-deprecated`.
- `lua/mdlive/server.lua`: the HTTP/SSE server, the token, path resolution
  (`M.resolve()`, shared by `/files` and clicked links) and the CSP headers.
- `lua/mdlive/config.lua`: defaults and `M.types`, which is both the type
  check and the list of known options.
- `lua/mdlive/health.lua`: `:checkhealth mdlive`.
- `lua/mdlive/theme.lua`: reads highlight groups into CSS colors.
- `app/preview.js`: renders, patches the DOM in place, scroll sync, jump to
  source, export. Blocks carry their source line in `data-line`. Mermaid is
  loaded lazily.
- `doc/mdlive.txt`: the `:help` docs. `doc/tags` is generated and ignored.
- `tests/smoke.lua`: Neovim side (server, security checks, API, commands).
- `tests/browser.mjs` + `tests/harness.mjs`: the page in headless Chrome
  against a real Neovim. No npm packages.
- `scripts/screenshot.mjs`: regenerates `docs/screenshot.png`.

## Checks

Run all of them before pushing; CI (`.github/workflows/ci.yml`) runs the same.

```sh
nvim --headless --clean --cmd "set rtp^=." -c "luafile tests/smoke.lua"
node tests/browser.mjs      # Node 22+, finds chromium-browser on PATH (or set CHROME)
stylua --check lua plugin tests      # stylua 2.5.2
VIMRUNTIME="$(nvim --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q)" \
  lua-language-server --check . --checklevel=Warning --configpath .luarc.json   # 3.19.1
nvim --headless --clean -c "helptags doc" -c "qa!"   # help tags build without errors
```

CI runs the smoke test on Neovim v0.11.0, stable and nightly, so don't use
APIs newer than 0.11 without a fallback.

## Conventions

- Every change ships with its tests and docs in the same commit or PR: a
  check in `tests/smoke.lua` and/or `tests/browser.mjs`, plus `doc/mdlive.txt`
  and the README when behavior or options change. Docs are in present tense.
- A new option needs: a default and a comment in `config.lua`, an entry in
  `M.types`, the `mdlive.Opts`/`mdlive.Config` annotations, a
  `*mdlive-config-<name>*` section in the help, and a line in the README's
  defaults block.
- Lua has LuaCATS annotations (`---@param`, `---@class`); keep them accurate,
  the type check runs at `Warning`. Style is stylua (`.stylua.toml`: 2 spaces,
  120 columns, double quotes, always parentheses).
- Augroups and server handlers are named following Neovim's dev guide.
- Errors go back to Lua callers as `nil, err`; the commands report them with
  `vim.notify()` prefixed with `[mdlive]`.
- `app/preview.js` is plain ES in one IIFE with `"use strict"`: no build
  step, no modules, no npm.
- Vendored libraries in `app/vendor` are not edited. When one is updated,
  update its version in the README table and its license in
  `app/vendor/licenses`.

## Security

Markdown files are untrusted input (think of a README in a freshly cloned
repository). Changes that touch the server, paths, links or HTML must keep
these properties, and the smoke/browser tests cover them:

- Every URL except `/app/...` needs the per-start random token. The token must
  not end up in the process list (`browser_redirect`), exported HTML or error
  messages.
- Files are served only from the buffer's directory and the working directory
  (or `file_root`) when the file is inside it, after resolving symlinks, and
  only for buffers being previewed. Use `server.resolve()`; don't add a second
  path check.
- The server binds to `127.0.0.1` and rejects non-local `Host` headers.
  Endpoints that act in Neovim require same-origin requests with the custom
  header.
- Rendered HTML goes through DOMPurify, and the page's CSP allows only the
  plugin's own scripts. Served files get a `sandbox` CSP. Exported HTML has a
  CSP that blocks scripts.
- Error responses to the browser don't include Lua messages or local paths.

Run `/security-review` on changes in these areas.

## Git workflow

- Branch off `main`, one topic per branch, and merge through a PR on GitHub
  (`rafael0rueda/mdlive`) once CI passes. Check `origin/main` before
  branching or merging; PRs are merged on GitHub, so the local `main` can be
  behind.
- Commit messages: an imperative subject line, without a trailing period,
  that says what changed for the user. Then a blank line, a short paragraph
  on why when it isn't obvious, and `- ` bullets for the details, including
  what the tests now cover.
