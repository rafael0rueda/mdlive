(function () {
  "use strict";

  let bufnr = location.pathname.match(/\/preview\/(\d+)/)[1];
  const root = document.documentElement;
  const contentEl = document.getElementById("content");
  const statusEl = document.getElementById("status");

  let mode = systemMode();
  let cursor = null;
  // Arrived through a link like guide.md#install: scroll there instead of to the cursor.
  let pendingAnchor = location.hash.length > 1 ? safeDecode(location.hash.slice(1)) : null;
  let ignoreCursor = pendingAnchor !== null;
  const themeKeys = new Set();

  root.dataset.theme = mode;

  function systemMode() {
    return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function setStatus(message) {
    statusEl.hidden = !message;
    statusEl.textContent = message || "";
  }

  // ---------------------------------------------------------------- markdown

  const md = window.markdownit({
    html: true,
    linkify: true,
    highlight(code, lang) {
      if (lang && hljs.getLanguage(lang)) {
        try {
          return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        } catch (_) {}
      }
      return ""; // markdown-it escapes the code itself
    },
  });

  md.use(texmath, { engine: katex, delimiters: "dollars" });

  // Tag every block with its source line so the preview can follow the cursor.
  md.core.ruler.push("source_lines", (state) => {
    for (const token of state.tokens) {
      if (token.block && token.map && token.nesting >= 0) {
        token.attrSet("data-line", String(token.map[0]));
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

  // Runs after sanitizing, so everything added here comes from this script.
  function postProcess(fragment, env) {
    for (const block of fragment.querySelectorAll(".mermaid-block[data-mermaid]")) {
      block.dataset.src = env.mermaid[Number(block.dataset.mermaid)] ?? "";
      block.removeAttribute("data-mermaid");
    }

    // Relative images are served from the markdown file's directory.
    for (const img of fragment.querySelectorAll("img[src]")) {
      const src = img.getAttribute("src");
      if (isRelative(src)) img.setAttribute("src", `/files/${bufnr}/${src}`);
    }

    for (const link of fragment.querySelectorAll("a[href]")) {
      const href = link.getAttribute("href");
      if (href.startsWith("#")) continue;
      // Everything except in-page anchors opens in a new tab so the preview stays put.
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      if (!isRelative(href)) continue;

      const [, path, hash = ""] = /^([^?#]*)(?:\?[^#]*)?(#.*)?$/.exec(href);
      if (!path) continue;
      // Local files are served raw; markdown files are opened in Neovim on click.
      link.setAttribute("href", `/files/${bufnr}/${path}`);
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
      box.disabled = true;
      if (match[1] !== " ") box.setAttribute("checked", "");
      host.insertBefore(box, first);
      li.classList.add("task-list-item");
    }
  }

  // ------------------------------------------------------------------ render

  const isMermaid = (node) => node.nodeType === Node.ELEMENT_NODE && node.classList.contains("mermaid-block");

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

  // Updates `target` in place so unchanged nodes (images, diagrams) are not rebuilt.
  function patch(target, source) {
    const oldNodes = Array.from(target.childNodes);
    const newNodes = Array.from(source.childNodes);

    newNodes.forEach((next, i) => {
      const prev = oldNodes[i];
      if (!prev) {
        target.appendChild(next);
      } else if (isMermaid(prev) || isMermaid(next)) {
        if (isMermaid(prev) && isMermaid(next) && prev.dataset.src === next.dataset.src) {
          prev.dataset.line = next.dataset.line;
        } else {
          target.replaceChild(next, prev);
        }
      } else if (prev.isEqualNode(next)) {
        // unchanged
      } else if (prev.nodeType === Node.TEXT_NODE && next.nodeType === Node.TEXT_NODE) {
        prev.nodeValue = next.nodeValue;
      } else if (
        prev.nodeType === Node.ELEMENT_NODE &&
        next.nodeType === Node.ELEMENT_NODE &&
        prev.tagName === next.tagName
      ) {
        syncAttributes(prev, next);
        patch(prev, next);
      } else {
        target.replaceChild(next, prev);
      }
    });

    for (let i = newNodes.length; i < oldNodes.length; i++) {
      oldNodes[i].remove();
    }
  }

  function render(text) {
    const template = document.createElement("template");
    // HTML inside the markdown is untrusted: drop scripts, event handlers, iframes, ...
    const env = { mermaid: [] };
    const { frontMatter, body } = splitFrontMatter(text);
    const html = (frontMatter ? frontMatterHtml(frontMatter) : "") + md.render(body, env);
    template.innerHTML = DOMPurify.sanitize(html, { ADD_TAGS: ["semantics", "annotation"] });
    postProcess(template.content, env);
    patch(contentEl, template.content);
    queueMermaid();
    if (pendingAnchor !== null) {
      document.getElementById(pendingAnchor)?.scrollIntoView();
      pendingAnchor = null;
    } else if (cursor) {
      scrollToLine(cursor);
    }
  }

  // ----------------------------------------------------------------- mermaid

  let mermaidLoad = null;
  let mermaidQueue = Promise.resolve();
  let mermaidTheme = null;
  let diagramId = 0;
  const diagramCache = new Map(); // `${theme}\n${src}` -> html
  const renderedDiagrams = new WeakMap(); // element -> cache key

  function loadMermaid() {
    mermaidLoad ??= new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "/app/vendor/mermaid.min.js";
      script.onload = () => resolve(window.mermaid);
      script.onerror = () => reject(new Error("Could not load mermaid"));
      document.head.appendChild(script);
    });
    return mermaidLoad;
  }

  function queueMermaid() {
    mermaidQueue = mermaidQueue.then(renderMermaid, renderMermaid);
  }

  async function renderMermaid() {
    const theme = mode === "dark" ? "dark" : "default";
    const pending = Array.from(contentEl.querySelectorAll(".mermaid-block")).filter(
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
    if (mermaidTheme !== theme) {
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme });
      mermaidTheme = theme;
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

  // ------------------------------------------------------------------ scroll

  function scrollToLine({ line, total }) {
    let prev = null;
    let prevLine = -1;
    let next = null;
    let nextLine = Infinity;
    for (const el of contentEl.querySelectorAll("[data-line]")) {
      const l = Number(el.dataset.line);
      if (l <= line && l >= prevLine) {
        prev = el;
        prevLine = l;
      } else if (l > line && l < nextLine) {
        next = el;
        nextLine = l;
      }
    }

    let y = 0;
    if (prev) {
      const top = (el) => el.getBoundingClientRect().top + window.scrollY;
      const start = top(prev);
      const end = next ? top(next) : start + prev.getBoundingClientRect().height;
      const endLine = next ? nextLine : Math.max(total, prevLine + 1);
      y = start + ((end - start) * (line - prevLine)) / Math.max(1, endLine - prevLine);
    }
    window.scrollTo({ top: Math.max(0, y - window.innerHeight / 3), behavior: "instant" });
  }

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

  // ------------------------------------------------------------------ events

  // Relative markdown links open the file in Neovim, then this tab follows it.
  contentEl.addEventListener("click", async (event) => {
    const link = event.target.closest("a[data-open-path]");
    if (!link || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const { openPath, openHash } = link.dataset;
    // Neovim changes buffer while handling this; don't also follow its "switch" event.
    navigating = true;
    try {
      const response = await fetch(`/open/${bufnr}?path=${encodeURIComponent(openPath)}`, {
        method: "POST",
        headers: { "X-MdLive": "1" },
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error);
      location.href = data.url + openHash;
    } catch (err) {
      navigating = false;
      setStatus(`Could not open ${openPath}: ${err.message}`);
      setTimeout(() => setStatus(null), 4000);
    }
  });

  let navigating = false;

  function connect() {
    const events = new EventSource(`/events/${bufnr}`);

    events.addEventListener("theme", (e) => applyTheme(JSON.parse(e.data)));
    events.addEventListener("content", (e) => {
      const data = JSON.parse(e.data);
      document.title = `${data.name || "[No Name]"} · mdlive`;
      render(data.text);
    });
    events.addEventListener("cursor", (e) => {
      if (ignoreCursor) {
        ignoreCursor = false;
        return;
      }
      cursor = JSON.parse(e.data);
      scrollToLine(cursor);
    });
    // Follow mode: Neovim moved to another markdown buffer, so show that one.
    events.addEventListener("switch", (e) => {
      if (navigating) return;
      events.close();
      bufnr = String(JSON.parse(e.data).bufnr);
      history.replaceState(null, "", `/preview/${bufnr}`);
      cursor = null;
      pendingAnchor = null;
      ignoreCursor = false;
      window.scrollTo(0, 0);
      connect();
    });
    events.addEventListener("close", () => {
      events.close();
      setStatus("Preview stopped in Neovim");
    });
    events.onopen = () => setStatus(null);
    events.onerror = () => {
      setStatus(events.readyState === EventSource.CLOSED ? "Disconnected from Neovim" : "Reconnecting to Neovim…");
    };
  }

  connect();
})();
