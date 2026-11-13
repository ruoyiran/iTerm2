import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { chromium } from "playwright";
const assets = fileURLToPath(
  new URL("../../../sources/FileWorkspace/Resources/FileWorkspaceUI/", import.meta.url),
);
test("document presentation, explicit focus and same-view replacement follow document readiness", async (t) => {
  const server = http.createServer(async (req, res) => {
    try {
      const file = path.join(assets, req.url.split("?")[0]);
      if (!file.startsWith(assets)) throw Error();
      res.setHeader(
        "Content-Type",
        /\.m?js$/.test(file)
          ? "text/javascript"
          : file.endsWith(".css")
            ? "text/css"
            : file.endsWith(".html")
              ? "text/html"
              : "application/octet-stream",
      );
      res.end(await readFile(file));
    } catch {
      res.statusCode = 404;
      res.end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(() => {
      window.sent = [];
      window.identity = {
        protocolVersion: 1,
        rendererEpoch: "lifecycle",
        viewIdentifier: "v",
        contextToken: "c",
        generation: "1",
      };
      window.send = (type, payload = {}) =>
        window.fileWorkspace.receive({
          ...window.identity,
          type,
          payload,
          requestIdentifier: crypto.randomUUID(),
        });
      window.webkit = {
        messageHandlers: {
          fileWorkspace: {
            postMessage: (message) => {
              window.sent.push(message);
              if (message.type === "hostRequest")
                queueMicrotask(() =>
                  window.fileWorkspace.receive({
                    ...window.identity,
                    type: "hostResult",
                    requestIdentifier: message.requestIdentifier,
                    payload: { result: message.payload.operation === "settings" ? {} : [] },
                  }),
                );
            },
          },
        },
      };
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    const configure = () => page.evaluate(() => send("configure", { purpose: "editor" }));
    const ready = (id) =>
      page.waitForFunction(
        (id) =>
          sent.some(
            (m) => m.type === "status" && m.payload.documentIdentifier === id && m.payload.isReady,
          ),
        id,
      );
    const snapshot = (id, kind, text) => ({
      documentIdentifier: id,
      filePath: "/repo/" + id + (kind === 1 ? ".md" : kind === 7 ? ".csv" : ".txt"),
      rootDirectory: "/repo",
      text,
      kind,
      revision: "1",
      isReadOnly: false,
      isDirty: false,
    });
    await t.test(
      "streamed Markdown keeps source mode, document-scoped view state, and later reveal",
      async () => {
        await configure();
        const text =
          "# Title\n" +
          Array.from({ length: 6000 }, (_, i) => `line ${i}: ${"text ".repeat(10)}\n`).join("");
        await page.evaluate(
          async ({ snapshot, text }) => {
            const total = Math.ceil(text.length / 131072);
            await send("documentStart", { transferIdentifier: "stream", snapshot, total });
            await send("restoreViewState", {
              viewMode: "source",
              selectionStartLine: 1,
              selectionStartColumn: 2,
              selectionEndLine: 1,
              selectionEndColumn: 2,
              scrollTop: 180,
              viewerState: { tableOfContents: true, frontmatterVisible: false },
            });
            await send("viewFlags", { viewMode: "source" });
            await send("reveal", { lineNumber: 50, utf16Column: 4 });
            for (let index = 0; index < total; index++)
              await send("documentText", {
                transferIdentifier: "stream",
                index,
                text: text.slice(index * 131072, (index + 1) * 131072),
              });
            await send("documentEnd", { transferIdentifier: "stream" });
          },
          { snapshot: snapshot("streamed", 1, ""), text },
        );
        await ready("streamed");
        assert.equal(
          await page.locator("[data-orca-view]").getAttribute("data-orca-view"),
          "source",
        );
        await page.evaluate(() => send("flush", { suspend: false }));
        const state = await page.evaluate(
          () => sent.findLast((m) => m.type === "viewState").payload,
        );
        assert.equal(state.selectionStartLine, 50);
        assert.equal(state.selectionStartColumn, 4);
        assert.equal(state.viewerState.tableOfContents, true);
        assert.equal(state.viewerState.frontmatterVisible, false);
        assert.ok(state.scrollTop > 0);
      },
    );
    await t.test("presentation preceding delayed document delivery is retained", async () => {
      await configure();
      await page.evaluate(
        async (snapshot) => {
          await send("restoreViewState", {
            viewMode: "preview",
            viewerState: { tableOfContents: true, frontmatterVisible: false },
          });
          await send("viewFlags", { viewMode: "preview" });
          await send("document", { snapshot });
        },
        snapshot("delayed", 1, "# Delayed title\n\nBody"),
      );
      await ready("delayed");
      assert.equal(
        await page.locator("[data-orca-view]").getAttribute("data-orca-view"),
        "preview",
      );
      await page.evaluate(() => send("flush", { suspend: false }));
      const state = await page.evaluate(() => sent.findLast((m) => m.type === "viewState").payload);
      assert.equal(state.viewerState.tableOfContents, true);
      assert.equal(state.viewerState.frontmatterVisible, false);
    });
    await t.test(
      "initial explicit source and rich focus waits for mount; cancellation and revocation prevent late focus",
      async () => {
        for (const [id, kind, cancel] of [
          ["source-focus", 0, null],
          ["rich-focus", 1, null],
          ["cancelled-focus", 0, "cancelFocus"],
          ["cancelled-rich-focus", 1, "cancelFocus"],
          ["revoked-focus", 0, "revoke"],
          ["revoked-rich-focus", 1, "revoke"],
          ["context-focus", 0, "context"],
        ]) {
          await configure();
          await page.evaluate(
            async ({ snapshot, cancel }) => {
              const loading = send("document", { snapshot });
              await send("focus");
              if (cancel === "cancelFocus") await send("cancelFocus");
              if (cancel === "revoke") await send("editAuthority", { granted: false });
              if (cancel === "context") await send("context", {});
              await loading;
            },
            {
              snapshot: snapshot(id, kind, kind === 1 ? "# Heading\n\nParagraph" : "hello"),
              cancel,
            },
          );
          await ready(id);
          const focused = await page.evaluate(
            () => !!document.activeElement?.closest(".monaco-editor,.tiptap"),
          );
          assert.equal(focused, !cancel, id);
        }
      },
    );
    await t.test(
      "same-view CSV and rich replacements report readiness and focus for their own identity",
      async () => {
        await configure();
        for (const id of ["csv1", "csv2"]) {
          await page.evaluate(
            (snapshot) => send("document", { snapshot }),
            snapshot(id, 7, "name,value\n" + id + ",2\n"),
          );
          await page.getByText(id, { exact: true }).waitFor();
          await ready(id);
          assert.equal(
            await page.evaluate(
              () => sent.findLast((m) => m.type === "status").payload.documentIdentifier,
            ),
            id,
          );
        }
        await configure();
        await page.evaluate(
          (snapshot) => send("document", { snapshot }),
          snapshot("rich1", 1, "# First document"),
        );
        await ready("rich1");
        await page.evaluate(
          async (snapshot) => {
            const loaded = send("document", { snapshot });
            await send("focus");
            await loaded;
          },
          snapshot("rich2", 1, "# Replacement document"),
        );
        await ready("rich2");
        assert.equal(await page.locator(".tiptap h1").textContent(), "Replacement document");
        assert.equal(
          await page.locator(".tiptap").evaluate((el) => el === document.activeElement),
          true,
        );
      },
    );
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
