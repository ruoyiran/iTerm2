import test from "node:test";
import assert from "node:assert/strict";
import { DocumentTransfers } from "../../../sources/FileWorkspace/Resources/src/document-transfers.mjs";
test("streamed document only commits ordered complete text and reset discards old parts", () => {
  const transfers = new DocumentTransfers();
  assert.equal(
    transfers.receive("documentStart", {
      transferIdentifier: "a",
      total: 2,
      snapshot: { documentIdentifier: "d" },
    }),
    null,
  );
  transfers.receive("documentText", { transferIdentifier: "a", index: 0, text: "first\r\n" });
  assert.equal(transfers.receive("documentEnd", { transferIdentifier: "a" }), null);
  transfers.receive("documentStart", {
    transferIdentifier: "b",
    total: 2,
    snapshot: { documentIdentifier: "d" },
  });
  transfers.receive("documentText", { transferIdentifier: "b", index: 0, text: "first\r\n" });
  transfers.receive("documentText", { transferIdentifier: "b", index: 1, text: "last😀" });
  assert.deepEqual(transfers.receive("documentEnd", { transferIdentifier: "b" }), {
    snapshot: { documentIdentifier: "d", text: "first\r\nlast😀" },
  });
  transfers.receive("documentStart", { transferIdentifier: "c", total: 2, snapshot: {} });
  transfers.receive("documentText", { transferIdentifier: "c", index: 1, text: "out of order" });
  assert.equal(transfers.receive("documentEnd", { transferIdentifier: "c" }), null);
  transfers.receive("documentStart", { transferIdentifier: "d", total: 1, snapshot: {} });
  transfers.reset();
  transfers.receive("documentText", { transferIdentifier: "d", index: 0, text: "old" });
  assert.equal(transfers.receive("documentEnd", { transferIdentifier: "d" }), null);
});
