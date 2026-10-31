import simd

/// Who a worker is, beyond its state's colour: picked once from its thread
/// ID's hash, so the same worker looks the same everywhere and its cached
/// loops key on it (nothing is decided per frame). The app's agent has none
/// of these: the plain cube.
///
/// Proposal (2026-10-31, user: workers "all too samey" and too like the top
/// level one): three directions, for the user to pick one.
struct JellyTraits: Hashable {
    enum Direction: CaseIterable {
        /// Something grows on its head (antenna, leaf, ears, tuft, bun).
        case sprouts
        /// Its own eyes and a mouth (the agent has no mouth), some blushing.
        case faces
        /// A round pebble body, not a cube, with markings in its own tint.
        case pebbles
    }

    /// The shader's identity knobs: eye spacing, cube aspect, eye size, roundness.
    var look: SIMD4<Float>
    /// Topper, its lean, eye style, mouth.
    var traits: SIMD4<Float> = .zero
    /// Pattern, blush.
    var marks: SIMD4<Float> = .zero

    /// The direction being shown (the user picks one).
    static let direction: Direction = .sprouts

    static let plain = JellyTraits(look: SIMD4(1, 1, 1, 0.28))

    /// Workers' eyes relative to the agent's, at the same body size.
    static let workerEyes: Float = 1.5

    static func worker(hash: UInt64, _ direction: Direction) -> JellyTraits {
        // Independent bytes of the hash for each feature.
        func pick(_ n: Int, _ byte: Int) -> Int { Int((hash >> UInt64(8 * byte)) & 0xff) % n }
        let aspects: [Float] = [1, 1.16, 0.86], spacings: [Float] = [0.84, 0.96, 1.08]
        let leans: [Float] = [-1, -0.4, 0.4, 1]
        switch direction {
        case .sprouts:
            return JellyTraits(look: SIMD4(spacings[pick(3, 1)], aspects[pick(3, 2)], workerEyes, 0.36),
                               traits: SIMD4(Float(1 + pick(5, 3)), leans[pick(4, 4)], 0, 0))
        case .faces:
            // Eyes 0 beads, 1 tall pills, 2 big rounds, 3 tiny dots, 4 wide ovals, 5 uneven.
            let eyes = pick(6, 3)
            let size: Float = eyes == 3 ? 1.25 : eyes == 2 ? 1.25 : workerEyes
            return JellyTraits(look: SIMD4(eyes == 3 ? 1.12 : spacings[pick(3, 1)], aspects[pick(3, 2)], size, 0.36),
                               traits: SIMD4(0, 0, Float(eyes), Float(1 + pick(4, 4))),
                               marks: SIMD4(0, pick(2, 5) == 0 ? 1 : 0, 0, 0))
        case .pebbles:
            // Patterns 1 spots, 2 band, 3 belly, 4 freckles, 5 cap, 6 side stripes.
            let roundness: [Float] = [0.44, 0.48, 0.5]
            return JellyTraits(look: SIMD4(spacings[pick(3, 1)], [1.0, 1.24, 0.8][pick(3, 2)], 1.3, roundness[pick(3, 4)]),
                               marks: SIMD4(Float(1 + pick(6, 3)), 0, 0, 0))
        }
    }
}
