import XCTest
import ProtobufRuntime
@testable import it2core

final class BrowserClientTests: XCTestCase {
    func testMultiplexesOutOfOrderResponses() async throws {
        let channel = BrowserTestChannel()
        let client = try BrowserClient(channel: channel, sessionID: "origin")
        defer { client.close() }
        let first = try BrowserClientRequest(action: "snapshot", requestID: "first")
        let second = try BrowserClientRequest(action: "screenshot", requestID: "second")
        let bothSent = expectation(description: "two requests sent")
        bothSent.expectedFulfillmentCount = 2
        channel.onSend = { _ in bothSent.fulfill() }
        async let resultA = client.request(first)
        async let resultB = client.request(second)
        await fulfillment(of: [bothSent], timeout: 5)
        let requests = channel.sentRequests
        for request in requests.reversed() { channel.reply(to: request, json: "{\"id\":\"\(request.browserRequest.requestId ?? "")\"}") }
        let a = try await resultA; let b = try await resultB
        XCTAssertTrue(a.resultJSON.contains("first")); XCTAssertTrue(b.resultJSON.contains("second"))
    }

    func testCancellationUsesSameChannelAndCompletesPromptly() async throws {
        let channel = BrowserTestChannel()
        let started = expectation(description: "wait sent")
        let cancellation = expectation(description: "cancel sent on same channel")
        channel.onSend = { request in
            if request.browserRequest.action == "wait" { started.fulfill() }
            if request.browserRequest.action == "cancel" { cancellation.fulfill() }
        }
        let client = try BrowserClient(channel: channel, sessionID: "origin")
        defer { client.close() }
        let request = try BrowserClientRequest(action: "wait", argumentsJSON: "{\"state\":\"ready\"}", requestID: "waiting")
        let task = Task { try await client.request(request) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [cancellation], timeout: 5)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let error as BrowserClientError { XCTAssertEqual(error.code, "cancelled") }
        let cancel = try XCTUnwrap(channel.sentRequests.last?.browserRequest)
        XCTAssertEqual(cancel.argumentsJson, "{\"request_id\":\"waiting\"}")
        XCTAssertEqual(cancel.originSessionId, "origin")
    }

    func testDeadlineReturnsTimeoutAndCancelsWait() async throws {
        let channel = BrowserTestChannel()
        let client = try BrowserClient(channel: channel, sessionID: "origin")
        defer { client.close() }
        let request = try BrowserClientRequest(action: "wait", argumentsJSON: "{\"state\":\"ready\"}", timeoutMS: 1, requestID: "waiting")
        do { _ = try await client.request(request); XCTFail("Expected timeout") }
        catch let error as BrowserClientError { XCTAssertEqual(error.code, "timeout") }
        XCTAssertEqual(channel.sentRequests.last?.browserRequest.action, "cancel")
    }

    func testResolvedTmuxOriginIgnoresInheritedTermSession() throws {
        let channel = FakeChannel()
        let lookup = ITMServerOriginatedMessage(); lookup.id_p = 1
        let value = ITMInvokeFunctionResponse(); let success = ITMInvokeFunctionResponse_Success()
        success.jsonResult = "\"correct-pane\""; value.success = success; lookup.invokeFunctionResponse = value
        channel.responses = [lookup]
        let client = try BrowserClient(channel: channel, environment: ["TMUX": "/tmp/tmux,123,0", "TMUX_PANE": "%2", "TERM_SESSION_ID": "w0t0p0:wrong"])
        XCTAssertEqual(client.originSessionID, "correct-pane")
        XCTAssertEqual(channel.sent.count, 1)
        XCTAssertEqual(channel.sent.first?.submessageOneOfCase, .invokeFunctionRequest)
        client.close()
    }
}

private final class BrowserTestChannel: APIChannel {
    private let condition = NSCondition()
    private var requests: [ITMClientOriginatedMessage] = []
    private var replies: [ITMServerOriginatedMessage] = []
    private var closed = false
    var onSend: ((ITMClientOriginatedMessage) -> Void)?
    var sentRequests: [ITMClientOriginatedMessage] { condition.lock(); defer { condition.unlock() }; return requests }
    func send(_ request: ITMClientOriginatedMessage) throws {
        condition.lock(); requests.append(request); condition.unlock()
        onSend?(request)
    }
    func receiveMessage() throws -> ITMServerOriginatedMessage {
        condition.lock(); defer { condition.unlock() }
        while replies.isEmpty && !closed { condition.wait() }
        guard !closed else { throw BrowserClientError(code: "cancelled", message: "Closed") }
        return replies.removeFirst()
    }
    func reply(to request: ITMClientOriginatedMessage, json: String) {
        let response = ITMServerOriginatedMessage(); response.id_p = request.id_p
        let value = ITMBrowserResponse(); value.resultJson = json; response.browserResponse = value
        condition.lock(); replies.append(response); condition.signal(); condition.unlock()
    }
    func disconnect() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
}
