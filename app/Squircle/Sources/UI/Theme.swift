import UIKit

/// One visual language for every screen: a lit studio backdrop for the real
/// devices, system text colors for content, and Liquid Glass only on controls.
enum Theme {
    /// Terracotta on warm cream (user-chosen "Clay", 2026-10-14).
    static let accent = dynamic(rgb(0.71, 0.33, 0.20), rgb(0.94, 0.56, 0.41))
    /// Text and symbols on an accent fill (the send button, Install).
    static let onAccent = dynamic(.white, rgb(0.20, 0.08, 0.03))
    /// The page behind conversations and lists that are not on the stage.
    static let paper = dynamic(rgb(0.972, 0.957, 0.933), rgb(0.078, 0.070, 0.064))
    /// Tint for your messages' glass bubbles.
    static let userGlass = dynamic(rgb(0.78, 0.44, 0.28, 0.14), rgb(0.86, 0.50, 0.34, 0.24))
    static let codeFill = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.09) : UIColor(white: 0, alpha: 0.055)
    }
    static let pressedFill = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.045)
    }
    /// The studio light behind a device, tinted by its app's own colors.
    static func glow(for color: UIColor, dark: Bool) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return dark ? UIColor(hue: h, saturation: min(0.85, s * 1.1), brightness: 0.62, alpha: 0.50)
                    : UIColor(hue: h, saturation: min(0.55, s * 0.8), brightness: 1, alpha: 0.85)
    }

    /// Saturation-weighted mean of an image: the color an app is known by.
    /// Nil for monochrome captures, which keep the neutral studio light.
    nonisolated static func characteristicColor(of image: UIImage) -> UIColor? {
        guard let source = image.cgImage else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[index]) / 255, pg = Double(pixels[index + 1]) / 255, pb = Double(pixels[index + 2]) / 255
            let high = max(pr, pg, pb), low = min(pr, pg, pb)
            let weight = (high - low) * (high - low)
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total / Double(side * side) > 0.004 else { return nil }
        return UIColor(red: r / total, green: g / total, blue: b / total, alpha: 1)
    }

    /// Olive, ochre and crimson, apart from the terracotta accent.
    static let success = dynamic(rgb(0.36, 0.53, 0.24), rgb(0.60, 0.78, 0.44))
    static let warning = dynamic(rgb(0.72, 0.55, 0.06), rgb(0.95, 0.78, 0.34))
    static let failure = dynamic(rgb(0.74, 0.13, 0.24), rgb(1.0, 0.44, 0.52))

    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Dynamic Type aware; `rounded` is reserved for app names.
    static func font(_ style: UIFont.TextStyle, _ size: CGFloat, _ weight: UIFont.Weight = .regular,
                     monospaced: Bool = false) -> UIFont {
        let font = monospaced ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    /// App names: plain SF, like the rest of the interface (the user rejected
    /// both SF Rounded and New York here).
    static func appNameFont() -> UIFont { font(.largeTitle, 34, .bold) }
    static func appCaptionFont() -> UIFont { font(.headline, 15, .semibold) }

    static func label(_ text: String = "", _ font: UIFont, color: UIColor = .label, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    /// Native Liquid Glass buttons (iOS 26+), with a tinted material fallback.
    static func glassButton(symbol: String? = nil, title: String? = nil, prominent: Bool = false,
                            identifier: String? = nil, accessibilityLabel: String? = nil) -> UIButton {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = prominent ? .prominentGlass() : .glass()
        } else {
            config = prominent ? .filled() : .tinted()
            config.cornerStyle = .capsule
        }
        config.image = symbol.flatMap { UIImage(systemName: $0) }
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        config.imagePadding = 7
        if let title {
            config.title = title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Theme.font(.body, 17, .semibold)
                return attributes
            }
            config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 18)
        } else {
            config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
        }
        if !prominent { config.baseForegroundColor = .label }
        let button = UIButton(configuration: config)
        button.tintColor = prominent ? accent : .label
        button.accessibilityIdentifier = identifier
        if let accessibilityLabel { button.accessibilityLabel = accessibilityLabel }
        return button
    }

    /// Glass surface for grouped interactive content (approvals, composer).
    /// `clear` is the more transparent glass, for lensing text seen through it;
    /// `tint` colours the glass itself.
    static func glassSurface(cornerRadius: CGFloat, interactive: Bool = false, clear: Bool = false,
                             tint: UIColor? = nil) -> UIVisualEffectView {
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: clear ? .clear : .regular)
            effect.isInteractive = interactive
            effect.tintColor = tint
            view = UIVisualEffectView(effect: effect)
            view.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
        } else {
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            view.layer.cornerRadius = cornerRadius
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
        }
        return view
    }

    /// The glass material itself, for materializing a surface in an animation.
    static func glassEffect(interactive: Bool = false) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = interactive
            return effect
        }
        return UIBlurEffect(style: .systemThinMaterial)
    }

    /// Rounds a glass surface made by `glassSurface` to a new radius.
    static func setGlassCorner(_ view: UIVisualEffectView, radius: CGFloat) {
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .corners(radius: .fixed(radius))
        } else {
            view.layer.cornerRadius = radius
        }
    }

    /// Lets adjacent glass shapes blend and morph as one native group.
    static func glassGroup(spacing: CGFloat = 12) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassContainerEffect()
            effect.spacing = spacing
            return UIVisualEffectView(effect: effect)
        }
        return UIVisualEffectView(effect: nil)
    }

    private static let selection = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .soft)
    static func selectionHaptic() { selection.selectionChanged() }
    static func openHaptic() { impact.impactOccurred(intensity: 0.7) }
}

enum Motion {
    /// The system setting, plus a DEBUG-only launch argument used by UI tests.
    static var reduced: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reduce-motion") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }
}

extension CGFloat {
    func clamped(_ lower: CGFloat = 0, _ upper: CGFloat = 1) -> CGFloat { Swift.min(upper, Swift.max(lower, self)) }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

extension UIView {
    /// Layout owns bounds and center; transitions own the transform.
    func place(in frame: CGRect) {
        let size = frame.size
        if bounds.size != size { bounds = CGRect(origin: .zero, size: size) }
        center = CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// Short display names for thread titles created as "App · Topic".
extension ChatSession {
    func displayTitle(in project: AppProject) -> String {
        let prefix = project.name + " · "
        return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }
}
