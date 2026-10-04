import UIKit

/// Geometry for both places a device can stand: the gallery and the top of an
/// app's workspace. Pure values, so transitions can interpolate between them
/// and tests can check them without rendering.
struct StageLayout: Equatable {
    var size: CGSize
    var safe: UIEdgeInsets
    /// Height of the app-name label beneath the gallery device.
    var titleHeight: CGFloat
    var reducedMotion: Bool

    static let topBarHeight: CGFloat = 52
    static let pageControlHeight: CGFloat = 36

    var pitch: CGFloat { max(1, size.width * 0.66) }

    // MARK: Gallery

    private var galleryTop: CGFloat { safe.top + Self.topBarHeight + 14 }
    private var galleryBottom: CGFloat { size.height - safe.bottom - Self.pageControlHeight - 14 - titleHeight - 22 }

    var galleryPhoneHeight: CGFloat {
        let available = max(140, galleryBottom - galleryTop)
        return min(available, size.width * 0.60 / PhonePose.aspect)
    }

    var galleryPhoneCenterY: CGFloat { galleryTop + max(140, galleryBottom - galleryTop) / 2 }

    /// Title center relative to the device in the gallery.
    var galleryTitleCenterY: CGFloat { galleryPhoneCenterY + galleryPhoneHeight / 2 + 22 + titleHeight / 2 }

    /// `offset` is the page distance from the centered app (negative = left).
    func galleryPose(offset: CGFloat) -> PhonePose {
        let height = galleryPhoneHeight
        let distance = min(abs(offset), 2.5)
        let side = offset.clamped(-1, 1)
        let center = CGPoint(x: size.width / 2 + offset * pitch, y: galleryPhoneCenterY)
        let visible = abs(offset) < 2.2
        if reducedMotion {
            // No turning or receding: neighbors simply sit smaller beside it.
            return PhonePose(center: center, height: height * (1 - min(1, distance) * 0.14),
                             pitch: -0.06, shadow: 1 - 0.35 * min(1, distance), visible: visible)
        }
        return PhonePose(center: center, height: height, depth: distance * height * 0.40,
                         yaw: 0.08 - side * 0.46, pitch: -0.12 - 0.03 * side * side, roll: 0.03 * side,
                         shadow: 1 - 0.4 * min(1, distance), visible: visible)
    }

    // MARK: Workspace

    var workspacePhoneHeight: CGFloat { min(size.height * 0.30, 280) }
    var workspacePhoneTop: CGFloat { safe.top + Self.topBarHeight + 12 }

    /// `scroll` is the workspace list's offset from its resting top.
    func workspacePose(scroll: CGFloat) -> PhonePose {
        let stretch = max(0, -scroll)
        let height = workspacePhoneHeight + stretch * 0.30
        let top = workspacePhoneTop - scroll - stretch * 0.30
        let center = CGPoint(x: size.width / 2, y: top + height / 2)
        let visible = top + height > -40
        if reducedMotion {
            return PhonePose(center: center, height: height, pitch: -0.06, shadow: 0.8, visible: visible)
        }
        return PhonePose(center: center, height: height, yaw: -0.30, pitch: -0.05, roll: 0, shadow: 0.8, visible: visible)
    }

    /// The opened device travels from gallery to workspace. A small lift
    /// toward the viewer gives the move weight without overshooting.
    func transitionPose(galleryOffset: CGFloat, scroll: CGFloat, progress: CGFloat) -> PhonePose {
        let start = galleryPose(offset: galleryOffset)
        let end = workspacePose(scroll: scroll)
        var pose = PhonePose.interpolate(start, end, progress.clamped(-0.05, 1.05))
        if !reducedMotion { pose.depth -= sin(.pi * progress.clamped()) * start.height * 0.12 }
        pose.visible = true
        return pose
    }

    /// Unselected devices part to the sides while an app opens.
    func neighborPose(offset: CGFloat, progress: CGFloat) -> PhonePose {
        let direction: CGFloat = offset < 0 ? -1 : 1
        return galleryPose(offset: offset + direction * progress.clamped() * 1.5)
    }

    /// Nearest page for a scroll offset, clamped to the catalog.
    func page(for offsetX: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, Int((offsetX / pitch).rounded())))
    }

    /// Paging decision at the end of a drag: a deliberate flick always moves
    /// at least one app; otherwise the nearest app wins.
    func targetPage(currentX: CGFloat, projectedX: CGFloat, velocityX: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let position = currentX / pitch
        var index = Int((projectedX / pitch).rounded())
        if velocityX > 0.25 { index = max(index, Int(floor(position)) + 1) }
        else if velocityX < -0.25 { index = min(index, Int(ceil(position)) - 1) }
        else { index = Int(position.rounded()) }
        return max(0, min(count - 1, index))
    }
}
