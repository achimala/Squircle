import XCTest
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
