import UIKit

/// The app's tasks beside its agent, one page per open work item that you
/// swipe through: your ask, where it stands, its sub-tasks as a checklist,
/// and its threads, builds and pictures. The last page holds what's done and
/// History; the Threads tab is every thread of the app.
@MainActor
final class TasksViewController: UIViewController, UIScrollViewDelegate, UITableViewDelegate {
    /// A thread to open; nil starts a new one.
    var onOpen: ((String?) -> Void)?
    private let model: SquircleModel
    private var project: AppProject
    private let tabs = UISegmentedControl(items: ["Tasks", "Threads"])
    private let close = Theme.glassButton(symbol: "xmark", identifier: "tasks.close", accessibilityLabel: "Close")
    private let header = UIView()
    /// The switch sits on glass like the close button, so pages passing
    /// under it don't show through.
    private let tabsGlass = Theme.glassSurface(cornerRadius: 20)
    /// Pages side by side; native paging, so a page follows the finger.
    private let pager = UIScrollView()
    private let dots = UIPageControl()
    private var pages: [String: WorkItemPage] = [:]
    /// The pages in order: open work items, most urgent first, then Done.
    private var order: [String] = []
    /// The page you're on, by work item; the pager's offset follows it.
    private var current: String?
    // The last page: done today and History. Grouped, so the small group
    // names scroll with their rows instead of sticking over them.
    private let table = UITableView(frame: .zero, style: .grouped)
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private lazy var threads = ThreadsViewController(model: model, project: project, embedded: true)
    private var dataSource: UITableViewDiffableDataSource<Group, String>!
    private var list = AppTasks()
    private var query = ""
    private var installing: String?
    /// What each Done row shows. A row is drawn again only when this changes:
    /// the tasks also carry times and orders that tick without showing.
    private var rows: [String: TaskRow] = [:]
    private var observation: Task<Void, Never>?
    /// Keeps the app's tasks fresh while the sheet is up.
    private var freshness: RefreshLease?
    /// The next History page is on its way.
    private var loadingHistory = false
    private static let donePage = "done"

    /// The Done page's sections; done and dropped work stays a day before History.
    enum Group: Hashable {
        case finished, history
        var title: String { self == .finished ? "Done" : "History" }
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

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.alwaysBounceVertical = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        pager.accessibilityIdentifier = "tasks.pages"
        dots.hidesForSinglePage = true
        dots.currentPageIndicatorTintColor = Theme.accent
        dots.pageIndicatorTintColor = .tertiaryLabel
        dots.addAction(UIAction { [weak self] _ in self?.dotsChanged() }, for: .valueChanged)

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
            cell.onCheck = { [weak self] in self?.task(id).map { self?.set($0, .done) } }
            cell.onMedia = { [weak self] media in self?.task(id).map { self?.openMedia(media, of: $0.id, title: $0.ask) } }
            cell.onInstall = { [weak self] in self?.task(id).map { self?.install($0) } }
            cell.loadThumbnail = { [weak self] media in await self?.thumbnail(media, of: id, height: 72) }
            return cell
        }
        dataSource.defaultRowAnimation = .fade

        notice.textAlignment = .center
        [pager, notice, dots].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        pager.addSubview(table)
        addChild(threads)
        threads.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(threads.view)
        threads.didMove(toParent: self)
        // The pages run under the controls, which float on the sheet's own
        // glass; content fades softly beneath them.
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
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 4),
            threads.view.topAnchor.constraint(equalTo: view.topAnchor),
            threads.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            threads.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            threads.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notice.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 48),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
        // No pull to refresh: the lease keeps the list current while it's up,
        // so pulling down at the top dismisses the sheet like any other.
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        freshness = model.keepFresh(.tasks(appID: project.id))
        Task { await model.refreshTasks() }
        renderTab()
        render()
    }

    #if DEBUG
    /// `SQUIRCLE_DEMO_PAGES=1`: swipes through every page and back, as a
    /// thumb would, for a recording.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_PAGES"] == "1" else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let count = self?.order.count else { return }
            for index in Array(1..<count) + Array((0..<(count - 1)).reversed()) {
                guard let self else { return }
                pager.setContentOffset(CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0), animated: true)
                try? await Task.sleep(for: .milliseconds(1300))
            }
        }
    }
    #endif

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private var onTasks: Bool { tabs.selectedSegmentIndex == 0 }
    /// Tells the soft top edge of the shown list where the controls are.
    private var edge: UIInteraction?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
        // Every list starts just below the controls and scrolls up under them.
        let top = header.frame.maxY + 4, bottom = view.safeAreaInsets.bottom + 28
        let scrolls = [table, threads.scrollView] + pages.values.map(\.scroll)
        for scroll in scrolls where scroll.contentInset.top != top || scroll.contentInset.bottom != bottom {
            let atTop = scroll.contentOffset.y <= -scroll.contentInset.top
            scroll.contentInset.top = top
            scroll.contentInset.bottom = bottom
            scroll.verticalScrollIndicatorInsets.top = top
            if atTop { scroll.contentOffset.y = -top }
        }
    }

    /// Lays the pages out side by side and puts the pager on `current`,
    /// unless a finger or a fling is moving it.
    private func layoutPages() {
        let size = pager.bounds.size
        guard size.width > 0 else { return }
        for (index, id) in order.enumerated() {
            let frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
            let page: UIView? = id == Self.donePage ? table : pages[id]
            if page?.frame != frame { page?.frame = frame }
        }
        pager.contentSize = CGSize(width: size.width * CGFloat(order.count), height: size.height)
        guard !pager.isTracking, !pager.isDecelerating, let current, let index = order.firstIndex(of: current) else { return }
        let x = CGFloat(index) * size.width
        if pager.contentOffset.x != x, !animatingPage { pager.contentOffset = CGPoint(x: x, y: 0) }
        dots.currentPage = index
    }

    private func renderTab() {
        pager.isHidden = !onTasks
        dots.isHidden = !onTasks
        threads.view.isHidden = onTasks
        notice.isHidden = !onTasks || !list.tasks.isEmpty || !list.history.isEmpty
        if #available(iOS 26.0, *), let edge = edge as? UIScrollEdgeElementContainerInteraction {
            edge.scrollView = !onTasks ? threads.scrollView : current.flatMap { pages[$0]?.scroll } ?? table
        }
    }

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
        let (build, shipped) = installable(task)
        let steps = task.subtasks.isEmpty ? nil : "\(task.subtasks.filter { !$0.status.open }.count) of \(task.subtasks.count) done"
        return TaskRow(ask: task.ask, status: task.status, checked: !task.status.open,
                       faded: task.archivedAt != nil, note: [task.note, steps].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                       shipped: shipped, install: build.map { _ in installing == task.id ? "Opening…" : "Install" },
                       threads: task.allThreads.filter { $0.state != "missing" }, media: task.media)
    }

    private func page(_ task: AppTask) -> WorkItemPage.Content {
        let (build, shipped) = installable(task)
        return .init(ask: task.ask, status: task.status, note: task.note, shipped: shipped,
                     install: build.map { _ in installing == task.id ? "Opening…" : "Install" },
                     subtasks: task.subtasks.map { .init(id: $0.id, ask: $0.ask, note: $0.note, status: $0.status, opens: $0.mainThread != nil) },
                     threads: task.allThreads.filter { $0.state != "missing" },
                     media: ([task] + task.subtasks).flatMap { owner in owner.media.map { WorkItemPage.Picture(task: owner.id, media: $0) } })
    }

    private func render() {
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        list = model.tasks(for: project)
        let rank: (AppTask.Status) -> Int = { [.needsYou, .inProgress, .readyToTry, .queued].firstIndex(of: $0) ?? 4 }
        let open = list.tasks.filter(\.status.open).enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }.map(\.element)
        let closed = list.tasks.filter { !$0.status.open }
        let ids = open.map(\.id) + (closed.isEmpty && list.history.isEmpty ? [] : [Self.donePage])

        // Pages for work items no longer open go; the rest are told what to show.
        for (id, page) in pages where !ids.contains(id) { page.removeFromSuperview(); pages[id] = nil }
        for task in open {
            let page = pages[task.id] ?? makePage(task.id)
            page.configure(self.page(task))
        }
        // A page that left (its work closed) hands over to its neighbour.
        if let current, !ids.contains(current), let was = order.firstIndex(of: current) {
            self.current = ids.isEmpty ? nil : ids[min(was, ids.count - 1)]
        }
        if current == nil { current = ids.first }
        let reordered = ids != order
        order = ids
        dots.numberOfPages = ids.count
        if reordered { view.setNeedsLayout() }
        renderDone(closed: closed)
        notice.text = model.error == nil ? "No tasks yet" : model.error
        renderTab()
    }

    private func makePage(_ id: String) -> WorkItemPage {
        let page = WorkItemPage()
        page.scroll.contentInsetAdjustmentBehavior = .never
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
        page.onMedia = { [weak self] picture in
            guard let self, let item = task(id) else { return }
            openMedia(picture.media, of: picture.task, title: item.ask)
        }
        page.loadThumbnail = { [weak self] picture in await self?.thumbnail(picture.media, of: picture.task, height: 220) }
        pages[id] = page
        pager.addSubview(page)
        view.setNeedsLayout()
        return page
    }

    /// The last page: done today, then History (searchable, a page at a time).
    private func renderDone(closed: [AppTask]) {
        var snapshot = NSDiffableDataSourceSnapshot<Group, String>()
        if !closed.isEmpty {
            snapshot.appendSections([.finished])
            snapshot.appendItems(closed.map(\.id), toSection: .finished)
        }
        if !list.history.isEmpty {
            snapshot.appendSections([.history])
            let words = query.lowercased().split(separator: " ")
            let found = list.history.filter { task in
                let text = ([task.ask, task.note] + task.subtasks.map(\.ask) + task.allThreads.compactMap(\.title)).joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            snapshot.appendItems([Self.searchRow] + found.map(\.id), toSection: .history)
        }
        // Rows whose look changed are drawn again; the rest keep their place.
        let previous = rows
        rows = Dictionary((closed + list.history).map { ($0.id, row($0)) }, uniquingKeysWith: { first, _ in first })
        let changed = snapshot.itemIdentifiers.filter { previous[$0] != nil && previous[$0] != rows[$0] }
        let current = dataSource.snapshot()
        let moved = current.sectionIdentifiers != snapshot.sectionIdentifiers || snapshot.sectionIdentifiers.contains {
            current.itemIdentifiers(inSection: $0) != snapshot.itemIdentifiers(inSection: $0)
        }
        if moved || !changed.isEmpty {
            snapshot.reconfigureItems(changed)
            dataSource.apply(snapshot, animatingDifferences: moved && !previous.isEmpty && view.window != nil)
        }
        for (index, group) in snapshot.sectionIdentifiers.enumerated() {
            (table.headerView(forSection: index) as? TaskGroupHeader).map { configure($0, group) }
        }
    }

    // MARK: Paging

    /// Moving to a page from the dots: one interruptible animation.
    private var animatingPage = false

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.width > 0, !order.isEmpty else { return }
        let index = min(max(Int((pager.contentOffset.x / pager.bounds.width).rounded()), 0), order.count - 1)
        guard order[index] != current else { return }
        current = order[index]
        dots.currentPage = index
        renderTab()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === pager { animatingPage = false }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === pager { animatingPage = false }
    }

    private func dotsChanged() {
        guard order.indices.contains(dots.currentPage) else { return }
        Theme.selectionHaptic()
        current = order[dots.currentPage]
        animatingPage = true
        pager.setContentOffset(CGPoint(x: CGFloat(dots.currentPage) * pager.bounds.width, y: 0), animated: !Motion.reduced)
        renderTab()
    }

    // MARK: Actions

    private func set(_ task: AppTask, _ status: AppTask.Status? = nil, toTop: Bool = false, haptic: Bool = true) {
        if haptic { Theme.selectionHaptic() }
        model.markTask(task, status: status, toTop: toTop)
        render()
        Task { await model.updateTask(task, status: status, toTop: toTop) }
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

    private func openMedia(_ media: AppTask.Media, of task: String, title: String) {
        guard presentedViewController == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            if media.kind == "video" {
                guard let url = await model.taskVideo(task: task, media: media.id) else { return }
                present(VideoPlayerViewController(url: url), animated: true)
            } else if let data = await model.taskMediaData(task: task, media: media.id), let image = UIImage(data: data) {
                present(ImageViewController(image: image, title: media.caption.isEmpty ? title : media.caption), animated: true)
            }
        }
    }

    // MARK: Done page

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let group = dataSource.sectionIdentifier(for: section) else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "group") as! TaskGroupHeader
        configure(header, group)
        return header
    }

    private func configure(_ header: TaskGroupHeader, _ group: Group) {
        let count = group == .history ? list.history.count : dataSource.snapshot().numberOfItems(inSection: group)
        header.configure(group.title, count: count, color: .secondaryLabel, chevron: nil)
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
        guard let id = dataSource.itemIdentifier(for: indexPath), let thread = task(id)?.mainThread else { return }
        onOpen?(thread)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).flatMap { self.task($0) }?.mainThread != nil
    }

    /// Any status, to bring one back; no swipes, which the pager owns.
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let task = task(id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [WorkItemPage.statusMenu(current: task.status) { self?.set(task, $0) }])
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
            let alive = row.threads.filter { TaskParts.mood($0) != nil }, rest = row.threads.filter { TaskParts.mood($0) == nil }
            for thread in alive {
                crew.addArrangedSubview(TaskParts.member(thread) { [weak self] in self?.onThread?(thread.id) })
            }
            for thread in rest {
                chips.addArrangedSubview(TaskParts.chip(thread) { [weak self] in self?.onThread?(thread.id) })
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

/// One open work item, a page of the Tasks sheet: where it stands (tap
/// for any status), your ask, its note, Install when a build is ready, its
/// sub-tasks as a checklist, its threads and its pictures and clips.
final class WorkItemPage: UIView {
    struct Sub: Equatable { let id, ask, note: String; let status: AppTask.Status; let opens: Bool }
    struct Picture: Equatable { let task: String; let media: AppTask.Media }
    struct Content: Equatable {
        let ask: String
        let status: AppTask.Status
        let note: String
        let shipped: String?
        let install: String?
        let subtasks: [Sub]
        let threads: [AppTask.Thread]
        let media: [Picture]
    }
    var onThread: ((String) -> Void)?
    var onSubtask: ((String) -> Void)?
    var onTick: ((String) -> Void)?
    var onStatus: ((AppTask.Status) -> Void)?
    var onTop: (() -> Void)?
    var onInstall: (() -> Void)?
    var onMedia: ((Picture) -> Void)?
    var loadThumbnail: ((Picture) async -> UIImage?)?
    let scroll = UIScrollView()
    private let stack = UIStackView()
    private let status = UIButton(configuration: .plain())
    private let ask = Theme.label("", Theme.font(.title2, 24, .semibold), lines: 0)
    private let note = Theme.label("", Theme.font(.subheadline, 15), color: .secondaryLabel, lines: 0)
    private let install = UIButton(configuration: .filled())
    private let shipped = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel)
    private let steps = UIStackView()
    private let crew = UIStackView()
    private let chips = UIStackView()
    private let pictures = UIStackView()
    private let pictureScroll = UIScrollView()
    private var loads: [Task<Void, Never>] = []
    private var shown: Content?
    private static let pictureHeight: CGFloat = 220

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        config.image = UIImage(systemName: "chevron.down")
        status.configuration = config
        status.showsMenuAsPrimaryAction = true
        status.contentHorizontalAlignment = .leading
        status.accessibilityIdentifier = "task.status"

        var fill = UIButton.Configuration.filled()
        fill.cornerStyle = .capsule
        fill.baseBackgroundColor = Theme.accent
        fill.baseForegroundColor = Theme.onAccent
        fill.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        fill.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.subheadline, 15, .semibold)
            return attributes
        }
        install.configuration = fill
        install.addAction(UIAction { [weak self] _ in self?.onInstall?() }, for: .touchUpInside)
        let installRow = UIStackView(arrangedSubviews: [install, shipped, UIView()])
        installRow.spacing = 12
        installRow.alignment = .center

        steps.axis = .vertical
        steps.spacing = 0
        crew.axis = .vertical
        crew.spacing = 10
        crew.alignment = .leading
        chips.spacing = 8
        chips.alignment = .leading
        let chipScroll = UIScrollView()
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.clipsToBounds = false
        pictures.spacing = 10
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
        [status, ask, note, installRow, steps, crew, chipScroll, pictureScroll].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(6, after: status)
        stack.setCustomSpacing(6, after: ask)
        stack.setCustomSpacing(20, after: installRow)
        stack.setCustomSpacing(20, after: steps)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24)
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
        case .needsYou: Theme.accent
        case .inProgress: Theme.warning
        case .readyToTry: Theme.success
        default: .secondaryLabel
        }
    }

    func configure(_ content: Content) {
        guard content != shown else { return }
        let was = shown
        shown = content
        status.configuration?.attributedTitle = AttributedString(Self.name(content.status), attributes: AttributeContainer([
            .font: Theme.font(.footnote, 13, .semibold), .foregroundColor: Self.color(content.status)]))
        status.tintColor = Self.color(content.status)
        status.menu = UIMenu(children: [
            UIAction(title: "Move to Front", image: UIImage(systemName: "arrow.left.to.line")) { [weak self] _ in self?.onTop?() },
            Self.statusMenu(current: content.status) { [weak self] in self?.onStatus?($0) }])
        status.accessibilityLabel = "Status, \(Self.name(content.status))"
        ask.text = content.ask
        note.text = content.note
        note.isHidden = content.note.isEmpty
        install.configuration?.title = content.install
        install.isHidden = content.install == nil
        shipped.text = content.shipped
        shipped.isHidden = content.shipped == nil
        install.superview?.isHidden = install.isHidden && shipped.isHidden

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
            content.media.forEach { pictures.addArrangedSubview(picture($0)) }
            pictureScroll.isHidden = content.media.isEmpty
        }
    }

    /// A screenshot or clip at a readable size; it takes its own shape once loaded.
    private func picture(_ picture: Picture) -> UIView {
        let button = UIButton(type: .custom)
        button.backgroundColor = Theme.codeFill
        button.layer.cornerRadius = 14
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
            play.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26)
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
        button.addAction(UIAction { [weak self] _ in self?.onMedia?(picture) }, for: .touchUpInside)
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
        let mark = UIImageView(image: UIImage(systemName: sub.status == .dropped ? "xmark.circle.fill" : closed ? "checkmark.circle.fill" : "circle"))
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .light)
        mark.tintColor = sub.status == .done ? Theme.success : .tertiaryLabel
        mark.isUserInteractionEnabled = false
        let ask = Theme.label(sub.ask, Theme.font(.body, 17), color: closed ? .secondaryLabel : .label, lines: 0)
        let words = [[.needsYou, .inProgress, .readyToTry].contains(sub.status) ? WorkItemPage.name(sub.status) : nil,
                     sub.note.isEmpty ? nil : sub.note].compactMap { $0 }
        let detail = Theme.label(words.joined(separator: " · "), Theme.font(.footnote, 13),
                                 color: words.first == sub.note ? .secondaryLabel : WorkItemPage.color(sub.status), lines: 2)
        detail.isHidden = words.isEmpty
        let text = UIStackView(arrangedSubviews: [ask, detail])
        text.axis = .vertical
        text.spacing = 2
        text.isUserInteractionEnabled = false
        check.addAction(UIAction { [weak self] _ in self?.onTick?() }, for: .touchUpInside)
        check.isEnabled = sub.status != .dropped
        check.accessibilityLabel = closed ? "Done" : "Mark done"
        check.accessibilityTraits = closed ? [.button, .selected] : .button
        [check, mark, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -11),
            check.widthAnchor.constraint(equalToConstant: 44),
            check.heightAnchor.constraint(equalToConstant: 44),
            check.centerYAnchor.constraint(equalTo: ask.topAnchor, constant: 11),
            mark.centerXAnchor.constraint(equalTo: check.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: check.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
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
            let threads = open.flatMap(\.allThreads).filter { $0.state == state && seen.insert($0.id).inserted }
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
