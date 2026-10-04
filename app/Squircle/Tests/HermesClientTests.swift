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

    func testAppContextIsAppendedToExistingInstructionsOnRunSubmission() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { request in
            let body = try Self.body(request)
            XCTAssertEqual(body["instructions"] as? String, "Use the configured workspace.\n\nThis conversation belongs to Atlas.")
            return (202, #"{"run_id":"run_project","status":"started","replayed":false}"#)
        }
        defer { FixtureProtocol.handler = nil }
        let client = HermesClient(configuration: try configuration(), sessionConfiguration: config)
        _ = try await client.startRun(sessionID: "atlas-thread", text: "Build it", idempotencyKey: "app-key", projectContext: "This conversation belongs to Atlas.")
    }

    func testStartBuildPostsActualRecipeToSquircleAndDecodesQueuedJob() async throws {
        let fixture = #"{"project":"/src/Atlas.xcworkspace","scheme":"Atlas","configuration":"Release","mode":"archive","export_options":"/src/ExportOptions.plist","allow_provisioning_updates":true,"request_id":"previous-build"}"#
        let recipe = try JSONDecoder().decode(AppBuildRequest.self, from: Data(fixture.utf8)).freshSubmission(id: "fresh-build")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mac.example.test:8443/v1/builds")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-control-key")
            let body = try Self.body(request)
            XCTAssertEqual(body["request_id"] as? String, "fresh-build")
            XCTAssertEqual(body["project"] as? String, "/src/Atlas.xcworkspace")
            XCTAssertEqual(body["allow_provisioning_updates"] as? Bool, true)
            let response: [String: Any] = ["schema_version": 1, "ok": true, "data": ["job": ["id": "queued-build", "state": "queued", "created_at": 1720000000, "request": body], "replayed": false]]
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self))
        }
        defer { FixtureProtocol.handler = nil }
        let client = HermesClient(configuration: try configuration(), sessionConfiguration: config)
        let build = try await client.startBuild(recipe)
        XCTAssertEqual(build.id, "queued-build")
        XCTAssertEqual(build.status, "queued")
        XCTAssertEqual(build.title, "Atlas")
        XCTAssertFalse(build.canInstall)
    }

    func testThreadNamingUpdatesHermesSessionMetadata() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/atlas-thread")
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(try Self.body(request)["title"] as? String, "Atlas · Add a map")
            return (200, #"{"object":"hermes.session","session":{"id":"atlas-thread","title":"Atlas · Add a map","message_count":1}}"#)
        }
        defer { FixtureProtocol.handler = nil }
        let client = HermesClient(configuration: try configuration(), sessionConfiguration: config)
        let session = try await client.renameSession("atlas-thread", title: "Atlas · Add a map")
        XCTAssertEqual(session.title, "Atlas · Add a map")
    }

    @MainActor
    func testCreatingProjectThreadDuringRefreshIsNotDroppedOrReplacedByOldSelection() async throws {
        let listStarted = expectation(description: "session list held in flight")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.holdSessionList = true
        FixtureProtocol.onHold = { listStarted.fulfill() }
        FixtureProtocol.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/api/sessions"):
                return (200, #"{"object":"list","data":[{"id":"old-thread","title":"Squircle · Old","message_count":2}]}"#)
            case ("POST", "/api/sessions"):
                XCTAssertEqual(try Self.body(request)["title"] as? String, "Atlas · 1")
                return (201, #"{"object":"hermes.session","session":{"id":"new-thread","title":"Atlas · 1","message_count":0}}"#)
            case ("GET", "/api/sessions/new-thread/messages"):
                return (200, #"{"object":"list","session_id":"new-thread","data":[]}"#)
            case ("GET", "/v1/builds"):
                return (200, #"{"schema_version":1,"ok":true,"data":[]}"#)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
                return (404, "{}")
            }
        }
        let suite = "SquircleProjectRaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            FixtureProtocol.heldDelivery?()
            FixtureProtocol.heldDelivery = nil
            FixtureProtocol.onHold = nil
            FixtureProtocol.holdSessionList = false
            FixtureProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = try configuration()
        let client = HermesClient(configuration: configuration, sessionConfiguration: config)
        let model = SquircleModel(configuration: configuration, defaults: defaults, client: client, embeddedBuildID: "")
        let refresh = Task { await model.refresh() }
        await fulfillment(of: [listStarted], timeout: 2)
        XCTAssertTrue(model.isLoading)
        let project = model.createProject(name: "Atlas")
        await model.createSession(in: project)
        XCTAssertEqual(model.selectedSessionID, "new-thread")
        let release = FixtureProtocol.heldDelivery
        FixtureProtocol.heldDelivery = nil
        release?()
        await refresh.value
        XCTAssertEqual(model.selectedProjectID, project.id)
        XCTAssertEqual(model.selectedSessionID, "new-thread")
        XCTAssertEqual(model.sessions(for: project).map(\.id), ["new-thread"])
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testOlderThreadCreationCannotOverrideANewerProjectThread() async throws {
        let held = expectation(description: "first thread creation held")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.holdRequest = { $0.httpMethod == "POST" && $0.url?.path == "/api/sessions" }
        FixtureProtocol.onHold = { held.fulfill() }
        FixtureProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let title = try Self.body(request)["title"] as? String ?? ""
                let id = title.hasPrefix("Alpha") ? "alpha-thread" : "beta-thread"
                return (201, String(decoding: try JSONSerialization.data(withJSONObject: ["session": ["id": id, "title": title, "message_count": 0]]), as: UTF8.self))
            }
            let id = request.url!.pathComponents[3]
            return (200, "{\"session_id\":\"\(id)\",\"data\":[]}")
        }
        let suite = "SquircleCreationRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { Self.resetFixture(); defaults.removePersistentDomain(forName: suite) }
        let configuration = try configuration()
        let model = SquircleModel(configuration: configuration, defaults: defaults,
                                  client: HermesClient(configuration: configuration, sessionConfiguration: config), embeddedBuildID: "")
        let alpha = model.createProject(name: "Alpha")
        let beta = model.createProject(name: "Beta")
        let first = Task { await model.createSession(in: alpha) }
        await fulfillment(of: [held], timeout: 2)
        FixtureProtocol.holdRequest = nil
        await model.createSession(in: beta)
        XCTAssertEqual(model.selectedSessionID, "beta-thread")
        let release = FixtureProtocol.heldDelivery
        FixtureProtocol.heldDelivery = nil
        release?()
        await first.value
        XCTAssertEqual(model.selectedProjectID, beta.id)
        XCTAssertEqual(model.selectedSessionID, "beta-thread")
        XCTAssertEqual(model.sessions(for: alpha).map(\.id), ["alpha-thread"])
        XCTAssertEqual(model.sessions(for: beta).map(\.id), ["beta-thread"])
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testStaleBuildListPreservesAcknowledgedSubmission() async throws {
        let held = expectation(description: "build list held")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let recipe: [String: Any] = ["project": "/src/Atlas.xcodeproj", "scheme": "Atlas", "configuration": "Release", "mode": "archive", "export_options": "/src/export.plist", "allow_provisioning_updates": false]
        let old: [String: Any] = ["id": "old-build", "state": "succeeded", "created_at": 1, "request": recipe,
                                  "output": ["title": "Atlas", "bundle_id": "test.atlas", "version": "1", "build_number": "1", "ipa_path": "/build/app.ipa"]]
        FixtureProtocol.handler = { request in
            let response: [String: Any]
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/api/sessions"): response = ["data": []]
            case ("GET", "/v1/builds"): response = ["ok": true, "data": [old]]
            case ("POST", "/v1/builds"):
                response = ["ok": true, "data": ["job": ["id": "new-build", "state": "queued", "created_at": 2, "request": try Self.body(request)]]]
            default: XCTFail("Unexpected request"); response = [:]
            }
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self))
        }
        let suite = "SquircleBuildRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { Self.resetFixture(); defaults.removePersistentDomain(forName: suite) }
        let configuration = try configuration()
        let model = SquircleModel(configuration: configuration, defaults: defaults,
                                  client: HermesClient(configuration: configuration, sessionConfiguration: config), embeddedBuildID: "")
        await model.refresh()
        let project = try XCTUnwrap(model.projects.first { $0.name == "Atlas" })
        FixtureProtocol.holdRequest = { $0.httpMethod == "GET" && $0.url?.path == "/v1/builds" }
        FixtureProtocol.onHold = { held.fulfill() }
        let refresh = Task { await model.refresh() }
        await fulfillment(of: [held], timeout: 2)
        let submitted = await model.startBuild(for: project)
        XCTAssertEqual(submitted?.id, "new-build")
        let release = FixtureProtocol.heldDelivery
        FixtureProtocol.heldDelivery = nil
        FixtureProtocol.holdRequest = nil
        release?()
        await refresh.value
        XCTAssertEqual(Set(model.builds(for: project).map(\.id)), ["old-build", "new-build"])
        XCTAssertEqual(model.builds.first { $0.id == "new-build" }?.status, "queued")
    }

    @MainActor
    func testPendingRunStateFollowsSelectedThreadUntilAcceptance() async throws {
        let held = expectation(description: "run admission held")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { request in
            if request.url?.path == "/v1/runs" {
                XCTAssertEqual(try Self.body(request)["session_id"] as? String, "alpha-thread")
                return (202, #"{"run_id":"run_alpha","status":"started","replayed":false}"#)
            }
            if request.httpMethod == "POST" {
                let title = try Self.body(request)["title"] as? String ?? ""
                let id = title.hasPrefix("Alpha") ? "alpha-thread" : "beta-thread"
                return (201, String(decoding: try JSONSerialization.data(withJSONObject: ["session": ["id": id, "title": title, "message_count": 0]]), as: UTF8.self))
            }
            let id = request.url!.pathComponents[3]
            return (200, "{\"session_id\":\"\(id)\",\"data\":[]}")
        }
        let suite = "SquircleRunAdmissionRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { Self.resetFixture(); defaults.removePersistentDomain(forName: suite) }
        let configuration = try configuration()
        let model = SquircleModel(configuration: configuration, defaults: defaults,
                                  client: HermesClient(configuration: configuration, sessionConfiguration: config), embeddedBuildID: "")
        let alpha = model.createProject(name: "Alpha")
        let beta = model.createProject(name: "Beta")
        await model.createSession(in: alpha, title: "Alpha work")
        await model.createSession(in: beta, title: "Beta work")
        await model.selectSession("alpha-thread")
        FixtureProtocol.holdRequest = { $0.url?.path == "/v1/runs" }
        FixtureProtocol.onHold = { held.fulfill() }
        let submission = Task { await model.send("Build Alpha") }
        await fulfillment(of: [held], timeout: 2)
        XCTAssertTrue(model.isRunning)
        await model.selectSession("beta-thread")
        XCTAssertFalse(model.isRunning)
        await model.selectSession("alpha-thread")
        XCTAssertTrue(model.isRunning, "Pending admission was forgotten when returning to its thread")
        await model.selectSession("beta-thread")
        let release = FixtureProtocol.heldDelivery
        FixtureProtocol.heldDelivery = nil
        release?()
        await submission.value
        XCTAssertEqual(model.selectedSessionID, "beta-thread")
        XCTAssertFalse(model.isRunning, "Alpha’s admission changed Beta’s activity state")
    }

    private static func resetFixture() {
        FixtureProtocol.heldDelivery?()
        FixtureProtocol.heldDelivery = nil
        FixtureProtocol.onHold = nil
        FixtureProtocol.holdRequest = nil
        FixtureProtocol.holdSessionList = false
        FixtureProtocol.handler = nil
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
    static var holdSessionList = false
    static var holdRequest: ((URLRequest) -> Bool)?
    static var onHold: (() -> Void)?
    static var heldDelivery: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, text) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            let deliver = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(text.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            if (Self.holdSessionList && request.httpMethod == "GET" && request.url?.path == "/api/sessions") || Self.holdRequest?(request) == true {
                Self.heldDelivery = deliver
                Self.onHold?()
            } else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
