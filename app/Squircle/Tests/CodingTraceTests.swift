import XCTest
@testable import Squircle

final class CodingTraceTests: XCTestCase {
    func testClaudeTimelineJoinsResultsAndOmitsProtocolNoise() {
        let raw = #"""
        {"type":"system","subtype":"init","model":"claude-opus","apiKeySource":"ANTHROPIC_API_KEY"}
        {"type":"system","subtype":"hook_response","stdout":"internal hook"}
        {"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Fixing the preview."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/app/Preview.swift","old_string":"bad","new_string":"good"}}]}}
        {"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Fixing the preview."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/app/Preview.swift","old_string":"bad","new_string":"good"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Updated Preview.swift"}]}}
        {"type":"result","subtype":"success"}
        {"type":"partial
        """#
        let trace = CodingTrace.parse(Data(raw.utf8))
        XCTAssertEqual(trace.messages.count, 2)
        XCTAssertEqual(trace.messages[1].activity, "Edit Preview.swift")
        XCTAssertTrue(trace.messages[1].detail.contains("− bad\n+ good"))
        XCTAssertTrue(trace.messages[1].detail.contains("Updated Preview.swift"))
        XCTAssertFalse(trace.messages[1].detail.contains("tool_use_id"))
        XCTAssertTrue(trace.authentication.contains("API billing"))
        XCTAssertEqual(trace.state, "Completed")
    }

    func testCodexIncrementalItemsUpdateWithoutDuplicateActions() {
        let started = #"""
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.started"}
        {"type":"item.started","item":{"id":"cmd","type":"command_execution","command":"sleep 45","status":"in_progress"}}
        """#
        let live = CodingTrace.parse(Data(started.utf8))
        XCTAssertEqual(live.model, "Codex")
        XCTAssertEqual(live.state, "Working")
        XCTAssertTrue(live.messages[0].isStreaming)
        let finished = started + "\n" + #"""
        {"type":"item.completed","item":{"id":"cmd","type":"command_execution","command":"sleep 45","aggregated_output":"test failed","exit_code":1,"status":"completed"}}
        {"type":"item.completed","item":{"id":"patch","type":"file_change","changes":[{"path":"/tmp/check.txt","kind":"add","diff":"+VERIFIED"}],"status":"completed"}}
        {"type":"turn.completed","usage":{"input_tokens":12}}
        """#
        let done = CodingTrace.parse(Data(finished.utf8))
        XCTAssertEqual(done.messages.count, 2)
        XCTAssertFalse(done.messages[0].isStreaming)
        XCTAssertTrue(done.messages[0].failed)
        XCTAssertTrue(done.messages[0].detail.contains("test failed"))
        XCTAssertEqual(done.messages[1].activity, "Edit check.txt")
        XCTAssertTrue(done.messages[1].detail.contains("+VERIFIED"))
        XCTAssertEqual(done.state, "Completed")
        XCTAssertEqual(CodingTrace.references(in: [.string("/tmp/codex-work.jsonl")]), ["/tmp/codex-work.jsonl"])
    }

    func testParentRelayedTraceSurvivesHistoryAndStreaming() {
        let path = "/tmp/codex-child.jsonl"
        let rows: [JSONValue] = [.object(["role": .string("assistant"), "content": .string("Child activity: " + path)])]
        XCTAssertEqual(HermesConversation.project(rows).first?.traceFiles, [path])
        var live = HermesConversation()
        live.consume(.object(["type": .string("message.delta"), "payload": .object(["text": .string("Child activity: /tmp/codex-")])]))
        live.consume(.object(["type": .string("message.delta"), "payload": .object(["text": .string("child.jsonl")])]))
        XCTAssertEqual(live.messages.first?.traceFiles, [path])
    }

    func testResumeRetainsLogForToolWithoutResult() throws {
        let raw = #"[{"role":"assistant","tool_calls":[{"id":"pending","function":{"name":"terminal","arguments":"{\"command\":\"claude -p task > /tmp/claude-task.jsonl\"}"}}]}]"#
        let rows = try JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8))
        let messages = HermesConversation.project(rows)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].traceFiles, ["/tmp/claude-task.jsonl"])
        XCTAssertFalse(messages[0].isStreaming, "A stored call does not prove a process is still running")
    }

    func testHiddenCallsDoNotAppearAsPendingActivity() throws {
        let raw = #"[{"role":"assistant","display_kind":"hidden","tool_calls":[{"id":"private","function":{"name":"terminal","arguments":"{}"}}]}]"#
        let rows = try JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8))
        XCTAssertTrue(HermesConversation.project(rows).isEmpty)
    }

    func testImagesReadByClaudeRemainOpenable() {
        let raw = #"{"type":"assistant","message":{"id":"image","content":[{"type":"tool_use","id":"read","name":"Read","input":{"file_path":"/tmp/actual capture.png"}}]}}"#
        let trace = CodingTrace.parse(Data(raw.utf8))
        XCTAssertEqual(HermesAttachment.parse(trace.messages[0].content).first?.reference, "/tmp/actual capture.png")
    }

    func testTraceDiscoveryUsesRealReferencedFilesAndDeduplicates() throws {
        let row = JSONValue.string("claude -p task --output-format stream-json > /Users/a/.hermes/cache/claude-work.jsonl")
        XCTAssertEqual(CodingTrace.references(in: [row, row]), ["/Users/a/.hermes/cache/claude-work.jsonl"])
        XCTAssertTrue(CodingTrace.references(in: [.string("/tmp/other.jsonl")]).isEmpty)
    }

    func testToolOutputUnwrapsJSONWithoutHidingFailure() throws {
        let result = JSONValue.string(#"{"output":"BUILD FAILED\nFile.swift: syntax error","exit_code":1}"#)
        XCTAssertEqual(ToolPresentation.summary(result), "BUILD FAILED\nFile.swift: syntax error")
        XCTAssertFalse(ToolPresentation.detail(args: .null, result: result).contains("exit_code"))
        XCTAssertTrue(HermesConversation.isFailure(result))
    }
}
