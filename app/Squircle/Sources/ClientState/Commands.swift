import Foundation

/// M04: addressed commands (answers, approvals, interrupts, approval mode,
/// task edits, new projects) and what each shows until it is settled. Each
/// keeps the identity it was made with. A lost answer leaves it pending:
/// a T3 command is sent again, unchanged, on the next session (T3 answers
/// a command it already took from its receipt), and anything already
/// settled in what T3 or the Mac shows is never sent again. Only a refusal
/// takes its overlay away early. Commands that conflict (one thread's mode,
/// one task) go one at a time; a newer one waits behind and replaces an
/// older one that hasn't left yet.
enum Commands {
    enum Kind: Equatable {
        case approval(thread: String, request: String, decision: String)
        case answer(thread: String, request: String, answers: JSONValue)
        /// Stops `turn`, the one running when you asked.
        case interrupt(thread: String, turn: String?)
        case mode(thread: String, T3RuntimeMode)
        case task(id: String, status: AppTask.Status?, toTop: Bool)
        case project(id: String, root: String)
        var thread: String? {
            switch self {
            case .approval(let t, _, _), .answer(let t, _, _), .interrupt(let t, _), .mode(let t, _): t
            case .task, .project: nil
            }
        }
        var request: String? {
            switch self {
            case .approval(_, let r, _), .answer(_, let r, _): r
            default: nil
            }
        }
        var slot: Slot? {
            switch self {
            case .mode(let thread, _): .mode(thread)
            case .task(let id, _, _): .task(id)
            default: nil
            }
        }
    }
    enum Slot: Hashable { case mode(String), task(String) }
    struct Intent: Equatable {
        let identity: CommandIdentity
        let kind: Kind
        /// The exact T3 command; nil for a task edit, which goes to the Mac.
        let command: JSONValue?
        var id: String { identity.id }
    }
    enum Phase: Equatable {
        /// Not sent yet: waiting for T3's session.
        case waiting
        /// Sent on this session (0: to the Mac).
        case dispatching(attempt: Int)
        /// Sent; the answer was lost.
        case unknown
        /// Taken; shown until T3 or the Mac shows it (`revision`: the task's that holds it).
        case acknowledged(revision: UInt64?)
    }
    struct Entry: Equatable {
        let intent: Intent
        var phase: Phase
    }
    struct State: Equatable {
        var entries: [Entry] = []
        var queued: [Slot: Intent] = [:]
        var session: Int?
        func entry(_ id: String) -> Int? { entries.firstIndex { $0.intent.id == id } }
        /// Requests answered from here, until T3 shows them resolved.
        var answering: Set<String> { Set(entries.compactMap(\.intent.kind.request)) }
        /// The mode you chose for `thread` that T3 doesn't show yet.
        func mode(for thread: String) -> T3RuntimeMode? {
            func mode(_ intent: Intent?) -> T3RuntimeMode? { if case .mode(thread, let m)? = intent?.kind { return m }; return nil }
            return mode(queued[.mode(thread)]) ?? mode(entries.last { $0.intent.kind.slot == .mode(thread) }?.intent)
        }
        /// Your task edits the Mac doesn't show yet, newest last.
        var taskEdits: [(id: String, status: AppTask.Status?, toTop: Bool)] {
            (entries.map(\.intent) + queued.values).compactMap {
                if case .task(let id, let status, let toTop) = $0.kind { return (id, status, toTop) }; return nil
            }
        }
    }
    /// A live view of the open thread.
    struct ThreadSight: Equatable {
        let threadID: String
        let pendingRequests: Set<String>
        let runtimeMode: String?
        let running: Bool
        let activeTurn: String?
    }
    struct TaskSight: Equatable {
        let id: String
        let status: AppTask.Status
        let revision: UInt64?
    }
    enum Settlement: Equatable {
        case done
        case refused(String)
        /// A newer command of the same kind replaced it before it left.
        case superseded
    }
    enum Event: Equatable {
        case propose(Intent)
        case answered(id: String, attempt: Int, CommandOutcome)
        case sessionReady(attempt: Int)
        case sessionLost
        case threadObserved(ThreadSight)
        case tasksObserved([TaskSight])
        case projectsObserved(roots: Set<String>)
        /// The thread is no longer on screen: nothing more will be seen of it here.
        case left(thread: String)
    }
    enum Effect: Equatable {
        case dispatch(id: String, command: JSONValue, attempt: Int)
        case editTask(id: String, task: String, status: AppTask.Status?, toTop: Bool)
        /// Read the Mac's tasks again to settle a lost edit of `task`.
        case readTasks(task: String)
        case settle(id: String, Settlement)
        case report(String)
    }

    typealias Result = Reduction<State, Effect>

    static func reduce(_ state: State, _ event: Event) -> Result {
        var s = state
        var effects: [Effect] = []
        func done(_ disposition: Disposition = .applied) -> Result { Result(state: s, effects: effects, disposition: disposition) }

        func send(_ e: inout Entry) {
            if case .task(let task, let status, let toTop) = e.intent.kind {
                e.phase = .dispatching(attempt: 0)
                effects.append(.editTask(id: e.intent.id, task: task, status: status, toTop: toTop))
            } else if let attempt = s.session, let command = e.intent.command {
                e.phase = .dispatching(attempt: attempt)
                effects.append(.dispatch(id: e.intent.id, command: command, attempt: attempt))
            }
        }
        /// Sends entry `i` (through a copy: `send` reads the session).
        func send(at i: Int) { var e = s.entries[i]; send(&e); s.entries[i] = e }
        /// Removes entry `i`; the next command waiting for its slot goes.
        func remove(_ i: Int, _ settlement: Settlement?) {
            let e = s.entries.remove(at: i)
            if let settlement { effects.append(.settle(id: e.intent.id, settlement)) }
            if let slot = e.intent.kind.slot, !s.entries.contains(where: { $0.intent.kind.slot == slot }), let next = s.queued.removeValue(forKey: slot) {
                var entry = Entry(intent: next, phase: .waiting)
                send(&entry)
                s.entries.append(entry)
            }
        }
        /// Settled by what T3 or the Mac shows. Waiters were told at acknowledgement.
        func resolved(_ i: Int) {
            if case .acknowledged = s.entries[i].phase { remove(i, nil) } else { remove(i, .done) }
        }

        switch event {
        case .propose(let intent):
            guard s.entry(intent.id) == nil, !s.queued.values.contains(intent) else { return done(.duplicate) }
            if let request = intent.kind.request, s.answering.contains(request) { return done(.notApplicable) }
            if let slot = intent.kind.slot, let i = s.entries.firstIndex(where: { $0.intent.kind.slot == slot }) {
                if s.entries[i].phase == .waiting {
                    // Not sent yet: the newer one takes its place.
                    effects.append(.settle(id: s.entries[i].intent.id, .superseded))
                    s.entries[i] = Entry(intent: intent, phase: .waiting)
                    send(at: i)
                } else {
                    if let older = s.queued[slot] { effects.append(.settle(id: older.id, .superseded)) }
                    s.queued[slot] = intent
                }
                return done()
            }
            var e = Entry(intent: intent, phase: .waiting)
            send(&e)
            s.entries.append(e)

        case .answered(let id, let attempt, let outcome):
            guard let i = s.entry(id) else { return done(.stale) }
            switch outcome {
            case .accepted(let value):
                if case .acknowledged = s.entries[i].phase { return done(.duplicate) }
                effects.append(.settle(id: id, .done))
                switch s.entries[i].intent.kind {
                case .interrupt: remove(i, nil)
                case .task:
                    let revision = value["revision"].double.map { UInt64($0) }
                    if revision == nil { remove(i, nil) } else { s.entries[i].phase = .acknowledged(revision: revision) }
                default: s.entries[i].phase = .acknowledged(revision: nil)
                }
            case .refused(let reason):
                remove(i, .refused(reason))
                effects.append(.report(reason))
            case .unknown, .notSent:
                guard s.entries[i].phase == .dispatching(attempt: attempt) else { return done(.stale) }
                if case .notSent = outcome { s.entries[i].phase = .waiting } else { s.entries[i].phase = .unknown }
                switch s.entries[i].intent.kind {
                case .task(let task, _, _): effects.append(.readTasks(task: task))
                // Settled by looking at the thread: a resend could stop a newer turn.
                case .interrupt where s.entries[i].phase == .unknown: break
                default: if s.session != attempt { send(at: i) }
                }
            }

        case .sessionReady(let attempt):
            s.session = attempt
            for i in s.entries.indices {
                if case .dispatching(let old) = s.entries[i].phase, old != 0, old != attempt { s.entries[i].phase = .unknown }
                switch (s.entries[i].phase, s.entries[i].intent.kind) {
                case (.unknown, .interrupt), (_, .task): continue
                case (.waiting, _), (.unknown, _): send(at: i)
                default: continue
                }
            }

        case .sessionLost:
            s.session = nil

        case .threadObserved(let sight):
            var applied = false
            for i in s.entries.indices.reversed() where s.entries[i].intent.kind.thread == sight.threadID {
                switch s.entries[i].intent.kind {
                case .approval(_, let request, _), .answer(_, let request, _):
                    if !sight.pendingRequests.contains(request) { resolved(i); applied = true }
                case .mode(_, let mode):
                    if sight.runtimeMode == mode.rawValue { resolved(i); applied = true }
                case .interrupt(_, let turn):
                    if !sight.running || sight.activeTurn != turn { resolved(i); applied = true }
                    else if s.entries[i].phase == .unknown, s.session != nil { send(at: i); applied = true }
                case .task, .project: break
                }
            }
            if !applied { return done(.irrelevant) }

        case .tasksObserved(let sights):
            let byID = Dictionary(sights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var applied = false
            for i in s.entries.indices.reversed() {
                guard case .task(let id, let status, _) = s.entries[i].intent.kind, let sight = byID[id] else { continue }
                switch s.entries[i].phase {
                case .acknowledged(let receipt):
                    if (sight.revision ?? 0) >= (receipt ?? 0) { resolved(i); applied = true }
                case .unknown:
                    // An edit sets a value, so sending it again is the same edit.
                    if let status, sight.status == status { resolved(i) } else { send(at: i) }
                    applied = true
                case .waiting, .dispatching: break
                }
            }
            if !applied { return done(.irrelevant) }

        case .projectsObserved(let roots):
            var applied = false
            for i in s.entries.indices.reversed() {
                guard case .project(_, let root) = s.entries[i].intent.kind, roots.contains(root) else { continue }
                resolved(i); applied = true
            }
            if !applied { return done(.irrelevant) }

        case .left(let thread):
            var applied = false
            for i in s.entries.indices.reversed() where s.entries[i].intent.kind.thread == thread {
                switch (s.entries[i].phase, s.entries[i].intent.kind) {
                case (.acknowledged, _): remove(i, nil); applied = true
                case (.unknown, .interrupt): remove(i, .done); applied = true
                default: break
                }
            }
            if !applied { return done(.irrelevant) }
        }
        return done()
    }

    /// What must hold after every event.
    static func violations(in s: State) -> [String] {
        var found: [String] = []
        let ids = s.entries.map(\.intent.id)
        if Set(ids).count != ids.count { found.append("one command filed twice") }
        var slots = Set<Slot>()
        for e in s.entries {
            if let slot = e.intent.kind.slot, !slots.insert(slot).inserted { found.append("two commands for one slot at once") }
            if let command = e.intent.command, command["commandId"].string != e.intent.id { found.append("command lost its identity") }
            if case .task = e.intent.kind, e.intent.command != nil { found.append("a task edit addressed to T3") }
        }
        let requests = s.entries.compactMap(\.intent.kind.request)
        if Set(requests).count != requests.count { found.append("one request answered twice") }
        for slot in s.queued.keys where !slots.contains(slot) { found.append("a queued command with nothing ahead of it") }
        return found
    }
}
