import AppKit

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
    private var token = UUID().uuidString
    private var snapshot: iTermFileDocumentSnapshot?
    private var path: String?
    private var recoveredIdentifier: String?
    private var editSession: FileUIEditSession?
    private var pending = false
    private var composing = false
    private var selection = false
    private var preview = false
    private var ready = false
    private var visible = false
    private var acquiring = false
    private var focusRequested = false
    private var pendingReveal: (Int, Int)?
    private var stopped = false
    private var error: NSError?
    private var flushes = [String: (NSError?) -> Void]()
    private var previewController: iTermFilePreviewViewController?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var cachedViewState = iTermFileViewState()
    var documentIdentifier: String? { snapshot?.documentIdentifier ?? recoveredIdentifier }
    private var usesNativePreview: Bool {
        guard let snapshot = snapshot else { return false }
        return snapshot.isTooLarge || (snapshot.kind != .text && snapshot.kind != .markdown) ||
            (snapshot.kind == .markdown && cachedViewState.showsMarkdownPreview)
    }
    var minimumContentSize: NSSize { NSSize(width: 240, height: 150) }
    var preferredFirstResponder: NSResponder { previewController?.preferredFirstResponder ?? renderer ?? view }
    var status: iTermFileViewStatus {
        iTermFileViewStatus(snapshot: snapshot, path: path, recoveredIdentifier: recoveredIdentifier, pending: pending || editSession?.pending == true,
                           composing: composing, selection: selection, preview: preview, ready: ready, error: error)
    }
    init(runtime: iTermFileWorkspaceUIRuntime, viewIdentifier: String) {
        self.runtime = runtime; self.viewIdentifier = viewIdentifier; super.init(nibName: nil, bundle: nil); runtime.register(self)
    }
    deinit { if let renderer = renderer { runtime.release(renderer) } }
    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView(); errorLabel.isHidden = true; view.addSubview(errorLabel) }
    override func viewDidLayout() { super.viewDidLayout(); renderer?.frame = view.bounds; previewController?.view.frame = view.bounds; errorLabel.frame = view.bounds.insetBy(dx: 12, dy: 12) }
    func applyContext(_ context: iTermFileBrowserContext) {
        guard self.context !== context else { return }
        if status.hasPendingEdits || composing { fail(fileUIError(3)); return }
        self.context = context; token = UUID().uuidString; ready = false
        renderer?.bind(viewIdentifier: viewIdentifier, context: context, token: token, purpose: "editor")
    }
    func applyDocumentChanges(_ snapshot: iTermFileDocumentSnapshot, edits: [iTermFileTextEdit]?) {
        if let previous = self.snapshot, previous.documentIdentifier == snapshot.documentIdentifier, snapshot.revision < previous.revision { return }
        if let previous = self.snapshot, previous.documentIdentifier != snapshot.documentIdentifier, status.hasPendingEdits || composing { fail(fileUIError(3)); return }
        let changedDocument = self.snapshot?.documentIdentifier != snapshot.documentIdentifier
        if changedDocument {
            let callbacks = flushes.values; flushes.removeAll(); callbacks.forEach { $0(fileUIError(3)) }
            runtime.unregister(self); runtime.register(self)
            editSession = FileUIEditSession(store: runtime.documentStore, documentIdentifier: snapshot.documentIdentifier)
            renderer?.send("editAuthority", payload: ["granted": false]); error = nil
        }
        self.snapshot = snapshot; path = snapshot.filePath; recoveredIdentifier = snapshot.documentIdentifier
        if renderer != nil && ready {
            var payload: [String: Any] = ["snapshot": snapshot.fileUIDictionary(includeText: edits == nil)]
            if let edits = edits { payload["edits"] = edits.map(\.fileUIDictionary) }; renderer?.send("document", payload: payload)
        }
        if !usesNativePreview {
            if previewController != nil { previewController?.shutdown(); previewController?.view.removeFromSuperview(); previewController?.removeFromParent(); previewController = nil; renderer?.isHidden = false }
        } else if visible { showPreview() }
        if changedDocument && ready && focusRequested { runtime.requestAuthority(self) }
        if visible && renderer == nil && previewController == nil { setVisible(true) }
        publish()
    }
    func showOpenFailure(path: String, documentIdentifier: String?, error: NSError) {
        guard !status.hasPendingEdits, !composing else { fail(fileUIError(3)); return }
        runtime.unregister(self); runtime.register(self)
        if let renderer = renderer { runtime.release(renderer) }; renderer = nil; editSession = nil; ready = false
        previewController?.shutdown(); previewController?.view.removeFromSuperview(); previewController?.removeFromParent(); previewController = nil
        snapshot = nil; self.path = path; recoveredIdentifier = documentIdentifier; fail(error)
    }
    func restoreViewState(_ state: iTermFileViewState) { cachedViewState = state; renderer?.send("restoreViewState", payload: state.dictionary); if usesNativePreview { showPreview() } }
    func setPreview(_ preview: Bool) { self.preview = preview; renderer?.send("viewFlags", payload: ["preview": preview]); publish() }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible {
            focusRequested = false
            previewController?.shutdown(); previewController?.view.removeFromSuperview(); previewController?.removeFromParent(); previewController = nil
            flushEdits(reason: .suspend) { [weak self] error in
                guard let self = self, !self.visible, error == nil else { return }
                if let renderer = self.renderer { self.runtime.release(renderer) }; self.renderer = nil; self.ready = false
            }; return
        }
        if usesNativePreview { showPreview(); return }
        guard !stopped, previewController == nil, renderer == nil, !acquiring, let snapshot = snapshot,
              snapshot.kind == .text || snapshot.kind == .markdown else { return }; acquiring = true
        runtime.acquire { [weak self] renderer, error in
            guard let self = self else { renderer?.shutdown(); return }; self.acquiring = false
            guard self.visible, !self.stopped, let renderer = renderer else {
                if let renderer = renderer { self.runtime.release(renderer) }; if let error = error { self.fail(error) }; return
            }
            self.renderer = renderer; renderer.fileDelegate = self; renderer.frame = self.view.bounds
            renderer.autoresizingMask = [.width, .height]; self.view.addSubview(renderer)
            renderer.bind(viewIdentifier: self.viewIdentifier, context: self.context, token: self.token, purpose: "editor")
        }
    }
    func focusEditor() { focusRequested = true; runtime.requestAuthority(self); if previewController != nil { view.window?.makeFirstResponder(preferredFirstResponder) } else { renderer?.send("focus") } }
    func reveal(lineNumber: Int, utf16Column: Int) { pendingReveal = (lineNumber, utf16Column); renderer?.send("reveal", payload: ["lineNumber": lineNumber, "utf16Column": utf16Column]) }
    func canPerform(_ command: iTermFileViewCommand) -> Bool {
        guard !stopped, snapshot != nil else { return false }
        if runtime.interactionSuspended && [.save, .saveAs, .undo, .redo, .cut, .paste].contains(command) { return false }
        switch command {
        case .save, .undo, .redo, .cut, .paste: return ready && !status.isReadOnly && !composing
        case .copy: return previewController?.hasSelection ?? selection
        case .find, .findNext, .findPrevious, .selectAll: return ready && previewController == nil
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
            flushEdits(reason: .suspend) { [weak self] error in
                guard let self = self, error == nil else { return }; var value = self.cachedViewState.dictionary
                value["showsMarkdownPreview"] = !self.cachedViewState.showsMarkdownPreview; self.cachedViewState = iTermFileViewState(dictionary: value)
                if self.cachedViewState.showsMarkdownPreview { self.showPreview() } else {
                    self.previewController?.view.removeFromSuperview(); self.previewController?.removeFromParent(); self.previewController = nil
                    self.renderer?.isHidden = false; self.resumeEditing(); self.setVisible(true)
                }; self.delegate?.fileView(self, didChangeViewState: self.cachedViewState)
            }
        case .cut, .copy: if command == .copy, let controller = previewController { controller.copySelection() } else { renderer?.send("copySelection", payload: ["cut": command == .cut]) }
        case .paste: if let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 10 * 1024 * 1024 { renderer?.send("paste", payload: ["text": text]) }
        default: renderer?.send("command", payload: ["command": command.wireName])
        }
    }
    func flushEdits(reason: iTermFileFlushReason, completion: @escaping (NSError?) -> Void) {
        if let error = error { completion(error); return }
        guard let renderer = renderer, ready else { completion(status.hasPendingEdits ? fileUIError(3) : nil); return }
        let id = UUID().uuidString, document = documentIdentifier, epoch = renderer.fence.epoch
        flushes[id] = { [weak self, weak renderer] error in
            guard let self = self, let renderer = renderer, self.renderer === renderer,
                  self.documentIdentifier == document, renderer.fence.epoch == epoch else { completion(fileUIError(3)); return }
            completion(error)
        }
        renderer.send("flush", payload: ["suspend": reason != .save], identifier: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let callback = self.flushes.removeValue(forKey: id) else { return }; callback(fileUIError(6))
        }
    }
    func resumeEditing() { renderer?.send("resume") }
    @nonobjc func setEditAuthority(_ granted: Bool) { renderer?.send("editAuthority", payload: ["granted": granted]) }
    func shutdown() {
        guard !stopped else { return }; stopped = true; runtime.unregister(self)
        let callbacks = flushes.values; flushes.removeAll(); callbacks.forEach { $0(fileUIError(2)) }
        if let renderer = renderer { runtime.release(renderer) }; renderer = nil; previewController?.shutdown(); previewController = nil; delegate = nil
    }
    @nonobjc func fileUIWebViewReady(_ webView: iTermFileWorkspaceWebView) {
        guard renderer === webView, let snapshot = snapshot else { return }; ready = true; errorLabel.isHidden = true
        editSession = FileUIEditSession(store: runtime.documentStore, documentIdentifier: snapshot.documentIdentifier)
        webView.send("document", payload: ["snapshot": snapshot.fileUIDictionary(includeText: true)])
        webView.send("restoreViewState", payload: cachedViewState.dictionary)
        webView.send("viewFlags", payload: ["preview": preview])
        if let reveal = pendingReveal { webView.send("reveal", payload: ["lineNumber": reveal.0, "utf16Column": reveal.1]) }
        if focusRequested { runtime.requestAuthority(self); webView.send("focus") }; publish()
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
        case "status": pending = payload["hasPendingEdits"] as? Bool ?? pending; composing = payload["isComposing"] as? Bool ?? composing; selection = payload["hasSelection"] as? Bool ?? false; publish()
        case "viewState": var state = payload; state["showsMarkdownPreview"] = cachedViewState.showsMarkdownPreview; cachedViewState = iTermFileViewState(dictionary: state); delegate?.fileView(self, didChangeViewState: cachedViewState)
        case "flushResult":
            guard let callback = flushes.removeValue(forKey: identifier) else { return }
            if payload["error"] != nil || editSession?.pending == true || payload["revision"] as? String != snapshot.map({ String($0.revision) }) { callback(fileUIError(3)) } else { pending = false; composing = false; publish(); callback(nil) }
        case "command": if let name = payload["command"] as? String, let command = iTermFileViewCommand(wireName: name) { perform(command) }
        case "clipboard": if let text = payload["text"] as? String, text.utf8.count <= 40 * 1024 * 1024 { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        case "editorContextMenu": showEditorMenu()
        case "error": fail(fileUIError(3))
        default: break
        }
    }
    @nonobjc func fileUIWebView(_ webView: iTermFileWorkspaceWebView, failed error: NSError) { guard renderer === webView else { return }; fail(error) }
    private func publish() { delegate?.fileView(self, didChangeStatus: status) }
    private func fail(_ error: NSError) { DLog("File workspace editor failure: \(error.domain) \(error.code)"); self.error = error; errorLabel.stringValue = FileUIStrings.labels["syncError"] ?? ""; errorLabel.isHidden = false; view.addSubview(errorLabel); let callbacks = flushes.values; flushes.removeAll(); callbacks.forEach { $0(error) }; publish() }
    private func showPreview() {
        guard let snapshot = snapshot else { return }
        if previewController == nil { let controller = iTermFilePreviewViewController(); previewController = controller; controller.onShowSource = { [weak self] in self?.perform(.toggleMarkdownPreview) }; controller.onFocus = { [weak self] in guard let self = self else { return }; self.delegate?.fileViewDidReceiveFocus(self) }; controller.onSelection = { [weak self] value in self?.selection = value; self?.publish() }; addChild(controller); controller.view.frame = view.bounds; controller.view.autoresizingMask = [.width, .height]; view.addSubview(controller.view) }
        renderer?.isHidden = true; previewController?.apply(snapshot); ready = true; publish()
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
