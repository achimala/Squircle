import XCTest
import UIKit
@testable import Squircle

final class T3Tests: XCTestCase {
    @MainActor
    func testRejectedApprovalModeChangeRestoresSelection() async {
        let model = SquircleModel(configuration:nil)
        await model.open(.thread("existing", appID: "app"))
        model.consumeThread(.from(["kind":"snapshot","snapshot":["snapshotSequence":1,"thread":["runtimeMode":"approval-required"]]]))
        await model.setRuntimeMode(.fullAccess)
        XCTAssertEqual(model.runtimeMode, .approvalRequired)
        XCTAssertNotNil(model.error)
        await model.open(.draft(UUID(), appID: "app", agent: false))
        await model.setRuntimeMode(.autoAcceptEdits)
        XCTAssertEqual(model.runtimeMode, .autoAcceptEdits)
    }
    private var modelConfig: JSONValue {
        .from(["providers":[
            ["instanceId":"codex","displayName":"Codex","enabled":true,"status":"ready","models":[
                ["slug":"sol","name":"Sol","isDefault":true], ["slug":"astra","name":"Astra"]]],
            ["instanceId":"claudeAgent","displayName":"Claude","enabled":true,"status":"ready","models":[["slug":"fable","name":"Fable","isDefault":true]]],
            ["instanceId":"offline","enabled":true,"status":"error","models":[["slug":"bad"]]],
            ["instanceId":"disabled","enabled":false,"status":"ready","models":[["slug":"bad"]]],
            ["instanceId":"empty","enabled":true,"status":"ready","models":[["name":"Missing slug"]]]
        ]])
    }
    @MainActor
    func testExistingThreadOnlyAllowsItsProviderAndPreservesModelChoice() async {
        let model = SquircleModel(configuration:nil, preferences:UserDefaults(suiteName:UUID().uuidString)!)
        model.consumeConfig(modelConfig)
        let codex = JSONValue.from(["instanceId":"codex","model":"sol"])
        let astra = JSONValue.from(["instanceId":"codex","model":"astra"])
        let claude = JSONValue.from(["instanceId":"claudeAgent","model":"fable"])
        func snapshot(_ selection:JSONValue, sequence:Int) -> JSONValue {
            .from(["kind":"snapshot","snapshot":["snapshotSequence":sequence,"thread":["modelSelection":selection.foundation]]])
        }
        await model.open(.thread("first", appID: "app"))
        XCTAssertTrue(model.availableModelSelections.isEmpty, "Do not offer other providers while the thread loads")
        model.consumeThread(snapshot(codex,sequence:1))
        XCTAssertEqual(model.availableModelSelections.count,2)
        model.chooseModel(claude)
        XCTAssertEqual(model.modelSelection,codex)
        model.chooseModel(.from(["instanceId":"codex","model":"unknown"]))
        XCTAssertEqual(model.modelSelection,codex)
        model.chooseModel(astra)
        model.consumeThread(snapshot(codex,sequence:2))
        XCTAssertEqual(model.modelSelection,astra)
        await model.open(.thread("second", appID: "app"))
        model.consumeThread(snapshot(claude,sequence:3))
        XCTAssertEqual(model.availableModelSelections,[claude])
        await model.open(.thread("first", appID: "app"))
        model.consumeThread(snapshot(codex,sequence:4))
        XCTAssertEqual(model.modelSelection,astra)
        model.consumeThread(snapshot(astra,sequence:5))
        model.consumeThread(snapshot(codex,sequence:6))
        XCTAssertEqual(model.modelSelection,codex)
    }
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

    func testUUIDScanFindsBuildIDsInText() {
        let text = "Build 3A396BB0-a97f-478f-ab18-9be4a83c744c done; café x3a396bb0-a97f-478f-ab18-9be4a83c744 and 101c1dc8-0000-4000-8000-000000000001."
        XCTAssertEqual(ThreadItem.uuids(in: text), ["3a396bb0-a97f-478f-ab18-9be4a83c744c", "101c1dc8-0000-4000-8000-000000000001"])
        XCTAssertEqual(ThreadItem.uuids(in: "3a396bb0-a97f-478f-ab18"), [])
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
    func testAVCCRejectsInvalidLengthsBeforeWaitingForPayload() {
        for header in [Data([0,0,0,0]),Data([0,128,0,1]),Data([255,255,255,255])] {
            var framer = AVCCFramer()
            XCTAssertThrowsError(try framer.consume(header) { _,_ in XCTFail("Invalid envelope delivered") })
        }
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

    func testLetterboxAndRotationMapping() {
        let bounds = CGRect(x:0,y:0,width:400,height:300), size = CGSize(width:200,height:400)
        XCTAssertNil(SimulatorSurface.point(CGPoint(x:10,y:150),bounds:bounds,size:size,orientation:"portrait"))
        let middle = SimulatorSurface.point(CGPoint(x:200,y:150),bounds:bounds,size:size,orientation:"portrait")!
        XCTAssertEqual(middle.x,0.5); XCTAssertEqual(middle.y,0.5)
        let rotated = SimulatorSurface.point(CGPoint(x:162.5,y:75),bounds:bounds,size:size,orientation:"landscape_left")!
        XCTAssertEqual(rotated.x,0.25,accuracy:0.001); XCTAssertEqual(rotated.y,0.75,accuracy:0.001)
    }
    func testThreadSnapshotReplayAndIncrementalToolProgress() {
        var state = T3ThreadState()
        state.consume(.from(["kind":"snapshot","snapshot":["snapshotSequence":40,"thread":["id":"thread","messages":[],"activities":[]]]]))
        let event = JSONValue.from(["kind":"event","event":["sequence":41,"type":"thread.message-sent","payload":["messageId":"a","role":"assistant","text":"Hello","streaming":true,"createdAt":"2026-10-05T10:00:00.000Z"]]])
        state.consume(event); state.consume(event)
        XCTAssertEqual(state.messages.count,1); XCTAssertEqual(state.messages[0].content,"Hello"); XCTAssertTrue(state.messages[0].isStreaming)
        state.consume(.from(["kind":"event","event":["sequence":42,"type":"thread.message-sent","payload":["messageId":"a","role":"assistant","text":" world","streaming":true,"createdAt":"2026-10-05T10:00:00.000Z"]]]))
        XCTAssertEqual(state.messages.count,1); XCTAssertEqual(state.messages[0].content,"Hello world")
        state.consume(.from(["kind":"event","event":["sequence":43,"type":"thread.message-sent","payload":["messageId":"a","role":"assistant","text":"","streaming":false]]]))
        XCTAssertEqual(state.messages[0].content,"Hello world"); XCTAssertFalse(state.messages[0].isStreaming)
        state.consume(.from(["kind":"event","event":["sequence":44,"type":"thread.activity-appended","payload":["activity":["id":"tool","kind":"tool.completed","summary":"Ran command","createdAt":"2026-10-05T10:00:01.000Z","payload":["data":["item":["command":"pwd","aggregatedOutput":"/work"]]]]]]]))
        XCTAssertEqual(state.messages.last?.detail,"pwd\n\n/work")
        state.consume(.from(["kind":"snapshot","snapshot":["snapshotSequence":39,"thread":["messages":[]]]]))
        XCTAssertEqual(state.messages.count,2)
    }
    /// Everything Squircle sends in your place (any `squircle-` record, even a
    /// kind this build doesn't know, or an early worker update's text) is
    /// Squircle's line, never your bubble or the agent's instructions.
    func testServiceMessagesNeverShowAsYours() {
        let build = "b2a5d37d-721e-4047-b60f-94f8c3cd6288"
        func record(_ kind: String, _ payload: [String: Any] = [:]) -> [String: Any] {
            ["context": ["version": 1, "records": [["kind": kind, "label": "Later news", "payload": payload]]]]
        }
        let marked: [(String, [String: Any])] = [
            ("build", record("squircle-build-update", ["build": build, "app": "App", "state": "failed", "reason": "No signing"])),
            ("workers", record("squircle-worker-update", ["workers": [["id": build, "title": "Dark mode", "state": "needs-you"]]])),
            ("handoff", record("squircle-handoff")),
            ("task", record("squircle-task", ["from": "agent"])),
            ("later", record("squircle-later")),
            ("old", [:]),
        ]
        let rows: [[String: Any]] = marked.map { id, extra in
            let text = id == "old" ? "[worker update]\n- \"Dark mode\" (\(build), dark) finished its turn.\nRun it." : "[x] instructions for the agent"
            return ["id": id, "role": "user", "text": text, "createdAt": "2026-10-15T10:00:00.000Z"].merging(extra) { a, _ in a }
        } + [["id": "you", "role": "user", "text": "Make it blue", "createdAt": "2026-10-15T10:00:00.000Z"]]
        var state = T3ThreadState()
        state.consume(.from(["kind": "snapshot", "snapshot": ["snapshotSequence": 1, "thread": ["messages": rows, "activities": []]]]))
        let messages = Dictionary(uniqueKeysWithValues: state.messages.map { ($0.id, $0) })
        for (id, _) in marked {
            let message = messages[id]!
            XCTAssertTrue(message.isUpdate || message.agent != nil, id)
            // A worker's task is the agent's words, shown as its message.
            if id != "task" { XCTAssertFalse(message.content.contains("instructions"), id) }
        }
        XCTAssertEqual(messages["build"]?.build?.reason, "No signing")
        XCTAssertEqual(messages["workers"]?.news.first?.state, .needsYou)
        XCTAssertEqual(messages["old"]?.news.first?.title, "Dark mode")
        XCTAssertEqual(messages["later"]?.content, "Later news")
        XCTAssertFalse(messages["you"]!.isUpdate); XCTAssertNil(messages["you"]!.agent)
    }
    /// After a reconnect T3 resends a snapshot and may replay events the
    /// thread already has; neither may lose or duplicate the transcript.
    func testQuestionsShowOnlyWhileOpenInTheRunningTurn() {
        func activity(_ id: String, _ kind: String, _ request: String?, turn: String, at second: Int) -> [String: Any] {
            (["id": id, "kind": kind, "turnId": turn, "createdAt": String(format: "2026-10-15T07:%02d:%02d.000Z", second / 60, second % 60),
                   "payload": request.map { ["requestId": $0] } ?? [String: String]()])
        }
        var state = T3ThreadState()
        state.consume(.from(["kind":"snapshot","snapshot":["snapshotSequence":1,"thread":["id":"t","messages":[],
            "session":["status":"running","activeTurnId":"old"],
            "activities":[activity("q", "user-input.requested", "r1", turn: "old", at: 0),
                          activity("a", "user-input.resolved", "r1", turn: "old", at: 1)]]]]))
        XCTAssertTrue(state.pendingRequests.isEmpty)
        // 600 later activities push the resolution out; the answered question must not come back.
        for i in 0..<620 {
            state.consume(.from(["kind":"event","event":["sequence":2 + i,"type":"thread.activity-appended",
                "payload":["activity":activity("s\(i)", "tool.completed", nil, turn: "old", at: 2 + i)]]]))
        }
        XCTAssertTrue(state.pendingRequests.isEmpty)
        XCTAssertFalse(state.thread["activities"].array.contains { $0["id"].string == "q" })
        // Open in the running turn: shown. A later turn makes it unanswerable.
        state.consume(.from(["kind":"event","event":["sequence":700,"type":"thread.activity-appended",
            "payload":["activity":activity("q2", "user-input.requested", "r2", turn: "old", at: 700)]]]))
        XCTAssertEqual(state.pendingRequests.map { $0["id"].string }, ["q2"])
        state.consume(.from(["kind":"event","event":["sequence":701,"type":"thread.session-set",
            "payload":["session":["status":"running","activeTurnId":"new"]]]]))
        XCTAssertTrue(state.pendingRequests.isEmpty)
    }
    func testResubscribeAfterReconnectKeepsTranscript() {
        func message(_ id: String, _ text: String, _ seq: Int) -> JSONValue {
            .from(["kind":"event","event":["sequence":seq,"type":"thread.message-sent","payload":["messageId":id,"role":"assistant","text":text,"streaming":false,"createdAt":"2026-10-14T10:00:0\(seq % 10).000Z"]]])
        }
        var state = T3ThreadState()
        state.consume(.from(["kind":"snapshot","snapshot":["snapshotSequence":10,"thread":["id":"t","messages":[],"activities":[]]]]))
        state.consume(message("a", "First", 11))
        // Resubscribed with nothing new: same sequence, same transcript.
        state.consume(.from(["kind":"snapshot","snapshot":["snapshotSequence":11,"thread":["id":"t","messages":[
            ["id":"a","role":"assistant","text":"First","createdAt":"2026-10-14T10:00:01.000Z"]],"activities":[]]]]))
        XCTAssertEqual(state.messages.map(\.content), ["First"])
        // A message sent while the socket was down arrives in the snapshot;
        // replayed events it already includes change nothing.
        state.consume(.from(["kind":"snapshot","snapshot":["snapshotSequence":12,"thread":["id":"t","messages":[
            ["id":"a","role":"assistant","text":"First","createdAt":"2026-10-14T10:00:01.000Z"],
            ["id":"b","role":"assistant","text":"Second","createdAt":"2026-10-14T10:00:02.000Z"]],"activities":[]]]]))
        state.consume(message("a", "First", 11)); state.consume(message("b", "Second", 12))
        state.consume(message("c", "Third", 13))
        XCTAssertEqual(state.messages.map(\.content), ["First", "Second", "Third"])
        // A late snapshot from the old socket never rolls the thread back.
        state.consume(.from(["kind":"snapshot","snapshot":["snapshotSequence":11,"thread":["id":"t","messages":[],"activities":[]]]]))
        XCTAssertEqual(state.messages.count, 3)
    }
    func testConfigurationRejectsCredentialOriginTricks() throws {
        let valid: [String:Any] = ["t3_url":"https://mac.example","t3_token":"token","squircle_url":"https://mac.example:8443","squircle_token":"build","diagnostic_token":"diagnostic"]
        XCTAssertNoThrow(try JSONDecoder().decode(AppConfiguration.self,from:JSONSerialization.data(withJSONObject:valid)))
        for url in ["http://mac.example","https://user:password@mac.example","https://mac.example/path","https://mac.example?credential=x"] {
            var bad = valid; bad["t3_url"] = url
            XCTAssertThrowsError(try JSONDecoder().decode(AppConfiguration.self,from:JSONSerialization.data(withJSONObject:bad)))
        }
    }

    func testMarkdownMediaSplitsAtLocalPicturesAndClipsOnly() {
        let text = """
        **Before → after:**
        ![before](/tmp/a.png)
        ![after](</tmp/b c.png> "title") and more
        [Real-speed clip](file:///tmp/clip.mp4)
        [docs](https://example.com/x.png) and [notes](/tmp/notes.md)
        ```
        ![code](/tmp/code.png)
        ```
        """
        XCTAssertEqual(Markdown.segments(text), [
            .text("**Before → after:**"),
            .media(MediaReference(path: "/tmp/a.png", video: false)),
            .text(" and more"),
            .media(MediaReference(path: "/tmp/b c.png", video: false)),
            .media(MediaReference(path: "/tmp/clip.mp4", video: true)),
            .text("[docs](https://example.com/x.png) and [notes](/tmp/notes.md)\n```\n![code](/tmp/code.png)\n```")
        ])
    }
}

// MARK: Native state, transport and caches (W5)

/// A command dispatch that holds each command until the test releases it.
@MainActor
private final class GatedDispatch {
    private(set) var commands: [JSONValue] = []
    private var waiting: [CheckedContinuation<Void, Error>] = []
    var dispatch: (JSONValue) async throws -> JSONValue {
        { [unowned self] command in
            commands.append(command)
            try await withCheckedThrowingContinuation { waiting.append($0) }
            return .object([:])
        }
    }
    /// `failing`: T3 refuses the command. `lost`: the answer never comes back.
    func release(failing: Bool = false, lost: Bool = false) {
        let next = waiting.removeFirst()
        if failing { next.resume(throwing: ClientError.backend("T3", 0, "refused")) }
        else if lost { next.resume(throwing: ClientError.connection("T3")) }
        else { next.resume() }
    }
    func until(_ count: Int) async { while commands.count < count { await Task.yield() } }
}

final class NativeStateTests: XCTestCase {
    private let config = JSONValue.from(["providers":[["instanceId":"codex","displayName":"Codex","enabled":true,"status":"ready",
                                                        "models":[["slug":"sol","name":"Sol","isDefault":true]]]]])
    private let project = AppProject(id: "app", name: "App", subtitle: "", bundleID: nil, canBuild: false, updatedAt: .now)

    @MainActor
    private func draftWithPicture(_ gate: GatedDispatch, upload: ((URL, String) async throws -> String)? = nil)
        async -> (SquircleModel, ConversationID) {
        let model = SquircleModel(configuration: nil, preferences: UserDefaults(suiteName: UUID().uuidString)!,
                                  commandDispatch: gate.dispatch, upload: upload)
        model.consumeConfig(config)
        let draft = ConversationID.draft(UUID(), appID: project.id, agent: false)
        await model.open(draft)
        model.attach(ImageAttachment(UIImage(systemName: "star")!, id: "picture")!)
        return (model, draft)
    }
    @MainActor
    private func start(_ model: SquircleModel, _ text: String, from id: ConversationID) throws -> Task<SendOutcome, Never> {
        guard case .started(_, let outcome) = model.startSend(text, in: project, from: id) else { throw XCTSkip("Send refused") }
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
        XCTAssertEqual(gate.commands[1]["type"].string, "thread.turn.start")
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
        model.consumeThread(.from(["kind":"snapshot","snapshot":["snapshotSequence":1,"thread":["id":"t","messages":[],
                                   "modelSelection":["instanceId":"codex","model":"sol"]]]]))
        let sending = try start(model, "hello", from: thread)
        await gate.until(1)
        let messageID = try XCTUnwrap(gate.commands[0]["message"]["messageId"].string)
        model.consumeThread(.from(["kind":"event","event":["sequence":2,"type":"thread.message-sent",
            "payload":["messageId":messageID,"role":"user","text":"hello","createdAt":"2026-10-15T10:00:00.000Z"]]]))
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
        var uploads = 0
        let (model, draft) = await draftWithPicture(gate) { _, _ in
            uploads += 1
            if uploads == 1 { throw ClientError.connection("Squircle") }
            return "/mac/clip.mp4"
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        model.attach(ImageAttachment(capture: .init(kind: .video, file: file, label: "0:01"), thumbnail: UIImage(systemName: "star")!, id: "clip"))
        let failed = try start(model, "look", from: draft)
        guard case .rejected = await failed.value else { return XCTFail("Expected a refusal") }
        XCTAssertEqual(Set(model.attachments.map(\.id)), ["picture", "clip"])
        let sending = try start(model, "look", from: draft)
        await gate.until(1); gate.release()
        await gate.until(2)
        XCTAssertTrue((gate.commands[1]["message"]["text"].string ?? "").contains("/mac/clip.mp4"))
        gate.release()
        _ = await sending.value
        XCTAssertEqual(uploads, 2)
    }

    /// Old and over-budget files go, least recently used first; one in use
    /// lately stays whatever its age (B-M02).
    func testMediaCacheEvictsByAgeAndBudgetButNotInUse() {
        let now = Date()
        func entry(_ name: String, _ bytes: Int, ago: TimeInterval) -> MediaFileStore.Entry {
            .init(name: name, bytes: bytes, used: now.addingTimeInterval(-ago))
        }
        let entries = [entry("stale", 1, ago: 20 * 86_400), entry("old", 6, ago: 3_600), entry("newer", 6, ago: 1_800),
                       entry("playing", 6, ago: 60)]
        XCTAssertEqual(MediaFileStore.evictions(entries, now: now, budget: 13), ["stale", "old"])
        XCTAssertEqual(MediaFileStore.evictions([entry("playing", 100, ago: 60)], now: now, budget: 1), [])
        XCTAssertEqual(MediaFileStore.name(for: "media:a"), MediaFileStore.name(for: "media:a"))
        XCTAssertTrue(MediaFileStore.name(for: "file:/x/clip.mov").hasSuffix(".mov"))
    }

    @MainActor
    func testSubscriptionEndingWithSocketUpIsReported() throws {
        let gateway = T3Gateway(configuration: try Self.configuration())
        var ends: [String: Error?] = [:]
        var values = 0
        gateway.track("shell", receive: { _ in values += 1 }, ended: { ends["shell"] = $0 })
        gateway.track("thread", receive: { _ in }, ended: { ends["thread"] = $0 })
        gateway.receive(.from(["_tag":"Chunk","requestId":"shell","values":[["kind":"snapshot"]]]))
        gateway.receive(.from(["_tag":"Exit","requestId":"shell","exit":["_tag":"Failure","cause":"nope"]]))
        gateway.receive(.from(["_tag":"Exit","requestId":"thread","exit":["_tag":"Success","value":NSNull()]]))
        XCTAssertEqual(values, 1)
        XCTAssertNotNil(ends["shell"] ?? nil, "A rejection says why")
        XCTAssertTrue(ends.keys.contains("thread") && ends["thread"]! == nil, "An unexpected end is reported too")
        XCTAssertEqual(gateway.subscriptionCount, 0)
        gateway.close()
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

    func testSharedKeychainUpdatesInPlaceAndNeverDeletes() {
        typealias Shared = AppConfiguration.Shared
        var adds = 0
        XCTAssertEqual(Shared.replace(data: Data(), update: { _ in errSecSuccess }, add: { _ in adds += 1; return errSecSuccess }), .stored)
        XCTAssertEqual(adds, 0)
        XCTAssertEqual(Shared.replace(data: Data(), update: { _ in errSecItemNotFound }, add: { _ in errSecSuccess }), .stored)
        XCTAssertEqual(Shared.replace(data: Data(), update: { _ in errSecItemNotFound }, add: { _ in errSecDuplicateItem }), .failed(errSecDuplicateItem))
        XCTAssertEqual(Shared.replace(data: Data(), update: { _ in errSecInteractionNotAllowed }, add: { _ in adds += 1; return errSecSuccess }),
                       .failed(errSecInteractionNotAllowed))
        XCTAssertEqual(adds, 0, "A refused update must not fall through to replacing the item")
    }

    func testOlderCacheSnapshotNeverReplacesNewer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DiskCache(root: root)
        let url = root.appendingPathComponent("thread.json")
        let wroteNew = await disk.write(["newer"], to: url, generation: 2)
        let wroteOld = await disk.write(["older"], to: url, generation: 1)
        XCTAssertTrue(wroteNew); XCTAssertFalse(wroteOld)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)), ["newer"])
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

    func testAgentDirectoryCarriesTheServicesCLI() throws {
        let reply = JSONValue.from(["ok": true, "data": ["agents": [["project_id": "p", "thread_id": "t"], ["project_id": "q"]],
                                                         "cli": "'/opt/sq dir/squircle' --data-dir /data --server http://127.0.0.1:9"]])
        let directory = try AgentDirectory.decode(reply)
        XCTAssertEqual(directory.agents, ["p": "t"])
        XCTAssertEqual(directory.cli, "'/opt/sq dir/squircle' --data-dir /data --server http://127.0.0.1:9")
        XCTAssertNil(try AgentDirectory.decode(.from(["ok": true, "data": ["agents": []]])).cli)
        XCTAssertThrowsError(try AgentDirectory.decode(.from(["ok": false])))
    }

    /// Closing breaks every cycle: the model, its client and sessions go.
    @MainActor
    func testClosedModelIsReleased() throws {
        weak var released: SquircleModel?
        try autoreleasepool {
            let model = SquircleModel(configuration: try Self.configuration(), preferences: UserDefaults(suiteName: UUID().uuidString)!)
            model.startMetadataUpdates()
            let updates = model.updates
            released = model
            model.close()
            _ = updates
        }
        XCTAssertNil(released)
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

    /// Any order of socket, subscription, clock and app events: sessions
    /// open and close in pairs, a session only follows both scopes current
    /// on its attempt, and the followed thread is subscribed only on a live socket.
    func testGeneratedTracesKeepSessionsPaired() {
        for seed in 0..<300 as Range<UInt64> {
            var rng = Seeded(state: seed)
            var s = Link.State()
            var open = false
            var current: [Int: Set<Link.Scope>] = [:]
            var trace: [Link.Event] = []
            for _ in 0..<80 {
                let attempt = max(1, s.nextAttempt - Int.random(in: 1...2, using: &rng))
                let scope: Link.Scope = Bool.random(using: &rng) ? .shell : .devices
                let generation = max(1, s.nextGeneration - Int.random(in: 1...2, using: &rng))
                let events: [Link.Event] = [
                    .start, .socketOpened(attempt: attempt), .socketFailed(attempt: attempt, .transient("x"), now: now),
                    .synchronized(attempt: attempt, scope, now: now), .subscriptionEnded(attempt: attempt, scope, now: now),
                    .dropped(attempt: attempt, nil, now: now), .retryDue(attempt: attempt), .reconnect, .retryNow,
                    .networkChanged(changed: Bool.random(using: &rng)), .foreground, .background, .backgroundExpired,
                    .tick(now: now + .seconds(90)), .follow(Bool.random(using: &rng) ? "t\(Int.random(in: 0...1, using: &rng))" : nil),
                    .followSubscribed(generation: generation, subscription: "sub"), .followEnded(generation: generation, reason: "x"),
                    .followRetryDue(generation: generation, exists: Bool.random(using: &rng)), .followReverted(threadID: "t0"),
                ]
                let event = events.randomElement(using: &rng)!
                trace.append(event)
                let before = s
                let r = Link.reduce(s, event); s = r.state
                if case .synchronized(let a, let sc, _) = event, r.disposition == .applied { current[a, default: []].insert(sc) }
                for effect in r.effects {
                    switch effect {
                    case .sessionReady(let session):
                        XCTAssertFalse(open, "seed \(seed): two sessions at once \(trace)")
                        XCTAssertEqual(current[session.attempt], Link.required, "seed \(seed): ready before both scopes")
                        guard case .synchronizing = before.phase else { return XCTFail("seed \(seed): ready from \(before.phase)") }
                        open = true
                    case .sessionLost:
                        XCTAssertTrue(open, "seed \(seed): lost a session never opened \(trace)"); open = false
                    default: break
                    }
                }
                XCTAssertEqual(open, s.session != nil, "seed \(seed) \(trace)")
                XCTAssertEqual(Link.violations(in: s), [], "seed \(seed) \(trace)")
                if s.phase == .stopped { break }
            }
        }
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
        case "thread.turn.start":
            guard threads.contains(command["threadId"].string!) else { receipts[id] = false; return .refused("no such thread") }
            messages.append(command["message"]["messageId"].string!)
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
                case .save(let entry): disk[entry.intent.messageID] = .init(intent: entry.intent, stage: entry.stage)
                case .forget(let id): disk[id] = nil
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

    /// T3 makes the draft's thread and refuses its turn: the message is
    /// the thread's from then on, and only a typed refusal ends it.
    func testDraftAliasSurvivesARefusedTurn() {
        let (sent, thread) = draft()
        var s = Delivery.State()
        func reduce(_ e: Delivery.Event) -> [Delivery.Effect] { let r = Delivery.reduce(s, e); s = r.state; return r.effects }
        _ = reduce(.sessionReady(attempt: 1))
        _ = reduce(.submit(sent))
        // The answer to making the thread is lost; the shell shows it anyway.
        _ = reduce(.createAnswered(messageID: sent.messageID, attempt: 1, .unknown("lost")))
        let created = reduce(.threadObserved(thread))
        XCTAssertTrue(created.contains(.adopt(draft: sent.origin, thread: .thread(thread, appID: "app"), agentOf: nil)))
        let refused = reduce(.turnAnswered(messageID: sent.messageID, attempt: 1, .refused("no")))
        XCTAssertTrue(refused.contains(.settle(messageID: sent.messageID, .rejected(.thread(thread, appID: "app"), reason: "no"))))
        XCTAssertTrue(refused.contains(.restoreField(.thread(thread, appID: "app"), sent)))
        XCTAssertTrue(s.entries.isEmpty)
    }

    /// Recordings uploading when the app died are prepared again on
    /// relaunch; nothing of a message that never left counts as sent.
    func testPreparingMessageRestartsItsUploadsAfterRelaunch() {
        let recording = Delivery.Recording(id: "r", kind: "video", path: "/tmp/r.mp4", label: "0:01", thumbnail: Data())
        let sent = intent(.thread("t"), origin: .thread("t", appID: "app"), recordings: [recording])
        let restored = Delivery.reduce(Delivery.State(), .restore([.init(intent: sent, stage: .preparing)]))
        XCTAssertEqual(restored.effects, [.prepare(sent)])
        XCTAssertEqual(restored.state.entries[sent.messageID]?.uncertain, false)
        // A failed upload before anything was sent gives the field back.
        let failed = Delivery.reduce(restored.state, .prepareFailed(messageID: sent.messageID, reason: "gone"))
        XCTAssertTrue(failed.effects.contains(.restoreField(sent.origin, sent)))
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
        _ = reduce(.answered(id: edit.id, attempt: 0, .accepted(.number(5))))
        XCTAssertEqual(s.taskEdits.count, 1, "held until the list has revision 5")
        _ = reduce(.tasksObserved([.init(id: "k", status: .done, revision: 4)]))
        XCTAssertEqual(s.taskEdits.count, 1)
        _ = reduce(.tasksObserved([.init(id: "k", status: .done, revision: 5)]))
        XCTAssertTrue(s.taskEdits.isEmpty)
    }

    /// Only a typed T3 failure is a refusal; an InternalError (a defect, an
    /// interruption while T3 shuts down) may have run.
    func testT3OutcomeDecoding() {
        func exit(_ value: [String: Any]) -> JSONValue { .from(value) }
        XCTAssertEqual(CommandOutcome.t3(exit: exit(["_tag": "Success", "value": ["sequence": 4]])), .accepted(.from(["sequence": 4])))
        guard case .refused = CommandOutcome.t3(exit: exit(["_tag": "Success", "value": ["status": "rejected"]])) else { return XCTFail() }
        guard case .refused = CommandOutcome.t3(exit: exit(["_tag": "Failure", "cause": [["_tag": "Fail", "error": ["_tag": "OrchestrationCommandPreviouslyRejectedError"]]]])) else { return XCTFail() }
        guard case .unknown = CommandOutcome.t3(exit: exit(["_tag": "Failure", "cause": [["_tag": "Fail", "error": ["_tag": "InternalError"]]]])) else { return XCTFail() }
        guard case .unknown = CommandOutcome.t3(exit: exit(["_tag": "Failure", "cause": ["_tag": "Die", "defect": "boom"]])) else { return XCTFail() }
        guard case .unknown = CommandOutcome.service(ClientError.connection("Squircle")) else { return XCTFail() }
        guard case .unknown = CommandOutcome.service(ClientError.backend("Squircle", 503, "busy")) else { return XCTFail() }
        guard case .refused = CommandOutcome.service(ClientError.backend("Squircle", 404, "gone")) else { return XCTFail() }
    }
}

/// A command dispatch that answers each command when the test says.
@MainActor
private final class HeldT3 {
    private(set) var commands: [JSONValue] = []
    private var waiting: [CheckedContinuation<Void, Error>] = []
    var dispatch: (JSONValue) async throws -> JSONValue {
        { [unowned self] command in
            commands.append(command)
            try await withCheckedThrowingContinuation { waiting.append($0) }
            return .object([:])
        }
    }
    func answer() { waiting.removeFirst().resume() }
    func until(_ count: Int) async { while commands.count < count { await Task.yield() } }
}

final class PendingJournalTests: XCTestCase {
    private let config = JSONValue.from(["providers":[["instanceId":"codex","displayName":"Codex","enabled":true,"status":"ready",
                                                        "models":[["slug":"sol","name":"Sol","isDefault":true]]]]])
    private let project = AppProject(id: "app", name: "App", subtitle: "", bundleID: nil, canBuild: false, updatedAt: .now)

    /// Killed while T3 hasn't answered: the next run sends the very same
    /// command (IDs, text, pictures) once, and forgets it once T3 has it.
    @MainActor
    func testUnansweredSendIsResentAsItselfAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func launch(_ t3: HeldT3) async -> SquircleModel {
            let model = SquircleModel(configuration: nil, preferences: UserDefaults(suiteName: UUID().uuidString)!,
                                      commandDispatch: t3.dispatch, journal: PendingJournal(directory: root))
            model.consumeConfig(config)
            return model
        }
        let first = HeldT3()
        let before = await launch(first)
        let thread = ConversationID.thread("t", appID: project.id)
        await before.open(thread)
        before.consumeThread(.from(["kind":"snapshot","snapshot":["snapshotSequence":1,"thread":["id":"t","messages":[["id":"m0","role":"user","text":"earlier sim start --thread t"]],
                                    "modelSelection":["instanceId":"codex","model":"sol"]]]]))
        before.attach(ImageAttachment(UIImage(systemName: "star")!, id: "picture")!)
        guard case .started = before.startSend("hello", in: project, from: thread) else { return XCTFail("refused") }
        await first.until(1)
        before.close() // the app is killed; T3 never answered

        let second = HeldT3()
        let after = await launch(second)
        await second.until(1)
        XCTAssertEqual(second.commands, first.commands, "the same command, byte for byte")
        await after.open(thread)
        XCTAssertEqual(after.pendingSend(for: thread)?.phase, .awaitingAcceptance)
        XCTAssertEqual(after.pendingSend(for: thread)?.images, 1)
        second.answer()
        while after.pendingSend(for: thread)?.phase == .awaitingAcceptance { await Task.yield() }
        // Forgotten on disk: a third run sends nothing.
        var left: [String] = []
        for _ in 0..<200 { left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []; if left.isEmpty { break }; await Task.yield() }
        XCTAssertEqual(left, [])
        let third = HeldT3()
        _ = await launch(third)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(third.commands.isEmpty)
        after.close()
    }

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
