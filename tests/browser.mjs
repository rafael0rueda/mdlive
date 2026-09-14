// Browser tests: the preview page in headless Chrome, driven against a real
// Neovim. Run from the repository root with Node 22+ and Chrome or Chromium
// (set CHROME=/path/to/chrome if it is not on PATH):
//   node tests/browser.mjs
import { existsSync, readFileSync, rmSync } from "node:fs";
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
try {
  nvim = await startNeovim({ dir, file: "examples/demo.md" });
  page = await startChrome({ dir });
  await page.goto(nvim.url);

  // Rendering ----------------------------------------------------------------

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

  // Untrusted HTML -----------------------------------------------------------

  const lineCount = await nvim.lua("return vim.api.nvim_buf_line_count(0)");
  await nvim.lua(`vim.api.nvim_buf_set_lines(0, -1, -1, false, {
    "", '<img alt="probe" src="x" onerror="window.__xss = 1">',
    "", "<script>window.__xss = 2</script>",
    "", '<a href="javascript:window.__xss = 3">probe link</a>',
  })`);
  const probed = await waitFor(() => page.eval(`!!document.querySelector('img[alt="probe"]')`));
  await sleep(300);
  const xss = await page.eval(`({
    ran: window.__xss ?? null,
    handlers: document.querySelectorAll("#content [onerror]").length,
    scripts: document.querySelectorAll("#content script").length,
    href: Array.from(document.querySelectorAll("#content a")).find((a) => a.textContent === "probe link")?.getAttribute("href") ?? null,
  })`);
  check("renders raw HTML from the buffer", probed);
  check("scripts and event handlers in the buffer do not run", xss.ran === null && !xss.handlers && !xss.scripts, xss);
  check("javascript: links are removed", !xss.href?.startsWith("javascript:"), xss.href);
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

  // Export -------------------------------------------------------------------

  const exportPath = join(dir, "demo.html");
  await nvim.lua(`require("mdlive").export(0, { path = ${JSON.stringify(exportPath)} })`);
  const html = await waitFor(() => existsSync(exportPath) && readFileSync(exportPath, "utf8"), { timeout: 15000 });
  check(
    "export writes a standalone page",
    html && html.includes('class="katex"') && html.includes("<svg") && !html.includes("data-line") && !html.includes("<script"),
    html ? html.slice(0, 120) : html,
  );

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
} catch (err) {
  failures++;
  report(`ERROR ${err.stack}`);
} finally {
  // Cleaning up (a browser still writing to its profile folder) must not fail the tests.
  try {
    await page?.close();
    nvim?.kill("SIGKILL");
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  } catch (err) {
    console.log(`warning: cleanup failed: ${err.message}`);
    if (process.env.GITHUB_ACTIONS) console.log(`::warning title=Browser tests::cleanup failed: ${err.message}`);
  }
}

const summary = failures === 0 ? "all checks passed" : `${failures} check(s) failed`;
console.log(`\n${summary}`);
if (process.env.GITHUB_ACTIONS) console.log(`::notice title=Browser tests::${summary}`);
process.exit(failures === 0 ? 0 : 1);
