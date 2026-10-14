import UIKit

/// Glass message field that grows with its text.
@MainActor
final class Composer: UIView, UITextViewDelegate {
    var onSend: (() -> Void)?
    var onChange: (() -> Void)?
    /// Pictures pasted or dropped into the field; nil leaves both to text.
    var onImages: (([UIImage]) -> Void)? {
        get { input.onImages }
        set { input.onImages = newValue }
    }
    let input = ComposerInput()
    /// The field is the glass; its buttons have none of their own.
    let send: UIButton = {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "arrow.up")
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = Theme.onAccent
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "thread.send"
        button.accessibilityLabel = "Send message"
        return button
    }()
    /// Adds pictures; shown once it has somewhere to get them from.
    var attachMenu: UIMenu? {
        didSet {
            attach.menu = attachMenu
            attach.showsMenuAsPrimaryAction = true
            attach.isHidden = attachMenu == nil
            inputLeading.constant = attachMenu == nil ? Self.edge : Self.edge + Self.button - 4
        }
    }
    var onRemoveAttachment: ((String) -> Void)?
    private let attach: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "plus")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "thread.attach"
        button.accessibilityLabel = "Add image"
        return button
    }()
    /// The + and send buttons' side, each centred on a one-line field as far
    /// from its edge as from the field's top and bottom.
    private static let button: CGFloat = 30
    private static let edge: CGFloat = (48 - button) / 2
    /// Pictures waiting to be sent, above the text.
    private let tray = UIScrollView()
    private let thumbs = UIStackView()
    private var shown: [String] = []
    private var trayHeight: NSLayoutConstraint!
    private var inputLeading: NSLayoutConstraint!
    /// The send arrow's point size.
    let sendSymbolSize: CGFloat = 13
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
        let side = Self.button, edge = Self.edge
        inputLeading = input.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: edge)
        NSLayoutConstraint.activate([
            attach.widthAnchor.constraint(equalToConstant: side), attach.heightAnchor.constraint(equalToConstant: side),
            send.widthAnchor.constraint(equalToConstant: side), send.heightAnchor.constraint(equalToConstant: side),
            attach.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: edge),
            attach.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -edge),
            send.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -edge),
            send.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -edge),
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

    /// Shows the pictures waiting to be sent, each with its own remove button.
    func show(_ attachments: [ImageAttachment]) {
        // A picture replaced under the same ID (a new capture) shows anew.
        let ids = attachments.map { "\($0.id)#\(ObjectIdentifier($0.thumbnail).hashValue)" }
        guard ids != shown else { return }
        let added = Set(ids).subtracting(shown)
        shown = ids
        thumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (attachment, key) in zip(attachments, ids) {
            let thumb = AttachmentThumb(attachment) { [weak self] id in
                Theme.selectionHaptic()
                self?.onRemoveAttachment?(id)
            }
            thumbs.addArrangedSubview(thumb)
            if held.contains(attachment.id) {
                // Something is flying into this slot; it shows when it lands.
                thumb.alpha = 0
            } else if added.contains(key), window != nil, !Motion.reduced {
                thumb.alpha = 0
                thumb.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) { thumb.alpha = 1; thumb.transform = .identity }
            }
        }
        trayHeight.constant = attachments.isEmpty ? 0 : 84
        onChange?()
    }

    /// Pictures whose thumbnails stay hidden: a capture is flying into them.
    var held = Set<String>() {
        didSet {
            for case let thumb as AttachmentThumb in thumbs.arrangedSubviews { thumb.alpha = held.contains(thumb.id) ? 0 : 1 }
        }
    }

    /// Where a picture's thumbnail is, or where the next one will appear.
    func thumbnailFrame(_ id: String, in view: UIView) -> CGRect {
        layoutIfNeeded()
        if let thumb = thumbs.arrangedSubviews.first(where: { ($0 as? AttachmentThumb)?.id == id }) {
            return thumb.convert(thumb.bounds, to: view)
        }
        return convert(CGRect(x: 10, y: -72, width: 48, height: 72), to: view)
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

/// The message field's text view: pasting or dropping pictures attaches them
/// (text alongside them is still inserted) instead of doing nothing.
@MainActor
final class ComposerInput: UITextView, UITextDropDelegate {
    var onImages: (([UIImage]) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textDropDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // A plain text view offers Paste only for text; a picture alone hides it.
        if action == #selector(paste(_:)), onImages != nil, UIPasteboard.general.hasImages { return isEditable }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        guard let onImages, board.hasImages else { return super.paste(sender) }
        // Item by item, so a picture's own text form (a link to it) isn't pasted too.
        let providers = board.itemProviders
        Task {
            var images: [UIImage] = [], texts: [String] = []
            for provider in providers {
                if let image = await AttachmentPicker.image(from: provider) { images.append(image) }
                else if let text = await Self.text(from: provider) { texts.append(text) }
            }
            if !texts.isEmpty { insertText(texts.joined(separator: "\n")) }
            if !images.isEmpty { onImages(images) }
        }
    }

    private nonisolated static func text(from provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        guard onImages != nil, drop.dropSession.canLoadObjects(ofClass: UIImage.self) else { return drop.suggestedProposal }
        return UITextDropProposal(operation: .copy)
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        guard let onImages else { return }
        let providers = drop.dropSession.items.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
        guard !providers.isEmpty else { return }
        Task {
            var images: [UIImage] = []
            for provider in providers { if let image = await AttachmentPicker.image(from: provider) { images.append(image) } }
            if !images.isEmpty { onImages(images) }
        }
    }
}

/// A picture in the message field, with a button that takes it out.
@MainActor
final class AttachmentThumb: UIView {
    let id: String

    init(_ attachment: ImageAttachment, remove: @escaping (String) -> Void) {
        id = attachment.id
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
