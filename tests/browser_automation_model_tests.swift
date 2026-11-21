import Foundation

func expectRejected(_ action: String, _ json: String, origin: String = "origin", timeout: UInt32 = 30000) {
    do {
        _ = try iTermBrowserAutomationRequest(originSessionID: origin, browserSessionID: "browser", action: action, argumentsJSON: json, timeoutMS: timeout, requestID: "id")
        preconditionFailure("Expected invalid request: \(action) \(json)")
    } catch {}
}
expectRejected("snapshot", "{}", origin: "active")
expectRejected("snapshot", "[]")
expectRejected("snapshot", "{\"max_nodes\":true}")
expectRejected("snapshot", "{\"max_nodes\":2001}")
expectRejected("click", "{\"ref\":\"e1\"}")
expectRejected("navigate", "{\"operation\":\"navigate\",\"url\":\"file:///etc/passwd\"}")
expectRejected("navigate", "{\"operation\":\"navigate\",\"url\":\"https://user:secret@example.com\"}")
expectRejected("evaluate", "{\"expression\":\"return 1\",\"world\":\"page\"}")
expectRejected("snapshot", "{}", timeout: 0)
let request = try iTermBrowserAutomationRequest(originSessionID: "origin", browserSessionID: "browser", action: "fill", argumentsJSON: "{\"generation\":\"g\",\"ref\":\"e1\",\"value\":\"x\"}", timeoutMS: 10, requestID: "id")
precondition(request.arguments["value"] as? String == "x")
precondition(!request.expired(at: request.deadline - 1))
precondition(request.expired(at: request.deadline))
let cancel = try iTermBrowserAutomationRequest(originSessionID: "origin", browserSessionID: "", action: "cancel", argumentsJSON: "{\"request_id\":\"request\"}", timeoutMS: 1000, requestID: "cancel")
precondition(cancel.action == .cancel)
print("PASS: request scoping, strict types/schema, URLs, refs, timeout/deadline and cancellation parsing")
