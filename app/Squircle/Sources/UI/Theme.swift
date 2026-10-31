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
    private static let tick = UIImpactFeedbackGenerator(style: .rigid)
    /// A firm tick for checking something off.
    static func checkHaptic() { tick.impactOccurred(intensity: 0.8) }
}

enum Motion {
    /// The system setting, plus a DEBUG-only launch argument used by UI tests.
    #if DEBUG
    /// Verification only: overrides the setting (the overlay's jelly stress).
    nonisolated(unsafe) static var debugReduced: Bool?
    #endif

    static var reduced: Bool {
        #if DEBUG
        if let debugReduced { return debugReduced }
        if ProcessInfo.processInfo.arguments.contains("--reduce-motion") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }
}

extension Theme {
    /// "+12 −3" in the success and failure colours; `omittingZeros` leaves out a zero count.
    static func lineCounts(added: Int, removed: Int, omittingZeros: Bool = false) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if added > 0 || !omittingZeros { text.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: success])) }
        if removed > 0 || !omittingZeros {
            text.append(NSAttributedString(string: (text.length > 0 ? " " : "") + "−\(removed)", attributes: [.foregroundColor: failure]))
        }
        return text
    }
    /// "5 min. ago", for rows that say when something happened.
    @MainActor static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

extension CGFloat {
    func clamped(_ lower: CGFloat = 0, _ upper: CGFloat = 1) -> CGFloat { Swift.min(upper, Swift.max(lower, self)) }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

extension CGRect {
    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: .lerp(a.minX, b.minX, t), y: .lerp(a.minY, b.minY, t),
               width: .lerp(a.width, b.width, t), height: .lerp(a.height, b.height, t))
    }
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

extension NSObjectProtocol {
    /// Sets a property only when it differs: UIKit does real work for
    /// `isHidden`, `alpha` and `transform` even when they don't change
    /// (it walks the subtree), and transitions set them every frame.
    @inline(__always)
    func update<Value: Equatable>(_ property: ReferenceWritableKeyPath<Self, Value>, to value: Value) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }
}

extension CALayer {
    /// Where Waiting on you took you: an accent ring that fades as the card
    /// gives a small nod. Animations only, so touches pass as ever.
    func markSpot(in traits: UITraitCollection) {
        borderColor = Theme.accent.resolvedColor(with: traits).cgColor
        let ring = CAKeyframeAnimation(keyPath: "borderWidth")
        ring.values = [0, 2.5, 2.5, 0]
        ring.keyTimes = [0, 0.12, 0.55, 1]
        ring.duration = 1.8
        add(ring, forKey: "mark")
        guard !Motion.reduced else { return }
        let nod = CASpringAnimation(keyPath: "transform.scale")
        nod.fromValue = 0.96
        nod.toValue = 1
        nod.damping = 9
        nod.stiffness = 170
        nod.duration = nod.settlingDuration
        add(nod, forKey: "nod")
    }
}
