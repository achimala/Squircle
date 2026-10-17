import Foundation

/// M06, the phone's downloads: which of a conversation's pictures, posters
/// and recordings load, and in what order. Each pass over what is on screen
/// says which media near it aren't on the phone yet and how far each is
/// from the middle of what shows; the nearest go first, at most `limit` at
/// once (a cellular link shares its bandwidth, so a few at a time arrive
/// sooner than all at once). One that leaves before its bytes arrive is
/// cancelled, and a waiting one in sight takes the place of one that isn't;
/// bytes that did arrive stay in the cache. A recording, being large, is
/// only started in sight and always finishes. One that failed isn't asked
/// again until it leaves and comes back.
enum MediaLoads {
    struct Need: Equatable {
        /// Points from the middle of what shows; 0 is the middle.
        var distance: Double
        /// Some of it is in sight.
        var visible: Bool
        /// A large file: started only in sight and never cancelled.
        var whole = false
    }
    struct Load: Equatable {
        let op: Int
        let whole: Bool
        /// Cancelled; it holds its place until it ends.
        var cancelling = false
    }
    struct State: Equatable {
        let limit: Int
        /// What the last pass found missing near the screen.
        var wanted: [String: Need] = [:]
        var running: [String: Load] = [:]
        /// Failed while wanted.
        var failed: Set<String> = []
        var nextOp = 1
        init(limit: Int) { self.limit = limit }
    }
    enum Event: Equatable {
        /// A pass: everything not in it is no longer wanted.
        case seen([String: Need])
        /// Load `op` ended, with its bytes in the cache or not.
        case ended(key: String, op: Int, loaded: Bool)
    }
    enum Effect: Equatable {
        case start(key: String, op: Int)
        case cancel(key: String, op: Int)
    }
    typealias Result = Reduction<State, Effect>

    static func reduce(_ state: State, _ event: Event) -> Result {
        var s = state
        var effects: [Effect] = []
        func cancel(_ key: String) {
            guard let load = s.running[key], !load.cancelling else { return }
            s.running[key]?.cancelling = true
            effects.append(.cancel(key: key, op: load.op))
        }

        switch event {
        case .seen(let needs):
            guard needs != s.wanted else { return Result(state: s, disposition: .duplicate) }
            s.wanted = needs
            s.failed.formIntersection(needs.keys)
            for (key, load) in s.running where !load.whole && needs[key] == nil { cancel(key) }
        case .ended(let key, let op, let loaded):
            guard let load = s.running[key], load.op == op else { return Result(state: s, disposition: .stale) }
            s.running[key] = nil
            // In the cache now: the next pass won't list it.
            if loaded { s.wanted[key] = nil }
            else if !load.cancelling, s.wanted[key] != nil { s.failed.insert(key) }
        }

        // Nearest first: in sight, then by distance (then key, to be stable).
        let waiting = s.wanted.filter { key, need in
            s.running[key] == nil && !s.failed.contains(key) && (!need.whole || need.visible)
        }.sorted { a, b in
            if a.value.visible != b.value.visible { return a.value.visible }
            return a.value.distance != b.value.distance ? a.value.distance < b.value.distance : a.key < b.key
        }
        var free = s.limit - s.running.count
        var inSightWaiting = 0
        for (key, need) in waiting {
            guard free > 0 else { if need.visible { inSightWaiting += 1 }; continue }
            s.running[key] = Load(op: s.nextOp, whole: need.whole)
            effects.append(.start(key: key, op: s.nextOp))
            s.nextOp += 1
            free -= 1
        }
        // Full, with something in sight waiting: the farthest out of sight
        // make room (each one cancelled frees its place when it ends).
        let cancelling = s.running.values.filter(\.cancelling).count
        let yielding = s.running.filter { key, load in !load.whole && !load.cancelling && s.wanted[key]?.visible != true }
            .sorted { (s.wanted[$0.key]?.distance ?? .infinity) > (s.wanted[$1.key]?.distance ?? .infinity) }
        for (key, _) in yielding.prefix(max(0, inSightWaiting - cancelling)) { cancel(key) }
        return Result(state: s, effects: effects)
    }

    /// What must hold after every event.
    static func violations(in s: State) -> [String] {
        var found: [String] = []
        if s.running.count > s.limit { found.append("more loads than the limit") }
        for (key, load) in s.running {
            if s.failed.contains(key) { found.append("a failed load still running") }
            if !load.whole, !load.cancelling, s.wanted[key] == nil { found.append("an unwanted load not cancelled") }
            if load.op >= s.nextOp { found.append("a load from the future") }
        }
        if !s.failed.isSubset(of: s.wanted.keys) { found.append("a failure kept after it left") }
        return found
    }
}
