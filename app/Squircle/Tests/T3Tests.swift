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

    /// The socket drops before T3 answers: the message stays pending, never
    /// failed, and goes again on its own under the same command and message
    /// IDs (T3 answers a command it already took from its receipt) (B-N05).
    @MainActor
    func testLostAnswerIsAskedAgainAsTheSameCommand() async throws {
        let gate = GatedDispatch()
        let (model, _) = await draftWithPicture(gate)
        let thread = ConversationID.thread("t", appID: project.id)
        await model.open(thread)
        model.consumeThread(.from(["kind":"snapshot","snapshot":["snapshotSequence":1,"thread":["id":"t","messages":[],
                                   "modelSelection":["instanceId":"codex","model":"sol"]]]]))
        let sending = try start(model, "hello", from: thread)
        await gate.until(1); gate.release(lost: true)
        await gate.until(2)
        XCTAssertEqual(gate.commands[1]["commandId"], gate.commands[0]["commandId"])
        XCTAssertEqual(gate.commands[1]["message"]["messageId"], gate.commands[0]["message"]["messageId"])
        XCTAssertEqual(model.pendingSend(for: thread)?.phase, .awaitingAcceptance)
        XCTAssertNil(model.error)
        guard case .refused = model.startSend("again", in: project, from: thread) else { return XCTFail("One message at a time") }
        gate.release()
        guard case .accepted = await sending.value else { return XCTFail("T3 took it") }
        XCTAssertEqual(gate.commands.count, 2)
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
