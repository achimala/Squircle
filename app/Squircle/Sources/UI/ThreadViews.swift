import UIKit

/// Glass message field that grows with its text.
@MainActor
final class Composer: UIView, UITextViewDelegate {
    var onSend: (() -> Void)?
    var onChange: (() -> Void)?
    /// Pictures and videos pasted or dropped into the field; nil leaves both to text.
    var onAttachments: (([ImageAttachment]) -> Void)? {
        get { input.onAttachments }
        set { input.onAttachments = newValue }
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
            inputLeading.constant = attachMenu == nil ? Self.edge : Self.edge + Self.button - Theme.Space.tight
        }
    }
    var onRemoveAttachment: ((String) -> Void)?
    /// The message you are replying to, quoted over the text; its x cancels.
    var onCancelQuote: (() -> Void)?
    private let quoteBar = UIView()
    private let quoteRule = UIView()
    private let quoteLabel = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 2)
    private let quoteClose: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark")
        config.preferredSymbolConfigurationForImage = Theme.symbol(Theme.Text.line)
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "thread.quote.cancel"
        button.accessibilityLabel = "Cancel reply"
        return button
    }()
    private var quoteCollapsed: NSLayoutConstraint!
    private let attach: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "plus")
        config.preferredSymbolConfigurationForImage = Theme.symbol(Theme.Text.body)
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
    private static let edge: CGFloat = (field - button) / 2
    /// A one-line field's height; it is a capsule then.
    private static let field: CGFloat = 48
    /// Pictures waiting to be sent, above the text.
    private let tray = UIScrollView()
    private let thumbs = UIStackView()
    private var shown: [String] = []
    private var trayHeight: NSLayoutConstraint!
    private var inputLeading: NSLayoutConstraint!
    /// The send arrow, in the field's line size.
    let sendSymbol = Theme.symbol(Theme.Text.line)
    var placeholderText: String {
        get { placeholder.text ?? "" }
        set { if placeholder.text != newValue { placeholder.text = newValue } }
    }
    private let glass = Theme.glassSurface(cornerRadius: Composer.field / 2, interactive: true)
    /// The field's glass shares a Liquid Glass group with anything sent from
    /// it, so a new message's bubble can pinch off the field as liquid.
    let group = Theme.glassGroup(spacing: 22)
    private let placeholder = Theme.label("", Theme.Text.body, color: .placeholderText)
    private var height: NSLayoutConstraint!

    var text: String {
        get { input.text ?? "" }
        set { input.text = newValue; textViewDidChange(input) }
    }

    init(placeholder text: String) {
        super.init(frame: .zero)
        placeholder.text = text
        input.font = Theme.Text.body
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
        tray.contentInset = UIEdgeInsets(top: 0, left: Theme.Space.row, bottom: 0, right: Theme.Space.row)
        thumbs.spacing = Theme.Space.row
        thumbs.alignment = .bottom
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        tray.addSubview(thumbs)
        glass.translatesAutoresizingMaskIntoConstraints = false
        group.translatesAutoresizingMaskIntoConstraints = false
        group.clipsToBounds = false
        group.contentView.clipsToBounds = false
        addSubview(group)
        group.contentView.addSubview(glass)
        quoteRule.backgroundColor = .separator
        quoteRule.layer.cornerRadius = 1
        quoteBar.clipsToBounds = true
        quoteBar.isHidden = true
        quoteBar.accessibilityIdentifier = "thread.quote"
        quoteClose.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onCancelQuote?() }, for: .touchUpInside)
        [quoteRule, quoteLabel, quoteClose].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; quoteBar.addSubview($0) }
        [quoteBar, tray, input, placeholder, attach, send].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glass.contentView.addSubview($0) }
        height = input.heightAnchor.constraint(equalToConstant: Self.field)
        trayHeight = tray.heightAnchor.constraint(equalToConstant: 0)
        quoteCollapsed = quoteBar.heightAnchor.constraint(equalToConstant: 0)
        // Gives way to the collapsed bar.
        let quoteBottom = quoteLabel.bottomAnchor.constraint(equalTo: quoteBar.bottomAnchor)
        quoteBottom.priority = .defaultHigh
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
            quoteBar.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            quoteBar.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            quoteBar.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            quoteCollapsed,
            // The quote starts where the field's text does, under its rule.
            quoteRule.leadingAnchor.constraint(equalTo: quoteBar.leadingAnchor, constant: Self.edge + Theme.Space.rowPad),
            quoteRule.widthAnchor.constraint(equalToConstant: 2),
            quoteRule.topAnchor.constraint(equalTo: quoteLabel.topAnchor, constant: 2),
            quoteRule.bottomAnchor.constraint(equalTo: quoteLabel.bottomAnchor, constant: -2),
            quoteLabel.leadingAnchor.constraint(equalTo: quoteRule.trailingAnchor, constant: Theme.Space.row),
            quoteLabel.topAnchor.constraint(equalTo: quoteBar.topAnchor, constant: Theme.Space.rowPad),
            quoteBottom,
            quoteLabel.trailingAnchor.constraint(equalTo: quoteClose.leadingAnchor, constant: -Theme.Space.tight),
            quoteClose.trailingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: -Self.edge),
            quoteClose.centerYAnchor.constraint(equalTo: quoteLabel.centerYAnchor),
            quoteClose.widthAnchor.constraint(equalToConstant: side), quoteClose.heightAnchor.constraint(equalToConstant: side),
            tray.topAnchor.constraint(equalTo: quoteBar.bottomAnchor),
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
            input.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -Theme.Space.tight),
            height,
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 17),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: send.leadingAnchor, constant: -Theme.Space.tight),
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

    /// The words you are replying to, over the text; nil for none.
    func showQuote(_ quote: String?) {
        guard quoteLabel.text != quote || quoteBar.isHidden != (quote == nil) else { return }
        quoteLabel.text = quote
        quoteBar.isHidden = quote == nil
        quoteCollapsed.isActive = quote == nil
        quoteLabel.accessibilityLabel = quote.map { "Replying to: " + $0 }
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
        return convert(CGRect(x: Theme.Space.row, y: -72, width: 48, height: 72), to: view)
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
        let next = min(140, max(Self.field, ceil(fitted)))
        textView.isScrollEnabled = fitted > 140
        if height.constant != next { height.constant = next }
        onChange?()
    }
}

/// The message field's text view: pasting or dropping pictures or videos
/// attaches them (text alongside them is still inserted) instead of doing nothing.
@MainActor
final class ComposerInput: UITextView, UITextDropDelegate {
    var onAttachments: (([ImageAttachment]) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textDropDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // A plain text view offers Paste only for text; a picture or video alone hides it.
        // (The types alone, so asking doesn't read the pasteboard.)
        if action == #selector(paste(_:)), onAttachments != nil, AttachmentPicker.holdsMedia(UIPasteboard.general.types) { return isEditable }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        guard let onAttachments, AttachmentPicker.holdsMedia(board.types) else { return super.paste(sender) }
        // Item by item, so a picture's own text form (a link to it) isn't pasted too.
        let providers = board.itemProviders
        Task {
            var attachments: [ImageAttachment] = [], texts: [String] = []
            for provider in providers {
                if let attachment = await AttachmentPicker.attachment(from: provider) { attachments.append(attachment) }
                else if let text = await Self.text(from: provider) { texts.append(text) }
            }
            if !texts.isEmpty { insertText(texts.joined(separator: "\n")) }
            if !attachments.isEmpty { onAttachments(attachments) }
        }
    }

    private nonisolated static func text(from provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        guard onAttachments != nil, drop.dropSession.items.contains(where: { AttachmentPicker.holdsMedia($0.itemProvider.registeredTypeIdentifiers) })
        else { return drop.suggestedProposal }
        return UITextDropProposal(operation: .copy)
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        guard let onAttachments else { return }
        let providers = drop.dropSession.items.map(\.itemProvider).filter { AttachmentPicker.holdsMedia($0.registeredTypeIdentifiers) }
        guard !providers.isEmpty else { return }
        Task {
            var attachments: [ImageAttachment] = []
            for provider in providers { if let attachment = await AttachmentPicker.attachment(from: provider) { attachments.append(attachment) } }
            if !attachments.isEmpty { onAttachments(attachments) }
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
        image.layer.cornerRadius = Theme.Radius.small
        image.layer.borderWidth = 1
        image.layer.borderColor = UIColor.separator.cgColor
        image.isAccessibilityElement = true
        image.accessibilityLabel = "Attached image"
        var config = UIButton.Configuration.plain()
        // A white cross on a dark disc reads over light and dark pictures alike.
        config.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: Theme.symbol(Theme.Text.body)
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
