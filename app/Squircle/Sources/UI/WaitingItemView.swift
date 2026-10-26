import UIKit

/// Answering what waits on you, wherever it shows (the Tasks sheet under
/// its task, a work item's page, Home): questions agents put in the tracker
/// (choices as buttons, or type a reply), workers' own questions and
/// approvals (answered straight to the worker), and needs-you tasks. An
/// answered one leaves every list at once.
@MainActor
final class WaitingAnswers {
    private let model: SquircleModel
    /// A thread's request with several questions: the answers so far, by item.
    private var progress: [String: [String: JSONValue]] = [:]

    init(model: SquircleModel) { self.model = model }

    /// Forgets the answers so far of requests no longer listed.
    func keep(_ ids: Set<String>) { progress = progress.filter { ids.contains($0.key) } }

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
            view.reply(placeholder: "Reply…", busy: busy) { [weak self] text in self?.send(question, text) }
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
                    view.choices([("Decline", nil, false), ("Allow", nil, true)], side: true, busy: busy) { [weak self] index in
                        self?.decide(request, index == 1 ? "accept" : "decline")
                    }
                } else {
                    let prominent: Set<String> = ["accept", "acceptForSession", "acceptAlways"]
                    view.choices(options.map { ($0["label"].string ?? "Choose", $0["warning"].string, prominent.contains($0["decision"].string ?? "")) },
                                 busy: busy) { [weak self] index in
                        if let decision = options[index]["decision"].string { self?.decide(request, decision) }
                    }
                }
                view.reply(placeholder: nil, busy: busy) { _ in }
            }
        case .task(let task):
            view.show(context: about ? task.itemAsk ?? "" : "", worker: nil, title: task.ask, detail: task.note.isEmpty ? nil : task.note, titleLines: 3)
            view.choices([], busy: busy) { _ in }
            view.reply(placeholder: nil, busy: busy) { _ in }
        }
    }

    /// A thread's questions one at a time; the last answer sends them all.
    private func question(_ view: WaitingItemView, _ request: WaitingList.Request, context: String, id: String, busy: Bool,
                          changed: @escaping () -> Void) {
        let questions = request.pending.questions
        let answers = progress[id] ?? [:]
        let index = min(answers.count, max(0, questions.count - 1))
        let question = questions.isEmpty ? JSONValue.null : questions[index]
        let key = question["id"].string ?? question["header"].string ?? "answer"
        var title = question["question"].string ?? "A question for you"
        if questions.count > 1 { title = "\(index + 1) of \(questions.count) · " + title }
        view.show(context: context, worker: request.worker ? request.threadID : nil, title: title, detail: nil)
        let options = question["options"].array
        let answer: (String) -> Void = { [weak self, weak view] value in
            guard let self else { return }
            var answers = answers
            answers[key] = .string(value)
            Theme.selectionHaptic()
            if answers.count >= questions.count {
                Task { await self.model.respond(request, answers: answers) }
            } else {
                progress[id] = answers
                if let view, view.itemID == id {
                    self.question(view, request, context: context, id: id, busy: false, changed: changed)
                    changed()
                }
            }
        }
        view.choices(options.map { ($0["label"].string ?? $0.string ?? "Option", $0["description"].string, false) }, busy: busy) { index in
            answer(options[index]["value"].string ?? options[index]["label"].string ?? options[index].string ?? "")
        }
        view.reply(placeholder: "Something else…", busy: busy, send: answer)
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
/// as plain glass buttons, and a reply field. `compact` (Home): smaller,
/// answers side by side in a row that scrolls, no field.
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
    private let field = UITextField()
    private let fieldWrap = UIView()
    private var onChoose: ((Int) -> Void)?
    private var onSend: ((String) -> Void)?

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
            field.text = nil
            onSend?(text)
        }, for: .editingDidEndOnExit)
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
            answers = buttons
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

    /// Answers as buttons: (title, subtitle, prominent). Stacked, or side by
    /// side (`side`, or always when compact).
    func choices(_ options: [(String, String?, Bool)], side: Bool = false, busy: Bool, choose: @escaping (Int) -> Void) {
        onChoose = choose
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let vertical = !side && !compact
        buttons.axis = vertical ? .vertical : .horizontal
        if !compact {
            buttons.alignment = vertical ? .leading : .fill
            buttons.distribution = vertical ? .fill : .fillEqually
        }
        for (index, option) in options.enumerated() {
            let button = Theme.glassButton(title: option.0, prominent: option.2, identifier: "waiting.option.\(option.0)")
            button.configuration?.subtitle = compact ? nil : option.1
            button.configuration?.titleLineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
            button.configuration?.titleAlignment = vertical ? .leading : .center
            if compact {
                button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
                button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    attributes.font = Theme.font(.subheadline, 15, .semibold)
                    return attributes
                }
            }
            button.contentHorizontalAlignment = vertical ? .leading : .center
            button.isEnabled = !busy
            button.addAction(UIAction { [weak self] _ in self?.onChoose?(index) }, for: .touchUpInside)
            buttons.addArrangedSubview(button)
        }
        (compact ? buttonScroll : buttons).isHidden = options.isEmpty
        if compact { buttonScroll.contentOffset.x = 0 }
    }

    /// A reply field, or none without a placeholder (never when compact).
    func reply(placeholder: String?, busy: Bool, send: @escaping (String) -> Void) {
        onSend = send
        field.placeholder = placeholder
        field.isEnabled = !busy
        fieldWrap.isHidden = compact || placeholder == nil
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
/// more), answerable with a tap where the answers are a few choices. The
/// rest open the app's Tasks sheet at the item.
@MainActor
final class HomeWaitingView: UIView {
    /// Opens an app's Tasks sheet, at an item's task when it has one.
    var onOpen: ((_ project: String, _ task: String?) -> Void)?
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
        if let shown, shown.list == list, shown.busy == busy { return false }
        shown = (list, busy)
        answers.keep(Set(list.apps.flatMap { $0.items.map(\.id) }))
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

    /// One item: tapping beside its answers opens it in the app's Tasks.
    private func row(_ item: WaitingList.Item, project: String) -> UIView {
        let control = HomeWaitingRow()
        answers.configure(control.item, item, about: true) { [weak self] in self?.superview?.setNeedsLayout() }
        let task: String? = switch item {
        case .question(let question): question.taskID
        case .task(let task): task.taskID
        case .request: nil
        }
        control.addAction(UIAction { [weak self] _ in self?.onOpen?(project, task) }, for: .touchUpInside)
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
