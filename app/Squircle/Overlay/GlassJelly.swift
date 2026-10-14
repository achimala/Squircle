#if SQUIRCLE_OVERLAY || DEBUG
import Metal
import UIKit

/// The overlay's one piece of jelly: the bubble, and grown, the panel that
/// holds the conversation (user, 2026-10-14: "frosted glass 3d jelly … let
/// the jelly become the platter … more jiggle physics … make it feel more
/// alive again" with eyes).
///
/// Material: the app behind, frosted by the system's live blur masked to the
/// outline; a handwritten Metal shader lighting it as a soft cushion (tint
/// deepening at the rim, a rim lit toward the light, a gloss streak, a glint,
/// light gathered inside) and filling it with paper as it opens so text
/// reads; a soft shadow in its colour; two eyes inside it.
///
/// Motion is a small soft body, not noise. Its owner only sets the frame (a
/// spring); the jelly feels that frame's acceleration and resizing and its
/// body lags, squashes, stretches and shears on damped springs, then rings
/// down. The outline is always the rest squircle under an affine squash and
/// shear with its edges pillowed outward, so it can bulge and wobble but
/// never dent. Taps, finished tasks and state changes kick the same springs.
@MainActor
final class GlassJelly: UIView {
    var tone = LiveCapsule.Tone.idle {
        didSet {
            guard tone != oldValue else { return }
            toneTime = 0
            switch tone {
            case .done: kick(squash: 140, shear: 50)
            case .needsYou: kick(squash: -70, hop: -90)
            case .working: kick(squash: 40)
            case .idle: break
            }
        }
    }
    /// The conversation and the bubble's line: masked to the outline and
    /// carried by the body as it wobbles.
    let content = UIView()
    /// The rest shape's corner radius.
    var cornerRadius: CGFloat = 22
    /// 0 bubble … 1 panel: fills with `fill`, calms down, eyes move to `panelEye`.
    var opened: CGFloat = 0
    var fill = UIColor.white
    var fillAmount: CGFloat = 0
    /// Where the eyes sit (bounds coordinates) as a bubble and as a panel.
    var bubbleEye = CGPoint(x: 22, y: 22)
    var panelEye = CGPoint(x: 22, y: 22)
    /// The keyboard is up: it watches the field.
    var typing = false

    private let shadow = CAShapeLayer()
    private let frost = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let frostMask = ShapeView()
    private let contentMask = CAShapeLayer()
    private let metal = CAMetalLayer()
    /// The eyes, drawn by the same shader above the content, so text
    /// scrolling under the panel's top never runs through its face.
    private let face = CAMetalLayer()
    private static let margin: CGFloat = 36

    // Body: squash (points the sides move out, the top and bottom in),
    // shear (points the top moves left), lag (points behind the frame).
    private var squash = Mode(), shear = Mode(), lagX = Mode(), lagY = Mode()
    private var pressed = false
    private var lastPosition: CGPoint?
    private var lastSize: CGSize?
    private var velocity = CGPoint.zero, sizeVelocity = CGSize.zero
    private var accel = CGPoint.zero, sizeAccel = CGSize.zero

    // Face.
    private var lookX = Wobble(0, response: 0.22, damping: 0.75)
    private var lookY = Wobble(0, response: 0.22, damping: 0.75)
    private var lid = Wobble(1, response: 0.06, damping: 1)
    private var happy = Wobble(0, response: 0.25, damping: 0.8)
    private var squint = Wobble(0, response: 0.1, damping: 0.9)
    private var worry = Wobble(0, response: 0.3, damping: 0.9)
    private var tint = (r: Wobble(0, response: 0.35, damping: 1), g: Wobble(0, response: 0.35, damping: 1),
                        b: Wobble(0, response: 0.35, damping: 1), a: Wobble(0, response: 0.35, damping: 1))
    private var tintSet = false
    private var finger: (point: CGPoint, at: CGFloat)?
    private var squintUntil: CGFloat = 0
    private var nextBlink: CGFloat = 1.5, blinkEnd: CGFloat = 0, secondBlink = false
    private var nextGlance: CGFloat = 3, glance = CGPoint.zero
    private var nextFidget: CGFloat = 1.5
    private var nextHop: CGFloat = 0

    private var time: CGFloat = 0, toneTime: CGFloat = 0, glowTime: CGFloat = 0
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var drawn: JellyUniforms?
    private var drawnCanvas = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.fillColor = UIColor.clear.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: 6)
        layer.addSublayer(shadow)
        frostMask.shape.fillColor = UIColor.black.cgColor
        frost.mask = frostMask
        frost.isUserInteractionEnabled = false
        addSubview(frost)
        metal.device = JellyRenderer.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        layer.addSublayer(metal)
        contentMask.fillColor = UIColor.black.cgColor
        content.layer.mask = contentMask
        addSubview(content)
        face.device = JellyRenderer.device
        face.pixelFormat = .bgra8Unorm
        face.isOpaque = false
        face.framebufferOnly = true
        layer.addSublayer(face)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Events

    /// A finished task: it swallows it (stretches up, then rings).
    func gulp() { kick(squash: -55) }

    /// Somewhere a finger touched (bounds coordinates): it glances there.
    func look(at point: CGPoint) { finger = (point, time) }

    private func kick(squash s: CGFloat = 0, shear h: CGFloat = 0, hop: CGFloat = 0) {
        guard !Motion.reduced else { return }
        // A panel is heavier: the same news moves it less.
        let calm = 1 - 0.75 * opened
        squash.velocity += s * calm
        shear.velocity += h * calm
        lagY.velocity += hop * calm
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        pressed = true
        squintUntil = time + 0.45
        kick(squash: 60)
        if let touch = touches.first { look(at: touch.location(in: self)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
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
        kick(squash: -90)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        last = nil
        guard window != nil else { return }
        metal.contentsScale = min(2, window?.screen.scale ?? 2)
        face.contentsScale = window?.screen.scale ?? 3
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
        stepBody(dt)
        stepFace(dt)
        draw()
    }

    // MARK: Body

    /// The frame's motion as its owner moves it, smoothed.
    private func sense(_ dt: CGFloat) {
        let position = layer.position, size = bounds.size
        defer { lastPosition = position; lastSize = size }
        guard let lastPosition, let lastSize else { return }
        let v = CGPoint(x: (position.x - lastPosition.x) / dt, y: (position.y - lastPosition.y) / dt)
        let sv = CGSize(width: (size.width - lastSize.width) / dt, height: (size.height - lastSize.height) / dt)
        let k: CGFloat = 0.5
        let a = CGPoint(x: (v.x - velocity.x) / dt, y: (v.y - velocity.y) / dt)
        let sa = CGSize(width: (sv.width - sizeVelocity.width) / dt, height: (sv.height - sizeVelocity.height) / dt)
        accel = CGPoint(x: .lerp(accel.x, a.x, k), y: .lerp(accel.y, a.y, k))
        sizeAccel = CGSize(width: .lerp(sizeAccel.width, sa.width, k), height: .lerp(sizeAccel.height, sa.height, k))
        velocity = v
        sizeVelocity = sv
    }

    private func stepBody(_ dt: CGFloat) {
        let half = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        let small = min(half.width, half.height)
        // Jelly rings at about 3 Hz and dies in a second; the panel is
        // slower and calmer.
        let frequency = CGFloat.lerp(3.1, 2.0, opened), damping = CGFloat.lerp(0.14, 0.3, opened)
        let reduced = Motion.reduced
        // Inertia: the body lags what moves it, is pressed flat along a
        // push and stretched along a stop; growing, it overshoots.
        let a = accel, magnitude = max(1, hypot(a.x, a.y))
        var squashForce = -0.35 * (a.x * a.x - a.y * a.y) / magnitude
        squashForce += 0.25 * (sizeAccel.width - sizeAccel.height) * (1 - 0.5 * opened)
        let shearForce = 0.28 * a.x
        // While held down it sits squashed.
        squash.target = pressed ? small * 0.22 : 0
        if !reduced {
            switch tone {
            case .needsYou where opened < 0.5 && time > nextHop:
                // Every few seconds, a small hop for your attention.
                nextHop = time + 2.6
                kick(squash: -50, hop: -110)
            case .working where opened < 0.5 && time > nextFidget:
                // Alive while it works: a small, irregular wobble now and then.
                nextFidget = time + .random(in: 0.9...1.8)
                kick(squash: .random(in: -22...22), shear: .random(in: -16...16))
            default: break
            }
        }
        let steps = 4, h = dt / CGFloat(steps)
        for _ in 0..<steps {
            squash.step(h, frequency: frequency, damping: damping, force: reduced ? 0 : squashForce)
            shear.step(h, frequency: frequency * 0.85, damping: damping, force: reduced ? 0 : shearForce)
            lagX.step(h, frequency: frequency, damping: damping * 1.4, force: reduced ? 0 : -0.3 * a.x)
            lagY.step(h, frequency: frequency, damping: damping * 1.4, force: reduced ? 0 : -0.3 * a.y)
        }
        // Never more than a fraction of itself, and a panel only a little.
        let reach = min(small * 0.3, CGFloat.lerp(14, 9, opened))
        squash.limit(reach)
        shear.limit(reach)
        lagX.limit(10)
        lagY.limit(14)
        if reduced { squash.value = 0; shear.value = 0; lagX.value = 0; lagY.value = 0 }
    }

    // MARK: Face

    private func stepFace(_ dt: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let color: UIColor = tone == .needsYou ? Theme.warning : tone == .done ? Theme.success : Theme.accent
        color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        let strength: CGFloat = tone == .idle ? 0.45 : 0.85
        (tint.r.target, tint.g.target, tint.b.target, tint.a.target) = (r, g, b, strength)
        if !tintSet {
            tintSet = true
            (tint.r.value, tint.g.value, tint.b.value, tint.a.value) = (r, g, b, strength)
        }

        // Where it looks: your finger, the field while you type, the text
        // while it works, you when it needs you, else around.
        var target = CGPoint.zero
        let eye = eyeCenter
        if let finger, time - finger.at < 1.4 {
            let d = CGPoint(x: finger.point.x - eye.x, y: finger.point.y - eye.y)
            let n = max(1, hypot(d.x, d.y))
            target = CGPoint(x: 2.4 * d.x / n, y: 1.8 * d.y / n)
        } else if typing, opened > 0.5 {
            target = CGPoint(x: 0, y: 1.8)
        } else if tone == .working, opened < 0.5 {
            target = CGPoint(x: 1.2 + 1.1 * CGFloat(Int(time * 2.4) % 3) / 2, y: 0.4)
        } else if tone == .needsYou {
            target = CGPoint(x: 0, y: -0.4)
        } else {
            if time > nextGlance {
                glance = [CGPoint(x: -2, y: 0.4), CGPoint(x: 2, y: -0.4), .zero, .zero, CGPoint(x: 0.8, y: 1.2)].randomElement()!
                nextGlance = time + .random(in: 2.2...5)
            }
            target = glance
        }
        (lookX.target, lookY.target) = (target.x, target.y)

        if time > nextBlink, happy.value < 0.3, squint.value < 0.3 {
            blinkEnd = time + 0.11
            if !secondBlink, Int.random(in: 0..<4) == 0 {
                secondBlink = true
                nextBlink = time + 0.24
            } else {
                secondBlink = false
                nextBlink = time + .random(in: 2...5)
            }
        }
        lid.target = time < blinkEnd ? 0.06 : tone == .working && opened < 0.5 ? 0.78 : 1
        happy.target = tone == .done && toneTime < 4 ? 1 : 0
        squint.target = time < squintUntil ? 1 : 0
        worry.target = tone == .needsYou ? 1 : 0
        for spring in [\GlassJelly.lookX, \.lookY, \.lid, \.happy, \.squint, \.worry] as [ReferenceWritableKeyPath<GlassJelly, Wobble>] {
            self[keyPath: spring].step(dt)
        }
        tint.r.step(dt); tint.g.step(dt); tint.b.step(dt); tint.a.step(dt)
    }

    private var eyeCenter: CGPoint {
        CGPoint(x: .lerp(bubbleEye.x, panelEye.x, opened), y: .lerp(bubbleEye.y, panelEye.y, opened))
    }

    // MARK: Shape

    /// The body's affine part, about the rest centre: x' = a x + c y, y' = d y.
    private var deformation: CGAffineTransform {
        let hx = max(1, bounds.width / 2), hy = max(1, bounds.height / 2)
        // Breathing, only as a bubble, barely.
        let breath = Motion.reduced ? 0 : 0.012 * (1 - opened) * sin(time * 2 * .pi / 3.8)
        return CGAffineTransform(a: (1 + squash.value / hx) * (1 + breath), b: 0,
                                 c: -shear.value / hy, d: (1 - squash.value / hy) * (1 + breath), tx: 0, ty: 0)
    }

    /// How far the edges bow out: more the more it is deformed.
    private var pillow: CGFloat { min(7, 0.45 * abs(squash.value) + 0.3 * abs(shear.value)) }

    /// The rest squircle with pillowed edges, about the origin.
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

    /// Signed distance from the pillowed rounded box; matches the shader.
    nonisolated static func distance(_ q: CGPoint, half: CGSize, radius: CGFloat, pillow: CGFloat) -> CGFloat {
        let qx = abs(q.x) - half.width + radius, qy = abs(q.y) - half.height + radius
        let box = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
        let nx = abs(q.x) / max(1, half.width), ny = abs(q.y) / max(1, half.height)
        let along = nx > ny ? q.y / max(1, half.height) : q.x / max(1, half.width)
        return box - pillow * max(0, 1 - along * along)
    }

    // MARK: Drawing

    private func draw() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let half = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        let radius = min(cornerRadius, half.width, half.height)
        let pillow = self.pillow
        let m = deformation
        let center = CGPoint(x: bounds.midX + lagX.value, y: bounds.midY + lagY.value)
        let margin = Self.margin
        let canvas = bounds.insetBy(dx: -margin, dy: -margin)
        let inverse = m.inverted()
        let eye = eyeCenter
        var u = JellyUniforms(
            tint: SIMD4(Float(tint.r.value), Float(tint.g.value), Float(tint.b.value), Float(tint.a.value)),
            fill: fillVector,
            eye: SIMD4(Float(eye.x - bounds.midX), Float(eye.y - bounds.midY), Float(lookX.value), Float(lookY.value)),
            face: SIMD4(Float(lid.value), Float(happy.value), Float(squint.value), Float(worry.value)),
            inverse: SIMD4(Float(inverse.a), Float(inverse.b), Float(inverse.c), Float(inverse.d)),
            center: SIMD2(Float(center.x), Float(center.y)),
            half: SIMD2(Float(half.width), Float(half.height)),
            origin: SIMD2(Float(canvas.minX), Float(canvas.minY)),
            scale: Float(metal.contentsScale), radius: Float(radius), pillow: Float(pillow),
            time: Float(glowTime), churn: Float(tone == .working ? 1 : 0.3), opened: Float(opened),
            dark: traitCollection.userInterfaceStyle == .dark ? 1 : 0, mode: 0)
        // Inner light drifts only as a bubble; a settled panel is still.
        if opened < 0.98 { glowTime += 1.0 / 60.0 }
        u.time = Float(glowTime)
        // Settled and unchanged: nothing to draw.
        if let drawn, drawnCanvas == canvas, drawn.isClose(to: u) { return }
        drawn = u
        drawnCanvas = canvas

        let rest = restPath(half: half, radius: radius, pillow: pillow)
        // Rest coordinates → bounds: deform about the centre, then move.
        var toBounds = m.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        let onScreen = rest.copy(using: &toBounds) ?? rest
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.frame = bounds
        frostMask.frame = frost.bounds
        frostMask.shape.path = onScreen
        shadow.frame = bounds
        shadow.shadowPath = onScreen
        shadow.shadowColor = UIColor(red: tint.r.value, green: tint.g.value, blue: tint.b.value, alpha: 1).cgColor
        shadow.shadowOpacity = Float(.lerp(0.22 + 0.3 * tint.a.value, 0.22, opened))
        shadow.shadowRadius = .lerp(8, 18, opened)
        // The content rides the body: same deformation, masked to the rest
        // outline in its own coordinates.
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.center = center
        content.transform = m
        var toContent = CGAffineTransform(translationX: half.width, y: half.height)
        contentMask.frame = content.bounds
        contentMask.path = rest.copy(using: &toContent)
        if metal.frame != canvas {
            metal.frame = canvas
            metal.drawableSize = CGSize(width: canvas.width * metal.contentsScale, height: canvas.height * metal.contentsScale)
        }
        // The face's own small canvas, around where the eyes are now.
        let eyeOnScreen = CGPoint(x: eye.x - bounds.midX + lookX.value, y: eye.y - bounds.midY + lookY.value).applying(toBounds)
        let faceRect = CGRect(x: eyeOnScreen.x - 26, y: eyeOnScreen.y - 18, width: 52, height: 36).integral
        if face.frame.size != faceRect.size {
            face.drawableSize = CGSize(width: faceRect.width * face.contentsScale, height: faceRect.height * face.contentsScale)
        }
        face.frame = faceRect
        CATransaction.commit()
        render(&u, into: metal)
        var f = u
        f.mode = 1
        f.origin = SIMD2(Float(faceRect.minX), Float(faceRect.minY))
        f.scale = Float(face.contentsScale)
        render(&f, into: face)
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

/// A damped oscillator driven by a force, in points.
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
    var eye: SIMD4<Float>       // centre (rest coordinates), look
    var face: SIMD4<Float>      // lid, happy, squint, worry
    var inverse: SIMD4<Float>   // the deformation's inverse (a b c d)
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
    /// 0: the body; 1: only the eyes.
    var mode: Float

    func isClose(to o: JellyUniforms) -> Bool {
        func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool { (0..<4).allSatisfy { Swift.abs(a[$0] - b[$0]) < 0.002 } }
        func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { (0..<2).allSatisfy { Swift.abs(a[$0] - b[$0]) < 0.02 } }
        return near(tint, o.tint) && near(fill, o.fill) && near(eye, o.eye) && near(face, o.face) && near(inverse, o.inverse)
            && near(center, o.center) && near(half, o.half) && near(origin, o.origin) && abs(pillow - o.pillow) < 0.02
            && radius == o.radius && dark == o.dark && (opened > 0.98 || abs(time - o.time) < 0.001)
            && abs(opened - o.opened) < 0.002 && churn == o.churn
    }
}

@MainActor
enum JellyRenderer {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    /// Compiled from source once, so the overlay framework needs no
    /// separate Metal library.
    static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
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
        float4 tint;     // rgb, strength
        float4 fill;     // rgb, amount
        float4 eye;      // centre xy (rest), look xy
        float4 face;     // lid, happy, squint, worry
        float4 inverse;  // a b c d
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

    // Screen point → rest coordinates (about the centre, undeformed).
    static float2 rest(float2 p, constant Uniforms& u) {
        float2 d = p - u.center;
        return float2(u.inverse.x * d.x + u.inverse.z * d.y, u.inverse.y * d.x + u.inverse.w * d.y);
    }

    static float sdf(float2 q, constant Uniforms& u) {
        float2 h = u.half_;
        float2 b = abs(q) - h + u.radius;
        float box = length(max(b, 0.0)) + min(max(b.x, b.y), 0.0) - u.radius;
        float nx = abs(q.x) / max(1.0, h.x), ny = abs(q.y) / max(1.0, h.y);
        float along = nx > ny ? q.y / max(1.0, h.y) : q.x / max(1.0, h.x);
        return box - u.pillow * max(0.0, 1.0 - along * along);
    }

    // A cushion: flat on top, rounding down to the edge over `bevel` points.
    static float height(float2 p, float bevel, constant Uniforms& u) {
        float t = clamp(-sdf(rest(p, u), u) / bevel, 0.0, 1.0);
        return sqrt(1.0 - (1.0 - t) * (1.0 - t));
    }

    static float segment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    fragment float4 jellyFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = in.position.xy / u.scale + u.origin;
        float2 q = rest(p, u);
        float d = sdf(q, u);
        float px = 1.0 / u.scale;
        float cover = clamp(0.5 - d / px, 0.0, 1.0);
        if (cover <= 0.0) { return float4(0.0); }

        float3 col = float3(0.0);
        float a = 0.0;
        float3 tint = u.tint.rgb;
        float s = u.tint.a;
        float small = min(u.half_.x, u.half_.y);
        if (u.mode < 0.5) {
        float bevel = clamp(small * 0.8, 5.0, 16.0);
        float lift = bevel * 0.7;
        float e = 0.6;
        float hx = (height(p + float2(e, 0.0), bevel, u) - height(p - float2(e, 0.0), bevel, u)) / (2.0 * e) * lift;
        float hy = (height(p + float2(0.0, e), bevel, u) - height(p - float2(0.0, e), bevel, u)) / (2.0 * e) * lift;
        float3 n = normalize(float3(-hx, -hy, 1.0));

        float3 L = normalize(float3(-0.45, -0.8, 0.9));
        float fres = pow(1.0 - n.z, 1.6);
        float2 side = normalize(n.xy + 1e-5);
        float facing = 0.5 + 0.5 * dot(side, normalize(-L.xy));
        float3 R = reflect(-L, n);
        float spec = pow(max(R.z, 0.0), 120.0) * 1.3 + pow(max(R.z, 0.0), 14.0) * 0.12;
        float depth = clamp(-d / bevel, 0.0, 1.0);

        // Light travels further through the jelly near its edge.
        float absorb = s * (0.12 + 0.8 * fres);
        col = tint * absorb;
        a = absorb;

        // Paper fills the inside as it opens, so text reads; the rim stays glass.
        float f = u.fill.a * smoothstep(0.15, 0.9, depth);
        col = col * (1.0 - f) + u.fill.rgb * f;
        a = a * (1.0 - f) + f;

        // Light gathered inside, opposite the light, near the bottom corner.
        float r0 = min(small, 22.0);
        float t = u.time;
        float2 c1 = float2(u.half_.x - r0 * (0.62 + 0.08 * sin(t * 1.3 * (0.5 + u.churn))), u.half_.y - r0 * (0.5 + 0.06 * cos(t * 1.7)));
        float2 c2 = float2(u.half_.x * (-0.2 + 0.3 * sin(t * 0.9 * u.churn + 1.0)) * (1.0 - u.opened), u.half_.y * 0.25 * cos(t * 1.1 * u.churn));
        float caus = exp(-length_squared((q - c1) / (r0 * float2(0.55, 0.32)))) * 0.55
                   + exp(-length_squared((q - c2) / (r0 * 0.4))) * 0.25 * u.churn * (1.0 - u.opened);
        float3 glow = mix(tint, float3(1.0), 0.55);
        col += glow * caus * s * 0.9;
        a += caus * s * 0.45;

        // Rim: bright where it faces the light, deeper where it turns away.
        float rim = fres * facing;
        col += float3(1.0) * rim * 0.75;
        a += rim * 0.75;
        float shade = fres * (1.0 - facing);
        col += tint * 0.45 * shade * s;
        a += shade * (0.3 + 0.3 * s);

        // The candy gloss: a soft streak just inside the top edge.
        float2 g0 = float2(-u.half_.x * 0.08, -u.half_.y + r0 * 0.42);
        float2 gq = (q - g0) / float2(max(4.0, u.half_.x - r0 * 0.55), r0 * 0.2);
        float gloss = exp(-pow(length_squared(gq), 2.0)) * mix(0.7, 0.45, u.opened);
        col += float3(gloss);
        a += gloss;

        float edge = smoothstep(1.4, 0.0, abs(d)) * (0.25 + 0.35 * facing);
        col += float3(1.0) * edge;
        a += edge;
        col += float3(spec);
        a += spec;
        } else {
        // Open, the face sits on a soft patch of the panel's paper, so text
        // scrolling under the panel's top fades out behind it.
        float2 hc = u.eye.xy + u.eye.zw * 0.5;
        float halo = exp(-length_squared((q - hc) / float2(13.0, 7.5))) * u.opened * u.fill.a * 0.95;
        col = u.fill.rgb * halo;
        a = halo;

        // Eyes: two beads inside it. Happy: arcs. Poked: squeezed shut.
        // Worried: tilted, a little bigger.
        float lid = u.face.x, happy = u.face.y, squint = u.face.z, worry = u.face.w;
        float3 ink = u.dark > 0.5 ? float3(0.96, 0.94, 0.9) : mix(float3(0.07, 0.05, 0.05), tint * 0.3, 0.25);
        for (int i = 0; i < 2; i++) {
            float sgn = i == 0 ? -1.0 : 1.0;
            float2 c = u.eye.xy + u.eye.zw + float2(sgn * 4.7, 0.0);
            float2 v = q - c;
            float ang = sgn * worry * 0.38;
            v = float2(cos(ang) * v.x - sin(ang) * v.y, sin(ang) * v.x + cos(ang) * v.y);
            float grow = 1.0 + 0.15 * worry;
            float2 rr = float2(2.3, max(0.25, 3.3 * lid)) * grow;
            float bead = (length(v / rr) - 1.0) * min(rr.x, rr.y);
            float R = 2.5;
            float2 w = v - float2(0.0, R * 0.55);
            float arc = w.y < R * 0.1 ? abs(length(w) - R) - 0.85 : 9.0;
            float2 tip = float2(-sgn * 1.6, 0.0);
            float chevron = min(segment(v, float2(sgn * 1.4, -1.9), tip), segment(v, tip, float2(sgn * 1.4, 1.9))) - 0.8;
            float kb = smoothstep(px, -px, bead) * (1.0 - happy) * (1.0 - squint);
            float ka = smoothstep(px, -px, arc) * happy * (1.0 - squint);
            float ks = smoothstep(px, -px, chevron) * squint;
            float k = clamp(kb + ka + ks, 0.0, 1.0) * 0.94;
            col = col * (1.0 - k) + ink * k;
            a = a * (1.0 - k) + k;
            float glint = exp(-length_squared((v - float2(-0.8, -1.3) * grow) / 0.7)) * kb;
            col += float3(glint * 0.85);
            a += glint * 0.4;
        }
        }

        a = clamp(a, 0.0, 1.0);
        col = min(col, float3(a));
        return float4(col, a) * cover;
    }
    """
}
#endif
