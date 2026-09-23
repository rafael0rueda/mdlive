// The browser libraries in app/vendor, rebuilt from their npm packages and
// checked against scripts/vendor.json. Run from the repository root with
// Node 22+ and no packages:
//   node scripts/vendor.mjs check                    no network: app/vendor matches the recorded hashes
//   node scripts/vendor.mjs fetch                    downloads the pinned packages and rewrites app/vendor
//   node scripts/vendor.mjs update <name> <version>  pins a new version, then fetches
//
// Each package is pinned by version and by the integrity hash npm publishes for
// its tarball, so a fetch writes the same bytes every time. The SHA-256 of every
// file it writes is recorded in vendor.json, which is what `check` compares.
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { gunzipSync } from "node:zlib";

const manifestPath = "scripts/vendor.json";
const vendorDir = "app/vendor";
const registry = "https://registry.npmjs.org";

const readManifest = () => JSON.parse(readFileSync(manifestPath, "utf8"));
const writeManifest = (manifest) => writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
const sha256 = (data) => createHash("sha256").update(data).digest("hex");

function fail(message) {
  console.error(`vendor: ${message}`);
  process.exit(1);
}

// Every file under `dir`, as paths relative to it with forward slashes.
function listFiles(dir, base = dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? listFiles(path, base) : [relative(base, path).split(sep).join("/")];
  });
}

// ------------------------------------------------------------------ check

function check() {
  const manifest = readManifest();
  const problems = [];
  const expected = new Map(Object.entries(manifest.sha256));
  for (const file of listFiles(vendorDir)) {
    const hash = expected.get(file);
    if (hash === undefined) problems.push(`${file} is not from a package in ${manifestPath}`);
    else if (sha256(readFileSync(join(vendorDir, file))) !== hash) problems.push(`${file} differs from its package`);
    expected.delete(file);
  }
  for (const file of expected.keys()) problems.push(`${file} is missing`);

  // The README lists every library with the version that is bundled.
  const readme = readFileSync("README.md", "utf8");
  for (const pkg of manifest.packages) {
    const row = readme.match(new RegExp(`^\\|\\s*${pkg.readme.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\|\\s*(\\S+)`, "m"));
    if (!row) problems.push(`README.md has no row for ${pkg.readme} in its bundled libraries table`);
    else if (row[1] !== pkg.version) problems.push(`README.md lists ${pkg.readme} ${row[1]}, ${manifestPath} ${pkg.version}`);
  }

  if (problems.length > 0) {
    for (const problem of problems) console.error(`FAIL ${problem}`);
    fail(`\`make vendor\` rebuilds app/vendor from ${manifestPath}; the README table is edited by hand`);
  }
  console.log(`app/vendor matches ${manifestPath}: ${Object.keys(manifest.sha256).length} files`);
}

// ------------------------------------------------------------------ fetch

const tarballUrl = (pkg) => `${registry}/${pkg.name}/-/${pkg.name.split("/").pop()}-${pkg.version}.tgz`;

async function download(url) {
  const response = await fetch(url);
  if (!response.ok) fail(`${url}: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

// The files of a .tgz as a Map of path -> contents, with the leading
// "package/" that npm puts on every path removed.
function untar(tgz) {
  const tar = gunzipSync(tgz);
  const files = new Map();
  const field = (header, start, length) => header.subarray(start, start + length).toString("utf8").replace(/\0.*$/s, "");
  let longName = null;
  for (let offset = 0; offset + 512 <= tar.length; ) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const size = parseInt(field(header, 124, 12).trim() || "0", 8);
    const type = String.fromCharCode(header[156] || 48);
    const data = tar.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === "x") {
      // A pax header: its path= record replaces the next entry's name.
      const path = data.toString("utf8").match(/^\d+ path=(.*)$/m);
      if (path) longName = path[1];
      continue;
    }
    if (type === "L") {
      longName = data.toString("utf8").replace(/\0.*$/s, "");
      continue;
    }
    const prefix = field(header, 345, 155);
    const name = longName ?? (prefix ? `${prefix}/${field(header, 0, 100)}` : field(header, 0, 100));
    longName = null;
    if (type === "0" || type === "\0") files.set(name.replace(/^[^/]+\//, ""), Buffer.from(data));
  }
  return files;
}

// The files a package puts in app/vendor, as a Map of vendor path -> contents.
// A source ending in "/" copies every file in that directory of the package.
function select(pkg, files) {
  const out = new Map();
  for (const [source, target] of Object.entries(pkg.files)) {
    const matches = source.endsWith("/")
      ? [...files.keys()].filter((path) => path.startsWith(source) && !path.slice(source.length).includes("/"))
      : files.has(source)
        ? [source]
        : [];
    if (matches.length === 0) fail(`${pkg.name}@${pkg.version} has no ${source}`);
    for (const path of matches) out.set(source.endsWith("/") ? target + path.slice(source.length) : target, files.get(path));
  }
  return out;
}

async function fetchAll() {
  const manifest = readManifest();
  const output = new Map();
  for (const pkg of manifest.packages) {
    const tgz = await download(tarballUrl(pkg));
    const integrity = `sha512-${createHash("sha512").update(tgz).digest("base64")}`;
    if (integrity !== pkg.integrity) fail(`${pkg.name}@${pkg.version}: the tarball's integrity is ${integrity}, not ${pkg.integrity}`);
    const files = select(pkg, untar(tgz));
    for (const [path, data] of files) {
      if (output.has(path)) fail(`${path} comes from two packages`);
      output.set(path, data);
    }
    console.log(`${pkg.name}@${pkg.version}: ${files.size} file${files.size === 1 ? "" : "s"}`);
  }

  for (const file of listFiles(vendorDir)) {
    if (!output.has(file)) {
      rmSync(join(vendorDir, file));
      console.log(`removed ${file}, which no package provides`);
    }
  }
  const hashes = {};
  for (const path of [...output.keys()].sort()) {
    const target = join(vendorDir, path);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, output.get(path));
    hashes[path] = sha256(output.get(path));
  }
  manifest.sha256 = hashes;
  writeManifest(manifest);
  console.log(`wrote ${output.size} files to app/vendor`);
}

// ------------------------------------------------------------------ update

async function update(name, version) {
  if (!name || !version) fail("usage: node scripts/vendor.mjs update <name> <version>");
  const manifest = readManifest();
  const pkg = manifest.packages.find((p) => p.name === name);
  if (!pkg) fail(`${name} is not in ${manifestPath}: ${manifest.packages.map((p) => p.name).join(", ")}`);
  const response = await fetch(`${registry}/${name}/${version}`);
  if (!response.ok) fail(`${name}@${version} is not on npm (HTTP ${response.status})`);
  const { dist } = await response.json();
  pkg.version = version;
  pkg.integrity = dist.integrity;
  writeManifest(manifest);
  console.log(`pinned ${name}@${version}`);
  await fetchAll();
  console.log(`Update the version of ${pkg.readme} in the README's bundled libraries table, and check its license.`);
}

const [command, ...args] = process.argv.slice(2);
if (command === "check") check();
else if (command === "fetch") await fetchAll();
else if (command === "update") await update(...args);
else fail("usage: node scripts/vendor.mjs check | fetch | update <name> <version>");
