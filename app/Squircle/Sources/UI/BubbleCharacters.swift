#if DEBUG
import UIKit

/// Prototypes (user, 2026-10-14: "something delightful, that feels like a
/// living character"): the overlay bubble's mark as a small creature that
/// shows what the agent is doing. Three concepts to choose from, picked with
/// `SQUIRCLE_BUBBLE_CHARACTER=peeper|jelly|tumbler`. Every frame is computed
/// by hand from a few springs and the time in the current tone (Core
/// Animation layers, one display link while on screen).
@MainActor
class BubbleCharacter: UIView, CapsuleCharacter {
    static func make(_ name: String) -> BubbleCharacter? {
        switch name {
        case "peeper": PeeperCharacter()
        case "jelly": JellyCharacter()
        case "tumbler": TumblerCharacter()
        default: nil
        }
    }

    var side: CGFloat { 26 }
    private(set) var tone = LiveCapsule.Tone.idle
    /// Seconds since the tone changed, and since the view appeared.
    private(set) var toneTime: CGFloat = 0
    private(set) var time: CGFloat = 0
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(tone: LiveCapsule.Tone) {
        guard tone != self.tone else { return }
        let old = self.tone
        self.tone = tone
        toneTime = 0
        toneChanged(from: old)
        recolor()
    }

    func lineChanged() {}
    func toneChanged(from old: LiveCapsule.Tone) {}
    /// Advance by `dt` seconds and draw.
    func step(_ dt: CGFloat) {}
    /// Layers that take the tone's colour.
    var tinted: [CAShapeLayer] { [] }

    var color: UIColor {
        switch tone {
        case .needsYou: Theme.warning
        case .done: Theme.success
        case .idle, .working: Theme.accent
        }
    }

    private func recolor() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        let fill = color.resolvedColor(with: traitCollection).cgColor
        for layer in tinted { layer.fillColor = fill }
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        recolor()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        last = nil
        recolor()
        guard window != nil else { return }
        let proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = CGFloat(min(1.0 / 20.0, max(0, now - (last ?? (now - link.duration)))))
        last = now
        time += dt
        toneTime += dt
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        step(dt)
        CATransaction.commit()
    }

    /// A squircle the size of `rect`.
    static func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
        UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
    }

    /// An eye as a stroked polyline: a vertical capsule `height` tall
    /// (squashed by `open`, 0 shut), bending into a happy arc ∩ by `happy`.
    static func eye(at center: CGPoint, height: CGFloat, open: CGFloat, happy: CGFloat, arc: CGFloat = 2.6) -> CGPath {
        let path = CGMutablePath()
        let n = 9
        for i in 0..<n {
            let u = CGFloat(i) / CGFloat(n - 1)
            let line = CGPoint(x: 0, y: (u - 0.5) * height * max(0.04, open))
            let a = CGFloat.pi * (1 - u)
            let bend = CGPoint(x: arc * cos(a), y: -arc * sin(a) * 0.9 + arc * 0.45)
            let p = CGPoint(x: center.x + .lerp(line.x, bend.x, happy), y: center.y + .lerp(line.y, bend.y, happy))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    static func eyeLayer(width: CGFloat) -> CAShapeLayer {
        let eye = CAShapeLayer()
        eye.strokeColor = UIColor.white.cgColor
        eye.fillColor = nil
        eye.lineWidth = width
        eye.lineCap = .round
        eye.lineJoin = .round
        return eye
    }
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

/// Repeats `period`, returning 0…1 through the first `active` seconds of
/// each and nil for the rest.
private func phase(_ t: CGFloat, period: CGFloat, active: CGFloat) -> CGFloat? {
    let p = t.truncatingRemainder(dividingBy: period)
    return p < active ? p / active : nil
}

// MARK: - A: Peeper

/// A: a squircle with two eyes. It breathes and blinks when idle and glances
/// around; working, it reads along the task (eyes toward the text, darting
/// as if reading) and its eyes flick up after each finished task; it hops for
/// your attention; it smiles (^ ^) when done.
final class PeeperCharacter: BubbleCharacter {
    private let rig = CALayer()
    private let body = CAShapeLayer()
    private let eyes = [BubbleCharacter.eyeLayer(width: 4), BubbleCharacter.eyeLayer(width: 4)]
    private var lookX = Wobble(0, response: 0.22, damping: 0.72)
    private var lookY = Wobble(0, response: 0.22, damping: 0.6)
    private var lid = Wobble(1, response: 0.07, damping: 1)
    private var happy = Wobble(0, response: 0.3, damping: 0.8)
    private var squash = Wobble(1, response: 0.32, damping: 0.42)
    private var nextBlink: CGFloat = 1.5
    private var nextGlance: CGFloat = 2
    private var blinkEnd: CGFloat = 0

    override init() {
        super.init()
        rig.addSublayer(body)
        eyes.forEach(rig.addSublayer)
        layer.addSublayer(rig)
    }

    override var tinted: [CAShapeLayer] { [body] }

    override func lineChanged() {
        lookY.velocity -= 70
        squash.velocity -= 0.8
    }

    override func toneChanged(from old: LiveCapsule.Tone) {
        squash.velocity += tone == .done ? 2.4 : 1.2
    }

    override func step(_ dt: CGFloat) {
        let s = side
        switch tone {
        case .idle:
            if time > nextGlance {
                let glance = [CGPoint(x: -2, y: 0.5), CGPoint(x: 2, y: -0.5), .zero, CGPoint(x: 1.2, y: 1.2), .zero]
                let g = glance.randomElement()!
                (lookX.target, lookY.target) = (g.x, g.y)
                nextGlance = time + .random(in: 1.8...4.5)
            }
            squash.target = 1 + 0.03 * sin(time * 2 * .pi / 3.4)
            happy.target = 0
        case .working:
            // Reading: little saccades toward the text on the right.
            let saccade = floor(time * 2.6)
            lookX.target = 1.6 + 1.3 * CGFloat(Int(saccade) % 3) / 2
            lookY.target = 0.5
            squash.target = 1 + 0.025 * sin(time * 2 * .pi * 1.3)
            happy.target = 0
        case .needsYou:
            (lookX.target, lookY.target) = (0, -0.8)
            squash.target = 1
            happy.target = 0
        case .done:
            (lookX.target, lookY.target) = (0, -0.5)
            squash.target = 1
            happy.target = toneTime < 3.5 ? 1 : 0
        }
        // Blinks, at random, not while smiling.
        if time > nextBlink, happy.value < 0.3 {
            blinkEnd = time + 0.11
            nextBlink = time + .random(in: tone == .working ? 2.2...4.5 : 1.6...4)
            if Bool.random(), tone == .idle { nextBlink = time + 0.3 } // a double blink now and then
        }
        lid.target = time < blinkEnd ? 0 : 1
        lookX.step(dt); lookY.step(dt); lid.step(dt); happy.step(dt); squash.step(dt)

        // Hops for attention: up and down every 1.3 s, landing with a squash.
        var hop: CGFloat = 0
        if tone == .needsYou, let p = phase(toneTime, period: 1.3, active: 0.42) {
            hop = -6 * sin(.pi * p)
            if p > 0.93, squash.velocity > -1 { squash.velocity -= 3.2 }
        }
        let sy = squash.value, sx = 1 / sqrt(max(0.5, sy))
        rig.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        rig.anchorPoint = CGPoint(x: 0.5, y: 1)
        rig.position = CGPoint(x: bounds.midX, y: bounds.midY + s / 2 + hop)
        rig.transform = CATransform3DMakeScale(sx, sy, 1)
        body.path = Self.squircle(rig.bounds, radius: s * 0.34)
        let height: CGFloat = tone == .needsYou ? 5.2 : 3.6
        for (i, eye) in eyes.enumerated() {
            let center = CGPoint(x: s * (i == 0 ? 0.33 : 0.67) + lookX.value, y: s * 0.43 + lookY.value)
            eye.path = Self.eye(at: center, height: height, open: lid.value, happy: happy.value.clamped())
        }
    }
}

// MARK: - B: Jelly

/// B: a soft jelly squircle with a glossy highlight and two dot eyes. Idle it
/// breathes with a slight wobble; working it churns (lobes rolling round its
/// outline) and kneads; each finished task is a little gulp; it bounces with
/// squash and stretch for your attention; done is one big happy jiggle.
final class JellyCharacter: BubbleCharacter {
    private let body = CAShapeLayer()
    private let gloss = CAShapeLayer()
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private var amp = Wobble(0.015, response: 0.5, damping: 1)
    private var squash = Wobble(1, response: 0.38, damping: 0.3)
    private var look = Wobble(0, response: 0.3, damping: 0.8)
    private var lid = Wobble(1, response: 0.08, damping: 1)
    private var nextBlink: CGFloat = 2
    private var blinkEnd: CGFloat = 0

    override init() {
        super.init()
        layer.addSublayer(body)
        gloss.fillColor = UIColor.white.withAlphaComponent(0.38).cgColor
        layer.addSublayer(gloss)
        for eye in eyes {
            eye.fillColor = UIColor.white.cgColor
            layer.addSublayer(eye)
        }
    }

    override var tinted: [CAShapeLayer] { [body] }

    override func lineChanged() { squash.velocity -= 2.2 }

    override func toneChanged(from old: LiveCapsule.Tone) {
        squash.velocity += tone == .done ? 5 : 2
    }

    override func step(_ dt: CGFloat) {
        let s = side
        switch tone {
        case .idle:
            amp.target = 0.018
            squash.target = 1 + 0.035 * sin(time * 2 * .pi / 3.2)
            look.target = 0
        case .working:
            amp.target = 0.055
            squash.target = 1 + 0.05 * sin(time * 2 * .pi * 1.1)
            look.target = 2
        case .needsYou:
            amp.target = 0.03
            squash.target = 1
            look.target = 0
        case .done:
            amp.target = 0.025
            squash.target = 1
            look.target = 0
        }
        if time > nextBlink {
            blinkEnd = time + 0.12
            nextBlink = time + .random(in: 2...5)
        }
        lid.target = time < blinkEnd ? 0.1 : (tone == .working ? 0.7 : 1)
        amp.step(dt); squash.step(dt); look.step(dt); lid.step(dt)

        var hop: CGFloat = 0
        if tone == .needsYou, let p = phase(toneTime, period: 1.2, active: 0.46) {
            hop = -6.5 * sin(.pi * p)
            // Stretched in the air, squashed on landing.
            squash.target = 1 + 0.12 * sin(.pi * p)
            if p > 0.92, squash.velocity > -2 { squash.velocity -= 4 }
        }
        let sy = squash.value, sx = 1 / sqrt(max(0.5, sy))
        let bottom = bounds.midY + s / 2 + hop
        let center = CGPoint(x: bounds.midX, y: bottom - s / 2 * sy)
        // A superellipse whose radius ripples with three rolling lobes.
        let r = s / 2, n: CGFloat = 4, a = amp.value, t = time
        let path = CGMutablePath()
        let count = 72
        for i in 0..<count {
            let th = CGFloat(i) / CGFloat(count) * 2 * .pi
            let c = cos(th), sn = sin(th)
            let base = r / pow(pow(abs(c), n) + pow(abs(sn), n), 1 / n)
            let w = 1 + a * (sin(2 * th + t * 3.1) + 0.7 * sin(3 * th - t * 2.3) + 0.4 * sin(5 * th + t * 4.7))
            let p = CGPoint(x: center.x + sx * base * w * c, y: center.y + sy * base * w * sn)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        body.path = path
        gloss.path = CGPath(ellipseIn: CGRect(x: center.x - s * 0.3 * sx, y: center.y - s * 0.36 * sy,
                                              width: s * 0.26 * sx, height: s * 0.13 * sy), transform: nil)
        let eyeH = 4.4 * lid.value * (tone == .needsYou ? 1.25 : 1), eyeW: CGFloat = tone == .needsYou ? 4 : 3.4
        for (i, eye) in eyes.enumerated() {
            let x = center.x + sx * s * (i == 0 ? -0.15 : 0.15) + look.value
            let y = center.y + sy * s * 0.02
            if tone == .done, toneTime < 3.5 {
                eye.fillColor = nil
                eye.strokeColor = UIColor.white.cgColor
                eye.lineWidth = 2
                eye.lineCap = .round
                eye.path = Self.eye(at: CGPoint(x: x, y: y), height: 0, open: 1, happy: 1, arc: 2.2)
            } else {
                eye.fillColor = UIColor.white.cgColor
                eye.strokeColor = nil
                eye.path = CGPath(ellipseIn: CGRect(x: x - eyeW / 2, y: y - eyeH / 2, width: eyeW, height: max(0.8, eyeH)), transform: nil)
            }
        }
    }
}

// MARK: - C: Tumbler

/// C: a little rounded cube that tumbles end over end in place while the
/// agent works (lifting on its corner, landing with a squash), sleeps when
/// idle (eyes shut, a "z" drifting up now and then), jumps and wiggles for
/// your attention, and does a backflip when done.
final class TumblerCharacter: BubbleCharacter {
    private let cube = CAShapeLayer()
    private let eyes = [BubbleCharacter.eyeLayer(width: 2.6), BubbleCharacter.eyeLayer(width: 2.6)]
    private var squash = Wobble(1, response: 0.3, damping: 0.4)
    private var shut = Wobble(1, response: 0.25, damping: 1)
    private var happy = Wobble(0, response: 0.3, damping: 0.8)
    /// Settled rotation, in quarter turns.
    private var turns: CGFloat = 0
    private var nextZ: CGFloat = 1
    private var landed = true

    override init() {
        super.init()
        layer.addSublayer(cube)
        eyes.forEach(cube.addSublayer)
    }

    override var side: CGFloat { 26 }
    override var tinted: [CAShapeLayer] { [cube] }

    override func lineChanged() { squash.velocity += 1.5 }

    override func toneChanged(from old: LiveCapsule.Tone) {
        // Settle on a face before anything else.
        turns = turns.rounded()
        landed = true
        squash.velocity += 1.5
    }

    override func step(_ dt: CGFloat) {
        let s: CGFloat = 18
        var angle = turns * .pi / 2, lift: CGFloat = 0, wiggle: CGFloat = 0
        shut.target = tone == .idle ? 1 : 0
        happy.target = tone == .done && toneTime < 3.5 ? 1 : 0
        squash.target = tone == .idle ? 1 + 0.04 * sin(time * 2 * .pi / 3.6) : 1
        let diagonalLift = (s / 2) * (sqrt(2) - 1)
        switch tone {
        case .working:
            // A quarter turn every 0.75 s, pivoting on its leading corner.
            let period: CGFloat = 0.75, roll: CGFloat = 0.42
            let p = toneTime.truncatingRemainder(dividingBy: period)
            if p < roll {
                landed = false
                let u = p / roll
                let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
                angle = (turns + e) * .pi / 2
                lift = diagonalLift * sin(.pi * e)
            } else if !landed {
                landed = true
                turns += 1
                angle = turns * .pi / 2
                squash.velocity -= 2.6
            }
        case .needsYou:
            if let p = phase(toneTime, period: 1.1, active: 0.4) {
                lift = 7 * sin(.pi * p)
                wiggle = 0.28 * sin(p * 2 * .pi * 2)
                if p > 0.92, squash.velocity > -1 { squash.velocity -= 3 }
            }
        case .done:
            // A backflip, once, then rest.
            if toneTime < 0.6 {
                let u = toneTime / 0.6
                let e = 1 - pow(1 - u, 3)
                angle = (turns - 4 * e) * .pi / 2
                lift = 9 * sin(.pi * u)
            } else if landed {
                landed = false
                squash.velocity -= 3
            }
        case .idle:
            if time > nextZ { floatZ(); nextZ = time + 2.6 }
        }
        squash.step(dt); shut.step(dt); happy.step(dt)

        let sy = squash.value, sx = 1 / sqrt(max(0.5, sy))
        let floor = bounds.midY + s / 2 + 1
        cube.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        cube.position = CGPoint(x: bounds.midX, y: floor - s / 2 * sy - lift)
        var transform = CATransform3DMakeScale(sx, sy, 1)
        transform = CATransform3DRotate(transform, angle + wiggle, 0, 0, 1)
        cube.transform = transform
        cube.path = Self.squircle(cube.bounds, radius: 5.5)
        for (i, eye) in eyes.enumerated() {
            let center = CGPoint(x: s * (i == 0 ? 0.33 : 0.67) + (tone == .working ? 1.5 : 0), y: s * 0.44)
            // Shut eyes are a short line: the capsule turned on its side.
            let open = 1 - shut.value
            let path = Self.eye(at: center, height: tone == .needsYou ? 5.4 : 4.2, open: open, happy: happy.value.clamped(), arc: 2)
            if shut.value > 0.5 {
                let line = CGMutablePath()
                line.move(to: CGPoint(x: center.x - 1.8, y: center.y + 0.6))
                line.addLine(to: CGPoint(x: center.x + 1.8, y: center.y + 0.6))
                eye.path = line
                eye.lineWidth = 1.6
            } else {
                eye.path = path
                eye.lineWidth = 2.6
            }
        }
    }

    /// A tiny "z" rising out of the sleeping cube.
    private func floatZ() {
        let z = CATextLayer()
        z.string = "z"
        z.font = UIFont.systemFont(ofSize: 8, weight: .heavy)
        z.fontSize = 8
        z.foregroundColor = color.resolvedColor(with: traitCollection).withAlphaComponent(0.8).cgColor
        z.contentsScale = window?.screen.scale ?? 3
        z.alignmentMode = .center
        z.frame = CGRect(x: bounds.midX + 5, y: bounds.midY - 12, width: 8, height: 10)
        layer.addSublayer(z)
        let rise = CABasicAnimation(keyPath: "position")
        rise.byValue = NSValue(cgPoint: CGPoint(x: 4, y: -9))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1.3
        let group = CAAnimationGroup()
        group.animations = [rise, fade, grow]
        group.duration = 1.8
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        z.opacity = 0
        z.add(group, forKey: "float")
        Task { [weak z] in
            try? await Task.sleep(for: .seconds(1.9))
            z?.removeFromSuperlayer()
        }
    }
}
#endif
