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
    /// that isn't right above it). `changed` runs when a request with
    /// several questions moves to its next one in place.
    func configure(_ view: WaitingItemView, _ item: WaitingList.Item, about: Bool, changed: @escaping () -> Void = {}) {
        let id = item.id
        view.itemID = id
        let busy = model.answering.contains(id)
        switch item {
        case .question(let question):
            let context = about ? [question.from, question.ask].compactMap { $0 }.joined(separator: " · ") : question.from ?? ""
            view.show(context: context, worker: question.from == nil ? nil : question.threadID, title: question.text, detail: nil)
            view.choices(question.options.map { ($0, nil, false) }, busy: busy) { [weak self] index in
                self?.send(question, question.options[index])
            }
            view.reply(placeholder: "Reply…", text: drafts[id].text, busy: busy,
                       edit: { [weak self] text in self?.drafts[id].text = text }) { [weak self] text in self?.send(question, text) }
        case .request(let request):
            let context = (about ? [request.title, request.ask] : [request.worker ? request.title : nil])
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
        case .task(let task):
            view.show(context: about ? task.itemAsk ?? "" : "", worker: nil, title: task.ask, detail: task.note.isEmpty ? nil : task.note, titleLines: 3)
            view.choices([], busy: busy) { _ in }
            view.reply(placeholder: nil, text: "", busy: busy, edit: { _ in }) { _ in }
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
/// fit), and a reply field. `compact` (Home): smaller, answers in one row
/// that scrolls sideways, no field.
final class WaitingItemView: UIView {
    /// The item drawn, so a late redraw never lands on a reused view.
    var itemID: String?
    private let compact: Bool
    private let context = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel, lines: 2)
    private let jelly = JellyView(.worker("", .needsYou), canvas: .roomy(18))
    private let title = Theme.label("", Theme.font(.body, 17, .semibold), lines: 0)
    private let detail = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel, lines: 4)
    private let buttons = UIStackView()
    private let buttonScroll = UIScrollView()
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
            title.font = Theme.font(.subheadline, 15, .semibold)
            title.numberOfLines = 2
            context.numberOfLines = 1
        }
        jelly.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([jelly.widthAnchor.constraint(equalToConstant: 18), jelly.heightAnchor.constraint(equalToConstant: 18)])
        let about = UIStackView(arrangedSubviews: [jelly, context])
        about.spacing = 6
        about.alignment = .center
        buttons.spacing = 8
        field.font = Theme.font(.body, 16)
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
        fieldWrap.backgroundColor = .tertiarySystemFill
        fieldWrap.layer.cornerRadius = 20
        fieldWrap.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)
        NSLayoutConstraint.activate([
            fieldWrap.heightAnchor.constraint(equalToConstant: 40),
            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor)
        ])
        let answers: UIView
        if compact {
            // Side by side, scrolling sideways past the edge when they don't fit.
            buttons.alignment = .center
            buttonScroll.showsHorizontalScrollIndicator = false
            buttonScroll.clipsToBounds = false
            buttons.translatesAutoresizingMaskIntoConstraints = false
            buttonScroll.addSubview(buttons)
            NSLayoutConstraint.activate([
                buttons.topAnchor.constraint(equalTo: buttonScroll.contentLayoutGuide.topAnchor),
                buttons.bottomAnchor.constraint(equalTo: buttonScroll.contentLayoutGuide.bottomAnchor),
                buttons.leadingAnchor.constraint(equalTo: buttonScroll.contentLayoutGuide.leadingAnchor),
                buttons.trailingAnchor.constraint(equalTo: buttonScroll.contentLayoutGuide.trailingAnchor),
                buttons.heightAnchor.constraint(equalTo: buttonScroll.frameLayoutGuide.heightAnchor),
                buttonScroll.heightAnchor.constraint(equalToConstant: 36)
            ])
            answers = buttonScroll
            fieldWrap.isHidden = true
        } else {
            answers = flow
        }
        let stack = UIStackView(arrangedSubviews: [about, title, detail, answers, fieldWrap])
        stack.axis = .vertical
        stack.spacing = compact ? 3 : 6
        stack.setCustomSpacing(compact ? 2 : 4, after: about)
        stack.setCustomSpacing(compact ? 8 : 12, after: title)
        stack.setCustomSpacing(compact ? 8 : 12, after: detail)
        stack.setCustomSpacing(10, after: answers)
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
        detail.font = monospaced ? Theme.font(.footnote, 12.5, monospaced: true) : Theme.font(.footnote, 13)
        // Home keeps to who asks and the question.
        detail.isHidden = compact || (more ?? "").isEmpty
    }

    /// Answers as buttons, side by side: (title, subtitle, prominent).
    /// `confirm`: a last button (its title, and whether it can be tapped)
    /// that sends a multi-select question's picks; its index is after the options.
    func choices(_ options: [(String, String?, Bool)], busy: Bool, confirm: (String, Bool)? = nil, choose: @escaping (Int) -> Void) {
        onChoose = choose
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var made: [UIButton] = []
        var options = options
        if let confirm { options.append((confirm.0, nil, true)) }
        for (index, option) in options.enumerated() {
            let button = Theme.glassButton(title: option.0, prominent: option.2, identifier: "waiting.option.\(option.0)")
            button.configuration?.subtitle = compact ? nil : option.1
            button.configuration?.titleLineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
            button.configuration?.titleAlignment = .center
            if compact {
                button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
                button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    attributes.font = Theme.font(.subheadline, 15, .semibold)
                    return attributes
                }
            }
            button.isEnabled = !busy && (confirm == nil || index < options.count - 1 || confirm!.1)
            button.addAction(UIAction { [weak self] _ in self?.onChoose?(index) }, for: .touchUpInside)
            if compact { buttons.addArrangedSubview(button) } else { made.append(button) }
        }
        if !compact { flow.set(made) }
        (compact ? buttonScroll : flow).isHidden = options.isEmpty
        if compact { buttonScroll.contentOffset.x = 0 }
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
    private static let gap: CGFloat = 8

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
            item.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            item.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            item.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 52),
            item.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
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
/// devices: each app's name, then what waits there (a few, then how many
/// more), answerable with a tap where the answers are a few choices.
/// Tapping a question's text opens the conversation that asked it, at the
/// spot; a needs-you task opens the app's Tasks sheet at it.
@MainActor
final class HomeWaitingView: UIView {
    /// Opens an app's Tasks sheet, at an item's task when it has one.
    var onOpen: ((_ project: String, _ task: String?) -> Void)?
    /// Opens the thread that asked, where it asked.
    var onJump: ((_ project: String, _ item: WaitingList.Item) -> Void)?
    private let answers: WaitingAnswers
    private let stack = UIStackView()
    private var shown: (list: WaitingList, busy: Set<String>)?
    /// Each app shows this many, then "N more".
    private static let perApp = 2

    init(model: SquircleModel) {
        answers = WaitingAnswers(model: model)
        super.init(frame: .zero)
        accessibilityIdentifier = "home.waiting"
        stack.axis = .vertical
        stack.spacing = 0
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

    var isEmpty: Bool { stack.arrangedSubviews.isEmpty }

    /// The list, its apps in Home's order. True when what shows changed.
    @discardableResult
    func update(_ list: WaitingList, order: [String], busy: Set<String>) -> Bool {
        var list = list
        list.apps.sort { (order.firstIndex(of: $0.projectID) ?? .max) < (order.firstIndex(of: $1.projectID) ?? .max) }
        // Questions first: a needs-you task can wait in Tasks, an agent can't.
        list.apps = list.apps.map { app in
            let asks = app.items.filter { if case .task = $0 { false } else { true } }
            return WaitingList.App(projectID: app.projectID, name: app.name, items: asks + app.items.filter { if case .task = $0 { true } else { false } })
        }
        if let shown, shown.list == list, shown.busy == busy { return false }
        shown = (list, busy)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard list.count > 0 else { return true }
        let heading = Theme.label("Waiting on you", Theme.font(.footnote, 13, .semibold), color: Theme.accent)
        heading.accessibilityTraits = .header
        let count = Theme.label("\(list.count)", Theme.font(.footnote, 13), color: .tertiaryLabel)
        let top = UIStackView(arrangedSubviews: [heading, count, UIView()])
        top.spacing = 5
        top.alignment = .firstBaseline
        stack.addArrangedSubview(top)
        stack.setCustomSpacing(6, after: top)
        for app in list.apps {
            let name = Theme.label(app.name ?? "App", Theme.font(.footnote, 13, .semibold), color: .secondaryLabel)
            stack.addArrangedSubview(spaced(name, top: 10))
            for item in app.items.prefix(Self.perApp) {
                stack.addArrangedSubview(row(item, project: app.projectID))
            }
            if app.items.count > Self.perApp {
                let more = UIButton(configuration: .plain())
                more.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0)
                more.configuration?.attributedTitle = AttributedString("\(app.items.count - Self.perApp) more in Tasks", attributes: AttributeContainer([
                    .font: Theme.font(.footnote, 13, .semibold), .foregroundColor: Theme.accent]))
                more.contentHorizontalAlignment = .leading
                more.addAction(UIAction { [weak self] _ in self?.onOpen?(app.projectID, nil) }, for: .touchUpInside)
                stack.addArrangedSubview(more)
            }
        }
        return true
    }

    private func spaced(_ view: UIView, top: CGFloat) -> UIView {
        let wrap = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor)
        ])
        return wrap
    }

    /// One item: tapping beside its answers opens where it was asked (a
    /// needs-you task, in the app's Tasks).
    private func row(_ item: WaitingList.Item, project: String) -> UIView {
        let control = HomeWaitingRow()
        answers.configure(control.item, item, about: true) { [weak self] in self?.superview?.setNeedsLayout() }
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if case .task(let task) = item { onOpen?(project, task.taskID) } else { onJump?(project, item) }
        }, for: .touchUpInside)
        return control
    }
}

private final class HomeWaitingRow: UIControl {
    let item = WaitingItemView(compact: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        item.translatesAutoresizingMaskIntoConstraints = false
        addSubview(item)
        NSLayoutConstraint.activate([
            item.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            item.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            item.leadingAnchor.constraint(equalTo: leadingAnchor),
            item.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        // Taps on the text open it; the answer buttons take their own.
        item.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { sendActions(for: .touchUpInside) }
}
