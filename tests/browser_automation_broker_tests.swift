import AppKit
import WebKit

@MainActor
final class Host: NSObject, iTermBrowserAutomationHost {
    let origin = PTYSession()
    let foreign = PTYSession()
    var targets: [PTYSession] = []
    var opens = 0
    var deferOpen = false
    var pendingOpen: ((PTYSession?, Error?) -> Void)?
    let window = NSWindow(contentRect: NSRect(x:0,y:0,width:100,height:100), styleMask: [], backing: .buffered, defer: false)
    override init() {
        super.init()
        origin.guid = "origin"
        origin.delegate = PTYSessionDelegate()
        origin.delegate?.controller = NSWindowController(window: window)
        foreign.guid = "foreign"
        foreign.browserSession = true
        foreign.view = SessionView()
        foreign.view?.browserViewController = iTermBrowserViewController()
    }
    func browserAutomationSession(withID id: String) -> PTYSession? {
        ([origin,foreign]+targets).first { $0.guid == id }
    }
    func browserAutomationSessions(forOrigin origin: PTYSession) -> [PTYSession] { [origin]+targets }
    func browserAutomationScope(forOrigin origin: PTYSession) -> String? { origin === self.origin ? "tab" : nil }
    func browserAutomationIsSidebar(_ session: PTYSession) -> Bool { targets.contains(session) }
    func browserAutomationOpen(_ url: URL, origin: PTYSession, completion: @escaping (PTYSession?, Error?) -> Void) {
        opens += 1
        if deferOpen { pendingOpen = completion }
        else { completeOpen(completion) }
    }
    func completeOpen(_ completion: ((PTYSession?, Error?) -> Void)? = nil) {
        let session = PTYSession()
        session.guid = "browser\(opens)"
        session.browserSession = true
        targets.append(session)
        (completion ?? pendingOpen)?(session,nil)
        pendingOpen = nil
    }
    func browserAutomationSelect(_ session: PTYSession) -> Bool { true }
    func browserAutomationClose(_ session: PTYSession, completion: @escaping (Bool) -> Void) {
        targets.removeAll { $0 === session }
        completion(true)
    }
}

@MainActor
final class PageLoader: NSObject, WKNavigationDelegate {
    var completion: CheckedContinuation<Void, Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume()
        completion = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error)
        completion = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error)
        completion = nil
    }
}

@main
struct BrokerTests {
    @MainActor
    static func message(_ id: String, action: String = "tabs", args: String = "{\"operation\":\"create\",\"url\":\"https://example.com\"}", timeout: UInt32 = 30000, browser: String = "") -> ITMBrowserRequest {
        let request = ITMBrowserRequest()
        request.originSessionId = "origin"
        request.browserSessionId = browser
        request.requestId = id
        request.action = action
        request.argumentsJson = args
        request.timeoutMs = timeout
        return request
    }
    @MainActor
    static func send(_ broker: iTermBrowserAutomationBroker, _ request: ITMBrowserRequest, connection: String = "connection") async -> ITMBrowserResponse {
        await withCheckedContinuation { completion in
            broker.handle(request, connectionKey: connection, scriptName: "test") { completion.resume(returning: $0) }
        }
    }
    @MainActor
    static func drain() async {
        // Event-driven barrier, not a delay intended to make races disappear.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let host = Host()
        let broker = iTermBrowserAutomationBroker(host: host)
        let wrongScope = await send(broker,message("wrong",action:"snapshot",args:"{}",browser:"foreign"))
        precondition(wrongScope.errorCode == "out_of_scope")
        iTermWarning.autoAnswer = false
        let deniedTask = Task { await send(broker,message("denied")) }
        await drain()
        precondition(host.opens == 0)
        iTermWarning.answerAll(.kiTermWarningSelection1)
        let denied = await deniedTask.value
        precondition(denied.errorCode == "permission_denied")
        let cancelTask = Task { await send(broker,message("cancel-me")) }
        await drain()
        let unrelated = await send(broker,message("cancel-other",action:"cancel",args:"{\"request_id\":\"cancel-me\"}"),connection:"other")
        precondition(unrelated.resultJson.contains("false"))
        let cancelled = await send(broker,message("cancel",action:"cancel",args:"{\"request_id\":\"cancel-me\"}"))
        precondition(cancelled.resultJson.contains("true"))
        let cancelledResponse = await cancelTask.value
        precondition(cancelledResponse.errorCode == "cancelled")
        iTermWarning.answerAll()
        await drain()
        precondition(host.opens == 0, "Late permission approval must never dispatch creation")
        let timeout = await send(broker,message("deadline",timeout:1))
        precondition(timeout.errorCode == "timeout")
        iTermWarning.answerAll()
        await drain()
        precondition(host.opens == 0)
        let disconnectTask = Task { await send(broker,message("disconnect")) }
        await drain()
        broker.cancelConnection("connection")
        let disconnectedResponse = await disconnectTask.value
        precondition(disconnectedResponse.errorCode == "cancelled")
        iTermWarning.answerAll()
        await drain()
        precondition(host.opens == 0)
        iTermWarning.autoAnswer = true
        host.deferOpen = true
        let first = Task { await send(broker,message("first")) }
        await drain()
        let second = Task { await send(broker,message("second")) }
        await drain()
        precondition(host.opens == 1, "Same scope actions must execute in order")
        host.completeOpen()
        let firstResponse = await first.value
        precondition(firstResponse.errorCode.isEmpty)
        await drain()
        precondition(host.opens == 2)
        host.completeOpen()
        let secondResponse = await second.value
        precondition(secondResponse.errorCode.isEmpty)
        // Exercise the actual broker and resources in a real offscreen WKWebView.
        // Only session ownership and permission UI are replaced by test fixtures.
        iTermBrowserTemplateLoader.loadResources = true
        let browser = PTYSession()
        browser.guid = "native-browser"
        browser.browserSession = true
        browser.view = SessionView()
        browser.view?.browserViewController = iTermBrowserViewController()
        host.targets.append(browser)
        let webView = browser.view!.browserViewController!.webView
        webView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        host.window.contentView!.addSubview(webView)
        let loader = PageLoader()
        webView.navigationDelegate = loader
        let html = try String(contentsOfFile: "tests/browser_automation_native_fixture.html", encoding: .utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loader.completion = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com"))
        }
        let snapshot = await send(broker,message("native-snapshot",action:"snapshot",args:"{}",browser:browser.guid))
        precondition(snapshot.errorCode.isEmpty)
        let snapshotJSON = try JSONSerialization.jsonObject(with: Data(snapshot.resultJson.utf8)) as! [String: Any]
        let generation = snapshotJSON["generation"] as! String
        let nodes = snapshotJSON["nodes"] as! [[String: Any]]
        let input = nodes.first { $0["name"] as? String == "Name" && $0["tag"] as? String == "input" }!
        let button = nodes.first { $0["role"] as? String == "button" }!
        func json(_ args: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        }
        let fill = await send(broker,message("native-fill",action:"fill",args:try json(["generation":generation,"ref":input["ref"]!,"value":"Ada"]),browser:browser.guid))
        precondition(fill.errorCode.isEmpty)
        let click = await send(broker,message("native-click",action:"click",args:try json(["generation":generation,"ref":button["ref"]!]),browser:browser.guid))
        precondition(click.errorCode.isEmpty)
        let evaluate = await send(broker,message("native-evaluate",action:"evaluate",args:try json(["expression":"return {value: document.getElementById('name').value, button: document.getElementById('button').textContent, pageGlobal: typeof pageSecret}"]),browser:browser.guid))
        precondition(evaluate.errorCode.isEmpty)
        let evaluationJSON = try JSONSerialization.jsonObject(with: Data(evaluate.resultJson.utf8)) as! [String: Any]
        let evaluated = evaluationJSON["value"] as! [String: Any]
        precondition(evaluated["value"] as? String == "Ada")
        precondition(evaluated["button"] as? String == "Clicked")
        precondition(evaluated["pageGlobal"] as? String == "undefined", "Automation must be isolated from page JavaScript globals")
        let screenshot = await send(broker,message("native-screenshot",action:"screenshot",args:"{}",browser:browser.guid))
        precondition(screenshot.errorCode.isEmpty)
        precondition(screenshot.pngData?.prefix(8) == Data([137,80,78,71,13,10,26,10]))
        print("PASS: real WKWebView isolated snapshot, DOM fill/click effects, evaluate return and viewport PNG")
        print("PASS: broker origin scope, denial, connection-scoped cancel, deadline, disconnect, late prompt and FIFO ordering")
    }
}
