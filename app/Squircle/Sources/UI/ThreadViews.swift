import UIKit

/// The agent's model and approval mode, as two glass capsules just above
/// the message field. Their menus are built when opened, so live updates
/// never reset a menu you are reading.
@MainActor
final class PickerBar: UIView {
    let model = PickerBar.capsule(identifier: "thread.model")
    let approvals = PickerBar.capsule(identifier: "thread.approvals")
    /// Jump to the latest message; sits at the row's trailing end.
    let jump = Theme.glassButton(symbol: "arrow.down", identifier: "thread.jump", accessibilityLabel: "Jump to latest")

    private static func capsule(identifier: String) -> UIButton {
        let button = Theme.glassButton(identifier: identifier)
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        button.configuration?.imagePadding = 6
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = Theme.font(.subheadline, 14, .semibold); return attributes
        }
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.showsMenuAsPrimaryAction = true
        return button
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        jump.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        jump.configuration?.contentInsets = .zero
        let row = UIStackView(arrangedSubviews: [model, approvals, UIView(), jump])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            model.heightAnchor.constraint(equalToConstant: 34), approvals.heightAnchor.constraint(equalToConstant: 34),
            jump.widthAnchor.constraint(equalToConstant: 34), jump.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(model name: String, mode: T3RuntimeMode) {
        if model.configuration?.title != name {
            model.configuration?.title = name
            model.configuration?.image = UIImage(systemName: "cpu")
        }
        if approvals.configuration?.title != mode.title {
            approvals.configuration?.title = mode.title
            approvals.configuration?.image = UIImage(systemName: mode.symbol)
        }
        model.accessibilityLabel = "Model, " + name
        approvals.accessibilityLabel = "Approvals, " + mode.title
    }
}

/// Glass message field that grows with its text.
@MainActor
final class Composer: UIView, UITextViewDelegate {
    var onSend: (() -> Void)?
    var onChange: (() -> Void)?
    let input = UITextView()
    let send = Theme.glassButton(symbol: "arrow.up", prominent: true, identifier: "thread.send", accessibilityLabel: "Send message")
    /// Adds pictures; shown once it has somewhere to get them from.
    var attachMenu: UIMenu? {
        didSet {
            attach.menu = attachMenu
            attach.showsMenuAsPrimaryAction = true
            attach.isHidden = attachMenu == nil
            inputLeading.constant = attachMenu == nil ? buttonEdges[0].constant : buttonEdges[0].constant + buttonSizes[0].constant + 2
        }
    }
    var onRemoveAttachment: ((String) -> Void)?
    private let attach = Theme.glassButton(symbol: "plus", identifier: "thread.attach", accessibilityLabel: "Add image")
    /// Pictures waiting to be sent, above the text.
    private let tray = UIScrollView()
    private let thumbs = UIStackView()
    private var shown: [String] = []
    private var trayHeight: NSLayoutConstraint!
    private var inputLeading: NSLayoutConstraint!
    private var buttonSizes: [NSLayoutConstraint] = []
    private var buttonEdges: [NSLayoutConstraint] = []
    /// The send arrow's point size.
    private(set) var sendSymbolSize: CGFloat = 15
    var placeholderText: String {
        get { placeholder.text ?? "" }
        set { if placeholder.text != newValue { placeholder.text = newValue } }
    }
    private let glass = Theme.glassSurface(cornerRadius: 24, interactive: true)
    /// The field's glass shares a Liquid Glass group with anything sent from
    /// it, so a new message's bubble can pinch off the field as liquid.
    let group = Theme.glassGroup(spacing: 22)
    private let placeholder = Theme.label("", Theme.font(.body, 17), color: .placeholderText)
    private var height: NSLayoutConstraint!

    var text: String {
        get { input.text ?? "" }
        set { input.text = newValue; textViewDidChange(input) }
    }

    init(placeholder text: String) {
        super.init(frame: .zero)
        placeholder.text = text
        input.font = Theme.font(.body, 17)
        input.adjustsFontForContentSizeCategory = true
        input.backgroundColor = .clear
        input.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 4)
        input.delegate = self
        input.accessibilityIdentifier = "thread.input"
        input.accessibilityLabel = "Message the coding agent"
        send.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)
        attach.isHidden = true
        tray.showsHorizontalScrollIndicator = false
        tray.alwaysBounceHorizontal = true
        tray.contentInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        thumbs.spacing = 8
        thumbs.alignment = .bottom
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        tray.addSubview(thumbs)
        glass.translatesAutoresizingMaskIntoConstraints = false
        group.translatesAutoresizingMaskIntoConstraints = false
        group.clipsToBounds = false
        group.contentView.clipsToBounds = false
        addSubview(group)
        group.contentView.addSubview(glass)
        [tray, input, placeholder, attach, send].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glass.contentView.addSubview($0) }
        height = input.heightAnchor.constraint(equalToConstant: 48)
        trayHeight = tray.heightAnchor.constraint(equalToConstant: 0)
        inputLeading = input.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6)
        buttonSizes = [attach.widthAnchor.constraint(equalToConstant: 36), attach.heightAnchor.constraint(equalToConstant: 36),
                       send.widthAnchor.constraint(equalToConstant: 36), send.heightAnchor.constraint(equalToConstant: 36)]
        buttonEdges = [attach.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
                       attach.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
                       send.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
                       send.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6)]
        NSLayoutConstraint.activate(buttonSizes + buttonEdges + [
            group.topAnchor.constraint(equalTo: topAnchor), group.bottomAnchor.constraint(equalTo: bottomAnchor),
            group.leadingAnchor.constraint(equalTo: leadingAnchor), group.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            tray.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            tray.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            tray.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            trayHeight,
            thumbs.topAnchor.constraint(equalTo: tray.contentLayoutGuide.topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: tray.contentLayoutGuide.bottomAnchor),
            thumbs.leadingAnchor.constraint(equalTo: tray.contentLayoutGuide.leadingAnchor),
            thumbs.trailingAnchor.constraint(equalTo: tray.contentLayoutGuide.trailingAnchor),
            thumbs.heightAnchor.constraint(equalTo: tray.frameLayoutGuide.heightAnchor),
            input.topAnchor.constraint(equalTo: tray.bottomAnchor),
            input.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            inputLeading,
            input.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -4),
            height,
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 17),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: send.leadingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The overlay's lighter field: its buttons lose their own glass.
    func apply(_ style: ChatStyle) {
        guard style == .light else { return }
        var plus = UIButton.Configuration.plain()
        plus.image = attach.configuration?.image
        plus.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        plus.baseForegroundColor = .secondaryLabel
        plus.contentInsets = .zero
        attach.configuration = plus
        var arrow = UIButton.Configuration.filled()
        arrow.image = send.configuration?.image
        arrow.cornerStyle = .capsule
        arrow.baseBackgroundColor = Theme.accent
        arrow.baseForegroundColor = .white
        arrow.contentInsets = .zero
        send.configuration = arrow
        // Smaller buttons, each centred on a one-line field and as far from
        // its edge as from the field's top and bottom.
        let side: CGFloat = 30, edge = (48 - side) / 2
        for constraint in buttonSizes { constraint.constant = side }
        for constraint in buttonEdges { constraint.constant = constraint.constant < 0 ? -edge : edge }
        inputLeading.constant = attachMenu == nil ? edge : edge + side - 4
        sendSymbolSize = 13
    }

    /// Shows the pictures waiting to be sent, each with its own remove button.
    func show(_ attachments: [ImageAttachment]) {
        let ids = attachments.map(\.id)
        guard ids != shown else { return }
        let added = Set(ids).subtracting(shown)
        shown = ids
        thumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            let thumb = AttachmentThumb(attachment) { [weak self] id in
                Theme.selectionHaptic()
                self?.onRemoveAttachment?(id)
            }
            thumbs.addArrangedSubview(thumb)
            if added.contains(attachment.id), window != nil, !Motion.reduced {
                thumb.alpha = 0
                thumb.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) { thumb.alpha = 1; thumb.transform = .identity }
            }
        }
        trayHeight.constant = attachments.isEmpty ? 0 : 84
        onChange?()
    }

    /// Where the first line of typed text begins, in `view`'s coordinates.
    func textOrigin(in view: UIView) -> CGPoint {
        let origin = CGPoint(x: input.textContainerInset.left + input.textContainer.lineFragmentPadding,
                             y: input.textContainerInset.top - input.contentOffset.y)
        return input.convert(origin, to: view)
    }

    /// Keeps the placeholder away while a sent message leaves the field.
    var holdsPlaceholder = false {
        didSet {
            guard holdsPlaceholder != oldValue else { return }
            placeholder.alpha = holdsPlaceholder ? 0 : 1
        }
    }

    func revealPlaceholder() {
        holdsPlaceholder = false
        placeholder.alpha = 0
        UIView.animate(withDuration: 0.25) { self.placeholder.alpha = 1 }
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        let fitted = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let next = min(140, max(48, ceil(fitted)))
        textView.isScrollEnabled = fitted > 140
        if height.constant != next { height.constant = next }
        onChange?()
    }
}

/// A picture in the message field, with a button that takes it out.
@MainActor
final class AttachmentThumb: UIView {
    init(_ attachment: ImageAttachment, remove: @escaping (String) -> Void) {
        super.init(frame: .zero)
        let image = UIImageView(image: attachment.thumbnail)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerCurve = .continuous
        image.layer.cornerRadius = 12
        image.layer.borderWidth = 1
        image.layer.borderColor = UIColor.separator.cgColor
        image.isAccessibilityElement = true
        image.accessibilityLabel = "Attached image"
        var config = UIButton.Configuration.plain()
        // A white cross on a dark disc reads over light and dark pictures alike.
        config.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor.black.withAlphaComponent(0.6)])))
        config.contentInsets = .zero
        let close = UIButton(configuration: config)
        close.layer.shadowColor = UIColor.black.cgColor
        close.layer.shadowOpacity = 0.35
        close.layer.shadowRadius = 3
        close.layer.shadowOffset = .zero
        close.accessibilityLabel = "Remove image"
        close.accessibilityIdentifier = "thread.attachment.remove"
        close.addAction(UIAction { _ in remove(attachment.id) }, for: .touchUpInside)
        [image, close].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        let ratio = attachment.thumbnail.size.width / max(1, attachment.thumbnail.size.height)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 72),
            widthAnchor.constraint(equalToConstant: min(120, max(48, 72 * ratio))),
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            close.topAnchor.constraint(equalTo: topAnchor), close.trailingAnchor.constraint(equalTo: trailingAnchor),
            close.widthAnchor.constraint(equalToConstant: 32), close.heightAnchor.constraint(equalToConstant: 32)
        ])
        accessibilityIdentifier = "thread.attachment"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A flat, full-width thread row: its title, who is working on it, and when.
@MainActor
final class ThreadRow: UIControl {
    let sessionID: String
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }
    private let titleLabel: UILabel
    private let detailLabel: UILabel
    private let dot = UIView()
    private let separator = UIView()
    private let highlight = UIView()
    private var date: Date?
    private var agent = ""
    private var phase = ChatSession.Phase.idle
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// `compact` rows fit the debug overlay's card.
    init(sessionID: String, compact: Bool = false) {
        self.sessionID = sessionID
        titleLabel = Theme.label("", compact ? Theme.font(.subheadline, 15, .semibold) : Theme.font(.headline, 17, .semibold))
        detailLabel = Theme.label("", compact ? Theme.font(.footnote, 13) : Theme.font(.subheadline, 15), color: .secondaryLabel)
        let inset: CGFloat = compact ? 9 : 13
        super.init(frame: .zero)
        accessibilityIdentifier = "thread.row"
        accessibilityValue = sessionID
        isAccessibilityElement = true
        accessibilityTraits = .button

        highlight.backgroundColor = Theme.pressedFill
        highlight.layer.cornerRadius = 18
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        dot.layer.cornerRadius = 4
        dot.isHidden = true
        titleLabel.lineBreakMode = .byTruncatingTail
        let detail = UIStackView(arrangedSubviews: [dot, detailLabel])
        detail.alignment = .center
        detail.spacing = 7
        let content = UIStackView(arrangedSubviews: [titleLabel, detail])
        content.axis = .vertical
        content.alignment = .leading
        content.spacing = compact ? 1 : 3
        separator.backgroundColor = .separator
        [highlight, content, separator].forEach {
            $0.isUserInteractionEnabled = false
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            heightAnchor.constraint(greaterThanOrEqualToConstant: compact ? 50 : 64)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, agent: String, date: Date, phase: ChatSession.Phase) {
        if titleLabel.text != title { titleLabel.text = title }
        self.date = date
        self.agent = agent
        if phase != self.phase || dot.isHidden != (phase == .idle) {
            self.phase = phase
            dot.isHidden = phase == .idle
            dot.backgroundColor = phase == .needsYou ? Theme.warning : Theme.accent
            dot.layer.removeAllAnimations()
            if phase == .working {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1; pulse.toValue = 0.25; pulse.duration = 0.8
                pulse.autoreverses = true; pulse.repeatCount = .infinity
                pulse.isRemovedOnCompletion = false
                dot.layer.add(pulse, forKey: "pulse")
            }
        }
        updateDetail()
    }

    func updateDetail() {
        let time = date.flatMap { $0.timeIntervalSince1970 > 0 ? Self.formatter.localizedString(for: $0, relativeTo: .now) : nil }
        let text: String
        switch phase {
        case .working: text = "Working"
        case .needsYou: text = "Needs you"
        case .idle: text = [agent, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if detailLabel.text != text { detailLabel.text = text }
        detailLabel.textColor = phase == .needsYou ? Theme.warning : phase == .working ? Theme.accent : .secondaryLabel
        accessibilityLabel = [titleLabel.text, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let animations = { self.highlight.alpha = self.isHighlighted ? 1 : 0 }
            if isHighlighted { animations() } else { UIView.animate(withDuration: 0.25, animations: animations) }
        }
    }
}
