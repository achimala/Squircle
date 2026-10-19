import Foundation

/// M03: one message on its way to T3. Everything about it is fixed when
/// you send it (where, with which model and mode, its pictures, the
/// context Squircle adds, the message and command IDs), saved on the phone
/// before anything leaves, and sent unchanged however often it has to be:
/// T3 answers a command ID it already took from its receipt. A lost answer
/// leaves the message pending, never failed; the next session (or the
/// thread showing it) settles it. Only a typed refusal ends it as refused.
enum Delivery {
    struct Picture: Codable, Equatable {
        let id: String
        let jpeg: Data
    }
    /// A recording in the field: its file on the phone until the Mac has it.
    struct Recording: Codable, Equatable {
        let id: String
        let kind: String
        let path: String
        let label: String
        let thumbnail: Data
    }
    enum Destination: Codable, Equatable {
        case thread(String)
        /// A draft: T3 makes its thread, named before T3 is asked, with this exact command.
        case newThread(id: String, command: JSONValue)
        /// A first message to the app's agent: the Mac makes (or finds) it.
        case agent(model: String?)
    }
    struct Intent: Codable, Equatable {
        let messageID: String
        let origin: ConversationID
        let projectID: String
        let destination: Destination
        let spoken: String
        let pictures: [Picture]
        let recordings: [Recording]
        let selection: JSONValue
        let mode: String
        /// Added after the message: Squircle's instructions for the thread, or nothing.
        let context: String
        let titleSeed: String
        let turn: CommandIdentity
    }
    /// The thread it goes to and the exact turn command.
    struct Resolved: Codable, Equatable {
        let threadID: String
        let command: JSONValue
    }
    enum Stage: Codable, Equatable {
        /// Recordings on their way to the Mac.
        case preparing
        /// The draft's thread being made; `text` is the message with its recordings.
        case creating(text: String)
        /// The turn, sent or about to be.
        case sending(Resolved)
        /// T3 took it; shown until the thread shows it. Never saved.
        case accepted(Resolved)
    }
    enum Flight: Equatable {
        /// On the phone or the Mac's service (recordings, the agent).
        case local
        /// A T3 request on this session.
        case t3(attempt: Int)
    }
    struct Entry: Equatable {
        let intent: Intent
        var stage: Stage
        var flight: Flight?
        /// Its last answer was lost: T3 may have it.
        var uncertain = false
        /// It couldn't be saved on the phone; nothing more is sent until it is.
        var blocked: String?
        /// The conversation it belongs to now: the thread a draft became.
        var owner: ConversationID {
            switch stage {
            case .sending(let r), .accepted(let r): .thread(r.threadID, appID: intent.origin.appID)
            case .preparing, .creating: intent.origin
            }
        }
    }
    struct State: Equatable {
        var entries: [String: Entry] = [:]
        /// T3's ready session, if any.
        var session: Int?
        /// The conversation on screen: an accepted message stays shown there until the thread has it.
        var watching: ConversationID?
        func entry(for conversation: ConversationID) -> Entry? {
            entries.values.first { $0.owner == conversation || $0.intent.origin == conversation }
        }
    }
    /// A message as the phone keeps it on disk.
    struct Saved: Codable, Equatable {
        let intent: Intent
        let stage: Stage
    }
    enum Settlement: Equatable {
        case accepted(ConversationID)
        case rejected(ConversationID, reason: String)
    }
    enum Event: Equatable {
        case submit(Intent)
        /// Unfinished messages saved before the app last quit.
        case restore([Saved])
        case saveFailed(messageID: String, reason: String)
        /// The message with its recordings linked, once they're on the Mac.
        case prepared(messageID: String, text: String)
        case prepareFailed(messageID: String, reason: String)
        /// The draft's thread exists (T3 made it, or the Mac made or found the agent).
        case created(messageID: String, threadID: String)
        /// Any other answer to making the draft's thread; `attempt` nil for the Mac.
        case createAnswered(messageID: String, attempt: Int?, CommandOutcome)
        case turnAnswered(messageID: String, attempt: Int, CommandOutcome)
        case sessionReady(attempt: Int)
        case sessionLost
        /// T3's shell has this thread.
        case threadObserved(String)
        /// The Mac reports this app's agent.
        case agentObserved(projectID: String, threadID: String)
        /// The thread shows this message.
        case messageObserved(threadID: String, messageID: String)
        /// The conversation on screen changed.
        case watch(ConversationID?)
    }
    enum Effect: Equatable {
        /// Saves the entry on the phone. What follows runs only once it is saved.
        case save(Entry)
        case forget(messageID: String)
        case prepare(Intent)
        case createThread(messageID: String, command: JSONValue, attempt: Int)
        case ensureAgent(messageID: String, projectID: String, model: String?, mode: String)
        case dispatch(messageID: String, command: JSONValue, attempt: Int)
        /// The draft's field, choices and screen belong to the thread from now on.
        case adopt(draft: ConversationID, thread: ConversationID, agentOf: String?)
        /// A refused message's pictures and recordings go back into its owner's field.
        case restoreField(ConversationID, Intent)
        case settle(messageID: String, Settlement)
        /// Says why, if the conversation is on screen.
        case report(ConversationID, String)
    }

    typealias Result = Reduction<State, Effect>

    static func reduce(_ state: State, _ event: Event) -> Result {
        var s = state
        var effects: [Effect] = []
        func done(_ disposition: Disposition = .applied) -> Result { Result(state: s, effects: effects, disposition: disposition) }

        /// The requests the entry's stage needs now, if it can make them.
        func drive(_ e: inout Entry) {
            guard e.flight == nil, e.blocked == nil else { return }
            switch (e.stage, e.intent.destination) {
            case (.preparing, _):
                e.flight = .local; effects.append(.prepare(e.intent))
            case (.creating, .newThread(_, let command)):
                guard let attempt = s.session else { return }
                e.flight = .t3(attempt: attempt)
                effects.append(.createThread(messageID: e.intent.messageID, command: command, attempt: attempt))
            case (.creating, .agent(let model)):
                e.flight = .local
                effects.append(.ensureAgent(messageID: e.intent.messageID, projectID: e.intent.projectID, model: model, mode: e.intent.mode))
            case (.sending(let r), _):
                guard let attempt = s.session else { return }
                e.flight = .t3(attempt: attempt)
                effects.append(.dispatch(messageID: e.intent.messageID, command: r.command, attempt: attempt))
            case (.creating, .thread), (.accepted, _): break
            }
        }
        /// Saves `e` at its new stage, then drives it.
        func commit(_ e: inout Entry) {
            e.flight = nil
            effects.append(.save(e))
            drive(&e)
        }
        func resolve(_ e: inout Entry, text: String, thread: String) {
            e.stage = .sending(Resolved(threadID: thread, command: turnCommand(e.intent, text: text, threadID: thread)))
            e.uncertain = false
        }
        /// The text is ready: on to the draft's thread, or straight to the turn.
        func advance(_ e: inout Entry, text: String) {
            if case .thread(let id) = e.intent.destination { resolve(&e, text: text, thread: id) } else { e.stage = .creating(text: text) }
            commit(&e)
        }
        func reject(_ e: Entry, _ reason: String) {
            s.entries[e.intent.messageID] = nil
            effects += [.forget(messageID: e.intent.messageID), .restoreField(e.owner, e.intent),
                        .settle(messageID: e.intent.messageID, .rejected(e.owner, reason: reason)), .report(e.owner, reason)]
        }
        /// The thread exists: the message belongs to it, and its turn goes next.
        func created(_ e: inout Entry, thread: String) {
            guard case .creating(let text) = e.stage else { return }
            let draft = e.intent.origin
            resolve(&e, text: text, thread: thread)
            e.flight = nil
            effects.append(.save(e))
            let agentOf: String? = if case .agent = e.intent.destination { e.intent.projectID } else { nil }
            effects.append(.adopt(draft: draft, thread: e.owner, agentOf: agentOf))
            drive(&e)
        }
        /// T3 has the message: nothing more to send. Shown until the thread has it, while anyone looks.
        func accepted(_ e: Entry, observed: Bool) {
            guard case .sending(let r) = e.stage else { return }
            let id = e.intent.messageID
            effects += [.forget(messageID: id), .settle(messageID: id, .accepted(e.owner))]
            if !observed, let watching = s.watching, watching == e.owner || watching == e.intent.origin {
                var kept = e; kept.stage = .accepted(r); kept.flight = nil; kept.uncertain = false
                s.entries[id] = kept
            } else { s.entries[id] = nil }
        }
        /// An answer that settled nothing: ask again on the next session, now if one is already up.
        func unsettled(_ e: inout Entry, from attempt: Int?, uncertain: Bool) {
            e.flight = nil
            if uncertain { e.uncertain = true }
            if let attempt, s.session != attempt { drive(&e) }
        }

        switch event {
        case .submit(let intent):
            guard s.entries[intent.messageID] == nil else { return done(.duplicate) }
            guard s.entry(for: intent.origin) == nil else { return done(.notApplicable) }
            var e = Entry(intent: intent, stage: .preparing)
            if intent.recordings.isEmpty { advance(&e, text: intent.spoken) } else { commit(&e) }
            s.entries[intent.messageID] = e

        case .restore(let saved):
            for record in saved where s.entries[record.intent.messageID] == nil {
                if case .accepted = record.stage { continue }
                // Anything past preparing may have reached T3 (or the Mac).
                var e = Entry(intent: record.intent, stage: record.stage, uncertain: record.stage != .preparing)
                drive(&e)
                s.entries[record.intent.messageID] = e
            }

        case .saveFailed(let id, let reason):
            guard var e = s.entries[id] else { return done(.stale) }
            let said = "Couldn’t keep the message on this phone: " + reason
            if e.stage == .preparing, !e.uncertain { reject(e, said); return done() }
            e.flight = nil; e.blocked = reason
            s.entries[id] = e
            effects.append(.report(e.owner, said))

        case .prepared(let id, let text):
            guard var e = s.entries[id], e.stage == .preparing, e.flight == .local else { return done(.stale) }
            advance(&e, text: text)
            s.entries[id] = e

        case .prepareFailed(let id, let reason):
            guard let e = s.entries[id], e.stage == .preparing, e.flight == .local else { return done(.stale) }
            reject(e, reason)

        case .created(let id, let thread):
            guard var e = s.entries[id] else { return done(.stale) }
            guard case .creating = e.stage else { return done(.duplicate) }
            created(&e, thread: thread)
            s.entries[id] = e

        case .createAnswered(let id, let attempt, let outcome):
            guard var e = s.entries[id], case .creating = e.stage else { return done(.stale) }
            switch outcome {
            case .accepted:
                guard case .newThread(let thread, _) = e.intent.destination else { return done(.protocolFault("the Mac's agent answers with its thread")) }
                created(&e, thread: thread)
            case .refused(let reason): reject(e, reason); return done()
            case .notSent, .unknown:
                if let attempt, e.flight != .t3(attempt: attempt) { return done(.stale) }
                if attempt == nil, e.flight != .local { return done(.stale) }
                if case .unknown = outcome { e.uncertain = true }
                e.flight = nil
                // The Mac's agent is asked again on the next session; T3's thread too.
                if let attempt, s.session != attempt { drive(&e) }
            }
            s.entries[id] = e

        case .turnAnswered(let id, let attempt, let outcome):
            guard var e = s.entries[id] else { return done(.stale) }
            guard case .sending = e.stage else { return done(.duplicate) }
            switch outcome {
            // T3's acceptance or refusal is evidence whichever request it answers.
            case .accepted: accepted(e, observed: false); return done()
            case .refused(let reason): reject(e, reason); return done()
            case .notSent, .unknown:
                guard e.flight == .t3(attempt: attempt) else { return done(.stale) }
                if case .unknown = outcome { unsettled(&e, from: attempt, uncertain: true) } else { unsettled(&e, from: attempt, uncertain: false) }
            }
            s.entries[id] = e

        case .sessionReady(let attempt):
            s.session = attempt
            for (id, var e) in s.entries {
                // An answer still out from the old session can't come any more.
                if case .t3(let old)? = e.flight, old != attempt { e.flight = nil; e.uncertain = true }
                if e.blocked != nil { e.blocked = nil; commit(&e) } else { drive(&e) }
                s.entries[id] = e
            }

        case .sessionLost:
            s.session = nil

        case .threadObserved(let thread):
            let proven = s.entries.values.filter {
                if case .creating = $0.stage, case .newThread(thread, _) = $0.intent.destination { return true }; return false
            }
            guard !proven.isEmpty else { return done(.irrelevant) }
            for var e in proven { created(&e, thread: thread); s.entries[e.intent.messageID] = e }

        case .agentObserved(let project, let thread):
            let proven = s.entries.values.filter {
                if case .creating = $0.stage, case .agent = $0.intent.destination, $0.intent.projectID == project, $0.flight == nil { return true }
                return false
            }
            guard !proven.isEmpty else { return done(.irrelevant) }
            for var e in proven { created(&e, thread: thread); s.entries[e.intent.messageID] = e }

        case .messageObserved(let thread, let message):
            guard let e = s.entries[message] else { return done(.irrelevant) }
            switch e.stage {
            case .sending(let r) where r.threadID == thread: accepted(e, observed: true)
            case .accepted(let r) where r.threadID == thread: s.entries[message] = nil
            default: return done(.irrelevant)
            }

        case .watch(let conversation):
            s.watching = conversation
            for (id, e) in s.entries {
                guard case .accepted = e.stage, e.owner != conversation, e.intent.origin != conversation else { continue }
                s.entries[id] = nil
            }
        }
        return done()
    }

    /// `message.dispatch` exactly as T3 gets it, every time. T3 starts a
    /// run on an idle thread and steers or queues behind one in progress,
    /// as its own clients do. Pictures go as uploads (`dataUrl`); T3 takes
    /// them first (`T3Gateway.persistPictures`), always to the same IDs.
    static func turnCommand(_ intent: Intent, text: String, threadID: String) -> JSONValue {
        let uploads: [JSONValue] = intent.pictures.enumerated().map { index, picture in
            ["type": "image", "name": "image-\(index + 1).jpg", "mimeType": "image/jpeg", "sizeBytes": .int(picture.jpeg.count),
             "dataUrl": .string("data:image/jpeg;base64," + picture.jpeg.base64EncodedString())]
        }
        return intent.turn.stamp(["type": "message.dispatch", "threadId": .string(threadID), "messageId": .string(intent.messageID),
            "text": .string(text + intent.context), "attachments": .array(uploads), "createdBy": "user", "creationSource": "mobile",
            "modelSelection": intent.selection, "titleSeed": .string(intent.titleSeed),
            "dispatchMode": ["type": "start_immediately"], "deliveryIntent": "auto"])
    }
    /// A draft's `thread.create`, made when it is sent.
    static func createCommand(threadID: String, projectID: String, selection: JSONValue, mode: String, identity: CommandIdentity) -> JSONValue {
        identity.stamp(["type": "thread.create", "threadId": .string(threadID), "projectId": .string(projectID), "title": "New thread",
                        "createdBy": "user", "creationSource": "mobile",
                        "modelSelection": selection, "runtimeMode": .string(mode), "interactionMode": "default",
                        "branch": .null, "worktreePath": .null])
    }

    /// What must hold after every event.
    static func violations(in s: State) -> [String] {
        var found: [String] = []
        var owners = Set<ConversationID>()
        for (id, e) in s.entries {
            if id != e.intent.messageID { found.append("entry filed under another ID") }
            if !owners.insert(e.owner).inserted { found.append("two messages on their way in one conversation") }
            switch e.stage {
            case .sending(let r), .accepted(let r):
                if r.command["commandId"].string != e.intent.turn.id || r.command["messageId"].string != id {
                    found.append("turn command lost its identity")
                }
                if case .thread(let t) = e.intent.destination, t != r.threadID { found.append("message moved threads") }
                if case .newThread(let t, _) = e.intent.destination, t != r.threadID { found.append("draft's thread changed") }
                if case .accepted = e.stage, e.flight != nil { found.append("accepted message still in flight") }
            case .creating:
                if case .thread = e.intent.destination { found.append("an existing thread being created") }
            case .preparing:
                if e.uncertain { found.append("preparing message counted as possibly sent") }
            }
            if case .t3(let attempt)? = e.flight, s.session != attempt, e.blocked == nil {
                // An answer still out from an earlier session is allowed only until the next session arrives.
                if s.session != nil { found.append("request from an older session still counted in flight") }
            }
        }
        return found
    }
}

extension ConversationID: Codable {
    private enum Keys: String, CodingKey { case draft, thread, app, agent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let app = try c.decode(String.self, forKey: .app)
        if let thread = try c.decodeIfPresent(String.self, forKey: .thread) { self = .thread(thread, appID: app); return }
        self = .draft(try c.decode(UUID.self, forKey: .draft), appID: app, agent: try c.decode(Bool.self, forKey: .agent))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(appID, forKey: .app)
        switch self {
        case .thread(let id, _): try c.encode(id, forKey: .thread)
        case .draft(let id, _, let agent): try c.encode(id, forKey: .draft); try c.encode(agent, forKey: .agent)
        }
    }
}
