import Foundation
import Synchronization

/// A finished turn's work, folded into one line.
struct TurnSummary: Equatable {
    let turn: String
    let duration: TimeInterval?
    let steps: Int
    let files: Int
    let added: Int
    let removed: Int
    /// Tracker and note changes folded in with the steps.
    var tasks = 0
    var notes = 0
    let failed: Bool
    let expanded: Bool

    var title: String {
        guard let duration, duration >= 1 else { return "Worked" }
        return "Worked for " + Elapsed.words(duration)
    }
    var detail: String {
        var parts = ["\(steps) step\(steps == 1 ? "" : "s")"]
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s") changed") }
        if tasks > 0 { parts.append("\(tasks) task\(tasks == 1 ? "" : "s")") }
        if notes > 0 { parts.append("\(notes) note\(notes == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// How long something took or has been running.
enum Elapsed {
    /// "45s", "1m 5s", "2m", "1h 15m".
    static func words(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
    /// "0:07", "12:34", "1:15:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        return Duration.seconds(whole).formatted(.time(pattern: whole < 3600 ? .minuteSecond : .hourMinuteSecond))
    }
}

/// One screenshot a step returned.
struct Shot: Equatable {
    let step: String
    let index: Int
    let title: String
    var video = false
    /// T3's ID for an image you sent.
    var attachment: String?
    /// A file on the Mac the agent's Markdown shows, read through T3.
    var path: String?
    /// Where its pixel size is kept (`MediaFiles.sizes`): a file by its
    /// path, a step's or message's picture by its place.
    var sizeKey: String { path != nil ? step : "\(step)#\(index)" }
}

/// What the agent is doing this moment.
struct LiveStatus: Equatable {
    let headline: String
    let started: Date?
}

/// A Squircle action or a worker's news, on a line of its own. Actions fold
/// with the turn's other steps; news stays in view. The conversation fills in the worker's name and
/// live state.
struct ActionLine: Equatable {
    enum Kind: Equatable {
        case action(SquircleAction)
        /// A worker finished, stopped or needs you.
        case news(WorkerState)
        /// Squircle telling the agent one of its builds finished.
        case build(BuildNews)
    }
    let id: String
    let kind: Kind
    /// The worker it is about, when its own command or Squircle's news names it.
    var thread: WorkerID?
    /// The worker's title as the agent or Squircle named it.
    var title: String?
    var running = false
    var failed = false
    /// Resolved by the conversation.
    var name: String?
    var state: WorkerState?
    /// For a build it started: where that build stands ("running", "succeeded", …).
    var buildStatus: String?
    /// The asks of the tasks a tracker change names, by ID.
    var taskAsks: [String: String] = [:]
    /// The task a tap opens in Tasks, when the app has it.
    var task: String?
    /// The tool call it came from, whose command shows on tap.
    var step: ChatMessage?

    var action: SquircleAction? { if case .action(let action) = kind { action } else { nil } }

    var text: String? {
        guard case .action(let action) = kind else { return nil }
        switch action.kind {
        case .send, .answer: return action.text
        default: return nil
        }
    }
}

/// One row of a conversation. A turn is your message, the agent's work and
/// its answer. Work in progress shows its latest note and newest steps; a
/// finished turn folds its work into a summary line, keeping screenshots.
enum ThreadItem: Equatable {
    /// The thread's title, scrolling with the conversation.
    case header(String)
    case user(ChatMessage)
    /// Squircle telling an app agent that workers finished: a quiet line.
    case update(ChatMessage)
    /// What an agent sent this thread: a worker's task or a message. A
    /// piece after one of its tables or pictures has no `agent`, so no label.
    case agentMessage(ChatMessage)
    case action(ActionLine)
    case answer(ChatMessage)
    case note(ChatMessage)
    case thought(ChatMessage)
    case step(ChatMessage)
    case earlier(turn: String, count: Int)
    /// Screenshots side by side, scrolling sideways.
    case gallery(id: String, shots: [Shot])
    /// A picture or clip the agent's text embeds, full width where it sits.
    case figure(id: String, shots: [Shot])
    /// A table in the agent's text; `quiet` in a note rather than an answer.
    case table(id: String, table: MarkdownTable, quiet: Bool)
    /// A PDF or text file the agent's text links; opens in the viewer.
    case document(id: String, path: String)
    case summary(TurnSummary)
    /// What the turn changed in the project; opens its diff.
    case changes(TurnChanges, turn: String)
    /// A build the agent made or mentioned in this turn, installable here.
    case build(AppBuild, turn: String)
    /// A simulator the turn used: live now, or its recording.
    case simulator(SimulatorUse)
    /// A question this thread put to you in the tracker, answerable here,
    /// where it was asked; `busy` while your answer is on its way.
    case question(WaitingList.Item, busy: Bool)
    case live(LiveStatus)

    var id: String {
        switch self {
        case .header: return "header"
        case .user(let message), .update(let message), .answer(let message), .agentMessage(let message): return message.id
        case .action(let line): return line.id
        case .note(let message): return "note:" + message.id
        case .thought(let message): return message.id
        case .step(let message): return message.id
        case .earlier(let turn, _): return "earlier:" + turn
        case .gallery(let id, _), .figure(let id, _), .table(let id, _, _), .document(let id, _): return id
        case .summary(let summary): return "summary:" + summary.turn
        case .build(let build, let turn): return "build:\(turn):\(build.id)"
        case .changes(_, let turn): return "changes:" + turn
        case .simulator(let use): return "simulator:" + use.id
        case .question(let item, _): return "ask:" + item.id
        case .live: return "live"
        }
    }

    /// The thread's open questions put in place: each right after its own
    /// `task ask` line (the same words, else the last one asked before it),
    /// or without one in sight, at the end of the turn it was asked in.
    static func placing(_ questions: [(question: WaitingList.Question, busy: Bool)], in items: [ThreadItem]) -> [ThreadItem] {
        var items = items
        for (question, busy) in questions.sorted(by: { ($0.question.askedAt ?? .distantPast) < ($1.question.askedAt ?? .distantPast) }) {
            let asks = items.indices.compactMap { index -> (index: Int, line: ActionLine)? in
                guard case .action(let line) = items[index], line.action?.kind == .taskAsk else { return nil }
                return (index, line)
            }
            let asked = question.askedAt
            var after = asks.first { $0.line.action?.text == question.text }?.index
            if after == nil, let asked {
                after = asks.last { $0.line.step.flatMap { date($0.createdAt) }.map { $0 <= asked } ?? false }?.index
            }
            if after == nil, let asked {
                let next = items.indices.first { index in
                    let head: ChatMessage? = switch items[index] {
                    case .user(let m), .update(let m), .agentMessage(let m): m
                    default: nil
                    }
                    return head.flatMap { date($0.createdAt) }.map { $0 > asked } ?? false
                }
                if let next { after = next - 1 }
            }
            let end = items.last?.id == "live" ? items.count - 2 : items.count - 1
            items.insert(.question(.question(question), busy: busy), at: min(after ?? end, end) + 1)
        }
        return items
    }

    /// Steps kept in view while a turn is running.
    static let liveWindow = 4

    /// The conversation's rows. Views re-render on every model change (any
    /// thread's), so the last few results are kept and reused while their
    /// inputs are unchanged; otherwise only turns whose own content changed
    /// are built again (streaming touches just the last one).
    /// `thread` is the conversation's own: builds its agent, workers or
    /// tasks started show in it.
    static func items(messages: [ChatMessage], running: Bool, expanded: Set<String> = [], builds: [AppBuild] = [],
                      changes: [TurnChanges] = [], simulators: [SimulatorUse] = [], thread: String? = nil) -> [ThreadItem] {
        let inputs = TimelineInputs(messages: messages, running: running, expanded: expanded, builds: builds,
                                    changes: changes, simulators: simulators, thread: thread?.lowercased())
        if let hit = recent.withLock({ $0.first { $0.inputs == inputs }?.items }) { return hit }
        let made = build(inputs)
        recent.withLock { cache in
            cache.removeAll { $0.inputs == inputs }
            cache.insert((inputs, made), at: 0)
            if cache.count > 3 { cache.removeLast() }
        }
        return made
    }

    private struct TimelineInputs: Equatable {
        let messages: [ChatMessage], running: Bool, expanded: Set<String>, builds: [AppBuild]
        let changes: [TurnChanges], simulators: [SimulatorUse], thread: String?
    }
    private static let recent = Mutex<[(inputs: TimelineInputs, items: [ThreadItem])]>([])

    /// Everything one turn's own rows depend on.
    private struct TurnInputs: Equatable {
        let user: ChatMessage?, rest: [ChatMessage], live: Bool, expanded: Bool
    }
    /// One turn's rows up to its answer, plus what the rest of the
    /// conversation's state is matched against.
    private struct TurnRows {
        /// The turn's rows before the simulators it used (added per
        /// conversation, so they never decide whether a turn is rebuilt) and after.
        let head: [ThreadItem], tail: [ThreadItem]
        let turnIDs: Set<String>
        let answerID: String?
        /// Build IDs the turn's messages name, in order.
        let buildIDs: [String]
        /// Builds the turn's own `build start` lines name.
        let startedIDs: Set<String>
        let live: LiveStatus?
    }
    /// Built turns by turn ID, reused while their inputs are equal.
    private static let turnCache = Mutex<[String: (inputs: TurnInputs, rows: TurnRows)]>([:])

    /// Builds each turn's rows ahead, off the main actor, as a thread first
    /// shows them (folded; the last live while running): parsing a long
    /// thread's Markdown is most of the cost of showing it the first time.
    static func prepare(_ messages: [ChatMessage], running: Bool) {
        let turns = self.turns(messages)
        for (index, turn) in turns.enumerated() {
            _ = rows(TurnInputs(user: turn.user, rest: turn.rest, live: running && index == turns.count - 1,
                                expanded: false))
        }
    }

    /// The conversation split into turns at each of your messages.
    private static func turns(_ messages: [ChatMessage]) -> [(user: ChatMessage?, rest: [ChatMessage])] {
        var turns: [(user: ChatMessage?, rest: [ChatMessage])] = []
        for message in messages {
            if message.role == "user" { turns.append((message, [])) }
            else if turns.isEmpty { turns.append((nil, [message])) }
            else { turns[turns.count - 1].rest.append(message) }
        }
        return turns
    }

    /// One turn's rows, built again only when its own inputs change.
    private static func rows(_ key: TurnInputs) -> TurnRows {
        let id = key.user?.id ?? "start"
        if let hit = turnCache.withLock({ $0[id] }), hit.inputs == key { return hit.rows }
        let rows = turnRows(id: id, key)
        turnCache.withLock { cache in
            if cache.count > 4000 { cache.removeAll() }
            cache[id] = (key, rows)
        }
        return rows
    }

    private static func build(_ inputs: TimelineInputs) -> [ThreadItem] {
        let (messages, running, expanded, builds, changes, simulators) =
            (inputs.messages, inputs.running, inputs.expanded, inputs.builds, inputs.changes, inputs.simulators)
        let turns = self.turns(messages)
        // Each simulator use belongs to the last turn that began before it. A
        // turn without your message (the conversation's first) begins with
        // its first message, so nothing from before the conversation shown
        // lands in it.
        let starts = turns.map { turn in
            (turn.user ?? turn.rest.first).flatMap { date($0.createdAt) } ?? .distantPast
        }
        var used: [Int: [SimulatorUse]] = [:]
        for use in simulators {
            let index = starts.lastIndex { $0 <= use.started } ?? 0
            used[index, default: []].append(use)
        }
        let known = Dictionary(builds.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var made: [TurnRows] = []
        for (index, turn) in turns.enumerated() {
            let id = turn.user?.id ?? "start"
            made.append(rows(TurnInputs(user: turn.user, rest: turn.rest, live: running && index == turns.count - 1,
                                        expanded: expanded.contains(id))))
        }
        // A build's card sits where it was last mentioned (Squircle's update,
        // the agent's words or its start) or where it finished, whichever is
        // later, once: a build that succeeds is posted by its card alone.
        var cardTurn: [String: Int] = [:]
        for (index, rows) in made.enumerated() { for buildID in rows.buildIDs { cardTurn[buildID] = index } }
        func finished(_ build: AppBuild) -> Int? {
            build.status == "queued" || build.status == "running" ? nil : starts.lastIndex { $0 <= build.updatedAt }
        }
        for (id, index) in cardTurn { if let build = known[id], let end = finished(build), end > index { cardTurn[id] = end } }
        // Builds this conversation's workers or tasks started get a line of
        // their own where they began, unless the agent's own command shows it.
        let startedHere = made.reduce(into: Set<String>()) { $0.formUnion($1.startedIDs) }
        var startedLines: [Int: [AppBuild]] = [:]
        if let thread = inputs.thread {
            for build in builds.reversed() where build.agentThread == thread && !startedHere.contains(build.id.lowercased()) {
                // A build begun before the first turn shown has no line here.
                guard let index = starts.lastIndex(where: { $0 <= build.date }) else { continue }
                startedLines[index, default: []].append(build)
                if cardTurn[build.id.lowercased()] == nil, let end = finished(build) { cardTurn[build.id.lowercased()] = max(index, end) }
            }
        }
        var items: [ThreadItem] = []
        for (index, rows) in made.enumerated() {
            let id = turns[index].user?.id ?? "start"
            let body = rows.head + (used[index] ?? []).map { ThreadItem.simulator($0) } + rows.tail
            items += body.compactMap { item in
                guard case .action(var line) = item else { return item }
                switch line.kind {
                // Squircle's news of a build is its card; the line stands in
                // only for a build the service no longer lists.
                case .build(let news): return known[news.id] == nil ? item : nil
                case .action(let action):
                    guard let build = action.build?.raw else { return item }
                    line.buildStatus = known[build]?.status
                    return .action(line)
                case .news: return item
                }
            }
            for build in startedLines[index] ?? [] {
                var line = ActionLine(id: "started:" + build.id.lowercased(),
                                      kind: .action(SquircleAction(kind: .buildStart(BuildID(build.id)), app: build.title)))
                line.buildStatus = build.status
                items.append(.action(line))
            }
            let live = running && index == turns.count - 1
            if !live, let change = changes.last(where: { rows.turnIDs.contains($0.turnID) || ($0.assistantMessageID != nil && $0.assistantMessageID == rows.answerID) }) {
                items.append(.changes(change, turn: id))
            }
            var seen = Set<String>()
            for buildID in rows.buildIDs + (startedLines[index] ?? []).map({ $0.id.lowercased() })
            where cardTurn[buildID] == index && seen.insert(buildID).inserted {
                if let build = known[buildID] { items.append(.build(build, turn: id)) }
            }
            if let live = rows.live { items.append(.live(live)) }
        }
        return items
    }

    private static func turnRows(id: String, _ turn: TurnInputs) -> TurnRows {
        let live = turn.live
        var items: [ThreadItem] = []
        // What you attached sits above your words, as in Messages.
        if let user = turn.user, !user.attachments.isEmpty || user.captures.contains(where: \.isVideo) {
            let images = user.attachments.enumerated().map {
                Shot(step: user.id, index: $0.offset, title: "Your image", attachment: $0.element)
            }
            let clips = user.captures.filter(\.isVideo).map {
                Shot(step: "file:" + $0.path, index: 0, title: "Your recording", video: true, path: $0.path)
            }
            items.append(.gallery(id: "gallery:sent:" + user.id, shots: images + clips))
        }
        if let user = turn.user, let build = user.build {
            items.append(.action(ActionLine(id: user.id, kind: .build(build))))
        } else if let user = turn.user, !user.news.isEmpty {
            items += user.news.enumerated().map { index, news in
                .action(ActionLine(id: "\(user.id)#\(index)", kind: .news(news.state), thread: WorkerID(news.id), title: news.title))
            }
        } else if let user = turn.user, !user.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if user.isUpdate { items.append(.update(user)) }
            else if user.agent != nil { items += withMedia(user, ThreadItem.agentMessage) }
            else { items.append(.user(user)) }
        }
        // A performance capture is for the agent; you see that it went.
        for (index, capture) in (turn.user?.captures ?? []).enumerated() where !capture.isVideo {
            var line = ChatMessage(id: "capture:\(id)#\(index)", role: "user", content: capture.label)
            line.symbol = "waveform.path.ecg"
            items.append(.update(line))
        }
        let rest = turn.rest.filter { $0.role == "tool" || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // The answer is the last thing the agent wrote, once nothing follows it.
        var answer: ChatMessage?
        if let last = rest.lastIndex(where: { $0.role == "assistant" }),
           !live || !rest[(last + 1)...].contains(where: { $0.role != "assistant" }) {
            answer = rest[last]
        }
        let work = rest.filter { $0.id != answer?.id }
        let steps = work.filter { $0.role == "tool" }
        if live {
            items += liveRows(turn: id, work: work, expanded: turn.expanded)
        } else if !steps.isEmpty {
            items.append(.summary(summary(turn: id, user: turn.user, work: work, answer: answer, expanded: turn.expanded)))
            // Squircle actions fold with the other steps (user, 2026-10-31).
            items += turn.expanded ? allRows(work) : gallery("gallery:" + id, work)
        }
        let head = items
        items = answer.map { withMedia($0, ThreadItem.answer) } ?? []
        return TurnRows(head: head, tail: items, turnIDs: Set(([turn.user] + rest).compactMap { $0?.turnID }), answerID: answer?.id,
                        buildIDs: (turn.user?.build.map { [$0.id] } ?? []) + mentionedBuildIDs(in: rest),
                        startedIDs: Set(rest.flatMap { $0.step?.actions.compactMap(\.build?.raw) ?? [] }),
                        live: live ? LiveStatus(headline: headline(work: work, answer: answer), started: turn.user.flatMap { date($0.createdAt) }) : nil)
    }

    /// Latest note, the newest few steps after it, and every screenshot.
    private static func liveRows(turn: String, work: [ChatMessage], expanded: Bool) -> [ThreadItem] {
        if expanded { return [.earlier(turn: turn, count: 0)] + allRows(work) }
        // The step running right now is the live line's headline; it joins
        // the steps when it finishes.
        var work = work
        if let last = work.last, last.role == "tool", last.isStreaming { work.removeLast() }
        let noteIndex = work.lastIndex { $0.role == "assistant" }
        let afterNote = work.indices.filter { $0 > (noteIndex ?? -1) && work[$0].role == "tool" }
        let shown = Set(afterNote.suffix(liveWindow))
        let folded = work.indices.filter { work[$0].role == "tool" && !shown.contains($0) }.count
        var rows: [ThreadItem] = folded > 0 ? [.earlier(turn: turn, count: folded)] : []
        rows += gallery("gallery:earlier:" + turn, work.indices.filter { work[$0].role == "tool" && !shown.contains($0) }.map { work[$0] })
        var visible: [ChatMessage] = []
        for (index, message) in work.enumerated() {
            if index == noteIndex { rows += stepRows(visible); visible = []; rows += withMedia(message, ThreadItem.note); continue }
            if message.role == "tool", shown.contains(index) { visible.append(message) }
        }
        return rows + stepRows(visible)
    }

    /// A step's Squircle actions that change something, one line each.
    static func actionRows(_ step: ChatMessage) -> [ThreadItem] {
        guard let actions = step.step?.actions else { return [] }
        return actions.enumerated().filter { $0.element.visible }.map { index, action in
            .action(ActionLine(id: "action:\(step.id)#\(index)", kind: .action(action), thread: action.worker, title: action.title,
                               running: step.isStreaming, failed: step.failed, step: step))
        }
    }

    private static func allRows(_ work: [ChatMessage]) -> [ThreadItem] {
        var rows: [ThreadItem] = []
        var run: [ChatMessage] = []
        for message in work {
            if message.role == "tool" { run.append(message); continue }
            rows += stepRows(run); run = []
            rows += message.role == "thinking" ? [.thought(message)] : withMedia(message, ThreadItem.note)
        }
        return rows + stepRows(run)
    }

    /// A message cut at the pictures, clips and tables it embeds, each in its place.
    private static func withMedia(_ message: ChatMessage, _ row: (ChatMessage) -> ThreadItem) -> [ThreadItem] {
        guard message.content.contains("](") || message.content.contains("|") else { return [row(message)] }
        let segments = Markdown.segments(message.content)
        guard segments.contains(where: { if case .text = $0 { return false }; return true }) else { return [row(message)] }
        let quiet: Bool = { if case .answer = row(message) { return false }; return true }()
        var rows: [ThreadItem] = []
        var named = false
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let text):
                var part = message
                part.content = String(text.characters)
                part.markdown = text
                // The first piece of text keeps the message's identity.
                if named { part.id = message.id + "#\(index)"; part.agent = nil }
                named = true
                rows.append(row(part))
            case .table(let table):
                rows.append(.table(id: "table:\(message.id)#\(index)", table: table, quiet: quiet))
            case .document(let path):
                rows.append(.document(id: "document:\(message.id)#\(index)", path: path))
            case .media(let media):
                let shot = Shot(step: "file:" + media.path, index: 0, title: "", video: media.video, path: media.path)
                // Pictures with nothing between them share one figure.
                if case .figure(let id, let shots)? = rows.last { rows[rows.count - 1] = .figure(id: id, shots: shots + [shot]) }
                else { rows.append(.figure(id: "figure:\(message.id)#\(index)", shots: [shot])) }
            }
        }
        return rows
    }

    /// A run of steps, each with its screenshots beneath it.
    private static func stepRows(_ run: [ChatMessage]) -> [ThreadItem] {
        var rows: [ThreadItem] = []
        var held: [ChatMessage] = []
        func flush() {
            for step in held {
                rows.append(.step(step))
                rows += gallery("gallery:" + step.id, [step])
            }
            held = []
        }
        for step in run {
            let actions = actionRows(step)
            if actions.isEmpty { held.append(step); continue }
            if step.step?.alsoRan == true { held.append(step) }
            flush()
            rows += actions
        }
        flush()
        return rows
    }

    private static func gallery(_ id: String, _ steps: [ChatMessage]) -> [ThreadItem] {
        let shots = steps.flatMap { step in
            (0..<step.imageCount).map { Shot(step: step.id, index: $0, title: step.content, video: step.videoID != nil) }
        }
        return shots.isEmpty ? [] : [.gallery(id: id, shots: shots)]
    }

    /// IDs (possibly of builds) the agent ran or wrote this turn, in the
    /// order first mentioned; matched against the builds when shown.
    private static func mentionedBuildIDs(in messages: [ChatMessage]) -> [String] {
        var seen = Set<String>(), found: [String] = []
        func scan(_ text: String) {
            for id in uuids(in: text) where seen.insert(id).inserted { found.append(id) }
        }
        for message in messages {
            scan(message.content); scan(message.detail)
            message.step?.actions.compactMap(\.build?.raw).forEach(scan)
        }
        return found
    }

    /// Lowercased UUIDs in `text`, in order. A byte scan: a regular
    /// expression over every step's output cost the timeline most of its time.
    static func uuids(in text: String) -> [String] {
        var text = text
        return text.withUTF8 { b -> [String] in
            var found: [String] = []
            guard b.count >= 36 else { return found }
            func hex(_ c: UInt8) -> Bool { (48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c) }
            var i = 0
            while i <= b.count - 36 {
                var ok = true
                for j in 0..<36 {
                    let c = b[i + j]
                    if j == 8 || j == 13 || j == 18 || j == 23 { if c != 45 { ok = false; break } }
                    else if !hex(c) { ok = false; break }
                }
                if ok {
                    found.append(String(decoding: UnsafeBufferPointer(rebasing: b[i..<i + 36]), as: UTF8.self).lowercased())
                    i += 36
                } else { i += 1 }
            }
            return found
        }
    }

    private static func headline(work: [ChatMessage], answer: ChatMessage?) -> String {
        if answer?.isStreaming == true { return "Writing" }
        guard let last = work.last else { return "Starting" }
        switch last.role {
        case "thinking": return "Thinking"
        case "tool": return last.isStreaming ? last.step?.live ?? last.content : "Working"
        default: return "Working"
        }
    }

    private static func summary(turn: String, user: ChatMessage?, work: [ChatMessage], answer: ChatMessage?, expanded: Bool) -> TurnSummary {
        let steps = work.filter { $0.role == "tool" }
        let edits = steps.compactMap { $0.step?.diff?.path ?? ($0.step?.kind == .edit ? $0.content : nil) }
        let end = (answer.map { [$0] } ?? []) + work
        let duration = user.flatMap { date($0.createdAt) }.flatMap { start in
            end.compactMap { date($0.createdAt) }.max().map { $0.timeIntervalSince(start) }
        }
        let tracker = steps.flatMap { $0.step?.actions ?? [] }.filter { $0.visible && $0.isTracker }
        let isNote = { (action: SquircleAction) in [.noteAdd, .noteEdit, .noteRemove].contains(action.kind) }
        let notes = tracker.filter(isNote).count
        let tasks = tracker.filter { !isNote($0) }.reduce(0) { $0 + max(1, $1.repeats ?? 1) }
        return TurnSummary(turn: turn, duration: duration, steps: steps.count, files: Set(edits).count,
                           added: steps.reduce(0) { $0 + ($1.step?.added ?? 0) },
                           removed: steps.reduce(0) { $0 + ($1.step?.removed ?? 0) },
                           tasks: tasks, notes: notes, failed: steps.contains { $0.failed }, expanded: expanded)
    }

    static func date(_ text: String) -> Date? { ISODate.parse(text) }
}
