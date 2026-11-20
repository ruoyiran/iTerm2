import {readFile, writeFile, unlink} from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';

const extensions = new Set(['.js', '.mjs', '.css', '.json', '.html', '.wasm']);
const hash = data => createHash('sha256').update(data).digest('hex');

export async function encodeAssets(directory, mimeByPath) {
  const records = [];
  for (const logical of Object.keys(mimeByPath).sort()) {
    const filename = path.join(directory, logical);
    const raw = await readFile(filename);
    const compressed = extensions.has(path.extname(logical)) ? gzipSync(raw, {level: 9, mtime: 0}) : null;
    const encoded = compressed && compressed.length < raw.length;
    const storagePath = encoded ? logical + '.gz' : logical;
    if (encoded && Object.hasOwn(mimeByPath, storagePath)) throw new Error('Gzip storage path collision: ' + storagePath);
    const data = encoded ? compressed : raw;
    if (encoded) {
      await writeFile(path.join(directory, storagePath), data, {flag: 'wx'});
      await unlink(filename);
    }
    records.push({path: logical, storagePath, bytes: data.length, sha256: hash(data), mime: mimeByPath[logical],
      ...(encoded ? {encoding: 'gzip', decodedBytes: raw.length, decodedSHA256: hash(raw)} : {})});
  }
  return records;
}
