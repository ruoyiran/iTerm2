export function viewRoute(kind, mode) {
  if (mode === "source" && [0, 1, 5, 6, 7, 8].includes(kind)) return "source";
  if (mode === "changes") return "changes";
  if (kind === 1 && mode === "preview") return "preview";
  return (
    [
      "source",
      "rich",
      "image",
      "pdf",
      "unsupported",
      "svg",
      "mermaid",
      "csv",
      "notebook",
      "audio",
      "video",
    ][kind] ?? "unsupported"
  );
}
export function applyContentChange(sync, content, rawPaste) {
  const before = sync.raw.normalized,
    after = content.replace(/\r\n?|\n/g, "\n");
  if (before === after) return;
  let start = 0,
    end = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start++;
  if (start > 0 && /[\uD800-\uDBFF]/.test(before[start - 1])) start--;
  while (
    end < before.length - start &&
    end < after.length - start &&
    before[before.length - 1 - end] === after[after.length - 1 - end]
  )
    end++;
  if (end > 0 && /[\uDC00-\uDFFF]/.test(before[before.length - end])) end--;
  sync.change([
    {
      rangeOffset: start,
      rangeLength: before.length - start - end,
      text: after.slice(start, after.length - end),
      rawText: rawPaste,
    },
  ]);
}
