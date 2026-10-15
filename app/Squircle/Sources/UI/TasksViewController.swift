import AVKit
import UIKit

/// The app's tasks beside its agent: what you asked for, grouped by what
/// each needs, with its threads, builds and pictures a tap away. Done work
/// ages into History; the Threads tab is every thread of the app.
@MainActor
final class TasksViewController: UIViewController, UITableViewDelegate {
    /// A thread to open; nil starts a new one.
    var onOpen: ((String?) -> Void)?
    private let model: SquircleModel
    private var project: AppProject
    private let tabs = UISegmentedControl(items: ["Tasks", "Threads"])
    private let close = Theme.glassButton(symbol: "xmark", identifier: "tasks.close", accessibilityLabel: "Close")
    private let header = UIView()
    /// The switch sits on glass like the close button, so rows passing
    /// under it don't show through.
    private let tabsGlass = Theme.glassSurface(cornerRadius: 20)
    // Grouped, so the small group names scroll with their rows instead of
    // sticking over them.
    private let table = UITableView(frame: .zero, style: .grouped)
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private lazy var threads = ThreadsViewController(model: model, project: project, embedded: true)
    private var dataSource: UITableViewDiffableDataSource<Group, String>!
    private var list = AppTasks()
    private var showsHistory = false
    private var query = ""
    private var installing: String?
    /// What each row shows. A row is drawn again only when this changes:
    /// the tasks also carry times and orders that tick without showing.
    private var rows: [String: TaskRow] = [:]
    /// A row's swipe actions are open. The list holds still under the
    /// finger and catches up when they close.
    private var swiping = false
    private var behind = false
    /// Tasks ticked off here that haven't moved yet. The list holds still
    /// while you tick down it; they go to Done together a beat after the last.
    private var checking: [AppTask] = []
    private var settle: Task<Void, Never>?
    /// What the last ticks moved to Done, and what each was, for Undo.
    private var undoable: [(task: AppTask, was: AppTask.Status)] = []
    private var undoExpiry: Task<Void, Never>?
    private let undo = UndoToast()
    private var observation: Task<Void, Never>?
    /// Keeps the app's tasks fresh while the sheet is up.
    private var freshness: RefreshLease?
    /// The next History page is on its way.
    private var loadingHistory = false

    /// Sections top to bottom; done and dropped tasks stay a day before History.
    enum Group: Hashable {
        case status(AppTask.Status), finished, history
        var title: String {
            switch self {
            case .status(.needsYou): "Needs you"
            case .status(.inProgress): "In progress"
            case .status(.readyToTry): "Ready to try"
            case .status(.queued): "Queued"
            case .status: ""
            case .finished: "Done"
            case .history: "History"
            }
        }
        var color: UIColor {
            switch self {
            case .status(.needsYou): Theme.accent
            case .status(.inProgress): Theme.warning
            case .status(.readyToTry): Theme.success
            default: .secondaryLabel
            }
        }
    }
    private static let searchRow = "search"

    init(model: SquircleModel, project: AppProject, threads: Bool = false) {
        self.model = model
        self.project = project
        super.init(nibName: nil, bundle: nil)
        tabs.selectedSegmentIndex = threads ? 1 : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
        ScrollSweep.start(table)
        #endif
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = Theme.paper }
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        tabs.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.renderTab() }, for: .valueChanged)

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.sectionHeaderTopPadding = 0
        table.sectionFooterHeight = 0
        table.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNonzeroMagnitude))
        table.contentInsetAdjustmentBehavior = .never
        table.register(TaskGroupHeader.self, forHeaderFooterViewReuseIdentifier: "group")
        table.register(TaskCell.self, forCellReuseIdentifier: "task")
        table.register(TaskSearchCell.self, forCellReuseIdentifier: Self.searchRow)
        dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
            guard let self else { return UITableViewCell() }
            if id == Self.searchRow {
                let cell = table.dequeueReusableCell(withIdentifier: Self.searchRow, for: path) as! TaskSearchCell
                cell.field.text = query
                cell.onChange = { [weak self] text in self?.query = text; self?.render() }
                return cell
            }
            let cell = table.dequeueReusableCell(withIdentifier: "task", for: path) as! TaskCell
            guard let row = rows[id] else { return cell }
            cell.configure(row)
            cell.onThread = { [weak self] thread in self?.onOpen?(thread) }
            cell.onCheck = { [weak self] in self?.toggleCheck(id) }
            cell.onMedia = { [weak self] media in self?.task(id).map { self?.openMedia(media, of: $0) } }
            cell.onInstall = { [weak self] in
                guard let self, let task = task(id), let build = installable(task).build else { return }
                install(build, for: task)
            }
            cell.loadThumbnail = { [weak self] media in
                guard let self else { return nil }
                guard media.kind == "video" else { return await model.taskMediaData(task: id, media: media.id).flatMap(UIImage.init) }
                guard let url = await model.taskVideo(task: id, media: media.id) else { return nil }
                return await SquircleModel.poster(of: url).flatMap(UIImage.init)
            }
            return cell
        }
        dataSource.defaultRowAnimation = .fade

        notice.textAlignment = .center
        [table, notice].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        undo.onUndo = { [weak self] in self?.undoLast() }
        addChild(threads)
        threads.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(threads.view)
        threads.didMove(toParent: self)
        // The lists run under the controls, which float on the sheet's own
        // glass; rows fade softly beneath them.
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        [close, tabsGlass].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabsGlass.contentView.addSubview(tabs)
        if #available(iOS 26.0, *) {
            table.topEdgeEffect.style = .soft
            threads.scrollView.topEdgeEffect.style = .soft
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.edge = .top
            header.addInteraction(edge)
            self.edge = edge
        }
        threads.scrollView.contentInsetAdjustmentBehavior = .never
        threads.onOpen = { [weak self] id in self?.onOpen?(id) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 40),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 40), close.heightAnchor.constraint(equalToConstant: 40),
            tabsGlass.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            tabsGlass.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabsGlass.widthAnchor.constraint(equalToConstant: 196),
            tabsGlass.heightAnchor.constraint(equalToConstant: 40),
            tabs.topAnchor.constraint(equalTo: tabsGlass.contentView.topAnchor, constant: 3),
            tabs.bottomAnchor.constraint(equalTo: tabsGlass.contentView.bottomAnchor, constant: -3),
            tabs.leadingAnchor.constraint(equalTo: tabsGlass.contentView.leadingAnchor, constant: 3),
            tabs.trailingAnchor.constraint(equalTo: tabsGlass.contentView.trailingAnchor, constant: -3),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            threads.view.topAnchor.constraint(equalTo: view.topAnchor),
            threads.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            threads.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            threads.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notice.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 48),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
        undo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(undo)
        NSLayoutConstraint.activate([
            undo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            undo.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        // No pull to refresh: the lease keeps the list current while it's up,
        // so pulling down at the top dismisses the sheet like any other.
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        freshness = model.keepFresh(.tasks(appID: project.id))
        Task { await model.refreshTasks() }
        renderTab()
        render()
        renderUndo(animated: false)
    }

    #if DEBUG
    /// `SQUIRCLE_DEMO_TICKS=1`: presses the first five circles a fifth of a
    /// second apart, then Undo, as a hurried thumb would.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_TICKS"] == "1" else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            for row in 0..<5 {
                guard let self else { return }
                let cells = table.visibleCells.compactMap { $0 as? TaskCell }
                guard row < cells.count else { return }
                let cell = cells[row]
                cell.debugPressCheck()
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(2))
            self?.undo.debugPress()
        }
    }
    #endif

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Ticks still waiting for their beat are sent before the sheet goes.
        finishChecks()
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private var onTasks: Bool { tabs.selectedSegmentIndex == 0 }
    /// Tells the soft top edge of the shown list where the controls are.
    private var edge: UIInteraction?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Both lists start just below the controls and scroll up under them.
        let top = header.frame.maxY + 4
        for scroll in [table, threads.scrollView] where scroll.contentInset.top != top {
            let atTop = scroll.contentOffset.y <= -scroll.contentInset.top
            scroll.contentInset.top = top
            scroll.verticalScrollIndicatorInsets.top = top
            if atTop { scroll.contentOffset.y = -top }
        }
    }

    private func renderTab() {
        table.isHidden = !onTasks
        threads.view.isHidden = onTasks
        notice.isHidden = !onTasks || !list.tasks.isEmpty || !list.history.isEmpty
        if #available(iOS 26.0, *), let edge = edge as? UIScrollEdgeElementContainerInteraction {
            edge.scrollView = onTasks ? table : threads.scrollView
        }
    }

    private func task(_ id: String) -> AppTask? {
        list.tasks.first { $0.id == id } ?? list.history.first { $0.id == id }
    }

    /// The build a task's row offers. Only the app's newest build installs
    /// from here: an older one would take the app back. The others are named.
    private func installable(_ task: AppTask) -> (build: AppBuild?, shipped: String?) {
        let linked = task.builds.last(where: { $0.state == "succeeded" && $0.installable == true })
            .flatMap { b in model.builds.first { $0.id == b.id } }
        let newest = linked.flatMap { build in
            model.builds.filter { $0.bundleID == build.bundleID && $0.canInstall }.max { $0.date < $1.date }
        }
        let build = linked?.id == newest?.id ? linked : nil
        return (build, build == nil ? linked.map { "In \($0.title) \($0.version)" } : nil)
    }

    private func row(_ task: AppTask) -> TaskRow {
        let (build, shipped) = installable(task)
        return TaskRow(ask: task.ask, status: task.status, checked: !task.status.open || checking.contains { $0.id == task.id },
                       faded: task.archivedAt != nil, note: task.note, shipped: shipped,
                       install: build.map { _ in installing == task.id ? "Opening…" : "Install" },
                       // Archived threads can't be opened any more.
                       threads: task.threads.filter { $0.state != "missing" }, media: task.media)
    }

    /// `now` is for the swipe actions themselves, which move their row
    /// while UIKit closes the swipe.
    private func render(now: Bool = false) {
        guard now || (!swiping && checking.isEmpty) else { behind = true; return }
        behind = false
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        list = model.tasks(for: project)
        var snapshot = NSDiffableDataSourceSnapshot<Group, String>()
        let groups: [Group] = [.status(.needsYou), .status(.inProgress), .status(.readyToTry), .status(.queued), .finished]
        for group in groups {
            let ids = list.tasks.filter { task in
                switch group {
                case .status(let status): task.status == status
                default: !task.status.open
                }
            }.map(\.id)
            guard !ids.isEmpty else { continue }
            snapshot.appendSections([group])
            snapshot.appendItems(ids, toSection: group)
        }
        if !list.history.isEmpty {
            snapshot.appendSections([.history])
            if showsHistory {
                let words = query.lowercased().split(separator: " ")
                let found = list.history.filter { task in
                    let text = (task.ask + " " + task.note + " " + task.threads.compactMap(\.title).joined(separator: " ")).lowercased()
                    return words.allSatisfy { text.contains($0) }
                }
                snapshot.appendItems([Self.searchRow] + found.map(\.id), toSection: .history)
            }
        }
        // Rows whose look changed are drawn again; the rest keep their place.
        // The model changes every few seconds for unrelated reasons, and
        // applying an unchanged list anyway resets an open swipe.
        let previous = rows
        rows = Dictionary((list.tasks + list.history).map { ($0.id, row($0)) }, uniquingKeysWith: { first, _ in first })
        let changed = snapshot.itemIdentifiers.filter { previous[$0] != nil && previous[$0] != rows[$0] }
        let current = dataSource.snapshot()
        let moved = current.sectionIdentifiers != snapshot.sectionIdentifiers || snapshot.sectionIdentifiers.contains {
            current.itemIdentifiers(inSection: $0) != snapshot.itemIdentifiers(inSection: $0)
        }
        if moved || !changed.isEmpty {
            snapshot.reconfigureItems(changed)
            // Only moves animate; a row whose text changed is just redrawn.
            dataSource.apply(snapshot, animatingDifferences: moved && !previous.isEmpty && view.window != nil)
        }
        // Group headers aren't reloaded with their rows; their counts are kept here.
        for (index, group) in snapshot.sectionIdentifiers.enumerated() {
            (table.headerView(forSection: index) as? TaskGroupHeader).map { configure($0, group) }
        }
        notice.text = model.error == nil ? "No tasks yet" : model.error
        renderTab()
    }

    // MARK: Actions

    private func set(_ task: AppTask, _ status: AppTask.Status? = nil, toTop: Bool = false) {
        Theme.selectionHaptic()
        model.markTask(task, status: status, toTop: toTop)
        render(now: true)
        Task { await model.updateTask(task, status: status, toTop: toTop) }
    }

    /// One tap ticks an open task off (or back on before it moves). Rapid
    /// ticks down the list all land: rows stay put until a beat after the
    /// last, then move to Done together.
    private func toggleCheck(_ id: String) {
        guard let task = task(id), task.status.open else { return }
        Theme.checkHaptic()
        if let index = checking.firstIndex(where: { $0.id == id }) { checking.remove(at: index) } else { checking.append(task) }
        let row = row(task)
        rows[id] = row
        if let path = dataSource.indexPath(for: id), let cell = table.cellForRow(at: path) as? TaskCell { cell.configure(row) }
        settle?.cancel()
        settle = nil
        if checking.isEmpty {
            if behind { render() }
            return
        }
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.finishChecks()
        }
    }

    private func finishChecks() {
        settle?.cancel()
        settle = nil
        let batch = checking
        guard !batch.isEmpty else { return }
        checking = []
        batch.forEach { model.markTask($0, status: .done) }
        render(now: true)
        for task in batch { Task { await model.updateTask(task, status: .done) } }
        undoable += batch.map { ($0, $0.status) }
        renderUndo(animated: true)
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            undoable = []
            renderUndo(animated: true)
        }
    }

    /// Puts the last ticked tasks back where they were.
    private func undoLast() {
        let batch = undoable
        guard !batch.isEmpty else { return }
        undoExpiry?.cancel()
        undoable = []
        renderUndo(animated: true)
        Theme.selectionHaptic()
        batch.forEach { model.markTask($0.task, status: $0.was) }
        render(now: true)
        for (task, was) in batch { Task { await model.updateTask(task, status: was) } }
    }

    private func renderUndo(animated: Bool) {
        undo.configure(count: undoable.count)
        let shown = !undoable.isEmpty
        undo.isUserInteractionEnabled = shown
        let apply = { [undo] in
            undo.alpha = shown ? 1 : 0
            undo.transform = shown ? .identity : CGAffineTransform(translationX: 0, y: 16).scaledBy(x: 0.9, y: 0.9)
        }
        guard animated, view.window != nil else { apply(); return }
        UIView.animate(springDuration: 0.4, bounce: 0.2, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    }

    private func install(_ build: AppBuild, for task: AppTask) {
        guard installing == nil else { return }
        installing = task.id
        render()
        Task { [weak self] in
            guard let self else { return }
            await model.install(build)
            installing = nil
            render()
        }
    }

    private func openMedia(_ media: AppTask.Media, of task: AppTask) {
        guard presentedViewController == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            if media.kind == "video" {
                guard let url = await model.taskVideo(task: task.id, media: media.id) else { return }
                let player = AVPlayerViewController()
                player.player = AVPlayer(url: url)
                present(player, animated: true) { player.player?.play() }
            } else if let data = await model.taskMediaData(task: task.id, media: media.id), let image = UIImage(data: data) {
                present(ImageViewController(image: image, title: media.caption.isEmpty ? task.ask : media.caption), animated: true)
            }
        }
    }

    /// The thread a task is about right now: one waiting on you, else one
    /// working, else the newest.
    private func mainThread(of task: AppTask) -> String? {
        let threads = task.threads.filter { $0.state != "missing" }
        return (threads.first { $0.state == "needs-you" } ?? threads.first { $0.state == "working" } ?? threads.last)?.id
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let group = dataSource.sectionIdentifier(for: section) else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "group") as! TaskGroupHeader
        configure(header, group)
        return header
    }

    private func configure(_ header: TaskGroupHeader, _ group: Group) {
        let count = group == .history ? list.history.count : dataSource.snapshot().numberOfItems(inSection: group)
        header.configure(group.title, count: count, color: group.color,
                         chevron: group == .history ? (showsHistory ? "chevron.up" : "chevron.down") : nil)
        header.onTap = group == .history ? { [weak self] in self?.toggleHistory() } : nil
    }

    private func toggleHistory() {
        Theme.selectionHaptic()
        showsHistory.toggle()
        if !showsHistory { query = "" }
        render()
        var snapshot = dataSource.snapshot()
        snapshot.reloadSections([.history])
        dataSource.apply(snapshot, animatingDifferences: false)
        if showsHistory, let section = snapshot.indexOfSection(.history) {
            table.scrollToRow(at: IndexPath(row: 0, section: section), at: .top, animated: true)
        }
    }

    /// History arrives a page at a time, the next as its last row shows.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard list.hasMoreHistory, !loadingHistory, let id = dataSource.itemIdentifier(for: indexPath),
              id == list.history.last?.id else { return }
        loadingHistory = true
        Task { [weak self] in
            guard let self else { return }
            await model.loadMoreHistory(appID: project.id)
            loadingHistory = false
        }
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { UITableView.automaticDimension }
    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat { 44 }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id), let thread = mainThread(of: task) else { return }
        onOpen?(thread)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).flatMap { self.task($0) }.flatMap { self.mainThread(of: $0) } != nil
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) { swiping = true }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        swiping = false
        if behind { render() }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id) else { return nil }
        let done = UIContextualAction(style: .normal, title: "Done") { [weak self] _, _, finish in self?.set(task, .done); finish(true) }
        done.backgroundColor = Theme.success
        let drop = UIContextualAction(style: .destructive, title: "Drop") { [weak self] _, _, finish in self?.set(task, .dropped); finish(true) }
        drop.backgroundColor = Theme.failure
        return UISwipeActionsConfiguration(actions: task.status.open ? [drop, done] : [])
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id), task.status.open else { return nil }
        let top = UIContextualAction(style: .normal, title: "Top") { [weak self] _, _, finish in self?.set(task, toTop: true); finish(true) }
        top.backgroundColor = Theme.accent
        return UISwipeActionsConfiguration(actions: [top])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let statuses: [(AppTask.Status, String, String)] = [
                (.needsYou, "Needs You", "hand.raised"), (.inProgress, "In Progress", "hammer"),
                (.readyToTry, "Ready to Try", "shippingbox"), (.queued, "Queued", "tray"),
                (.done, "Done", "checkmark"), (.dropped, "Drop", "xmark")]
            let status = UIMenu(options: .displayInline, children: statuses.map { value, title, symbol in
                UIAction(title: title, image: UIImage(systemName: symbol), attributes: value == .dropped ? .destructive : [],
                         state: task.status == value ? .on : .off) { _ in self?.set(task, value) }
            })
            let top = UIAction(title: "Move to Top", image: UIImage(systemName: "arrow.up.to.line")) { _ in self?.set(task, toTop: true) }
            return UIMenu(children: (task.status.open ? [top] : []) + [status])
        })
    }
}

/// A status group's name and count: a small coloured label over its rows.
private final class TaskGroupHeader: UITableViewHeaderFooterView {
    var onTap: (() -> Void)?
    private let name = Theme.label("", Theme.font(.footnote, 13, .semibold))
    private let count = Theme.label("", Theme.font(.footnote, 13), color: .tertiaryLabel)
    private let chevron = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        let line = UIStackView(arrangedSubviews: [name, count, chevron, UIView()])
        line.spacing = 5
        line.alignment = .firstBaseline
        line.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24)
        ])
    }

    @objc private func tapped() { onTap?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String, count value: Int, color: UIColor, chevron symbol: String?) {
        name.text = title
        name.textColor = color
        count.text = "\(value)"
        chevron.image = symbol.flatMap { UIImage(systemName: $0) }
        chevron.isHidden = symbol == nil
        isAccessibilityElement = true
        accessibilityTraits = symbol == nil ? .header : [.header, .button]
        accessibilityLabel = "\(title), \(value)"
    }
}

/// Searches History.
private final class TaskSearchCell: UITableViewCell {
    let field = UISearchTextField()
    var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        field.placeholder = "Search history"
        field.addAction(UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// What a task's row shows.
private struct TaskRow: Equatable {
    let ask: String
    let status: AppTask.Status
    /// Shows a tick: done, or ticked here and about to move.
    let checked: Bool
    let faded: Bool
    let note: String
    let shipped: String?
    let install: String?
    let threads: [AppTask.Thread]
    let media: [AppTask.Media]
}

/// One task: your words, a short note, its threads, its pictures and clips,
/// and Install when a build of it is ready.
private final class TaskCell: UITableViewCell {
    var onThread: ((String) -> Void)?
    var onMedia: ((AppTask.Media) -> Void)?
    var onInstall: (() -> Void)?
    var onCheck: (() -> Void)?
    var loadThumbnail: ((AppTask.Media) async -> UIImage?)?
    private let ask = Theme.label("", Theme.font(.body, 17), lines: 3)
    private let note = Theme.label("", Theme.font(.subheadline, 15), color: .secondaryLabel, lines: 2)
    private let chips = UIStackView()
    private let chipScroll = UIScrollView()
    /// Its workers that are alive (working, needing you, stopped on an
    /// error): each is its jelly, its title and how it is doing.
    private let crew = UIStackView()
    private let thumbs = UIStackView()
    private let thumbScroll = UIScrollView()
    private let install = UIButton(configuration: .filled())
    private let rule = UIView()
    /// The round tick at the leading edge; one tap marks the task done.
    private let check = UIButton(type: .custom)
    private let mark = UIImageView()
    private var shownSymbol: String?
    private var loads: [Task<Void, Never>] = []
    private var shown: TaskRow?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Theme.pressedFill
        selectedBackgroundView = selected

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = Theme.onAccent
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 13, bottom: 6, trailing: 13)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.subheadline, 15, .semibold)
            return attributes
        }
        install.configuration = config
        install.setContentHuggingPriority(.required, for: .horizontal)
        install.setContentCompressionResistancePriority(.required, for: .horizontal)
        install.addAction(UIAction { [weak self] _ in self?.onInstall?() }, for: .touchUpInside)
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .light)
        mark.isUserInteractionEnabled = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        check.addSubview(mark)
        check.addAction(UIAction { [weak self] _ in self?.onCheck?() }, for: .touchUpInside)

        for (stack, scroll) in [(chips, chipScroll), (thumbs, thumbScroll)] {
            stack.spacing = 8
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsHorizontalScrollIndicator = false
            scroll.clipsToBounds = false
            scroll.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
            ])
        }
        chipScroll.heightAnchor.constraint(equalToConstant: 30).isActive = true
        thumbScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let text = UIStackView(arrangedSubviews: [ask, note])
        text.axis = .vertical
        text.spacing = 3
        let top = UIStackView(arrangedSubviews: [text, install])
        top.alignment = .center
        top.spacing = 12
        crew.axis = .vertical
        crew.spacing = 8
        crew.alignment = .leading
        let column = UIStackView(arrangedSubviews: [top, crew, chipScroll, thumbScroll])
        column.axis = .vertical
        column.spacing = 8
        rule.backgroundColor = .separator
        [column, rule, check].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 54),
            // A generous target, its circle centred on the ask's first line.
            check.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            check.widthAnchor.constraint(equalToConstant: 46),
            check.heightAnchor.constraint(equalToConstant: 46),
            check.centerYAnchor.constraint(equalTo: ask.topAnchor, constant: 11),
            mark.centerXAnchor.constraint(equalTo: check.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: check.centerYAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rule.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loads.forEach { $0.cancel() }
        loads = []
        shown = nil
    }

    func configure(_ row: TaskRow) {
        ask.text = row.ask
        ask.textColor = row.faded || row.checked ? .secondaryLabel : .label
        let symbol = row.status == .dropped ? "xmark.circle.fill" : row.checked ? "checkmark.circle.fill" : "circle"
        if symbol != shownSymbol, let image = UIImage(systemName: symbol) {
            shownSymbol = symbol
            // Ticking animates; a reused cell just shows its state.
            if shown != nil, shown?.checked != row.checked {
                mark.setSymbolImage(image, contentTransition: .replace.downUp)
            } else {
                mark.image = image
            }
        }
        mark.tintColor = row.status == .dropped ? .tertiaryLabel : row.checked ? Theme.success : .tertiaryLabel
        check.isEnabled = row.status.open
        check.accessibilityLabel = row.checked ? "Done" : "Mark done"
        check.accessibilityTraits = row.checked ? [.button, .selected] : .button
        let detail = [row.faded ? Self.statusName(row.status) : nil, row.note.isEmpty ? nil : row.note, row.shipped].compactMap { $0 }
        note.text = detail.joined(separator: " · ")
        note.isHidden = detail.isEmpty
        install.isHidden = row.install == nil
        install.configuration?.title = row.install

        // Chips and pictures are rebuilt only when they change, so a
        // redrawn row keeps its loaded thumbnails.
        if row.threads != shown?.threads {
            chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
            crew.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let alive = row.threads.filter { Self.mood($0) != nil }, rest = row.threads.filter { Self.mood($0) == nil }
            for thread in alive {
                crew.addArrangedSubview(member(thread))
            }
            for thread in rest {
                chips.addArrangedSubview(chip(thread))
            }
            crew.isHidden = alive.isEmpty
            chipScroll.isHidden = rest.isEmpty
        }
        if row.media != shown?.media {
            loads.forEach { $0.cancel() }
            loads = []
            thumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for media in row.media {
                thumbs.addArrangedSubview(thumbnail(media))
            }
            thumbScroll.isHidden = row.media.isEmpty
        }
        shown = row
        accessibilityLabel = [row.ask, note.text].compactMap { $0 }.joined(separator: ", ")
    }

    #if DEBUG
    func debugPressCheck() {
        check.isHighlighted = true
        check.sendActions(for: .touchUpInside)
        check.isHighlighted = false
    }
    #endif

    private static func statusName(_ status: AppTask.Status) -> String {
        switch status {
        case .needsYou: "Needed you"
        case .inProgress: "Was in progress"
        case .readyToTry: "Was ready to try"
        case .queued: "Was queued"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }

    /// A linked worker's jelly mood while it is alive; nil once it finished.
    private static func mood(_ thread: AppTask.Thread) -> JellyLook.Mood? {
        switch thread.state {
        case "working": .working
        case "needs-you": .needsYou
        case "error": .failed
        default: nil
        }
    }

    /// A live worker: the worker itself (its jelly), its title and how it is
    /// doing. Tapping it opens it.
    private func member(_ thread: AppTask.Thread) -> UIView {
        let mood = Self.mood(thread) ?? .working
        let button = UIControl()
        let jelly = JellyView(.worker(thread.id, mood), canvas: .roomy(22))
        let title = Theme.label(thread.title ?? "Worker", Theme.font(.subheadline, 15, .semibold), lines: 1)
        let (word, color): (String, UIColor) = switch mood {
        case .needsYou: ("Needs you", Theme.warning)
        case .failed: ("Stopped with an error", Theme.failure)
        default: ("Working", .secondaryLabel)
        }
        let state = Theme.label(word, Theme.font(.footnote, 13), color: color, lines: 1)
        let text = UIStackView(arrangedSubviews: [title, state])
        text.axis = .vertical
        text.spacing = 0
        text.isUserInteractionEnabled = false
        [jelly, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; button.addSubview($0) }
        NSLayoutConstraint.activate([
            jelly.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1),
            jelly.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: 1),
            jelly.widthAnchor.constraint(equalToConstant: 22),
            jelly.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: jelly.trailingAnchor, constant: 11),
            text.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor),
            text.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2)
        ])
        button.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onThread?(thread.id) }, for: .touchUpInside)
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityLabel = "Open thread \(thread.title ?? ""), \(word)"
        return button
    }

    /// A linked thread: a dot for what it is doing and its title.
    private func chip(_ thread: AppTask.Thread) -> UIView {
        var config = UIButton.Configuration.plain()
        config.title = thread.title ?? "Thread"
        config.baseForegroundColor = .label
        config.background.backgroundColor = Theme.codeFill
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 11)
        config.imagePadding = 6
        config.image = UIImage(systemName: "circle.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 7))
        config.imageColorTransformer = UIConfigurationColorTransformer { _ in
            switch thread.state {
            case "needs-you": Theme.accent
            case "working": Theme.warning
            case "error": Theme.failure
            default: .tertiaryLabel
            }
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.footnote, 13, .medium)
            return attributes
        }
        config.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: config)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        button.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onThread?(thread.id) }, for: .touchUpInside)
        button.accessibilityLabel = "Open thread \(thread.title ?? "")"
        return button
    }

    private func thumbnail(_ media: AppTask.Media) -> UIView {
        let button = UIButton(type: .custom)
        button.backgroundColor = Theme.codeFill
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        button.imageView?.contentMode = .scaleAspectFill
        button.contentHorizontalAlignment = .fill
        button.contentVerticalAlignment = .fill
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: media.kind == "video" ? 96 : 54),
                                     button.heightAnchor.constraint(equalToConstant: 72)])
        if media.kind == "video" {
            let play = UIImageView(image: UIImage(systemName: "play.fill"))
            play.tintColor = .white
            play.layer.shadowOpacity = 0.4
            play.layer.shadowRadius = 4
            play.layer.shadowOffset = .zero
            play.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(play)
            NSLayoutConstraint.activate([play.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                                         play.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        }
        button.accessibilityLabel = media.caption.isEmpty ? (media.kind == "video" ? "Clip" : "Picture") : media.caption
        button.addAction(UIAction { [weak self] _ in self?.onMedia?(media) }, for: .touchUpInside)
        loads.append(Task { [weak self, weak button] in
            guard let image = await self?.loadThumbnail?(media), !Task.isCancelled else { return }
            button?.setImage(image, for: .normal)
        })
        return button
    }
}

/// Undo for the last ticks: a small glass capsule at the sheet's foot.
private final class UndoToast: UIView {
    var onUndo: (() -> Void)?
    private let surface = Theme.glassSurface(cornerRadius: 20, interactive: true)
    private let text = Theme.label("", Theme.font(.subheadline, 15, .medium), color: .secondaryLabel)
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.setTitle("Undo", for: .normal)
        button.titleLabel?.font = Theme.font(.subheadline, 15, .semibold)
        button.tintColor = Theme.accent
        button.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .touchUpInside)
        let line = UIStackView(arrangedSubviews: [text, button])
        line.spacing = 14
        line.alignment = .center
        [surface, line].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(surface)
        surface.contentView.addSubview(line)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.heightAnchor.constraint(equalToConstant: 40),
            line.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int) {
        // Keeps its words while fading out.
        guard count > 0 else { return }
        text.text = count == 1 ? "Marked done" : "\(count) marked done"
    }

    #if DEBUG
    func debugPress() { button.sendActions(for: .touchUpInside) }
    #endif
}

/// Open tasks at a glance: a small glass capsule of counts above the field,
/// as wide as what it says.
final class TaskStrip: UIControl {
    private let surface = Theme.glassSurface(cornerRadius: 15, interactive: true)
    private let parts = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "agent.taskStrip"
        isAccessibilityElement = true
        accessibilityTraits = .button
        // Never clip: the glass draws its rim and shadow past its bounds.
        if #available(iOS 26.0, *) { surface.cornerConfiguration = .capsule() }
        parts.spacing = 10
        parts.alignment = .center
        [surface, parts].forEach { $0.isUserInteractionEnabled = false; $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(surface)
        surface.contentView.addSubview(parts)
        let height = surface.heightAnchor.constraint(equalToConstant: 30)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
            parts.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
            parts.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 12),
            parts.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // A larger touch than it looks.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -8).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { surface.alpha = isHighlighted ? 0.7 : 1 }
    }

    private var shown: [String] = []

    /// Counts of open tasks; working and needing you are shown by who is on
    /// them (up to three of the crew, overlapping), the rest by a dot.
    func configure(_ open: [AppTask]) {
        func count(_ status: AppTask.Status) -> Int { open.filter { $0.status == status }.count }
        func crew(_ state: String, _ mood: JellyLook.Mood) -> [JellyLook] {
            var seen = Set<String>()
            let threads = open.flatMap(\.threads).filter { $0.state == state && seen.insert($0.id).inserted }
            // No worker on it: the app's agent is.
            return threads.isEmpty ? [.agent(mood)] : threads.prefix(3).map { .worker($0.id, mood) }
        }
        var items: [(Int, String, UIColor, Bool, [JellyLook])] = [
            (count(.needsYou), "needs you", Theme.accent, true, crew("needs-you", .needsYou).prefix(1).map { $0 }),
            (count(.inProgress), "working", Theme.warning, false, crew("working", .working)),
            (count(.readyToTry), "to try", Theme.success, false, [])
        ].filter { $0.0 > 0 }
        if items.isEmpty { items = [(count(.queued), "queued", .tertiaryLabel, false, [])] }
        let texts = items.map { "\($0.0) \($0.1)" }
        let key = texts + items.flatMap { $0.4.map { "\($0)" } }
        guard key != shown else { return }
        shown = key
        parts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let lead: UIView
            if item.4.isEmpty {
                let dot = UIView()
                dot.backgroundColor = item.2
                dot.layer.cornerRadius = 3
                dot.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
                lead = dot
            } else {
                let group = UIStackView(arrangedSubviews: item.4.map { look in
                    let jelly = JellyView(look, canvas: JellyCanvas(size: 16, side: 0.16, top: 0.42, bottom: 0.14))
                    jelly.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([jelly.widthAnchor.constraint(equalToConstant: 16), jelly.heightAnchor.constraint(equalToConstant: 16)])
                    return jelly
                })
                // A little crew, shoulder to shoulder.
                group.spacing = -3
                lead = group
            }
            let label = Theme.label(texts[index], Theme.font(.footnote, 13, .medium), color: item.3 ? .label : .secondaryLabel)
            let part = UIStackView(arrangedSubviews: [lead, label])
            part.spacing = 5
            part.alignment = .center
            parts.addArrangedSubview(part)
        }
        accessibilityLabel = "Tasks: " + texts.joined(separator: ", ")
    }
}
