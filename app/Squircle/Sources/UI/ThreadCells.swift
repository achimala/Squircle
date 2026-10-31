import AVFoundation
import ImageIO
import UIKit

/// Pictures decoded off the main thread straight at the size they show
/// (ImageIO thumbnailing): the full-resolution bitmap is never made.
enum Downsample {
    /// `scale(pixelSize)`: the fraction of the file's size needed; never above 1.
    static func image(_ data: Data, scale: @escaping @Sendable (CGSize) -> CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
            let fit = min(1, scale(CGSize(width: width, height: height)))
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(1, (max(width, height) * fit).rounded(.up))]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
    }
}

/// Text with a band of light sweeping across it while something is live.
final class ShimmerLabel: UIView {
    let label = UILabel()
    private let shine = UILabel()
    private let band = CAGradientLayer()
    var isShimmering = false { didSet { if isShimmering != oldValue { updateShimmer() } } }

    var text: String? {
        get { label.text }
        set { label.text = newValue; shine.text = newValue }
    }
    var font: UIFont {
        get { label.font }
        set { label.font = newValue; shine.font = newValue }
    }
    var textColor: UIColor = .secondaryLabel { didSet { label.textColor = textColor } }
    var numberOfLines: Int {
        get { label.numberOfLines }
        set { label.numberOfLines = newValue; shine.numberOfLines = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [label, shine] {
            view.adjustsFontForContentSizeCategory = true
            view.lineBreakMode = .byTruncatingTail
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }
        shine.textColor = .label
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        band.locations = [0.35, 0.5, 0.65]
        shine.layer.mask = band
        shine.isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: max(240, bounds.width * 1.6), height: bounds.height)
        CATransaction.commit()
        if isShimmering { updateShimmer() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateShimmer()
    }

    private func updateShimmer() {
        band.removeAllAnimations()
        shine.isHidden = !isShimmering
        guard isShimmering, window != nil, !Motion.reduced, bounds.width > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -band.bounds.width / 2
        sweep.toValue = bounds.width + band.bounds.width / 2
        sweep.duration = 1.5 + Double(bounds.width) / 400
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        band.position = CGPoint(x: -band.bounds.width / 2, y: bounds.height / 2)
        band.add(sweep, forKey: "shimmer")
    }
}

/// The room a row leaves above and below its content: half the gap to each
/// neighbour, set by the conversation (`ThreadViewController.halfGap`).
struct RowGap: Equatable {
    var top: CGFloat, bottom: CGFloat
    static let line = RowGap(top: Theme.Space.tight, bottom: Theme.Space.tight)
}

class TimelineCell: UITableViewCell {
    var gap = RowGap.line {
        didSet {
            guard gap != oldValue else { return }
            gapConstraints?.top.constant = gap.top
            gapConstraints?.bottom.constant = -gap.bottom
        }
    }
    private var gapConstraints: (top: NSLayoutConstraint, bottom: NSLayoutConstraint)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
    }

    /// The row's content from its top to its bottom, `gap` from each edge.
    func pinGap(_ content: UIView) -> [NSLayoutConstraint] {
        let top = content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: gap.top)
        let bottom = content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -gap.bottom)
        gapConstraints = (top, bottom)
        return [top, bottom]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Pressed feedback for tappable rows.
    func setPressed(_ pressed: Bool) {
        UIView.animate(withDuration: pressed ? 0.08 : 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.contentView.alpha = pressed ? 0.5 : 1
        }
    }
}

/// The thread's title at the top of its conversation.
final class HeaderCell: TimelineCell {
    private let title = Theme.label("", Theme.Text.title, lines: 3)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        title.accessibilityTraits = .header
        title.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(title)
        NSLayoutConstraint.activate(pinGap(title) + [
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
        accessibilityIdentifier = "thread.title"
    }

    func configure(_ text: String) { title.text = text }
}

/// Text a person or the agent wrote. Yours sits in a bubble at the trailing
/// edge, the app agent's in received bubbles at the leading one; other
/// answers fill the column; notes and thoughts are quieter.
final class MessageCell: TimelineCell {
    enum Style { case user, answer, received, note, thought, update, action, agent }
    override var gap: RowGap { didSet { if gap != oldValue { measured = nil; setNeedsLayout() } } }
    /// The app agent's paragraph: a plain fill. Made only for its rows.
    private lazy var received: UIView = {
        let view = UIView()
        view.backgroundColor = Theme.receivedFill
        view.layer.cornerRadius = Theme.Radius.large
        view.layer.cornerCurve = .continuous
        contentView.insertSubview(view, at: 0)
        hasReceived = true
        setNeedsLayout()
        return view
    }()
    private var hasReceived = false
    /// Your words sit in lightly tinted glass. Made only for your rows:
    /// glass is costly to create and most rows never show it.
    private(set) lazy var bubble: UIVisualEffectView = {
        let bubble = Theme.glassSurface(cornerRadius: Theme.Radius.large, tint: Theme.userGlass)
        contentView.insertSubview(bubble, at: 0)
        hasBubble = true
        setNeedsLayout()
        return bubble
    }()
    private var hasBubble = false
    /// What an agent sent hangs off a thin rule, like a quotation.
    private let rule = UIView()
    let text = UITextView()
    private var style = Style.answer
    private var bubbled: Bool { style == .user || style == .received }
    /// The text's frame for the last width it was laid out at, and how far
    /// a bubble reaches past it to be at least `Space.tap` tall.
    private var measured: (width: CGFloat, frame: CGRect, pad: CGFloat)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        text.isEditable = false
        text.isScrollEnabled = false
        text.backgroundColor = .clear
        text.textContainer.lineFragmentPadding = 0
        // Most rows have none; set once here, not again for every row it shows.
        text.textContainerInset = .zero
        text.adjustsFontForContentSizeCategory = true
        text.linkTextAttributes = [.foregroundColor: Theme.accent]
        rule.backgroundColor = .separator
        rule.layer.cornerRadius = 1 // a capsule: the rule is 2 wide
        [rule, text].forEach(contentView.addSubview)
    }

    /// Laid out by hand: the most common row, measured and placed without
    /// solving constraints (sizing it through Auto Layout laid its text out
    /// twice more).
    private func textFrame(width: CGFloat) -> (frame: CGRect, pad: CGFloat) {
        if let measured, measured.width == width { return (measured.frame, measured.pad) }
        let frame: CGRect
        var pad: CGFloat = 0
        let margin = Theme.Space.margin
        if bubbled {
            // A bubble hugs its text at its sender's edge (yours trailing,
            // the agent's leading), keeping `bubbleFree` clear of the other.
            let inset = Theme.Space.bubble.left + Theme.Space.bubble.right
            let available = max(0, width - Theme.Space.bubbleFree - margin - inset)
            let size = text.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude))
            let used = min(available, size.width)
            pad = max(0, Theme.Space.tap - size.height) / 2
            let x = style == .user ? width - margin - Theme.Space.bubble.right - used : margin + Theme.Space.bubble.left
            frame = CGRect(x: x, y: gap.top + pad, width: used, height: size.height)
        } else {
            // What an agent sent hangs off its rule in the glyph slot, its text where lines' text starts.
            let x = style == .agent ? Theme.Space.text : margin
            let used = max(0, width - x - margin)
            frame = CGRect(x: x, y: gap.top, width: used, height: text.sizeThatFits(CGSize(width: used, height: .greatestFiniteMagnitude)).height)
        }
        measured = (width, frame, pad)
        return (frame, pad)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize {
        let (frame, pad) = textFrame(width: targetSize.width)
        return CGSize(width: targetSize.width, height: frame.maxY + pad + gap.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (fitted, pad) = textFrame(width: contentView.bounds.width)
        var frame = fitted
        frame.size.height = max(0, contentView.bounds.height - frame.minY - pad - gap.bottom)
        text.frame = frame
        let around = frame.insetBy(dx: -Theme.Space.bubble.left, dy: -pad)
        if hasBubble { bubble.frame = around }
        if hasReceived { received.frame = around }
        rule.frame = CGRect(x: Theme.Space.margin, y: frame.minY + 2, width: 2, height: max(0, frame.height - 4))
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { measured = nil }
    }

    /// Where the last touch went down, so a row can tell its first line
    /// (an agent's message's "From …") from the rest.
    private var touch: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touch = touches.first?.location(in: contentView)
        super.touchesBegan(touches, with: event)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        touch = nil
    }
    var touchedFirstLine: Bool {
        guard let touch, text.layoutManager.numberOfGlyphs > 0 else { return false }
        let line = text.layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return touch.y < text.frame.minY + text.textContainerInset.top + line.maxY
    }

    func configure(_ message: ChatMessage, style: Style, rendered: NSAttributedString, expanded: Bool) {
        let user = style == .user
        self.style = style
        measured = nil
        // The text last, so it is laid out once, in its final container.
        let padding = Theme.Space.bubble
        text.update(\.textContainerInset, to: bubbled ? UIEdgeInsets(top: padding.top, left: 0, bottom: padding.bottom, right: 0) : .zero)
        // Reasoning reads in full; long notes and agents' messages fold until tapped.
        let folded = [.note, .action, .agent].contains(style) && !expanded
        text.textContainer.update(\.maximumNumberOfLines, to: folded ? [.action: 2, .agent: 9][style] ?? 4 : 0)
        text.textContainer.update(\.lineBreakMode, to: folded ? .byTruncatingTail : .byWordWrapping)
        text.attributedText = rendered
        // Selecting text matters for answers; quieter rows are tapped to unfold.
        text.isUserInteractionEnabled = style == .answer || style == .received || user
        if user || hasBubble { bubble.isHidden = !user }
        if style == .received || hasReceived { received.isHidden = style != .received }
        rule.isHidden = style != .agent
        setNeedsLayout()
        accessibilityIdentifier = "thread.message.\(message.role)"
    }
}

/// One thing the agent did: its symbol in the glyph slot, the step as a line.
final class StepCell: TimelineCell {
    /// The glyph slot; a ring pulses out of it while the step runs.
    private let well = UIView()
    private let icon = UIImageView()
    let title = ShimmerLabel()
    private let stats = UILabel()
    private let pulse = CAShapeLayer()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        stats.font = Theme.Text.line.tabularDigits
        stats.adjustsFontForContentSizeCategory = true
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        title.label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pulse.fillColor = nil
        pulse.lineWidth = 1.5
        well.layer.addSublayer(pulse)
        [well, title, stats].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)
        NSLayoutConstraint.activate(pinGap(title) + [
            well.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            well.widthAnchor.constraint(equalToConstant: Theme.Space.glyph), well.heightAnchor.constraint(equalToConstant: Theme.Space.glyph),
            well.centerYAnchor.constraint(equalTo: title.label.firstBaselineAnchor, constant: -5),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor), icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: Theme.Space.glyphGap),
            stats.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: Theme.Space.row),
            stats.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            stats.firstBaselineAnchor.constraint(equalTo: title.label.firstBaselineAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "thread.step"
    }

    func configure(_ step: ChatMessage) {
        let literal = step.step?.literal == true
        title.text = step.content
        title.font = literal ? Theme.Text.mono : Theme.Text.line
        title.numberOfLines = literal ? 1 : 2
        title.textColor = .secondaryLabel
        title.isShimmering = step.isStreaming
        icon.image = UIImage(systemName: step.failed ? "exclamationmark" : step.symbol.isEmpty ? "wrench.and.screwdriver" : step.symbol)
        icon.tintColor = step.failed ? Theme.failure : step.isStreaming ? Theme.working : .secondaryLabel
        let added = step.step?.added ?? 0, removed = step.step?.removed ?? 0
        let text = Theme.lineCounts(added: added, removed: removed, omittingZeros: true)
        stats.attributedText = text
        stats.isHidden = text.length == 0
        setPulsing(step.isStreaming)
        accessibilityLabel = step.content
        accessibilityValue = step.isStreaming ? "Running" : step.failed ? "Failed" : nil
    }

    func configureEarlier(count: Int, expanded: Bool) {
        title.text = expanded ? "Show fewer steps" : "\(count) earlier step\(count == 1 ? "" : "s")"
        title.font = Theme.Text.line
        title.numberOfLines = 1
        title.textColor = .secondaryLabel
        title.isShimmering = false
        icon.image = UIImage(systemName: expanded ? "chevron.up" : "ellipsis")
        icon.tintColor = .secondaryLabel
        stats.isHidden = true
        setPulsing(false)
        accessibilityLabel = title.text
        accessibilityValue = nil
        accessibilityIdentifier = "thread.earlier"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityIdentifier = "thread.step"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pulse.frame = well.bounds
        pulse.path = UIBezierPath(ovalIn: well.bounds).cgPath
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setPulsing(pulse.strokeColor != nil)
    }

    private func setPulsing(_ on: Bool) {
        pulse.removeAllAnimations()
        pulse.strokeColor = on ? Theme.working.cgColor : nil
        guard on, window != nil, !Motion.reduced else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1; grow.toValue = 1.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.3
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.add(group, forKey: "pulse")
    }
}

/// Screenshots the agent took, on the page at the small radius, in a row
/// that scrolls sideways.
final class GalleryCell: TimelineCell {
    static let height: CGFloat = 188
    var onTap: ((Shot) -> Void)?
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var shots: [Shot] = []
    private var galleryID: String?
    /// Your own pictures sit at the right, under your message.
    private var trailing = false
    private var indent = Theme.Space.margin
    private static let cache = NSCache<NSString, UIImage>()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false
        row.spacing = Theme.Space.row
        row.alignment = .center
        [scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate(pinGap(scroll) + [
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Self.height),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        accessibilityIdentifier = "thread.gallery"
    }

    /// The decoded thumbnail, once `prepare` has made it.
    static func image(for shot: Shot) -> UIImage? { cache.object(forKey: "\(shot.step):\(shot.index)" as NSString) }

    func view(for shot: Shot) -> ShotView? { row.arrangedSubviews.lazy.compactMap { $0 as? ShotView }.first { $0.shot == shot } }

    /// Scrolls sideways so `shot` shows whole.
    func reveal(_ shot: Shot) {
        guard let view = view(for: shot) else { return }
        scroll.layoutIfNeeded()
        let visible = scroll.bounds
        guard view.frame.minX < visible.minX || view.frame.maxX > visible.maxX else { return }
        let lowest = -scroll.contentInset.left
        let highest = max(lowest, scroll.contentSize.width + scroll.contentInset.right - visible.width)
        scroll.contentOffset.x = min(highest, max(lowest, view.frame.midX - visible.width / 2))
    }

    /// Decodes a loaded screenshot off the main thread, at the size it shows.
    static func prepare(_ shot: Shot) async -> UIImage? {
        if let cached = image(for: shot) { return cached }
        guard let data = StepImages.data(for: shot.step, index: shot.index) else { return nil }
        let height = Self.height
        let thumbnail = await Downsample.image(data) { 2 * height / max(1, $0.height) }
        if let thumbnail { cache.setObject(thumbnail, forKey: "\(shot.step):\(shot.index)" as NSString) }
        return thumbnail
    }

    /// Oldest to newest, resting on the newest. Only screenshots added to
    /// this same gallery while it is on screen animate in; scrolling back
    /// through history never replays them.
    func configure(_ shots: [Shot], indent: CGFloat, id: String, trailing: Bool = false) {
        self.indent = indent
        self.trailing = trailing
        scroll.contentInset = UIEdgeInsets(top: 0, left: indent, bottom: 0, right: Theme.Space.margin)
        let same = id == galleryID
        galleryID = id
        if shots != self.shots {
            let known = Set(self.shots.map { "\($0.step)#\($0.index)" })
            let animate = same && !self.shots.isEmpty && window != nil && !Motion.reduced
            self.shots = shots
            row.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for shot in shots {
                let view = ShotView(shot: shot) { [weak self] in self?.onTap?($0) }
                row.addArrangedSubview(view)
                if animate, !known.contains("\(shot.step)#\(shot.index)") {
                    view.alpha = 0
                    view.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                    UIView.animate(withDuration: 0.7, delay: 0.1, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                        view.alpha = 1
                        view.transform = .identity
                    }
                }
            }
            row.layoutIfNeeded()
            scroll.layoutIfNeeded()
            let end = max(-indent, scroll.contentSize.width + Theme.Space.margin - scroll.bounds.width)
            scroll.setContentOffset(CGPoint(x: end, y: 0), animated: animate)
        }
        for case let view as ShotView in row.arrangedSubviews { view.update() }
        alignTrailing()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignTrailing()
    }

    /// A row narrower than the cell rests against its right edge.
    private func alignTrailing() {
        guard trailing, scroll.bounds.width > 0 else { return }
        row.layoutIfNeeded()
        let width = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let left = max(indent, scroll.bounds.width - Theme.Space.margin - width)
        guard scroll.contentInset.left != left else { return }
        scroll.contentInset.left = left
        scroll.contentOffset.x = -left
    }
}

/// One screenshot at the image's own proportions, with no frame around it.
final class ShotView: UIControl {
    let shot: Shot
    private let image = UIImageView()
    private var width: NSLayoutConstraint!
    private let action: (Shot) -> Void
    /// Recordings play inline, muted and looping, inside the frame.
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    /// Only recordings have one: making it is costly, and most shots are pictures.
    private lazy var playerLayer: AVPlayerLayer = {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        image.layer.addSublayer(layer)
        return layer
    }()
    private let badge = UIImageView(image: UIImage(systemName: "play.fill"))

    init(shot: Shot, action: @escaping (Shot) -> Void) {
        self.shot = shot
        self.action = action
        super.init(frame: .zero)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerCurve = .continuous
        image.layer.cornerRadius = Theme.Radius.small
        image.backgroundColor = Theme.codeFill
        image.isUserInteractionEnabled = false
        badge.tintColor = .white
        badge.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        badge.contentMode = .center
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        badge.layer.cornerRadius = 12 // a capsule: the badge is 24 across
        badge.isHidden = !shot.video
        badge.isUserInteractionEnabled = false
        [image, badge].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        width = widthAnchor.constraint(equalToConstant: GalleryCell.height * 0.46)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: GalleryCell.height), width,
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24), badge.heightAnchor.constraint(equalToConstant: 24),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.row),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.row)
        ])
        addAction(UIAction { [weak self] _ in guard let self else { return }; Theme.selectionHaptic(); self.action(self.shot) }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        accessibilityLabel = "Screenshot: " + shot.title
        accessibilityIdentifier = "thread.media"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// True once this frame was shown before its picture arrived; only then
    /// does the picture fade in.
    private var waited = false

    /// Where the media viewer flies from and back to, what it shows there,
    /// and the clip playing in place.
    var spot: MediaSpot { MediaSpot(self, style: image.layer) }
    var picture: UIImage? { image.image }
    var inlinePlayer: AVPlayer? { player }

    func update() {
        startPlaybackIfReady()
        guard let picture = GalleryCell.image(for: shot) else { waited = true; return }
        guard image.image !== picture else { return }
        let ratio = picture.size.width / max(1, picture.size.height)
        width.constant = min(320, max(64, GalleryCell.height * ratio))
        if waited, image.image == nil, window != nil {
            UIView.transition(with: image, duration: 0.35, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.image.image = picture }
        } else {
            image.image = picture
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if shot.video { playerLayer.frame = image.bounds }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { player?.pause() } else { startPlaybackIfReady() }
    }

    private func startPlaybackIfReady() {
        guard shot.video, window != nil, !Motion.reduced else { return }
        if let player { player.play(); return }
        guard let url = StepVideos.url(for: shot.step) else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        playerLayer.player = queue
        player = queue
        queue.play()
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
            }
        }
    }
}

/// Pictures and clips the agent's text embeds, as wide as the text at their
/// own proportions. Several in a row share rows the way a photo album does:
/// phone screenshots sit side by side, a wide picture keeps a row to itself.
/// Clips play inline, muted and looping; a tap opens either full screen.
final class FigureCell: TimelineCell {
    static let maxHeight: CGFloat = 440
    static let minRowHeight: CGFloat = 190
    static let gap = Theme.Space.row
    var onTap: ((Shot) -> Void)?
    private let canvas = UIView()
    private var tiles: [FigureTile] = []
    private var height: NSLayoutConstraint!
    private var shots: [Shot] = []
    private var available: CGFloat = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(canvas)
        height = canvas.heightAnchor.constraint(equalToConstant: 200)
        height.priority = .required - 1
        NSLayoutConstraint.activate(pinGap(canvas) + [
            canvas.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            canvas.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            height
        ])
        accessibilityIdentifier = "thread.figures"
    }

    /// Each picture's frame for a row width: rows filled left to right, each
    /// as tall as fits the width, no taller than `maxHeight`, and a new row
    /// whenever adding the next would make the row shorter than
    /// `minRowHeight`. Before a size is known, a screen-shaped placeholder.
    static func layout(_ shots: [Shot], width: CGFloat) -> [CGRect] {
        let ratios = shots.map { shot in
            MediaFiles.sizes[shot.step].map { $0.width / max(1, $0.height) } ?? 16 / 10
        }
        func rowHeight(_ row: ArraySlice<CGFloat>) -> CGFloat {
            min(maxHeight, (width - gap * CGFloat(row.count - 1)) / max(0.01, row.reduce(0, +)))
        }
        var rows: [Range<Int>] = []
        var start = 0
        for index in ratios.indices.dropFirst() where rowHeight(ratios[start...index]) < minRowHeight {
            rows.append(start..<index)
            start = index
        }
        if !ratios.isEmpty { rows.append(start..<ratios.count) }
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for row in rows {
            let h = rowHeight(ratios[row])
            var x: CGFloat = 0
            for index in row {
                let w = h * ratios[index]
                frames.append(CGRect(x: x, y: y, width: w, height: h).integral)
                x += w + gap
            }
            y += h + gap
        }
        return frames
    }

    static func height(_ shots: [Shot], width: CGFloat) -> CGFloat {
        (layout(shots, width: width - 2 * Theme.Space.margin).map(\.maxY).max() ?? 0) + 2 * Theme.Space.row
    }

    /// The decoded picture, once `prepare` has made it.
    static func image(for shot: Shot) -> UIImage? { cache.object(forKey: shot.step as NSString) }

    func tile(for shot: Shot) -> FigureTile? { tiles.first { $0.shot == shot } }

    /// Decoded once off the main thread at the size it shows, not the
    /// file's full resolution.
    static func prepare(_ shot: Shot) async -> UIImage? {
        if let cached = image(for: shot) { return cached }
        guard let data = StepImages.data(for: shot.step, index: shot.index) else { return nil }
        let picture = await Downsample.image(data) { 1200 / max(1, $0.width, $0.height) }
        if let picture { cache.setObject(picture, forKey: shot.step as NSString) }
        return picture
    }
    private static let cache = NSCache<NSString, UIImage>()

    /// `failed`: the steps whose pictures couldn't be loaded.
    func configure(_ shots: [Shot], width: CGFloat, failed: Set<String> = []) {
        if shots != self.shots {
            self.shots = shots
            tiles.forEach { $0.removeFromSuperview() }
            tiles = shots.map { shot in
                let tile = FigureTile(shot: shot) { [weak self] in self?.onTap?($0) }
                canvas.addSubview(tile)
                return tile
            }
        }
        available = width - 2 * Theme.Space.margin
        height.constant = Self.layout(shots, width: available).map(\.maxY).max() ?? 0
        tiles.forEach { $0.update(failed: failed.contains($0.shot.step)) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (tile, frame) in zip(tiles, Self.layout(shots, width: canvas.bounds.width > 0 ? canvas.bounds.width : available)) {
            tile.frame = frame
        }
    }

    override func setPressed(_ pressed: Bool) {}
}

/// One picture or clip in a `FigureCell`.
final class FigureTile: UIControl {
    let shot: Shot
    private let image = UIImageView()
    /// Only recordings have one: making it is costly, and most shots are pictures.
    private lazy var playerLayer: AVPlayerLayer = {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        image.layer.addSublayer(layer)
        return layer
    }()
    private let badge = UIImageView(image: UIImage(systemName: "play.fill"))
    /// Shown instead of the picture when it couldn't be loaded.
    private let broken = UIImageView(image: UIImage(systemName: "photo.badge.exclamationmark"))
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    init(shot: Shot, action: @escaping (Shot) -> Void) {
        self.shot = shot
        super.init(frame: .zero)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = Theme.Radius.small
        backgroundColor = Theme.codeFill
        image.contentMode = .scaleAspectFill
        image.isUserInteractionEnabled = false
        badge.tintColor = .white
        badge.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        badge.contentMode = .center
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        badge.layer.cornerRadius = 12 // a capsule: the badge is 24 across
        badge.isUserInteractionEnabled = false
        badge.isHidden = !shot.video
        broken.tintColor = .tertiaryLabel
        broken.preferredSymbolConfiguration = Theme.symbol(Theme.Text.body)
        broken.contentMode = .center
        broken.isHidden = true
        addSubview(image)
        addSubview(badge)
        addSubview(broken)
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.selectionHaptic()
            action(self.shot)
        }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        accessibilityLabel = shot.video ? "Recording" : "Image"
        accessibilityIdentifier = "thread.figure"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Where the media viewer flies from and back to, what it shows there,
    /// and the clip playing in place.
    var spot: MediaSpot { MediaSpot(self) }
    var picture: UIImage? { image.image }
    var inlinePlayer: AVPlayer? { player }

    func update(failed: Bool = false) {
        broken.isHidden = !failed || image.image != nil || FigureCell.image(for: shot) != nil
        accessibilityLabel = shot.video ? "Recording" : broken.isHidden ? "Image" : "Image couldn't load"
        if let picture = FigureCell.image(for: shot), image.image !== picture {
            if window != nil, image.image == nil {
                UIView.transition(with: image, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.image.image = picture }
            } else {
                image.image = picture
            }
        }
        startPlaybackIfReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        image.frame = bounds
        broken.frame = bounds
        badge.frame = CGRect(x: bounds.maxX - 32, y: bounds.maxY - 32, width: 24, height: 24)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if shot.video { playerLayer.frame = image.bounds }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { player?.pause() } else { startPlaybackIfReady() }
    }

    private func startPlaybackIfReady() {
        guard shot.video, window != nil, !Motion.reduced else { return }
        if let player { player.play(); return }
        guard let url = StepVideos.url(for: shot.step) else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        playerLayer.player = queue
        player = queue
        queue.play()
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            }
        }
    }
}

/// What a turn changed, as a quiet line with its size; opens the diff.
final class ChangesCell: TimelineCell {
    private let icon = UIImageView(image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"))
    private let label = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private let stats = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        chevron.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        chevron.tintColor = .tertiaryLabel
        stats.font = Theme.Text.line.tabularDigits
        stats.adjustsFontForContentSizeCategory = true
        let row = UIStackView(arrangedSubviews: [icon, label, stats, chevron])
        row.spacing = Theme.Space.glyphGap
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate(pinGap(row) + [
            icon.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "thread.changes"
    }

    func configure(_ changes: TurnChanges) {
        label.text = "\(changes.files.count) file\(changes.files.count == 1 ? "" : "s")"
        stats.attributedText = Theme.lineCounts(added: changes.additions, removed: changes.deletions)
        accessibilityLabel = "Changes: \(label.text ?? ""), \(changes.additions) added, \(changes.deletions) removed"
    }
}

/// A PDF or text file the agent linked: a file row that opens the viewer.
final class DocumentCell: TimelineCell {
    let row = FileRowView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate(pinGap(row) + [
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }
}

/// A build in the conversation: what it is, where it stands, and Install.
final class BuildCell: TimelineCell {
    var onInstall: ((AppBuild) -> Void)?
    private var build: AppBuild?
    /// A plain card: the row's one control is Install.
    private let card = UIView()
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = Theme.label("", Theme.Text.body)
    private let detailLabel = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private let install: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Install"
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = Theme.onAccent
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "thread.build.install"
        return button
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.preferredSymbolConfiguration = Theme.symbol(Theme.Text.body)
        icon.contentMode = .center
        spinner.hidesWhenStopped = true
        let padding = Theme.Space.bubble
        install.configuration?.contentInsets = NSDirectionalEdgeInsets(top: padding.top, leading: padding.left, bottom: padding.bottom, trailing: padding.right)
        install.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = Theme.Text.bodyStrong; return attributes
        }
        install.setContentCompressionResistancePriority(.required, for: .horizontal)
        install.setContentHuggingPriority(.required, for: .horizontal)
        install.addAction(UIAction { [weak self] _ in
            guard let self, let build else { return }
            Theme.selectionHaptic()
            onInstall?(build)
        }, for: .touchUpInside)
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let glyph = UIView()
        [icon, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glyph.addSubview($0) }
        let row = UIStackView(arrangedSubviews: [glyph, text, install])
        row.spacing = Theme.Space.glyphGap
        row.alignment = .center
        card.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = Theme.receivedFill
        card.layer.cornerRadius = Theme.Radius.large
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        card.addSubview(row)
        NSLayoutConstraint.activate(pinGap(card) + [
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.card.top),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.card.bottom),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.card.left),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Space.card.right),
            glyph.widthAnchor.constraint(equalToConstant: Theme.Space.glyph), glyph.heightAnchor.constraint(equalToConstant: Theme.Space.glyph),
            icon.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), icon.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor)
        ])
        accessibilityIdentifier = "thread.build"
    }

    func configure(_ build: AppBuild, installing: Bool) {
        self.build = build
        titleLabel.text = build.version.isEmpty ? build.title : build.title + " " + build.version
        let detail: String
        switch build.status {
        case "queued": detail = "Queued"; icon.image = UIImage(systemName: "clock"); icon.tintColor = .secondaryLabel
        case "running": detail = "Building"; icon.image = nil
        case "succeeded": detail = "Ready to install"; icon.image = UIImage(systemName: "app.badge.checkmark"); icon.tintColor = Theme.success
        case "failed":
            detail = build.error?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Build failed"
            icon.image = UIImage(systemName: "xmark.octagon"); icon.tintColor = Theme.failure
        default: detail = BuildRow.statusText(for: build); icon.image = UIImage(systemName: "hammer"); icon.tintColor = .secondaryLabel
        }
        detailLabel.text = detail
        if build.status == "running" { spinner.startAnimating() } else { spinner.stopAnimating() }
        install.isHidden = !build.canInstall
        install.isEnabled = !installing
        install.configuration?.showsActivityIndicator = installing
        isAccessibilityElement = false
    }
}

/// A question this thread put to you, where it asked it: the question
/// card, answered in place, the same as in Waiting on you and Tasks.
final class QuestionCell: TimelineCell {
    let item = WaitingItemView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        item.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(item)
        NSLayoutConstraint.activate(pinGap(item) + [
            item.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            item.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.bubbleFree)
        ])
        accessibilityIdentifier = "thread.question"
    }

    /// Where Waiting on you took you.
    func mark() { item.mark() }

    override func setPressed(_ pressed: Bool) {}
}

/// A finished turn's work, folded into one quiet line.
final class SummaryCell: TimelineCell {
    /// The line; it pulses when the turn finishes.
    private let line = UIView()
    private let icon = UIImageView()
    private let titleLabel = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private let detailLabel = Theme.label("", Theme.Text.line, color: .tertiaryLabel)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        icon.contentMode = .center
        chevron.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        chevron.tintColor = .tertiaryLabel
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, chevron])
        row.spacing = Theme.Space.glyphGap
        row.alignment = .center
        row.isUserInteractionEnabled = false
        line.isUserInteractionEnabled = false
        [line, row].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        contentView.addSubview(line)
        line.addSubview(row)
        NSLayoutConstraint.activate(pinGap(row) + [
            // The line reaches a little past its text, for the pulse to bloom
            // around; the check still sits in the glyph slot.
            line.topAnchor.constraint(equalTo: row.topAnchor, constant: -Theme.Space.tight),
            line.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: Theme.Space.tight),
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin - Theme.Space.row),
            line.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -(Theme.Space.margin - Theme.Space.row)),
            row.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: Theme.Space.row),
            row.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -Theme.Space.row),
            icon.widthAnchor.constraint(equalToConstant: Theme.Space.glyph)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "thread.summary"
    }

    /// A soft pulse: light blooms around the line and fades as it settles.
    func celebrate() {
        guard !Motion.reduced else { return }
        let bloom = CALayer()
        bloom.frame = line.frame
        bloom.cornerRadius = line.bounds.height / 2
        bloom.cornerCurve = .continuous
        bloom.backgroundColor = Theme.success.withAlphaComponent(0.18).cgColor
        bloom.shadowColor = Theme.success.cgColor
        bloom.shadowRadius = 16
        bloom.shadowOffset = .zero
        bloom.shadowOpacity = 0
        bloom.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: line.bounds.size), cornerRadius: line.bounds.height / 2).cgPath
        bloom.opacity = 0
        contentView.layer.insertSublayer(bloom, below: line.layer)
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0, 0.75, 0]
        glow.keyTimes = [0, 0.3, 1]
        let fill = CAKeyframeAnimation(keyPath: "opacity")
        fill.values = [0, 1, 0]
        fill.keyTimes = [0, 0.25, 1]
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.12
        let pulse = CAAnimationGroup()
        pulse.animations = [glow, fill, grow]
        pulse.duration = 1.1
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { bloom.removeFromSuperlayer() }
        bloom.add(pulse, forKey: "pulse")
        CATransaction.commit()
        line.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.line.transform = .identity
        }
    }

    func configure(_ summary: TurnSummary) {
        icon.image = UIImage(systemName: "checkmark")
        icon.tintColor = .tertiaryLabel
        titleLabel.text = summary.title
        detailLabel.text = summary.detail
        chevron.transform = summary.expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        accessibilityLabel = summary.title + ", " + summary.detail
        accessibilityValue = summary.expanded ? "Expanded" : "Collapsed"
    }
}

/// A view that reports when its own size is laid out.
final class LayoutView: UIView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// What the agent is doing now, as a line of text, with the agent itself
/// beside it: the conversation's jelly, live (direction B, 2026-10-15). When
/// the agent moves on, the finished task slides up out of the line and the
/// next slides in from below.
final class LiveCell: TimelineCell {
    private let capsule = LiveCapsule()
    private var hero: JellyHero?
    private var heroLead: NSLayoutConstraint!
    private static let heroSize = Theme.Glyph.live
    /// Where the capsule starts: its mark in the glyph slot (the capsule
    /// leads it by 12) or, with the jelly there instead, its text at
    /// `Space.text` (an empty mark slot puts the text 18 in).
    private static let markLead = Theme.Space.margin - 12, jellyLead = Theme.Space.text - 18

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        capsule.isUserInteractionEnabled = false
        capsule.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(capsule)
        heroLead = capsule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.markLead)
        NSLayoutConstraint.activate(pinGap(capsule) + [
            heroLead,
            capsule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            capsule.heightAnchor.constraint(equalToConstant: Self.heroSize)
        ])
        accessibilityIdentifier = "thread.working"
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `jelly`: who is working, drawn beside the line (nil: the line's mark).
    func configure(_ status: LiveStatus, jelly: JellyLook? = nil) {
        if let jelly {
            if let hero { hero.look = jelly } else {
                let hero = JellyHero(jelly, size: Self.heroSize)
                hero.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(hero)
                NSLayoutConstraint.activate([
                    // Centred on the glyph slot, rounding over it on each side.
                    hero.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin + Theme.Space.glyph / 2),
                    hero.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
                    hero.widthAnchor.constraint(equalToConstant: Self.heroSize),
                    hero.heightAnchor.constraint(equalToConstant: Self.heroSize)
                ])
                self.hero = hero
            }
        }
        hero?.isHidden = jelly == nil
        capsule.markSlot = jelly == nil ? nil : 0
        heroLead.constant = jelly == nil ? Self.markLead : Self.jellyLead
        capsule.configure(headline: status.headline, started: status.started)
        accessibilityLabel = status.headline
    }
}

/// The live capsule: the app's mark turning while the agent works, the task
/// in shimmering text that slides vertically as tasks change, and the time
/// since the turn began. Sized by its owner; it has no surface of its own
/// (the overlay's bubble puts it on glass).
///
/// Each line is laid out at its own width (within `widthLimit`), never at
/// the capsule's current width, so a capsule whose width springs never
/// squeezes or re-truncates its text; whatever its edge cuts fades out
/// instead of being clipped mid-glyph. A task shows for at least `dwell`
/// before the next replaces it; changes in between collapse into the latest.
final class LiveCapsule: UIView {
    /// `recording`: a screen or performance recording runs; the mark is a
    /// pulsing dot in the failure colour and the time shows.
    enum Tone: Equatable { case idle, working, needsYou, done, recording }
    /// Clips the sliding lines to the capsule.
    private let track = LayoutView()
    /// Fades the track's trailing edge.
    private let edge = CAGradientLayer()
    private var line = ShimmerLabel()
    private(set) var headline: String?
    private(set) var tone = Tone.idle
    private let mark = UIView()
    private let elapsed = UILabel()
    private var started: Date?
    private var timer: Timer?
    var showsTime = true { didSet { setNeedsLayout() } }
    var font = Theme.Text.line { didSet { line.font = font; setNeedsLayout() } }
    /// The widest the owner lets the capsule get (`preferredWidth`'s limit),
    /// when it animates the capsule's width itself.
    var widthLimit: CGFloat?
    /// Called when a held-back headline shows, so the owner can resize.
    var onHeadlineChange: (() -> Void)?
    private static let dwell: TimeInterval = 1.1
    private var shownAt: Date?
    private var queued: String??
    private var flush: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        mark.backgroundColor = Theme.working
        mark.layer.cornerCurve = .continuous
        mark.layer.cornerRadius = 4.5
        elapsed.font = Theme.Text.line.tabularDigits
        elapsed.adjustsFontForContentSizeCategory = true
        elapsed.textColor = .tertiaryLabel
        track.onLayout = { [weak self] in self?.placeLines() }
        track.clipsToBounds = true
        track.layer.cornerCurve = .continuous
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        edge.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        track.layer.mask = edge
        style(line)
        [track, mark, elapsed].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func style(_ label: ShimmerLabel) {
        label.font = font
        label.textColor = textColor
        label.numberOfLines = 1
        label.isShimmering = tone == .working
        track.addSubview(label)
    }

    /// Space for something drawn in place of the mark (the overlay's
    /// jelly draws eyes there), or 0 for none; nil shows the turning mark.
    var markSlot: CGFloat? {
        didSet {
            mark.isHidden = markSlot != nil
            setNeedsLayout()
        }
    }
    /// Whether "needs you" colours the text (off where the surface shows the tone).
    var tintsText = true
    var textColor = UIColor.secondaryLabel { didSet { line.textColor = textColor } }
    /// Called as a new line rises in.
    var onLineChange: (() -> Void)?
    private var markSide: CGFloat { markSlot ?? 14 }
    private func lead(_ height: CGFloat) -> CGFloat {
        guard let markSlot else { return max(12, (height - markSide) / 2 + 1) }
        return markSlot == 0 ? 7 : (height - markSlot) / 2 - 2
    }
    private func trail(_ height: CGFloat) -> CGFloat { markSlot == nil ? lead(height) - 2 : 18 }
    private var inset: CGFloat { lead(bounds.height) }

    /// The width that shows the whole headline, within `limit`.
    func preferredWidth(limit: CGFloat, height: CGFloat) -> CGFloat {
        let lead = lead(height)
        guard let headline, !headline.isEmpty else { return height }
        let text = ceil((headline as NSString).size(withAttributes: [.font: font]).width)
        let time = showsTime && started != nil ? 52 : trail(height)
        return min(limit, lead + markSide + 11 + text + time)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        track.frame = bounds
        track.layer.cornerRadius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = track.bounds
        let width = max(1, track.bounds.width)
        edge.locations = [0, NSNumber(value: Double(max(0, width - 11) / width)), NSNumber(value: Double(max(0, width - 2) / width))]
        CATransaction.commit()
        mark.frame = CGRect(x: inset, y: (bounds.height - markSide) / 2, width: markSide, height: markSide)
        elapsed.sizeToFit()
        elapsed.isHidden = !showsTime || started == nil
        elapsed.center = CGPoint(x: bounds.width - inset - 3 - elapsed.bounds.width / 2, y: bounds.height / 2)
        placeLines()
    }

    /// Where a line rests: after the mark, as wide as its text, short of the
    /// timer (or of where it would be at `widthLimit`).
    private func restingFrame(_ label: ShimmerLabel) -> CGRect {
        let x = mark.frame.maxX + 11
        let end = elapsed.isHidden ? track.bounds.width - trail(bounds.height) : elapsed.frame.minX - 8
        var room = end - x
        if let widthLimit { room = widthLimit - (track.bounds.width - room) }
        let text = ceil(((label.text ?? "") as NSString).size(withAttributes: [.font: font]).width) + 1
        return CGRect(x: x, y: 0, width: max(0, min(text, room)), height: track.bounds.height)
    }

    /// Lines move by their transforms; their frames are only ever where they rest.
    private func placeLines() {
        for case let label as ShimmerLabel in track.subviews {
            let rest = restingFrame(label)
            label.bounds = CGRect(origin: .zero, size: rest.size)
            label.center = CGPoint(x: rest.midX, y: rest.midY)
        }
    }

    func configure(headline next: String?, started: Date?, tone: Tone = .working) {
        self.started = started
        tick()
        let toneChanged = tone != self.tone
        if toneChanged {
            self.tone = tone
            mark.backgroundColor = switch tone {
            case .needsYou: Theme.warning
            case .done: Theme.success
            case .recording: Theme.failure
            default: Theme.working
            }
            mark.layer.cornerRadius = tone == .recording ? markSide / 2 : 4.5
            line.isShimmering = tone == .working
            line.textColor = tone == .needsYou && tintsText ? Theme.warning : tone == .recording ? .label : textColor
            animateMark()
        }
        if next == headline {
            cancelQueued()
            return
        }
        // The same kind of news within `dwell` of the last waits its turn;
        // only the latest is kept.
        let wait = shownAt.map { Self.dwell - Date.now.timeIntervalSince($0) } ?? 0
        if !toneChanged, headline != nil, next != nil, wait > 0, window != nil {
            queued = .some(next)
            if flush == nil {
                flush = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    self?.showQueued()
                }
            }
            return
        }
        cancelQueued()
        show(next)
    }

    private func cancelQueued() {
        queued = nil
        flush?.cancel()
        flush = nil
    }

    private func showQueued() {
        flush = nil
        guard let next = queued else { return }
        queued = nil
        guard next != headline else { return }
        show(next)
        onHeadlineChange?()
    }

    private func show(_ next: String?) {
        headline = next
        shownAt = .now
        guard window != nil, !Motion.reduced, track.bounds.height > 0 else {
            line.text = next
            setNeedsLayout()
            return
        }
        onLineChange?()
        // The finished task rises out of the capsule and fades; the next
        // rises in from below.
        let old = line
        let fresh = ShimmerLabel()
        style(fresh)
        fresh.textColor = line.textColor
        fresh.text = next
        line = fresh
        let rest = restingFrame(fresh), travel = track.bounds.height * 0.62
        fresh.bounds = CGRect(origin: .zero, size: rest.size)
        fresh.center = CGPoint(x: rest.midX, y: rest.midY)
        fresh.transform = CGAffineTransform(translationX: 0, y: travel)
        fresh.alpha = 0
        UIView.animate(withDuration: 0.6, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            old.transform = CGAffineTransform(translationX: 0, y: -travel)
            fresh.transform = .identity
        } completion: { [weak self] _ in
            if old !== self?.line { old.removeFromSuperview() }
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
            old.alpha = 0
        }
        UIView.animate(withDuration: 0.34, delay: 0.1, options: [.allowUserInteraction, .curveEaseOut]) {
            fresh.alpha = 1
        }
    }

    private func tick() {
        guard let started else { elapsed.text = nil; return }
        let text = Elapsed.clock(Date.now.timeIntervalSince(started))
        if elapsed.text != text {
            elapsed.text = text
            setNeedsLayout()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        animateMark()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The app's mark turning between circle and squircle while work runs.
    private func animateMark() {
        mark.layer.removeAllAnimations()
        if window != nil, tone == .recording {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.3; pulse.duration = 0.8
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mark.layer.add(pulse, forKey: "recording")
            return
        }
        guard window != nil, tone == .working else { return }
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
        round.values = [4.5, 7, 4.5]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 0.75, 1]
        let group = CAAnimationGroup()
        group.animations = [turn, round, scale]
        group.duration = 1.1
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.repeatCount = .infinity
        mark.layer.add(group, forKey: "working")
    }
}

/// A table the agent wrote, in the message's own type with hairlines
/// between rows. One too wide for the screen scrolls sideways.
final class MarkdownTableCell: TimelineCell {
    private let scroll = UIScrollView()
    private let grid = MarkdownTableView()
    private var height: NSLayoutConstraint!
    private var shown: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 0, left: Theme.Space.margin, bottom: 0, right: Theme.Space.margin)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(grid)
        contentView.addSubview(scroll)
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        height.priority = .defaultHigh + 1
        NSLayoutConstraint.activate(pinGap(scroll) + [
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            height
        ])
        isAccessibilityElement = true
        accessibilityIdentifier = "thread.table"
    }

    static func height(_ layout: MarkdownTableLayout) -> CGFloat { layout.size.height + Theme.Space.tight + Theme.Space.row }

    func configure(_ layout: MarkdownTableLayout, id: String) {
        grid.layout = layout
        grid.frame = CGRect(origin: .zero, size: layout.size)
        scroll.contentSize = layout.size
        scroll.isScrollEnabled = layout.overflows
        height.constant = layout.size.height
        // A different table starts at its first column.
        if shown != id { scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: 0) }
        shown = id
        accessibilityLabel = layout.cells.map { $0.map(\.string).joined(separator: ", ") }.joined(separator: ". ")
    }

    override func setPressed(_ pressed: Bool) {}
}

/// Draws a `MarkdownTableLayout`; nothing is measured here.
final class MarkdownTableView: UIView {
    var layout: MarkdownTableLayout? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        let hairline = 1 / max(1, traitCollection.displayScale)
        var y: CGFloat = 0
        for (row, cells) in layout.cells.enumerated() {
            let height = layout.heights[row]
            defer { y += height }
            if row > 0 {
                // The header's rule is a touch stronger than the rows'.
                (row == 1 ? UIColor.separator : UIColor.separator.withAlphaComponent(0.45)).setFill()
                context.fill(CGRect(x: 0, y: y - hairline / 2, width: bounds.width, height: hairline))
            }
            guard y < rect.maxY, y + height > rect.minY else { continue }
            var x: CGFloat = 0
            for (column, cell) in cells.enumerated() {
                let width = layout.widths[column]
                cell.draw(with: CGRect(x: x, y: y + MarkdownTableLayout.padding, width: width, height: height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                x += width + MarkdownTableLayout.gap
            }
        }
    }
}
