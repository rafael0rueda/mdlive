(function () {
  "use strict";

  // The page is at /<token>/preview/<bufnr>, the only path it is served at;
  // every request to the server but the bundled /app files needs the token.
  const pageMatch = /** @type {RegExpMatchArray} */ (location.pathname.match(/^(\/[0-9a-f]+)\/preview\/(\d+)/));
  const session = pageMatch[1];
  let bufnr = pageMatch[2];
  const root = document.documentElement;
  // Both are in index.html.
  const contentEl = /** @type {HTMLElement} */ (document.getElementById("content"));
  const statusEl = /** @type {HTMLElement} */ (document.getElementById("status"));
  // The rules of the `css` option, after the page's own so they win.
  const userStyle = /** @type {HTMLStyleElement} */ (document.getElementById("user-style"));

  let mode = systemMode();
  let cursor = null;
  let documentName = "";
  let lastText = null;
  const settings = { lineNumbers: true, scrollEditor: false };
  // Arrived through a link like guide.md#install: scroll there instead of to the cursor.
  let pendingAnchor = location.hash.length > 1 ? safeDecode(location.hash.slice(1)) : null;
  let ignoreCursor = pendingAnchor !== null;
  // After a double-click jump, Neovim's cursor event should not scroll the page away.
  let jumpedAt = 0;
  const themeKeys = new Set();

  root.dataset.theme = mode;

  function systemMode() {
    return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  // A message shown for a few seconds; any status set after it cancels its timer.
  /** @type {number | undefined} */
  let statusTimer;

  function setStatus(message) {
    clearTimeout(statusTimer);
    statusTimer = undefined;
    statusEl.hidden = !message;
    statusEl.textContent = message || "";
  }

  function flashStatus(message) {
    setStatus(message);
    statusTimer = setTimeout(() => setStatus(null), 4000);
  }

  // A small cache: every edit renders the whole document again, but most code
  // blocks and formulas in it are the same as last time.
  function memo(limit) {
    const cache = new Map();
    return (key, compute) => {
      let value = cache.get(key);
      if (value === undefined) {
        value = compute();
        cache.set(key, value);
        if (cache.size > limit) cache.delete(cache.keys().next().value);
      }
      return value;
    };
  }

  const highlightCache = memo(500);
  const mathCache = memo(2000);

  // ---------------------------------------------------------------- markdown

  const md = window.markdownit({
    html: true,
    linkify: true,
    highlight(code, lang) {
      if (!lang || !hljs.getLanguage(lang)) return ""; // markdown-it escapes the code itself
      return highlightCache(`${lang}\n${code}`, () => {
        try {
          return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        } catch (_) {
          return "";
        }
      });
    },
  });

  // Formulas become placeholders that are rendered after sanitizing, like diagrams.
  // KaTeX output is safe without the `trust` option, and it is large: checking it
  // took most of the sanitizing time on long documents.
  let mathSources = [];
  md.use(texmath, {
    engine: {
      renderToString(tex, options) {
        mathSources.push({ tex, display: Boolean(options.displayMode) });
        return `<span class="math" data-math="${mathSources.length - 1}"></span>`;
      },
    },
    delimiters: "dollars",
  });
  md.use(markdownitFootnote);
  md.use(markdownitEmoji);

  // [[page]], [[page#Heading]], [[page|label]] and [[#Heading]]: links to other
  // notes, as in Obsidian and other wikis. They become relative links, so they
  // open in Neovim like any other: the page is a file next to this one, with .md
  // added unless it names another kind of file, and Neovim also looks for it by
  // name when it is not there (the "wikilink" class asks for that, see post()).
  const attachment = /\.(?:pdf|png|jpe?g|gif|svg|webp|avif|mp4|webm|mov|mp3|ogg|wav|txt|csv|html?)$/i;
  md.inline.ruler.before("link", "wikilink", (state, silent) => {
    const start = state.pos;
    if (state.src.charCodeAt(start) !== 0x5b || state.src.charCodeAt(start + 1) !== 0x5b) return false;
    const end = state.src.indexOf("]]", start + 2);
    if (end < 0) return false;
    const inner = state.src.slice(start + 2, end);
    if (!inner.trim() || /[[\]\n]/.test(inner)) return false;
    if (!silent) {
      const bar = inner.indexOf("|");
      const target = (bar < 0 ? inner : inner.slice(0, bar)).trim();
      const label = bar < 0 ? target : inner.slice(bar + 1).trim();
      const hashAt = target.indexOf("#");
      const page = (hashAt < 0 ? target : target.slice(0, hashAt)).trim();
      const heading = hashAt < 0 ? "" : target.slice(hashAt + 1);
      const file = page && (isMarkdown(page) || attachment.test(page) ? page : `${page}.md`);
      const path = file ? file.split("/").map(encodeURIComponent).join("/") : "";
      const open = state.push("link_open", "a", 1);
      open.attrSet("href", path + (heading ? `#${encodeURIComponent(slugify(heading))}` : ""));
      open.attrSet("class", "wikilink");
      state.push("text", "", 0).content = label || target;
      state.push("link_close", "a", -1);
    }
    state.pos = end + 2;
    return true;
  });

  // Tag every block with its source lines: data-line is where it starts (scroll
  // sync), data-source the lines its text comes from (double-click to jump).
  md.core.ruler.push("source_lines", (state) => {
    for (const token of state.tokens) {
      if (!(token.block && token.map && token.nesting >= 0)) continue;
      token.attrSet("data-line", String(token.map[0]));
      if (token.type === "fence") {
        // The code sits between the fences.
        const first = token.map[0] + 1;
        token.attrSet("data-source", `${first}-${first + token.content.split("\n").length - 1}`);
      } else {
        token.attrSet("data-source", `${token.map[0]}-${token.map[1]}`);
      }
    }
  });

  function slugify(text) {
    return text
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s+/g, "-");
  }

  // Mermaid fences become placeholders that are rendered asynchronously.
  const defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    if (token.info.trim().split(/\s+/)[0] === "mermaid") {
      // The source is attached after sanitizing: DOMPurify drops attributes containing "-->".
      env.mermaid.push(token.content);
      return `<div class="mermaid-block" data-line="${token.map[0]}" data-mermaid="${env.mermaid.length - 1}"></div>\n`;
    }
    return defaultFence(tokens, idx, options, env, self);
  };

  // YAML (---) or TOML (+++) front matter at the top of the file. Its lines are
  // blanked out instead of removed so source line numbers stay correct.
  function splitFrontMatter(text) {
    const match = /^(---|\+\+\+)[ \t]*\r?\n(?:([\s\S]*?)\r?\n)?(?:\1|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(text);
    if (!match) return { frontMatter: null, body: text };
    const newlines = match[0].split("\n").length - 1;
    return {
      frontMatter: { lang: match[1] === "---" ? "yaml" : "toml", code: match[2] || "" },
      body: "\n".repeat(newlines) + text.slice(match[0].length),
    };
  }

  function frontMatterHtml({ lang, code }) {
    const highlighted = hljs.getLanguage(lang)
      ? hljs.highlight(code, { language: lang, ignoreIllegals: true }).value
      : md.utils.escapeHtml(code);
    return `<details class="front-matter" data-line="0"><summary>Front matter</summary><pre><code>${highlighted}</code></pre></details>\n`;
  }

  // Relative to the markdown file, as opposed to "https:", "/absolute" or "#anchor".
  const isRelative = (url) => !/^(?:[a-z][a-z\d+.-]*:|\/|#)/i.test(url);
  const isMarkdown = (path) => /\.(?:md|markdown|mdown|mkdn?)$/i.test(path);

  function safeDecode(text) {
    try {
      return decodeURIComponent(text);
    } catch (_) {
      return text;
    }
  }

  // srcset is a list of "url [descriptor]" separated by commas. A URL can contain
  // commas itself (data: URLs); only commas right after it separate candidates.
  const srcsetCandidate = /([\s,]*)([^\s,](?:\S*[^\s,])?)(,+|(?:[^,(]|\([^)]*\))*)/g;

  function mapSrcset(value, map) {
    return value.replace(srcsetCandidate, (_, lead, url, rest) => lead + map(url) + rest);
  }

  // Set by postProcess(), which trusts them. The same attributes in the markdown's
  // HTML are dropped: a web link must not pose as a link that opens a file in Neovim.
  const scriptAttributes = ["data-src", "data-tex", "data-display", "data-open-path", "data-open-hash", "data-task"];

  // Runs after sanitizing, so everything added here comes from this script.
  function postProcess(fragment, env) {
    for (const block of fragment.querySelectorAll(".mermaid-block[data-mermaid]")) {
      block.dataset.src = env.mermaid[Number(block.dataset.mermaid)] ?? "";
      block.removeAttribute("data-mermaid");
    }

    for (const el of fragment.querySelectorAll(".math[data-math]")) {
      const source = mathSources[Number(el.dataset.math)];
      el.removeAttribute("data-math");
      if (!source) continue;
      el.dataset.tex = source.tex;
      if (source.display) el.dataset.display = "";
    }

    // Relative images and media (<img>, <picture> sources, <video>, <audio>) are
    // served from the markdown file's directory.
    const fileUrl = (url) => (url && isRelative(url) ? `${session}/files/${bufnr}/${url}` : url);
    for (const el of fragment.querySelectorAll("[src], [poster]")) {
      for (const name of ["src", "poster"]) {
        if (el.hasAttribute(name)) el.setAttribute(name, fileUrl(el.getAttribute(name)));
      }
    }
    for (const el of fragment.querySelectorAll("[srcset]")) {
      el.setAttribute("srcset", mapSrcset(el.getAttribute("srcset"), fileUrl));
    }

    for (const link of fragment.querySelectorAll("a[href]")) {
      const href = link.getAttribute("href");
      if (href.startsWith("#")) continue;
      // Everything except in-page anchors opens in a new tab so the preview stays put.
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      if (!isRelative(href)) continue;

      // Matches every string: `s` lets it match an href from raw HTML with a line break.
      const [, path, hash = ""] = /** @type {RegExpExecArray} */ (/^([^?#]*)(?:\?[^#]*)?(#.*)?$/s.exec(href));
      if (!path) continue;
      // Local files are served raw (keeping fragments like #page=3 for PDFs);
      // markdown files are opened in Neovim on click.
      link.setAttribute("href", `${session}/files/${bufnr}/${path}${hash}`);
      if (isMarkdown(path)) {
        link.dataset.openPath = safeDecode(path);
        link.dataset.openHash = hash;
      }
    }

    // GitHub-style ids so `[link](#some-heading)` works.
    const usedIds = new Map();
    for (const heading of fragment.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
      const base = slugify(heading.textContent);
      const count = usedIds.get(base) || 0;
      usedIds.set(base, count + 1);
      heading.id = count ? `${base}-${count}` : base;
    }

    // Task lists: "- [ ] todo" / "- [x] done".
    for (const li of fragment.querySelectorAll("li")) {
      let host = li;
      let first = li.firstChild;
      while (first && first.nodeType === Node.TEXT_NODE && !first.nodeValue.trim()) {
        first = first.nextSibling;
      }
      if (first && first.nodeName === "P") {
        host = first;
        first = first.firstChild;
      }
      if (!first || first.nodeType !== Node.TEXT_NODE) continue;
      const match = /^\[([ xX])\]\s+/.exec(first.nodeValue);
      if (!match) continue;
      first.nodeValue = first.nodeValue.slice(match[0].length);
      const box = document.createElement("input");
      box.type = "checkbox";
      // A click ticks the item on its source line, the <li>'s data-line (see the
      // change handler). Not copied here: blocks are matched by their HTML
      // without line numbers, and a copy would make every edit above rebuild them.
      if (li.dataset.line) box.dataset.task = "";
      else box.disabled = true;
      if (match[1] !== " ") box.setAttribute("checked", "");
      host.insertBefore(box, first);
      li.classList.add("task-list-item");
    }

    // GitHub alerts: a blockquote whose first line is [!NOTE], [!TIP], [!IMPORTANT], [!WARNING] or [!CAUTION].
    for (const quote of fragment.querySelectorAll("blockquote")) {
      const paragraph = quote.firstElementChild;
      const text = paragraph && paragraph.tagName === "P" ? paragraph.firstChild : null;
      const match =
        text &&
        text.nodeType === Node.TEXT_NODE &&
        /^\[!(note|tip|important|warning|caution)\][ \t]*(?:\n|$)/i.exec(text.nodeValue);
      if (!match) continue;
      text.nodeValue = text.nodeValue.slice(match[0].length);
      if (!text.nodeValue) text.remove();
      if (!paragraph.hasChildNodes()) paragraph.remove();
      const type = match[1].toLowerCase();
      quote.classList.add("markdown-alert", `markdown-alert-${type}`);
      const title = document.createElement("p");
      title.className = "markdown-alert-title";
      title.textContent = type[0].toUpperCase() + type.slice(1);
      quote.prepend(title);
    }

    // Copy buttons, and line numbers on code blocks with more than one line.
    for (const pre of fragment.querySelectorAll("pre")) {
      const code = pre.querySelector(":scope > code");
      if (!code || pre.closest(".front-matter")) continue;
      const lines = code.textContent.replace(/\n$/, "").split("\n").length;
      if (settings.lineNumbers && lines > 1) {
        const gutter = document.createElement("span");
        gutter.className = "line-numbers";
        gutter.setAttribute("aria-hidden", "true");
        gutter.textContent = Array.from({ length: lines }, (_, i) => i + 1).join("\n");
        pre.prepend(gutter);
        pre.classList.add("numbered");
      }
      const wrapper = document.createElement("div");
      wrapper.className = "code-block";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "copy-code";
      button.textContent = "Copy";
      pre.replaceWith(wrapper);
      wrapper.append(pre, button);
    }
  }

  // ------------------------------------------------------------------ render

  // Diagrams and formulas are filled in after patching. Their placeholders are
  // compared by source, so unchanged ones keep what was rendered into them.
  function renderedKey(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return null;
    if (node.classList.contains("mermaid-block")) return `mermaid\n${node.dataset.src}`;
    if (node.classList.contains("math") && node.hasAttribute("data-tex")) {
      return `math\n${node.hasAttribute("data-display")}\n${node.dataset.tex}`;
    }
    return null;
  }

  function syncAttributes(target, source) {
    for (const { name } of Array.from(target.attributes)) {
      // Keep a <details> the reader expanded open across re-renders.
      if (name === "open" && target.tagName === "DETAILS") continue;
      if (!source.hasAttribute(name)) target.removeAttribute(name);
    }
    for (const { name, value } of Array.from(source.attributes)) {
      if (target.getAttribute(name) !== value) target.setAttribute(name, value);
    }
  }

  // Updates `prev` in place to match `next` so unchanged nodes (images, diagrams)
  // are not rebuilt. Returns the node that ends up in the document.
  function patchNode(parent, prev, next) {
    const prevKey = renderedKey(prev);
    const nextKey = renderedKey(next);
    if (prevKey !== null || nextKey !== null) {
      if (prevKey === nextKey) {
        syncAttributes(prev, next);
        return prev;
      }
    } else if (prev.isEqualNode(next)) {
      return prev;
    } else if (prev.nodeType === Node.TEXT_NODE && next.nodeType === Node.TEXT_NODE) {
      prev.nodeValue = next.nodeValue;
      return prev;
    } else if (
      prev.nodeType === Node.ELEMENT_NODE &&
      next.nodeType === Node.ELEMENT_NODE &&
      prev.tagName === next.tagName
    ) {
      syncAttributes(prev, next);
      patch(prev, next);
      return prev;
    }
    parent.replaceChild(next, prev);
    return next;
  }

  function patch(target, source) {
    const oldNodes = Array.from(target.childNodes);
    const newNodes = Array.from(source.childNodes);
    newNodes.forEach((next, i) => {
      if (oldNodes[i]) patchNode(target, oldNodes[i], next);
      else target.appendChild(next);
    });
    for (let i = newNodes.length; i < oldNodes.length; i++) {
      oldNodes[i].remove();
    }
  }

  // A block whose HTML differs from `next` only in line numbers: copy those
  // attributes, pairing the elements that carry them, instead of a full patch.
  function updateLines(parent, prev, next) {
    if (prev.nodeType !== Node.ELEMENT_NODE) return patchNode(parent, prev, next);
    const selector = "[data-line], [data-source]";
    const sources = [next, ...next.querySelectorAll(selector)];
    const targets = [prev, ...prev.querySelectorAll(selector)];
    if (sources.length !== targets.length) return patchNode(parent, prev, next);
    sources.forEach((source, i) => {
      for (const name of ["data-line", "data-source"]) {
        const value = source.getAttribute(name);
        if (value === null) targets[i].removeAttribute(name);
        else if (targets[i].getAttribute(name) !== value) targets[i].setAttribute(name, value);
      }
    });
    return prev;
  }

  // The HTML each top-level block was rendered from, and the same without line numbers.
  const blockSources = new WeakMap();

  function blockSource(node) {
    const html = node.nodeType === Node.ELEMENT_NODE ? node.outerHTML : `#${node.nodeType}${node.nodeValue}`;
    return { html, key: html.replace(/ data-(?:line|source)="[^"]*"/g, "") };
  }

  // Top-level blocks are matched from both ends by their HTML without line
  // numbers, so adding or removing a block only touches the blocks that changed:
  // the ones below just get new line numbers instead of being rebuilt.
  function patchBlocks(target, source) {
    const oldNodes = Array.from(target.childNodes);
    const newNodes = Array.from(source.childNodes);
    const oldSources = oldNodes.map((node) => blockSources.get(node));
    const newSources = newNodes.map(blockSource);
    const same = (i, j) => oldSources[i] !== undefined && oldSources[i].key === newSources[j].key;

    let start = 0;
    while (start < oldNodes.length && start < newNodes.length && same(start, start)) start++;
    let oldEnd = oldNodes.length;
    let newEnd = newNodes.length;
    while (oldEnd > start && newEnd > start && same(oldEnd - 1, newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }

    // Blocks rendered from the same HTML are left alone, keeping what was filled
    // into them; blocks that only moved get their new line numbers.
    const update = (prev, j) => {
      const old = blockSources.get(prev);
      let node = prev;
      if (!old || old.key !== newSources[j].key) node = patchNode(target, prev, newNodes[j]);
      else if (old.html !== newSources[j].html) node = updateLines(target, prev, newNodes[j]);
      blockSources.set(node, newSources[j]);
    };
    for (let i = 0; i < start; i++) update(oldNodes[i], i);
    for (let i = oldEnd, j = newEnd; i < oldNodes.length; i++, j++) update(oldNodes[i], j);

    // The changed blocks in between: update in place, then add or remove the rest.
    const anchor = oldNodes[oldEnd] ?? null;
    const changed = Math.min(oldEnd, newEnd) - start;
    for (let k = 0; k < changed; k++) update(oldNodes[start + k], start + k);
    for (let j = start + changed; j < newEnd; j++) {
      target.insertBefore(newNodes[j], anchor);
      blockSources.set(newNodes[j], newSources[j]);
    }
    for (let i = start + changed; i < oldEnd; i++) oldNodes[i].remove();
  }

  const renderedMath = new WeakSet();

  function renderMath() {
    for (const el of /** @type {NodeListOf<HTMLElement>} */ (contentEl.querySelectorAll(".math[data-tex]"))) {
      if (renderedMath.has(el)) continue;
      const { tex = "" } = el.dataset;
      const displayMode = el.hasAttribute("data-display");
      el.innerHTML = mathCache(`${displayMode}\n${tex}`, () => {
        try {
          return katex.renderToString(tex, { displayMode, throwOnError: false });
        } catch (err) {
          return `<span class="math-error">${md.utils.escapeHtml(`${tex}: ${err.message}`)}</span>`;
        }
      });
      renderedMath.add(el);
    }
  }

  function render(text) {
    const template = document.createElement("template");
    // HTML inside the markdown is untrusted: drop scripts, event handlers, iframes, ...
    const env = { mermaid: [] };
    mathSources = [];
    const { frontMatter, body } = splitFrontMatter(text);
    const html = (frontMatter ? frontMatterHtml(frontMatter) : "") + md.render(body, env);
    template.innerHTML = DOMPurify.sanitize(html, {
      ADD_TAGS: ["semantics", "annotation"],
      FORBID_ATTR: scriptAttributes,
    });
    postProcess(template.content, env);
    patchBlocks(contentEl, template.content);
    renderMath();
    lineIndex = null;
    buildOutline();
    queueMermaid();
    if (pendingAnchor !== null) {
      document.getElementById(pendingAnchor)?.scrollIntoView();
      pendingAnchor = null;
    } else if (cursor) {
      scrollToLine(cursor);
    }
  }

  // Content and cursor events that arrive while a long render runs are merged
  // into one update. (Not requestAnimationFrame: it stops in covered windows,
  // and the preview is usually next to or behind the editor.)
  let pendingText = null;
  let pendingScroll = false;
  let updateQueued = false;

  function scheduleUpdate() {
    if (updateQueued) return;
    updateQueued = true;
    setTimeout(flushUpdates, 0);
  }

  function flushUpdates() {
    updateQueued = false;
    if (pendingText !== null) {
      const text = pendingText;
      pendingText = null;
      pendingScroll = false; // render() scrolls to the cursor itself
      render(text);
    }
    if (pendingScroll) {
      pendingScroll = false;
      if (cursor) scrollToLine(cursor);
    }
  }

  // ----------------------------------------------------------------- mermaid

  /** @type {Promise<Mermaid> | null} */
  let mermaidLoad = null;
  let mermaidQueue = Promise.resolve();
  /** @type {string | null} */
  let mermaidThemeKey = null;
  let diagramId = 0;
  const diagramCache = new Map(); // `${theme}\n${src}` -> html
  const renderedDiagrams = new WeakMap(); // element -> cache key

  function loadMermaid() {
    mermaidLoad ??= new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "/app/vendor/mermaid.min.js";
      script.onload = () => (window.mermaid ? resolve(window.mermaid) : reject(new Error("Could not load mermaid")));
      script.onerror = () => reject(new Error("Could not load mermaid"));
      document.head.appendChild(script);
    });
    return mermaidLoad;
  }

  function queueMermaid() {
    mermaidQueue = mermaidQueue.then(renderMermaid, renderMermaid);
  }

  // Diagrams take the page's colors, which come from the colorscheme and the
  // `css` option. Mermaid's "base" theme is the one that uses themeVariables,
  // and it works out the other shades from these.
  function mermaidTheme() {
    const style = getComputedStyle(root);
    /** @type {Record<string, string | boolean>} */
    const vars = { darkMode: mode === "dark", fontFamily: getComputedStyle(contentEl).fontFamily };
    const colors = {
      background: "bg",
      mainBkg: "surface",
      primaryColor: "surface",
      primaryTextColor: "fg",
      primaryBorderColor: "border",
      secondaryColor: "bg",
      tertiaryColor: "bg",
      lineColor: "muted",
      defaultLinkColor: "muted",
      arrowheadColor: "muted",
      edgeLabelBackground: "bg",
      clusterBkg: "surface",
      clusterBorder: "border",
      textColor: "fg",
      noteBkgColor: "surface",
      noteTextColor: "fg",
      noteBorderColor: "border",
    };
    for (const [name, variable] of Object.entries(colors)) {
      const value = style.getPropertyValue(`--${variable}`).trim();
      if (value) vars[name] = value;
    }
    return vars;
  }

  async function renderMermaid() {
    const themeVariables = mermaidTheme();
    const theme = JSON.stringify(themeVariables);
    const blocks = /** @type {NodeListOf<HTMLElement>} */ (contentEl.querySelectorAll(".mermaid-block"));
    const pending = Array.from(blocks).filter(
      (block) => renderedDiagrams.get(block) !== `${theme}\n${block.dataset.src}`,
    );
    if (!pending.length) return;

    let mermaid;
    try {
      mermaid = await loadMermaid();
    } catch (err) {
      pending.forEach((block) => (block.innerHTML = errorHtml(err)));
      return;
    }
    if (mermaidThemeKey !== theme) {
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "base", themeVariables });
      mermaidThemeKey = theme;
    }

    for (const block of pending) {
      const src = block.dataset.src;
      const key = `${theme}\n${src}`;
      let html = diagramCache.get(key);
      if (html === undefined) {
        const id = `mermaid-${++diagramId}`;
        try {
          html = (await mermaid.render(id, src)).svg;
        } catch (err) {
          html = errorHtml(err);
          document.getElementById(`d${id}`)?.remove();
        }
        diagramCache.set(key, html);
        if (diagramCache.size > 100) diagramCache.delete(diagramCache.keys().next().value);
      }
      if (block.isConnected && block.dataset.src === src) {
        block.innerHTML = html;
        renderedDiagrams.set(block, key);
      }
    }
    if (cursor) scrollToLine(cursor);
  }

  function errorHtml(err) {
    return `<pre class="mermaid-error">${md.utils.escapeHtml(String((err && err.message) || err))}</pre>`;
  }

  // ----------------------------------------------------------------- outline

  // The document's headings as links on the side, opened with the button at the
  // top left. It is rebuilt when the headings change, and marks the section at
  // the top of the window.
  const outlineEl = /** @type {HTMLElement} */ (document.getElementById("outline"));
  const outlineButton = /** @type {HTMLElement} */ (document.getElementById("outline-toggle"));
  // Wide enough to show the outline next to the text instead of over it.
  const wideWindow = matchMedia("(min-width: 1240px)");
  /** @type {HTMLElement[]} */
  let outlineHeadings = [];
  /** @type {HTMLAnchorElement[]} */
  let outlineLinks = [];
  let outlineKey = "";
  let outlineOpen = false;
  // The `outline` option as last sent by Neovim: it opens or closes the outline
  // when it changes, and the button decides in between.
  /** @type {boolean | null} */
  let outlineOption = null;

  function showOutline() {
    const shown = outlineOpen && outlineHeadings.length > 0;
    outlineButton.hidden = outlineHeadings.length === 0;
    outlineButton.setAttribute("aria-expanded", String(shown));
    outlineEl.hidden = !shown;
    document.body.classList.toggle("outline-open", shown);
    markSection();
  }

  function buildOutline() {
    const headings = /** @type {NodeListOf<HTMLElement>} */ (contentEl.querySelectorAll("h1, h2, h3, h4, h5, h6"));
    outlineHeadings = Array.from(headings);
    // innerText, not textContent: formulas also hold their source, which is hidden.
    const texts = outlineHeadings.map((heading) => heading.innerText.trim());
    const key = outlineHeadings.map((heading, i) => `${heading.tagName} ${texts[i]}`).join("\n");
    if (key !== outlineKey) {
      outlineKey = key;
      const top = Math.min(...outlineHeadings.map((heading) => Number(heading.tagName[1])));
      const list = document.createElement("ul");
      outlineLinks = outlineHeadings.map((heading, i) => {
        const link = document.createElement("a");
        link.href = `#${encodeURIComponent(heading.id)}`;
        link.textContent = texts[i];
        link.dataset.depth = String(Number(heading.tagName[1]) - top);
        link.dataset.index = String(i);
        const item = document.createElement("li");
        item.append(link);
        list.append(item);
        return link;
      });
      outlineEl.replaceChildren(list);
    }
    showOutline();
  }

  // The current section: the last heading above a line a little below the top
  // of the window, so a heading just scrolled to counts. At the bottom of the
  // page, where the last headings cannot reach the top, the last one in view.
  function markSection() {
    if (outlineEl.hidden) return;
    const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 1;
    const line = atBottom ? window.innerHeight : 80;
    let current = -1;
    while (current + 1 < outlineHeadings.length && outlineHeadings[current + 1].getBoundingClientRect().top <= line) {
      current++;
    }
    outlineLinks.forEach((link, i) => {
      if (i === current) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
    // Keep the marked entry in view in a long outline.
    const link = outlineLinks[current];
    const { scrollTop, clientHeight } = outlineEl;
    if (link && (link.offsetTop < scrollTop || link.offsetTop + link.offsetHeight > scrollTop + clientHeight)) {
      outlineEl.scrollTop = link.offsetTop - clientHeight / 2;
    }
  }

  outlineButton.addEventListener("click", () => {
    outlineOpen = !outlineOpen;
    showOutline();
  });

  outlineEl.addEventListener("click", (event) => {
    const link = /** @type {Element} */ (event.target).closest("a");
    if (!link) return;
    // Scrolls without adding the heading to the address and the history.
    event.preventDefault();
    outlineHeadings[Number(/** @type {HTMLElement} */ (link).dataset.index)]?.scrollIntoView();
    if (!wideWindow.matches) {
      outlineOpen = false;
      showOutline();
    }
  });

  let sectionQueued = false;
  window.addEventListener(
    "scroll",
    () => {
      if (sectionQueued) return;
      sectionQueued = true;
      requestAnimationFrame(() => {
        sectionQueued = false;
        markSection();
      });
    },
    { passive: true },
  );

  // ------------------------------------------------------------------ scroll

  // Blocks sorted by their first source line (document order for equal lines),
  // rebuilt after each render. Footnotes are left out: they are rendered at the
  // end, away from where they are written.
  /** @type {{ line: number, el: HTMLElement }[] | null} */
  let lineIndex = null;

  function lineBlocks() {
    if (!lineIndex) {
      const footnotes = new Set(contentEl.querySelectorAll(".footnotes [data-line]"));
      lineIndex = [];
      for (const el of /** @type {NodeListOf<HTMLElement>} */ (contentEl.querySelectorAll("[data-line]"))) {
        if (!footnotes.has(el)) lineIndex.push({ line: Number(el.dataset.line), el });
      }
      lineIndex.sort((a, b) => a.line - b.line);
    }
    return lineIndex;
  }

  // Page offset of a source line, interpolated between the blocks around it.
  function lineOffset(line, total) {
    const blocks = lineBlocks();
    // Binary search for the first block that starts after `line`.
    let lo = 0;
    let hi = blocks.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (blocks[mid].line <= line) lo = mid + 1;
      else hi = mid;
    }
    const prev = blocks[lo - 1];
    const next = blocks[lo];
    if (!prev) return 0;

    const top = (el) => el.getBoundingClientRect().top + window.scrollY;
    const start = top(prev.el);
    const end = next ? top(next.el) : start + prev.el.getBoundingClientRect().height;
    const endLine = next ? next.line : Math.max(total, prev.line + 1);
    return start + ((end - start) * (line - prev.line)) / Math.max(1, endLine - prev.line);
  }

  // Shows the same part of the document as the Neovim window, keeping the cursor on screen.
  function scrollToLine({ line, top = line, bottom = line, total }) {
    const height = window.innerHeight;
    let y = top === 0 ? 0 : lineOffset(top, total);
    // Rendered blocks can be much taller than their source, so the cursor may fall off the page.
    const cursorY = lineOffset(line, total);
    if (cursorY < y || cursorY > y + height * 0.8) {
      const fraction = Math.min(1, Math.max(0, (line - top) / Math.max(1, bottom - top)));
      y = cursorY - height * 0.8 * fraction;
    }
    window.scrollTo({ top: Math.max(0, y), behavior: "instant" });
    syncedY = window.scrollY;
  }

  // Scrolling the preview by hand scrolls the Neovim window to the same place.
  // Scrolls that scrollToLine() makes are not sent back, and while the page is
  // scrolled by hand, the cursor events Neovim answers with do not move it.
  let syncedY = -1; // where scrollToLine() last put the page
  let scrolledByHandAt = 0;
  /** @type {number | undefined} */
  let editorScrollTimer;

  // The source line at the top of the window: the inverse of lineOffset().
  function topSourceLine() {
    const blocks = lineBlocks();
    const y = window.scrollY;
    const top = (el) => el.getBoundingClientRect().top + y;
    // Binary search for the first block that starts below the top of the window,
    // give or take the fraction of a pixel a block scrolled to can be off by.
    let lo = 0;
    let hi = blocks.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (top(blocks[mid].el) <= y + 1) lo = mid + 1;
      else hi = mid;
    }
    const prev = blocks[lo - 1];
    if (!prev) return 0;
    const next = blocks[lo];
    const start = top(prev.el);
    const end = next ? top(next.el) : start + prev.el.getBoundingClientRect().height;
    const endLine = next ? next.line : prev.line + 1;
    const fraction = end > start ? Math.min(1, Math.max(0, (y - start) / (end - start))) : 0;
    return Math.floor(prev.line + fraction * (endLine - prev.line));
  }

  window.addEventListener(
    "scroll",
    () => {
      if (!settings.scrollEditor || Math.abs(window.scrollY - syncedY) < 2) return;
      scrolledByHandAt = performance.now();
      if (editorScrollTimer !== undefined) return;
      editorScrollTimer = setTimeout(() => {
        editorScrollTimer = undefined;
        // Nothing to say when the buffer is in no window: the page just scrolls.
        post(`/scroll/${bufnr}?line=${topSourceLine()}`).catch(() => {});
      }, 100);
    },
    { passive: true },
  );

  // ------------------------------------------------------------------- theme

  function applyTheme(data) {
    const vars = (data && data.vars) || {};
    for (const key of themeKeys) {
      if (!(key in vars)) root.style.removeProperty(`--${key}`);
    }
    themeKeys.clear();
    for (const [key, value] of Object.entries(vars)) {
      root.style.setProperty(`--${key}`, value);
      themeKeys.add(key);
    }
    mode = (data && data.mode) || systemMode();
    root.dataset.theme = mode;
    queueMermaid();
  }

  // ------------------------------------------------------------------ export

  // Attributes this script adds for the live preview; the exported page does not need them.
  const liveAttributes = [
    "data-task",
    "data-line",
    "data-source",
    "data-src",
    "data-tex",
    "data-display",
    "data-open-path",
    "data-open-hash",
  ];

  const exportPolicy = "script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";

  async function fetchOk(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${url}: ${response.status}`);
    return response;
  }

  async function dataUrl(url) {
    const blob = await (await fetchOk(url)).blob();
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
  }

  // KaTeX styles with the woff2 fonts inlined, so math renders without the plugin.
  async function katexCss() {
    const css = await (await fetchOk("/app/vendor/katex/katex.min.css")).text();
    const files = new Set(Array.from(css.matchAll(/url\((fonts\/[^)]+\.woff2)\)/g), (m) => m[1]));
    /** @type {(file: string) => Promise<[string, string]>} */
    const inline = async (file) => [file, await dataUrl(`/app/vendor/katex/${file}`)];
    const urls = new Map(await Promise.all(Array.from(files, inline)));
    return css.replace(/src:url\((fonts\/[^)]+\.woff2)\)[^;}]*/g, (_, file) => `src:url(${urls.get(file)}) format("woff2")`);
  }

  // A standalone page: styles and fonts inlined, relative files resolved through `base`.
  async function standaloneHtml(base) {
    const page = /** @type {HTMLElement} */ (contentEl.cloneNode(true));
    // Rewriting these also keeps the token out of the exported file.
    const prefix = `${session}/files/${bufnr}/`;
    const local = (url) => (url.startsWith(prefix) ? base + url.slice(prefix.length) : url);
    for (const el of page.querySelectorAll("[src], [href], [poster]")) {
      for (const name of ["src", "href", "poster"]) {
        const value = el.getAttribute(name);
        if (value) el.setAttribute(name, local(value));
      }
    }
    for (const el of page.querySelectorAll("[srcset]")) {
      el.setAttribute("srcset", mapSrcset(el.getAttribute("srcset"), local));
    }
    page.querySelectorAll(".copy-code").forEach((button) => button.remove());
    // The file cannot tick them in Neovim.
    page.querySelectorAll("input[data-task]").forEach((box) => box.setAttribute("disabled", ""));
    for (const el of page.querySelectorAll(liveAttributes.map((name) => `[${name}]`).join(","))) {
      liveAttributes.forEach((name) => el.removeAttribute(name));
    }

    const styles = [];
    if (page.querySelector(".katex")) styles.push(await katexCss());
    styles.push(await (await fetchOk("/app/style.css")).text());
    styles.push(".markdown-body { padding-bottom: 32px; }");
    if (userStyle.textContent) styles.push(userStyle.textContent);

    const escape = md.utils.escapeHtml;
    const heading = page.querySelector("h1");
    const title = (heading && heading.textContent.trim()) || documentName || "mdlive";
    return [
      "<!doctype html>",
      `<html lang="en" data-theme="${mode}" style="${escape(root.style.cssText)}">`,
      "<head>",
      '<meta charset="utf-8" />',
      // The content was sanitized already; this also blocks scripts wherever the file is opened.
      `<meta http-equiv="Content-Security-Policy" content="${exportPolicy}" />`,
      '<meta name="viewport" content="width=device-width, initial-scale=1" />',
      '<meta name="generator" content="mdlive" />',
      `<title>${escape(title)}</title>`,
      // A </style> in the rules must not end the block early.
      `<style>\n${styles.join("\n").replace(/<\/style/gi, "<\\/style")}\n</style>`,
      "</head>",
      "<body>",
      `<main class="markdown-body">\n${page.innerHTML}\n</main>`,
      "</body>",
      "</html>",
      "",
    ].join("\n");
  }

  // :MdLiveExport asked for the rendered page; Neovim writes it to disk.
  async function exportPage({ id, base }) {
    let body = "";
    let query = "";
    try {
      flushUpdates(); // render content that is still queued
      await mermaidQueue; // diagrams from the latest content
      body = await standaloneHtml(base);
    } catch (err) {
      query = `?error=${encodeURIComponent(String((err && err.message) || err))}`;
    }
    try {
      await fetch(`${session}/export/${id}${query}`, {
        method: "POST",
        headers: { "X-MdLive": "1", "Content-Type": "text/html; charset=utf-8" },
        body,
      });
    } catch (_) {
      // Neovim reports the export as timed out.
    }
  }

  // ------------------------------------------------------------------ events

  // Actions answer JSON, but other errors (a rejected Host header, a server
  // error) are plain text.
  async function post(path) {
    const response = await fetch(session + path, { method: "POST", headers: { "X-MdLive": "1" } });
    const body = await response.text();
    /** @type {any} */
    let data = null;
    try {
      data = JSON.parse(body);
    } catch (_) {
      // Not JSON: the body is the error message.
    }
    if (!response.ok) throw new Error(data?.error || body.trim() || `HTTP ${response.status}`);
    if (!data) throw new Error("unexpected response");
    return data;
  }

  let navigating = false;

  contentEl.addEventListener("click", async (event) => {
    const target = /** @type {Element} */ (event.target);
    const copy = target.closest(".copy-code");
    if (copy) {
      const code = copy.parentElement?.querySelector("pre > code")?.textContent ?? "";
      try {
        await navigator.clipboard.writeText(code);
        copy.textContent = "Copied";
      } catch (_) {
        copy.textContent = "Copy failed";
      }
      setTimeout(() => (copy.textContent = "Copy"), 1500);
      return;
    }

    // Relative markdown links open the file in Neovim, then this tab follows it.
    const link = /** @type {HTMLElement | null} */ (target.closest("a[data-open-path]"));
    if (!link || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const { openPath = "", openHash = "" } = link.dataset;
    // Neovim changes buffer while handling this; don't also follow its "switch" event.
    navigating = true;
    try {
      // A wiki link names a note: Neovim may look for it by name.
      const wiki = link.classList.contains("wikilink") ? "&wiki=1" : "";
      const data = await post(`/open/${bufnr}?path=${encodeURIComponent(openPath)}${wiki}`);
      location.href = data.url + openHash;
    } catch (err) {
      navigating = false;
      flashStatus(`Could not open ${openPath}: ${err.message}`);
    }
  });

  // A task list checkbox ticks or clears its item in Neovim, and the buffer
  // update that follows renders it again. When Neovim refuses, it goes back.
  contentEl.addEventListener("change", async (event) => {
    const box = /** @type {HTMLInputElement} */ (event.target);
    if (!box.matches("input[data-task]")) return;
    const line = /** @type {HTMLElement | null} */ (box.closest("li"))?.dataset.line;
    if (line === undefined) return;
    const checked = box.checked;
    try {
      await post(`/task/${bufnr}?line=${line}&checked=${checked ? 1 : 0}`);
    } catch (err) {
      box.checked = !checked;
      flashStatus(`Could not update the task: ${err.message}`);
    }
  });

  // Double-clicking a block moves the Neovim cursor to its source line.
  contentEl.addEventListener("dblclick", async (event) => {
    const target = /** @type {Element} */ (event.target);
    if (target.closest("a, button, input, summary")) return;
    // A line number stands for the same line of the code next to it.
    const gutter = target.closest(".line-numbers");
    const block = /** @type {HTMLElement | null} */ (
      gutter ? gutter.parentElement?.querySelector(":scope > code") : target.closest("[data-source], [data-line]")
    );
    if (!block) return;
    const [first, last] = (block.dataset.source || `${block.dataset.line}-${Number(block.dataset.line) + 1}`)
      .split("-")
      .map(Number);
    // Estimate the line inside multi-line blocks from where the click landed.
    const rect = block.getBoundingClientRect();
    const fraction = rect.height > 0 ? (event.clientY - rect.top) / rect.height : 0;
    const line = first + Math.max(0, Math.min(last - first - 1, Math.floor(fraction * (last - first))));
    jumpedAt = performance.now();
    try {
      await post(`/jump/${bufnr}?line=${line}`);
    } catch (err) {
      flashStatus(`Could not jump to line ${line + 1}: ${err.message}`);
    }
  });

  // The browser retries a lost connection on its own. When Neovim quits, stop
  // after a few failed attempts instead of retrying forever; a click on the
  // status message tries again.
  const maxAttempts = 5;
  /** @type {(() => void) | null} */
  let retry = null;

  statusEl.addEventListener("click", () => retry?.());

  function giveUp(events) {
    events.close();
    setStatus("Can't reach Neovim · click to retry");
    statusEl.classList.add("retry");
    retry = () => {
      retry = null;
      statusEl.classList.remove("retry");
      setStatus("Reconnecting to Neovim…");
      connect();
    };
  }

  function connect() {
    const events = new EventSource(`${session}/events/${bufnr}`);
    let failures = 0;

    events.addEventListener("theme", (e) => applyTheme(JSON.parse(e.data)));
    events.addEventListener("style", (e) => {
      userStyle.textContent = JSON.parse(e.data).css;
      queueMermaid(); // the stylesheet may change the colors diagrams use
    });
    events.addEventListener("content", (e) => {
      const data = JSON.parse(e.data);
      documentName = data.name || "";
      document.title = `${documentName || "[No Name]"} · mdlive`;
      pendingText = lastText = data.text;
      scheduleUpdate();
    });
    events.addEventListener("settings", (e) => {
      const data = JSON.parse(e.data);
      settings.scrollEditor = data.scroll_editor === true;
      const outline = data.outline === true;
      if (outline !== outlineOption) {
        outlineOption = outline;
        outlineOpen = outline;
        showOutline();
      }
      const lineNumbers = data.code_line_numbers !== false;
      if (lineNumbers === settings.lineNumbers) return;
      settings.lineNumbers = lineNumbers;
      if (lastText !== null) {
        pendingText = lastText;
        scheduleUpdate();
      }
    });
    events.addEventListener("cursor", (e) => {
      if (ignoreCursor) {
        ignoreCursor = false;
        return;
      }
      cursor = JSON.parse(e.data);
      const now = performance.now();
      if (now - jumpedAt > 800 && now - scrolledByHandAt > 800) {
        pendingScroll = true;
        scheduleUpdate();
      }
    });
    events.addEventListener("export", (e) => exportPage(JSON.parse(e.data)));
    // Follow mode: Neovim moved to another markdown buffer, so show that one.
    events.addEventListener("switch", (e) => {
      if (navigating) return;
      events.close();
      bufnr = String(JSON.parse(e.data).bufnr);
      history.replaceState(null, "", `${session}/preview/${bufnr}`);
      cursor = null;
      pendingText = null;
      pendingScroll = false;
      pendingAnchor = null;
      ignoreCursor = false;
      window.scrollTo(0, 0);
      connect();
    });
    events.addEventListener("close", () => {
      events.close();
      setStatus("Preview stopped in Neovim");
    });
    events.onopen = () => {
      failures = 0;
      setStatus(null);
    };
    events.onerror = () => {
      failures++;
      // CLOSED: the server answered but has no preview for this buffer any more.
      if (events.readyState === EventSource.CLOSED || failures >= maxAttempts) {
        giveUp(events);
      } else {
        setStatus("Reconnecting to Neovim…");
      }
    };
  }

  connect();
})();
