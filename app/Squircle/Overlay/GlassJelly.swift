#if SQUIRCLE_OVERLAY || DEBUG
import Metal
import UIKit

/// The overlay's jelly (user, 2026-10-14). Two bodies of frosted glass jelly
/// joined by a liquid neck:
///
/// - the **blob**: the status line's pill, and grown, the panel holding the
///   conversation (a soft cushion that fills with paper as it opens);
/// - the **creature**: a rounded cube of jelly, drawn in 3D with perspective
///   (its top and a side face show; it leans into its motion and toward a
///   touch), with two eyes on its front. It sits at the pill's end while the
///   agent works, and rises above the panel's top edge as a head when open.
///
/// The neck is a smooth union of the two outlines, so it thins as they part
/// and pinches if the creature, on its own lagging spring, pulls too far.
/// Behind both, the app is faintly blurred (the system's live blur, masked).
///
/// Motion: the owner only sets the frame and where the creature belongs. The
/// blob feels the frame's acceleration and gives a little (damped squash and
/// shear of the rest shape, edges pillowed outward, never dented); the
/// creature follows a step behind, squashes when touched or landing, hops for
/// attention. Eyes move in eased glances with holds and blink on a timer.
@MainActor
final class GlassJelly: UIView {
    var tone = LiveCapsule.Tone.idle {
        didSet {
            guard tone != oldValue else { return }
            toneTime = 0
            switch tone {
            case .done: creatureSquash.velocity -= 1.6
            case .needsYou: hop.velocity -= 70
            case .working, .idle: break
            }
        }
    }
    /// The status line or the conversation: masked to the blob, carried by it.
    let content = UIView()
    /// The blob's rest shape, in bounds coordinates.
    var bodyRect = CGRect(x: 0, y: 0, width: 44, height: 44)
    var cornerRadius: CGFloat = 18
    /// Where the creature belongs, in bounds coordinates (its centre).
    var creatureAnchor = CGPoint(x: 22, y: 22)
    /// +1 when the creature sits to the right of the blob, -1 to the left.
    var creatureSide: CGFloat = 1
    static let creatureSize: CGFloat = 34
    /// 0 bubble … 1 panel: fills with paper, calms down.
    var opened: CGFloat = 0
    var fill = UIColor.white
    var fillAmount: CGFloat = 0
    /// The keyboard is up: it watches the field.
    var typing = false

    /// The creature as drawn now, in the superview's coordinates.
    var creatureFrame: CGRect {
        let s = Self.creatureSize
        return CGRect(x: creatureWorld.x - s / 2, y: creatureWorld.y - s / 2, width: s, height: s)
    }

    private let shadow = CAShapeLayer()
    private let frost = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    /// The blur shows exactly where the jelly is: its coverage, drawn by the
    /// same shader at a lower resolution.
    private let frostMask = MetalView()
    private let contentMask = CAShapeLayer()
    /// One layer draws the whole jelly: pill or panel, neck and cube.
    private let metal = CAMetalLayer()
    private static let margin: CGFloat = 60

    // Blob: squash (points the sides move out, the top and bottom in),
    // shear (points the top moves left), lag (points behind the frame).
    private var squash = Mode(), shear = Mode(), lagX = Mode(), lagY = Mode()
    private var lastPosition: CGPoint?, lastSize: CGSize?
    private var velocity = CGPoint.zero, sizeVelocity = CGSize.zero
    private var accel = CGPoint.zero, sizeAccel = CGSize.zero

    // Creature: its own place a step behind, squash, hop and lean.
    private var creatureWorld = CGPoint.zero
    private var creatureVelocity = CGPoint.zero
    private var placedCreature = false
    private var creatureSquash = Mode(), hop = Mode()
    private var yaw = Wobble(0, response: 0.45, damping: 0.85)
    private var pitch = Wobble(0, response: 0.45, damping: 0.85)
    private var roll = Wobble(0, response: 0.5, damping: 0.85)
    private var pressed = false

    // Face: glances (eased, held), blinks (timed), expressions.
    private var gazeX = Wobble(0, response: 0.16, damping: 1)
    private var gazeY = Wobble(0, response: 0.16, damping: 1)
    private var gazeHold: CGFloat = 0
    private var readStep = 0
    private var lid: CGFloat = 1
    private var blinkStart: CGFloat = -1
    private var nextBlink: CGFloat = 2.5
    private var doubleBlink = false
    private var happy = Wobble(0, response: 0.3, damping: 1)
    private var squint = Wobble(0, response: 0.12, damping: 1)
    private var worry = Wobble(0, response: 0.35, damping: 1)
    private var squintUntil: CGFloat = 0
    private var finger: (point: CGPoint, at: CGFloat)?
    private var tint = (r: Wobble(0, response: 0.35, damping: 1), g: Wobble(0, response: 0.35, damping: 1),
                        b: Wobble(0, response: 0.35, damping: 1), a: Wobble(0, response: 0.35, damping: 1))
    private var tintSet = false

    private var time: CGFloat = 0, toneTime: CGFloat = 0
    private var nextHop: CGFloat = 1.5
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var drawn: JellyUniforms?
    private var drawnCanvas = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.fillColor = UIColor.clear.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: 6)
        layer.addSublayer(shadow)
        frost.mask = frostMask
        frost.isUserInteractionEnabled = false
        addSubview(frost)
        for target in [metal, frostMask.metal] {
            target.device = JellyRenderer.device
            target.pixelFormat = .bgra8Unorm
            target.isOpaque = false
            target.framebufferOnly = true
        }
        layer.addSublayer(metal)
        contentMask.fillColor = UIColor.black.cgColor
        content.layer.mask = contentMask
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Events

    /// A finished task: the creature gulps it down.
    func gulp() { creatureSquash.velocity += 1.1 }

    /// Somewhere a finger touched (bounds coordinates).
    func look(at point: CGPoint) {
        if let finger, time - finger.at < 0.4, hypot(point.x - finger.point.x, point.y - finger.point.y) < 30 { return }
        finger = (point, time)
        gazeHold = 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        pressed = true
        squintUntil = time + 0.5
        if let touch = touches.first { look(at: touch.location(in: self)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        letGo()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        letGo()
    }
    private func letGo() {
        guard pressed else { return }
        pressed = false
        creatureSquash.velocity -= 1.2
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        last = nil
        guard window != nil else { return }
        metal.contentsScale = min(2, window?.screen.scale ?? 2)
        frostMask.metal.contentsScale = 1
        let proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var dt = CGFloat(min(1.0 / 20.0, max(0.001, now - (last ?? (now - link.duration)))))
        #if DEBUG
        dt /= CGFloat(SpringDriver.debugSlowMotion)
        #endif
        last = now
        time += dt
        toneTime += dt
        sense(dt)
        stepBlob(dt)
        stepCreature(dt)
        stepFace(dt)
        draw()
    }

    // MARK: Blob

    private func sense(_ dt: CGFloat) {
        let position = layer.position, size = bounds.size
        defer { lastPosition = position; lastSize = size }
        guard let lastPosition, let lastSize else { return }
        let v = CGPoint(x: (position.x - lastPosition.x) / dt, y: (position.y - lastPosition.y) / dt)
        let sv = CGSize(width: (size.width - lastSize.width) / dt, height: (size.height - lastSize.height) / dt)
        let a = CGPoint(x: (v.x - velocity.x) / dt, y: (v.y - velocity.y) / dt)
        let sa = CGSize(width: (sv.width - sizeVelocity.width) / dt, height: (sv.height - sizeVelocity.height) / dt)
        // Smoothed hard: the body answers the move, not each frame's noise.
        let k: CGFloat = 0.25
        accel = CGPoint(x: .lerp(accel.x, a.x, k), y: .lerp(accel.y, a.y, k))
        sizeAccel = CGSize(width: .lerp(sizeAccel.width, sa.width, k), height: .lerp(sizeAccel.height, sa.height, k))
        velocity = v
        sizeVelocity = sv
    }

    private func stepBlob(_ dt: CGFloat) {
        let small = min(bodyRect.width, bodyRect.height) / 2
        // Weighty: low, well damped, and calmer still as a panel.
        let frequency = CGFloat.lerp(2.2, 1.6, opened), damping = CGFloat.lerp(0.42, 0.6, opened)
        let reduced = Motion.reduced
        let a = accel, magnitude = max(1, hypot(a.x, a.y))
        var squashForce = -0.16 * (a.x * a.x - a.y * a.y) / magnitude
        squashForce += 0.1 * (sizeAccel.width - sizeAccel.height) * (1 - 0.6 * opened)
        let shearForce = 0.12 * a.x
        let steps = 4, h = dt / CGFloat(steps)
        for _ in 0..<steps {
            squash.step(h, frequency: frequency, damping: damping, force: reduced ? 0 : squashForce)
            shear.step(h, frequency: frequency * 0.85, damping: damping, force: reduced ? 0 : shearForce)
            lagX.step(h, frequency: frequency, damping: damping * 1.3, force: reduced ? 0 : -0.15 * a.x)
            lagY.step(h, frequency: frequency, damping: damping * 1.3, force: reduced ? 0 : -0.15 * a.y)
        }
        let reach = min(small * 0.15, CGFloat.lerp(6, 4, opened))
        squash.limit(reach)
        shear.limit(reach)
        lagX.limit(6)
        lagY.limit(8)
        if reduced { squash.value = 0; shear.value = 0; lagX.value = 0; lagY.value = 0 }
    }

    // MARK: Creature

    private func stepCreature(_ dt: CGFloat) {
        // Where it belongs, in the superview's coordinates.
        let target = CGPoint(x: layer.position.x - bounds.midX + creatureAnchor.x,
                             y: layer.position.y - bounds.midY + creatureAnchor.y)
        if !placedCreature || Motion.reduced {
            placedCreature = true
            creatureWorld = target
            creatureVelocity = .zero
        } else {
            // A step behind, so the neck stretches as the blob moves; never
            // so far it is left behind.
            let parameters = SpringDriver.Parameters(response: 0.26, damping: 0.78)
            (creatureWorld.x, creatureVelocity.x) = SpringDriver.step(value: creatureWorld.x, velocity: creatureVelocity.x,
                                                                     target: target.x, dt: dt, parameters: parameters)
            (creatureWorld.y, creatureVelocity.y) = SpringDriver.step(value: creatureWorld.y, velocity: creatureVelocity.y,
                                                                     target: target.y, dt: dt, parameters: parameters)
            let d = CGPoint(x: creatureWorld.x - target.x, y: creatureWorld.y - target.y), n = hypot(d.x, d.y)
            if n > 26 { creatureWorld = CGPoint(x: target.x + d.x * 26 / n, y: target.y + d.y * 26 / n) }
        }
        creatureSquash.target = pressed ? 0.16 : 0
        if !Motion.reduced, tone == .needsYou, time > nextHop {
            // Now and then, a small hop for your attention.
            nextHop = time + 3.2
            hop.velocity -= 75
        }
        let steps = 4, h = dt / CGFloat(steps)
        for _ in 0..<steps {
            creatureSquash.step(h, frequency: 2.6, damping: 0.4, force: 0)
            // Gravity pulls a hop back down; the floor is its rest place.
            hop.step(h, frequency: 2.2, damping: 0.5, force: 0)
        }
        creatureSquash.limit(0.22)
        hop.limit(14)
        // It leans into its motion and turns a little toward what it looks at.
        let v = creatureVelocity
        yaw.target = -0.34 * creatureSide + (v.x / 2600).clamped(-0.25, 0.25) + gazeX.target * 0.05
        pitch.target = -0.42 + (v.y / 2600).clamped(-0.2, 0.2) - gazeY.target * 0.04
        roll.target = (v.x / 4000).clamped(-0.12, 0.12)
        yaw.step(dt); pitch.step(dt); roll.step(dt)
    }

    // MARK: Face

    private func stepFace(_ dt: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let color: UIColor = tone == .needsYou ? Theme.warning : tone == .done ? Theme.success : Theme.accent
        color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        let strength: CGFloat = tone == .idle ? 0.5 : 0.85
        (tint.r.target, tint.g.target, tint.b.target, tint.a.target) = (r, g, b, strength)
        if !tintSet {
            tintSet = true
            (tint.r.value, tint.g.value, tint.b.value, tint.a.value) = (r, g, b, strength)
        }
        tint.r.step(dt); tint.g.step(dt); tint.b.step(dt); tint.a.step(dt)

        // Glances: a target is held for a while, and reached on an eased,
        // critically damped move; never a per-frame wobble.
        if time >= gazeHold {
            var target = CGPoint.zero, hold: CGFloat = 1
            let center = creatureAnchor
            if let finger, time - finger.at < 1.6 {
                let d = CGPoint(x: finger.point.x - center.x, y: finger.point.y - center.y), n = max(1, hypot(d.x, d.y))
                target = CGPoint(x: 2.4 * d.x / n, y: 1.6 * d.y / n)
                hold = 0.35
            } else if typing, opened > 0.5 {
                target = CGPoint(x: 0, y: 1.8)
                hold = 0.6
            } else if tone == .working, opened < 0.5 {
                // Reading along the line, a word or two at a time.
                readStep = (readStep + 1) % 4
                target = CGPoint(x: -creatureSide * (0.6 + 0.6 * CGFloat(readStep)), y: 0.5)
                hold = .random(in: 0.5...0.85)
            } else if tone == .needsYou {
                target = CGPoint(x: 0, y: -0.3)
                hold = 1
            } else {
                target = [CGPoint(x: -1.8, y: 0.4), CGPoint(x: 1.8, y: -0.3), .zero, .zero, CGPoint(x: 0.6, y: 1.1)].randomElement()!
                hold = .random(in: 2.4...5)
            }
            (gazeX.target, gazeY.target) = (target.x, target.y)
            gazeHold = time + hold
        }
        gazeX.step(dt); gazeY.step(dt)

        // Blinks: shut quickly, open a little slower, every few seconds.
        if blinkStart < 0, time > nextBlink, happy.value < 0.3, squint.value < 0.3 {
            blinkStart = time
        }
        if blinkStart >= 0 {
            let p = (time - blinkStart) / 0.24
            lid = p < 0.35 ? 1 - p / 0.35 : min(1, (p - 0.35) / 0.65)
            lid = lid * lid * (3 - 2 * lid)
            if p >= 1 {
                blinkStart = -1
                lid = 1
                if !doubleBlink, Int.random(in: 0..<5) == 0 {
                    doubleBlink = true
                    nextBlink = time + 0.18
                } else {
                    doubleBlink = false
                    nextBlink = time + .random(in: 3...6)
                }
            }
        }
        happy.target = tone == .done && toneTime < 4 ? 1 : 0
        squint.target = time < squintUntil ? 1 : 0
        worry.target = tone == .needsYou ? 1 : 0
        happy.step(dt); squint.step(dt); worry.step(dt)
    }

    // MARK: Shape

    private var deformation: CGAffineTransform {
        let hx = max(1, bodyRect.width / 2), hy = max(1, bodyRect.height / 2)
        let breath = Motion.reduced ? 0 : 0.008 * (1 - opened) * sin(time * 2 * .pi / 4.2)
        return CGAffineTransform(a: (1 + squash.value / hx) * (1 + breath), b: 0,
                                 c: -shear.value / hy, d: (1 - squash.value / hy) * (1 + breath), tx: 0, ty: 0)
    }

    private var pillow: CGFloat { min(4, 0.4 * abs(squash.value) + 0.25 * abs(shear.value)) }

    /// The rest rounded box with pillowed edges, about the origin.
    private func restPath(half: CGSize, radius: CGFloat, pillow: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let count = 144
        let far = hypot(half.width, half.height) + pillow + 4
        for i in 0..<count {
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            let dx = cos(angle), dy = sin(angle)
            var lo: CGFloat = 0, hi = far
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                if Self.distance(CGPoint(x: dx * mid, y: dy * mid), half: half, radius: radius, pillow: pillow) < 0 { lo = mid } else { hi = mid }
            }
            let p = CGPoint(x: dx * lo, y: dy * lo)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    nonisolated static func distance(_ q: CGPoint, half: CGSize, radius: CGFloat, pillow: CGFloat) -> CGFloat {
        let qx = abs(q.x) - half.width + radius, qy = abs(q.y) - half.height + radius
        let box = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
        let nx = abs(q.x) / max(1, half.width), ny = abs(q.y) / max(1, half.height)
        let along = nx > ny ? q.y / max(1, half.height) : q.x / max(1, half.width)
        return box - pillow * max(0, 1 - along * along)
    }

    // MARK: Drawing

    private func draw() {
        guard bounds.width > 1, bounds.height > 1, bodyRect.width > 1 else { return }
        let s = Self.creatureSize
        let half = CGSize(width: bodyRect.width / 2, height: bodyRect.height / 2)
        let radius = min(cornerRadius, half.width, half.height)
        let pillow = self.pillow
        let m = deformation
        let center = CGPoint(x: bodyRect.midX + lagX.value, y: bodyRect.midY + lagY.value)
        let creature = CGPoint(x: creatureWorld.x - layer.position.x + bounds.midX,
                               y: creatureWorld.y - layer.position.y + bounds.midY + hop.value)
        let canvas = bounds.insetBy(dx: -Self.margin, dy: -Self.margin)
        let inverse = m.inverted()
        var u = JellyUniforms(
            tint: SIMD4(Float(tint.r.value), Float(tint.g.value), Float(tint.b.value), Float(tint.a.value)),
            fill: fillVector,
            face: SIMD4(Float(lid), Float(happy.value), Float(squint.value), Float(worry.value)),
            inverse: SIMD4(Float(inverse.a), Float(inverse.b), Float(inverse.c), Float(inverse.d)),
            creature: SIMD4(Float(creature.x), Float(creature.y), Float(s), 12),
            pose: SIMD4(Float(yaw.value), Float(pitch.value), Float(roll.value), Float(creatureSquash.value)),
            gaze: SIMD4(Float(gazeX.value), Float(gazeY.value), 0, 0),
            center: SIMD2(Float(center.x), Float(center.y)),
            half: SIMD2(Float(half.width), Float(half.height)),
            origin: SIMD2(Float(canvas.minX), Float(canvas.minY)),
            scale: Float(metal.contentsScale), radius: Float(radius), pillow: Float(pillow),
            time: 0, churn: 0, opened: Float(opened),
            dark: traitCollection.userInterfaceStyle == .dark ? 1 : 0, mode: 0)
        // Settled and unchanged (no blink, glance or move): nothing to draw.
        if let drawn, drawnCanvas == canvas, drawn.isClose(to: u) { return }
        drawn = u
        drawnCanvas = canvas

        let rest = restPath(half: half, radius: radius, pillow: pillow)
        var toBounds = m.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        let onScreen = rest.copy(using: &toBounds) ?? rest
        let outline = CGMutablePath()
        outline.addPath(onScreen)
        outline.addPath(UIBezierPath(roundedRect: CGRect(x: creature.x - s * 0.4, y: creature.y - s * 0.4, width: s * 0.8, height: s * 0.8),
                                     cornerRadius: s * 0.28).cgPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.frame = canvas
        frostMask.frame = frost.bounds
        if frostMask.metal.drawableSize != canvas.size { frostMask.metal.drawableSize = canvas.size }
        // One soft shadow in its colour.
        shadow.frame = bounds
        shadow.shadowPath = outline
        shadow.shadowColor = UIColor(red: tint.r.value, green: tint.g.value, blue: tint.b.value, alpha: 1).cgColor
        shadow.shadowOpacity = Float(.lerp(0.12 + 0.14 * tint.a.value, 0.16, opened))
        shadow.shadowRadius = .lerp(8, 18, opened)
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.center = CGPoint(x: bounds.midX + center.x - bodyRect.midX, y: bounds.midY + center.y - bodyRect.midY)
        let pivot = CGPoint(x: bodyRect.midX - bounds.midX, y: bodyRect.midY - bounds.midY)
        content.transform = CGAffineTransform(translationX: -pivot.x, y: -pivot.y).concatenating(m)
            .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
        var toContent = CGAffineTransform(translationX: bodyRect.midX, y: bodyRect.midY)
        contentMask.frame = content.bounds
        contentMask.path = rest.copy(using: &toContent)
        if metal.frame != canvas {
            metal.frame = canvas
            metal.drawableSize = CGSize(width: canvas.width * metal.contentsScale, height: canvas.height * metal.contentsScale)
        }
        CATransaction.commit()
        render(&u, into: metal)
        var coverage = u
        coverage.mode = 2
        coverage.scale = 1
        render(&coverage, into: frostMask.metal)
    }

    private var fillVector: SIMD4<Float> {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        fill.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(fillAmount * a))
    }

    private func render(_ u: inout JellyUniforms, into target: CAMetalLayer) {
        guard let pipeline = JellyRenderer.pipeline, let queue = JellyRenderer.queue,
              let drawable = target.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<JellyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// A damped oscillator driven by a force.
private struct Mode {
    var value: CGFloat = 0
    var velocity: CGFloat = 0
    var target: CGFloat = 0

    mutating func step(_ dt: CGFloat, frequency: CGFloat, damping: CGFloat, force: CGFloat) {
        let w = 2 * .pi * frequency
        let a = -w * w * (value - target) - 2 * damping * w * velocity + force
        velocity += a * dt
        value += velocity * dt
    }

    mutating func limit(_ reach: CGFloat) {
        if abs(value) > reach {
            value = reach * (value < 0 ? -1 : 1)
            if value * velocity > 0 { velocity *= -0.3 }
        }
    }
}

/// A view whose layer Metal draws into, for masks.
final class MetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metal: CAMetalLayer { layer as! CAMetalLayer }
}

/// A view whose layer is a shape, for masks.
final class ShapeView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shape: CAShapeLayer { layer as! CAShapeLayer }
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

    mutating func step(_ dt: CGFloat) {
        (value, velocity) = SpringDriver.step(value: value, velocity: velocity, target: target, dt: dt, parameters: parameters)
    }
}

/// Matches `Uniforms` in the shader.
struct JellyUniforms {
    var tint: SIMD4<Float>
    var fill: SIMD4<Float>
    var face: SIMD4<Float>      // lid, happy, squint, worry
    var inverse: SIMD4<Float>   // the blob's deformation, inverted (a b c d)
    var creature: SIMD4<Float>  // centre xy, size, neck reach
    var pose: SIMD4<Float>      // yaw, pitch, roll, squash
    var gaze: SIMD4<Float>
    var center: SIMD2<Float>
    var half: SIMD2<Float>
    var origin: SIMD2<Float>
    var scale: Float
    var radius: Float
    var pillow: Float
    var time: Float
    var churn: Float
    var opened: Float
    var dark: Float
    /// 0: the jelly; 2: its coverage only (the blur's mask).
    var mode: Float

    /// For the blob layer: whether anything it draws has moved.
    func isClose(to o: JellyUniforms) -> Bool {
        func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ e: Float) -> Bool { (0..<4).allSatisfy { Swift.abs(a[$0] - b[$0]) < e } }
        func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { (0..<2).allSatisfy { Swift.abs(a[$0] - b[$0]) < 0.02 } }
        return near(tint, o.tint, 0.002) && near(fill, o.fill, 0.002) && near(inverse, o.inverse, 0.0005)
            && near(face, o.face, 0.003) && near(pose, o.pose, 0.0008) && near(gaze, o.gaze, 0.01)
            && near(creature, o.creature, 0.05) && near(center, o.center) && near(half, o.half) && near(origin, o.origin)
            && Swift.abs(pillow - o.pillow) < 0.02 && radius == o.radius && dark == o.dark && Swift.abs(opened - o.opened) < 0.002
    }
}

@MainActor
enum JellyRenderer {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    /// Compiled from source once, so the overlay framework needs no
    /// separate Metal library.
    static let pipeline: MTLRenderPipelineState? = {
        guard let device else { return nil }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: source, options: nil) } catch {
            #if DEBUG
            print("GlassJelly shader:", error)
            #endif
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "jellyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "jellyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 tint;      // rgb, strength
        float4 fill;      // rgb, amount
        float4 face;      // lid, happy, squint, worry
        float4 inverse;   // a b c d
        float4 creature;  // centre xy, size, neck reach
        float4 pose;      // yaw, pitch, roll, squash
        float4 gaze;
        float2 center;
        float2 half_;
        float2 origin;
        float scale, radius, pillow, time, churn, opened, dark, mode;
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut jellyVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static float2 rest(float2 p, constant Uniforms& u) {
        float2 d = p - u.center;
        return float2(u.inverse.x * d.x + u.inverse.z * d.y, u.inverse.y * d.x + u.inverse.w * d.y);
    }

    static float roundBox(float2 q, float2 h, float r) {
        float2 b = abs(q) - h + r;
        return length(max(b, 0.0)) + min(max(b.x, b.y), 0.0) - r;
    }

    static float blob(float2 q, constant Uniforms& u) {
        float2 h = u.half_;
        float nx = abs(q.x) / max(1.0, h.x), ny = abs(q.y) / max(1.0, h.y);
        float along = nx > ny ? q.y / max(1.0, h.y) : q.x / max(1.0, h.x);
        return roundBox(q, h, u.radius) - u.pillow * max(0.0, 1.0 - along * along);
    }

    // The creature's footprint, flat, a little inside its 3D silhouette.
    static float foot(float2 p, constant Uniforms& u) {
        float s = u.creature.z;
        return roundBox(p - u.creature.xy, float2(s * 0.34), s * 0.26);
    }

    static float smin(float a, float b, float k) {
        float h = max(k - abs(a - b), 0.0) / k;
        return min(a, b) - h * h * k * 0.25;
    }

    static float field(float2 p, constant Uniforms& u) {
        return smin(blob(rest(p, u), u), foot(p, u), u.creature.w);
    }

    static float height(float2 p, float bevel, constant Uniforms& u) {
        float t = clamp(-field(p, u) / bevel, 0.0, 1.0);
        return sqrt(1.0 - (1.0 - t) * (1.0 - t));
    }

    static float segment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    // Two eyes at `c` in a face plane (points). Returns coverage in .a, ink in .rgb.
    static float4 eyes(float2 q, float px, float3 tint, constant Uniforms& u) {
        float lid = u.face.x, happy = u.face.y, squint = u.face.z, worry = u.face.w;
        float3 ink = u.dark > 0.5 ? float3(0.97, 0.95, 0.92) : mix(float3(0.07, 0.05, 0.05), tint * 0.3, 0.2);
        float3 col = float3(0.0);
        float a = 0.0;
        for (int i = 0; i < 2; i++) {
            float sgn = i == 0 ? -1.0 : 1.0;
            float2 c = u.gaze.xy + float2(sgn * 5.2, -1.2);
            float2 v = q - c;
            float ang = sgn * worry * 0.38;
            v = float2(cos(ang) * v.x - sin(ang) * v.y, sin(ang) * v.x + cos(ang) * v.y);
            float grow = 1.0 + 0.12 * worry;
            float2 rr = float2(2.5, max(0.3, 3.6 * lid)) * grow;
            float bead = (length(v / rr) - 1.0) * min(rr.x, rr.y);
            float R = 2.7;
            float2 w = v - float2(0.0, R * 0.55);
            float arc = w.y < R * 0.1 ? abs(length(w) - R) - 0.9 : 9.0;
            float2 tip = float2(-sgn * 1.7, 0.0);
            float chevron = min(segment(v, float2(sgn * 1.5, -2.0), tip), segment(v, tip, float2(sgn * 1.5, 2.0))) - 0.85;
            float kb = smoothstep(px, -px, bead) * (1.0 - happy) * (1.0 - squint);
            float ka = smoothstep(px, -px, arc) * happy * (1.0 - squint);
            float ks = smoothstep(px, -px, chevron) * squint;
            float k = clamp(kb + ka + ks, 0.0, 1.0) * 0.95;
            col = col * (1.0 - k) + ink * k;
            a = a * (1.0 - k) + k;
            float glint = exp(-length_squared((v - float2(-0.9, -1.4) * grow) / 0.75)) * kb;
            col += float3(glint * 0.9);
            a += glint * 0.4;
        }
        return float4(col, clamp(a, 0.0, 1.0));
    }

    // One material for all of it: translucent tinted jelly, a little deeper
    // toward its edges, one soft rim of light, one soft highlight.
    static float4 jelly(float3 n, float3 V, float shape, constant Uniforms& u) {
        float3 tint = u.tint.rgb;
        float s = u.tint.a;
        float3 L = normalize(float3(-0.45, -0.8, -0.9));
        float fres = pow(1.0 - clamp(dot(n, V), 0.0, 1.0), 2.0);
        float a = s * (0.24 + 0.42 * fres);
        float3 col = tint * a * shape;
        float rim = fres * 0.22 * (0.5 + 0.5 * dot(normalize(n.xy + 1e-5), normalize(L.xy)));
        col += mix(tint, float3(1.0), 0.6) * rim;
        a += rim * 0.6;
        float spec = pow(max(dot(reflect(-L, n), V), 0.0), 36.0) * 0.32;
        col += float3(spec);
        a += spec * 0.5;
        return float4(col, a);
    }

    // MARK: the cube, seen in perspective.

    static float3x3 turn(float yaw, float pitch, float roll) {
        float cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch), cr = cos(roll), sr = sin(roll);
        float3x3 ry = float3x3(float3(cy, 0.0, -sy), float3(0.0, 1.0, 0.0), float3(sy, 0.0, cy));
        float3x3 rx = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, cp, sp), float3(0.0, -sp, cp));
        float3x3 rz = float3x3(float3(cr, sr, 0.0), float3(-sr, cr, 0.0), float3(0.0, 0.0, 1.0));
        return ry * rx * rz;
    }

    static float cube(float3 p, float3x3 inv, constant Uniforms& u) {
        float s = u.creature.z, squash = u.pose.w;
        float3 l = inv * p;
        l.y -= s * 0.5 * squash;
        float3 b = float3(s * 0.5 * (1.0 + 0.6 * squash), s * 0.5 * (1.0 - squash), s * 0.4);
        float r = s * 0.28;
        float3 q = abs(l) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
    }

    struct Cube { float4 color; float cover; };

    static Cube creature(float2 p, float px, bool shade, constant Uniforms& u) {
        Cube out = { float4(0.0), 0.0 };
        float s = u.creature.z;
        float D = 150.0;
        float3 ro = float3(0.0, 0.0, -D);
        float3 rd = normalize(float3(p - u.creature.xy, D));
        float3x3 R = turn(u.pose.x, u.pose.y, u.pose.z);
        float3x3 inv = transpose(R);
        float t = D - s * 1.2, dmin = 1e4;
        bool hit = false;
        for (int i = 0; i < 48; i++) {
            float d = cube(ro + rd * t, inv, u);
            dmin = min(dmin, d);
            if (d < 0.01) { hit = true; break; }
            t += d;
            if (t > D + s * 1.4) break;
        }
        out.cover = hit ? 1.0 : clamp(1.0 - dmin / px, 0.0, 1.0);
        if (out.cover <= 0.0 || !shade) return out;
        float3 pos = ro + rd * t;
        float e = 0.2;
        float3 n = normalize(float3(1, -1, -1) * cube(pos + float3(1, -1, -1) * e, inv, u)
                           + float3(-1, -1, 1) * cube(pos + float3(-1, -1, 1) * e, inv, u)
                           + float3(-1, 1, -1) * cube(pos + float3(-1, 1, -1) * e, inv, u)
                           + float3(1, 1, 1) * cube(pos + float3(1, 1, 1) * e, inv, u));
        // Faces turned up a touch lighter, so it reads as a cube.
        float shape = 1.0 + 0.25 * (-n.y) - 0.1 * abs(n.x);
        float4 c = jelly(n, -rd, shape, u);
        float3 col = c.rgb;
        float a = c.a;
        float3 l = inv * pos;
        float front = smoothstep(-u.creature.z * 0.2, -u.creature.z * 0.36, l.z);
        float4 face = eyes(l.xy, px * 0.9, u.tint.rgb, u);
        float k = face.a * front;
        col = col * (1.0 - k) + face.rgb * k;
        a = a * (1.0 - k) + k;
        a = clamp(a, 0.0, 1.0);
        out.color = float4(min(col, float3(a)), a);
        return out;
    }

    fragment float4 jellyFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = in.position.xy / u.scale + u.origin;
        float px = 1.0 / u.scale;
        float2 q = rest(p, u);
        float db = blob(q, u);
        float d = smin(db, foot(p, u), u.creature.w);
        float cover = clamp(0.5 - d / px, 0.0, 1.0);
        Cube c = { float4(0.0), 0.0 };
        bool near = length(p - u.creature.xy) < u.creature.z * 1.05;
        if (near) c = creature(p, px, u.mode < 1.0, u);
        if (u.mode > 1.5) { return float4(0.0, 0.0, 0.0, max(cover, c.cover)); }
        if (cover <= 0.0 && c.cover <= 0.0) { return float4(0.0); }

        float4 body = float4(0.0);
        if (cover > 0.0) {
            float small = min(u.half_.x, u.half_.y);
            float bevel = clamp(small * 0.8, 5.0, 16.0);
            float lift = bevel * 0.7;
            float e = 0.6;
            float hx = (height(p + float2(e, 0.0), bevel, u) - height(p - float2(e, 0.0), bevel, u)) / (2.0 * e) * lift;
            float hy = (height(p + float2(0.0, e), bevel, u) - height(p - float2(0.0, e), bevel, u)) / (2.0 * e) * lift;
            float3 n = normalize(float3(-hx, -hy, -1.0));
            float4 j = jelly(n, float3(0.0, 0.0, -1.0), 1.0, u);
            float3 col = j.rgb;
            float a = j.a;
            // Paper inside the panel as it opens, so text reads.
            float depth = clamp(-d / bevel, 0.0, 1.0);
            float bodyness = clamp(1.0 - db / 6.0, 0.0, 1.0);
            float f = u.fill.a * smoothstep(0.15, 0.9, depth) * bodyness;
            col = col * (1.0 - f) + u.fill.rgb * f;
            a = clamp(a * (1.0 - f) + f, 0.0, 1.0);
            body = float4(min(col, float3(a)), a) * cover;
        }
        // The cube is the same jelly, in front where it is.
        return mix(body, c.color, c.cover);
    }
    """
}
#endif
