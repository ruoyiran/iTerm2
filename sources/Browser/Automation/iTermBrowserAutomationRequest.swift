import Foundation

// Localization unneeded: wire identifiers and structural error codes.
enum iTermBrowserAutomationAction: String, CaseIterable {
    case tabs, navigate, snapshot, click, fill, pressKey = "press_key", scroll, wait, screenshot, evaluate, cancel
}

enum iTermBrowserAutomationError: String, Error {
    case invalidRequest = "invalid_request"
    case originNotFound = "origin_not_found"
    case targetNotFound = "target_not_found"
    case outOfScope = "out_of_scope"
    case permissionDenied = "permission_denied"
    case unsupported
    case staleReference = "stale_reference"
    case elementNotFound = "element_not_found"
    case elementNotInteractable = "element_not_interactable"
    case navigationChanged = "navigation_changed"
    case timeout, cancelled
    case javascriptError = "javascript_error"
    case internalError = "internal_error"
}

struct iTermBrowserAutomationRequest {
    let originSessionID: String
    let browserSessionID: String
    let action: iTermBrowserAutomationAction
    let arguments: [String: Any]
    let requestID: String
    let deadline: TimeInterval
    let javaScriptDeadline: TimeInterval

    init(originSessionID: String, browserSessionID: String, action: String,
         argumentsJSON: String, timeoutMS: UInt32, requestID: String) throws {
        guard !originSessionID.isEmpty, !["active", "all"].contains(originSessionID),
              !["active", "all"].contains(browserSessionID),
              originSessionID.utf8.count <= 256, browserSessionID.utf8.count <= 256,
              requestID.utf8.count <= 256,
              let action = iTermBrowserAutomationAction(rawValue: action),
              (1...120000).contains(timeoutMS),
              argumentsJSON.utf8.count <= 1_048_576,
              let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw iTermBrowserAutomationError.invalidRequest
        }
        self.originSessionID = originSessionID
        self.browserSessionID = browserSessionID
        self.action = action
        self.arguments = arguments
        self.requestID = requestID.isEmpty ? UUID().uuidString : requestID
        deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMS) / 1000
        javaScriptDeadline = (Date().timeIntervalSince1970 + Double(timeoutMS) / 1000) * 1000
        try validate()
    }

    func expired(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        uptime >= deadline
    }

    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func validate() throws {
        var allowed = Set<String>()
        func requireString(_ key: String, emptyOK: Bool = false) throws {
            guard let value = arguments[key] as? String, emptyOK || !value.isEmpty else {
                throw iTermBrowserAutomationError.invalidRequest
            }
        }
        func operation(_ choices: [String]) throws -> String {
            guard let value = arguments["operation"] as? String, choices.contains(value) else {
                throw iTermBrowserAutomationError.invalidRequest
            }
            return value
        }
        func reference() throws {
            try requireString("generation")
            try requireString("ref")
        }
        func url() throws {
            guard let value = arguments["url"] as? String, Self.webURL(value) != nil else {
                throw iTermBrowserAutomationError.invalidRequest
            }
        }
        func number(_ key: String) throws -> Double {
            guard let value = arguments[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
                throw iTermBrowserAutomationError.invalidRequest
            }
            return value.doubleValue
        }
        switch action {
        case .tabs:
            allowed = ["operation", "url"]
            let op = try operation(["list", "create", "select", "close"])
            if op == "create" { try url() }
            if ["select", "close"].contains(op) && browserSessionID.isEmpty { throw iTermBrowserAutomationError.invalidRequest }
        case .navigate:
            allowed = ["operation", "url"]
            if try operation(["navigate", "back", "forward", "reload"]) == "navigate" { try url() }
        case .snapshot:
            allowed = ["max_nodes"]
            if arguments["max_nodes"] != nil {
                let value = try number("max_nodes")
                guard (1...2000).contains(value), value.rounded() == value else { throw iTermBrowserAutomationError.invalidRequest }
            }
        case .click:
            allowed = ["generation", "ref"]
            try reference()
        case .fill:
            allowed = ["generation", "ref", "value"]
            try reference()
            try requireString("value", emptyOK: true)
        case .pressKey:
            allowed = ["generation", "ref", "key"]
            try requireString("generation")
            try requireString("key")
        case .scroll:
            allowed = ["generation", "ref", "x", "y"]
            try requireString("generation")
            _ = try number("x")
            _ = try number("y")
        case .wait:
            allowed = ["generation", "selector", "state"]
            guard let state = arguments["state"] as? String,
                  ["visible", "hidden", "attached", "detached", "ready"].contains(state) else { throw iTermBrowserAutomationError.invalidRequest }
            if state != "ready" { try requireString("selector") }
        case .screenshot:
            break
        case .evaluate:
            allowed = ["expression"]
            try requireString("expression")
        case .cancel:
            allowed = ["request_id"]
            try requireString("request_id")
        }
        guard Set(arguments.keys).isSubset(of: allowed) else { throw iTermBrowserAutomationError.invalidRequest }
        for key in ["generation", "ref", "selector", "url"] where arguments[key] != nil {
            try requireString(key)
        }
        if action != .tabs && action != .cancel && browserSessionID.isEmpty { throw iTermBrowserAutomationError.invalidRequest }
    }
}
