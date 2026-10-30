import Foundation

/// One T3 thread as T3's orchestration protocol 2 shows it: a snapshot's
/// projection, kept current by events that each carry one whole entity
/// (a run, message, turn item, runtime request or checkpoint) to put in
/// place of the one with its ID. Server sequence numbers keep replayed
/// events from applying twice.
struct T3ThreadState: Codable {
    /// Where this state came from, and how far into T3's events it is.
    enum Provenance: Codable, Equatable {
        /// Nothing yet, or history T3 rewrote (a rollback): only a snapshot
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
    /// The parts of T3's projection the phone reads (`kept`).
    private(set) var projection: JSONValue = .null
    var thread: JSONValue { projection["thread"] }
    /// Inputs and screenshot counts from the Mac, keyed by tool call.
    var details: [String: JSONValue] = [:]
    /// Newest step detail fetched, so later fetches ask only for what's new.
    var detailsSince: String?
    /// Details from an older version fetch them all again: before 2 they
    /// lack what rebuilds steps T3 no longer sends, before 3 the pictures
    /// agents looked at.
    var detailsVersion: Int?
    static let detailsVersion = 3
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
    /// Grows as the agent works; the Mac's step details follow it.
    var itemCount: Int { projection["turnItems"].array.count }

    /// The projection's lists the phone keeps, by the event that carries
    /// one of their entities.
    private static let lists: [String: String] = [
        "run.created": "runs", "run.updated": "runs", "message.updated": "messages", "turn-item.updated": "turnItems",
        "runtime-request.updated": "runtimeRequests", "checkpoint.captured": "checkpoints",
    ]
    private static func kept(_ projection: JSONValue) -> JSONValue {
        var kept: [String: JSONValue] = ["thread": projection["thread"]]
        for list in Set(lists.values) { kept[list] = .array(projection[list].array) }
        return .object(kept)
    }
    /// Turn items kept past a long run: the newest, and those of requests
    /// still open (the Mac's details rebuild older tool calls).
    private static let itemsKept = 1000

    mutating func consume(_ item: JSONValue) {
        switch item["kind"].string {
        case "snapshot":
            guard let seq = item["snapshotSequence"].int, seq >= sequence || !isLive else { return }
            provenance = .live(sequence: seq); projection = Self.kept(item["projection"])
        case "event":
            guard let seq = item["sequence"].int, seq > sequence, provenance != .none else { return }
            provenance = .live(sequence: seq)
            let event = item["event"], type = event["type"].string ?? "", entity = event["payload"]
            var p = projection.object
            if type == "checkpoint.rollback-requested" {
                // History was rewritten; only a snapshot shows it right.
                provenance = .none; return
            } else if let list = Self.lists[type], let id = entity["id"].string {
                var rows = p[list]?.array ?? []
                if let i = rows.lastIndex(where: { $0["id"].string == id }) { rows[i] = entity } else { rows.append(entity) }
                if list == "turnItems", rows.count > Self.itemsKept + 200 {
                    let cut = rows.count - Self.itemsKept, open = Set(openRequests.map(\.id))
                    rows = rows.enumerated().filter { $0.offset >= cut || $0.element["requestId"].string.map(open.contains) == true }.map(\.element)
                }
                p[list] = .array(rows)
            } else if type.hasPrefix("thread."), type != "thread.pull-request-link-updated" {
                // Every other thread event carries the whole thread.
                p["thread"] = entity
            } else { return }
            projection = .object(p)
        default: break
        }
    }

    /// Statuses of a run in progress: T3 is getting it going, running it,
    /// or it waits on the user.
    static let activeRunStatuses: Set<String> = ["preparing", "starting", "running", "waiting"]
    /// The run in progress, if any.
    var activeRunID: String? {
        projection["runs"].array.last { Self.activeRunStatuses.contains($0["status"].string ?? "") }?["id"].string
    }
    var isRunning: Bool { activeRunID != nil }

    /// Conversation in time order: messages, the agent's thinking, and one
    /// step per tool call.
    var messages: [ChatMessage] {
        // A row without an ID is named by its place, so it keeps one identity on every pass.
        var rows: [(String, ChatMessage)] = projection["messages"].array.enumerated().compactMap { index, m in
            guard m["role"].string != "system" else { return nil }
            let id = m["id"].string ?? "message-\(index)"
            var message = ChatMessage(id: id, role: m["role"].string ?? "assistant", content: Self.spoken(m["text"].string ?? ""),
                                      isStreaming: m["streaming"].bool, createdAt: m["createdAt"].string ?? "", turnID: m["runId"].string)
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
            case .agent(let author):
                message.agent = author; message.content = Self.task(message.content)
            case .other(let label):
                message.isUpdate = true; message.content = label
            case .background(let summary, let symbol):
                message.isUpdate = true; message.content = summary; message.symbol = symbol
            }
            return (m["createdAt"].string ?? "", message)
        }
        let running = isRunning
        let items = projection["turnItems"].array
        // T3 sends a bounded history; the Mac's details rebuild the tool
        // calls before it.
        let sent = Set(items.compactMap(ToolCall.key))
        let rebuilt: [(String, ChatMessage)] = details.compactMap { key, extra in
            guard !sent.contains(key), let at = extra["started_at"].string, extra["input"] != .null else { return nil }
            let call = ToolCall(tool: extra["tool"].string ?? "", input: extra["input"], result: extra["result"].string)
            let described = AgentStep.describe(call)
            guard !described.hidden else { return nil }
            let finished = extra["finished"].string
            return (at, ChatMessage(id: key, role: "tool", content: described.title, isStreaming: running && finished == nil,
                                    detail: extra["input"].formatted, failed: finished == "failed", symbol: described.symbol,
                                    createdAt: at, step: described, imageCount: extra["images"].int ?? 0, turnID: extra["turn_id"].string))
        }
        rows += rebuilt
        for item in items {
            let at = item["startedAt"].string ?? item["updatedAt"].string ?? ""
            let streaming = running && !ToolCall.finished.contains(item["status"].string ?? "")
            if item["type"].string == "reasoning" {
                guard let text = item["text"].string, !text.isEmpty, let id = item["id"].string else { continue }
                rows.append((at, ChatMessage(id: id, role: "thinking", content: text, isStreaming: item["streaming"].bool && running,
                                             createdAt: at, turnID: item["runId"].string)))
                continue
            }
            guard let key = ToolCall.key(item), var call = ToolCall(item) else { continue }
            let extra = details[key]
            if call.input == .null, let input = extra?["input"], input != .null { call.input = input }
            call.result = call.result ?? extra?["result"].string
            let described = AgentStep.describe(call)
            if described.hidden { continue }
            rows.append((at, ChatMessage(id: key, role: "tool", content: described.title, isStreaming: streaming, detail: call.detail,
                                         failed: call.failed, symbol: described.symbol, createdAt: at, step: described,
                                         imageCount: extra?["images"].int ?? 0, turnID: item["runId"].string)))
        }
        return rows.sorted { $0.0 < $1.0 }.map(\.1)
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
    /// Each finished run's changed files, from its ready checkpoint. T3
    /// counts turns for diffs by the run's ordinal in the thread.
    var changes: [TurnChanges] {
        projection["checkpoints"].array.compactMap { c in
            guard c["status"].string == "ready", let run = c["runId"].string, let count = c["appRunOrdinal"].int else { return nil }
            let files = c["files"].array.compactMap { f -> TurnChanges.File? in
                guard let path = f["path"].string else { return nil }
                return TurnChanges.File(path: path, kind: f["kind"].string ?? "modified",
                                        additions: f["additions"].int ?? 0, deletions: f["deletions"].int ?? 0)
            }
            guard !files.isEmpty else { return nil }
            return TurnChanges(turnID: run, count: count, assistantMessageID: nil, files: files)
        }.sorted { $0.count < $1.count }
    }
    /// Whether T3 has the user message with this ID.
    func hasMessage(_ id: String) -> Bool { projection["messages"].array.contains { $0["id"].string == id } }

    /// Requests T3 has open that the user can answer now: pending, answered
    /// on the live provider session, in the run going now. A question or
    /// approval blocks its run, so one from another run can never be
    /// answered and never shows.
    var pendingRequests: [PendingRequest] {
        guard let run = activeRunID else { return [] }
        return openRequests.filter { $0.runID.map { $0 == run } ?? true }
    }
    /// Pending runtime requests with the turn item that says what they ask.
    private var openRequests: [PendingRequest] {
        let items = projection["turnItems"].array
        return projection["runtimeRequests"].array.compactMap { request in
            guard request["status"].string == "pending", request["responseCapability"]["type"].string != "not_resumable",
                  let id = request["id"].string,
                  let item = items.last(where: { $0["requestId"].string == id && ["user_input_request", "approval_request"].contains($0["type"].string ?? "") })
            else { return nil }
            return PendingRequest(id: id, item: item)
        }
    }
}

/// A question or approval T3 is waiting on, as its turn item tells it.
struct PendingRequest: Equatable {
    /// T3's runtime request ID, which an answer names.
    let id: String
    let item: JSONValue
    var isQuestion: Bool { item["type"].string == "user_input_request" }
    var runID: String? { item["runId"].string }
    var questions: [JSONValue] { item["questions"].array }
    /// What an approval asks.
    var title: String { item["title"].string ?? "The agent needs your response" }
    var prompt: String { item["prompt"].string ?? "" }
    /// The choices an approval offers (`decision`, `label`, `warning`).
    var options: [JSONValue] { item["options"].array }
}

/// One tool call: the tool and its input, said the way Claude names them,
/// from a protocol 2 turn item or the Mac's copy of one.
struct ToolCall {
    var tool: String
    var input: JSONValue
    /// A Squircle command's output, which names what it made.
    var result: String?
    var title: String?
    var detail = ""
    var failed = false

    static let finished: Set<String> = ["completed", "failed", "cancelled", "interrupted"]

    init(tool: String, input: JSONValue, result: String? = nil, title: String? = nil) {
        self.tool = tool; self.input = input; self.result = result; self.title = title
    }

    /// The key the Mac files a call's details under: the provider's call ID
    /// (Claude's `toolu_…`), else T3's item ID.
    static func key(_ item: JSONValue) -> String? { item["nativeItemRef"]["nativeId"].string ?? item["id"].string }

    /// Nil for an item that isn't a tool call, and for T3's own workspace
    /// preparation.
    init?(_ item: JSONValue) {
        let output = item["output"].string
        switch item["type"].string {
        case "dynamic_tool":
            self.init(tool: item["toolName"].string ?? "", input: item["input"])
            detail = output ?? (item["input"] == .null ? "" : item["input"].formatted)
        case "command_execution":
            guard item["nativeItemRef"] != .null else { return nil }
            let command = item["input"].string ?? ""
            self.init(tool: "Bash", input: ["command": .string(command)], result: output)
            detail = [command, output].compactMap { $0 }.joined(separator: "\n\n")
            failed = item["outputIndicatesFailure"].bool || (item["exitCode"].int ?? 0) != 0
        case "file_change":
            self.init(tool: "Edit", input: ["file_path": item["fileName"], "old_string": item["oldStr"], "new_string": item["newStr"]])
            detail = item["diffStr"].string ?? ""
        case "file_search":
            self.init(tool: "Grep", input: ["pattern": item["pattern"]])
        case "web_search":
            self.init(tool: "WebSearch", input: ["query": item["patterns"].array.first ?? .null])
        case "subagent":
            self.init(tool: "Agent", input: ["description": .string(item["title"].string ?? item["prompt"].string ?? "")])
            detail = item["result"].string ?? item["progress"].string ?? ""
        case "todo_list":
            self.init(tool: "TodoWrite", input: .null)
        case "error":
            self.init(tool: "", input: .null, title: item["failure"]["message"].string ?? "Something went wrong")
            failed = true
        default: return nil
        }
        if item["status"].string == "failed" { failed = true }
        if title == nil { title = item["title"].string }
        if detail.isEmpty { detail = item.formatted }
    }
}

/// A user-role message nobody typed. Squircle's own go as the user's, so
/// the service marks each with a context record whose kind starts with
/// `squircle-`; any marked message is Squircle's, whatever its kind, so one
/// this build doesn't know still never shows as yours or shows the agent's
/// instructions. T3 marks the rest itself: a background command, monitor,
/// subagent or delegated task finishing carries a `notification` (shown as
/// its summary line), and another agent's message (`thread send`, a
/// delegated task's brief) is `createdBy` an agent. Worker updates and tasks
/// from before the marks are known by their text.
enum ServiceNote: Equatable {
    case build(BuildNews)
    case workers([WorkerNews])
    /// A worker's task or another agent's `thread send`.
    case agent(AgentAuthor)
    /// A kind this build doesn't know: Squircle's line, with its label.
    case other(String)
    /// T3's word that background work finished: its summary and symbol.
    case background(String, symbol: String)

    static let prefix = "squircle-"

    init?(_ message: JSONValue) {
        guard message["role"].string == "user" else { return nil }
        let text = message["text"].string ?? ""
        guard let record = message["context"]["records"].array.first(where: { ($0["kind"].string ?? "").hasPrefix(Self.prefix) }) else {
            let notification = message["notification"]
            if notification != .null {
                let symbol = switch notification["source"]["kind"].string {
                case "background_command": "terminal"
                case "monitor": "eye"
                case "delegated_task": "person.2"
                case "background_task" where notification["source"]["work"].string == "subagent": "person.2"
                default: "gearshape"
                }
                self = .background(notification["summary"].string ?? "Background work finished", symbol: symbol); return
            }
            if let author = message["createdBy"].string, author != "user" {
                self = .agent(AgentAuthor(kind: .message, from: message["senderThreadId"].string)); return
            }
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
