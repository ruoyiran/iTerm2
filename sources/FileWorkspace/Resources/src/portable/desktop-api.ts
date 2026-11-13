import { request, state } from "./local-state";
import type { HostClient } from "./host-contract";
export function installDesktopAPI(host: HostClient) {
  const contextListeners = new Set<(payload: any) => void>();
  let contextTarget: any = null;
  const writeClipboardText = async (text: string) => host.send("clipboard", { text });
  const readClipboardText = async () => request("readClipboardText", {});
  const filePreview = async (path: string) => {
    const stats = await request("stat", { path });
    if (stats.size > 50 * 1024 * 1024) throw new Error("Image preview is too large");
    let data = "";
    for (let position = 0; position < stats.size; position += 262144) {
      const part = await request("readRange", {
        path,
        position,
        length: Math.min(262144, stats.size - position),
      });
      data += atob(part.data);
    }
    return {
      content: btoa(data),
      isBinary: true,
      mimeType: /\.svg$/i.test(path)
        ? "image/svg+xml"
        : /\.jpe?g$/i.test(path)
          ? "image/jpeg"
          : /\.gif$/i.test(path)
            ? "image/gif"
            : "image/png",
    };
  };
  const api = {
    ui: {
      writeClipboardText,
      readClipboardText,
      setMarkdownEditorFocused: (focused: boolean) => {
        if (focused) host.send("focus", {});
      },
      setRichMarkdownContextMenuTarget: (target: any) => {
        contextTarget = target;
        state.richMarkdownContextTarget = target;
      },
      onRichMarkdownContextCommand: (listener: (payload: any) => void) => {
        contextListeners.add(listener);
        return () => contextListeners.delete(listener);
      },
      writeClipboardImage: async (data: string) => {
        await request("writeClipboardImage", { data });
      },
    },
    shell: {
      openExternal: (url: string) => request("openExternal", { url }),
      openFilePath: async (path: string) => {
        await request("openExternally", { path });
        return true;
      },
      showItemInFolder: (path: string) => request("revealInFinder", { path }),
    },
    fs: {
      readPreviewRange: async ({ url, offset, length }: any) => {
        const path = state.mediaPaths?.get(url);
        if (!path) throw new Error("Unknown media document");
        const result = await request("readRange", {
          path,
          position: offset,
          length: Math.min(length, 262144),
        });
        return Uint8Array.from(atob(result.data), (c) => c.charCodeAt(0));
      },
      readFile: ({ filePath }: { filePath: string }) => filePreview(filePath),
    },
  };
  state.dispatchMarkdownCommand = (payload: any) =>
    contextListeners.forEach((listener) => listener(payload));
  (window as any).api = api;
  return {
    dispatch: (command: any) =>
      contextListeners.forEach((listener) => listener({ ...command, target: contextTarget })),
    dispose: () => {
      contextListeners.clear();
      delete (window as any).api;
    },
  };
}
