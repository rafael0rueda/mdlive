// Makes the README screenshot: examples/demo.md in Neovim next to its preview.
// Run from the repository root with Node 22+ and Chrome or Chromium:
//   node scripts/screenshot.mjs [docs/screenshot.png]
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { sleep, startChrome, startNeovim, tempDir, waitFor } from "../tests/harness.mjs";

const output = resolve(process.argv[2] || "docs/screenshot.png");
const height = 860;
const editorWidth = 720;
const previewWidth = 880;
const dir = tempDir();

let nvim;
let page;
try {
  nvim = await startNeovim({ dir, file: "examples/demo.md", commands: ["set termguicolors background=dark", "colorscheme default"] });
  page = await startChrome({ dir });

  // Neovim side: the buffer with its highlighting, rendered to HTML by Neovim itself.
  const editorHtml = join(dir, "editor.html");
  await nvim.lua(`
    vim.cmd("packadd nvim.tohtml")
    local lines = require("tohtml").tohtml(0, { number_lines = true })
    vim.fn.writefile(lines, ${JSON.stringify(editorHtml)})`);
  writeFileSync(
    editorHtml,
    readFileSync(editorHtml, "utf8").replace(
      "</head>",
      "<style>body { margin: 0; padding: 20px 8px; } pre { font: 14px/1.6 ui-monospace, 'JetBrains Mono', monospace; }</style></head>",
    ),
  );
  await page.resize(editorWidth, height);
  await page.goto(pathToFileURL(editorHtml).href);
  const editorShot = join(dir, "editor.png");
  await page.screenshot(editorShot);

  // Preview side, once the diagram and math are drawn.
  await page.resize(previewWidth, height);
  await page.goto(nvim.url);
  await waitFor(() => page.eval(`!!document.querySelector(".mermaid-block svg") && !!document.querySelector(".katex")`), {
    timeout: 20000,
  });
  await sleep(500);
  const previewShot = join(dir, "preview.png");
  await page.screenshot(previewShot);

  // Both side by side, joined by Chrome so no image tools are needed.
  const image = (file) => `data:image/png;base64,${readFileSync(file).toString("base64")}`;
  const composeHtml = join(dir, "compose.html");
  writeFileSync(
    composeHtml,
    `<!doctype html><body style="margin:0;display:flex;background:#4f5258;gap:2px">
      <img src="${image(editorShot)}" width="${editorWidth}" height="${height}">
      <img src="${image(previewShot)}" width="${previewWidth}" height="${height}">
    </body>`,
  );
  await page.resize(editorWidth + previewWidth + 2, height);
  await page.goto(pathToFileURL(composeHtml).href);
  await page.screenshot(output);
  console.log(`wrote ${output}`);
} finally {
  await page?.close();
  nvim?.kill("SIGKILL");
  rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
