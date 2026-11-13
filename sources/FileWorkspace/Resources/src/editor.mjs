import { DocumentSync } from "./document-sync.mjs";
import { HostClient } from "./portable/host-contract.ts";
import { initializeHost, setDocumentState, state } from "./portable/local-state.ts";
import { installDesktopAPI } from "./portable/desktop-api.ts";
import {
  createViewer,
  flushPendingEditorBuffer,
  getActiveMarkdownExportPayload,
} from "./portable/viewers.tsx";
import { viewRoute, applyContentChange } from "./portable/view-routes.mjs";
import {
  captureViewerState,
  restoreViewerState,
  restoreLiveScrolls,
  requestViewerZoom,
  sourceEditorIn,
} from "./portable/view-state.ts";
import { element } from "./explorer.mjs";
export class FileEditor {
  constructor(root, send, t) {
    this.root = root;
    this.send = send;
    this.t = t;
    this.authorized = false;
    this.readOnly = true;
    this.mode = null;
    this.editor = null;
    this.pendingPastes = [];
    this.pasteWaiters = [];
    this.viewerState = null;
    this.pendingPresentation = [];
    this.loadingDocumentIdentifier = null;
    this.pendingFocus = null;
    this.displayedRoute = null;
    this.structuredDirty = false;
    this.disposed = false;
    this.host = new HostClient(send);
    this.desktopAPI = installDesktopAPI(this.host);
    this.sync = new DocumentSync({
      send: (payload) => send("edits", payload),
      changed: () => this.status(),
    });
    root.className = "editor-shell";
    this.error = element("div", "editor-error");
    this.error.hidden = true;
    this.container = element("div", "portable-viewer");
    root.replaceChildren(this.error, this.container);
    this.viewer = createViewer(this.container);
    this.settingsReady = initializeHost(this.host).catch((error) => this.showHostError(error));
    this.onCompositionStart = () => {
      if (this.writable()) {
        this.sync.composing = true;
        this.status();
      }
    };
    this.onCompositionEnd = () => {
      flushPendingEditorBuffer(state, this.sync.documentIdentifier);
      this.sync.endComposition();
      this.render();
    };
    this.onSelection = () => this.status();
    document.addEventListener("selectionchange", this.onSelection);
    this.selectionObserver = new MutationObserver((changes) => {
      if (!this.surfaceReady || changes.some((change) => change.type === "attributes"))
        this.status();
    });
    this.selectionObserver.observe(root, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["aria-selected"],
    });
    this.onFocus = () => send("focus", {});
    this.onScroll = () => this.viewState();
    this.onPaste = (event) => {
      if (!this.writable() || !this.editor || this.activeRoute() !== "source") return;
      const text = event.clipboardData?.getData("text/plain");
      if (text !== undefined) {
        event.preventDefault();
        this.paste(text);
      }
    };
    root.addEventListener("compositionstart", this.onCompositionStart);
    root.addEventListener("compositionend", this.onCompositionEnd);
    root.addEventListener("focusin", this.onFocus);
    root.addEventListener("keyup", this.onSelection);
    root.addEventListener("pointerup", this.onSelection);
    root.addEventListener("scroll", this.onScroll, true);
    root.addEventListener("paste", this.onPaste, true);
  }
  textInput() {
    const input = document.activeElement;
    return input &&
      this.root.contains(input) &&
      ["INPUT", "TEXTAREA"].includes(input.tagName) &&
      !input.closest(".monaco-editor,.tiptap")
      ? input
      : null;
  }
  activeRoute() {
    return this.displayedRoute ?? viewRoute(this.snapshot?.kind, this.mode);
  }
  intrinsicallyReadOnly() {
    return this.readOnly || !["source", "rich", "csv", "notebook"].includes(this.activeRoute());
  }
  writable() {
    return (
      !this.intrinsicallyReadOnly() &&
      this.authorized &&
      !this.sync.error &&
      (!this.sync.suspended || this.sync.composing)
    );
  }
  resolveMode(mode) {
    if (this.snapshot?.kind === 7 && this.snapshot.isTooLarge && mode === "source") return null;
    return mode && mode !== "default"
      ? mode
      : this.snapshot?.kind === 1
        ? (state.settings.markdownDefaultViewMode ?? "rich")
        : null;
  }
  beginDocument(documentIdentifier) {
    if (
      typeof documentIdentifier !== "string" ||
      documentIdentifier === this.sync.documentIdentifier
    )
      return;
    if (this.loadingDocumentIdentifier === documentIdentifier) return;
    if (this.loadingDocumentIdentifier || this.snapshot) {
      this.pendingPresentation = [];
      this.pendingSelection = null;
      this.pendingReveal = null;
      this.viewerState = null;
      if (this.pendingFocus?.documentIdentifier !== documentIdentifier) this.pendingFocus = null;
    }
    this.loadingDocumentIdentifier = documentIdentifier;
  }
  applyPresentation(type, payload) {
    if (type === "viewFlags" || type === "command") {
      flushPendingEditorBuffer(state, this.sync.documentIdentifier);
      this.mode = this.resolveMode(payload.viewMode);
    } else if (type === "restoreViewState") {
      if (typeof payload.viewerState?.frontmatterVisible === "boolean")
        state.setMarkdownFrontmatterVisible(
          this.sync.documentIdentifier,
          payload.viewerState.frontmatterVisible,
        );
      restoreViewerState(this.sync.documentIdentifier, payload.viewerState);
      this.viewerState = payload.viewerState;
      this.mode = this.resolveMode(
        payload.viewMode ??
          (payload.showsMarkdownPreview === true
            ? "preview"
            : payload.showsMarkdownPreview === false
              ? "source"
              : this.mode),
      );
      this.pendingReveal = null;
      this.restoreSelection(payload);
    } else if (type === "reveal") {
      const position = {
        lineNumber: Math.max(1, payload.lineNumber),
        column: Math.max(1, payload.utf16Column),
      };
      if (this.editor) {
        this.editor.setPosition(position);
        this.editor.revealPositionInCenter(position);
      } else this.pendingReveal = position;
    }
  }
  requestFocus() {
    this.pendingFocus = {
      documentIdentifier: this.loadingDocumentIdentifier ?? this.sync.documentIdentifier ?? null,
    };
    this.applyPendingFocus();
  }
  applyPendingFocus() {
    const request = this.pendingFocus;
    if (
      !request ||
      !this.surfaceReady ||
      this.disposed ||
      this.loadingDocumentIdentifier ||
      this.sync.error
    )
      return;
    if (request.documentIdentifier && request.documentIdentifier !== this.sync.documentIdentifier)
      return;
    const target =
      this.activeRoute() === "source"
        ? this.editor
        : (this.container.querySelector(".tiptap") ??
          this.container.querySelector("[data-portable-content] [tabindex]") ??
          this.container);
    if (!target) return;
    this.pendingFocus = null;
    if (target instanceof HTMLElement && !target.hasAttribute("tabindex")) target.tabIndex = -1;
    target.focus();
  }
  async document(snapshot, edits) {
    this.beginDocument(snapshot.documentIdentifier);
    await this.settingsReady;
    if (
      this.disposed ||
      (this.loadingDocumentIdentifier &&
        this.loadingDocumentIdentifier !== snapshot.documentIdentifier)
    )
      return;
    const changed = this.sync.documentIdentifier !== snapshot.documentIdentifier;
    if (changed && this.pendingPastes.length)
      throw new Error("Document changed before admitted paste completed");
    this.snapshot = snapshot;
    this.readOnly = !!snapshot.isReadOnly;
    if (changed) {
      this.displayedRoute = null;
      this.surfaceReady = false;
      this.sourceReadyDocument = null;
      this.editor = null;
      this.sync.open(snapshot);
      this.mode = this.resolveMode(null);
      this.structuredDirty = false;
    } else this.sync.remote(snapshot, edits);
    setDocumentState({ ...snapshot, text: this.sync.raw.text });
    this.loadingDocumentIdentifier = null;
    for (const message of this.pendingPresentation.splice(0))
      this.applyPresentation(message.type, message.payload);
    this.render();
    this.status();
  }
  render() {
    if (!this.snapshot || this.disposed) return;
    this.editor?.updateOptions({ readOnly: !this.writable() });
    const documentIdentifier = this.snapshot.documentIdentifier;
    this.viewer.render({
      file: this.snapshot,
      mode: this.mode,
      content: this.sync.raw.text,
      writable: this.writable(),
      change: (content) => {
        if (documentIdentifier === this.sync.documentIdentifier) this.contentChange(content);
      },
      save: (content) =>
        documentIdentifier === this.sync.documentIdentifier
          ? this.save(content)
          : Promise.resolve(false),
      onDirty: (dirty) => {
        if (documentIdentifier !== this.sync.documentIdentifier) return;
        this.structuredDirty = dirty;
        this.status();
      },
      host: this.host,
      viewerState: this.viewerState,
      onExportPDF: () => this.exportPDF().catch((error) => this.showHostError(error)),
      onSourceReady: (editor) => this.sourceReady(editor, documentIdentifier),
      onCommand: (command) => this.command(command),
      onViewChanged: (route) => {
        if (documentIdentifier !== this.sync.documentIdentifier) return;
        if (this.displayedRoute !== route) {
          this.displayedRoute = route;
          this.render();
        }
        this.status();
      },
    });
  }
  sourceReady(editor, documentIdentifier) {
    if (documentIdentifier !== this.sync.documentIdentifier) return;
    this.sourceReadyDocument = editor ? documentIdentifier : null;
    this.editor = editor;
    this.sourceSubscriptions?.forEach((s) => s.dispose());
    this.sourceSubscriptions = editor
      ? [
          editor.onDidChangeCursorSelection(() => {
            this.viewState();
            this.status();
          }),
          editor.onDidScrollChange(() => this.viewState()),
          editor.onDidChangeConfiguration(() => {
            if (documentIdentifier !== this.sync.documentIdentifier) return;
            const readOnly = !this.writable();
            if (editor.getRawOptions().readOnly !== readOnly) editor.updateOptions({ readOnly });
          }),
        ]
      : [];
    if (editor && this.pendingSelection) {
      this.restoreSelection(this.pendingSelection);
      this.pendingSelection = null;
    }
    if (editor && this.pendingReveal) {
      editor.setPosition(this.pendingReveal);
      editor.revealPositionInCenter(this.pendingReveal);
      this.pendingReveal = null;
    }
    this.drainSourcePastes();
    this.status();
  }
  drainSourcePastes() {
    if (!this.editor || !this.writable()) return;
    const pastes = this.pendingPastes.splice(0);
    for (const paste of pastes) {
      if (paste.documentIdentifier !== this.sync.documentIdentifier)
        throw new Error("Paste document changed");
      this.paste(paste.text);
    }
    if (!this.pendingPastes.length)
      for (const waiter of this.pasteWaiters.splice(0)) waiter.resolve();
  }
  contentChange(content) {
    if (!this.writable()) return;
    try {
      this.structuredDirty = false;
      applyContentChange(this.sync, content, this.rawPaste);
      state.editorDrafts[this.sync.documentIdentifier] = this.sync.raw.text;
      this.rawPaste = null;
      this.send("pin", {});
      this.render();
      this.status();
    } catch (error) {
      this.failure(error);
    }
  }
  async save(content) {
    this.contentChange(content);
    flushPendingEditorBuffer(state, this.sync.documentIdentifier);
    await this.sync.flush();
    const result = await this.host.request("saveDocument", {
      documentIdentifier: this.sync.documentIdentifier,
    });
    return result.success;
  }
  async exportPDF() {
    flushPendingEditorBuffer(state, this.sync.documentIdentifier);
    const payload = await getActiveMarkdownExportPayload({
      fileId: this.sync.documentIdentifier,
      root: this.container,
    });
    if (!payload) throw new Error("Open a rendered Markdown view to export PDF");
    return this.host.request("exportPDF", payload);
  }
  command(command, fromHost = false) {
    if (command === "paste") {
      void this.host
        .request("readClipboardText", {})
        .then((text) => this.paste(text))
        .catch((error) => this.showHostError(error));
      return;
    }
    if (command === "copy" || command === "cut") {
      void this.receive("copySelection", { cut: command === "cut" });
      return;
    }
    const route = this.activeRoute();
    const source = ["source", "changes", "notebook"].includes(route)
      ? sourceEditorIn(this.container)
      : null;
    if (["zoomIn", "zoomOut", "zoomReset"].includes(command)) {
      requestViewerZoom(command === "zoomIn" ? "in" : command === "zoomOut" ? "out" : "reset");
      return;
    }
    if (command === "exportPDF") {
      void this.exportPDF().catch((error) => this.showHostError(error));
      return;
    }
    if (source && ["find", "findNext", "findPrevious"].includes(command)) {
      void source
        .getAction(
          {
            find: "actions.find",
            findNext: "editor.action.nextMatchFindAction",
            findPrevious: "editor.action.previousMatchFindAction",
          }[command],
        )
        ?.run();
      return;
    }
    if (source && command === "selectAll") {
      source.setSelection(source.getModel().getFullModelRange());
      return;
    }
    if (source && ["undo", "redo"].includes(command)) {
      source.trigger("native", command, null);
      return;
    }
    if (["find", "findNext", "findPrevious"].includes(command) && !source) {
      if (route === "csv") {
        const input = this.container.querySelector('[data-orca-view="csv"] input');
        if (command === "find") {
          input?.focus();
          input?.select();
        } else {
          const grid = this.container.querySelector('[role="grid"],[role="table"]');
          grid?.dispatchEvent(
            new KeyboardEvent("keydown", {
              key: command === "findPrevious" ? "ArrowUp" : "ArrowDown",
              bubbles: true,
              cancelable: true,
            }),
          );
        }
        return;
      }
      const input = this.container.querySelector(
        ".rich-markdown-search input,.markdown-preview-search input,[data-pdf-find] input",
      );
      if (command !== "find" && input) {
        input.dispatchEvent(
          new KeyboardEvent("keydown", {
            key: "Enter",
            shiftKey: command === "findPrevious",
            bubbles: true,
            cancelable: true,
          }),
        );
        return;
      }
      const target = this.container.querySelector(".tiptap,.markdown-preview,.pdfViewer");
      target?.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "f",
          code: "KeyF",
          metaKey: navigator.userAgent.includes("Mac"),
          ctrlKey: !navigator.userAgent.includes("Mac"),
          bubbles: true,
          cancelable: true,
        }),
      );
      return;
    }
    if (["undo", "redo", "selectAll"].includes(command) && !source) {
      const target = this.container.querySelector('.tiptap,[role="grid"]');
      if (target) {
        const key = command === "selectAll" ? "a" : "z";
        target.dispatchEvent(
          new KeyboardEvent("keydown", {
            key,
            code: "Key" + key.toUpperCase(),
            metaKey: navigator.userAgent.includes("Mac"),
            ctrlKey: !navigator.userAgent.includes("Mac"),
            shiftKey: command === "redo",
            bubbles: true,
            cancelable: true,
          }),
        );
      } else if (command === "selectAll") {
        const body = this.container.querySelector(".pdfViewer,[data-portable-content]");
        if (body) {
          const range = document.createRange();
          range.selectNodeContents(body);
          window.getSelection()?.removeAllRanges();
          window.getSelection()?.addRange(range);
        }
      }
      return;
    }
    if (["openMarkdownPreview", "openBrowserPreview", "reload"].includes(command)) {
      void this.host.request(command, {}).catch((error) => this.showHostError(error));
      return;
    }

    if (!fromHost) this.send("command", { command });
  }
  status() {
    if (!this.sync.raw || this.disposed) return;
    this.editor?.updateOptions({ readOnly: !this.writable() });
    const input = this.textInput(),
      editor = sourceEditorIn(this.container),
      selection = editor?.getSelection();
    const hasSelection = input
      ? (input.selectionEnd ?? 0) > (input.selectionStart ?? 0)
      : !!this.container.querySelector("[role=gridcell][aria-selected=true]") ||
        (!!selection && !selection.isEmpty()) ||
        !!window.getSelection()?.toString();
    const route = this.activeRoute();
    const ownsSurface =
      this.container.querySelector("[data-orca-view]")?.dataset.documentIdentifier ===
      this.sync.documentIdentifier;
    this.surfaceReady =
      ownsSurface &&
      (route === "source"
        ? this.sourceReadyDocument === this.sync.documentIdentifier && !!this.editor
        : route === "rich"
          ? !!this.container.querySelector(".tiptap")
          : this.displayedRoute !== null);
    if (this.surfaceReady && this.viewerState) {
      const documentIdentifier = this.sync.documentIdentifier;
      restoreLiveScrolls(
        this.container,
        this.viewerState,
        () => !this.disposed && this.sync.documentIdentifier === documentIdentifier,
      );
      this.viewerState = null;
    }
    this.applyPendingFocus();
    this.send("status", {
      documentIdentifier: this.sync.documentIdentifier,
      revision: String(this.sync.revision),
      isReady: this.surfaceReady,
      hasPendingEdits:
        this.sync.hasPendingEdits || this.structuredDirty || this.pendingPastes.length > 0,
      isComposing: this.sync.composing,
      isReadOnly: this.intrinsicallyReadOnly(),
      hasSelection,
    });
  }

  viewState() {
    if (!this.snapshot || this.disposed) return;
    const selection = this.editor?.getSelection();
    this.send("viewState", {
      schemaVersion: 2,
      viewMode: this.mode ?? "default",
      selectionStartLine: selection?.selectionStartLineNumber ?? 1,
      selectionStartColumn: selection?.selectionStartColumn ?? 1,
      selectionEndLine: selection?.positionLineNumber ?? 1,
      selectionEndColumn: selection?.positionColumn ?? 1,
      scrollTop: this.editor?.getScrollTop() ?? 0,
      scrollLeft: this.editor?.getScrollLeft() ?? 0,
      viewerState: captureViewerState(this.container, this.sync.documentIdentifier),
    });
  }
  restoreSelection(payload) {
    if (!this.editor) {
      this.pendingSelection = payload;
      return;
    }
    if (payload.selectionStartLine)
      this.editor.setSelection({
        selectionStartLineNumber: payload.selectionStartLine,
        selectionStartColumn: payload.selectionStartColumn,
        positionLineNumber: payload.selectionEndLine ?? payload.selectionStartLine,
        positionColumn: payload.selectionEndColumn ?? payload.selectionStartColumn,
      });
    this.editor.setScrollPosition({
      scrollTop: payload.scrollTop ?? 0,
      scrollLeft: payload.scrollLeft ?? 0,
    });
  }
  showHostError(error) {
    if (this.disposed) return;
    this.error.hidden = false;
    this.error.textContent = error.message;
  }
  failure(error) {
    this.pendingFocus = null;
    this.sync.fail(error);
    this.showHostError(error);
    this.render();
    this.send("error", { code: 3 });
  }
  async receive(type, payload, id) {
    try {
      if (type === "hostResult") {
        this.host.receive(payload, id);
        return;
      }
      const presentation =
        type === "restoreViewState" ||
        type === "reveal" ||
        (type === "viewFlags" && payload.viewMode) ||
        (type === "command" && payload.command === "setViewMode");
      if (presentation) {
        if (payload.documentIdentifier) this.beginDocument(payload.documentIdentifier);
        if (!this.snapshot || this.loadingDocumentIdentifier) {
          this.pendingPresentation = this.pendingPresentation.filter(
            (message) => message.type !== type,
          );
          this.pendingPresentation.push({ type, payload });
        } else {
          this.applyPresentation(type, payload);
          this.render();
        }
        return;
      }
      if (type === "cancelFocus" || type === "context") {
        this.pendingFocus = null;
        return;
      }
      if (type === "document") await this.document(payload.snapshot, payload.edits);
      if (type === "ack") this.sync.ack(payload);
      if (type === "editAuthority") {
        this.authorized = payload.granted;
        if (!payload.granted) this.pendingFocus = null;
        this.render();
        this.drainSourcePastes();
      }
      if (type === "flush") {
        if (payload.suspend) this.pendingFocus = null;
        if (this.pendingPastes.length)
          await new Promise((resolve, reject) => this.pasteWaiters.push({ resolve, reject }));
        flushPendingEditorBuffer(state, this.sync.documentIdentifier);
        const barrier = this.sync.flush(payload.suspend);
        this.render();
        await barrier;
        this.viewState();
        this.send(
          "flushResult",
          { revision: String(this.sync.revision), sequence: String(this.sync.sequence) },
          id,
        );
      }
      if (type === "resume") {
        this.sync.resume();
        this.render();
        this.drainSourcePastes();
      }
      if (type === "focus") this.requestFocus();
      if (type === "command") this.command(payload.command, true);
      if (type === "settingsChanged") {
        await initializeHost(this.host);
        this.render();
      }
      if (type === "paste") this.paste(payload.text);
      if (type === "copySelection") {
        const input = this.textInput();
        if (input) {
          this.send("clipboard", {
            text: input.value.slice(input.selectionStart ?? 0, input.selectionEnd ?? 0),
          });
          if (payload.cut && !input.readOnly && !input.disabled) document.execCommand("delete");
          return;
        }

        if (this.activeRoute() === "csv") {
          const grid = this.container.querySelector("[role=grid]");
          grid?.dispatchEvent(
            new KeyboardEvent("keydown", {
              key: payload.cut && this.writable() ? "x" : "c",
              metaKey: navigator.userAgent.includes("Mac"),
              ctrlKey: !navigator.userAgent.includes("Mac"),
              bubbles: true,
              cancelable: true,
            }),
          );
          return;
        }
        const source = ["source", "changes", "notebook"].includes(this.activeRoute())
          ? sourceEditorIn(this.container)
          : null;
        const text = source
          ? source.getModel().getValueInRange(source.getSelection())
          : (window.getSelection()?.toString() ?? "");
        this.send("clipboard", { text });
        if (payload.cut && this.writable()) {
          if (source)
            source.executeEdits("native-cut", [{ range: source.getSelection(), text: "" }]);
          else document.execCommand("delete");
        }
      }
    } catch (error) {
      if (type === "flush") this.send("flushResult", { error: 3 }, id);
      this.failure(error);
    }
  }
  paste(text) {
    const input = this.textInput();
    if (input && !input.readOnly && !input.disabled && typeof text === "string") {
      document.execCommand("insertText", false, text);
      return;
    }

    if (!this.writable() || typeof text !== "string") return;
    if (this.activeRoute() === "source" && !this.editor) {
      this.pendingPastes.push({ documentIdentifier: this.sync.documentIdentifier, text });
      this.status();
      return;
    }
    if (this.activeRoute() === "source" && this.editor) {
      this.rawPaste = text;
      try {
        this.editor.executeEdits("native-paste", [
          { range: this.editor.getSelection(), text, forceMoveMarkers: true },
        ]);
        this.contentChange(this.editor.getValue());
      } finally {
        this.rawPaste = null;
      }
    } else document.execCommand("insertText", false, text);
  }
  dispose() {
    this.disposed = true;
    this.pendingFocus = null;
    this.pendingPresentation = [];
    for (const waiter of this.pasteWaiters.splice(0)) waiter.reject(new Error("View closed"));
    document.removeEventListener("selectionchange", this.onSelection);
    this.selectionObserver.disconnect();
    this.sourceSubscriptions?.forEach((s) => s.dispose());
    this.viewer.dispose();
    this.desktopAPI.dispose();
    this.host.dispose();
    this.root.removeEventListener("compositionstart", this.onCompositionStart);
    this.root.removeEventListener("compositionend", this.onCompositionEnd);
    this.root.removeEventListener("focusin", this.onFocus);
    this.root.removeEventListener("keyup", this.onSelection);
    this.root.removeEventListener("pointerup", this.onSelection);
    this.root.removeEventListener("scroll", this.onScroll, true);
    this.root.removeEventListener("paste", this.onPaste, true);
    this.root.replaceChildren();
  }
}
