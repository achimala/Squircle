import AVFoundation
import UIKit

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

class TimelineCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
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
    private let title = Theme.label("", Theme.font(.title2, 24, .bold), lines: 3)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        title.accessibilityTraits = .header
        title.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            title.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
        accessibilityIdentifier = "thread.title"
    }

    func configure(_ text: String) { title.text = text }
}

/// Text a person or the agent wrote. Yours sits in a bubble at the trailing
/// edge; the answer fills the column; notes and thoughts are quieter.
final class MessageCell: TimelineCell {
    enum Style { case user, answer, note, thought }
    let bubble = UIView()
    let text = UITextView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var minimumLeading: NSLayoutConstraint!
    private var top: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        bubble.layer.cornerRadius = 21
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
        top = text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
        NSLayoutConstraint.activate([
            top,
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            trailing,
            bubble.topAnchor.constraint(equalTo: text.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: text.bottomAnchor),
            bubble.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: -15),
            bubble.trailingAnchor.constraint(equalTo: text.trailingAnchor, constant: 15)
        ])
    }

    func configure(_ message: ChatMessage, style: Style, rendered: NSAttributedString, expanded: Bool) {
        let user = style == .user
        text.attributedText = rendered
        text.textContainerInset = user ? UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0) : .zero
        let folded = (style == .thought || style == .note) && !expanded
        text.textContainer.maximumNumberOfLines = folded ? (style == .thought ? 2 : 4) : 0
        text.textContainer.lineBreakMode = folded ? .byTruncatingTail : .byWordWrapping
        // Selecting text matters for answers; quieter rows are tapped to unfold.
        text.isUserInteractionEnabled = style == .answer || style == .user
        bubble.isHidden = !user
        bubble.backgroundColor = Theme.userBubble
        leading.isActive = !user
        minimumLeading.isActive = user
        trailing.constant = user ? -35 : -20
        top.constant = user ? 14 : style == .answer ? 10 : 6
        accessibilityIdentifier = "thread.message.\(message.role)"
    }
}

/// One thing the agent did, on a rail joining the steps around it.
final class StepCell: TimelineCell {
    private let well = UIView()
    private let icon = UIImageView()
    private let railUp = UIView()
    private let railDown = UIView()
    let title = ShimmerLabel()
    private let stats = UILabel()
    private let pulse = CAShapeLayer()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        well.layer.cornerRadius = 12
        well.layer.cornerCurve = .continuous
        well.backgroundColor = .tertiarySystemFill
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        [railUp, railDown].forEach { $0.backgroundColor = .quaternaryLabel }
        stats.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        title.label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pulse.fillColor = nil
        pulse.lineWidth = 1.5
        well.layer.addSublayer(pulse)
        [railUp, railDown, well, title, stats].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            well.widthAnchor.constraint(equalToConstant: 24), well.heightAnchor.constraint(equalToConstant: 24),
            well.centerYAnchor.constraint(equalTo: title.label.firstBaselineAnchor, constant: -5),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor), icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            railUp.centerXAnchor.constraint(equalTo: well.centerXAnchor), railUp.widthAnchor.constraint(equalToConstant: 1.5),
            railUp.topAnchor.constraint(equalTo: contentView.topAnchor), railUp.bottomAnchor.constraint(equalTo: well.topAnchor, constant: -3),
            railDown.centerXAnchor.constraint(equalTo: well.centerXAnchor), railDown.widthAnchor.constraint(equalToConstant: 1.5),
            railDown.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 3), railDown.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            title.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            title.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stats.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            stats.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stats.firstBaselineAnchor.constraint(equalTo: title.label.firstBaselineAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "thread.step"
    }

    func configure(_ step: ChatMessage, first: Bool, last: Bool) {
        let literal = step.step?.literal == true
        title.text = step.content
        title.font = literal ? Theme.font(.footnote, 13, .regular, monospaced: true) : Theme.font(.subheadline, 15)
        title.numberOfLines = literal ? 1 : 2
        title.textColor = .secondaryLabel
        title.isShimmering = step.isStreaming
        icon.image = UIImage(systemName: step.failed ? "exclamationmark" : step.symbol.isEmpty ? "wrench.and.screwdriver" : step.symbol)
        icon.tintColor = step.failed ? Theme.failure : step.isStreaming ? Theme.accent : .secondaryLabel
        well.backgroundColor = step.isStreaming ? Theme.accent.withAlphaComponent(0.14) : .tertiarySystemFill
        railUp.isHidden = first
        railDown.isHidden = last
        let added = step.step?.added ?? 0, removed = step.step?.removed ?? 0
        let text = NSMutableAttributedString()
        if added > 0 { text.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: Theme.success])) }
        if removed > 0 { text.append(NSAttributedString(string: (added > 0 ? " " : "") + "−\(removed)", attributes: [.foregroundColor: Theme.failure])) }
        stats.attributedText = text
        stats.isHidden = text.length == 0
        setPulsing(step.isStreaming)
        accessibilityLabel = step.content
        accessibilityValue = step.isStreaming ? "Running" : step.failed ? "Failed" : nil
    }

    func configureEarlier(count: Int, expanded: Bool) {
        title.text = expanded ? "Show fewer steps" : "\(count) earlier step\(count == 1 ? "" : "s")"
        title.font = Theme.font(.subheadline, 15, .medium)
        title.numberOfLines = 1
        title.textColor = .secondaryLabel
        title.isShimmering = false
        icon.image = UIImage(systemName: expanded ? "chevron.up" : "ellipsis")
        icon.tintColor = .secondaryLabel
        well.backgroundColor = .tertiarySystemFill
        railUp.isHidden = true
        railDown.isHidden = true
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
        pulse.path = UIBezierPath(roundedRect: well.bounds, cornerRadius: 12).cgPath
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setPulsing(pulse.strokeColor != nil)
    }

    private func setPulsing(_ on: Bool) {
        pulse.removeAllAnimations()
        pulse.strokeColor = on ? Theme.accent.cgColor : nil
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

/// Screenshots the agent took, framed like the device they came from, in a
/// row that scrolls sideways.
final class GalleryCell: TimelineCell {
    static let height: CGFloat = 188
    var onTap: ((Shot) -> Void)?
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var shots: [Shot] = []
    private var galleryID: String?
    private static let cache = NSCache<NSString, UIImage>()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false
        row.spacing = 12
        row.alignment = .center
        [scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
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

    static func image(for shot: Shot) -> UIImage? {
        let key = "\(shot.step):\(shot.index)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = StepImages.data(for: shot.step, index: shot.index), let image = UIImage(data: data) else { return nil }
        let scale = 2 * height / max(1, image.size.height)
        let thumbnail = image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
        cache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    /// Oldest to newest, resting on the newest. Only screenshots added to
    /// this same gallery while it is on screen animate in; scrolling back
    /// through history never replays them.
    func configure(_ shots: [Shot], indent: CGFloat, id: String) {
        scroll.contentInset = UIEdgeInsets(top: 0, left: indent, bottom: 0, right: 20)
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
            let end = max(-indent, scroll.contentSize.width + 20 - scroll.bounds.width)
            scroll.setContentOffset(CGPoint(x: end, y: 0), animated: animate)
        }
        for case let view as ShotView in row.arrangedSubviews { view.update() }
    }
}

/// One framed screenshot; its frame takes the image's own proportions.
final class ShotView: UIControl {
    let shot: Shot
    private let image = UIImageView()
    private let shadow = UIView()
    private var width: NSLayoutConstraint!
    private let action: (Shot) -> Void
    /// Recordings play inline, muted and looping, inside the frame.
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private let badge = UIImageView(image: UIImage(systemName: "play.fill"))

    init(shot: Shot, action: @escaping (Shot) -> Void) {
        self.shot = shot
        self.action = action
        super.init(frame: .zero)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerCurve = .continuous
        image.layer.cornerRadius = 18
        image.layer.borderWidth = 2.5
        image.backgroundColor = .secondarySystemFill
        image.isUserInteractionEnabled = false
        shadow.isUserInteractionEnabled = false
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.16
        shadow.layer.shadowRadius = 12
        shadow.layer.shadowOffset = CGSize(width: 0, height: 7)
        playerLayer.videoGravity = .resizeAspectFill
        image.layer.addSublayer(playerLayer)
        badge.tintColor = .white
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        badge.contentMode = .center
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        badge.layer.cornerRadius = 12
        badge.isHidden = !shot.video
        badge.isUserInteractionEnabled = false
        [shadow, image, badge].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        width = widthAnchor.constraint(equalToConstant: GalleryCell.height * 0.46)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: GalleryCell.height), width,
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            shadow.topAnchor.constraint(equalTo: topAnchor), shadow.bottomAnchor.constraint(equalTo: bottomAnchor),
            shadow.leadingAnchor.constraint(equalTo: leadingAnchor), shadow.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24), badge.heightAnchor.constraint(equalToConstant: 24),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        addAction(UIAction { [weak self] _ in guard let self else { return }; Theme.selectionHaptic(); self.action(self.shot) }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        accessibilityLabel = "Screenshot: " + shot.title
        accessibilityIdentifier = "thread.media"
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// True once this frame was shown before its picture arrived; only then
    /// does the picture fade in.
    private var waited = false

    func update() {
        startPlaybackIfReady()
        guard let picture = GalleryCell.image(for: shot) else { waited = true; return }
        guard image.image !== picture else { return }
        let ratio = picture.size.width / max(1, picture.size.height)
        width.constant = min(320, max(64, GalleryCell.height * ratio))
        image.layer.cornerRadius = ratio < 0.7 ? 18 : 10
        if waited, image.image == nil, window != nil {
            UIView.transition(with: image, duration: 0.35, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.image.image = picture }
        } else {
            image.image = picture
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shadow.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: image.layer.cornerRadius).cgPath
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = image.bounds
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

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateBorder()
    }

    private func updateBorder() { image.layer.borderColor = UIColor.label.withAlphaComponent(0.85).cgColor }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
            }
        }
    }
}

/// A finished turn's work, folded into one glass line.
final class SummaryCell: TimelineCell {
    private let glass = Theme.glassSurface(cornerRadius: 19, interactive: true)
    private let icon = UIImageView()
    private let titleLabel = Theme.label("", Theme.font(.subheadline, 14, .semibold))
    private let detailLabel = Theme.label("", Theme.font(.subheadline, 14), color: .secondaryLabel)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        chevron.tintColor = .tertiaryLabel
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, chevron])
        row.spacing = 7
        row.alignment = .center
        row.setCustomSpacing(10, after: detailLabel)
        row.isUserInteractionEnabled = false
        [glass].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        glass.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            glass.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            glass.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            glass.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "thread.summary"
    }

    /// A ring of light leaves the pill: the turn just finished.
    func celebrate() {
        let effect = EffectView()
        effect.mode = .ripple
        effect.cornerRadius = 19
        effect.inset = 60
        effect.frame = glass.frame.insetBy(dx: -60, dy: -60)
        contentView.insertSubview(effect, belowSubview: glass)
        effect.layoutIfNeeded()
        effect.ripple { effect.removeFromSuperview() }
        glass.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.7, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.glass.transform = .identity
        }
    }

    func configure(_ summary: TurnSummary) {
        icon.image = UIImage(systemName: "checkmark.circle.fill")
        icon.tintColor = Theme.accent
        titleLabel.text = summary.title
        detailLabel.text = summary.detail
        chevron.transform = summary.expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        accessibilityLabel = summary.title + ", " + summary.detail
        accessibilityValue = summary.expanded ? "Expanded" : "Collapsed"
    }
}

/// What the agent is doing now: a glass capsule with a living edge.
final class LiveCell: TimelineCell {
    let glass = Theme.glassSurface(cornerRadius: 22)
    /// Behind the glass: the Metal edge light.
    let glowHost = EffectView()
    private let mark = UIView()
    let headline = ShimmerLabel()
    private let elapsed = UILabel()
    private var started: Date?
    private var timer: Timer?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        mark.backgroundColor = Theme.accent
        mark.layer.cornerCurve = .continuous
        mark.layer.cornerRadius = 4.5
        headline.font = Theme.font(.subheadline, 15, .semibold)
        headline.textColor = .secondaryLabel
        headline.isShimmering = true
        elapsed.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        elapsed.textColor = .tertiaryLabel
        elapsed.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsed.setContentHuggingPriority(.required, for: .horizontal)
        glowHost.cornerRadius = 22
        glowHost.inset = 18
        [glowHost, glass].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        [mark, headline, elapsed].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glass.contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            glass.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            glass.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            glass.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            glass.heightAnchor.constraint(equalToConstant: 44),
            glowHost.topAnchor.constraint(equalTo: glass.topAnchor, constant: -18),
            glowHost.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: 18),
            glowHost.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: -18),
            glowHost.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 18),
            mark.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            mark.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 14), mark.heightAnchor.constraint(equalToConstant: 14),
            headline.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 12),
            headline.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            elapsed.leadingAnchor.constraint(greaterThanOrEqualTo: headline.trailingAnchor, constant: 10),
            elapsed.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
            elapsed.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor)
        ])
        accessibilityIdentifier = "thread.working"
        isAccessibilityElement = true
    }

    func configure(_ status: LiveStatus) {
        if headline.text != status.headline {
            if headline.text != nil, window != nil, !Motion.reduced {
                let push = CATransition()
                push.type = .push
                push.subtype = .fromTop
                push.duration = 0.32
                push.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                headline.layer.add(push, forKey: "headline")
            }
            headline.text = status.headline
        }
        started = status.started
        tick()
        accessibilityLabel = status.headline
    }

    private func tick() {
        guard let started else { elapsed.text = nil; return }
        let seconds = max(0, Date.now.timeIntervalSince(started))
        elapsed.text = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        animateMark()
        glowHost.setActive(window != nil)
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The app's mark turning between circle and squircle.
    private func animateMark() {
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
