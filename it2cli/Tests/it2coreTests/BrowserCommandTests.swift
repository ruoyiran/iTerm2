import XCTest
import ProtobufRuntime
@testable import it2core

final class BrowserCommandTests: XCTestCase {
    private func reply(_ json: String = "{}", code: String = "", png: Data? = nil, id: Int64 = 1001) -> ITMServerOriginatedMessage {
        let value = ITMBrowserResponse()
        value.resultJson = json
        value.errorCode = code
        value.errorMessage = "Localized detail"
        if let png { value.pngData = png }
        let message = ITMServerOriginatedMessage()
        message.id_p = id
        message.browserResponse = value
        return message
    }

    func testCallerSessionAndFrozenRequest() throws {
        let channel = FakeChannel()
        channel.responses = [reply("{\"tabs\":[]}")]
        let output = OutputCapture()
        let status = runToExitCode(["browser", "tabs", "--operation", "list"], output.context(channel: channel, environment: ["TERM_SESSION_ID": "w0t1p0:origin"]))
        XCTAssertEqual(status, 0)
        XCTAssertEqual(channel.sent.count, 1)
        let request = try XCTUnwrap(channel.sent.first?.browserRequest)
        XCTAssertEqual(request.originSessionId, "origin")
        XCTAssertEqual(request.action, "tabs")
        XCTAssertEqual(request.argumentsJson, "{\"operation\":\"list\"}")
        XCTAssertFalse(request.requestId.isEmpty)
        XCTAssertEqual(request.timeoutMs, 30000)
        let result = try json(output.out)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertTrue(output.err.isEmpty)
    }

    func testMissingOriginNeverQueriesFocus() throws {
        let channel = FakeChannel()
        let output = OutputCapture()
        XCTAssertNotEqual(runToExitCode(["browser", "snapshot"], output.context(channel: channel)), 0)
        XCTAssertTrue(channel.sent.isEmpty)
        XCTAssertEqual(try errorCode(output.out), "origin_not_found")
    }

    func testTmuxNeverUsesInheritedTermSession() throws {
        let channel = FakeChannel()
        let output = OutputCapture()
        let status = runToExitCode(["browser", "snapshot"], output.context(channel: channel, environment: ["TERM_SESSION_ID": "w0t1p0:wrong", "TMUX": "malformed", "TMUX_PANE": "%1"]))
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(channel.sent.isEmpty)
        XCTAssertEqual(try errorCode(output.out), "origin_not_found")
    }

    func testExplicitSessionAndScreenshotBytes() throws {
        let channel = FakeChannel()
        channel.responses = [reply("{\"format\":\"png\"}", png: Data([137, 80, 78, 71]))]
        let output = OutputCapture()
        XCTAssertEqual(runToExitCode(["browser", "screenshot", "--session", "w1t2p3:explicit", "--browser-session", "target"], output.context(channel: channel)), 0)
        XCTAssertEqual(channel.sent.first?.browserRequest.originSessionId, "explicit")
        XCTAssertEqual(channel.sent.first?.browserRequest.browserSessionId, "target")
        XCTAssertEqual(try json(output.out)["png_data"] as? String, "iVBORw==")
    }

    func testStableServerError() throws {
        let channel = FakeChannel()
        channel.responses = [reply(code: "stale_reference")]
        let output = OutputCapture()
        XCTAssertNotEqual(runToExitCode(["browser", "click", "--session", "origin", "--generation", "g", "--ref", "e1"], output.context(channel: channel)), 0)
        XCTAssertEqual(try errorCode(output.out), "stale_reference")
    }

    func testAllBrowserActionsRejectRemoteBeforeTransport() throws {
        for action in ["tabs", "snapshot", "navigate", "screenshot", "evaluate", "cancel", "mcp", "capabilities"] {
            let channel = FakeChannel()
            let output = OutputCapture()
            XCTAssertNotEqual(runToExitCode(["browser", action, "--session", "origin"], output.context(channel: channel, isRemote: true)), 0)
            XCTAssertEqual(try errorCode(output.out + output.err), "unsupported", action)
            XCTAssertTrue(channel.sent.isEmpty)
        }
    }

    func testMCPLauncherFailuresKeepProtocolStdoutClean() throws {
        let channel = FakeChannel()
        let output = OutputCapture()
        XCTAssertNotEqual(runToExitCode(["browser", "mcp"], output.context(channel: channel)), 0)
        XCTAssertTrue(output.out.isEmpty)
        XCTAssertEqual(try errorCode(output.err), "unsupported")
    }

    func testParsingFailuresAreJSON() throws {
        for args in [["browser", "bogus"], ["browser", "tabs", "--operation", "close", "--session", "origin"], ["browser", "snapshot", "--timeout-ms", "0"], ["browser", "snapshot", "--arguments-json", "[]"], ["browser", "tabs", "--session", "active"], ["browser", "navigate", "--url", "file:///tmp/private", "--session", "origin"]] {
            let output = OutputCapture()
            let channel = FakeChannel()
            XCTAssertNotEqual(runToExitCode(args, output.context(channel: channel)), 0)
            XCTAssertEqual(try errorCode(output.out), "invalid_request")
            XCTAssertTrue(channel.sent.isEmpty)
            XCTAssertTrue(output.err.isEmpty)
        }
    }

    private func json(_ lines: [String]) throws -> [String: Any] {
        let line = try XCTUnwrap(lines.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    private func errorCode(_ lines: [String]) throws -> String? {
        try (json(lines)["error"] as? [String: Any])?["code"] as? String
    }
}
