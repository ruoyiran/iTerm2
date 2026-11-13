export class DocumentTransfers {
  constructor() {
    this.reset();
  }
  reset() {
    this.transfers = new Map();
  }
  receive(type, payload) {
    const id = payload.transferIdentifier;
    if (typeof id !== "string") return null;
    if (type === "documentStart") {
      if (
        this.transfers.size >= 2 ||
        !Number.isSafeInteger(payload.total) ||
        payload.total < 1 ||
        payload.total > 4096 ||
        !payload.snapshot ||
        typeof payload.snapshot !== "object"
      )
        return null;
      this.transfers.set(id, {
        snapshot: payload.snapshot,
        total: payload.total,
        parts: [],
        length: 0,
      });
      return null;
    }
    const transfer = this.transfers.get(id);
    if (!transfer) return null;
    if (type === "documentText") {
      if (
        payload.index !== transfer.parts.length ||
        typeof payload.text !== "string" ||
        payload.text.length > 131072 ||
        transfer.parts.length >= transfer.total ||
        transfer.length + payload.text.length > 100 * 1024 * 1024
      ) {
        this.transfers.delete(id);
        return null;
      }
      transfer.parts.push(payload.text);
      transfer.length += payload.text.length;
      return null;
    }
    if (type === "documentEnd") {
      this.transfers.delete(id);
      if (transfer.parts.length === transfer.total)
        return { snapshot: { ...transfer.snapshot, text: transfer.parts.join("") } };
    }
    return null;
  }
}
