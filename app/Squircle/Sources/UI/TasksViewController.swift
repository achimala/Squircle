import UIKit

/// The app's tasks beside its agent. The Tasks tab opens on every work item
/// at a glance, grouped by what each needs (needs you and ready to try on
/// top); a row opens the item's page, and pages swipe sideways through the
/// list in the same order. Questions waiting on you sit under their task in
/// Needs you (and on its page), answered right there. Done work ages into
/// History; the Threads tab is every thread of the app.
@MainActor
final class TasksViewController: UIViewController, UIScrollViewDelegate, UITableViewDelegate, UIGestureRecognizerDelegate {
    /// A thread to open; nil starts a new one.
    var onOpen: ((String?) -> Void)?
    /// A question's text tapped: the conversation that asked it, at the spot.
    var onJump: ((WaitingList.Item) -> Void)?
    private let model: SquircleModel
    private var project: AppProject
    private let tabs = UISegmentedControl(items: ["Tasks", "Threads"])
    private let close = Theme.glassButton(symbol: "xmark", identifier: "tasks.close", accessibilityLabel: "Close")
    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "tasks.back", accessibilityLabel: "All tasks")
    private let header = UIView()
    /// The switch sits on glass like the close button, so rows passing
    /// under it don't show through.
    private let tabsGlass = Theme.glassSurface(cornerRadius: Theme.Space.tap / 2)

    /// Where the Tasks tab is: the overview, or one work item's page. Every
    /// frame, visibility and touch below is derived from this and `push`.
    enum Route: Equatable { case overview, item(String) }
    private var route = Route.overview
    /// 0 shows the overview, 1 the pages; one interruptible spring, which an
    /// edge swipe takes over at any frame.
    private let push = SpringDriver()
    private var dragStart: CGFloat?
    /// Back from a page: a swipe right that starts at the left edge. A
    /// plain pan, as a screen-edge one never starts inside a sheet.
    private let edgePan = UIPanGestureRecognizer()

    // The overview. Grouped, so the small group names scroll with their
    // rows instead of sticking over them.
    private let table = UITableView(frame: .zero, style: .grouped)
    /// Pages side by side, in the overview's order; native paging, so a
    /// page follows the finger. Only the shown page and its neighbours exist.
    private let pager = UIScrollView()
    private var pages: [String: WorkItemPage] = [:]
    /// The work items the pages run through: the overview's rows, in order.
    private var order: [String] = []
    private let notice = Theme.label("", Theme.Text.body, color: .secondaryLabel, lines: 0)
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
    private lazy var answers = WaitingAnswers(model: model)
    /// What each question row shows, by row ID (`ask.` and the item's ID).
    private var asks: [String: AskRow] = [:]
    /// What waits on you for each work item.
    private var asked: [String: [WaitingList.Item]] = [:]
    /// A task to show first, once it's listed (a question tapped elsewhere).
    private var focus: String?

    /// Sections top to bottom; done and dropped tasks stay a day before History.
    enum Group: Hashable {
        case search, status(AppTask.Status), finished, history
        var title: String {
            switch self {
            case .status(let status): WorkItemPage.name(status)
            case .finished: "Done"
            case .history: "History"
            case .search: ""
            }
        }
    }
    private static let searchRow = "search"
    private static let askPrefix = "ask."
    /// `about`: it's about one of the item's sub-tasks, so that is named.
    struct AskRow: Equatable { let item: WaitingList.Item; let busy: Bool; let last: Bool; var about = false }
    /// What needs a look comes first: you, then something to try.
    private static let statusOrder: [AppTask.Status] = [.needsYou, .readyToTry, .inProgress, .queued]

    /// The task to open on, at its work item's page.
    private var initialTask: String?

    /// `focus`: a task whose row (or work item's row) shows first; `task`:
    /// a task whose work item's page it opens on.
    init(model: SquircleModel, project: AppProject, threads: Bool = false, focus: String? = nil, task: String? = nil) {
        self.model = model
        self.project = project
        self.focus = focus
        initialTask = task?.lowercased()
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
        view.backgroundColor = Theme.paper
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        back.addAction(UIAction { [weak self] _ in self?.showOverview() }, for: .touchUpInside)
        tabs.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.renderChrome() }, for: .valueChanged)

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.sectionHeaderTopPadding = 0
        table.sectionFooterHeight = 0
        table.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNonzeroMagnitude))
        table.contentInsetAdjustmentBehavior = .never
        table.accessibilityIdentifier = "tasks.overview"
        table.register(TaskGroupHeader.self, forHeaderFooterViewReuseIdentifier: "group")
        table.register(TaskCell.self, forCellReuseIdentifier: "task")
        table.register(TaskSearchCell.self, forCellReuseIdentifier: Self.searchRow)
        table.register(WaitingCell.self, forCellReuseIdentifier: "ask")
        dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
            guard let self else { return UITableViewCell() }
            if id.hasPrefix(Self.askPrefix) {
                let cell = table.dequeueReusableCell(withIdentifier: "ask", for: path) as! WaitingCell
                guard let ask = asks[id] else { return cell }
                cell.setLast(ask.last)
                answers.configure(cell.item, ask.item, about: ask.about) { [weak self] in
                    self?.table.performBatchUpdates(nil)
                }
                return cell
            }
            if id == Self.searchRow {
                let cell = table.dequeueReusableCell(withIdentifier: Self.searchRow, for: path) as! TaskSearchCell
                cell.field.text = query
                cell.onChange = { [weak self] text in self?.query = text; self?.render() }
                return cell
            }
            let cell = table.dequeueReusableCell(withIdentifier: "task", for: path) as! TaskCell
            guard let row = rows[id] else { return cell }
            cell.configure(row)
            cell.onCheck = { [weak self] in self?.toggleCheck(id) }
            cell.onInstall = { [weak self] in self?.task(id).map { self?.install($0) } }
            return cell
        }
        dataSource.defaultRowAnimation = .fade

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.alwaysBounceVertical = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        pager.accessibilityIdentifier = "tasks.pages"
        edgePan.delegate = self
        edgePan.addTarget(self, action: #selector(edgePanned(_:)))
        view.addGestureRecognizer(edgePan)
        // A swipe from the edge goes back; anywhere else it turns the page.
        pager.panGestureRecognizer.require(toFail: edgePan)

        notice.textAlignment = .center
        [table, pager, notice].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        undo.onUndo = { [weak self] in self?.undoLast() }
        addChild(threads)
        threads.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(threads.view)
        threads.didMove(toParent: self)
        // The lists run under the controls, which float on the sheet's own
        // glass; content fades softly beneath them.
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        [close, back, tabsGlass].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
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
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.rowPad),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Space.group),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.group),
            header.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: Theme.Space.tap), close.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: Theme.Space.tap), back.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            tabsGlass.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            tabsGlass.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabsGlass.widthAnchor.constraint(equalToConstant: 196),
            tabsGlass.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            tabs.topAnchor.constraint(equalTo: tabsGlass.contentView.topAnchor, constant: Theme.Space.tight),
            tabs.bottomAnchor.constraint(equalTo: tabsGlass.contentView.bottomAnchor, constant: -Theme.Space.tight),
            tabs.leadingAnchor.constraint(equalTo: tabsGlass.contentView.leadingAnchor, constant: Theme.Space.tight),
            tabs.trailingAnchor.constraint(equalTo: tabsGlass.contentView.trailingAnchor, constant: -Theme.Space.tight),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // A reply field under a question stays above the keyboard.
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            threads.view.topAnchor.constraint(equalTo: view.topAnchor),
            threads.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            threads.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            threads.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notice.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2 * Theme.Space.section),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Space.margin),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.margin)
        ])
        undo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(undo)
        NSLayoutConstraint.activate([
            undo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            undo.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Space.rowPad)
        ])
        push.onChange = { [weak self] _ in self?.applyPush() }
        // No pull to refresh: the lease keeps the list current while it's up,
        // so pulling down at the top dismisses the sheet like any other.
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        freshness = model.keepFresh(.tasks(appID: project.id))
        Task { await model.refreshTasks() }
        render()
        if let task = initialTask { initialTask = nil; open(task: task) }
        renderUndo(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Ticks still waiting for their beat are sent before the sheet goes.
        finishChecks()
    }

    override func accessibilityPerformEscape() -> Bool {
        if onTasks, route != .overview { showOverview(); return true }
        dismiss(animated: true)
        return true
    }

    private var onTasks: Bool { tabs.selectedSegmentIndex == 0 }
    private var openItem: String? { if case .item(let id) = route { id } else { nil } }
    /// Tells the soft top edge of the shown list where the controls are.
    private var edge: UIInteraction?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
        applyPush()
        defer { showFocus() }
        // Every list starts just below the controls and scrolls up under them.
        let top = header.frame.maxY + Theme.Space.tight, bottom = view.safeAreaInsets.bottom + Theme.Space.section
        let scrolls = [table, threads.scrollView] + pages.values.map(\.scroll)
        for scroll in scrolls where scroll.contentInset.top != top || scroll.contentInset.bottom != bottom {
            let atTop = scroll.contentOffset.y <= -scroll.contentInset.top
            scroll.contentInset.top = top
            scroll.contentInset.bottom = bottom
            scroll.verticalScrollIndicatorInsets.top = top
            if atTop { scroll.contentOffset.y = -top }
        }
    }

    // MARK: Route

    /// Opens a work item's page, from its row.
    private func showItem(_ id: String) {
        guard order.contains(id) else { return }
        Theme.selectionHaptic()
        view.endEditing(true)
        route = .item(id)
        layoutPages()
        push.redirect(to: 1)
        renderChrome()
    }

    /// Already on its work item's page as the sheet comes up.
    private func open(task id: String) {
        let list = model.tasks(for: project)
        guard let item = (list.tasks + list.history).first(where: { $0.id.lowercased() == id || $0.subtasks.contains { $0.id.lowercased() == id } }),
              order.contains(item.id) else { return }
        route = .item(item.id)
        layoutPages()
        push.set(1)
        applyPush()
    }

    private func showOverview() {
        guard route != .overview else { return }
        Theme.selectionHaptic()
        route = .overview
        push.redirect(to: 0)
        renderChrome()
    }

    /// The overview slides out to the left as the pages come in from the
    /// right, side by side: a flat push, never one over the other.
    private func applyPush() {
        let width = view.bounds.width, progress = push.value
        table.transform = CGAffineTransform(translationX: -progress * width, y: 0)
        pager.transform = CGAffineTransform(translationX: (1 - progress) * width, y: 0)
        renderChrome()
        mountPages()
    }

    /// Visibility and touches, from the route, the tab and where the push is.
    private func renderChrome() {
        let item = onTasks && route != .overview
        // Whatever the route points at takes touches from its first frame.
        table.isUserInteractionEnabled = !item
        pager.isUserInteractionEnabled = item
        table.isHidden = !onTasks || (item && push.value >= 1)
        pager.isHidden = !onTasks || (!item && push.value <= 0)
        table.accessibilityElementsHidden = item
        pager.accessibilityElementsHidden = !item
        close.isHidden = item
        back.isHidden = !item
        edgePan.isEnabled = item
        threads.view.isHidden = onTasks
        notice.isHidden = !onTasks || !list.tasks.isEmpty || !list.history.isEmpty
        if #available(iOS 26.0, *), let edge = edge as? UIScrollEdgeElementContainerInteraction {
            edge.scrollView = !onTasks ? threads.scrollView : openItem.flatMap { pages[$0]?.scroll } ?? table
        }
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === edgePan else { return true }
        let start = edgePan.location(in: view).x - edgePan.translation(in: view).x
        let velocity = edgePan.velocity(in: view)
        return start < 28 && velocity.x > abs(velocity.y)
    }

    @objc private func edgePanned(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        switch gesture.state {
        case .began:
            dragStart = push.value
            push.set(push.value)
        case .changed:
            push.set(min(1, max(0, (dragStart ?? 1) - gesture.translation(in: view).x / width)))
        default:
            dragStart = nil
            let velocity = -gesture.velocity(in: view).x / width
            if gesture.state == .ended, push.value + velocity * 0.18 < 0.5 {
                Theme.selectionHaptic()
                route = .overview
            }
            push.animate(to: route == .overview ? 0 : 1, initialVelocity: velocity)
            renderChrome()
        }
    }

    // MARK: Pages

    /// Lays the pager out for `order` and puts it on the open item, unless a
    /// finger or a fling is moving it.
    private func layoutPages() {
        let size = pager.bounds.size
        guard size.width > 0 else { return }
        let content = CGSize(width: size.width * CGFloat(max(order.count, 1)), height: size.height)
        if pager.contentSize != content { pager.contentSize = content }
        if !pager.isTracking, !pager.isDecelerating, let id = openItem, let index = order.firstIndex(of: id) {
            let x = CGFloat(index) * size.width
            if pager.contentOffset.x != x { pager.contentOffset = CGPoint(x: x, y: 0) }
        }
        mountPages()
    }

    /// Only the page in view and its neighbours exist, and only while the
    /// pages are on screen; each comes and goes off screen.
    private func mountPages() {
        let size = pager.bounds.size
        var near: [Int] = []
        if size.width > 0, openItem != nil || push.value > 0, !order.isEmpty {
            let position = pager.contentOffset.x / size.width
            near = Array((Int(position.rounded(.down)) - 1)...(Int(position.rounded(.up)) + 1)).filter(order.indices.contains)
        }
        let ids = Set(near.map { order[$0] })
        for (id, page) in pages where !ids.contains(id) { page.removeFromSuperview(); pages[id] = nil }
        for index in near {
            let id = order[index]
            let page: WorkItemPage
            if let mounted = pages[id] { page = mounted } else {
                page = makePage(id)
                task(id).map { page.configure(content(of: $0)) }
            }
            let frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
            if page.frame != frame { page.frame = frame }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.width > 0, !order.isEmpty, openItem != nil else { return }
        mountPages()
        let index = min(max(Int((pager.contentOffset.x / pager.bounds.width).rounded()), 0), order.count - 1)
        guard order[index] != openItem else { return }
        route = .item(order[index])
        renderChrome()
    }

    private func makePage(_ id: String) -> WorkItemPage {
        let page = WorkItemPage()
        page.answers = answers
        page.scroll.contentInsetAdjustmentBehavior = .never
        let top = header.frame.maxY + Theme.Space.tight
        page.scroll.contentInset = UIEdgeInsets(top: top, left: 0, bottom: view.safeAreaInsets.bottom + Theme.Space.section, right: 0)
        page.scroll.verticalScrollIndicatorInsets.top = top
        page.scroll.contentOffset.y = -top
        if #available(iOS 26.0, *) { page.scroll.topEdgeEffect.style = .soft }
        page.onThread = { [weak self] thread in self?.onOpen?(thread) }
        page.onSubtask = { [weak self] sub in self?.task(sub)?.mainThread.map { self?.onOpen?($0) } }
        page.onTick = { [weak self] sub in
            guard let self, let task = task(sub) else { return }
            Theme.checkHaptic()
            set(task, task.status.open ? .done : .queued, haptic: false)
        }
        page.onStatus = { [weak self] status in self?.task(id).map { self?.set($0, status) } }
        page.onTop = { [weak self] in self?.task(id).map { self?.set($0, toTop: true) } }
        page.onInstall = { [weak self] in self?.task(id).map { self?.install($0) } }
        page.onMedia = { [weak self] picture, button in self?.openMedia(picture.media, of: picture.task, from: button) }
        page.loadThumbnail = { [weak self] picture in await self?.thumbnail(picture.media, of: picture.task, height: 220) }
        page.documents = model.documents
        page.onDocument = { [weak self] row in
            guard let self else { return }
            DocumentViewer.open(row, documents: model.documents, from: self)
        }
        pages[id] = page
        pager.addSubview(page)
        return page
    }

    // MARK: Content

    private func task(_ id: String) -> AppTask? {
        list.everyTask.first { $0.id == id }
    }

    /// The build a task offers, its sub-tasks' included. Only the app's
    /// newest build installs from here: an older one would take the app
    /// back. The others are named.
    private func installable(_ task: AppTask) -> (build: AppBuild?, shipped: String?) {
        let linked = (task.builds + task.subtasks.flatMap(\.builds)).last(where: { $0.state == "succeeded" && $0.installable == true })
            .flatMap { b in model.builds.first { $0.id == b.id } }
        let newest = linked.flatMap { build in
            model.builds.filter { $0.bundleID == build.bundleID && $0.canInstall }.max { $0.date < $1.date }
        }
        let build = linked?.id == newest?.id ? linked : nil
        return (build, build == nil ? linked.map { "In \($0.title) \($0.version)" } : nil)
    }

    private func row(_ task: AppTask) -> TaskRow {
        let ticked = checking.contains { $0.id == task.id }
        let threads = task.allThreads
        let worker = threads.first { $0.state == "needs-you" } ?? threads.first { $0.state == "working" } ?? threads.first { $0.state == "error" }
        return TaskRow(ask: task.ask, status: task.status, joined: asked[task.id] != nil && task.status.open, checked: !task.status.open || ticked, faded: task.archivedAt != nil,
                       note: task.note, steps: task.subtasks.isEmpty ? nil : "\(task.subtasks.filter { !$0.status.open }.count)/\(task.subtasks.count)",
                       worker: worker.flatMap { thread in TaskParts.mood(thread).map { .worker(thread.id, $0) } },
                       install: installable(task).build.map { _ in installing == task.id ? "Opening…" : "Install" })
    }

    private func content(of task: AppTask) -> WorkItemPage.Content {
        let (build, shipped) = installable(task)
        let index = order.firstIndex(of: task.id)
        return .init(ask: task.ask, status: task.status, note: task.note, shipped: shipped,
                     install: build.map { _ in installing == task.id ? "Opening…" : "Install" },
                     position: index.map { "\($0 + 1) of \(order.count)" } ?? "",
                     subtasks: task.subtasks.map { .init(id: $0.id, ask: $0.ask, note: $0.note, status: $0.status, opens: $0.mainThread != nil) },
                     threads: task.allThreads.filter { $0.state != "missing" },
                     media: ([task] + task.subtasks).flatMap { owner in owner.media.map { WorkItemPage.Picture(task: owner.id, media: $0) } },
                     asks: (asked[task.id] ?? []).map { item in
                         var about = false
                         if case .question(let question) = item { about = question.taskID != task.id }
                         return .init(item: item, busy: model.answering.contains(item.id), last: false, about: about)
                     })
    }

    /// `now` is for the swipe actions themselves, which move their row
    /// while UIKit closes the swipe.
    private func render(now: Bool = false) {
        guard now || (!swiping && checking.isEmpty) else { behind = true; return }
        behind = false
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        list = model.tasks(for: project)
        // The threads open tasks link to, ready before one is tapped.
        model.prefetch(threads: list.tasks.filter { $0.status.open }.flatMap(\.allThreads).map(\.id))
        // What waits on you here, by the work item it's about; a question
        // nothing claims leads Needs you.
        let waiting = model.waiting.apps.first { $0.projectID == project.id }?.items ?? []
        var loose: [WaitingList.Item] = []
        asked = [:]
        for item in waiting {
            let owner: AppTask? = switch item {
            case .question(let question): list.tasks.first { $0.id == question.taskID || $0.subtasks.contains { $0.id == question.taskID } }
            case .request(let request): list.tasks.first { task in task.status.open && task.allThreads.contains { $0.id == request.threadID } }
            }
            if let owner, owner.status.open { asked[owner.id, default: []].append(item) } else { loose.append(item) }
        }
        let words = query.lowercased().split(separator: " ")
        let found: (AppTask) -> Bool = { task in
            guard !words.isEmpty else { return true }
            let text = ([task.ask, task.note] + task.subtasks.map(\.ask) + task.allThreads.compactMap(\.title)).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Group, String>()
        // Search once the list is long enough to need finding things in.
        if list.tasks.count + list.history.count > 6 {
            snapshot.appendSections([.search])
            snapshot.appendItems([Self.searchRow], toSection: .search)
        }
        let groups: [Group] = Self.statusOrder.map { .status($0) } + [.finished]
        for group in groups {
            var ids = list.tasks.filter { task in
                guard found(task) else { return false }
                // Anything with a question for you is in Needs you.
                if task.status.open, asked[task.id] != nil { return group == .status(.needsYou) }
                return switch group {
                case .status(let status): task.status == status
                default: !task.status.open
                }
            }.flatMap { task in
                [task.id] + (asked[task.id] ?? []).map { Self.askPrefix + $0.id }
            }
            if group == .status(.needsYou), words.isEmpty { ids = loose.map { Self.askPrefix + $0.id } + ids }
            guard !ids.isEmpty else { continue }
            snapshot.appendSections([group])
            snapshot.appendItems(ids, toSection: group)
        }
        if !list.history.isEmpty {
            snapshot.appendSections([.history])
            // A search looks through History too.
            if showsHistory || !words.isEmpty {
                snapshot.appendItems(list.history.filter(found).map(\.id), toSection: .history)
            }
        }
        // Rows whose look changed are drawn again; the rest keep their place.
        // The model changes every few seconds for unrelated reasons, and
        // applying an unchanged list anyway resets an open swipe.
        let previous = rows, previousAsks = asks
        rows = Dictionary((list.tasks + list.history).map { ($0.id, row($0)) }, uniquingKeysWith: { first, _ in first })
        asks = [:]
        let items = Dictionary(waiting.map { (Self.askPrefix + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shownIDs = snapshot.itemIdentifiers
        for (index, id) in shownIDs.enumerated() {
            guard let item = items[id] else { continue }
            let next = shownIDs.indices.contains(index + 1) ? shownIDs[index + 1] : nil
            var about = false
            if case .question(let question) = item { about = !list.tasks.contains { $0.id == question.taskID } }
            asks[id] = AskRow(item: item, busy: model.answering.contains(item.id), last: !(next?.hasPrefix(Self.askPrefix) ?? false), about: about)
        }
        let changed = snapshot.itemIdentifiers.filter {
            (previous[$0] != nil && previous[$0] != rows[$0]) || (previousAsks[$0] != nil && previousAsks[$0] != asks[$0])
        }
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

        // The pages run through the same rows. An open item that left the
        // list (it aged into History, folded) goes back to the overview.
        order = snapshot.itemIdentifiers.filter { $0 != Self.searchRow && !$0.hasPrefix(Self.askPrefix) }
        if let id = openItem, !order.contains(id) {
            route = .overview
            push.redirect(to: 0)
        }
        for (id, page) in pages { task(id).map { page.configure(content(of: $0)) } }
        layoutPages()
        notice.text = model.error == nil ? "No tasks yet" : model.error
        renderChrome()
        showFocus()
    }

    /// The focused task's row at the top, once the list has it.
    private func showFocus() {
        guard let wanted = focus, table.contentInset.top > 0 else { return }
        let id = list.tasks.first { $0.id == wanted || $0.subtasks.contains { $0.id == wanted } }?.id ?? wanted
        guard let path = dataSource.indexPath(for: id) else { return }
        focus = nil
        table.layoutIfNeeded()
        table.scrollToRow(at: path, at: .top, animated: false)
        #if DEBUG
        if ProcessInfo.processInfo.environment["SQUIRCLE_TASK_PAGE"] == "1" { showItem(id) }
        #endif
    }

    // MARK: Actions

    private func set(_ task: AppTask, _ status: AppTask.Status? = nil, toTop: Bool = false, haptic: Bool = true) {
        if haptic { Theme.selectionHaptic() }
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

    private func install(_ task: AppTask) {
        guard installing == nil, let build = installable(task).build else { return }
        installing = task.id
        render()
        Task { [weak self] in
            guard let self else { return }
            await model.install(build)
            installing = nil
            render()
        }
    }

    /// A picture or a clip's poster, with enough pixels for `height` points.
    private func thumbnail(_ media: AppTask.Media, of task: String, height: CGFloat) async -> UIImage? {
        let data: Data?
        if media.kind == "video" {
            guard let url = await model.taskVideo(task: task, media: media.id) else { return nil }
            data = await ConversationMedia.poster(of: url)
        } else {
            data = await model.taskMediaData(task: task, media: media.id)
        }
        guard let data else { return nil }
        return await Downsample.image(data) { height * 3 / max(1, $0.height) }
    }

    /// A task's picture or clip, flown up from its thumbnail.
    private func openMedia(_ media: AppTask.Media, of task: String, from button: UIButton) {
        guard let window = view.window, let poster = button.image(for: .normal) else { return }
        let origin = MediaOrigin { [weak button] in button.map { MediaSpot($0) } }
        if media.kind == "video" {
            MediaViewer.open(.video(poster: poster, size: nil, player: nil, url: { [weak self] in
                await self?.model.taskVideo(task: task, media: media.id)
            }), from: origin, in: window)
        } else {
            MediaViewer.open(.image(poster, size: nil, full: { [weak self] pixels in
                guard let data = await self?.model.taskMediaData(task: task, media: media.id) else { return nil }
                return await Downsample.image(data) { pixels / max(1, $0.width, $0.height) }
            }), from: origin, in: window)
        }
    }

    // MARK: Overview

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let group = dataSource.sectionIdentifier(for: section), group != .search else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "group") as! TaskGroupHeader
        configure(header, group)
        return header
    }

    private func configure(_ header: TaskGroupHeader, _ group: Group) {
        let folds = group == .history && query.isEmpty
        let count = folds ? list.history.count
            : dataSource.snapshot().itemIdentifiers(inSection: group).filter { !$0.hasPrefix(Self.askPrefix) }.count
        header.configure(group.title, count: count,
                         chevron: folds ? (showsHistory ? "chevron.up" : "chevron.down") : nil)
        header.onTap = folds ? { [weak self] in self?.toggleHistory() } : nil
    }

    private func toggleHistory() {
        Theme.selectionHaptic()
        showsHistory.toggle()
        render()
        var snapshot = dataSource.snapshot()
        snapshot.reloadSections([.history])
        dataSource.apply(snapshot, animatingDifferences: false)
        if showsHistory, let section = snapshot.indexOfSection(.history), snapshot.numberOfItems(inSection: .history) > 0 {
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

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        dataSource.sectionIdentifier(for: section) == .search ? CGFloat.leastNonzeroMagnitude : UITableView.automaticDimension
    }
    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat { 44 }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), id != Self.searchRow else { return }
        if let item = asks[id]?.item, item.threadID != nil {
            onJump?(item)
            return
        }
        showItem(id)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        if let item = asks[id]?.item { return item.threadID != nil }
        return id != Self.searchRow
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) { swiping = true }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        swiping = false
        if behind { render() }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id), task.status.open else { return nil }
        let done = UIContextualAction(style: .normal, title: "Done") { [weak self] _, _, finish in self?.set(task, .done); finish(true) }
        done.backgroundColor = Theme.success
        let drop = UIContextualAction(style: .destructive, title: "Drop") { [weak self] _, _, finish in self?.set(task, .dropped); finish(true) }
        drop.backgroundColor = Theme.failure
        return UISwipeActionsConfiguration(actions: [drop, done])
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id), task.status.open else { return nil }
        let top = UIContextualAction(style: .normal, title: "Top") { [weak self] _, _, finish in self?.set(task, toTop: true); finish(true) }
        top.backgroundColor = Theme.accent
        return UISwipeActionsConfiguration(actions: [top])
    }

    /// Long press: any status, to bring one back, or Move to Top.
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let top = UIAction(title: "Move to Top", image: UIImage(systemName: "arrow.up.to.line")) { _ in self?.set(task, toTop: true) }
            return UIMenu(children: (task.status.open ? [top] : []) + [WorkItemPage.statusMenu(current: task.status) { self?.set(task, $0) }])
        })
    }
}

/// A status group's name and count: a Caption label over its rows.
private final class TaskGroupHeader: UITableViewHeaderFooterView {
    var onTap: (() -> Void)?
    private let name = Theme.label("", Theme.Text.caption, color: .secondaryLabel)
    private let count = Theme.label("", Theme.Text.caption, color: .tertiaryLabel)
    private let chevron = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = Theme.symbol(Theme.Text.caption)
        let line = UIStackView(arrangedSubviews: [name, count, chevron, UIView()])
        line.spacing = Theme.Space.tight
        line.alignment = .firstBaseline
        line.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.section),
            line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @objc private func tapped() { onTap?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String, count value: Int, chevron symbol: String?) {
        name.text = title
        count.text = "\(value)"
        chevron.image = symbol.flatMap { UIImage(systemName: $0) }
        chevron.isHidden = symbol == nil
        isAccessibilityElement = true
        accessibilityTraits = symbol == nil ? .header : [.header, .button]
        accessibilityLabel = "\(title), \(value)"
    }
}

/// Searches every task, History included.
private final class TaskSearchCell: UITableViewCell {
    let field = UISearchTextField()
    var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        field.placeholder = "Search tasks"
        field.addAction(UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.row),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.row),
            field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}


/// What a task's overview row shows.
private struct TaskRow: Equatable {
    let ask: String
    let status: AppTask.Status
    /// Its questions follow right under it, with no rule between.
    let joined: Bool
    /// Shows a tick: done, or ticked here and about to move.
    let checked: Bool
    let faded: Bool
    let note: String
    /// Sub-tasks closed of all, "2/5"; nil without sub-tasks.
    let steps: String?
    /// The worker on it while one is alive (working, needing you, stopped).
    let worker: JellyLook?
    let install: String?
}

/// One work item in the overview, compact enough to scan two dozen: a
/// round tick in its status colour, the ask's first lines, sub-task progress
/// and the note on one line, and the worker on it or Install at the end.
/// Tapping the row opens its page.
private final class TaskCell: UITableViewCell {
    var onInstall: (() -> Void)?
    var onCheck: (() -> Void)?
    private let ask = Theme.label("", Theme.Text.body, lines: 2)
    private let note = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 1)
    private let jelly = JellyView(.worker("", .working), canvas: .roomy(Theme.Glyph.line))
    private let install = UIButton(configuration: .filled())
    private let rule = UIView()
    /// The round tick at the leading edge; one tap marks the task done.
    private let check = UIButton(type: .custom)
    private let mark = UIImageView()
    private var shownSymbol: String?
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
        config.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.tight, leading: Theme.Space.rowPad,
                                                       bottom: Theme.Space.tight, trailing: Theme.Space.rowPad)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Text.caption
            return attributes
        }
        install.configuration = config
        install.setContentHuggingPriority(.required, for: .horizontal)
        install.setContentCompressionResistancePriority(.required, for: .horizontal)
        install.addAction(UIAction { [weak self] _ in self?.onInstall?() }, for: .touchUpInside)
        mark.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        mark.isUserInteractionEnabled = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        check.addSubview(mark)
        check.addAction(UIAction { [weak self] _ in self?.onCheck?() }, for: .touchUpInside)
        jelly.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line), jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line)])

        let text = UIStackView(arrangedSubviews: [ask, note])
        text.axis = .vertical
        text.spacing = Theme.Space.tight
        let line = UIStackView(arrangedSubviews: [text, jelly, install])
        line.alignment = .center
        line.spacing = Theme.Space.rowPad
        rule.backgroundColor = .separator
        [line, rule, check].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.rowPad),
            line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.rowPad),
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.text),
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            // A generous target, its mark centred in the glyph slot on the ask's first line.
            check.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin + Theme.Space.glyph / 2),
            check.widthAnchor.constraint(equalToConstant: Theme.Space.tap),
            check.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            check.centerYAnchor.constraint(equalTo: ask.topAnchor, constant: (ask.font.lineHeight / 2).rounded()),
            mark.centerXAnchor.constraint(equalTo: check.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: check.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        shown = nil
    }

    func configure(_ row: TaskRow) {
        ask.text = row.ask
        ask.textColor = row.faded || row.checked ? .secondaryLabel : .label
        let symbol = row.checked ? "checkmark" : WorkItemPage.symbol(row.status)
        if symbol != shownSymbol, let image = UIImage(systemName: symbol) {
            shownSymbol = symbol
            // Ticking animates; a reused cell just shows its state.
            if shown != nil, shown?.checked != row.checked {
                mark.setSymbolImage(image, contentTransition: .replace.downUp)
            } else {
                mark.image = image
            }
        }
        // The mark carries the status, so a row reads on its own; a tick
        // made here shows in success until it moves to Done.
        mark.tintColor = row.checked && row.status.open ? Theme.success : WorkItemPage.symbolColor(row.status)
        check.isEnabled = row.status.open
        check.accessibilityLabel = row.checked ? "Done" : "Mark done"
        check.accessibilityTraits = row.checked ? [.button, .selected] : .button
        let detail = [row.faded ? Self.statusName(row.status) : nil, row.steps,
                      row.note.isEmpty ? nil : row.note].compactMap { $0 }
        note.text = detail.joined(separator: " · ")
        note.isHidden = detail.isEmpty
        if let look = row.worker { jelly.look = look }
        jelly.isHidden = row.worker == nil
        install.isHidden = row.install == nil
        install.configuration?.title = row.install
        rule.isHidden = row.joined
        shown = row
        accessibilityLabel = [row.faded ? nil : WorkItemPage.name(row.status), row.ask, note.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
    }

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
}

/// Undo for the last ticks: a small glass capsule at the sheet's foot.
private final class UndoToast: UIView {
    var onUndo: (() -> Void)?
    private let surface = Theme.glassSurface(cornerRadius: Theme.Space.tap / 2, interactive: true)
    private let text = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.setTitle("Undo", for: .normal)
        button.titleLabel?.font = Theme.Text.lineStrong
        button.tintColor = Theme.accent
        button.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .touchUpInside)
        let line = UIStackView(arrangedSubviews: [text, button])
        line.spacing = Theme.Space.rowPad
        line.alignment = .center
        [surface, line].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(surface)
        surface.contentView.addSubview(line)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            line.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: Theme.Space.group),
            line.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -Theme.Space.group)
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

/// One work item, a page of the Tasks sheet: where it stands (tap
/// for any status), your ask, its note, Install when a build is ready, its
/// sub-tasks as a checklist, its threads, its pictures and clips, and its
/// documents.
final class WorkItemPage: UIView {
    struct Sub: Equatable { let id, ask, note: String; let status: AppTask.Status; let opens: Bool }
    struct Picture: Equatable { let task: String; let media: AppTask.Media }
    struct Content: Equatable {
        let ask: String
        let status: AppTask.Status
        let note: String
        let shipped: String?
        let install: String?
        /// Where it is among the pages, "3 of 24".
        let position: String
        let subtasks: [Sub]
        let threads: [AppTask.Thread]
        let media: [Picture]
        /// What waits on you about it, answered here.
        let asks: [TasksViewController.AskRow]
    }
    /// Draws and answers `asks`.
    var answers: WaitingAnswers?
    var onThread: ((String) -> Void)?
    var onSubtask: ((String) -> Void)?
    var onTick: ((String) -> Void)?
    var onStatus: ((AppTask.Status) -> Void)?
    var onTop: (() -> Void)?
    var onInstall: (() -> Void)?
    var onMedia: ((Picture, UIButton) -> Void)?
    var loadThumbnail: ((Picture) async -> UIImage?)?
    var documents: DocumentFiles?
    var onDocument: ((FileRowView) -> Void)?
    let scroll = UIScrollView()
    private let stack = UIStackView()
    private let status = UIButton(configuration: .plain())
    private let ask = Theme.label("", Theme.Text.title, lines: 0)
    private let note = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 0)
    private let install = UIButton(configuration: .filled())
    private let shipped = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private let position = Theme.label("", Theme.Text.caption, color: .tertiaryLabel)
    private let steps = UIStackView()
    private let questions = UIStackView()
    private let crew = UIStackView()
    private let chips = UIStackView()
    private let pictures = UIStackView()
    private let pictureScroll = UIScrollView()
    private let files = UIStackView()
    private var loads: [Task<Void, Never>] = []
    private var shown: Content?
    private static let pictureHeight: CGFloat = 220

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        stack.axis = .vertical
        stack.spacing = Theme.Space.group
        stack.alignment = .fill
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.imagePlacement = .trailing
        config.imagePadding = Theme.Space.tight
        config.preferredSymbolConfigurationForImage = Theme.symbol(Theme.Text.line)
        config.image = UIImage(systemName: "chevron.down")
        status.configuration = config
        status.showsMenuAsPrimaryAction = true
        status.contentHorizontalAlignment = .leading
        status.accessibilityIdentifier = "task.status"

        var fill = UIButton.Configuration.filled()
        fill.cornerStyle = .capsule
        fill.baseBackgroundColor = Theme.accent
        fill.baseForegroundColor = Theme.onAccent
        fill.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.row, leading: Theme.Space.group,
                                                     bottom: Theme.Space.row, trailing: Theme.Space.group)
        fill.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Text.lineStrong
            return attributes
        }
        install.configuration = fill
        install.addAction(UIAction { [weak self] _ in self?.onInstall?() }, for: .touchUpInside)
        let installRow = UIStackView(arrangedSubviews: [install, shipped, UIView()])
        installRow.spacing = Theme.Space.rowPad
        installRow.alignment = .center

        steps.axis = .vertical
        steps.spacing = 0
        crew.axis = .vertical
        crew.spacing = Theme.Space.row
        crew.alignment = .leading
        chips.spacing = Theme.Space.row
        chips.alignment = .leading
        let chipScroll = UIScrollView()
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.clipsToBounds = false
        pictures.spacing = Theme.Space.row
        pictures.alignment = .center
        pictureScroll.showsHorizontalScrollIndicator = false
        pictureScroll.clipsToBounds = false
        for (inner, outer, height) in [(chips, chipScroll, 30.0), (pictures, pictureScroll, Self.pictureHeight)] {
            inner.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.topAnchor.constraint(equalTo: outer.contentLayoutGuide.topAnchor),
                inner.bottomAnchor.constraint(equalTo: outer.contentLayoutGuide.bottomAnchor),
                inner.leadingAnchor.constraint(equalTo: outer.contentLayoutGuide.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: outer.contentLayoutGuide.trailingAnchor),
                inner.heightAnchor.constraint(equalTo: outer.frameLayoutGuide.heightAnchor),
                outer.heightAnchor.constraint(equalToConstant: height)
            ])
        }
        position.setContentHuggingPriority(.required, for: .horizontal)
        let statusRow = UIStackView(arrangedSubviews: [status, UIView(), position])
        statusRow.alignment = .firstBaseline
        questions.axis = .vertical
        questions.spacing = Theme.Space.group
        files.axis = .vertical
        files.spacing = Theme.Space.row
        [statusRow, ask, note, questions, installRow, steps, crew, chipScroll, pictureScroll, files].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(Theme.Space.row, after: statusRow)
        stack.setCustomSpacing(Theme.Space.row, after: ask)
        stack.setCustomSpacing(Theme.Space.section, after: note)
        stack.setCustomSpacing(Theme.Space.section, after: questions)
        stack.setCustomSpacing(Theme.Space.section, after: installRow)
        stack.setCustomSpacing(Theme.Space.section, after: steps)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.group),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.rowPad),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.margin),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Every status, ticked at `current`, for a page's status and a Done row's menu.
    static func statusMenu(current: AppTask.Status, set: @escaping (AppTask.Status) -> Void) -> UIMenu {
        let statuses: [(AppTask.Status, String)] = [
            (.needsYou, "hand.raised"), (.inProgress, "hammer"), (.readyToTry, "shippingbox"),
            (.queued, "tray"), (.done, "checkmark"), (.dropped, "xmark")]
        return UIMenu(options: .displayInline, children: statuses.map { value, symbol in
            UIAction(title: value == .dropped ? "Drop" : name(value), image: UIImage(systemName: symbol),
                     attributes: value == .dropped ? .destructive : [], state: current == value ? .on : .off) { _ in set(value) }
        })
    }

    static func name(_ status: AppTask.Status) -> String {
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

    /// A status as a flat outline in the glyph slot (never a filled disc).
    static func symbol(_ status: AppTask.Status) -> String {
        switch status {
        case .queued: "circle"
        case .inProgress: "circle.dashed"
        case .needsYou: "exclamationmark.circle"
        case .readyToTry: "checkmark.circle"
        case .done: "checkmark"
        case .dropped: "xmark"
        }
    }

    /// The status mark's colour: its state's, or tertiary when there's nothing to do.
    static func symbolColor(_ status: AppTask.Status) -> UIColor {
        switch status {
        case .queued, .done, .dropped: .tertiaryLabel
        default: color(status)
        }
    }

    func configure(_ content: Content) {
        guard content != shown else { return }
        let was = shown
        shown = content
        status.configuration?.attributedTitle = AttributedString(Self.name(content.status), attributes: AttributeContainer([
            .font: Theme.Text.line, .foregroundColor: Self.color(content.status)]))
        status.tintColor = Self.color(content.status)
        status.menu = UIMenu(children: [
            UIAction(title: "Move to Front", image: UIImage(systemName: "arrow.left.to.line")) { [weak self] _ in self?.onTop?() },
            Self.statusMenu(current: content.status) { [weak self] in self?.onStatus?($0) }])
        status.accessibilityLabel = "Status, \(Self.name(content.status))"
        position.text = content.position
        ask.text = content.ask
        note.text = content.note
        note.isHidden = content.note.isEmpty
        install.configuration?.title = content.install
        install.isHidden = content.install == nil
        shipped.text = content.shipped
        shipped.isHidden = content.shipped == nil
        install.superview?.isHidden = install.isHidden && shipped.isHidden

        if content.asks != was?.asks {
            questions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for ask in content.asks {
                let view = WaitingItemView()
                answers?.configure(view, ask.item, about: ask.about)
                questions.addArrangedSubview(view)
            }
            questions.isHidden = content.asks.isEmpty
        }
        if content.subtasks != was?.subtasks {
            steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for sub in content.subtasks {
                let row = SubtaskRow(sub)
                row.onTick = { [weak self] in self?.onTick?(sub.id) }
                row.addAction(UIAction { [weak self] _ in self?.onSubtask?(sub.id) }, for: .touchUpInside)
                steps.addArrangedSubview(row)
            }
            steps.isHidden = content.subtasks.isEmpty
        }
        if content.threads != was?.threads {
            crew.arrangedSubviews.forEach { $0.removeFromSuperview() }
            chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let alive = content.threads.filter { TaskParts.mood($0) != nil }, rest = content.threads.filter { TaskParts.mood($0) == nil }
            for thread in alive { crew.addArrangedSubview(TaskParts.member(thread) { [weak self] in self?.onThread?(thread.id) }) }
            for thread in rest { chips.addArrangedSubview(TaskParts.chip(thread) { [weak self] in self?.onThread?(thread.id) }) }
            crew.isHidden = alive.isEmpty
            chips.superview?.isHidden = rest.isEmpty
        }
        if content.media != was?.media {
            loads.forEach { $0.cancel() }
            loads = []
            pictures.arrangedSubviews.forEach { $0.removeFromSuperview() }
            files.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let shown = content.media.filter { $0.media.kind != "file" }
            shown.forEach { pictures.addArrangedSubview(picture($0)) }
            pictureScroll.isHidden = shown.isEmpty
            for item in content.media where item.media.kind == "file" {
                guard let documents else { continue }
                let row = FileRowView()
                let media = item.media
                row.show(.attached(task: item.task, media: media.id, name: media.name ?? "Document", bytes: media.bytes.map { Int($0) }),
                         documents: documents)
                row.onOpen = { [weak self] row in self?.onDocument?(row) }
                files.addArrangedSubview(row)
            }
            files.isHidden = files.arrangedSubviews.isEmpty
        }
    }

    /// A screenshot or clip at a readable size; it takes its own shape once loaded.
    private func picture(_ picture: Picture) -> UIView {
        let button = UIButton(type: .custom)
        button.backgroundColor = Theme.codeFill
        button.layer.cornerRadius = Theme.Radius.small
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        button.imageView?.contentMode = .scaleAspectFill
        button.contentHorizontalAlignment = .fill
        button.contentVerticalAlignment = .fill
        button.translatesAutoresizingMaskIntoConstraints = false
        let width = button.widthAnchor.constraint(equalToConstant: picture.media.kind == "video" ? 300 : 102)
        NSLayoutConstraint.activate([width, button.heightAnchor.constraint(equalToConstant: Self.pictureHeight)])
        if picture.media.kind == "video" {
            let play = UIImageView(image: UIImage(systemName: "play.fill"))
            play.tintColor = .white
            play.preferredSymbolConfiguration = Theme.symbol(Theme.Text.body)
            play.layer.shadowOpacity = 0.4
            play.layer.shadowRadius = 6
            play.layer.shadowOffset = .zero
            play.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(play)
            NSLayoutConstraint.activate([play.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                                         play.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        }
        let media = picture.media
        button.accessibilityLabel = media.caption.isEmpty ? (media.kind == "video" ? "Clip" : "Picture") : media.caption
        button.addAction(UIAction { [weak self, weak button] _ in if let button { self?.onMedia?(picture, button) } }, for: .touchUpInside)
        loads.append(Task { [weak self, weak button] in
            guard let image = await self?.loadThumbnail?(picture), !Task.isCancelled, image.size.height > 0 else { return }
            width.constant = min(max(Self.pictureHeight * image.size.width / image.size.height, 90), 360)
            button?.setImage(image, for: .normal)
        })
        return button
    }
}

/// A sub-task in a work item's checklist: a round tick (tap to mark it
/// done, again to reopen it), what it is, and how it stands when that's
/// worth saying. Tapping the rest opens its thread.
private final class SubtaskRow: UIControl {
    var onTick: (() -> Void)?
    private let check = UIButton(type: .custom)
    private let opens: Bool

    init(_ sub: WorkItemPage.Sub) {
        opens = sub.opens
        super.init(frame: .zero)
        let closed = !sub.status.open
        let mark = UIImageView(image: UIImage(systemName: WorkItemPage.symbol(sub.status)))
        mark.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        mark.tintColor = WorkItemPage.symbolColor(sub.status)
        mark.isUserInteractionEnabled = false
        let ask = Theme.label(sub.ask, Theme.Text.body, color: closed ? .secondaryLabel : .label, lines: 0)
        let words = [[.needsYou, .inProgress, .readyToTry].contains(sub.status) ? WorkItemPage.name(sub.status) : nil,
                     sub.note.isEmpty ? nil : sub.note].compactMap { $0 }
        let detail = Theme.label(words.joined(separator: " · "), Theme.Text.line,
                                 color: words.first == sub.note ? .secondaryLabel : WorkItemPage.color(sub.status), lines: 2)
        detail.isHidden = words.isEmpty
        let text = UIStackView(arrangedSubviews: [ask, detail])
        text.axis = .vertical
        text.spacing = Theme.Space.tight
        text.isUserInteractionEnabled = false
        check.addAction(UIAction { [weak self] _ in self?.onTick?() }, for: .touchUpInside)
        check.isEnabled = sub.status != .dropped
        check.accessibilityLabel = closed ? "Done" : "Mark done"
        check.accessibilityTraits = closed ? [.button, .selected] : .button
        [check, mark, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            // The mark in the glyph slot, its target a generous 44.
            check.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.glyph / 2),
            check.widthAnchor.constraint(equalToConstant: Theme.Space.tap),
            check.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            check.centerYAnchor.constraint(equalTo: ask.topAnchor, constant: (ask.font.lineHeight / 2).rounded()),
            mark.centerXAnchor.constraint(equalTo: check.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: check.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.indent),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.row),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.row)
        ])
        isAccessibilityElement = false
        accessibilityElements = [check, text]
        text.isAccessibilityElement = true
        text.accessibilityLabel = ([sub.ask] + words).joined(separator: ", ")
        text.accessibilityTraits = sub.opens ? .button : .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && opens ? Theme.pressedFill : .clear }
    }
}

/// Pieces a Done row and a work item's page share.
@MainActor
enum TaskParts {
    /// A linked worker's jelly mood while it is alive; nil once it finished.
    static func mood(_ thread: AppTask.Thread) -> JellyLook.Mood? {
        switch thread.state {
        case "working": .working
        case "needs-you": .needsYou
        case "error": .failed
        default: nil
        }
    }

    /// A live worker: the worker itself (its jelly), its title and how it is
    /// doing. Tapping it opens it.
    static func member(_ thread: AppTask.Thread, open: @escaping () -> Void) -> UIView {
        let mood = mood(thread) ?? .working
        let button = UIControl()
        let jelly = JellyView(.worker(thread.id, mood), canvas: .roomy(Theme.Glyph.line))
        let title = Theme.label(thread.title ?? "Worker", Theme.Text.lineStrong, lines: 1)
        let (word, color): (String, UIColor) = switch mood {
        case .needsYou: ("Needs you", Theme.warning)
        case .failed: ("Stopped with an error", Theme.failure)
        default: ("Working", Theme.working)
        }
        let state = Theme.label(word, Theme.Text.line, color: color, lines: 1)
        let text = UIStackView(arrangedSubviews: [title, state])
        text.axis = .vertical
        text.spacing = 0
        text.isUserInteractionEnabled = false
        [jelly, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; button.addSubview($0) }
        NSLayoutConstraint.activate([
            jelly.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            jelly.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line),
            jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line),
            text.leadingAnchor.constraint(equalTo: jelly.trailingAnchor, constant: Theme.Space.glyphGap),
            text.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor),
            text.topAnchor.constraint(equalTo: button.topAnchor),
            text.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        button.addAction(UIAction { _ in Theme.selectionHaptic(); open() }, for: .touchUpInside)
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityLabel = "Open thread \(thread.title ?? ""), \(word)"
        return button
    }

    /// A linked thread: a dot for what it is doing and its title.
    static func chip(_ thread: AppTask.Thread, open: @escaping () -> Void) -> UIView {
        var config = UIButton.Configuration.plain()
        config.title = thread.title ?? "Thread"
        config.baseForegroundColor = .label
        config.background.backgroundColor = Theme.codeFill
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.tight, leading: Theme.Space.rowPad,
                                                       bottom: Theme.Space.tight, trailing: Theme.Space.rowPad)
        config.imagePadding = Theme.Space.tight
        // A small dot in the chip's own font.
        config.image = UIImage(systemName: "circle.fill")?
            .withConfiguration(Theme.symbol(Theme.Text.caption).applying(UIImage.SymbolConfiguration(scale: .small)))
        config.imageColorTransformer = UIConfigurationColorTransformer { _ in
            switch thread.state {
            case "needs-you": Theme.warning
            case "working": Theme.working
            case "error": Theme.failure
            default: .tertiaryLabel
            }
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Text.caption
            return attributes
        }
        config.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: config)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        button.addAction(UIAction { _ in Theme.selectionHaptic(); open() }, for: .touchUpInside)
        button.accessibilityLabel = "Open thread \(thread.title ?? "")"
        return button
    }

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
        parts.spacing = Theme.Space.rowPad
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
            parts.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: Theme.Space.rowPad),
            parts.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -Theme.Space.rowPad)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // A larger touch than it looks.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Theme.Space.row, dy: -Theme.Space.row).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { surface.alpha = isHighlighted ? 0.7 : 1 }
    }

    private var shown: (texts: [String], crews: [[JellyLook]])?

    /// Counts of open tasks; working and needing you are shown by who is on
    /// them (up to three of the crew, overlapping), the rest by a dot.
    func configure(_ open: [AppTask]) {
        func count(_ status: AppTask.Status) -> Int { open.filter { $0.status == status }.count }
        func crew(_ state: String, _ mood: JellyLook.Mood) -> [JellyLook] {
            var seen = Set<String>()
            let threads = open.flatMap(\.allThreads).filter { $0.state == state && seen.insert($0.id).inserted }
            // No worker on it: the app's agent is.
            return threads.isEmpty ? [.agent(mood)] : threads.prefix(3).map { .worker($0.id, mood) }
        }
        var items: [(Int, String, UIColor, Bool, [JellyLook])] = [
            (count(.needsYou), "needs you", Theme.warning, true, crew("needs-you", .needsYou).prefix(1).map { $0 }),
            (count(.inProgress), "working", Theme.working, false, crew("working", .working)),
            (count(.readyToTry), "to try", Theme.success, false, [])
        ].filter { $0.0 > 0 }
        if items.isEmpty { items = [(count(.queued), "queued", .tertiaryLabel, false, [])] }
        let texts = items.map { "\($0.0) \($0.1)" }
        // Compared as values: describing looks as text is slow (reflection), and this runs every render.
        let crews = items.map(\.4)
        guard shown?.texts != texts || shown?.crews != crews else { return }
        shown = (texts, crews)
        parts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let lead: UIView
            if item.4.isEmpty {
                let dot = UIView()
                dot.backgroundColor = item.2
                // A capsule: half its size.
                dot.layer.cornerRadius = 3
                dot.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
                lead = dot
            } else {
                let group = UIStackView(arrangedSubviews: item.4.map { look in
                    let jelly = JellyView(look, canvas: JellyCanvas(size: Theme.Glyph.line, side: 0.16, top: 0.42, bottom: 0.14))
                    jelly.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line),
                                                 jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line)])
                    return jelly
                })
                // A little crew, shoulder to shoulder.
                group.spacing = -3
                lead = group
            }
            let label = Theme.label(texts[index], Theme.Text.caption, color: item.3 ? .label : .secondaryLabel)
            let part = UIStackView(arrangedSubviews: [lead, label])
            part.spacing = Theme.Space.tight
            part.alignment = .center
            parts.addArrangedSubview(part)
        }
        accessibilityLabel = "Tasks: " + texts.joined(separator: ", ")
    }
}
