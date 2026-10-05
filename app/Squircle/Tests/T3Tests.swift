import XCTest
@testable import Squircle

final class T3Tests: XCTestCase {
    @MainActor
    func testProviderChoiceSurvivesActivityReconnectAndThreadNavigation() async {
        let model = SquircleModel(configuration:nil)
        let codex = JSONValue.from(["instanceId":"codex","model":"gpt-6.1-sol"])
        let claude = JSONValue.from(["instanceId":"claudeAgent","model":"claude-fable-5-1"])
        func snapshot(_ selection:JSONValue, sequence:Int) -> JSONValue {
            .from(["kind":"snapshot","snapshot":["snapshotSequence":sequence,"thread":["modelSelection":selection.foundation]]])
        }
        await model.selectSession("first")
        model.consumeThread(snapshot(codex,sequence:1))
        model.chooseModel(claude)
        model.consumeThread(.from(["kind":"event","event":["sequence":2,"type":"thread.session-set","payload":["session":["status":"ready"]]]]))
        XCTAssertEqual(model.modelSelection,claude)
        model.consumeThread(snapshot(codex,sequence:3))
        XCTAssertEqual(model.modelSelection,claude)
        await model.selectSession("second")
        model.consumeThread(snapshot(codex,sequence:4))
        XCTAssertEqual(model.modelSelection,codex)
        await model.selectSession("first")
        model.consumeThread(snapshot(codex,sequence:5))
        XCTAssertEqual(model.modelSelection,claude)
        model.consumeThread(snapshot(claude,sequence:6))
        // After T3 acknowledges the choice, future server changes are authoritative.
        model.consumeThread(snapshot(codex,sequence:7))
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
    func testSimulatorTargetRejectsMissingOrInvalidIdentity() {
        XCTAssertNil(SimulatorTarget(deviceID:nil,hostID:"local"))
        XCTAssertNil(SimulatorTarget(deviceID:"",hostID:"local"))
        XCTAssertNil(SimulatorTarget(deviceID:UUID().uuidString,hostID:""))
        XCTAssertNotNil(SimulatorTarget(deviceID:UUID().uuidString,hostID:"local"))
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
    func testConfigurationRejectsCredentialOriginTricks() throws {
        let valid: [String:Any] = ["t3_url":"https://mac.example","t3_token":"token","squircle_url":"https://mac.example:8443","squircle_token":"build","diagnostic_token":"diagnostic"]
        XCTAssertNoThrow(try JSONDecoder().decode(AppConfiguration.self,from:JSONSerialization.data(withJSONObject:valid)))
        for url in ["http://mac.example","https://user:password@mac.example","https://mac.example/path","https://mac.example?credential=x"] {
            var bad = valid; bad["t3_url"] = url
            XCTAssertThrowsError(try JSONDecoder().decode(AppConfiguration.self,from:JSONSerialization.data(withJSONObject:bad)))
        }
    }
}

@MainActor
final class T3LiveTests: XCTestCase {
    private func gateway() async throws -> T3Gateway {
        let config = try AppConfiguration.load()
        let gateway = T3Gateway(configuration:config); try await gateway.connect(); return gateway
    }
    func testLiveNativeSubscriptions() async throws {
        let g = try await gateway(); defer { g.disconnect() }
        let config = try await g.call("server.getConfig")
        XCTAssertEqual(config["environment"]["serverVersion"].string,"0.0.45")
        XCTAssertTrue(config["providers"].array.contains { $0["instanceId"].string == "codex" && $0["status"].string == "ready" })
        let snapshot = expectation(description:"Authoritative T3 snapshot")
        try await g.subscribe("orchestration.subscribeShell") { if $0["kind"].string == "snapshot" { snapshot.fulfill() } }
        await fulfillment(of:[snapshot],timeout:20)
        let device = try await g.call("device.list")
        XCTAssertEqual(device["hubBasePath"].string,"/api/device-hub")
    }
    func testCodexRoundTrip() async throws { try await roundTrip(instance:"codex",model:"gpt-6.1-sol") }
    func testClaudeRoundTrip() async throws { try await roundTrip(instance:"claudeAgent",model:"claude-fable-5-1") }
    private func roundTrip(instance:String,model:String) async throws {
        let g = try await gateway(); defer { g.disconnect() }
        let root = "/Users/anshu/Documents/ChatGPT/RemoteAppDev"
        let shell = try await g.http.json("/api/orchestration/shell")
        var project = shell["projects"].array.first { $0["workspaceRoot"].string == root }?["id"].string
        func dispatch(_ command:[String:Any]) async throws {
            var c = command; c["commandId"] = UUID().uuidString.lowercased(); c["createdAt"] = ISO8601DateFormatter().string(from:.now)
            _ = try await g.call("orchestration.dispatchCommand",.from(c))
        }
        if project == nil {
            project = UUID().uuidString.lowercased()
            try await dispatch(["type":"project.create","projectId":project!,"title":"Squircle","workspaceRoot":root])
        }
        let thread = UUID().uuidString.lowercased(), marker = "SQUIRCLE_T3_" + UUID().uuidString.prefix(8)
        try await dispatch(["type":"thread.create","threadId":thread,"projectId":project!,"title":"Native \(instance) verification",
            "modelSelection":["instanceId":instance,"model":model],"runtimeMode":"full-access","interactionMode":"default","branch":NSNull(),"worktreePath":NSNull()])
        let complete = expectation(description:"Native agent reply and tool events")
        var state = T3ThreadState(); var fulfilled = false
        try await g.subscribe("orchestration.subscribeThread",.from(["threadId":thread])) { item in
            state.consume(item)
            let reply = state.messages.contains { $0.role == "assistant" && $0.content.contains(marker) && !$0.isStreaming }
            let tool = state.messages.contains { $0.role == "tool" && $0.activity?.hasPrefix("tool.") == true }
            if let error = state.thread["session"]["lastError"].string, !fulfilled {
                fulfilled = true; XCTFail(error); complete.fulfill()
            } else if reply && tool && !fulfilled { fulfilled = true; complete.fulfill() }
        }
        try await dispatch(["type":"thread.turn.start","threadId":thread,"message":["messageId":UUID().uuidString.lowercased(),"role":"user","text":"Verification only. Run pwd once, then reply exactly \(marker). Do not edit files or do other work.","attachments":[]],"modelSelection":["instanceId":instance,"model":model],"runtimeMode":"full-access","interactionMode":"default"])
        await fulfillment(of:[complete],timeout:120)
        print("T3 native verification: \(instance), thread \(thread), \(state.messages.count) messages/activity rows")
        XCTAssertTrue(fulfilled)
        let stored = try await g.http.json("/api/orchestration/threads/\(thread)")
        XCTAssertTrue(stored["thread"]["messages"].array.contains { $0["role"].string == "assistant" && $0["text"].string?.contains(marker) == true })
    }
    func testNativeSimulatorFrame() async throws {
        try await simulatorFrames(required:1)
    }
    func testContinuousNativeSimulatorFrames() async throws {
        guard ProcessInfo.processInfo.environment["SQUIRCLE_VERIFY_STREAM_MOTION"] == "1" else {
            throw XCTSkip("Requires an unlocked Mac and a changing simulator surface")
        }
        try await simulatorFrames(required:180,deviceID:"DFDF12FB-5C70-4B39-B85C-D5D82D6AB5F7")
    }
    private func simulatorFrames(required: Int,deviceID:String = "C800634B-1469-491D-9477-9BF9A883EEF7") async throws {
        let g = try await gateway(); defer { g.disconnect() }
        let shell = try await g.http.json("/api/orchestration/shell")
        let thread = shell["threads"].array.first { $0["title"].string == "Native codex verification" }?["id"].string
        guard let thread else { throw XCTSkip("Run the Codex round trip first") }
        _ = try await g.call("device.open",.from(["threadId":thread,"hostId":"local","deviceId":deviceID,"platform":"ios","boot":true]))
        let rendered = expectation(description:"Native simulator: \(required) rendered frame(s)")
        let stream = T3DeviceStream(http:g.http,base:"/api/device-hub",target:SimulatorTarget(deviceID:deviceID,hostID:"local")!)
        XCTAssertEqual(stream.codec,"h264")
        defer { stream.stop() }
        let interactive = expectation(description:"Simulator input screen handshake")
        var inputReady = false
        stream.onInteractive = { ready in if ready && !inputReady { inputReady = true; interactive.fulfill() } }
        var received = false; var count = 0, changes = 0
        var previousSignature: UInt64?
        stream.onFrame = { buffer in
            count += 1
            if required > 1 {
                CVPixelBufferLockBaseAddress(buffer,.readOnly)
                if let pixels = CVPixelBufferGetBaseAddressOfPlane(buffer,0)?.assumingMemoryBound(to:UInt8.self) {
                    let width = CVPixelBufferGetWidthOfPlane(buffer,0), height = CVPixelBufferGetHeightOfPlane(buffer,0)
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
                    var signature: UInt64 = 0
                    for y in 1..<16 { for x in 1..<16 { signature = signature &* 31 &+ UInt64(pixels[(height*y/16)*stride + width*x/16]) } }
                    if let previousSignature, signature != previousSignature { changes += 1 }
                    previousSignature = signature
                }
                CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
            }
            if count == required {
                received = true; XCTAssertGreaterThan(CVPixelBufferGetWidth(buffer),300)
                if required > 1 { XCTAssertGreaterThan(changes,10,"Decoded pictures must actually change") }
                print("Native simulator: \(stream.codec), \(count) frame(s), \(changes) changed pictures"); rendered.fulfill()
            }
        }
        stream.onStatus = { if let status = $0 { print("T3 simulator: \(status)") } }
        stream.start(); await fulfillment(of:[rendered,interactive],timeout:60)
        XCTAssertTrue(received); XCTAssertTrue(stream.isInteractive)
    }
    func testRepeatedSimulatorLifecycleAndInputRecovery() async throws {
        let g = try await gateway(); defer { g.disconnect() }
        let target = SimulatorTarget(deviceID:"C800634B-1469-491D-9477-9BF9A883EEF7",hostID:"local")!
        let stream = T3DeviceStream(http:g.http,base:"/api/device-hub",target:target)
        defer { stream.stop() }
        for cycle in 0..<6 {
            let ready = expectation(description:"Interactive simulator cycle \(cycle)")
            var fulfilled = false
            stream.onInteractive = { if $0 && !fulfilled { fulfilled = true; ready.fulfill() } }
            stream.start(); stream.start() // duplicate reconciliation must be harmless
            await fulfillment(of:[ready],timeout:30)
            XCTAssertTrue(stream.isInteractive)
            if cycle == 0 {
                var stayedInteractive = true
                stream.onInteractive = { if !$0 { stayedInteractive = false } }
                try await Task.sleep(for:.seconds(31))
                XCTAssertTrue(stayedInteractive,"A quiet surface must survive idle HTTP and socket intervals")
                XCTAssertTrue(stream.isInteractive)
            }
            let recovering = expectation(description:"Lost input disables interaction")
            let restored = expectation(description:"Fresh video and input restored")
            var lost = false; var recovered = false
            stream.onInteractive = { active in
                if !active && !lost { lost = true; recovering.fulfill() }
                if active && lost && !recovered { recovered = true; restored.fulfill() }
            }
            stream.disconnectInputForTesting()
            await fulfillment(of:[recovering,restored],timeout:30)
            XCTAssertTrue(stream.isInteractive)
            stream.stop(); XCTAssertFalse(stream.isInteractive)
        }
        // Cancel startup immediately, then reopen the same object. Old callbacks
        // cannot enable input or replace frames in the fresh lifetime.
        stream.onInteractive = nil
        stream.start(); stream.stop(); stream.start(); stream.stop()
        let final = expectation(description:"Restored after cancelled startup")
        var ready = false
        stream.onInteractive = { if $0 && !ready { ready = true; final.fulfill() } }
        stream.start(); await fulfillment(of:[final],timeout:30)
        XCTAssertTrue(stream.isInteractive)
    }
}
