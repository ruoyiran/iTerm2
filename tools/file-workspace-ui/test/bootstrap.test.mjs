import test from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {buildOptions} from './module-loader.mjs';
import {Window} from 'happy-dom';
import {fileURLToPath} from 'node:url';

// Execute the production bootstrap, bridge and Explorer together. Only the native
// postMessage boundary and browser DOM are supplied here; no editor is requested.
const bootstrap = await build({...buildOptions,
  entryPoints: [fileURLToPath(new URL('../../../sources/FileWorkspace/Resources/src/bootstrap.mjs', import.meta.url))],
  bundle: true, write: false, format: 'esm', platform: 'browser',
  loader: {'.css': 'empty'}, external: ['./editor.mjs'], logLevel: 'silent'
});

test('configure fences retained actions before the new context arrives and preserves owner caches', async () => {
  const w = new Window();
  globalThis.window = w;globalThis.matchMedia=w.matchMedia.bind(w);globalThis.CSS=w.CSS; globalThis.document = w.document;
  const root = document.createElement('div'); root.id = 'workspace'; document.body.append(root);
  const sent = [];
  w.webkit = {messageHandlers: {fileWorkspace: {postMessage: message => sent.push(message)}}};
  await import('data:text/javascript;base64,' + Buffer.from(bootstrap.outputFiles[0].text).toString('base64'));
  let generation = 0;
  const fence = label => ({protocolVersion: 1, rendererEpoch: label, viewIdentifier: 'same-explorer', contextToken: label, generation: String(++generation)});
  const receive = (identity, type, payload, requestIdentifier = type) => w.fileWorkspace.receive({...identity, type, payload, requestIdentifier});
  const configure = identity => receive(identity, 'configure', {purpose: 'explorer', labels: {}});
  const context = (identity, project) => receive(identity, 'context', {token: identity.contextToken, rootDirectory: '/same', projectIdentifier: project, worktreeIdentifier: project + '-tree', title: project});
  const entries = [{path: '/same/nested', relativePath: 'nested', name: 'nested', isDirectory: true, isExpandable: true}, {path: '/same/item.txt', relativePath: 'item.txt', name: 'item.txt', isDirectory: false}];
  const listing = async (identity, path, values) => {
    const request = sent.findLast(m => m.type === 'listDirectory' && m.contextToken === identity.contextToken && m.payload.directoryPath === path);
    assert.ok(request, 'actual explorer requested directory ' + path);
    await receive(identity, 'listing', {token: identity.contextToken, directoryPath: path, requestIdentifier: request.requestIdentifier, entries: values});
  };
  const menu = target => target.dispatchEvent(new w.MouseEvent('contextmenu', {bubbles: true, cancelable: true}));
  const mutations = messages => messages.filter(m => ['createFile', 'createFolder', 'trash', 'openFile', 'rename', 'move'].includes(m.type));
  try {
    const a = fence('A'); await configure(a); await context(a, 'owner-A'); await listing(a, '/same', entries);
    root.querySelector('[data-path="/same/nested"]').click();
    await listing(a, '/same/nested', [{path: '/same/nested/child.txt', relativePath: 'nested/child.txt', name: 'child.txt', isDirectory: false}]);
    menu(root.querySelector('.tree-viewport')); root.querySelector('[role="menuitem"][aria-label="newFile"]').click();
    const oldForm = root.querySelector('.inline-input'); oldForm.querySelector('input').value = 'created-under-A.txt';
    const oldRow = root.querySelector('[data-path="/same/item.txt"]'); menu(oldRow);
    const oldTrash = root.querySelector('[role="menuitem"][aria-label="trash"]');
    const oldNewFolder = root.querySelector('[role="menuitem"][aria-label="newFolder"]');
    const query = root.querySelector('[data-query="names"]'); query.value = 'remembered-query'; query.dispatchEvent(new w.Event('input', {bubbles: true}));

    const b = fence('B'); await configure(b);
    assert.ok(sent.some(m => m.type === 'ready' && m.contextToken === 'B'));
    // Native has adopted B, but deliberately withhold its context response. Paths
    // remain identical, so a retagged A action would pass native path validation.
    const before = sent.length;
    oldForm.dispatchEvent(new w.Event('submit', {bubbles: true, cancelable: true})); oldTrash.click(); oldNewFolder.click(); oldRow.click();
    root.querySelector('.tree-viewport').dispatchEvent(new w.KeyboardEvent('keydown', {key: 'Delete', bubbles: true, cancelable: true}));
    await context(a, 'owner-A'); // A stale native response must not resume actions.
    oldTrash.click();
    assert.deepEqual(mutations(sent.slice(before)), []);
    assert.equal(root.inert, true);
    assert.equal(root.querySelector('.inline-input'), null); assert.equal(root.querySelector('.context-menu'), null);

    await context(b, 'owner-B'); await listing(b, '/same', entries);
    assert.equal(root.inert, false);
    assert.equal(root.querySelector('[data-query="names"]').value, '');
    menu(root.querySelector('.tree-viewport')); root.querySelector('[role="menuitem"][aria-label="newFile"]').click();
    const newForm = root.querySelector('.inline-input'); newForm.querySelector('input').value = 'created-under-B.txt';
    newForm.dispatchEvent(new w.Event('submit', {bubbles: true, cancelable: true}));
    const created = sent.findLast(m => m.type === 'createFile');
    assert.equal(created.rendererEpoch, 'B'); assert.equal(created.contextToken, 'B');
    assert.equal(created.payload.directoryPath, '/same'); assert.equal(created.payload.name, 'created-under-B.txt');

    const restored = fence('A-restored'); await configure(restored); await context(restored, 'owner-A');
    assert.equal(root.querySelector('[data-query="names"]').value, 'remembered-query');
    await listing(restored, '/same', entries);
    await listing(restored, '/same/nested', [{path: '/same/nested/child.txt', relativePath: 'nested/child.txt', name: 'child.txt', isDirectory: false}]);
    root.querySelector('[data-query="names"]').dispatchEvent(new w.KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
    assert.ok(root.querySelector('[data-path="/same/nested/child.txt"]'), 'retained expansion survives the configure/context round trip');
  } finally { await w.happyDOM.abort(); }
});
