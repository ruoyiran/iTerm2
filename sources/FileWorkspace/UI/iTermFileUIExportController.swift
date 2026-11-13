import AppKit
import WebKit
import UniformTypeIdentifiers

final class FileUIExportController {
    private var job: FileHTMLPDFJob?
    func saveCopy(data: Data, name: String, window: NSWindow?, isCurrent: @escaping () -> Bool,
                  completion: @escaping (Result<[String: Any], Error>) -> Void) {
        choose(name: name, pdf: false, window: window) { url in
            guard let url else { completion(.success(["success": false, "cancelled": true])); return }
            guard isCurrent() else { completion(.failure(fileUIError(2))); return }
            do { try data.write(to: url, options: .atomic); completion(.success(["success": true, "filePath": url.path])) }
            catch { completion(.failure(error)) }
        }
    }
    func exportPDF(html: String, title: String, window: NSWindow?, isCurrent: @escaping () -> Bool,
                   completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard job == nil else { completion(.failure(fileUIError(6))); return }
        let name = (title as NSString).lastPathComponent
        choose(name: name.isEmpty ? "document.pdf" : (name as NSString).deletingPathExtension + ".pdf", pdf: true, window: window) { [weak self] url in
            guard let url else { completion(.success(["success": false, "cancelled": true])); return }
            guard let self, isCurrent(), self.job == nil else { completion(.failure(fileUIError(2))); return }
            let job = FileHTMLPDFJob(html: html, destination: url, isCurrent: isCurrent) { [weak self] error in
                self?.job = nil
                if let error { completion(.failure(error)) }
                else { completion(.success(["success": true, "filePath": url.path])) }
            }
            self.job = job; job.start()
        }
    }
    private func choose(name: String, pdf: Bool, window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        if pdf { panel.allowedContentTypes = [.pdf] }
        let selected: (NSApplication.ModalResponse) -> Void = { response in completion(response == .OK ? panel.url : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: selected) }
        else { panel.begin(completionHandler: selected) }
    }
}

private final class FileHTMLPDFJob: NSObject, WKNavigationDelegate {
    private let html: String
    private let destination: URL
    private let isCurrent: () -> Bool
    private var completion: ((NSError?) -> Void)?
    private let webView: WKWebView
    init(html: String, destination: URL, isCurrent: @escaping () -> Bool, completion: @escaping (NSError?) -> Void) {
        self.html = html; self.destination = destination; self.isCurrent = isCurrent; self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 595.28, height: 841.89), configuration: configuration)
        super.init(); webView.navigationDelegate = self
    }
    func start() {
        webView.loadHTMLString(html, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(fileUIError(6)) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript("await document.fonts.ready; await Promise.all(Array.from(document.images, image => image.decode().catch(() => {}))); return true", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.completion != nil else { return }
            guard self.isCurrent() else { self.finish(fileUIError(2)); return }
            if case .failure(let error) = result { self.finish(error as NSError); return }
            let info = NSPrintInfo()
            info.paperSize = NSSize(width: 595.28, height: 841.89)
            info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
            info.horizontalPagination = .fit; info.verticalPagination = .automatic
            info.isHorizontallyCentered = false; info.isVerticallyCentered = false; info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = self.destination
            let operation = self.webView.printOperation(with: info)
            operation.showsPrintPanel = false; operation.showsProgressPanel = false
            self.finish(operation.run() ? nil : fileUIError(7))
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error as NSError) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error as NSError) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(fileUIError(5)) }
    private func finish(_ error: NSError?) {
        guard let completion else { return }; self.completion = nil
        webView.stopLoading(); webView.navigationDelegate = nil; completion(error)
    }
}
