import Foundation

/// Which conversation: a T3 thread, or a draft T3 hasn't been told about
/// yet (each draft its own, so a late send can't land in a later one). Its
/// identity is the draft or thread ID; the app it belongs to never changes.
enum ConversationID: Hashable {
    case draft(UUID, appID: String, agent: Bool)
    case thread(String, appID: String)
    var threadID: String? { if case .thread(let id, _) = self { return id }; return nil }
    var appID: String { switch self { case .draft(_, let app, _), .thread(_, let app): app } }
    /// A first message to the app's agent.
    var isAgentDraft: Bool { if case .draft(_, _, true) = self { return true }; return false }
    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.draft(let x, _, _), .draft(let y, _, _)): x == y
        case (.thread(let x, _), .thread(let y, _)): x == y
        default: false
        }
    }
    func hash(into hasher: inout Hasher) {
        switch self {
        case .draft(let id, _, _): hasher.combine(0); hasher.combine(id)
        case .thread(let id, _): hasher.combine(1); hasher.combine(id)
        }
    }
}

/// A message on its way to T3, under the conversation that owns it (a
/// draft's moves to its thread once T3 made it). Its message and command
/// IDs are chosen before the first attempt and kept for every resend, and
/// T3 keeps a receipt per command ID, so a lost answer can never turn into
/// a second message. A refused message is no longer pending.
struct PendingSend: Equatable {
    enum Phase: Equatable {
        /// Recordings on their way to the Mac.
        case preparing
        /// T3 making the draft's thread.
        case creating
        /// T3 asked to start the turn; asked again on the next connection
        /// if this one drops before T3 answers.
        case awaitingAcceptance
        /// T3 took it; pending until the message shows in the thread.
        case accepted
    }
    let messageID: String
    let text: String
    let images: Int
    /// Its recordings, by their file on the phone until the Mac has them.
    let captures: [SentCapture]
    let phase: Phase
}

/// How a send ended. `conversation` owns the message now: the thread a
/// draft created, even when the turn then failed.
enum SendOutcome: Equatable {
    case accepted(messageID: String, conversation: ConversationID)
    /// T3 or the Mac refused it, or it never left: the pictures are back in
    /// the owner's field, the text is the caller's to put back.
    case rejected(messageID: String, reason: String, conversation: ConversationID)
    var conversation: ConversationID {
        switch self { case .accepted(_, let c), .rejected(_, _, let c): c }
    }
}

enum SendStart {
    case started(messageID: String, outcome: Task<SendOutcome, Never>)
    case refused(String)
}

/// The connection to T3. Every subscription callback carries the attempt
/// that made it, so one ending during setup fails that attempt, and one from
/// an older attempt changes nothing.
enum ConnectionPhase: Equatable {
    /// Closed for good, or no configuration.
    case stopped
    /// Background time ran out; reconnects on return.
    case suspended
    /// T3 refused this build's session; retrying can't help.
    case refused
    /// An attempt under way, or the wait before the next one.
    case connecting(Attempt)
    case ready(Session)
    struct Attempt: Equatable {
        let id: Int
        /// The first failure in this run of attempts.
        let failingSince: ContinuousClock.Instant?
    }
    struct Session: Equatable {
        let attempt: Int
        let since: ContinuousClock.Instant
    }
}

/// Something fetched from the Mac and kept fresh: never requested, in
/// flight, here, or failed with when to try again. Each keeps what it last had.
enum ResourceState<Value: Equatable>: Equatable {
    case absent
    case loading(previous: Value?)
    case ready(Value, fetchedAt: ContinuousClock.Instant)
    case failed(previous: Value?, failure: String, retryAt: ContinuousClock.Instant)
    var value: Value? {
        switch self {
        case .absent: nil
        case .loading(let previous), .failed(let previous, _, _): previous
        case .ready(let value, _): value
        }
    }
}

/// What a screen needs kept fresh from the Mac while it shows.
enum RefreshNeed: Hashable {
    case tasks(appID: String)
    /// The thread's published media, while the conversation shows.
    case conversation(ConversationID)
}

/// Held for as long as a screen needs something refreshed; released on
/// `end()` or when the lease goes away.
final class RefreshLease {
    private var onEnd: (@MainActor () -> Void)?
    init(_ onEnd: @escaping @MainActor () -> Void) { self.onEnd = onEnd }
    @MainActor func end() { onEnd?(); onEnd = nil }
    deinit { if let onEnd { Task { @MainActor in onEnd() } } }
}

/// Installing a build of this very app: what has been observed of it.
/// "Transferred" means the Mac sent every byte, not that iOS installed it.
enum InstallAttempt: Equatable {
    case none
    case requestingLink(AppBuild)
    /// iOS's prompt is up; nothing fetched yet.
    case prompting(AppBuild, link: URL, deadline: ContinuousClock.Instant)
    /// iOS is fetching the IPA.
    case watching(AppBuild, link: URL, deadline: ContinuousClock.Instant)
    case transferred(AppBuild)
    case ended(String?)
}
