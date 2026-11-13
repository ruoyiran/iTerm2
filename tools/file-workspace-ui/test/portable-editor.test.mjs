import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { DocumentSync } from "../../../sources/FileWorkspace/Resources/src/document-sync.mjs";

test("structured edits preserve CRLF and flush waits for final composition and acknowledgment", async () => {
  const { applyContentChange } =
    await import("../../../sources/FileWorkspace/Resources/src/portable/view-routes.mjs");
  const sent = [];
  const sync = new DocumentSync({ send: (edit) => sent.push(edit) });
  sync.open({ documentIdentifier: "csv", revision: "1", text: "a,b\r\n1,2\r\n" });
  applyContentChange(sync, "a,b\n1,3\n");
  assert.equal(sync.raw.text, "a,b\r\n1,3\r\n");
  assert.deepEqual(sent[0].edits, [{ location: 7, length: 1, replacement: "3" }]);
  sync.composing = true;
  let flushed = false;
  const flush = sync.flush(true).then(() => (flushed = true));
  sync.ack({ sequence: "1", revision: "2" });
  await Promise.resolve();
  assert.equal(flushed, false);
  sync.endComposition();
  await flush;
  assert.equal(flushed, true);
  assert.throws(() => applyContentChange(sync, "edited"), /suspended/);
});
