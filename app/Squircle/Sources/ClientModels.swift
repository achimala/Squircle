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
    /// T3's IDs for the images sent with a message of yours.
    var attachments: [String] = []
}

/// A picture waiting in the message field, sent with the next message.
struct ImageAttachment: Identifiable, Equatable {
    let id: String
    /// JPEG, small enough for T3's 10 MB per-image limit.
    let data: Data
    let thumbnail: UIImage

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

    var needsPolling: Bool {
        status == "queued" || status == "running" || previewState == "pending" || previewState == "running"
    }

    enum CodingKeys: String, CodingKey { case id, state, output, createdAt = "created_at", request }
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
    }
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

