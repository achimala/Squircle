import Foundation
import XCTest
@testable import Squircle

final class HermesClientTests: XCTestCase {
    private func configuration(_ override: [String: String] = [:]) throws -> AppConfiguration {
        var values = ["hermes_url": "https://mac.example.test:8444", "hermes_token": "test-hermes-key",
                      "squircle_url": "https://mac.example.test:8443", "squircle_token": "test-control-key",
                      "diagnostic_token": "test-diagnostic-key", "agent_instructions": "Use the configured workspace."]
        values.merge(override) { _, new in new }
        return try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: values))
    }

    func testConfigurationRejectsCredentialBearingOrInsecureOriginsWithoutEchoingSecrets() throws {
        for origin in ["http://mac.example.test", "https://user:SECRET@mac.example.test", "https://mac.example.test/?token=SECRET", "https://mac.example.test/api"] {
            XCTAssertThrowsError(try configuration(["hermes_url": origin])) { error in
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
                XCTAssertFalse(error.localizedDescription.contains(origin))
            }
        }
        XCTAssertThrowsError(try configuration(["hermes_token": "secret\r\nInjected: header"]))
        XCTAssertEqual(try configuration().hermesURL.port, 8444)
    }

    func testSessionAndHistoryFixturesProjectTextAndToolsWithoutReasoning() throws {
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(#"{"id":"api_test","title":null,"preview":null,"last_active":null,"started_at":1720000000.5,"message_count":4}"#.utf8))
        XCTAssertEqual(session.title, "New conversation")
        XCTAssertEqual(session.updatedAt.timeIntervalSince1970, 1720000000.5)
        let fixture = #"""
        {"object":"list","session_id":"api_test","data":[
          {"id":12,"role":"user","content":"Build the app"},
          {"id":13,"role":"assistant","content":[{"type":"reasoning","text":"PRIVATE"},{"type":"text","text":"I’ll build it."}],"reasoning":"PRIVATE","tool_calls":[{"function":{"name":"terminal","arguments":"SECRET TOOL INPUT"}}]},
          {"id":14,"role":"tool","content":"SECRET TOOL OUTPUT","tool_name":"terminal"},
          {"id":15,"role":"system","content":"PRIVATE SYSTEM PROMPT"}
        ],"pagination":{"limit":500,"offset":0,"returned":4,"order":"latest"}}
        """#
        let page = try JSONDecoder().decode(MessagePage.self, from: Data(fixture.utf8))
        XCTAssertEqual(page.messages.count, 3)
        XCTAssertEqual(page.messages[0].id, "12")
        XCTAssertEqual(page.messages[1].content, "I’ll build it.")
        XCTAssertEqual(page.messages[1].tools, ["terminal"])
        XCTAssertEqual(page.messages[2].content, "")
        XCTAssertFalse(page.messages.map(\.content).joined().contains("PRIVATE"))
        XCTAssertFalse(page.messages.map(\.content).joined().contains("SECRET"))
    }

    func testSSECommentsCRLFMultilineAndSequencePayload() throws {
        var parser = SSEParser()
        XCTAssertNil(try parser.line(": open\r"))
        XCTAssertNil(try parser.line("\r"))
        XCTAssertNil(try parser.line("id: 42\r"))
        XCTAssertNil(try parser.line(#"data: {"event":"message.delta","run_id":"run_test","seq":42,"delta":"Hello"}"# + "\r"))
        let frame = try XCTUnwrap(parser.line("\r"))
        XCTAssertEqual(frame.id, "42")
        let event = try JSONDecoder().decode(RunEvent.self, from: Data(frame.data.utf8))
        XCTAssertEqual(event.event, "message.delta")
        XCTAssertEqual(event.seq, 42)
        XCTAssertEqual(event.delta, "Hello")
        XCTAssertNil(try parser.line(": keepalive"))
        XCTAssertNil(try parser.line(""))
        XCTAssertNil(try parser.line("data: first"))
        XCTAssertNil(try parser.line("data: second"))
        XCTAssertEqual(try parser.line(""), SSEFrame(id: nil, data: "first\nsecond"))
        XCTAssertThrowsError(try parser.line("data: " + String(repeating: "x", count: 1_048_576)))
    }

    func testApprovalAndTerminalRunFixturesUseExactRequestIDs() throws {
        let fixture = #"""
        {"object":"hermes.run","run_id":"run_test","status":"waiting_for_approval","session_id":"api_test",
         "approval":{"event":"approval.request","run_id":"run_test","request_id":"approval-123","description":"Delete generated files","command":"rm generated.txt","choices":["once","deny"]}}
        """#
        let run = try JSONDecoder().decode(RunStatus.self, from: Data(fixture.utf8))
        XCTAssertFalse(run.terminal)
        let approval = try XCTUnwrap(run.approval?.approval(runID: run.run_id))
        XCTAssertEqual(approval.id, "approval-123")
        XCTAssertEqual(approval.choices, ["once", "deny"])
        let completed = try JSONDecoder().decode(RunStatus.self, from: Data(#"{"run_id":"run_test","status":"completed","session_id":"api_test","output":"Built."}"#.utf8))
        XCTAssertTrue(completed.terminal)
        XCTAssertEqual(completed.output, "Built.")
    }

    func testBuildFixtureOnlyOffersInstallationForSucceededIPA() throws {
        let built = try JSONDecoder().decode(AppBuild.self, from: Data(#"{"id":"build1","state":"succeeded","created_at":1720000000,"output":{"title":"Demo","version":"1.0","build_number":"3","ipa_path":"/private/build/app.ipa"}}"#.utf8))
        XCTAssertTrue(built.canInstall)
        XCTAssertEqual(built.version, "1.0 (3)")
        let simulator = try JSONDecoder().decode(AppBuild.self, from: Data(#"{"id":"build2","state":"succeeded","created_at":1720000000,"output":{"title":"Demo","version":"1.0","build_number":"3","ipa_path":null}}"#.utf8))
        XCTAssertFalse(simulator.canInstall)
    }

    func testRunSubmissionUsesCorrectOriginCredentialAndIdempotencyHeader() async throws {
        let received = expectation(description: "run request")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mac.example.test:8444/v1/runs")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-hermes-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "stable-id")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = try Self.body(request)
            XCTAssertEqual(body["session_id"] as? String, "api_test")
            XCTAssertEqual(body["input"] as? String, "Hello")
            XCTAssertEqual(body["instructions"] as? String, "Use the configured workspace.")
            received.fulfill()
            return (202, #"{"run_id":"run_test","status":"started","replayed":false}"#)
        }
        defer { FixtureProtocol.handler = nil }
        let client = HermesClient(configuration: try configuration(), sessionConfiguration: config)
        let id = try await client.startRun(sessionID: "api_test", text: "Hello", idempotencyKey: "stable-id")
        XCTAssertEqual(id, "run_test")
        await fulfillment(of: [received], timeout: 2)
    }

    func testHTTPErrorDoesNotExposeUntrustedResponseBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { _ in (401, #"{"error":{"message":"SECRET_TOKEN"}}"#) }
        defer { FixtureProtocol.handler = nil }
        let client = HermesClient(configuration: try configuration(), sessionConfiguration: config)
        do {
            _ = try await client.sessions()
            XCTFail("Expected authentication rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("SECRET_TOKEN"))
            XCTAssertTrue(error.localizedDescription.contains("credential"))
        }
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, text) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
