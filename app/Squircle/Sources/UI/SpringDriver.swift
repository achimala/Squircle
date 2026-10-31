import UIKit

/// One progress value shared by UIKit and SceneKit. A finger can take it over
/// at any frame and release it with velocity; nothing has to finish first.
@MainActor
final class SpringDriver {
    struct Parameters: Equatable {
        var response: CGFloat
        var damping: CGFloat
        static let navigation = Parameters(response: 0.50, damping: 0.86)
    }

    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat
    var parameters = Parameters.navigation
    /// Called for every presented value, including interactive updates.
    var onChange: ((CGFloat) -> Void)?
    /// Called once when an animation settles exactly on its target.
    var onRest: ((CGFloat) -> Void)?
    var isAnimating: Bool { link != nil }

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var tween: (from: CGFloat, start: CFTimeInterval?, duration: CFTimeInterval)?

    init(value: CGFloat = 0) {
        self.value = value
        target = value
    }

    /// Interactive scrubbing; cancels any animation without a jump.
    func set(_ newValue: CGFloat) {
        stopLink()
        tween = nil
        velocity = 0
        value = newValue
        target = newValue
        onChange?(value)
    }

    /// Retargets from the current presented value and velocity.
    func animate(to newTarget: CGFloat, initialVelocity: CGFloat? = nil) {
        target = newTarget
        if let initialVelocity { velocity = initialVelocity }
        tween = Motion.reduced ? (from: value, start: nil, duration: 0.24) : nil
        if abs(value - target) < 0.0005, abs(velocity) < 0.01, tween == nil {
            settle()
            return
        }
        startLink()
    }

    /// A tap changing direction: momentum that opposes the new target is
    /// dropped, so the move turns at once instead of drifting on first.
    func redirect(to newTarget: CGFloat) {
        let opposing = (newTarget - value) * velocity < 0
        animate(to: newTarget, initialVelocity: opposing ? 0 : velocity)
    }

    func stop() {
        stopLink()
        tween = nil
        velocity = 0
        target = value
    }

    private func startLink() {
        guard link == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] link in
            // Let go mid-animation: its link stops with it.
            guard let self else { link.invalidate(); JellyDirector.shared.springs -= 1; return }
            tick(link)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = Motion.displayRange
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
        JellyDirector.shared.springs += 1
    }

    private func stopLink() {
        if link != nil { JellyDirector.shared.springs -= 1 }
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        let rested = resting; resting.removeAll()
        rested.forEach { $0.resume() }
    }

    private var resting: [CheckedContinuation<Void, Never>] = []
    /// Returns once nothing animates it: settled, set by a finger or stopped.
    func rest() async {
        guard isAnimating else { return }
        await withCheckedContinuation { resting.append($0) }
    }

    #if DEBUG
    /// Verification only: slows every spring for frame-by-frame review.
    nonisolated(unsafe) static var debugSlowMotion: Double = 1
    #endif

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var dt = min(1.0 / 30.0, max(0, now - (lastTimestamp ?? (now - link.duration))))
        #if DEBUG
        dt /= Self.debugSlowMotion
        #endif
        lastTimestamp = now
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        if var tween {
            let start = tween.start ?? now - dt
            tween.start = start
            self.tween = tween
            let t = CGFloat(min(1, (now - start) / tween.duration))
            let eased = 1 - pow(1 - t, 3)
            value = tween.from + (target - tween.from) * eased
            velocity = 0
            onChange?(value)
            if t >= 1 { settle() }
        } else {
            (value, velocity) = Self.step(value: value, velocity: velocity, target: target, dt: CGFloat(dt), parameters: parameters)
            if abs(value - target) < 0.0005, abs(velocity) < 0.01 { settle() }
            else { onChange?(value) }
        }
        #if DEBUG
        MotionAudit.shared.work((CACurrentMediaTime() - started) * 1000)
        #endif
    }

    private func settle() {
        stopLink()
        tween = nil
        value = target
        velocity = 0
        onChange?(value)
        onRest?(value)
    }

    /// Damped harmonic oscillator, unit mass, integrated in small fixed steps.
    nonisolated static func step(value: CGFloat, velocity: CGFloat, target: CGFloat, dt: CGFloat,
                                 parameters: Parameters) -> (CGFloat, CGFloat) {
        let stiffness = pow(2 * .pi / max(0.05, parameters.response), 2)
        let damping = 4 * .pi * parameters.damping / max(0.05, parameters.response)
        var x = value, v = velocity
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 480.0)
            let acceleration = -stiffness * (x - target) - damping * v
            v += acceleration * h
            x += v * h
            remaining -= h
        }
        return (x, v)
    }
}

/// CADisplayLink retains its target; this keeps the owner releasable.
final class DisplayLinkProxy: NSObject {
    private let handler: @MainActor (CADisplayLink) -> Void
    init(_ handler: @escaping @MainActor (CADisplayLink) -> Void) { self.handler = handler }
    @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { handler(link) } }
}

/// `await DisplayFrame.next()` resumes on the display's next frame, after
/// everything this frame committed is on screen. One shared display link runs
/// only while something is waiting.
@MainActor
enum DisplayFrame {
    private static var waiting: [CheckedContinuation<Void, Never>] = []
    private static var link: CADisplayLink?

    static func next() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard link == nil else { return }
            let link = CADisplayLink(target: DisplayLinkProxy { _ in DisplayFrame.tick() }, selector: #selector(DisplayLinkProxy.tick(_:)))
            link.preferredFrameRateRange = Motion.displayRange
            link.add(to: .main, forMode: .common)
            Self.link = link
        }
    }

    private static func tick() {
        link?.invalidate()
        link = nil
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}
