import React, { useCallback, useEffect, useRef, useState } from "react";
import { CombinedDiffFileTree } from "../orca/src/renderer/src/components/editor/combined-diff/browse-files/combined-diff-file-tree";
import { CombinedDiffSectionList } from "../orca/src/renderer/src/components/editor/combined-diff/scroll-viewport/combined-diff-section-list";
import { CombinedDiffToolbar } from "../orca/src/renderer/src/components/editor/combined-diff/review-controls/combined-diff-toolbar";
import { CombinedDiffNoChangesEmptyState } from "../orca/src/renderer/src/components/editor/combined-diff/review-controls/combined-diff-skipped-conflicts";
import { useCombinedDiffVirtualizer } from "../orca/src/renderer/src/components/editor/combined-diff/scroll-viewport/use-combined-diff-virtualizer";
import { createProgrammaticScrollMarks } from "../orca/src/renderer/src/hooks/programmatic-scroll-marks";
import { getLargeDiffRenderLimit } from "../orca/src/shared/large-diff-render-limit";
import type { DiffSection } from "../orca/src/renderer/src/components/editor/diff/sections/diff-section-types";
import type { FileSnapshot, HostClient } from "./host-contract";
import { state, useAppStore } from "./local-state";
import { useDocumentDarkTheme } from "./platform";
export function LocalChanges({ file, host }: { file: FileSnapshot; host: HostClient }) {
  const settings = useAppStore((s) => s.settings),
    dark = useDocumentDarkTheme();
  const [source, setSource] = useState("head"),
    [reference, setReference] = useState(""),
    [sections, setSections] = useState<DiffSection[]>([]),
    [heights, setHeights] = useState<Record<number, number>>({}),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(true),
    [treeCollapsed, setTreeCollapsed] = useState(false),
    [active, setActive] = useState<string | null>(null);
  const generation = useRef(0),
    inflight = useRef(new Set<string>()),
    sectionsRef = useRef(sections),
    scrollContainer = useRef<HTMLDivElement | null>(null),
    scrollOffset = useRef(0),
    renderedIndices = useRef(new Set<number>()),
    modifiedEditors = useRef(new Map());
  sectionsRef.current = sections;
  const [marks] = useState(createProgrammaticScrollMarks),
    [epoch, setEpoch] = useState(0);
  const root = file.rootDirectory ?? state.root;
  const args = {
    source,
    ...(source === "branch"
      ? { baseRef: reference || "HEAD" }
      : source === "commit"
        ? { commit: reference || "HEAD" }
        : {}),
  };
  const loadSection = useCallback(
    (index: number) => {
      const section = sectionsRef.current[index],
        version = generation.current;
      if (
        !section ||
        !section.loading ||
        inflight.current.has(section.key) ||
        inflight.current.size >= 4
      )
        return;
      inflight.current.add(section.key);
      host
        .request("gitDiff", {
          path: root + "/" + section.path,
          source,
          ...(source === "branch"
            ? { baseRef: reference || "HEAD" }
            : source === "commit"
              ? { commit: reference || "HEAD" }
              : {}),
        })
        .then(
          (result) => {
            if (version !== generation.current) return;
            setSections((current) => {
              let next = current.map((item) =>
                item.key === section.key
                  ? {
                      ...item,
                      loading: false,
                      error: undefined,
                      diffResult: result,
                      originalContent: result.originalContent ?? "",
                      modifiedContent: result.modifiedContent ?? "",
                      largeDiffRenderLimit:
                        result.kind === "text"
                          ? (result.largeDiffRenderLimit ?? getLargeDiffRenderLimit(result))
                          : null,
                      contentGeneration: version,
                    }
                  : item,
              );
              let bytes = next.reduce(
                (size, item) =>
                  size + 2 * (item.originalContent.length + item.modifiedContent.length),
                0,
              );
              next = next.map((item, index) => {
                if (
                  bytes <= 64 * 1024 * 1024 ||
                  renderedIndices.current.has(index) ||
                  item.key === section.key
                )
                  return item;
                bytes -= 2 * (item.originalContent.length + item.modifiedContent.length);
                return {
                  ...item,
                  originalContent: "",
                  modifiedContent: "",
                  diffResult: null,
                  loading: true,
                };
              });
              return next;
            });
          },
          (error) => {
            if (version === generation.current)
              setSections((current) =>
                current.map((item) =>
                  item.key === section.key
                    ? { ...item, loading: false, error: error.message }
                    : item,
                ),
              );
          },
        )
        .finally(() => {
          if (version === generation.current) inflight.current.delete(section.key);
        });
    },
    [host, root, source, reference],
  );
  useEffect(() => {
    const version = ++generation.current;
    inflight.current.clear();
    setSections([]);
    setHeights({});
    setLoading(true);
    setError("");
    host.request("gitChanges", { directoryPath: root, ...args }).then(
      (entries) => {
        if (version !== generation.current) return;
        setSections(
          entries.map((entry) => ({
            key: (source === "commit" ? "combined-commit:" : "combined-branch:") + entry.path,
            path: entry.path,
            status: entry.status,
            oldPath: entry.oldPath,
            originalContent: "",
            modifiedContent: "",
            collapsed: false,
            loading: true,
            dirty: false,
            diffResult: null,
            largeDiffRenderLimit: null,
          })),
        );
        setLoading(false);
      },
      (error) => {
        if (version === generation.current) {
          setError(error.message);
          setLoading(false);
        }
      },
    );
    return () => {
      generation.current++;
    };
  }, [host, root, source, reference, epoch, file.revision]);
  const virtualizer = useCombinedDiffVirtualizer({
    generation: epoch,
    programmaticScrollMarks: marks,
    renderedIndicesRef: renderedIndices,
    rowKeys: sections.map((s) => s.key),
    scrollContainerRef: scrollContainer,
    scrollOffsetRef: scrollOffset,
    sectionHeights: heights,
    sections,
    sideBySide: settings.diffSideBySide === true,
  });
  const retry = (index: number) => {
    setSections((current) =>
      current.map((item, i) => (i === index ? { ...item, loading: true, error: undefined } : item)),
    );
    inflight.current.delete(sectionsRef.current[index]?.key);
    queueMicrotask(() => loadSection(index));
  };
  useEffect(() => {
    for (const item of virtualizer.getVirtualItems()) loadSection(item.index);
  }, [sections, loadSection, virtualizer]);
  const openSection = (index: number) => {
    const section = sectionsRef.current[index];
    if (section)
      void host.request("openFile", {
        path: root + "/" + section.path,
        activation: "pinned",
        placement: "tab",
        viewMode: "source",
      });
  };
  const save = useRef(async (index: number) => openSection(index));
  save.current = async (index: number) => openSection(index);
  const toggle = (index: number) =>
    setSections((current) =>
      current.map((item, i) => (i === index ? { ...item, collapsed: !item.collapsed } : item)),
    );
  const fileState = {
    id: file.documentIdentifier,
    worktreeId: "local",
    filePath: root,
    mode: "diff",
    diffSource: "combined-branch",
  } as any;
  const index = new Map(sections.map((section, i) => [section.key, i]));
  const toolbar = (
    <CombinedDiffToolbar
      activeGroupId="local"
      allSectionsCollapsed={sections.length > 0 && sections.every((s) => s.collapsed)}
      branchCompare={source === "branch" ? ({ baseRef: reference || "HEAD" } as any) : null}
      commitCompare={source === "commit" ? ({ compareRef: reference || "HEAD" } as any) : null}
      commentOwner={null}
      diffCommentCount={0}
      diffCommentsForWorktree={[]}
      diffShowWhitespace={settings.diffShowWhitespace}
      diffWordWrap={settings.diffWordWrap}
      file={fileState}
      fileTreeCollapsed={treeCollapsed}
      isAllMode={false}
      isBranchMode={source === "branch"}
      isCommitMode={source === "commit"}
      notesCopied={false}
      onCopyNotes={() => host.send("clipboard", { text: "" })}
      onOpenAlternateDiff={() => setSource("head")}
      onOpenClearNotes={() => {}}
      onShowFileTree={() => setTreeCollapsed(false)}
      previewDiffComments={[]}
      sectionCount={sections.length}
      setAllSectionsCollapsed={(collapsed) =>
        setSections((current) => current.map((item) => ({ ...item, collapsed })))
      }
      sideBySide={settings.diffSideBySide === true}
      toggleDiffShowWhitespace={() =>
        state.updateSettings({ diffShowWhitespace: !settings.diffShowWhitespace })
      }
      toggleDiffWordWrap={() => state.updateSettings({ diffWordWrap: !settings.diffWordWrap })}
      toggleSideBySide={() => state.updateSettings({ diffSideBySide: !settings.diffSideBySide })}
    />
  );
  return (
    <div className="flex h-full flex-col">
      <div className="flex gap-2 border-b px-3 py-1">
        <select
          aria-label="Compare changes"
          value={source}
          onChange={(event) => setSource(event.target.value)}
        >
          <option value="head">Working tree vs HEAD</option>
          <option value="staged">Staged</option>
          <option value="unstaged">Unstaged</option>
          <option value="branch">Branch</option>
          <option value="commit">Commit</option>
        </select>
        {["branch", "commit"].includes(source) && (
          <input
            aria-label="Git reference"
            value={reference}
            onChange={(event) => setReference(event.target.value)}
          />
        )}
      </div>
      {toolbar}
      {error ? (
        <div role="alert" className="p-4">
          {error}
          <button onClick={() => setEpoch((value) => value + 1)}>Retry</button>
        </div>
      ) : loading ? (
        <div role="status" className="p-4">
          Loading changes…
        </div>
      ) : !sections.length ? (
        <CombinedDiffNoChangesEmptyState commitHeader={null} />
      ) : (
        <div className="flex min-h-0 flex-1">
          <CombinedDiffFileTree
            mode={source === "commit" ? "commit" : "branch"}
            worktreePath={root}
            entries={sections}
            sectionIndexByKey={index}
            activeSectionKey={active}
            viewedSectionKeys={new Set()}
            collapsed={treeCollapsed}
            onCollapsedChange={setTreeCollapsed}
            onNavigate={(entry) => {
              const key =
                (source === "commit" ? "combined-commit:" : "combined-branch:") + entry.path;
              setActive(key);
              const row = index.get(key);
              if (row !== undefined) virtualizer.scrollToIndex(row, { align: "start" });
            }}
          />
          <CombinedDiffSectionList
            activeGroupId="local"
            canOpenWorkspaceFileBrowserForPath={(path) => /\.mdx?$/i.test(path)}
            commentOwner={null}
            diffCommentsForWorktree={[]}
            file={fileState}
            handleSectionSaveRef={save}
            isAllMode={false}
            isBranchMode={true}
            isCommitMode={source === "commit"}
            isDark={dark}
            loadSection={loadSection}
            loadDeferredSection={retry}
            markDirectScrollInput={() => {
              scrollOffset.current = scrollContainer.current?.scrollTop ?? 0;
            }}
            modifiedEditorsRef={modifiedEditors}
            onScrollbarPointerDown={() => {}}
            openSection={openSection}
            openSectionPreview={(section) => {
              void host.request("openFile", {
                path: root + "/" + section.path,
                viewMode: "preview",
                placement: "tab",
                activation: "pinned",
              });
            }}
            retrySection={retry}
            scrollThumb={{ visible: false, top: 0, height: 0 }}
            sectionHeights={heights}
            sections={sections}
            setScrollContainerRef={(node) => {
              scrollContainer.current = node;
            }}
            setSectionHeights={setHeights}
            setSections={setSections}
            sideBySide={settings.diffSideBySide === true}
            skippedConflictNotice={null}
            toggleSection={toggle}
            virtualizer={virtualizer}
          />
        </div>
      )}
    </div>
  );
}
