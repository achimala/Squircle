import XCTest
@testable import SquircleProbe

final class DiagnosticsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testQueueSurvivesRelaunchAndRetriesKeepEventIdentity() throws {
        let file = folder.appendingPathComponent("events.json")
        let event = DiagnosticEvent(buildID: "build-1", kind: .log, message: "offline")
        let original = try PersistentEventQueue(file: file)
        try original.append(event)
        let reopened = try PersistentEventQueue(file: file)
        XCTAssertEqual(reopened.events, [event])
        try reopened.append(event)
        XCTAssertEqual(reopened.events.count, 1)
        try reopened.acknowledge(event.id)
        XCTAssertTrue(try PersistentEventQueue(file: file).events.isEmpty)
    }

    func testFullQueuePreservesPriorEvents() throws {
        let queue = try PersistentEventQueue(file: folder.appendingPathComponent("events.json"), maxCount: 1)
        let crash = DiagnosticEvent(buildID: "old-build", kind: .crash, message: "crash evidence")
        try queue.append(crash)
        XCTAssertThrowsError(try queue.append(DiagnosticEvent(buildID: "new-build", kind: .launch, message: "launch")))
        XCTAssertEqual(queue.events, [crash])
    }

    func testOversizedAndInvalidEventsAreRejected() throws {
        let queue = try PersistentEventQueue(file: folder.appendingPathComponent("events.json"))
        XCTAssertThrowsError(try queue.append(DiagnosticEvent(buildID: "", kind: .log, message: "missing ID")))
        XCTAssertThrowsError(try queue.append(DiagnosticEvent(buildID: "b", kind: .log,
                                                               message: String(repeating: "a", count: PersistentEventQueue.eventByteLimit))))
        XCTAssertTrue(queue.events.isEmpty)
    }

    func testOnlyExplicitSuccessfulJSONAcknowledgesAnEvent() throws {
        let url = URL(string: "https://example.test/v1/diagnostics")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let denied = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
        XCTAssertNoThrow(try DiagnosticsTransport.validateAcknowledgement(data: Data("{\"ok\":true}".utf8), response: ok))
        XCTAssertThrowsError(try DiagnosticsTransport.validateAcknowledgement(data: Data("{\"ok\":false}".utf8), response: ok))
        XCTAssertThrowsError(try DiagnosticsTransport.validateAcknowledgement(data: Data("login page".utf8), response: ok))
        XCTAssertThrowsError(try DiagnosticsTransport.validateAcknowledgement(data: Data("{\"ok\":true}".utf8), response: denied))
    }

    func testCredentialsCannotBeSentToHTTPOrURLWithUserInfo() throws {
        XCTAssertThrowsError(try DiagnosticsTransport.endpoint("http://example.test"))
        XCTAssertThrowsError(try DiagnosticsTransport.endpoint("https://user:password@example.test"))
        XCTAssertThrowsError(try DiagnosticsTransport.endpoint("https://example.test?token=secret"))
        XCTAssertEqual(try DiagnosticsTransport.endpoint("https://example.test:8443").absoluteString,
                       "https://example.test:8443/v1/diagnostics")
    }

    @MainActor
    func testKnownBuildStartsCaptureAndQueuesLaunchWithoutNetworkCredentials() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let capture = RecordingCrashReporter()
        let file = folder.appendingPathComponent("events.json")
        let model = ProbeModel(defaults: defaults, embeddedBuildID: "embedded-build", queueFile: file,
                               crash: capture, readToken: { "" })
        XCTAssertTrue(model.serverOrigin.isEmpty)
        XCTAssertTrue(model.token.isEmpty)
        XCTAssertTrue(model.canCrash)
        XCTAssertEqual(capture.identities.last, "embedded-build")
        let queued = try PersistentEventQueue(file: file).events
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.kind, .launch)
        XCTAssertEqual(queued.first?.buildID, "embedded-build")
    }

    @MainActor
    func testKeychainFailureDoesNotDisableCaptureForKnownBuild() {
        let capture = RecordingCrashReporter()
        let model = ProbeModel(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                               embeddedBuildID: "offline-build", queueFile: folder.appendingPathComponent("events.json"),
                               crash: capture, readToken: { throw ProbeError("Keychain unavailable") })
        XCTAssertTrue(model.canCrash)
        XCTAssertEqual(capture.identities.last, "offline-build")
        XCTAssertEqual(model.status, "Keychain unavailable")
    }

    @MainActor
    func testUnrecoveredCrashPreventsNewCaptureAndRemainsVisible() {
        let capture = RecordingCrashReporter()
        capture.recoveryError = ProbeError("Previous report retained: queue full")
        let model = ProbeModel(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                               embeddedBuildID: "new-build", queueFile: folder.appendingPathComponent("events.json"),
                               crash: capture, readToken: { "" })
        XCTAssertFalse(model.canCrash)
        XCTAssertTrue(capture.identities.isEmpty)
        XCTAssertEqual(model.crashStatus, "Previous report retained: queue full")
    }
}

@MainActor
private final class RecordingCrashReporter: CrashReporting {
    var identities: [String] = []
    var recoveryError: Error?
    func recover(into queue: PersistentEventQueue) throws -> Bool {
        if let recoveryError { throw recoveryError }
        return false
    }
    func enable(buildID: String) throws { identities.append(buildID) }
}
