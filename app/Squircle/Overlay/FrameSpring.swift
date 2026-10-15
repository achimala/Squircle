#if SQUIRCLE_OVERLAY || DEBUG
import UIKit

/// The glass's frame as one spring: origin and size move together toward a
/// target, keep their velocity when retargeted, and can be held by a finger.
@MainActor
final class FrameSpring {
    private(set) var value = CGRect.zero
    private(set) var target = CGRect.zero
    /// Points per second for x, y, width and height.
    private var velocity: [CGFloat] = [0, 0, 0, 0]
    /// Slightly underdamped, so the glass lands with a little give.
    var parameters = SpringDriver.Parameters(response: 0.46, damping: 0.8)
    var onChange: (() -> Void)?
    var onRest: (() -> Void)?
    var isAnimating: Bool { link != nil }
    private(set) var isHeld = false
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    /// Jumps there and rests.
    func set(_ rect: CGRect) {
        stopLink()
        velocity = [0, 0, 0, 0]
        value = rect
        target = rect
        onChange?()
    }

    /// A finger holds it here.
    func hold(_ rect: CGRect) {
        isHeld = true
        set(rect)
    }

    func release() { isHeld = false }

    /// Retargets from the presented frame, keeping its momentum unless a
    /// finger's velocity is given.
    func animate(to rect: CGRect, velocity v: CGPoint? = nil, sizeVelocity: CGSize = .zero) {
        target = rect
        if let v { velocity = [v.x, v.y, sizeVelocity.width, sizeVelocity.height] }
        if Motion.reduced {
            set(rect)
            onRest?()
            return
        }
        guard link == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var dt = min(1.0 / 30.0, max(0, now - (lastTimestamp ?? (now - link.duration))))
        #if DEBUG
        dt /= SpringDriver.debugSlowMotion
        #endif
        lastTimestamp = now
        var current = [value.minX, value.minY, value.width, value.height]
        let goal = [target.minX, target.minY, target.width, target.height]
        var resting = true
        for i in 0..<4 {
            (current[i], velocity[i]) = SpringDriver.step(value: current[i], velocity: velocity[i], target: goal[i],
                                                          dt: CGFloat(dt), parameters: parameters)
            if abs(current[i] - goal[i]) > 0.2 || abs(velocity[i]) > 2 { resting = false }
        }
        if resting {
            set(target)
            onRest?()
        } else {
            value = CGRect(x: current[0], y: current[1], width: max(1, current[2]), height: max(1, current[3]))
            onChange?()
        }
    }
}
#endif
