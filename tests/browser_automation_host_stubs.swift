import AppKit
import WebKit
@objc class ITMBrowserRequest: NSObject {
    @objc var originSessionId: String? = ""
    @objc var browserSessionId: String? = ""
    @objc var action: String? = ""
    @objc var argumentsJson: String? = "{}"
    @objc var timeoutMs: UInt32 = 30000
    @objc var requestId: String? = ""
}
@objc class ITMBrowserResponse: NSObject {
    @objc var capabilitiesArray: NSMutableArray = []
    @objc var errorCode: String = ""
    @objc var errorMessage: String = ""
    @objc var resultJson: String = ""
    @objc var pngData: Data?
}
@objc class PTYSessionDelegate: NSObject {
    var controller: NSWindowController?
    func realParentWindow() -> NSWindowController? { controller }
}
@objc class PTYSession: NSObject {
    @objc var guid = ""
    @objc var name: String = ""
    @objc var browserSession = false
    @objc func isBrowserSession() -> Bool { browserSession }
    @objc var view: SessionView?
    @objc var delegate: PTYSessionDelegate?
}
@objc class SessionView: NSObject {
    @objc var browserViewController: iTermBrowserViewController?
}
@objc class iTermBrowserViewController: NSObject {
    @objc lazy var webView = WKWebView()
}
class iTermBrowserTemplateLoader {
    static var loadResources = false
    static func load(template: String) -> String {
        guard loadResources else { return "return {}" }
        return (try? String(contentsOfFile: "sources/Browser/Automation/" + template, encoding: .utf8)) ?? "return {}"
    }
}
class iTermBrowserScriptingPermissions {
    static func javaScriptOrigin(for url: URL?) -> String? { url?.absoluteString }
    static func javaScriptIdentifier(origin: String) -> String { origin }
}
enum iTermWarningSelection { case kiTermWarningSelection0, kiTermWarningSelection1 }
enum iTermWarningType { case kiTermWarningTypePermanentlySilenceable }
class iTermWarning {
    var title = ""
    var heading = ""
    var actionLabels: [String] = []
    var identifier = ""
    var warningType = iTermWarningType.kiTermWarningTypePermanentlySilenceable
    var window: NSWindow?
    static var autoAnswer = true
    static var pending: [(iTermWarningSelection,iTermWarning)->Void] = []
    func runModalAsync(_ completion: @escaping (iTermWarningSelection,iTermWarning)->Void) {
        if Self.autoAnswer { completion(.kiTermWarningSelection0,self) }
        else { Self.pending.append(completion) }
    }
    static func answerAll(_ selection: iTermWarningSelection = .kiTermWarningSelection0) {
        let callbacks = pending
        pending.removeAll()
        for callback in callbacks { callback(selection,iTermWarning()) }
    }
}
func iTermLocalizedOK() -> String { "OK" }
func iTermLocalizedCancel() -> String { "Cancel" }
func DLog(_ value: String) {}
