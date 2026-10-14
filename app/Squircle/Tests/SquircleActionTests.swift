import XCTest
@testable import Squircle

/// Command lines as agents actually write them.
final class SquircleActionTests: XCTestCase {
    private let cli = "cd /Users/me/RemoteAppDev && target/release/squircle --data-dir .squircle --server http://127.0.0.1:8787"
    private let worker = "0cb24ec7-8423-40f3-a23e-d36e5f38807d"

    func testSpawnReadsTitleBranchPromptAndTruncatedOutput() {
        let command = cli + #" thread spawn --coordinator ee706a81-71a5-48ce-9cc1-c9da511a96e4 --title "Stray pulse on send" --branch send-pulse-fix --prompt "Fix the \"pulse\".\nIt's on send." | head -4"#
        let actions = SquircleAction.parse(command: command, result: "{\n  \"data\": {\n    \"base\": \"main\",\n    \"branch\": \"send-pulse-fix\",")
        XCTAssertEqual(actions, [SquircleAction(kind: .spawn(nil), title: "Stray pulse on send", branch: "send-pulse-fix", text: "Fix the \"pulse\".\\nIt's on send.", outcome: .succeeded)])
        let refused = SquircleAction.parse(command: command, result: "{\n  \"error\": {\n    \"code\": \"agent_failed\",")
        XCTAssertEqual(refused.first?.visible, false)
        let full = SquircleAction.parse(command: command, result: #"{"data":{"id":"\#(worker)","title":"Stray pulse on send"}}"#)
        XCTAssertEqual(full.first?.worker?.raw, worker)
    }

    func testSendWithHeredocQuotesAndContinuations() {
        let command = cli + " thread send \(worker.uppercased()) \"$(cat <<'EOF'\nUser says: 'close, but'\n\n- make it \"shorter\"\nEOF\n)\" 2>&1 | tail -2"
        let actions = SquircleAction.parse(command: command)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].kind, .send(WorkerID(worker)))
        XCTAssertEqual(actions[0].text, "User says: 'close, but'\n\n- make it \"shorter\"")

        let single = SquircleAction.parse(command: cli + " \\\n  thread answer \(worker) 'Use the '\\''blue'\\'' one'")
        XCTAssertEqual(single.first?.kind, .answer(WorkerID(worker)))
        XCTAssertEqual(single.first?.text, "Use the 'blue' one")
    }

    func testSeveralCommandsShellFunctionsAndVariables() {
        let function = "cd /x && S() { target/release/squircle --data-dir .squircle \"$@\"; }; S thread read \(worker) | python3 -c \"import json; print('squircle')\"; S thread archive \(worker)"
        XCTAssertEqual(SquircleAction.parse(command: function).map(\.kind), [.read(WorkerID(worker)), .archive(WorkerID(worker))])

        let variable = "S=\"/x/target/release/squircle --data-dir /x/.squircle\"; $S sim start --thread \(worker) | grep state\n$S build start --project /a/LanguageApp.xcodeproj --scheme LanguageApp --export"
        // Filtered output of two commands can't say whose ID it is.
        let actions = SquircleAction.parse(command: variable, result: "6268db78-1cc2-4d64-a1f6-cbcdd308ed65\nTrue")
        XCTAssertEqual(actions.map(\.kind), [.simStart, .buildStart(nil)])
        XCTAssertEqual(actions[1].app, "LanguageApp")
        XCTAssertEqual(actions[1].outcome, .unattributed)
        let alone = SquircleAction.parse(command: cli + " build start --scheme LanguageApp | jq -r .data.id", result: "6268db78-1cc2-4d64-a1f6-cbcdd308ed65\n")
        XCTAssertEqual(alone.first?.build?.raw, "6268db78-1cc2-4d64-a1f6-cbcdd308ed65")
    }

    func testEachCommandTakesOnlyItsOwnReply() {
        let second = "5d7e3a52-0b8a-4c51-9a0f-2f4cbe0f6a11", build = "6268db78-1cc2-4d64-a1f6-cbcdd308ed65"
        let command = cli + " thread spawn --title One --branch one --prompt a; " + cli + " thread spawn --title Two --branch two --prompt b; " + cli + " build start --scheme X"
        let replies = #"{"data":{"coordinator":"ee706a81-71a5-48ce-9cc1-c9da511a96e4","id":"\#(worker)","title":"One"},"ok":true}"#
            + "\n" + #"{"error":{"code":"agent_failed","message":"no {brace}"},"ok":false}"# + "\n"
            + #"{"data":{"id":"\#(build)"},"ok":true}"#
        let actions = SquircleAction.parse(command: command, result: replies)
        XCTAssertEqual(actions.map(\.kind), [.spawn(WorkerID(worker)), .spawn(nil), .buildStart(BuildID(build))])
        XCTAssertEqual(actions.map(\.outcome), [.succeeded, .refused, .succeeded])

        let both = #"{"data":{"id":"\#(worker)"}}"# + "\n" + #"{"data":{"id":"\#(second)"}}"#
        let spawns = SquircleAction.parse(command: cli + " thread spawn --title One; " + cli + " thread spawn --title Two", result: both)
        XCTAssertEqual(spawns.map(\.worker?.raw), [worker, second])
        // Text between replies that names an ID breaks the pairing: nobody gets one.
        let mixed = SquircleAction.parse(command: cli + " thread spawn --title One; echo \(second); " + cli + " thread spawn --title Two",
                                         result: #"{"data":{"id":"\#(worker)"}}"# + "\n\(second)\n")
        XCTAssertEqual(mixed.map(\.worker), [nil, nil])
        XCTAssertEqual(mixed.map(\.outcome), [.unattributed, .unattributed])
    }

    func testLookupsAndHelpFoldAndOtherMentionsAreIgnored() {
        XCTAssertEqual(SquircleAction.parse(command: cli + " thread --help").map(\.kind), [.help])
        XCTAssertEqual(SquircleAction.parse(command: cli + " build status abc").first?.visible, false)
        XCTAssertEqual(SquircleAction.parse(command: cli + " thread cleanup --coordinator \(worker) --dry-run").first?.kind, .status)
        XCTAssertTrue(SquircleAction.parse(command: "grep -rn squircle src # thread spawn").isEmpty)
        XCTAssertTrue(SquircleAction.parse(command: "cat <<EOF > notes.md\nsquircle thread spawn --title x\nEOF\necho done").isEmpty)
        XCTAssertTrue(SquircleAction.parse(command: "xcrun simctl launch $U ai.dreamslate.Squircle").isEmpty)
    }
}
