import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {compactStylesheets} from '../compact-css.mjs';
import http from 'node:http';
import {chromium} from 'playwright';

test('duplicate CSS keeps every entry URL and imports a canonical file in the same directory', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'iterm-css-'));
  try {
    await mkdir(path.join(root, 'chunks'));
    const css = '.editor { color: red; background: url("../assets/pixel.png"); }';
    await writeFile(path.join(root, 'chunks/a.css'), css);
    await writeFile(path.join(root, 'chunks/b.css'), css);
    await writeFile(path.join(root, 'chunks/c.css'), '.editor { color: blue; }');
    await writeFile(path.join(root, 'root.css'), css);
    await compactStylesheets(root);
    assert.equal(await readFile(path.join(root, 'chunks/a.css'), 'utf8'), css);
    assert.equal(await readFile(path.join(root, 'chunks/b.css'), 'utf8'), '@import url("./a.css");\n');
    assert.equal(await readFile(path.join(root, 'chunks/c.css'), 'utf8'), '.editor { color: blue; }');
    assert.equal(await readFile(path.join(root, 'root.css'), 'utf8'), css,
      'identical text in another directory has different relative asset URLs');
    await compactStylesheets(root);
    assert.equal(await readFile(path.join(root, 'chunks/b.css'), 'utf8'), '@import url("./a.css");\n');
  } finally {
    await rm(root, {recursive: true, force: true});
  }
});

test('repeated compaction does not build import chains through shorter entry names', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'iterm-css-repeat-'));
  try {
    const css = '.editor { color: red; }'.repeat(20);
    for (const name of ['a-long-canonical-stylesheet.css', 'b.css', 'c.css']) {
      await writeFile(path.join(root, name), css);
    }
    await compactStylesheets(root);
    const before = await readFile(path.join(root, 'c.css'), 'utf8');
    await compactStylesheets(root);
    assert.equal(await readFile(path.join(root, 'c.css'), 'utf8'), before);
  } finally {
    await rm(root, {recursive: true, force: true});
  }
});

test('a compacted stylesheet retains its cascade position and relative asset URLs in a browser', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'iterm-css-browser-'));
  const server = http.createServer(async (request, response) => {
    try {
      const file = path.join(root, request.url);
      response.setHeader('Content-Type', file.endsWith('.css') ? 'text/css' : file.endsWith('.svg') ? 'image/svg+xml' : 'text/html');
      response.end(await readFile(file));
    } catch {
      response.statusCode = 404;
      response.end();
    }
  });
  let browser;
  const requests = [];
  try {
    await mkdir(path.join(root, 'chunks'));
    await mkdir(path.join(root, 'assets'));
    const css = '.sample { color: rgb(255, 0, 0); background-image: url("../assets/pixel.svg"); }';
    for (const name of ['a.css', 'b.css']) await writeFile(path.join(root, 'chunks', name), css);
    await writeFile(path.join(root, 'override.css'), '.sample { color: rgb(0, 0, 255); }');
    await writeFile(path.join(root, 'assets/pixel.svg'), '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>');
    await writeFile(path.join(root, 'index.html'), '<link rel="stylesheet" href="./chunks/b.css"><link rel="stylesheet" href="./override.css"><div class="sample">sample</div>');
    await compactStylesheets(root);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    browser = await chromium.launch({headless: true});
    const page = await browser.newPage();
    page.on('request', request => requests.push(new URL(request.url()).pathname));
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`, {waitUntil: 'networkidle'});
    assert.equal(await page.locator('.sample').evaluate(element => getComputedStyle(element).color), 'rgb(0, 0, 255)');
    assert.ok(requests.includes('/chunks/a.css'));
    assert.ok(requests.includes('/assets/pixel.svg'));
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
    await rm(root, {recursive: true, force: true});
  }
});
