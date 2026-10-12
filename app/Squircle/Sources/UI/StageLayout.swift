import UIKit

/// Geometry for every place a device can stand: a cell in Home's grid, the
/// top of an app's thread list, and above a conversation's divider. Pure
/// values, so transitions interpolate between them and tests check them
/// without rendering.
struct StageLayout: Equatable {
    var size: CGSize
    var safe: UIEdgeInsets
    /// Height of one line of the app name.
    var titleHeight: CGFloat
    var reducedMotion: Bool

    static let topBarHeight: CGFloat = 52
    static let dockHeight: CGFloat = 58
    static let dividerHeight: CGFloat = 26

    // MARK: Home grid

    static let gridMargin: CGFloat = 20
    static let gridGap: CGFloat = 18
    /// The app's name beneath each device.
    static let cellCaption: CGFloat = 26

    var columns: Int { size.width > 600 ? 3 : 2 }
    var gridTop: CGFloat { safe.top + 62 }
    var cellWidth: CGFloat {
        let n = CGFloat(columns)
        return ((size.width - 2 * Self.gridMargin - Self.gridGap * (n - 1)) / n).rounded(.down)
    }
    /// Narrower than its cell, so a turned device never touches its neighbor.
    var gridPhoneHeight: CGFloat { (cellWidth * 0.82 / PhonePose.aspect).rounded() }
    var cellHeight: CGFloat { gridPhoneHeight + 12 + Self.cellCaption }
    var rowPitch: CGFloat { cellHeight + 24 }

    /// A cell in the grid's content coordinates.
    func cellFrame(_ index: Int) -> CGRect {
        let column = index % columns, row = index / columns
        return CGRect(x: Self.gridMargin + CGFloat(column) * (cellWidth + Self.gridGap),
                      y: gridTop + CGFloat(row) * rowPitch, width: cellWidth, height: cellHeight)
    }

    func gridContentHeight(count: Int) -> CGFloat {
        let rows = (max(1, count) + columns - 1) / columns
        return gridTop + CGFloat(rows) * rowPitch + max(safe.bottom, 16) + 12
    }

    /// The device in a grid cell (`cell` in view coordinates). Each column
    /// turns a little toward the middle. The pose is fixed, so a cell shows a
    /// still portrait that scrolls natively with the grid.
    func gridPose(cell: CGRect, column: Int) -> PhonePose {
        let height = gridPhoneHeight
        let center = CGPoint(x: cell.midX, y: cell.minY + height / 2)
        if reducedMotion { return PhonePose(center: center, height: height, shadow: 0.8) }
        let side: CGFloat = columns == 1 ? 0 : (CGFloat(column) / CGFloat(columns - 1)) * 2 - 1
        return PhonePose(center: center, height: height, yaw: -side * 0.14, pitch: -0.06, shadow: 0.8)
    }

    /// Where a neighbor goes while one app opens: it drifts away from the
    /// opened device, shrinks back and fades. Applied to the grid cell.
    func recede(_ cell: CGRect, from origin: CGPoint, progress p: CGFloat) -> CATransform3D {
        let p = p.clamped()
        guard p > 0, !reducedMotion else { return CATransform3DIdentity }
        let dx = cell.midX - origin.x, dy = cell.minY + gridPhoneHeight / 2 - origin.y
        let length = max(1, hypot(dx, dy))
        let push = p * p * (3 - 2 * p)
        let scale = 1 - push * 0.28
        return CATransform3DScale(CATransform3DMakeTranslation(dx / length * push * 70, dy / length * push * 70, 0),
                                  scale, scale, 1)
    }

    /// Opacity of a receding neighbor.
    func recedeAlpha(progress p: CGFloat) -> CGFloat { pow(1 - p.clamped(), 1.4) }

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
