// Helpers for the browser tests and the README screenshot: a Neovim running
// mdlive, driven over its --listen socket, and a headless Chrome driven over the
// DevTools protocol. Needs Node 22+ (built-in WebSocket) and no packages.
import { execFile, spawn } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const tempDir = () => mkdtempSync(join(tmpdir(), "mdlive-"));

// Polls `predicate` until it returns a truthy value (returned) or time runs out.
export async function waitFor(predicate, { timeout = 10000, interval = 100 } = {}) {
  const end = Date.now() + timeout;
  let value;
  do {
    try {
      value = await predicate();
    } catch (_) {
      value = undefined;
    }
    if (value) return value;
    await sleep(interval);
  } while (Date.now() < end);
  return value;
}

// ------------------------------------------------------------------ neovim

// Starts Neovim with mdlive previewing `file`. `commands` run before the file is
// opened, for example to pick a colorscheme. `browser` is a Lua expression for
// the `browser` option; by default the preview URL is captured and returned as
// `nvim.url`, which a browser command would not let us see.
export async function startNeovim({ dir, file, commands = [], browser = null }) {
  const socket = join(dir, "nvim.sock");
  const args = ["--headless", "--clean", "--listen", socket, "--cmd", "set rtp^=. noswapfile lines=24 columns=100"];
  const option = browser ?? "function(url) vim.g.mdlive_url = url end";
  args.push("-c", `lua require("mdlive").setup({ browser = ${option} })`);
  for (const command of commands) args.push("-c", command);
  args.push("-c", `edit ${file}`, "-c", "MdLive");
  const proc = spawn("nvim", args, { stdio: "ignore" });
  let startError = null;
  proc.on("error", (err) => (startError = err));

  const nvim = {
    expr: async (expression) => (await exec("nvim", ["--server", socket, "--remote-expr", expression])).stdout,
    // Runs a Lua function body and returns its result (through JSON).
    lua: async (body) => {
      const code = `(function() local r = (function() ${body} end)() return vim.json.encode(r == nil and vim.NIL or r) end)()`;
      return JSON.parse(await nvim.expr(`luaeval(${JSON.stringify(code)})`));
    },
    keys: (keys) => exec("nvim", ["--server", socket, "--remote-send", keys]),
    kill: (signal = "SIGTERM") => proc.kill(signal),
  };

  // With a browser command there is no URL to wait for: the caller picks it up
  // from whatever that command does with it.
  const expression = browser ? "get(g:, 'mdlive_url', 'started')" : "get(g:, 'mdlive_url', '')";
  const url = await waitFor(async () => startError || (existsSync(socket) && (await nvim.expr(expression)).trim()));
  if (!url || startError) {
    proc.kill("SIGKILL");
    throw new Error(startError ? `Could not start Neovim: ${startError.message}` : "Neovim did not start the preview");
  }
  if (!browser) nvim.url = url;
  return nvim;
}

// ------------------------------------------------------------------ chrome

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const names = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome"];
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    for (const name of names) {
      if (existsSync(join(dir, name))) return join(dir, name);
    }
  }
  throw new Error("Chrome or Chromium not found; set CHROME=/path/to/chrome");
}

async function connect(url) {
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  let lastId = 0;
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    const call = pending.get(message.id);
    if (!call) return;
    pending.delete(message.id);
    if (message.error) call.reject(new Error(message.error.message));
    else call.resolve(message.result);
  });
  return {
    socket,
    send(method, params = {}) {
      const id = ++lastId;
      socket.send(JSON.stringify({ id, method, params }));
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    },
  };
}

// Starts headless Chrome and returns its page: eval(), goto(), screenshot(), close().
export async function startChrome({ dir, width = 1200, height = 800 }) {
  const proc = spawn(
    findChrome(),
    [
      "--headless=new",
      "--no-sandbox",
      "--no-first-run",
      "--no-default-browser-check",
      "--hide-scrollbars",
      "--remote-debugging-port=0",
      `--user-data-dir=${join(dir, "chrome")}`,
      "about:blank",
    ],
    // Its own process group, so close() can stop the helper processes as well.
    { stdio: ["ignore", "ignore", "pipe"], detached: true },
  );
  const endpoint = await new Promise((resolve, reject) => {
    let output = "";
    const timer = setTimeout(() => reject(new Error(`Chrome did not start: ${output}`)), 15000);
    proc.stderr.on("data", (chunk) => {
      output += chunk;
      const match = output.match(/DevTools listening on (ws:\/\/\S+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    proc.on("exit", (code) => reject(new Error(`Chrome exited with ${code}: ${output}`)));
    proc.on("error", (err) => reject(new Error(`Could not start Chrome: ${err.message}`)));
  });

  const { port } = new URL(endpoint);
  // The first page can join the target list a moment after DevTools starts listening.
  const target = await waitFor(async () => {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    return targets.find((t) => t.type === "page");
  });
  if (!target) throw new Error("Chrome has no page to drive");
  const cdp = await connect(target.webSocketDebuggerUrl);

  const page = {
    send: cdp.send,
    // Evaluates `expression` in the page, awaiting promises, and returns its value.
    async eval(expression) {
      const { result, exceptionDetails } = await cdp.send("Runtime.evaluate", {
        expression,
        awaitPromise: true,
        returnByValue: true,
      });
      if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
      return result.value;
    },
    async resize(w, h) {
      await cdp.send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false });
    },
    async goto(url) {
      await cdp.send("Page.navigate", { url });
      const loaded = await waitFor(() => page.eval(`location.href === ${JSON.stringify(url)} && document.readyState === "complete"`), {
        timeout: 15000,
      });
      if (!loaded) throw new Error(`${url} did not load`);
    },
    async screenshot(file) {
      // Right after a resize or navigation Chrome can still show a stale frame:
      // wait for the fonts and two painted frames first.
      await page.eval(`document.fonts.ready.then(() => new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve))))`);
      await sleep(100);
      const { data } = await cdp.send("Page.captureScreenshot", { format: "png" });
      writeFileSync(file, Buffer.from(data, "base64"));
    },
    // Stops Chrome and its helper processes, which otherwise keep writing to the
    // profile folder for a moment. Resolves once Chrome has exited, or after 5 seconds.
    close() {
      return new Promise((resolve) => {
        cdp.socket.close();
        const exited = proc.exitCode !== null || proc.signalCode !== null;
        const timer = exited ? null : setTimeout(resolve, 5000);
        if (!exited) {
          proc.once("exit", () => {
            clearTimeout(timer);
            resolve();
          });
        }
        try {
          process.kill(-proc.pid, "SIGTERM");
        } catch (_) {
          proc.kill();
        }
        if (exited) resolve();
      });
    },
  };
  await page.resize(width, height);
  return page;
}
