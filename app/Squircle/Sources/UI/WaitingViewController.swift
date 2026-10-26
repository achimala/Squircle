import UIKit

/// Everything waiting on you, across apps, in one list you work down:
/// questions agents put in the tracker (choices as buttons, or type a
/// reply), workers' own questions and approvals (answered straight to the
/// worker), and needs-you tasks (a tap opens the app). Each answered row
/// leaves the list.
@MainActor
final class WaitingViewController: UIViewController, UITableViewDelegate {
    /// Opens an app's agent, or one of its threads.
    var onOpen: ((_ project: String, _ thread: String?) -> Void)?
    private let model: SquircleModel
    /// Shown first: the app you came from.
    private let firstApp: String?
    private let close = Theme.glassButton(symbol: "xmark", identifier: "waiting.close", accessibilityLabel: "Close")
    private let header = UIView()
    private let titleLabel = Theme.label("Waiting on you", Theme.font(.subheadline, 15, .semibold))
    /// The title sits on glass like the Tasks switch, so rows passing under it don't show through.
    private let titleGlass = Theme.glassSurface(cornerRadius: 20)
    private let table = UITableView(frame: .zero, style: .grouped)
    private let notice = Theme.label("Nothing is waiting on you.", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private var dataSource: UITableViewDiffableDataSource<String, String>!
    private var shown = WaitingList()
    private var items: [String: WaitingList.Item] = [:]
    /// A thread's request with several questions: the answers so far.
    private var progress: [String: [String: JSONValue]] = [:]
    private var observation: Task<Void, Never>?
    private var edge: UIInteraction?

    init(model: SquircleModel, firstApp: String? = nil) {
        self.model = model
        self.firstApp = firstApp
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = Theme.paper }
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.delegate = self
        table.keyboardDismissMode = .interactive
        table.sectionHeaderTopPadding = 0
        table.sectionFooterHeight = 0
        table.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNonzeroMagnitude))
        table.contentInsetAdjustmentBehavior = .never
        table.accessibilityIdentifier = "waiting.list"
        table.register(WaitingAppHeader.self, forHeaderFooterViewReuseIdentifier: "app")
        table.register(WaitingCell.self, forCellReuseIdentifier: "item")
        dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
            let cell = table.dequeueReusableCell(withIdentifier: "item", for: path) as! WaitingCell
            guard let self, let item = items[id] else { return cell }
            configure(cell, item, id: id)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
        notice.textAlignment = .center
        titleLabel.textAlignment = .center
        [table, notice, header].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        [close, titleGlass].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        if #available(iOS 26.0, *) { titleGlass.cornerConfiguration = .capsule() }
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleGlass.contentView.addSubview(titleLabel)
        if #available(iOS 26.0, *) {
            table.topEdgeEffect.style = .soft
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.edge = .top
            edge.scrollView = table
            header.addInteraction(edge)
            self.edge = edge
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 40),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 40), close.heightAnchor.constraint(equalToConstant: 40),
            titleGlass.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleGlass.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleGlass.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: titleGlass.contentView.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: titleGlass.contentView.trailingAnchor, constant: -18),
            titleLabel.centerYAnchor.constraint(equalTo: titleGlass.contentView.centerYAnchor),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            notice.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 48),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        Task { [weak model] in await model?.refreshMetadata(fresh: true) }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = header.frame.maxY + 4, bottom = view.safeAreaInsets.bottom + 28
        if table.contentInset.top != top || table.contentInset.bottom != bottom {
            let atTop = table.contentOffset.y <= -table.contentInset.top
            table.contentInset.top = top
            table.contentInset.bottom = bottom
            table.verticalScrollIndicatorInsets.top = top
            if atTop { table.contentOffset.y = -top }
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    // MARK: Rendering

    /// The list from the model: the app you came from first, then the rest
    /// as the Mac orders them. A row is drawn again only when its item changes.
    private func render() {
        var list = model.waiting
        if let first = firstApp, let index = list.apps.firstIndex(where: { $0.projectID == first }) {
            list.apps.insert(list.apps.remove(at: index), at: 0)
        }
        notice.isHidden = list.count > 0
        guard list != shown else { return }
        let old = items
        shown = list
        items = Dictionary(list.apps.flatMap { $0.items.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
        progress = progress.filter { items[$0.key] != nil }
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for app in list.apps {
            snapshot.appendSections([app.projectID])
            snapshot.appendItems(app.items.map(\.id), toSection: app.projectID)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { old[$0] != nil && old[$0] != items[$0] })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func configure(_ cell: WaitingCell, _ item: WaitingList.Item, id: String) {
        let busy = model.answering.contains(id)
        switch item {
        case .question(let question):
            cell.show(context: question.from.map { "\($0) · \(question.ask)" } ?? question.ask,
                      worker: question.from == nil ? nil : question.threadID,
                      title: question.text, detail: nil)
            cell.choices(question.options.map { option in (option, nil, false) }, vertical: true, busy: busy) { [weak self] index in
                self?.send(question, question.options[index])
            }
            cell.reply(placeholder: "Reply…", busy: busy) { [weak self] text in self?.send(question, text) }
        case .request(let request):
            let context = [request.title, request.ask].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if request.pending.isQuestion {
                renderQuestion(cell, request, context: context, id: id, busy: busy)
            } else {
                cell.show(context: context, worker: request.worker ? request.threadID : nil,
                          title: request.pending.title, detail: request.pending.prompt, monospaced: true)
                let options = request.pending.options
                if options.isEmpty {
                    cell.choices([("Decline", nil, false), ("Allow", nil, true)], vertical: false, busy: busy) { [weak self] index in
                        self?.decide(request, index == 1 ? "accept" : "decline")
                    }
                } else {
                    let prominent: Set<String> = ["accept", "acceptForSession", "acceptAlways"]
                    cell.choices(options.map { ($0["label"].string ?? "Choose", $0["warning"].string, prominent.contains($0["decision"].string ?? "")) },
                                 vertical: true, busy: busy) { [weak self] index in
                        if let decision = options[index]["decision"].string { self?.decide(request, decision) }
                    }
                }
                cell.reply(placeholder: nil, busy: busy) { _ in }
            }
        case .task(let task):
            cell.show(context: task.itemAsk ?? "", worker: nil, title: task.ask, detail: task.note.isEmpty ? nil : task.note, titleLines: 3)
            cell.choices([], vertical: true, busy: busy) { _ in }
            cell.reply(placeholder: nil, busy: busy) { _ in }
        }
    }

    /// A thread's questions one at a time; the last answer sends them all.
    private func renderQuestion(_ cell: WaitingCell, _ request: WaitingList.Request, context: String, id: String, busy: Bool) {
        let questions = request.pending.questions
        let answers = progress[id] ?? [:]
        let index = min(answers.count, max(0, questions.count - 1))
        let question = questions.isEmpty ? JSONValue.null : questions[index]
        let key = question["id"].string ?? question["header"].string ?? "answer"
        var title = question["question"].string ?? "A question for you"
        if questions.count > 1 { title = "\(index + 1) of \(questions.count) · " + title }
        cell.show(context: context, worker: request.worker ? request.threadID : nil, title: title, detail: nil)
        let options = question["options"].array
        let answer: (String) -> Void = { [weak self] value in
            guard let self else { return }
            var answers = answers
            answers[key] = .string(value)
            if answers.count >= questions.count {
                Task { await self.model.respond(request, answers: answers) }
            } else {
                progress[id] = answers
                if let path = dataSource.indexPath(for: id), let cell = table.cellForRow(at: path) as? WaitingCell {
                    table.performBatchUpdates { self.renderQuestion(cell, request, context: context, id: id, busy: false) }
                }
            }
        }
        cell.choices(options.map { ($0["label"].string ?? $0.string ?? "Option", $0["description"].string, false) },
                     vertical: true, busy: busy) { index in
            answer(options[index]["value"].string ?? options[index]["label"].string ?? options[index].string ?? "")
        }
        cell.reply(placeholder: "Something else…", busy: busy, send: answer)
    }

    private func send(_ question: WaitingList.Question, _ text: String) {
        Theme.selectionHaptic()
        Task { await model.answer(question, text: text) }
    }

    private func decide(_ request: WaitingList.Request, _ decision: String) {
        Theme.selectionHaptic()
        Task { await model.respond(request, decision: decision) }
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "app") as? WaitingAppHeader
        let id = dataSource.sectionIdentifier(for: section)
        header?.name.text = shown.apps.first { $0.projectID == id }?.name ?? "App"
        return header
    }

    /// A needs-you task opens its app (its thread, if a worker has it); the
    /// rest answer in place.
    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath), case .task = items[id] else { return false }
        return true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), case .task(let task) = items[id],
              let project = dataSource.sectionIdentifier(for: indexPath.section) else { return }
        dismiss(animated: true) { [onOpen] in onOpen?(project, task.threadID) }
    }
}

private final class WaitingAppHeader: UITableViewHeaderFooterView {
    let name = Theme.label("", Theme.font(.footnote, 13, .semibold), color: .secondaryLabel)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        name.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(name)
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            name.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            name.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// One thing waiting on you: what it's about, the question in full, and
/// its answers as plain glass buttons and a reply field.
private final class WaitingCell: UITableViewCell {
    private let context = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel, lines: 2)
    private let jelly = JellyView(.worker("", .needsYou), canvas: .roomy(18))
    private let title = Theme.label("", Theme.font(.body, 17, .semibold), lines: 0)
    private let detail = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel, lines: 4)
    private let buttons = UIStackView()
    private let field = UITextField()
    private let fieldWrap = UIView()
    private let rule = UIView()
    private var onChoose: ((Int) -> Void)?
    private var onSend: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Theme.pressedFill
        selectedBackgroundView = selected
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
        let stack = UIStackView(arrangedSubviews: [about, title, detail, buttons, fieldWrap])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(4, after: about)
        stack.setCustomSpacing(12, after: detail)
        stack.setCustomSpacing(10, after: buttons)
        rule.backgroundColor = .separator
        [stack, rule].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `worker`: the thread whose sprout shows beside what it's about.
    func show(context text: String, worker: String?, title value: String, detail more: String?, monospaced: Bool = false,
              titleLines: Int = 0) {
        title.numberOfLines = titleLines
        context.text = text
        context.isHidden = text.isEmpty
        if let worker { jelly.look = .worker(worker, .needsYou) }
        jelly.isHidden = worker == nil
        title.text = value
        detail.text = more
        detail.font = monospaced ? Theme.font(.footnote, 12.5, monospaced: true) : Theme.font(.footnote, 13)
        detail.isHidden = (more ?? "").isEmpty
    }

    /// Answers as buttons: (title, subtitle, prominent). Stacked, or side by side.
    func choices(_ options: [(String, String?, Bool)], vertical: Bool, busy: Bool, choose: @escaping (Int) -> Void) {
        onChoose = choose
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.axis = vertical ? .vertical : .horizontal
        buttons.alignment = vertical ? .leading : .fill
        buttons.distribution = vertical ? .fill : .fillEqually
        for (index, option) in options.enumerated() {
            let button = Theme.glassButton(title: option.0, prominent: option.2, identifier: "waiting.option.\(option.0)")
            button.configuration?.subtitle = option.1
            button.configuration?.titleLineBreakMode = .byWordWrapping
            button.configuration?.titleAlignment = vertical ? .leading : .center
            button.contentHorizontalAlignment = vertical ? .leading : .center
            button.isEnabled = !busy
            button.addAction(UIAction { [weak self] _ in self?.onChoose?(index) }, for: .touchUpInside)
            buttons.addArrangedSubview(button)
        }
        buttons.isHidden = options.isEmpty
    }

    /// A reply field, or none without a placeholder.
    func reply(placeholder: String?, busy: Bool, send: @escaping (String) -> Void) {
        onSend = send
        field.placeholder = placeholder
        field.isEnabled = !busy
        fieldWrap.isHidden = placeholder == nil
    }
}
