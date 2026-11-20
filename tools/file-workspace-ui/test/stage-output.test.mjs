import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import {stageOutput} from '../stage-output.mjs';

test('generated files are staged only in their own repository, never an ignored build copy in a parent repository', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'iterm-stage-'));
  try {
    execFileSync('git', ['init', '--quiet', root]);
    await writeFile(path.join(root, '.gitignore'), 'cache/\n');
    const own = path.join(root, 'generated.js');
    await writeFile(own, 'export default 1;');
    assert.equal(stageOutput(root, own), true);
    const copy = path.join(root, 'cache/source');
    await mkdir(copy, {recursive: true});
    const copied = path.join(copy, 'generated.js');
    await writeFile(copied, 'export default 2;');
    assert.equal(stageOutput(copy, copied), false);
    assert.equal(execFileSync('git', ['diff', '--cached', '--name-only'], {cwd: root, encoding: 'utf8'}).trim(), 'generated.js');
  } finally {
    await rm(root, {recursive: true, force: true});
  }
});
