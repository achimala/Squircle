import UIKit

/// One visual language for every screen, the design deck's tokens
/// (docs/design/README.md, approved 2026-10-31): six text roles, a 4-point
/// grid, a 20-point glyph slot, three radii and the Pearl colours. Nothing
/// outside these ships.
enum Theme {
    // MARK: Pearl (user-chosen, 2026-10-31): ink controls, violet work.

    /// What you can tap: near-black ink, near-white in dark.
    static let accent = hex(0x1C1D22, 0xF2F2F5)
    /// Text and symbols on an accent fill (the send button, Install).
    static let onAccent = hex(0xFFFFFF, 0x0E0F12)
    /// Every page's backdrop, sheets included.
    static let paper = hex(0xF5F5F2, 0x0E0F12)
    /// An agent at work: its jelly, the "working" word.
    static let working = hex(0x6E56F0, 0x9C8CFF)
    /// Something waits on you (needs you).
    static let warning = hex(0xD08A00, 0xFFC24D)
    /// Finished, ready to try.
    static let success = hex(0x2F9461, 0x5FD38E)
    /// Failed, stopped.
    static let failure = hex(0xD33A3A, 0xFF6B6B)
    /// An idle jelly.
    static let idle = hex(0x8E8E95, 0x7A7A82)
    /// The agent's bubbles and the question card: a plain fill, not glass.
    static let receivedFill = hex(0xE9E9E6, 0x1E1F24)
    /// Tint for your messages' glass bubbles: a breath of violet.
    static let userGlass = UIColor { working.resolvedColor(with: $0).withAlphaComponent($0.userInterfaceStyle == .dark ? 0.26 : 0.14) }
    static let codeFill = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.09) : UIColor(white: 0, alpha: 0.055)
    }
    static let pressedFill = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.045)
    }

    private static func hex(_ light: UInt32, _ dark: UInt32) -> UIColor {
        func color(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        let l = color(light), d = color(dark)
        return UIColor { $0.userInterfaceStyle == .dark ? d : l }
    }

    // MARK: Type: six roles, all scaling with Dynamic Type. Nothing else.

    enum Text {
        /// A page's one heading.
        static var title: UIFont { font(.title2, 22, .bold) }
        /// What people and agents say; row titles, fields, buttons.
        static var body: UIFont { font(.body, 17) }
        /// A button's title.
        static var bodyStrong: UIFont { font(.body, 17, .semibold) }
        /// Everything the agent did as one line; a row's second line.
        static var line: UIFont { font(.subheadline, 15) }
        /// A line's verb or name; app names on Home.
        static var lineStrong: UIFont { font(.subheadline, 15, .semibold) }
        /// Section labels, who asks, counts, tags.
        static var caption: UIFont { font(.footnote, 13, .semibold) }
        /// Commands, paths and code.
        static var mono: UIFont { font(.footnote, 13, monospaced: true) }
        /// Mono, semibold: a figure in a mono line that leads it.
        static var monoStrong: UIFont { font(.footnote, 13, .semibold, monospaced: true) }

        private static func font(_ style: UIFont.TextStyle, _ size: CGFloat, _ weight: UIFont.Weight = .regular,
                                 monospaced: Bool = false) -> UIFont {
            let font = monospaced ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
                : UIFont.systemFont(ofSize: size, weight: weight)
            return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
        }
    }

    /// An SF Symbol drawn in a text role's own size and weight.
    static func symbol(_ font: UIFont) -> UIImage.SymbolConfiguration { UIImage.SymbolConfiguration(font: font) }

    // MARK: Space: a 4-point grid.

    enum Space {
        /// Between bubbles from the same sender; between nested lines.
        static let tight: CGFloat = 4
        /// Between lines, between rows in a list, between pictures.
        static let row: CGFloat = 8
        /// A list row's padding above and below.
        static let rowPad: CGFloat = 12
        /// Between a bubble and a line, a card or media.
        static let group: CGFloat = 16
        /// From each screen edge.
        static let margin: CGFloat = 20
        /// Above a section label; before your message.
        static let section: CGFloat = 24
        /// The glyph slot, the gap after it, and where a line's text starts.
        static let glyph: CGFloat = 20, glyphGap: CGFloat = 8
        static let text: CGFloat = margin + glyph + glyphGap
        /// One nesting level: a slot and its gap.
        static let indent: CGFloat = glyph + glyphGap
        static let bubble = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        /// The question card and the build card.
        static let card = UIEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        /// A bubble's free side: it never comes closer to the far edge.
        static let bubbleFree: CGFloat = 56
        /// The smallest thing you can tap, and a one-line bubble's height.
        static let tap: CGFloat = 44
    }

    /// Jelly sizes: in lines and rows, the app agent's live line, and Home.
    enum Glyph {
        static let line: CGFloat = 20, live: CGFloat = 28, home: CGFloat = 26
    }

    /// A thread's preview, portrait at the device's ratio: at the right of a
    /// nested thread line, and of a thread row on a work item's page.
    enum Thumb {
        static let row = CGSize(width: 24, height: 52), page = CGSize(width: 56, height: 120)
        static let rowRadius: CGFloat = 6
    }

    /// Three radii: small things, bubbles and cards, and capsules
    /// (`cornerStyle = .capsule`, or half the height).
    enum Radius {
        /// Media, code, thumbnails.
        static let small: CGFloat = 8
        /// Bubbles, cards, fields, sheets' inner surfaces.
        static let large: CGFloat = 18
    }

    /// App names: plain SF, like the rest of the interface (the user rejected
    /// both SF Rounded and New York here).
    static func appCaptionFont() -> UIFont { Text.lineStrong }

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
        config.imagePadding = Space.row
        if let title {
            config.title = title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Text.bodyStrong
                return attributes
            }
            config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: Space.group, bottom: 11, trailing: Space.group)
        } else {
            // 11 around a 22-point line: the 44-point control.
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
    static func glassGroup(spacing: CGFloat = Space.rowPad) -> UIVisualEffectView {
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
    private static let light = UIImpactFeedbackGenerator(style: .light)
    /// A swiped message reaching the point where letting go replies to it.
    static func lightHaptic() { light.impactOccurred() }
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

extension UIFont {
    /// The same font with figures of one width, for counts and clocks that
    /// change in place.
    var tabularDigits: UIFont {
        let feature: [UIFontDescriptor.FeatureKey: Int] = [.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector]
        return UIFont(descriptor: fontDescriptor.addingAttributes([.featureSettings: [feature]]), size: 0)
    }
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
        ring.values = [0, 2, 2, 0]
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
