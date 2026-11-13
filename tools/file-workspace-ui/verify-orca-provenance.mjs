import { readFile, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
const resources = new URL("../../sources/FileWorkspace/Resources/", import.meta.url);
const metadata = JSON.parse(
  await readFile(new URL("licenses/Orca-SOURCE-PROVENANCE.json", resources), "utf8"),
);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
async function walk(directory, prefix = "") {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const name = prefix + entry.name;
    if (entry.isDirectory())
      result.push(...(await walk(new URL(entry.name + "/", directory), name + "/")));
    else result.push(name);
  }
  return result.sort();
}
const vendor = new URL("src/orca/", resources);
const paths = await walk(vendor);
if (JSON.stringify(paths) !== JSON.stringify(metadata.files.map((file) => file.path).sort()))
  throw new Error("Orca source inventory differs from provenance");
for (const file of metadata.files)
  if (hash(await readFile(new URL(file.path, vendor))) !== file.sha256)
    throw new Error("Modified Orca source needs provenance update: " + file.path);
if (
  hash(await readFile(new URL("src/portable/orca-locales.json", resources))) !==
  metadata.localeSubsetSHA256
)
  throw new Error("Orca locale provenance mismatch");
console.log(
  `Verified ${metadata.files.length} pinned Orca source files and ${metadata.locales.length} locale subsets.`,
);
