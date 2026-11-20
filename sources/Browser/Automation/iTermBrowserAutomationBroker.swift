import AppKit
import WebKit

// Host operations deliberately keep session/window ownership in iTermAPIHelper.
// The broker's host reference is weak to avoid a dependency cycle.
@MainActor
@objc protocol iTermBrowserAutomationHost: AnyObject {
    @objc(browserAutomationSessionWithID:)
    func browserAutomationSession(withID identifier: String) -> PTYSession?
    @objc(browserAutomationSessionsForOrigin:)
    func browserAutomationSessions(forOrigin origin: PTYSession) -> [PTYSession]
    @objc(browserAutomationScopeForOrigin:)
    func browserAutomationScope(forOrigin origin: PTYSession) -> String?
    @objc(browserAutomationIsSidebar:)
    func browserAutomationIsSidebar(_ session: PTYSession) -> Bool
    @objc(browserAutomationOpen:origin:completion:)
    func browserAutomationOpen(_ url: URL, origin: PTYSession, completion: @escaping (PTYSession?, Error?) -> Void)
    @objc(browserAutomationSelect:)
    func browserAutomationSelect(_ session: PTYSession) -> Bool
    @objc(browserAutomationClose:completion:)
    func browserAutomationClose(_ session: PTYSession, completion: @escaping (Bool) -> Void)
}

@MainActor
@objc(iTermBrowserAutomationBroker)
final class iTermBrowserAutomationBroker: NSObject {
    @MainActor private final class Operation {
        let request: iTermBrowserAutomationRequest
        let connection: String
        let scriptName: String
        let queueKey: String
        let completion: (ITMBrowserResponse) -> Void
        var cancelled: iTermBrowserAutomationError?
        var responded = false
        var closing = false
        var timer: DispatchSourceTimer?
        var cancelWait: ((iTermBrowserAutomationError) -> Void)?
        init(request: iTermBrowserAutomationRequest, connection: String, scriptName: String,
             queueKey: String, completion: @escaping (ITMBrowserResponse) -> Void) {
            self.request = request
            self.connection = connection
            self.scriptName = scriptName
            self.queueKey = queueKey
            self.completion = completion
        }
    }

    @MainActor private final class PermissionContinuation {
        private var continuation: CheckedContinuation<iTermWarningSelection, Error>?
        init(_ continuation: CheckedContinuation<iTermWarningSelection, Error>) { self.continuation = continuation }
        func fail(_ error: Error) {
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(throwing: error)
        }
        func answer(_ selection: iTermWarningSelection) {
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(returning: selection)
        }
    }

    // Localization unneeded: advertised machine-readable capabilities.
    private static let capabilities = ["tabs", "navigate", "snapshot", "click_dom", "fill_dom",
                                       "press_key_dom", "scroll_dom", "wait", "screenshot_viewport",
                                       "evaluate_isolated", "same_origin_frames", "cancel"]
    private weak var host: iTermBrowserAutomationHost?
    private let world = WKContentWorld.world(name: "iTerm2BrowserAutomation")
    private var operations = [String: Operation]()
    private var queues = [String: [Operation]]()
    private var running = Set<String>()

    @objc(initWithHost:)
    init(host: iTermBrowserAutomationHost) {
        self.host = host
        super.init()
    }

    @objc(handleRequest:connectionKey:scriptName:completion:)
    func handle(_ message: ITMBrowserRequest, connectionKey: String, scriptName: String,
                completion: @escaping (ITMBrowserResponse) -> Void) {
        do {
            let request = try iTermBrowserAutomationRequest(
                originSessionID: message.originSessionId ?? "", browserSessionID: message.browserSessionId ?? "",
                action: message.action ?? "", argumentsJSON: message.argumentsJson ?? "{}",
                timeoutMS: message.timeoutMs, requestID: message.requestId ?? "")
            guard !connectionKey.isEmpty else { throw iTermBrowserAutomationError.permissionDenied }
            if request.action == .cancel {
                let key = operationKey(connectionKey, request.arguments["request_id"] as! String)
                let target = operations[key]
                if let target { cancel(target, error: .cancelled) }
                completion(response(result: ["cancelled": target != nil]))
                return
            }
            guard let host, let origin = host.browserAutomationSession(withID: request.originSessionID),
                  let scope = host.browserAutomationScope(forOrigin: origin) else { throw iTermBrowserAutomationError.originNotFound }
            let key = operationKey(connectionKey, request.requestID)
            guard operations[key] == nil else { throw iTermBrowserAutomationError.invalidRequest }
            let queueKey = request.browserSessionID.isEmpty ? "scope:\(scope)" : request.browserSessionID
            let op = Operation(request: request, connection: connectionKey, scriptName: scriptName,
                               queueKey: queueKey, completion: completion)
            try check(op)
            operations[key] = op
            queues[queueKey, default: []].append(op)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            op.timer = timer
            timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
            timer.setEventHandler { [weak self, weak op] in
                guard let self, let op, !op.responded else { return }
                do { try self.check(op) }
                catch { self.cancel(op, error: error as? iTermBrowserAutomationError ?? .internalError) }
            }
            timer.resume()
            DLog("Browser automation queued \(request.action.rawValue) request \(request.requestID)")
            pump(queueKey)
        } catch {
            completion(response(error: error as? iTermBrowserAutomationError ?? .invalidRequest))
        }
    }

    @objc(cancelConnection:)
    func cancelConnection(_ connection: String) {
        for op in Array(operations.values) where op.connection == connection {
            cancel(op, error: .cancelled)
        }
    }

    @objc(cancelAllRequests)
    func cancelAllRequests() {
        for op in Array(operations.values) { cancel(op, error: .cancelled) }
    }

    private func operationKey(_ connection: String, _ request: String) -> String { connection + "\0" + request }

    private func check(_ op: Operation) throws {
        if let error = op.cancelled { throw error }
        guard !op.request.expired() else { throw iTermBrowserAutomationError.timeout }
        guard let host, let origin = host.browserAutomationSession(withID: op.request.originSessionID),
              host.browserAutomationScope(forOrigin: origin) != nil else { throw iTermBrowserAutomationError.originNotFound }
        if !op.request.browserSessionID.isEmpty {
            if op.closing && host.browserAutomationSession(withID: op.request.browserSessionID) == nil { return }
            guard let target = host.browserAutomationSession(withID: op.request.browserSessionID),
                  target.isBrowserSession(), target.view?.browserViewController != nil else { throw iTermBrowserAutomationError.targetNotFound }
            guard host.browserAutomationSessions(forOrigin: origin).contains(where: { $0 === target }) else { throw iTermBrowserAutomationError.outOfScope }
        }
    }

    private func cancel(_ op: Operation, error: iTermBrowserAutomationError) {
        guard op.cancelled == nil else { return }
        op.cancelled = error
        finish(op, response(error: error))
        let cancelWait = op.cancelWait
        op.cancelWait = nil
        cancelWait?(error)
    }

    private func finish(_ op: Operation, _ value: ITMBrowserResponse) {
        guard !op.responded else { return }
        op.responded = true
        op.timer?.cancel()
        op.timer = nil
        operations.removeValue(forKey: operationKey(op.connection, op.request.requestID))
        op.completion(value)
    }

    private func pump(_ key: String) {
        guard !running.contains(key) else { return }
        while var queue = queues[key], !queue.isEmpty {
            let op = queue.removeFirst()
            queues[key] = queue
            if op.responded { continue }
            running.insert(key)
            Task { @MainActor in
                do {
                    let (result, png) = try await perform(op)
                    try check(op)
                    finish(op, response(result: result, png: png))
                } catch {
                    finish(op, response(error: error as? iTermBrowserAutomationError ?? .internalError))
                }
                running.remove(key)
                if queues[key]?.isEmpty == true { queues.removeValue(forKey: key) }
                pump(key)
            }
            return
        }
        queues.removeValue(forKey: key)
    }

    private func perform(_ op: Operation) async throws -> ([String: Any], Data?) {
        try check(op)
        guard let host, let origin = host.browserAutomationSession(withID: op.request.originSessionID) else { throw iTermBrowserAutomationError.originNotFound }
        let args = op.request.arguments
        if op.request.action == .tabs {
            let operation = args["operation"] as! String
            if operation == "list" {
                let tabs: [[String: Any]] = host.browserAutomationSessions(forOrigin: origin).filter { $0.isBrowserSession() }.map { session in
                    ["browser_session_id": session.guid, "title": session.name,
                     "url": session.view?.browserViewController?.webView.url?.absoluteString ?? "",
                     "sidebar": host.browserAutomationIsSidebar(session)]
                }
                return (["tabs": tabs], nil)
            }
            if operation == "create" {
                let url = iTermBrowserAutomationRequest.webURL(args["url"] as! String)!
                try await authorize(url: url, op: op, origin: origin)
                try check(op)
                let session: PTYSession = try await withCheckedThrowingContinuation { continuation in
                    host.browserAutomationOpen(url, origin: origin) { session, error in
                        if let session { continuation.resume(returning: session) }
                        else { continuation.resume(throwing: error ?? iTermBrowserAutomationError.unsupported) }
                    }
                }
                // The synchronous host must establish ownership before reporting creation.
                guard host.browserAutomationSessions(forOrigin: origin).contains(where: { $0 === session }), session.isBrowserSession() else {
                    throw iTermBrowserAutomationError.internalError
                }
                return (["browser_session_id": session.guid], nil)
            }
        }
        guard let target = host.browserAutomationSession(withID: op.request.browserSessionID),
              let controller = target.view?.browserViewController else { throw iTermBrowserAutomationError.targetNotFound }
        let webView = controller.webView
        // A navigation acknowledgement is not a load completion. Wait until the
        // currently loading document settles before asking permission for ready.
        if op.request.action == .wait && args["state"] as? String == "ready" {
            while webView.isLoading {
                try check(op)
                try await pause(op)
            }
        }
        let expectedOrigin = try await documentOrigin(webView)
        try await authorize(url: URL(string: expectedOrigin)!, op: op, origin: origin)
        try check(op)
        // Origin is read again after an asynchronous permission sheet, immediately before
        // native dispatch. DOM helpers also check it in the same script as the action.
        guard try await documentOrigin(webView) == expectedOrigin else { throw iTermBrowserAutomationError.navigationChanged }
        try check(op)
        var result: [String: Any] = ["browser_session_id": target.guid]
        if op.request.action == .tabs {
            guard host.browserAutomationIsSidebar(target) else { throw iTermBrowserAutomationError.unsupported }
            if args["operation"] as? String == "select" {
                guard host.browserAutomationSelect(target) else { throw iTermBrowserAutomationError.targetNotFound }
                result["selected"] = true
            } else {
                op.closing = true
                let closed: Bool = await withCheckedContinuation { continuation in
                    host.browserAutomationClose(target) { continuation.resume(returning: $0) }
                }
                guard closed else { throw iTermBrowserAutomationError.unsupported }
                // Closing the target intentionally makes the final liveness check fail;
                // finish here once the host confirms removal rather than claiming success early.
                guard host.browserAutomationSession(withID: target.guid) == nil else { throw iTermBrowserAutomationError.internalError }
                result["closed"] = true
                finish(op, response(result: result))
            }
            return (result, nil)
        }
        if op.request.action == .navigate {
            let operation = args["operation"] as! String
            var destination: URL?
            var historyItem: WKBackForwardListItem?
            switch operation {
            case "navigate": destination = iTermBrowserAutomationRequest.webURL(args["url"] as! String)
            case "back":
                historyItem = webView.backForwardList.backItem
                destination = historyItem?.url
            case "forward":
                historyItem = webView.backForwardList.forwardItem
                destination = historyItem?.url
            default: destination = URL(string: expectedOrigin)
            }
            guard let destination, iTermBrowserAutomationRequest.webURL(destination.absoluteString) != nil else { throw iTermBrowserAutomationError.unsupported }
            try await authorize(url: destination, op: op, origin: origin)
            try check(op)
            guard try await documentOrigin(webView) == expectedOrigin else { throw iTermBrowserAutomationError.navigationChanged }
            try check(op)
            let navigation: WKNavigation?
            switch operation {
            case "navigate": navigation = webView.load(URLRequest(url: destination))
            case "back", "forward":
                guard let historyItem,
                      (operation == "back" ? webView.backForwardList.backItem : webView.backForwardList.forwardItem) === historyItem else { throw iTermBrowserAutomationError.navigationChanged }
                navigation = webView.go(to: historyItem)
            default: navigation = webView.reload()
            }
            guard navigation != nil else { throw iTermBrowserAutomationError.unsupported }
            result["navigation_started"] = true
            return (result, nil)
        }
        if op.request.action == .screenshot {
            guard webView.bounds.width > 0, webView.bounds.height > 0 else { throw iTermBrowserAutomationError.unsupported }
            let image = try await webView.takeSnapshot(configuration: nil)
            try check(op)
            guard try await documentOrigin(webView) == expectedOrigin else { throw iTermBrowserAutomationError.navigationChanged }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw iTermBrowserAutomationError.internalError }
            result["format"] = "png"
            return (result, png)
        }
        if op.request.action == .wait {
            while true {
                try check(op)
                let value = try await runDOM(op, webView: webView, expectedOrigin: expectedOrigin)
                if value["matched"] as? Bool == true && (args["state"] as? String != "ready" || !webView.isLoading) {
                    result.merge(value) { _, new in new }
                    return (result, nil)
                }
                try await pause(op)
            }
        }
        let value = try await runDOM(op, webView: webView, expectedOrigin: expectedOrigin)
        result.merge(value) { _, new in new }
        return (result, nil)
    }

    private func documentOrigin(_ webView: WKWebView) async throws -> String {
        let value = try await webView.callAsyncJavaScript("return location.origin", arguments: [:], in: nil, contentWorld: world)
        guard let origin = value as? String,
              iTermBrowserScriptingPermissions.javaScriptOrigin(for: URL(string: origin)) != nil else { throw iTermBrowserAutomationError.unsupported }
        return origin
    }

    private func authorize(url: URL, op: Operation, origin: PTYSession) async throws {
        try check(op)
        guard let site = iTermBrowserScriptingPermissions.javaScriptOrigin(for: url),
              let window = origin.delegate?.realParentWindow()?.window else { throw iTermBrowserAutomationError.unsupported }
        let warning = iTermWarning()
        warning.title = String(localized: "BrowserAutomation.PermissionTitle", defaultValue: "Allow scripts to read and control pages on \(site)?", comment: "Permission prompt for browser automation; placeholder is the website origin")
        warning.heading = String(localized: "BrowserAutomation.PermissionHeading", defaultValue: "\(op.scriptName) wants to control this browser workspace.", comment: "Permission heading for browser automation; placeholder is the authenticated script name")
        warning.actionLabels = [iTermLocalizedOK(), iTermLocalizedCancel()]
        warning.identifier = iTermBrowserScriptingPermissions.javaScriptIdentifier(origin: site)
        warning.warningType = .kiTermWarningTypePermanentlySilenceable
        warning.window = window
        let selection: iTermWarningSelection = try await withCheckedThrowingContinuation { continuation in
            let pending = PermissionContinuation(continuation)
            op.cancelWait = { error in pending.fail(error) }
            warning.runModalAsync { [weak op] selection, _ in
                Task { @MainActor in
                    op?.cancelWait = nil
                    pending.answer(selection)
                }
            }
        }
        try check(op)
        guard selection == .kiTermWarningSelection0 else { throw iTermBrowserAutomationError.permissionDenied }
    }

    private func runDOM(_ op: Operation, webView: WKWebView, expectedOrigin: String) async throws -> [String: Any] {
        try check(op)
        let evaluate = op.request.action == .evaluate
        let script = iTermBrowserTemplateLoader.load(template: evaluate ? "browser-automation-evaluate.js" : "browser-automation.js")
        var arguments: [String: Any] = ["action": op.request.action.rawValue, "args": op.request.arguments,
                                       "expectedOrigin": expectedOrigin, "deadline": op.request.javaScriptDeadline]
        if evaluate { arguments["expression"] = op.request.arguments["expression"] }
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world)
        } catch { throw iTermBrowserAutomationError.javascriptError }
        try check(op)
        guard let result = value as? [String: Any] else { throw iTermBrowserAutomationError.internalError }
        if let code = result["error_code"] as? String {
            throw iTermBrowserAutomationError(rawValue: code) ?? .internalError
        }
        return result
    }

    private func pause(_ op: Operation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            let work = DispatchWorkItem {
                guard !completed else { return }
                completed = true
                op.cancelWait = nil
                continuation.resume()
            }
            op.cancelWait = { error in
                guard !completed else { return }
                completed = true
                work.cancel()
                continuation.resume(throwing: error)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    private func response(result: [String: Any] = [:], png: Data? = nil,
                          error: iTermBrowserAutomationError? = nil) -> ITMBrowserResponse {
        let response = ITMBrowserResponse()
        response.capabilitiesArray = NSMutableArray(array: Self.capabilities)
        if let error {
            response.errorCode = error.rawValue
            response.errorMessage = error.localizedMessage
        } else if JSONSerialization.isValidJSONObject(result),
                  let data = try? JSONSerialization.data(withJSONObject: result),
                  let json = String(data: data, encoding: .utf8) {
            response.resultJson = json
            if let png { response.pngData = png }
        } else {
            response.errorCode = iTermBrowserAutomationError.internalError.rawValue
            response.errorMessage = iTermBrowserAutomationError.internalError.localizedMessage
        }
        return response
    }
}

private extension iTermBrowserAutomationError {
    var localizedMessage: String {
        switch self {
        case .invalidRequest: return String(localized: "BrowserAutomation.InvalidRequest", defaultValue: "The browser request is invalid.", comment: "Error returned for malformed browser automation arguments")
        case .originNotFound: return String(localized: "BrowserAutomation.OriginNotFound", defaultValue: "The originating session is no longer available.", comment: "Error returned when the browser automation origin session closed")
        case .targetNotFound: return String(localized: "BrowserAutomation.TargetNotFound", defaultValue: "The browser session is no longer available.", comment: "Error returned when a browser automation target closed")
        case .outOfScope: return String(localized: "BrowserAutomation.OutOfScope", defaultValue: "The browser session belongs to a different workspace.", comment: "Error returned when an automation request targets another primary tab")
        case .permissionDenied: return String(localized: "BrowserAutomation.PermissionDenied", defaultValue: "Permission to control this website was denied.", comment: "Error returned when a browser automation permission prompt is declined")
        case .unsupported: return String(localized: "BrowserAutomation.Unsupported", defaultValue: "This browser interaction is not supported.", comment: "Error returned for unavailable or unsafe browser automation interactions")
        case .staleReference: return String(localized: "BrowserAutomation.StaleReference", defaultValue: "The page reference expired. Take a new snapshot before using it.", comment: "Error returned when a browser snapshot generation or element reference expired")
        case .elementNotFound: return String(localized: "BrowserAutomation.ElementNotFound", defaultValue: "The page element is no longer available.", comment: "Error returned when a referenced DOM element was removed")
        case .elementNotInteractable: return String(localized: "BrowserAutomation.ElementNotInteractable", defaultValue: "The page element cannot receive this interaction.", comment: "Error returned for hidden, disabled or read-only browser elements")
        case .navigationChanged: return String(localized: "BrowserAutomation.NavigationChanged", defaultValue: "The browser navigated to a different website before the action could run.", comment: "Error returned when browser navigation changes the approved origin")
        case .timeout: return String(localized: "BrowserAutomation.Timeout", defaultValue: "The browser request timed out.", comment: "Error returned when browser automation exceeds its deadline")
        case .cancelled: return String(localized: "BrowserAutomation.Cancelled", defaultValue: "The browser request was cancelled.", comment: "Error returned when a browser automation request is cancelled")
        case .javascriptError: return String(localized: "BrowserAutomation.JavaScriptError", defaultValue: "The browser could not execute the page action.", comment: "Error returned when a browser automation JavaScript helper fails")
        case .internalError: return String(localized: "BrowserAutomation.InternalError", defaultValue: "The browser returned an invalid result.", comment: "Error returned for an inconsistent native browser automation result")
        }
    }
}
