# The checks CI runs, to run them before pushing. `make check` runs them all.
# `make tools` installs the pinned stylua and lua-language-server; CI uses the
# same targets and versions.

NVIM ?= nvim
STYLUA_VERSION = 2.5.2
LUALS_VERSION = 3.19.1
# Where `make tools` installs: $(TOOLS)/bin must be on PATH.
TOOLS ?= $(HOME)/.local

.PHONY: check test browser lint format typecheck helptags vendor vendor-check vendor-update tools release-notes

check: test browser lint typecheck helptags vendor-check

# Neovim side: the server, its security checks and the Lua API.
test:
	$(NVIM) --headless --clean --cmd "set rtp^=." -c "luafile tests/smoke.lua"

# The page in headless Chrome against a real Neovim (Node 22+, CHROME=... if not on PATH).
browser:
	node tests/browser.mjs

lint:
	stylua --check lua plugin tests

format:
	stylua lua plugin tests

# The Neovim runtime provides the types of the vim and vim.uv modules.
typecheck:
	VIMRUNTIME="$$($(NVIM) --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q)" \
	  lua-language-server --check "$(CURDIR)" --checklevel=Warning \
	  --configpath "$(CURDIR)/.luarc.json" --check_format=pretty

helptags:
	$(NVIM) --headless --clean -c "try | helptags doc | catch | echo v:exception | cquit | endtry" -c "qa!"

# The browser libraries in app/vendor, from the npm packages pinned in
# scripts/vendor.json. vendor-check needs no network; vendor downloads.
vendor-check:
	node scripts/vendor.mjs check

vendor:
	node scripts/vendor.mjs fetch

# make vendor-update PACKAGE=dompurify VERSION=3.4.16
vendor-update:
	node scripts/vendor.mjs update "$(PACKAGE)" "$(VERSION)"

tools:
	mkdir -p "$(TOOLS)/bin" "$(TOOLS)/share/lua-language-server-$(LUALS_VERSION)"
	curl -fsSL -o "$(TOOLS)/stylua.zip" \
	  "https://github.com/JohnnyMorganz/StyLua/releases/download/v$(STYLUA_VERSION)/stylua-linux-x86_64.zip"
	unzip -o -q "$(TOOLS)/stylua.zip" stylua -d "$(TOOLS)/bin"
	rm "$(TOOLS)/stylua.zip"
	curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/$(LUALS_VERSION)/lua-language-server-$(LUALS_VERSION)-linux-x64.tar.gz" \
	  | tar -xz -C "$(TOOLS)/share/lua-language-server-$(LUALS_VERSION)"
	ln -sf "$(TOOLS)/share/lua-language-server-$(LUALS_VERSION)/bin/lua-language-server" "$(TOOLS)/bin/lua-language-server"
	"$(TOOLS)/bin/stylua" --version
	"$(TOOLS)/bin/lua-language-server" --version

# The CHANGELOG.md section of VERSION (make release-notes VERSION=0.1.0), which
# the release workflow publishes as the release notes. Fails if it is missing.
release-notes:
	@test -n "$(VERSION)" || { echo "usage: make release-notes VERSION=x.y.z" >&2; exit 1; }
	@awk -v v="$(VERSION)" ' \
	  index($$0, "## [" v "]") == 1 { found = 1; next } \
	  found && (/^## \[/ || /^\[[^]]*\]: /) { exit } \
	  found && /^$$/ { if (printed) blank++; next } \
	  found { while (blank) { print ""; blank-- } print; printed = 1 } \
	  END { if (!found) { print "CHANGELOG.md has no section for " v > "/dev/stderr"; exit 1 } }' CHANGELOG.md
