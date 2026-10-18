import UIKit

/// Geometry of Home's grid of devices and how it falls back when an app
/// opens. Pure values, derived from the screen.
struct StageLayout: Equatable {
    var size: CGSize
    var safe: UIEdgeInsets
    var reducedMotion: Bool


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
}
