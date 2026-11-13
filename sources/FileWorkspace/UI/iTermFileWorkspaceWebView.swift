import AppKit
import WebKit

protocol FileUIWebViewDelegate: AnyObject {
    func fileUIWebViewReady(_ webView: iTermFileWorkspaceWebView)
    func fileUIWebView(_ webView: iTermFileWorkspaceWebView, received type: String, payload: [String: Any], identifier: String)
    func fileUIWebView(_ webView: iTermFileWorkspaceWebView, failed error: NSError)
}
private final class FileUIWeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: iTermFileWorkspaceWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}
final class iTermFileWorkspaceWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    weak var fileDelegate: FileUIWebViewDelegate?
    private let proxy: FileUIWeakMessageHandler
    private var pageReady = false
    private var bound = false
    private(set) var fence = FileUIMessageFence(epoch: UUID().uuidString, view: "", token: "", generation: 0)
    private var purpose = "explorer"
    private var assetURL: URL?
    private let incomingChunks = FileUIChunkAssembler()
    private var documentTransferGeneration: UInt64 = 0

    init(dataStore: WKWebsiteDataStore) {
        proxy = FileUIWeakMessageHandler()
        let config = WKWebViewConfiguration(); config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(proxy, name: "fileWorkspace")
        super.init(frame: .zero, configuration: config)
        proxy.owner = self; navigationDelegate = self; uiDelegate = self
    }
    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }
    func bind(viewIdentifier: String, context: iTermFileBrowserContext?, token: String, purpose: String) {
        fence = FileUIMessageFence(epoch: UUID().uuidString, view: viewIdentifier, token: token, generation: context?.generation ?? 0)
        self.purpose = purpose; incomingChunks.reset(); bound = true
        if pageReady { configure() }
    }
    func loadAssets(_ url: URL) {
        guard bound, assetURL == nil else { return }; assetURL = url; load(URLRequest(url: url))
    }
    private func configure() {
        var message = fence.dictionary; message["type"] = "configure"; message["requestIdentifier"] = UUID().uuidString
        message["payload"] = ["purpose": purpose, "labels": FileUIStrings.labels,
                              "locale": Bundle.main.preferredLocalizations.first ?? "en"]; deliver(message)
    }
    func send(_ type: String, payload: [String: Any] = [:], identifier: String = UUID().uuidString) {
        guard bound else { return }
        var message = fence.dictionary; message["type"] = type; message["payload"] = payload; message["requestIdentifier"] = identifier
        guard let data = try? JSONSerialization.data(withJSONObject: message), data.count <= 300 * 1024 * 1024,
              let string = String(data: data, encoding: .utf8) else { fileDelegate?.fileUIWebView(self, failed: fileUIError(4)); return }
        if string.utf16.count <= 262144 { deliver(message); return }
        let chunks = fileUIChunks(string), transfer = UUID().uuidString
        guard chunks.count <= 4096 else { fileDelegate?.fileUIWebView(self, failed: fileUIError(4)); return }
        for (index, text) in chunks.enumerated() {
            var chunk = fence.dictionary; chunk["type"] = "chunk"; chunk["requestIdentifier"] = identifier
            chunk["payload"] = ["identifier": transfer, "index": index, "total": chunks.count, "text": text]; deliver(chunk)
        }
    }

    func sendDocument(_ payload: [String: Any]) {
        documentTransferGeneration &+= 1
        guard var snapshot = payload["snapshot"] as? [String: Any], let text = snapshot["text"] as? String,
              text.utf16.count > 262144, payload["edits"] == nil else { send("document", payload: payload); return }
        let string = text as NSString, transfer = UUID().uuidString, generation = documentTransferGeneration, epoch = fence.epoch
        var ranges = [NSRange](), offset = 0
        while offset < string.length {
            var count = min(131072, string.length - offset)
            if offset + count < string.length, (0xd800...0xdbff).contains(string.character(at: offset + count - 1)),
               (0xdc00...0xdfff).contains(string.character(at: offset + count)) { count -= 1 }
            ranges.append(NSRange(location: offset, length: count)); offset += count
        }
        guard ranges.count <= 4096 else { fileDelegate?.fileUIWebView(self, failed: fileUIError(4)); return }
        snapshot.removeValue(forKey: "text")
        func message(_ type: String, _ payload: [String: Any]) -> [String: Any] {
            var result = fence.dictionary; result["type"] = type; result["payload"] = payload; result["requestIdentifier"] = transfer
            return result
        }
        func next(_ index: Int) {
            guard bound, fence.epoch == epoch, documentTransferGeneration == generation else { return }
            if index == ranges.count { deliver(message("documentEnd", ["transferIdentifier": transfer])); return }
            deliver(message("documentText", ["transferIdentifier": transfer, "index": index, "text": string.substring(with: ranges[index])])) { accepted in
                if accepted { next(index + 1) }
            }
        }
        deliver(message("documentStart", ["snapshot": snapshot, "transferIdentifier": transfer, "total": ranges.count])) { accepted in
            if accepted { next(0) }
        }
    }

    private func deliver(_ message: [String: Any], completion: ((Bool) -> Void)? = nil) {
        let epoch = fence.epoch
        callAsyncJavaScript("return window.fileWorkspace.receive(message)", arguments: ["message": message], in: nil, in: .page) { [weak self] result in
            guard let self = self, self.bound, self.fence.epoch == epoch else { completion?(false); return }
            if case .failure(let error) = result { self.fileDelegate?.fileUIWebView(self, failed: error as NSError); completion?(false) }
            else { completion?(true) }
        }
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.webView === self, message.frameInfo.isMainFrame, let origin = assetURL,
              message.frameInfo.securityOrigin.protocol == "http", message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == origin.port, message.frameInfo.request.url?.path == origin.path,
              let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "bootstrap", !pageReady { pageReady = true; if bound { configure() }; return }
        receiveBody(body)
    }
    private func receiveBody(_ body: [String: Any]) {
        guard bound, fence.accepts(body), let type = body["type"] as? String, let payload = body["payload"] as? [String: Any], let id = body["requestIdentifier"] as? String else { return }
        if type == "chunkNative" { if let assembled = incomingChunks.accept(payload), assembled["type"] as? String != "chunkNative" { receiveBody(assembled) }; return }
        if type == "ready" { fileDelegate?.fileUIWebViewReady(self); return }
        fileDelegate?.fileUIWebView(self, received: type, payload: payload, identifier: id)
    }

    func unbind() { bound = false; documentTransferGeneration &+= 1; fileDelegate = nil; incomingChunks.reset(); removeFromSuperview() }
    func shutdown() { unbind(); stopLoading(); configuration.userContentController.removeScriptMessageHandler(forName: "fileWorkspace"); navigationDelegate = nil; uiDelegate = nil }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == assetURL ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fileDelegate?.fileUIWebView(self, failed: fileUIError(5)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fileDelegate?.fileUIWebView(self, failed: error as NSError) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fileDelegate?.fileUIWebView(self, failed: error as NSError) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
