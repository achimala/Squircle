import Foundation

struct HermesQuestion: Identifiable, Equatable {
    static let supported: Set<String> = ["approval", "clarify", "sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code"]
    let id: String
    let method: String
    let params: JSONValue
    var sessionID: String { params["session_id"].string ?? "" }
    var title: String {
        params["description"].string ?? params["prompt"].string ?? params["display_name"].string
            ?? ["approval": "Approval needed", "clarify": "Hermes has a question", "sudo": "Mac password", "secret": "Credential needed", "vault.code": "Verification code", "vault.save_login": "Save login"][method] ?? method
    }
}

/// A display projection of Hermes's canonical transcript and typed events. The
/// server owns history, scheduling, tool execution and request lifetimes.
struct HermesConversation {
    var messages: [ChatMessage] = []
    var questions: [HermesQuestion] = []
    var running = false
    var status = "Connected to your Mac"
    var control: JSONValue = .null
    var info: JSONValue = .null
    var lastSequence = 0
    private var segment = UUID().uuidString

    mutating func hydrate(_ snapshot: JSONValue) {
        messages = Self.project(snapshot["messages"].array)
        running = snapshot["running"].bool || snapshot["info"]["running"].bool
        info = snapshot["info"]
        questions = snapshot["open_requests"].array.compactMap(Self.question).filter { HermesQuestion.supported.contains($0.method) }
        updateConnection(snapshot["pending_connection"], sessionID: snapshot["session_id"].string ?? "")
        segment = UUID().uuidString
        let inflight = snapshot["inflight"]["display_kind"].string == "hidden" ? JSONValue.null : snapshot["inflight"]
        if let user = inflight["user"].string, !user.isEmpty, messages.last(where: { $0.role == "user" })?.content != user {
            messages.append(ChatMessage(id: "inflight-user", role: "user", content: user))
        }
        if let text = inflight["assistant"].string, !text.isEmpty {
            appendText(text, role: "assistant", streaming: inflight["streaming"].bool)
        }
        if let error = inflight["error"].string { notice(error, failed: true) }
        status = running ? "Hermes is working" : "Connected to your Mac"
    }

    static func question(_ frame: JSONValue) -> HermesQuestion? {
        guard let id = frame["id"].identifier, let method = frame["method"].string else { return nil }
        return HermesQuestion(id: id, method: method, params: frame["params"])
    }

    static func project(_ inputRows: [JSONValue]) -> [ChatMessage] {
        let rows = inputRows.filter { $0["display_kind"].string != "hidden" }
        var calls: [String: JSONValue] = [:]
        for row in rows {
            for call in row["tool_calls"].array {
                if let id = call["id"].string { calls[id] = call["function"] }
            }
        }
        let projected: [ChatMessage] = rows.enumerated().compactMap { index, row in
            guard row["display_kind"].string != "hidden" else { return nil }
            let role = row["role"].string ?? "notice"
            let id = row["row_id"].identifier ?? row["id"].identifier ?? "history-\(index)"
            var text = row["display_content"].string ?? row["text"].string ?? row["content"].text
            if row["text"].string == nil {
                for block in row["content"].array {
                    let url = block["image_url"]["url"].string ?? block["image_url"].string ?? (block["type"].string == "input_image" ? block["url"].string : nil)
                    if let url { text += "\n@image:\(url)" }
                }
            }
            if role == "tool" {
                let callID = row["tool_call_id"].string ?? id
                let call = calls[callID] ?? .null
                let rawArgs = call["arguments"]
                let args = row["args"] != .null ? row["args"] : rawArgs.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? rawArgs
                let name = row["name"].string ?? row["tool_name"].string ?? call["name"].string ?? "Tool"
                let result = row["content"] == .null ? JSONValue.string(text) : row["content"]
                return ChatMessage(id: "tool-\(callID)", role: "tool", content: ToolPresentation.summary(result),
                                   detail: details(args: args, result: result, diff: row["inline_diff"]),
                                   activity: ToolPresentation.title(name, args), failed: isFailure(result),
                                   traceFiles: CodingTrace.references(in: [row, args]))
            }
            if role == "system" { return nil }
            var result = ChatMessage(id: "row-\(id)", role: role, content: text, traceFiles: role == "assistant" ? CodingTrace.references(in: [.string(text)]) : [])
            // Preserve structured content and sidecars rather than silently dropping an unfamiliar message.
            if text.isEmpty, row["content"] != .null { result.content = ToolPresentation.readable(row["content"]) }
            if let reasoning = row["reasoning"].string, !reasoning.isEmpty { result.detail = reasoning; result.activity = "Reasoning" }
            return result.content.isEmpty && result.detail.isEmpty ? nil : result
        }
        let completed = Set(rows.compactMap { $0["tool_call_id"].string })
        // A resumed long-running command may have a call but no result yet.
        // Keep its log discoverable without inventing a completion or running state.
        let pending = rows.flatMap { $0["tool_calls"].array }.compactMap { call -> ChatMessage? in
            guard let id = call["id"].string, !completed.contains(id) else { return nil }
            let function = call["function"], args = ToolPresentation.decoded(function["arguments"])
            return ChatMessage(id: "tool-\(id)", role: "tool", content: "No result recorded yet",
                               detail: Self.details(args: args, result: .null),
                               activity: ToolPresentation.title(function["name"].string ?? "Tool", args),
                               traceFiles: CodingTrace.references(in: [args]))
        }
        return projected + pending
    }

    static func details(args: JSONValue, result: JSONValue, diff: JSONValue = .null) -> String {
        ToolPresentation.detail(args: args, result: result, diff: diff)
    }

    static func isFailure(_ result: JSONValue) -> Bool {
        let value = result.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? result
        return value["error"] != .null && value["error"] != .bool(false) || (value["exit_code"].int ?? 0) != 0 || value["success"] == .bool(false)
    }

    mutating func consume(_ event: JSONValue) {
        if let seq = event["seq"].int {
            guard seq > lastSequence else { return }
            lastSequence = seq
        }
        let type = event["type"].string ?? "event"
        let p = event["payload"]
        switch type {
        case "message.start":
            running = true; segment = UUID().uuidString; status = "Hermes is working"
        case "message.delta": running = true; appendText(p["text"].string ?? "", role: "assistant", streaming: true)
        case "message.interim":
            if !p["already_streamed"].bool { appendText(p["text"].string ?? "", role: "assistant", streaming: true) }
            seal()
        case "message.complete":
            let text = p["text"].text
            let id = "live-\(segment)"
            if let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].content = text.isEmpty ? messages[i].content : text
                messages[i].traceFiles = CodingTrace.references(in: [.string(messages[i].content)])
            }
            else if !text.isEmpty { appendText(text, role: "assistant", streaming: false) }
            seal(); running = false
            status = p["status"].string == "interrupted" ? "Stopped" : "Connected to your Mac"
            for key in ["error", "warning", "failure_reason"] {
                if let text = p[key].string, !text.isEmpty { notice(text, failed: key != "warning") }
            }
        case "tool.start", "tool.complete":
            seal()
            let id = "tool-\(p["tool_id"].identifier ?? UUID().uuidString)"
            let index = messages.firstIndex(where: { $0.id == id })
            let prior = index.map { messages[$0] }
            let name = p["name"].string ?? prior?.activity ?? "Tool"
            let duration = p["duration_s"].formatted
            let row = ChatMessage(id: id, role: "tool", content: type == "tool.start" ? "" : ToolPresentation.summary(p["result"]),
                                  isStreaming: type == "tool.start",
                                  detail: (p["args"] == .null ? prior?.detail ?? "" : "") + Self.details(args: p["args"], result: p["result"], diff: p["inline_diff"]),
                                  activity: (p["args"] == .null ? prior?.activity ?? name : ToolPresentation.title(name, p["args"])) + (duration.isEmpty ? "" : " · \(duration)s"), failed: Self.isFailure(p["result"]),
                                  traceFiles: Array(Set((prior?.traceFiles ?? []) + CodingTrace.references(in: [p]))).sorted())
            if let index { messages[index] = row } else { messages.append(row) }
            status = type == "tool.start" ? "Using \(name)" : "Hermes is working"
        case "status.update": status = p["text"].string ?? status
        case "tool.generating": status = "Preparing \(p["name"].string ?? "tool")"
        case "session.info": info = p; running = p["running"].bool; if !running { seal() }
        case "session.reclaimed": running = false; seal(); notice("Hermes released this idle session. Your next message will reconnect.")
        case "connection.request", "connection.update": updateConnection(p, sessionID: event["session_id"].string ?? "")
        case "todo.updated":
            let todos = p["todos"].array.isEmpty ? p["todo_state"]["todos"].array : p["todos"].array
            notice(todos.map { "\($0["status"].string == "completed" ? "✓" : "○") \($0["content"].string ?? $0["text"].string ?? ToolPresentation.readable($0))" }.joined(separator: "\n"), id: "todos")
        case "session.control.update": control = p["control"]
        case "request.cancel": questions.removeAll { $0.id == p["id"].identifier }
        case "approval.cancelled": questions.removeAll { $0.method == "approval" }
        case "thinking.delta":
            if let text = p["text"].string, !text.isEmpty { status = text }
        case "reasoning.delta", "reasoning.available":
            guard let text = p["text"].string, !text.isEmpty else { return }
            let id = "reasoning-\(segment)"
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].detail += p["text"].string ?? "" }
            else { messages.append(ChatMessage(id: id, role: "activity", content: "", detail: p["text"].string ?? "", activity: "Reasoning")) }
        case "subagent.spawn_requested", "subagent.start", "subagent.progress", "subagent.tool", "subagent.complete", "subagent.thinking":
            seal()
            let identity = p["subagent_id"].identifier ?? "\(p["delegation_id"].string ?? "batch")-\(p["task_index"].int ?? 0)"
            let id = "child-\(identity)"
            let i = messages.firstIndex(where: { $0.id == id })
            var row = i.map { messages[$0] } ?? ChatMessage(id: id, role: "activity", content: p["goal"].string ?? "", activity: "Delegated task")
            row.isStreaming = type != "subagent.complete"
            row.childSessionID = p["child_session_id"].string ?? row.childSessionID
            row.detail += (row.detail.isEmpty ? "" : "\n\n") + ToolPresentation.readable(p)
            row.failed = ["failed", "error", "timeout", "interrupted"].contains(p["status"].string ?? "")
            if let summary = p["summary"].string { row.content = summary }
            row.activity = p["status"].string.map { "Delegated task · \($0)" } ?? "Delegated task"
            if let i { messages[i] = row } else { messages.append(row) }
        case "error": running = false; seal(); notice(p["message"].string ?? ToolPresentation.readable(p), failed: true)
        case "notice", "notification.show": notice(p["text"].string ?? p["message"].string ?? ToolPresentation.readable(p), failed: p["level"].string == "error", id: p["key"].string)
        case "notification.clear": messages.removeAll { $0.id == "notice-\(p["key"].string ?? "")" }
        case "preview.open":
            let ref = p["url"].string ?? ""
            notice("[\(p["label"].string ?? "Open preview")](\(ref))")
        case "voice.transcript": notice(p["text"].string ?? (p["stop_phrase"].bool ? "Voice stopped" : ""))
        case "session.resume_progress": status = p["message"].string ?? status
        case "review.summary", "background.complete", "btw.complete": seal(); notice(p["text"].string ?? ToolPresentation.readable(p))
        case "agent.terminal.output":
            let id = "terminal-\(p["terminal_id"].identifier ?? p["process_id"].identifier ?? "output")"
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].detail += p["chunk"].string ?? p["data"].string ?? p["text"].string ?? ToolPresentation.readable(p) }
            else { messages.append(ChatMessage(id: id, role: "activity", content: "", detail: p["chunk"].string ?? p["data"].string ?? p["text"].string ?? ToolPresentation.readable(p), activity: "Terminal output")) }
        case "gateway.ready", "session.usage", "session.title", "sessions.changed", "cron.changed", "projects.changed", "platforms.changed", "skin.changed", "setup.ready": break
        default:
            // New Hermes message types remain inspectable instead of vanishing.
            messages.append(ChatMessage(id: "event-\(UUID().uuidString)", role: "activity", content: p["text"].string ?? p["message"].string ?? "", detail: ToolPresentation.fields(p), activity: type.replacingOccurrences(of: ".", with: " ").capitalized))
        }
    }

    private mutating func updateConnection(_ payload: JSONValue, sessionID: String) {
        guard let op = payload["op_id"].string else { return }
        let id = "connection-" + op
        questions.removeAll { $0.id == id }
        let summary = payload["targets"].array.map { "\($0["display"].string ?? $0["name"].string ?? "Connection"): \($0["state"].string ?? "pending")" }.joined(separator: "\n")
        notice(summary, id: id)
        guard !payload["settled"].bool else { return }
        var params = payload.object; params["session_id"] = .string(sessionID)
        questions.append(HermesQuestion(id: id, method: "connection", params: .object(params)))
    }

    mutating func notice(_ text: String, failed: Bool = false, id: String? = nil) {
        let key = "notice-\(id ?? UUID().uuidString)"
        let message = ChatMessage(id: key, role: "notice", content: text, failed: failed)
        if let i = messages.firstIndex(where: { $0.id == key }) { messages[i] = message } else { messages.append(message) }
    }
    private mutating func seal() {
        for i in messages.indices where messages[i].id == "live-\(segment)" { messages[i].isStreaming = false }
        segment = UUID().uuidString
    }
    private mutating func appendText(_ text: String, role: String, streaming: Bool) {
        let id = "live-\(segment)"
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].content += text }
        else { messages.append(ChatMessage(id: id, role: role, content: text, isStreaming: streaming)) }
        if role == "assistant", let i = messages.firstIndex(where: { $0.id == id }) { messages[i].traceFiles = CodingTrace.references(in: [.string(messages[i].content)]) }
    }
}
