import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { FileExplorerRow } from "../orca/src/renderer/src/components/right-sidebar/file-explorer/panel/FileExplorerRow";
export function createExplorerRow(row: any, expanded: boolean, selected: boolean, loading = false) {
  const template = document.createElement("template");
  template.innerHTML = renderToStaticMarkup(
    <FileExplorerRow
      node={{ ...row, isSymlink: row.isSymbolicLink }}
      isExpanded={expanded}
      isLoading={loading}
      isSelected={selected}
      nodeStatus={row.gitStatus ?? null}
      isIgnored={row.isIgnored ?? false}
    />,
  );
  return template.content.firstElementChild as HTMLButtonElement;
}

import {
  FileResultRow,
  MatchResultRow,
} from "../orca/src/renderer/src/components/right-sidebar/file-explorer/content-search/SearchResultItems";
export function createSearchResult(item: any, collapsed: boolean) {
  const group = item.group;
  const view =
    item.kind === "group" ? (
      <FileResultRow
        fileResult={
          {
            relativePath: group.relativePath,
            matches: group.lines.map((line: any) => ({ line: line.lineNumber })),
            matchCount: group.lines.reduce((n: number, line: any) => n + line.ranges.length, 0),
          } as any
        }
        collapsed={collapsed}
        onToggleCollapse={() => {}}
      />
    ) : (
      <MatchResultRow
        relativePath={group.relativePath}
        match={
          {
            line: item.line.lineNumber,
            lineContent: item.line.snippet,
            column: (item.line.ranges[0]?.location ?? 0) + 1,
            matchLength: item.line.ranges[0]?.length ?? 0,
            displayColumn:
              (item.line.ranges[0]?.location ?? 0) - (item.line.snippetColumn ?? 0) + 1,
          } as any
        }
        onClick={() => {}}
      />
    );
  const template = document.createElement("template");
  template.innerHTML = renderToStaticMarkup(view);
  return template.content.querySelector("button")!;
}
