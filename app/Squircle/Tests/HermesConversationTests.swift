import XCTest
@testable import Squircle

final class HermesConversationTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    private func event(_ type: String, _ payload: String, seq: Int) throws -> JSONValue {
        try json("{\"type\":\"\(type)\",\"session_id\":\"live\",\"seq\":\(seq),\"payload\":\(payload)}")
    }

    func testNativeToolLifecyclePreservesArgumentsResultsAndFailure() throws {
        var c = HermesConversation()
        c.consume(try event("tool.start", #"{"tool_id":"a","name":"terminal","args":{"command":"swift test"},"context":"swift test"}"#, seq: 1))
        c.consume(try event("tool.complete", #"{"tool_id":"a","name":"terminal","args":{"command":"swift test"},"result":{"output":"test failed","exit_code":1},"duration_s":2.5}"#, seq: 2))
        XCTAssertEqual(c.messages.count, 1)
        XCTAssertTrue(c.messages[0].detail.contains("swift test"))
        XCTAssertTrue(c.messages[0].detail.contains("test failed"))
        XCTAssertTrue(c.messages[0].failed)
        XCTAssertFalse(c.messages[0].isStreaming)
    }

    func testReplayDoesNotDuplicateTokensOrToolRows() throws {
        var c = HermesConversation()
        let e = try event("message.delta", #"{"text":"Hello"}"#, seq: 4)
        c.consume(e); c.consume(e)
        XCTAssertEqual(c.messages.map(\.content), ["Hello"])
        c.consume(try event("message.interim", #"{"text":"Hello","already_streamed":true}"#, seq: 5))
        c.consume(try event("message.delta", #"{"text":"Done"}"#, seq: 6))
        c.consume(try event("message.complete", #"{"text":"Done","status":"complete"}"#, seq: 7))
        XCTAssertEqual(c.messages.map(\.content), ["Hello", "Done"])
        XCTAssertFalse(c.running)
    }

    func testHydrationRestoresRealToolHistoryAndOutstandingClarification() throws {
        var c = HermesConversation()
        c.hydrate(try json(#"{"messages":[{"row_id":1,"role":"user","text":"Fix it"},{"row_id":2,"role":"tool","name":"search_files","args":{"pattern":"TODO"},"content":"Found 4 matches"},{"role":"assistant","text":"private context","display_kind":"hidden"}],"running":true,"open_requests":[{"id":"srq-x","method":"clarify","params":{"session_id":"live","questions":[{"qid":"q1","question":"Which file?","choices":["A","B"]}]}}]}"#))
        XCTAssertEqual(c.messages.count, 2)
        XCTAssertTrue(c.messages[1].detail.contains("Found 4 matches"))
        XCTAssertEqual(c.questions.first?.id, "srq-x")
        XCTAssertTrue(c.running)
        c.consume(try event("request.cancel", #"{"id":"srq-x","reason":"resolved"}"#, seq: 1))
        XCTAssertTrue(c.questions.isEmpty)
    }

    func testSubagentProgressUsesHermesIdentityAndPreservesChildConversation() throws {
        var c = HermesConversation()
        c.consume(try event("subagent.start", #"{"subagent_id":"a","goal":"Fix navigation","child_session_id":"child","task_index":0}"#, seq: 1))
        c.consume(try event("subagent.tool", #"{"subagent_id":"a","tool_name":"read_file","tool_preview":"App.swift","task_index":0}"#, seq: 2))
        c.consume(try event("subagent.complete", #"{"subagent_id":"a","status":"completed","summary":"Fixed","task_index":0}"#, seq: 3))
        XCTAssertEqual(c.messages.count, 1)
        XCTAssertEqual(c.messages[0].childSessionID, "child")
        XCTAssertTrue(c.messages[0].detail.contains("App.swift"))
        XCTAssertEqual(c.messages[0].content, "Fixed")
    }

    func testBackgroundTurnStartsAfterOriginalRunAndUnknownMessagesRemainVisible() throws {
        var c = HermesConversation()
        c.consume(try event("message.complete", #"{"text":"Initial answer"}"#, seq: 1))
        c.consume(try event("message.start", "{}", seq: 2))
        c.consume(try event("message.delta", #"{"text":"Scheduled update"}"#, seq: 3))
        c.consume(try event("message.complete", #"{"text":"Scheduled update"}"#, seq: 4))
        c.consume(try event("new.hermes.event", #"{"message":"New capability","extra":123}"#, seq: 5))
        XCTAssertEqual(c.messages.map(\.content), ["Initial answer", "Scheduled update", "New capability"])
        XCTAssertTrue(c.messages.last!.detail.contains("123"))
    }

    func testNativeTerminalOutputAndControls() throws {
        var c = HermesConversation()
        c.consume(try event("agent.terminal.output", #"{"process_id":"p","chunk":"Building\n"}"#, seq: 1))
        c.consume(try event("agent.terminal.output", #"{"process_id":"p","chunk":"Passed"}"#, seq: 2))
        c.consume(try event("session.control.update", #"{"control":{"heartbeat":{"status":"active","interval_seconds":60}}}"#, seq: 3))
        XCTAssertEqual(c.messages.first?.detail, "Building\nPassed")
        XCTAssertEqual(c.control["heartbeat"]["interval_seconds"].int, 60)
    }
    func testAttachmentsPreservePathsAndHideEncodedImageBody() {
        let body = "Here it is\n@image:\"/tmp/a b.png\"\n[Report](/tmp/report.pdf)\n![Remote](https://example.com/image.png)"
        let files = HermesAttachment.parse(body)
        XCTAssertEqual(files.map(\.reference), ["/tmp/a b.png", "/tmp/report.pdf", "https://example.com/image.png"])
        XCTAssertFalse(HermesAttachment.displayText(body).contains("@image:"))
        XCTAssertTrue(HermesAttachment.displayText(body).contains("[Report]"))
    }

    func testConnectionRequestsSettleAndRestore() throws {
        var c = HermesConversation()
        c.consume(try event("connection.request", #"{"op_id":"op","targets":[{"name":"test","state":"pending"}]}"#, seq: 1))
        XCTAssertEqual(c.questions.first?.method, "connection")
        c.consume(try event("connection.update", #"{"op_id":"op","settled":true,"targets":[{"name":"test","state":"skipped"}]}"#, seq: 2))
        XCTAssertTrue(c.questions.isEmpty)
        XCTAssertEqual(c.messages.last?.content, "test: skipped")
    }

    func testUnknownDesktopRequestsAreNotRestoredAsCredentialPrompts() throws {
        var c = HermesConversation()
        c.hydrate(try json(#"{"messages":[],"open_requests":[{"id":"x","method":"preview.read","params":{"session_id":"live"}}]}"#))
        XCTAssertTrue(c.questions.isEmpty)
    }

    func testStoredTranscriptJoinsFullToolResultToOriginalArguments() throws {
        let rows = try json(#"[{"role":"assistant","content":null,"tool_calls":[{"id":"call-1","function":{"name":"terminal","arguments":"{\"command\":\"printf hello\"}"}}]},{"role":"tool","tool_call_id":"call-1","content":"{\"output\":\"hello\",\"exit_code\":0}"}]"#).array
        let projected = HermesConversation.project(rows)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].id, "tool-call-1")
        XCTAssertEqual(projected[0].activity, "terminal")
        XCTAssertTrue(projected[0].detail.contains("printf hello"))
        XCTAssertTrue(projected[0].detail.contains("output"))
    }

}
