import Foundation
import UIKit

/// What M01's runtime needs from the model that holds the replicas.
@MainActor
protocol LinkHost: AnyObject {
    /// Before the first socket: the copy of Home on disk, so T3 can resume the shell from it.
    func linkWillConnect() async
    /// How far the held shell is, for T3 to send only what changed since.
    var shellCursor: Int? { get }
    func linkReceived(shell item: JSONValue)
    func linkReceived(devices value: JSONValue)
    /// How far the held thread is, once its copy on disk has been read.
    func threadCursor(_ id: String) async -> Int?
    func linkReceived(thread id: String, _ item: JSONValue)
    func threadExists(_ id: String) -> Bool
    func linkChanged()
    func linkSessionReady(_ session: Link.Session)
    func linkSessionLost()
    func linkReport(_ report: Link.Report)
}

/// The one executor of M01: it feeds `Link.reduce` the socket's, the
/// clock's and the app's events and runs the effects it returns. It
/// decides nothing itself.
@MainActor
final class LinkRuntime {
    private(set) var state = Link.State()
    let gateway: T3Gateway
    weak var host: LinkHost?
    private var retry: Task<Void, Never>?
    private var followRetry: Task<Void, Never>?
    private var lease: UIBackgroundTaskIdentifier = .invalid
    /// The attempt the gateway's socket belongs to.
    private var socketAttempt: Int?
    /// Attempts whose device state has delivered its first value.
    private var devicesCurrent: Int?

    init(gateway: T3Gateway) {
        self.gateway = gateway
        gateway.onDisconnect = { [weak self] in
            guard let self, let attempt = socketAttempt else { return }
            send(.dropped(attempt: attempt, gateway.rejection.map(Self.failure), now: .now))
        }
    }

    func send(_ event: Link.Event) {
        let reduction = Link.reduce(state, event)
        #if DEBUG
        for violation in Link.violations(in: reduction.state) { NSLog("SQUIRCLE-FSM M01 %@ after %@", violation, String(describing: event)) }
        if case .protocolFault(let fault) = reduction.disposition { NSLog("SQUIRCLE-FSM M01 fault %@", fault) }
        #endif
        let before = state.phase
        state = reduction.state
        for effect in reduction.effects { run(effect) }
        if state.phase != before { host?.linkChanged() }
    }

    /// Ends the connection for good: timers, the background lease and the socket.
    func close() {
        send(.close)
        retry?.cancel(); followRetry?.cancel(); retry = nil; followRetry = nil
        gateway.close()
    }

    private static func failure(_ error: Error) -> Link.Failure {
        if case ClientError.http(_, let status) = error, status == 401 || status == 403 { return .refused }
        return .transient(error.localizedDescription)
    }

    private func run(_ effect: Link.Effect) {
        switch effect {
        case .openSocket(let attempt):
            socketAttempt = attempt; devicesCurrent = nil
            Task { [weak self] in
                await self?.host?.linkWillConnect()
                guard let self, socketAttempt == attempt else { return }
                ConnectionTrace.mark("connect.start")
                do { try await gateway.connect(); send(.socketOpened(attempt: attempt)) }
                catch { send(.socketFailed(attempt: attempt, Self.failure(error), now: .now)) }
            }
        case .subscribe(let attempt, let scope):
            Task { [weak self] in
                guard let self else { return }
                do {
                    switch scope {
                    case .shell:
                        // With a shell already held, T3 sends only what changed since (or a fresh snapshot).
                        var request: [String: Any] = ["requestCompletionMarker": true]
                        if let sequence = host?.shellCursor { request["afterSequence"] = sequence }
                        try await gateway.subscribe("orchestration.subscribeShell", .from(request), receive: { [weak self] item in
                            guard let self, socketAttempt == attempt else { return }
                            host?.linkReceived(shell: item)
                            if item["kind"].string == "synchronized" { send(.synchronized(attempt: attempt, .shell, now: .now)) }
                        }, ended: { [weak self] _ in self?.send(.subscriptionEnded(attempt: attempt, .shell, now: .now)) })
                    case .devices:
                        // Its first value is the whole device state.
                        try await gateway.subscribe("subscribeDeviceState", receive: { [weak self] value in
                            guard let self, socketAttempt == attempt else { return }
                            host?.linkReceived(devices: value)
                            if devicesCurrent != attempt { devicesCurrent = attempt; send(.synchronized(attempt: attempt, .devices, now: .now)) }
                        }, ended: { [weak self] _ in self?.send(.subscriptionEnded(attempt: attempt, .devices, now: .now)) })
                    }
                } catch {
                    send(.socketFailed(attempt: attempt, Self.failure(gateway.rejection ?? error), now: .now))
                }
            }
        case .closeSocket:
            socketAttempt = nil
            gateway.disconnect(notify: false)
        case .armRetry(let attempt, let delay):
            retry?.cancel()
            retry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.send(.retryDue(attempt: attempt))
            }
        case .cancelRetry:
            retry?.cancel(); retry = nil
        case .probe:
            // A dead socket reports itself through `onDisconnect`.
            Task { _ = await gateway.probe() }
        case .beginBackgroundLease:
            // Hold the socket for as long as iOS gives (about 30 s), so a quick app switch never drops it.
            lease = UIApplication.shared.beginBackgroundTask(withName: "T3 connection") { [weak self] in
                MainActor.assumeIsolated { self?.send(.backgroundExpired) }
            }
        case .endBackgroundLease:
            guard lease != .invalid else { return }
            UIApplication.shared.endBackgroundTask(lease); lease = .invalid
        case .subscribeThread(let id, let generation, let attempt):
            Task { [weak self] in
                let cursor = await self?.host?.threadCursor(id)
                guard let self, state.follow?.generation == generation, socketAttempt == attempt else { return }
                // Holding the thread up to some point, T3 sends only the events since, or a snapshot when it can't.
                var request: [String: Any] = ["threadId": id, "requestCompletionMarker": true]
                if let cursor { request["afterSequence"] = cursor }
                do {
                    let subscription = try await gateway.subscribe("orchestration.subscribeThread", .from(request), receive: { [weak self] item in
                        guard let self, state.follow?.generation == generation else { return }
                        host?.linkReceived(thread: id, item)
                    }, ended: { [weak self] failure in
                        self?.send(.followEnded(generation: generation, reason: failure?.localizedDescription ?? "T3 ended it."))
                    })
                    send(.followSubscribed(generation: generation, subscription: subscription))
                } catch {
                    send(.followEnded(generation: generation, reason: error.localizedDescription))
                }
            }
        case .unsubscribeThread(let subscription):
            Task { await gateway.unsubscribe(subscription) }
        case .armFollowRetry(let generation, let delay):
            followRetry?.cancel()
            followRetry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                let exists = state.follow.map { self.host?.threadExists($0.threadID) ?? true } ?? true
                send(.followRetryDue(generation: generation, exists: exists))
            }
        case .sessionReady(let session):
            ConnectionTrace.mark("connected")
            host?.linkSessionReady(session)
        case .sessionLost:
            host?.linkSessionLost()
        case .report(let report):
            host?.linkReport(report)
        }
    }
}
