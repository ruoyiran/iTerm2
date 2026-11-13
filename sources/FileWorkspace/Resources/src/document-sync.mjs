const boundary = (s, i) => i >= 0 && i <= s.length && !(i > 0 && i < s.length && /[\uD800-\uDBFF]/.test(s[i - 1]) && /[\uDC00-\uDFFF]/.test(s[i]));
export class RawText {
  constructor(text) { this.text = text; this.reindex(); }
  reindex() {
    this.normalized = this.text.replace(/\r\n?|\n/g, '\n');
    this.eol = this.text.match(/\r\n|\r|\n/)?.[0] ?? '\n';
    this.breaks = []; let delta = 0;
    for (let i = 0; i < this.text.length; i++) {
      if (this.text[i] === '\r' && this.text[i + 1] === '\n') {
        this.breaks.push(i - delta + 1); delta++; i++;
      }
    }
  }
  rawOffset(offset) {
    let low = 0, high = this.breaks.length;
    while (low < high) { const mid = (low + high) >>> 1; if (this.breaks[mid] <= offset) low = mid + 1; else high = mid; }
    return offset + low;
  }
  applyModelChanges(changes) {
    const sorted = [...changes].sort((a, b) => a.rangeOffset - b.rangeOffset);
    let end = -1;
    const edits = sorted.map(change => {
      const {rangeOffset: start, rangeLength: length, text} = change;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(length) || length < 0 || typeof text !== 'string' || !boundary(this.normalized, start) || !boundary(this.normalized, start + length)) throw new Error('Invalid UTF16 boundary');
      if (start < end || start === end && length === 0 && end !== -1) throw new Error('Overlapping edits');
      end = start + length;
      const location = this.rawOffset(start);
      return {location, length: this.rawOffset(end) - location, replacement: typeof change.rawText === 'string' && change.rawText.replace(/\r\n?|\n/g, '\n') === text.replace(/\r\n?|\n/g, '\n') ? change.rawText : text.replace(/\r\n?|\n/g, this.eol)};
    });
    this.applyRawEdits(edits);
    return edits;
  }
  applyRawEdits(edits) {
    let result = this.text;
    const sorted = [...edits].sort((a, b) => b.location - a.location);
    let next = result.length + 1;
    for (const {location, length, replacement} of sorted) {
      if (!boundary(this.text, location) || !boundary(this.text, location + length) || location + length > next) throw new Error('Invalid edit boundary');
      next = location; result = result.slice(0, location) + replacement + result.slice(location + length);
    }
    this.text = result; this.reindex();
  }
}

export class DocumentSync {
  constructor({send, changed = () => {}}) { this.send = send; this.changed = changed; this.queue = []; this.waiters = []; this.composing = false; this.suspended = false; this.sequence = 0n; this.error = null; }
  open(snapshot) {
    if (this.hasPendingEdits) throw new Error('Unacknowledged edits');
    this.documentIdentifier = snapshot.documentIdentifier; this.revision = BigInt(snapshot.revision); this.raw = new RawText(snapshot.text ?? ''); this.sequence = 0n; this.error = null; this.suspended = false;
  }
  get hasPendingEdits() { return this.queue.length > 0; }
  change(changes) {
    if (this.error || this.suspended && !this.composing) throw new Error('Editing suspended');
    const edits = this.raw.applyModelChanges(changes);
    this.queue.push({sequence: String(++this.sequence), edits});
    this.changed(); this.pump();
  }
  pump() {
    if (this.inFlight || this.error || !this.queue.length) return;
    this.inFlight = this.queue[0];
    this.send({documentIdentifier: this.documentIdentifier, expectedRevision: String(this.revision), ...this.inFlight});
  }
  ack({sequence, revision, error}) {
    if (error || !this.inFlight || sequence !== this.inFlight.sequence || BigInt(revision) !== this.revision + 1n) {
      this.fail(new Error(error || 'Stale acknowledgment')); throw this.error;
    }
    this.revision = BigInt(revision); this.queue.shift(); this.inFlight = null;
    this.pump(); this.settle(); this.changed();
  }
  remote(snapshot, edits) {
    const revision = BigInt(snapshot.revision);
    if (revision <= this.revision) return false;
    if (this.hasPendingEdits) {
      // Own transaction notifications can precede their completion acknowledgments.
      if (this.inFlight && revision === this.revision + 1n) return false;
      this.fail(new Error('Document changed while edits are pending')); return false;
    }
    if (edits && revision === this.revision + 1n) this.raw.applyRawEdits(edits);
    else this.raw = new RawText(snapshot.text ?? '');
    this.revision = revision; this.changed(); return true;
  }
  flush(suspend = false) {
    if (suspend) this.suspended = true;
    if (this.error) return Promise.reject(this.error);
    if (!this.hasPendingEdits && !this.composing) return Promise.resolve({revision: String(this.revision), sequence: String(this.sequence)});
    return new Promise((resolve, reject) => { this.waiters.push({resolve, reject}); this.pump(); });
  }
  settle() { if (!this.hasPendingEdits && !this.composing) for (const waiter of this.waiters.splice(0)) waiter.resolve({revision: String(this.revision), sequence: String(this.sequence)}); }
  endComposition() { this.composing = false; this.settle(); this.changed(); }
  resume() { if (!this.error) this.suspended = false; }
  fail(error) { this.error = error; for (const waiter of this.waiters.splice(0)) waiter.reject(error); this.changed(); }
}
