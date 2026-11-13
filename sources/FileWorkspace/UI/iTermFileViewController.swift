import AppKit
import ImageIO
import UniformTypeIdentifiers

@objc protocol iTermFileViewControllerDelegate: AnyObject {
    func fileViewDidReceiveFocus(_ controller: iTermFileViewController)
    func fileView(_ controller: iTermFileViewController, didChangeStatus status: iTermFileViewStatus)
    func fileView(_ controller: iTermFileViewController, didChangeViewState state: iTermFileViewState)
    func fileViewDidRequestPin(_ controller: iTermFileViewController)
    func fileView(_ controller: iTermFileViewController, didRequest command: iTermFileViewCommand)
}
@objcMembers final class iTermFileViewController: NSViewController, FileUIWebViewDelegate {
    weak var delegate: iTermFileViewControllerDelegate?
    let viewIdentifier: String
    private let runtime: iTermFileWorkspaceUIRuntime
    private var renderer: iTermFileWorkspaceWebView?
    private var context: iTermFileBrowserContext?
    private var ownerContext: iTermFileBrowserContext?
    private var token = UUID().uuidString
    private var snapshot: iTermFileDocumentSnapshot?
    private var path: String?
    private var recoveredIdentifier: String?
    private var editSession: FileUIEditSession?
    private var pending = false
    private var composing = false
    private var selection = false
    private var renderedReadOnly = true
    private var preview = false
    private var ready = false
    // Native previews may be ready before a leased WK page has installed its message receiver.
    private var rendererReady = false
    private var visible = false
    private var acquiring = false
    private var acquisition: FileUIAcquisition?
    private var focusRequested = false
    private var focusPending = false
    private var pendingReveal: (Int, Int)?
    private var stopped = false
    private var explicitlySuspended = false
    private var transferSuspended = false
    @nonobjc var blocksEditAuthority: Bool { explicitlySuspended || error != nil || stopped }
    private var error: NSError?
    private var flushes = [String: (NSError?) -> Void]()
    private var hostSession: FileUIHostSession?
    private var mediaURL: URL?
    private var mediaKey: String?
    private var mediaGeneration: UInt64 = 0
    private var hostPending = Set<String>()
    private let exporter = FileUIExportController()
    @nonobjc var onOpenFile: ((iTermFileOpenRequest) -> Bool)?
    @nonobjc var onBrowserPreview: ((String) -> Bool)?
    @nonobjc var onReload: ((@escaping (NSError?) -> Void) -> Void)?
    @nonobjc var onSave: ((@escaping (NSError?) -> Void) -> Void)?
    @nonobjc var onFindInFiles: ((String) -> Bool)?
    @nonobjc var onRename: ((iTermFileBrowserRequest, @escaping (NSError?) -> Void) -> Void)?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var cachedViewState = iTermFileViewState()
    var documentIdentifier: String? { snapshot?.documentIdentifier ?? recoveredIdentifier }
    private var mediaOwner: String { viewIdentifier + ":" + token }
    var minimumContentSize: NSSize { NSSize(width: 240, height: 150) }
    var preferredFirstResponder: NSResponder { renderer ?? view }
    var status: iTermFileViewStatus {
        iTermFileViewStatus(snapshot: snapshot, path: path, recoveredIdentifier: recoveredIdentifier, pending: pending || editSession?.pending == true,
                           composing: composing, selection: selection, preview: preview, ready: ready, error: error)
    }
    init(runtime: iTermFileWorkspaceUIRuntime, viewIdentifier: String) {
        self.runtime = runtime; self.viewIdentifier = viewIdentifier; super.init(nibName: nil, bundle: nil); runtime.register(self)
    }
    deinit { acquisition?.cancel() }
    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView(); errorLabel.isHidden = true; view.addSubview(errorLabel) }
    override func viewDidLayout() { super.viewDidLayout(); renderer?.frame = view.bounds; errorLabel.frame = view.bounds.insetBy(dx: 12, dy: 12) }
    func applyContext(_ context: iTermFileBrowserContext) {
        guard self.context !== context else { return }
        if status.hasPendingEdits || composing { fail(fileUIError(3)); return }
        runtime.revokeMedia(owner: mediaOwner); mediaGeneration &+= 1; mediaURL = nil; mediaKey = nil
        self.context = context; token = UUID().uuidString; ready = false; rendererReady = false
        hostSession = snapshot.map { FileUIHostSession(context: ownerContext ?? context, document: $0) }
        renderer?.bind(viewIdentifier: viewIdentifier, context: context, token: token, purpose: "editor")
    }
    func applyOwnerContext(_ value: iTermFileBrowserContext) {
        ownerContext = value
        hostSession = snapshot.map { FileUIHostSession(context: value, document: $0) }
    }
    func applyDocumentChanges(_ snapshot: iTermFileDocumentSnapshot, edits: [iTermFileTextEdit]?) {
        if let previous = self.snapshot, previous.documentIdentifier == snapshot.documentIdentifier, snapshot.revision < previous.revision { return }
        if let previous = self.snapshot, previous.documentIdentifier != snapshot.documentIdentifier, status.hasPendingEdits || composing { fail(fileUIError(3)); return }
        let changedDocument = self.snapshot?.documentIdentifier != snapshot.documentIdentifier
        let changedPath = self.snapshot?.canonicalPath != snapshot.canonicalPath
        if changedDocument { ready = false }
        if changedDocument {
            let callbacks = flushes.values; flushes.removeAll(); callbacks.forEach { $0(fileUIError(3)) }
            runtime.unregister(self); runtime.register(self)
            editSession = FileUIEditSession(store: runtime.documentStore, documentIdentifier: snapshot.documentIdentifier)
            if rendererReady { renderer?.send("editAuthority", payload: ["granted": false]) }; error = nil
        }
        self.snapshot = snapshot; path = snapshot.filePath; recoveredIdentifier = snapshot.documentIdentifier
        if changedDocument { renderedReadOnly = snapshot.isReadOnly }
        if changedDocument || changedPath {
            hostSession = FileUIHostSession(context: ownerContext ?? context, document: snapshot)
        } else if hostSession == nil { hostSession = FileUIHostSession(context: ownerContext ?? context, document: snapshot) }
        hostSession?.update(snapshot)
        if renderer != nil && rendererReady {
            sendDocument(snapshot, edits: edits)
        }
        if changedDocument && rendererReady && focusRequested { runtime.requestAuthority(self) }
        if visible && renderer == nil { setVisible(true) }
        publish()
    }
    func showOpenFailure(path: String, documentIdentifier: String?, error: NSError) {
        guard !status.hasPendingEdits, !composing else { fail(fileUIError(3)); return }
        runtime.unregister(self); runtime.register(self)
        acquisition?.cancel(); acquisition = nil; acquiring = false; renderer = nil; editSession = nil; ready = false; rendererReady = false
        runtime.revokeMedia(owner: mediaOwner); mediaGeneration &+= 1; mediaURL = nil; mediaKey = nil; hostSession = nil
        snapshot = nil; self.path = path; recoveredIdentifier = documentIdentifier; fail(error)
    }
    func restoreViewState(_ state: iTermFileViewState) { cachedViewState = state; if rendererReady { renderer?.send("restoreViewState", payload: state.dictionary) } }
    func setPreview(_ preview: Bool) { self.preview = preview; if rendererReady { renderer?.send("viewFlags", payload: ["preview": preview, "viewMode": cachedViewState.viewMode]) }; publish() }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible {
            if renderer == nil { acquisition?.cancel(); acquisition = nil; acquiring = false }
            cancelPendingFocus()
            flushEdits(reason: .suspend) { [weak self] error in
                guard let self = self, !self.visible, error == nil else { return }
                self.acquisition?.cancel(); self.acquisition = nil; self.renderer = nil; self.ready = false; self.rendererReady = false
                self.runtime.revokeMedia(owner: self.mediaOwner); self.mediaGeneration &+= 1; self.mediaURL = nil; self.mediaKey = nil
            }; return
        }
        guard !stopped, renderer == nil, !acquiring, snapshot != nil else { return }; acquiring = true
        acquisition = runtime.acquire(owner: self) { [weak self, weak runtime = self.runtime] renderer, error in
            guard let self = self else { if let renderer = renderer { runtime?.release(renderer) }; return }; self.acquiring = false
            guard self.visible, !self.stopped, let renderer = renderer else {
                if let renderer = renderer { self.runtime.release(renderer) }; if let error = error { self.fail(error) }; return
            }
            self.renderer = renderer; self.rendererReady = false; renderer.fileDelegate = self; renderer.frame = self.view.bounds
            renderer.autoresizingMask = [.width, .height]; self.view.addSubview(renderer)
            renderer.bind(viewIdentifier: self.viewIdentifier, context: self.context, token: self.token, purpose: "editor")
        }
    }
    func cancelPendingFocus() { focusRequested = false; focusPending = false; if rendererReady { renderer?.send("cancelFocus") } }
    func focusEditor() {
        focusRequested = true; focusPending = true
        deliverPendingFocus()
    }
    private func deliverPendingFocus() {
        guard rendererReady, ready, focusRequested, focusPending else { return }
        focusPending = false; runtime.requestAuthority(self); renderer?.send("focus")
    }
    func reveal(lineNumber: Int, utf16Column: Int) { pendingReveal = (lineNumber, utf16Column); if rendererReady { renderer?.send("reveal", payload: ["lineNumber": lineNumber, "utf16Column": utf16Column]) } }
    func canPerform(_ command: iTermFileViewCommand) -> Bool {
        guard !stopped, snapshot != nil else { return false }
        if (runtime.interactionSuspended || blocksEditAuthority) && [.save, .saveAs, .undo, .redo, .cut, .paste].contains(command) { return false }
        switch command {
        case .save, .undo, .redo: return ready && !status.isReadOnly && !composing
        case .cut, .paste: return rendererReady && !renderedReadOnly && !cachedViewState.showsMarkdownPreview && !status.isReadOnly && !composing
        case .copy: return rendererReady && selection
        case .find, .findNext, .findPrevious:
            return rendererReady && ((snapshot?.kind.isEditable == true && (snapshot?.isTooLarge == false || snapshot?.kind == .csv)) || snapshot?.kind == .pdf)
        case .selectAll: return rendererReady
        case .toggleMarkdownPreview: return snapshot?.kind == .markdown && snapshot?.text != nil
        case .saveAs: return snapshot?.text != nil
        case .pin: return preview
        }
    }
    func perform(_ command: iTermFileViewCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .save, .saveAs, .undo, .redo:
            flushEdits(reason: .save) { [weak self] error in guard let self = self, error == nil else { return }; self.delegate?.fileView(self, didRequest: command) }
        case .pin: delegate?.fileViewDidRequestPin(self)
        case .toggleMarkdownPreview:
            setViewMode(cachedViewState.showsMarkdownPreview ? "source" : "preview") { _ in }
        case .find, .findNext, .findPrevious:
            renderer?.send("command", payload: ["command": command.wireName])
        case .cut, .copy: renderer?.send("copySelection", payload: ["cut": command == .cut])
        case .paste: if let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 10 * 1024 * 1024 { renderer?.send("paste", payload: ["text": text]) }
        default: renderer?.send("command", payload: ["command": command.wireName])
        }
    }
    func flushEdits(reason: iTermFileFlushReason, completion: @escaping (NSError?) -> Void) {
        if reason == .focusTransfer { transferSuspended = true }
        else if reason != .save { explicitlySuspended = true }
        if let error = error {
            // An open failure with no editor buffer has nothing to acknowledge. A sync failure
            // with a snapshot/edit session must still retain input and fail the barrier.
            let metadataOnly = snapshot == nil && editSession == nil && !pending && !composing && flushes.isEmpty
            completion(metadataOnly ? nil : error)
            return
        }
        guard let renderer = renderer, rendererReady, ready else { completion(status.hasPendingEdits ? fileUIError(3) : nil); return }
        let id = UUID().uuidString, document = documentIdentifier, epoch = renderer.fence.epoch
        flushes[id] = { [weak self, weak renderer] error in
            guard let self = self, let renderer = renderer, self.renderer === renderer,
                  self.documentIdentifier == document, renderer.fence.epoch == epoch else { completion(fileUIError(3)); return }
            completion(error)
        }
        renderer.send("flush", payload: ["suspend": reason != .save || explicitlySuspended || transferSuspended || runtime.interactionSuspended], identifier: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let callback = self.flushes.removeValue(forKey: id) else { return }; callback(fileUIError(6))
        }
    }
    func resumeEditing() {
        guard !runtime.interactionSuspended else { return }
        explicitlySuspended = false; transferSuspended = false; if rendererReady { renderer?.send("resume") }
    }
    @nonobjc func setEditAuthority(_ granted: Bool) {
        let permitted = granted && !blocksEditAuthority && !runtime.interactionSuspended
        if permitted && transferSuspended { transferSuspended = false; if rendererReady { renderer?.send("resume") } }
        if rendererReady { renderer?.send("editAuthority", payload: ["granted": permitted]) }
    }
    func shutdown() {
        guard !stopped else { return }; stopped = true; runtime.unregister(self)
        let callbacks = flushes.values; flushes.removeAll(); callbacks.forEach { $0(fileUIError(2)) }
        acquisition?.cancel(); acquisition = nil; acquiring = false; renderer = nil; runtime.revokeMedia(owner: mediaOwner)
        mediaGeneration &+= 1; hostSession = nil; delegate = nil; onOpenFile = nil; onBrowserPreview = nil; onReload = nil; onSave = nil; onFindInFiles = nil; onRename = nil
    }
    @nonobjc func fileUIWebViewReady(_ webView: iTermFileWorkspaceWebView) {
        guard renderer === webView, let snapshot = snapshot else { return }; rendererReady = true; ready = false; errorLabel.isHidden = true
        editSession = FileUIEditSession(store: runtime.documentStore, documentIdentifier: snapshot.documentIdentifier)
        sendDocument(snapshot, edits: nil)
        webView.send("restoreViewState", payload: cachedViewState.dictionary)
        webView.send("viewFlags", payload: ["preview": preview, "viewMode": cachedViewState.viewMode])
        webView.send("settingsChanged", payload: runtime.settings.snapshot)
        if let reveal = pendingReveal { webView.send("reveal", payload: ["lineNumber": reveal.0, "utf16Column": reveal.1]) }
        if explicitlySuspended || transferSuspended || runtime.interactionSuspended { webView.send("flush", payload: ["suspend": true]) }
        if focusRequested { focusPending = true }; publish()
    }
    @nonobjc func fileUIWebView(_ webView: iTermFileWorkspaceWebView, received type: String, payload: [String: Any], identifier: String) {
        guard renderer === webView else { return }
        switch type {
        case "focus": runtime.requestAuthority(self); delegate?.fileViewDidReceiveFocus(self)
        case "pin": if preview { delegate?.fileViewDidRequestPin(self) }
        case "edits":
            guard runtime.hasAuthority(self), let session = editSession else { webView.send("ack", payload: ["error": 3]); return }
            pending = true; publish(); let epoch = webView.fence.epoch
            session.apply(payload) { [weak self, weak webView] snapshot, error in
                guard let self = self, let webView = webView, self.renderer === webView, webView.fence.epoch == epoch else { return }
                if let snapshot = snapshot { self.snapshot = snapshot }
                var ack: [String: Any] = ["sequence": payload["sequence"] ?? "", "revision": String(snapshot?.revision ?? 0)]
                if error != nil { ack["error"] = 3; self.fail(error!) }; webView.send("ack", payload: ack); self.publish()
            }
        case "status":
            if let document = payload["documentIdentifier"] as? String, document != documentIdentifier { return }
            if let applied = payload["isReady"] as? Bool, payload["documentIdentifier"] as? String == documentIdentifier { ready = applied }
            pending = payload["hasPendingEdits"] as? Bool ?? pending; composing = payload["isComposing"] as? Bool ?? composing
            selection = payload["hasSelection"] as? Bool ?? false
            renderedReadOnly = payload["isReadOnly"] as? Bool ?? renderedReadOnly; publish()
            deliverPendingFocus()
        case "viewState":
            var state = cachedViewState.dictionary; state.merge(payload) { _, value in value }
            if payload["viewMode"] == nil { state["viewMode"] = cachedViewState.viewMode }
            cachedViewState = iTermFileViewState(dictionary: state); delegate?.fileView(self, didChangeViewState: cachedViewState)
        case "flushResult":
            guard let callback = flushes.removeValue(forKey: identifier) else { return }
            if payload["error"] != nil || editSession?.pending == true || payload["revision"] as? String != snapshot.map({ String($0.revision) }) { callback(fileUIError(3)) } else { pending = false; composing = false; publish(); callback(nil) }
        case "command":
            if payload["command"] as? String == "findInFiles", let query = payload["query"] as? String, query.utf8.count <= 2048 { _ = onFindInFiles?(query) }
            else if payload["command"] as? String == "setViewMode", let mode = payload["viewMode"] as? String { setViewMode(mode) { _ in } }
            else if let name = payload["command"] as? String, let command = iTermFileViewCommand(wireName: name) { perform(command) }
        case "hostRequest": handleHostRequest(payload, identifier: identifier, webView: webView)
        case "clipboard": if let text = payload["text"] as? String, text.utf8.count <= 40 * 1024 * 1024 { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        case "editorContextMenu": showEditorMenu()
        case "error": fail(fileUIError(3))
        default: break
        }
    }
    @nonobjc func fileUIWebView(_ webView: iTermFileWorkspaceWebView, failed error: NSError) { guard renderer === webView else { return }; fail(error) }
    func hasContext(_ value: iTermFileBrowserContext) -> Bool { !stopped && context === value }
    func settingsDidChange(_ settings: [String: Any]) { if rendererReady { renderer?.send("settingsChanged", payload: settings) } }
    func setViewMode(_ mode: String, completion: @escaping (NSError?) -> Void) {
        guard ["source", "rich", "preview", "changes", "edit"].contains(mode), snapshot != nil else { completion(fileUIError(4)); return }
        flushEdits(reason: .save) { [weak self] error in
            guard let self, error == nil else { completion(error ?? fileUIError(2)); return }
            var state = self.cachedViewState.dictionary; state["viewMode"] = mode
            self.cachedViewState = iTermFileViewState(dictionary: state)
            self.renderer?.send("viewFlags", payload: ["preview": self.preview, "viewMode": mode])
            self.delegate?.fileView(self, didChangeViewState: self.cachedViewState); completion(nil)
        }
    }
    private func sendDocument(_ snapshot: iTermFileDocumentSnapshot, edits: [iTermFileTextEdit]?) {
        guard let webView = renderer, rendererReady else { return }
        var value = snapshot.fileUIDictionary(includeText: edits == nil)
        value["rootDirectory"] = ownerContext?.rootDirectory ?? context?.rootDirectory ?? (snapshot.filePath as NSString).deletingLastPathComponent
        value["projectIdentifier"] = context?.projectIdentifier ?? ""; value["worktreeIdentifier"] = context?.worktreeIdentifier ?? ""
        value["mimeType"] = snapshot.kind == .pdf ? "application/pdf" : FileContentService.mimeType(snapshot.filePath)
        let deliver: ([String: Any]) -> Void = { [weak self, weak webView] value in
            guard let self, let webView, self.renderer === webView, self.snapshot?.documentIdentifier == snapshot.documentIdentifier,
                  self.snapshot?.revision == snapshot.revision else { return }
            var payload: [String: Any] = ["snapshot": value]
            if let edits { payload["edits"] = edits.map(\.fileUIDictionary) }
            webView.sendDocument(payload)
        }
        guard [.image, .pdf, .audio, .video].contains(snapshot.kind), !snapshot.isTooLarge else { deliver(value); return }
        let key = snapshot.canonicalPath + ":" + String(snapshot.revision)
        if mediaKey == key, let mediaURL { value["mediaURL"] = mediaURL.absoluteString; deliver(value); return }
        mediaGeneration &+= 1; let generation = mediaGeneration, epoch = webView.fence.epoch
        runtime.registerMedia(path: snapshot.canonicalPath, owner: mediaOwner) { [weak self, weak webView] result in
            guard let self, let webView, self.renderer === webView, webView.fence.epoch == epoch, self.mediaGeneration == generation else { return }
            switch result {
            case .success(let url): self.mediaURL = url; self.mediaKey = key; value["mediaURL"] = url.absoluteString; deliver(value)
            case .failure(let error): self.fail(error as NSError)
            }
        }
    }
    private func handleHostRequest(_ payload: [String: Any], identifier: String, webView: iTermFileWorkspaceWebView) {
        guard let operation = payload["operation"] as? String, let args = payload["args"] as? [String: Any],
              let snapshot, let hostSession, hostPending.count < 64, !hostPending.contains(identifier) else { return }
        hostPending.insert(identifier)
        let epoch = webView.fence.epoch, documentIdentifier = snapshot.documentIdentifier
        let current = { [weak self, weak webView] in
            guard let self, let webView else { return false }
            return !self.stopped && self.renderer === webView && webView.fence.epoch == epoch && self.documentIdentifier == documentIdentifier
        }
        let finish: (Result<Any, Error>) -> Void = { [weak self, weak webView] result in
            self?.hostPending.remove(identifier)
            guard current(), let webView else { return }
            switch result {
            case .success(let value): webView.send("hostResult", payload: ["result": value], identifier: identifier)
            case .failure(let error):
                DLog("File UI host request \(operation) failed: \((error as NSError).domain) \((error as NSError).code)")
                webView.send("hostResult", payload: ["error": ["code": "file_request_failed", "message": FileUIStrings.labels["previewError"] ?? ""]], identifier: identifier)
            }
        }
        do {
            switch operation {
            case "settings":
                if args["action"] as? String == "update" {
                    guard let changes = args["settings"] as? [String: Any] else { throw fileUIError(4) }
                    let value = try runtime.settings.update(changes); runtime.settingsDidChange(); finish(.success(value))
                } else if args["action"] as? String == "read" { finish(.success(runtime.settings.snapshot)) }
                else { throw fileUIError(4) }
            case "annotations":
                let path = try hostSession.path(args["path"] ?? snapshot.filePath)
                let owner = hostSession.ownerIdentifier
                if args["action"] as? String == "update" {
                    guard let comments = args["comments"] as? [[String: Any]] else { throw fileUIError(4) }
                    finish(.success(try runtime.settings.setComments(comments, owner: owner, path: path)))
                } else if args["action"] as? String == "read" { finish(.success(runtime.settings.comments(owner: owner, path: path))) }
                else { throw fileUIError(4) }
            case "readClipboardText": finish(.success(NSPasteboard.general.string(forType: .string) ?? ""))
            case "writeClipboardImage":
                let prefix = "data:image/png;base64,"
                guard let encoded = args["data"] as? String, encoded.utf8.count <= 70 * 1024 * 1024, encoded.hasPrefix(prefix),
                      let data = Data(base64Encoded: String(encoded.dropFirst(prefix.count))), data.count <= 50 * 1024 * 1024,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 32768, height <= 32768, width <= (32 * 1024 * 1024) / height else { throw fileUIError(4) }
                NSPasteboard.general.clearContents()
                finish(.success(["success": NSPasteboard.general.setData(data, forType: .png)]))
            case "pickImage": FileUIImagePicker.pick(window: view.window, isCurrent: current) { finish($0.map { $0 as Any }) }
            case "saveDocument":
                guard args["documentIdentifier"] as? String == snapshot.documentIdentifier, canPerform(.save), let onSave else { throw fileUIError(4) }
                onSave { error in finish(.success(["success": error == nil])) }
            case "findInFiles":
                guard let query = args["query"] as? String, query.utf8.count <= 2048, onFindInFiles?(query) == true else { throw fileUIError(4) }
                finish(.success(NSNull()))
            case "rename":
                guard let context, let onRename, let name = args["name"] as? String,
                      let request = iTermFileBrowserRequest(identifier: identifier, context: context, type: "rename",
                        payload: ["paths": [snapshot.filePath], "name": name]) else { throw fileUIError(4) }
                onRename(request) { error in finish(error.map { .failure($0) } ?? .success(["success": true])) }
            case "setViewMode":
                guard let mode = args["viewMode"] as? String else { throw fileUIError(4) }
                setViewMode(mode) { error in finish(error.map { .failure($0) } ?? .success(NSNull())) }
            case "openFile", "openMarkdownPreview":
                let path = try hostSession.openPath(args["path"] ?? snapshot.filePath)
                let owner = context ?? iTermFileBrowserContext(rootDirectory: (snapshot.filePath as NSString).deletingLastPathComponent,
                    projectIdentifier: "", worktreeIdentifier: "", generation: 0)
                guard let placement = fileUIOpenStyle(args["placement"] as? String ?? "tab"),
                      let line = fileUIInteger(args["lineNumber"] ?? 0, maximum: Int(Int32.max)),
                      let column = fileUIInteger(args["utf16Column"] ?? 0, maximum: Int(Int32.max)) else { throw fileUIError(4) }
                let request = iTermFileOpenRequest(context: owner, ownerContext: ownerContext ?? owner, path: path, placement: placement,
                    activation: args["activation"] as? String == "preview" ? .preview : .pinned, lineNumber: line, utf16Column: column)
                request.viewMode = operation == "openMarkdownPreview" ? "preview" : args["viewMode"] as? String
                request.readScope = hostSession.readScope(for: path)
                request.anchor = args["anchor"] as? String
                if let mode = request.viewMode, !["source", "rich", "preview", "changes", "edit"].contains(mode) { throw fileUIError(4) }
                if let anchor = request.anchor, anchor.utf8.count > 2048 { throw fileUIError(4) }
                flushEdits(reason: .save) { [weak self] error in
                    guard error == nil, current(), self?.onOpenFile?(request) == true else { finish(.failure(error ?? fileUIError(2))); return }
                    finish(.success(NSNull()))
                }
            case "openBrowserPreview":
                flushEdits(reason: .save) { [weak self] error in
                    guard error == nil, current(), self?.onBrowserPreview?(snapshot.filePath) == true else { finish(.failure(error ?? fileUIError(2))); return }
                    finish(.success(NSNull()))
                }
            case "openExternal":
                guard let string = args["url"] as? String, string.utf8.count <= 16384, let url = URL(string: string),
                      ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { throw fileUIError(4) }
                finish(.success(NSWorkspace.shared.open(url)))
            case "revealInFinder", "openExternally":
                let path = try hostSession.path(args["path"] ?? snapshot.filePath), url = URL(fileURLWithPath: path)
                if operation == "revealInFinder" { NSWorkspace.shared.activateFileViewerSelecting([url]); finish(.success(NSNull())) }
                else { finish(.success(NSWorkspace.shared.open(url))) }
            case "reload":
                guard let onReload else { throw fileUIError(2) }
                onReload { error in finish(error.map { .failure($0) } ?? .success(NSNull())) }
            case "exportPDF":
                guard let html = args["html"] as? String, html.utf8.count <= 16 * 1024 * 1024,
                      let title = args["title"] as? String, title.utf8.count <= 1024 else { throw fileUIError(4) }
                exporter.exportPDF(html: html, title: title, window: view.window, isCurrent: current) { finish($0.map { $0 as Any }) }
            case "saveCopy":
                guard let encoded = args["data"] as? String, encoded.utf8.count <= 70 * 1024 * 1024,
                      let data = Data(base64Encoded: encoded), data.count <= iTermFileDocumentStore.maximumFileBytes,
                      let name = args["name"] as? String, name.utf8.count <= 255, !name.contains("/"), !name.contains("\0") else { throw fileUIError(4) }
                exporter.saveCopy(data: data, name: name, window: view.window, isCurrent: current) { finish($0.map { $0 as Any }) }
            default: hostSession.read(operation, args: args, completion: finish)
            }
        } catch { finish(.failure(error)) }
    }
    private func publish() { delegate?.fileView(self, didChangeStatus: status) }
    private func fail(_ error: NSError) {
        DLog("File workspace editor failure: \(error.domain) \(error.code)")
        self.error = error
        if rendererReady { renderer?.send("editAuthority", payload: ["granted": false]) }
        errorLabel.stringValue = FileUIStrings.labels["syncError"] ?? ""; errorLabel.isHidden = false; view.addSubview(errorLabel)
        let callbacks = flushes.values; flushes.removeAll(); callbacks.forEach { $0(error) }; publish()
    }
    private func showEditorMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        for command in [iTermFileViewCommand.undo, .redo, .cut, .copy, .paste, .selectAll, .find] {
            let item = NSMenuItem(title: FileUIStrings.labels[command.wireName] ?? "", action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self; item.tag = command.rawValue; item.isEnabled = canPerform(command); menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil), in: view)
    }
    @objc private func menuCommand(_ sender: NSMenuItem) { if let command = iTermFileViewCommand(rawValue: sender.tag) { perform(command) } }
}
