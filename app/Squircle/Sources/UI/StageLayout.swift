import UIKit

/// Geometry for every place a device can stand. One rule holds everywhere:
/// the device fills the space above the content. On Home that space is above
/// the app's name and shrinks as its thread list scrolls up; in a thread it is
/// above the conversation's divider. Pure values, so transitions interpolate
/// between them and tests check them without rendering.
struct StageLayout: Equatable {
    var size: CGSize
    var safe: UIEdgeInsets
    /// Height of one line of the app name.
    var titleHeight: CGFloat
    var reducedMotion: Bool

    static let topBarHeight: CGFloat = 52
    static let bottomBarHeight: CGFloat = 52
    static let dockHeight: CGFloat = 58
    static let dividerHeight: CGFloat = 26

    // MARK: Home

    /// Horizontal distance between neighboring devices in the carousel.
    var phoneSpacing: CGFloat { size.width * 0.66 }
    var heroTop: CGFloat { safe.top + 14 }
    var bottomBarTop: CGFloat { size.height - max(safe.bottom, 16) - 6 - Self.bottomBarHeight }
    /// Resting top of the app name; the first thread row peeks beneath it.
    var nameTop: CGFloat { bottomBarTop - 56 - titleHeight }
    var heroHeight: CGFloat {
        min(max(160, nameTop - 34 - heroTop), size.width * 0.66 / PhonePose.aspect)
    }
    /// Device height once the list has been pulled up to its reading position.
    var listPhoneHeight: CGFloat { min(heroHeight, (size.height * 0.30).rounded()) }
    /// List offset at which the device reaches `listPhoneHeight`.
    var expandedOffset: CGFloat { max(1, nameTop - 20 - heroTop - listPhoneHeight) }
    private var minimumPhoneHeight: CGFloat { 150 }

    /// 0 = hero, 1 = list. `scroll` is the list's offset from its resting top.
    func expansion(scroll: CGFloat) -> CGFloat { (scroll / expandedOffset).clamped() }

    /// `offset` is the page distance from the centered app (negative = left).
    /// `spread` separates neighbors to a full page apart as lists expand.
    func homePose(offset: CGFloat, scroll: CGFloat = 0, spread: CGFloat = 0) -> PhonePose {
        let e = expansion(scroll: scroll)
        let nameY = nameTop - scroll
        let gap = CGFloat.lerp(34, 20, e)
        let available = nameY - gap - heroTop
        let height = min(heroHeight + max(0, -scroll) * 0.2, max(minimumPhoneHeight, available))
        let slack = max(0, available - height)
        let distance = min(abs(offset), 2.5)
        let side = offset.clamped(-1, 1)
        let center = CGPoint(x: size.width / 2 + offset * .lerp(phoneSpacing, size.width, spread.clamped()),
                             y: nameY - gap - height / 2 - slack / 2)
        let visible = abs(offset) < 2.2 && center.y + height / 2 > -40
        if reducedMotion {
            // No turning or receding: neighbors simply sit smaller beside it.
            return PhonePose(center: center, height: height * (1 - min(1, distance) * 0.14),
                             pitch: -0.06, shadow: 1 - 0.35 * min(1, distance), visible: visible)
        }
        return PhonePose(center: center, height: height, depth: distance * height * 0.40,
                         yaw: .lerp(0.10, -0.30, e) - side * 0.46, pitch: .lerp(-0.10, -0.05, e) - 0.03 * side * side,
                         roll: 0.03 * side, shadow: 1 - 0.4 * min(1, distance), visible: visible)
    }

    /// Where a released list should rest: fully hero, or at/after the reading
    /// position. Past the reading position the list scrolls freely.
    func restingOffset(current: CGFloat, projected: CGFloat, velocity: CGFloat) -> CGFloat {
        guard projected < expandedOffset else { return projected }
        if velocity > 0.2 { return expandedOffset }
        if velocity < -0.2 { return 0 }
        return current > expandedOffset * 0.4 ? expandedOffset : 0
    }

    // MARK: Thread

    var splitPhoneHeight: CGFloat { (size.height * 0.40).rounded() }
    /// Conversation-first: the device docks in the top corner, opposite the
    /// back button. There is no title bar.
    var chatDivider: CGFloat { safe.top + 4 + Self.dockHeight + 6 }
    /// Device and conversation share the screen.
    var splitDivider: CGFloat { safe.top + 8 + splitPhoneHeight + 24 }

    /// Divider position for a continuous detent: 0 chat, 1 split, 2 device.
    /// `limit` is the lowest the divider may sit (just above the composer).
    func divider(detent: CGFloat, limit: CGFloat) -> CGFloat {
        let device = max(chatDivider, limit)
        let split = min(splitDivider, device)
        if detent <= 1 { return .lerp(chatDivider, split, detent) }
        return .lerp(split, device, detent - 1)
    }

    func detent(divider y: CGFloat, limit: CGFloat) -> CGFloat {
        let device = max(chatDivider, limit)
        let split = min(splitDivider, device)
        if y <= split { return split > chatDivider ? (y - chatDivider) / (split - chatDivider) : 0 }
        return device > split ? 1 + (y - split) / (device - split) : 1
    }

    /// The device fills the region between the top of the screen and the divider.
    func threadPose(divider y: CGFloat) -> PhonePose {
        let raw = ((y - chatDivider) / 150).clamped()
        let t = raw * raw * (3 - 2 * raw)
        let top = CGFloat.lerp(safe.top + 4, safe.top + 8, t)
        let gap = CGFloat.lerp(6, 24, t)
        let region = max(40, y - gap - top)
        let height = min(region, (size.width - 40) / PhonePose.aspect)
        let dockX = size.width - 18 - Self.dockHeight * PhonePose.aspect / 2
        let center = CGPoint(x: .lerp(dockX, size.width / 2, t), y: top + region / 2)
        if reducedMotion { return PhonePose(center: center, height: height, shadow: .lerp(0.5, 0.9, t)) }
        // Facing the viewer squarely once it is large enough to touch.
        let flat = ((height - splitPhoneHeight) / 90).clamped()
        return PhonePose(center: center, height: height, yaw: .lerp(.lerp(-0.34, -0.12, t), 0, flat),
                         pitch: .lerp(-0.05, 0, flat), shadow: .lerp(0.5, 0.9, t))
    }

    /// The opened device travels between its Home and thread poses. A small
    /// lift toward the viewer gives the move weight without overshooting.
    func transitionPose(from start: PhonePose, to end: PhonePose, progress: CGFloat) -> PhonePose {
        var pose = PhonePose.interpolate(start, end, progress.clamped(-0.05, 1.05))
        if !reducedMotion { pose.depth -= sin(.pi * progress.clamped()) * min(start.height, end.height) * 0.25 }
        pose.visible = true
        return pose
    }
}
