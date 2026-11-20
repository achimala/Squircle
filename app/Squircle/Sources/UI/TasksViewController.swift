import UIKit

/// The app's tasks, pushed in over its agent (the deck's visual gates,
/// 2026-11-20). The overview lists every work item with its four-step bar
/// (Plan, Build, Review, Merge) and the one thing it waits on: Needs you (an
/// approval or a question) first, then Working; Not planned yet, No code and
/// Merged are folded lines below, then History. A row opens the item's page,
/// which is about the step it is on (`GatePage`); pages swipe sideways in the
/// overview's order. Questions waiting on you sit under their item. Threads
/// on no task: working ones at the foot, idle ones folded.
@MainActor
final class TasksViewController: UIViewController, UIScrollViewDelegate, UITableViewDelegate, UIGestureRecognizerDelegate {
    /// Back to the agent (or closing the overlay's sheet).
    var onBack: (() -> Void)?
    /// A thread to push over Tasks.
    var onOpen: ((String) -> Void)?
    /// A finger went down on a line that opens a thread: its page can be made ahead.
    var onPrepare: ((String) -> Void)?
    /// A question's text tapped: the conversation that asked it, at the spot.
    var onJump: ((WaitingList.Item) -> Void)?
    /// Simulator streams for previews.
    weak var host: ConversationHost?
    private let model: SquircleModel
    private var project: AppProject
    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "tasks.back", accessibilityLabel: "Back")
    private let more = Theme.glassButton(symbol: "ellipsis", identifier: "tasks.more", accessibilityLabel: "More")

    /// Where Tasks is: the overview, or one work item's page. Every frame,
    /// visibility and touch below is derived from this and `push`.
    enum Route: Equatable { case overview, item(String) }
    private var route = Route.overview
    /// 0 shows the overview, 1 the pages; one interruptible spring, which an
    /// edge swipe takes over at any frame.
    private let push = SpringDriver()
    private var dragStart: CGFloat?
    /// Back from a page: a swipe right that starts at the left edge.
    private let edgePan = UIPanGestureRecognizer()

    private let table = UITableView(frame: .zero, style: .grouped)
    private let heading = TasksHeading()
    /// Pages side by side, in the overview's order; native paging, so a
    /// page follows the finger. Only the shown page and its neighbours exist.
    private let pager = UIScrollView()
    private var pages: [String: GatePage] = [:]
    /// The work items the pages run through: the overview's rows, in order.
    private var order: [String] = []
    private let notice = Theme.label("", Theme.Text.body, color: .secondaryLabel, lines: 0)
    private var dataSource: UITableViewDiffableDataSource<Group, String>!
    private var list = AppTasks()
    /// Folded groups opened here.
    private var unfolded: Set<String> = []
    private var showsLoose = false
    private var query = ""
    /// What each row shows. A row is drawn again only when this changes:
    /// the tasks also carry times and orders that tick without showing.
    private var rows: [String: TaskRow] = [:]
    private var lines: [String: ThreadLine.Content] = [:]
    private var folds: [String: FoldCell.Content] = [:]
    /// A row's swipe action is open. The list holds still under the
    /// finger and catches up when it closes.
    private var swiping = false
    private var behind = false
    private var observation: Task<Void, Never>?
    /// Keeps the app's tasks fresh while Tasks is up.
    private var freshness: RefreshLease?
    private var loadingHistory = false
    private lazy var answers = WaitingAnswers(model: model)
    /// What each question row shows, by row ID (`ask.` and the item's ID).
    private var asks: [String: AskRow] = [:]
    /// What waits on you for each work item.
    private var asked: [String: [WaitingList.Item]] = [:]
    /// What each thread waiting on you asks, by thread.
    private var asking: [String: String] = [:]
    /// Items whose gate button is on its way to the Mac, and why one wasn't taken.
    private var sending: Set<String> = []
    private var refused: [String: String] = [:]
    /// A task to show first, once it's listed (a question tapped elsewhere).
    private var focus: String?
    /// The task to open on, at its work item's page.
    private var initialTask: String?

    /// Sections top to bottom.
    enum Group: Hashable {
        case search, needsYou, working, folded, loose, history
        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            default: ""
            }
        }
    }
    private static let searchRow = "search"
    private static let askPrefix = "ask."
    private static let loosePrefix = "loose."
    private static let looseFold = "fold.loose"
    private static let historyFold = "fold.history"
    private static let notPlannedFold = "fold.notPlanned"
    private static let noCodeFold = "fold.noCode"
    private static let mergedFold = "fold.merged"
    /// `about`: it's about one of the item's sub-tasks, so that is named.
    struct AskRow: Equatable { let item: WaitingList.Item; let busy: Bool; let last: Bool; var about = false }

    /// `focus`: a task whose row (or work item's row) shows first; `task`:
    /// a task whose work item's page it opens on.
    init(model: SquircleModel, project: AppProject, focus: String? = nil, task: String? = nil) {
        self.model = model
        self.project = project
        self.focus = focus
        initialTask = task?.lowercased()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
        ScrollSweep.start(table)
        #endif
        view.backgroundColor = Theme.paper
        back.addAction(UIAction { [weak self] _ in
            Theme.selectionHaptic()
            if self?.route == .overview { self?.onBack?() } else { self?.showOverview() }
        }, for: .touchUpInside)
        more.showsMenuAsPrimaryAction = true

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.sectionHeaderTopPadding = 0
        table.sectionFooterHeight = 0
        table.contentInsetAdjustmentBehavior = .never
        table.accessibilityIdentifier = "tasks.overview"
        heading.configure(app: project.name)
        table.tableHeaderView = heading
        table.register(TaskGroupHeader.self, forHeaderFooterViewReuseIdentifier: "group")
        table.register(TaskCell.self, forCellReuseIdentifier: "task")
        table.register(TaskSearchCell.self, forCellReuseIdentifier: Self.searchRow)
        table.register(WaitingCell.self, forCellReuseIdentifier: "ask")
        table.register(ThreadCell.self, forCellReuseIdentifier: "thread")
        table.register(FoldCell.self, forCellReuseIdentifier: "fold")
        // A finger down on a thread line: its page can start being made.
        table.addGestureRecognizer(TouchDown { [weak self] point in
            guard let self, let id = threadLine(at: point, in: table) else { return }
            onPrepare?(id)
        })
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
            if let fold = folds[id] {
                let cell = table.dequeueReusableCell(withIdentifier: "fold", for: path) as! FoldCell
                cell.configure(fold)
                return cell
            }
            if let line = lines[id] {
                let cell = table.dequeueReusableCell(withIdentifier: "thread", for: path) as! ThreadCell
                cell.line.configure(line, feeds: host?.simulatorFeeds)
                return cell
            }
            let cell = table.dequeueReusableCell(withIdentifier: "task", for: path) as! TaskCell
            guard let row = rows[id] else { return cell }
            cell.configure(row, feeds: host?.simulatorFeeds)
            cell.onThread = { [weak self] thread in self?.openThread(thread) }
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
        [back, more].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        if #available(iOS 26.0, *) {
            table.topEdgeEffect.style = .soft
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.edge = .top
            back.addInteraction(edge)
            self.edge = edge
        }
        NSLayoutConstraint.activate([
            // Where every conversation's back button is.
            back.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.tight),
            back.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Space.group),
            back.widthAnchor.constraint(equalToConstant: Theme.Space.tap), back.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            more.topAnchor.constraint(equalTo: back.topAnchor),
            more.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.group),
            more.widthAnchor.constraint(equalToConstant: Theme.Space.tap), more.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // A reply field under a question stays above the keyboard.
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notice.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 4 * Theme.Space.section),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Space.margin),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.margin)
        ])
        push.onChange = { [weak self] _ in self?.applyPush() }
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        freshness = model.keepFresh(.tasks(appID: project.id))
        Task { await model.refreshTasks() }
        render()
        if let task = initialTask { initialTask = nil; open(task: task) }
        #if DEBUG
        // `SQUIRCLE_TASKS_SCROLL=POINTS`: for stills, the shown list scrolled that far (at most to its end).
        if let points = ProcessInfo.processInfo.environment["SQUIRCLE_TASKS_SCROLL"].flatMap(Double.init) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                let scroll = openItem.flatMap { self.pages[$0]?.scroll } ?? table
                let end = max(-scroll.contentInset.top, scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height)
                scroll.setContentOffset(CGPoint(x: 0, y: min(end, -scroll.contentInset.top + points)), animated: false)
            }
        }
        #endif
    }

    /// Leaving for good.
    func tearDown() {
        observation?.cancel()
        freshness = nil
    }

    override func accessibilityPerformEscape() -> Bool {
        if route != .overview { showOverview() } else { onBack?() }
        return true
    }

    /// Back swipes from the left edge belong to the host only on the
    /// overview; on a page they go back to the overview here.
    func allowsBackSwipe(at point: CGPoint) -> Bool { route == .overview && push.value <= 0.001 }

    /// Shows a task: its row first (`focus`), or its work item's page (`task`).
    func show(focus: String?, task: String?) {
        if let task { open(task: task.lowercased()); return }
        guard let focus else { return }
        if route != .overview { route = .overview; push.set(0); applyPush() }
        self.focus = focus
        showFocus()
    }

    /// The work item a thread is for, by name, to name it on top of the thread.
    func taskName(for thread: String) -> String? {
        list.tasks.first { $0.allThreads.contains { $0.id == thread } }?.name
    }

    private var openItem: String? { if case .item(let id) = route { id } else { nil } }
    /// Tells the soft top edge of the shown list where the controls are.
    private var edge: UIInteraction?
    /// Where lists and pages start: just below the back button.
    private var contentTop: CGFloat { view.safeAreaInsets.top + Theme.Space.tight + Theme.Space.tap + Theme.Space.tight }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
        applyPush()
        defer { showFocus() }
        let width = table.bounds.width
        // The table sets its header's width, never its height.
        let fitted = width > 0 ? heading.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                                 verticalFittingPriority: .fittingSizeLevel) : .zero
        if width > 0, heading.frame.size != fitted {
            heading.frame.size = fitted
            table.tableHeaderView = heading
        }
        // Every list starts just below the controls and scrolls up under them.
        let top = contentTop, bottom = view.safeAreaInsets.bottom + Theme.Space.section
        let scrolls = [table] + pages.values.map(\.scroll)
        for scroll in scrolls where scroll.contentInset.top != top || scroll.contentInset.bottom != bottom {
            let atTop = scroll.contentOffset.y <= -scroll.contentInset.top
            scroll.contentInset.top = top
            scroll.contentInset.bottom = bottom
            scroll.verticalScrollIndicatorInsets.top = top
            if atTop { scroll.contentOffset.y = -top }
        }
        pages.values.forEach { $0.top = top }
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

    /// Already on its work item's page as Tasks comes up.
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
        view.endEditing(true)
        route = .overview
        push.redirect(to: 0)
        renderChrome()
    }

    private func openThread(_ id: String) {
        Theme.selectionHaptic()
        view.endEditing(true)
        onOpen?(id)
    }

    /// The overview slides out to the left as the pages come in from the
    /// right, side by side: a flat push, never one over the other.
    private func applyPush() {
        let width = view.bounds.width, progress = push.value
        table.update(\.transform, to: CGAffineTransform(translationX: -progress * width, y: 0))
        pager.update(\.transform, to: CGAffineTransform(translationX: (1 - progress) * width, y: 0))
        renderChrome()
        mountPages()
    }

    /// Visibility and touches, from the route and where the push is.
    private func renderChrome() {
        let item = route != .overview
        // Whatever the route points at takes touches from its first frame.
        table.update(\.isUserInteractionEnabled, to: !item)
        pager.update(\.isUserInteractionEnabled, to: item)
        table.update(\.isHidden, to: item && push.value >= 1)
        pager.update(\.isHidden, to: !item && push.value <= 0)
        table.accessibilityElementsHidden = item
        pager.accessibilityElementsHidden = !item
        back.accessibilityLabel = item ? "All tasks" : "Back"
        edgePan.isEnabled = item
        // The item's menu: Change… and Drop, while it is open.
        let shown = openItem.flatMap { task($0) }
        more.update(\.isHidden, to: !(item && shown?.status.open == true))
        if let shown, more.menu?.title != shown.id { more.menu = menu(for: shown) }
        // The notice stands in for an empty overview.
        notice.isHidden = item || dataSource.snapshot().itemIdentifiers.contains { $0 != Self.searchRow }
        if #available(iOS 26.0, *), let edge = edge as? UIScrollEdgeElementContainerInteraction {
            edge.scrollView = openItem.flatMap { pages[$0]?.scroll } ?? table
        }
    }

    private func menu(for task: AppTask) -> UIMenu {
        var actions: [UIAction] = []
        if task.gate?.kind != .notPlanned {
            actions.append(UIAction(title: "Change…", image: UIImage(systemName: "text.bubble")) { [weak self] _ in self?.change(task) })
        }
        actions.append(UIAction(title: "Drop", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            self?.drop(task)
        })
        return UIMenu(title: task.id, options: .displayInline, children: actions)
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
            view.endEditing(true)
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
        for (id, page) in pages where !ids.contains(id) {
            page.removeFromSuperview()
            pages[id] = nil
        }
        for index in near {
            let id = order[index]
            let page: GatePage
            if let mounted = pages[id] { page = mounted } else {
                page = makePage(id)
                configure(page, id)
            }
            let frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
            if page.frame != frame { page.frame = frame }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.width > 0, !order.isEmpty, openItem != nil else { return }
        mountPages()
        let index = min(max(Int((pager.contentOffset.x / pager.bounds.width).rounded()), 0), order.count - 1)
        if order[index] != openItem {
            route = .item(order[index])
            view.endEditing(true)
        }
        renderChrome()
    }

    private func makePage(_ id: String) -> GatePage {
        let page = GatePage()
        page.answers = answers
        page.feeds = host?.simulatorFeeds
        page.top = contentTop
        page.scroll.contentInsetAdjustmentBehavior = .never
        page.scroll.contentInset = UIEdgeInsets(top: contentTop, left: 0, bottom: view.safeAreaInsets.bottom + Theme.Space.section, right: 0)
        page.scroll.verticalScrollIndicatorInsets.top = contentTop
        page.scroll.contentOffset.y = -contentTop
        if #available(iOS 26.0, *) { page.scroll.topEdgeEffect.style = .soft }
        page.onThread = { [weak self] thread in self?.openThread(thread) }
        page.onPrepare = { [weak self] thread in self?.onPrepare?(thread) }
        page.onApprovePlan = { [weak self] bind in
            self?.press(id) { try await $0.approvePlan(taskID: id, round: bind.round, digest: bind.digest) }
        }
        page.onApproveMerge = { [weak self] bind in
            self?.press(id) { try await $0.approveMerge(taskID: id, round: bind.round, head: bind.head) }
        }
        page.onChange = { [weak self] in self?.task(id).map { self?.change($0) } }
        page.onClose = { [weak self] in self?.press(id) { try await $0.closeTask(taskID: id) } }
        page.onItem = { [weak self] item in
            guard let self else { return }
            if order.contains(item) { route = .item(item); layoutPages(); renderChrome() }
        }
        page.load = { [weak self] picture, height in await self?.image(picture, of: id, height: height) }
        page.onPictures = { [weak self] pictures, index, views in self?.openPictures(pictures, at: index, views: views, of: id) }
        pages[id] = page
        pager.addSubview(page)
        return page
    }

    private func configure(_ page: GatePage, _ id: String) {
        guard let task = task(id) else { return }
        page.configure(content(of: task))
    }

    // MARK: Content

    private func task(_ id: String) -> AppTask? {
        list.everyTask.first { $0.id == id }
    }

    /// Live threads first by what they need: you, then working, stopped, finished.
    private static func rank(_ thread: AppTask.Thread) -> Int {
        switch thread.state {
        case "needs-you": 0
        case "working": 1
        case "error": 2
        default: 3
        }
    }

    /// A thread's line: its Sprout, title, what it is doing, and its live simulator.
    private func line(_ thread: AppTask.Thread, previews: [String: SimulatorTarget]) -> ThreadLine.Content {
        let (mood, doing): (JellyLook.Mood, String) = switch thread.state {
        case "needs-you": (.needsYou, asking[thread.id] ?? "Needs you")
        case "working": (.working, thread.step ?? "Working")
        case "error": (.failed, "Stopped with an error")
        default: (.done, thread.said ?? "Finished")
        }
        let title = thread.title.map { $0.hasPrefix(project.name + " · ") ? String($0.dropFirst(project.name.count + 3)) : $0 } ?? "Worker"
        return .init(id: thread.id, title: title, doing: doing, mood: mood, preview: previews[thread.id].map(ThreadLine.Preview.live))
    }

    /// An item's live threads as lines, the ones that need you or work first.
    private func lines(of task: AppTask, previews: [String: SimulatorTarget]) -> [ThreadLine.Content] {
        task.allThreads.filter { $0.state != "missing" }
            .sorted { Self.rank($0) < Self.rank($1) }
            .map { line($0, previews: previews) }
    }

    private func row(_ task: AppTask, previews: [String: SimulatorTarget]) -> TaskRow {
        let open = task.status.open && task.archivedAt == nil
        // A working worker's line under a working row: what it is doing now.
        let threads = open ? lines(of: task, previews: previews).filter { $0.mood == .working || $0.mood == .needsYou } : []
        let gate = task.gate
        let label: String, detail: String, tone: UIColor
        if let gate, gate.kind == .code {
            label = gate.label ?? ""
            detail = gate.detail ?? ""
            tone = gate.tone.map(GateLook.color) ?? .secondaryLabel
        } else if let gate, gate.kind == .noCode {
            label = gate.label ?? ""
            detail = ""
            tone = gate.answers?.isEmpty == false ? Theme.success : .secondaryLabel
        } else if let gate, gate.kind == .notPlanned {
            label = "\(gate.detail ?? "")"
            detail = ""
            tone = .secondaryLabel
        } else {
            label = TaskLook.name(task.status)
            detail = task.note
            tone = .secondaryLabel
        }
        return TaskRow(title: task.name, steps: gate?.kind == .code ? gate?.steps : nil, label: label, detail: detail, tone: tone,
                       joined: asked[task.id] != nil && task.status.open, faded: task.archivedAt != nil,
                       threads: Array(threads.prefix(1)))
    }

    private func content(of task: AppTask) -> GatePage.Content {
        let asks = (asked[task.id] ?? []).map { item in
            var about = false
            if case .question(let question) = item { about = question.taskID != task.id }
            return TasksViewController.AskRow(item: item, busy: model.answering.contains(item.id), last: false, about: about)
        }
        let open = task.status.open && task.archivedAt == nil
        return .init(task: task, threads: open ? lines(of: task, previews: previewTargets()) : [], asks: asks,
                     sending: sending.contains(task.id), refused: refused[task.id])
    }

    /// The live simulator each thread of the app holds, by thread.
    private func previewTargets() -> [String: SimulatorTarget] {
        guard host?.simulatorFeeds != nil else { return [:] }
        var targets: [String: SimulatorTarget] = [:]
        for use in model.activeSimulators(for: project) { if let target = use.target { targets[use.threadID] = target } }
        return targets
    }

    /// Which group a work item is listed in.
    private enum Place { case needsYou, working, notPlanned, noCode, merged, history }

    private func place(_ task: AppTask) -> Place {
        if task.archivedAt != nil { return task.gate?.merged != nil ? .merged : .history }
        if task.status.open, asked[task.id] != nil { return .needsYou }
        guard let gate = task.gate else { return task.status.open ? .working : .history }
        switch gate.group {
        case .needsYou?: return .needsYou
        case .notPlanned?: return .notPlanned
        case .noCode?: return .noCode
        case .merged?: return .merged
        case .closed?: return .history
        case .working?, nil: return task.status.open ? .working : .history
        }
    }

    /// `now` is for the swipe action itself, which moves its row while UIKit closes the swipe.
    private func render(now: Bool = false) {
        guard now || !swiping else { behind = true; return }
        behind = false
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        list = model.tasks(for: project)
        let previews = previewTargets()
        // The threads open tasks link to, ready before one is tapped.
        model.prefetch(threads: list.tasks.filter { $0.status.open }.flatMap(\.allThreads).filter { $0.state != "missing" }.map(\.id))
        // What waits on you here, by the work item it's about; a question
        // nothing claims leads Needs you.
        let waiting = (model.waiting.apps.first { $0.projectID == project.id }?.items ?? []).filter {
            if case .approval = $0 { return false }
            return true
        }
        var loose: [WaitingList.Item] = []
        asked = [:]
        asking = [:]
        for item in waiting {
            switch item {
            case .question(let question): if let thread = question.threadID { asking[thread] = question.text }
            case .request(let request): asking[request.threadID] = request.pending.isQuestion
                ? request.pending.questions.first?["question"].string ?? request.pending.title : request.pending.title
            case .approval: break
            }
            let owner: AppTask? = switch item {
            case .question(let question): list.tasks.first { $0.id == question.taskID || $0.subtasks.contains { $0.id == question.taskID } }
            case .request(let request): list.tasks.first { task in task.status.open && task.allThreads.contains { $0.id == request.threadID } }
            case .approval: nil
            }
            if let owner, owner.status.open { asked[owner.id, default: []].append(item) } else { loose.append(item) }
        }
        let words = query.lowercased().split(separator: " ")
        let found: (AppTask) -> Bool = { task in
            guard !words.isEmpty else { return true }
            let text = ([task.name, task.ask, task.note] + task.subtasks.flatMap { [$0.name, $0.ask] } + task.allThreads.compactMap(\.title)).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Group, String>()
        // Search once the list is long enough to need finding things in.
        if list.tasks.count + list.history.count > 6 {
            snapshot.appendSections([.search])
            snapshot.appendItems([Self.searchRow], toSection: .search)
        }
        let all = (list.tasks + list.history).filter(found)
        let placed = Dictionary(grouping: all, by: place)
        // Needs you, then Working, each most recently active first (the Mac's order).
        let needs = (placed[.needsYou] ?? []).flatMap { [$0.id] + (asked[$0.id] ?? []).map { Self.askPrefix + $0.id } }
        let lead = words.isEmpty ? loose.map { Self.askPrefix + $0.id } : []
        if !(lead + needs).isEmpty {
            snapshot.appendSections([.needsYou])
            snapshot.appendItems(lead + needs, toSection: .needsYou)
        }
        if let working = placed[.working], !working.isEmpty {
            snapshot.appendSections([.working])
            snapshot.appendItems(working.map(\.id), toSection: .working)
        }
        // Not planned yet, No code and Merged: folded lines.
        var nextFolds: [String: FoldCell.Content] = [:]
        var foldedIDs: [String] = []
        let week = Date.now.timeIntervalSince1970 - 7 * 24 * 3600
        let merged = (placed[.merged] ?? []).filter { ($0.gate?.merged?.at ?? 0) >= week || $0.archivedAt == nil }
        for (fold, items, text, symbol, count) in [
            (Self.notPlannedFold, placed[.notPlanned] ?? [], "Not planned yet", "tray",
             (placed[.notPlanned] ?? []).reduce(0) { $0 + $1.subtasks.filter(\.status.open).count }),
            (Self.noCodeFold, placed[.noCode] ?? [], "No code", "questionmark.bubble", (placed[.noCode] ?? []).count),
            (Self.mergedFold, merged, "Merged this week", "arrow.triangle.merge", merged.count)
        ] where !items.isEmpty {
            let open = unfolded.contains(fold) || !words.isEmpty
            nextFolds[fold] = .init(symbol: symbol, text: text, count: count, open: open)
            foldedIDs.append(fold)
            if open { foldedIDs += items.map(\.id) }
        }
        if !foldedIDs.isEmpty {
            snapshot.appendSections([.folded])
            snapshot.appendItems(foldedIDs, toSection: .folded)
        }
        // Threads on no task: working ones show, idle ones fold.
        let linked = Set((list.tasks + list.history).flatMap(\.allThreads).map(\.id))
        let unlinked = model.sessions(for: project).filter { session in
            !linked.contains(session.id) && (words.isEmpty || words.allSatisfy { session.title.lowercased().contains($0) })
        }
        let busy = unlinked.filter { $0.phase != .idle }, idle = unlinked.filter { $0.phase == .idle }
        var nextLines: [String: ThreadLine.Content] = [:]
        for session in unlinked {
            let (mood, doing): (JellyLook.Mood, String) = switch session.phase {
            case .needsYou: (.needsYou, asking[session.id] ?? "Needs you")
            case .working: (.working, "Working")
            case .idle: (.done, Theme.relativeDate.localizedString(for: session.updatedAt, relativeTo: .now))
            }
            nextLines[Self.loosePrefix + session.id] = .init(id: session.id, title: session.displayTitle(in: project), doing: doing, mood: mood,
                                                            preview: previews[session.id].map(ThreadLine.Preview.live))
        }
        if !busy.isEmpty || !idle.isEmpty {
            var ids = busy.map { Self.loosePrefix + $0.id }
            if !idle.isEmpty {
                nextFolds[Self.looseFold] = .init(symbol: "bubble.left.and.bubble.right", text: "Not on a task", count: idle.count, open: showsLoose || !words.isEmpty)
                ids.append(Self.looseFold)
                if showsLoose || !words.isEmpty { ids += idle.map { Self.loosePrefix + $0.id } }
            }
            snapshot.appendSections([.loose])
            snapshot.appendItems(ids, toSection: .loose)
        }
        let history = (placed[.history] ?? []) + (placed[.merged] ?? []).filter { !merged.map(\.id).contains($0.id) }
        if !history.isEmpty {
            // A search looks through History too.
            let open = unfolded.contains(Self.historyFold) || !words.isEmpty
            nextFolds[Self.historyFold] = .init(symbol: "clock.arrow.circlepath", text: "History", count: history.count, open: open)
            snapshot.appendSections([.history])
            snapshot.appendItems([Self.historyFold] + (open ? history.map(\.id) : []), toSection: .history)
        }
        // Rows whose look changed are drawn again; the rest keep their place.
        let previous = rows, previousAsks = asks, previousLines = lines, previousFolds = folds
        rows = Dictionary((list.tasks + list.history).map { ($0.id, row($0, previews: previews)) }, uniquingKeysWith: { first, _ in first })
        lines = nextLines
        folds = nextFolds
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
                || (previousLines[$0] != nil && previousLines[$0] != lines[$0]) || (previousFolds[$0] != nil && previousFolds[$0] != folds[$0])
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
        order = snapshot.itemIdentifiers.filter { rows[$0] != nil }
        if let id = openItem, !order.contains(id) {
            route = .overview
            push.redirect(to: 0)
        }
        for (id, page) in pages { configure(page, id) }
        layoutPages()
        notice.text = model.error == nil ? "No tasks yet" : model.error
        more.menu = nil
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
        let environment = ProcessInfo.processInfo.environment
        if environment["SQUIRCLE_TASK_PAGE"] == "1" { showItem(id) }
        #endif
    }

    /// The thread whose line is under `point`, in a row of the overview.
    private func threadLine(at point: CGPoint, in table: UITableView) -> String? {
        guard let path = table.indexPathForRow(at: point), let cell = table.cellForRow(at: path) else { return nil }
        if let cell = cell as? ThreadCell { return cell.line.threadID }
        return (cell as? TaskCell)?.thread(at: table.convert(point, to: cell))
    }

    // MARK: Actions

    /// A gate button: sent once, the page busy meanwhile, and the Mac's
    /// reason shown under it if it refused (the plan or review moved on).
    private func press(_ id: String, _ action: @escaping (SquircleClient) async throws -> Void) {
        guard !sending.contains(id) else { return }
        Theme.checkHaptic()
        sending.insert(id)
        refused[id] = nil
        render(now: true)
        Task { [weak self] in
            guard let self else { return }
            let error = await model.gate(action)
            sending.remove(id)
            refused[id] = error
            render(now: true)
        }
    }

    /// Change… (Ask more… on a No code item): your words go on the item,
    /// and its agent has them.
    private func change(_ task: AppTask) {
        let noCode = task.gate?.kind == .noCode
        let alert = UIAlertController(title: noCode ? "Ask more" : "What should change?",
                                      message: noCode ? nil : "Your words go on “\(task.name)”; the agent ties them to the plan.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = noCode ? "Your question" : "Your words"
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Send", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            self?.press(task.id) { try await $0.changeTask(taskID: task.id, text: text) }
        })
        present(alert, animated: true)
    }

    private func drop(_ task: AppTask) {
        Theme.selectionHaptic()
        model.markTask(task, status: .dropped)
        render(now: true)
        Task { await model.updateTask(task, status: .dropped) }
    }

    /// A page's picture, from the round it was handed in with or the item's media.
    private func image(_ picture: GatePicture, of task: String, height: CGFloat) async -> UIImage? {
        switch picture {
        case .round(let kind, let round, let path):
            return await model.roundPicture(task: task, kind: kind, round: round, path: path, height: height)
        case .media(let id):
            let media = self.task(task)?.media.first { $0.id == id } ?? AppTask.Media(id: id, kind: "image", caption: "", name: nil, bytes: nil)
            return await model.taskThumbnail(task: task, media: media, height: height)
        }
    }

    /// A page's pictures full screen, from the one tapped; swipe through the rest.
    private func openPictures(_ pictures: [GatePicture], at index: Int, views: [GatePicture: UIView], of task: String) {
        guard let window = view.window else { return }
        let items: [ViewerItem] = pictures.map { picture in
            let origin = MediaOrigin { [weak view = views[picture]] in view.map { MediaSpot($0) } }
            if case .media(let id) = picture, let media = self.task(task)?.media.first(where: { $0.id == id }) {
                return .task(media, of: task, poster: (views[picture] as? UIButton)?.image(for: .normal), origin: origin, model: model)
            }
            return ViewerItem(media: .image((views[picture] as? UIButton)?.image(for: .normal), size: nil, full: { [weak self] pixels in
                await self?.image(picture, of: task, height: pixels / 3)
            }), origin: origin)
        }
        MediaViewer.open(items, at: index, in: window)
    }

    // MARK: Overview

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let group = dataSource.sectionIdentifier(for: section), !group.title.isEmpty else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "group") as! TaskGroupHeader
        configure(header, group)
        return header
    }

    private func configure(_ header: TaskGroupHeader, _ group: Group) {
        let count = dataSource.snapshot().itemIdentifiers(inSection: group).filter { rows[$0] != nil }.count
        header.configure(group.title, count: count)
    }

    private func toggle(fold id: String) {
        Theme.selectionHaptic()
        if id == Self.looseFold { showsLoose.toggle() } else if unfolded.remove(id) == nil { unfolded.insert(id) }
        render()
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

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // A preview off screen stops showing its simulator.
        (cell as? TaskCell)?.hidePreviews(feeds: host?.simulatorFeeds)
        (cell as? ThreadCell)?.line.hidePreview(feeds: host?.simulatorFeeds)
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch dataSource.sectionIdentifier(for: section) {
        case .search?: CGFloat.leastNonzeroMagnitude
        // Folded lines say what they are; a section's gap is all they need.
        case .folded?, .loose?, .history?: Theme.Space.section - Theme.Space.row
        default: UITableView.automaticDimension
        }
    }
    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat { Theme.Space.tap }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), id != Self.searchRow else { return }
        if folds[id] != nil { toggle(fold: id); return }
        if let line = lines[id] { openThread(line.id); return }
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

    /// Swipe to drop: done is merged (or closed by you on a No code item's page).
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id), task.status.open else { return nil }
        let drop = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, finish in self?.drop(task); finish(true) }
        drop.image = SwipeLabel.image(symbol: "xmark", title: "Drop", in: tableView.traitCollection)
        drop.backgroundColor = Theme.failure
        drop.accessibilityLabel = "Drop"
        return UISwipeActionsConfiguration(actions: [drop])
    }

    #if DEBUG
    /// Verification only: Tasks' own taps, for the host's stress run.
    func debugActions() -> [() -> Void] {
        var actions: [() -> Void] = []
        if route == .overview {
            for id in order.shuffled().prefix(2) { actions.append { [weak self] in self?.showItem(id) } }
        } else {
            actions.append { [weak self] in self?.showOverview() }
            if let id = openItem, let index = order.firstIndex(of: id), order.indices.contains(index + 1) {
                actions.append { [weak self] in
                    guard let self else { return }
                    // Where a swipe to the next page lands.
                    pager.setContentOffset(CGPoint(x: CGFloat(index + 1) * pager.bounds.width, y: 0), animated: false)
                }
            }
        }
        return actions
    }

    /// Threads a stress run may open over Tasks.
    var debugThreads: [String] { list.tasks.flatMap(\.allThreads).filter { $0.state != "missing" }.map(\.id) }

    /// At rest, exactly the routed level shows and takes touches.
    func debugViolation() -> String? {
        guard !push.isAnimating, dragStart == nil, !pager.isTracking, !pager.isDecelerating else { return nil }
        switch route {
        case .overview:
            if push.value != 0 || table.isHidden || !table.isUserInteractionEnabled { return "tasks overview not showing at rest" }
        case .item(let id):
            if push.value != 1 || pager.isHidden || pages[id] == nil { return "task page not showing at rest" }
            if pages[id].map({ abs($0.frame.minX - pager.contentOffset.x) > 0.5 }) == true { return "task page out of place" }
        }
        return nil
    }
    #endif
}

/// What a work item's overview row shows.
private struct TaskRow: Equatable {
    let title: String
    /// Its four-step bar; nil for an item with no code gates.
    let steps: [Gate.Step]?
    /// The one thing it waits on ("Approve merge"), in its step's colour, then a detail.
    let label: String
    let detail: String
    let tone: UIColor
    /// Its questions follow right under it, with no rule between.
    let joined: Bool
    let faded: Bool
    /// Its live worker, nested under it.
    let threads: [ThreadLine.Content]
}

/// One work item in the overview: its title, then its four-step bar and the
/// one thing it waits on, and its working thread nested under it. Tapping
/// the thread opens it; the rest of the row opens the item's page.
private final class TaskCell: UITableViewCell {
    var onThread: ((String) -> Void)?
    private let title = Theme.label("", Theme.Text.body, lines: 2)
    private let bar = StageBar()
    private let status = Theme.label("", Theme.Text.line, lines: 1)
    private let threads = UIStackView()
    private let rule = UIView()
    private var shown: TaskRow?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Theme.pressedFill
        selectedBackgroundView = selected
        bar.setContentHuggingPriority(.required, for: .horizontal)
        let line = UIStackView(arrangedSubviews: [bar, status])
        line.spacing = Theme.Space.row
        line.alignment = .center
        threads.axis = .vertical
        threads.spacing = Theme.Space.tight
        let text = UIStackView(arrangedSubviews: [title, line, threads])
        text.axis = .vertical
        text.spacing = Theme.Space.tight
        text.setCustomSpacing(Theme.Space.row, after: line)
        rule.backgroundColor = .separator
        [text, rule].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.rowPad),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.rowPad),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            rule.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
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

    func configure(_ row: TaskRow, feeds: SimulatorFeeds?) {
        title.text = row.title
        title.textColor = row.faded ? .secondaryLabel : .label
        bar.isHidden = row.steps == nil
        if let steps = row.steps { bar.configure(steps) }
        let words = NSMutableAttributedString(string: row.label, attributes: [.font: Theme.Text.line, .foregroundColor: row.tone])
        if !row.detail.isEmpty {
            words.append(NSAttributedString(string: (row.label.isEmpty ? "" : " · ") + row.detail,
                                            attributes: [.font: Theme.Text.line, .foregroundColor: UIColor.secondaryLabel]))
        }
        status.attributedText = words
        status.isHidden = words.length == 0
        if row.threads.map(\.id) != shown?.threads.map(\.id) || threads.arrangedSubviews.count != row.threads.count {
            hidePreviews(feeds: feeds)
            threads.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for _ in row.threads {
                let line = ThreadLine(size: .row)
                line.addAction(UIAction { [weak self, weak line] _ in line?.threadID.map { self?.onThread?($0) } }, for: .touchUpInside)
                threads.addArrangedSubview(line)
            }
        }
        for (line, content) in zip(threads.arrangedSubviews.compactMap { $0 as? ThreadLine }, row.threads) { line.configure(content, feeds: feeds) }
        threads.isHidden = row.threads.isEmpty
        rule.isHidden = row.joined
        shown = row
        accessibilityLabel = [row.title, words.string].filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityTraits = .button
    }

    /// The thread whose line is at `point`, in the cell's coordinates.
    func thread(at point: CGPoint) -> String? {
        threads.arrangedSubviews.compactMap { $0 as? ThreadLine }.first { $0.bounds.contains($0.convert(point, from: self)) }?.threadID
    }

    func hidePreviews(feeds: SimulatorFeeds?) {
        threads.arrangedSubviews.compactMap { $0 as? ThreadLine }.forEach { $0.hidePreview(feeds: feeds) }
    }
}

/// The overview's heading: the app's name over "Tasks", scrolling with the list.
private final class TasksHeading: UIView {
    private let app = Theme.label("", Theme.Text.caption, color: .secondaryLabel)
    private let title = Theme.label("Tasks", Theme.Text.title)

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [app, title])
        stack.axis = .vertical
        stack.spacing = Theme.Space.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.row),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.margin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(app name: String) { app.text = name }
}

/// A status group's name and count: a Caption label over its rows.
private final class TaskGroupHeader: UITableViewHeaderFooterView {
    private let name = Theme.label("", Theme.Text.caption, color: .secondaryLabel)
    private let count = Theme.label("", Theme.Text.caption, color: .tertiaryLabel)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        let line = UIStackView(arrangedSubviews: [name, count, UIView()])
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String, count value: Int) {
        name.text = title
        count.text = value > 0 ? "\(value)" : nil
        isAccessibilityElement = !title.isEmpty
        accessibilityTraits = .header
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
            field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.group),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.row),
            field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}


/// A thread on no task, at the overview's foot, its Sprout in the slot.
private final class ThreadCell: UITableViewCell {
    let line = ThreadLine(size: .row)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Theme.pressedFill
        selectedBackgroundView = selected
        line.isUserInteractionEnabled = false
        line.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.row),
            line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.row),
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A folded line in the overview ("Not on a task 5", "History 20").
private final class FoldCell: UITableViewCell {
    struct Content: Equatable { let symbol: String; let text: String; let count: Int; let open: Bool }
    private let fold = FoldRow()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Theme.pressedFill
        selectedBackgroundView = selected
        fold.isUserInteractionEnabled = false
        fold.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fold)
        NSLayoutConstraint.activate([
            fold.topAnchor.constraint(equalTo: contentView.topAnchor),
            fold.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            fold.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin),
            fold.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ content: Content) {
        fold.configure(symbol: content.symbol, text: content.text, count: content.count, open: content.open)
        accessibilityLabel = fold.accessibilityLabel
        accessibilityTraits = .button
        accessibilityValue = content.open ? "Open" : "Folded"
    }
}

/// The deck's folded line: a symbol in the slot, what it holds in Line with
/// its count, a chevron at the right margin, 44 tall. Tapping it opens the
/// list in place (the chevron turns down).
final class FoldRow: UIControl {
    private let symbol = UIImageView()
    private let text = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private let count = Theme.label("", Theme.Text.line, color: .tertiaryLabel)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        symbol.tintColor = .secondaryLabel
        symbol.contentMode = .center
        chevron.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        chevron.tintColor = .tertiaryLabel
        let words = UIStackView(arrangedSubviews: [text, count])
        words.spacing = Theme.Space.tight
        words.alignment = .firstBaseline
        [symbol, words, chevron].forEach { $0.isUserInteractionEnabled = false; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.indent),
            words.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -Theme.Space.row),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol name: String, text words: String, count value: Int, open: Bool) {
        symbol.image = UIImage(systemName: name)
        text.text = words
        count.text = "\(value)"
        chevron.transform = open ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        accessibilityLabel = "\(words), \(value)"
        accessibilityValue = open ? "Open" : "Folded"
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Theme.pressedFill : .clear }
    }
}

/// One thread as a line: its Sprout in the glyph slot (the face says its
/// state), its title in Line strong, what it is doing in Line, and a small
/// preview at the right (its simulator live, or its task's newest picture).
final class ThreadLine: UIControl {
    enum Size { case row, page }
    enum Preview: Equatable { case live(SimulatorTarget), picture(UIImage) }
    struct Content: Equatable {
        let id: String
        let title: String
        let doing: String
        let mood: JellyLook.Mood
        let preview: Preview?
    }
    private(set) var threadID: String?
    private let size: Size
    private let jelly = JellyView(.worker("", .working), canvas: .roomy(Theme.Glyph.line))
    private let title = Theme.label("", Theme.Text.lineStrong, lines: 1)
    private let doing = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 1)
    private let thumb = UIView()
    private let picture = UIImageView()
    private let screen = SimulatorScreen()
    private var thumbWidth: NSLayoutConstraint!
    private var thumbHeight: NSLayoutConstraint!
    /// Room above the words for the jelly's sprout and hop.
    private var headroom: NSLayoutConstraint!
    private var shown: Content?

    init(size: Size) {
        self.size = size
        super.init(frame: .zero)
        let dimensions = size == .row ? Theme.Thumb.row : Theme.Thumb.page
        doing.numberOfLines = size == .row ? 1 : 3
        thumb.layer.cornerRadius = size == .row ? Theme.Thumb.rowRadius : Theme.Radius.small
        thumb.layer.cornerCurve = .continuous
        thumb.clipsToBounds = true
        thumb.backgroundColor = Theme.codeFill
        picture.contentMode = .scaleAspectFill
        [picture, screen].forEach { $0.frame = CGRect(origin: .zero, size: dimensions); $0.autoresizingMask = [.flexibleWidth, .flexibleHeight]; thumb.addSubview($0) }
        let text = UIStackView(arrangedSubviews: [title, doing])
        text.axis = .vertical
        text.spacing = 0
        [jelly, text, thumb].forEach { $0.isUserInteractionEnabled = false; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        thumbWidth = thumb.widthAnchor.constraint(equalToConstant: dimensions.width)
        thumbHeight = thumb.heightAnchor.constraint(equalToConstant: dimensions.height)
        let tall = bottomAnchor.constraint(greaterThanOrEqualTo: thumb.bottomAnchor)
        headroom = text.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            // Its body centred on the glyph slot and the title's capitals.
            jelly.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.glyph / 2),
            jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line),
            jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line),
            title.centred(on: jelly.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.indent),
            headroom,
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            text.trailingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: -Theme.Space.row),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumb.topAnchor.constraint(equalTo: text.topAnchor),
            thumbWidth, thumbHeight, tall
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ content: Content, feeds: SimulatorFeeds?) {
        threadID = content.id
        guard content != shown else { return }
        shown = content
        jelly.look = .worker(content.id, content.mood)
        headroom.constant = JellyBody.room(jelly.look, size: Theme.Glyph.line, moving: true, centre: title.font.capCentre, height: title.font.lineHeight).top
        title.text = content.title
        doing.text = content.doing
        doing.textColor = content.mood == .failed ? Theme.failure : .secondaryLabel
        let dimensions = size == .row ? Theme.Thumb.row : Theme.Thumb.page
        thumbWidth.constant = content.preview == nil ? 0 : dimensions.width
        thumbHeight.constant = content.preview == nil ? 0 : dimensions.height
        thumb.isHidden = content.preview == nil
        switch content.preview {
        case .live(let target)?:
            screen.isHidden = false
            picture.image = nil
            feeds?.attach(screen, to: target)
        case .picture(let image)?:
            screen.isHidden = true
            feeds?.attach(screen, to: nil)
            picture.image = image
        case nil:
            feeds?.attach(screen, to: nil)
            picture.image = nil
        }
        accessibilityLabel = "\(content.title), \(content.doing)"
    }

    /// Off screen: its simulator stops showing here.
    func hidePreview(feeds: SimulatorFeeds?) {
        feeds?.attach(screen, to: nil)
        if case .live? = shown?.preview { shown = nil }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// A row's swipe action, drawn rather than left to UIKit's white title: its
/// glyph in Body over its label in Caption, both in `onAccent` on the
/// action's state colour, which reads in light and dark.
private enum SwipeLabel {
    static func image(symbol: String, title: String, in traits: UITraitCollection) -> UIImage? {
        let ink = Theme.onAccent.resolvedColor(with: traits)
        guard let glyph = UIImage(systemName: symbol, withConfiguration: Theme.symbol(Theme.Text.body))?
            .withTintColor(ink, renderingMode: .alwaysOriginal) else { return nil }
        let text = NSAttributedString(string: title, attributes: [
            .font: Theme.Text.caption, .foregroundColor: ink])
        let label = text.size()
        let size = CGSize(width: ceil(max(glyph.size.width, label.width)),
                          height: ceil(glyph.size.height + Theme.Space.tight + label.height))
        let format = UIGraphicsImageRendererFormat(for: traits)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            glyph.draw(at: CGPoint(x: (size.width - glyph.size.width) / 2, y: 0))
            text.draw(at: CGPoint(x: (size.width - label.width) / 2, y: glyph.size.height + Theme.Space.tight))
        }.withRenderingMode(.alwaysOriginal)
    }
}
