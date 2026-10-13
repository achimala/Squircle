#if SQUIRCLE_OVERLAY || DEBUG
import UIKit

/// The host app as it looks under the overlay, for the message field.
@MainActor
enum HostCapture {
    static let attachmentID = "overlay.capture"

    /// The scene's windows below the overlay, as they were last drawn.
    static func image(below overlay: UIWindow) -> UIImage? {
        guard let scene = overlay.windowScene else { return nil }
        let windows = scene.windows
            .filter { $0 !== overlay && !$0.isHidden && $0.alpha > 0 && $0.windowLevel < overlay.windowLevel }
            .sorted { $0.windowLevel < $1.windowLevel }
        guard !windows.isEmpty else { return nil }
        let bounds = scene.screen.bounds
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            for window in windows { window.drawHierarchy(in: window.frame, afterScreenUpdates: false) }
        }
    }

    /// Puts the capture in the message field, replacing an earlier one.
    static func attach(below overlay: UIWindow, to model: SquircleModel) {
        guard let image = image(below: overlay), let attachment = ImageAttachment(image, id: attachmentID) else { return }
        model.attach(attachment)
    }
}
#endif
