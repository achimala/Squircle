import UIKit

/// One row of a conversation. Consecutive tool steps share a row so an agent's
/// work reads as one quiet block between the things it says.
enum ThreadItem: Equatable {
    case message(ChatMessage)
    case steps(id: String, steps: [ChatMessage])
    case working

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .steps(let id, _): return "steps:" + id
        case .working: return "working"
        }
    }

    static func items(messages: [ChatMessage], running: Bool) -> [ThreadItem] {
        var items: [ThreadItem] = []
        var pending: [ChatMessage] = []
        func flush() {
            guard let first = pending.first else { return }
            items.append(.steps(id: first.id, steps: pending))
            pending = []
        }
        for message in messages {
            if message.role == "tool" { pending.append(message); continue }
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            flush()
            items.append(.message(message))
        }
        flush()
        if running { items.append(.working) }
        return items
    }
}

/// Text a person or the agent wrote. The user's words sit in a tinted bubble
/// at the trailing edge; the agent's fill the column.
final class MessageCell: UITableViewCell {
    private let bubble = UIView()
    private let text = UITextView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var minimumLeading: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        bubble.layer.cornerRadius = 20
        bubble.layer.cornerCurve = .continuous
        text.isEditable = false
        text.isScrollEnabled = false
        text.backgroundColor = .clear
        text.textContainer.lineFragmentPadding = 0
        text.adjustsFontForContentSizeCategory = true
        text.linkTextAttributes = [.foregroundColor: Theme.accent]
        [bubble, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        leading = text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20)
        trailing = text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        minimumLeading = text.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 76)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            trailing,
            bubble.topAnchor.constraint(equalTo: text.topAnchor, constant: -2),
            bubble.bottomAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            bubble.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: -14),
            bubble.trailingAnchor.constraint(equalTo: text.trailingAnchor, constant: 14)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ message: ChatMessage, rendered: NSAttributedString, expanded: Bool) {
        let user = message.role == "user", thinking = message.role == "thinking"
        text.attributedText = rendered
        text.textContainerInset = user ? UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0) : .zero
        text.textContainer.maximumNumberOfLines = thinking && !expanded ? 3 : 0
        text.textContainer.lineBreakMode = thinking && !expanded ? .byTruncatingTail : .byWordWrapping
        // Selecting text matters for answers; a thought is tapped to unfold it.
        text.isUserInteractionEnabled = !thinking
        bubble.isHidden = !user
        bubble.backgroundColor = Theme.userBubble
        leading.isActive = !user
        minimumLeading.isActive = user
        trailing.constant = user ? -30 : -20
        accessibilityIdentifier = "thread.message.\(message.role)"
    }
}

/// An agent's tool calls: one line per step, the newest few visible.
final class StepsCell: UITableViewCell {
    var onSelect: ((ChatMessage) -> Void)?
    var onExpand: (() -> Void)?
    private let stack = UIStackView()
    private let rail = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        stack.axis = .vertical
        rail.backgroundColor = .separator
        rail.layer.cornerRadius = 1
        [rail, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 21),
            rail.widthAnchor.constraint(equalToConstant: 2),
            rail.topAnchor.constraint(equalTo: stack.topAnchor, constant: 6),
            rail.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let collapsedCount = 3

    func configure(_ steps: [ChatMessage], expanded: Bool) {
        let hidden = expanded || steps.count <= Self.collapsedCount + 1 ? 0 : steps.count - Self.collapsedCount
        let shown = Array(steps.dropFirst(hidden))
        var lines = stack.arrangedSubviews.compactMap { $0 as? StepLine }
        let wanted = shown.count + (hidden > 0 ? 1 : 0)
        while lines.count > wanted { let last = lines.removeLast(); stack.removeArrangedSubview(last); last.removeFromSuperview() }
        while lines.count < wanted { let line = StepLine(); stack.addArrangedSubview(line); lines.append(line) }
        var index = 0
        if hidden > 0 {
            lines[0].configure(symbol: "ellipsis", text: "\(hidden) earlier steps", running: false, failed: false, mono: false)
            lines[0].action = { [weak self] in self?.onExpand?() }
            index = 1
        }
        for step in shown {
            lines[index].configure(symbol: step.symbol.isEmpty ? "wrench.and.screwdriver" : step.symbol, text: step.content,
                                   running: step.isStreaming, failed: step.failed, mono: step.symbol == "terminal")
            lines[index].action = { [weak self] in self?.onSelect?(step) }
            index += 1
        }
    }
}

final class StepLine: UIControl {
    var action: (() -> Void)?
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = Theme.label("", Theme.font(.footnote, 13))

    init() {
        super.init(frame: .zero)
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        spinner.transform = CGAffineTransform(scaleX: 0.62, y: 0.62)
        spinner.hidesWhenStopped = true
        label.lineBreakMode = .byTruncatingTail
        [icon, spinner, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.isUserInteractionEnabled = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "thread.step"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, text: String, running: Bool, failed: Bool, mono: Bool) {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        label.text = line
        label.font = Theme.font(.footnote, mono ? 12.5 : 13, running ? .medium : .regular, monospaced: mono)
        label.textColor = failed ? Theme.failure : running ? .label : .secondaryLabel
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = failed ? Theme.failure : .tertiaryLabel
        icon.isHidden = running
        if running { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityLabel = line
        accessibilityValue = running ? "Running" : failed ? "Failed" : nil
    }

    override var isHighlighted: Bool {
        didSet { label.alpha = isHighlighted ? 0.45 : 1 }
    }
}

/// The agent is working: the app's own mark, turning between circle and squircle.
final class WorkingCell: UITableViewCell {
    private let mark = UIView()
    private let label = Theme.label("Working", Theme.font(.subheadline, 15, .medium), color: .secondaryLabel)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        mark.backgroundColor = Theme.accent
        mark.layer.cornerCurve = .continuous
        mark.layer.cornerRadius = 5
        [mark, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            mark.widthAnchor.constraint(equalToConstant: 16), mark.heightAnchor.constraint(equalToConstant: 16),
            mark.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])
        accessibilityIdentifier = "thread.working"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        animate()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        animate()
    }

    func animate() {
        mark.layer.removeAllAnimations()
        guard window != nil else { return }
        if Motion.reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0.35; fade.duration = 0.9
            fade.autoreverses = true; fade.repeatCount = .infinity
            mark.layer.add(fade, forKey: "working")
            return
        }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = CGFloat.pi / 2
        let round = CAKeyframeAnimation(keyPath: "cornerRadius")
        round.values = [5, 8, 5]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 0.78, 1]
        let group = CAAnimationGroup()
        group.animations = [turn, round, scale]
        group.duration = 1.1
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.repeatCount = .infinity
        mark.layer.add(group, forKey: "working")
    }
}

/// Glass message field that grows with its text.
@MainActor
final class Composer: UIView, UITextViewDelegate {
    var onSend: (() -> Void)?
    var onChange: (() -> Void)?
    let input = UITextView()
    let send = Theme.glassButton(symbol: "arrow.up", prominent: true, identifier: "thread.send", accessibilityLabel: "Send message")
    private let glass = Theme.glassSurface(cornerRadius: 24, interactive: true)
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
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        [input, placeholder, send].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glass.contentView.addSubview($0) }
        height = input.heightAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            input.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            input.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            input.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
            input.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -4),
            height,
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 17),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: send.leadingAnchor, constant: -4),
            send.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
            send.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
            send.widthAnchor.constraint(equalToConstant: 36), send.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        let fitted = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let next = min(140, max(48, ceil(fitted)))
        textView.isScrollEnabled = fitted > 140
        if height.constant != next { height.constant = next }
        onChange?()
    }
}

/// Covers the device in a thread. While the simulator is live and large enough
/// to use, raw touches go to it; otherwise the device itself is a handle.
@MainActor
final class DeviceTouchView: UIView {
    /// Returns false when the touch is not for the simulator.
    var onTouch: ((_ phase: String, _ point: CGPoint) -> Bool)?
    private var tracking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "simulator.surface"
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func forward(_ touches: Set<UITouch>, _ phase: String) {
        guard let touch = touches.first, let superview else { return }
        if phase == "begin" { tracking = onTouch?(phase, touch.location(in: superview)) ?? false }
        else if tracking { _ = onTouch?(phase, touch.location(in: superview)) }
        if phase == "end" { tracking = false }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "begin") }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "move") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "end") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, "end") }
}

/// A flat, full-width thread row: its title, who is working on it, and when.
@MainActor
final class ThreadRow: UIControl {
    let sessionID: String
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }
    private let titleLabel = Theme.label("", Theme.font(.headline, 17, .semibold))
    private let detailLabel = Theme.label("", Theme.font(.subheadline, 15), color: .secondaryLabel)
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

    init(sessionID: String) {
        self.sessionID = sessionID
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
        content.spacing = 3
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
            content.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
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

/// Lays its subviews out left to right at their natural size, wrapping onto
/// new lines, so every choice stays on screen.
final class FlowView: UIView {
    var spacing: CGFloat = 8 { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    private var measuredHeight: CGFloat = 0

    private func frames(for width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        return subviews.map { view in
            let size = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let w = min(size.width, width)
            if x > 0, x + w > width { x = 0; y += line + spacing; line = 0 }
            defer { x += w + spacing; line = max(line, size.height) }
            return CGRect(x: x, y: y, width: w, height: size.height)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = frames(for: bounds.width)
        zip(subviews, frames).forEach { $0.frame = $1 }
        let height = frames.map(\.maxY).max() ?? 0
        if height != measuredHeight { measuredHeight = height; invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight) }
    override func didAddSubview(_ subview: UIView) { super.didAddSubview(subview); setNeedsLayout() }
}
