import Foundation

/// M01: T3's socket and the subscriptions that make it current. A socket
/// alone is not a connection: the phone is connected (`ready`) only once
/// both required subscriptions are current, the shell at T3's
/// `synchronized` marker (T3 0.0.45 sends it after its snapshot or replay
/// whenever it is asked for one) and the device state at its first value.
/// The open conversation's thread is an optional child that fails and
/// recovers on its own. Time comes in with events; nothing here reads a
/// clock or does I/O.
enum Link {
    enum Scope: Hashable { case shell, devices }
    static let required: Set<Scope> = [.shell, .devices]
    /// How long T3 may stay unreachable before Squircle says so. Shorter
    /// outages (an app switch, a network handover) reconnect silently.
    static let grace: Duration = .seconds(8)
    /// A connection that held this long is stable again.
    static let stable: Duration = .seconds(60)

    struct Attempt: Equatable {
        let id: Int
        /// The first failure in this run of attempts.
        let failingSince: ContinuousClock.Instant?
        /// The wait before this attempt; the next failure doubles it.
        let backoff: Duration
    }
    struct Session: Equatable {
        let attempt: Int
        let since: ContinuousClock.Instant
    }
    enum Phase: Equatable {
        /// Closed for good, or no configuration.
        case stopped
        /// Background time ran out; reconnects on return.
        case suspended
        /// T3 refused this build's session; retrying can't help.
        case refused
        /// The attempt's socket is opening.
        case connecting(Attempt)
        /// Subscribed on the attempt's socket; `current` are the required
        /// scopes T3 has brought up to date.
        case synchronizing(Attempt, current: Set<Scope>)
        case ready(Session)
        /// Waiting `delay` after a failed `attempt` (RetryDue).
        case retrying(Attempt, delay: Duration)
    }
    /// The open conversation's thread subscription.
    struct Follow: Equatable {
        enum Phase: Equatable {
            /// No session to subscribe on yet.
            case idle
            case requesting
            /// Asked for; T3 hasn't brought it up to date yet.
            case synchronizing(subscription: String)
            /// Up to date (T3's `synchronized` marker) and following.
            case live(subscription: String)
            /// T3 ended it; subscribing again after a wait.
            case backingOff
            /// T3 refused it outright: asking again the same way can't help.
            case refused
            /// The thread is no longer on the Mac.
            case gone
        }
        let threadID: String
        var generation: Int
        var phase: Phase
        /// T3 ended it this many times running without bringing it up to date.
        var failures = 0
        var subscription: String? {
            switch phase {
            case .synchronizing(let s), .live(let s): s
            default: nil
            }
        }
    }
    /// What the connection tells the user, through the model's notice.
    enum Notice: Equatable {
        case unreachable(String)
        case refused
        case lost
        case threadGone
        case threadStopped(String)
        var text: String {
            switch self {
            case .unreachable(let reason): reason
            case .refused: "T3 no longer accepts this build’s session. Pair Squircle with T3 again on your Mac and install a new build."
            case .lost: "T3 stopped sending updates; reconnecting."
            case .threadGone: "This thread is no longer on your Mac."
            case .threadStopped(let reason): "This thread stopped updating: " + reason
            }
        }
    }
    enum Report: Equatable {
        case set(Notice)
        /// Clears whatever the notice says (a connection that came up).
        case clearAny
        /// Clears the notice unless it is `.lost` (an unstable connection keeps saying so until it holds).
        case clearAnyUnlessLost
        /// Clears the notice if it is the connection's `.lost`.
        case clearLost
        /// Clears the notice if it is about the followed thread.
        case clearThread
    }
    struct State: Equatable {
        var phase: Phase = .stopped
        var follow: Follow?
        var nextAttempt = 1
        var nextGeneration = 1
        /// T3 ended a required subscription soon after a connection came up, this many times running.
        var instability = 0
        /// Holding iOS's background time.
        var backgroundLease = false
        var session: Session? { if case .ready(let s) = phase { return s }; return nil }
        /// The attempt whose socket subscriptions belong to now.
        var socketAttempt: Int? {
            switch phase {
            case .synchronizing(let a, _): a.id
            case .ready(let s): s.attempt
            default: nil
            }
        }
    }
    enum Failure: Equatable {
        /// T3 refused the session's credential.
        case refused
        case transient(String)
    }
    enum Event: Equatable {
        case start
        case socketOpened(attempt: Int)
        case socketFailed(attempt: Int, Failure, now: ContinuousClock.Instant)
        /// A required scope is current: the shell's `synchronized`, the device state's first value.
        case synchronized(attempt: Int, Scope, now: ContinuousClock.Instant)
        /// T3 ended a required subscription with the socket still up.
        case subscriptionEnded(attempt: Int, Scope, now: ContinuousClock.Instant)
        /// The socket closed or went silent.
        case dropped(attempt: Int, Failure?, now: ContinuousClock.Instant)
        case retryDue(attempt: Int)
        /// Reconnect, tapped.
        case reconnect
        /// A usable network path; `changed`: different from the last one.
        case networkChanged(changed: Bool)
        /// Try now, as if nothing had failed yet (pull to refresh).
        case retryNow
        case foreground
        case background
        case backgroundExpired
        case tick(now: ContinuousClock.Instant)
        case close
        /// The thread the open conversation shows, if any.
        case follow(String?)
        case followSubscribed(generation: Int, subscription: String)
        /// T3 brought the followed thread up to date.
        case followSynchronized(generation: Int)
        /// T3 ended it, or it couldn't be asked for: worth asking again.
        case followEnded(generation: Int, reason: String)
        /// T3 refused it with a typed error; `exists`: the shell still has the thread.
        case followRefused(generation: Int, reason: String, exists: Bool)
        case followRetryDue(generation: Int, exists: Bool)
        /// T3 rewrote the thread's history: subscribe again for a snapshot.
        case followReverted(threadID: String)
    }
    enum Effect: Equatable {
        case openSocket(attempt: Int)
        case subscribe(attempt: Int, Scope)
        case closeSocket
        case armRetry(attempt: Int, after: Duration)
        case cancelRetry
        /// Check that the socket still answers; a dead one reports itself as dropped.
        case probe
        case beginBackgroundLease
        case endBackgroundLease
        case subscribeThread(String, generation: Int, attempt: Int)
        case unsubscribeThread(subscription: String)
        case armFollowRetry(generation: Int, after: Duration)
        /// Sends and commands may go now, on this session.
        case sessionReady(Session)
        /// Nothing sent from now on can be answered on the old session.
        case sessionLost
        case report(Report)
    }

    typealias Result = Reduction<State, Effect>

    static func reduce(_ state: State, _ event: Event) -> Result {
        var s = state
        var effects: [Effect] = []
        func done(_ disposition: Disposition = .applied) -> Result { Result(state: s, effects: effects, disposition: disposition) }

        /// Starts attempt `nextAttempt`, subscribing the followed thread once its socket opens.
        func begin(failingSince: ContinuousClock.Instant?, backoff: Duration) {
            let attempt = Attempt(id: s.nextAttempt, failingSince: failingSince, backoff: backoff)
            s.nextAttempt += 1
            s.phase = .connecting(attempt)
            effects.append(.openSocket(attempt: attempt.id))
        }
        /// The session (or attempt) is gone: the followed thread waits for the next one.
        func loseSession(wasReady: Bool) {
            if wasReady { effects.append(.sessionLost) }
            if var f = s.follow, f.phase != .gone { f.phase = .idle; f.generation = s.nextGeneration; s.nextGeneration += 1; s.follow = f }
        }
        /// An attempt failed: wait, longer each time, then try again.
        func fail(_ attempt: Attempt, _ failure: Failure, now: ContinuousClock.Instant) {
            effects.append(.closeSocket)
            loseSession(wasReady: false)
            if failure == .refused { s.phase = .refused; effects.append(.report(.set(.refused))); return }
            let since = attempt.failingSince ?? now
            let delay: Duration = attempt.backoff == .zero ? .milliseconds(500) : min(attempt.backoff * 2, .seconds(15))
            s.phase = .retrying(Attempt(id: attempt.id, failingSince: since, backoff: attempt.backoff), delay: delay)
            effects.append(.armRetry(attempt: attempt.id, after: delay))
            if case .transient(let reason) = failure, since.duration(to: now) >= grace { effects.append(.report(.set(.unreachable(reason)))) }
        }
        /// A working connection dropped: reconnect at once, or after a wait
        /// if T3 keeps ending subscriptions soon after connecting.
        func reconnectAfterDrop() {
            effects.append(.sessionLost)
            loseSession(wasReady: false)
            let first: Duration = s.instability == 0 ? .zero : min(.milliseconds(500) * (1 << min(s.instability, 6)), .seconds(30))
            if first == .zero { begin(failingSince: nil, backoff: .zero); return }
            let attempt = Attempt(id: s.nextAttempt, failingSince: nil, backoff: first)
            s.nextAttempt += 1
            s.phase = .retrying(attempt, delay: first)
            effects.append(.armRetry(attempt: attempt.id, after: first))
        }
        /// Subscribe the followed thread on `attempt`'s socket.
        func requestFollow(on attempt: Int) {
            guard var f = s.follow, f.phase != .gone else { return }
            f.generation = s.nextGeneration; s.nextGeneration += 1
            f.phase = .requesting
            s.follow = f
            effects.append(.subscribeThread(f.threadID, generation: f.generation, attempt: attempt))
        }
        func forgetFailures() {
            switch s.phase {
            case .connecting(let a): s.phase = .connecting(Attempt(id: a.id, failingSince: nil, backoff: .zero))
            case .synchronizing(let a, let current): s.phase = .synchronizing(Attempt(id: a.id, failingSince: nil, backoff: .zero), current: current)
            case .retrying:
                effects.append(.cancelRetry)
                begin(failingSince: nil, backoff: .zero)
            default: break
            }
        }

        switch event {
        case .start:
            guard s.phase == .stopped else { return done(.notApplicable) }
            begin(failingSince: nil, backoff: .zero)

        case .socketOpened(let id):
            guard case .connecting(let a) = s.phase, a.id == id else { return done(.stale) }
            s.phase = .synchronizing(a, current: [])
            effects += [.subscribe(attempt: id, .shell), .subscribe(attempt: id, .devices)]
            requestFollow(on: id)

        case .socketFailed(let id, let failure, let now), .dropped(let id, let failure?, let now):
            switch s.phase {
            case .connecting(let a) where a.id == id, .synchronizing(let a, _) where a.id == id: fail(a, failure, now: now)
            case .ready(let session) where session.attempt == id:
                if failure == .refused {
                    effects += [.sessionLost, .closeSocket]; loseSession(wasReady: false)
                    s.phase = .refused; effects.append(.report(.set(.refused)))
                } else { reconnectAfterDrop() }
            default: return done(.stale)
            }

        case .dropped(let id, nil, let now):
            switch s.phase {
            case .connecting(let a) where a.id == id, .synchronizing(let a, _) where a.id == id: fail(a, .transient(ClientError.connection("T3").localizedDescription), now: now)
            case .ready(let session) where session.attempt == id: reconnectAfterDrop()
            default: return done(.stale)
            }

        case .synchronized(let id, let scope, let now):
            switch s.phase {
            case .synchronizing(let a, var current) where a.id == id:
                current.insert(scope)
                guard current.isSuperset(of: required) else { s.phase = .synchronizing(a, current: current); return done() }
                let session = Session(attempt: id, since: now)
                s.phase = .ready(session)
                effects += [.sessionReady(session), .report(s.instability == 0 ? .clearAny : .clearAnyUnlessLost)]
            case .ready(let session) where session.attempt == id: return done(.irrelevant)
            default: return done(.stale)
            }

        case .subscriptionEnded(let id, _, let now):
            switch s.phase {
            case .synchronizing(let a, _) where a.id == id:
                s.instability += 1
                effects.append(.report(.set(.lost)))
                fail(a, .transient(Notice.lost.text), now: now)
            case .ready(let session) where session.attempt == id:
                let quick = session.since.duration(to: now) < stable
                s.instability = quick ? s.instability + 1 : 1
                effects += [.report(.set(.lost)), .closeSocket]
                reconnectAfterDrop()
            default: return done(.stale)
            }

        case .retryDue(let id):
            guard case .retrying(let a, let delay) = s.phase, a.id == id else { return done(.stale) }
            begin(failingSince: a.failingSince, backoff: delay)

        case .reconnect:
            switch s.phase {
            case .refused: begin(failingSince: nil, backoff: .zero)
            case .connecting, .synchronizing:
                effects.append(.closeSocket); loseSession(wasReady: false)
                begin(failingSince: nil, backoff: .zero)
            case .retrying:
                effects.append(.cancelRetry)
                begin(failingSince: nil, backoff: .zero)
            case .ready, .suspended, .stopped: return done(.notApplicable)
            }
            effects.append(.report(.clearAny))

        case .networkChanged(let changed):
            switch s.phase {
            case .ready: guard changed else { return done(.irrelevant) }; effects.append(.probe)
            case .connecting, .synchronizing, .retrying: forgetFailures()
            case .suspended, .refused, .stopped: return done(.irrelevant)
            }

        case .retryNow:
            switch s.phase {
            case .connecting, .synchronizing, .retrying: forgetFailures()
            case .ready, .suspended, .refused, .stopped: return done(.irrelevant)
            }

        case .foreground:
            if s.backgroundLease { s.backgroundLease = false; effects.append(.endBackgroundLease) }
            switch s.phase {
            case .ready: effects.append(.probe)
            case .suspended: begin(failingSince: nil, backoff: .zero)
            case .connecting, .synchronizing, .retrying: forgetFailures()
            case .refused, .stopped: break
            }

        case .background:
            switch s.phase {
            case .stopped, .refused, .suspended: return done(.irrelevant)
            default:
                guard !s.backgroundLease else { return done(.duplicate) }
                s.backgroundLease = true; effects.append(.beginBackgroundLease)
            }

        case .backgroundExpired:
            guard s.backgroundLease else { return done(.stale) }
            s.backgroundLease = false
            effects.append(.endBackgroundLease)
            switch s.phase {
            case .ready:
                effects += [.sessionLost, .closeSocket]; loseSession(wasReady: false); s.phase = .suspended
            case .connecting, .synchronizing:
                effects.append(.closeSocket); loseSession(wasReady: false); s.phase = .suspended
            case .retrying:
                effects.append(.cancelRetry); s.phase = .suspended
            case .stopped, .refused, .suspended: break
            }

        case .tick(let now):
            guard s.instability > 0, case .ready(let session) = s.phase, session.since.duration(to: now) >= stable else { return done(.irrelevant) }
            s.instability = 0
            effects.append(.report(.clearLost))

        case .close:
            switch s.phase {
            case .ready: effects += [.sessionLost, .closeSocket]
            case .connecting, .synchronizing: effects.append(.closeSocket)
            case .retrying: effects.append(.cancelRetry)
            case .stopped, .suspended, .refused: break
            }
            if s.backgroundLease { s.backgroundLease = false; effects.append(.endBackgroundLease) }
            if let sub = s.follow?.subscription { effects.append(.unsubscribeThread(subscription: sub)) }
            s.phase = .stopped; s.follow = nil

        case .follow(let id):
            if let f = s.follow, f.threadID == id, ![.gone, .backingOff, .refused].contains(f.phase) { return done(.duplicate) }
            if let sub = s.follow?.subscription { effects.append(.unsubscribeThread(subscription: sub)) }
            guard let id else { s.follow = nil; return done() }
            s.follow = Follow(threadID: id, generation: s.nextGeneration, phase: .idle)
            s.nextGeneration += 1
            if let attempt = s.socketAttempt { requestFollow(on: attempt) }

        case .followSubscribed(let generation, let subscription):
            guard var f = s.follow, f.generation == generation, f.phase == .requesting else {
                // A late subscription for a thread no longer followed is the executor's to end.
                effects.append(.unsubscribeThread(subscription: subscription))
                return done(.stale)
            }
            f.phase = .synchronizing(subscription: subscription)
            s.follow = f

        case .followSynchronized(let generation):
            guard var f = s.follow, f.generation == generation, case .synchronizing(let subscription) = f.phase else { return done(.stale) }
            // Only a subscription T3 brought up to date ends a run of failures.
            if f.failures > 0 { effects.append(.report(.clearThread)) }
            f.phase = .live(subscription: subscription); f.failures = 0
            s.follow = f

        case .followRefused(let generation, let reason, let exists):
            guard var f = s.follow, f.generation == generation, f.phase == .requesting || f.subscription != nil else { return done(.stale) }
            f.phase = exists ? .refused : .gone; f.failures += 1
            s.follow = f
            effects.append(.report(.set(exists ? .threadStopped(reason) : .threadGone)))

        case .followEnded(let generation, let reason):
            guard var f = s.follow, f.generation == generation, f.phase == .requesting || f.subscription != nil else { return done(.stale) }
            f.failures += 1
            f.phase = .backingOff
            let delay = min(.seconds(1) * (1 << min(f.failures - 1, 5)), Duration.seconds(30))
            s.follow = f
            effects.append(.armFollowRetry(generation: generation, after: delay))
            if f.failures >= 3 { effects.append(.report(.set(.threadStopped(reason)))) }

        case .followRetryDue(let generation, let exists):
            guard var f = s.follow, f.generation == generation, f.phase == .backingOff else { return done(.stale) }
            guard exists else { f.phase = .gone; s.follow = f; effects.append(.report(.set(.threadGone))); return done() }
            if let attempt = s.socketAttempt { requestFollow(on: attempt) } else { f.phase = .idle; s.follow = f }

        case .followReverted(let id):
            guard let f = s.follow, f.threadID == id, let sub = f.subscription, let attempt = s.socketAttempt else { return done(.irrelevant) }
            effects.append(.unsubscribeThread(subscription: sub))
            requestFollow(on: attempt)
        }
        return done()
    }

    /// What must hold after every event (DEBUG audits and tests).
    static func violations(in s: State) -> [String] {
        var found: [String] = []
        if case .retrying(_, let delay) = s.phase, delay <= .zero { found.append("retrying without a wait") }
        if s.backgroundLease, [.stopped, .suspended, .refused].contains(s.phase) { found.append("background lease without a connection") }
        if let f = s.follow {
            if f.generation >= s.nextGeneration { found.append("follow generation not issued") }
            switch f.phase {
            case .requesting, .synchronizing, .live: if s.socketAttempt == nil { found.append("thread subscribed without a socket") }
            default: break
            }
        }
        switch s.phase {
        case .connecting(let a), .synchronizing(let a, _), .retrying(let a, _): if a.id >= s.nextAttempt { found.append("attempt not issued") }
        case .ready(let session): if session.attempt >= s.nextAttempt { found.append("session attempt not issued") }
        default: break
        }
        return found
    }
}
