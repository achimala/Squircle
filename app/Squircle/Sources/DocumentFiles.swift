import PDFKit
import UIKit

/// A document (a PDF or plain text) an agent linked in a thread or attached
/// to a task: shown as a file row, opened in the viewer.
enum DocumentSource: Hashable {
    /// A file on the Mac an agent's message in `thread` links by path.
    case linked(thread: String, path: String)
    /// A file attached to a task (`squircle task attach`).
    case attached(task: String, media: String, name: String, bytes: Int?)

    static let extensions: Set<String> = ["pdf", "md", "markdown", "txt", "log", "json", "csv"]
    static func isDocument(_ path: String) -> Bool { extensions.contains((path as NSString).pathExtension.lowercased()) }

    var name: String {
        switch self {
        case .linked(_, let path): return (path as NSString).lastPathComponent
        case .attached(_, _, let name, _): return name
        }
    }
    /// The download cache's key; ends in the file's extension.
    fileprivate var key: String {
        switch self {
        case .linked(let thread, let path): return "document:\(thread):\(path)"
        case .attached(let task, let media, let name, _): return "document:\(task):\(media)." + (name as NSString).pathExtension.lowercased()
        }
    }
    /// What kind of file it is, in a word.
    var kind: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "PDF"
        case "md", "markdown": return "Markdown"
        case "json": return "JSON"
        case "csv": return "CSV"
        case "log": return "Log"
        default: return "Text"
        }
    }
    var symbol: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "json": return "curlybraces"
        case "csv": return "tablecells"
        default: return "doc.text"
        }
    }
}

/// Documents downloaded once into the media cache (`StepVideos`), and what
/// is known of each: its size, then its pages once it is on the phone. On
/// a metered network a document downloads only when opened.
@MainActor
final class DocumentFiles {
    struct Info: Equatable {
        var bytes: Int?
        var pages: Int?
        /// It couldn't be fetched (gone from the Mac, or no longer linked).
        var failed = false
    }
    private let client: SquircleClient?
    private let metered: () -> Bool
    private(set) var info: [DocumentSource: Info] = [:]

    init(client: SquircleClient?, metered: @escaping () -> Bool) {
        self.client = client
        self.metered = metered
    }

    /// Its size and, when it may download now, its pages.
    func describe(_ source: DocumentSource) async -> Info {
        if let known = info[source], known.failed || known.pages != nil || metered() && known.bytes != nil { return known }
        if case .attached(_, _, _, let bytes?) = source { info[source, default: Info()].bytes = bytes }
        if metered() {
            if info[source]?.bytes == nil, case .linked(let thread, let path) = source, let client {
                do { info[source, default: Info()].bytes = try await client.documentSize(threadID: thread, path: path) }
                catch is CancellationError {} catch { info[source, default: Info()].failed = true }
            }
            return info[source] ?? Info()
        }
        _ = await file(source)
        return info[source] ?? Info()
    }

    /// The document on the phone under its own name (what the viewer shows
    /// and shares), downloading it first if need be.
    func file(_ source: DocumentSource) async -> URL? {
        guard let client else { return nil }
        let cached = await StepVideos.file(for: source.key) { destination in
            do {
                switch source {
                case .linked(let thread, let path): try await client.downloadDocument(threadID: thread, path: path, to: destination)
                case .attached(let task, let media, _, _): try await client.downloadTaskMedia(taskID: task, id: media, to: destination)
                }
                return true
            } catch { return false }
        }
        guard let cached else {
            if !Task.isCancelled { info[source, default: Info()].failed = true }
            return nil
        }
        let named = await Self.named(cached, source.name)
        var known = info[source] ?? Info()
        known.failed = false
        known.bytes = await MediaFileStore.size(of: cached)
        if known.pages == nil, source.kind == "PDF" { known.pages = await Self.pages(cached) }
        info[source] = known
        return named
    }

    /// A hard link to the cached file under the document's own name.
    private nonisolated static func named(_ cached: URL, _ name: String) async -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("documents", isDirectory: true)
            .appendingPathComponent(cached.deletingPathExtension().lastPathComponent, isDirectory: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(safe.isEmpty ? cached.lastPathComponent : safe)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        if (try? FileManager.default.linkItem(at: cached, to: url)) == nil { try? FileManager.default.copyItem(at: cached, to: url) }
        return url
    }

    private nonisolated static func pages(_ url: URL) async -> Int? {
        PDFDocument(url: url)?.pageCount
    }
}
