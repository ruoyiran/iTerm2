import Foundation
import MCP
import it2core

/// Establish API access lazily: MCP initialization and tool discovery do not prompt for auth.
private actor BrowserMCPConnection {
    let sessionID: String?
    let environment: [String: String]
    private var connection: Task<BrowserClient, Error>?
    init(sessionID: String?, environment: [String: String]) { self.sessionID = sessionID; self.environment = environment }
    func execute(_ request: BrowserClientRequest) async throws -> BrowserClientResult {
        try Task.checkCancellation()
        if connection == nil {
            let sessionID = sessionID; let environment = environment
            connection = Task.detached { try BrowserClient.connect(sessionID: sessionID, environment: environment) }
        }
        guard let connection else { throw BrowserClientError(code: "internal_error", message: "Missing API connection.") }
        let client: BrowserClient
        do { client = try await connection.value }
        catch { self.connection = nil; throw error }
        try Task.checkCancellation()
        return try await client.request(request)
    }
    func close() async { if let connection, let client = try? await connection.value { client.close() } }
}

@main struct BrowserMCPMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--session" && !["", "active", "all"].contains(arguments[1])) else {
                throw BrowserClientError(code: "invalid_request", message: "Usage: it2-browser-mcp [--session UUID]")
            }
            let connection = BrowserMCPConnection(sessionID: arguments.last, environment: ProcessInfo.processInfo.environment)
            let server = await BrowserMCP.makeServer { request in try await connection.execute(request) }
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
            await connection.close()
        } catch {
            // Stdout contains MCP messages exclusively, including during startup failures.
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            Foundation.exit(1)
        }
    }
}
