import Foundation
import MCP
import it2core

/// MCP lives only in this executable; embedded it2core has no SDK dependency.
enum BrowserMCP {
    static let instructions = """
        Tools control browsers in the caller’s primary iTerm2 tab only. Take a snapshot before
        using DOM references; generation changes expire older references. Navigation starts a
        WebKit navigation; use browser_wait with state ready separately. DOM input is untrusted.
        Evaluate accepts an async function body in an isolated world with DOM access but no page
        JavaScript globals. Screenshots are PNGs of the current viewport. Cross-origin frames,
        native pickers, trusted input, downloads, clipboard, drag/drop and dialogs are unsupported.
        Local use only. Python API access and automation permission must be enabled by the user.
        """

    static func makeServer(execute: @escaping @Sendable (BrowserClientRequest) async throws -> BrowserClientResult) async -> Server {
        let server = Server(name: "it2-browser", version: "1.0.0", instructions: instructions, capabilities: .init(tools: .init(listChanged: false)))
        let tools = makeTools()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { parameters in
            do {
                try Task.checkCancellation()
                let request = try parse(parameters)
                let result: BrowserClientResult
                if let request { result = try await BrowserMCPDeadline.run(request.timeoutMS) { try await execute(request) } }
                else { result = .init(resultJSON: "{\"scope\":\"caller_primary_tab\",\"trusted_input\":false,\"evaluate_world\":\"isolated\",\"remote_ssh\":false}", capabilities: BrowserClientRequest.capabilities) }
                try Task.checkCancellation()
                let json = try result.json(includePNG: false)
                var content: [Tool.Content] = [.text(text: json, annotations: nil, _meta: nil)]
                if !result.pngData.isEmpty { content.append(.image(data: result.pngData.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)) }
                let structured = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
                return .init(content: content, structuredContent: Optional.some(structured), isError: false)
            } catch {
                // SDK cancellation deliberately omits a response; app cancellation has already
                // been sent by BrowserClient's cancellation handler on the same API channel.
                if Task.isCancelled { throw CancellationError() }
                let json = (error as? BrowserClientError ?? BrowserClientError(code: "internal_error", message: String(describing: error))).json
                return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: true)
            }
        }
        return server
    }

    private static func parse(_ parameters: CallTool.Parameters) throws -> BrowserClientRequest? {
        let invalid = BrowserClientError(code: "invalid_request", message: "Invalid browser tool arguments.")
        guard parameters.name.hasPrefix("browser_") else { throw invalid }
        let action = String(parameters.name.dropFirst("browser_".count))
        var arguments = parameters.arguments ?? [:]
        if action == "capabilities" { guard arguments.isEmpty else { throw invalid }; return nil }
        let browserSession: String?
        if let value = arguments.removeValue(forKey: "browser_session_id") {
            guard let id = value.stringValue, !id.isEmpty else { throw invalid }; browserSession = id
        } else { browserSession = nil }
        let timeout: Int
        if let value = arguments.removeValue(forKey: "timeout_ms") { guard let ms = value.intValue else { throw invalid }; timeout = ms }
        else { timeout = 30000 }
        let requestID: String
        if let value = arguments.removeValue(forKey: "client_request_id") { guard let id = value.stringValue, !id.isEmpty else { throw invalid }; requestID = id }
        else { requestID = UUID().uuidString }
        let json = String(decoding: try JSONEncoder().encode(Value.object(arguments)), as: UTF8.self)
        return try BrowserClientRequest(action: action, argumentsJSON: json, browserSessionID: browserSession, timeoutMS: timeout, requestID: requestID)
    }

    private static func makeTools() -> [Tool] {
        func type(_ name: String) -> Value { .object(["type": .string(name)]) }
        func choice(_ values: [String]) -> Value { .object(["type": "string", "enum": .array(values.map(Value.string))]) }
        let text = type("string")
        let fields: [String: [String: Value]] = [
            "tabs": ["operation": choice(["list", "create", "select", "close"]), "url": text],
            "navigate": ["operation": choice(["navigate", "back", "forward", "reload"]), "url": text],
            "snapshot": ["max_nodes": .object(["type": "integer", "minimum": 1, "maximum": 2000])],
            "click": ["generation": text, "ref": text],
            "fill": ["generation": text, "ref": text, "value": text],
            "press_key": ["generation": text, "ref": text, "key": text],
            "scroll": ["generation": text, "ref": text, "x": type("number"), "y": type("number")],
            "wait": ["generation": text, "selector": text, "state": choice(["visible", "hidden", "attached", "detached", "ready"])],
            "screenshot": [:], "evaluate": ["expression": text], "cancel": ["request_id": text]]
        let required: [String: [String]] = ["tabs": ["operation"], "navigate": ["operation"], "click": ["generation", "ref"], "fill": ["generation", "ref", "value"], "press_key": ["generation", "key"], "scroll": ["generation", "x", "y"], "wait": ["state"], "evaluate": ["expression"], "cancel": ["request_id"]]
        let descriptions: [String: String] = [
            "tabs": "List, create, select or close browser tabs owned by the caller’s primary tab. Create requires an HTTP(S) URL; select/close require browser_session_id.",
            "navigate": "Start navigation, back, forward or reload. navigate requires an HTTP(S) URL. Wait for ready separately.",
            "snapshot": "Get accessible DOM nodes and generation-scoped references. Same-origin frames supported; cross-origin frames skipped.",
            "click": "Dispatch an untrusted DOM click at a snapshot reference.",
            "fill": "Set an editable element’s value and dispatch untrusted input/change events. File inputs unsupported.",
            "press_key": "Dispatch an untrusted DOM key. Named keys or single characters; modifier chords unsupported.",
            "scroll": "Scroll a reference or the document by CSS pixel deltas.",
            "wait": "Wait for a selector state, or ready without a selector. Supports cancellation and timeout_ms (1–120000).",
            "screenshot": "Capture the current viewport as a PNG image block.",
            "evaluate": "Run an async function body in an isolated automation world. Return a JSON value; page JS globals unavailable.",
            "cancel": "Cancel client_request_id from an outstanding tool on this helper’s API connection."]
        var tools = BrowserClientRequest.actions.map { action -> Tool in
            var properties = fields[action] ?? [:]
            properties["browser_session_id"] = text
            properties["timeout_ms"] = .object(["type": "integer", "minimum": 1, "maximum": 120000, "default": 30000])
            properties["client_request_id"] = text
            let schema: Value = .object(["type": "object", "properties": .object(properties), "required": .array((required[action] ?? []).map(Value.string)), "additionalProperties": false])
            return Tool(name: "browser_" + action, description: descriptions[action], inputSchema: schema)
        }
        tools.append(Tool(name: "browser_capabilities", description: instructions, inputSchema: .object(["type": "object", "properties": .object([:]), "additionalProperties": false])))
        return tools
    }
}

/// A tool deadline also covers authentication/origin lookup before the app request is sent.
/// The cancelled worker checks cancellation after connecting, preventing a later DOM action.
private final class BrowserMCPDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<BrowserClientResult, Error>?
    private var worker: Task<Void, Never>?

    static func run(_ timeoutMS: UInt32, operation: @escaping @Sendable () async throws -> BrowserClientResult) async throws -> BrowserClientResult {
        let state = BrowserMCPDeadline()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.start(continuation, timeoutMS: timeoutMS, operation: operation)
            }
        }, onCancel: { state.finish(.failure(CancellationError())) })
    }
    private func start(_ continuation: CheckedContinuation<BrowserClientResult, Error>, timeoutMS: UInt32, operation: @escaping @Sendable () async throws -> BrowserClientResult) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        let task = Task {
            do { try Task.checkCancellation(); self.finish(.success(try await operation())) }
            catch { self.finish(.failure(error)) }
        }
        lock.lock()
        if finished { lock.unlock(); task.cancel() }
        else { worker = task; lock.unlock() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMS))) { [weak self] in
            self?.finish(.failure(BrowserClientError(code: "timeout", message: "Browser tool deadline exceeded.")))
        }
    }
    private func finish(_ result: Result<BrowserClientResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation; self.continuation = nil
        let worker = worker; self.worker = nil
        lock.unlock()
        worker?.cancel()
        continuation?.resume(with: result)
    }
}
