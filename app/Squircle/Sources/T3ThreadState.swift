import Foundation

/// Server sequence numbers prevent replayed chunks from duplicating messages.
struct T3ThreadState: Codable {
    /// Where this state came from, and how far into T3's events it is.
    enum Provenance: Codable, Equatable {
        /// Nothing yet, or history T3 rewrote (a revert): only a snapshot
        /// shows it right.
        case none
        /// A copy kept on the phone: the next live snapshot replaces it
        /// whatever its sequence, so a reset server can never leave a
        /// thread stuck. Events after its sequence still apply.
        case cached(sequence: Int)
        /// From T3 on this connection.
        case live(sequence: Int)
    }
    private(set) var provenance = Provenance.none
    private(set) var thread: JSONValue = .null
    /// Inputs and screenshot counts from the Mac, keyed by tool call.
    var details: [String: JSONValue] = [:]
    /// Newest step detail fetched, so later fetches ask only for what's new.
    var detailsSince: String?
    /// Details older than version 2 lack what rebuilds steps T3 no longer
    /// sends; such a cache fetches them all again.
    var detailsVersion: Int?
    /// Recordings and images published into the thread.
    var media: [JSONValue] = []
    /// T3's sequence this state is at; -1 for none.
    var sequence: Int {
        switch provenance { case .none: -1; case .cached(let s), .live(let s): s }
    }
    var isLive: Bool { if case .live = provenance { return true }; return false }
    /// The same state as a copy kept on the phone, never live authority.
    var restored: T3ThreadState {
        var copy = self
        if case .live(let s) = provenance { copy.provenance = .cached(sequence: s) }
        return copy
    }
    var activityCount: Int { thread["activities"].array.count }
    mutating func consume(_ item: JSONValue) {
        if item["kind"].string == "snapshot" {
            let snapshot = item["snapshot"]
            guard let seq = snapshot["snapshotSequence"].int, seq >= sequence || !isLive else { return }
            provenance = .live(sequence: seq); thread = snapshot["thread"]; return
        }
        guard item["kind"].string == "event" else { return }
        let event = item["event"]
        guard let seq = event["sequence"].int, seq > sequence, provenance != .none else { return }
        provenance = .live(sequence: seq)
        let p = event["payload"]; var t = thread.object
        switch event["type"].string {
        case "thread.message-sent":
            var m = p.object; m["id"] = p["messageId"]
            var rows = t["messages"]?.array ?? []
            if let i = rows.firstIndex(where: { $0["id"] == p["messageId"] }) {
                let old = rows[i]; let delta = p["text"].string ?? ""
                m["text"] = .string(p["streaming"].bool ? (old["text"].string ?? "") + delta : delta.isEmpty ? old["text"].string ?? "" : delta)
                m["createdAt"] = old["createdAt"]
                rows[i] = .object(m)
            }
            else { rows.append(.object(m)) }
            t["messages"] = .array(rows)
        case "thread.session-set": t["session"] = p["session"]
        case "thread.activity-appended":
            var rows = t["activities"]?.array ?? []
            if !rows.contains(where: { $0["id"] == p["activity"]["id"] }) { rows.append(p["activity"]) }
            // Like T3's own snapshot: the newest 500, and open requests.
            if rows.count > 600 {
                let cut = rows.count - 500
                rows = rows.enumerated().filter { $0.offset >= cut || ($0.element["kind"].string ?? "").hasSuffix(".requested") }.map(\.element)
            }
            t["activities"] = .array(rows)
        case "thread.turn-diff-completed":
            var rows = (t["checkpoints"]?.array ?? [])
            let existing = rows.first { $0["turnId"] == p["turnId"] }
            if existing.map({ $0["status"].string != "missing" }) == true, p["status"].string == "missing" { break }
            rows.removeAll { $0["turnId"] == p["turnId"] }
            var checkpoint = p.object; checkpoint["threadId"] = nil
            rows.append(.object(checkpoint))
            t["checkpoints"] = .array(rows.sorted { ($0["checkpointTurnCount"].int ?? 0) < ($1["checkpointTurnCount"].int ?? 0) })
        case "thread.reverted":
            // History was rewritten; only a snapshot shows it right.
            provenance = .none; return
        case "thread.meta-updated": for (key,value) in p.object where key != "threadId" { t[key] = value }
        case "thread.runtime-mode-set": t["runtimeMode"] = p["runtimeMode"]
        case "thread.interaction-mode-set": t["interactionMode"] = p["interactionMode"]
        case "thread.turn-start-requested":
            var session = t["session"]?.object ?? [:]; session["status"] = .string("running"); t["session"] = .object(session)
        default: break
        }
        thread = .object(t)
    }
    var isRunning: Bool { ["running","starting"].contains(thread["session"]["status"].string ?? "") }
    /// Conversation in time order. A tool call's started/updated/completed
    /// activities are one step; bookkeeping activities are not conversation.
    var messages: [ChatMessage] {
        var rows: [(String, ChatMessage)] = thread["messages"].array.compactMap { m in
            let id = m["id"].string ?? UUID().uuidString
            let reasoning = m["role"].string == "system" && id.hasPrefix("reasoning:")
            guard reasoning || m["role"].string != "system" else { return nil }
            var message = ChatMessage(id: id, role: reasoning ? "thinking" : m["role"].string ?? "assistant",
                content: Self.spoken(m["text"].string ?? ""), isStreaming: m["streaming"].bool, createdAt: m["createdAt"].string ?? "",
                turnID: m["turnId"].string)
            message.attachments = m["attachments"].array.compactMap { $0["type"].string == "image" ? $0["id"].string : nil }
            if message.role == "user" { message.captures = SentCapture.parse(m["text"].string ?? "") }
            switch ServiceNote(m) {
            case nil: break
            case .build(let news):
                message.isUpdate = true; message.build = news
                message.content = news.app + (news.succeeded ? " build ready" : " build failed")
            case .workers(let news):
                message.isUpdate = true; message.news = news; message.threadIDs = news.map(\.id)
                message.content = news.isEmpty ? "Workers moved on" : news.map(\.summary).joined(separator: " · ")
            case .handoff:
                message.isUpdate = true; message.content = "Started fresh"
            case .agent(let author):
                message.agent = author; message.content = Self.task(message.content)
            case .other(let label):
                message.isUpdate = true; message.content = label
            }
            return (m["createdAt"].string ?? "", message)
        }
        let running = isRunning
        var steps: [String: Int] = [:]
        // T3 sends only a thread's newest activities; the Mac's details
        // rebuild the tool calls before them.
        let sent = Set(thread["activities"].array.compactMap { $0["payload"]["toolCallId"].string })
        let rebuilt: [JSONValue] = details.compactMap { key, extra in
            guard !sent.contains(key), let at = extra["started_at"].string, extra["input"] != .null else { return nil }
            let finished = extra["finished"].string
            return .from(["id": key, "kind": finished == nil ? "tool.updated" : "tool.completed", "createdAt": at,
                          "tone": finished == "failed" ? "error" : "tool", "turnId": extra["turn_id"].string ?? "",
                          "payload": ["toolCallId": key, "status": finished ?? "inProgress",
                                      "data": ["toolName": extra["tool"].string ?? ""]]])
        }.sorted { ($0["createdAt"].string ?? "") < ($1["createdAt"].string ?? "") }
        for a in rebuilt + thread["activities"].array {
            let kind = a["kind"].string ?? "", p = a["payload"]
            if ["approval.", "user-input.", "context-window.", "runtime.warning", "checkpoint.captured"].contains(where: kind.hasPrefix) { continue }
            // A background task already appears as the tool call that started it.
            if kind.hasPrefix("task."), p["toolUseId"].string != nil { continue }
            let key = p["toolCallId"].string ?? p["taskId"].string ?? a["id"].string ?? UUID().uuidString
            let output = [p["data"]["item"]["aggregatedOutput"].string, p["data"]["output"].string,
                          p["data"]["rawOutput"]["content"].string].compactMap { $0 }.first
            let detail = [p["data"]["command"].string ?? p["data"]["item"]["command"].string ?? p["detail"].string, output]
                .compactMap { $0 }.joined(separator: "\n\n")
            let extra = details[key]
            let described = AgentStep.describe(extra.map { Self.enrich(a, with: $0) } ?? a)
            if described.hidden { continue }
            let finished = kind.hasSuffix(".completed") || kind.hasSuffix(".failed") || p["status"].string == "completed"
            let images = extra?["images"].int ?? 0
            var step = ChatMessage(id: key, role: "tool", content: described.title, isStreaming: running && !finished,
                                   detail: detail.isEmpty ? p.formatted : detail, activity: kind,
                                   failed: a["tone"].string == "error" || p["status"].string == "failed", symbol: described.symbol,
                                   createdAt: a["createdAt"].string ?? "", step: described, imageCount: images)
            if let index = steps[key] {
                // Updates may arrive after completion; a finished step stays finished.
                if !rows[index].1.isStreaming { step.isStreaming = false; step.activity = rows[index].1.activity }
                if step.detail.count < rows[index].1.detail.count { step.detail = rows[index].1.detail }
                step.createdAt = rows[index].1.createdAt
                step.imageCount = max(step.imageCount, rows[index].1.imageCount)
                // Some events carry the tool's full input and others only a
                // raw command; keep whichever describes the step best.
                if let earlier = rows[index].1.step, let current = step.step, earlier.richness > current.richness {
                    step.step = earlier; step.content = earlier.title; step.symbol = earlier.symbol
                }
                rows[index].1 = step
            } else {
                steps[key] = rows.count
                rows.append((a["createdAt"].string ?? "", step))
            }
        }
        return rows.sorted { $0.0 < $1.0 }.map(\.1)
    }
    /// Puts the Mac's copy of a tool call's input back into its activity.
    static func enrich(_ activity: JSONValue, with extra: JSONValue) -> JSONValue {
        var a = activity.object, payload = activity["payload"].object, data = activity["payload"]["data"].object
        if extra["input"] != .null { data["input"] = extra["input"] }
        if let tool = extra["tool"].string, data["toolName"] == nil || data["toolName"] == .string("") { data["toolName"] = .string(tool) }
        if let result = extra["result"].string { data["squircleResult"] = .string(result) }
        payload["data"] = .object(data); a["payload"] = .object(payload)
        return .object(a)
    }
    /// Where Squircle's instructions to a worker start, after its task.
    static let workerMarker = "\n\n---\nYou are a worker for this app's agent"
    /// A worker's task without the instructions Squircle appends.
    static func task(_ text: String) -> String {
        guard let range = text.range(of: workerMarker, options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
    }

    /// What the person typed, without the app context Squircle sends after it.
    static func spoken(_ text: String) -> String {
        let end = [text.range(of: SentCapture.marker), text.range(of: AppProject.contextMarker)].compactMap { $0?.lowerBound }.min()
        guard let end else { return text }
        return String(text[..<end])
    }
    /// Each finished turn's changed files, from its ready checkpoint.
    var changes: [TurnChanges] {
        thread["checkpoints"].array.compactMap { c in
            guard c["status"].string == "ready", let turn = c["turnId"].string, let count = c["checkpointTurnCount"].int else { return nil }
            let files = c["files"].array.compactMap { f -> TurnChanges.File? in
                guard let path = f["path"].string else { return nil }
                return TurnChanges.File(path: path, kind: f["kind"].string ?? "modified",
                                        additions: f["additions"].int ?? 0, deletions: f["deletions"].int ?? 0)
            }
            guard !files.isEmpty else { return nil }
            return TurnChanges(turnID: turn, count: count, assistantMessageID: c["assistantMessageId"].string, files: files)
        }
    }
    /// Whether T3 has the user message with this ID.
    func hasMessage(_ id: String) -> Bool { thread["messages"].array.contains { $0["id"].string == id || $0["messageId"].string == id } }
    var pendingRequests: [JSONValue] {
        let activities = thread["activities"].array
        let finished = Set(activities.filter {
            let kind = $0["kind"].string ?? ""
            return kind.contains("resolved") || kind.contains("responded") || kind.contains("completed") || kind.contains("cancelled") || kind == "user-input.answer-submitted"
        }.compactMap { $0["payload"]["requestId"].string })
        return activities.filter {
            let kind = $0["kind"].string ?? ""
            guard let id = $0["payload"]["requestId"].string else { return false }
            return (kind.contains("approval") || kind.contains("user-input")) && (kind.contains("requested") || kind.contains("opened")) && !finished.contains(id)
        }
    }
}

/// A message Squircle sent in the user's place: T3 sends every message as
/// the user's, so the service marks each with a context record whose kind
/// starts with `squircle-`. Any marked message is Squircle's, whatever its
/// kind, so one this build doesn't know still never shows as yours or shows
/// the agent's instructions. Worker updates and tasks from before the marks
/// are known by their text.
enum ServiceNote: Equatable {
    case build(BuildNews)
    case workers([WorkerNews])
    /// A fresh agent's briefing.
    case handoff
    /// A worker's task or another agent's `thread send`.
    case agent(AgentAuthor)
    /// A kind this build doesn't know: Squircle's line, with its label.
    case other(String)

    static let prefix = "squircle-"

    init?(_ message: JSONValue) {
        guard message["role"].string == "user" else { return nil }
        let text = message["text"].string ?? ""
        guard let record = message["context"]["records"].array.first(where: { ($0["kind"].string ?? "").hasPrefix(Self.prefix) }) else {
            if text.hasPrefix("[worker update]") { self = .workers(Self.workers(text: text)) }
            else if text.contains(T3ThreadState.workerMarker) { self = .agent(AgentAuthor(kind: .task, from: nil)) }
            else { return nil }
            return
        }
        let payload = record["payload"]
        switch record["kind"].string {
        case "squircle-build-update":
            guard let id = payload["build"].string.flatMap(SquircleAction.uuid) else { self = .other(record["label"].string ?? "Squircle"); return }
            self = .build(BuildNews(id: id, app: payload["app"].string ?? "App", succeeded: payload["state"].string == "succeeded",
                                    reason: payload["reason"].string))
        case "squircle-worker-update":
            self = .workers(payload["workers"].array.compactMap { worker in
                worker["id"].string.map { WorkerNews(id: $0, title: worker["title"].string ?? "A worker",
                                                     state: WorkerState(rawValue: worker["state"].string ?? "") ?? .done) }
            })
        case "squircle-handoff": self = .handoff
        case "squircle-task": self = .agent(AgentAuthor(kind: .task, from: payload["from"].string))
        case "squircle-agent-message": self = .agent(AgentAuthor(kind: .message, from: payload["from"].string))
        default: self = .other(record["label"].string ?? "Squircle")
        }
    }

    /// Each worker in an early update's text:
    /// - "Title" (id, branch) finished its turn.
    private static func workers(text: String) -> [WorkerNews] {
        text.split(separator: "\n").compactMap { line -> WorkerNews? in
            guard line.hasPrefix("- \""), let close = line.range(of: "\" ("),
                  let comma = line[close.upperBound...].firstIndex(where: { $0 == "," || $0 == ")" }) else { return nil }
            let title = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let id = String(line[close.upperBound..<comma])
            let state: WorkerState = line.contains("is waiting") ? .needsYou : line.contains("error") ? .error : .done
            return SquircleAction.uuid(id).map { WorkerNews(id: $0, title: title, state: state) }
        }
    }
}
