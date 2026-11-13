import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("./", import.meta.url));
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
for (const record of JSON.parse(readFileSync(root + "patches/orca-packages.json", "utf8"))) {
  const directory = root + "node_modules/" + record.name;
  if (
    JSON.parse(readFileSync(directory + "/package.json")).version !== record.version ||
    hash(record.patch) !== record.upstreamSHA256
  )
    throw new Error("Unexpected Orca package or patch: " + record.name);
  const current = record.files.map((file) => hash(readFileSync(directory + "/" + file.path)));
  if (record.files.every((file, index) => current[index] === file.before))
    execFileSync("/usr/bin/patch", ["-p1", "--forward"], {
      cwd: directory,
      input: record.patch + record.legacyPatch,
    });
  for (const file of record.files)
    if (hash(readFileSync(directory + "/" + file.path)) !== file.after)
      throw new Error("Orca package patch verification failed: " + record.name + "/" + file.path);
}
