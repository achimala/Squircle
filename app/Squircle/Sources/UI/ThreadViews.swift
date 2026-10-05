import UIKit

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
