#if SQUIRCLE_OVERLAY || DEBUG
import UIKit

/// What the overlay's bubble says about the app's agent and its workers,
/// read from the model, and the brief news it shows when that changes:
/// workers starting or finishing, a new question while docked, a finished
/// turn. The controller shows it; this keeps what has already been told.
@MainActor
final class OverlayNews {
    /// A status line for the bubble.
    struct Line: Equatable {
        var text: String
        var tone: LiveCapsule.Tone
        var started: Date?
    }

    /// What the agent and its workers are doing, read from the model.
    struct Activity {
        /// What lasts while it is so: who needs you, else the agent's live
        /// step (its turn runs).
        var line: Line?
        var mood = GlassJelly.Mood.idle
        /// Workers running: their thread IDs, titles and states.
        var workers: [(id: String, title: String, mood: JellyLook.Mood)] = []
    }

    /// Brief news ("Done · …", "2 workers"), shown for `dwell` and then
    /// absorbed into the jelly.
    private var notice: Line?
    private static let dwell = Duration.seconds(4)
    /// Takes the notice down when its dwell is over; replaced by a newer one.
    private var expiry: Task<Void, Never>?
    /// The notice ran out: the bubble should render again.
    var onExpire: (() -> Void)?
    /// Each thread's newest finished turn already accounted for (thread ID
    /// → turn ID), so only a turn T3 newly reports finished is announced.
    private var completions: [String: String] = [:]
    /// Workers and who needs you as last rendered, so a change is news.
    private var knownWorkers: Int?
    private var knownWaiting: String?
    /// The last turn's outcome until you open the panel: the jelly stays
    /// happy (done) or slumped (failed) meanwhile.
    var unseen: GlassJelly.Mood?

    /// The news showing now, if any.
    var line: Line? { notice }
    func dismiss() { notice = nil }
    func cancel() { expiry?.cancel() }

    /// What the agent and its workers are doing in `project` (none: the
    /// model's error, if any). Notes newly finished turns as news.
    func activity(model: SquircleModel, project: AppProject?) -> Activity {
        guard let project else {
            return Activity(line: model.error.map { Line(text: $0, tone: .needsYou) }, mood: model.error == nil ? .idle : .needsYou)
        }
        let sessions = model.sessions(for: project, includingAgent: true)
        let agentID = model.agentThreadID(for: project)
        func title(_ session: ChatSession) -> String { session.id == agentID ? project.name : session.displayTitle(in: project) }
        let active = sessions.filter { $0.phase != .idle }
        noticeCompletions(in: sessions, title: title)
        var activity = Activity()
        activity.workers = active.filter { $0.id != agentID }.map { ($0.id, title($0), JellyLook.Mood($0.phase)) }
        // Whoever needs you, else what the agent is doing (its live step;
        // with no agent, a thread is the work). Workers running while the
        // agent's turn has ended say nothing lasting: the jelly shows them.
        if let waiting = active.first(where: { $0.phase == .needsYou }) {
            activity.line = Line(text: "Needs you · " + title(waiting), tone: .needsYou)
            activity.mood = .needsYou
        } else if let busy = active.first(where: { $0.id == agentID }) ?? (agentID == nil ? active.first : nil) {
            let live = model.selectedSessionID == busy.id ? liveStatus(model) : nil
            activity.line = Line(text: live?.headline ?? title(busy), tone: .working, started: live?.started)
            activity.mood = .working
        }
        return activity
    }

    /// News that shows briefly, then is absorbed into the jelly: workers
    /// starting or finishing (their count) and, docked, a new question.
    func notice(_ activity: Activity, docked: Bool) {
        let count = activity.workers.count
        if let known = knownWorkers, count != known, count > 0 {
            announce(Line(text: count == 1 ? "Worker · " + activity.workers[0].title : "\(count) workers", tone: .idle))
        }
        knownWorkers = count
        let waiting = activity.line?.tone == .needsYou ? activity.line?.text : nil
        if docked, let waiting, waiting != knownWaiting { announce(Line(text: waiting, tone: .needsYou)) }
        knownWaiting = waiting
    }

    /// Shows `line` for `dwell`, then lets it go.
    private func announce(_ line: Line) {
        notice = line
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled, let self else { return }
            notice = nil
            onExpire?()
        }
    }

    /// Announces a turn T3 newly reports finished, briefly; the jelly keeps
    /// its outcome until you open the panel. A thread seen for the first
    /// time announces only a turn that ended just now; what finished before
    /// the overlay looked stays quiet.
    private func noticeCompletions(in sessions: [ChatSession], title: (ChatSession) -> String) {
        for session in sessions {
            guard let completion = session.latestTurn?.completion else { continue }
            let known = completions[session.id]
            guard known != completion.turnID else { continue }
            completions[session.id] = completion.turnID
            let recent = completion.endedAt.map { Date.now.timeIntervalSince($0) < 6 } ?? false
            guard known != nil || recent else { continue }
            finished(completion.outcome, title: title(session))
        }
    }

    func finished(_ outcome: TurnCompletion.Outcome, title: String) {
        let (word, tone, mood): (String, LiveCapsule.Tone, GlassJelly.Mood?) = switch outcome {
        case .completed: ("Done", .done, .done)
        case .interrupted: ("Stopped", .idle, nil)
        case .failed: ("Failed", .idle, .failed)
        }
        unseen = mood
        announce(Line(text: word + " · " + title, tone: tone))
    }

    private func liveStatus(_ model: SquircleModel) -> LiveStatus? {
        ThreadItem.items(messages: model.messages, running: model.isRunning).reversed().lazy.compactMap { item -> LiveStatus? in
            if case .live(let status) = item { return status }
            return nil
        }.first
    }
}
#endif
