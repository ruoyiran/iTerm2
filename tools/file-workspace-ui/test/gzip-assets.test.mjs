import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, access, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import {encodeAssets} from '../gzip-assets.mjs';

test('gzip packaging is deterministic, lossless and keeps logical URLs without retaining raw copies', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'iterm-gzip-'));
  const hash = data => createHash('sha256').update(data).digest('hex');
  try {
    const raw = Buffer.from('import "./child.js";\n'.repeat(500));
    const wasm = Buffer.concat([Buffer.from([0, 97, 115, 109]), Buffer.alloc(5000)]);
    const runs = [];
    for (const name of ['first', 'second']) {
      const dir = path.join(root, name);
      await mkdir(dir);
      await writeFile(path.join(dir, 'app.js'), raw);
      await writeFile(path.join(dir, 'engine.wasm'), wasm);
      await writeFile(path.join(dir, 'license.txt'), 'license unchanged');
      await writeFile(path.join(dir, 'tiny.js'), 'x');
      const records = await encodeAssets(dir, {'app.js': 'text/javascript', 'engine.wasm': 'application/wasm', 'license.txt': 'text/plain', 'tiny.js': 'text/javascript'});
      const js = records.find(record => record.path === 'app.js');
      assert.equal(js.storagePath, 'app.js.gz');
      assert.equal(js.encoding, 'gzip');
      const encoded = await readFile(path.join(dir, js.storagePath));
      assert.deepEqual(gunzipSync(encoded), raw);
      assert.equal(js.bytes, encoded.length);
      assert.equal(js.sha256, hash(encoded));
      assert.equal(js.decodedBytes, raw.length);
      assert.equal(js.decodedSHA256, hash(raw));
      assert.equal(records.find(record => record.path === 'engine.wasm').encoding, 'gzip');
      assert.equal(records.find(record => record.path === 'tiny.js').storagePath, 'tiny.js');
      assert.equal(await readFile(path.join(dir, 'license.txt'), 'utf8'), 'license unchanged');
      await assert.rejects(access(path.join(dir, 'app.js')));
      runs.push({records, encoded});
    }
    assert.deepEqual(runs[0], runs[1]);
  } finally {
    await rm(root, {recursive: true, force: true});
  }
});
