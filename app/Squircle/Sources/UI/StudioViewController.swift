import UIKit

/// Where the user has asked to be. The only navigation state there is:
/// everything on screen is derived from it and from two springs that always
/// move toward what it implies, so no sequence of taps can leave the screen
/// somewhere it should not be.
enum Route: Equatable {
    case grid
    /// The app's agent: the conversation an app opens to.
    case app(String)
    /// Another of the app's threads, over its agent. A T3 thread ID, or
    /// `draft:<uuid>` for a new conversation.
    case thread(app: String, thread: String)

    var app: String? {
        switch self {
        case .grid: nil
        case .app(let id), .thread(let id, _): id
        }
    }
    var thread: String? { if case .thread(_, let thread) = self { thread } else { nil } }
}

/// The root: every app's real device. Home is a grid of still portraits of
/// those devices that scroll natively. Opening an app pushes in the
/// conversation with its agent while Home falls back beneath it. The app's
/// other threads open from the agent's Threads page or its update lines,
/// pushing in over it the same way. Simulators the app's agents are using
/// float over its conversations (`SimulatorDock`).
///
/// Navigation is a route plus two springs (`appSpring` grid→agent, `spring`
/// agent→thread). Each spring's target is a function of the route and of what
/// is mounted. What is mounted (the agent, the thread over it) changes only
/// while its spring is at zero, i.e. off screen. Every frame is a pure
/// function of those values, including which views take touches.
@MainActor
final class StudioViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let model: SquircleModel
    /// Renders the grid's still device portraits.
    private let stage = DeviceStage()
    private lazy var feeds = SimulatorFeeds(model: model)
    private lazy var dock = SimulatorDock(feeds: feeds)
    /// The grid and its controls.
    private let home = UIView()
    private let grid = UIScrollView()
    private let connection = Theme.glassButton(symbol: "macbook", identifier: "connection.status", accessibilityLabel: "Mac connection")
    private let add = Theme.glassButton(symbol: "plus", identifier: "project.add", accessibilityLabel: "Add app")
    /// Holds the app's agent; touches pass through when empty.
    private let agentHost = PassthroughView()
    /// Holds a thread over the agent; touches pass through when empty.
    private let threadHost = PassthroughView()
    /// 0 = grid, 1 = agent.
    private let appSpring = SpringDriver()
    /// 0 = agent, 1 = thread over it.
    private let spring = SpringDriver()
    private var cells: [String: GridCell] = [:]
    private var bindings: [String: ScreenshotBinding] = [:]
    /// Display order. It changes only while the grid is out of sight, so
    /// nothing rearranges under a finger.
    private var projects: [AppProject] = []
    /// Pending model render (at most one) and portrait drawing.
    private var renderTask: Task<Void, Never>?
    private var portraitTask: Task<Void, Never>?
    private var laidOut: StageLayout?
    /// Bumped whenever an app's screen changes; part of each portrait's key.
    private var screenVersions: [String: Int] = [:]

    // MARK: Navigation state

    private var route = Route.grid
    /// The app whose agent (and device) is mounted. Changes only at `appSpring` 0.
    private(set) var selectedID: String?
    private(set) var agent: ThreadViewController?
    /// The mounted conversation and its route key. Changes only at `spring` 0.
    private(set) var thread: ThreadViewController?
    private var threadKey: String?
    /// A finger on the back edge owns one spring; targets wait for release.
    private var dragging: SpringDriver?
    private var dragStart: CGFloat = 0
    /// Inside `sync()`: the scene is drawn once, from the finished state.
    private var syncing = false
    /// The conversation on screen changed (nil: none), for notifications.
    var onViewing: ((String?) -> Void)?
    /// A notification tapped before the apps arrived from the Mac.
    private var pendingTarget: PushTarget?

    init(model: SquircleModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        view.addSubview(stage)
        view.addSubview(home)
        view.addSubview(agentHost)
        view.addSubview(threadHost)
        view.addSubview(dock)
        dock.onOpenThread = { [weak self] id in
            guard let self else { return }
            if id == agent?.currentSessionID { closeThread() } else if route.thread != id { openThread(id) }
        }

        grid.alwaysBounceVertical = true
        grid.showsVerticalScrollIndicator = false
        grid.contentInsetAdjustmentBehavior = .never
        grid.accessibilityIdentifier = "app.grid"
        if #available(iOS 26.0, *) { grid.topEdgeEffect.style = .soft }
        home.addSubview(grid)
        [connection, add].forEach(home.addSubview)
        connection.showsMenuAsPrimaryAction = true
        add.addAction(UIAction { [weak self] _ in self?.presentImport() }, for: .touchUpInside)


        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(backPanned(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)

        for driver in [appSpring, spring] {
            driver.onChange = { [weak self] value in
                guard let self else { return }
                // Off screen: whatever the route wants mounted can mount now.
                if value <= 0.001 { sync() } else { applyScene() }
            }
            driver.onRest = { [weak self] _ in self?.rested() }
        }

        Task { [weak self, updates = model.updates] in
            for await _ in updates {
                guard let self else { return }
                // A burst of model changes renders the latest state once,
                // 80 ms after its first change, however long the burst lasts.
                guard renderTask == nil else { continue }
                renderTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self else { return }
                    renderTask = nil
                    render()
                }
            }
        }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIAccessibility.reduceMotionStatusDidChangeNotification) {
                self?.relayout()
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: StudioViewController, _: UITraitCollection) in
            controller.relayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: StudioViewController, _: UITraitCollection) in
            controller.schedulePortraits()
        }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        #if !SQUIRCLE_OVERLAY
        MotionAudit.shared.note("gallery.visible", values: ["since_launch_ms": (CACurrentMediaTime() - SquircleApp.launchedAt) * 1000])
        #endif
        startVerificationHooks()
        #endif
    }

    #if DEBUG
    /// Verification only (never in Release). Holds real states still for a
    /// screen capture: `SQUIRCLE_GRID` (grid scroll in points), `SQUIRCLE_APP`
    /// (open the app with this name), `SQUIRCLE_APP_SCRUB` (0…1 of opening it)
    /// and `SQUIRCLE_SCRUB` (0…1 of a thread over its agent); `SQUIRCLE_SIM_EXPAND=1` brings
    /// the first simulator large; `SQUIRCLE_BUILDS=1` shows the app's builds and
    /// `SQUIRCLE_NO_DOCK=1` hides simulators for stills; `SQUIRCLE_TASKS=1|threads` opens Tasks on either tab. `SQUIRCLE_DEMO=1` loops through them; `SQUIRCLE_STRESS=1`
    /// navigates as fast as a hurried person and checks every frame.
    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> CGFloat? { environment[key].flatMap(Double.init).map { CGFloat($0) } }
        if let slow = value("SQUIRCLE_SLOW") { SpringDriver.debugSlowMotion = Double(slow) }
        if environment["SQUIRCLE_NO_DOCK"] == "1" { dock.isHidden = true }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if let y = value("SQUIRCLE_GRID") { grid.contentOffset.y = y; applyScene() }
            guard let name = environment["SQUIRCLE_APP"], let project = projects.first(where: { $0.name == name }) else { return }
            openApp(project.id)
            if let scrub = value("SQUIRCLE_APP_SCRUB") { hold(appSpring, at: scrub); return }
            appSpring.set(1)
            guard let scrub = value("SQUIRCLE_SCRUB") else {
                if let text = environment["SQUIRCLE_SEND"] {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.agent?.debugSend(text) }
                }
                if let text = environment["SQUIRCLE_DEMO_SEND"] {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.agent?.debugFlySend(text) }
                }
                if let tab = environment["SQUIRCLE_TASKS"] {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.presentTasks(threads: tab == "threads") }
                }
                if environment["SQUIRCLE_BUILDS"] == "1" {
                    Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.presentBuilds() }
                }
                return
            }
            let sessions = model.sessions(for: project)
            let named = environment["SQUIRCLE_THREAD"].flatMap { title in sessions.first { $0.title == title } }
            openThread(environment["SQUIRCLE_DRAFT"] == "1" ? nil : (named ?? sessions.first)?.id)
            if environment["SQUIRCLE_DEMO_QUESTION"] == "1" { thread?.debugShowQuestion() }
            let later: (@escaping @MainActor () -> Void) -> Void = { work in
                Task { try? await Task.sleep(for: .seconds(2.5)); work() }
            }
            if environment["SQUIRCLE_DEMO_LENS"] == "1" { later { [weak self] in self?.thread?.debugLens() } }
            if environment["SQUIRCLE_DEMO_PULSE"] == "1" { later { [weak self] in self?.thread?.debugPulse() } }
            if let text = environment["SQUIRCLE_DEMO_SEND"] { later { [weak self] in self?.thread?.debugFlySend(text) } }
            if scrub < 1 { hold(spring, at: scrub) }
            if environment["SQUIRCLE_THEN_BACK"] == "1" {
                Task { [weak self] in try? await Task.sleep(for: .seconds(5)); self?.closeThread() }
            }
        }
        if environment["SQUIRCLE_SIM_EXPAND"] == "1" {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(9))
                guard let self, let first = dock.uses.first else { return }
                dock.expand(first.id)
            }
        }
        if environment["SQUIRCLE_STRESS"] == "1" {
            let seconds = value("SQUIRCLE_STRESS_SECONDS").map(Double.init) ?? 30
            Task { [weak self] in await self?.stress(for: seconds) }
        }
        if environment["SQUIRCLE_DEMO"] == "1" {
            Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard let self else { return }
                    switch route {
                    case .grid: if let first = projects.first { openApp(first.id) }
                    case .app:
                        if let project = selectedProject, let first = model.sessions(for: project).first,
                           Int.random(in: 0...1) == 0 { openThread(first.id) } else { closeApp() }
                    case .thread: closeThread()
                    }
                }
            }
        }
    }

    /// Holds one spring still at a value, as a finger would.
    private func hold(_ driver: SpringDriver, at value: CGFloat) {
        driver.stop()
        dragging = driver
        driver.set(value)
    }

    /// Verification only: taps and back swipes as fast as a hurried person,
    /// through the same entry points as the controls, while `audit` checks
    /// every frame. At the end, the screen must have settled on the route.
    private func stress(for seconds: Double) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            var actions: [() -> Void] = []
            if let driver = dragging {
                let target = (driver.value + CGFloat.random(in: -0.4...0.4)).clamped()
                actions.append { [weak self] in self?.moveBack(to: target) }
                actions.append { [weak self] in self?.endBack(velocity: CGFloat.random(in: -2...2), closing: Bool.random()) }
            } else {
                switch route {
                case .grid: for project in projects.prefix(3) { actions.append { [weak self] in self?.openApp(project.id) } }
                case .app:
                    actions.append { [weak self] in self?.closeApp() }
                    if let project = selectedProject {
                        for session in model.sessions(for: project).prefix(2) { actions.append { [weak self] in self?.openThread(session.id) } }
                    }
                    actions.append { [weak self] in self?.openThread(nil) }
                case .thread:
                    actions.append { [weak self] in self?.closeThread() }
                }
                if route != .grid { actions.append { [weak self] in self?.beginBack() } }
            }
            actions.randomElement()?()
            try? await Task.sleep(for: .milliseconds(Int.random(in: 20...450)))
        }
        if dragging != nil { endBack(velocity: 0, closing: Bool.random()) }
        try? await Task.sleep(for: .seconds(2.5))
        let settled = !appSpring.isAnimating && !spring.isAnimating
            && appSpring.value == appTarget && spring.value == threadTarget
            && selectedID == (route.app ?? selectedID) && threadKey == route.thread
        NSLog("STRESS end route=%@ settled=%d a=%.3f t=%.3f violations=%d", "\(route)", settled,
              appSpring.value, spring.value, auditViolations)
    }

    private var auditViolations = 0

    /// Every frame: at rest exactly the routed screen is showing, and the
    /// simulators float only over the app's screens.
    private func audit(a: CGFloat, t: CGFloat) {
        func fail(_ what: String) {
            auditViolations += 1
            NSLog("AUDIT %@ route=%@ a=%.3f t=%.3f", what, "\(route)", a, t)
        }
        if route == .grid, !appSpring.isAnimating, dragging == nil, dock.alpha > 0.001 { fail("simulators over Home") }
        guard !appSpring.isAnimating, !spring.isAnimating, dragging == nil else { return }
        switch route {
        case .grid: if home.isHidden || home.alpha < 0.99 { fail("grid not showing at rest") }
        case .app: if agent == nil || agentHost.isHidden || a < 1 || t > 0 || agent?.view.transform != .identity { fail("agent not showing at rest") }
        case .thread: if thread == nil || t < 1 || thread?.view.transform != .identity { fail("thread not showing at rest") }
        }
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        stage.frame = bounds
        dock.frame = bounds
        dock.bottomInset = view.safeAreaInsets.bottom + 150
        home.place(in: bounds)
        agentHost.frame = bounds
        grid.frame = bounds
        threadHost.frame = bounds
        agent?.view.place(in: bounds)
        thread?.view.place(in: bounds)
        let current = makeLayout()
        if current != laidOut {
            laidOut = current
            layoutGrid()
        }
        // Controls rise in with transforms; `place` keeps their resting spot exact.
        let safe = view.safeAreaInsets
        connection.place(in: CGRect(x: 16, y: safe.top + 4, width: 44, height: 44))
        add.place(in: CGRect(x: bounds.width - 60, y: safe.top + 4, width: 44, height: 44))
        applyScene()
    }

    private func relayout() {
        laidOut = nil
        view.setNeedsLayout()
    }

    private func makeLayout() -> StageLayout {
        StageLayout(size: view.bounds.size, safe: view.safeAreaInsets, titleHeight: ceil(Theme.appNameFont().lineHeight),
                    reducedMotion: Motion.reduced)
    }

    private var layout: StageLayout { laidOut ?? makeLayout() }
    private var selectedProject: AppProject? { projects.first { $0.id == selectedID } }
    /// The grid is entirely out of sight, so apps may reorder in it.
    private var gridHidden: Bool { appSpring.value >= 1 && !appSpring.isAnimating }

    // MARK: Model

    private func render() {
        let next = model.projects
        let ids = Set(next.map(\.id))
        if !gridHidden {
            // Keep what is on screen where it is; new apps join at the end.
            let known = Set(projects.map(\.id))
            let byID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            projects = projects.compactMap { byID[$0.id] } + next.filter { !known.contains($0.id) }
        } else {
            projects = next
        }
        // An app that disappeared from the Mac takes its route with it.
        if let app = route.app, !ids.contains(app) { route = .grid }
        for id in Array(cells.keys) where !ids.contains(id) {
            cells.removeValue(forKey: id)?.removeFromSuperview()
            bindings[id] = nil
        }
        stage.sync(ids: projects.map(\.id))
        for project in projects {
            let cell = cells[project.id] ?? {
                let cell = GridCell(id: project.id)
                cell.addAction(UIAction { [weak self] _ in self?.openApp(project.id) }, for: .touchUpInside)
                cells[project.id] = cell
                grid.addSubview(cell)
                return cell
            }()
            let sessions = model.sessions(for: project, includingAgent: true)
            cell.configure(name: project.name,
                           phase: sessions.contains { $0.phase == .needsYou } ? .needsYou
                               : sessions.contains { $0.phase == .working } ? .working : .idle)
            let binding = bindings[project.id] ?? {
                let binding = ScreenshotBinding(id: project.id, stage: stage)
                binding.onChange = { [weak self] in
                    self?.screenVersions[project.id, default: 0] += 1
                    self?.schedulePortraits()
                }
                return binding
            }()
            bindings[project.id] = binding
            binding.update(model: model, project: project)
        }
        renderControls()
        renderSimulators()
        UpdateCurtain.sync(in: view, build: model.updatingTo) { [weak self] in self?.model.cancelUpdate() }
        if laidOut != nil { layoutGrid() }
        sync()
        schedulePortraits()
        if let pendingTarget, !projects.isEmpty { open(pendingTarget) }
    }

    /// The simulators the open app's agents are using, over its conversations.
    private func renderSimulators() {
        // Home, once the app has slid away: no simulator floats or streams.
        guard let project = selectedProject, route.app != nil || appSpring.value > 0.001 else { dock.update(uses: [], currentThread: nil, titles: [:]); return }
        var titles: [String: String] = [:]
        for session in model.sessions(for: project, includingAgent: true) { titles[session.id] = session.displayTitle(in: project) }
        if let agent = model.agentThreadID(for: project) { titles[agent] = project.name }
        let front = route.thread != nil ? thread : agent
        dock.update(uses: model.activeSimulators(for: project), currentThread: front?.currentSessionID, titles: titles)
    }

    private func renderControls() {
        let offline = !model.connected && !model.isLoading
        let state = model.connected ? "Connected" : (offline ? "Offline" : "Connecting")
        if connection.accessibilityValue != state {
            connection.accessibilityValue = state
            let tint: UIColor = model.connected ? Theme.success : (offline ? Theme.warning : .secondaryLabel)
            connection.configuration?.image = UIImage(systemName: "macbook")?.withTintColor(tint, renderingMode: .alwaysOriginal)
        }
        let detail = model.error ?? (model.connected ? "Connected to \(model.hostName)" : model.status)
        connection.menu = UIMenu(title: detail, children: [
            UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                Task { await self?.model.reconnect() }
            }
        ])
    }

    private func layoutGrid() {
        let layout = self.layout
        grid.contentSize = CGSize(width: view.bounds.width, height: layout.gridContentHeight(count: projects.count))
        for (index, project) in projects.enumerated() {
            guard let cell = cells[project.id] else { continue }
            cell.transform = .identity
            cell.frame = layout.cellFrame(index)
            cell.phoneHeight = layout.gridPhoneHeight
        }
        schedulePortraits()
        // An app reordered while the grid was hidden stays in sight for its return.
        if gridHidden, let id = selectedID, let cell = cells[id] {
            let visible = CGRect(x: 0, y: grid.contentOffset.y + layout.gridTop, width: grid.bounds.width,
                                 height: grid.bounds.height - layout.gridTop)
            if !visible.contains(cell.frame) {
                let maxY = max(0, grid.contentSize.height - grid.bounds.height)
                grid.contentOffset.y = (cell.frame.minY - layout.gridTop).clamped(0, maxY)
            }
        }
    }

    // MARK: Navigation

    /// Where each spring is headed: open only while the route wants exactly
    /// what is mounted. Anything else first goes back to zero, off screen.
    private var appTarget: CGFloat { route.app != nil && route.app == selectedID ? 1 : 0 }
    private var threadTarget: CGFloat {
        appTarget == 1 && route.thread != nil && route.thread == threadKey && thread != nil ? 1 : 0
    }

    func openApp(_ id: String) {
        guard presentedViewController == nil, projects.contains(where: { $0.id == id }) else { return }
        if route.app != id { Theme.openHaptic() }
        route = .app(id)
        sync()
    }

    func closeApp() {
        guard route != .grid, presentedViewController == nil else { return }
        Theme.selectionHaptic()
        route = .grid
        sync()
    }

    /// A thread of the mounted app; nil starts a new conversation.
    func openThread(_ sessionID: String?) {
        guard presentedViewController == nil, let app = selectedID, route.app == app else { return }
        Theme.openHaptic()
        route = .thread(app: app, thread: sessionID ?? "draft:" + UUID().uuidString)
        sync()
    }

    func closeThread() {
        guard case .thread(let app, _) = route, presentedViewController == nil else { return }
        view.endEditing(true)
        route = .app(app)
        sync()
    }

    /// A tapped notification or Live Activity: its app, then its thread or
    /// build. Whatever was presented gives way.
    func open(_ target: PushTarget) {
        let id = target.project.flatMap { p in projects.contains { $0.id == p } ? p : nil }
            ?? target.bundle.flatMap { b in projects.first { $0.bundleID == b }?.id }
        guard let id, let project = projects.first(where: { $0.id == id }) else {
            pendingTarget = projects.isEmpty ? target : nil
            return
        }
        pendingTarget = nil
        if presentedViewController != nil { dismiss(animated: false) }
        view.endEditing(true)
        if let thread = target.thread, thread != model.agentThreadID(for: project) {
            route = .thread(app: id, thread: thread)
        } else {
            route = .app(id)
        }
        sync()
        guard let buildID = target.build else { return }
        Task { [weak self] in
            // Builds may still be on their way from the Mac.
            for _ in 0..<20 {
                guard let self else { return }
                if let build = model.builds.first(where: { $0.id == buildID }) {
                    guard presentedViewController == nil else { return }
                    let navigation = UINavigationController(rootViewController: BuildDetailViewController(model: model, build: build))
                    navigation.modalPresentationStyle = .pageSheet
                    navigation.sheetPresentationController?.detents = [.large()]
                    navigation.sheetPresentationController?.prefersGrabberVisible = true
                    present(navigation, animated: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Makes what is mounted and where the springs head agree with the route.
    /// Safe to call at any moment, any number of times.
    private func sync() {
        guard !syncing else { return }
        syncing = true
        defer {
            syncing = false
            renderSimulators()
            applyScene()
            onViewing?(route == .grid ? nil : route.thread != nil ? thread?.currentSessionID : agent?.currentSessionID)
        }
        // The thread level only exists inside its app; it leaves first.
        if spring.value <= 0.001, threadKey != nil, route.thread != threadKey || route.app != selectedID {
            unmountThread()
        }
        if appSpring.value <= 0.001, let app = route.app, app != selectedID {
            unmountThread()
            unmountAgent()
            mountApp(app)
        }
        if spring.value <= 0.001, thread == nil, let key = route.thread, route.app == selectedID {
            mountThread(key)
        }
        for (driver, target) in [(appSpring, appTarget), (spring, threadTarget)] where driver !== dragging {
            if driver.target != target || (!driver.isAnimating && driver.value != target) {
                driver.redirect(to: target)
            }
        }
    }

    private func rested() {
        sync()
        guard dragging == nil, !appSpring.isAnimating, !spring.isAnimating else { return }
        let focus: Any? = switch route {
        case .grid: selectedID.flatMap { cells[$0] }
        case .app: agent?.view
        case .thread: thread?.view
        }
        UIAccessibility.post(notification: .screenChanged, argument: focus)
    }

    private func mountApp(_ id: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        selectedID = id
        model.selectProject(project)
        let controller = ThreadViewController(model: model, project: project, sessionID: model.agentThreadID(for: project), agent: true)
        controller.onOpenThread = { [weak self] id in self?.openThread(id) }
        controller.onTasks = { [weak self] in self?.presentTasks() }
        controller.onBuilds = { [weak self] in self?.presentBuilds() }
        host(controller, in: agentHost)
        controller.onBack = { [weak self] in self?.closeApp() }
        agent = controller
    }

    private func unmountAgent() {
        guard let controller = agent else { return }
        agent = nil
        dismount(controller)
    }

    /// Adds a conversation as an opaque page that covers what is beneath it
    /// as it slides in, never text over text.
    private func host(_ controller: ThreadViewController, in host: UIView) {
        controller.host = self
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.backgroundColor = Theme.paper
        controller.view.layer.shadowColor = UIColor.black.cgColor
        controller.view.layer.shadowOpacity = 0.14
        controller.view.layer.shadowRadius = 18
        controller.view.layer.shadowOffset = CGSize(width: -6, height: 0)
        controller.view.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
        controller.view.transform = CGAffineTransform(translationX: view.bounds.width, y: 0)
        host.addSubview(controller.view)
        controller.didMove(toParent: self)
        controller.view.layoutIfNeeded()
    }

    private func dismount(_ controller: ThreadViewController) {
        controller.tearDown()
        dock.docked = []
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func mountThread(_ key: String) {
        guard let project = selectedProject else { return }
        agent?.deactivate()
        let controller = ThreadViewController(model: model, project: project, sessionID: key.hasPrefix("draft:") ? nil : key)
        controller.onBack = { [weak self] in self?.closeThread() }
        host(controller, in: threadHost)
        thread = controller
        threadKey = key
    }

    private func unmountThread() {
        guard let controller = thread else { return }
        thread = nil
        threadKey = nil
        dismount(controller)
        agent?.reactivate()
    }

    // MARK: Back

    /// Swipe in from the left edge to go back a level, following the finger.
    @objc private func backPanned(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        switch gesture.state {
        case .began: beginBack()
        case .changed:
            guard dragging != nil else { return }
            moveBack(to: dragStart - gesture.translation(in: view).x / width)
        case .ended, .cancelled, .failed:
            guard let driver = dragging else { return }
            let velocity = -gesture.velocity(in: view).x / width
            let closing = gesture.state == .ended && driver.value + velocity * 0.18 < 0.5
            #if DEBUG
            MotionAudit.shared.note("back", values: ["progress": driver.value, "velocity": velocity, "closing": closing])
            #endif
            endBack(velocity: velocity, closing: closing)
        default: break
        }
    }

    /// The top level on screen: the thread if it is showing, else the app.
    private func beginBack() {
        guard dragging == nil, route != .grid else { return }
        let driver = route.thread != nil && threadTarget == 1 ? spring : appSpring
        guard driver === spring || appTarget == 1 else { return }
        driver.stop()
        dragging = driver
        dragStart = driver.value
        applyScene()
    }

    private func moveBack(to value: CGFloat) {
        dragging?.set(value.clamped())
    }

    private func endBack(velocity: CGFloat, closing: Bool) {
        guard let driver = dragging else { return }
        dragging = nil
        if closing {
            if driver === spring { closeThread() } else { closeApp() }
        }
        let target = driver === spring ? threadTarget : appTarget
        driver.animate(to: target, initialVelocity: velocity)
        sync()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, presentedViewController == nil,
              pan.velocity(in: view).x >= 0, dragging == nil else { return false }
        if route.thread != nil {
            guard let thread, threadTarget == 1 else { return false }
            return thread.allowsBackSwipe(at: pan.location(in: thread.view))
        }
        guard let agent, appTarget == 1 else { return false }
        return agent.allowsBackSwipe(at: pan.location(in: agent.view))
    }

    /// Scrolling waits until a touch is known not to be a back swipe, so the
    /// two never move together.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }

    // MARK: Portraits

    private var displayScale: CGFloat { view.window?.windowScene?.screen.scale ?? traitCollection.displayScale }
    private var dark: Bool { traitCollection.userInterfaceStyle == .dark }

    private func gridPose(_ index: Int) -> PhonePose {
        layout.gridPose(cell: layout.cellFrame(index), column: index % layout.columns)
    }

    /// What a portrait shows; a different key means it must be drawn again.
    private func portraitKey(_ id: String, _ pose: PhonePose) -> String {
        "\(screenVersions[id] ?? 0):\(pose.height):\(pose.yaw):\(pose.pitch):\(dark)"
    }

    /// Redraws stale portraits one per frame, so a grid of many apps never
    /// stalls one.
    private func schedulePortraits() {
        guard portraitTask == nil, laidOut != nil else { return }
        portraitTask = Task { [weak self] in
            while let self, drawNextPortrait() { await DisplayFrame.next() }
            self?.portraitTask = nil
        }
    }

    /// Draws one stale grid portrait. False when none is stale.
    private func drawNextPortrait() -> Bool {
        for (index, project) in projects.enumerated() {
            guard let cell = cells[project.id] else { continue }
            let pose = gridPose(index), key = portraitKey(project.id, pose)
            guard cell.portraitKey != key else { continue }
            cell.portraitKey = key
            cell.portrait.image = stage.portrait(for: project.id, pose: pose, scale: displayScale)
            return true
        }
        return false
    }

    // MARK: Scene

    /// Every frame, from the route and the two springs alone: where the
    /// selected device stands and whether the stage or a portrait draws it,
    /// what is visible, and which screen takes touches.
    private func applyScene() {
        let width = view.bounds.width
        guard width > 0, !syncing else { return }
        let layout = self.layout
        // A spring may overshoot its end a little; screens never travel past it.
        let a = appSpring.value.clamped(), t = spring.value.clamped()
        let scroll = grid.contentOffset.y
        var origin = CGPoint(x: width / 2, y: view.safeAreaInsets.top + 58)
        if let id = selectedID, let index = projects.firstIndex(where: { $0.id == id }) {
            let cell = layout.cellFrame(index).offsetBy(dx: 0, dy: -scroll)
            origin = CGPoint(x: cell.midX, y: cell.minY + layout.gridPhoneHeight / 2)
        }

        // Home falls back as the conversation slides over it: every device
        // drifts away from the opened one, shrinks and fades.
        home.alpha = (1 - a * 1.6).clamped()
        home.isHidden = a >= 1 && !appSpring.isAnimating && dragging == nil
        for (index, project) in projects.enumerated() {
            guard let cell = cells[project.id] else { continue }
            let frame = layout.cellFrame(index).offsetBy(dx: 0, dy: -scroll)
            cell.layer.transform = layout.recede(frame, from: origin, progress: a)
            cell.alpha = layout.recedeAlpha(progress: a)
            cell.captionAlpha = project.id == selectedID ? (1 - a * 4).clamped() : 1
        }
        dock.alpha = a
        dock.isUserInteractionEnabled = route.app != nil && a > 0.5

        // Flat pushes. The agent's conversation slides over Home; a thread
        // slides over the agent while the agent drifts a third as far left.
        // The device travels on its own.
        agentHost.isHidden = a <= 0.001
        agent?.setTransitionProgress(a * (1 - t))
        agent?.view.transform = CGAffineTransform(translationX: width * (1 - a) - (layout.reducedMotion ? 0 : width * 0.3 * t), y: 0)
        thread?.setTransitionProgress(t)
        thread?.view.transform = CGAffineTransform(translationX: width * (1 - t), y: 0)

        // Touches go to the screen the route names, from the first frame of its
        // transition. A conversation on its way out still covers the one
        // beneath, so touches on it stop there.
        let onGrid = route == .grid
        let onAgent = route.app != nil && route.app == selectedID && route.thread == nil
        let onThread = threadTarget == 1
        home.isUserInteractionEnabled = onGrid
        home.accessibilityElementsHidden = !onGrid
        agent?.view.isUserInteractionEnabled = onAgent
        agent?.view.accessibilityElementsHidden = !onAgent
        thread?.view.isUserInteractionEnabled = onThread
        thread?.view.accessibilityElementsHidden = !onThread
        threadHost.swallowsTouches = thread != nil && !onThread
        #if DEBUG
        audit(a: a, t: t)
        #endif
    }

    // MARK: Sheets

    private func presentBuilds() {
        guard let project = selectedProject, presentedViewController == nil, route == .app(project.id) else { return }
        Theme.selectionHaptic()
        let controller = BuildsViewController(model: model, project: project)
        controller.onNewThread = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.openThread(nil) }
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(controller, animated: true)
    }

    private func presentTasks(threads: Bool = false) {
        guard let project = selectedProject, presentedViewController == nil, route == .app(project.id) else { return }
        Theme.selectionHaptic()
        let controller = TasksViewController(model: model, project: project, threads: threads)
        controller.onOpen = { [weak self, weak controller] id in
            controller?.dismiss(animated: true) { self?.openThread(id) }
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }

    private func presentImport() {
        guard route == .grid, presentedViewController == nil else { return }
        let importer = AppImportNavigationController(model: model)
        importer.onImport = { [weak self, weak importer] project in
            importer?.dismiss(animated: true) {
                guard let self else { return }
                self.render()
                guard let index = self.projects.firstIndex(where: { $0.id == project.id }) else { return }
                let frame = self.layout.cellFrame(index)
                self.grid.scrollRectToVisible(frame.insetBy(dx: 0, dy: -self.layout.gridTop), animated: !Motion.reduced)
            }
        }
        present(importer, animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        switch route {
        case .thread: closeThread(); return true
        case .app: closeApp(); return true
        case .grid: return false
        }
    }
}

extension StudioViewController: ConversationHost {
    var simulatorFeeds: SimulatorFeeds { feeds }
    var expandsSimulators: Bool { true }
    func expandSimulator(_ use: SimulatorUse) { dock.expand(use.id) }
    func conversation(_ conversation: ThreadViewController, showsSimulators ids: Set<String>) {
        guard conversation === (thread ?? agent) else { return }
        dock.docked = ids
    }
}

/// A container that is never itself the target of a touch, unless it is
/// told to swallow touches that land on its (non-interactive) content.
final class PassthroughView: UIView {
    var swallowsTouches = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if swallowsTouches, subviews.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return self }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// One app in the grid: a still portrait of its device, which scrolls with
/// the grid like any view, and its name.
@MainActor
final class GridCell: UIControl {
    let id: String
    let portrait = UIImageView()
    var portraitKey = ""
    var phoneHeight: CGFloat = 0 { didSet { setNeedsLayout() } }
    var captionAlpha: CGFloat = 1 {
        didSet { if captionAlpha != oldValue { name.alpha = captionAlpha; dot.alpha = captionAlpha } }
    }
    private let name = Theme.label("", Theme.appCaptionFont())
    private let dot = UIView()

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "project.cell"
        accessibilityValue = id
        name.textAlignment = .center
        name.lineBreakMode = .byTruncatingTail
        dot.layer.cornerRadius = 3.5
        dot.isHidden = true
        [portrait, name, dot].forEach {
            $0.isUserInteractionEnabled = false
            addSubview($0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name text: String, phase: ChatSession.Phase) {
        if name.text != text { name.text = text }
        dot.isHidden = phase == .idle
        dot.backgroundColor = phase == .needsYou ? Theme.warning : Theme.success
        accessibilityLabel = text
        accessibilityValue = phase == .needsYou ? "Needs you" : (phase == .working ? "Working" : nil)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = DeviceStage.portraitSize(height: phoneHeight)
        portrait.bounds = CGRect(origin: .zero, size: size)
        portrait.center = CGPoint(x: bounds.midX, y: phoneHeight / 2)
        let top = phoneHeight + 12
        let gap: CGFloat = dot.isHidden ? 0 : 12
        let width = min(bounds.width - gap, ceil(name.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 21)).width))
        let x = (bounds.width - width - gap) / 2
        dot.frame = CGRect(x: x, y: top + 7, width: 7, height: 7)
        name.frame = CGRect(x: x + gap, y: top, width: width, height: 21)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, !Motion.reduced else { return }
            let scale: CGFloat = isHighlighted ? 0.95 : 1
            UIView.animate(springDuration: 0.3, bounce: 0.25, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.portrait.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }
}
