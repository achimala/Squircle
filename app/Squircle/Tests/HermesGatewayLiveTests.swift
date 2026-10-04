import XCTest
@testable import Squircle

/// Opt-in integration against the user's configured, unmodified Hermes server.
/// Uses a dedicated session and clears its heartbeat even when an assertion fails.
@MainActor
final class HermesGatewayLiveTests: XCTestCase {
    func testNativeToolsHeartbeatAndReconnect() async throws {
        guard ProcessInfo.processInfo.environment["SQUIRCLE_LIVE_HERMES"] == "1" else { throw XCTSkip("Live Hermes verification is opt-in") }
        let config = try AppConfiguration.load()
        let gateway = HermesGateway(configuration: config)
        var events: [JSONValue] = []
        gateway.onEvent = { events.append($0) }
        let snapshot = try await gateway.call("session.create", ["source": .string("desktop"), "title": .string("Squircle native protocol integration test"), "close_on_disconnect": .bool(false)])
        let runtime = try XCTUnwrap(snapshot["session_id"].string)
        let stored = try XCTUnwrap(snapshot["stored_session_id"].string)
        let scope: [String: JSONValue] = ["session_id": .string(runtime)]
        _ = try await gateway.call("prompt.submit", scope.merging(["text": .string("Run terminal command printf SQUIRCLE_NATIVE_TOOL_OK then reply exactly SQUIRCLE_NATIVE_TOOL_OK. Do not change any files.")]) { _, new in new })
        try await waitUntil(120) { events.contains { $0["type"].string == "message.complete" } }
        XCTAssertTrue(events.contains { $0["type"].string == "tool.start" && $0["payload"]["args"] != .null })
        XCTAssertTrue(events.contains { $0["type"].string == "tool.complete" && $0["payload"]["result"] != .null })
        // Hermes v0.21.5 slash-worker watchdog can consume the first tick.
        // Verify native delivery through the second interval; do not implement a client scheduler.
        let transcript = try await gateway.transcript(stored)
        let tool = try XCTUnwrap(HermesConversation.project(transcript).first { $0.role == "tool" })
        XCTAssertTrue(tool.detail.contains("SQUIRCLE_NATIVE_TOOL_OK"))
        XCTAssertTrue(tool.detail.contains("Output"))
        let initialCount = events.filter { $0["type"].string == "message.complete" }.count
        _ = try await gateway.call("slash.exec", scope.merging(["command": .string("/heartbeat every 60s Reply exactly SQUIRCLE_NATIVE_HEARTBEAT_OK. Do not use tools.")]) { _, new in new })
        do {
            try await waitUntil(180) { events.filter { $0["type"].string == "message.complete" }.count > initialCount }
            XCTAssertTrue(events.contains { $0["type"].string == "message.complete" && $0["payload"]["text"].text.contains("SQUIRCLE_NATIVE_HEARTBEAT_OK") })
        } catch {
            _ = try? await gateway.call("slash.exec", scope.merging(["command": .string("/heartbeat clear")]) { _, new in new })
            throw error
        }
        _ = try await gateway.call("slash.exec", scope.merging(["command": .string("/heartbeat clear")]) { _, new in new })
        let other = HermesGateway(configuration: config)
        let resumed = try await other.call("session.resume", ["session_id": .string(stored), "source": .string("desktop")])
        XCTAssertEqual(resumed["session_id"].string, runtime, "Both clients must attach to the same live Hermes session")
        XCTAssertTrue(HermesConversation.project(resumed["messages"].array).contains { $0.content.contains("SQUIRCLE_NATIVE_HEARTBEAT_OK") })
    }

    func testNativeClarificationAndStoredToolBody() async throws {
        guard ProcessInfo.processInfo.environment["SQUIRCLE_LIVE_HERMES"] == "1" else { throw XCTSkip("Live Hermes verification is opt-in") }
        let gateway = HermesGateway(configuration: try AppConfiguration.load())
        var completed = false
        var answered = false
        gateway.onEvent = { if $0["type"].string == "message.complete" { completed = true } }
        gateway.onRequest = { frame in
            guard frame["method"].string == "clarify", let id = frame["id"].string else { return }
            let answers = Dictionary(uniqueKeysWithValues: frame["params"]["questions"].array.compactMap { q -> (String, JSONValue)? in
                guard let qid = q["qid"].string else { return nil }
                return (qid, .string("SQUIRCLE_ANSWER_OK"))
            })
            Task {
                _ = try await gateway.call("request.answer", ["id": .string(id), "result": .object(["answers": .object(answers)])])
                answered = true
            }
        }
        let snapshot = try await gateway.call("session.create", ["source": .string("desktop"), "title": .string("Squircle request verification")])
        let runtime = try XCTUnwrap(snapshot["session_id"].string)
        let stored = try XCTUnwrap(snapshot["stored_session_id"].string)
        _ = try await gateway.call("prompt.submit", ["session_id": .string(runtime), "text": .string("Use the clarify tool to ask which marker to print, offering SQUIRCLE_ANSWER_OK or SECOND. After the answer, run terminal command printf SQUIRCLE_ANSWER_OK and reply exactly SQUIRCLE_ANSWER_OK. Do not change files.")])
        try await waitUntil(120) { completed }
        XCTAssertTrue(answered, "A real native clarification must be answered through request.answer")
        let rows = try await gateway.transcript(stored)
        let tool = try XCTUnwrap(HermesConversation.project(rows).first { $0.activity?.hasPrefix("Run printf") == true })
        XCTAssertTrue(tool.detail.contains("Output"))
        XCTAssertTrue(tool.detail.contains("SQUIRCLE_ANSWER_OK"))
    }

    private func waitUntil(_ seconds: Double, condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while !condition(), Date() < until { try await Task.sleep(for: .milliseconds(200)) }
        if !condition() { throw NSError(domain: "Hermes live test timed out", code: 1) }
    }
}
