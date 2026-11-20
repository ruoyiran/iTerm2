import Foundation
#if canImport(ProtobufRuntime)
import ProtobufRuntime
#endif

/// Stable browser errors, independent of localized API messages.
public struct BrowserClientError: Error, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var json: String {
        (try? browserJSONString(["ok": false, "error": ["code": code, "message": message]])) ?? "{}"
    }
    static func converting(_ error: Error) -> BrowserClientError {
        if let error = error as? BrowserClientError { return error }
        if error is CancellationError { return .init(code: "cancelled", message: "Request cancelled.") }
        return .init(code: "internal_error", message: String(describing: error))
    }
}

func browserJSONString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

public struct BrowserClientResult: Sendable {
    public let resultJSON: String
    public let pngData: Data
    public let capabilities: [String]
    public init(resultJSON: String, pngData: Data = Data(), capabilities: [String] = []) {
        self.resultJSON = resultJSON; self.pngData = pngData; self.capabilities = capabilities
    }
    public func json(includePNG: Bool = true) throws -> String {
        let value = try JSONSerialization.jsonObject(with: Data(resultJSON.utf8), options: .fragmentsAllowed)
        var object: [String: Any] = ["ok": true, "result": value, "capabilities": capabilities]
        if includePNG && !pngData.isEmpty { object["png_data"] = pngData.base64EncodedString() }
        return try browserJSONString(object)
    }
    static func decode(_ response: ITMServerOriginatedMessage) throws -> Self {
        guard response.submessageOneOfCase == .browserResponse, let value = response.browserResponse else {
            throw BrowserClientError(code: "internal_error", message: "Missing browser response.")
        }
        if !value.errorCode.isEmpty { throw BrowserClientError(code: value.errorCode, message: value.errorMessage) }
        _ = try JSONSerialization.jsonObject(with: Data(value.resultJson.utf8), options: .fragmentsAllowed)
        return .init(resultJSON: value.resultJson, pngData: value.pngData, capabilities: value.capabilitiesArray as? [String] ?? [])
    }
}

/// Validated frozen wire request. Shared by CLI and the separate MCP executable.
public struct BrowserClientRequest: Sendable {
    public let action: String
    public let argumentsJSON: String
    public let browserSessionID: String?
    public let timeoutMS: UInt32
    public let requestID: String
    public static let capabilities = ["tabs", "navigate", "snapshot", "click_dom", "fill_dom", "press_key_dom", "scroll_dom", "wait", "screenshot_viewport", "evaluate_isolated", "same_origin_frames", "cancel"]
    public static let actions = ["tabs", "navigate", "snapshot", "click", "fill", "press_key", "scroll", "wait", "screenshot", "evaluate", "cancel"]

    public init(action: String, argumentsJSON: String = "{}", browserSessionID: String? = nil, timeoutMS: Int = 30000, requestID: String = UUID().uuidString) throws {
        guard (1...120000).contains(timeoutMS), !requestID.isEmpty,
              browserSessionID == nil || !(browserSessionID?.isEmpty ?? true) else {
            throw BrowserClientError(code: "invalid_request", message: "Invalid timeout, request ID, or browser session.")
        }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) }
        catch { throw BrowserClientError(code: "invalid_request", message: "Arguments must be a JSON object.") }
        guard let arguments = parsed as? [String: Any] else { throw BrowserClientError(code: "invalid_request", message: "Arguments must be a JSON object.") }
        try Self.validate(action, arguments)
        if action == "tabs", let operation = arguments["operation"] as? String,
           ["select", "close"].contains(operation), browserSessionID == nil {
            throw BrowserClientError(code: "invalid_request", message: "Select and close require a browser session target.")
        }
        self.action = action; self.argumentsJSON = try browserJSONString(arguments)
        self.browserSessionID = browserSessionID; self.timeoutMS = UInt32(timeoutMS); self.requestID = requestID
    }

    private static func validate(_ action: String, _ args: [String: Any]) throws {
        func invalid(_ message: String) -> BrowserClientError { .init(code: "invalid_request", message: message) }
        let fields: [String: Set<String>] = [
            "tabs": ["operation", "url"], "navigate": ["operation", "url"], "snapshot": ["max_nodes"],
            "click": ["generation", "ref"], "fill": ["generation", "ref", "value"],
            "press_key": ["generation", "ref", "key"], "scroll": ["generation", "ref", "x", "y"],
            "wait": ["generation", "selector", "state"], "screenshot": [], "evaluate": ["expression"], "cancel": ["request_id"]]
        guard let allowed = fields[action], Set(args.keys).isSubset(of: allowed) else { throw invalid("Unknown browser action or argument.") }
        func string(_ key: String, required: Bool = true, emptyAllowed: Bool = false) throws -> String? {
            guard let value = args[key] else {
                if required { throw invalid("Missing argument: \(key).") }; return nil
            }
            guard let value = value as? String, emptyAllowed || !value.isEmpty else { throw invalid("Invalid string argument: \(key).") }
            return value
        }
        if ["click", "fill", "press_key", "scroll"].contains(action) { _ = try string("generation") }
        if ["click", "fill"].contains(action) { _ = try string("ref") }
        if ["press_key", "scroll"].contains(action) { _ = try string("ref", required: false) }
        if action == "fill" { _ = try string("value", emptyAllowed: true) }
        if action == "evaluate" { _ = try string("expression") }
        if action == "cancel" { _ = try string("request_id") }
        if action == "tabs" || action == "navigate" {
            let operation = try string("operation") ?? ""
            let operations = action == "tabs" ? ["list", "create", "select", "close"] : ["navigate", "back", "forward", "reload"]
            guard operations.contains(operation) else { throw invalid("Invalid operation.") }
            let needsURL = operation == "create" || operation == "navigate"
            if let url = try string("url", required: needsURL) {
                guard let parsed = URLComponents(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), let host = parsed.host, !host.isEmpty else { throw invalid("URL must use HTTP or HTTPS.") }
            }
        }
        if action == "snapshot", let number = args["max_nodes"] {
            guard let number = number as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue, (1...2000).contains(number.intValue) else { throw invalid("max_nodes must be an integer from 1 to 2000.") }
        }
        if action == "press_key" {
            let key = try string("key") ?? ""
            guard key.count == 1 || ["Enter", "Escape", "Tab", "Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "space"].contains(key) else {
                throw BrowserClientError(code: "unsupported", message: "Modifier chords and trusted input are unsupported.")
            }
        }
        if action == "scroll" {
            for key in ["x", "y"] {
                guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid("Scroll deltas must be numbers.") }
            }
        }
        if action == "wait" {
            let state = try string("state") ?? ""
            guard ["visible", "hidden", "attached", "detached", "ready"].contains(state) else { throw invalid("Invalid wait state.") }
            _ = try string("selector", required: state != "ready")
            _ = try string("generation", required: false)
        }
    }

    func message(origin: String, id: Int64) -> ITMClientOriginatedMessage {
        let value = ITMBrowserRequest()
        value.originSessionId = origin
        if let browserSessionID { value.browserSessionId = browserSessionID }
        value.action = action; value.argumentsJson = argumentsJSON; value.timeoutMs = timeoutMS; value.requestId = requestID
        let message = ITMClientOriginatedMessage(); message.id_p = id; message.browserRequest = value
        return message
    }
}

extension APIClient {
    func browserOrigin(_ explicit: String?, environment: [String: String]) throws -> String {
        let resolved: String?
        if let explicit { resolved = APIClient.normalizeSessionId(explicit) }
        else if let address = APIClient.paneAddressFromEnvironment(environment) { resolved = try sessionIdForTmuxPane(address, origin: nil) }
        else { resolved = APIClient.sessionIdFromEnvironment(environment) }
        guard let resolved, !resolved.isEmpty else {
            throw BrowserClientError(code: "origin_not_found", message: "Caller session could not be resolved. Supply --session.")
        }
        guard resolved != "active", resolved != "all" else {
            throw BrowserClientError(code: "invalid_request", message: "A concrete origin session is required.")
        }
        return resolved
    }
}

/// Multiplexes browser requests on one existing local API connection. Cancellation is sent on
/// that same connection, and deadlines retire continuations before any late response arrives.
public final class BrowserClient: @unchecked Sendable {
    public let originSessionID: String
    private let channel: APIChannel
    private let lock = NSLock()
    private let reader = DispatchQueue(label: "it2.browser.responses")
    private var nextID: Int64 = 1000
    private var pending: [Int64: (Result<BrowserClientResult, Error>) -> Void] = [:]
    private var requestIDs: [String: Int64] = [:]
    private var cancelledBeforeSend: Set<String> = []
    private var reading = false
    private var closed = false

    public static func connect(sessionID: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> BrowserClient {
        if let sessionID, ["", "active", "all"].contains(APIClient.normalizeSessionId(sessionID)) {
            throw BrowserClientError(code: "invalid_request", message: "A concrete origin session is required.")
        }
        if sessionID == nil && APIClient.paneAddressFromEnvironment(environment) == nil && APIClient.sessionIdFromEnvironment(environment) == nil {
            throw BrowserClientError(code: "origin_not_found", message: "Caller session could not be resolved. Supply --session.")
        }
        let api = try APIClient.connect()
        do { return try BrowserClient(channel: api.channel, sessionID: sessionID, environment: environment) }
        catch { api.disconnect(); throw error }
    }
    public init(channel: APIChannel, sessionID: String? = nil, environment: [String: String] = [:]) throws {
        self.channel = channel
        (channel as? SocketChannel)?.configureBrowserTimeout(120000)
        originSessionID = try APIClient(channel: channel).browserOrigin(sessionID, environment: environment)
    }
    /// Synchronous CLI entry point using the same dispatcher and deadline as MCP.
    func requestSync(_ request: BrowserClientRequest) throws -> BrowserClientResult {
        let completed = DispatchSemaphore(value: 0)
        var result: Result<BrowserClientResult, Error>?
        submit(request) { result = $0; completed.signal() }
        completed.wait()
        guard let result else { throw BrowserClientError(code: "internal_error", message: "Missing browser result.") }
        do { return try result.get() } catch { throw BrowserClientError.converting(error) }
    }

    public func request(_ request: BrowserClientRequest) async throws -> BrowserClientResult {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                submit(request) { continuation.resume(with: $0) }
            }
        }, onCancel: { self.cancel(requestID: request.requestID) })
    }
    private func submit(_ request: BrowserClientRequest, completion: @escaping (Result<BrowserClientResult, Error>) -> Void) {
        lock.lock()
        if closed || cancelledBeforeSend.remove(request.requestID) != nil {
            lock.unlock(); completion(.failure(BrowserClientError(code: "cancelled", message: "Request cancelled."))); return
        }
        guard requestIDs[request.requestID] == nil else {
            lock.unlock(); completion(.failure(BrowserClientError(code: "invalid_request", message: "Duplicate request ID."))); return
        }
        nextID += 1; let id = nextID
        pending[id] = completion; requestIDs[request.requestID] = id
        do { try channel.send(request.message(origin: originSessionID, id: id)) }
        catch {
            pending.removeValue(forKey: id); requestIDs.removeValue(forKey: request.requestID)
            lock.unlock(); completion(.failure(error)); return
        }
        if !reading { reading = true; reader.async { self.receiveLoop() } }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(request.timeoutMS))) { [weak self] in
            self?.cancel(requestID: request.requestID, code: "timeout", remember: false, expectedTransportID: id)
        }
    }
    public func cancel(requestID: String) { cancel(requestID: requestID, code: "cancelled", remember: true) }
    private func cancel(requestID: String, code: String, remember: Bool, expectedTransportID: Int64? = nil) {
        lock.lock()
        if let expectedTransportID, requestIDs[requestID] != expectedTransportID { lock.unlock(); return }
        guard let id = requestIDs.removeValue(forKey: requestID), let completion = pending.removeValue(forKey: id) else {
            if remember && !closed { cancelledBeforeSend.insert(requestID) }
            lock.unlock(); return
        }
        nextID += 1
        if let request = try? BrowserClientRequest(action: "cancel", argumentsJSON: browserJSONString(["request_id": requestID])) {
            try? channel.send(request.message(origin: originSessionID, id: nextID))
        }
        lock.unlock()
        completion(.failure(BrowserClientError(code: code, message: code == "timeout" ? "Browser request deadline exceeded." : "Request cancelled.")))
    }
    private func receiveLoop() {
        while true {
            do {
                let response = try channel.receiveMessage()
                lock.lock()
                let completion = pending.removeValue(forKey: response.id_p)
                requestIDs = requestIDs.filter { $0.value != response.id_p }
                let stop = pending.isEmpty
                if stop { reading = false }
                lock.unlock()
                completion?(Result { try BrowserClientResult.decode(response) })
                if stop { return }
            } catch { close(error: error); return }
        }
    }
    public func close() { close(error: BrowserClientError(code: "cancelled", message: "Browser connection closed.")) }
    private func close(error: Error) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let completions = Array(pending.values); pending.removeAll(); requestIDs.removeAll(); cancelledBeforeSend.removeAll()
        lock.unlock()
        channel.disconnect()
        completions.forEach { $0(.failure(error)) }
    }
}
