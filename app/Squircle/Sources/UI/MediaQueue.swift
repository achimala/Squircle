import Foundation

/// M06's one executor for a conversation's downloads (`MediaLoads`). Each
/// pass hands it what is missing near the screen, with the work that loads
/// each into the cache; it runs what the reducer starts and cancels.
@MainActor
final class MediaQueue {
    struct Want {
        let need: MediaLoads.Need
        /// Loads it into the cache and shows it; true if it's there now.
        let load: () async -> Bool
    }
    /// After a load ends: what's missing may have changed.
    var onEnded: (() -> Void)?
    private var state: MediaLoads.State
    private var jobs: [String: () async -> Bool] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]

    /// Three at once: over cellular the first picture in sight lands
    /// sooner than with a whole screen's worth sharing the link.
    init(limit: Int = 3) { state = MediaLoads.State(limit: limit) }
    deinit { tasks.values.forEach { $0.cancel() } }

    func seen(_ wants: [String: Want]) {
        for (key, want) in wants { jobs[key] = want.load }
        send(.seen(wants.mapValues(\.need)))
        jobs = jobs.filter { state.wanted[$0.key] != nil || state.running[$0.key] != nil }
    }

    private func send(_ event: MediaLoads.Event) {
        let reduction = MediaLoads.reduce(state, event)
        #if DEBUG
        for violation in MediaLoads.violations(in: reduction.state) { NSLog("SQUIRCLE-FSM M06 %@", violation) }
        #endif
        state = reduction.state
        for effect in reduction.effects { perform(effect) }
    }

    private func perform(_ effect: MediaLoads.Effect) {
        switch effect {
        case .start(let key, let op):
            guard let job = jobs[key] else { send(.ended(key: key, op: op, loaded: false)); return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["SQUIRCLE_MEDIA_LOG"] != nil {
                NSLog("SQUIRCLE-MEDIA start %@ distance=%.0f visible=%d", key, state.wanted[key]?.distance ?? -1, state.wanted[key]?.visible == true ? 1 : 0)
            }
            #endif
            tasks[op] = Task { [weak self] in
                let loaded = await job()
                guard let self else { return }
                tasks[op] = nil
                #if DEBUG
                if ProcessInfo.processInfo.environment["SQUIRCLE_MEDIA_LOG"] != nil { NSLog("SQUIRCLE-MEDIA end %@ loaded=%d", key, loaded ? 1 : 0) }
                #endif
                send(.ended(key: key, op: op, loaded: loaded))
                onEnded?()
            }
        case .cancel(_, let op):
            tasks[op]?.cancel()
        }
    }
}
