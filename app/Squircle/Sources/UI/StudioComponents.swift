import UIKit

// Shared visual primitives. Motion belongs to explicit, interruptible animators;
// these views never run an idle animation or rebuild themselves on a chat delta.
enum Studio {
    static let canvas = UIColor(red: 0.974, green: 0.964, blue: 0.945, alpha: 1)
    static let ink = UIColor(red: 0.075, green: 0.082, blue: 0.085, alpha: 1)
    static let muted = UIColor(red: 0.49, green: 0.50, blue: 0.54, alpha: 1)
    static let accent = UIColor(red: 0.43, green: 0.44, blue: 0.87, alpha: 1)
    static let lilac = UIColor(red: 0.925, green: 0.914, blue: 0.974, alpha: 1)
    static let line = UIColor.black.withAlphaComponent(0.065)

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }
    static func label(_ text: String = "", size: CGFloat = 16, weight: UIFont.Weight = .regular, color: UIColor = ink) -> UILabel {
        let label = UILabel()
        label.text = text; label.font = font(size, weight); label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        return label
    }
    static func spring(_ duration: TimeInterval = 0.65, damping: CGFloat = 0.88, _ changes: @escaping () -> Void) -> UIViewPropertyAnimator {
        let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0.18 : duration, dampingRatio: damping, animations: changes)
        animator.startAnimation()
        return animator
    }
    static func glass() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            return effect
        }
        return UIBlurEffect(style: .systemThinMaterialLight)
    }
    static func haptic() { UISelectionFeedbackGenerator().selectionChanged() }
}

final class GlassButton: UIButton {
    private let glass = UIVisualEffectView(effect: Studio.glass())
    init(symbol: String, label: String, diameter: CGFloat = 48) {
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        glass.isUserInteractionEnabled = false; glass.clipsToBounds = true
        insertSubview(glass, at: 0)
        setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal)
        tintColor = Studio.ink
        accessibilityLabel = label
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds; glass.layer.cornerRadius = bounds.height / 2
        sendSubviewToBack(glass)
    }
    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.18) { self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity } }
    }
}

final class AppGlyphView: UIView {
    private let mark = CAShapeLayer()
    private let dot = CAShapeLayer()
    var isProbe = false { didSet { setNeedsLayout() } }
    var filled = true { didSet { setNeedsLayout() } }
    var ink: UIColor = Studio.ink { didSet { setNeedsLayout() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false
        layer.addSublayer(mark); layer.addSublayer(dot)
    }
    convenience init(probe: Bool = false) { self.init(frame: .zero); isProbe = probe }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let s = min(bounds.width, bounds.height)
        backgroundColor = filled ? UIColor(red: 0.79, green: 0.74, blue: 0.99, alpha: 1) : .clear
        layer.cornerRadius = s * 0.28; layer.cornerCurve = .continuous
        mark.frame = bounds; mark.fillColor = UIColor.clear.cgColor; mark.strokeColor = ink.cgColor
        mark.lineWidth = s * 0.058; mark.lineCap = .round; mark.lineJoin = .round
        if isProbe {
            let p = UIBezierPath(); p.move(to: CGPoint(x: s * 0.2, y: s * 0.55))
            for (x,y) in [(0.32,0.55),(0.40,0.30),(0.49,0.74),(0.60,0.40),(0.67,0.55),(0.79,0.55)] { p.addLine(to: CGPoint(x: s*x, y: s*y)) }
            mark.path = p.cgPath; dot.path = nil
        } else {
            let box = CGRect(x: s * 0.26, y: s * 0.29, width: s * 0.47, height: s * 0.47)
            let path = UIBezierPath(roundedRect: box, cornerRadius: s * 0.105)
            path.apply(CGAffineTransform(translationX: -s/2, y: -s/2))
            path.apply(CGAffineTransform(rotationAngle: -.pi / 16))
            path.apply(CGAffineTransform(translationX: s/2, y: s/2))
            mark.path = path.cgPath
            dot.path = UIBezierPath(ovalIn: CGRect(x: s * 0.705, y: s * 0.22, width: s * 0.096, height: s * 0.096)).cgPath
            dot.fillColor = ink.cgColor
        }
    }
}

final class ProjectHero: UIControl {
    var onPage: ((Int) -> Void)?
    let project: AppProject
    let phone: DevicePreview
    private let previewBinding: PreviewBinding
    private let model: SquircleModel
    private let titleLabel = Studio.label(size: 31, weight: .semibold)
    private let subtitleLabel = Studio.label(size: 14, color: Studio.muted)
    private let indexLabel = Studio.label("01", size: 12, color: Studio.muted)
    private let previous = UIButton(type: .system)
    private let nextPage = UIButton(type: .system)
    private let arrow = UIImageView(image: UIImage(systemName: "arrow.up.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .light)))
    init(model: SquircleModel, project: AppProject, build: AppBuild?) {
        self.project = project; self.model = model
        phone = DevicePreview(name: project.name, probe: project.name.localizedCaseInsensitiveContains("probe"))
        previewBinding = PreviewBinding(phone)
        super.init(frame: .zero)
        backgroundColor = .clear
        titleLabel.text = project.name
        update(build: build)
        arrow.tintColor = Studio.ink
        [phone,titleLabel,subtitleLabel,indexLabel,arrow].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        for (button, symbol, direction) in [(previous, "chevron.left", -1), (nextPage, "chevron.right", 1)] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .light)), for: .normal)
            button.tintColor = Studio.ink
            button.addAction(UIAction { [weak self] _ in Studio.haptic(); self?.onPage?(direction) }, for: .touchUpInside)
            addSubview(button)
        }
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Previous app", actionHandler: { [weak self] _ in self?.onPage?(-1); return true }), UIAccessibilityCustomAction(name: "Next app", actionHandler: { [weak self] _ in self?.onPage?(1); return true })]
        isAccessibilityElement = true; accessibilityLabel = "\(project.name), \(build?.version ?? "No builds yet")"
        accessibilityTraits = .button; accessibilityIdentifier = "project.hero"
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(build: AppBuild?) {
        previewBinding.update(model: model, project: project)
        let version = build?.version.split(separator: " ").first.map(String.init) ?? ""
        subtitleLabel.text = build.map { $0.canInstall ? "\(version) · Ready to install" : $0.status.capitalized } ?? "Start with an idea"
        accessibilityLabel = "\(project.name), \(build?.version ?? "No builds yet")"
    }
    func setPosition(_ index: Int, count: Int) {
        indexLabel.text = String(format: "%02d / %02d", index, count)
        previous.isHidden = count < 2; nextPage.isHidden = count < 2
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        indexLabel.frame = CGRect(x: 0, y: 9, width: 70, height: 18)
        previous.frame = CGRect(x: bounds.width-98, y: 0, width: 44, height: 44)
        nextPage.frame = CGRect(x: bounds.width-44, y: 0, width: 44, height: 44)
        phone.bounds = CGRect(x: 0, y: 0, width: bounds.width-24, height: bounds.height-118)
        phone.center = CGPoint(x: bounds.midX, y: 19 + (bounds.height-118)/2)
        titleLabel.frame = CGRect(x: 0, y: bounds.height-75, width: bounds.width-45, height: 40)
        subtitleLabel.frame = CGRect(x: 1, y: bounds.height-28, width: bounds.width-40, height: 21)
        arrow.frame = CGRect(x: bounds.width-26, y: bounds.height-61, width: 26, height: 26)
    }
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.phone.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.975, y: 0.975) : .identity
            }
        }
    }
}
