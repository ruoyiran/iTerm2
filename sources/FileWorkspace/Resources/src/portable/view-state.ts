import {
  scrollTopCache,
  pdfViewPositionCache,
  mediaPlaybackPositionCache,
} from "../orca/src/renderer/src/components/editor/model-lifetime/retention/editor-view-state-cache";
export { requestViewerZoom } from "../orca/src/renderer/src/components/editor/viewer-zoom-request";
export function captureViewerState(root: HTMLElement, key: string) {
  const scrolls = Array.from(root.querySelectorAll<HTMLElement>(".scrollbar-editor"))
    .map((el) => ({ top: el.scrollTop, left: el.scrollLeft }))
    .slice(0, 8);
  const media = root.querySelector<HTMLMediaElement>("audio,video");
  const surface = root.querySelector<HTMLElement>("[data-orca-view]");
  return {
    tableOfContents: surface?.dataset.tocVisible === "true",
    frontmatterVisible: surface?.dataset.frontmatterVisible !== "false",
    scrolls,
    pdf: pdfViewPositionCache.get(key),
    mediaTime: media?.currentTime ?? mediaPlaybackPositionCache.get(key),
  };
}
export function restoreViewerState(key: string, value: any) {
  if (value?.scrolls?.[0])
    for (const cacheKey of [key, key + ":rich", key + ":preview"])
      scrollTopCache.set(cacheKey, Math.max(0, Number(value.scrolls[0].top) || 0));
  if (value?.pdf) pdfViewPositionCache.set(key, value.pdf);
  if (Number.isFinite(value?.mediaTime)) mediaPlaybackPositionCache.set(key, value.mediaTime);
}
export function restoreLiveScrolls(root: HTMLElement, value: any, isCurrent = () => true) {
  if (!Array.isArray(value?.scrolls)) return;
  const apply = () => {
    if (!isCurrent()) return;
    Array.from(root.querySelectorAll<HTMLElement>(".scrollbar-editor")).forEach((el, index) => {
      const s = value.scrolls[index];
      if (s) {
        el.scrollTop = Math.max(0, Number(s.top) || 0);
        el.scrollLeft = Math.max(0, Number(s.left) || 0);
      }
    });
  };
  requestAnimationFrame(apply);
}
import { monaco } from "../orca/src/renderer/src/lib/editor/monaco/monaco-setup";
export function sourceEditorIn(root: HTMLElement) {
  const editors = monaco.editor
    .getEditors()
    .filter((editor) => root.contains(editor.getContainerDomNode()));
  return (
    editors.find((editor) => editor.hasTextFocus()) ??
    editors.find((editor) => editor.getContainerDomNode().closest(".editor.modified")) ??
    editors.at(-1)
  );
}
