import Foundation

/// A finished turn's work, folded into one line.
struct TurnSummary: Equatable {
    let turn: String
    let duration: TimeInterval?
    let steps: Int
    let files: Int
    let added: Int
    let removed: Int
    let failed: Bool
    let expanded: Bool

    var title: String {
        guard let duration, duration >= 1 else { return "Worked" }
        return "Worked for " + TurnSummary.format(duration)
    }
    var detail: String {
        var parts = ["\(steps) step\(steps == 1 ? "" : "s")"]
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s") changed") }
        return parts.joined(separator: " · ")
    }
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// One screenshot a step returned.
struct Shot: Equatable {
    let step: String
    let index: Int
    let title: String
}

/// What the agent is doing this moment.
struct LiveStatus: Equatable {
    let headline: String
    let started: Date?
}

/// One row of a conversation. A turn is your message, the agent's work and
/// its answer. Work in progress shows its latest note and newest steps; a
/// finished turn folds its work into a summary line, keeping screenshots.
enum ThreadItem: Equatable {
    case user(ChatMessage)
    case answer(ChatMessage)
    case note(ChatMessage)
    case thought(ChatMessage)
    case step(ChatMessage, first: Bool, last: Bool)
    case earlier(turn: String, count: Int)
    /// Screenshots side by side, scrolling sideways.
    case gallery(id: String, shots: [Shot])
    case summary(TurnSummary)
    case live(LiveStatus)

    var id: String {
        switch self {
        case .user(let message), .answer(let message): return message.id
        case .note(let message): return "note:" + message.id
        case .thought(let message): return message.id
        case .step(let message, _, _): return message.id
        case .earlier(let turn, _): return "earlier:" + turn
        case .gallery(let id, _): return id
        case .summary(let summary): return "summary:" + summary.turn
        case .live: return "live"
        }
    }

    /// Steps kept in view while a turn is running.
    static let liveWindow = 4

    static func items(messages: [ChatMessage], running: Bool, expanded: Set<String> = [], now: Date = .now) -> [ThreadItem] {
        // Split into turns at each of your messages.
        var turns: [(user: ChatMessage?, rest: [ChatMessage])] = []
        for message in messages {
            if message.role == "user" { turns.append((message, [])) }
            else if turns.isEmpty { turns.append((nil, [message])) }
            else { turns[turns.count - 1].rest.append(message) }
        }
        var items: [ThreadItem] = []
        for (index, turn) in turns.enumerated() {
            let live = running && index == turns.count - 1
            let id = turn.user?.id ?? "start"
            if let user = turn.user, !user.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(.user(user)) }
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
                items += liveRows(turn: id, work: work, expanded: expanded.contains(id))
            } else if !steps.isEmpty {
                let open = expanded.contains(id)
                items.append(.summary(summary(turn: id, user: turn.user, work: work, answer: answer, expanded: open)))
                items += open ? allRows(work) : gallery("gallery:" + id, work)
            }
            if let answer { items.append(.answer(answer)) }
            if live {
                items.append(.live(LiveStatus(headline: headline(work: work, answer: answer), started: turn.user.flatMap { date($0.createdAt) })))
            }
        }
        return items
    }

    /// Latest note, the newest few steps after it, and every screenshot.
    private static func liveRows(turn: String, work: [ChatMessage], expanded: Bool) -> [ThreadItem] {
        if expanded { return [.earlier(turn: turn, count: 0)] + allRows(work) }
        let noteIndex = work.lastIndex { $0.role == "assistant" }
        let afterNote = work.indices.filter { $0 > (noteIndex ?? -1) && work[$0].role == "tool" }
        let shown = Set(afterNote.suffix(liveWindow))
        let folded = work.indices.filter { work[$0].role == "tool" && !shown.contains($0) }.count
        var rows: [ThreadItem] = folded > 0 ? [.earlier(turn: turn, count: folded)] : []
        rows += gallery("gallery:earlier:" + turn, work.indices.filter { work[$0].role == "tool" && !shown.contains($0) }.map { work[$0] })
        var visible: [ChatMessage] = []
        for (index, message) in work.enumerated() {
            if index == noteIndex { rows += stepRows(visible); visible = []; rows.append(.note(message)); continue }
            if message.role == "tool", shown.contains(index) { visible.append(message) }
        }
        return rows + stepRows(visible)
    }

    private static func allRows(_ work: [ChatMessage]) -> [ThreadItem] {
        var rows: [ThreadItem] = []
        var run: [ChatMessage] = []
        for message in work {
            if message.role == "tool" { run.append(message); continue }
            rows += stepRows(run); run = []
            rows.append(message.role == "thinking" ? .thought(message) : .note(message))
        }
        return rows + stepRows(run)
    }

    /// A run of steps shares one rail; screenshots sit beneath their step.
    private static func stepRows(_ run: [ChatMessage]) -> [ThreadItem] {
        var rows: [ThreadItem] = []
        for (index, step) in run.enumerated() {
            rows.append(.step(step, first: index == 0, last: index == run.count - 1))
            rows += gallery("gallery:" + step.id, [step])
        }
        return rows
    }

    private static func gallery(_ id: String, _ steps: [ChatMessage]) -> [ThreadItem] {
        let shots = steps.flatMap { step in (0..<step.imageCount).map { Shot(step: step.id, index: $0, title: step.content) } }
        return shots.isEmpty ? [] : [.gallery(id: id, shots: shots)]
    }

    private static func headline(work: [ChatMessage], answer: ChatMessage?) -> String {
        if answer?.isStreaming == true { return "Writing" }
        guard let last = work.last else { return "Starting" }
        switch last.role {
        case "thinking": return "Thinking"
        case "tool": return last.isStreaming ? last.content : "Working"
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
        return TurnSummary(turn: turn, duration: duration, steps: steps.count, files: Set(edits).count,
                           added: steps.reduce(0) { $0 + ($1.step?.added ?? 0) },
                           removed: steps.reduce(0) { $0 + ($1.step?.removed ?? 0) },
                           failed: steps.contains { $0.failed }, expanded: expanded)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static func date(_ text: String) -> Date? {
        iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
