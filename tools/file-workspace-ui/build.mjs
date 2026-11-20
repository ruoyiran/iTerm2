import {writePackageNotices} from "./package-notices.mjs";
import {compactStylesheets} from "./compact-css.mjs";
import {stageOutput} from "./stage-output.mjs";
import {encodeAssets} from "./gzip-assets.mjs";
import { safariStyles } from "./safari-css.mjs";
import { execFileSync } from "node:child_process";
import { portablePlugin } from "./portable-build.mjs";
import "./patch-monaco.mjs";
import "./patch-orca-packages.mjs";
import { build } from "esbuild";
import { readFile, writeFile, readdir, mkdir, cp, rm, rename } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
const tooling = path.dirname(fileURLToPath(import.meta.url)),
  repo = path.resolve(tooling, "../..");
const source = path.join(repo, "sources/FileWorkspace/Resources"),
  target = path.join(source, "FileWorkspaceUI"),
  staging = target + ".staging";
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
async function files(dir) {
  const result = [];
  for (const entry of (await readdir(dir, { withFileTypes: true })).sort((a, b) =>
    a.name.localeCompare(b.name, "en"),
  )) {
    const p = path.join(dir, entry.name);
    if (entry.isSymbolicLink()) throw new Error("Symlink in build inputs");
    if (entry.isDirectory()) result.push(...(await files(p)));
    else result.push(p);
  }
  return result;
}
await rm(staging, { recursive: true, force: true });
await mkdir(staging, { recursive: true });
execFileSync(
  path.join(tooling, "node_modules/.bin/tailwindcss"),
  [
    "-i",
    path.join(tooling, "orca-style.css"),
    "-o",
    path.join(source, "css/orca-generated.css"),
    "--minify",
  ],
  { cwd: tooling, stdio: "pipe" },
);
stageOutput(repo, path.join(source, "css/orca-generated.css"));
const legacy = safariStyles(
  await readFile(path.join(source, "css/orca-generated.css"), "utf8"),
  await readFile(path.join(source, "src/orca/src/renderer/src/assets/main.css"), "utf8"),
);
for (const name of ["light", "dark"]) {
  const output = path.join(source, `css/orca-safari-${name}.css`);
  await writeFile(output, legacy[name]);
  stageOutput(repo, output);
}
const monaco = path.join(tooling, "node_modules/monaco-editor/esm/vs");
const bundle = await build({
  metafile: true,
  absWorkingDir: tooling,
  entryPoints: {
    "legacy-light": path.join(source, "css/orca-safari-light.css"),
    "legacy-dark": path.join(source, "css/orca-safari-dark.css"),
    "workers/markdown-preview": path.join(
      source,
      "src/orca/src/renderer/src/components/editor/markdown-preview/document-worker/markdown-preview-document.worker.ts",
    ),
    "workers/csv-preview": path.join(
      source,
      "src/orca/src/renderer/src/components/editor/csv/preview/worker/csv-preview.worker.ts",
    ),
    app: path.join(source, "src/bootstrap.mjs"),
    "workers/editor.worker": monaco + "/editor/editor.worker.js",
    "workers/json.worker": monaco + "/language/json/json.worker.js",
    "workers/css.worker": monaco + "/language/css/css.worker.js",
    "workers/html.worker": monaco + "/language/html/html.worker.js",
    "workers/ts.worker": monaco + "/language/typescript/ts.worker.js",
  },
  outdir: staging,
  entryNames: "[dir]/[name]",
  chunkNames: "chunks/[name]-[hash]",
  assetNames: "assets/[name]-[hash]",
  define: { "import.meta.env": '{"MODE":"production","PROD":true,"DEV":false,"SSR":false}' },
  bundle: true,
  splitting: true,
  format: "esm",
  target: "safari16",
  minify: true,
  sourcemap: false,
  legalComments: "linked",
  loader: {
    ".ttf": "file",
    ".woff2": "file",
    ".woff": "file",
    ".png": "file",
    ".gif": "file",
    ".svg": "file",
    ".wasm": "file",
  },
  jsx: "automatic",
  plugins: [portablePlugin(source, tooling)],
  nodePaths: [path.join(tooling, "node_modules")],
  logLevel: "warning",
});
writePackageNotices(bundle.metafile, tooling, path.join(source, "licenses/THIRD-PARTY-NOTICES.txt"));
if (process.env.FILE_UI_METAFILE)
  await writeFile(process.env.FILE_UI_METAFILE, JSON.stringify(bundle.metafile));
for (const name of ["cmaps", "standard_fonts", "wasm"])
  await cp(path.join(tooling, "node_modules/pdfjs-dist", name), path.join(staging, name), {
    recursive: true,
  });
// Font URLs in the source stylesheets are emitted under assets by esbuild.
for (const name of ["index.html", "icons", "licenses"])
  await cp(path.join(source, name), path.join(staging, name), { recursive: true });
await compactStylesheets(staging);
const mime = {
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
  ".mjs": "text/javascript; charset=utf-8",
  ".bcmap": "application/octet-stream",
  ".pfb": "application/octet-stream",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
};
const manifest = { version: 2, files: [], inputs: [] };
const mimeByPath = {};
for (const filename of await files(staging)) {
  mimeByPath[path.relative(staging, filename)] = mime[path.extname(filename)] ?? "application/octet-stream";
}
manifest.files = await encodeAssets(staging, mimeByPath);
const inputs = [
  path.join(source, "index.html"),
  ...(await files(path.join(source, "src"))),
  ...(await files(path.join(source, "css"))),
  ...(await files(path.join(source, "icons"))),
  ...(await files(path.join(source, "fonts"))),
  ...(await files(path.join(source, "licenses"))),
  ...[
    "package.json",
    "package-lock.json",
    "build.mjs",
    "compact-css.mjs",
    "stage-output.mjs",
    "gzip-assets.mjs",
    "package-notices.mjs",
    "patch-monaco.mjs",
    "patch-orca-packages.mjs",
    "patches/orca-packages.json",
    "portable-build.mjs",
    "portable-imports.json",
    "orca-style.css",
    "safari-css.mjs",
    "verify-resources.mjs",
    "verify-orca-provenance.mjs",
    "sync-orca-provenance.py",
    "patches/orca-local.patch.json",
    "patches/monaco-editor@0.55.1.patch",
  ].map((x) => path.join(tooling, x)),
];
for (const filename of inputs.sort()) {
  manifest.inputs.push({
    path: path.relative(repo, filename),
    sha256: hash(await readFile(filename)),
  });
}
await writeFile(path.join(staging, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
await rm(target, { recursive: true, force: true });
await rename(staging, target);
stageOutput(repo, target);
const inputLines = [
  "$(SRCROOT)/tools/verify_file_workspace_ui.py",
  "$(SRCROOT)/sources/FileWorkspace/Resources/FileWorkspaceUI/manifest.json",
  ...manifest.inputs.map((x) => "$(SRCROOT)/" + x.path),
  ...manifest.files.map(
    (x) => "$(SRCROOT)/sources/FileWorkspace/Resources/FileWorkspaceUI/" + x.storagePath,
  ),
];
await writeFile(path.join(tooling, "inputs.xcfilelist"), inputLines.join("\n") + "\n");
console.log(`Packaged ${manifest.files.length} offline file UI assets.`);
