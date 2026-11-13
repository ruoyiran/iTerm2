import { Window } from "happy-dom";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { portablePlugin } from "../portable-build.mjs";
if (!globalThis.window) {
  globalThis.window = new Window();
  globalThis.document = window.document;
}
for (const key of [
  "Element",
  "HTMLElement",
  "HTMLInputElement",
  "SVGElement",
  "Node",
  "NodeFilter",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "ResizeObserver",
  "IntersectionObserver",
  "DOMRect",
  "DocumentFragment",
  "ShadowRoot",
])
  Object.defineProperty(globalThis, key, { configurable: true, get: () => window[key] });
globalThis.getComputedStyle = (...args) => window.getComputedStyle(...args);
globalThis.requestAnimationFrame = (callback) => window.requestAnimationFrame(callback);
globalThis.cancelAnimationFrame = (id) => window.cancelAnimationFrame(id);
const tooling = fileURLToPath(new URL("../", import.meta.url));
const source = path.resolve(tooling, "../../sources/FileWorkspace/Resources");
export const buildOptions = {
  define: { "process.env.NODE_ENV": '"production"' },
  bundle: true,
  write: false,
  format: "esm",
  platform: "browser",
  jsx: "automatic",
  loader: { ".css": "empty" },
  nodePaths: [path.join(tooling, "node_modules")],
  plugins: [portablePlugin(source, tooling)],
  logLevel: "silent",
};
export async function loadModule(url) {
  const result = await build({ ...buildOptions, entryPoints: [fileURLToPath(url)] });
  return import(
    "data:text/javascript;base64," + Buffer.from(result.outputFiles[0].text).toString("base64")
  );
}
