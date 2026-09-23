// Browser tests: the preview page in headless Chrome, driven against a real
// Neovim. Run from the repository root with Node 22+ and Chrome or Chromium
// (set CHROME=/path/to/chrome if it is not on PATH):
//   node tests/browser.mjs
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { sleep, startChrome, startNeovim, tempDir, waitFor } from "./harness.mjs";

const dir = tempDir();
let failures = 0;

// On GitHub Actions a failure also becomes an annotation, shown on the run page.
function report(message) {
  console.log(message);
  if (process.env.GITHUB_ACTIONS) {
    const text = message.slice(0, 4000).replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
    console.log(`::error title=Browser tests::${text}`);
  }
}

// Anything that escapes the checks below still ends up on the run page.
process.on("uncaughtException", (err) => {
  report(`ERROR ${err.stack}`);
  process.exit(1);
});
process.on("unhandledRejection", (err) => {
  report(`ERROR ${err?.stack ?? err}`);
  process.exit(1);
});

function check(name, ok, detail) {
  if (ok) {
    console.log(`ok   ${name}`);
  } else {
    failures++;
    report(`FAIL ${name}${detail === undefined ? "" : ` -> ${JSON.stringify(detail)}`}`);
  }
}

let nvim;
let page;
let launcher;
let launcherDir;
try {
  page = await startChrome({ dir });

  // Starting the browser -----------------------------------------------------

  // The preview URL carries the token, so it is not handed to the browser on a
  // command line, which every user on the machine can read: the browser is
  // started on a file that redirects to the preview instead.
  launcherDir = tempDir();
  const recorded = join(launcherDir, "argv.txt");
  launcher = await startNeovim({
    dir: launcherDir,
    file: "examples/demo.md",
    browser: `{ "sh", "-c", 'printf "%s" "$0" > ${recorded}' }`,
  });
  const launched = await waitFor(() => existsSync(recorded) && readFileSync(recorded, "utf8").trim());
  check("the browser is started on a file, not on the preview URL", Boolean(launched?.startsWith("file://")), launched);
  check("the token is not on the command line", !/\/[0-9a-f]{32}\//.test(launched ?? ""), launched);

  await page.send("Page.navigate", { url: launched });
  const landed = await waitFor(
    async () => {
      const href = await page.eval("location.href");
      return /^http:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{32}\/preview\/\d+/.test(href) && href;
    },
    { timeout: 15000 },
  );
  check("the file redirects to the preview", Boolean(landed), landed || (await page.eval("location.href")));
  const redirected = await waitFor(() => page.eval(`document.querySelector("h1")?.textContent`), { timeout: 20000 });
  check("the preview works after the redirect", redirected === "mdlive demo", redirected);
  const history = await page.send("Page.getNavigationHistory");
  check(
    "the redirect leaves no entry to go back to",
    !history.entries.some((entry) => entry.url.startsWith("file://")),
    history.entries.map((entry) => entry.url),
  );
  launcher.kill("SIGKILL");
  launcher = null;

  // Rendering ----------------------------------------------------------------

  nvim = await startNeovim({ dir, file: "examples/demo.md" });
  await page.goto(nvim.url);
  const [, token, , bufnr] = new URL(nvim.url).pathname.split("/");
  const files = `/${token}/files/${bufnr}/`;

  const heading = await waitFor(
    () => page.eval(`document.querySelector(".mermaid-block svg") && document.querySelector("h1")?.textContent`),
    { timeout: 20000 },
  );
  check("renders the buffer", heading === "mdlive demo", heading);
  const features = await page.eval(`({
    math: document.querySelectorAll(".katex").length,
    alerts: document.querySelectorAll(".markdown-alert").length,
    footnotes: document.querySelectorAll(".footnotes li").length,
    lineNumbers: document.querySelectorAll(".line-numbers").length,
    title: document.title,
  })`);
  check(
    "renders math, alerts, footnotes and code line numbers",
    features.math === 2 && features.alerts === 2 && features.footnotes === 1 && features.lineNumbers === 2,
    features,
  );
  check("tab title is the file name", features.title === "demo.md · mdlive", features.title);

  // Diagrams take the page's colors, and follow them when the colorscheme changes.
  const diagramColors = () =>
    page.eval(`(() => {
      const probe = document.createElement("span");
      document.body.append(probe);
      const rgb = (name) => {
        probe.style.color = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
        return getComputedStyle(probe).color;
      };
      const svg = document.querySelector(".mermaid-block svg");
      const colors = {
        node: svg && getComputedStyle(svg.querySelector(".node rect, .node polygon")).fill,
        link: svg && getComputedStyle(svg.querySelector(".flowchart-link")).stroke,
        surface: rgb("--surface"),
        muted: rgb("--muted"),
      };
      probe.remove();
      return colors;
    })()`);
  let colors = await diagramColors();
  check(
    "diagrams use the colors of the page",
    colors.node === colors.surface && colors.link === colors.muted,
    colors,
  );
  const firstSurface = colors.surface;
  await nvim.lua(`vim.o.background = vim.o.background == "dark" and "light" or "dark"`);
  colors = await waitFor(async () => {
    const now = await diagramColors();
    return now.surface !== firstSurface && now.node === now.surface && now;
  });
  check("diagrams are drawn again when the colorscheme changes", Boolean(colors), await diagramColors());
  await nvim.lua(`vim.o.background = vim.o.background == "dark" and "light" or "dark"`);
  await waitFor(async () => (await diagramColors()).node === firstSurface);
  const imageLoaded = await waitFor(() => page.eval(`document.querySelector('img[alt="Local image"]')?.naturalWidth > 0`));
  check("relative images load through the token URL", imageLoaded);

  // Outline ------------------------------------------------------------------

  const outlineState = () =>
    page.eval(`({
      button: !document.getElementById("outline-toggle").hidden,
      open: !document.getElementById("outline").hidden,
      entries: Array.from(document.querySelectorAll("#outline a"), (a) => a.textContent + "@" + a.dataset.depth),
      headings: Array.from(document.querySelectorAll("#content :is(h1, h2, h3, h4, h5, h6)"), (h) => h.textContent),
      current: document.querySelector("#outline a[aria-current]")?.textContent ?? null,
      padded: parseFloat(getComputedStyle(document.body).paddingLeft) > 0,
    })`);
  let outline = await outlineState();
  check("the outline button is shown and the outline starts closed", outline.button && !outline.open, outline);
  await page.eval(`document.getElementById("outline-toggle").click()`);
  outline = await outlineState();
  check(
    "the outline lists the headings, indented by level",
    outline.open &&
      outline.entries.length === outline.headings.length &&
      outline.entries[0] === "mdlive demo@0" &&
      outline.entries[1] === `${outline.headings[1]}@1`,
    outline,
  );
  // The front matter comes before the first heading: no section is passed yet.
  check("nothing is marked above the first heading", outline.current === null, outline);
  const lastHeading = outline.headings.at(-1);
  await page.eval(`Array.from(document.querySelectorAll("#outline a")).at(-1).click()`);
  // 16px below the top (scroll-margin-top), unless it is too close to the end of the page to get there.
  const atHeading = await waitFor(() =>
    page.eval(`(() => {
      const top = Array.from(document.querySelectorAll("#content h2")).at(-1).getBoundingClientRect().top;
      const atBottom = innerHeight + scrollY >= document.documentElement.scrollHeight - 1;
      return Math.abs(top - 16) < 2 || (atBottom && top > 0 && top < innerHeight);
    })()`),
  );
  outline = await outlineState();
  check("clicking an entry scrolls to its heading", atHeading, await page.eval("scrollY"));
  check(
    "in a narrow window the outline covers the text and closes after a click",
    !outline.open && !outline.padded,
    outline,
  );
  check("clicking an entry leaves the address alone", (await page.eval("location.hash")) === "");
  await page.eval(`document.getElementById("outline-toggle").click()`);
  outline = await outlineState();
  check("the outline marks the section at the top of the window", outline.current === lastHeading, outline);
  await page.eval(`document.getElementById("outline-toggle").click()`);

  await page.resize(1400, 800);
  await page.eval(`document.getElementById("outline-toggle").click()`);
  await page.eval(`document.querySelector("#outline a").click()`);
  outline = await waitFor(async () => {
    const state = await outlineState();
    return state.current === "mdlive demo" && state;
  });
  check("in a wide window the outline sits next to the text and stays open", outline?.open && outline.padded, outline);
  await page.eval(`document.getElementById("outline-toggle").click()`);
  await page.resize(1200, 800);

  // The option opens it when it changes, and the button decides in between.
  const setOutline = (value) =>
    nvim.lua(`local options = vim.tbl_extend("force", require("mdlive.config").options, { outline = ${value} })
      require("mdlive").setup(options)`);
  await setOutline(true);
  check("the outline option opens the outline", await waitFor(async () => (await outlineState()).open));
  await setOutline(false);
  check("turning the option off closes it", await waitFor(async () => !(await outlineState()).open));
  await page.eval(`window.scrollTo(0, 0)`);

  // Task lists ---------------------------------------------------------------

  const taskBox = `Array.from(document.querySelectorAll("#content li.task-list-item"))
    .find((li) => li.textContent.includes("Something still to do")).querySelector("input")`;
  const taskLine = await nvim.lua(`for i, text in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if text:find("Something still to do", 1, true) then return i - 1 end
    end`);
  const bufferTask = () => nvim.lua(`return vim.api.nvim_buf_get_lines(0, ${taskLine}, ${taskLine + 1}, false)[1]`);
  check(
    "task list checkboxes can be clicked",
    await page.eval(`(() => { const box = ${taskBox}; return !box.disabled && box.closest("li").dataset.line === "${taskLine}"; })()`),
  );
  await page.eval(`${taskBox}.click()`);
  const ticked = await waitFor(async () => (await bufferTask()) === "- [x] Something still to do");
  check("clicking a task checkbox ticks the item in the buffer", ticked, await bufferTask());
  check("the preview shows the ticked item", await waitFor(() => page.eval(`${taskBox}.checked`)));
  await page.eval(`${taskBox}.click()`);
  check(
    "clicking it again clears the item",
    await waitFor(async () => (await bufferTask()) === "- [ ] Something still to do"),
    await bufferTask(),
  );
  await waitFor(() => page.eval(`!${taskBox}.checked`));
  await nvim.lua(`vim.bo.modifiable = false`);
  await page.eval(`${taskBox}.click()`);
  const refused = await waitFor(() =>
    page.eval(`!${taskBox}.checked && document.getElementById("status").textContent.startsWith("Could not update the task")`),
  );
  check("a refused click puts the checkbox back and says why", refused, await page.eval(`document.getElementById("status").textContent`));
  await nvim.lua(`vim.bo.modifiable = true`);

  // Untrusted HTML -----------------------------------------------------------

  const lineCount = await nvim.lua("return vim.api.nvim_buf_line_count(0)");
  await nvim.lua(`vim.api.nvim_buf_set_lines(0, -1, -1, false, {
    "", '<img alt="probe" src="x" onerror="window.__xss = 1">',
    "", "<script>window.__xss = 2</script>",
    "", '<a href="javascript:window.__xss = 3">probe link</a>',
    "", '<a href="https://example.com/" data-open-path="docs/guide.md" data-open-hash="#install">probe web link</a>',
    "", '<p><input type="checkbox" class="posing-task" data-task="0"></p>',
  })`);
  const probed = await waitFor(() => page.eval(`!!document.querySelector('img[alt="probe"]')`));
  await sleep(300);
  const xss = await page.eval(`({
    ran: window.__xss ?? null,
    handlers: document.querySelectorAll("#content [onerror]").length,
    scripts: document.querySelectorAll("#content script").length,
    href: Array.from(document.querySelectorAll("#content a")).find((a) => a.textContent === "probe link")?.getAttribute("href") ?? null,
    posing: Array.from(document.querySelectorAll("#content a")).find((a) => a.textContent === "probe web link")?.hasAttribute("data-open-path") ?? null,
    posingTask: document.querySelector("#content .posing-task")?.hasAttribute("data-task") ?? null,
  })`);
  check("renders raw HTML from the buffer", probed);
  check("scripts and event handlers in the buffer do not run", xss.ran === null && !xss.handlers && !xss.scripts, xss);
  check("javascript: links are removed", !xss.href?.startsWith("javascript:"), xss.href);
  check("a web link cannot pose as a link that opens a file in Neovim", xss.posing === false, xss);
  check("a checkbox in the buffer cannot pose as a task list checkbox", xss.posingTask === false, xss);
  await nvim.lua(`vim.api.nvim_buf_set_lines(0, ${lineCount}, -1, false, {})`);
  await waitFor(() => page.eval(`!document.querySelector('img[alt="probe"]')`));

  // In-place update ----------------------------------------------------------

  await page.eval(`(() => {
    const kept = document.querySelectorAll('img[alt="Local image"], .mermaid-block, .math[data-tex], table');
    kept.forEach((el) => (el.__kept = true));
    document.querySelector("details.front-matter").open = true;
  })()`);
  const tableLine = await page.eval(`Number(document.querySelector("table").dataset.line)`);
  await nvim.lua(`
    for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if line == "## Text" then
        vim.api.nvim_buf_set_lines(0, i, i, false, { "", "Inserted paragraph." })
        return
      end
    end`);
  await waitFor(() => page.eval(`document.body.textContent.includes("Inserted paragraph.")`));
  const after = await page.eval(`({
    image: !!document.querySelector('img[alt="Local image"]').__kept,
    diagram: !!document.querySelector(".mermaid-block").__kept && !!document.querySelector(".mermaid-block svg"),
    math: Array.from(document.querySelectorAll(".math[data-tex]")).every((el) => el.__kept && el.querySelector(".katex")),
    table: !!document.querySelector("table").__kept,
    tableLine: Number(document.querySelector("table").dataset.line),
    details: document.querySelector("details.front-matter").open,
  })`);
  check(
    "inserting a block keeps the image, diagram, formulas and table",
    after.image && after.diagram && after.math && after.table,
    after,
  );
  check("blocks below an insertion get their new line numbers", after.tableLine === tableLine + 2, { tableLine, after });
  check("an expanded front matter block stays open", after.details, after);

  // Scroll sync --------------------------------------------------------------

  await nvim.keys("<Esc>gg");
  await waitFor(() => page.eval("scrollY === 0"));
  await nvim.keys("/^## Diagram<CR>");
  const inView = await waitFor(() =>
    page.eval(`(() => {
      const heading = Array.from(document.querySelectorAll("h2")).find((h) => h.textContent === "Diagram");
      const { top } = heading.getBoundingClientRect();
      return scrollY > 0 && top >= 0 && top < innerHeight;
    })()`),
  );
  check("the preview scrolls to the block under the cursor", inView, await page.eval("scrollY"));
  await nvim.keys("gg");
  check("the preview scrolls back to the top", await waitFor(() => page.eval("scrollY === 0")));

  await nvim.keys("12G");
  await sleep(300);
  const before = await page.eval("scrollY");
  await nvim.keys("<C-e><C-e><C-e><C-e><C-e>");
  const scrolled = await waitFor(() => page.eval(`scrollY > ${before}`));
  const cursor = await nvim.lua(`return { line = vim.fn.line("."), top = vim.fn.line("w0") }`);
  check(
    "scrolling the window without moving the cursor scrolls the preview",
    scrolled && cursor.line === 12 && cursor.top > 1,
    { before, cursor },
  );

  // Double-click and copy ----------------------------------------------------

  const fence = await nvim.lua(`return vim.fn.search("^" .. string.rep("\`", 3) .. "lua", "nw")`);
  await page.eval(`(() => {
    const gutter = document.querySelector(".line-numbers");
    gutter.scrollIntoView({ block: "center" });
    const rect = gutter.getBoundingClientRect();
    const lines = gutter.textContent.split("\\n").length;
    const y = rect.top + (rect.height * 2.5) / lines;
    gutter.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, clientX: rect.left + 4, clientY: y }));
  })()`);
  const jumped = await waitFor(async () => {
    const line = await nvim.lua(`return vim.fn.line(".")`);
    return line === fence + 3 && line;
  });
  check("double-clicking line 3 of a code block moves the cursor to it", jumped === fence + 3, { fence, jumped });

  const copied = await page.eval(`(async () => {
    let text = null;
    navigator.clipboard.writeText = async (value) => { text = value; };
    document.querySelector(".copy-code").click();
    await new Promise((resolve) => setTimeout(resolve, 100));
    return text;
  })()`);
  check("the copy button copies the code without line numbers", copied?.startsWith("local function greet(name)"), copied);

  // Links and media ----------------------------------------------------------

  await nvim.lua(`vim.api.nvim_buf_set_lines(0, -1, -1, false, {
    "", '<picture><source srcset="assets/logo.svg 1x, https://example.com/big.png 2x"><img alt="picture probe" src="missing.png"></picture>',
    "", '<video poster="assets/logo.svg" src="clip.mp4"></video>',
    "", "[manual probe](assets/manual.pdf#page=3)",
  })`);
  // The <img> itself points to a missing file: it only loads through the rewritten srcset.
  const media = await waitFor(() =>
    page.eval(`(() => {
      if (!(document.querySelector('img[alt="picture probe"]')?.naturalWidth > 0)) return null;
      const video = document.querySelector("#content video");
      return {
        srcset: document.querySelector("#content picture source").getAttribute("srcset"),
        poster: video.getAttribute("poster"),
        src: video.getAttribute("src"),
        manual: Array.from(document.querySelectorAll("#content a")).find((a) => a.textContent === "manual probe")?.getAttribute("href"),
      };
    })()`),
  );
  check(
    "relative srcset, poster and media URLs load through the token URL",
    media?.srcset === `${files}assets/logo.svg 1x, https://example.com/big.png 2x` &&
      media.poster === `${files}assets/logo.svg` &&
      media.src === `${files}clip.mp4`,
    media,
  );
  check("links to local files keep their fragment", media?.manual === `${files}assets/manual.pdf#page=3`, media);

  // An href from raw HTML may hold a line break; the page must still render.
  await nvim.lua(`vim.api.nvim_buf_set_lines(0, -1, -1, false, {
    "", '<a href="docs/guide.md#a', 'b">newline probe</a>',
  })`);
  const newline = await waitFor(() =>
    page.eval(`(() => {
      const link = Array.from(document.querySelectorAll("#content a")).find((a) => a.textContent === "newline probe");
      return link && { href: link.getAttribute("href"), open: link.dataset.openPath ?? null };
    })()`),
  );
  check(
    "a link with a line break in its fragment is still rewritten",
    newline?.href === `${files}docs/guide.md#a\nb` && newline.open === "docs/guide.md",
    newline,
  );

  // Custom CSS ---------------------------------------------------------------

  // The comment tries to end the <style> block of an exported page early.
  const cssFile = join(dir, "custom.css");
  writeFileSync(cssFile, ".markdown-body { max-width: 610px; } /* </style><p id=\"escaped\"> */\n");
  const setOptions = (extra) =>
    nvim.lua(`require("mdlive").setup(vim.tbl_extend("force", require("mdlive.config").options, ${extra}))`);
  await setOptions(`{ css = ${JSON.stringify(cssFile)} }`);
  const styled = await waitFor(() => page.eval(`getComputedStyle(document.getElementById("content")).maxWidth === "610px"`));
  check("the css option styles the preview", styled, await page.eval(`getComputedStyle(document.getElementById("content")).maxWidth`));

  // Export -------------------------------------------------------------------

  const exportPath = join(dir, "demo.html");
  await nvim.lua(`require("mdlive").export(0, { path = ${JSON.stringify(exportPath)} })`);
  const html = await waitFor(() => existsSync(exportPath) && readFileSync(exportPath, "utf8"), { timeout: 15000 });
  check(
    "export writes a standalone page",
    html && html.includes('class="katex"') && html.includes("<svg") && !html.includes("data-line") && !html.includes("<script"),
    html ? html.slice(0, 120) : html,
  );
  check("the exported page does not contain the server token", html && !html.includes(token));
  check("the exported page has no outline", html && !html.includes('id="outline"'));
  check(
    "the exported page has the css option's rules, which cannot end its <style>",
    html && html.includes("max-width: 610px") && !html.includes('</style><p id="escaped">'),
  );
  await nvim.lua(`local options = vim.deepcopy(require("mdlive.config").options)
    options.css = nil
    require("mdlive").setup(options)`);
  await waitFor(() => page.eval(`getComputedStyle(document.getElementById("content")).maxWidth === "900px"`));
  check(
    "the exported task checkboxes cannot be clicked",
    html && html.includes('<input type="checkbox" disabled') && !html.includes("data-task"),
  );
  check("the exported page has a policy that blocks scripts", html?.includes(`http-equiv="Content-Security-Policy"`));
  check(
    "the exported page resolves relative srcset URLs",
    html && /srcset="[^"]*assets\/logo\.svg 1x, https:\/\/example\.com\/big\.png 2x"/.test(html) && !html.includes("/files/"),
    html?.match(/srcset="[^"]*"/)?.[0],
  );

  // Wiki links ---------------------------------------------------------------

  const beforeWiki = await nvim.lua("return vim.api.nvim_buf_line_count(0)");
  await nvim.lua(`vim.api.nvim_buf_set_lines(0, -1, -1, false, {
    "", "[[docs/guide#Install|the guide]] [[guide]] [[#Math]] [[manual.pdf]]",
  })`);
  const wiki = await waitFor(() =>
    page.eval(`(() => {
      const links = Array.from(document.querySelectorAll("#content a.wikilink"));
      if (links.length < 4) return null;
      return links.map((a) => ({ text: a.textContent, href: a.getAttribute("href"), open: a.dataset.openPath ?? null }));
    })()`),
  );
  check(
    "wiki links render as links, with a label and a heading",
    wiki?.[0].text === "the guide" && wiki[0].href === `${files}docs/guide.md#install` && wiki[0].open === "docs/guide.md",
    wiki,
  );
  check("a wiki link without an extension points to a note", wiki?.[1].text === "guide" && wiki[1].open === "guide.md", wiki);
  check("a wiki link to a heading of this page stays on it", wiki?.[2].href === "#math", wiki);
  check(
    "a wiki link to another kind of file keeps its extension",
    wiki?.[3].href === `${files}manual.pdf` && wiki[3].open === null,
    wiki,
  );
  const demoBuf = await nvim.lua("return vim.api.nvim_get_current_buf()");
  await page.eval(`Array.from(document.querySelectorAll("#content a.wikilink")).find((a) => a.textContent === "guide").click()`);
  const noteOpened = await waitFor(async () => {
    const title = await page.eval(`document.querySelector("h1")?.textContent`);
    return title === "Guide" && (await nvim.lua(`return vim.fs.basename(vim.api.nvim_buf_get_name(0))`));
  });
  check("clicking a wiki link opens the note it names, found in another folder", noteOpened === "guide.md", noteOpened);
  // Back to the demo: follow mode takes the tab along.
  await nvim.lua(`vim.cmd.buffer(${demoBuf})`);
  await waitFor(() => page.eval(`document.querySelector("h1")?.textContent === "mdlive demo"`), { timeout: 10000 });
  await nvim.lua(`vim.api.nvim_buf_set_lines(0, ${beforeWiki}, -1, false, {})`);
  await waitFor(() => page.eval(`!document.querySelector("#content a.wikilink")`));

  // Status messages ----------------------------------------------------------

  await nvim.lua(`vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "[missing probe](missing.md)" })`);
  await waitFor(() =>
    page.eval(`Array.from(document.querySelectorAll("#content a")).some((a) => a.textContent === "missing probe")`),
  );
  const flashed = await page.eval(`(async () => {
    const status = document.getElementById("status");
    window.__statuses = [];
    new MutationObserver(() => window.__statuses.push(status.hidden ? null : status.textContent))
      .observe(status, { attributes: true, childList: true, characterData: true, subtree: true });
    // The server answers some errors in plain text, such as a rejected Host header.
    const realFetch = window.fetch;
    window.fetch = async () => new Response("Forbidden", { status: 403 });
    Array.from(document.querySelectorAll("#content a")).find((a) => a.textContent === "missing probe").click();
    await new Promise((resolve) => setTimeout(resolve, 100));
    window.fetch = realFetch;
    return status.textContent;
  })()`);
  const flashedAt = Date.now();
  check("a plain-text error from the server is shown", flashed === "Could not open missing.md: Forbidden", flashed);

  // Neovim goes away without closing the preview -----------------------------

  nvim.kill("SIGKILL");
  const status = await waitFor(
    async () => {
      const text = await page.eval(`document.getElementById("status").textContent`);
      return text.includes("click to retry") && text;
    },
    { timeout: 30000, interval: 500 },
  );
  check("the tab stops reconnecting when Neovim is gone", status, status);
  // The error shown above disappears after 4 s, but must not hide the statuses that replaced it.
  await sleep(Math.max(0, 4500 - (Date.now() - flashedAt)));
  const statuses = await page.eval("window.__statuses");
  check("a message shown for a few seconds does not hide later ones", !statuses.includes(null), statuses);
} catch (err) {
  failures++;
  report(`ERROR ${err.stack}`);
} finally {
  // Cleaning up (a browser still writing to its profile folder) must not fail the tests.
  try {
    await page?.close();
    nvim?.kill("SIGKILL");
    launcher?.kill("SIGKILL");
    for (const path of [dir, launcherDir]) {
      if (path) rmSync(path, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    }
  } catch (err) {
    console.log(`warning: cleanup failed: ${err.message}`);
    if (process.env.GITHUB_ACTIONS) console.log(`::warning title=Browser tests::cleanup failed: ${err.message}`);
  }
}

const summary = failures === 0 ? "all checks passed" : `${failures} check(s) failed`;
console.log(`\n${summary}`);
if (process.env.GITHUB_ACTIONS) console.log(`::notice title=Browser tests::${summary}`);
process.exit(failures === 0 ? 0 : 1);
