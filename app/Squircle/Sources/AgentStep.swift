import CryptoKit
import Foundation

/// What one tool call did, said the way a person would say it. Built from the
/// tool input T3 already records (a command's own description, an edit's old
/// and new text, a screenshot's pixels), never from guesses about its output.
struct AgentStep: Equatable {
    enum Kind: String { case command, read, edit, search, web, agent, device, plan, squircle, other }
    var kind: Kind
    var title: String
    var symbol: String
    /// What it is doing while it runs ("Reading Theme.swift"), when that
    /// reads differently from what it did.
    var live: String?
    /// Shown in a monospaced face because it is literally a command.
    var literal = false
    var added = 0
    var removed = 0
    var diff: StepDiff?
    /// Tool calls that are pure bookkeeping for the agent.
    var hidden = false
    /// Squircle commands the step ran.
    var actions: [SquircleAction] = []
    /// It ran other work too (a merge, a build), which its own line shows.
    var alsoRan = false

    /// How much a description says: a written sentence beats a raw command,
    /// and an edit with its text beats one without.
    var richness: Int { (literal ? 0 : 1) + (diff != nil ? 2 : 0) + (title.count > 8 ? 1 : 0) + (actions.isEmpty ? 0 : 4) }

    /// Identity-free description of one tool call.
    static func describe(_ call: ToolCall) -> AgentStep {
        let args = call.input, name = call.tool

        switch name {
        case "Bash", "BashOutput":
            let command = args["command"].string ?? ""
            let actions = SquircleAction.parse(command: command, result: call.result)
            if let first = actions.first(where: \.visible) ?? actions.first {
                // Work besides Squircle's keeps its own line, in the agent's words.
                if actions.contains(where: \.visible), let other = CommandLabel.besidesSquircle(command) {
                    let description = args["description"].string.flatMap { $0.isEmpty ? nil : sentence($0) }
                    return AgentStep(kind: .squircle, title: description ?? other, symbol: "terminal", live: other, actions: actions, alsoRan: true)
                }
                return AgentStep(kind: .squircle, title: first.sentence(worker: nil) + (first.refused ? " · refused" : ""),
                                 symbol: first.symbol, live: first.live, actions: actions)
            }
            if let description = args["description"].string, !description.isEmpty {
                return AgentStep(kind: .command, title: sentence(description), symbol: "terminal")
            }
            return AgentStep(kind: .command, title: humanCommand(command), symbol: "terminal", live: CommandLabel.label(command), literal: true)
        case "Read":
            let path = args["file_path"].string ?? ""
            let image = ["png", "jpg", "jpeg", "heic", "gif"].contains(path.split(separator: ".").last?.lowercased() ?? "")
            return AgentStep(kind: .read, title: (image ? "Looked at " : "Read ") + file(path), symbol: image ? "photo" : "doc.text",
                             live: (image ? "Looking at " : "Reading ") + file(path))
        case "Edit", "MultiEdit", "NotebookEdit":
            let path = args["file_path"].string ?? args["notebook_path"].string ?? ""
            var old = args["old_string"].string ?? "", new = args["new_string"].string ?? args["new_source"].string ?? ""
            for edit in args["edits"].array {
                old += (old.isEmpty ? "" : "\n") + (edit["old_string"].string ?? "")
                new += (new.isEmpty ? "" : "\n") + (edit["new_string"].string ?? "")
            }
            let (added, removed) = lineDelta(old: old, new: new)
            return AgentStep(kind: .edit, title: "Edited " + file(path), symbol: "pencil.line", live: "Editing " + file(path), added: added, removed: removed,
                             diff: StepDiff(path: path, old: old, new: new))
        case "Write":
            let path = args["file_path"].string ?? ""
            let content = args["content"].string ?? ""
            let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
            return AgentStep(kind: .edit, title: "Wrote " + file(path), symbol: "doc.badge.plus", live: "Writing " + file(path), added: lines,
                             diff: StepDiff(path: path, old: "", new: content))
        case "Grep":
            return AgentStep(kind: .search, title: "Searched for “\(args["pattern"].string ?? "")”", symbol: "magnifyingglass",
                             live: "Searching for “\(args["pattern"].string ?? "")”")
        case "Glob":
            return AgentStep(kind: .search, title: "Looked for \(args["pattern"].string ?? "files")", symbol: "magnifyingglass", live: "Looking for files")
        case "WebSearch":
            return AgentStep(kind: .web, title: "Searched the web for “\(args["query"].string ?? "")”", symbol: "globe", live: "Searching the web")
        case "WebFetch":
            let host = URL(string: args["url"].string ?? "")?.host ?? "a web page"
            return AgentStep(kind: .web, title: "Read \(host)", symbol: "globe", live: "Reading \(host)")
        case "Agent", "Task":
            return AgentStep(kind: .agent, title: sentence(args["description"].string ?? "Asked a helper agent"), symbol: "person.2")
        case "TodoWrite":
            return AgentStep(kind: .plan, title: "Updated the plan", symbol: "checklist", live: "Updating the plan")
        case "Skill":
            return AgentStep(kind: .other, title: "Used \(args["skill"].string ?? "a skill")", symbol: "sparkles", live: "Using \(args["skill"].string ?? "a skill")")
        case "ToolSearch", "ListMcpResourcesTool":
            return AgentStep(kind: .other, title: "Loaded tools", symbol: "wrench.and.screwdriver", hidden: true)
        default: break
        }
        if name.hasPrefix("mcp__") {
            let tool = name.components(separatedBy: "__").last ?? name
            if name.contains("device_") {
                let action = name.components(separatedBy: "device_").last ?? ""
                switch action {
                case "open": return AgentStep(kind: .device, title: "Opened the simulator", symbol: "iphone", live: "Opening the simulator")
                case "screenshot": return AgentStep(kind: .device, title: "Looked at the simulator", symbol: "camera.viewfinder", live: "Looking at the simulator")
                case "close": return AgentStep(kind: .device, title: "Closed the simulator", symbol: "iphone.slash", live: "Closing the simulator")
                case "list": return AgentStep(kind: .device, title: "Checked simulators", symbol: "iphone", live: "Checking simulators")
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

        return AgentStep(kind: .other, title: sentence(call.title ?? "Worked"), symbol: "wrench.and.screwdriver")
    }

    /// "/a/b/Theme.swift" → "Theme.swift".
    static func file(_ path: String) -> String { (path as NSString).lastPathComponent }

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
        let difference = b.difference(from: a)
        return (difference.insertions.count, difference.removals.count)
    }
}

extension Sequence where Element == UInt8 {
    /// Lowercase hex, two digits a byte.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct StepDiff: Equatable {
    let path: String
    let old: String
    let new: String
}

/// Recordings and clips as files for AVFoundation: one cache on disk for
/// every download (conversation recordings, clips agents link, task clips).
/// Files are named by what they are, so a later launch finds them again;
/// the cache is listed at launch and bounded by bytes and age. A file used
/// in the last few minutes (a player may hold it) is never evicted. A file
/// Squircle was handed (your own recording) is not the cache's.
@MainActor
enum StepVideos {
    /// Where downloads go; anything in it is Squircle's to delete.
    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = caches.appendingPathComponent("squircle-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// Files on hand, by name, with their size and last use.
    private static var files: [String: MediaFileStore.Entry] = [:]
    /// Your own recordings, by step ID; never deleted here.
    private static var handed = BoundedCache<String, URL>(budget: 64)
    /// Downloads under way, by step ID: everyone asking waits for the one.
    private static var loads: [String: Task<URL?, Never>] = [:]
    private static var listed: Task<Void, Never>?

    static func url(for id: String) -> URL? {
        if let url = handed.value(for: id) { return url }
        let name = MediaFileStore.name(for: id)
        guard files[name] != nil else { return nil }
        files[name]?.used = .now
        return directory.appendingPathComponent(name)
    }
    /// A file Squircle didn't download, such as your own recording.
    static func set(_ url: URL, for id: String) { handed.set(url, for: id) }

    /// The file for `id`, fetched once by `fetch` (which writes the
    /// destination it's given and says whether it did), however many ask.
    static func file(for id: String, fetch: @escaping (URL) async -> Bool) async -> URL? {
        if let url = url(for: id) { return url }
        if let load = loads[id] { return await load.value }
        await list()
        if let url = url(for: id) { return url }
        let name = MediaFileStore.name(for: id), destination = directory.appendingPathComponent(name)
        let load = Task<URL?, Never> {
            guard await fetch(destination), let bytes = await MediaFileStore.size(of: destination) else { return nil }
            files[name] = MediaFileStore.Entry(name: name, bytes: bytes, used: .now)
            await evict()
            return destination
        }
        loads[id] = load
        let url = await load.value
        loads[id] = nil
        return url
    }

    /// Lists what earlier launches left, once, and trims it.
    static func list() async {
        if listed == nil {
            listed = Task {
                for entry in await MediaFileStore.scan(directory) where files[entry.name] == nil { files[entry.name] = entry }
                await evict()
            }
        }
        await listed?.value
    }

    private static func evict() async {
        let doomed = MediaFileStore.evictions(Array(files.values), now: .now)
        guard !doomed.isEmpty else { return }
        for name in doomed { files[name] = nil }
        await MediaFileStore.remove(doomed.map { directory.appendingPathComponent($0) })
    }
}

/// The disk side of `StepVideos`, off the main actor.
enum MediaFileStore {
    struct Entry: Equatable {
        let name: String
        let bytes: Int
        var used: Date
    }
    static let budget = 1 << 30
    static let maxAge: TimeInterval = 14 * 86_400
    /// A file used this recently may be playing: it stays.
    static let inUse: TimeInterval = 15 * 60

    /// A stable file name for a step ID, keeping a video's extension.
    static func name(for id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(16).hex
        let ext = (id as NSString).pathExtension.lowercased()
        return digest + "." + (["mp4", "mov", "m4v"].contains(ext) ? ext : "mp4")
    }

    /// What to delete: anything unused for `maxAge`, then the least recently
    /// used until the rest fit `budget`; never a file used within `inUse`.
    static func evictions(_ entries: [Entry], now: Date, budget: Int = budget, maxAge: TimeInterval = maxAge,
                          inUse: TimeInterval = inUse) -> [String] {
        var doomed: [String] = []
        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.used < $1.used }) {
            let idle = now.timeIntervalSince(entry.used)
            guard idle >= inUse else { continue }
            guard idle >= maxAge || total > budget else { continue }
            doomed.append(entry.name); total -= entry.bytes
        }
        return doomed
    }

    /// Replaces `destination` with `file` in one step.
    static func move(_ file: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: file)
        } else {
            try manager.moveItem(at: file, to: destination)
        }
    }
    static func size(of url: URL) async -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
    static func scan(_ directory: URL) async -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let bytes = values.fileSize else { return nil }
            return Entry(name: url.lastPathComponent, bytes: bytes,
                         used: values.contentAccessDate ?? values.contentModificationDate ?? .distantPast)
        }
    }
    static func remove(_ urls: [URL]) async {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}

/// Screenshot pixels steps returned, fetched from the Mac on demand and kept
/// outside message values so comparing conversations stays cheap. Bounded by
/// bytes; an evicted picture is fetched again when it next shows.
@MainActor
enum StepImages {
    private static var store = BoundedCache<String, Data>(budget: 64 << 20, cost: \.count)
    static func data(for id: String, index: Int) -> Data? { store.value(for: "\(id)#\(index)") }
    static func set(_ data: Data, for id: String, index: Int) { store.set(data, for: "\(id)#\(index)") }
    static func removeAll() { store.removeAll() }
}

/// Pictures and clips agents embed in their Markdown by path, keyed by
/// their step ID (`file:` and the path).
@MainActor
enum MediaFiles {
    /// Pixel sizes, so a picture's place is reserved before its bytes arrive.
    static var sizes = SizeTable()
    /// Short-lived URLs T3 signed, by thread and path: T3 signs a file for
    /// the thread whose folder it is in.
    static var urls = SignedURLs()
    nonisolated static func isVideo(_ stepID: String) -> Bool {
        ["mp4", "mov", "m4v"].contains((stepID as NSString).pathExtension.lowercased())
    }
    struct SizeTable {
        private var cache = BoundedCache<String, CGSize>(budget: 4_000)
        subscript(id: String) -> CGSize? {
            get { cache.peek(id) }
            set { if let newValue { cache.set(newValue, for: id) } else { cache.removeValue(for: id) } }
        }
    }
    struct SignedURLs {
        private var cache = BoundedCache<String, (url: URL, expires: Date)>(budget: 500)
        subscript(thread: String, path: String) -> (url: URL, expires: Date)? {
            get { cache.peek(thread + "\n" + path) }
            set { if let newValue { cache.set(newValue, for: thread + "\n" + path) } else { cache.removeValue(for: thread + "\n" + path) } }
        }
        mutating func removeAll() { cache.removeAll() }
    }
}
