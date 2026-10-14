import Foundation
import UIKit

struct ChatSession: Identifiable, Equatable {
    /// What a thread is doing right now, from T3's live shell.
    enum Phase: Equatable { case idle, working, needsYou }
    let id: String
    let title: String
    let preview: String
    let updatedAt: Date
    var phase = Phase.idle
    var modelSelection = JSONValue.null

    init(id: String, title: String, preview: String = "", updatedAt: Date = .now,
         phase: Phase = .idle, modelSelection: JSONValue = .null) {
        self.id = id; self.title = title; self.preview = preview
        self.updatedAt = updatedAt; self.phase = phase; self.modelSelection = modelSelection
    }
}

struct ChatMessage: Identifiable, Equatable {
    var id: String
    /// Recordings sent with a message of yours, by path on the Mac.
    var captures: [SentCapture] = []
    /// "user", "assistant", "thinking" (reasoning summary) or "tool".
    let role: String
    var content: String
    var isStreaming = false
    var detail: String = ""
    var activity: String?
    var failed = false
    /// SF Symbol for a tool step.
    var symbol: String = ""
    var createdAt = ""
    /// What a tool step did, in words; nil for text.
    var step: AgentStep?
    /// Screenshots this step returned, held in `StepImages` under `id`.
    var imageCount = 0
    /// A recording published into the thread with `squircle media add`.
    var videoID: String?
    /// The T3 turn this belongs to.
    var turnID: String?
    /// Squircle's note to an app agent that its workers moved on, not
    /// something the person wrote.
    var isUpdate = false
    /// The worker threads an update is about.
    var threadIDs: [String] = []
    /// What each worker in an update did.
    var news: [WorkerNews] = []
    /// Set when an agent, not the person, wrote this user message: a
    /// worker's task or a `squircle thread send`.
    var agent: AgentAuthor?
    /// T3's IDs for the images sent with a message of yours.
    var attachments: [String] = []
}

/// A worker's state as Squircle reports it.
enum WorkerState: String, Equatable {
    case working, done, needsYou = "needs-you", error, archived
    var word: String {
        switch self {
        case .working: return "working"
        case .done: return "done"
        case .needsYou: return "needs you"
        case .error: return "error"
        case .archived: return "archived"
        }
    }
}

/// One worker in Squircle's wake-up message to an app agent.
struct WorkerNews: Equatable {
    let id: String
    let title: String
    let state: WorkerState
}

/// A user message Squircle sent for an agent, marked by the service.
struct AgentAuthor: Equatable {
    enum Kind: Equatable { case task, message }
    let kind: Kind
    /// The agent's thread.
    let from: String?
}

/// A screen or performance recording a message links to.
struct SentCapture: Equatable {
    let label: String
    let path: String
    var isVideo: Bool { MediaFiles.isVideo("file:" + path) }

    /// Starts the recordings block after what you typed; the conversation
    /// shows it as the recordings themselves.
    static let marker = "\n\nRecorded in the app:"

    /// The lines a message carries for `captures`, after `marker`.
    static func block(_ captures: [(label: String, path: String, video: Bool)]) -> String {
        guard !captures.isEmpty else { return "" }
        return marker + captures.map { capture in
            let link = "\n[\(capture.label)](\(capture.path))"
            return capture.video ? link
                : link + " (performance capture: run `squircle perf show \(capture.path)` for hitches, symbolicated main-thread stacks and a timeline)"
        }.joined()
    }

    /// The recordings in a message's block.
    static func parse(_ text: String) -> [SentCapture] {
        guard let start = text.range(of: marker) else { return [] }
        var block = text[start.upperBound...]
        if let end = block.range(of: AppProject.contextMarker) { block = block[..<end.lowerBound] }
        return block.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.range(of: "]("),
                  let end = line[close.upperBound...].firstIndex(of: ")") else { return nil }
            let path = String(line[close.upperBound..<end])
            guard path.hasPrefix("/") else { return nil }
            return SentCapture(label: String(line[line.index(after: line.startIndex)..<close.lowerBound]), path: path)
        }
    }
}

/// A picture waiting in the message field, sent with the next message.
struct ImageAttachment: Identifiable, Equatable {
    let id: String
    /// JPEG, small enough for T3's 10 MB per-image limit.
    let data: Data
    let thumbnail: UIImage
    /// Set for a screen or performance recording: it goes to the Mac through
    /// Squircle, and the message links it, instead of going to T3 as a picture.
    var capture: Capture?

    struct Capture: Equatable {
        enum Kind: String { case video, performance }
        let kind: Kind
        let file: URL
        /// Its length (and, for performance, its hitches), e.g. "0:12 · 3 hitches".
        let label: String
    }

    init(capture: Capture, thumbnail: UIImage, id: String = UUID().uuidString) {
        self.id = id
        self.capture = capture
        self.thumbnail = thumbnail
        data = thumbnail.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// Scales `image` so its long side is at most 2000 pixels.
    init?(_ image: UIImage, id: String = UUID().uuidString) {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let fit = min(1, 2000 / max(1, max(pixels.width, pixels.height)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (pixels.width * fit).rounded(), height: (pixels.height * fit).rounded())
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.82) else { return nil }
        self.id = id
        self.data = data
        thumbnail = resized.preparingThumbnail(of: CGSize(width: 160, height: 160 * size.height / max(1, size.width))) ?? resized
    }
}

/// What one turn changed in the project, from T3's checkpoint for it.
struct TurnChanges: Equatable {
    struct File: Equatable {
        let path: String
        let kind: String
        let additions: Int
        let deletions: Int
    }
    let turnID: String
    /// T3 numbers checkpoints by turn; a turn's diff runs from count − 1.
    let count: Int
    let assistantMessageID: String?
    let files: [File]
    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

struct AppBuild: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let version: String
    let status: String
    let date: Date
    let canInstall: Bool
    let bundleID: String?
    let request: AppBuildRequest?
    let previewAvailable: Bool
    let previewState: String?
    let previewError: String?
    let previewCapturedAt: Date?
    let updatedAt: Date
    /// The service's error for a job that didn't succeed.
    let error: String?
    let sourceRevision: String?
    let sourceDirty: Bool?

    var needsPolling: Bool {
        status == "queued" || status == "running" || previewState == "pending" || previewState == "running"
    }

    enum CodingKeys: String, CodingKey {
        case id, state, output, request, error
        case createdAt = "created_at", updatedAt = "updated_at", sourceRevision = "source_revision", sourceDirty = "source_dirty"
    }
    private struct Output: Decodable {
        let title: String?
        let version: String?
        let build_number: String?
        let ipa_path: String?
        let bundle_id: String?
        let preview_path: String?
        let preview_state: String?
        let preview_error: String?
        let preview_captured_at: Double?
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .state)
        let output = try values.decodeIfPresent(Output.self, forKey: .output)
        request = try values.decodeIfPresent(AppBuildRequest.self, forKey: .request)
        title = output?.title ?? request?.scheme ?? "App build"
        bundleID = output?.bundle_id
        version = [output?.version, output?.build_number.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        canInstall = status == "succeeded" && output?.ipa_path != nil
        previewState = output?.preview_state
        previewError = output?.preview_error
        previewCapturedAt = output?.preview_captured_at.map { Date(timeIntervalSince1970: $0) }
        previewAvailable = !(output?.preview_path ?? "").isEmpty && (previewState == nil || previewState == "succeeded")
        date = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .createdAt))
        updatedAt = (try values.decodeIfPresent(Double.self, forKey: .updatedAt)).map(Date.init(timeIntervalSince1970:)) ?? date
        error = try values.decodeIfPresent(String.self, forKey: .error)
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        sourceDirty = try values.decodeIfPresent(Bool.self, forKey: .sourceDirty)
    }
}

/// Why a build failed, as the Mac read it from the build's log.
struct BuildFailure: Decodable, Equatable {
    struct Issue: Decodable, Equatable {
        let message: String
        let file: String?
        let line: Int?
        /// Xcode's hint or the compiler's source excerpt.
        let detail: String?
    }
    let message: String?
    let step: String?
    let exitStatus: Int?
    let errors: [Issue]
    let failedCommands: [String]

    enum CodingKeys: String, CodingKey { case message, step, errors, exitStatus = "exit_status", failedCommands = "failed_commands" }
}

struct BuildLogPage: Decodable {
    let text: String
    let nextOffset: Int
    let hasMore: Bool
    let size: Int?
    enum CodingKeys: String, CodingKey { case text, size, nextOffset = "next_offset", hasMore = "has_more" }
}

struct AgentApproval: Identifiable, Equatable {
    let id: String
    let runID: String
    let prompt: String
    let command: String
    let choices: [String]
}

/// JSON content can be text or multimodal blocks. Reasoning fields are never projected.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var int: Int? { if case .number(let v) = self { return Int(v) }; return nil }
    var double: Double? { if case .number(let v) = self { return v }; return nil }
    var formatted: String {
        if let string { return string }
        if self == .null { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? ""
    }
    subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
    var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var text: String {
        if let string { return string }
        return array.compactMap { block in
            let block = block.object
            guard ["text", "input_text", "output_text"].contains(block["type"]?.string ?? "") else { return nil }
            return block["text"]?.string
        }.joined(separator: "\n")
    }
    var identifier: String? {
        if let string { return string }
        if case .number(let number) = self { return String(format: "%.0f", number) }
        return nil
    }
}


/// One thing the user asked an app's agent for, and where it stands
/// (`squircle task`). Linked threads and builds come with their state.
struct AppTask: Decodable, Equatable, Identifiable {
    enum Status: String, Decodable, CaseIterable {
        case needsYou = "needs_you", inProgress = "in_progress", readyToTry = "ready_to_try", queued, done, dropped
        var open: Bool { self != .done && self != .dropped }
    }
    struct Thread: Decodable, Equatable { let id: String; let title: String?; let state: String }
    struct Build: Decodable, Equatable {
        let id: String; let state: String; let title: String?; let version: String?
        let buildNumber: String?; let installable: Bool?
        enum CodingKeys: String, CodingKey { case id, state, title, version, installable, buildNumber = "build_number" }
    }
    struct Media: Decodable, Equatable { let id: String; let kind: String; let caption: String }

    let id: String
    let ask: String
    let status: Status
    let note: String
    let order: Double
    let updatedAt: Double
    let archivedAt: Double?
    let threads: [Thread]
    let builds: [Build]
    let media: [Media]

    enum CodingKeys: String, CodingKey {
        case id, ask, status, note, order, threads, builds, media
        case updatedAt = "updated_at", archivedAt = "archived_at"
    }
}

/// An app's tasks: the active list and History.
struct AppTasks: Decodable, Equatable {
    var tasks: [AppTask] = []
    var history: [AppTask] = []
}
