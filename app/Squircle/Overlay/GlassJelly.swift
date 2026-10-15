#if SQUIRCLE_OVERLAY || DEBUG
import Metal
import simd
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
            case .working, .idle, .recording: break
            }
            wake()
        }
    }
    /// The status line or the conversation: masked to the blob, carried by it.
    let content = UIView()
    /// The blob's rest shape, in bounds coordinates.
    var bodyRect = CGRect(x: 0, y: 0, width: 44, height: 44)
    var cornerRadius: CGFloat = 18
    /// Where the creature belongs, in bounds coordinates (its centre).
    var creatureAnchor = CGPoint(x: 22, y: 22)
    /// Where the neck leaves the body (bounds coordinates), and its rest length.
    var neckRoot = CGPoint(x: 22, y: 22)
    var neckLength: CGFloat = 30
    /// +1 when the creature sits to the right of the blob, -1 to the left.
    var creatureSide: CGFloat = 1
    static let creatureSize: CGFloat = 34
    /// 0 bubble … 1 panel: fills with paper, calms down.
    var opened: CGFloat = 0
    var fill = UIColor.white
    var fillAmount: CGFloat = 0
    /// The keyboard is up: it watches the field.
    var typing = false {
        didSet { if typing != oldValue { wake() } }
    }
    /// Not connected to the Mac: it dozes (heavy lids, faded colour).
    var drowsy = false {
        didSet { if drowsy != oldValue { wake() } }
    }

    /// The creature as drawn now, in the superview's coordinates.
    var creatureFrame: CGRect {
        let s = Self.creatureSize
        return CGRect(x: creatureWorld.x - s / 2, y: creatureWorld.y - s / 2, width: s, height: s)
    }

    private let shadow = CAShapeLayer()
    private let shadowMask = CAShapeLayer()
    private let frost = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    /// The blur shows where the jelly is: its outline, as a path (a second
    /// Metal pass here cost a whole frame on the phone).
    private let frostMask = ShapeView()
    private let contentMask = CAShapeLayer()
    /// One layer draws the whole jelly: pill or panel, neck and cube.
    private let metal = CAMetalLayer()
    private static let margin: CGFloat = 60
    /// The Metal layer's size grows and shrinks in steps of this many
    /// points, so resizing the panel doesn't reallocate drawables each frame.
    private static let sizeStep: CGFloat = 96

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
    private var offsetX = Mode(), offsetY = Mode()
    /// Carried across a jump of its anchor; no clamps until it is back.
    private var gliding = false
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
    private var sleepy = Wobble(0, response: 0.6, damping: 1)
    /// A finger dragging the panel sideways without moving it (resizing):
    /// rubber-banded points the body and head lean toward.
    private var pullX: CGFloat = 0
    private var finger: (point: CGPoint, at: CGFloat)?
    private var tint = (r: Wobble(0, response: 0.35, damping: 1), g: Wobble(0, response: 0.35, damping: 1),
                        b: Wobble(0, response: 0.35, damping: 1), a: Wobble(0, response: 0.35, damping: 1))
    private var tintSet = false

    private var time: CGFloat = 0, toneTime: CGFloat = 0
    private var nextHop: CGFloat = 1.5
    private var last: CFTimeInterval?
    /// The display link and how it runs, decided after every tick from what
    /// moves: one owner for the link, its rate and, while it sleeps, when it
    /// paused and the alarm that wakes it.
    private enum Ticker {
        /// Off screen: no link.
        case detached
        /// Ticking at the cadence's rate (moving or breathing).
        case running(CADisplayLink, Cadence)
        /// Paused since `since`; `alarm` resumes it for the next blink,
        /// glance or hop (nil: only a touch or move does).
        case sleeping(CADisplayLink, since: CFTimeInterval, alarm: Task<Void, Never>?)

        var link: CADisplayLink? {
            switch self {
            case .detached: nil
            case .running(let link, _), .sleeping(let link, _, _): link
            }
        }
        /// Lets go of the link and the alarm.
        func end() {
            link?.invalidate()
            if case .sleeping(_, _, let alarm) = self { alarm?.cancel() }
        }
    }
    private var ticker = Ticker.detached
    private var link: CADisplayLink? { ticker.link }
    private var cadence: Cadence {
        switch ticker {
        case .detached: .moving
        case .running(_, let cadence): cadence
        case .sleeping: .still(after: nil)
        }
    }
    private var observers: [Task<Void, Never>] = []
    /// What is on screen: set only once a frame was actually presented (a
    /// frame that found no drawable, or came in the background, isn't), so
    /// it may only sleep showing the pose it rests in.
    private var presented: (uniforms: JellyUniforms, canvas: CGRect)?
    /// The owner's layout drew this frame: the tick draws next frame instead
    /// (one draw a frame), and doesn't sleep until that frame is shown.
    private var drewInLayout = false
    /// The app is in the background: no GPU work, nothing presented.
    private var inBackground = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.fillColor = UIColor.clear.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: 6)
        shadowMask.fillRule = .evenOdd
        shadow.mask = shadowMask
        layer.addSublayer(shadow)
        frostMask.shape.fillColor = UIColor.black.cgColor
        frost.mask = frostMask
        frost.isUserInteractionEnabled = false
        addSubview(frost)
        metal.device = JellyRenderer.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        // Drawn on the main thread, in the same transaction as the text it
        // carries (see `render`).
        metal.presentsWithTransaction = true
        metal.anchorPoint = .zero
        layer.addSublayer(metal)
        contentMask.fillColor = UIColor.black.cgColor
        content.layer.mask = contentMask
        addSubview(content)
        // Light or dark: its colours change, so it draws again.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.wake() }
        // Reduce Motion changing, and the app leaving or returning, wake it;
        // back in front it draws its pose again whatever it last showed.
        let center = NotificationCenter.default
        let events: [(Notification.Name, @MainActor (GlassJelly) -> Void)] = [
            (UIAccessibility.reduceMotionStatusDidChangeNotification, { $0.wake() }),
            (UIApplication.didEnterBackgroundNotification, { $0.background(true) }),
            (UIApplication.willEnterForegroundNotification, { $0.background(false) }),
            (UIApplication.didBecomeActiveNotification, { $0.background(false) })
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

    deinit { ticker.end(); observers.forEach { $0.cancel() } }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Events

    /// A finished task: the creature gulps it down.
    func gulp() {
        creatureSquash.velocity += 1.1
        wake()
    }

    /// A finger drags sideways by `dx` points while the frame stays put (nil:
    /// let go). The body and head lean a few rubber-banded points after it
    /// and, let go, spring back with a small jiggle.
    func pull(_ dx: CGFloat?) {
        let next = dx.map { 7 * tanh($0 / 90) } ?? 0
        guard abs(next - pullX) > 0.01 else { return }
        pullX = next
        wake()
    }

    /// Somewhere a finger touched (bounds coordinates).
    func look(at point: CGPoint) {
        if let finger, time - finger.at < 0.4, hypot(point.x - finger.point.x, point.y - finger.point.y) < 30 { return }
        finger = (point, time)
        gazeHold = 0
        wake()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        wake()
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

    /// A display link runs while it is on screen, at the screen's full rate
    /// while anything moves, slowly while it only breathes, and not at all
    /// while it is still (Reduce Motion, or the open panel) until its next
    /// blink or glance or something touches or moves it. iOS stops it with
    /// the app in the background, and it ends with the window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        ticker.end()
        ticker = .detached
        last = nil
        presented = nil
        drewInLayout = false
        pressed = false
        guard window != nil else { return }
        metal.contentsScale = min(2, window?.screen.scale ?? 2)
        let proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = Cadence.moving.rate ?? .default
        link.add(to: .main, forMode: .common)
        ticker = .running(link, .moving)
    }

    /// The owner moved or resized it: draw now, in the same transaction, so
    /// the jelly and its text never sit a frame apart.
    func layoutChanged() {
        guard window != nil else { return }
        wake()
        if draw() { drewInLayout = true }
    }

    /// The app left or came back. Away, it draws nothing (no GPU work in the
    /// background) and lets go of a held press; back, whatever it showed
    /// before is stale, so it draws its pose again, without replaying the
    /// time away as motion.
    private func background(_ away: Bool) {
        guard away != inBackground else { return }
        inBackground = away
        presented = nil
        if away {
            pressed = false
        } else {
            last = nil
            lastPosition = nil
            lastSize = nil
        }
        wake()
    }

    /// Something may move: full rate from the next frame. Time it spent
    /// paused passes at once (blinks and glances come due), without
    /// stepping the springs, which were at rest.
    private func wake() {
        switch ticker {
        case .detached:
            return
        case .sleeping(let link, let since, _):
            let gap = CGFloat(max(0, CACurrentMediaTime() - since))
            time += gap
            toneTime += gap
            last = nil
            setCadence(.moving, link: link)
        case .running(let link, _):
            setCadence(.moving, link: link)
        }
    }

    private func setCadence(_ next: Cadence, link: CADisplayLink) {
        switch (ticker, next) {
        case (.running(_, let current), _) where current == next: return
        case (.sleeping, .still): return
        default: break
        }
        if case .sleeping(_, _, let alarm) = ticker { alarm?.cancel() }
        if let rate = next.rate { link.preferredFrameRateRange = rate }
        link.isPaused = next.paused
        guard case .still(let after) = next else {
            ticker = .running(link, next)
            return
        }
        let alarm = after.map { after in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(after)))
                guard !Task.isCancelled else { return }
                self?.wake()
            }
        }
        ticker = .sleeping(link, since: CACurrentMediaTime(), alarm: alarm)
    }

    private func tick(_ link: CADisplayLink) {
        // Real time between frames, however late they come; long gaps (a
        // stall, the app returning) skip ahead rather than replay.
        let now = link.targetTimestamp
        var dt = CGFloat(min(0.25, max(0.001, now - (last ?? (now - link.duration)))))
        #if DEBUG
        dt /= CGFloat(SpringDriver.debugSlowMotion)
        #endif
        last = now
        sense(dt)
        // The springs step at most a 60th of a second at a time, so a slow
        // frame moves them as far as it should without going unstable.
        var left = min(dt, 0.1)
        while left > 1e-4 {
            let h = min(left, 1.0 / 60.0)
            left -= h
            time += h
            toneTime += h
            stepBlob(h)
            stepCreature(h)
            stepFace(h)
            stepBridge(h)
        }
        time += dt - min(dt, 0.1)
        toneTime += dt - min(dt, 0.1)
        if !isValid { settleAtRest() }
        // The owner's layout drew this frame already; what the springs
        // moved since shows next frame (`showsCurrentPose` keeps it awake).
        if drewInLayout { drewInLayout = false } else { draw() }
        setCadence(nextCadence, link: link)
    }

    /// Full rate while anything moves or the screen doesn't yet show where
    /// it rests; otherwise slow for the breath alone, or paused until the
    /// next thing timed to happen.
    private var nextCadence: Cadence {
        guard isAtRest, showsCurrentPose else { return .moving }
        if !Motion.reduced, opened < 0.999 { return .breathing }
        var due: [CGFloat] = [gazeHold, squintUntil]
        if let finger { due.append(finger.at + 1.6) }
        if tone == .done { due.append(time - toneTime + 4) }
        if !Motion.reduced {
            due.append(nextBlink)
            if tone == .needsYou { due.append(nextHop) }
        }
        return .still(after: due.filter { $0 > time }.min().map { $0 - time })
    }

    /// The whole body at rest: every spring of the blob, the creature, its
    /// face and the bridge settled on its target, the frame not moving, the
    /// cube back on its anchor, no blink, touch or glide under way.
    private var isAtRest: Bool {
        guard !pressed, !gliding, blinkStart < 0, abs(cubeScale - 1) < 0.001,
              hypot(velocity.x, velocity.y) < 0.5, hypot(sizeVelocity.width, sizeVelocity.height) < 0.5,
              hypot(accel.x, accel.y) < 1, hypot(sizeAccel.width, sizeAccel.height) < 1 else { return false }
        let modes = [squash, shear, lagX, lagY, offsetX, offsetY, creatureSquash, hop, stubRoot, stubCube]
        let wobbles = [yaw, pitch, roll, gazeX, gazeY, happy, squint, worry, sleepy, tint.r, tint.g, tint.b, tint.a]
        return modes.allSatisfy { $0.isAtRest } && wobbles.allSatisfy { $0.isAtRest }
    }

    /// The screen shows the pose it has now (in the foreground, a frame with
    /// these values was presented).
    private var showsCurrentPose: Bool {
        if inBackground { return true }
        guard let now = uniforms() else { return true }
        guard let presented else { return false }
        return presented.canvas == now.canvas && presented.uniforms.isClose(to: now.uniforms)
    }

    /// Every value finite (a NaN anywhere would never settle and draw nothing).
    private var isValid: Bool {
        let modes = [squash, shear, lagX, lagY, offsetX, offsetY, creatureSquash, hop, stubRoot, stubCube]
        let wobbles = [yaw, pitch, roll, gazeX, gazeY, happy, squint, worry, sleepy, tint.r, tint.g, tint.b, tint.a]
        let values = modes.flatMap { [$0.value, $0.velocity] } + wobbles.flatMap { [$0.value, $0.velocity] }
            + [velocity.x, velocity.y, sizeVelocity.width, sizeVelocity.height, accel.x, accel.y,
               sizeAccel.width, sizeAccel.height, creatureWorld.x, creatureWorld.y, waist, catenary, cubeScale, time, toneTime]
        return values.allSatisfy(\.isFinite)
    }

    /// Back to the rest pose on its anchor (after an invalid state).
    private func settleAtRest() {
        (squash, shear, lagX, lagY, offsetX, offsetY) = (Mode(), Mode(), Mode(), Mode(), Mode(), Mode())
        (creatureSquash, hop, stubRoot, stubCube) = (Mode(), Mode(), Mode(), Mode())
        func rest(_ wobble: inout Wobble) {
            if !wobble.target.isFinite { wobble.target = 0 }
            (wobble.value, wobble.velocity) = (wobble.target, 0)
        }
        rest(&yaw); rest(&pitch); rest(&roll); rest(&gazeX); rest(&gazeY)
        rest(&happy); rest(&squint); rest(&worry); rest(&sleepy)
        rest(&tint.r); rest(&tint.g); rest(&tint.b); rest(&tint.a)
        (velocity, sizeVelocity, accel, sizeAccel) = (.zero, .zero, .zero, .zero)
        (lastPosition, lastSize, gliding) = (nil, nil, false)
        (bridgeConnected, waist, catenary, cubeScale) = (true, Self.restWaist, 10, 1)
        if !time.isFinite || !toneTime.isFinite { (time, toneTime, gazeHold, nextBlink, nextHop, squintUntil) = (0, 0, 0, 2.5, 1.5, 0) }
        creatureWorld = anchorWorld
    }

    #if DEBUG
    // MARK: Stress (`SQUIRCLE_JELLY_STRESS`)

    /// The chance a frame finds no drawable.
    var debugDropRate = 0.0
    private var debugNoDrawable = 0

    func debugBackground(_ away: Bool) { background(away) }
    func debugPoke(_ down: Bool) {
        if down { touchesBegan([], with: nil) } else { touchesEnded([], with: nil) }
    }

    /// Asleep (paused or breathing), resting on its anchor and showing the
    /// pose it rests in.
    var debugSettled: Bool {
        cadence != .moving && isAtRest && showsCurrentPose && hypot(offsetX.value, offsetY.value) < 0.5
            && (bridgeConnected || stubRoot.value + stubCube.value < 0.5)
    }

    /// Which part of it isn't settled.
    var debugState: String {
        let names = ["squash", "shear", "lagX", "lagY", "offsetX", "offsetY", "creatureSquash", "hop", "stubRoot", "stubCube"]
        let modes = [squash, shear, lagX, lagY, offsetX, offsetY, creatureSquash, hop, stubRoot, stubCube]
        let wobbleNames = ["yaw", "pitch", "roll", "gazeX", "gazeY", "happy", "squint", "worry", "sleepy", "r", "g", "b", "a"]
        let wobbles = [yaw, pitch, roll, gazeX, gazeY, happy, squint, worry, sleepy, tint.r, tint.g, tint.b, tint.a]
        var moving = zip(names, modes).filter { !$0.1.isAtRest }.map { "\($0.0)=\($0.1.value)/\($0.1.velocity)" }
        moving += zip(wobbleNames, wobbles).filter { !$0.1.isAtRest }.map { "\($0.0)=\($0.1.value)→\($0.1.target) v\($0.1.velocity)" }
        return "cadence=\(cadence) paused=\(link?.isPaused ?? true) rest=\(isAtRest) shows=\(showsCurrentPose) pressed=\(pressed) "
            + "gliding=\(gliding) blink=\(blinkStart) scale=\(cubeScale) connected=\(bridgeConnected) v=\(velocity) sv=\(sizeVelocity) "
            + "a=\(accel) sa=\(sizeAccel) bg=\(inBackground) presented=\(presented != nil) noDrawable=\(debugNoDrawable) "
            + "window=\(window != nil) hidden=\(isHidden) alpha=\(alpha) metal=\(metal.bounds.size) drawable=\(metal.drawableSize) moving=[\(moving.joined(separator: ", "))]"
    }

    /// What is wrong with it, if anything, held for at least three audited
    /// frames (a change whose wake is a notification away is not frozen):
    /// any value not finite; asleep in the foreground while not at rest or
    /// not showing its pose (a frozen mid-motion frame); awake but its pose
    /// not on screen for a second; or no display link on screen.
    func debugViolation() -> String? {
        let problem = debugProblem()
        debugStreak = problem == nil ? 0 : debugStreak + 1
        return debugStreak >= 3 ? problem : nil
    }

    private var debugStreak = 0
    private var debugStaleSince: CFTimeInterval?

    private func debugProblem() -> String? {
        let now = CACurrentMediaTime()
        guard isValid else { return "invalid state" }
        guard window != nil, !inBackground else { debugStaleSince = nil; return nil }
        guard let link else { return "no display link on screen" }
        let shows = showsCurrentPose
        if shows { debugStaleSince = nil } else if debugStaleSince == nil { debugStaleSince = now }
        if cadence != .moving || link.isPaused {
            if !isAtRest { return "asleep while moving" }
            if !shows { return "asleep showing a stale pose" }
        } else if let since = debugStaleSince, now - since > 1 {
            return "awake but its pose not presented for a second"
        }
        if !gliding, hypot(offsetX.value, offsetY.value) > 46.5 { return "cube beyond its reach" }
        return nil
    }
    #endif

    // MARK: Blob

    /// Where the cube belongs, on screen: the one point the body's motion is
    /// read from, so a pill growing toward it (text changing) moves nothing.
    private var anchorWorld: CGPoint {
        CGPoint(x: layer.position.x - bounds.midX + creatureAnchor.x, y: layer.position.y - bounds.midY + creatureAnchor.y)
    }

    private func sense(_ dt: CGFloat) {
        let position = anchorWorld, size = bounds.size
        defer { lastPosition = position; lastSize = size }
        guard let lastPosition, let lastSize else { return }
        // Its anchor jumped (it changed sides): the cube stays where it is on
        // screen and glides to its new place; the jump is no motion.
        let jump = CGPoint(x: position.x - lastPosition.x - velocity.x * dt, y: position.y - lastPosition.y - velocity.y * dt)
        if hypot(jump.x, jump.y) > 24 {
            offsetX.value -= position.x - lastPosition.x
            offsetY.value -= position.y - lastPosition.y
            gliding = true
            // A jump (or a fast frame stopping dead) carries no motion: the
            // frame's motion starts again from rest. Kept, the old velocity
            // made every following still frame read as a jump again, so the
            // body held that phantom pull forever, frozen mid-stretch.
            velocity = .zero
            sizeVelocity = .zero
            accel = .zero
            sizeAccel = .zero
            return
        }
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
        // Only the panel resizing squashes it; a pill fitting new text doesn't.
        squashForce += 0.06 * (sizeAccel.width - sizeAccel.height) * opened
        let shearForce = 0.12 * a.x
        // A sideways pull leans the top after the finger and shifts the body.
        lagX.target = reduced ? 0 : pullX
        shear.target = reduced ? 0 : -0.6 * pullX
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
        // A step behind where it belongs: an offset from its anchor that only
        // the anchor's acceleration moves (the same springy lag as a body on
        // a short neck), so it glides with the pill and never fights it.
        if !placedCreature || Motion.reduced {
            // On its anchor, still: nothing left to glide back from.
            placedCreature = true
            offsetX = Mode()
            offsetY = Mode()
            gliding = false
        } else {
            let steps = 4, h = dt / CGFloat(steps)
            for _ in 0..<steps {
                offsetX.step(h, frequency: 4.5, damping: 0.72, force: -accel.x)
                offsetX.target = 1.4 * pullX
                offsetY.step(h, frequency: 4.5, damping: 0.72, force: -accel.y)
            }
            let n = hypot(offsetX.value, offsetY.value), reach: CGFloat = 46
            if gliding, n < 12 { gliding = false }
            if !gliding, n > reach { offsetX.value *= reach / n; offsetY.value *= reach / n }
            // It can't be pushed into the body: toward the neck's root it
            // squashes the meniscus a few points, then the jelly pushes back.
            let root = CGPoint(x: layer.position.x - bounds.midX + neckRoot.x, y: layer.position.y - bounds.midY + neckRoot.y)
            let axis = CGPoint(x: anchorWorld.x - root.x, y: anchorWorld.y - root.y), len = max(1, hypot(axis.x, axis.y))
            let dir = CGPoint(x: axis.x / len, y: axis.y / len)
            let along = offsetX.value * dir.x + offsetY.value * dir.y
            if !gliding, along < -5 {
                offsetX.value -= (along + 5) * dir.x
                offsetY.value -= (along + 5) * dir.y
                let v = offsetX.velocity * dir.x + offsetY.velocity * dir.y
                if v < 0 { offsetX.velocity -= 1.3 * v * dir.x; offsetY.velocity -= 1.3 * v * dir.y }
                creatureSquash.velocity += 0.02 * max(0, -v) / 60
            }
        }
        let anchor = anchorWorld
        creatureWorld = CGPoint(x: anchor.x + offsetX.value, y: anchor.y + offsetY.value)
        creatureVelocity = CGPoint(x: velocity.x + offsetX.velocity, y: velocity.y + offsetY.velocity)
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

    // MARK: Bridge

    /// The neck between the body and the cube, as a liquid bridge: a
    /// catenoid whose volume is kept, so stretching it lengthens and thins
    /// its waist (drawing a little from the bodies); below a critical waist
    /// it pinches off (Plateau–Rayleigh) and each half is drawn back into its
    /// body with a damped wobble; brought close again, the bodies merge.
    private var bridgeConnected = true
    private var waist: CGFloat = 5.5
    private var catenary: CGFloat = 10
    private var stubRoot = Mode(), stubCube = Mode()
    private var cubeScale: CGFloat = 1
    private static let endRadius: CGFloat = 11
    private static let restWaist: CGFloat = 8
    private static let pinchWaist: CGFloat = 4.9

    private var rootNow: CGPoint {
        CGPoint(x: neckRoot.x + lagX.value, y: neckRoot.y + lagY.value)
    }
    private var cubeNow: CGPoint {
        CGPoint(x: creatureWorld.x - layer.position.x + bounds.midX, y: creatureWorld.y - layer.position.y + bounds.midY + hop.value)
    }

    /// Volume of the catenoid of waist `w` spanning `L` between ends of
    /// radius `R`, and its shape constant.
    private static func catenoid(waist w: CGFloat, length L: CGFloat) -> (volume: CGFloat, c: CGFloat) {
        let R = endRadius, w = min(w, R * 0.999)
        let c = (L / 2) / acosh(R / w)
        return (.pi * w * w * (L / 2 + c / 2 * sinh(L / c)), c)
    }

    private func stepBridge(_ dt: CGFloat) {
        let full = max(1, hypot(cubeNow.x - rootNow.x, cubeNow.y - rootNow.y))
        let L = max(1, full - Self.creatureSize * cubeScale * 0.28)
        let restLength = max(1, neckLength - Self.creatureSize * 0.28)
        let rest = Self.catenoid(waist: Self.restWaist, length: restLength).volume
        if bridgeConnected {
            // Stretched, it draws a little more jelly from the bodies.
            let target = rest * (1 + 0.25 * max(0, L / restLength - 1))
            var lo: CGFloat = 0.05, hi = Self.endRadius * 0.99
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if Self.catenoid(waist: mid, length: L).volume < target { lo = mid } else { hi = mid }
            }
            waist = lo
            catenary = Self.catenoid(waist: waist, length: L).c
            // The cube gives up half of what the bridge took (it is about 0.72 s³).
            let cubeVolume = 0.72 * pow(Self.creatureSize, 3)
            cubeScale = cbrt(max(0.8, 1 - 0.5 * (target - rest) / cubeVolume))
            if waist < Self.pinchWaist, !Motion.reduced, !gliding {
                // Pinch: the halves spring back into their bodies.
                bridgeConnected = false
                stubRoot.value = L * 0.45
                stubCube.value = L * 0.45
                stubRoot.velocity = 0
                stubCube.velocity = 0
                creatureSquash.velocity -= 1.4
                squash.velocity += 30
            }
        } else {
            for _ in 0..<4 {
                stubRoot.step(dt / 4, frequency: 3.2, damping: 0.35, force: 0)
                stubCube.step(dt / 4, frequency: 3.4, damping: 0.35, force: 0)
            }
            // Drawn back in, a stub is gone: no motion left in it.
            if stubRoot.value <= 0 { stubRoot = Mode() }
            if stubCube.value <= 0 { stubCube = Mode() }
            cubeScale += (1 - cubeScale) * min(1, dt * 6)
            // Close enough again: they touch and merge.
            if L < restLength * 1.12 {
                bridgeConnected = true
                (stubRoot, stubCube) = (Mode(), Mode())
                creatureSquash.velocity += 0.8
            }
        }
    }

    // MARK: Face

    private func stepFace(_ dt: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let color: UIColor = tone == .needsYou ? Theme.warning : tone == .done ? Theme.success
            : tone == .recording ? Theme.failure : Theme.accent
        color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        var strength: CGFloat = tone == .idle ? 0.5 : 0.85
        if drowsy {
            // Offline: greyed toward its own luminance, and fainter.
            let grey = 0.3 * r + 0.59 * g + 0.11 * b
            (r, g, b) = (.lerp(r, grey, 0.75), .lerp(g, grey, 0.75), .lerp(b, grey, 0.75))
            strength *= 0.6
        }
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
            } else if Motion.reduced {
                // Still: it looks ahead, and only at what you do.
                hold = 10
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
        if blinkStart < 0, !Motion.reduced, time > nextBlink, happy.value < 0.3, squint.value < 0.3 {
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
        sleepy.target = drowsy ? 1 : 0
        happy.step(dt); squint.step(dt); worry.step(dt); sleepy.step(dt)
    }

    // MARK: Shape

    private var deformation: CGAffineTransform {
        let hx = max(1, bodyRect.width / 2), hy = max(1, bodyRect.height / 2)
        let breath = Motion.reduced ? 0 : 0.008 * (1 - opened) * sin(time * 2 * .pi / 4.2)
        // Area kept: as wide as it gets, it gets that much shorter.
        let wide = 1 + squash.value / hx
        _ = hy
        return CGAffineTransform(a: wide * (1 + breath), b: 0,
                                 c: -shear.value / hy, d: (1 / wide) * (1 + breath), tx: 0, ty: 0)
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

    /// The pose as the shader draws it, and the canvas it draws on (nil
    /// while there is nothing to draw).
    private func uniforms() -> (uniforms: JellyUniforms, canvas: CGRect)? {
        guard bounds.width > 1, bounds.height > 1, bodyRect.width > 1, bodyRect.height > 1 else { return nil }
        let s = Self.creatureSize
        let half = CGSize(width: bodyRect.width / 2, height: bodyRect.height / 2)
        let radius = min(cornerRadius, half.width, half.height)
        let inverse = deformation.inverted()
        let center = bodyCenter, creature = cubeNow
        let canvas = bounds.insetBy(dx: -Self.margin, dy: -Self.margin)
        let u = JellyUniforms(
            tint: SIMD4(Float(tint.r.value), Float(tint.g.value), Float(tint.b.value), Float(tint.a.value)),
            fill: fillVector,
            face: SIMD4(Float(lid * (1 - 0.55 * sleepy.value)), Float(happy.value), Float(squint.value), Float(worry.value)),
            inverse: SIMD4(Float(inverse.a), Float(inverse.b), Float(inverse.c), Float(inverse.d)),
            creature: SIMD4(Float(creature.x), Float(creature.y), Float(s), Float(neckLength)),
            pose: SIMD4(Float(yaw.value), Float(pitch.value), Float(roll.value), Float(creatureSquash.value)),
            gaze: SIMD4(Float(gazeX.value), Float(gazeY.value), Float(rootNow.x), Float(rootNow.y)),
            bridge: SIMD4(Float(waist), Float(catenary), Float(Self.endRadius), bridgeConnected ? 1 : 0),
            stubs: SIMD4(Float(stubRoot.value), Float(stubCube.value), Float(cubeScale), 0),
            center: SIMD2(Float(center.x), Float(center.y)),
            half: SIMD2(Float(half.width), Float(half.height)),
            origin: SIMD2(Float(canvas.minX), Float(canvas.minY)),
            scale: Float(metal.contentsScale), radius: Float(radius), pillow: Float(pillow),
            time: 0, churn: 0, opened: Float(opened),
            dark: traitCollection.userInterfaceStyle == .dark ? 1 : 0, mode: 0)
        return u.isFinite && canvas.width.isFinite && canvas.height.isFinite ? (u, canvas) : nil
    }

    /// The cube as the shader draws it, seen from the front: its rounded
    /// box (turned, squashed, scaled) projects to the convex hull of its
    /// inner box's corners grown by the rounding radius.
    private func cubeSilhouette(at center: CGPoint) -> CGPath {
        let s = Self.creatureSize * cubeScale, squash = creatureSquash.value
        let side = 1 / sqrt(max(0.4, 1 - squash))
        let r = s * 0.28
        let inner = SIMD3<Double>(max(0, s * 0.5 * side - r), max(0, s * 0.5 * (1 - squash) - r), max(0, s * 0.4 * side - r))
        let turn = Self.turn(yaw: yaw.value, pitch: pitch.value, roll: roll.value)
        var corners: [CGPoint] = []
        for x in [-1.0, 1.0] { for y in [-1.0, 1.0] { for z in [-1.0, 1.0] {
            let l = SIMD3<Double>(x * inner.x, s * 0.5 * squash + y * inner.y, z * inner.z)
            let p = turn * l
            corners.append(CGPoint(x: center.x + p.x, y: center.y + p.y))
        } } }
        return Self.grown(hull: Self.hull(corners), by: r)
    }

    /// The neck as the shader draws it (its axis lies in the screen's
    /// plane, so its silhouette is its radius along the axis): the catenoid,
    /// or after a pinch the two stubs.
    private func neckSilhouette(from a: CGPoint, to cube: CGPoint) -> CGPath? {
        let toward = CGPoint(x: cube.x - a.x, y: cube.y - a.y)
        let n = max(1e-4, hypot(toward.x, toward.y))
        let dir = CGPoint(x: toward.x / n, y: toward.y / n)
        let reach = Self.creatureSize * cubeScale * 0.28
        let b = CGPoint(x: cube.x - dir.x * reach, y: cube.y - dir.y * reach)
        let L = max(0.001, hypot(b.x - a.x, b.y - a.y))
        let R = Self.endRadius
        func tube(from start: CGFloat, to end: CGFloat, radius: (CGFloat) -> CGFloat) -> CGPath {
            let path = CGMutablePath()
            let count = 24
            for i in 0...count {
                let t = start + (end - start) * CGFloat(i) / CGFloat(count)
                path.addEllipse(in: CGRect(x: a.x + dir.x * t - radius(t), y: a.y + dir.y * t - radius(t),
                                           width: 2 * radius(t), height: 2 * radius(t)))
            }
            return path
        }
        if bridgeConnected {
            let c = max(0.01, catenary)
            return tube(from: 0, to: L) { min(R, self.waist * cosh(($0 - L / 2) / c)) }
        }
        var stubs: CGPath?
        let la = stubRoot.value, lb = stubCube.value
        if la > 0.3 { stubs = tube(from: 0, to: la) { .lerp(R, 2.2, $0 / la) } }
        if lb > 0.3 {
            let stub = tube(from: L - lb, to: L) { .lerp(R, 2.2, (L - $0) / lb) }
            stubs = stubs.map { $0.union(stub) } ?? stub
        }
        return stubs
    }

    /// The shader's `turn`: local cube coordinates to the screen's.
    private static func turn(yaw: CGFloat, pitch: CGFloat, roll: CGFloat) -> simd_double3x3 {
        let (cy, sy, cp, sp, cr, sr) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch), cos(roll), sin(roll))
        let ry = simd_double3x3(columns: (SIMD3(cy, 0, -sy), SIMD3(0, 1, 0), SIMD3(sy, 0, cy)))
        let rx = simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cp, sp), SIMD3(0, -sp, cp)))
        let rz = simd_double3x3(columns: (SIMD3(cr, sr, 0), SIMD3(-sr, cr, 0), SIMD3(0, 0, 1)))
        return ry * rx * rz
    }

    /// Convex hull, counter-clockwise (monotone chain).
    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A convex polygon grown by `r`: its edges pushed out, its corners arcs.
    private static func grown(hull: [CGPoint], by r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard hull.count > 1 else {
            let c = hull.first ?? .zero
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            return path
        }
        let count = hull.count
        for i in 0..<count {
            let p = hull[i], prev = hull[(i + count - 1) % count], next = hull[(i + 1) % count]
            // Outward normals of the edges into and out of this corner.
            func normal(_ a: CGPoint, _ b: CGPoint) -> CGFloat { atan2(-(b.x - a.x), b.y - a.y) }
            let from = normal(prev, p), to = normal(p, next)
            var sweep = to - from
            while sweep < 0 { sweep += 2 * .pi }
            if i == 0 { path.move(to: CGPoint(x: p.x + r * cos(from), y: p.y + r * sin(from))) }
            path.addArc(center: p, radius: r, startAngle: from, endAngle: from + sweep, clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    private var bodyCenter: CGPoint { CGPoint(x: bodyRect.midX + lagX.value, y: bodyRect.midY + lagY.value) }

    /// Draws the pose unless the screen already shows it. False when a frame
    /// was due but not presented (the background, no drawable): the tick
    /// tries again and it doesn't sleep meanwhile.
    @discardableResult
    private func draw() -> Bool {
        guard let (uniforms, canvas) = uniforms() else { return true }
        // Settled and unchanged (no blink, glance or move): nothing to draw.
        if let presented, presented.canvas == canvas, presented.uniforms.isClose(to: uniforms) { return true }
        guard !inBackground else { return false }
        var u = uniforms
        let half = CGSize(width: bodyRect.width / 2, height: bodyRect.height / 2)
        let radius = min(cornerRadius, half.width, half.height)
        let pillow = self.pillow
        let m = deformation
        let center = bodyCenter
        let creature = cubeNow

        let rest = restPath(half: half, radius: radius, pillow: pillow)
        var toBounds = m.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        let onScreen = rest.copy(using: &toBounds) ?? rest
        // The blur and the shadow follow exactly what the shader draws: the
        // body's outline, the turned and squashed cube's silhouette and the
        // neck's. One union: overlapping pieces of opposite winding would
        // cancel and punch a hole in the blur.
        var covered = onScreen.union(cubeSilhouette(at: creature))
        if let neck = neckSilhouette(from: rootNow, to: creature) { covered = covered.union(neck) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.frame = canvas
        frostMask.frame = frost.bounds
        var toCanvas = CGAffineTransform(translationX: -canvas.minX, y: -canvas.minY)
        frostMask.shape.path = covered.copy(using: &toCanvas)
        // One soft shadow in its colour.
        shadow.frame = bounds
        shadow.shadowPath = covered
        shadow.shadowColor = UIColor(red: tint.r.value, green: tint.g.value, blue: tint.b.value, alpha: 1).cgColor
        shadow.shadowOpacity = Float(.lerp(0.12 + 0.14 * tint.a.value, 0.16, opened))
        shadow.shadowRadius = .lerp(8, 18, opened)
        // Only outside the jelly: under its translucent body a shadow reads
        // as a dark blob inside it.
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -Self.margin, dy: -Self.margin))
        outside.addPath(covered)
        shadowMask.frame = bounds
        shadowMask.path = outside
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.center = CGPoint(x: bounds.midX + center.x - bodyRect.midX, y: bounds.midY + center.y - bodyRect.midY)
        let pivot = CGPoint(x: bodyRect.midX - bounds.midX, y: bodyRect.midY - bounds.midY)
        content.transform = CGAffineTransform(translationX: -pivot.x, y: -pivot.y).concatenating(m)
            .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
        var toContent = CGAffineTransform(translationX: bodyRect.midX, y: bodyRect.midY)
        contentMask.frame = content.bounds
        contentMask.path = rest.copy(using: &toContent)
        // The layer starts at the canvas and is at least as large, in steps.
        var size = metal.bounds.size
        func stepped(_ needed: CGFloat, _ now: CGFloat) -> CGFloat {
            needed > now || needed < now - 2 * Self.sizeStep ? ceil(needed / Self.sizeStep) * Self.sizeStep : now
        }
        size = CGSize(width: stepped(canvas.width, size.width), height: stepped(canvas.height, size.height))
        metal.position = canvas.origin
        if metal.bounds.size != size {
            metal.bounds = CGRect(origin: .zero, size: size)
            metal.drawableSize = CGSize(width: size.width * metal.contentsScale, height: size.height * metal.contentsScale)
        }
        let shown = render(&u, into: metal)
        CATransaction.commit()
        presented = shown ? (uniforms, canvas) : nil
        return shown
    }

    private var fillVector: SIMD4<Float> {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        fill.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(fillAmount * a))
    }

    private func render(_ u: inout JellyUniforms, into target: CAMetalLayer) -> Bool {
        #if DEBUG
        // Stress: a frame now and then finds no drawable.
        if Double.random(in: 0..<1) < debugDropRate { return false }
        #endif
        guard let pipeline = JellyRenderer.pipeline, let queue = JellyRenderer.queue else { return false }
        guard let drawable = target.nextDrawable() else {
            #if DEBUG
            debugNoDrawable += 1
            #endif
            return false
        }
        guard let commands = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<JellyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // With `presentsWithTransaction`, the drawable must be presented from
        // this thread once the GPU has the work, so it lands in this
        // transaction. (Presenting from the command buffer did so from a
        // Metal thread, outside any flushed transaction: on the phone the
        // drawables stayed held and `nextDrawable` blocked the main thread.)
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
        return true
    }
}

/// How often the jelly draws.
private enum Cadence: Equatable {
    case moving
    /// Only the breath moves: a fraction of a point a frame.
    case breathing
    /// Nothing moves; the link pauses, to resume after this long (nil: only
    /// when something touches or moves it).
    case still(after: CGFloat?)

    var paused: Bool { if case .still = self { true } else { false } }
    var rate: CAFrameRateRange? {
        switch self {
        case .moving: CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        case .breathing: CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        case .still: nil
        }
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

    var isAtRest: Bool { abs(value - target) < 0.01 && abs(velocity) < 0.05 }

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

#endif
