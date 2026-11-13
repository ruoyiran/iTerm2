if (!Promise.withResolvers)
  Promise.withResolvers = function () {
    let resolve, reject;
    const promise = new Promise((yes, no) => {
      resolve = yes;
      reject = no;
    });
    return { promise, resolve, reject };
  };
if (!Array.prototype.toSorted)
  Object.defineProperty(Array.prototype, "toSorted", {
    value: function (compare) {
      return [...this].sort(compare);
    },
  });
if (!Array.prototype.toReversed)
  Object.defineProperty(Array.prototype, "toReversed", {
    value: function () {
      return [...this].reverse();
    },
  });
if (!Array.prototype.toSpliced)
  Object.defineProperty(Array.prototype, "toSpliced", {
    value: function (...args) {
      const copy = [...this];
      copy.splice(...args);
      return copy;
    },
  });
if (!Array.prototype.findLast)
  Object.defineProperty(Array.prototype, "findLast", {
    value: function (predicate, thisArg) {
      for (let i = this.length - 1; i >= 0; i--)
        if (predicate.call(thisArg, this[i], i, this)) return this[i];
    },
  });
if (!Array.prototype.findLastIndex)
  Object.defineProperty(Array.prototype, "findLastIndex", {
    value: function (predicate, thisArg) {
      for (let i = this.length - 1; i >= 0; i--)
        if (predicate.call(thisArg, this[i], i, this)) return i;
      return -1;
    },
  });
if (typeof ReadableStream !== "undefined" && !ReadableStream.prototype.values) {
  Object.defineProperty(ReadableStream.prototype, "values", {
    configurable: true,
    writable: true,
    value: function ({ preventCancel = false } = {}) {
      const reader = this.getReader();
      let finished = false;
      let pending = Promise.resolve();
      const enqueue = (action) => (pending = pending.then(action, action));
      return {
        next: () =>
          enqueue(async () => {
            if (finished) return { done: true, value: undefined };
            try {
              const result = await reader.read();
              if (result.done) {
                finished = true;
                reader.releaseLock();
              }
              return result;
            } catch (error) {
              finished = true;
              reader.releaseLock();
              throw error;
            }
          }),
        return: (value) =>
          enqueue(async () => {
            if (!finished) {
              finished = true;
              try {
                if (!preventCancel) await reader.cancel(value);
              } finally {
                reader.releaseLock();
              }
            }
            return { done: true, value };
          }),
        [Symbol.asyncIterator]() {
          return this;
        },
      };
    },
  });
}
if (typeof ReadableStream !== "undefined" && !ReadableStream.prototype[Symbol.asyncIterator])
  Object.defineProperty(ReadableStream.prototype, Symbol.asyncIterator, {
    configurable: true,
    writable: true,
    value: ReadableStream.prototype.values,
  });
