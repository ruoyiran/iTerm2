import catalogs from "./orca-locales.json";
import { filesystemPathToFileUri } from "../orca/src/shared/file-links/file-uri-path";
import { parseMarkdownPreviewLineTarget } from "../orca/src/renderer/src/components/editor/markdown-preview/links/markdown-preview-editor-reveal";
import { useSyncExternalStore, useRef, useState, useCallback, useEffect } from "react";
import type { HostClient, FileSnapshot } from "./host-contract";
const listeners = new Set<() => void>();
let host: HostClient;
export function notifyState() {
  for (const listener of listeners) listener();
}
export const defaults = {
  editorWordWrap: true,
  markdownDefaultViewMode: "rich",
  diffSideBySide: false,
  editorAutoSave: false,
  richMarkdownSpellcheckEnabled: true,
  editorFontZoomLevel: 0,
  theme: "system",
  uiFontFamily: "Geist",
};
export const state: any = {
  settings: defaults,
  annotationOwners: {},
  annotationData: {},
  annotationLoading: new Set(),
  mediaPaths: new Map(),
  keybindings: {},
  editorFontZoomLevel: 0,
  markdownFrontmatterVisible: {},
  markdownTocExpandedPaths: {},
  openFiles: [],
  worktreesByRepo: {},
  pendingEditorFocusRequest: null,
  comments: [],
  modal: null,
  theme: "system",
  effectiveTheme: "light",
  activeFileIdByWorktree: {},
  activeGroupIdByWorktree: {},
  folderWorkspaces: [],
};
export function useAppStore<T>(selector: (s: any) => T): T {
  useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => state.version ?? 0,
  );
  return selector(state);
}
useAppStore.getState = () => state;
useAppStore.subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
export function updateState(values: any) {
  Object.assign(state, values);
  state.version = (state.version ?? 0) + 1;
  notifyState();
}
export function initializeHost(client: HostClient) {
  if (host !== client) {
    state.annotationOwners = {};
    state.annotationData = {};
    state.annotationLoading = new Set();
  }
  host = client;
  return host.request("settings", { action: "read" }).then((settings) =>
    updateState({
      settings: { ...defaults, ...settings },
      editorFontZoomLevel: settings.editorFontZoomLevel ?? 0,
      combinedDiffFileTreeWidth: settings.combinedDiffFileTreeWidth ?? 240,
    }),
  );
}
export function setDocumentState(snapshot: FileSnapshot) {
  const pathChanged =
    state.filePath !== snapshot.filePath || state.openFiles[0]?.id !== snapshot.documentIdentifier;
  if (snapshot.mediaURL) {
    state.mediaPaths.set(snapshot.mediaURL, snapshot.filePath);
    if (state.mediaPaths.size > 8) state.mediaPaths.delete(state.mediaPaths.keys().next().value);
  }
  const directory =
    snapshot.rootDirectory ?? snapshot.filePath.slice(0, snapshot.filePath.lastIndexOf("/"));
  updateState({
    editorDrafts: { [snapshot.documentIdentifier]: snapshot.text },
    filePath: snapshot.filePath,
    root: directory,
    openFiles: [
      {
        id: snapshot.documentIdentifier,
        worktreeId: "local",
        mode: "edit",
        isDirty: snapshot.isDirty,
        readOnly: snapshot.isReadOnly,
        filePath: snapshot.filePath,
        relativePath: snapshot.filePath.slice(directory.length + 1),
      },
    ],
    worktreesByRepo: { local: [{ id: "local", path: directory }] },
  });
}

export const request = (operation: any, args: any) => host.request(operation, args);
export async function openLink(href: string, options: any = {}) {
  const url = new URL(href, filesystemPathToFileUri(options.sourceFilePath ?? state.filePath));
  if (["http:", "https:", "mailto:"].includes(url.protocol))
    return request("openExternal", { url: url.href });
  if (url.protocol === "file:") {
    const path = decodeURIComponent(url.pathname),
      line = parseMarkdownPreviewLineTarget(url.hash);
    if (options.external) return request("openExternally", { path });
    return request("openFile", {
      path,
      anchor: line ? undefined : url.hash.slice(1),
      lineNumber: line?.line,
      utf16Column: line?.column,
      viewMode: line ? "source" : undefined,
      activation: "pinned",
      placement: "tab",
    });
  }
  throw new Error("Unsupported link protocol");
}
state.activateMarkdownLink = openLink;
state.openFile = (options: any) =>
  request("openFile", { path: options.filePath, activation: "pinned", placement: "tab" });
state.openMarkdownPreview = (options: any, view: any) =>
  request("openFile", {
    path: options.filePath,
    viewMode: "preview",
    anchor: view?.anchor,
    activation: "pinned",
    placement: "tab",
  });
state.setMarkdownViewMode = (_id: string, viewMode: string) =>
  host.send("command", { command: "setViewMode", viewMode });
state.openModal = (name: string, data: any) =>
  updateState({ modal: { name, data }, modalData: data });
state.closeModal = () => updateState({ modal: null });
state.consumeEditorFocusRequest = () => updateState({ pendingEditorFocusRequest: null });
state.setMarkdownTocExpandedPaths = (id: string, paths: string[]) =>
  updateState({ markdownTocExpandedPaths: { ...state.markdownTocExpandedPaths, [id]: paths } });
state.setMarkdownFrontmatterVisible = (id: string, value: boolean) =>
  updateState({ markdownFrontmatterVisible: { ...state.markdownFrontmatterVisible, [id]: value } });
async function writeComments(comments: any[], owner: any) {
  if (!owner || state.annotationOwners[owner.filePath] !== owner || owner.root !== state.root)
    return false;
  const path = owner.filePath;
  let result;
  try {
    result = await host.request("annotations", { action: "update", path, comments });
  } catch (error) {
    updateState({ hostError: (error as Error).message });
    return false;
  }
  if (state.annotationOwners[path] === owner)
    updateState({ annotationData: { ...state.annotationData, [path]: result } });
  return true;
}
state.addDiffComment = async (owner: any, comment: any) =>
  writeComments(
    [
      ...(state.annotationData[owner?.filePath] ?? []),
      { ...comment, worktreeId: "local", id: crypto.randomUUID(), createdAt: Date.now() },
    ],
    owner,
  );
state.deleteDiffComment = async (owner: any, id: string) =>
  writeComments(
    (state.annotationData[owner?.filePath] ?? []).filter((c: any) => c.id !== id),
    owner,
  );
state.updateDiffComment = async (owner: any, id: string, body: any) =>
  writeComments(
    (state.annotationData[owner?.filePath] ?? []).map((c: any) =>
      c.id === id ? { ...c, ...(typeof body === "string" ? { body } : body) } : c,
    ),
    owner,
  );
state.clearDeliveredDiffComments = async (owner: any) =>
  writeComments(
    (state.annotationData[owner?.filePath] ?? []).filter((c: any) => !c.sentAt),
    owner,
  );
export const localOwner = { kind: "local", worktreeId: "local" };
export function useDiffCommentView(_worktreeId?: string, source?: any) {
  const path =
    source?.filePath && source.filePath !== state.root ? source.filePath : state.filePath;
  const owner = path
    ? (state.annotationOwners[path] ??= {
        kind: "local",
        worktreeId: "local",
        filePath: path,
        root: state.root,
      })
    : null;
  const comments = useAppStore((s) => s.annotationData[path]);
  useEffect(() => {
    if (!owner || state.annotationData[path] !== undefined || state.annotationLoading.has(path))
      return;
    state.annotationLoading.add(path);
    void host
      .request("annotations", { action: "read", path })
      .then(
        (comments) => {
          if (state.annotationOwners[path] === owner)
            updateState({ annotationData: { ...state.annotationData, [path]: comments } });
        },
        (error) => updateState({ hostError: error.message }),
      )
      .finally(() => state.annotationLoading.delete(path));
  }, [owner, path]);
  return { owner: comments === undefined ? null : owner, comments };
}
export function useOwnedDiffCommentTarget<T>(worktreeId?: string, source?: any) {
  const [value, setValue] = useState<T | null>(null);
  const current = useDiffCommentView(worktreeId, source).owner;
  const owner = useRef<any>(null);
  const claim = useCallback(
    (value: T | null) => {
      if (value !== null) owner.current = current;
      setValue(value);
    },
    [current],
  );
  return [value, claim, owner] as const;
}

export const diffCommentOwnerKey = (owner: any) => JSON.stringify([owner?.root, owner?.filePath]);
export const sameDiffCommentOwner = (a: any, b: any) =>
  diffCommentOwnerKey(a) === diffCommentOwnerKey(b);
export const isSameDiffCommentOwner = sameDiffCommentOwner;
let locale = "en";
export function setUILocale(value: string) {
  const normalized = value.replace("_", "-");
  locale = /^zh-(Hant|TW|HK)/i.test(normalized) ? "zh-Hant" : normalized.split("-")[0];
  if (!(locale in catalogs)) locale = "en";
  updateState({ locale });
}
export function translate(
  key: string,
  fallback: string = key,
  values: Record<string, unknown> = {},
) {
  const catalog = (catalogs as Record<string, Record<string, string>>)[locale] ?? {};
  const plural =
    typeof values.count === "number" ? new Intl.PluralRules(locale).select(values.count) : null;
  const text =
    (plural ? catalog[key + "_" + plural] : undefined) ??
    catalog[key] ??
    (plural && typeof values["defaultValue_" + plural] === "string"
      ? String(values["defaultValue_" + plural])
      : fallback);
  return text.replace(/\{\{(\w+)\}\}/g, (_all, k) => String(values[k] ?? ""));
}
export const useTranslate = () => translate;
export const useIntlLocale = () => locale;
export const useUiLanguageRevision = () => 0;
export const getUiLanguageRevision = () => 0;
export const getUiLanguage = () => locale;
export const getUiIntlLocale = () => locale;
export const getUiCollator = (options: any) => new Intl.Collator(locale, options);
export const createConnectionIdForFileSelector = () => () => null;
export const getConnectionIdForFile = () => null;
export const selectWorktreesByRepo = (s: any) => s.worktreesByRepo;
export const findFirstIndexedWorktree = (records: any, id: string) =>
  Object.values(records)
    .flat()
    .find((w: any) => w.id === id);
export const useFileOwnerRuntimeTarget = () => localOwner;
export const runtimeTargetEnvironmentId = () => null;
export const localRuntimeTarget = () => localOwner;
export const requireRuntimeTargetForFileOwner = () => localOwner;
export const editorBufferSiblingViewIds = (_s: any, id: string) => [id];
export const ORCA_EDITOR_FILE_SAVED_EVENT = "orca:editor-file-saved";
export const ORCA_EDITOR_QUIESCE_FILE_SAVES_EVENT = "orca:editor-quiesce-file-saves";
export const openHttpLink = openLink;
export const openAppHttpLink = openLink;
export async function readRuntimeFileRange(args: any, position: number, length: number) {
  const bytes = new Uint8Array(length);
  let consumed = 0;
  let identity: string | undefined;
  while (consumed < length) {
    const result = await request("readRange", {
      path: args.filePath,
      position: position + consumed,
      length: Math.min(length - consumed, 262144),
    });
    if (identity && identity !== result.fileIdentity)
      throw new Error("File changed during range read");
    identity = result.fileIdentity;
    const chunk = Uint8Array.from(atob(result.data), (c: string) => c.charCodeAt(0));
    bytes.set(chunk, consumed);
    consumed += chunk.length;
    if (chunk.length === 0 || position + consumed >= result.size) break;
  }
  return bytes.subarray(0, consumed);
}

export const statRuntimeReadTarget = (args: any) => request("stat", { path: args.filePath });
export const sameRuntimeFileSnapshot = (a: any, b: any) =>
  a.size === b.size && a.fileIdentity === b.fileIdentity;
export const isEventTargetInsideFloatingWorkspacePanel = () => false;
export const getConnectionId = () => null;
export const uiCollator = (options: any) => new Intl.Collator(locale, options);
export const createLocalizedCatalog = <T>(factory: () => T) => factory;
export const readRuntimeFilePreview = (_args: any, path: string) =>
  (window as any).api.fs.readFile({ filePath: path });
export const getResolvedExecutionHostIdForWorktree = () => "local";
export const getRuntimeTargetForFileOwner = () => localOwner;
export const NO_RESOURCE_EVIDENCE = {};
state.scrollToDiffCommentId = null;
state.setScrollToDiffCommentId = (id: string | null) => updateState({ scrollToDiffCommentId: id });
export const uiNumberFormat = (options: any) => new Intl.NumberFormat(locale, options);
export const preferenceStorage = {
  getItem(key: string) {
    const values = state.settings.viewerPreferences?.[key];
    return values === undefined ? null : JSON.stringify(values);
  },
  setItem(key: string, text: string) {
    const viewerPreferences = { ...state.settings.viewerPreferences, [key]: JSON.parse(text) };
    updateState({ settings: { ...state.settings, viewerPreferences } });
    void request("settings", { action: "update", settings: { viewerPreferences } }).catch(
      (error: Error) => updateState({ hostError: error.message }),
    );
  },
  removeItem(key: string) {
    const viewerPreferences = { ...state.settings.viewerPreferences };
    delete viewerPreferences[key];
    updateState({ settings: { ...state.settings, viewerPreferences } });
    void request("settings", { action: "update", settings: { viewerPreferences } }).catch(
      (error: Error) => updateState({ hostError: error.message }),
    );
  },
};
export function useVisibleWorktreeDiffComments(worktreeId?: string, source?: any) {
  const result = useDiffCommentView(worktreeId, source);
  return { ...result, comments: result.comments ?? [], markdownReviewNotesEnabled: true };
}
export const isVirtualEditorFile = () => false;
export const getOpenFileRevealOwner = () => localOwner;
export const getRevealInFileManagerLabel = () => "Reveal in Finder";
export const revealInFileManager = (path: string) => request("revealInFinder", { path });
state.updateSettings = async (settings: any) => {
  try {
    const result = await request("settings", { action: "update", settings });
    updateState({ settings: { ...state.settings, ...result }, hostError: null });
  } catch (error) {
    updateState({ hostError: (error as Error).message });
  }
};
state.setMarkdownDefaultViewMode = (markdownDefaultViewMode: string) =>
  state.updateSettings({ markdownDefaultViewMode });
state.pendingEditorReveal = null;
state.setPendingEditorReveal = (pendingEditorReveal: any) => updateState({ pendingEditorReveal });
state.setEditorCursorLine = (line: number) => {
  state.editorCursorLine = line;
};
export const getEditorModelOwnerKey = (file: any) => JSON.stringify([state.root, file.id]);
export const isEditorModelDirty = (s: any, file: any) =>
  s.openFiles.some((tab: any) => tab.filePath === file.filePath && tab.isDirty);
export const notifyEditorFileCacheStale = () => host.send("command", { command: "reload" });
state.editorDrafts = {};
state.showRightSidebarSearch = ({ query }: any) =>
  host.send("command", { command: "findInFiles", query });
state.combinedDiffFileTreeWidth = 240;
state.setCombinedDiffFileTreeWidth = (width: number) => {
  updateState({ combinedDiffFileTreeWidth: width });
  void state.updateSettings({ combinedDiffFileTreeWidth: width });
};
export function writeWorkspaceFileDragSourceForWorkspace(data: DataTransfer) {
  const path = data.getData("application/x-orca-workspace-file-path");
  if (path) data.setData("text/uri-list", encodeURI("file://" + path));
}

export const useAppStateValue = useAppStore;
export const canPreviewLanguage = (language: string) => language === "markdown";
state.markdownRichModeSizeOverrides = {};
state.setMarkdownRichModeSizeOverride = (id: string, value: boolean) =>
  updateState({
    markdownRichModeSizeOverrides: { ...state.markdownRichModeSizeOverrides, [id]: value },
  });
