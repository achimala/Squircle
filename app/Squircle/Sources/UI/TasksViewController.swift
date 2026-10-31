import UIKit

/// The app's tasks, pushed in over its agent (the deck's A · Outline). The
/// overview lists every work item with its live status up front and its
/// live threads nested under it (a Sprout, the title, what it is doing, a
/// tiny preview); needs you and ready to try come first. A row opens the
/// item's page, and pages swipe sideways in the overview's order. A page
/// lists threads first (each under the sub-task it serves), then the open
/// sub-tasks, closed ones and earlier threads folded; an item with one live
/// thread is that thread, its conversation under a short header. Opening a
/// thread pushes it over Tasks, named for its task; back returns here.
/// Questions waiting on you sit under their task as the question card.
/// Threads on no task: working ones at the foot, idle ones folded; History
/// folded below them.
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
    /// Simulator streams for previews, and the host of an item's conversation.
    weak var host: ConversationHost?
    private let model: SquircleModel
    private var project: AppProject
    /// An item with one live thread shows its conversation (not in the
    /// overlay's sheet, where a field would fight the sheet's drag).
    private let embedsConversations: Bool
    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "tasks.back", accessibilityLabel: "Back")

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
    /// Tasks is the screen in front (its host says), so the page in view
    /// may hold its conversation.
    var inFront = false { didSet { if inFront != oldValue { syncConversations() } } }
    /// Some of Tasks is in sight (its host's route says: not covered by a
    /// thread at rest); its conversations' jellies draw only then.
    var inSight = true { didSet { if inSight != oldValue { renderSight() } } }

    private let table = UITableView(frame: .zero, style: .grouped)
    private let heading = TasksHeading()
    /// Pages side by side, in the overview's order; native paging, so a
    /// page follows the finger. Only the shown page and its neighbours exist.
    private let pager = UIScrollView()
    private var pages: [String: WorkItemPage] = [:]
    /// The work items the pages run through: the overview's rows, in order.
    private var order: [String] = []
    /// Conversations shown inside one-thread pages, by work item; one per
    /// mounted page, the one in view in front.
    private var conversations: [String: ThreadViewController] = [:]
    private var frontConversation: String?
    /// Conversations shown once: since then they come back as they were
    /// left (`reveal`), never opened anew.
    private var opened: Set<String> = []
    /// One-thread items whose outline was asked for instead of their conversation.
    private var outlined: Set<String> = []
    private let notice = Theme.label("", Theme.Text.body, color: .secondaryLabel, lines: 0)
    private var dataSource: UITableViewDiffableDataSource<Group, String>!
    private var list = AppTasks()
    private var showsHistory = false
    private var showsLoose = false
    private var query = ""
    private var installing: String?
    /// What each row shows. A row is drawn again only when this changes:
    /// the tasks also carry times and orders that tick without showing.
    private var rows: [String: TaskRow] = [:]
    private var lines: [String: ThreadLine.Content] = [:]
    private var folds: [String: FoldCell.Content] = [:]
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
    /// Pictures for previews, by media ID, once loaded.
    private var pictures: [String: UIImage] = [:]
    private var loadingPictures: Set<String> = []
    /// A task to show first, once it's listed (a question tapped elsewhere).
    private var focus: String?
    /// The task to open on, at its work item's page.
    private var initialTask: String?

    /// Sections top to bottom; done and dropped tasks stay a day before History.
    enum Group: Hashable {
        case search, status(AppTask.Status), finished, loose, history
        var title: String {
            switch self {
            case .status(let status): WorkItemPage.name(status)
            case .finished: "Done"
            case .search, .loose, .history: ""
            }
        }
    }
    private static let searchRow = "search"
    private static let askPrefix = "ask."
    private static let loosePrefix = "loose."
    private static let looseFold = "fold.loose"
    private static let historyFold = "fold.history"
    /// `about`: it's about one of the item's sub-tasks, so that is named.
    struct AskRow: Equatable { let item: WaitingList.Item; let busy: Bool; let last: Bool; var about = false }
    /// What needs a look comes first: you, then something to try.
    private static let statusOrder: [AppTask.Status] = [.needsYou, .readyToTry, .inProgress, .queued]
    /// Live threads nested under an overview row; the page has them all.
    private static let nested = 3

    /// `focus`: a task whose row (or work item's row) shows first; `task`:
    /// a task whose work item's page it opens on.
    init(model: SquircleModel, project: AppProject, embedsConversations: Bool, focus: String? = nil, task: String? = nil) {
        self.model = model
        self.project = project
        self.embedsConversations = embedsConversations
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
            cell.onCheck = { [weak self] in self?.toggleCheck(id) }
            cell.onInstall = { [weak self] in self?.task(id).map { self?.install($0) } }
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
        back.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(back)
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
        undo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(undo)
        NSLayoutConstraint.activate([
            undo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            undo.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Space.rowPad)
        ])
        push.onChange = { [weak self] _ in self?.applyPush() }
        push.onRest = { [weak self] _ in self?.syncConversations() }
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        freshness = model.keepFresh(.tasks(appID: project.id))
        Task { await model.refreshTasks() }
        render()
        if let task = initialTask { initialTask = nil; open(task: task) }
        renderUndo(animated: false)
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Ticks still waiting for their beat are sent before Tasks goes.
        finishChecks()
    }

    /// Leaving for good: ticks are sent, and the conversations let go.
    func tearDown() {
        finishChecks()
        observation?.cancel()
        freshness = nil
        for id in Array(conversations.keys) { dropConversation(id) }
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

    /// The work item a thread is for, in the user's words, to name it on top of the thread.
    func taskName(for thread: String) -> String? {
        list.tasks.first { $0.allThreads.contains { $0.id == thread } }?.ask
    }

    /// The conversation shown on the page in view, while it holds one.
    var conversation: ThreadViewController? { frontConversation.flatMap { conversations[$0] } }

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
        syncConversations()
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
        notice.isHidden = item || !list.tasks.isEmpty || !list.history.isEmpty
        if #available(iOS 26.0, *), let edge = edge as? UIScrollEdgeElementContainerInteraction {
            edge.scrollView = openItem.flatMap { pages[$0]?.scroll } ?? table
        }
        syncConversations()
        renderSight()
    }

    /// Each conversation is in sight while Tasks is and its page shows in the pager.
    private func renderSight() {
        let window = pager.isHidden ? .null : pager.bounds
        for (id, conversation) in conversations {
            conversation.inSight = inSight && pages[id].map { $0.frame.intersects(window) } == true
        }
    }

    /// Only the page in view, at rest, with Tasks in front, holds its
    /// conversation in front; every other one lets go of the model for the
    /// moment, keeping its draft and place. A conversation opens (at the
    /// bottom, field empty) only the first time it comes to the front.
    private func syncConversations() {
        let front = inFront && !push.isAnimating && push.value >= 1 && !pager.isTracking && !pager.isDecelerating ? openItem : nil
        let wanted = front.flatMap { conversations[$0] != nil ? $0 : nil }
        guard wanted != frontConversation else { return }
        if let old = frontConversation.flatMap({ conversations[$0] }) { old.hide() }
        frontConversation = wanted
        guard let wanted, let conversation else { return }
        if opened.insert(wanted).inserted { conversation.resume() } else { conversation.reveal() }
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
            dropConversation(id)
            page.removeFromSuperview()
            pages[id] = nil
        }
        for index in near {
            let id = order[index]
            let page: WorkItemPage
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
            outlined.remove(openItem ?? "")
            route = .item(order[index])
            view.endEditing(true)
        }
        renderChrome()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if scrollView === pager { syncConversations() } }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === pager, !decelerate { syncConversations() }
    }

    private func makePage(_ id: String) -> WorkItemPage {
        let page = WorkItemPage()
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
        page.onSubtask = { [weak self] sub in self?.task(sub)?.mainThread.map { self?.openThread($0) } }
        page.onTick = { [weak self] sub in
            guard let self, let task = task(sub) else { return }
            Theme.checkHaptic()
            set(task, task.status.open ? .done : .queued, haptic: false)
        }
        page.onStatus = { [weak self] status in self?.task(id).map { self?.set($0, status) } }
        page.onTop = { [weak self] in self?.task(id).map { self?.set($0, toTop: true) } }
        page.onInstall = { [weak self] in self?.task(id).map { self?.install($0) } }
        page.onOutline = { [weak self] in
            guard let self else { return }
            Theme.selectionHaptic()
            outlined.insert(id)
            dropConversation(id)
            if let page = pages[id] { configure(page, id) }
        }
        page.onMedia = { [weak self] picture, button in self?.openMedia(picture.media, of: picture.task, from: button) }
        page.loadThumbnail = { [weak self] picture in await self?.model.taskThumbnail(task: picture.task, media: picture.media, height: 220) }
        page.documents = model.documents
        page.onDocument = { [weak self] row in
            guard let self else { return }
            DocumentViewer.open(row, documents: model.documents, from: self)
        }
        pages[id] = page
        pager.addSubview(page)
        return page
    }

    /// Draws a page, and gives a one-thread page its conversation (made
    /// here, off screen as the page mounts, in front once it is in view).
    private func configure(_ page: WorkItemPage, _ id: String) {
        guard let task = task(id) else { return }
        let content = content(of: task)
        page.configure(content)
        guard let thread = content.conversation?.thread.id else { dropConversation(id); return }
        if let shown = conversations[id], shown.currentSessionID == thread { return }
        dropConversation(id)
        let controller = ThreadViewController(model: model, project: project, sessionID: thread, ahead: true)
        controller.embedded = true
        controller.host = host
        controller.onOpenThread = { [weak self] id in id.map { self?.openThread($0) } }
        addChild(controller)
        controller.view.backgroundColor = Theme.paper
        page.slot.addSubview(controller.view)
        controller.view.frame = page.slot.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.didMove(toParent: self)
        conversations[id] = controller
        syncConversations()
        renderSight()
    }

    private func dropConversation(_ id: String) {
        guard let controller = conversations.removeValue(forKey: id) else { return }
        if frontConversation == id { frontConversation = nil }
        opened.remove(id)
        controller.park()
        controller.tearDown()
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
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

    /// Live threads first by what they need: you, then working, stopped, finished.
    private static func rank(_ thread: AppTask.Thread) -> Int {
        switch thread.state {
        case "needs-you": 0
        case "working": 1
        case "error": 2
        default: 3
        }
    }

    /// A thread's line: its Sprout, title, what it is doing, and its preview
    /// (its simulator live, else the newest picture of the task it is for).
    private func line(_ thread: AppTask.Thread, for owner: AppTask, previews: [String: SimulatorTarget]) -> ThreadLine.Content {
        let (mood, doing): (JellyLook.Mood, String) = switch thread.state {
        case "needs-you": (.needsYou, asking[thread.id] ?? "Needs you")
        case "working": (.working, thread.step ?? "Working")
        case "error": (.failed, "Stopped with an error")
        default: (.done, thread.said ?? "Finished")
        }
        var preview: ThreadLine.Preview?
        if let target = previews[thread.id] {
            preview = .live(target)
        } else if let media = owner.media.last(where: { $0.kind == "image" || $0.kind == "video" }) {
            preview = picture(media, of: owner.id).map(ThreadLine.Preview.picture)
        }
        let title = thread.title.map { $0.hasPrefix(project.name + " · ") ? String($0.dropFirst(project.name.count + 3)) : $0 } ?? "Worker"
        return .init(id: thread.id, title: title, doing: doing, mood: mood, preview: preview)
    }

    /// A task's live threads as lines, each under the task it was spawned for.
    private func lines(of task: AppTask, previews: [String: SimulatorTarget]) -> [ThreadLine.Content] {
        let owned = task.threads.filter { $0.state != "missing" }.map { ($0, task) }
        let subs = task.subtasks.flatMap { sub in sub.threads.filter { $0.state != "missing" }.map { ($0, sub) } }
        var seen = Set<String>()
        return (owned + subs).filter { seen.insert($0.0.id).inserted }
            .sorted { Self.rank($0.0) < Self.rank($1.0) }
            .map { line($0.0, for: $0.1, previews: previews) }
    }

    /// A picture for previews, from memory; loads it once, then draws again.
    private func picture(_ media: AppTask.Media, of task: String) -> UIImage? {
        if let image = pictures[media.id] { return image }
        guard loadingPictures.insert(media.id).inserted else { return nil }
        Task { [weak self] in
            guard let image = await self?.model.taskThumbnail(task: task, media: media, height: Theme.Thumb.page.height) else { return }
            self?.pictures[media.id] = image
            self?.render()
        }
        return nil
    }

    private func row(_ task: AppTask, previews: [String: SimulatorTarget]) -> TaskRow {
        let ticked = checking.contains { $0.id == task.id }
        let detail = [task.subtasks.isEmpty ? nil : "\(task.subtasks.filter { !$0.status.open }.count)/\(task.subtasks.count)",
                      task.note.isEmpty ? nil : task.note].compactMap { $0 }.joined(separator: " · ")
        let threads = task.archivedAt == nil && task.status.open ? lines(of: task, previews: previews) : []
        return TaskRow(ask: task.ask, status: task.status, joined: asked[task.id] != nil && task.status.open,
                       checked: !task.status.open || ticked, faded: task.archivedAt != nil, detail: detail,
                       threads: Array(threads.prefix(Self.nested)), more: max(0, threads.count - Self.nested),
                       install: installable(task).build.map { _ in installing == task.id ? "Opening…" : "Install" })
    }

    private func content(of task: AppTask) -> WorkItemPage.Content {
        let (build, shipped) = installable(task)
        let index = order.firstIndex(of: task.id)
        let previews = previewTargets()
        let sub = { (sub: AppTask) in
            WorkItemPage.Sub(id: sub.id, ask: sub.ask, note: sub.note, status: sub.status, opens: sub.mainThread != nil,
                             threads: sub.threads.filter { $0.state != "missing" }.sorted { Self.rank($0) < Self.rank($1) }
                                .map { self.line($0, for: sub, previews: previews) })
        }
        // A thread linked to a sub-task shows under it, not again on its own.
        let underSubs = Set(task.subtasks.flatMap(\.threads).map(\.id))
        let own = task.threads.filter { $0.state != "missing" && !underSubs.contains($0.id) }.sorted { Self.rank($0) < Self.rank($1) }
            .map { line($0, for: task, previews: previews) }
        let asks = (asked[task.id] ?? []).map { item in
            var about = false
            if case .question(let question) = item { about = question.taskID != task.id }
            return TasksViewController.AskRow(item: item, busy: model.answering.contains(item.id), last: false, about: about)
        }
        let live = lines(of: task, previews: previews)
        var conversation: WorkItemPage.Header?
        if embedsConversations, live.count == 1, asks.isEmpty, task.status.open, !outlined.contains(task.id) {
            let closed = task.subtasks.filter { !$0.status.open }.count
            conversation = .init(thread: live[0], more: task.subtasks.isEmpty ? "Details" : "\(closed)/\(task.subtasks.count) sub-tasks")
        }
        let archived = { (owner: AppTask) in owner.threads.filter { $0.state == "missing" } }
        var seen = Set<String>()
        return .init(ask: task.ask, status: task.status, note: task.note, shipped: shipped,
                     install: build.map { _ in installing == task.id ? "Opening…" : "Install" },
                     position: index.map { "\($0 + 1) of \(order.count)" } ?? "",
                     threads: own,
                     earlier: (archived(task) + task.subtasks.flatMap(archived)).filter { seen.insert($0.id).inserted }.map { $0.title ?? "Thread" },
                     subtasks: task.subtasks.filter(\.status.open).map(sub),
                     closed: task.subtasks.filter { !$0.status.open }.map(sub),
                     media: ([task] + task.subtasks).flatMap { owner in owner.media.map { WorkItemPage.Picture(task: owner.id, media: $0) } },
                     asks: asks, conversation: conversation)
    }

    /// The live simulator each thread of the app holds, by thread.
    private func previewTargets() -> [String: SimulatorTarget] {
        guard host?.simulatorFeeds != nil else { return [:] }
        var targets: [String: SimulatorTarget] = [:]
        for use in model.activeSimulators(for: project) { if let target = use.target { targets[use.threadID] = target } }
        return targets
    }

    /// `now` is for the swipe actions themselves, which move their row
    /// while UIKit closes the swipe.
    private func render(now: Bool = false) {
        guard now || (!swiping && checking.isEmpty) else { behind = true; return }
        behind = false
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        list = model.tasks(for: project)
        let previews = previewTargets()
        // The threads open tasks link to, ready before one is tapped.
        model.prefetch(threads: list.tasks.filter { $0.status.open }.flatMap(\.allThreads).filter { $0.state != "missing" }.map(\.id))
        // What waits on you here, by the work item it's about; a question
        // nothing claims leads Needs you.
        let waiting = model.waiting.apps.first { $0.projectID == project.id }?.items ?? []
        var loose: [WaitingList.Item] = []
        asked = [:]
        asking = [:]
        for item in waiting {
            switch item {
            case .question(let question): if let thread = question.threadID { asking[thread] = question.text }
            case .request(let request): asking[request.threadID] = request.pending.isQuestion
                ? request.pending.questions.first?["question"].string ?? request.pending.title : request.pending.title
            }
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
        var nextFolds: [String: FoldCell.Content] = [:]
        if !busy.isEmpty || !idle.isEmpty {
            var ids = busy.map { Self.loosePrefix + $0.id }
            if !idle.isEmpty {
                nextFolds[Self.looseFold] = .init(symbol: "tray", text: "Not on a task", count: idle.count, open: showsLoose || !words.isEmpty)
                ids.append(Self.looseFold)
                if showsLoose || !words.isEmpty { ids += idle.map { Self.loosePrefix + $0.id } }
            }
            snapshot.appendSections([.loose])
            snapshot.appendItems(ids, toSection: .loose)
        }
        if !list.history.isEmpty {
            // A search looks through History too.
            let open = showsHistory || !words.isEmpty
            nextFolds[Self.historyFold] = .init(symbol: "clock.arrow.circlepath", text: "History", count: list.history.count, open: open)
            snapshot.appendSections([.history])
            snapshot.appendItems([Self.historyFold] + (open ? list.history.filter(found).map(\.id) : []), toSection: .history)
        }
        // Rows whose look changed are drawn again; the rest keep their place.
        // The model changes every few seconds for unrelated reasons, and
        // applying an unchanged list anyway resets an open swipe.
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
        // `SQUIRCLE_TASKS_THREAD=1`: the item's first live thread, pushed over Tasks.
        if environment["SQUIRCLE_TASKS_THREAD"] == "1", let thread = task(id)?.allThreads.first(where: { $0.state != "missing" }) {
            Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.openThread(thread.id) }
        }
        #endif
    }

    /// The thread whose line is under `point`, in a row of the overview.
    private func threadLine(at point: CGPoint, in table: UITableView) -> String? {
        guard let path = table.indexPathForRow(at: point), let cell = table.cellForRow(at: path) else { return nil }
        if let cell = cell as? ThreadCell { return cell.line.threadID }
        return (cell as? TaskCell)?.thread(at: table.convert(point, to: cell))
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
        let row = row(task, previews: previewTargets())
        rows[id] = row
        if let path = dataSource.indexPath(for: id), let cell = table.cellForRow(at: path) as? TaskCell { cell.configure(row, feeds: host?.simulatorFeeds) }
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
        undo.onUndo = { [weak self] in self?.undoLast() }
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

    /// A task's picture or clip, flown up from its thumbnail.
    private func openMedia(_ media: AppTask.Media, of task: String, from button: UIButton) {
        guard let window = view.window else { return }
        let origin = MediaOrigin { [weak button] in button.map { MediaSpot($0) } }
        MediaViewer.open([.task(media, of: task, poster: button.image(for: .normal), origin: origin, model: model)], at: 0, in: window)
    }

    // MARK: Overview

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let group = dataSource.sectionIdentifier(for: section), group != .search else { return nil }
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
        if id == Self.historyFold { showsHistory.toggle() } else { showsLoose.toggle() }
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
        case .loose?, .history?: Theme.Space.section - Theme.Space.row
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
            if conversation != nil { return "a task's conversation in front on the overview" }
        case .item(let id):
            if push.value != 1 || pager.isHidden || pages[id] == nil { return "task page not showing at rest" }
            if pages[id].map({ abs($0.frame.minX - pager.contentOffset.x) > 0.5 }) == true { return "task page out of place" }
        }
        return nil
    }
    #endif
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

/// What a task's overview row shows.
private struct TaskRow: Equatable {
    let ask: String
    let status: AppTask.Status
    /// Its questions follow right under it, with no rule between.
    let joined: Bool
    /// Shows a tick: done, or ticked here and about to move.
    let checked: Bool
    let faded: Bool
    /// Sub-tasks closed of all, "2/5", and the note.
    let detail: String
    /// Its live threads, nested under it, and how many more its page has.
    let threads: [ThreadLine.Content]
    let more: Int
    let install: String?
}

/// One work item in the overview: its status in the glyph slot (tap to
/// tick it off), the ask, its progress and note on one line, and its live
/// threads nested under it, one slot in. Tapping a thread opens it; the
/// rest of the row opens the item's page.
private final class TaskCell: UITableViewCell {
    var onInstall: (() -> Void)?
    var onCheck: (() -> Void)?
    var onThread: ((String) -> Void)?
    private let ask = Theme.label("", Theme.Text.body, lines: 2)
    private let detail = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 1)
    private let more = Theme.label("", Theme.Text.line, color: .tertiaryLabel, lines: 1)
    private let threads = UIStackView()
    private let install = UIButton(configuration: .filled())
    private let rule = UIView()
    /// The status at the leading edge; one tap marks the task done.
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

        let top = UIStackView(arrangedSubviews: [ask, install])
        top.alignment = .firstBaseline
        top.spacing = Theme.Space.rowPad
        threads.axis = .vertical
        threads.spacing = Theme.Space.tight
        let text = UIStackView(arrangedSubviews: [top, detail, threads, more])
        text.axis = .vertical
        text.spacing = Theme.Space.tight
        text.setCustomSpacing(Theme.Space.row, after: detail)
        rule.backgroundColor = .separator
        [text, rule, check].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.rowPad),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.rowPad),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.text),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            // A generous target, its mark centred in the glyph slot on the ask's first line.
            check.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.margin + Theme.Space.glyph / 2),
            check.widthAnchor.constraint(equalToConstant: Theme.Space.tap),
            check.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            check.centerYAnchor.constraint(equalTo: ask.topAnchor, constant: (ask.font.lineHeight / 2).rounded()),
            mark.centerXAnchor.constraint(equalTo: check.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: check.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: text.leadingAnchor),
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

    func configure(_ row: TaskRow, feeds: SimulatorFeeds?) {
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
        let words = [row.faded ? Self.statusName(row.status) : nil, row.detail.isEmpty ? nil : row.detail].compactMap { $0 }
        detail.text = words.joined(separator: " · ")
        detail.isHidden = words.isEmpty
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
        more.text = row.more == 1 ? "1 more thread" : "\(row.more) more threads"
        more.isHidden = row.more == 0
        install.isHidden = row.install == nil
        install.configuration?.title = row.install
        rule.isHidden = row.joined
        shown = row
        accessibilityLabel = [row.faded ? nil : WorkItemPage.name(row.status), row.ask, detail.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
    }

    /// The thread whose line is at `point`, in the cell's coordinates.
    func thread(at point: CGPoint) -> String? {
        threads.arrangedSubviews.compactMap { $0 as? ThreadLine }.first { $0.bounds.contains($0.convert(point, from: self)) }?.threadID
    }

    func hidePreviews(feeds: SimulatorFeeds?) {
        threads.arrangedSubviews.compactMap { $0 as? ThreadLine }.forEach { $0.hidePreview(feeds: feeds) }
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
        let tall = heightAnchor.constraint(greaterThanOrEqualTo: thumb.heightAnchor)
        NSLayoutConstraint.activate([
            jelly.leadingAnchor.constraint(equalTo: leadingAnchor),
            jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line),
            jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line),
            jelly.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.indent),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            text.trailingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: -Theme.Space.row),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumb.topAnchor.constraint(equalTo: topAnchor),
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

/// Undo for the last ticks: a small glass capsule at the foot.
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
}

/// One work item, a page of Tasks: where it stands (tap for any status),
/// your ask, its note, what waits on you, Install when a build is ready,
/// its threads (each under the sub-task it serves, earlier ones folded),
/// its open sub-tasks (closed ones folded), its pictures and clips, and its
/// documents. With one live thread (`conversation`), a short header over
/// that thread's conversation instead.
final class WorkItemPage: UIView {
    struct Sub: Equatable {
        let id, ask, note: String
        let status: AppTask.Status
        let opens: Bool
        let threads: [ThreadLine.Content]
    }
    struct Picture: Equatable { let task: String; let media: AppTask.Media }
    /// A one-thread item's header: its thread, and the way to its outline.
    struct Header: Equatable { let thread: ThreadLine.Content; let more: String }
    struct Content: Equatable {
        let ask: String
        let status: AppTask.Status
        let note: String
        let shipped: String?
        let install: String?
        /// Where it is among the pages, "3 of 24".
        let position: String
        /// Its own live threads; sub-tasks carry theirs.
        let threads: [ThreadLine.Content]
        /// Archived threads' titles, folded.
        let earlier: [String]
        let subtasks: [Sub]
        let closed: [Sub]
        let media: [Picture]
        /// What waits on you about it, answered here.
        let asks: [TasksViewController.AskRow]
        let conversation: Header?
    }
    /// Draws and answers `asks`.
    var answers: WaitingAnswers?
    var feeds: SimulatorFeeds?
    var onThread: ((String) -> Void)?
    var onPrepare: ((String) -> Void)?
    var onSubtask: ((String) -> Void)?
    var onTick: ((String) -> Void)?
    var onStatus: ((AppTask.Status) -> Void)?
    var onTop: (() -> Void)?
    var onInstall: (() -> Void)?
    var onOutline: (() -> Void)?
    var onMedia: ((Picture, UIButton) -> Void)?
    var loadThumbnail: ((Picture) async -> UIImage?)?
    var documents: DocumentFiles?
    var onDocument: ((FileRowView) -> Void)?
    /// Where content starts: below Tasks' back button.
    var top: CGFloat = 0 { didSet { if top != oldValue { setNeedsLayout() } } }
    let scroll = UIScrollView()
    /// Holds a one-thread item's conversation, under its header.
    let slot = UIView()
    private let header = UIStackView()
    private let stack = UIStackView()
    private let status = UIButton(configuration: .plain())
    private let position = Theme.label("", Theme.Text.caption, color: .tertiaryLabel)
    private let ask = Theme.label("", Theme.Text.title, lines: 0)
    private let note = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 0)
    private let install = UIButton(configuration: .filled())
    private let shipped = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private let questions = UIStackView()
    private let crew = UIStackView()
    private let steps = UIStackView()
    private let pictures = UIStackView()
    private let pictureScroll = UIScrollView()
    private let files = UIStackView()
    private var showsEarlier = false
    private var showsClosed = false
    private var loads: [Task<Void, Never>] = []
    private var shown: Content?
    /// What the outline last drew; nil while the conversation shows instead,
    /// so coming back to the outline draws all of it.
    private var outline: Content?
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

        crew.axis = .vertical
        crew.spacing = 0
        steps.axis = .vertical
        steps.spacing = 0
        pictures.spacing = Theme.Space.row
        pictures.alignment = .center
        pictureScroll.showsHorizontalScrollIndicator = false
        pictureScroll.clipsToBounds = false
        pictures.translatesAutoresizingMaskIntoConstraints = false
        pictureScroll.addSubview(pictures)
        NSLayoutConstraint.activate([
            pictures.topAnchor.constraint(equalTo: pictureScroll.contentLayoutGuide.topAnchor),
            pictures.bottomAnchor.constraint(equalTo: pictureScroll.contentLayoutGuide.bottomAnchor),
            pictures.leadingAnchor.constraint(equalTo: pictureScroll.contentLayoutGuide.leadingAnchor),
            pictures.trailingAnchor.constraint(equalTo: pictureScroll.contentLayoutGuide.trailingAnchor),
            pictures.heightAnchor.constraint(equalTo: pictureScroll.frameLayoutGuide.heightAnchor),
            pictureScroll.heightAnchor.constraint(equalToConstant: Self.pictureHeight)
        ])
        position.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        questions.axis = .vertical
        questions.spacing = Theme.Space.group
        files.axis = .vertical
        files.spacing = Theme.Space.row
        header.axis = .vertical
        header.spacing = Theme.Space.row
        header.addArrangedSubview({
            let row = UIStackView(arrangedSubviews: [status, UIView(), position])
            row.alignment = .firstBaseline
            return row
        }())
        header.addArrangedSubview(ask)
        [header, note, questions, installRow, crew, steps, pictureScroll, files].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(Theme.Space.row, after: header)
        stack.setCustomSpacing(Theme.Space.section, after: note)
        stack.setCustomSpacing(Theme.Space.section, after: questions)
        stack.setCustomSpacing(Theme.Space.section, after: installRow)
        stack.setCustomSpacing(Theme.Space.section, after: crew)
        stack.setCustomSpacing(Theme.Space.section, after: steps)
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [scroll, slot].forEach(addSubview)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.row),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.rowPad),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.margin),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.margin)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The outline scrolls the full height; a conversation sits under its
    /// header, which stays put above it.
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        guard shown?.conversation != nil else { slot.frame = .zero; return }
        let width = bounds.width - 2 * Theme.Space.margin
        let height = header.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel).height
        header.frame = CGRect(x: Theme.Space.margin, y: top + Theme.Space.row, width: width, height: height)
        let below = header.frame.maxY + Theme.Space.row
        slot.frame = CGRect(x: 0, y: below, width: bounds.width, height: max(0, bounds.height - below))
    }

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
        if (content.conversation != nil) != (was?.conversation != nil) || was == nil { arrange(conversation: content.conversation != nil) }
        if let conversation = content.conversation {
            outline = nil
            renderHeader(conversation)
            setNeedsLayout()
            return
        }
        let drawn = outline
        outline = content
        note.text = content.note
        note.isHidden = content.note.isEmpty
        install.configuration?.title = content.install
        install.isHidden = content.install == nil
        shipped.text = content.shipped
        shipped.isHidden = content.shipped == nil
        install.superview?.isHidden = install.isHidden && shipped.isHidden

        if content.asks != drawn?.asks {
            questions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for ask in content.asks {
                let view = WaitingItemView()
                answers?.configure(view, ask.item, about: ask.about)
                questions.addArrangedSubview(view)
            }
            questions.isHidden = content.asks.isEmpty
        }
        if content.threads != drawn?.threads || content.earlier != drawn?.earlier { renderThreads(content) }
        if content.subtasks != drawn?.subtasks || content.closed != drawn?.closed { renderSteps(content) }
        if content.media != drawn?.media { renderMedia(content) }
    }

    /// The outline in the scroll view, or the header over the conversation.
    private func arrange(conversation: Bool) {
        if conversation {
            header.removeFromSuperview()
            addSubview(header)
            header.translatesAutoresizingMaskIntoConstraints = true
        } else {
            header.removeFromSuperview()
            header.translatesAutoresizingMaskIntoConstraints = false
            stack.insertArrangedSubview(header, at: 0)
            header.arrangedSubviews.dropFirst(2).forEach { $0.removeFromSuperview() }
        }
        ask.numberOfLines = conversation ? 3 : 0
        scroll.isHidden = conversation
        slot.isHidden = !conversation
    }

    /// A one-thread item: under its status and ask, the way to its outline
    /// and its thread's line, which opens the thread on its own.
    private func renderHeader(_ conversation: WorkItemPage.Header) {
        header.arrangedSubviews.dropFirst(2).forEach { $0.removeFromSuperview() }
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.imagePlacement = .trailing
        config.imagePadding = Theme.Space.tight
        config.preferredSymbolConfigurationForImage = Theme.symbol(Theme.Text.line)
        config.image = UIImage(systemName: "chevron.right")
        config.attributedTitle = AttributedString(conversation.more, attributes: AttributeContainer([
            .font: Theme.Text.line, .foregroundColor: UIColor.secondaryLabel]))
        let more = UIButton(configuration: config)
        more.tintColor = .tertiaryLabel
        more.contentHorizontalAlignment = .leading
        more.addAction(UIAction { [weak self] _ in self?.onOutline?() }, for: .touchUpInside)
        header.addArrangedSubview(more)
        header.addArrangedSubview(threadLine(conversation.thread, size: .row))
    }

    private func threadLine(_ content: ThreadLine.Content, size: ThreadLine.Size) -> ThreadLine {
        let line = ThreadLine(size: size)
        line.configure(content, feeds: feeds)
        line.addAction(UIAction { [weak self] _ in self?.onThread?(content.id) }, for: .touchUpInside)
        line.addAction(UIAction { [weak self] _ in self?.onPrepare?(content.id) }, for: .touchDown)
        return line
    }

    /// A Caption label over a part of the page, its count beside it.
    private func label(_ text: String, count: String) -> UIView {
        let line = UIStackView(arrangedSubviews: [Theme.label(text, Theme.Text.caption, color: .secondaryLabel),
                                                  Theme.label(count, Theme.Text.caption, color: .tertiaryLabel), UIView()])
        line.spacing = Theme.Space.tight
        line.alignment = .firstBaseline
        line.accessibilityTraits = .header
        return line
    }

    /// `view` one nesting level in from where it would sit.
    private func nested(_ view: UIView, levels: CGFloat = 1, top: CGFloat = 0) -> UIView {
        let holder = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: holder.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: levels * Theme.Space.indent),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor)
        ])
        return holder
    }

    /// Its own live threads, one slot in under the ask; earlier ones folded.
    private func renderThreads(_ content: Content) {
        crew.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let threads = content.threads, earlier = content.earlier
        crew.isHidden = threads.isEmpty && earlier.isEmpty
        guard !crew.isHidden else { return }
        crew.addArrangedSubview(label("Threads", count: threads.isEmpty ? "" : "\(threads.count)"))
        for thread in threads { crew.addArrangedSubview(nested(threadLine(thread, size: .page), top: Theme.Space.row)) }
        guard !earlier.isEmpty else { return }
        let fold = FoldRow()
        fold.configure(symbol: "archivebox", text: "Earlier threads", count: earlier.count, open: showsEarlier)
        fold.addAction(UIAction { [weak self] _ in
            guard let self, let shown else { return }
            Theme.selectionHaptic()
            showsEarlier.toggle()
            renderThreads(shown)
        }, for: .touchUpInside)
        crew.addArrangedSubview(nested(fold, top: threads.isEmpty ? 0 : Theme.Space.row))
        guard showsEarlier else { return }
        // Archived: named, no longer opened.
        for title in earlier { crew.addArrangedSubview(nested(Theme.label(title, Theme.Text.line, color: .tertiaryLabel), levels: 2, top: Theme.Space.tight)) }
    }

    /// The open sub-tasks, one slot in, each with its threads one further;
    /// closed ones folded.
    private func renderSteps(_ content: Content) {
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = content.subtasks.count + content.closed.count
        steps.isHidden = all == 0
        guard all > 0 else { return }
        steps.addArrangedSubview(label("Sub-tasks", count: "\(content.closed.count)/\(all)"))
        func add(_ sub: Sub) {
            let row = SubtaskRow(sub)
            row.onTick = { [weak self] in self?.onTick?(sub.id) }
            row.addAction(UIAction { [weak self] _ in self?.onSubtask?(sub.id) }, for: .touchUpInside)
            steps.addArrangedSubview(nested(row))
            for thread in sub.threads { steps.addArrangedSubview(nested(threadLine(thread, size: .row), levels: 2, top: Theme.Space.tight)) }
        }
        content.subtasks.forEach(add)
        guard !content.closed.isEmpty else { return }
        let fold = FoldRow()
        fold.configure(symbol: "checkmark", text: "Closed", count: content.closed.count, open: showsClosed)
        fold.addAction(UIAction { [weak self] _ in
            guard let self, let shown else { return }
            Theme.selectionHaptic()
            showsClosed.toggle()
            renderSteps(shown)
        }, for: .touchUpInside)
        steps.addArrangedSubview(nested(fold, top: Theme.Space.tight))
        if showsClosed { content.closed.forEach(add) }
    }

    private func renderMedia(_ content: Content) {
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

/// A sub-task on a work item's page: its status in the glyph slot (tap to
/// mark it done, again to reopen it), what it is, and how it stands when
/// that's worth saying. Tapping the rest opens its thread.
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
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.tight)
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
        let height = surface.heightAnchor.constraint(equalToConstant: Self.height)
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

    private static let height: CGFloat = 30
    /// A Sprout's body here: its slot (body and sprout) fits the capsule
    /// with `inset` above and below.
    private static let inset: CGFloat = 3
    private static let body = (height - 2 * inset) / (1 + JellyTraits.crown)
    private static let crewGap: CGFloat = 3

    /// One Sprout in a slot as wide as its body is drawn and as tall as its
    /// sprout reaches, so the stack spaces bodies evenly and nothing leaves
    /// the capsule.
    private static func slot(_ look: JellyLook) -> UIView {
        let slot = UIView()
        let jelly = JellyView(look, canvas: JellyCanvas(size: body, side: 0.2, top: 0.42, bottom: 0.14))
        slot.isUserInteractionEnabled = false
        [slot, jelly].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        slot.addSubview(jelly)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: (body * CGFloat(look.traits.look.y)).rounded(.up)),
            slot.heightAnchor.constraint(equalToConstant: body * (1 + JellyTraits.crown)),
            jelly.widthAnchor.constraint(equalToConstant: body),
            jelly.heightAnchor.constraint(equalToConstant: body),
            jelly.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            jelly.bottomAnchor.constraint(equalTo: slot.bottomAnchor)
        ])
        return slot
    }

    /// Counts of open tasks; working and needing you are shown by the
    /// workers on them (up to three Sprouts, overlapping), the rest by a dot.
    /// With no worker in that state (the app's agent asking, or doing it
    /// itself) the count gets the dot too: the capsule shows the workers,
    /// and the agent is never drawn here.
    func configure(_ open: [AppTask]) {
        func count(_ status: AppTask.Status) -> Int { open.filter { $0.status == status }.count }
        func crew(_ state: String, _ mood: JellyLook.Mood) -> [JellyLook] {
            var seen = Set<String>()
            let threads = open.flatMap(\.allThreads).filter { $0.state == state && seen.insert($0.id).inserted }
            return threads.prefix(3).map { .worker($0.id, mood) }
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
                let group = UIStackView(arrangedSubviews: item.4.map(Self.slot))
                // A little crew, shoulder to shoulder: the bodies never overlap.
                group.spacing = Self.crewGap
                group.alignment = .bottom
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
