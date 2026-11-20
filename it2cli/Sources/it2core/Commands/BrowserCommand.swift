import ArgumentParser
import Foundation

struct Browser: ParsableCommand, IT2Runnable {
    static let configuration = CommandConfiguration(commandName: "browser", abstract: "Control the caller’s tab-scoped browser; JSON output by default.", discussion: """
        Actions: tabs, navigate, snapshot, click, fill, press-key, scroll, wait, screenshot,
        evaluate, cancel, capabilities, mcp. Origin comes from TERM_SESSION_ID or the current
        tmux pane, or --session. Browser targets stay within that origin’s primary tab.
        DOM input is untrusted; evaluate runs in an isolated world. Use mcp for local agents.

        Open a browser: it2 browser tabs --operation create --url https://example.com
        Read the page: it2 browser snapshot --browser-session <browser-session-id>
        Register with Codex: codex mcp add iterm-browser -- it2 browser mcp
        Register with Claude Code: claude mcp add iterm-browser -- it2 browser mcp

        Launch the agent in the owning iTerm2 terminal so the MCP helper inherits
        TERM_SESSION_ID. For a fixed origin, append --session <session-id> to mcp.
        Enable iTerm2’s Python API and approve the native connection prompt; page
        access asks for permission once per site. No agent configuration is changed
        by it2 itself. Use the full path to it2 if it is not on the agent’s PATH.
        """)
    @Argument var action: String
    @Option(name: .long) var session: String?
    @Option(name: .long) var browserSession: String?
    @Option(name: .long) var argumentsJSON: String?
    @Option(name: .long) var timeoutMS: Int = 30000
    @Option(name: .long) var requestID: String?
    @Option(name: .long) var operation: String?
    @Option(name: .long) var url: String?
    @Option(name: .long) var generation: String?
    @Option(name: .long) var ref: String?
    @Option(name: .long) var value: String?
    @Option(name: .long) var key: String?
    @Option(name: .long) var x: Double?
    @Option(name: .long) var y: Double?
    @Option(name: .long) var maxNodes: Int?
    @Option(name: .long) var selector: String?
    @Option(name: .long) var state: String?
    @Option(name: .long) var expression: String?
    @Option(name: .long) var cancelRequestID: String?
    @Flag(name: .long) var json = false

    func run(_ ctx: IT2Context) throws {
        guard !ctx.isRemote else { throw BrowserClientError(code: "unsupported", message: "Browser commands are unavailable over SSH integration. Run locally on your Mac.") }
        let wireAction = action.replacingOccurrences(of: "-", with: "_")
        if wireAction == "mcp" { try launchMCP(ctx); return }
        if wireAction == "capabilities" {
            ctx.out(try browserJSONString(["ok": true, "capabilities": BrowserClientRequest.capabilities, "scope": "caller_primary_tab", "trusted_input": false, "evaluate_world": "isolated", "remote_ssh": false])); return
        }
        var args: [String: Any] = [:]
        let fields: [(String, Any?)] = [("operation", operation), ("url", url), ("generation", generation), ("ref", ref), ("value", value), ("key", key), ("x", x), ("y", y), ("max_nodes", maxNodes), ("selector", selector), ("state", state), ("expression", expression), ("request_id", cancelRequestID)]
        for (name, value) in fields { if let value { args[name] = value } }
        guard argumentsJSON == nil || args.isEmpty else { throw BrowserClientError(code: "invalid_request", message: "Use either --arguments-json or individual argument options.") }
        if argumentsJSON == nil {
            if wireAction == "tabs" && operation == nil { args["operation"] = "list" }
            if wireAction == "navigate" && operation == nil { args["operation"] = "navigate" }
            if wireAction == "wait" && state == nil { args["state"] = "ready" }
        }
        let request = try BrowserClientRequest(action: wireAction, argumentsJSON: argumentsJSON ?? browserJSONString(args), browserSessionID: browserSession, timeoutMS: timeoutMS, requestID: requestID ?? UUID().uuidString)
        // Reject special selectors before connecting (and therefore before any auth prompt).
        if let session, ["", "active", "all"].contains(APIClient.normalizeSessionId(session)) {
            throw BrowserClientError(code: "invalid_request", message: "A concrete origin session is required.")
        }
        if session == nil && APIClient.paneAddressFromEnvironment(ctx.environment) == nil && APIClient.sessionIdFromEnvironment(ctx.environment) == nil {
            throw BrowserClientError(code: "origin_not_found", message: "Caller session could not be resolved. Supply --session.")
        }
        let client = try ctx.makeClient(); defer { client.disconnect() }
        (client.channel as? SocketChannel)?.configureBrowserTimeout(request.timeoutMS)
        let origin = try client.browserOrigin(session, environment: ctx.environment)
        let browser = try BrowserClient(channel: client.channel, sessionID: origin)
        defer { browser.close() }
        let result = try browser.requestSync(request)
        ctx.out(try result.json())
    }
    private func launchMCP(_ ctx: IT2Context) throws {
        guard ctx.installsSignalHandlers else { throw BrowserClientError(code: "unsupported", message: "The MCP helper requires standalone local stdio.") }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let helper = executable.deletingLastPathComponent().appendingPathComponent("it2-browser-mcp")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw BrowserClientError(code: "unsupported", message: "Bundled it2-browser-mcp helper is missing. Rebuild or reinstall it2.") }
        let process = Process(); process.executableURL = helper
        process.arguments = session.map { ["--session", $0] } ?? []
        process.environment = ctx.environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { try ctx.exit(process.terminationStatus) }
    }
}
