import Foundation

/// What one tool call did, said the way a person would say it. Built from the
/// tool input T3 already records (a command's own description, an edit's old
/// and new text, a screenshot's pixels), never from guesses about its output.
struct AgentStep: Equatable {
    enum Kind: String { case command, read, edit, search, web, agent, device, plan, other }
    var kind: Kind
    var title: String
    var symbol: String
    /// Shown in a monospaced face because it is literally a command.
    var literal = false
    var added = 0
    var removed = 0
    var diff: StepDiff?
    /// Tool calls that are pure bookkeeping for the agent.
    var hidden = false

    /// How much a description says: a written sentence beats a raw command,
    /// and an edit with its text beats one without.
    var richness: Int { (literal ? 0 : 1) + (diff != nil ? 2 : 0) + (title.count > 8 ? 1 : 0) }

    /// Identity-free description for one activity payload.
    static func describe(_ activity: JSONValue) -> AgentStep {
        let p = activity["payload"], data = p["data"]
        let input = data["input"]
        let tool = data["toolName"].string ?? ""
        let detail = p["detail"].string ?? ""
        let kind = activity["kind"].string ?? ""
        if kind.hasPrefix("task.") {
            return AgentStep(kind: .agent, title: sentence(p["title"].string ?? p["detail"].string ?? activity["summary"].string ?? "Background task"), symbol: "person.2")
        }
        // Claude's tool input arrives structured; Codex sometimes only as "Name: {json}".
        var args = input
        if args == .null, let colon = detail.range(of: ": "),
           let json = try? JSONDecoder().decode(JSONValue.self, from: Data(detail[colon.upperBound...].utf8)) { args = json }
        let name = tool.isEmpty ? String(detail.prefix { $0 != ":" }) : tool

        switch name {
        case "Bash", "BashOutput":
            let command = args["command"].string ?? data["command"].string ?? ""
            if let description = args["description"].string, !description.isEmpty {
                return AgentStep(kind: .command, title: sentence(description), symbol: "terminal")
            }
            return AgentStep(kind: .command, title: humanCommand(command), symbol: "terminal", literal: true)
        case "Read":
            let path = args["file_path"].string ?? ""
            let image = ["png", "jpg", "jpeg", "heic", "gif"].contains(path.split(separator: ".").last?.lowercased() ?? "")
            return AgentStep(kind: .read, title: (image ? "Looked at " : "Read ") + file(path), symbol: image ? "photo" : "doc.text")
        case "Edit", "MultiEdit", "NotebookEdit":
            let path = args["file_path"].string ?? args["notebook_path"].string ?? ""
            var old = args["old_string"].string ?? "", new = args["new_string"].string ?? args["new_source"].string ?? ""
            for edit in args["edits"].array {
                old += (old.isEmpty ? "" : "\n") + (edit["old_string"].string ?? "")
                new += (new.isEmpty ? "" : "\n") + (edit["new_string"].string ?? "")
            }
            let (added, removed) = lineDelta(old: old, new: new)
            return AgentStep(kind: .edit, title: "Edited " + file(path), symbol: "pencil.line", added: added, removed: removed,
                             diff: StepDiff(path: path, old: old, new: new))
        case "Write":
            let path = args["file_path"].string ?? ""
            let content = args["content"].string ?? ""
            let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
            return AgentStep(kind: .edit, title: "Wrote " + file(path), symbol: "doc.badge.plus", added: lines,
                             diff: StepDiff(path: path, old: "", new: content))
        case "Grep":
            return AgentStep(kind: .search, title: "Searched for “\(args["pattern"].string ?? "")”", symbol: "magnifyingglass")
        case "Glob":
            return AgentStep(kind: .search, title: "Looked for \(args["pattern"].string ?? "files")", symbol: "magnifyingglass")
        case "WebSearch":
            return AgentStep(kind: .web, title: "Searched the web for “\(args["query"].string ?? "")”", symbol: "globe")
        case "WebFetch":
            let host = URL(string: args["url"].string ?? "")?.host ?? "a web page"
            return AgentStep(kind: .web, title: "Read \(host)", symbol: "globe")
        case "Agent", "Task":
            return AgentStep(kind: .agent, title: sentence(args["description"].string ?? "Asked a helper agent"), symbol: "person.2")
        case "TodoWrite":
            return AgentStep(kind: .plan, title: "Updated the plan", symbol: "checklist")
        case "Skill":
            return AgentStep(kind: .other, title: "Used \(args["skill"].string ?? "a skill")", symbol: "sparkles")
        case "ToolSearch", "ListMcpResourcesTool":
            return AgentStep(kind: .other, title: "Loaded tools", symbol: "wrench.and.screwdriver", hidden: true)
        default: break
        }
        if name.hasPrefix("mcp__") {
            let tool = name.components(separatedBy: "__").last ?? name
            if name.contains("device_") {
                let action = name.components(separatedBy: "device_").last ?? ""
                switch action {
                case "open": return AgentStep(kind: .device, title: "Opened the simulator", symbol: "iphone")
                case "screenshot": return AgentStep(kind: .device, title: "Looked at the simulator", symbol: "camera.viewfinder")
                case "close": return AgentStep(kind: .device, title: "Closed the simulator", symbol: "iphone.slash")
                case "list": return AgentStep(kind: .device, title: "Checked simulators", symbol: "iphone")
                default: break
                }
            }
            if name.contains("preview_") {
                return AgentStep(kind: .web, title: "Used the browser preview", symbol: "safari")
            }
            if name.contains("link_pull_request") || name.contains("list_thread_pull_requests") {
                return AgentStep(kind: .other, title: "Linked the pull request", symbol: "arrow.triangle.pull")
            }
            return AgentStep(kind: .other, title: sentence(tool.replacingOccurrences(of: "_", with: " ")), symbol: "puzzlepiece.extension")
        }

        // Codex native items.
        let item = data["item"]
        if let command = data["command"].string ?? item["command"].string ?? (p["itemType"].string == "command_execution" ? detail : nil) {
            let actions = item["commandActions"].array
            if !actions.isEmpty, actions.allSatisfy({ $0["type"].string == "read" }) {
                let names = actions.compactMap { $0["name"].string ?? $0["path"].string.map(file) }
                return AgentStep(kind: .read, title: "Read " + names.joined(separator: ", "), symbol: "doc.text")
            }
            if let search = actions.first(where: { $0["type"].string == "search" }), let query = search["query"].string {
                return AgentStep(kind: .search, title: "Searched for “\(query)”", symbol: "magnifyingglass")
            }
            if actions.count == 1, actions[0]["type"].string == "listFiles" {
                return AgentStep(kind: .search, title: "Listed files", symbol: "folder")
            }
            return AgentStep(kind: .command, title: humanCommand(command), symbol: "terminal", literal: true)
        }
        switch p["itemType"].string {
        case "file_change":
            let paths = item["changes"].array.compactMap { $0["path"].string }
            let title = paths.isEmpty ? "Edited files" : "Edited " + paths.map(file).joined(separator: ", ")
            return AgentStep(kind: .edit, title: title, symbol: "pencil.line")
        case "web_search": return AgentStep(kind: .web, title: "Searched the web", symbol: "globe")
        case "image_view":
            return AgentStep(kind: .read, title: "Looked at " + file(data["imagePath"].string ?? "an image"), symbol: "photo")
        default: break
        }
        let fallback = p["title"].string ?? activity["summary"].string ?? "Worked"
        return AgentStep(kind: .other, title: sentence(detail.isEmpty ? fallback : detail), symbol: "wrench.and.screwdriver")
    }

    /// "/a/b/Theme.swift" → "Theme.swift".
    static func file(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func sentence(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Drops shell wrappers and `cd somewhere &&` so the command itself shows.
    static func humanCommand(_ command: String) -> String {
        var text = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        for wrapper in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where text.hasPrefix(wrapper) {
            text = String(text.dropFirst(wrapper.count))
            if text.count > 1, let quote = text.first, quote == "'" || quote == "\"", text.last == quote { text = String(text.dropFirst().dropLast()) }
        }
        while text.hasPrefix("cd "), let range = text.range(of: " && ") { text = String(text[range.upperBound...]) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func lineDelta(old: String, new: String) -> (Int, Int) {
        let a = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var counts: [String: Int] = [:]
        for line in a { counts[line, default: 0] += 1 }
        var common = 0
        for line in b where (counts[line] ?? 0) > 0 { counts[line]! -= 1; common += 1 }
        return (b.count - common, a.count - common)
    }
}

struct StepDiff: Equatable {
    let path: String
    let old: String
    let new: String
}

/// Screenshot pixels steps returned, fetched from the Mac on demand and kept
/// outside message values so comparing conversations stays cheap.
/// Downloaded recordings, kept as local files for AVFoundation.
enum StepVideos {
    nonisolated(unsafe) private static var files: [String: URL] = [:]
    static func url(for id: String) -> URL? { files[id] }
    static func set(_ url: URL, for id: String) { files[id] = url }
}

enum StepImages {
    nonisolated(unsafe) private static var store: [String: Data] = [:]
    static func data(for id: String, index: Int) -> Data? { store["\(id)#\(index)"] }
    static func set(_ data: Data, for id: String, index: Int) { store["\(id)#\(index)"] = data }
}
