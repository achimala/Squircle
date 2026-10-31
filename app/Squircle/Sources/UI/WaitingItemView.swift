import UIKit

/// Answering what waits on you, wherever it shows (the chat where it was
/// asked, the Tasks sheet under its task, Home): questions agents put in
/// the tracker, workers' own questions and approvals (answered straight to
/// the worker), and needs-you tasks. What you've answered so far lives in
/// the model's `QuestionAnswers`, shared with the thread's request card; an
/// answered one leaves every list at once.
@MainActor
final class WaitingAnswers {
    private let model: SquircleModel
    private var drafts: QuestionAnswers { model.questionAnswers }

    init(model: SquircleModel) { self.model = model }

    /// Draws `item` into `view`. `about`: say which task it's for (where
    /// that isn't right above it); otherwise only who asks. `changed` runs
    /// when a request with several questions moves to its next one in place.
    func configure(_ view: WaitingItemView, _ item: WaitingList.Item, about: Bool, changed: @escaping () -> Void = {}) {
        let id = item.id
        view.itemID = id
        let busy = model.answering.contains(id)
        switch item {
        case .question(let question):
            let asker = question.from ?? (about ? nil : "Your agent asks")
            let context = ([asker] + (about ? [question.ask] : [])).compactMap { $0 }.joined(separator: " · ")
            let jelly = question.from == nil ? JellyLook.agent(.needsYou) : .worker(question.threadID ?? "", .needsYou)
            view.show(context: context, asker: jelly, question: question.text, detail: nil)
            view.answers(question.options.map { WaitingItemView.Answer(title: $0) }, busy: busy) { [weak self] index in
                self?.send(question, question.options[index])
            }
            view.reply(placeholder: "Something else…", text: drafts[id].text, busy: busy,
                       edit: { [weak self] text in self?.drafts[id].text = text }) { [weak self] text in self?.send(question, text) }
        case .request(let request):
            let context = (about ? [request.title, request.ask] : [request.worker ? request.title : "Your agent asks"])
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let jelly = request.worker ? JellyLook.worker(request.threadID, .needsYou) : .agent(.needsYou)
            if request.pending.isQuestion {
                question(view, request, context: context, jelly: jelly, id: id, busy: busy, changed: changed)
            } else {
                view.show(context: context, asker: jelly, question: request.pending.title, detail: request.pending.prompt)
                let choices = WaitingItemView.decisions(request.pending)
                view.answers(choices.map(\.answer), busy: busy) { [weak self] index in self?.decide(request, choices[index].decision) }
                view.reply(placeholder: nil, text: "", busy: busy, edit: { _ in }) { _ in }
            }
        case .task(let task):
            // Not a question: a plain row with its note, no card.
            view.show(context: about ? task.itemAsk ?? "" : "", asker: nil, question: task.ask, detail: task.note.isEmpty ? nil : task.note,
                      plain: true)
            view.answers([], busy: busy) { _ in }
            view.reply(placeholder: nil, text: "", busy: busy, edit: { _ in }) { _ in }
        }
    }

    /// A thread's questions one at a time, from the shared draft; the last
    /// answer sends them all.
    private func question(_ view: WaitingItemView, _ request: WaitingList.Request, context: String, jelly: JellyLook, id: String,
                          busy: Bool, changed: @escaping () -> Void) {
        let form = QuestionForm(questions: request.pending.questions, draft: drafts[id])
        view.show(context: context, asker: jelly, question: WaitingItemView.title(form), detail: nil)
        // Each tap reads the draft as it is then (typing changes it in between).
        let step: ((QuestionForm) -> QuestionForm.Step) -> Void = { [weak self, weak view] make in
            guard let self else { return }
            let now = QuestionForm(questions: request.pending.questions, draft: drafts[id])
            switch make(now) {
            case .edit(let draft):
                let advanced = draft.answers.count != now.draft.answers.count
                Theme.selectionHaptic()
                drafts[id] = draft
                if let view, view.itemID == id {
                    self.question(view, request, context: context, jelly: jelly, id: id, busy: false, changed: changed)
                    if advanced { changed() }
                }
            case .send(let answers):
                Theme.selectionHaptic()
                Task { await self.model.respond(request, answers: answers) }
            }
        }
        view.form(form, busy: busy) { index in step { index < form.options.count ? $0.choose(index) : $0.confirm() } }
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

/// The question card, the same in the chat, in Tasks and on Home (and,
/// without its fill, in the thread's request card over the field): a
/// received bubble from whoever asks. Who asks on one Caption line led by
/// their jelly in the glyph slot, the question in Body, then the answers as
/// a list of rows: a mark in the slot (a circle to pick one, a square to
/// pick several, filled when picked), the label wrapping as long as it
/// needs, its description under it, and a last row to write something
/// else. Several picks go with Send. `compact` (Home): the question in
/// three lines and no write-in row.
final class WaitingItemView: UIView {
    struct Answer {
        var title: String
        var detail: String?
        /// Nil: tapping it answers. Otherwise one of several, picked or not.
        var picked: Bool?
    }

    /// The item drawn, so a late redraw never lands on a reused view.
    var itemID: String?
    private let compact: Bool
    private let filled: Bool
    private let context = Theme.label("", Theme.Text.caption, color: .secondaryLabel)
    private let jelly = JellyView(.agent(.needsYou), canvas: .roomy(Theme.Glyph.line))
    private let title = Theme.label("", Theme.Text.body, lines: 0)
    private let detail = Theme.label("", Theme.Text.mono, color: .secondaryLabel, lines: 6)
    private let rows = UIStackView()
    private let send = Theme.glassButton(title: "Send", prominent: true, identifier: "waiting.send")
    private let field = UITextField()
    private let fieldRow = UIView()
    private var onChoose: ((Int) -> Void)?
    private var onSend: ((String) -> Void)?
    private var onEdit: ((String) -> Void)?
    private var sendIndex = 0

    /// `filled` false: no bubble of its own (the request card's glass is its surface).
    init(compact: Bool = false, filled: Bool = true) {
        self.compact = compact
        self.filled = filled
        super.init(frame: .zero)
        if filled {
            backgroundColor = Theme.receivedFill
            layer.cornerRadius = Theme.Radius.large
            layer.cornerCurve = .continuous
        }
        context.lineBreakMode = .byTruncatingTail
        jelly.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line),
                                     jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line)])
        let about = UIStackView(arrangedSubviews: [jelly, context])
        about.spacing = Theme.Space.glyphGap
        about.alignment = .center
        rows.axis = .vertical

        field.font = Theme.Text.body
        field.adjustsFontForContentSizeCategory = true
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
        // Always in place (only hidden), so a redraw never takes the keyboard away.
        let pencil = OptionRow.mark("pencil", color: .tertiaryLabel)
        let rule = OptionRow.rule()
        [rule, pencil, field].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; fieldRow.addSubview($0) }
        fieldRow.isHidden = true
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: fieldRow.topAnchor),
            rule.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor), rule.trailingAnchor.constraint(equalTo: fieldRow.trailingAnchor),
            fieldRow.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            pencil.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor), pencil.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            pencil.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: pencil.trailingAnchor, constant: Theme.Space.glyphGap),
            field.trailingAnchor.constraint(equalTo: fieldRow.trailingAnchor),
            field.topAnchor.constraint(equalTo: fieldRow.topAnchor, constant: Theme.Space.rowPad),
            field.bottomAnchor.constraint(equalTo: fieldRow.bottomAnchor, constant: -Theme.Space.rowPad)
        ])

        send.addAction(UIAction { [weak self] _ in guard let self else { return }; onChoose?(sendIndex) }, for: .touchUpInside)
        let sendRow = UIStackView(arrangedSubviews: [UIView(), send])
        sendRow.isLayoutMarginsRelativeArrangement = true
        sendRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.row, leading: 0, bottom: Theme.Space.tight, trailing: 0)
        sendRow.isHidden = true

        let stack = UIStackView(arrangedSubviews: [about, title, detail, rows, fieldRow, sendRow])
        stack.axis = .vertical
        stack.spacing = Theme.Space.row
        stack.setCustomSpacing(Theme.Space.tight, after: about)
        stack.setCustomSpacing(0, after: rows)
        stack.setCustomSpacing(0, after: fieldRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset = filled ? Theme.Space.card : .zero
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Who asks (`asker`: their jelly) and the question; `detail`, an
    /// approval's command, in Mono under it. `plain`: a needs-you task's
    /// row (its note in Line, no fill, three lines).
    func show(context text: String, asker: JellyLook?, question: String, detail more: String?, plain: Bool = false) {
        backgroundColor = filled && !plain ? Theme.receivedFill : .clear
        title.numberOfLines = compact || plain ? 3 : 0
        detail.font = plain ? Theme.Text.line : Theme.Text.mono
        context.text = text
        context.isHidden = text.isEmpty
        if let asker { jelly.look = asker }
        jelly.isHidden = asker == nil
        context.superview?.isHidden = context.isHidden && jelly.isHidden
        title.text = question
        detail.text = more
        // Home keeps to who asks and the question.
        detail.isHidden = compact || (more ?? "").isEmpty
    }

    /// The answers as rows; `send`: Send's title and whether it can be
    /// tapped, for picks of several (its index is after the answers').
    func answers(_ answers: [Answer], busy: Bool, send: (title: String, enabled: Bool)? = nil, choose: @escaping (Int) -> Void) {
        onChoose = choose
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, answer) in answers.enumerated() {
            let row = OptionRow(answer)
            row.isEnabled = !busy
            row.addAction(UIAction { [weak self] _ in self?.onChoose?(index) }, for: .touchUpInside)
            rows.addArrangedSubview(OptionRow.rule())
            rows.addArrangedSubview(row)
        }
        sendIndex = answers.count
        self.send.configuration?.title = send?.title ?? "Send"
        self.send.isEnabled = !busy && send?.enabled == true
        self.send.superview?.isHidden = send == nil
        rows.isHidden = answers.isEmpty
    }

    /// One of a thread's questions as `QuestionForm` has it.
    func form(_ form: QuestionForm, busy: Bool, choose: @escaping (Int) -> Void) {
        let several = form.multiple
        answers(form.options.map { Answer(title: $0.label, detail: $0.detail, picked: several ? $0.picked : nil) }, busy: busy,
                send: several ? (form.isLast ? "Send" : "Next", form.canConfirm) : nil, choose: choose)
    }

    /// The write-in row, last, showing `text`; none without a placeholder,
    /// and never when compact. `edit` gets each change.
    func reply(placeholder: String?, text: String, busy: Bool, edit: @escaping (String) -> Void, send: @escaping (String) -> Void) {
        onSend = send
        onEdit = edit
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        field.isEnabled = !busy
        fieldRow.isHidden = compact || placeholder == nil
    }

    /// Where Waiting on you took you.
    func mark() { layer.markSpot(in: traitCollection) }

    /// "2 of 3 · Which…" for a thread's question among several.
    static func title(_ form: QuestionForm) -> String {
        let text = form.question["question"].string ?? "A question for you"
        return form.questions.count > 1 ? "\(form.index + 1) of \(form.questions.count) · " + text : text
    }

    /// An approval's choices as rows, each with the decision it sends.
    static func decisions(_ request: PendingRequest) -> [(answer: Answer, decision: String)] {
        guard !request.options.isEmpty else { return [(Answer(title: "Allow"), "accept"), (Answer(title: "Decline"), "decline")] }
        return request.options.compactMap { option in
            option["decision"].string.map { (Answer(title: option["label"].string ?? "Choose", detail: option["warning"].string), $0) }
        }
    }
}

/// One answer: its mark in the glyph slot, its label in Body wrapping as
/// long as it needs, its description in Line, and "Recommended" as a
/// Caption tag in the accent when the asker said so. At least 44 tall.
private final class OptionRow: UIControl {
    static func rule() -> UIView {
        let rule = UIView()
        rule.backgroundColor = .separator
        rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return rule
    }

    /// A mark in Body, centred in the glyph slot.
    static func mark(_ symbol: String, color: UIColor) -> UIImageView {
        let mark = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Theme.symbol(Theme.Text.body)))
        mark.tintColor = color
        mark.contentMode = .center
        return mark
    }

    init(_ answer: WaitingItemView.Answer) {
        super.init(frame: .zero)
        var text = answer.title
        let recommended = text.range(of: "(Recommended)", options: [.caseInsensitive])
        if let recommended { text.removeSubrange(recommended); text = text.trimmingCharacters(in: .whitespaces) }
        let mark = Self.mark(answer.picked == true ? "checkmark.square.fill" : answer.picked == false ? "square" : "circle",
                             color: answer.picked == true ? Theme.accent : .tertiaryLabel)
        let label = Theme.label(text, Theme.Text.body, lines: 0)
        let lines = UIStackView(arrangedSubviews: [label])
        lines.axis = .vertical
        lines.spacing = 2
        if let detail = answer.detail, !detail.isEmpty {
            lines.addArrangedSubview(Theme.label(detail, Theme.Text.line, color: .secondaryLabel, lines: 0))
        }
        if recommended != nil { lines.addArrangedSubview(Theme.label("Recommended", Theme.Text.caption, color: Theme.accent)) }
        [mark, lines].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.isUserInteractionEnabled = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor), mark.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            mark.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -Theme.Text.body.capHeight / 2),
            lines.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: Theme.Space.glyphGap),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.rowPad),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.rowPad)
        ])
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityHint = answer.detail
        accessibilityTraits = answer.picked == true ? [.button, .selected] : .button
        accessibilityIdentifier = "waiting.option.\(text)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? Theme.pressedFill : .clear } }
    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.5 } }
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
        let heading = Theme.label("Waiting on you", Theme.Text.caption, color: .secondaryLabel)
        heading.accessibilityTraits = .header
        let count = Theme.label("\(list.count)", Theme.Text.caption, color: .tertiaryLabel)
        let top = UIStackView(arrangedSubviews: [heading, count, UIView()])
        top.spacing = Theme.Space.tight
        top.alignment = .firstBaseline
        stack.addArrangedSubview(top)
        stack.setCustomSpacing(Theme.Space.row, after: top)
        for app in list.apps {
            let name = Theme.label(app.name ?? "App", Theme.Text.caption, color: .secondaryLabel)
            stack.addArrangedSubview(spaced(name, top: Theme.Space.rowPad))
            for item in app.items.prefix(Self.perApp) {
                stack.addArrangedSubview(row(item, project: app.projectID))
            }
            if app.items.count > Self.perApp {
                let more = UIButton(configuration: .plain())
                more.configuration?.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.row, leading: 0, bottom: Theme.Space.tight, trailing: 0)
                more.configuration?.attributedTitle = AttributedString("\(app.items.count - Self.perApp) more in Tasks", attributes: AttributeContainer([
                    .font: Theme.Text.caption, .foregroundColor: Theme.accent]))
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
            item.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.row),
            item.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.tight),
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
