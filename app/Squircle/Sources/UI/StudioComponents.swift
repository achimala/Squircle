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
    private(set) var project: AppProject
    let phone: DevicePreview
    let titleLabel = Studio.label(size: 30, weight: .semibold)
    private let previewBinding: PreviewBinding
    private let model: SquircleModel

    init(model: SquircleModel, project: AppProject) {
        self.project = project; self.model = model
        phone = DevicePreview(name: project.name)
        previewBinding = PreviewBinding(phone)
        super.init(frame: .zero)
        backgroundColor = .clear
        [phone, titleLabel].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        titleLabel.textAlignment = .center; titleLabel.lineBreakMode = .byTruncatingTail
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Previous app", actionHandler: { [weak self] _ in self?.onPage?(-1); return true }),
            UIAccessibilityCustomAction(name: "Next app", actionHandler: { [weak self] _ in self?.onPage?(1); return true })
        ]
        isAccessibilityElement = true; accessibilityTraits = .button
        update(project: project)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Empty cell margins pass taps through to neighboring phones.
        let device = CGRect(x: bounds.width * 0.22, y: 0, width: bounds.width * 0.56, height: bounds.height - 85)
        return device.contains(point) || titleLabel.frame.insetBy(dx: -16, dy: -12).contains(point)
    }
    func update(project: AppProject) {
        self.project = project
        titleLabel.text = project.name; accessibilityLabel = project.name
        accessibilityValue = project.id
        previewBinding.update(model: model, project: project)
        setNeedsLayout()
    }
    func setSelected(_ selected: Bool) {
        accessibilityIdentifier = selected ? "project.hero" : "project.picker.\(project.id)"
        accessibilityTraits = selected ? [.button, .selected] : .button
    }
    func setPickerOffset(_ offset: CGFloat) {
        phone.setPickerOffset(offset)
        let distance = min(1, abs(offset))
        phone.transform = CGAffineTransform(scaleX: 1 - distance * 0.12, y: 1 - distance * 0.12)
        phone.isHidden = abs(offset) > 1.7
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        phone.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: max(150, bounds.height - 85))
        phone.center = CGPoint(x: bounds.midX, y: (bounds.height - 85) * 0.48)
        if titleLabel.superview === self {
            let available = bounds.width * 0.58 - 24
            let size = titleLabel.sizeThatFits(CGSize(width: available, height: 54))
            titleLabel.frame = CGRect(x: (bounds.width - min(size.width, available)) / 2,
                                      y: bounds.height - 65, width: min(size.width, available), height: max(40, size.height))
        }
    }
}
