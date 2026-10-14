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
    enum Style { case user, answer, note, thought, update }
    /// Your words sit in lightly tinted glass.
    let bubble = Theme.glassSurface(cornerRadius: 21, tint: Theme.userGlass)
    let text = UITextView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var minimumLeading: NSLayoutConstraint!
    private var top: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
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
        leading.isActive = !user
        minimumLeading.isActive = user
        trailing.constant = user ? -35 : -20
        top.constant = user || style == .update ? 14 : style == .answer ? 10 : 6
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
    /// Your own pictures sit at the right, under your message.
    private var trailing = false
    private var indent: CGFloat = 20
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
    func configure(_ shots: [Shot], indent: CGFloat, id: String, trailing: Bool = false) {
        self.indent = indent
        self.trailing = trailing
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
        let left = max(indent, scroll.bounds.width - 20 - width)
        guard scroll.contentInset.left != left else { return }
        scroll.contentInset.left = left
        scroll.contentOffset.x = -left
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

/// Pictures and clips the agent's text embeds, as wide as the text at their
/// own proportions. Several in a row share rows the way a photo album does:
/// phone screenshots sit side by side, a wide picture keeps a row to itself.
/// Clips play inline, muted and looping; a tap opens either full screen.
final class FigureCell: TimelineCell {
    static let maxHeight: CGFloat = 440
    static let minRowHeight: CGFloat = 190
    static let gap: CGFloat = 8
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
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            canvas.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            canvas.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            canvas.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
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
        (layout(shots, width: width - 40).map(\.maxY).max() ?? 0) + 16
    }

    /// Decoded once at the size it shows, not the file's full resolution.
    static func image(for shot: Shot) -> UIImage? {
        let key = shot.step as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = StepImages.data(for: shot.step, index: shot.index), let image = UIImage(data: data) else { return nil }
        let fit = min(1, 1200 / max(1, max(image.size.width, image.size.height)))
        let picture = image.preparingThumbnail(of: CGSize(width: image.size.width * fit, height: image.size.height * fit)) ?? image
        cache.setObject(picture, forKey: key)
        return picture
    }
    private static let cache = NSCache<NSString, UIImage>()

    func configure(_ shots: [Shot], width: CGFloat) {
        if shots != self.shots {
            self.shots = shots
            tiles.forEach { $0.removeFromSuperview() }
            tiles = shots.map { shot in
                let tile = FigureTile(shot: shot) { [weak self] in self?.onTap?($0) }
                canvas.addSubview(tile)
                return tile
            }
        }
        available = width - 40
        height.constant = Self.layout(shots, width: available).map(\.maxY).max() ?? 0
        tiles.forEach { $0.update() }
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
    private let playerLayer = AVPlayerLayer()
    private let badge = UIImageView(image: UIImage(systemName: "play.fill"))
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    init(shot: Shot, action: @escaping (Shot) -> Void) {
        self.shot = shot
        super.init(frame: .zero)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill
        image.contentMode = .scaleAspectFill
        image.isUserInteractionEnabled = false
        image.layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspectFill
        badge.tintColor = .white
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        badge.contentMode = .center
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        badge.layer.cornerRadius = 12
        badge.isUserInteractionEnabled = false
        badge.isHidden = !shot.video
        addSubview(image)
        addSubview(badge)
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.selectionHaptic()
            action(self.shot)
        }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        accessibilityLabel = shot.video ? "Recording" : "Image"
        accessibilityIdentifier = "thread.figure"
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update() {
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
        // Phone screenshots read as phones; everything else as a picture.
        layer.cornerRadius = bounds.width / max(1, bounds.height) < 0.7 ? min(22, bounds.width * 0.1) : 12
        image.frame = bounds
        badge.frame = CGRect(x: bounds.maxX - 32, y: bounds.maxY - 32, width: 24, height: 24)
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

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            }
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateBorder()
    }

    private func updateBorder() {
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 1 / max(1, traitCollection.displayScale)
    }
}

/// What a turn changed, as a quiet line with its size; opens the diff.
final class ChangesCell: TimelineCell {
    private let icon = UIImageView(image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"))
    private let label = Theme.label("", Theme.font(.footnote, 13, .medium), color: .secondaryLabel)
    private let stats = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        icon.tintColor = .secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        chevron.tintColor = .tertiaryLabel
        stats.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let row = UIStackView(arrangedSubviews: [icon, label, stats, chevron])
        row.spacing = 7
        row.alignment = .center
        row.setCustomSpacing(10, after: stats)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "thread.changes"
    }

    func configure(_ changes: TurnChanges) {
        label.text = "\(changes.files.count) file\(changes.files.count == 1 ? "" : "s")"
        let text = NSMutableAttributedString(string: "+\(changes.additions)", attributes: [.foregroundColor: Theme.success])
        text.append(NSAttributedString(string: " −\(changes.deletions)", attributes: [.foregroundColor: Theme.failure]))
        stats.attributedText = text
        accessibilityLabel = "Changes: \(label.text ?? ""), \(changes.additions) added, \(changes.deletions) removed"
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
    private let titleLabel = Theme.label("", Theme.font(.subheadline, 15, .semibold))
    private let detailLabel = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel)
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
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        icon.contentMode = .center
        spinner.hidesWhenStopped = true
        install.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14)
        install.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = Theme.font(.subheadline, 15, .semibold); return attributes
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
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let glyph = UIView()
        [icon, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glyph.addSubview($0) }
        let row = UIStackView(arrangedSubviews: [glyph, text, install])
        row.spacing = 12
        row.alignment = .center
        card.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .tertiarySystemFill
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            glyph.widthAnchor.constraint(equalToConstant: 30), glyph.heightAnchor.constraint(equalToConstant: 30),
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
        case "succeeded": detail = "Ready to install"; icon.image = UIImage(systemName: "app.badge.checkmark"); icon.tintColor = Theme.accent
        case "failed": detail = "Build failed"; icon.image = UIImage(systemName: "xmark.octagon"); icon.tintColor = Theme.failure
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

/// A finished turn's work, folded into one quiet line.
final class SummaryCell: TimelineCell {
    /// The line; it pulses when the turn finishes.
    private let line = UIView()
    private let icon = UIImageView()
    private let titleLabel = Theme.label("", Theme.font(.footnote, 13, .medium), color: .secondaryLabel)
    private let detailLabel = Theme.label("", Theme.font(.footnote, 13), color: .tertiaryLabel)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        chevron.tintColor = .tertiaryLabel
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, chevron])
        row.spacing = 7
        row.alignment = .center
        row.setCustomSpacing(10, after: detailLabel)
        row.isUserInteractionEnabled = false
        line.isUserInteractionEnabled = false
        [line, row].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        contentView.addSubview(line)
        line.addSubview(row)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: line.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -6)
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
        bloom.backgroundColor = Theme.accent.withAlphaComponent(0.18).cgColor
        bloom.shadowColor = Theme.accent.cgColor
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

/// What the agent is doing now, as a line of text. When the agent moves
/// on, the finished task slides up out of it and the next slides in from
/// below.
final class LiveCell: TimelineCell {
    private let capsule = LiveCapsule()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        capsule.isUserInteractionEnabled = false
        capsule.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            capsule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            capsule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            capsule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            capsule.heightAnchor.constraint(equalToConstant: 34)
        ])
        accessibilityIdentifier = "thread.working"
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ status: LiveStatus) {
        capsule.configure(headline: status.headline, started: status.started)
        accessibilityLabel = status.headline
    }
}

#if DEBUG
/// Prototype: something alive in place of the capsule's mark.
@MainActor
protocol CapsuleCharacter: AnyObject {
    var side: CGFloat { get }
    func set(tone: LiveCapsule.Tone)
    /// The task text just changed (the old line rises out).
    func lineChanged()
}
#endif

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
    enum Tone: Equatable { case idle, working, needsYou, done }
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
    var font = Theme.font(.subheadline, 15, .semibold) { didSet { line.font = font; setNeedsLayout() } }
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
        mark.backgroundColor = Theme.accent
        mark.layer.cornerCurve = .continuous
        mark.layer.cornerRadius = 4.5
        elapsed.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
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
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.isShimmering = tone == .working
        track.addSubview(label)
    }

    #if DEBUG
    /// Prototype: a living character in place of the mark (see
    /// `BubbleCharacter`).
    var character: (UIView & CapsuleCharacter)? {
        didSet {
            oldValue?.removeFromSuperview()
            if let character {
                addSubview(character)
                character.set(tone: tone)
            }
            mark.isHidden = character != nil
            setNeedsLayout()
        }
    }
    private var markSide: CGFloat { character?.side ?? 14 }
    private func lead(_ height: CGFloat) -> CGFloat {
        character != nil ? (height - markSide) / 2 : max(12, (height - markSide) / 2 + 1)
    }
    #else
    private var markSide: CGFloat { 14 }
    private func lead(_ height: CGFloat) -> CGFloat { max(12, (height - markSide) / 2 + 1) }
    #endif
    private var inset: CGFloat { lead(bounds.height) }

    /// The width that shows the whole headline, within `limit`.
    func preferredWidth(limit: CGFloat, height: CGFloat) -> CGFloat {
        let lead = lead(height)
        guard let headline, !headline.isEmpty else { return height }
        let text = ceil((headline as NSString).size(withAttributes: [.font: font]).width)
        let time = showsTime && started != nil ? 52 : lead - 2
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
        #if DEBUG
        character?.frame = mark.frame
        #endif
        elapsed.sizeToFit()
        elapsed.isHidden = !showsTime || started == nil
        elapsed.center = CGPoint(x: bounds.width - inset - 3 - elapsed.bounds.width / 2, y: bounds.height / 2)
        placeLines()
    }

    /// Where a line rests: after the mark, as wide as its text, short of the
    /// timer (or of where it would be at `widthLimit`).
    private func restingFrame(_ label: ShimmerLabel) -> CGRect {
        let x = mark.frame.maxX + 11
        let end = elapsed.isHidden ? track.bounds.width - inset + 2 : elapsed.frame.minX - 8
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
            mark.backgroundColor = tone == .needsYou ? Theme.warning : tone == .done ? Theme.success : Theme.accent
            line.isShimmering = tone == .working
            line.textColor = tone == .needsYou ? Theme.warning : .secondaryLabel
            animateMark()
            #if DEBUG
            character?.set(tone: tone)
            #endif
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
        #if DEBUG
        character?.lineChanged()
        #endif
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
        let seconds = max(0, Date.now.timeIntervalSince(started))
        let text = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
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
