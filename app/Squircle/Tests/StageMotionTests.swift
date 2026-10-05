import UIKit
import XCTest
@testable import Squircle

final class StageMotionTests: XCTestCase {
    private func layout(reduced: Bool = false) -> StageLayout {
        StageLayout(size: CGSize(width: 402, height: 874), safe: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
                    titleHeight: 41, reducedMotion: reduced)
    }

    func testHeroFillsTheSpaceAboveTheNameAndNeighborsFaceTheCenter() {
        let layout = layout()
        let hero = layout.homePose(offset: 0)
        XCTAssertGreaterThan(hero.height, layout.size.height * 0.55, "The device is the hero of Home.")
        XCTAssertGreaterThanOrEqual(hero.center.y - hero.height / 2, layout.heroTop - 0.001)
        XCTAssertLessThan(hero.center.y + hero.height / 2, layout.nameTop)
        XCTAssertLessThan(layout.nameTop + layout.titleHeight, layout.bottomBarTop, "The name clears the bottom controls.")
        XCTAssertGreaterThan(layout.homePose(offset: -1).yaw, hero.yaw, "The left neighbor turns right, toward the center.")
        XCTAssertLessThan(layout.homePose(offset: 1).yaw, hero.yaw)
        XCTAssertFalse(layout.homePose(offset: 2.5).visible, "Far devices are not rendered.")
    }

    func testDeviceGivesWayAsItsListScrollsUp() {
        let layout = layout()
        let hero = layout.homePose(offset: 0)
        let reading = layout.homePose(offset: 0, scroll: layout.expandedOffset, spread: 1)
        XCTAssertEqual(reading.height, layout.listPhoneHeight, accuracy: 0.5)
        XCTAssertEqual(layout.expansion(scroll: layout.expandedOffset), 1)
        var previous = hero.height
        for step in 1...20 {
            let pose = layout.homePose(offset: 0, scroll: layout.expandedOffset * CGFloat(step) / 20)
            XCTAssertLessThanOrEqual(pose.height, previous + 0.001, "Shrinks monotonically with the scroll.")
            XCTAssertLessThan(pose.center.y + pose.height / 2, layout.nameTop - layout.expandedOffset * CGFloat(step) / 20,
                              "Always stands above its name.")
            previous = pose.height
        }
        XCTAssertGreaterThan(layout.homePose(offset: 0, scroll: -80).height, hero.height, "Pulling down enlarges it slightly.")
        XCTAssertFalse(layout.homePose(offset: 0, scroll: 2000).visible, "A device scrolled away is not rendered.")
        // Neighbors stand a whole page apart once a list is being read.
        XCTAssertEqual(layout.homePose(offset: 1, spread: 1).center.x, layout.size.width * 1.5, accuracy: 0.001)
        XCTAssertLessThan(layout.homePose(offset: 1, spread: 0).center.x, layout.size.width * 1.2)
    }

    func testListRestsAtHeroOrReadingPosition() {
        let layout = layout(), expanded = layout.expandedOffset
        XCTAssertEqual(layout.restingOffset(current: 40, projected: 90, velocity: 0.6), expanded, "A flick up opens the list.")
        XCTAssertEqual(layout.restingOffset(current: expanded - 30, projected: expanded - 90, velocity: -0.6), 0, "A flick down returns the hero.")
        XCTAssertEqual(layout.restingOffset(current: expanded * 0.2, projected: expanded * 0.25, velocity: 0), 0)
        XCTAssertEqual(layout.restingOffset(current: expanded * 0.7, projected: expanded * 0.75, velocity: 0), expanded)
        XCTAssertEqual(layout.restingOffset(current: expanded + 200, projected: expanded + 900, velocity: 2), expanded + 900,
                       "Past the reading position the list scrolls freely.")
    }

    func testThreadDeviceFillsTheSpaceAboveTheDivider() {
        let layout = layout(), limit: CGFloat = 740
        let stops = (0...2).map { layout.divider(detent: CGFloat($0), limit: limit) }
        XCTAssertEqual(stops, [layout.chatDivider, layout.splitDivider, limit])
        for (index, stop) in stops.enumerated() {
            XCTAssertEqual(layout.detent(divider: stop, limit: limit), CGFloat(index), accuracy: 0.0001)
        }
        let docked = layout.threadPose(divider: stops[0])
        XCTAssertEqual(docked.height, StageLayout.dockHeight, accuracy: 0.5)
        XCTAssertGreaterThan(docked.center.x, layout.size.width * 0.8, "Docked beside the title.")
        let half = layout.threadPose(divider: stops[1]), full = layout.threadPose(divider: stops[2])
        XCTAssertEqual(half.height, layout.splitPhoneHeight, accuracy: 0.5)
        XCTAssertEqual(half.center.x, layout.size.width / 2, accuracy: 0.001)
        XCTAssertGreaterThan(full.height, half.height)
        XCTAssertEqual(full.yaw, 0, "Square to the viewer when large enough to use.")
        XCTAssertLessThanOrEqual(full.height * PhonePose.aspect, layout.size.width - 40 + 0.001)
        for y in stride(from: stops[0], through: stops[2], by: 20) {
            let pose = layout.threadPose(divider: y)
            XCTAssertLessThanOrEqual(pose.center.y + pose.height / 2, y, "Never crosses the divider.")
        }
        // A keyboard can leave less room than the half detent wants.
        XCTAssertEqual(layout.divider(detent: 2, limit: 300), layout.divider(detent: 1, limit: 300))
    }

    func testTransitionEndpointsMatchHomeAndThreadPoses() {
        let layout = layout()
        let home = layout.homePose(offset: 0), thread = layout.threadPose(divider: layout.chatDivider)
        XCTAssertEqual(layout.transitionPose(from: home, to: thread, progress: 0), home)
        let end = layout.transitionPose(from: home, to: thread, progress: 1)
        XCTAssertEqual(end.center.y, thread.center.y, accuracy: 0.001)
        XCTAssertEqual(end.height, thread.height, accuracy: 0.001)
        XCTAssertEqual(end.depth, 0, accuracy: 0.001, "The lift must vanish exactly at rest.")
        XCTAssertLessThan(layout.transitionPose(from: home, to: thread, progress: 0.5).depth, 0, "Mid-flight the device lifts toward the viewer.")
    }

    func testReducedMotionRemovesTurningRecedingAndLift() {
        let layout = layout(reduced: true)
        for offset in [-1.0, -0.4, 0, 0.6, 1] as [CGFloat] {
            let pose = layout.homePose(offset: offset)
            XCTAssertEqual(pose.yaw, 0)
            XCTAssertEqual(pose.depth, 0)
        }
        let home = layout.homePose(offset: 0), thread = layout.threadPose(divider: layout.splitDivider)
        XCTAssertEqual(thread.yaw, 0)
        XCTAssertEqual(layout.transitionPose(from: home, to: thread, progress: 0.5).depth, 0)
    }

    func testSpringSettlesWithoutOvershootingFarAndReversesFromVelocity() {
        var value: CGFloat = 0, velocity: CGFloat = 0, peak: CGFloat = 0
        for _ in 0..<120 {
            (value, velocity) = SpringDriver.step(value: value, velocity: velocity, target: 1, dt: 1.0 / 120, parameters: .navigation)
            peak = max(peak, value)
        }
        XCTAssertEqual(value, 1, accuracy: 0.002, "Settles within one second.")
        XCTAssertLessThan(peak, 1.03, "Restrained: at most a whisper of overshoot.")
        // A finger releasing toward Home with velocity keeps moving that way first.
        let (next, _) = SpringDriver.step(value: 0.6, velocity: -3, target: 0, dt: 1.0 / 60, parameters: .navigation)
        XCTAssertLessThan(next, 0.6)
    }

    @MainActor
    func testSpringDriverIsInterruptibleAndReportsRest() {
        let driver = SpringDriver(value: 0)
        var rested: [CGFloat] = []
        driver.onRest = { rested.append($0) }
        driver.animate(to: 1)
        XCTAssertTrue(driver.isAnimating)
        driver.set(0.4)
        XCTAssertFalse(driver.isAnimating, "A finger takes over immediately.")
        XCTAssertEqual(driver.value, 0.4)
        driver.animate(to: 0.4)
        XCTAssertEqual(rested, [0.4], "Animating to the current value settles at once.")
        let expectation = expectation(description: "rest")
        driver.onRest = { _ in expectation.fulfill() }
        driver.animate(to: 0)
        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(driver.value, 0)
    }

    func testPoseInterpolationIsLinearAndKeepsVisibility() {
        let a = PhonePose(center: .zero, height: 100, depth: 10, yaw: 0, shadow: 1, visible: false)
        let b = PhonePose(center: CGPoint(x: 10, y: 20), height: 200, depth: 0, yaw: 1, shadow: 0, visible: true)
        let mid = PhonePose.interpolate(a, b, 0.5)
        XCTAssertEqual(mid.center, CGPoint(x: 5, y: 10))
        XCTAssertEqual(mid.height, 150)
        XCTAssertEqual(mid.yaw, 0.5)
        XCTAssertTrue(mid.visible)
    }

    func testConversationGroupsToolStepsAndHidesBookkeeping() {
        var state = T3ThreadState()
        func tool(_ id: String, _ kind: String, call: String, status: String, at second: Int, detail: String) -> [String: Any] {
            ["id": id, "kind": kind, "tone": "tool", "summary": "Tool call", "createdAt": "2026-10-05T10:00:0\(second).000Z",
             "payload": ["itemType": "dynamic_tool_call", "toolCallId": call, "status": status, "detail": detail,
                         "data": ["toolName": String(detail.prefix { $0 != ":" })]]]
        }
        state.consume(.from(["kind": "snapshot", "snapshot": ["snapshotSequence": 1, "thread": [
            "session": ["status": "running"],
            "messages": [
                ["id": "u", "role": "user", "text": "Fix it", "createdAt": "2026-10-05T10:00:00.000Z"],
                ["id": "reasoning:summary:1", "role": "system", "text": "Looking at the layout", "createdAt": "2026-10-05T10:00:01.000Z"],
                ["id": "s", "role": "system", "text": "internal", "createdAt": "2026-10-05T10:00:01.500Z"]
            ],
            "activities": [
                tool("1", "tool.started", call: "a", status: "inProgress", at: 2, detail: "Read: {}"),
                tool("2", "tool.completed", call: "a", status: "completed", at: 3, detail: "Read: {\"file_path\":\"/work/app/Sources/Home.swift\"}"),
                tool("3", "tool.updated", call: "a", status: "inProgress", at: 4, detail: "Read: {\"file_path\":\"/work/app/Sources/Home.swift\"}"),
                tool("4", "tool.started", call: "b", status: "inProgress", at: 5, detail: "Grep: {\"pattern\":\"heroTop\"}"),
                ["id": "5", "kind": "context-window.updated", "createdAt": "2026-10-05T10:00:06.000Z", "payload": ["usedTokens": 10]],
                ["id": "6", "kind": "approval.requested", "createdAt": "2026-10-05T10:00:07.000Z", "payload": ["requestId": "r", "detail": "Bash: ls"]]
            ]
        ]]]))
        let messages = state.messages
        XCTAssertEqual(messages.map(\.role), ["user", "thinking", "tool", "tool"])
        XCTAssertEqual(messages[2].content, "Read Home.swift")
        XCTAssertFalse(messages[2].isStreaming, "A late update never reopens a completed step.")
        XCTAssertEqual(messages[3].content, "Searched for “heroTop”")
        XCTAssertTrue(messages[3].isStreaming)
        XCTAssertEqual(state.pendingRequests.count, 1)
        let items = ThreadItem.items(messages: messages, running: state.isRunning)
        XCTAssertEqual(items.map(\.id), ["u", "a", "live"], "The running step is the live line, not a row.")
        if case .step(_, let first, let last) = items[1] { XCTAssertTrue(first); XCTAssertTrue(last) } else { XCTFail() }
        XCTAssertEqual(items.last, .live(LiveStatus(headline: "Searched for “heroTop”", started: ThreadItem.date("2026-10-05T10:00:00.000Z"))))
    }

    func testFinishedTurnFoldsWorkKeepsScreenshotsAndAnswer() {
        func message(_ id: String, _ role: String, _ text: String, _ second: Int) -> ChatMessage {
            ChatMessage(id: id, role: role, content: text, createdAt: "2026-10-05T10:0\(second / 60):\(String(format: "%02d", second % 60)).000Z")
        }
        var shot = message("shot", "tool", "Looked at the simulator", 20)
        shot.imageCount = 1
        var edit = message("edit", "tool", "Edited Theme.swift", 30)
        edit.step = AgentStep(kind: .edit, title: "Edited Theme.swift", symbol: "pencil.line", added: 3, removed: 1,
                              diff: StepDiff(path: "/a/Theme.swift", old: "a", new: "b"))
        let messages = [message("u", "user", "Make it shine", 0), message("t", "thinking", "Plan", 5),
                        message("n", "assistant", "Looking at the screen.", 10), shot, edit,
                        message("answer", "assistant", "Done.", 95)]
        let folded = ThreadItem.items(messages: messages, running: false)
        XCTAssertEqual(folded.map(\.id), ["u", "summary:u", "gallery:u", "answer"])
        guard case .summary(let summary) = folded[1] else { return XCTFail() }
        XCTAssertEqual(summary.title, "Worked for 1m 35s")
        XCTAssertEqual(summary.detail, "2 steps · 1 file changed")
        let open = ThreadItem.items(messages: messages, running: false, expanded: ["u"])
        XCTAssertEqual(open.map(\.id), ["u", "summary:u", "t", "note:n", "shot", "gallery:shot", "edit", "answer"])
        let live = ThreadItem.items(messages: Array(messages.dropLast()), running: true)
        XCTAssertEqual(live.map(\.id), ["u", "note:n", "shot", "gallery:shot", "edit", "live"],
                       "While working the latest note leads its steps.")
    }

    func testStepsReadAsSentencesAndHideAppContext() {
        func activity(_ tool: String, _ input: [String: Any]) -> JSONValue {
            .from(["kind": "tool.completed", "payload": ["itemType": "dynamic_tool_call", "data": ["toolName": tool, "input": input]]])
        }
        XCTAssertEqual(AgentStep.describe(activity("Bash", ["command": "cd /x && make", "description": "build the app"])).title, "Build the app")
        XCTAssertEqual(AgentStep.describe(activity("Bash", ["command": "cd /x && make test"])).title, "make test")
        let edit = AgentStep.describe(activity("Edit", ["file_path": "/x/Theme.swift", "old_string": "a\nb", "new_string": "a\nc\nd"]))
        XCTAssertEqual(edit.title, "Edited Theme.swift")
        XCTAssertEqual([edit.added, edit.removed], [2, 1])
        XCTAssertEqual(AgentStep.describe(activity("mcp__t3-code__device_screenshot", [:])).title, "Looked at the simulator")
        XCTAssertTrue(AgentStep.describe(activity("ToolSearch", ["query": "x"])).hidden)
        XCTAssertEqual(AgentStep.humanCommand("/bin/zsh -lc 'cd /x && git status'"), "git status")
        XCTAssertEqual(T3ThreadState.spoken("Fix it" + AppProject.contextMarker + "Squircle. Keep work…"), "Fix it")
        XCTAssertEqual(StepDetailViewController.lineDiff(["a", "b"], ["a", "c"]), [.same("a"), .added("c"), .removed("b")])
    }

    func testAmbientColorComesFromSaturatedPixelsOnly() {
        func image(_ fill: UIColor, accent: UIColor?) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 60, height: 120)).image { context in
                fill.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
                if let accent { accent.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 40)) }
            }
        }
        XCTAssertNil(Theme.characteristicColor(of: image(.white, accent: .darkGray)), "Monochrome captures keep the neutral light.")
        var hue: CGFloat = 0, saturation: CGFloat = 0
        let color = Theme.characteristicColor(of: image(.white, accent: UIColor(red: 1, green: 0.45, blue: 0, alpha: 1)))
        XCTAssertNotNil(color)
        color?.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
        XCTAssertEqual(hue, 0.075, accuracy: 0.03)
        XCTAssertGreaterThan(saturation, 0.8, "White around the accent does not dilute it.")
    }
}
