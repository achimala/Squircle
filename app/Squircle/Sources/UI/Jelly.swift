import Metal
import simd
import UIKit

/// A jelly always means an agent: one T3 thread, live (user, 2026-10-15,
/// direction B "little crew"). Colour is its state, shape is who it is.
/// The app's agent is the plain full-size jelly under a soap film (design
/// deck, 2026-10-31); a worker is a Sprout, with a stable look of its own.
struct JellyLook: Hashable {
    enum Role: Hashable { case agent, worker }
    enum Mood: Hashable {
        case working, needsYou, done, idle, failed, offline

        init(_ state: WorkerState) {
            switch state {
            case .working: self = .working
            case .needsYou: self = .needsYou
            case .done, .archived: self = .done
            case .error: self = .failed
            }
        }

        init(_ phase: ChatSession.Phase) {
            switch phase {
            case .working: self = .working
            case .needsYou: self = .needsYou
            case .idle: self = .idle
            }
        }

        /// Loops while shown (within the budget); the rest are stills.
        var loops: Bool { self == .working || self == .needsYou || self == .idle }
    }

    var role: Role
    var mood: Mood
    /// Who it is, from its thread ID; the agent is plain.
    var traits: JellyTraits
    /// The first byte of its ID's hash, for its temperament (blink and glance timing).
    var temper: Int

    static func agent(_ mood: Mood) -> JellyLook { JellyLook(role: .agent, mood: mood, traits: .plain, temper: 0) }

    @MainActor
    static func worker(_ id: String, _ mood: Mood) -> JellyLook {
        // FNV-1a: stable across launches (Swift's hashes are not).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return JellyLook(role: .worker, mood: mood, traits: JellyCrew.shared.traits(id), temper: Int((hash >> 16) & 0xff))
    }
}

/// One frame of a jelly's face and body.
struct JellyPose {
    var lid: CGFloat = 1, happy: CGFloat = 0, squint: CGFloat = 0, worry: CGFloat = 0
    var gaze = CGPoint.zero
    var yaw = JellyBody.yaw, pitch = JellyBody.pitch, roll: CGFloat = 0
    var squash: CGFloat = 0
    /// Points up, as a fraction of its size.
    var hop: CGFloat = 0
    /// The agent's soap film drifting: an angle, once round per loop.
    var drift: CGFloat = 0

    /// How long one loop of `mood` lasts, and its frames per second.
    static func period(_ mood: JellyLook.Mood) -> Double {
        switch mood {
        case .working: 3.2
        case .needsYou: 3.0
        case .idle: 6.0
        case .done: 1.0
        case .failed: 0.7
        case .offline: 1
        }
    }
    static let fps: Double = 15

    /// The pose at `t` seconds into its loop (periodic in `period`), or for
    /// `.done` and `.failed` into their one arrival (a gulp, a shudder).
    static func at(_ t: Double, _ look: JellyLook) -> JellyPose {
        var p = JellyPose()
        let P = period(look.mood)
        let temper = Double(look.temper) / 255
        func smooth(_ x: Double) -> CGFloat { let c = min(1, max(0, x)); return CGFloat(c * c * (3 - 2 * c)) }
        // A blink: shut fast, open slower, over 0.24 s from `at`.
        func blink(at: Double, length: Double = 0.24) -> CGFloat {
            let u = (t - at) / length
            guard u >= 0, u < 1 else { return 1 }
            let lid = u < 0.35 ? 1 - u / 0.35 : (u - 0.35) / 0.65
            return smooth(lid)
        }
        p.drift = CGFloat(2 * Double.pi * t / P)
        switch look.mood {
        case .working:
            // Reading along a line, a word at a time, then back to the next.
            let step = 0.8, k = Double(Int(t / step) % 4)
            let from = k == 0 ? 3.0 : k - 1, ease = smooth((t - k * step) / 0.16)
            let x = { (i: Double) in CGFloat(-1.3 + 0.85 * i) }
            p.gaze = CGPoint(x: x(from) + (x(k) - x(from)) * ease, y: 0.7)
            p.squash = 0.025 * CGFloat(sin(2 * .pi * t / P))
            p.lid = blink(at: (0.45 + 0.4 * temper) * P)
        case .needsYou:
            // A hop for your attention, then waiting, looking up at you.
            p.worry = 1
            p.gaze = CGPoint(x: 0, y: -0.5)
            let air = 0.5
            if t < air {
                let u = t / air
                p.hop = 0.32 * CGFloat(sin(.pi * u))
                p.squash = -0.06 * CGFloat(sin(.pi * u))
            } else if t < air + 0.6 {
                let u = t - air
                p.squash = 0.14 * CGFloat(exp(-6 * u) * cos(2 * .pi * 2.4 * u))
            } else if t > P - 0.18 {
                p.squash = 0.08 * smooth((t - (P - 0.18)) / 0.18)
            }
            p.lid = blink(at: 1.6 + 0.6 * temper)
        case .idle:
            p.lid = 0.5 * blink(at: (0.5 + 0.3 * temper) * P, length: 0.6)
            p.gaze = CGPoint(x: 0, y: 0.6)
            p.squash = 0.02 * CGFloat(sin(2 * .pi * t / P))
        case .done:
            // One gulp, then happy and still.
            p.happy = 1
            p.squash = 0.18 * CGFloat(exp(-5 * t) * cos(2 * .pi * 2.6 * t)) * (t < P ? 1 : 0)
        case .failed:
            // Slumped `> <`, with one shudder on arrival.
            p.squint = 1
            p.squash = 0.15
            p.roll = -0.14 + (t < P ? 0.09 * CGFloat(exp(-6 * t) * sin(2 * .pi * 7 * t)) : 0)
            p.gaze = CGPoint(x: 0, y: 0.8)
        case .offline:
            p.lid = 0.45
            p.gaze = CGPoint(x: 0, y: 0.6)
        }
        return p
    }

    /// The still frame: what a stopped jelly shows.
    static func still(_ look: JellyLook) -> JellyPose {
        switch look.mood {
        case .working:
            var p = at(0, look); p.gaze = CGPoint(x: 1.1, y: 0.9); p.squash = 0; p.lid = 1; return p
        case .needsYou:
            var p = at(2.0, look); p.lid = 1; p.squash = 0; return p
        case .idle: var p = at(0, look); p.lid = 0.5; p.squash = 0; return p
        case .done, .failed: return at(10, look)
        case .offline: return at(0, look)
        }
    }
}

/// Where a jelly sits in its picture: the body is `size` points square,
/// with room around it for the turned cube's top and side and, above, for
/// a hop.
struct JellyCanvas: Hashable {
    var size: CGFloat
    /// Room around the body, as fractions of its size.
    var side: CGFloat, top: CGFloat, bottom: CGFloat

    /// For lists: room to hop.
    static func roomy(_ size: CGFloat) -> JellyCanvas { JellyCanvas(size: size, side: 0.22, top: 0.5, bottom: 0.18) }
    /// For a glyph in text: just the body.
    static func tight(_ size: CGFloat) -> JellyCanvas { JellyCanvas(size: size, side: 0.1, top: 0.14, bottom: 0.12) }

    var bounds: CGSize { CGSize(width: size * (1 + 2 * side), height: size * (1 + top + bottom)) }
    /// With room above for a worker's sprout.
    func fitting(_ look: JellyLook) -> JellyCanvas {
        guard look.traits.sprout.x > 0 else { return self }
        var c = self; c.top += JellyTraits.crown; return c
    }
    /// The body's frame within `bounds`. Every jelly's body bottom sits on
    /// one line near its bottom (`baseline`), whatever its build or sprout,
    /// and the reference body is centred in it, so owners lay a jelly out by
    /// this square: its centre on the text's visual centre.
    var body: CGRect { CGRect(x: size * side, y: size * top, width: size, height: size) }
    /// Where the body's visible bottom sits, the same for every build.
    func baseline(_ role: JellyLook.Role) -> CGFloat { body.midY + JellyBody.reference(role) * size }
}

/// The body as the shader draws it at rest (turned by `JellyBody.yaw` and
/// `.pitch`, a rounded box): how far its visible bottom reaches below its
/// centre, as a fraction of its size. A tall build reaches further than a
/// squat one, so each is placed by its bottom, not its centre: the sprout
/// grows up into the room above and never moves the body.
enum JellyBody {
    static let yaw: CGFloat = -0.3, pitch: CGFloat = -0.4

    /// The shader's `cubeD` at rest, seen from the front: half its height
    /// on screen (the box's inner half-extents turned, plus its rounding).
    static func reach(_ look: SIMD4<Float>) -> CGFloat {
        let aspect = CGFloat(look.y).squareRoot(), round = CGFloat(look.w)
        let half = (y: 0.5 / aspect, z: 0.4)
        return abs(cos(pitch)) * (half.y - round) + abs(sin(pitch)) * (half.z - round) + round
    }

    /// Half its width on screen, the same way: so a row of them can stand
    /// a set gap apart, wide or narrow.
    static func halfWidth(_ look: SIMD4<Float>) -> CGFloat {
        let aspect = CGFloat(look.y).squareRoot(), round = CGFloat(look.w)
        let half = (x: 0.5 * aspect, y: 0.5 / aspect, z: 0.4)
        return abs(cos(yaw)) * (half.x - round) + abs(sin(yaw) * sin(pitch)) * (half.y - round)
            + abs(sin(yaw) * cos(pitch)) * (half.z - round) + round
    }

    /// The reach every body of a role is placed by: the bare agent's own;
    /// for workers a square build of middling roundness, so their bodies,
    /// tall or squat, centre on average and share one bottom.
    static func reference(_ role: JellyLook.Role) -> CGFloat {
        switch role {
        case .agent: reach(JellyTraits.plain.look)
        case .worker:
            reach(SIMD4(1, 1, JellyTraits.workerEyes, JellyTraits.roundness.reduce(0, +) / Float(JellyTraits.roundness.count)))
        }
    }

    /// Where its centre goes so its bottom sits on `baseline`.
    static func centre(_ look: JellyLook, on baseline: CGFloat, size: CGFloat) -> CGFloat {
        baseline - reach(look.traits.look) * size
    }
}

extension JellyRenderer {
    /// The pose as the shader draws a lone jelly (no pill, no neck) on `canvas`.
    @MainActor
    static func uniforms(_ pose: JellyPose, _ look: JellyLook, canvas: JellyCanvas, scale: CGFloat,
                         traits: UITraitCollection) -> JellyUniforms {
        let color: UIColor = switch look.mood {
        case .working: Theme.working
        case .needsYou: Theme.warning
        case .done: Theme.success
        case .failed: Theme.failure
        case .idle, .offline: Theme.idle
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        // Small jellies read pale on cream: denser below hero size.
        var strength: CGFloat = 0.85 * (canvas.size < 30 ? 1.25 : 1)
        if look.mood == .idle { strength *= 0.85 }
        if look.mood == .offline {
            let grey = 0.3 * r + 0.59 * g + 0.11 * b
            (r, g, b) = (.lerp(r, grey, 0.75), .lerp(g, grey, 0.75), .lerp(b, grey, 0.75))
            strength *= 0.5
        }
        let s = canvas.size
        // Placed by its bottom: every build on the same line, hopping up from it.
        let rest = JellyBody.centre(look, on: canvas.baseline(look.role), size: s)
        let center = CGPoint(x: canvas.body.midX, y: rest - pose.hop * s)
        return JellyUniforms(
            tint: SIMD4(Float(r), Float(g), Float(b), Float(strength)),
            fill: SIMD4(1, 1, 1, 0),
            face: SIMD4(Float(pose.lid), Float(pose.happy), Float(pose.squint), Float(pose.worry)),
            inverse: SIMD4(1, 0, 0, 1),
            creature: SIMD4(Float(center.x), Float(center.y), 34, 0),
            pose: SIMD4(Float(pose.yaw), Float(pose.pitch), Float(pose.roll), Float(pose.squash)),
            gaze: SIMD4(Float(pose.gaze.x), Float(pose.gaze.y), Float(center.x), Float(center.y)),
            bridge: SIMD4(0, 1, 0, 0),
            stubs: SIMD4(0, 0, Float(s / 34), 0),
            look: look.traits.look, sprout: look.traits.sprout,
            film: look.role == .agent ? SIMD4(1, Float(cos(pose.drift)), Float(sin(pose.drift)), 0) : .zero,
            // No pill: its body is far off the canvas.
            center: SIMD2(-1e4, -1e4), half: SIMD2(1, 1), origin: SIMD2(0, 0),
            scale: Float(scale), radius: 1, pillow: 0, time: 0, churn: 0, opened: 0,
            dark: traits.userInterfaceStyle == .dark ? 1 : 0, mode: 0)
    }

    /// Draws each pose offscreen into an image (premultiplied BGRA), all in
    /// one command buffer. Any thread; empty when there is no GPU.
    nonisolated static func images(_ frames: [JellyUniforms], width: Int, height: Int) -> [CGImage] {
        guard let device, let queue, let pipeline, width > 0, height > 0,
              let commands = queue.makeCommandBuffer() else { return [] }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        var textures: [MTLTexture] = []
        for var u in frames {
            guard let texture = device.makeTexture(descriptor: descriptor) else { return [] }
            guard encode(&u, into: texture, on: commands, pipeline: pipeline) else { return [] }
            textures.append(texture)
        }
        commands.commit()
        commands.waitUntilCompleted()
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return textures.compactMap { texture in
            var bytes = Data(count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Compiles the shader off the main thread, so the first jelly on
    /// screen doesn't wait for it.
    nonisolated static func warm() {
        Task.detached(priority: .utility) { _ = pipeline }
    }
}

/// Every small jelly's pictures: a still, a loop (its mood's frames at
/// 15 fps) or an arrival (done's gulp, failed's shudder), rendered once by
/// the shader and kept by (look, canvas, scale, appearance).
@MainActor
final class JellySprites {
    static let shared = JellySprites()

    enum Clip: Hashable { case still, loop }
    struct Key: Hashable {
        let look: JellyLook
        let canvas: JellyCanvas
        let scale: CGFloat
        let dark: Bool
        let clip: Clip
    }

    private let cache = RecentCache<Key, [CGImage]>(limit: 64)
    private var pending: [Key: Task<[CGImage], Never>] = [:]

    private static func key(_ look: JellyLook, _ canvas: JellyCanvas, _ traits: UITraitCollection, _ clip: Clip) -> Key {
        // Loops of moods that don't loop are their arrival.
        Key(look: look, canvas: canvas.fitting(look), scale: min(3, max(2, traits.displayScale)), dark: traits.userInterfaceStyle == .dark, clip: clip)
    }

    private func uniforms(_ key: Key, _ traits: UITraitCollection) -> [JellyUniforms] {
        let poses: [JellyPose]
        switch key.clip {
        case .still: poses = [JellyPose.still(key.look)]
        case .loop:
            let count = max(1, Int((JellyPose.period(key.look.mood) * JellyPose.fps).rounded()))
            poses = (0..<count).map { JellyPose.at(Double($0) / JellyPose.fps, key.look) }
        }
        return poses.map { JellyRenderer.uniforms($0, key.look, canvas: key.canvas, scale: key.scale, traits: traits) }
    }

    private func pixels(_ key: Key) -> (Int, Int) {
        let size = key.canvas.bounds
        return (Int((size.width * key.scale).rounded(.up)), Int((size.height * key.scale).rounded(.up)))
    }

    /// The still, now: drawn on this thread if it isn't kept yet (a small
    /// picture, well under a millisecond) once the shader is compiled.
    func still(_ look: JellyLook, _ canvas: JellyCanvas, traits: UITraitCollection) -> CGImage? {
        let key = Self.key(look, canvas, traits, .still)
        if let images = cache.value(for: key) { return images.first }
        let (w, h) = pixels(key)
        let images = JellyRenderer.images(uniforms(key, traits), width: w, height: h)
        if !images.isEmpty { cache.set(images, for: key) }
        return images.first
    }

    /// A still as an image for text and SwiftUI.
    func image(_ look: JellyLook, _ canvas: JellyCanvas, traits: UITraitCollection) -> UIImage? {
        let key = Self.key(look, canvas, traits, .still)
        return still(look, canvas, traits: traits).map { UIImage(cgImage: $0, scale: key.scale, orientation: .up) }
    }

    /// The loop's frames, rendered on a background task the first time.
    func loop(_ look: JellyLook, _ canvas: JellyCanvas, traits: UITraitCollection) async -> [CGImage] {
        let key = Self.key(look, canvas, traits, .loop)
        if let images = cache.value(for: key) { return images }
        if let task = pending[key] { return await task.value }
        let frames = uniforms(key, traits), (w, h) = pixels(key)
        let task = Task.detached(priority: .userInitiated) { JellyRenderer.images(frames, width: w, height: h) }
        pending[key] = task
        let images = await task.value
        pending[key] = nil
        if !images.isEmpty { cache.set(images, for: key) }
        return images
    }

    /// Kept frames, if any, without rendering.
    func cachedLoop(_ look: JellyLook, _ canvas: JellyCanvas, traits: UITraitCollection) -> [CGImage]? {
        cache.value(for: Self.key(look, canvas, traits, .loop))
    }
}

/// A small jelly: a picture, still by default, playing its mood's loop
/// when `JellyDirector` lets it (at most four at once, on screen, Motion
/// and Low Power permitting). Sized by its owner; the picture overflows the
/// bounds (the bounds are the body) for the cube's top and its hop.
@MainActor
final class JellyView: UIView {
    var look: JellyLook {
        didSet { if look != oldValue { lookChanged(from: oldValue) } }
    }
    /// Plays its loop when allowed; false keeps it still (old lines,
    /// previews), from this frame rather than the director's next tick.
    var animates = true {
        didSet {
            guard animates != oldValue else { return }
            if !animates, playing { play(false, now: 0) }
            JellyDirector.shared.needsUpdate()
        }
    }
    let canvas: JellyCanvas
    private let picture = CALayer()
    private var frames: [CGImage] = []
    private var loading: Task<Void, Never>?
    /// The arrival playing (done's gulp, failed's shudder), from when.
    private var arrival: (frames: [CGImage], start: CFTimeInterval)?
    fileprivate(set) var playing = false
    /// Where its loop starts, so two side by side never blink together.
    private let offset: Double

    init(_ look: JellyLook, canvas: JellyCanvas) {
        self.look = look
        self.canvas = canvas
        offset = Double(look.temper) / 255 * 2
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: canvas.size, height: canvas.size)))
        isUserInteractionEnabled = false
        picture.contentsGravity = .resize
        layer.addSublayer(picture)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _) in self.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: canvas.size, height: canvas.size) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let canvas = canvas.fitting(look)
        let k = bounds.width / canvas.size, b = canvas.body, full = canvas.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = CGRect(x: -b.minX * k, y: -b.minY * k, width: full.width * k, height: full.height * k)
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { JellyDirector.shared.add(self) }
        JellyDirector.shared.needsUpdate()
    }

    private func lookChanged(from old: JellyLook) {
        reload()
        // Done gulps and failed shudders once, as it happens, where it is seen.
        if old.mood != look.mood, look.mood == .done || look.mood == .failed, window != nil, animates, JellyDirector.shared.motionAllowed {
            let look = look, traits = traitCollection
            Task { [weak self] in
                let clip = await JellySprites.shared.loop(look, self?.canvas ?? .roomy(20), traits: traits)
                guard let self, self.look == look else { return }
                arrival = (clip, CACurrentMediaTime())
                JellyDirector.shared.needsUpdate()
            }
        } else {
            arrival = nil
        }
    }

    private func reload() {
        setNeedsLayout()
        loading?.cancel()
        frames = []
        arrival = nil
        show(JellySprites.shared.still(look, canvas, traits: traitCollection))
        JellyDirector.shared.needsUpdate()
    }

    private func show(_ image: CGImage?) {
        guard picture.contents as! CGImage? !== image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }

    /// Whether it wants to move now.
    fileprivate var wantsMotion: Bool { animates && (look.mood.loops || arrival != nil) }

    /// The director's tick: the frame for `now`, or the still.
    fileprivate func play(_ allowed: Bool, now: CFTimeInterval) {
        if let (clip, start) = arrival {
            let index = Int((now - start) * JellyPose.fps)
            if !allowed || index >= clip.count {
                arrival = nil
            } else {
                playing = true
                show(clip[index])
                return
            }
        }
        guard allowed, look.mood.loops else {
            playing = false
            show(JellySprites.shared.still(look, canvas, traits: traitCollection))
            return
        }
        if frames.isEmpty {
            if let kept = JellySprites.shared.cachedLoop(look, canvas, traits: traitCollection) {
                frames = kept
            } else if loading == nil {
                let look = look, traits = traitCollection
                loading = Task { [weak self] in
                    let loop = await JellySprites.shared.loop(look, self?.canvas ?? .roomy(20), traits: traits)
                    guard let self, !Task.isCancelled, self.look == look else { return }
                    loading = nil
                    frames = loop
                }
                return
            } else {
                return
            }
        }
        playing = true
        let index = Int(((now + offset) * JellyPose.fps).rounded(.down)) % frames.count
        show(frames[index])
    }

    /// Ranked before others for the budget: needs you first, then nearest the top.
    fileprivate var urgency: Int { look.mood == .needsYou ? 0 : 1 }
}

/// The one clock for every small jelly: a 15 fps display link that runs
/// only while one plays. At most `budget` play at once (needs you first,
/// then the ones nearest the top of the screen); the rest hold their still.
/// Nothing plays off screen, under a sheet, in the background, with Reduce
/// Motion or in Low Power Mode.
@MainActor
final class JellyDirector {
    static let shared = JellyDirector()
    static let budget = 4

    private struct Weak { weak var view: JellyView? }
    private var views: [ObjectIdentifier: Weak] = [:]
    private var link: CADisplayLink?
    private var active = true
    private var observers: [Task<Void, Never>] = []

    private init() {
        let center = NotificationCenter.default
        let events: [(Notification.Name, @MainActor (JellyDirector) -> Void)] = [
            (UIApplication.didEnterBackgroundNotification, { $0.active = false; $0.needsUpdate() }),
            (UIApplication.didBecomeActiveNotification, { $0.active = true; $0.needsUpdate() }),
            (UIAccessibility.reduceMotionStatusDidChangeNotification, { $0.needsUpdate() }),
            (Notification.Name.NSProcessInfoPowerStateDidChange, { $0.needsUpdate() })
        ]
        observers = events.map { name, action in
            Task { [weak self] in
                for await _ in center.notifications(named: name) {
                    guard let self else { return }
                    action(self)
                }
            }
        }
    }

    var motionAllowed: Bool { active && !Motion.reduced && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    func add(_ view: JellyView) { views[ObjectIdentifier(view)] = Weak(view: view) }

    /// Something changed: decide on the next frame (and keep ticking while any play).
    func needsUpdate() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] link in self?.tick(link) },
                                 selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: Float(JellyPose.fps))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// On screen, in a window, not hidden or faded out, not under a sheet.
    static func visible(_ view: UIView) -> Bool {
        guard let window = view.window, !view.isHidden else { return false }
        var node: UIView? = view.superview
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        guard view.alpha > 0.01, view.convert(view.bounds, to: window).intersects(window.bounds) else { return false }
        // Covered by a presented sheet it isn't part of.
        var top = window.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        if let top, top !== window.rootViewController, let sheet = top.view, !view.isDescendant(of: sheet) { return false }
        return true
    }

    private func tick(_ link: CADisplayLink) {
        views = views.filter { $0.value.view != nil }
        let all = views.values.compactMap(\.view)
        let allowed = motionAllowed
        let candidates = all.filter { $0.wantsMotion && allowed && Self.visible($0) }
            .map { view in (view, view.window.map { view.convert(view.bounds, to: $0).minY } ?? 0) }
            .sorted { ($0.0.urgency, $0.1) < ($1.0.urgency, $1.1) }
            .prefix(Self.budget).map { ObjectIdentifier($0.0) }
        let chosen = Set(candidates)
        let now = link.targetTimestamp
        for view in all where chosen.contains(ObjectIdentifier(view)) || view.playing {
            view.play(chosen.contains(ObjectIdentifier(view)), now: now)
        }
        // Ticks while one could play: one scrolled away comes back on its
        // own. Asleep when none could (all still, away, Reduce Motion…).
        if !allowed || !all.contains(where: { $0.wantsMotion && $0.window != nil }) {
            link.invalidate()
            self.link = nil
        }
    }

    #if DEBUG
    private var debugHeroes: [ObjectIdentifier: () -> JellyHero?] = [:]
    func debugAdd(_ hero: JellyHero) { debugHeroes[ObjectIdentifier(hero)] = { [weak hero] in hero } }

    private var debugHeroSince: CFTimeInterval?

    /// Stress audit, with every screen at rest: a hero drawing off screen
    /// (its screen covered, slid away or parked), held as long as a small
    /// one may be.
    func debugHeroViolation() -> String? {
        debugHeroes = debugHeroes.filter { $0.value() != nil }
        guard let stray = debugHeroes.values.compactMap({ $0() }).first(where: { $0.debugLive && !Self.visible($0) }) else {
            debugHeroSince = nil
            return nil
        }
        let now = CACurrentMediaTime()
        if debugHeroSince == nil { debugHeroSince = now }
        return now - (debugHeroSince ?? now) > 2.5 / JellyPose.fps ? "hero drawing off screen: \(stray.look.role) \(stray.look.mood)" : nil
    }

    /// Stress audit: more playing than the budget, or one playing off screen.
    /// Held for more than two of its ticks: a picture slid or scrolled
    /// away stops on the next tick, a 15th of a second later.
    func debugViolation() -> String? {
        let all = views.values.compactMap(\.view)
        let playing = all.filter(\.playing)
        var problem: String?
        if playing.count > Self.budget { problem = "\(playing.count) jellies playing (budget \(Self.budget))" }
        if let stray = playing.first(where: { !Self.visible($0) }) { problem = "jelly playing off screen: \(stray.look.role) \(stray.look.mood)" }
        let now = CACurrentMediaTime()
        guard problem != nil else { debugSince = nil; return nil }
        if debugSince == nil { debugSince = now }
        return now - (debugSince ?? now) > 2.5 / JellyPose.fps ? problem : nil
    }
    private var debugSince: CFTimeInterval?
    #endif
}

/// The hero: the conversation's own agent, by its live step, drawn live by
/// the shader every frame (30 fps) while it is on screen. It squashes when
/// touched. Still under Reduce Motion and Low Power Mode, and paused away
/// from the screen: out of a window, or not `inSight` (its screen covered or
/// slid away, as the route says). Only one is on screen at a time.
@MainActor
final class JellyHero: UIView {
    var look: JellyLook {
        didSet {
            guard look != oldValue else { return }
            if oldValue.mood != look.mood { moodStart = clock }
            if oldValue.traits != look.traits { setNeedsLayout() }
            wake()
        }
    }
    /// Its screen is showing, from the route; covered, it doesn't draw.
    var inSight = true { didSet { if inSight != oldValue { wake() } } }
    let canvas: JellyCanvas
    private let metal = CAMetalLayer()
    private var link: CADisplayLink?
    private var clock: CFTimeInterval = 0
    /// When its mood last changed (long ago at first: a done jelly shows still).
    private var moodStart: CFTimeInterval = -1000
    private var last: CFTimeInterval?
    private var press = Wobble(0, response: 0.32, damping: 0.42)
    private var drawn: JellyUniforms?
    private var observers: [Task<Void, Never>] = []

    init(_ look: JellyLook, size: CGFloat) {
        self.look = look
        canvas = .roomy(size)
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        metal.device = JellyRenderer.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        layer.addSublayer(metal)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.drawn = nil; self.wake() }
        let center = NotificationCenter.default
        #if DEBUG
        JellyDirector.shared.debugAdd(self)
        #endif
        observers = [UIAccessibility.reduceMotionStatusDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                     UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification].map { name in
            Task { [weak self] in
                for await _ in center.notifications(named: name) { self?.wake() }
            }
        }
    }

    deinit { link?.invalidate(); observers.forEach { $0.cancel() } }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: canvas.size, height: canvas.size) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let canvas = canvas.fitting(look), b = canvas.body, full = canvas.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = CGRect(x: -b.minX, y: -b.minY, width: full.width, height: full.height)
        let scale = min(3, window?.screen.scale ?? traitCollection.displayScale)
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: full.width * scale, height: full.height * scale)
        CATransaction.commit()
        drawn = nil
        wake()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        last = nil
        drawn = nil
        wake()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        press.target = 0.16
        wake()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        press.target = 0
        press.velocity -= 1.2
        wake()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        press.target = 0
        wake()
    }

    private var moving: Bool {
        JellyDirector.shared.motionAllowed && (look.mood.loops || clock - moodStart < JellyPose.period(look.mood))
    }

    /// Ticks while it moves on screen; otherwise draws its still once.
    private func wake() {
        guard window != nil, inSight, UIApplication.shared.applicationState != .background else {
            link?.invalidate(); link = nil
            return
        }
        if link == nil {
            let link = CADisplayLink(target: DisplayLinkProxy { [weak self] link in self?.tick(link) },
                                     selector: #selector(DisplayLinkProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(0.1, max(0, now - (last ?? now)))
        last = now
        clock += dt
        press.step(CGFloat(dt))
        let moves = moving
        var pose: JellyPose
        if moves {
            let since = clock - moodStart
            pose = look.mood.loops ? JellyPose.at(clock.truncatingRemainder(dividingBy: JellyPose.period(look.mood)), look)
                : JellyPose.at(since, look)
        } else {
            pose = JellyPose.still(look)
        }
        pose.squash += press.value
        if press.value > 0.05 { pose.squint = max(pose.squint, 1) }
        draw(pose)
        // Asleep once still and drawn.
        if !moves, press.isAtRest, drawn != nil {
            link.invalidate()
            self.link = nil
        }
    }

    private func draw(_ pose: JellyPose) {
        guard bounds.width > 0, let pipeline = JellyRenderer.pipeline, let queue = JellyRenderer.queue else { return }
        var u = JellyRenderer.uniforms(pose, look, canvas: canvas.fitting(look), scale: metal.contentsScale, traits: traitCollection)
        if let drawn, drawn.isClose(to: u) { return }
        guard let drawable = metal.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        guard JellyRenderer.encode(&u, into: drawable.texture, on: commands, pipeline: pipeline) else { return }
        commands.present(drawable)
        commands.commit()
        drawn = u
    }

    #if DEBUG
    var debugLive: Bool { link != nil }
    #endif
}

/// One damped spring on a value.
struct Wobble {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    var parameters: SpringDriver.Parameters

    init(_ value: CGFloat, response: CGFloat, damping: CGFloat) {
        self.value = value
        target = value
        parameters = .init(response: response, damping: damping)
    }

    var isAtRest: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.005 }

    mutating func step(_ dt: CGFloat) {
        (value, velocity) = SpringDriver.step(value: value, velocity: velocity, target: target, dt: dt, parameters: parameters)
    }
}
