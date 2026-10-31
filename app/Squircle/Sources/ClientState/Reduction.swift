import Foundation

// The phone's reducer contract (docs/fsm-architecture.md §3), as on the
// Rust side: each owner's decisions are a pure `reduce(state, event)`
// that returns its next state and the effects to run, as values. One
// executor per owner runs them and feeds their results back as events;
// nothing else changes the owner's state.

/// What a reducer did with an event.
enum Disposition: Equatable {
    case applied
    /// From an older attempt, session or generation: changes nothing.
    case stale
    case duplicate
    /// A request the current state can't take (the UI may still offer it).
    case notApplicable
    /// A broadcast that concerns nothing this owner holds.
    case irrelevant
    /// A current result that should be impossible here.
    case protocolFault(String)
}

struct Reduction<State, Effect> {
    var state: State
    var effects: [Effect] = []
    var disposition: Disposition = .applied
}

/// How a mutation's request ended. Only a typed refusal proves nothing
/// ran; an answer lost after the request left is `unknown`, never a refusal.
enum CommandOutcome: Equatable {
    case accepted(JSONValue)
    case refused(String)
    /// It never left the phone: nothing can have run.
    case notSent(String)
    /// It may have run: the answer was lost, or T3 failed without saying why.
    case unknown(String)
}

/// A command's identity, fixed when its intent is made and sent unchanged
/// every time. T3 keeps a receipt per command ID, across restarts, and
/// answers a command it already took from it without running it again.
struct CommandIdentity: Codable, Hashable {
    let id: String
    let createdAt: String
    static func fresh(at date: Date = .now) -> Self {
        Self(id: UUID().uuidString.lowercased(), createdAt: ISODate.format(date))
    }
    /// `command` with this identity, exactly as T3 is sent it.
    func stamp(_ command: [String: JSONValue]) -> JSONValue {
        var c = command; c["commandId"] = .string(id); c["createdAt"] = .string(createdAt)
        return .object(c)
    }
}

extension CommandOutcome {
    /// T3's answer to `orchestration.dispatchCommand`, from the RPC's Exit.
    /// T3 commits a command's events and receipt in one transaction and
    /// fails its own refusals with a typed error; a defect or interruption
    /// (a queued command may still run) reaches the wire as `InternalError`.
    static func t3(exit: JSONValue) -> Self {
        if exit["_tag"].string == "Success" {
            let value = exit["value"]
            return value["status"].string == "rejected" ? .refused("T3 rejected the command: \(value.formatted.prefix(700))") : .accepted(value)
        }
        let cause = exit["cause"], detail = "T3 rejected the command: \(cause.formatted.prefix(700))"
        return typedFailure(cause) ? .refused(detail) : .unknown(detail)
    }
    /// A failed Exit's cause holds one of T3's typed errors: T3 decided
    /// no, rather than a defect or interruption.
    static func typedFailure(_ cause: JSONValue) -> Bool {
        let reasons = cause.array.isEmpty ? [cause] : cause.array
        return reasons.contains { $0["_tag"].string == "Fail" && ($0["error"]["_tag"].string.map { $0 != "InternalError" } ?? false) }
    }
}

extension CommandOutcome {
    /// A failed request to the Mac's service (or a test's stand-in for T3):
    /// a refusal only when it answered no; a 5xx or a lost reply may have done it.
    static func service(_ error: Error) -> Self {
        switch error {
        case ClientError.backend(_, let status, let message) where status < 500: .refused(message)
        case ClientError.http(_, let status) where status < 500: .refused(error.localizedDescription)
        case ClientError.configuration: .refused(error.localizedDescription)
        default: .unknown(error.localizedDescription)
        }
    }
}
