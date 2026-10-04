import UIKit

/// One visual language for every screen: a lit studio backdrop for the real
/// devices, system text colors for content, and Liquid Glass only on controls.
enum Theme {
    static let accent = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.60, green: 0.62, blue: 1.0, alpha: 1)
            : UIColor(red: 0.33, green: 0.35, blue: 0.84, alpha: 1)
    }
    /// The page behind conversations and lists that are not on the stage.
    static let paper = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.067, green: 0.067, blue: 0.074, alpha: 1)
            : UIColor(red: 0.973, green: 0.966, blue: 0.953, alpha: 1)
    }
    static let backdropTop = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.115, green: 0.115, blue: 0.128, alpha: 1)
            : UIColor(red: 0.984, green: 0.978, blue: 0.968, alpha: 1)
    }
    static let backdropBottom = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.032, green: 0.032, blue: 0.038, alpha: 1)
            : UIColor(red: 0.900, green: 0.890, blue: 0.872, alpha: 1)
    }
    static let backdropGlow = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.30, blue: 0.36, alpha: 0.55)
            : UIColor(white: 1, alpha: 0.95)
    }
    static let userBubble = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.20, green: 0.21, blue: 0.30, alpha: 1)
            : UIColor(red: 0.905, green: 0.905, blue: 0.965, alpha: 1)
    }
    static let codeFill = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.09) : UIColor(white: 0, alpha: 0.055)
    }
    static let pressedFill = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.045)
    }
    static let success = UIColor.systemGreen
    static let warning = UIColor.systemOrange
    static let failure = UIColor.systemRed

    /// Dynamic Type aware; `rounded` is reserved for app names.
    static func font(_ style: UIFont.TextStyle, _ size: CGFloat, _ weight: UIFont.Weight = .regular,
                     rounded: Bool = false, monospaced: Bool = false) -> UIFont {
        var font = monospaced ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    static func appNameFont() -> UIFont { font(.largeTitle, 34, .bold, rounded: true) }

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
    static func glassSurface(cornerRadius: CGFloat, interactive: Bool = false) -> UIVisualEffectView {
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = interactive
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
