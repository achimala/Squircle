import XCTest
@testable import Squircle

/// Command lines as agents actually write them.
final class SquircleActionTests: XCTestCase {
    private let cli = "cd /Users/me/RemoteAppDev && target/release/squircle --data-dir .squircle --server http://127.0.0.1:8787"
    private let worker = "0cb24ec7-8423-40f3-a23e-d36e5f38807d"

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

    func testTrackerChangesInTheShapesAgentsWrite() {
        let item = "36aec36a-4771-4163-915d-6be56bd9b08c", old = "a22a444e-7a41-4ef5-bf7e-0753d9a4de5a"
        let array = "cd /Users/me/RemoteAppDev; A=('/Users/me/Library/Application Support/dev.squircle.service/squircle' --data-dir .squircle --server http://127.0.0.1:8787); T=\(worker)\n"
        // A captured reply, then commands that read their IDs from shell variables.
        let command = array + "S=$(\"${A[@]}\" task sub add \(item) --thread $T --ask \"Just make it a tab\" | python3 -I -c \"import json\"); echo $S\n"
            + "\"${A[@]}\" task update \(item.uppercased()) --status ready_to_try --note \"Merged; build coming\" | grep -m1 '\"ok\"'\n"
            + "\"${A[@]}\" task sub add \(item) --thread $T --replaces \(old) --ask 'Questions inline'\n"
            + "\"${A[@]}\" task update $S --replaced-by \(item)\n"
            + "\"${A[@]}\" task ask \(item) --thread $T --question \"Have a key already?\" --option Yes --option No"
        let actions = SquircleAction.parse(command: command, result: "1\n")
        XCTAssertEqual(actions.map(\.kind), [.taskAdd, .taskStatus("ready_to_try"), .taskAdd, .taskReplace, .taskAsk])
        XCTAssertEqual(actions[0].text, "Just make it a tab")
        XCTAssertEqual(actions[1].task, item)
        XCTAssertEqual(actions[1].note, "Merged; build coming")
        XCTAssertEqual(actions[2].replaces, [old])
        XCTAssertNil(actions[3].task)
        XCTAssertEqual(actions[4].text, "Have a key already?")
        let asks = [item: "Waiting on you, in one place", old: "Separate sheet"]
        XCTAssertEqual(actions[1].phrase { asks[$0] }.map(\.text), ["Marked", "“Waiting on you, in one place”", "ready to try", "· Merged; build coming"])
        XCTAssertEqual(actions[2].phrase { asks[$0] }.map(\.text), ["Replaced", "“Separate sheet”", "with", "“Questions inline”"])
        // An ID only the shell knows reads as "a task", never as `$S`.
        XCTAssertEqual(actions[3].phrase { asks[$0] }.map(\.text), ["Replaced", "a task", "with", "“Waiting on you, in one place”"])
        XCTAssertTrue(actions.allSatisfy(\.visible))
    }

    func testPathAndOptionArrayLoopsAndNotes() {
        let cli = "S='/Users/me/Library/Application Support/dev.squircle.service/squircle'; A=(--data-dir /x/.squircle --server http://127.0.0.1:8787)\n"
        let loop = cli + "for o in 50164a02 641a544d d5007397; do \"$S\" \"${A[@]}\" task update $(full $o) --status dropped --note \"Stale\" 2>&1 | grep -q ok && n=$((n+1)); done; echo $n"
        let dropped = SquircleAction.parse(command: loop, result: "3\n")
        XCTAssertEqual(dropped.map(\.kind), [.taskStatus("dropped")])
        XCTAssertEqual(dropped[0].repeats, 3)
        XCTAssertEqual(dropped[0].phrase { _ in nil }.prefix(3).map(\.text), ["Marked", "3 tasks", "dropped"])

        let notes = cli + "\"$S\" \"${A[@]}\" notes edit 23 --thread \(worker) \"Folder spec lives in its task\" | head -1; \"$S\" \"${A[@]}\" --json task show \(worker)"
        let found = SquircleAction.parse(command: notes)
        XCTAssertEqual(found.map(\.kind), [.noteEdit, .taskLookup])
        XCTAssertEqual(found[0].text, "Folder spec lives in its task")
        XCTAssertEqual(found.map(\.visible), [true, false])

        // The bare form agents now use, with a merge around it.
        let merge = "git merge --no-ff x -m 'Merge x' && squircle task attach \(worker) --file /a/b.mov && squircle build start --scheme Squircle --task \(worker)"
        XCTAssertEqual(SquircleAction.parse(command: merge).map(\.kind), [.taskAttach(video: true), .buildStart(nil)])
        XCTAssertEqual(CommandLabel.besidesSquircle(merge), "Merging")
        XCTAssertNil(CommandLabel.besidesSquircle(cli + "\"$S\" \"${A[@]}\" thread read \(worker) | python3 -c 'import json'; git diff --stat main...x"))
    }
}
