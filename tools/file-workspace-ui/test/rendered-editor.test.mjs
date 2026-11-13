import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
const assets = fileURLToPath(
  new URL("../../../sources/FileWorkspace/Resources/FileWorkspaceUI/", import.meta.url),
);
test("original Orca views render offline and edits pass the authority bridge", async () => {
  const server = http.createServer(async (req, res) => {
    try {
      const p = path.join(assets, decodeURIComponent(req.url.split("?")[0]));
      if (!p.startsWith(assets)) throw Error();
      const bytes = await readFile(p);
      res.setHeader(
        "content-type",
        p.endsWith(".js") || p.endsWith(".mjs")
          ? "text/javascript"
          : p.endsWith(".css")
            ? "text/css"
            : p.endsWith(".html")
              ? "text/html"
              : p.endsWith(".svg")
                ? "image/svg+xml"
                : p.endsWith(".woff2")
                  ? "font/woff2"
                  : "application/octet-stream",
      );
      res.end(bytes);
    } catch {
      res.statusCode = 404;
      res.end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 1100, height: 800 },
    colorScheme: process.env.FILE_UI_FORCE_LEGACY === "1" ? "dark" : "light",
  });
  const errors = [];
  page.on("request", (request) => {
    if (/^https?:/.test(request.url()) && !request.url().startsWith("http://127.0.0.1:"))
      errors.push("External asset request: " + request.url());
  });
  page.on("pageerror", (e) => {
    errors.push(e.message);
    console.error("PAGE:", e.stack);
  });
  page.on("console", (m) => {
    if (m.type() === "error") {
      errors.push(m.text());
      console.error("CONSOLE:", m.text());
    }
  });
  try {
    await page.addInitScript(() => {
      window.sent = [];
      window.fixtures = {};
      window.identity = {
        protocolVersion: 1,
        rendererEpoch: "e",
        viewIdentifier: "v",
        contextToken: "c",
        generation: "1",
      };
      window.webkit = {
        messageHandlers: {
          fileWorkspace: {
            postMessage: (message) => {
              window.sent.push(message);
              if (message.type === "hostRequest") {
                const { operation } = message.payload;
                const args = message.payload.args;
                const bytes = atob(window.fixtures[args.path] ?? "");
                const result =
                  operation === "settings"
                    ? {}
                    : operation === "annotations"
                      ? (args.comments ?? [])
                      : operation === "listMarkdownDocuments"
                        ? []
                        : operation === "gitChanges"
                          ? [
                              { path: "sample.js", status: "modified" },
                              { path: "other.js", status: "added" },
                            ]
                          : operation === "saveDocument" ||
                              operation === "writeClipboardImage" ||
                              operation === "exportPDF"
                            ? { success: true }
                            : operation === "stat"
                              ? {
                                  mtime: 123,
                                  size: bytes.length,
                                  isDirectory: false,
                                  fileIdentity: args.path,
                                }
                              : operation === "readRange"
                                ? {
                                    data: btoa(
                                      bytes.slice(args.position, args.position + args.length),
                                    ),
                                    byteLength: Math.min(args.length, bytes.length - args.position),
                                    size: bytes.length,
                                    fileIdentity: args.path,
                                  }
                                : operation === "gitDiff"
                                  ? {
                                      kind: "text",
                                      originalContent: "before\n",
                                      modifiedContent: "after\n",
                                    }
                                  : null;
                queueMicrotask(() =>
                  window.fileWorkspace.receive({
                    ...window.identity,
                    type: "hostResult",
                    payload: { result },
                    requestIdentifier: message.requestIdentifier,
                  }),
                );
              }
              if (message.type === "edits")
                queueMicrotask(() =>
                  window.fileWorkspace.receive({
                    ...window.identity,
                    type: "ack",
                    payload: {
                      sequence: message.payload.sequence,
                      revision: String(BigInt(message.payload.expectedRevision) + 1n),
                    },
                  }),
                );
            },
          },
        },
      };
    });
    if (process.env.FILE_UI_FORCE_LEGACY === "1")
      await page.addInitScript(() => {
        delete Promise.withResolvers;
        delete ReadableStream.prototype.values;
        delete ReadableStream.prototype[Symbol.asyncIterator];
        for (const key of ["toSorted", "toReversed", "toSpliced", "findLast", "findLastIndex"])
          delete Array.prototype[key];
        const NativeWorker = Worker;
        window.Worker = class extends NativeWorker {
          constructor(url, options) {
            const absolute = new URL(url, location.href).href;
            const prelude = URL.createObjectURL(
              new Blob(
                [
                  "delete Promise.withResolvers; delete ReadableStream.prototype.values; delete ReadableStream.prototype[Symbol.asyncIterator];",
                ],
                { type: "text/javascript" },
              ),
            );
            const source = `import ${JSON.stringify(prelude)}; import ${JSON.stringify(absolute)};`;
            super(URL.createObjectURL(new Blob([source], { type: "text/javascript" })), options);
          }
        };
        const supports = CSS.supports.bind(CSS);
        CSS.supports = (...args) =>
          args.some((value) => String(value).includes("color-mix")) ? false : supports(...args);
      });
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    await page.waitForFunction(() => window.fileWorkspace);
    await page.evaluate(() =>
      window.fileWorkspace.receive({
        ...window.identity,
        type: "configure",
        payload: { purpose: "editor", labels: {} },
      }),
    );
    const receive = (type, payload) =>
      page.evaluate(
        ({ type, payload }) => window.fileWorkspace.receive({ ...window.identity, type, payload }),
        { type, payload },
      );
    const open = async (kind, text, filePath, earlyPaste) => {
      await page.evaluate(
        async ({ snapshot, earlyPaste }) => {
          const receive = (type, payload) =>
            window.fileWorkspace.receive({ ...window.identity, type, payload });
          await receive("document", { snapshot });
          await receive("editAuthority", { granted: true });
          if (earlyPaste !== undefined) {
            await receive("paste", { text: earlyPaste });
            await receive("flush", { suspend: false });
          }
        },
        {
          snapshot: {
            documentIdentifier: String(kind),
            filePath,
            text,
            kind,
            revision: "1",
            isReadOnly: false,
            isDirty: false,
          },
          earlyPaste,
        },
      );
    };
    await open(0, "const value = 1;\r\n", "/repo/code.js", "// early\r\n");
    assert.equal(
      await page.evaluate(
        () =>
          window.sent.filter((m) => m.type === "edits" && m.payload.documentIdentifier === "0")
            .length,
      ),
      1,
    );
    await page.locator(".monaco-editor").waitFor();
    await page.waitForFunction(
      () =>
        window.sent.findLast((m) => m.type === "status")?.payload.documentIdentifier === "0" &&
        window.sent.findLast((m) => m.type === "status")?.payload.isReady === true,
    );
    await receive("paste", { text: "// test\r\n" });
    await page.waitForFunction(() =>
      window.sent.some((m) => m.type === "edits" && m.payload.documentIdentifier === "0"),
    );
    await receive("flush", { suspend: false });
    await receive("command", { command: "selectAll" });
    await page.waitForFunction(
      () =>
        window.sent.findLast((message) => message.type === "status")?.payload.hasSelection === true,
    );
    await receive("copySelection", { cut: false });
    assert.ok(
      await page.evaluate(() =>
        window.sent
          .findLast((message) => message.type === "clipboard")
          ?.payload.text.includes("const value = 1;"),
      ),
    );

    await open(1, "# Hello\n\nParagraph with **bold**.\n", "/repo/readme.md");
    await receive("restoreViewState", {
      schemaVersion: 2,
      viewMode: "default",
      selectionStartLine: 1,
      selectionStartColumn: 1,
      selectionEndLine: 1,
      selectionEndColumn: 1,
      scrollTop: 0,
      scrollLeft: 0,
    });
    await page.locator(".tiptap").waitFor();
    assert.equal(await page.locator(".tiptap h1").textContent(), "Hello");
    await receive("focus", {});
    assert.equal(
      await page.locator(".tiptap").evaluate((el) => el === document.activeElement),
      true,
    );
    await page.locator(".tiptap").click();
    await page.keyboard.press("End");
    await page.keyboard.type(" changed");
    await page.waitForFunction(() => window.sent.some((m) => m.type === "edits"));
    await page.keyboard.press("Home");
    await page.keyboard.press("Shift+End");
    await page.keyboard.press("Meta+Shift+A");
    await page.getByPlaceholder("Add note for the AI").fill("Review this paragraph");
    await page.getByRole("button", { name: "Add note", exact: true }).click();
    await page.waitForFunction(() =>
      window.sent.some(
        (m) =>
          m.type === "hostRequest" &&
          m.payload.operation === "annotations" &&
          m.payload.args.action === "update",
      ),
    );
    await receive("command", { command: "find" });
    await page.locator(".rich-markdown-search input").first().fill("Hello");
    await receive("command", { command: "findNext" });
    await receive("command", { command: "findPrevious" });
    await page.locator(".rich-markdown-search input").first().press("Escape");
    await page.getByRole("button", { name: "File actions" }).click();
    await page.getByRole("menuitem", { name: "Export as PDF" }).click();
    await page.waitForFunction(() =>
      window.sent.some((m) => m.type === "hostRequest" && m.payload.operation === "exportPDF"),
    );
    await page.locator(".editor-header-path-row").click({ button: "right" });
    await page.getByRole("menuitem", { name: "Open Markdown Preview" }).click();
    await page.waitForFunction(() =>
      window.sent.some(
        (m) => m.type === "hostRequest" && m.payload.operation === "openMarkdownPreview",
      ),
    );
    await receive("flush", { suspend: true });
    await page.waitForFunction(
      () => window.sent.findLast((m) => m.type === "status")?.payload.hasPendingEdits === false,
    );
    const count = await page.evaluate(() => window.sent.filter((m) => m.type === "edits").length);
    await receive("editAuthority", { granted: false });
    assert.equal(
      await page.evaluate(
        () => window.sent.findLast((m) => m.type === "status").payload.isReadOnly,
      ),
      false,
    );
    await page
      .locator(".tiptap")
      .evaluate((el) =>
        el.dispatchEvent(new InputEvent("input", { bubbles: true, data: "forbidden" })),
      );
    assert.equal(
      await page.evaluate(() => window.sent.filter((m) => m.type === "edits").length),
      count,
    );
    await receive("resume", {});
    await receive("command", { command: "setViewMode", viewMode: "preview" });
    await page.locator('[data-orca-view="preview"] h1').waitFor();
    await open(7, "name,value\r\nalpha,42\r\n", "/repo/data.csv");
    await page.getByText("alpha", { exact: true }).waitFor();
    await page.getByText("alpha", { exact: true }).dblclick();
    await page.getByRole("textbox", { name: "Edit row 2, column 1" }).fill("beta");
    await page.keyboard.press("Enter");
    await receive("flush", { suspend: false });
    assert.ok(
      await page.evaluate(() =>
        window.sent.some((m) => m.type === "edits" && m.payload.documentIdentifier === "7"),
      ),
    );
    await receive("command", { command: "find" });
    assert.equal(
      await page
        .getByRole("textbox", { name: "Filter rows" })
        .evaluate((el) => el === document.activeElement),
      true,
    );
    await receive("command", { command: "findNext" });
    await receive("command", { command: "findPrevious" });
    await open(
      8,
      JSON.stringify({
        nbformat: 4,
        metadata: { kernelspec: { language: "python" } },
        cells: [
          {
            cell_type: "code",
            metadata: {},
            execution_count: 1,
            source: ["print(42)"],
            outputs: [{ output_type: "stream", name: "stdout", text: ["42\n"] }],
          },
        ],
      }),
      "/repo/notebook.ipynb",
    );
    await page.getByText("print(42)", { exact: true }).waitFor();
    assert.equal(await page.getByText("Run Notebook Code?", { exact: true }).count(), 0);
    await page.getByText("print(42)", { exact: true }).click();
    await page.locator("[data-orca-view=notebook] .monaco-editor").waitFor();
    await page.keyboard.press("End");
    await page.keyboard.type(" # saved");
    await page.getByRole("button", { name: "Save notebook" }).click();
    await page.waitForFunction(() =>
      window.sent.some((m) => m.type === "hostRequest" && m.payload.operation === "saveDocument"),
    );
    await receive("command", { command: "setViewMode", viewMode: "changes" });
    await page.locator(".monaco-diff-editor").first().waitFor();
    await page.locator("[data-combined-diff-section-key]").nth(1).waitFor();

    await open(
      5,
      '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="red"/></svg>',
      "/repo/icon.svg",
    );
    await page.locator("[data-orca-view=svg] img").waitFor();
    await open(6, "graph TD; A-->B", "/repo/chart.mmd");
    await page.locator(".mermaid-viewer svg.flowchart").waitFor();
    await page.getByRole("button", { name: "Expand diagram" }).click();
    await page.getByRole("dialog").waitFor();
    await page.getByRole("button", { name: "Copy as PNG" }).click();
    await page.waitForFunction(() =>
      window.sent.some(
        (m) => m.type === "hostRequest" && m.payload.operation === "writeClipboardImage",
      ),
    );
    await page.keyboard.press("Escape");
    const csv = Buffer.from(
      "name,value\n" + Array.from({ length: 500 }, (_, i) => `row-${i},${i}`).join("\n"),
    );
    await page.evaluate(({ data }) => (window.fixtures["/repo/large.csv"] = data), {
      data: csv.toString("base64"),
    });
    await receive("document", {
      snapshot: {
        documentIdentifier: "large",
        filePath: "/repo/large.csv",
        text: "",
        kind: 7,
        revision: "1",
        isReadOnly: true,
        isTooLarge: true,
        byteCount: csv.length,
      },
    });
    await page.getByText("row-0", { exact: true }).waitFor();
    let pdf = "%PDF-1.4\n";
    const pdfText = "BT /F1 12 Tf 20 150 Td (sample searchable text) Tj ET";
    const offsets = [0];
    for (const object of [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
      `<< /Length ${pdfText.length} >>\nstream\n${pdfText}\nendstream`,
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]) {
      offsets.push(pdf.length);
      pdf += `${offsets.length - 1} 0 obj\n${object}\nendobj\n`;
    }
    const xref = pdf.length;
    pdf +=
      "xref\n0 6\n0000000000 65535 f \n" +
      offsets
        .slice(1)
        .map((offset) => String(offset).padStart(10, "0") + " 00000 n \n")
        .join("") +
      `trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`;
    await page.evaluate(({ data }) => (window.fixtures["/repo/test.pdf"] = data), {
      data: Buffer.from(pdf).toString("base64"),
    });
    await receive("document", {
      snapshot: {
        documentIdentifier: "pdf",
        filePath: "/repo/test.pdf",
        text: "",
        kind: 3,
        revision: "1",
        isReadOnly: true,
        byteCount: pdf.length,
        mediaURL: "iterm-media://pdf",
      },
    });
    await page.locator(".pdfViewer .page canvas").waitFor();
    await page.waitForFunction(() =>
      document
        .querySelector(".pdfViewer .textLayer")
        ?.textContent.includes("sample searchable text"),
    );
    await receive("command", { command: "find" });
    await page.locator("[data-pdf-find] input").fill("sample");
    await page.locator(".textLayer .highlight.selected").waitFor();
    await receive("command", { command: "findNext" });
    await receive("command", { command: "findPrevious" });
    await receive("document", {
      snapshot: {
        documentIdentifier: "image",
        filePath: "/repo/test.png",
        text: "",
        kind: 2,
        revision: "1",
        isReadOnly: true,
        mimeType: "image/png",
        mediaURL:
          "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6eVQAAAAASUVORK5CYII=",
      },
    });
    await page.locator("[data-orca-view=image] img").waitFor();
    await receive("document", {
      snapshot: {
        documentIdentifier: "audio",
        filePath: "/repo/test.wav",
        text: "",
        kind: 9,
        revision: "1",
        isReadOnly: true,
        mimeType: "audio/wav",
        mediaURL:
          "data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA=",
      },
    });
    await page.locator("audio[controls]").waitFor();
    await receive("document", {
      snapshot: {
        documentIdentifier: "video",
        filePath: "/repo/test.mp4",
        text: "",
        kind: 10,
        revision: "1",
        isReadOnly: true,
        mimeType: "video/mp4",
        mediaURL: "data:video/mp4;base64,",
      },
    });
    assert.equal(await page.locator("[data-orca-view=video]").count(), 1);
    await page.screenshot({ path: "/tmp/iterm2-orca-media.png" });
    await receive("document", {
      snapshot: {
        documentIdentifier: "unsafe-md",
        filePath: "/repo/unsafe.mdx",
        text: "# Preserved\n\n[Example][ref]\n\n[ref]: https://example.com\n",
        kind: 1,
        revision: "1",
        isReadOnly: false,
      },
    });
    await receive("editAuthority", { granted: true });
    await receive("restoreViewState", { schemaVersion: 2, viewMode: "default" });
    await page.locator("[data-orca-view=preview] h1").waitFor();
    assert.equal(await page.locator(".tiptap").count(), 0);
    await receive("command", { command: "setViewMode", viewMode: "source" });
    await page.locator(".monaco-editor").waitFor();

    await page.evaluate(() =>
      window.fileWorkspace.receive({
        ...window.identity,
        type: "configure",
        payload: { purpose: "explorer", labels: {} },
      }),
    );
    await receive("context", { token: "c", rootDirectory: "/repo", title: "repo" });
    let listing = await page.evaluate(() =>
      window.sent.findLast((m) => m.type === "listDirectory"),
    );
    await receive("listing", {
      token: "c",
      requestIdentifier: listing.requestIdentifier,
      directoryPath: "/repo",
      entries: [{ path: "/repo/folder", name: "folder", isDirectory: true, isExpandable: true }],
    });
    await page.locator('[data-path="/repo/folder"]').click();
    listing = await page.evaluate(() => window.sent.findLast((m) => m.type === "listDirectory"));
    await receive("listing", {
      token: "c",
      requestIdentifier: listing.requestIdentifier,
      directoryPath: "/repo/folder",
      entries: [{ path: "/repo/folder/file.txt", name: "file.txt", isDirectory: false }],
    });
    await page.locator('[data-path="/repo/folder/file.txt"]').waitFor();
    await page.getByRole("textbox", { name: "Find files", exact: true }).focus();
    await page.getByRole("radio", { name: "Search file contents" }).click();
    await page.getByRole("textbox", { name: "Search files", exact: true }).fill("needle");
    await page.getByRole("textbox", { name: "Search files", exact: true }).press("Enter");
    const search = await page.evaluate(() =>
      window.sent.findLast((m) => m.type === "searchContents"),
    );
    assert.equal(search.payload.query.text, "needle");
    await receive("search", {
      token: "c",
      requestIdentifier: search.requestIdentifier,
      matches: [
        {
          path: "/repo/folder/file.txt",
          relativePath: "folder/file.txt",
          lines: [
            {
              lineNumber: 7,
              snippet: "a needle here",
              snippetColumn: 0,
              ranges: [{ location: 2, length: 6 }],
            },
          ],
        },
      ],
      isComplete: true,
    });
    await page.locator(".result-match").click();
    assert.equal(
      await page.evaluate(
        () => window.sent.findLast((m) => m.type === "openFile").payload.lineNumber,
      ),
      7,
    );
    await page.getByRole("button", { name: "More Explorer Actions", exact: true }).click();
    await receive("dismissMenu", {});
    assert.equal(
      await page.getByRole("menuitemcheckbox", { name: "Show Dotfiles", exact: true }).count(),
      0,
    );
    await page.getByRole("button", { name: "More Explorer Actions", exact: true }).click();
    await receive("context", { token: "c", rootDirectory: "/repo", title: "repo" });
    assert.equal(
      await page.getByRole("menuitemcheckbox", { name: "Show Dotfiles", exact: true }).count(),
      0,
    );
    await page.getByRole("button", { name: "More Explorer Actions", exact: true }).click();
    await page.getByRole("menuitemcheckbox", { name: "Show Dotfiles", exact: true }).click();
    assert.equal(
      await page.evaluate(
        () => window.sent.findLast((m) => m.type === "setVisibility").payload.showsHiddenFiles,
      ),
      true,
    );
    await page.getByRole("radio", { name: "Filter files by name" }).click();
    await page.locator('[data-path="/repo/folder/file.txt"]').click({ button: "right" });
    await page.getByRole("menuitem", { name: "copyPath", exact: true }).click();
    assert.equal(
      await page.evaluate(
        () => window.sent.findLast((m) => m.type === "copyAbsolutePaths").payload.paths[0],
      ),
      "/repo/folder/file.txt",
    );
    assert.equal(
      await page.evaluate(() =>
        window.sent.some(
          (m) =>
            m.type === "command" &&
            ["find", "findNext", "findPrevious"].includes(m.payload.command),
        ),
      ),
      false,
    );
    assert.deepEqual(errors, []);
  } finally {
    await page.screenshot({
      path: `/tmp/iterm2-orca-rendered${process.env.FILE_UI_FORCE_LEGACY === "1" ? "-legacy-dark" : ""}.png`,
    });
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
