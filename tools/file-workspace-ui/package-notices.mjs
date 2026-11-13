import { readFileSync, readdirSync, existsSync, writeFileSync } from "node:fs";
import path from "node:path";
export function writePackageNotices(metafile, tooling, destination) {
  const packages = new Map();
  for (let name of Object.keys(metafile.inputs)) {
    name = name.replace(/^offline-asset:/, "");
    if (!name.includes("node_modules/")) continue;
    let directory = path.dirname(path.resolve(tooling, name));
    while (directory !== tooling && directory !== path.dirname(directory)) {
      const manifest = path.join(directory, "package.json");
      if (existsSync(manifest)) {
        const data = JSON.parse(readFileSync(manifest, "utf8"));
        if (data.name && data.version) {
          packages.set(data.name + "@" + data.version, { directory, data });
          break;
        }
      }
      directory = path.dirname(directory);
    }
  }
  const notices = [
    "Third-party notices for packages included in the offline file workspace bundle.\nSupplementary notices are distributed beside this file.",
  ];
  for (const [name, { directory, data }] of [...packages].sort(([a], [b]) =>
    a.localeCompare(b, "en"),
  )) {
    notices.push(`\n${name}\nLicense: ${data.license ?? "See bundled source notice"}`);
    for (const filename of readdirSync(directory).sort()) {
      if (!/^(licen[sc]e|copying|notice|copyright)(\.|$)/i.test(filename)) continue;
      try {
        notices.push(filename + "\n" + readFileSync(path.join(directory, filename), "utf8"));
      } catch {}
    }
  }
  writeFileSync(destination, notices.join("\n") + "\n");
}
