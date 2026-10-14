import XCTest
import UIKit
@testable import Squircle

final class T3Tests: XCTestCase {
    @MainActor
    func testRejectedApprovalModeChangeRestoresSelection() async {
        let model = SquircleModel(configuration:nil)
        await model.selectSession("existing")
        model.consumeThread(.from(["kind":"snapshot","snapshot":["snapshotSequence":1,"thread":["runtimeMode":"approval-required"]]]))
        await model.setRuntimeMode(.fullAccess)
        XCTAssertEqual(model.runtimeMode, .approvalRequired)
        XCTAssertNotNil(model.error)
        await model.beginDraft()
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
        await model.selectSession("first")
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
        await model.selectSession("second")
        model.consumeThread(snapshot(claude,sequence:3))
        XCTAssertEqual(model.availableModelSelections,[claude])
        await model.selectSession("first")
        model.consumeThread(snapshot(codex,sequence:4))
        XCTAssertEqual(model.modelSelection,astra)
        model.consumeThread(snapshot(astra,sequence:5))
        model.consumeThread(snapshot(codex,sequence:6))
        XCTAssertEqual(model.modelSelection,codex)
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
    /// After a reconnect T3 resends a snapshot and may replay events the
    /// thread already has; neither may lose or duplicate the transcript.
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
    func release(failing: Bool = false) {
        let next = waiting.removeFirst()
        if failing { next.resume(throwing: ClientError.backend("T3", 0, "refused")) } else { next.resume() }
    }
    func until(_ count: Int) async { while commands.count < count { await Task.yield() } }
}

final class NativeStateTests: XCTestCase {
    private let config = JSONValue.from(["providers":[["instanceId":"codex","displayName":"Codex","enabled":true,"status":"ready",
                                                        "models":[["slug":"sol","name":"Sol","isDefault":true]]]]])
    private let project = AppProject(id: "app", name: "App", subtitle: "", bundleID: nil, canBuild: false, updatedAt: .now)

    @MainActor
    private func draftWithPicture(_ gate: GatedDispatch) async -> SquircleModel {
        let model = SquircleModel(configuration: nil, preferences: UserDefaults(suiteName: UUID().uuidString)!, commandDispatch: gate.dispatch)
        model.consumeConfig(config)
        model.selectProject(project)
        await model.beginDraft()
        model.attach(ImageAttachment(UIImage(systemName: "star")!, id: "picture")!)
        return model
    }

    /// Navigating away while a draft's thread is being created: the message
    /// still goes to the thread that draft created, and selection stays put.
    @MainActor
    func testDraftSendStaysWithItsThreadAcrossNavigation() async throws {
        let gate = GatedDispatch()
        let model = await draftWithPicture(gate)
        let sending = Task { await model.send("hello", in: project, to: nil, agent: false) }
        await gate.until(1)
        let created = try XCTUnwrap(gate.commands[0]["threadId"].string)
        await model.selectSession("other")
        gate.release()
        await gate.until(2)
        XCTAssertEqual(gate.commands[1]["type"].string, "thread.turn.start")
        XCTAssertEqual(gate.commands[1]["threadId"].string, created)
        gate.release()
        let outcome = await sending.value
        XCTAssertEqual(outcome, .sent(threadID: created))
        XCTAssertEqual(model.selectedSessionID, "other")
        XCTAssertTrue(model.attachments.isEmpty)
    }

    /// A failed send puts its pictures back in the conversation that sent
    /// them, not the one open now.
    @MainActor
    func testFailedSendRestoresPicturesToItsOwnConversation() async throws {
        let gate = GatedDispatch()
        let model = await draftWithPicture(gate)
        let sending = Task { await model.send("hello", in: project, to: nil, agent: false) }
        await gate.until(1)
        await model.selectSession("other")
        gate.release(failing: true)
        guard case .failed = await sending.value else { return XCTFail("Expected failure") }
        XCTAssertTrue(model.attachments.isEmpty, "The open thread's field stays empty")
        XCTAssertNil(model.error, "The error belongs to the conversation that sent")
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

    @MainActor
    func testEvictedDownloadsAreDeletedButHandedFilesAreNot() throws {
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data([1]).write(to: mine)
        defer { try? FileManager.default.removeItem(at: mine) }
        StepVideos.set(mine, for: "mine")
        let download = StepVideos.directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data([1]).write(to: download)
        StepVideos.set(download, for: "download")
        StepVideos.removeAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
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
