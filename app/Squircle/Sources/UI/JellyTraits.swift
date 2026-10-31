import CoreGraphics
import Foundation
import simd

/// Who a worker is, beyond its state: the sprout on its head, which way it
/// leans, and its build (user, 2026-10-31: "sprouts", with faces kept for
/// status). Every jelly, agent or worker, shows the same face for the same
/// state; only these vary. Given once per thread (`JellyCrew`), so the same
/// worker looks the same everywhere and its cached loops key on it.
/// The app's agent has none: the bare cube.
struct JellyTraits: Hashable {
    /// The shader's identity knobs: eye spacing, cube aspect, eye size, roundness.
    var look: SIMD4<Float>
    /// Sprout kind (0 none, 1...kinds), lean, scale, -.
    var sprout: SIMD4<Float> = .zero

    static let plain = JellyTraits(look: SIMD4(1, 1, 1, 0.28))

    /// Workers' eyes relative to the agent's, at the same body size (chibi).
    static let workerEyes: Float = 1.5
    /// Sprouts the shader draws (antenna, leaves, ears, tuft, bun, …).
    static let kinds = 20
    /// Room a sprout takes above the body, as a fraction of its size.
    static let crown: CGFloat = 0.5

    static let leans: [Float] = [-1, -0.5, 0, 0.5, 1]
    static let scales: [Float] = [0.92, 1.1]
    static let aspects: [Float] = [1, 1.16, 0.86]
    static let roundness: [Float] = [0.38, 0.46]
    /// Distinct looks: 1,200.
    static var count: Int { kinds * leans.count * scales.count * aspects.count * roundness.count }

    /// The `n`th look in the crew's sequence: twenty workers in a row all
    /// get different sprouts, and each round of twenty shifts lean, scale
    /// and build, so two workers met close together never look alike.
    static func worker(_ n: Int) -> JellyTraits {
        // Sprouts ordered so neighbours differ most (a stalk, then ears, then a cluster…).
        let order = [1, 3, 12, 16, 6, 17, 4, 13, 8, 15, 2, 11, 19, 10, 18, 5, 9, 7, 14, 20]
        let round = n / kinds
        let kind = order[n % kinds]
        let lean = leans[(n * 2 + round) % leans.count]
        let scale = scales[(n + round) % scales.count]
        let aspect = aspects[(n + round * 2) % aspects.count]
        let corners = roundness[(n / 2 + round) % roundness.count]
        return JellyTraits(look: SIMD4(1, aspect, workerEyes, corners), sprout: SIMD4(Float(kind), lean, scale, 0))
    }
}

/// Which look each worker has: the next in the sequence the first time this
/// phone shows it, kept from then on (in this app's preferences), so it is
/// the same worker everywhere and the ones you meet together differ.
@MainActor
final class JellyCrew {
    static let shared = JellyCrew()
    private let defaults: UserDefaults
    private var slots: [String: Int]
    private var next: Int
    private static let key = "jellyCrew", limit = 600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        slots = defaults.dictionary(forKey: Self.key + ".slots") as? [String: Int] ?? [:]
        next = defaults.integer(forKey: Self.key + ".next")
    }

    func traits(_ id: String) -> JellyTraits {
        // A placeholder (no thread yet) takes no slot.
        guard !id.isEmpty else { return JellyTraits.worker(0) }
        let id = id.lowercased()
        if let n = slots[id] { return JellyTraits.worker(n) }
        let n = next
        next += 1
        slots[id] = n
        // Forget the oldest beyond the limit.
        if slots.count > Self.limit { slots = slots.filter { $0.value > n - Self.limit } }
        defaults.set(slots, forKey: Self.key + ".slots")
        defaults.set(next, forKey: Self.key + ".next")
        return JellyTraits.worker(n)
    }
}
