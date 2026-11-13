import React from "react";
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { FileExplorerToolbar } from "../orca/src/renderer/src/components/right-sidebar/file-explorer/panel/FileExplorerToolbar";
import { FileExplorerQueryStrip } from "../orca/src/renderer/src/components/right-sidebar/file-explorer/panel/FileExplorerQueryStrip";
import { FileExplorerNameFilter } from "../orca/src/renderer/src/components/right-sidebar/file-explorer/panel/FileExplorerNameFilter";
import { SearchQueryRow } from "../orca/src/renderer/src/components/right-sidebar/file-explorer/content-search/SearchQueryRow";
import { SearchFilters } from "../orca/src/renderer/src/components/right-sidebar/file-explorer/content-search/SearchFilters";
import { TooltipProvider } from "../orca/src/renderer/src/components/ui/tooltip";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSub,
  DropdownMenuSubTrigger,
  DropdownMenuSubContent,
} from "../orca/src/renderer/src/components/ui/dropdown-menu";
import { FolderOpen, Terminal, ArrowUp } from "lucide-react";
function Chrome({ controller: c }: any) {
  const clear = (mode: string) => {
    c[mode].value = "";
    c.search(mode === "names" ? "names" : "contents");
    c[mode].focus();
  };
  const visibility = (key: string) =>
    c.send("setVisibility", {
      showsHiddenFiles: !!c.scope?.showsHiddenFiles,
      showsGitIgnoredFiles: !!c.scope?.showsGitIgnoredFiles,
      [key]: !c.scope?.[key],
    });
  return (
    <TooltipProvider>
      <FileExplorerToolbar
        menuOpen={!!c.toolbarMenuOpen}
        onMenuOpenChange={(open) => {
          c.toolbarMenuOpen = open;
          c.chrome.render();
        }}
        repoName={c.repoTitle ?? c.t("selectProject")}
        worktreePath={c.scope?.rootDirectory ?? ""}
        canRefresh={!!c.scope}
        canCollapseAll={c.state.expanded.size > 0}
        refresh={{
          isRefreshing: !!c.refreshing,
          showRefreshSpinner: !!c.refreshing,
          handleRefresh: () => c.refresh(),
        }}
        onCollapseAll={() => {
          c.state.expanded.clear();
          c.render();
        }}
        showGitIgnoredFilesToggle
        showGitIgnoredFiles={!!c.scope?.showsGitIgnoredFiles}
        showDotfiles={!!c.scope?.showsHiddenFiles}
        onToggleDotfiles={() => visibility("showsHiddenFiles")}
        onToggleGitIgnoredFiles={() => visibility("showsGitIgnoredFiles")}
        openInItems={
          <>
            <DropdownMenuItem onSelect={() => c.send("returnToRoot", {})}>
              <ArrowUp />
              {c.t("returnToRoot")}
            </DropdownMenuItem>
            <DropdownMenuItem
              disabled={!c.scope}
              onSelect={() => c.send("revealInFinder", { paths: [c.scope.rootDirectory] })}
            >
              <FolderOpen />
              {c.t("reveal")}
            </DropdownMenuItem>
            <DropdownMenuItem
              disabled={!c.scope}
              onSelect={() =>
                c.send("openTerminal", { directoryPath: c.scope.rootDirectory, placement: "tab" })
              }
            >
              <Terminal />
              {c.t("openTerminal")}
            </DropdownMenuItem>
          </>
        }
      />
      <FileExplorerQueryStrip
        view={c.mode === "names" ? "files" : "search"}
        onSelectView={(mode) => c.setMode(mode === "files" ? "names" : "contents")}
      >
        <div hidden={c.mode !== "names"} data-name-row>
          <FileExplorerNameFilter
            query={c.names?.value ?? ""}
            loading={c.state.searching && c.mode === "names"}
            onQueryChange={() => {}}
            onClear={() => clear("names")}
          />
        </div>
        <div hidden={c.mode !== "contents"} data-content-row>
          <SearchQueryRow
            inputRef={() => {}}
            query={c.contents?.value ?? ""}
            loading={c.state.searching && c.mode === "contents"}
            {...c.flags}
            useRegex={c.flags.regularExpression}
            onQueryChange={() => {}}
            onKeyDown={() => {}}
            onClearSearch={() => clear("contents")}
            onToggleCaseSensitive={() => {
              c.flags.caseSensitive = !c.flags.caseSensitive;
              c.render();
            }}
            onToggleWholeWord={() => {
              c.flags.wholeWord = !c.flags.wholeWord;
              c.render();
            }}
            onToggleRegex={() => {
              c.flags.regularExpression = !c.flags.regularExpression;
              c.render();
            }}
          />
        </div>
        <div hidden={c.mode !== "contents"} data-search-filters>
          <SearchFilters
            includePattern={c.include?.value ?? ""}
            excludePattern={c.exclude?.value ?? ""}
            onIncludeChange={() => {}}
            onExcludeChange={() => {}}
          />
        </div>
      </FileExplorerQueryStrip>
    </TooltipProvider>
  );
}
export function createExplorerChrome(root: HTMLElement, c: any) {
  const react = createRoot(root);
  const render = () => {
    flushSync(() => react.render(<Chrome controller={c} />));
    const switches = root.querySelectorAll('[data-slot="toggle-group-item"]');
    switches.forEach((el, i) => ((el as HTMLElement).dataset.mode = i ? "contents" : "names"));
  };
  render();
  return { render, dispose: () => react.unmount() };
}
export function createExplorerMenu(
  root: HTMLElement,
  items: any[],
  point: { x: number; y: number },
  close: () => void,
) {
  const react = createRoot(root);
  flushSync(() =>
    react.render(
      <DropdownMenu
        open
        modal={false}
        onOpenChange={(open) => {
          if (!open) close();
        }}
      >
        <DropdownMenuTrigger asChild>
          <button
            aria-hidden
            tabIndex={-1}
            className="pointer-events-none fixed size-px opacity-0"
            style={{ left: point.x, top: point.y }}
          />
        </DropdownMenuTrigger>
        <DropdownMenuContent
          portalContainer={root}
          sideOffset={0}
          align="start"
          onCloseAutoFocus={(e) => e.preventDefault()}
        >
          {items.map((item, index) =>
            item.children ? (
              <DropdownMenuSub key={index}>
                <DropdownMenuSubTrigger>{item.label}</DropdownMenuSubTrigger>
                <DropdownMenuSubContent>
                  {item.children.map((child: any, i: number) => (
                    <DropdownMenuItem key={i} onSelect={child.action}>
                      {child.label}
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuSubContent>
              </DropdownMenuSub>
            ) : (
              <DropdownMenuItem key={index} aria-label={item.label} onSelect={item.action}>
                {item.icon}
                {item.label}
              </DropdownMenuItem>
            ),
          )}
        </DropdownMenuContent>
      </DropdownMenu>,
    ),
  );
  return { dispose: () => react.unmount() };
}
