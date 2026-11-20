import UIKit

/// The colours of a work item's four steps (Plan, Build, Review, Merge):
/// done green, an agent at work violet, waiting on you amber, blocked red.
enum GateLook {
    static func color(_ step: Gate.Step) -> UIColor {
        switch step {
        case .done: Theme.success
        case .working: Theme.working
        case .you: Theme.warning
        case .blocked: Theme.failure
        case .todo: .tertiaryLabel
        }
    }
    static let names = ["Plan", "Build", "Review", "Merge"]
}

/// The overview's four-step bar: four short capsules, each its step's colour.
final class StageBar: UIView {
    private var dashes: [UIView] = []
    static let size = CGSize(width: 4 * 20 + 3 * 6, height: 4)

    override init(frame: CGRect) {
        super.init(frame: frame)
        for _ in 0..<4 {
            let dash = UIView()
            dash.layer.cornerRadius = 2
            dashes.append(dash)
            addSubview(dash)
        }
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (i, dash) in dashes.enumerated() {
            dash.frame = CGRect(x: CGFloat(i) * 26, y: (bounds.height - 4) / 2, width: 20, height: 4)
        }
    }

    func configure(_ steps: [Gate.Step]) {
        for (dash, step) in zip(dashes, steps + Array(repeating: .todo, count: max(0, 4 - steps.count))) {
            dash.backgroundColor = step == .todo ? Theme.codeFill : GateLook.color(step)
        }
    }
}

/// A page's stage track: "● Plan —— ● Build —— ● Review —— ● Merge", each
/// dot and name in its step's colour.
private final class StageTrack: UIView {
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.alignment = .center
        row.spacing = Theme.Space.tight
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ steps: [Gate.Step]) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var rules: [UIView] = []
        for (i, name) in GateLook.names.enumerated() {
            let step = i < steps.count ? steps[i] : .todo
            let color = step == .todo ? UIColor.tertiaryLabel : GateLook.color(step)
            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
            if step == .you || step == .working {
                dot.layer.shadowColor = color.cgColor
                dot.layer.shadowOpacity = 0.5
                dot.layer.shadowRadius = 3
                dot.layer.shadowOffset = .zero
            }
            let label = Theme.label(name, Theme.Text.line, color: color)
            row.addArrangedSubview(dot)
            row.addArrangedSubview(label)
            if i < 3 {
                let rule = UIView()
                rule.backgroundColor = .separator
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rule.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
                row.addArrangedSubview(rule)
                rules.append(rule)
                row.setCustomSpacing(Theme.Space.tight, after: label)
            }
        }
        // The rules share what's left equally.
        for rule in rules.dropFirst() { rule.widthAnchor.constraint(equalTo: rules[0].widthAnchor).isActive = true }
        accessibilityLabel = zip(GateLook.names, steps).map { "\($0) \($1.rawValue)" }.joined(separator: ", ")
        isAccessibilityElement = true
    }
}

/// A picture on a work item's page: a plan or review round's file, or one of
/// the item's media (a film's still).
enum GatePicture: Equatable, Hashable {
    case round(kind: String, round: Int, path: String)
    case media(String)
}

/// One work item, a page of Tasks, about the one step it is on (the
/// deck's visual gates): the stage track, the title and your words, then
/// the plan with Approve plan; the build with each change's films; the
/// review's verdict, findings or plan vs actual with Approve merge; the
/// merged story; or a No code item's answer. Approve and Change… sit at
/// the foot, always in reach. Rebuilt whole when its item changes.
final class GatePage: UIView {
    struct Content: Equatable {
        let task: AppTask
        let threads: [ThreadLine.Content]
        let asks: [TasksViewController.AskRow]
        /// What a gate button is sending, so it shows busy.
        let sending: Bool
        /// Why the last press didn't go through.
        let refused: String?
    }
    var answers: WaitingAnswers?
    var feeds: SimulatorFeeds?
    var onThread: ((String) -> Void)?
    var onPrepare: ((String) -> Void)?
    var onApprovePlan: ((Gate.ApprovePlan) -> Void)?
    var onApproveMerge: ((Gate.ApproveMerge) -> Void)?
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    var onItem: ((String) -> Void)?
    /// A picture tapped: every picture of its group, which one, and its view.
    var onPictures: (([GatePicture], Int, [GatePicture: UIView]) -> Void)?
    var load: ((GatePicture, CGFloat) async -> UIImage?)?
    var top: CGFloat = 0
    let scroll = UIScrollView()
    private let stack = UIStackView()
    private let footer = UIStackView()
    private let reason = Theme.label("", Theme.Text.lineStrong, color: Theme.failure, lines: 2)
    private let primary = UIButton(configuration: .filled())
    private let secondary = UIButton(configuration: .filled())
    private let spacer = UIView()
    /// Paper under the foot's buttons, fading in above them.
    private let backdrop = UIView()
    private let fade = CAGradientLayer()
    private var spacerHeight: NSLayoutConstraint!
    private var shown: Content?
    private var loads: [Task<Void, Never>] = []
    private var images: [GatePicture: UIImage] = [:]
    /// The views showing each picture now, for the viewer to fly from.
    private var pictureViews: [GatePicture: UIView] = [:]
    private var primaryAction: (() -> Void)?
    private var showsPlan = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.paper
        scroll.alwaysBounceVertical = true
        stack.axis = .vertical
        stack.spacing = Theme.Space.group
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        for (button, filled) in [(primary, true), (secondary, false)] {
            var config = UIButton.Configuration.filled()
            config.cornerStyle = .capsule
            config.baseBackgroundColor = filled ? Theme.accent : .systemBackground
            config.baseForegroundColor = filled ? Theme.onAccent : .label
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Theme.Text.bodyStrong
                return attributes
            }
            button.configuration = config
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = filled ? 0 : 0.08
            button.layer.shadowRadius = 8
            button.layer.shadowOffset = CGSize(width: 0, height: 2)
            button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
        primary.addAction(UIAction { [weak self] _ in self?.primaryAction?() }, for: .touchUpInside)
        secondary.addAction(UIAction { [weak self] _ in
            Theme.selectionHaptic()
            self?.onChange?()
        }, for: .touchUpInside)
        reason.textAlignment = .center
        let buttons = UIStackView(arrangedSubviews: [primary, secondary])
        buttons.spacing = Theme.Space.rowPad
        buttons.distribution = .fillEqually
        footer.axis = .vertical
        footer.spacing = Theme.Space.group
        footer.addArrangedSubview(reason)
        footer.addArrangedSubview(buttons)
        footer.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isUserInteractionEnabled = false
        backdrop.layer.addSublayer(fade)
        addSubview(backdrop)
        addSubview(footer)
        spacerHeight = spacer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.tight),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.rowPad),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.margin),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.margin),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.margin),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.margin),
            footer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Space.tight),
            spacerHeight
        ])
        if #available(iOS 26.0, *) { scroll.bottomEdgeEffect.style = .soft }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let height = footer.isHidden ? 0 : footer.systemLayoutSizeFitting(CGSize(width: bounds.width - 2 * Theme.Space.margin, height: 0),
                                                                         withHorizontalFittingPriority: .required,
                                                                         verticalFittingPriority: .fittingSizeLevel).height + Theme.Space.group
        if spacerHeight.constant != height { spacerHeight.constant = height }
        backdrop.isHidden = footer.isHidden
        let top = footer.frame.minY - Theme.Space.section
        backdrop.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        let paper = Theme.paper.resolvedColor(with: traitCollection)
        fade.colors = [paper.withAlphaComponent(0).cgColor, paper.cgColor, paper.cgColor]
        fade.locations = [0, NSNumber(value: Double(Theme.Space.section / max(1, backdrop.bounds.height))), 1]
        fade.frame = backdrop.bounds
    }

    func configure(_ content: Content) {
        guard content != shown else { return }
        shown = content
        loads.forEach { $0.cancel() }
        loads = []
        pictureViews = [:]
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let task = content.task
        guard let gate = task.gate else { legacy(content); finish(); return }
        if gate.kind == .code, let steps = gate.steps {
            let track = StageTrack()
            track.configure(steps)
            stack.addArrangedSubview(track)
            stack.setCustomSpacing(Theme.Space.rowPad, after: track)
        } else {
            let caption = switch gate.kind {
            case .noCode: gate.group == .closed ? "CLOSED" : (gate.answers?.isEmpty == false ? "ANSWERED" : "ASKED")
            case .notPlanned: "NOT PLANNED YET"
            case .code: (gate.label ?? "").uppercased()
            }
            let color: UIColor = gate.kind == .noCode && gate.answers?.isEmpty == false ? Theme.success : .secondaryLabel
            let label = Theme.label(caption, Theme.Text.caption, color: color)
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(Theme.Space.tight, after: label)
        }
        let title = Theme.label(task.name, Theme.Text.title, lines: 0)
        title.accessibilityTraits = .header
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(Theme.Space.tight, after: title)
        // What waits on you about it, answered here.
        if !content.asks.isEmpty {
            let questions = UIStackView()
            questions.axis = .vertical
            questions.spacing = Theme.Space.group
            for ask in content.asks {
                let view = WaitingItemView()
                answers?.configure(view, ask.item, about: ask.about)
                questions.addArrangedSubview(view)
            }
            stack.addArrangedSubview(questions)
        }
        switch gate.kind {
        case .code: code(content, gate)
        case .noCode: noCode(content, gate)
        case .notPlanned: notPlanned(content, gate)
        }
        finish()
    }

    private func finish() {
        stack.addArrangedSubview(spacer)
        setNeedsLayout()
    }

    // MARK: Parts

    private func caption(_ text: String) -> UILabel {
        let label = Theme.label(text.uppercased(), Theme.Text.caption, color: .secondaryLabel)
        label.accessibilityTraits = .header
        return label
    }

    private func quote(_ text: String, lines: Int = 0) -> UILabel {
        Theme.label("“" + text + "”", Theme.Text.body, color: .secondaryLabel, lines: lines)
    }

    /// A quote as a row of a list, with a row's room above and below.
    private func quoteRow(_ text: String, lines: Int = 0) -> UIView {
        let row = UIStackView(arrangedSubviews: [quote(text, lines: lines)])
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.rowPad, leading: 0, bottom: Theme.Space.rowPad, trailing: 0)
        return row
    }

    private func rule() -> UIView {
        let rule = UIView()
        rule.backgroundColor = .separator
        rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return rule
    }

    /// A pill with a word on it: PASS green, BLOCKED red, MERGED green, REVISE outlined.
    private func pill(_ text: String, color: UIColor, outlined: Bool = false) -> UIView {
        let label = Theme.label(text, Theme.Text.caption, color: outlined ? color : .white)
        let pill = UIView()
        pill.backgroundColor = outlined ? .clear : color
        pill.layer.cornerRadius = 11
        pill.layer.borderColor = color.cgColor
        pill.layer.borderWidth = outlined ? 1.5 : 0
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9)
        ])
        pill.setContentHuggingPriority(.required, for: .horizontal)
        return pill
    }

    private func verdictPill(_ verdict: Gate.Verdict, round: Int? = nil) -> UIView {
        let prefix = round.map { "r\($0) " } ?? ""
        return switch verdict {
        case .pass: pill(prefix + "PASS", color: Theme.success)
        case .blocked: pill(prefix + (round == nil ? "BLOCKED" : "✕"), color: Theme.failure)
        case .revise: pill(prefix + "REVISE", color: Theme.failure, outlined: true)
        }
    }

    /// A pill and words after it on one line.
    private func headline(_ lead: UIView, _ text: String) -> UIView {
        let words = Theme.label(text, Theme.Text.line, color: .secondaryLabel, lines: 2)
        lead.setContentHuggingPriority(.required, for: .horizontal)
        lead.setContentCompressionResistancePriority(.required, for: .horizontal)
        let width = lead.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        lead.widthAnchor.constraint(equalToConstant: width).isActive = true
        let row = UIStackView(arrangedSubviews: [lead, words])
        row.spacing = Theme.Space.row
        row.alignment = .center
        return row
    }

    /// A picture at `height`, tapped open full screen among `group`.
    private func picture(_ picture: GatePicture, group: [GatePicture], height: CGFloat, width: CGFloat? = nil, radius: CGFloat = Theme.Radius.small) -> UIView {
        let button = UIButton(type: .custom)
        button.backgroundColor = Theme.codeFill
        button.layer.cornerRadius = radius
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        button.imageView?.contentMode = .scaleAspectFill
        button.contentHorizontalAlignment = .fill
        button.contentVerticalAlignment = .fill
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
        if let width { button.widthAnchor.constraint(equalToConstant: width).isActive = true }
        button.accessibilityLabel = "Picture"
        pictureViews[picture] = button
        let index = group.firstIndex(of: picture) ?? 0
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.selectionHaptic()
            onPictures?(group, index, pictureViews)
        }, for: .touchUpInside)
        if let image = images[picture] {
            button.setImage(image, for: .normal)
        } else {
            loads.append(Task { [weak self, weak button] in
                guard let image = await self?.load?(picture, height), !Task.isCancelled else { return }
                self?.images[picture] = image
                button?.setImage(image, for: .normal)
            })
        }
        return button
    }

    /// A picture shown whole at the page's width (a plan's first picture),
    /// its height following the picture once loaded, at most `cap`.
    private func wide(_ picture: GatePicture, group: [GatePicture], cap: CGFloat) -> UIView {
        let button = UIButton(type: .custom)
        button.backgroundColor = Theme.codeFill
        button.layer.cornerRadius = 12
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        button.layer.borderColor = UIColor.separator.cgColor
        button.layer.borderWidth = 1 / UIScreen.main.scale
        button.accessibilityLabel = "Picture"
        // The whole picture at the page's width, its top showing; the viewer flies it up whole.
        let whole = UIImageView()
        whole.contentMode = .scaleAspectFill
        whole.isUserInteractionEnabled = false
        whole.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(whole)
        let tall = whole.heightAnchor.constraint(equalToConstant: 180)
        NSLayoutConstraint.activate([whole.topAnchor.constraint(equalTo: button.topAnchor),
                                     whole.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                                     whole.trailingAnchor.constraint(equalTo: button.trailingAnchor), tall])
        let height = button.heightAnchor.constraint(equalToConstant: 180)
        height.isActive = true
        pictureViews[picture] = button
        let index = group.firstIndex(of: picture) ?? 0
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.selectionHaptic()
            onPictures?(group, index, pictureViews)
        }, for: .touchUpInside)
        // Fitted to the page's width; a tall one shows its top, the rest a tap away.
        let show = { [weak self] (image: UIImage) in
            guard let self, image.size.width > 0 else { return }
            let width = max(1, (bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width) - 2 * Theme.Space.margin)
            let full = width * image.size.height / image.size.width
            height.constant = min(cap, full)
            tall.constant = full
            whole.image = image
        }
        if let image = images[picture] { show(image) } else {
            loads.append(Task { [weak self] in
                // Sharp at full width: a tall picture needs many rows.
                guard let image = await self?.load?(picture, 1600), !Task.isCancelled else { return }
                self?.images[picture] = image
                show(image)
            })
        }
        return button
    }

    private func threadLines(_ threads: [ThreadLine.Content]) {
        for content in threads {
            let line = ThreadLine(size: .row)
            line.configure(content, feeds: feeds)
            line.addAction(UIAction { [weak self] _ in self?.onThread?(content.id) }, for: .touchUpInside)
            line.addAction(UIAction { [weak self] _ in self?.onPrepare?(content.id) }, for: .touchDown)
            stack.addArrangedSubview(line)
        }
    }

    /// A numbered row: the number in the glyph slot (violet), a title, and lines under it.
    private func numbered(_ mark: String, color: UIColor, _ title: String, under: [(String, UIColor)] = [], extra: UIView? = nil) -> UIView {
        let number = Theme.label(mark, Theme.Text.bodyStrong, color: color)
        number.textAlignment = .center
        let text = UIStackView(arrangedSubviews: [Theme.label(title, Theme.Text.body, lines: 0)]
                                + under.map { Theme.label($0.0, Theme.Text.line, color: $0.1, lines: 0) })
        text.axis = .vertical
        text.spacing = 2
        if let extra { text.addArrangedSubview(extra); text.setCustomSpacing(Theme.Space.row, after: text.arrangedSubviews[text.arrangedSubviews.count - 2]) }
        let row = UIView()
        [number, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; row.addSubview($0) }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            number.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            number.firstBaselineAnchor.constraint(equalTo: (text.arrangedSubviews[0] as! UILabel).firstBaselineAnchor),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Theme.Space.indent),
            text.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: Theme.Space.row),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Theme.Space.row)
        ])
        return row
    }

    private func list(_ rows: [UIView]) {
        for (i, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(0, after: row)
            if i < rows.count - 1 {
                let rule = rule()
                stack.addArrangedSubview(rule)
                stack.setCustomSpacing(0, after: rule)
            }
        }
        if let last = rows.last { stack.setCustomSpacing(Theme.Space.section, after: last) }
    }

    private func setFooter(primary title: String?, enabled: Bool = true, secondary second: String?, reason why: String? = nil,
                           action: (() -> Void)? = nil) {
        footer.isHidden = title == nil && second == nil
        primary.isHidden = title == nil
        secondary.isHidden = second == nil
        primary.configuration?.title = title
        secondary.configuration?.title = second
        primary.isEnabled = enabled && shown?.sending != true
        primary.configuration?.showsActivityIndicator = shown?.sending == true
        primary.configuration?.baseBackgroundColor = enabled ? Theme.accent : Theme.codeFill
        primary.configuration?.baseForegroundColor = enabled ? Theme.onAccent : .tertiaryLabel
        let refused = shown?.refused
        reason.text = refused ?? why
        reason.isHidden = reason.text?.isEmpty ?? true
        primaryAction = action
    }

    /// The words under a quoted ask: the change answering it.
    private func tie(_ ask: Gate.Ask, plan: Gate.Plan?) -> (String, UIColor) {
        if !ask.open { return (ask.replaced ? "replaced by a later ask" : "closed", .tertiaryLabel) }
        if let n = ask.change, let change = plan?.changes.first(where: { $0.n == n }) {
            return ("→ change \(n) · \(change.title)", Theme.success)
        }
        if plan == nil { return ("going into the plan", Theme.working) }
        return ("→ not in the plan yet", Theme.failure)
    }

    /// Your words, oldest first, each with the change that answers it.
    private func words(_ gate: Gate, plan: Gate.Plan?, limit: Int? = nil) {
        let asks = gate.asks.filter { $0.open || $0.change != nil }
        guard !asks.isEmpty else { return }
        stack.addArrangedSubview(caption("Your words · \(asks.count)"))
        let shown = limit.map { Array(asks.prefix($0)) } ?? asks
        var rows: [UIView] = shown.map { ask in
            let (text, color) = tie(ask, plan: plan)
            let tie = Theme.label(text, Theme.Text.lineStrong, color: color, lines: 0)
            let row = UIStackView(arrangedSubviews: [Theme.label("“" + ask.text + "”", Theme.Text.body, lines: 0), tie])
            row.axis = .vertical
            row.spacing = Theme.Space.tight
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.rowPad, leading: 0, bottom: Theme.Space.rowPad, trailing: 0)
            return row
        }
        if asks.count > shown.count {
            let more = FoldRow()
            more.configure(symbol: "text.quote", text: "more", count: asks.count - shown.count, open: false)
            rows.append(more)
        }
        list(rows)
    }

    // MARK: Code

    private func code(_ content: Content, _ gate: Gate) {
        let task = content.task
        let plan = gate.plan
        let step = gate.steps?.firstIndex { $0 != .done } ?? 3
        let merged = gate.merged != nil
        let closed = gate.group == .closed
        if merged {
            mergedStory(task, gate)
            setFooter(primary: nil, secondary: nil)
            return
        }
        switch step {
        case 0:
            if task.named, gate.asks.count <= 1 || plan == nil { stack.addArrangedSubview(quote(task.ask)) }
            if gate.tone == .you, let plan {
                planBody(task, plan, approved: false)
            } else {
                // Drawing (round 1), or round N+1 after your words.
                let line = headline(pill(gate.label ?? "Planning", color: Theme.working), gate.detail ?? "")
                stack.addArrangedSubview(line)
                threadLines(content.threads)
                if let plan { planFold(task, plan, title: "Round \(plan.round) · not approved") }
                words(gate, plan: plan)
                stack.addArrangedSubview(Theme.label("Change… on any page adds your words here. The plan must tie each one to a change before you can approve it.",
                                                     Theme.Text.line, color: .tertiaryLabel, lines: 0))
            }
            if closed { setFooter(primary: nil, secondary: nil); return }
            setFooter(primary: "Approve plan", enabled: gate.approvePlan != nil, secondary: "Change…") { [weak self] in
                guard let bind = gate.approvePlan else { return }
                self?.onApprovePlan?(bind)
            }
        case 1:
            if let plan {
                let approved = Theme.label("Plan round \(plan.round) · approved by you", Theme.Text.line, color: .secondaryLabel)
                stack.addArrangedSubview(approved)
            }
            threadLines(content.threads)
            if let plan { changes(task, plan, filmsShown: true) }
            reviewChips(gate, caption: "Reviews")
            if let plan { planFold(task, plan, title: "The plan, round \(plan.round)") }
            setFooter(primary: nil, secondary: closed ? nil : "Change…")
        default:
            review(content, gate)
            if closed { setFooter(primary: nil, secondary: nil); return }
            let blocked = gate.approveMerge == nil
            let why = gate.tone == .blocked ? gate.mergeBlocked : nil
            if gate.label == "Merging" {
                setFooter(primary: nil, secondary: nil)
            } else {
                setFooter(primary: "Approve merge", enabled: !blocked, secondary: "Change…", reason: why) { [weak self] in
                    guard let bind = gate.approveMerge else { return }
                    self?.onApproveMerge?(bind)
                }
            }
        }
    }

    /// The plan as you approve it: its round, the big picture first, the
    /// others in a strip, the summary, then the changes with your words.
    private func planBody(_ task: AppTask, _ plan: Gate.Plan, approved: Bool) {
        let pictures = plan.pictures.map { GatePicture.round(kind: "plan", round: plan.round, path: $0) }
        let count = pictures.count == 1 ? "1 picture" : "\(pictures.count) pictures"
        stack.addArrangedSubview(caption("The plan · round \(plan.round) · \(count)"))
        if let first = pictures.first {
            let big = wide(first, group: pictures, cap: 420)
            stack.addArrangedSubview(big)
            stack.setCustomSpacing(Theme.Space.row, after: big)
        }
        if pictures.count > 1 {
            let strip = UIStackView()
            strip.spacing = Theme.Space.row
            for picture in pictures.dropFirst().prefix(3) {
                strip.addArrangedSubview(self.picture(picture, group: pictures, height: 120, width: 84))
            }
            if pictures.count > 4 {
                let more = Theme.label("+\(pictures.count - 4)", Theme.Text.bodyStrong, color: .secondaryLabel)
                more.textAlignment = .center
                more.backgroundColor = Theme.codeFill
                more.layer.cornerRadius = Theme.Radius.small
                more.clipsToBounds = true
                more.widthAnchor.constraint(equalToConstant: 84).isActive = true
                strip.addArrangedSubview(more)
            }
            strip.addArrangedSubview(UIView())
            stack.addArrangedSubview(strip)
        }
        if !plan.summary.isEmpty {
            stack.addArrangedSubview(Theme.label(plan.summary, Theme.Text.line, color: .secondaryLabel, lines: 0))
        }
        changes(task, plan, filmsShown: false)
    }

    /// The plan's numbered changes; each with the asks it answers, or
    /// (building) its films on main and on the branch.
    private func changes(_ task: AppTask, _ plan: Gate.Plan, filmsShown: Bool) {
        guard let gate = task.gate else { return }
        let asks = Dictionary(gate.asks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let covered = gate.asks.filter(\.open).allSatisfy(\.covered)
        let words = gate.asks.filter(\.open).count
        let head = filmsShown ? "Changes" : "\(plan.changes.count) changes · " + (covered ? "your \(words) \(words == 1 ? "ask" : "asks") covered" : "not all your words covered")
        stack.addArrangedSubview(caption(head))
        let rows: [UIView] = plan.changes.map { change in
            if filmsShown {
                let branch = change.films.first { $0.side == .branch }
                let main = change.films.first { $0.side == .main }
                var under: [(String, UIColor)] = []
                var films: UIView?
                if let branch {
                    under.append(("filmed" + (branch.jumps.isEmpty ? "" : " · \(branch.jumps.count) jumps measured"), .secondaryLabel))
                    let pair = UIStackView()
                    pair.spacing = Theme.Space.row
                    pair.distribution = .fillEqually
                    for (film, side) in [(main, "main"), (branch, "branch")] {
                        guard let film else { continue }
                        let still = film.stills.last ?? film.media
                        let group = [main, branch].compactMap { $0 }.map { GatePicture.media($0.stills.last ?? $0.media) }
                        let column = UIStackView(arrangedSubviews: [picture(.media(still), group: group, height: 150),
                                                                    Theme.label(side, Theme.Text.line, color: .secondaryLabel)])
                        column.axis = .vertical
                        column.alignment = .center
                        column.spacing = Theme.Space.tight
                        column.arrangedSubviews[0].widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                        pair.addArrangedSubview(column)
                    }
                    // A lone film keeps its half: the other side is simply not filmed.
                    if pair.arrangedSubviews.count == 1 { pair.addArrangedSubview(UIView()) }
                    films = pair
                } else {
                    under.append(("not filmed yet", .tertiaryLabel))
                }
                let mark = branch == nil ? "\(change.n)" : "✓"
                return numbered(mark, color: branch == nil ? Theme.working : Theme.success, change.title, under: under, extra: films)
            }
            let quoted = change.asks.compactMap { asks[$0] }.filter { $0.id != task.id || task.named }
                .map { ("“" + $0.text + "”", UIColor.secondaryLabel) }
            return numbered("\(change.n)", color: Theme.working, change.title, under: quoted)
        }
        list(rows)
        // Your words no change answers yet, in red.
        let loose = gate.asks.filter { $0.open && !$0.covered }
        if !loose.isEmpty, !filmsShown {
            stack.addArrangedSubview(caption("Not in the plan yet"))
            list(loose.map { ask in
                let row = UIStackView(arrangedSubviews: [Theme.label("“" + ask.text + "”", Theme.Text.body, lines: 0),
                                                         Theme.label("→ not in the plan yet", Theme.Text.lineStrong, color: Theme.failure)])
                row.axis = .vertical
                row.spacing = Theme.Space.tight
                row.isLayoutMarginsRelativeArrangement = true
                row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.rowPad, leading: 0, bottom: Theme.Space.rowPad, trailing: 0)
                return row
            })
        }
    }

    /// The plan folded under a line; tapping opens it in place.
    private func planFold(_ task: AppTask, _ plan: Gate.Plan, title: String) {
        let fold = FoldRow()
        fold.configure(symbol: "photo.on.rectangle", text: title, count: nil, open: showsPlan)
        fold.addAction(UIAction { [weak self] _ in
            guard let self, let shown else { return }
            Theme.selectionHaptic()
            showsPlan.toggle()
            self.shown = nil
            configure(shown)
        }, for: .touchUpInside)
        stack.addArrangedSubview(fold)
        if showsPlan { planBody(task, plan, approved: plan.approvedAt != nil) }
    }

    /// Earlier review rounds as chips: r1 ✕ r2 ✕ r3 PASS.
    private func reviewChips(_ gate: Gate, caption title: String, skippingLatest: Bool = false) {
        var rounds = gate.reviews ?? []
        if skippingLatest { rounds = Array(rounds.dropLast()) }
        guard !rounds.isEmpty else { return }
        stack.addArrangedSubview(caption(title))
        let chips = UIStackView(arrangedSubviews: rounds.map { round in
            let verdict = round.verdict ?? .blocked
            return verdict == .pass ? pill("r\(round.round) PASS", color: Theme.success) : pill("r\(round.round) ✕", color: Theme.failure)
        } + [UIView()])
        chips.spacing = Theme.Space.tight
        stack.addArrangedSubview(chips)
        if let last = rounds.last, let summary = last.summary, !summary.isEmpty {
            stack.addArrangedSubview(Theme.label(summary, Theme.Text.line, color: .secondaryLabel, lines: 3))
        }
    }

    /// The review step: its verdict; blocked, each finding as a picture and
    /// planned / branch / fix; passed, the films side by side and plan vs actual.
    private func review(_ content: Content, _ gate: Gate) {
        let task = content.task
        guard let review = gate.review, review.lapsed != true else {
            stack.addArrangedSubview(headline(pill(gate.label ?? "Reviewing", color: Theme.working), gate.detail ?? ""))
            threadLines(content.threads)
            reviewChips(gate, caption: "Earlier reviews")
            return
        }
        if gate.label == "Reviewing" {
            stack.addArrangedSubview(headline(pill("Reviewing", color: Theme.working), gate.detail ?? ""))
            threadLines(content.threads)
            reviewChips(gate, caption: "Earlier reviews")
            return
        }
        let blocked = (gate.reviews ?? []).dropLast().filter { $0.verdict != .pass }.count
        let after = review.verdict == .pass && blocked > 0 ? " · after \(blocked) blocked" : ""
        let detail = review.verdict == .pass ? (review.findings.isEmpty ? "nothing to fix" : "\(review.findings.count) notes")
            : "\(review.findings.count) to fix"
        stack.addArrangedSubview(headline(verdictPill(review.verdict), "review \(review.round)\(after) · \(detail)"))
        if review.verdict == .pass {
            // The films of the first filmed change, main beside the branch.
            if let change = gate.plan?.changes.first(where: { $0.films.contains { $0.side == .branch } }) {
                let films = change.films.sorted { $0.side == .main && $1.side == .branch }
                let group = films.map { GatePicture.media($0.stills.last ?? $0.media) }
                let pair = UIStackView(arrangedSubviews: films.map { film in
                    let column = UIStackView(arrangedSubviews: [picture(.media(film.stills.last ?? film.media), group: group, height: 220),
                                                                Theme.label("\(film.side.rawValue) · \(film.caption)", Theme.Text.line, color: .secondaryLabel, lines: 2)])
                    column.axis = .vertical
                    column.spacing = Theme.Space.tight
                    return column
                })
                pair.spacing = Theme.Space.row
                pair.distribution = .fillEqually
                stack.addArrangedSubview(pair)
            }
            stack.addArrangedSubview(caption("Plan vs actual"))
            list(review.lines.map { line in
                let (mark, color): (String, UIColor) = switch line.mark {
                case .built: ("✓", Theme.success)
                case .differs: ("≠", Theme.warning)
                case .dropped: ("✗", Theme.failure)
                }
                let title = gate.plan?.changes.first { $0.n == line.n }?.title ?? line.text
                var under: [(String, UIColor)] = []
                if line.mark != .built {
                    let why = line.why ?? ""
                    let built = line.text == title ? "" : line.text
                    under.append(([built, why].filter { !$0.isEmpty }.joined(separator: " — "), .secondaryLabel))
                }
                return numbered(mark, color: color, title, under: under)
            })
        } else {
            let group = review.findings.compactMap(\.picture).map { GatePicture.round(kind: "review", round: review.round, path: $0) }
            list(review.findings.map { finding in
                let words = UIStackView(arrangedSubviews: [Theme.label(finding.title, Theme.Text.body, lines: 0)])
                words.axis = .vertical
                words.spacing = Theme.Space.tight
                for (key, value) in [("planned", finding.planned), ("branch", finding.branch), ("fix", finding.fix)] where !value.isEmpty {
                    let row = UIStackView(arrangedSubviews: [Theme.label(key, Theme.Text.lineStrong, color: .secondaryLabel),
                                                             Theme.label(value, Theme.Text.line, lines: 0)])
                    row.spacing = Theme.Space.row
                    row.alignment = .firstBaseline
                    row.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 62).isActive = true
                    words.addArrangedSubview(row)
                }
                let row = UIStackView(arrangedSubviews: (finding.picture.map { [picture(.round(kind: "review", round: review.round, path: $0), group: group, height: 150, width: 96)] } ?? []) + [words])
                row.spacing = Theme.Space.rowPad
                row.alignment = .top
                row.isLayoutMarginsRelativeArrangement = true
                row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.rowPad, leading: 0, bottom: Theme.Space.rowPad, trailing: 0)
                return row
            })
            threadLines(content.threads)
            reviewChips(gate, caption: "Earlier reviews", skippingLatest: true)
        }
        if let plan = gate.plan { planFold(task, plan, title: "The plan, round \(plan.round)") }
    }

    /// A merged item's whole story: the plan's first picture, then every
    /// round in order, and the plan, reviews and films folded.
    private func mergedStory(_ task: AppTask, _ gate: Gate) {
        let when = gate.merged.map { Theme.relativeDate.localizedString(for: Date(timeIntervalSince1970: $0.at), relativeTo: .now) } ?? ""
        stack.addArrangedSubview(headline(pill("MERGED", color: Theme.success), when))
        if let plan = gate.plan, let first = plan.pictures.first {
            let pictures = plan.pictures.map { GatePicture.round(kind: "plan", round: plan.round, path: $0) }
            stack.addArrangedSubview(wide(.round(kind: "plan", round: plan.round, path: first), group: pictures, cap: 260))
        }
        stack.addArrangedSubview(caption("How it got here"))
        var rows: [UIView] = []
        func story(_ lead: UIView, _ text: String) -> UIView {
            let label = Theme.label(text, Theme.Text.line, color: .secondaryLabel, lines: 0)
            let row = UIStackView(arrangedSubviews: [lead, label])
            row.spacing = Theme.Space.rowPad
            row.alignment = .firstBaseline
            lead.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.row, leading: 0, bottom: Theme.Space.row, trailing: 0)
            return row
        }
        let rounds = gate.plans ?? []
        let unapproved = rounds.filter { $0.approvedAt == nil }.map(\.round)
        if !unapproved.isEmpty {
            rows.append(story(pill("REVISE", color: Theme.failure, outlined: true),
                              "Plan round\(unapproved.count == 1 ? "" : "s") \(unapproved.map(String.init).joined(separator: ", ")): sent back"))
        }
        if let approved = rounds.last(where: { $0.approvedAt != nil }) {
            rows.append(story(pill("✓ you", color: Theme.accent), "Plan round \(approved.round) approved"))
        }
        let reviews = gate.reviews ?? []
        let failed = reviews.filter { $0.verdict != .pass || $0.lapsed == true }
        if !failed.isEmpty {
            rows.append(story(pill(String(repeating: "✕", count: min(failed.count, 3)), color: Theme.failure),
                              "Review\(failed.count == 1 ? "" : "s") \(failed.map { String($0.round) }.joined(separator: ", ")) blocked or voided"))
        }
        if let pass = reviews.last(where: { $0.verdict == .pass && $0.lapsed != true }) {
            rows.append(story(pill("PASS", color: Theme.success), "Review \(pass.round)"))
            rows.append(story(pill("✓ you", color: Theme.accent), "Merge approved · merged"))
        }
        list(rows)
        if let plan = gate.plan { planFold(task, plan, title: "Plan, reviews, films") }
    }

    // MARK: No code and Not planned yet

    private func noCode(_ content: Content, _ gate: Gate) {
        let task = content.task
        stack.addArrangedSubview(quote(task.ask))
        for answer in gate.answers ?? [] {
            let text = Theme.label(answer.text, Theme.Text.body, lines: 0)
            let bubble = UIView()
            bubble.backgroundColor = Theme.receivedFill
            bubble.layer.cornerRadius = Theme.Radius.large
            bubble.layer.cornerCurve = .continuous
            text.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(text)
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Space.rowPad),
                text.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Theme.Space.rowPad),
                text.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Theme.Space.group),
                text.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Theme.Space.group)
            ])
            stack.addArrangedSubview(bubble)
            let pictures = (answer.media ?? []).map(GatePicture.media)
            if !pictures.isEmpty {
                let strip = UIStackView(arrangedSubviews: pictures.prefix(3).map { picture($0, group: pictures, height: 140, width: 96) } + [UIView()])
                strip.spacing = Theme.Space.row
                stack.addArrangedSubview(strip)
            }
        }
        threadLines(content.threads)
        let later = gate.asks.dropFirst().filter(\.open)
        if !later.isEmpty {
            stack.addArrangedSubview(caption("Asked more"))
            list(later.map { quoteRow($0.text) })
        }
        if let spawned = gate.spawned, !spawned.isEmpty {
            stack.addArrangedSubview(caption("Became work items"))
            list(spawned.map { item in
                let bar = StageBar()
                bar.configure(item.steps ?? [])
                let title = Theme.label(item.title, Theme.Text.body, lines: 2)
                let row = UIStackView(arrangedSubviews: [title, bar])
                row.spacing = Theme.Space.rowPad
                row.alignment = .center
                row.isLayoutMarginsRelativeArrangement = true
                row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.rowPad, leading: 0, bottom: Theme.Space.rowPad, trailing: 0)
                bar.setContentHuggingPriority(.required, for: .horizontal)
                let control = UIControl()
                row.isUserInteractionEnabled = false
                row.translatesAutoresizingMaskIntoConstraints = false
                control.addSubview(row)
                NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: control.topAnchor), row.bottomAnchor.constraint(equalTo: control.bottomAnchor),
                                             row.leadingAnchor.constraint(equalTo: control.leadingAnchor), row.trailingAnchor.constraint(equalTo: control.trailingAnchor)])
                control.addAction(UIAction { [weak self] _ in self?.onItem?(item.id) }, for: .touchUpInside)
                return control
            })
        }
        if gate.group == .closed {
            setFooter(primary: nil, secondary: nil)
        } else {
            setFooter(primary: "Close", enabled: gate.answers?.isEmpty == false, secondary: "Ask more…") { [weak self] in self?.onClose?() }
        }
    }

    private func notPlanned(_ content: Content, _ gate: Gate) {
        let asks = content.task.subtasks.filter { $0.status.open }
        stack.addArrangedSubview(Theme.label("\(asks.count) asks wait here in your words. When the agent takes some on, it groups them into a work item with a plan you approve.",
                                             Theme.Text.line, color: .secondaryLabel, lines: 0))
        list(asks.map { quoteRow($0.ask, lines: 4) })
        setFooter(primary: nil, secondary: nil)
    }

    /// An item closed before gates: its words and how it ended.
    private func legacy(_ content: Content) {
        let task = content.task
        let title = Theme.label(task.name, Theme.Text.title, lines: 0)
        stack.addArrangedSubview(Theme.label(TaskLook.name(task.status).uppercased(), Theme.Text.caption, color: .secondaryLabel))
        stack.addArrangedSubview(title)
        if task.named { stack.addArrangedSubview(quote(task.ask)) }
        if !task.note.isEmpty { stack.addArrangedSubview(Theme.label(task.note, Theme.Text.line, color: .secondaryLabel, lines: 0)) }
        threadLines(content.threads)
        let words = task.subtasks.map { quoteRow($0.ask, lines: 3) }
        if !words.isEmpty {
            stack.addArrangedSubview(caption("Asks"))
            list(words)
        }
        setFooter(primary: nil, secondary: nil)
    }
}

/// A task's old status, by name and colour (History, and the agent's lines
/// that name a status).
enum TaskLook {
    nonisolated static func name(_ status: AppTask.Status) -> String {
        switch status {
        case .needsYou: "Needs you"
        case .inProgress: "In progress"
        case .readyToTry: "Ready to try"
        case .queued: "Queued"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }

    static func color(_ status: AppTask.Status) -> UIColor {
        switch status {
        case .needsYou: Theme.warning
        case .inProgress: Theme.working
        case .readyToTry: Theme.success
        default: .secondaryLabel
        }
    }
}
