import XCTest
import MCP
import it2core
@testable import it2_browser_mcp

final class BrowserMCPTests: XCTestCase {
    func testHandshakeAndTypedTools() async throws {
        let (transport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await BrowserMCP.makeServer { _ in .init(resultJSON: "{}") }
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        let initialized = try await client.connect(transport: transport)
        XCTAssertEqual(initialized.serverInfo.name, "it2-browser")
        XCTAssertNotNil(initialized.capabilities.tools)
        let listed = try await client.listTools()
        XCTAssertEqual(Set(listed.tools.map(\.name)), Set(BrowserClientRequest.actions.map { "browser_" + $0 } + ["browser_capabilities"]))
        let click = try XCTUnwrap(listed.tools.first { $0.name == "browser_click" })
        XCTAssertEqual(click.inputSchema.objectValue?["additionalProperties"], .bool(false))
        XCTAssertTrue(click.inputSchema.objectValue?["required"]?.arrayValue?.contains(.string("generation")) == true)
        await client.disconnect(); await server.stop()
    }

    func testToolUsesFrozenArgumentsAndPNGBlock() async throws {
        let (transport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await BrowserMCP.makeServer { request in
            XCTAssertEqual(request.action, "screenshot")
            XCTAssertEqual(request.browserSessionID, "browser-id")
            XCTAssertEqual(request.timeoutMS, 120000)
            XCTAssertEqual(request.argumentsJSON, "{}")
            return .init(resultJSON: "{\"format\":\"png\"}", pngData: Data([137, 80, 78, 71]))
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: transport)
        let result = try await client.callTool(name: "browser_screenshot", arguments: ["browser_session_id": "browser-id", "timeout_ms": 120000])
        XCTAssertEqual(result.content.count, 2)
        guard case .image(let data, let mime, _, _) = result.content.last else { return XCTFail("Expected PNG image block") }
        XCTAssertEqual(data, "iVBORw=="); XCTAssertEqual(mime, "image/png")
        await client.disconnect(); await server.stop()
    }

    func testInvalidAndStableErrors() async throws {
        let server = await BrowserMCP.makeServer { _ in throw BrowserClientError(code: "stale_reference", message: "Localized message") }
        let (transport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: transport)
        let result = try await client.callTool(name: "browser_snapshot", arguments: ["max_nodes": 0])
        XCTAssertEqual(result.isError, true)
        guard case .text(let text, _, _) = result.content.first else { return XCTFail("Expected error text") }
        XCTAssertTrue(text.contains("invalid_request"))
        let stale = try await client.callTool(name: "browser_snapshot")
        guard case .text(let detail, _, _) = stale.content.first else { return XCTFail("Expected error text") }
        XCTAssertTrue(detail.contains("stale_reference"))
        await client.disconnect(); await server.stop()
    }

    func testToolDeadlineIncludesAppConnection() async throws {
        let server = await BrowserMCP.makeServer { _ in
            try await Task.sleep(for: .seconds(3600))
            return .init(resultJSON: "{}")
        }
        let (transport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: transport)
        let calling = Task { try await client.callTool(name: "browser_wait", arguments: ["state": "ready", "timeout_ms": 1]) }
        let result = try await calling.value
        XCTAssertEqual(result.isError, true)
        guard case .text(let text, _, _) = result.content.first else { return XCTFail("Expected timeout error") }
        XCTAssertTrue(text.contains("timeout"))
        await client.disconnect(); await server.stop()
    }

    func testSDKCancellationReachesAppOperation() async throws {
        let started = expectation(description: "operation began")
        let cancelled = expectation(description: "operation cancelled")
        let server = await BrowserMCP.makeServer { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(3600)) }
            catch { cancelled.fulfill(); throw error }
            return .init(resultJSON: "{}")
        }
        let (transport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: transport)
        let context = try await client.send(CallTool.request(.init(name: "browser_wait", arguments: ["state": "ready"])))
        await fulfillment(of: [started], timeout: 5)
        try await client.cancelRequest(context.requestID)
        await fulfillment(of: [cancelled], timeout: 5)
        await client.disconnect(); await server.stop()
    }
}
