export type FileSnapshot = {
  documentIdentifier: string;
  filePath: string;
  text: string;
  revision: string;
  kind: number;
  isReadOnly: boolean;
  isDirty: boolean;
  isTooLarge?: boolean;
  byteCount?: number;
  mediaURL?: string;
  rootDirectory?: string;
  mimeType?: string;
};
export type HostOperations = {
  pickImage: { args: Record<string, never>; result: { dataURL?: string; cancelled: boolean } };
  openMarkdownPreview: { args: { path?: string; anchor?: string }; result: unknown };
  openBrowserPreview: { args: Record<string, never>; result: unknown };
  reload: { args: Record<string, never>; result: unknown };
  writeClipboardImage: { args: { data: string }; result: { success: boolean } };
  rename: { args: { path?: string; name: string }; result: { success: boolean } };
  saveDocument: { args: { documentIdentifier: string }; result: { success: boolean } };
  readClipboardText: { args: Record<string, never>; result: string };
  stat: {
    args: { path: string };
    result: { size: number; mtime: number; isDirectory: boolean; fileIdentity: string };
  };
  readRange: {
    args: { path: string; position: number; length: number };
    result: { data: string; byteLength: number; size: number; fileIdentity: string };
  };
  readText: { args: { path: string }; result: { content: string; byteLength: number } };
  listMarkdownDocuments: {
    args: { directoryPath: string };
    result: { relativePath: string; filePath: string; title?: string }[];
  };
  openFile: {
    args: {
      path: string;
      activation?: string;
      placement?: string;
      lineNumber?: number;
      utf16Column?: number;
      viewMode?: string;
      anchor?: string;
    };
    result: unknown;
  };
  openExternal: { args: { url: string }; result: unknown };
  openExternally: { args: { path: string }; result: unknown };
  revealInFinder: { args: { path: string }; result: unknown };
  settings: {
    args: { action: "read" | "update"; settings?: Record<string, unknown> };
    result: Record<string, unknown>;
  };
  annotations: {
    args: { action: "read" | "update"; path: string; comments?: unknown[] };
    result: unknown[];
  };
  gitDiff: {
    args: { path: string; source: string; baseRef?: string; commit?: string };
    result: any;
  };
  gitChanges: {
    args: { directoryPath: string; source: string; baseRef?: string; commit?: string };
    result: any[];
  };
  exportPDF: {
    args: { html: string; title: string };
    result: { success: boolean; cancelled: boolean; filePath?: string };
  };
  saveCopy: {
    args: { data: string; name: string; mimeType: string };
    result: { success: boolean; cancelled: boolean; filePath?: string };
  };
};
export type HostSend = (type: string, payload: unknown, requestIdentifier?: string) => void;
export class HostClient {
  private sequence = 0;
  private prefix = crypto.randomUUID();
  private pending = new Map<
    string,
    {
      resolve: (value: any) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  constructor(public send: HostSend) {}
  request<K extends keyof HostOperations>(
    operation: K,
    args: HostOperations[K]["args"],
  ): Promise<HostOperations[K]["result"]> {
    return new Promise((resolve, reject) => {
      const id = `host-${this.prefix}-${++this.sequence}`;
      const timer = setTimeout(
        () => {
          this.pending.delete(id);
          reject(new Error(`Host request timed out: ${operation}`));
        },
        ["pickImage", "exportPDF", "saveCopy", "saveDocument", "rename"].includes(operation)
          ? 300000
          : 30000,
      );
      this.pending.set(id, { resolve, reject, timer });
      this.send("hostRequest", { operation, args }, id);
    });
  }
  receive(payload: any, id: string) {
    const p = this.pending.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(id);
    if (payload.error) p.reject(new Error(payload.error.message));
    else p.resolve(payload.result);
  }
  dispose() {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("View closed"));
    }
    this.pending.clear();
  }
}
