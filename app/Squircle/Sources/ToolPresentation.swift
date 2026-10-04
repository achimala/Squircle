import Foundation

/// Presentation only: Hermes and the CLI retain ownership of execution and history.
enum ToolPresentation {
    static func decoded(_ value: JSONValue) -> JSONValue {
        guard let s = value.string, let data = s.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { return value }
        return parsed
    }

    static func title(_ name: String, _ args: JSONValue) -> String {
        let path = args["file_path"].string ?? args["path"].string ?? args["changes"].array.first?["path"].string ?? ""
        let file = URL(fileURLWithPath: path).lastPathComponent
        switch name.lowercased() {
        case "read", "read_file": return "Read \(file.isEmpty ? "file" : file)"
        case "write", "write_file": return "Write \(file.isEmpty ? "file" : file)"
        case "edit", "patch", "apply_patch": return "Edit \(file.isEmpty ? "file" : file)"
        case "grep", "glob", "search_files": return "Search · \(args["pattern"].string ?? args["query"].string ?? file)"
        case "bash", "terminal", "exec_command":
            if let description = args["description"].string { return description }
            let command = args["command"].string ?? ""
            if command.contains("squircle build status") { return "Check app build" }
            if command.contains("squircle build start") { return "Build app" }
            if command.contains("squircle install-link") { return "Prepare installation" }
            if command.contains("squircle preview") { return "Capture simulator preview" }
            if command.contains("claude") && (command.contains("jsonl") || command.contains("task-0.log")) && !command.contains("claude -p") { return "Read Claude Code progress" }
            if command.contains("claude -p") { return "Claude Code · coding task" }
            let executable = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            if ["python3", "python"].contains(executable) { return "Run Python script" }
            if executable == "ps" { return "Check running processes" }
            if executable == "tail" { return "Read command output" }
            return "Run \(command.split(separator: "\n").first.map(String.init).map { String($0.prefix(90)) } ?? "command")"
        case "skill_view": return "Read \(args["name"].string ?? "agent") instructions"
        case "delegate_task":
            switch args["action"].string {
            case "list": return "Check coding agent progress"
            case "stop": return "Stop coding agent"
            case "steer": return "Guide coding agent"
            default: return "Delegate coding task"
            }
        case "process_manage": return "Check running command"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func readable(_ raw: JSONValue) -> String {
        let value = decoded(raw)
        if value["type"].string == "image" { return "Image returned by tool" }
        if let s = value.string { return s.replacingOccurrences(of: "<tool_use_error>", with: "").replacingOccurrences(of: "</tool_use_error>", with: "") }
        if !value.array.isEmpty { return value.array.map(readable).filter { !$0.isEmpty }.joined(separator: "\n") }
        for key in ["output", "text", "content", "result", "message", "summary", "description"] {
            if value[key] != .null { return readable(value[key]) }
        }
        if !value["files"].array.isEmpty { return value["files"].array.compactMap(\.string).joined(separator: "\n") }
        // Unknown fields remain readable without exposing a serialized object.
        return fields(value)
    }

    static func fields(_ value: JSONValue) -> String {
        return value.object.keys.sorted().filter { !["approval", "session_id", "tool_call_id", "token_usage"].contains($0) }.compactMap { key in
            let item = value[key]
            guard item != .null else { return nil }
            return "\(key.replacingOccurrences(of: "_", with: " ").capitalized): \(item.string ?? (item.object.isEmpty && item.array.isEmpty ? item.formatted : readable(item)))"
        }.joined(separator: "\n")
    }

    static func detail(args: JSONValue, result: JSONValue, diff: JSONValue = .null) -> String {
        var parts: [String] = []
        if let command = args["command"].string { parts.append("Command\n" + command) }
        if let path = args["file_path"].string ?? args["path"].string { parts.append(path) }
        if let old = args["old_string"].string, let new = args["new_string"].string {
            parts.append("Changes\n" + old.components(separatedBy: "\n").map { "− " + $0 }.joined(separator: "\n") + "\n" + new.components(separatedBy: "\n").map { "+ " + $0 }.joined(separator: "\n"))
        }
        if let contents = args["content"].string { parts.append("File contents\n" + contents) }
        if let pattern = args["pattern"].string { parts.append("Search: " + pattern) }
        if parts.isEmpty, args != .null { parts.append(fields(args)) }
        let body = readable(result)
        if !body.isEmpty { parts.append("Output\n" + body) }
        if diff != .null { parts.append("Changes\n" + readable(diff)) }
        return parts.joined(separator: "\n\n")
    }

    static func summary(_ raw: JSONValue) -> String {
        let result = decoded(raw)
        if let error = result["error"].string, !error.isEmpty { return String(error.prefix(240)) }
        if result["process_running"].bool { return "Still working" }
        if let count = result["total_count"].int { return "\(count) matches" }
        if result["status"].string == "dispatched" { return "Coding agent started" }
        let nested = decoded(result["output"])
        let job = nested["data"]["job"]
        if let state = job["state"].string { return "Build " + state }
        if let agents = result["subagents"].array.first { return agents["status"].string?.capitalized ?? "" }
        let text = readable(result).trimmingCharacters(in: .whitespacesAndNewlines)
        if HermesConversation.isFailure(result) { return String(text.split(separator: "\n").prefix(2).joined(separator: "\n").prefix(200)) }
        // Long console dumps, instructions and metadata belong in the detail view.
        guard text.count <= 120, text.components(separatedBy: "\n").count <= 2,
              !text.contains("/Users/"), !text.contains("{\""), result.object.isEmpty || result["output"] != .null else { return "" }
        return text
    }
}

/// Presents the CLIs’ documented JSON event streams; never launches or controls an agent.
struct CodingTrace {
    var messages: [ChatMessage] = []
    var model = "Claude Code"
    var authentication = "Authentication not recorded"
    var state = "Recorded activity"

    static func references(in rows: [JSONValue]) -> [String] {
        let source = rows.map(\.formatted).joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"/[^\s\"'<>\\]+(?:[Cc]laude|[Cc]odex)[^\s\"'<>\\]*\.jsonl"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            guard let range = Range($0.range, in: source) else { return nil }
            let path = String(source[range]); return seen.insert(path).inserted ? path : nil
        }
    }

    static func parse(_ data: Data) -> Self {
        var trace = Self()
        var tools: [String: Int] = [:]
        var seen = Set<String>()
        for line in data.split(separator: 10) {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue } // partial final line during a live write
            let type = event["type"].string ?? ""
            if type == "thread.started" { trace.model = "Codex"; trace.state = "Working" }
            if type == "turn.started" { trace.state = "Working" }
            if type == "turn.completed" { trace.state = "Completed" }
            if type == "turn.failed" || type == "error" {
                trace.state = "Failed"
                trace.messages.append(ChatMessage(id: "error-\(trace.messages.count)", role: "assistant", content: ToolPresentation.readable(event["error"] == .null ? event["message"] : event["error"]), failed: true))
            }
            if ["item.started", "item.updated", "item.completed"].contains(type) {
                let item = event["item"], kind = item["type"].string ?? ""
                let id = item["id"].string ?? "item-\(trace.messages.count)"
                var message: ChatMessage?
                switch kind {
                case "agent_message": message = ChatMessage(id: id, role: "assistant", content: item["text"].string ?? "")
                case "command_execution":
                    message = ChatMessage(id: id, role: "tool", content: "", isStreaming: type != "item.completed", detail: ToolPresentation.detail(args: item, result: item["aggregated_output"]), activity: ToolPresentation.title("terminal", item), failed: (item["exit_code"].int ?? 0) != 0 || item["status"].string == "failed")
                case "file_change":
                    let changes = item["changes"].array.map { change in
                        "\(change["kind"].string ?? "Edit") \(change["path"].string ?? "file")\n\(change["diff"].string ?? "")"
                    }.joined(separator: "\n\n")
                    message = ChatMessage(id: id, role: "tool", content: "", isStreaming: type != "item.completed", detail: changes, activity: ToolPresentation.title("apply_patch", item), failed: item["status"].string == "failed")
                case "mcp_tool_call":
                    message = ChatMessage(id: id, role: "tool", content: "", isStreaming: type != "item.completed", detail: ToolPresentation.detail(args: item["arguments"], result: item["result"]), activity: ToolPresentation.title(item["tool"].string ?? "Tool", item["arguments"]), failed: item["status"].string == "failed")
                case "web_search": message = ChatMessage(id: id, role: "tool", content: "", detail: item["query"].string ?? "", activity: "Search · " + (item["query"].string ?? "web"))
                case "todo_list": message = ChatMessage(id: id, role: "assistant", content: item["items"].array.map { ($0["completed"].bool ? "✓ " : "○ ") + ($0["text"].string ?? "") }.joined(separator: "\n"))
                default: break // Protocol/reasoning events are not user-facing activity.
                }
                if let message {
                    if let index = tools[id] { trace.messages[index] = message }
                    else { tools[id] = trace.messages.count; trace.messages.append(message) }
                }
            }
            if type == "system", event["subtype"].string == "init" {
                trace.model = event["model"].string ?? trace.model
                trace.state = "Working"
                let source = event["apiKeySource"].string ?? ""
                trace.authentication = source == "ANTHROPIC_API_KEY" ? "API key · this recorded run used API billing" : source.lowercased().contains("oauth") ? "Claude subscription" : "Authentication: \(source.isEmpty ? "not recorded" : source)"
            }
            if type == "assistant" {
                let messageID = event["message"]["id"].string ?? UUID().uuidString
                for (n, block) in event["message"]["content"].array.enumerated() {
                    let id = block["id"].string ?? "\(messageID)-\(n)"
                    guard seen.insert(id).inserted else { continue }
                    if block["type"].string == "text", let text = block["text"].string, !text.isEmpty {
                        trace.messages.append(ChatMessage(id: id, role: "assistant", content: text))
                    } else if block["type"].string == "tool_use" {
                        let name = block["name"].string ?? "Tool", args = block["input"]
                        tools[id] = trace.messages.count
                        let path = args["file_path"].string ?? ""
                        let isImage = name == "Read" && ["png", "jpg", "jpeg", "webp", "gif"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
                        trace.messages.append(ChatMessage(id: id, role: "tool", content: isImage ? "@image:\"\(path)\"" : "", isStreaming: true, detail: ToolPresentation.detail(args: args, result: .null), activity: ToolPresentation.title(name, args)))
                    }
                }
            }
            if type == "user" {
                for block in event["message"]["content"].array where block["type"].string == "tool_result" {
                    guard let id = block["tool_use_id"].string, let index = tools[id] else { continue }
                    let output = ToolPresentation.readable(block["content"])
                    trace.messages[index].detail += "\n\nOutput\n" + output
                    trace.messages[index].isStreaming = false
                    trace.messages[index].failed = block["is_error"].bool
                    // Output is available on disclosure; command metadata never swamps the timeline.
                    if block["is_error"].bool { trace.messages[index].content = String(output.split(separator: "\n").first?.prefix(120) ?? "") }
                }
            }
            if type == "result" {
                trace.state = event["subtype"].string == "success" ? "Completed" : "Stopped · \(event["num_turns"].int ?? 0) turns"
            }
        }
        return trace
    }
}
