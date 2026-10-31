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
    /// T3's newest turn in this thread, as the shell last reported it.
    var latestTurn: TurnObservation?

    init(id: String, title: String, preview: String = "", updatedAt: Date = .now,
         phase: Phase = .idle, modelSelection: JSONValue = .null, latestTurn: TurnObservation? = nil) {
        self.id = id; self.title = title; self.preview = preview
        self.updatedAt = updatedAt; self.phase = phase; self.modelSelection = modelSelection
        self.latestTurn = latestTurn
    }
}

/// A thread's newest turn as T3 observed it. A finished one is a
/// `TurnCompletion`: whether work completed comes from here, never from a
/// row that stopped showing as working.
struct TurnObservation: Equatable {
    enum State: Equatable {
        case running, completed, interrupted, error
        /// A state this build doesn't know; never read as finished.
        case unknown(String)
    }
    let turnID: String
    let state: State
    let endedAt: Date?
    /// From a thread's shell row: its latest run, whose status is the
    /// row's `status` (`idle` only for a thread with no run).
    init?(shell row: JSONValue) {
        guard let run = row["latestRunId"].string else { return nil }
        turnID = run
        switch row["status"].string ?? "" {
        case "preparing", "queued", "starting", "running", "waiting": state = .running
        case "completed": state = .completed
        case "interrupted", "cancelled": state = .interrupted
        case "failed": state = .error
        case let other: state = .unknown(other)
        }
        endedAt = row["latestRunCompletedAt"].string.flatMap(ISODate.parse)
    }
    /// The turn's end, when it has ended.
    var completion: TurnCompletion? {
        switch state {
        case .completed: TurnCompletion(turnID: turnID, endedAt: endedAt, outcome: .completed)
        case .interrupted: TurnCompletion(turnID: turnID, endedAt: endedAt, outcome: .interrupted)
        case .error: TurnCompletion(turnID: turnID, endedAt: endedAt, outcome: .failed)
        case .running, .unknown: nil
        }
    }
}

/// A turn T3 reported finished: the event a "Done" notice is about.
struct TurnCompletion: Equatable, Hashable {
    enum Outcome: Hashable { case completed, interrupted, failed }
    let turnID: String
    let endedAt: Date?
    let outcome: Outcome
}

struct ChatMessage: Identifiable, Equatable {
    var id: String
    /// Recordings sent with a message of yours, by path on the Mac.
    var captures: [SentCapture] = []
    /// "user", "assistant", "thinking" (reasoning summary) or "tool".
    let role: String
    var content: String
    /// One piece of a message cut at its tables and pictures, already
    /// parsed; `content` is then its plain text.
    var markdown: AttributedString?
    var isStreaming = false
    var detail: String = ""
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
    /// Squircle telling an app agent that one of its builds finished.
    var build: BuildNews?
}

/// A finished build in Squircle's update to its app agent.
struct BuildNews: Equatable {
    let id: String
    let app: String
    let succeeded: Bool
    /// Why it failed, in a line.
    let reason: String?
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
    /// "Dark mode finished", "Launch crash needs input".
    var summary: String {
        switch state {
        case .needsYou: return title + " needs input"
        case .error: return title + " stopped with an error"
        default: return title + " finished"
        }
    }
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
        /// What it is, for the sent message: a recording unless you picked a video.
        var name: String?
        /// How the sent message names it.
        var sentLabel: String { (name ?? (kind == .video ? "Screen recording" : "Performance recording")) + " · " + label }
    }

    init(capture: Capture, thumbnail: UIImage, id: String = UUID().uuidString) {
        self.id = id
        self.capture = capture
        self.thumbnail = thumbnail
        data = thumbnail.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// A video, picked, pasted or recorded: it goes to the Mac through
    /// Squircle like a recording. `poster` is its thumbnail's picture.
    init(video file: URL, poster: UIImage, duration: Double, name: String? = nil) {
        let length = Elapsed.clock(duration.rounded())
        self.init(capture: .init(kind: .video, file: file, label: length, name: name),
                  thumbnail: Self.videoThumbnail(poster, length: length))
    }

    /// The top of `poster`, wide enough for the field's tray to show, with a
    /// play badge and the video's length.
    private static func videoThumbnail(_ poster: UIImage, length text: String) -> UIImage {
        let size = CGSize(width: 200, height: 160)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let height = size.width * poster.size.height / max(1, poster.size.width)
            poster.draw(in: CGRect(x: 0, y: -height * 0.06, width: size.width, height: height))
            let font = Theme.Text.lineStrong
            let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white])
            let icon = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            let width = label.size().width + 32
            let pill = CGRect(x: Theme.Space.row, y: size.height - 34, width: width, height: 26)
            UIColor.black.withAlphaComponent(0.6).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            icon?.draw(in: CGRect(x: pill.minX + Theme.Space.row, y: pill.midY - 6, width: 12, height: 12))
            label.draw(at: CGPoint(x: pill.minX + 24, y: pill.midY - label.size().height / 2))
        }
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
    let updatedAt: Date
    /// The service's error for a job that didn't succeed.
    let error: String?
    let sourceRevision: String?
    let sourceDirty: Bool?
    /// The app agent whose agent, worker or task started it.
    let agentThread: String?
    /// The project in the main checkout, for a build of a T3 worktree.
    let mainProject: String?
    /// The project whose app this build is, whichever checkout built it.
    var appProject: String? { mainProject ?? request?.project }

    var needsPolling: Bool {
        status == "queued" || status == "running"
    }

    enum CodingKeys: String, CodingKey {
        case id, state, output, request, error
        case createdAt = "created_at", updatedAt = "updated_at", sourceRevision = "source_revision", sourceDirty = "source_dirty"
        case agentThread = "agent_thread", mainProject = "source_main_project"
    }
    private struct Output: Decodable {
        let title: String?
        let version: String?
        let build_number: String?
        let ipa_path: String?
        let bundle_id: String?
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
        date = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .createdAt))
        updatedAt = (try values.decodeIfPresent(Double.self, forKey: .updatedAt)).map(Date.init(timeIntervalSince1970:)) ?? date
        error = try values.decodeIfPresent(String.self, forKey: .error)
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        sourceDirty = try values.decodeIfPresent(Bool.self, forKey: .sourceDirty)
        agentThread = try values.decodeIfPresent(String.self, forKey: .agentThread)?.lowercased()
        mainProject = try values.decodeIfPresent(String.self, forKey: .mainProject)
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

/// One thing the user asked an app's agent for, and where it stands
/// (`squircle task`): a work item with its sub-tasks, or one sub-task.
/// Linked threads and builds come with their state.
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
    var status: Status
    let note: String
    let order: Double
    let updatedAt: Double
    let archivedAt: Double?
    /// The service's revision of this task; an edit's receipt names the
    /// revision that holds it.
    let revision: UInt64
    let threads: [Thread]
    let builds: [Build]
    let media: [Media]
    private var subtaskList: [AppTask]?
    /// A work item's sub-tasks, in order; none on a sub-task.
    var subtasks: [AppTask] {
        get { subtaskList ?? [] }
        set { subtaskList = newValue }
    }
    /// The item's own threads, then its sub-tasks', each once.
    var allThreads: [Thread] {
        var seen = Set<String>()
        return (threads + subtasks.flatMap(\.threads)).filter { seen.insert($0.id).inserted }
    }
    /// The thread it is about right now: one waiting on you, else one
    /// working, else the newest. Archived threads can't be opened.
    var mainThread: String? {
        let threads = threads.filter { $0.state != "missing" }
        return (threads.first { $0.state == "needs-you" } ?? threads.first { $0.state == "working" } ?? threads.last)?.id
    }

    enum CodingKeys: String, CodingKey {
        case id, ask, status, note, order, threads, builds, media, revision
        case updatedAt = "updated_at", archivedAt = "archived_at", subtaskList = "subtasks"
    }
}

/// An app's tasks: the active list and History, newest first. The service
/// sends History a page at a time; `historyNext` is where the next older
/// page starts, nil once all of it is here.
struct AppTasks: Decodable, Equatable {
    var tasks: [AppTask] = []
    var history: [AppTask] = []
    var historyNext: String?
    var hasMoreHistory: Bool { historyNext != nil }
    /// Every work item and sub-task, active and History.
    var everyTask: [AppTask] { (tasks + history).flatMap { [$0] + $0.subtasks } }
    enum CodingKeys: String, CodingKey { case tasks, history, historyNext = "history_next" }
}
