import Foundation

/// Server sequence numbers prevent replayed chunks from duplicating messages.
struct T3ThreadState: Codable {
    private(set) var sequence = -1
    private(set) var thread: JSONValue = .null
    /// Inputs and screenshot counts from the Mac, keyed by tool call.
    var details: [String: JSONValue] = [:]
    /// Newest step detail fetched, so later fetches ask only for what's new.
    var detailsSince: String?
    /// Recordings and images published into the thread.
    var media: [JSONValue] = []
    /// Restored from a cache: the next live snapshot replaces it whatever its
    /// sequence, so a reset server can never leave a thread stuck.
    var fromCache = false
    var activityCount: Int { thread["activities"].array.count }
    mutating func consume(_ item: JSONValue) {
        if item["kind"].string == "snapshot" {
            let snapshot = item["snapshot"]
            guard let seq = snapshot["snapshotSequence"].int, seq >= sequence || fromCache else { return }
            sequence = seq; thread = snapshot["thread"]; fromCache = false; return
        }
        guard item["kind"].string == "event" else { return }
        let event = item["event"]
        guard let seq = event["sequence"].int, seq > sequence else { return }
        sequence = seq
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
            t["activities"] = .array(rows)
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
            if let update = Self.workerUpdate(m) {
                message.content = update; message.isUpdate = true
                message.threadIDs = m["context"]["records"].array.flatMap { $0["payload"]["workers"].array.compactMap { $0["id"].string } }
            }
            return (m["createdAt"].string ?? "", message)
        }
        let running = isRunning
        var steps: [String: Int] = [:]
        for a in thread["activities"].array {
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
        if let tool = extra["tool"].string, data["toolName"] == nil { data["toolName"] = .string(tool) }
        payload["data"] = .object(data); a["payload"] = .object(payload)
        return .object(a)
    }
    /// "Dark mode finished · Launch crash needs you" for Squircle's wake-up
    /// message to an app agent; nil for anything else.
    static func workerUpdate(_ message: JSONValue) -> String? {
        guard message["role"].string == "user",
              let record = message["context"]["records"].array.first(where: { $0["kind"].string == "squircle-worker-update" })
        else { return nil }
        let lines = record["payload"]["workers"].array.map { worker -> String in
            let title = worker["title"].string ?? "A worker"
            switch worker["state"].string {
            case "needs-you": return title + " needs input"
            case "error": return title + " stopped with an error"
            default: return title + " finished"
            }
        }
        return lines.isEmpty ? "Workers moved on" : lines.joined(separator: " · ")
    }
    /// What the person typed, without the app context Squircle sends after it.
    static func spoken(_ text: String) -> String {
        guard let range = text.range(of: AppProject.contextMarker) else { return text }
        return String(text[..<range.lowerBound])
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
