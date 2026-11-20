import {readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';

// Keep each emitted CSS entry URL. @import preserves its position in the
// cascade, while duplicate bodies share one file with the same URL base.
export async function compactStylesheets(directory) {
  const canonical = new Map();
  for (const entry of (await readdir(directory, {withFileTypes: true})).sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
    const filename = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      await compactStylesheets(filename);
    } else if (entry.isFile() && entry.name.endsWith('.css')) {
      const css = await readFile(filename, 'utf8');
      if (/^@import url\("[^"\n]+"\);\n$/.test(css)) continue;
      const first = canonical.get(css);
      if (first) {
        const imported = JSON.stringify('./' + first);
        const replacement = `@import url(${imported});\n`;
        if (replacement.length < css.length) await writeFile(filename, replacement);
      } else {
        canonical.set(css, entry.name);
      }
    }
  }
}
