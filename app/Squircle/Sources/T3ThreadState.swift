import Foundation

/// Server sequence numbers prevent replayed chunks from duplicating messages.
struct T3ThreadState {
    private(set) var sequence = -1
    private(set) var thread: JSONValue = .null
    mutating func consume(_ item: JSONValue) {
        if item["kind"].string == "snapshot" {
            let snapshot = item["snapshot"]
            guard let seq = snapshot["snapshotSequence"].int, seq >= sequence else { return }
            sequence = seq; thread = snapshot["thread"]; return
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
            return (m["createdAt"].string ?? "", ChatMessage(id: id, role: reasoning ? "thinking" : m["role"].string ?? "assistant",
                content: m["text"].string ?? "", isStreaming: m["streaming"].bool))
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
            let (label, symbol) = Self.describe(a)
            let finished = kind.hasSuffix(".completed") || kind.hasSuffix(".failed") || p["status"].string == "completed"
            var step = ChatMessage(id: key, role: "tool", content: label, isStreaming: running && !finished,
                                   detail: detail.isEmpty ? p.formatted : detail, activity: kind,
                                   failed: a["tone"].string == "error" || p["status"].string == "failed", symbol: symbol)
            if let index = steps[key] {
                // Updates may arrive after completion; a finished step stays finished.
                if !rows[index].1.isStreaming { step.isStreaming = false; step.activity = rows[index].1.activity }
                if step.detail.count < rows[index].1.detail.count { step.detail = rows[index].1.detail }
                rows[index].1 = step
            } else {
                steps[key] = rows.count
                rows.append((a["createdAt"].string ?? "", step))
            }
        }
        return rows.sorted { $0.0 < $1.0 }.map(\.1)
    }
    /// A short human line and symbol for one tool activity.
    static func describe(_ activity: JSONValue) -> (String, String) {
        let p = activity["payload"], data = p["data"]
        let tool = data["toolName"].string ?? ""
        let detail = p["detail"].string ?? ""
        if let command = data["command"].string ?? data["item"]["command"].string { return (command, "terminal") }
        if p["itemType"].string == "command_execution" {
            return (detail.hasPrefix("Bash: ") ? String(detail.dropFirst(6)) : detail, "terminal")
        }
        if (activity["kind"].string ?? "").hasPrefix("task.") {
            return (p["title"].string ?? p["detail"].string ?? activity["summary"].string ?? "Task", "gearshape.2")
        }
        let symbol: String
        switch tool {
        case "Read": symbol = p["itemType"].string == "image_view" ? "photo" : "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": symbol = "pencil.line"
        case "Grep", "Glob", "ToolSearch": symbol = "magnifyingglass"
        case "Bash": symbol = "terminal"
        case "Agent", "Task": symbol = "person.2"
        case "WebFetch", "WebSearch": symbol = "globe"
        default:
            switch p["itemType"].string {
            case "file_change": symbol = "pencil.line"
            case "web_search": symbol = "globe"
            case "image_view": symbol = "photo"
            default: symbol = "wrench.and.screwdriver"
            }
        }
        func short(_ path: String) -> String { path.split(separator: "/").suffix(2).joined(separator: "/") }
        if let path = data["imagePath"].string { return ("View " + short(path), symbol) }
        // Claude tools arrive as "Name: {json arguments}".
        if let colon = detail.range(of: ": "), let json = try? JSONDecoder().decode(JSONValue.self, from: Data(detail[colon.upperBound...].utf8)),
           !json.object.isEmpty || detail.hasSuffix("{}") {
            let name = String(detail[..<colon.lowerBound]).replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ")
            if let path = json["file_path"].string ?? json["path"].string ?? json["notebook_path"].string { return (name + " " + short(path), symbol) }
            for key in ["pattern", "query", "description", "command", "url", "skill", "prompt"] {
                if let value = json[key].string { return (name + " " + value, symbol) }
            }
            return (name, symbol)
        }
        if !detail.isEmpty { return (detail, symbol) }
        return (p["title"].string ?? activity["summary"].string ?? activity["kind"].string ?? "Activity", symbol)
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
