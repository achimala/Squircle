import UIKit

/// Answering what waits on you, wherever it shows (the Tasks sheet under
/// its task, a work item's page, Home): questions agents put in the tracker
/// (choices as buttons, or type a reply), workers' own questions and
/// approvals (answered straight to the worker), and needs-you tasks. What
/// you've answered so far lives in the model's `QuestionAnswers`, shared
/// with the conversation's card; an answered one leaves every list at once.
@MainActor
final class WaitingAnswers {
    private let model: SquircleModel
    private var drafts: QuestionAnswers { model.questionAnswers }

    init(model: SquircleModel) { self.model = model }

    /// Draws `item` into `view`. `about`: say which task it's for (where
    /// that isn't right above it), after `app`'s name when given (Home).
    /// `changed` runs when a request with several questions moves to its
    /// next one in place.
    func configure(_ view: WaitingItemView, _ item: WaitingList.Item, about: Bool, app: String? = nil, changed: @escaping () -> Void = {}) {
        let id = item.id
        view.itemID = id
        let busy = model.answering.contains(id)
        switch item {
        case .question(let question):
            let context = about ? [app, question.from, question.ask].compactMap { $0 }.joined(separator: " · ") : question.from ?? ""
            view.show(context: context, worker: question.from == nil ? nil : question.threadID, title: question.text, detail: nil)
            view.choices(question.options.map { ($0, nil, false) }, busy: busy) { [weak self] index in
                self?.send(question, question.options[index])
            }
            view.reply(placeholder: "Reply…", text: drafts[id].text, busy: busy,
                       edit: { [weak self] text in self?.drafts[id].text = text }) { [weak self] text in self?.send(question, text) }
        case .request(let request):
            let context = (about ? [app, request.title, request.ask] : [request.worker ? request.title : nil])
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if request.pending.isQuestion {
                question(view, request, context: context, id: id, busy: busy, changed: changed)
            } else {
                view.show(context: context, worker: request.worker ? request.threadID : nil,
                          title: request.pending.title, detail: request.pending.prompt, monospaced: true)
                let options = request.pending.options
                if options.isEmpty {
                    view.choices([("Decline", nil, false), ("Allow", nil, true)], busy: busy) { [weak self] index in
                        self?.decide(request, index == 1 ? "accept" : "decline")
                    }
                } else {
                    let prominent: Set<String> = ["accept", "acceptForSession", "acceptAlways"]
                    view.choices(options.map { ($0["label"].string ?? "Choose", $0["warning"].string, prominent.contains($0["decision"].string ?? "")) },
                                 busy: busy) { [weak self] index in
                        if let decision = options[index]["decision"].string { self?.decide(request, decision) }
                    }
                }
                view.reply(placeholder: nil, text: "", busy: busy, edit: { _ in }) { _ in }
            }
        }
    }

    /// A thread's questions one at a time, from the shared draft; the last
    /// answer sends them all.
    private func question(_ view: WaitingItemView, _ request: WaitingList.Request, context: String, id: String, busy: Bool,
                          changed: @escaping () -> Void) {
        let form = QuestionForm(questions: request.pending.questions, draft: drafts[id])
        var title = form.question["question"].string ?? "A question for you"
        if form.questions.count > 1 { title = "\(form.index + 1) of \(form.questions.count) · " + title }
        view.show(context: context, worker: request.worker ? request.threadID : nil, title: title, detail: nil)
        // Each tap reads the draft as it is then (typing changes it in between).
        let step: ((QuestionForm) -> QuestionForm.Step) -> Void = { [weak self, weak view] make in
            guard let self else { return }
            let now = QuestionForm(questions: request.pending.questions, draft: drafts[id])
            switch make(now) {
            case .edit(let draft):
                let advanced = draft.answers.count != now.draft.answers.count
                if advanced { Theme.selectionHaptic() }
                drafts[id] = draft
                if let view, view.itemID == id {
                    self.question(view, request, context: context, id: id, busy: false, changed: changed)
                    if advanced { changed() }
                }
            case .send(let answers):
                Theme.selectionHaptic()
                Task { await self.model.respond(request, answers: answers) }
            }
        }
        let confirm = form.multiple ? (form.isLast ? "Send" : "Next", form.canConfirm) : nil
        let count = form.options.count
        view.choices(form.options.map { ($0.label, $0.detail, $0.picked) }, busy: busy, confirm: confirm) { index in
            step { index < count ? $0.choose(index) : $0.confirm() }
        }
        view.reply(placeholder: "Something else…", text: form.draft.text, busy: busy,
                   edit: { [weak self] text in self?.drafts[id].text = text }) { text in step { $0.reply(text) } }
    }

    private func send(_ question: WaitingList.Question, _ text: String) {
        Theme.selectionHaptic()
        Task { await model.answer(question, text: text) }
    }

    private func decide(_ request: WaitingList.Request, _ decision: String) {
        Theme.selectionHaptic()
        Task { await model.respond(request, decision: decision) }
    }
}

/// One thing waiting on you: who asks, the question in full, its answers
/// as plain glass buttons side by side (wrapping only when they don't
/// fit), and a reply field. `compact` (Home): the question in three lines,
/// no detail and no field.
final class WaitingItemView: UIView {
    /// The item drawn, so a late redraw never lands on a reused view.
    var itemID: String?
    private let compact: Bool
    private let context = Theme.label("", Theme.Text.caption, color: .secondaryLabel, lines: 2)
    private let jelly = JellyView(.worker("", .needsYou), canvas: .roomy(Theme.Glyph.line))
    private let title = Theme.label("", Theme.Text.body, lines: 0)
    private let detail = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 4)
    private let flow = AnswerFlow()
    /// Its width before it is laid out, for a table measuring its cell.
    var fitWidth: CGFloat {
        get { flow.widthHint }
        set { flow.widthHint = newValue }
    }
    private let field = UITextField()
    private let fieldWrap = UIView()
    private var onChoose: ((Int) -> Void)?
    private var onSend: ((String) -> Void)?
    private var onEdit: ((String) -> Void)?

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        if compact {
            title.numberOfLines = 3
            context.numberOfLines = 1
        }
        jelly.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line), jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line)])
        let about = UIStackView(arrangedSubviews: [jelly, context])
        about.spacing = Theme.Space.glyphGap
        about.alignment = .center
        field.font = Theme.Text.body
        field.returnKeyType = .send
        field.accessibilityIdentifier = "waiting.reply"
        field.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let text = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            field.resignFirstResponder()
            onSend?(text)
        }, for: .editingDidEndOnExit)
        field.addAction(UIAction { [weak self] _ in self?.onEdit?(self?.field.text ?? "") }, for: .editingChanged)
        fieldWrap.backgroundColor = Theme.codeFill
        fieldWrap.layer.cornerRadius = Theme.Radius.large
        fieldWrap.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)
        NSLayoutConstraint.activate([
            fieldWrap.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: Theme.Space.group),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -Theme.Space.group),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor)
        ])
        fieldWrap.isHidden = compact
        let stack = UIStackView(arrangedSubviews: [about, title, detail, flow, fieldWrap])
        stack.axis = .vertical
        stack.spacing = Theme.Space.row
        stack.setCustomSpacing(Theme.Space.tight, after: about)
        stack.setCustomSpacing(Theme.Space.rowPad, after: title)
        stack.setCustomSpacing(Theme.Space.rowPad, after: detail)
        stack.setCustomSpacing(Theme.Space.row, after: flow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `worker`: the thread whose sprout shows beside who asks.
    func show(context text: String, worker: String?, title value: String, detail more: String?, monospaced: Bool = false,
              titleLines: Int = 0) {
        if !compact { title.numberOfLines = titleLines }
        context.text = text
        context.isHidden = text.isEmpty
        if let worker { jelly.look = .worker(worker, .needsYou) }
        jelly.isHidden = worker == nil
        context.superview?.isHidden = context.isHidden && jelly.isHidden
        title.text = value
        detail.text = more
        detail.font = monospaced ? Theme.Text.mono : Theme.Text.line
        // Home keeps to who asks and the question.
        detail.isHidden = compact || (more ?? "").isEmpty
    }

    /// Answers as buttons, side by side: (title, subtitle, prominent).
    /// `confirm`: a last button (its title, and whether it can be tapped)
    /// that sends a multi-select question's picks; its index is after the options.
    func choices(_ options: [(String, String?, Bool)], busy: Bool, confirm: (String, Bool)? = nil, choose: @escaping (Int) -> Void) {
        onChoose = choose
        var made: [UIButton] = []
        var options = options
        if let confirm { options.append((confirm.0, nil, true)) }
        for (index, option) in options.enumerated() {
            let button = Theme.glassButton(title: option.0, prominent: option.2, identifier: "waiting.option.\(option.0)")
            button.configuration?.subtitle = option.1
            button.configuration?.titleLineBreakMode = .byWordWrapping
            button.configuration?.titleAlignment = .center
            button.isEnabled = !busy && (confirm == nil || index < options.count - 1 || confirm!.1)
            button.addAction(UIAction { [weak self] _ in self?.onChoose?(index) }, for: .touchUpInside)
            made.append(button)
        }
        flow.set(made)
        flow.isHidden = options.isEmpty
    }

    /// A reply field showing `text`, or none without a placeholder (never
    /// when compact). `edit` gets each change; the text stays after a send.
    func reply(placeholder: String?, text: String, busy: Bool, edit: @escaping (String) -> Void, send: @escaping (String) -> Void) {
        onSend = send
        onEdit = edit
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        field.isEnabled = !busy
        fieldWrap.isHidden = compact || placeholder == nil
    }
}

/// Buttons left to right in rows, a new row only when the next doesn't
/// fit; one wider than a row wraps its title. Its height follows its width
/// (`widthHint` until it has one).
private final class AnswerFlow: UIView {
    var widthHint: CGFloat = 0 { didSet { if widthHint != oldValue, bounds.width == 0 { invalidateIntrinsicContentSize() } } }
    private var items: [UIButton] = []
    private var measured: CGFloat = -1
    private static let gap = Theme.Space.row

    func set(_ buttons: [UIButton]) {
        items.forEach { $0.removeFromSuperview() }
        items = buttons
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Each button's frame for `width`, and the height they take.
    private func frames(for width: CGFloat) -> ([CGRect], CGFloat) {
        guard width > 0 else { return (items.map { _ in .zero }, 0) }
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for button in items {
            var size = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            if size.width > width {
                size = CGSize(width: width, height: button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += row + Self.gap
                row = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + Self.gap
            row = max(row, size.height)
        }
        return (frames, items.isEmpty ? 0 : y + row)
    }

    private var width: CGFloat { bounds.width > 0 ? bounds.width : widthHint }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: frames(for: width).1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (frames, _) = frames(for: bounds.width)
        for (button, frame) in zip(items, frames) where button.frame != frame { button.frame = frame }
        if measured != bounds.width {
            measured = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A question or request under its task in the Tasks overview, lined up
/// with the task's text.
final class WaitingCell: UITableViewCell {
    let item = WaitingItemView()
    private let rule = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Theme.pressedFill
        selectedBackgroundView = selected
        rule.backgroundColor = .separator
        [item, rule].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            item.topAnchor.constraint(equalTo: contentView.topAnchor),
            item.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.rowPad),
            item.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.text),
            item.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            rule.leadingAnchor.constraint(equalTo: item.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `last`: the task's last one, ruled off from the next task.
    func setLast(_ last: Bool) { rule.isHidden = !last }
}

/// Everything waiting on you across apps, at the top of Home above the
/// devices: one question or approval at a time, the next a swipe sideways
/// under the finger (native paging), answerable in place. It keeps the
/// tallest one's height however many wait, so the devices stay put.
/// Tapping a question's text opens the conversation that asked it, at the
/// spot.
@MainActor
final class HomeWaitingView: UIView, UIScrollViewDelegate {
    /// Opens the thread that asked, where it asked.
    var onJump: ((_ project: String, _ item: WaitingList.Item) -> Void)?
    /// Its height changed (a request moved on to its next question).
    var onResize: (() -> Void)?
    private let answers: WaitingAnswers
    private let heading = Theme.label("Waiting on you", Theme.Text.caption, color: .secondaryLabel)
    private let count = Theme.label("", Theme.Text.caption, color: .tertiaryLabel)
    private let pages = UIScrollView()
    private var cards: [(id: String, view: HomeWaitingCard)] = []
    private var shown: (list: [(project: String, item: WaitingList.Item)], busy: Set<String>)?

    init(model: SquircleModel) {
        answers = WaitingAnswers(model: model)
        super.init(frame: .zero)
        accessibilityIdentifier = "home.waiting"
        heading.accessibilityTraits = .header
        pages.isPagingEnabled = true
        pages.showsHorizontalScrollIndicator = false
        pages.alwaysBounceHorizontal = false
        // The next one shows past the margin, so there is something to swipe to.
        pages.clipsToBounds = false
        pages.delegate = self
        [heading, count, pages].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { cards.isEmpty }

    /// One page: a card and the gap after it.
    private var step: CGFloat { bounds.width + Theme.Space.row }
    private var headingHeight: CGFloat { ceil(Theme.Text.caption.lineHeight) }

    /// Its height at `width`: the heading and the tallest card.
    func height(width: CGFloat) -> CGFloat {
        guard !cards.isEmpty else { return 0 }
        return headingHeight + Theme.Space.row + cards.map { $0.view.height(width: width) }.max()!
    }

    /// The list, its apps in Home's order. True when what shows changed.
    @discardableResult
    func update(_ list: WaitingList, order: [String], busy: Set<String>) -> Bool {
        let rank = { (id: String) in order.firstIndex(of: id) ?? .max }
        let items = list.apps.sorted { rank($0.projectID) < rank($1.projectID) }
            .flatMap { app in app.items.map { (project: app.projectID, item: $0) } }
        if let shown, shown.busy == busy, shown.list.elementsEqual(items, by: { $0.project == $1.project && $0.item == $1.item }) {
            return false
        }
        shown = (items, busy)
        // The one showing stays showing; answered, the next takes its place.
        let current = page
        let showing = cards.indices.contains(current) ? cards[current].id : nil
        cards.forEach { $0.view.removeFromSuperview() }
        cards = items.map { project, item in
            let card = HomeWaitingCard()
            answers.configure(card.item, item, about: true, app: list.apps.first { $0.projectID == project }?.name ?? "App") { [weak self] in
                self?.onResize?()
            }
            card.addAction(UIAction { [weak self] _ in self?.onJump?(project, item) }, for: .touchUpInside)
            pages.addSubview(card)
            return (item.id, card)
        }
        let target = showing.flatMap { id in cards.firstIndex { $0.id == id } } ?? min(current, max(0, cards.count - 1))
        setNeedsLayout()
        layoutIfNeeded()
        pages.contentOffset.x = CGFloat(target) * step
        showCount()
        return true
    }

    /// The card under the finger's page.
    private var page: Int {
        guard step > 0 else { return 0 }
        return max(0, min(cards.count - 1, Int((pages.contentOffset.x / step).rounded())))
    }

    private func showCount() {
        count.text = cards.count > 1 ? "\(page + 1) of \(cards.count)" : nil
        accessibilityValue = count.text
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { showCount() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width, line = headingHeight
        let headingWidth = ceil(heading.sizeThatFits(CGSize(width: width, height: line)).width)
        heading.frame = CGRect(x: 0, y: 0, width: headingWidth, height: line)
        count.frame = CGRect(x: headingWidth + Theme.Space.tight, y: 0, width: max(0, width - headingWidth - Theme.Space.tight), height: line)
        let top = line + Theme.Space.row
        pages.frame = CGRect(x: 0, y: top, width: step, height: max(0, bounds.height - top))
        for (index, card) in cards.enumerated() {
            card.view.frame = CGRect(x: CGFloat(index) * step, y: 0, width: width, height: card.view.height(width: width))
        }
        pages.contentSize = CGSize(width: CGFloat(cards.count) * step, height: pages.bounds.height)
    }
}

/// One page of Home's deck: the shared card, which opens where it was
/// asked when tapped beside its answers.
private final class HomeWaitingCard: UIControl {
    let item = WaitingItemView(compact: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        item.translatesAutoresizingMaskIntoConstraints = false
        addSubview(item)
        NSLayoutConstraint.activate([
            item.topAnchor.constraint(equalTo: topAnchor),
            item.bottomAnchor.constraint(equalTo: bottomAnchor),
            item.leadingAnchor.constraint(equalTo: leadingAnchor),
            item.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        // Taps on the text open it; the answer buttons take their own.
        item.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func height(width: CGFloat) -> CGFloat {
        item.fitWidth = width
        return item.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                            verticalFittingPriority: .fittingSizeLevel).height.rounded(.up)
    }

    @objc private func tapped() { sendActions(for: .touchUpInside) }
}
