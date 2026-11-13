import path from "node:path";
import { readFileSync, existsSync } from "node:fs";
export function portablePlugin(source, tooling) {
  const mapping = JSON.parse(readFileSync(path.join(tooling, "portable-imports.json"), "utf8"));
  const vendor = path.join(source, "src/orca");
  return {
    name: "portable-orca",
    setup(build) {
      build.onResolve({ filter: /^pdfjs-dist(?:\/web\/pdf_viewer\.mjs)?$/ }, (args) => ({
        path: path.join(
          tooling,
          "node_modules/pdfjs-dist/legacy",
          args.path === "pdfjs-dist" ? "build/pdf.mjs" : "web/pdf_viewer.mjs",
        ),
      }));
      const polyfills = path.join(source, "src/portable/runtime-polyfills.js");
      build.onLoad({ filter: /\.worker\.[jt]s$/ }, (args) => ({
        contents: `import ${JSON.stringify(polyfills)};\n` + readFileSync(args.path, "utf8"),
        loader: args.path.endsWith(".ts") ? "ts" : "js",
        resolveDir: path.dirname(args.path),
      }));
      build.onResolve({ filter: /^react-dom\/server$/ }, () => ({
        path: path.join(
          tooling,
          "node_modules/react-dom/cjs/react-dom-server-legacy.browser.production.js",
        ),
      }));
      build.onResolve({ filter: /^(?:\.\/)?fonts\// }, (args) => ({
        path: args.path.includes("KaTeX")
          ? path.join(tooling, "node_modules/katex/dist", args.path)
          : path.join(source, "fonts", path.basename(args.path)),
      }));
      build.onResolve({ filter: /\?url$/ }, (args) => ({
        path: path.join(
          tooling,
          "node_modules",
          args.path.replace(/\?url$/, "").replace("pdfjs-dist/build/", "pdfjs-dist/legacy/build/"),
        ),
        namespace: "offline-asset",
      }));
      build.onLoad({ filter: /.*/, namespace: "offline-asset" }, (args) => ({
        contents: args.path.endsWith("pdf.worker.min.mjs")
          ? Buffer.concat([readFileSync(polyfills), readFileSync(args.path)])
          : readFileSync(args.path),
        loader: "file",
      }));
      build.onLoad({ filter: /.*/, namespace: "offline-url" }, (args) => {
        const file = path.join(tooling, "node_modules", args.path);
        return {
          contents: `import url from ${JSON.stringify(file)};export default url;`,
          loader: "js",
          resolveDir: tooling,
        };
      });
      build.onResolve({ filter: /\?worker$/ }, (args) => ({
        path: args.path,
        namespace: "offline-worker",
      }));
      build.onLoad({ filter: /.*/, namespace: "offline-worker" }, (args) => {
        const name = args.path.includes("/json/")
          ? "json"
          : args.path.includes("/css/")
            ? "css"
            : args.path.includes("/html/")
              ? "html"
              : args.path.includes("/typescript/")
                ? "ts"
                : "editor";
        return {
          contents: `export default class extends Worker {constructor(){super(new URL('./workers/${name}.worker.js',location.href),{type:'module'})}}`,
          loader: "js",
        };
      });
      build.onResolve({ filter: /^@\/|^\./ }, (args) => {
        let candidate = args.path.startsWith("@/")
          ? path.join(vendor, "src/renderer/src", args.path.slice(2))
          : path.resolve(args.resolveDir, args.path);
        const key = path.relative(vendor, candidate).replace(/\.(tsx?|mjs)$/, "");
        if (mapping[key]) return { path: path.join(source, "src/portable", mapping[key]) };
        if (args.path.startsWith("@/")) {
          const file = [
            candidate,
            candidate + ".ts",
            candidate + ".tsx",
            candidate + "/index.ts",
            candidate + "/index.tsx",
          ].find(existsSync);
          if (file) return { path: file };
        }
      });
    },
  };
}
