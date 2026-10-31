import XCTest
import UIKit
@testable import Squircle

/// Fixtures written as Foundation values; a value JSON can't hold fails the test.
extension JSONValue {
    static func from(_ value: Any) -> Self {
        try! JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
}

final class T3Tests: XCTestCase {
    func testISODateMatchesFoundation() {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for text in ["2026-10-15T09:41:07.123Z", "2024-02-29T23:59:59.999999Z", "1999-12-31T00:00:00Z",
                     "2026-03-01T12:00:00+05:30", "2026-01-01T00:00:00.5-08:00", "1970-01-01T00:00:00Z"] {
            let expected = fractional.date(from: text) ?? plain.date(from: text)
            XCTAssertEqual(ISODate.parse(text)!.timeIntervalSince1970, expected!.timeIntervalSince1970, accuracy: 0.001, text)
        }
        for text in ["", "2026-13-01T00:00:00Z", "2026-10-15", "2026-10-15T09:41:07", "2026-10-15T09:41:07.Z", "nope"] {
            XCTAssertNil(ISODate.parse(text), text)
        }
    }

    /// Numbers off the wire: a whole number that fits, or nothing; never a
    /// trap (1e100) or a silent truncation (2.5). A thread event whose
    /// sequence isn't one is never applied.
    func testNumbersOffTheWireAreExactOrRejected() throws {
        func value(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
        XCTAssertEqual(try value("42").int, 42)
        XCTAssertEqual(try value("-7").int, -7)
        XCTAssertEqual(try value("3.0").int, 3)
        for bad in ["1e100", "-1e100", "2.5", "9.3e18", "\"4\"", "true", "null"] { XCTAssertNil(try value(bad).int, bad) }
        XCTAssertEqual(try value("12").identifier, "12")
        XCTAssertNil(try value("1e100").identifier)
        XCTAssertNil(try value("0.5").identifier)
        var state = T3ThreadState()
        state.consume(try value(#"{"kind":"snapshot","snapshotSequence":5,"projection":{"thread":{"id":"t"},"messages":[]}}"#))
        state.consume(try value(#"{"kind":"event","sequence":1e100,"event":{"type":"message.updated","payload":{"id":"a","role":"assistant","text":"x"}}}"#))
        state.consume(try value(#"{"kind":"event","sequence":6.5,"event":{"type":"message.updated","payload":{"id":"b","role":"assistant","text":"y"}}}"#))
        XCTAssertEqual(state.sequence, 5)
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testAVCCHandlesFragmentedAndCoalescedHTTPBytes() throws {
        let packets = Data([0,0,0,4,1,11,12,13, 0,0,0,3,2,21,22, 0,0,0,2,3,31])
        for split in 0...packets.count {
            var framer = AVCCFramer(), tags = [UInt8](), payloads = [Data]()
            let receive: (UInt8,Data) -> Void = { tags.append($0); payloads.append($1) }
            try framer.consume(Data(packets.prefix(split)),emit:receive)
            try framer.consume(Data(packets.dropFirst(split)),emit:receive)
            XCTAssertEqual(tags,[1,2,3]); XCTAssertEqual(payloads,[Data([11,12,13]),Data([21,22]),Data([31])])
        }
        var framer = AVCCFramer(), tags = [UInt8]()
        for byte in packets { try framer.consume(Data([byte])) { tag,_ in tags.append(tag) } }
        XCTAssertEqual(tags,[1,2,3])
    }
    /// A 50 fps feed delivered in bunches (a relayed link) plays evenly,
    /// never backwards, and no further behind arrival than the cap.
    func testPacerSpreadsBunchedArrivalsEvenly() {
        var pacer = SimulatorPacer()
        var arrivals = (0..<200).map { Double($0) * 0.02 }
        for i in stride(from: 40, to: 200, by: 25) { for j in i..<(i + 6) { arrivals[j] = arrivals[i + 5] } } // 100 ms stalls
        let times = arrivals.map { pacer.time(arrival: $0, earliest: $0 + 0.002) }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        XCTAssert(gaps.allSatisfy { $0 > 0 })
        XCTAssert(zip(times, arrivals).allSatisfy { $0 - $1 <= SimulatorPacer.maximumLead + 0.001 })
        // Unpaced, each stall shows as a 120 ms hold then five pictures at
        // once. After the first, the delay covers them.
        XCTAssertLessThan(gaps.dropFirst(70).max()!, 0.04)
        XCTAssertGreaterThan(gaps.dropFirst(20).min()!, 0.008)
    }
    /// Every protocol 2 event carries one whole entity: a replayed one
    /// applies once, a newer one replaces the old in place, and a late
    /// snapshot never rolls the thread back.
    func testEntityEventsReplaceInPlaceAndApplyOnce() {
        func event(_ seq: Int, _ type: String, _ payload: [String: Any]) -> JSONValue {
            .from(["kind": "event", "sequence": seq, "event": ["type": type, "payload": payload]])
        }
        func message(_ text: String, streaming: Bool) -> [String: Any] {
            ["id": "a", "role": "assistant", "text": text, "streaming": streaming, "runId": "r1", "createdAt": "2026-10-19T10:00:00.000Z"]
        }
        var state = T3ThreadState()
        // Events before any snapshot can't be placed.
        state.consume(event(39, "message.updated", message("Lost", streaming: false)))
        XCTAssertTrue(state.messages.isEmpty)
        state.consume(.from(["kind": "snapshot", "snapshotSequence": 40, "projection": ["thread": ["id": "t"], "messages": [],
            "runs": [["id": "r1", "status": "running"]], "turnItems": [], "nodes": [["id": "n"]]]]))
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.projection["nodes"], .null, "only what the phone reads is kept")
        let hello = event(41, "message.updated", message("Hello", streaming: true))
        state.consume(hello); state.consume(hello)
        XCTAssertEqual(state.messages.map(\.content), ["Hello"]); XCTAssertTrue(state.messages[0].isStreaming)
        state.consume(event(42, "message.updated", message("Hello world", streaming: false)))
        XCTAssertEqual(state.messages.map(\.content), ["Hello world"]); XCTAssertFalse(state.messages[0].isStreaming)
        let tool: [String: Any] = ["id": "turn-item:x", "type": "command_execution", "runId": "r1", "status": "running", "input": "pwd",
                                   "nativeItemRef": ["nativeId": "toolu_1"], "startedAt": "2026-10-19T10:00:01.000Z"]
        state.consume(event(43, "turn-item.updated", tool))
        XCTAssertEqual(state.messages.last?.id, "toolu_1"); XCTAssertTrue(state.messages.last!.isStreaming)
        state.consume(event(44, "turn-item.updated", tool.merging(["status": "completed", "output": "/work"]) { $1 }))
        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.messages.last?.detail, "pwd\n\n/work"); XCTAssertFalse(state.messages.last!.isStreaming)
        state.consume(event(45, "run.updated", ["id": "r1", "status": "completed"]))
        XCTAssertFalse(state.isRunning)
        state.consume(event(46, "thread.metadata-updated", ["id": "t", "title": "Renamed"]))
        XCTAssertEqual(state.thread["title"].string, "Renamed")
        state.consume(.from(["kind": "snapshot", "snapshotSequence": 39, "projection": ["thread": ["id": "t"], "messages": []]]))
        XCTAssertEqual(state.messages.count, 2)
        // A rollback rewrites history: only a fresh snapshot shows it.
        state.consume(event(47, "checkpoint.rollback-requested", ["scopeId": "s"]))
        XCTAssertLessThan(state.sequence, 0)
    }
    /// A question or approval shows only while it is pending in the run
    /// going now, also after a long run pushes its item out of the kept
    /// history.
    func testRequestsShowOnlyWhilePendingInTheActiveRun() {
        func event(_ seq: Int, _ type: String, _ payload: [String: Any]) -> JSONValue {
            .from(["kind": "event", "sequence": seq, "event": ["type": type, "payload": payload]])
        }
        func request(_ id: String, _ status: String) -> [String: Any] {
            ["id": id, "kind": "user_input", "status": status, "responseCapability": ["type": "live", "providerSessionId": "p"]]
        }
        func item(_ id: String, request: String, run: String) -> [String: Any] {
            ["id": id, "type": "user_input_request", "requestId": request, "runId": run, "status": "waiting",
             "questions": [["id": "q", "header": "Pick", "question": "Which?", "options": []]], "startedAt": "2026-10-19T07:00:00.000Z"]
        }
        var state = T3ThreadState()
        state.consume(.from(["kind": "snapshot", "snapshotSequence": 1, "projection": ["thread": ["id": "t"],
            "runs": [["id": "old", "status": "waiting"]],
            "runtimeRequests": [request("r1", "resolved"), request("r2", "pending")],
            "turnItems": [item("i1", request: "r1", run: "old"), item("i2", request: "r2", run: "old")]]]))
        XCTAssertEqual(state.pendingRequests.map(\.id), ["r2"])
        XCTAssertEqual(state.pendingRequests.first?.questions.count, 1)
        // 1300 later tool calls: the open request's item stays, and it still shows.
        for i in 0..<1300 {
            state.consume(event(2 + i, "turn-item.updated", ["id": "s\(i)", "type": "dynamic_tool", "toolName": "Read", "runId": "old",
                                                            "status": "completed", "input": ["file_path": "/a"]]))
        }
        XCTAssertLessThan(state.itemCount, 1300)
        XCTAssertEqual(state.pendingRequests.map(\.id), ["r2"])
        // Its run ended: it can never be answered.
        state.consume(event(2000, "run.updated", ["id": "old", "status": "interrupted"]))
        state.consume(event(2001, "run.created", ["id": "new", "status": "running"]))
        XCTAssertTrue(state.pendingRequests.isEmpty)
        state.consume(event(2002, "runtime-request.updated", request("r3", "pending")))
        state.consume(event(2003, "turn-item.updated", item("i3", request: "r3", run: "new")))
        XCTAssertEqual(state.pendingRequests.map(\.id), ["r3"])
        state.consume(event(2004, "runtime-request.updated", request("r3", "resolved")))
        XCTAssertTrue(state.pendingRequests.isEmpty)
    }
    /// Segments with their text as plain characters, for comparing.
    private func plain(_ text: String) -> [String] {
        Markdown.segments(text).map {
            switch $0 {
            case .text(let text): "text:" + String(text.characters)
            case .media(let media): (media.video ? "video:" : "image:") + media.path
            case .table(let table): "table:" + ([table.header] + table.rows).map { $0.map { String($0.characters) }.joined(separator: ",") }.joined(separator: "/")
            }
        }
    }

    func testDiffKeepsDashDashAndPlusPlusLinesInsideHunks() {
        let diff = """
        diff --git a/q.sql b/q.sql
        index 1..2 100644
        --- a/q.sql
        +++ b/q.sql
        @@ -1,2 +1,2 @@ select
         select 1;
        --- old comment
        +++i;
        \\ No newline at end of file
        @@ -9 +9,2 @@
        -x
        +--- rule
        ++y
        diff --git a/new b/new
        new file mode 100644
        --- /dev/null
        +++ b/new
        @@ -0,0 +1 @@
        +hi
        """
        let parsed = ParsedDiff.parse(diff)
        XCTAssertEqual(parsed.files.map(\.path), ["q.sql", "new"])
        let q = parsed.files[0]
        XCTAssertEqual(q.lines.map { "\($0.kind)\($0.old)/\($0.new):\($0.text)" }, [
            "hunk0/0:@@ -1,2 +1,2 @@ select", "context1/1:select 1;", "removed2/0:-- old comment", "added0/2:++i;",
            "hunk0/0:@@ -9 +9,2 @@", "removed9/0:x", "added0/9:--- rule", "added0/10:+y",
        ])
        XCTAssertEqual([q.additions, q.deletions], [3, 2])
        XCTAssertEqual(parsed.files[1].lines.last?.text, "hi")
    }
}

// MARK: Native state, transport and caches (W5)

extension SquircleModel {
    /// A model that keeps nothing in the app's own places and never reaches
    /// the network: throwaway preferences, caches and journal, an offline transport.
    static func hermetic(configuration: AppConfiguration? = nil,
                         commandDispatch: ((JSONValue) async throws -> JSONValue)? = nil,
                         upload: ((URL, String) async throws -> String)? = nil,
                         journal: PendingJournal? = nil) -> SquircleModel {
        let suite = "squircle-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let journal = journal ?? (configuration == nil ? nil : PendingJournal(directory: scratch.appendingPathComponent("journal")))
        return SquircleModel(configuration: configuration, preferences: preferences, commandDispatch: commandDispatch,
                             upload: upload, journal: .some(journal), cache: DiskCache(root: scratch),
                             transport: .offline, sharesMedia: false)
    }

}

/// A command dispatch that holds each command until the test releases it.
@MainActor
private final class GatedDispatch {
    private(set) var commands: [JSONValue] = []
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var counted: [(count: Int, arrived: CheckedContinuation<Void, Never>)] = []
    var dispatch: (JSONValue) async throws -> JSONValue {
        { [unowned self] command in
            commands.append(command)
            let reached = counted.filter { $0.count <= commands.count }
            counted.removeAll { $0.count <= commands.count }
            for waiter in reached { waiter.arrived.resume() }
            try await withCheckedThrowingContinuation { waiting.append($0) }
            return .object([:])
        }
    }
    /// Resumes once `count` commands have arrived.
    func until(_ count: Int) async {
        guard commands.count < count else { return }
        await withCheckedContinuation { counted.append((count, $0)) }
    }
    /// `failing`: T3 refuses the command. `lost`: the answer never comes back.
    func release(failing: Bool = false, lost: Bool = false) {
        let next = waiting.removeFirst()
        if failing { next.resume(throwing: ClientError.backend("T3", 0, "refused")) }
        else if lost { next.resume(throwing: ClientError.connection("T3")) }
        else { next.resume() }
    }
}

final class NativeStateTests: XCTestCase {
    private let config = JSONValue.from(["providers":[["instanceId":"codex","displayName":"Codex","enabled":true,"status":"ready",
                                                        "models":[["slug":"sol","name":"Sol","isDefault":true]]]]])
    private let project = AppProject(id: "app", name: "App", subtitle: "", bundleID: nil, canBuild: false)

    @MainActor
    private func draftWithPicture(_ gate: GatedDispatch, upload: ((URL, String) async throws -> String)? = nil)
        async -> (SquircleModel, ConversationID) {
        let model = SquircleModel.hermetic(commandDispatch: gate.dispatch, upload: upload)
        model.consumeConfig(config)
        let draft = ConversationID.draft(UUID(), appID: project.id, agent: false)
        await model.open(draft)
        model.attach(ImageAttachment(UIImage(systemName: "star")!, id: "picture")!)
        return (model, draft)
    }
    @MainActor
    private func start(_ model: SquircleModel, _ text: String, from id: ConversationID,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Task<SendOutcome, Never> {
        let result = model.startSend(text, in: project, from: id)
        guard case .started(_, let outcome) = result else {
            XCTFail("Send refused: \(result)", file: file, line: line)
            throw CancellationError()
        }
        return outcome
    }

    /// Navigating away while a draft's thread is being created: the message
    /// still goes to the thread that draft created, and the open
    /// conversation stays put.
    @MainActor
    func testDraftSendStaysWithItsThreadAcrossNavigation() async throws {
        let gate = GatedDispatch()
        let (model, draft) = await draftWithPicture(gate)
        let sending = try start(model, "hello", from: draft)
        await gate.until(1)
        let created = try XCTUnwrap(gate.commands[0]["threadId"].string)
        await model.open(.thread("other", appID: project.id))
        gate.release()
        await gate.until(2)
        XCTAssertEqual(gate.commands[1]["type"].string, "message.dispatch")
        XCTAssertEqual(gate.commands[1]["threadId"].string, created)
        gate.release()
        let outcome = await sending.value
        XCTAssertEqual(outcome.conversation, .thread(created, appID: project.id))
        XCTAssertEqual(model.successor(of: draft), .thread(created, appID: project.id))
        XCTAssertEqual(model.selectedSessionID, "other")
        XCTAssertTrue(model.attachments.isEmpty)
    }

    /// T3 makes the draft's thread, then refuses the turn: the outcome names
    /// that thread, and the pictures wait in its field (B-N01).
    @MainActor
    func testRefusedTurnAfterCreationBelongsToTheNewThread() async throws {
        let gate = GatedDispatch()
        let (model, draft) = await draftWithPicture(gate)
        let sending = try start(model, "hello", from: draft)
        await gate.until(1); gate.release()
        await gate.until(2); gate.release(failing: true)
        guard case .rejected(_, _, let owner) = await sending.value else { return XCTFail("Expected a refusal") }
        let created = try XCTUnwrap(gate.commands[0]["threadId"].string)
        XCTAssertEqual(owner, .thread(created, appID: project.id))
        XCTAssertEqual(model.successor(of: draft), owner)
        XCTAssertNil(model.pendingSend(for: owner))
        await model.open(owner)
        XCTAssertEqual(model.attachments.map(\.id), ["picture"])
    }

    /// The thread shows the message while T3's answer is still out, then
    /// the answer is lost: it was taken, and nothing is sent again.
    @MainActor
    func testMessageInTheThreadSettlesALostAnswer() async throws {
        let gate = GatedDispatch()
        let (model, _) = await draftWithPicture(gate)
        let thread = ConversationID.thread("t", appID: project.id)
        await model.open(thread)
        model.consumeThread(.from(["kind":"snapshot","snapshotSequence":1,"projection":["thread":["id":"t",
                                   "modelSelection":["instanceId":"codex","model":"sol"]],"messages":[]]]))
        let sending = try start(model, "hello", from: thread)
        await gate.until(1)
        let messageID = try XCTUnwrap(gate.commands[0]["messageId"].string)
        model.consumeThread(.from(["kind":"event","sequence":2,"event":["type":"message.updated",
            "payload":["id":messageID,"role":"user","text":"hello","createdAt":"2026-10-15T10:00:00.000Z"]]]))
        XCTAssertNil(model.pendingSend(for: thread), "T3 has it: nothing pending")
        gate.release(lost: true)
        guard case .accepted = await sending.value else { return XCTFail("It landed") }
        XCTAssertEqual(gate.commands.count, 1)
        XCTAssertNil(model.error)
    }

    /// A recording's upload fails: sending again uploads it again, and an
    /// upload that made it is never repeated (B-N04).
    @MainActor
    func testFailedUploadIsTriedAgain() async throws {
        let gate = GatedDispatch()
        var uploads = 0, reachable = false
        let (model, draft) = await draftWithPicture(gate) { _, _ in
            uploads += 1
            guard reachable else { throw ClientError.connection("Squircle") }
            return "/mac/clip.mp4"
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        model.attach(ImageAttachment(capture: .init(kind: .video, file: file, label: "0:01"), thumbnail: UIImage(systemName: "star")!, id: "clip"))
        let failed = try start(model, "look", from: draft)
        guard case .rejected = await failed.value else { return XCTFail("Expected a refusal") }
        XCTAssertEqual(Set(model.attachments.map(\.id)), ["picture", "clip"])
        reachable = true
        let failedUploads = uploads
        let sending = try start(model, "look", from: draft)
        await gate.until(1); gate.release()
        await gate.until(2)
        XCTAssertTrue((gate.commands[1]["text"].string ?? "").contains("/mac/clip.mp4"))
        gate.release()
        _ = await sending.value
        XCTAssertEqual(uploads, failedUploads + 1)
    }

    func testAssetURLsStayOnT3sOrigin() throws {
        let base = URL(string: "https://mac.tail.ts.net:8443")!
        XCTAssertEqual(T3HTTP.assetURL("/api/assets/x?sig=1", base: base)?.absoluteString, "https://mac.tail.ts.net:8443/api/assets/x?sig=1")
        for hostile in ["//evil.example/x", "http://mac.tail.ts.net:8443/x", "https://mac.tail.ts.net:9443/x",
                        "https://user@mac.tail.ts.net:8443/x", "https://evil.example/x", "api/x", "/\\evil.example/x"] {
            XCTAssertNil(T3HTTP.assetURL(hostile, base: base), hostile)
        }
        XCTAssertTrue(T3HTTP.sameOrigin(URL(string: "https://MAC.tail.ts.net:443/a")!, URL(string: "https://mac.tail.ts.net")!))
        XCTAssertFalse(T3HTTP.sameOrigin(URL(string: "http://mac.tail.ts.net/a")!, URL(string: "https://mac.tail.ts.net")!))
    }

    func testBoundedCacheEvictsLeastRecentlyUsedByCost() {
        var cache = BoundedCache<String, Data>(budget: 10, cost: \.count)
        cache.set(Data(count: 4), for: "a"); cache.set(Data(count: 4), for: "b")
        _ = cache.value(for: "a")
        let dropped = cache.set(Data(count: 4), for: "c")
        XCTAssertEqual(dropped.count, 1)
        XCTAssertNil(cache.peek("b")); XCTAssertNotNil(cache.peek("a")); XCTAssertEqual(cache.total, 8)
        cache.set(Data(count: 50), for: "huge")
        XCTAssertEqual(cache.count, 1, "One entry over budget is kept alone, not refused")
    }

    static func configuration() throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"t3_url":"https://127.0.0.1:9","t3_token":"t","squircle_url":"https://127.0.0.1:9","squircle_token":"s","diagnostic_token":"d"}"#.utf8))
    }
}

// MARK: Phone state machines (M01, M03, M04) and the pending-send journal

/// A small seeded generator, so a failing trace can be replayed from its seed.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class LinkMachineTests: XCTestCase {
    private let now = ContinuousClock.now

    /// Connected means both required subscriptions are current on the
    /// attempt's socket; an Exit during setup or a late event from an older
    /// attempt never makes (or keeps) the phone connected.
    func testReadyOnlyOnceShellAndDevicesAreCurrentOnTheSameAttempt() {
        var s = Link.State()
        func step(_ e: Link.Event) -> Link.Result {
            let r = Link.reduce(s, e); s = r.state
            XCTAssertEqual(Link.violations(in: s), [], "\(e)")
            return r
        }
        _ = step(.start)
        _ = step(.socketOpened(attempt: 1))
        _ = step(.synchronized(attempt: 1, .shell, now: now))
        XCTAssertNil(s.session, "devices not current yet")
        // T3 ends the device subscription during setup: this attempt fails and waits.
        _ = step(.subscriptionEnded(attempt: 1, .devices, now: now))
        guard case .retrying(let failed, _) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(failed.id, 1)
        // A late value from attempt 1 changes nothing.
        XCTAssertEqual(step(.synchronized(attempt: 1, .devices, now: now)).disposition, .stale)
        _ = step(.retryDue(attempt: 1))
        _ = step(.socketOpened(attempt: 2))
        _ = step(.synchronized(attempt: 2, .devices, now: now))
        let ready = step(.synchronized(attempt: 2, .shell, now: now))
        XCTAssertTrue(ready.effects.contains(.sessionReady(Link.Session(attempt: 2, since: now))))
        // The old socket's close is not this session's.
        XCTAssertEqual(step(.dropped(attempt: 1, nil, now: now)).disposition, .stale)
        XCTAssertNotNil(s.session)
        // A refused credential stops retrying until asked.
        let refused = step(.dropped(attempt: 2, .refused, now: now))
        XCTAssertEqual(s.phase, .refused)
        XCTAssertTrue(refused.effects.contains(.sessionLost))
        XCTAssertFalse(refused.effects.contains { if case .armRetry = $0 { return true }; return false })
    }

    /// A thread T3 keeps ending counts as failing until T3 actually brings
    /// it up to date, so the user is told after a few; a typed refusal is
    /// told at once and not retried.
    func testThreadFailuresResetOnlyOnceSynchronized() {
        var s = Link.State()
        func step(_ e: Link.Event) -> Link.Result {
            let r = Link.reduce(s, e); s = r.state
            XCTAssertEqual(Link.violations(in: s), [], "\(e)")
            return r
        }
        func warned(_ r: Link.Result) -> Bool { r.effects.contains { if case .report(.set(.threadStopped)) = $0 { return true }; return false } }
        _ = step(.start); _ = step(.socketOpened(attempt: 1))
        _ = step(.synchronized(attempt: 1, .shell, now: now)); _ = step(.synchronized(attempt: 1, .devices, now: now))
        _ = step(.follow("t"))
        var warnings = 0
        for round in 1...3 {
            guard let generation = s.follow?.generation else { return XCTFail() }
            // Written, then ended by T3 before it is ever up to date.
            _ = step(.followSubscribed(generation: generation, subscription: "s\(round)"))
            if warned(step(.followEnded(generation: generation, reason: "no"))) { warnings += 1 }
            _ = step(.followRetryDue(generation: generation, exists: true))
        }
        XCTAssertEqual(warnings, 1, "the third failure in a row warns")
        guard let generation = s.follow?.generation else { return XCTFail() }
        _ = step(.followSubscribed(generation: generation, subscription: "s4"))
        XCTAssertEqual(s.follow?.failures, 3)
        XCTAssertTrue(step(.followSynchronized(generation: generation)).effects.contains(.report(.clearThread)))
        XCTAssertEqual(s.follow?.failures, 0)
        // A refusal: said at once, no retry.
        let refused = step(.followRefused(generation: generation, reason: "not allowed", exists: true))
        XCTAssertTrue(warned(refused))
        XCTAssertFalse(refused.effects.contains { if case .armFollowRetry = $0 { return true }; return false })
        XCTAssertEqual(s.follow?.phase, .refused)
        // Opening the thread again asks again.
        XCTAssertTrue(step(.follow("t")).effects.contains { if case .subscribeThread = $0 { return true }; return false })
    }
}

/// T3 as far as a message needs it: a receipt per command ID (kept
/// forever, as T3 keeps them across restarts) and the messages it holds.
private struct FakeT3 {
    var receipts: [String: Bool] = [:]
    var threads: Set<String> = []
    var messages: [String] = []
    /// Runs `command` unless T3 already took its ID; true if T3 has it now.
    mutating func run(_ command: JSONValue) -> CommandOutcome {
        let id = command["commandId"].string!
        if let taken = receipts[id] { return taken ? .accepted(.object([:])) : .refused("previously rejected") }
        switch command["type"].string {
        case "thread.create": threads.insert(command["threadId"].string!)
        case "message.dispatch":
            guard threads.contains(command["threadId"].string!) else { receipts[id] = false; return .refused("no such thread") }
            messages.append(command["messageId"].string!)
        default: break
        }
        receipts[id] = true
        return .accepted(.object([:]))
    }
}

final class DeliveryMachineTests: XCTestCase {
    private func intent(_ destination: Delivery.Destination, origin: ConversationID, recordings: [Delivery.Recording] = []) -> Delivery.Intent {
        Delivery.Intent(messageID: UUID().uuidString.lowercased(), origin: origin, projectID: "app", destination: destination,
                        spoken: "hello", pictures: [.init(id: "p", jpeg: Data([1, 2, 3]))], recordings: recordings,
                        selection: .from(["instanceId": "codex", "model": "sol"]), mode: "auto", context: "\n\nctx",
                        titleSeed: "hello", turn: .fresh())
    }
    private func draft() -> (Delivery.Intent, String) {
        let thread = UUID().uuidString.lowercased()
        let command = Delivery.createCommand(threadID: thread, projectID: "app", selection: .null, mode: "auto", identity: .fresh())
        return (intent(.newThread(id: thread, command: command), origin: .draft(UUID(), appID: "app", agent: false)), thread)
    }

    /// The connection comes up while a message's save is still being
    /// written: nothing is sent until that exact save is acknowledged, an
    /// older write's acknowledgement doesn't count, and a failed save
    /// sends nothing.
    func testSendWaitsForItsOwnSave() {
        var state = Delivery.State()
        func reduce(_ e: Delivery.Event) -> [Delivery.Effect] {
            let r = Delivery.reduce(state, e); state = r.state
            XCTAssertEqual(Delivery.violations(in: state), [])
            return r.effects
        }
        func sends(_ effects: [Delivery.Effect], _ id: String) -> Bool {
            effects.contains {
                switch $0 {
                case .dispatch(let m, _, _), .createThread(let m, _, _): m == id
                default: false
                }
            }
        }
        // Offline: submitting asks for a save, nothing else.
        let message = intent(.thread("t"), origin: .thread("t", appID: "app"))
        guard case .save(_, let first)? = reduce(.submit(message)).first else { return XCTFail("no save") }
        // The connection comes up before the save finishes.
        XCTAssertFalse(sends(reduce(.sessionReady(attempt: 1)), message.messageID))
        XCTAssertTrue(sends(reduce(.saved(messageID: message.messageID, sequence: first)), message.messageID))

        // A draft: the thread is made only after the first save, its turn only after the second.
        let (drafted, _) = draft()
        guard case .save(_, let creating)? = reduce(.submit(drafted)).first else { return XCTFail("no save") }
        XCTAssertFalse(sends(reduce(.sessionLost), drafted.messageID))
        XCTAssertFalse(sends(reduce(.sessionReady(attempt: 2)), drafted.messageID))
        let created = reduce(.saved(messageID: drafted.messageID, sequence: creating))
        guard case .createThread(_, _, let attempt)? = created.first(where: { if case .createThread = $0 { return true }; return false })
        else { return XCTFail("no thread made") }
        let answered = reduce(.createAnswered(messageID: drafted.messageID, attempt: attempt, .accepted(.null)))
        guard case .save(_, let sending)? = answered.first(where: { if case .save = $0 { return true }; return false }) else { return XCTFail("turn not saved") }
        XCTAssertFalse(sends(answered, drafted.messageID))
        // The earlier save's acknowledgement arriving late is not this one's.
        XCTAssertEqual(Delivery.reduce(state, .saved(messageID: drafted.messageID, sequence: creating)).disposition, .stale)
        // This save fails: nothing goes, the next session saves again first.
        XCTAssertFalse(sends(reduce(.saveFailed(messageID: drafted.messageID, sequence: sending, reason: "disk full")), drafted.messageID))
        _ = reduce(.sessionLost)
        let retried = reduce(.sessionReady(attempt: 3))
        XCTAssertFalse(sends(retried, drafted.messageID))
        guard case .save(_, let again)? = retried.first(where: {
            if case .save(let e, _) = $0 { return e.intent.messageID == drafted.messageID }; return false
        }) else { return XCTFail("not saved again") }
        XCTAssertTrue(sends(reduce(.saved(messageID: drafted.messageID, sequence: again)), drafted.messageID))
    }

    /// The app is killed at every point of a send (before or after each
    /// save, after T3 ran a request but before its answer arrived) and
    /// starts again from what was saved: T3 gets the message once, every
    /// request carries the bytes first made, and a lost answer never turns
    /// into a refusal or a second message.
    func testCrashAtAnyPointSendsTheMessageOnce() {
        for seed in 0..<400 as Range<UInt64> {
            var rng = Seeded(state: seed)
            var t3 = FakeT3()
            var disk: [String: Delivery.Saved] = [:]
            let (sent, thread) = seed % 2 == 0 ? draft() : (intent(.thread("t"), origin: .thread("t", appID: "app")), "t")
            if seed % 2 == 1 { t3.threads.insert("t") }
            var state = Delivery.State()
            var queue: [Delivery.Effect] = []
            var session = 1
            var commands: [String: JSONValue] = [:]
            var settled: [Delivery.Settlement] = []
            func reduce(_ e: Delivery.Event) {
                let r = Delivery.reduce(state, e); state = r.state; queue += r.effects
                XCTAssertEqual(Delivery.violations(in: state), [], "seed \(seed) after \(e)")
            }
            func crash() {
                state = Delivery.State(); queue = []
                session += 1
                reduce(.restore(Array(disk.values)))
                reduce(.sessionReady(attempt: session))
            }
            reduce(.sessionReady(attempt: session))
            reduce(.submit(sent))
            var steps = 0
            while !queue.isEmpty, steps < 200 {
                steps += 1
                // Crash before this effect runs: it and everything after are lost.
                if Int.random(in: 0..<10, using: &rng) == 0 { crash(); continue }
                let effect = queue.removeFirst()
                switch effect {
                case .save(let entry, let sequence):
                    disk[entry.intent.messageID] = .init(intent: entry.intent, stage: entry.stage)
                    // The app can die after the write but before its acknowledgement.
                    if Int.random(in: 0..<10, using: &rng) == 0 { crash(); continue }
                    reduce(.saved(messageID: entry.intent.messageID, sequence: sequence))
                case .forget(let id, _): disk[id] = nil
                case .createThread(let id, let command, let attempt), .dispatch(let id, let command, let attempt):
                    let key = command["type"].string!
                    if let first = commands[key] { XCTAssertEqual(first, command, "seed \(seed): \(key) changed between attempts") }
                    commands[key] = command
                    let roll = Int.random(in: 0..<10, using: &rng)
                    let outcome: CommandOutcome = roll < 2 ? .notSent("x") : t3.run(command)
                    if roll == 2 || roll == 3 {
                        // T3 ran it; the answer is lost with the socket, or the app dies first.
                        if roll == 3 { crash(); continue }
                        if case .createThread = effect { reduce(.createAnswered(messageID: id, attempt: attempt, .unknown("lost"))) }
                        else { reduce(.turnAnswered(messageID: id, attempt: attempt, .unknown("lost"))) }
                        reduce(.sessionLost); session += 1; reduce(.sessionReady(attempt: session))
                        continue
                    }
                    if case .createThread = effect { reduce(.createAnswered(messageID: id, attempt: attempt, outcome)) }
                    else { reduce(.turnAnswered(messageID: id, attempt: attempt, outcome)) }
                    if case .notSent = outcome { reduce(.sessionLost); session += 1; reduce(.sessionReady(attempt: session)) }
                case .settle(_, let settlement): settled.append(settlement)
                case .prepare, .ensureAgent: XCTFail("seed \(seed): \(effect)")
                case .adopt, .restoreField, .report: break
                }
            }
            XCTAssertTrue(queue.isEmpty, "seed \(seed) didn't settle")
            let landed = t3.messages.filter { $0 == sent.messageID }.count
            if disk.isEmpty, state.entries.isEmpty, landed == 0 {
                // The app died before the message was first saved: nothing left the phone.
                XCTAssertTrue(commands.isEmpty, "seed \(seed)")
                continue
            }
            XCTAssertEqual(landed, 1, "seed \(seed): T3 has the message \(landed) times")
            XCTAssertEqual(t3.threads.subtracting(["t"]).count, seed % 2 == 0 ? 1 : 0, "seed \(seed)")
            XCTAssertTrue(t3.threads.contains(thread))
            XCTAssertFalse(settled.contains { if case .rejected = $0 { return true }; return false }, "seed \(seed): refused \(settled)")
            XCTAssertTrue(disk.isEmpty, "seed \(seed): an accepted message is still kept")
        }
    }
}

final class CommandMachineTests: XCTestCase {
    private func intent(_ kind: Commands.Kind) -> Commands.Intent {
        let identity = CommandIdentity.fresh()
        return .init(identity: identity, kind: kind, command: { if case .task = kind { return nil }; return identity.stamp(["type": "x"]) }())
    }

    /// An approval whose answer is lost stays answered here and goes again,
    /// unchanged, on the next session; T3 showing the request resolved
    /// settles it even before any answer.
    func testLostApprovalIsResentAsItselfAndSettledByObservation() {
        var s = Commands.State()
        func reduce(_ e: Commands.Event) -> Commands.Result { let r = Commands.reduce(s, e); s = r.state; XCTAssertEqual(Commands.violations(in: s), []); return r }
        let approval = intent(.approval(thread: "t", request: "r", decision: "accept"))
        // Proposed offline: hidden, not sent.
        XCTAssertEqual(reduce(.propose(approval)).effects, [])
        XCTAssertEqual(s.answering, ["r"])
        XCTAssertEqual(reduce(.propose(intent(.approval(thread: "t", request: "r", decision: "decline")))).disposition, .notApplicable)
        XCTAssertEqual(reduce(.sessionReady(attempt: 1)).effects, [.dispatch(id: approval.id, command: approval.command!, attempt: 1)])
        _ = reduce(.answered(id: approval.id, attempt: 1, .unknown("lost")))
        XCTAssertEqual(s.answering, ["r"], "a lost answer is not a refusal")
        _ = reduce(.sessionLost)
        XCTAssertEqual(reduce(.sessionReady(attempt: 2)).effects, [.dispatch(id: approval.id, command: approval.command!, attempt: 2)])
        // The request resolved in T3's view before the answer came.
        let seen = reduce(.threadObserved(.init(threadID: "t", pendingRequests: [], runtimeMode: nil, running: true, activeTurn: "a")))
        XCTAssertEqual(seen.effects, [.settle(id: approval.id, .done)])
        XCTAssertEqual(reduce(.answered(id: approval.id, attempt: 2, .accepted(.null))).disposition, .stale)
        XCTAssertTrue(s.answering.isEmpty)
    }

    /// A lost interrupt is never sent again onto a turn that started since.
    func testLostInterruptNeverStopsANewerTurn() {
        var s = Commands.State(session: 1)
        func reduce(_ e: Commands.Event) -> Commands.Result { let r = Commands.reduce(s, e); s = r.state; return r }
        let stop = intent(.interrupt(thread: "t", turn: "a"))
        _ = reduce(.propose(stop))
        _ = reduce(.answered(id: stop.id, attempt: 1, .unknown("lost")))
        XCTAssertEqual(reduce(.sessionReady(attempt: 2)).effects, [], "waits to see the thread")
        let newer = reduce(.threadObserved(.init(threadID: "t", pendingRequests: [], runtimeMode: nil, running: true, activeTurn: "b")))
        XCTAssertEqual(newer.effects, [.settle(id: stop.id, .done)])
        // Still the same turn: sent again as itself.
        let again = intent(.interrupt(thread: "t", turn: "b"))
        _ = reduce(.propose(again)); _ = reduce(.answered(id: again.id, attempt: 2, .unknown("lost")))
        let same = reduce(.threadObserved(.init(threadID: "t", pendingRequests: [], runtimeMode: nil, running: true, activeTurn: "b")))
        XCTAssertEqual(same.effects, [.dispatch(id: again.id, command: again.command!, attempt: 2)])
    }

    /// One thread's mode changes go one at a time: an unsent one is
    /// replaced, a sent one is followed by the newest asked for; a refusal
    /// takes only its own overlay away.
    func testModeChangesAreSerializedAndSuperseded() {
        var s = Commands.State()
        func reduce(_ e: Commands.Event) -> Commands.Result { let r = Commands.reduce(s, e); s = r.state; XCTAssertEqual(Commands.violations(in: s), []); return r }
        let ask = intent(.mode(thread: "t", .approvalRequired)), full = intent(.mode(thread: "t", .fullAccess))
        _ = reduce(.propose(ask))
        XCTAssertEqual(reduce(.propose(full)).effects, [.settle(id: ask.id, .superseded)], "not sent yet: replaced")
        _ = reduce(.sessionReady(attempt: 1))
        let auto = intent(.mode(thread: "t", .auto)), edits = intent(.mode(thread: "t", .autoAcceptEdits))
        XCTAssertEqual(reduce(.propose(auto)).effects, [], "waits behind the one sent")
        XCTAssertEqual(reduce(.propose(edits)).effects, [.settle(id: auto.id, .superseded)])
        XCTAssertEqual(s.mode(for: "t"), .autoAcceptEdits)
        let refused = reduce(.answered(id: full.id, attempt: 1, .refused("no")))
        XCTAssertEqual(refused.effects, [.settle(id: full.id, .refused("no")), .dispatch(id: edits.id, command: edits.command!, attempt: 1), .report("no")])
        _ = reduce(.answered(id: edits.id, attempt: 1, .accepted(.null)))
        XCTAssertEqual(s.mode(for: "t"), .autoAcceptEdits, "shown until T3 shows it")
        _ = reduce(.threadObserved(.init(threadID: "t", pendingRequests: [], runtimeMode: "auto-accept-edits", running: false, activeTurn: nil)))
        XCTAssertNil(s.mode(for: "t"))
    }

    /// A task edit whose reply is lost is settled by the Mac's list: shown
    /// there, done; not shown, the same edit (a set, not a toggle) goes again.
    func testLostTaskEditIsReconciledAgainstTheList() {
        var s = Commands.State()
        func reduce(_ e: Commands.Event) -> Commands.Result { let r = Commands.reduce(s, e); s = r.state; return r }
        let edit = intent(.task(id: "k", status: .done, toTop: false))
        XCTAssertEqual(reduce(.propose(edit)).effects, [.editTask(id: edit.id, task: "k", status: .done, toTop: false)])
        XCTAssertEqual(reduce(.answered(id: edit.id, attempt: 0, .unknown("lost"))).effects, [.readTasks(task: "k")])
        XCTAssertEqual(reduce(.tasksObserved([.init(id: "k", status: .queued, revision: 3)])).effects,
                       [.editTask(id: edit.id, task: "k", status: .done, toTop: false)])
        _ = reduce(.answered(id: edit.id, attempt: 0, .accepted(.from(["revision": 5]))))
        XCTAssertEqual(s.taskEdits.count, 1, "held until the list has revision 5")
        _ = reduce(.tasksObserved([.init(id: "k", status: .done, revision: 4)]))
        XCTAssertEqual(s.taskEdits.count, 1)
        _ = reduce(.tasksObserved([.init(id: "k", status: .done, revision: 5)]))
        XCTAssertTrue(s.taskEdits.isEmpty)
    }
}

final class PendingJournalTests: XCTestCase {
    private let config = JSONValue.from(["providers":[["instanceId":"codex","displayName":"Codex","enabled":true,"status":"ready",
                                                        "models":[["slug":"sol","name":"Sol","isDefault":true]]]]])
    private let project = AppProject(id: "app", name: "App", subtitle: "", bundleID: nil, canBuild: false)

    /// A slow save never brings back a message already forgotten, and an
    /// unreadable file is set aside (never resent, never silently lost).
    func testJournalOrdersWritesAndSetsUnreadableFilesAside() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PendingJournal(directory: root)
        let id = UUID().uuidString.lowercased()
        let saved = Delivery.Saved(intent: .init(messageID: id, origin: .thread("t", appID: "a"), projectID: "a", destination: .thread("t"),
                                                 spoken: "x", pictures: [], recordings: [], selection: .null, mode: "auto", context: "",
                                                 titleSeed: "x", turn: .fresh()), stage: .preparing)
        try await journal.save(saved, sequence: 1)
        await journal.forget(id, sequence: 3)
        try await journal.save(saved, sequence: 2)
        var loaded = await journal.load()
        XCTAssertTrue(loaded.saved.isEmpty)
        try await journal.save(saved, sequence: 4)
        try Data("{".utf8).write(to: root.appendingPathComponent(UUID().uuidString.lowercased() + ".json"))
        loaded = await PendingJournal(directory: root).load()
        XCTAssertEqual(loaded.saved, [saved])
        XCTAssertEqual(loaded.unreadable.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".unreadable") }.count, 1)
    }
}
