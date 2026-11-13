import { useEffect, useState, useMemo, useLayoutEffect } from "react";
import { request, openLink, state } from "./local-state";
import { createRichMarkdownEditorCodec } from "../orca/src/renderer/src/components/editor/rich-markdown/document/rich-markdown-source-transport";
import { createRichMarkdownHtmlSuperscriptLinkContext } from "../orca/src/renderer/src/components/editor/rich-markdown/citations/rich-markdown-html-superscript-link-context";
export function useDocumentDarkTheme() {
  const [dark, setDark] = useState(matchMedia("(prefers-color-scheme: dark)").matches);
  useEffect(() => {
    const media = matchMedia("(prefers-color-scheme: dark)");
    const changed = () => setDark(media.matches);
    media.addEventListener("change", changed);
    return () => media.removeEventListener("change", changed);
  }, []);
  return dark;
}
export function useRichMarkdownSuperscriptLinkSetup({ filePath, worktreeId }: any) {
  const [codec] = useState(createRichMarkdownEditorCodec);
  const worktreeRoot = state.root;
  const [context] = useState(() =>
    createRichMarkdownHtmlSuperscriptLinkContext({
      sourceFilePath: filePath,
      worktreeId,
      worktreeRoot,
      sourceOwner: { kind: "local" },
    }),
  );
  useLayoutEffect(
    () =>
      context.update({
        sourceFilePath: filePath,
        worktreeId,
        worktreeRoot,
        sourceOwner: { kind: "local" },
      }),
    [context, filePath, worktreeId, worktreeRoot],
  );
  return { codec, htmlSuperscriptLinkContext: context, worktreeRoot };
}
const owners = new WeakMap<HTMLElement, () => HTMLElement | null>();
export function registerOverlayFocusOwner(element: HTMLElement, owner: () => HTMLElement | null) {
  owners.set(element, owner);
}
export function handleOverlayCloseAutoFocus(event: Event) {
  const owner = owners.get(event.currentTarget as HTMLElement)?.();
  if (owner) {
    event.preventDefault();
    owner.focus();
  }
}
export async function handleMarkdownPreviewLinkClick({ event, href, context, filePath }: any) {
  event.preventDefault();
  if (href?.startsWith("#")) context.scrollToAnchor(href.slice(1));
  else if (href) await openLink(href, { sourceFilePath: filePath });
}
export function EditorFileLoadErrorView({ message, onRetry }: any) {
  return (
    <div role="alert" className="p-4 text-sm">
      <p>{message}</p>
      <button onClick={onRetry}>Retry</button>
    </div>
  );
}
export async function readLocalImage(args: any) {
  return request("readText", { path: args.filePath });
}
export function useMonacoTheme(isDark?: boolean) {
  const dark = useDocumentDarkTheme();
  return (isDark ?? dark) ? "vs-dark" : "vs";
}
async function fileDataURL(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}
export function useLocalImagePick(editor: any) {
  return async () => {
    if (!editor || editor.isDestroyed) return;
    const selection = { from: editor.state.selection.from, to: editor.state.selection.to };
    const doc = editor.state.doc;
    const result = await request("pickImage", {});
    if (result.dataURL && !editor.isDestroyed && editor.isEditable && editor.state.doc === doc)
      editor
        .chain()
        .focus()
        .insertContentAt(selection, { type: "image", attrs: { src: result.dataURL } })
        .run();
  };
}

export function clipboardHasImage(event: ClipboardEvent) {
  return Array.from(event.clipboardData?.items ?? []).some((item) =>
    item.type.startsWith("image/"),
  );
}
export function handleRichMarkdownImagePaste({ editor, event }: any) {
  const item = Array.from(event.clipboardData?.items ?? []).find((item: any) =>
    item.type.startsWith("image/"),
  ) as DataTransferItem | undefined;
  const file = item?.getAsFile();
  if (!file) return false;
  event.preventDefault();
  void fileDataURL(file).then((src) => {
    if (editor && !editor.isDestroyed && editor.isEditable)
      editor.chain().focus().setImage({ src }).run();
  });
  return true;
}
export function scheduleRichMarkdownBlobImageImport({ editor, slice }: any) {
  if (!editor || !slice) return;
  slice.content.descendants((node: any) => {
    const src = node.attrs.src;
    if (node.type.name === "image" && typeof src === "string" && src.startsWith("blob:"))
      void fetch(src)
        .then((r) => r.blob())
        .then(fileDataURL)
        .then((data) => {
          if (editor.isDestroyed) return;
          const tr = editor.state.tr;
          editor.state.doc.descendants((n: any, pos: number) => {
            if (n.type.name === "image" && n.attrs.src === src)
              tr.setNodeMarkup(pos, undefined, { ...n.attrs, src: data });
          });
          editor.view.dispatch(tr);
        });
  });
}
export function handleRichMarkdownEditorClick({ event, filePath }: any) {
  const anchor = (event.target as HTMLElement)?.closest("a");
  if (!anchor) return false;
  const href = anchor.getAttribute("href");
  if (!href) return false;
  if (event.metaKey || event.ctrlKey) {
    event.preventDefault();
    void openLink(href, { sourceFilePath: filePath });
    return true;
  }
  return false;
}
export const usePluginSyntaxLanguage = (_path: string, language: string) => language;
export const TranslationScopeProvider = ({ children }: any) => children;
export function useGitHubImagePending() {
  const [pending, setPending] = useState(false);
  const pendingRef = { current: pending };
  return { pending, pendingRef, onPending: setPending };
}
