import { BinaryFileDefaultAppButton } from "../orca/src/renderer/src/components/editor/BinaryFileDefaultAppButton";
import { EditorMarkdownFileSurface } from "../orca/src/renderer/src/components/editor/EditorMarkdownFileSurface";
import { EditorFileLoadErrorView } from "../orca/src/renderer/src/components/editor/EditorFileLoadErrorView";
import { getCachedMarkdownRichModeEligibility } from "../orca/src/renderer/src/components/editor/markdown/render-mode/markdown-rich-mode-eligibility-cache";
import { getMarkdownRenderMode } from "../orca/src/renderer/src/components/editor/markdown/render-mode/markdown-render-mode";
import { LocalChanges } from "./local-changes";
import { EditorCommandOwnerContext } from "../orca/src/renderer/src/components/editor/editor-command-owner-context";
import { MarkdownContextMenu } from "./markdown-context-menu";
import DiagramViewerModal from "../orca/src/renderer/src/components/editor/DiagramViewerModal";
import MonacoEditor from "../orca/src/renderer/src/components/editor/MonacoEditor";
import { EditorPanelHeader } from "../orca/src/renderer/src/components/editor/EditorPanelHeader";
import { DiffNavigationProvider } from "../orca/src/renderer/src/components/editor/diff/review/diff-navigation-context";
import {
  extractFrontMatter,
  prependFrontMatter,
  markdownFrontMatterInner,
} from "../orca/src/renderer/src/components/editor/markdown/source-scanning/markdown-frontmatter";
export { getActiveMarkdownExportPayload } from "../orca/src/renderer/src/components/editor/markdown-export-extract";
import { loader } from "@monaco-editor/react";
import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { TooltipProvider } from "../orca/src/renderer/src/components/ui/tooltip";
import ImageViewer from "../orca/src/renderer/src/components/editor/ImageViewer";
import MediaViewer from "../orca/src/renderer/src/components/editor/MediaViewer";
import MermaidViewer from "../orca/src/renderer/src/components/editor/MermaidViewer";
import CsvViewer from "../orca/src/renderer/src/components/editor/csv/CsvViewer";
import CsvPagedViewer from "../orca/src/renderer/src/components/editor/csv/preview/CsvPagedViewer";
import IpynbViewer from "../orca/src/renderer/src/components/editor/notebook/document/IpynbViewer";
import MarkdownPreview from "../orca/src/renderer/src/components/editor/markdown-preview/surface/MarkdownPreview";
import RichMarkdownEditor from "../orca/src/renderer/src/components/editor/rich-markdown/instance/RichMarkdownEditor";
import { flushPendingEditorBuffer } from "../orca/src/renderer/src/components/editor/save/flush/editor-pending-flush";
import { Toaster } from "sonner";
import { state, useAppStore, request, translate } from "./local-state";
import type { FileSnapshot, HostClient } from "./host-contract";
import { viewRoute } from "./view-routes.mjs";
import * as monaco from "monaco-editor/esm/vs/editor/editor.main.js";
loader.config({ monaco });
export { flushPendingEditorBuffer };
class ViewError extends React.Component<any, { error: Error | null }> {
  state = { error: null };
  static getDerivedStateFromError(error: Error) {
    return { error };
  }
  render() {
    return this.state.error ? (
      <EditorFileLoadErrorView
        message={(this.state.error as Error).message}
        onRetry={() => this.setState({ error: null })}
      />
    ) : (
      this.props.children
    );
  }
}
function PagedCSV({ file, host }: any) {
  const [preview, setPreview] = useState<any>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    host.request("stat", { path: file.filePath }).then(
      (snapshot: any) => {
        if (live) setPreview({ readArgs: { filePath: file.filePath }, snapshot });
      },
      (error: Error) => setError(error.message),
    );
    return () => {
      live = false;
    };
  }, [file.filePath, host]);
  return error ? (
    <div role="alert">{error}</div>
  ) : preview ? (
    <CsvPagedViewer
      file={preview}
      filePath={file.filePath}
      preferenceKey={file.filePath}
      onReload={() => host.request("reload", {})}
    />
  ) : (
    <div role="status">Loading table…</div>
  );
}
function Surface({
  file,
  mode,
  content,
  writable,
  change,
  save,
  host,
  onDirty,
  viewerState,
  onExportPDF,
  onSourceReady,
  onCommand,
  onViewChanged,
}: {
  viewerState?: any;
  onExportPDF: () => void;
  onSourceReady: (editor: any) => void;
  onCommand: (command: string) => void;
  onViewChanged: (route: string) => void;
  file: FileSnapshot;
  mode: string;
  content: string;
  writable: boolean;
  change: (value: string) => void;
  save: (value: string) => Promise<boolean>;
  host: HostClient;
  onDirty: (dirty: boolean) => void;
}) {
  const requestedRoute = viewRoute(file.kind, mode),
    key = file.documentIdentifier;
  const sizeOverride = useAppStore((s) => s.markdownRichModeSizeOverrides?.[key] === true);
  const eligibility =
    file.kind === 1 && requestedRoute === "rich"
      ? getCachedMarkdownRichModeEligibility({ content, sizeOverridden: sizeOverride })
      : { exceedsSizeLimit: false, unsupportedMessage: null };
  const renderMode = getMarkdownRenderMode({
    viewMode: (mode ?? "rich") as any,
    exceedsRichModeSizeLimit: eligibility.exceedsSizeLimit,
    hasRichModeUnsupportedContent: !!eligibility.unsupportedMessage,
  });
  const route =
    file.kind === 1 && requestedRoute !== "changes"
      ? renderMode === "rich-editor"
        ? "rich"
        : renderMode
      : requestedRoute;
  useEffect(() => onViewChanged(route), [route, file.documentIdentifier]);
  const [docs, setDocs] = useState<any[]>([]);
  const [toc, setToc] = useState(false);
  const modal = useAppStore((s) => s.modal);
  const settings = useAppStore((s) => s.settings);
  const hostError = useAppStore((s) => s.hostError);
  const frontmatterVisible = useAppStore((s) => s.markdownFrontmatterVisible[key] !== false);
  useEffect(() => {
    let active = true;
    if (file.kind === 1)
      host
        .request("listMarkdownDocuments", {
          directoryPath: file.filePath.slice(0, file.filePath.lastIndexOf("/")),
        })
        .then(
          (documents) => {
            if (active) setDocs(documents);
          },
          () => setDocs([]),
        );
    return () => {
      active = false;
    };
  }, [file.filePath, file.kind, host]);
  const frontmatter = extractFrontMatter(content);
  useEffect(() => {
    if (typeof viewerState?.tableOfContents === "boolean") setToc(viewerState.tableOfContents);
  }, [viewerState]);
  const common = { content, filePath: file.filePath, scrollCacheKey: key };
  const edit = {
    ...common,
    fileId: key,
    worktreeId: "local",
    onContentChange: change,
    onSave: save,
    onDirtyStateHint: onDirty,
  };
  let viewer;
  const sourceEditor = (
    <MonacoEditor
      {...edit}
      onEditorReady={onSourceReady}
      readOnly={!writable}
      viewStateKey={key}
      viewStateId={key}
      relativePath={file.filePath.slice(state.root.length + 1)}
      language={
        monaco.languages
          .getLanguages()
          .find((language) => language.extensions?.includes("." + file.filePath.split(".").pop()))
          ?.id ?? "plaintext"
      }
      markdownDocuments={docs}
      markdownAnnotationsEnabled={file.kind === 1}
    />
  );
  if (file.kind === 1 && route !== "changes")
    viewer = (
      <EditorMarkdownFileSurface
        activeFile={{ ...state.openFiles[0], readOnly: !writable }}
        viewStateScopeId={key}
        editorViewStateKey={key}
        currentContent={content}
        mdViewMode={(mode ?? "rich") as any}
        inlineMarkdownRenderState={{
          renderMode,
          richModeUnsupportedMessage: eligibility.unsupportedMessage,
        }}
        showMarkdownTableOfContents={toc}
        showMarkdownFrontmatter={frontmatterVisible}
        onCloseMarkdownTableOfContents={() => setToc(false)}
        markdownAnnotationsEnabled
        markdownDocuments={
          {
            markdownDocuments: docs,
            mdSave: save,
            onOpenDocLink: (href: string) =>
              state.activateMarkdownLink(href, { sourceFilePath: file.filePath }),
            previewProps: {
              initialAnchor: viewerState?.anchor ?? null,
              markdownDocuments: docs,
              onOpenDocument: (document: any) => state.openFile(document),
            },
          } as any
        }
        getMarkdownSourceLineOffset={(raw) => raw.split("\n").length - 1}
        handleContentChange={change}
        handleDirtyStateHint={onDirty}
        monacoEditor={sourceEditor}
      />
    );
  else if (route === "source") viewer = sourceEditor;
  else if (["image", "pdf", "svg"].includes(route))
    viewer = (
      <ImageViewer
        filePath={file.filePath}
        src={file.mediaURL}
        byteSize={file.byteCount}
        svgSource={route === "svg" ? content : undefined}
        mimeType={
          route === "pdf" ? "application/pdf" : route === "svg" ? "image/svg+xml" : file.mimeType
        }
        preferenceKey={key}
        scrollCacheKey={key}
      />
    );
  else if (["audio", "video"].includes(route))
    viewer = (
      <MediaViewer
        src={file.mediaURL ?? ""}
        filePath={file.filePath}
        mimeType={file.mimeType ?? route + "/unknown"}
        canOpenLocally
        playbackCacheKey={key}
      />
    );
  else if (route === "mermaid") viewer = <MermaidViewer content={content} scrollCacheKey={key} />;
  else if (route === "csv")
    viewer = file.isTooLarge ? (
      <PagedCSV file={file} host={host} />
    ) : (
      <CsvViewer
        {...edit}
        onContentChange={writable ? change : undefined}
        isDirty={file.isDirty}
        preferenceKey={key}
      />
    );
  else if (route === "notebook") viewer = <IpynbViewer {...edit} readOnly={!writable} />;
  else if (route === "changes") viewer = <LocalChanges file={file} host={host} />;
  else
    viewer = (
      <div className="flex h-full flex-col">
        <div className="flex flex-1 flex-col items-center justify-center gap-3 text-sm text-muted-foreground">
          {translate(
            "auto.components.editor.EditorContent.b9de81ba52",
            "Binary file — cannot display",
          )}
          <BinaryFileDefaultAppButton source={{ filePath: file.filePath } as any} />
        </div>
      </div>
    );
  const activeFile = {
    ...state.openFiles[0],
    isDirty: file.isDirty,
    csvPreviewOnly: file.kind === 7 && file.isTooLarge,
    mode: route === "preview" ? "markdown-preview" : "edit",
  };
  const editableKind = [0, 1, 5, 6, 7, 8].includes(file.kind);
  const modes =
    file.kind === 1
      ? ["source", "rich", "preview", "changes"]
      : [5, 6, 7, 8].includes(file.kind)
        ? ["source", "rich", "changes"]
        : editableKind
          ? ["edit", "changes"]
          : [];
  const toggleValue =
    file.kind === 1
      ? (mode ?? "rich")
      : route === "changes"
        ? "changes"
        : route === "source"
          ? file.kind === 0
            ? "edit"
            : "source"
          : route === "preview"
            ? "preview"
            : "rich";
  return (
    <TooltipProvider>
      <EditorCommandOwnerContext.Provider value={true}>
        <DiffNavigationProvider>
          <div
            className="h-full flex flex-col"
            data-orca-view={route}
            data-document-identifier={file.documentIdentifier}
            data-toc-visible={toc}
            data-frontmatter-visible={frontmatterVisible}
          >
            {hostError && (
              <div role="alert" className="px-3 py-2 text-destructive">
                {hostError}
              </div>
            )}
            <EditorPanelHeader
              activeFile={activeFile}
              copiedPathVisible={false}
              isSingleDiff={false}
              isDiffSurface={route === "changes"}
              isMarkdown={file.kind === 1}
              isCsv={file.kind === 7}
              isNotebook={file.kind === 8}
              isSvg={[5, 6].includes(file.kind)}
              hasEditorToggle={modes.length > 0}
              availableEditorToggleModes={modes as any}
              effectiveToggleValue={toggleValue}
              canOpenPreview={/\.html?$/i.test(file.filePath)}
              canShowMarkdownPreview={file.kind === 1}
              canShowMarkdownTableOfContents={file.kind === 1}
              isMarkdownTableOfContentsDisabled={route === "source" || route === "changes"}
              shouldShowMarkdownExportAction={file.kind === 1}
              canExportMarkdownToPdf={["rich", "preview"].includes(route)}
              showMarkdownTableOfContents={toc}
              canShowMarkdownFrontmatterToggle={file.kind === 1 && !!frontmatter}
              markdownFrontmatterVisible={frontmatterVisible}
              sideBySide={settings.diffSideBySide === true}
              openFileState={{ canOpen: true }}
              onCopyPath={() => host.send("clipboard", { text: file.filePath })}
              onOpenDiffTargetFile={() =>
                host.send("command", { command: "setViewMode", viewMode: "source" })
              }
              onOpenPreview={() => host.request("openBrowserPreview", {})}
              onOpenMarkdownPreview={() => host.request("openMarkdownPreview", {})}
              onToggleSideBySide={() =>
                state.updateSettings({ diffSideBySide: !settings.diffSideBySide })
              }
              onEditorToggleChange={(viewMode) =>
                host.send("command", {
                  command: "setViewMode",
                  viewMode: viewMode === "edit" ? "source" : viewMode,
                })
              }
              onToggleMarkdownTableOfContents={() => setToc(!toc)}
              onToggleMarkdownFrontmatter={() =>
                state.setMarkdownFrontmatterVisible(key, !frontmatterVisible)
              }
              onExportMarkdownToPdf={onExportPDF}
            />
            <div className="flex-1 min-h-0" data-portable-content>
              <ViewError key={key + route}>
                {route === "rich" ? (
                  <MarkdownContextMenu writable={writable} onCommand={onCommand}>
                    {viewer}
                  </MarkdownContextMenu>
                ) : (
                  viewer
                )}
              </ViewError>
            </div>
            {modal?.name === "diagram-viewer" && <DiagramViewerModal />}
            <Toaster />
          </div>
        </DiffNavigationProvider>
      </EditorCommandOwnerContext.Provider>
    </TooltipProvider>
  );
}
export function createViewer(root: HTMLElement) {
  const react = createRoot(root);
  return {
    render: (props: any) => react.render(<Surface {...props} />),
    dispose: () => react.unmount(),
  };
}
