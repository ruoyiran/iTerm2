import AppKit

@objc protocol iTermFileBrowserViewControllerDelegate: AnyObject {
    func fileBrowser(_ controller: iTermFileBrowserViewController, didRequest request: iTermFileBrowserRequest)
    func fileBrowserDidReceiveFocus(_ controller: iTermFileBrowserViewController)
}
@objcMembers final class iTermFileBrowserViewController: NSViewController, FileUIWebViewDelegate {
    weak var delegate: iTermFileBrowserViewControllerDelegate?
    private let runtime: iTermFileWorkspaceUIRuntime
    private var renderer: iTermFileWorkspaceWebView?
    private var context: iTermFileBrowserContext?
    private var token = UUID().uuidString
    private let viewIdentifier = UUID().uuidString
    private var titleText = ""
    private var visible = false
    private var acquiring = false
    private var acquisition: FileUIAcquisition?
    private var surfaceReady = false
    private var operationState: [String: Any] = ["canUndo": false, "canRedo": false]
    private var pendingQueryFocus: Bool?
    private var stopped = false
    private var requests = [String: iTermFileBrowserRequestKind]()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    init(runtime: iTermFileWorkspaceUIRuntime) { self.runtime = runtime; super.init(nibName: nil, bundle: nil) }
    deinit { acquisition?.cancel() }
    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView(); errorLabel.isHidden = true; view.addSubview(errorLabel) }
    override func viewDidLayout() { super.viewDidLayout(); renderer?.frame = view.bounds; errorLabel.frame = view.bounds.insetBy(dx: 12, dy: 12) }
    var preferredFirstResponder: NSResponder { renderer ?? view }
    func applyContext(_ context: iTermFileBrowserContext?, title: String) {
        cancelSearches(); surfaceReady = false; operationState = ["canUndo": false, "canRedo": false]; self.context = context; titleText = title; token = UUID().uuidString; requests.removeAll()
        renderer?.bind(viewIdentifier: viewIdentifier, context: context, token: token, purpose: "explorer")
    }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible { pendingQueryFocus = nil; cancelSearches(); return }
        if renderer != nil { refresh(); return }
        guard !stopped, renderer == nil, !acquiring else { return }; acquiring = true
        acquisition = runtime.acquire(owner: self) { [weak self, weak runtime = self.runtime] renderer, error in
            guard let self = self else { if let renderer = renderer { runtime?.release(renderer) }; return }; self.acquiring = false
            guard !self.stopped, self.visible, let renderer = renderer else {
                if let renderer = renderer { self.runtime.release(renderer) }
                if let error = error { self.show(error) }; return
            }
            self.renderer = renderer; renderer.fileDelegate = self; renderer.frame = self.view.bounds
            renderer.autoresizingMask = [.width, .height]; self.view.addSubview(renderer)
            renderer.bind(viewIdentifier: self.viewIdentifier, context: self.context, token: self.token, purpose: "explorer")
        }
    }
    func applyListing(_ entries: [iTermFileBrowserEntry]?, directoryPath: String, requestIdentifier: String,
                      context: iTermFileBrowserContext, error: NSError?) {
        guard context === self.context, requests.removeValue(forKey: requestIdentifier) == .listDirectory else { return }
        var payload: [String: Any] = ["token": token, "directoryPath": directoryPath, "requestIdentifier": requestIdentifier,
                                     "entries": (entries ?? []).map { ["path": $0.path, "relativePath": $0.relativePath, "name": $0.name,
                                                                         "isDirectory": $0.isDirectory, "isSymbolicLink": $0.isSymbolicLink, "isExpandable": $0.isExpandable] as [String: Any] }]
        if error != nil { payload["error"] = FileUIStrings.labels["previewError"] }
        renderer?.send("listing", payload: payload)
    }
    func applySearch(_ batch: iTermFileSearchBatch, requestIdentifier: String) {
        guard batch.context === context, let kind = requests[requestIdentifier], kind == .searchNames || kind == .searchContents else { return }
        var payload: [String: Any] = ["token": token, "requestIdentifier": requestIdentifier, "isComplete": batch.isComplete,
                                     "isTruncated": batch.isTruncated, "skippedFileCount": batch.skippedFileCount,
                                     "entries": batch.entries.map { ["path": $0.path, "relativePath": $0.relativePath, "name": $0.name,
                                                                     "isDirectory": $0.isDirectory, "isExpandable": $0.isExpandable] as [String: Any] },
                                     "matches": batch.matches.map { group in
            ["path": group.path, "relativePath": group.relativePath, "lines": group.lines.map { line in
                ["lineNumber": line.lineNumber, "snippet": line.snippet, "snippetColumn": line.snippetColumn,
                 "ranges": line.ranges.map { ["location": $0.rangeValue.location, "length": $0.rangeValue.length] }] as [String: Any]
            }] as [String: Any]
        }]
        if batch.error != nil { payload["error"] = FileUIStrings.labels["previewError"] }
        if batch.isComplete { requests.removeValue(forKey: requestIdentifier) }
        renderer?.send("search", payload: payload)
    }
    func completeRequest(_ requestIdentifier: String, context: iTermFileBrowserContext, error: NSError?) {
        guard context === self.context else { return }; requests.removeValue(forKey: requestIdentifier)
        var payload: [String: Any] = ["requestIdentifier": requestIdentifier]
        if error != nil { payload["error"] = FileUIStrings.labels["previewError"] }; renderer?.send("complete", payload: payload)
    }
    func applyOperationState(canUndo: Bool, canRedo: Bool, context: iTermFileBrowserContext) {
        guard context === self.context else { return }; operationState = ["canUndo": canUndo, "canRedo": canRedo]
        if surfaceReady { renderer?.send("operationState", payload: operationState) }
    }
    func revealPath(_ path: String, context: iTermFileBrowserContext) { guard context === self.context else { return }; renderer?.send("reveal", payload: ["path": path]) }
    func focusQuery(contents: Bool) { pendingQueryFocus = contents; deliverQueryFocus() }
    private func deliverQueryFocus() {
        guard surfaceReady, let renderer = renderer, let contents = pendingQueryFocus else { return }
        pendingQueryFocus = nil; renderer.send("focusQuery", payload: ["contents": contents])
    }
    func applyFilesystemChanges(_ paths: [String], rescanDirectories: [String], context: iTermFileBrowserContext) {
        guard context === self.context, surfaceReady, visible else { return }
        renderer?.send("filesystemChanges", payload: ["token": token, "paths": paths, "rescanDirectories": rescanDirectories])
    }
    func refresh() { if surfaceReady && visible { renderer?.send("refresh") } }
    func shutdown() { guard !stopped else { return }; stopped = true; setVisible(false); acquisition?.cancel(); acquisition = nil; renderer = nil; requests.removeAll(); delegate = nil }
    @nonobjc func fileUIWebViewReady(_ webView: iTermFileWorkspaceWebView) {
        guard renderer === webView else { return }; surfaceReady = true; errorLabel.isHidden = true
        webView.send("context", payload: context?.fileUIDictionary(token: token, title: titleText) ?? ["token": token, "title": titleText])
        webView.send("operationState", payload: operationState)
        deliverQueryFocus()
    }
    @nonobjc func fileUIWebView(_ webView: iTermFileWorkspaceWebView, received type: String, payload: [String: Any], identifier: String) {
        guard renderer === webView, visible else { return }
        if type == "focus" { delegate?.fileBrowserDidReceiveFocus(self); return }
        guard let context = context, let request = iTermFileBrowserRequest(identifier: identifier, context: context, type: type, payload: payload), requests.count < 1024 else { return }
        if request.kind == .refresh { requests = requests.filter { $0.value != .listDirectory } }
        if request.kind == .cancelSearch, let id = request.cancelledRequestIdentifier { requests.removeValue(forKey: id) }
        else if [.listDirectory, .searchNames, .searchContents].contains(request.kind) { requests[identifier] = request.kind }
        delegate?.fileBrowser(self, didRequest: request)
    }
    @nonobjc func fileUIWebView(_ webView: iTermFileWorkspaceWebView, failed error: NSError) { guard renderer === webView else { return }; show(error) }
    private func cancelSearches() {
        guard let context = context else { requests.removeAll(); return }
        for (id, kind) in requests where kind == .searchNames || kind == .searchContents {
            if let request = iTermFileBrowserRequest(identifier: UUID().uuidString, context: context, type: "cancelSearch", payload: ["identifier": id]) { delegate?.fileBrowser(self, didRequest: request) }
        }
        requests.removeAll()
    }
    private func show(_ error: NSError) { DLog("File workspace explorer failure: \(error.domain) \(error.code)"); errorLabel.stringValue = FileUIStrings.labels["syncError"] ?? ""; errorLabel.isHidden = false }
}
