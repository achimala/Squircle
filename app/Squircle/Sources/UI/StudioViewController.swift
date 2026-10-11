import UIKit

/// Where the user has asked to be. The only navigation state there is:
/// everything on screen is derived from it and from two springs that always
/// move toward what it implies, so no sequence of taps can leave the screen
/// somewhere it should not be.
enum Route: Equatable {
    case grid
    case app(String)
    /// `thread` is a T3 thread ID, or `draft:<uuid>` for a new conversation.
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
/// those devices that scroll natively. Opening an app lifts its device to the
/// top while the others fall back and its threads rise beneath it; a thread
/// pushes in over the list while the same device travels into it.
///
/// Navigation is a route plus two springs (`appSpring` grid→app, `spring`
/// app→thread). Each spring's target is a function of the route and of what
/// is mounted. What is mounted (the app page's app, the thread controller)
/// changes only while its spring is at zero, i.e. off screen. Every frame is
/// a pure function of those values, including which views take touches and
/// whether a portrait or the 3D stage draws the device.
@MainActor
final class StudioViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let model: SquircleModel
    private let stage = DeviceStage()
    /// The grid and its controls.
    private let home = UIView()
    private let grid = UIScrollView()
    private let connection = Theme.glassButton(symbol: "macbook", identifier: "connection.status", accessibilityLabel: "Mac connection")
    private let add = Theme.glassButton(symbol: "plus", identifier: "project.add", accessibilityLabel: "Add app")
    /// One app's threads and controls.
    private let pageHost = UIView()
    /// Holds the conversation above the list; touches pass through when empty.
    private let threadHost = PassthroughView()
    private let page = AppPage()
    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "project.back", accessibilityLabel: "Apps")
    private let compose = Theme.glassButton(symbol: "square.and.pencil", title: "New Thread", prominent: true, identifier: "thread.new")
    private let builds = Theme.glassButton(symbol: "shippingbox", identifier: "project.builds", accessibilityLabel: "Builds")
    /// 0 = grid, 1 = app page.
    private let appSpring = SpringDriver()
    /// 0 = app page, 1 = thread.
    private let spring = SpringDriver()
    private var cells: [String: GridCell] = [:]
    private var bindings: [String: ScreenshotBinding] = [:]
    /// Display order. It changes only while the grid is out of sight, so
    /// nothing rearranges under a finger.
    private var projects: [AppProject] = []
    /// Pending model render (debounced), portrait drawing and handback.
    private var renderTask: Task<Void, Never>?
    private var portraitTask: Task<Void, Never>?
    private var handbackTask: Task<Void, Never>?
    private var laidOut: StageLayout?
    /// Bumped whenever an app's screen changes; part of each portrait's key.
    private var screenVersions: [String: Int] = [:]

    // MARK: Navigation state

    private var route = Route.grid
    /// The app whose page (and device) is mounted. Changes only at `appSpring` 0.
    private(set) var selectedID: String?
    /// The mounted conversation and its route key. Changes only at `spring` 0.
    private(set) var thread: ThreadViewController?
    private var threadKey: String?
    /// A finger on the back edge owns one spring; targets wait for release.
    private var dragging: SpringDriver?
    private var dragStart: CGFloat = 0
    /// Portraits were hidden in the last frame (the stage had the device).
    private var portraitsHidden = false
    /// Inside `sync()`: the scene is drawn once, from the finished state.
    private var syncing = false

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
        view.addSubview(pageHost)
        view.addSubview(threadHost)
        view.addSubview(stage.overlay)

        grid.alwaysBounceVertical = true
        grid.showsVerticalScrollIndicator = false
        grid.contentInsetAdjustmentBehavior = .never
        grid.accessibilityIdentifier = "app.grid"
        if #available(iOS 26.0, *) { grid.topEdgeEffect.style = .soft }
        home.addSubview(grid)
        [connection, add].forEach(home.addSubview)
        connection.showsMenuAsPrimaryAction = true
        add.addAction(UIAction { [weak self] _ in self?.presentImport() }, for: .touchUpInside)

        page.onScroll = { [weak self] in self?.applyScene() }
        page.onOpenThread = { [weak self] id in self?.openThread(id) }
        pageHost.addSubview(page)
        [back, compose, builds].forEach(pageHost.addSubview)
        back.addAction(UIAction { [weak self] _ in self?.closeApp() }, for: .touchUpInside)
        compose.addAction(UIAction { [weak self] _ in self?.openThread(nil) }, for: .touchUpInside)
        builds.addAction(UIAction { [weak self] _ in self?.presentBuilds() }, for: .touchUpInside)

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
        stage.onRendered = { [weak self] in self?.applyScene() }

        Task { [weak self, updates = model.updates] in
            for await _ in updates {
                guard let self else { return }
                // Bursts of model changes render once, 80 ms after the last.
                renderTask?.cancel()
                renderTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    self?.render()
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
    /// (open the app with this name), `SQUIRCLE_APP_SCRUB` (0…1 of opening it),
    /// `SQUIRCLE_EXPAND` (its list's scroll in points), `SQUIRCLE_SCRUB` (0…1
    /// of the thread transition) and `SQUIRCLE_DETENT` (0…2 of the thread's
    /// divider). `SQUIRCLE_DEMO=1` loops through them; `SQUIRCLE_STRESS=1`
    /// navigates as fast as a hurried person and checks every frame.
    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> CGFloat? { environment[key].flatMap(Double.init).map { CGFloat($0) } }
        if let slow = value("SQUIRCLE_SLOW") { SpringDriver.debugSlowMotion = Double(slow) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if let y = value("SQUIRCLE_GRID") { grid.contentOffset.y = y; applyScene() }
            guard let name = environment["SQUIRCLE_APP"], let project = projects.first(where: { $0.name == name }) else { return }
            openApp(project.id)
            if let scrub = value("SQUIRCLE_APP_SCRUB") { hold(appSpring, at: scrub); return }
            appSpring.set(1)
            if let expand = value("SQUIRCLE_EXPAND") { page.contentOffset.y = expand }
            guard let scrub = value("SQUIRCLE_SCRUB") else { return }
            let sessions = model.sessions(for: project)
            let named = environment["SQUIRCLE_THREAD"].flatMap { title in sessions.first { $0.title == title } }
            openThread(environment["SQUIRCLE_DRAFT"] == "1" ? nil : (named ?? sessions.first)?.id)
            if let detent = value("SQUIRCLE_DETENT") { thread?.debugSetDetent(detent) }
            if environment["SQUIRCLE_DEMO_QUESTION"] == "1" { thread?.debugShowQuestion() }
            let later: (@escaping @MainActor () -> Void) -> Void = { work in
                Task { try? await Task.sleep(for: .seconds(2.5)); work() }
            }
            if environment["SQUIRCLE_DEMO_TAP"] == "1" { later { [weak self] in self?.thread?.debugTapDevice() } }
            if environment["SQUIRCLE_DEMO_LENS"] == "1" { later { [weak self] in self?.thread?.debugLens() } }
            if environment["SQUIRCLE_DEMO_PULSE"] == "1" { later { [weak self] in self?.thread?.debugPulse() } }
            if let text = environment["SQUIRCLE_DEMO_SEND"] { later { [weak self] in self?.thread?.debugFlySend(text) } }
            if scrub < 1 { hold(spring, at: scrub) }
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

    /// Every frame: the selected device is drawn somewhere, and at rest exactly
    /// the routed screen is showing.
    private func audit(a: CGFloat, t: CGFloat, posed: Bool) {
        func fail(_ what: String) {
            auditViolations += 1
            NSLog("AUDIT %@ route=%@ a=%.3f t=%.3f", what, "\(route)", a, t)
        }
        if let id = selectedID, a > 0.001 || route.app == id {
            let cellShows = cells[id].map { !$0.portrait.isHidden } ?? false
            let pageShows = !page.portrait.isHidden && !page.isHidden && !pageHost.isHidden
            if !posed && !cellShows && !pageShows { fail("device drawn nowhere") }
        }
        guard !appSpring.isAnimating, !spring.isAnimating, dragging == nil else { return }
        switch route {
        case .grid: if home.isHidden || home.alpha < 0.99 { fail("grid not showing at rest") }
        case .app: if pageHost.isHidden || page.isHidden || a < 1 || t > 0 { fail("app page not showing at rest") }
        case .thread: if thread == nil || t < 1 || thread?.view.transform != .identity { fail("thread not showing at rest") }
        }
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        stage.frame = bounds
        stage.overlay.frame = bounds
        home.place(in: bounds)
        pageHost.place(in: bounds)
        grid.frame = bounds
        page.frame = bounds
        threadHost.frame = bounds
        thread?.view.place(in: bounds)
        let current = makeLayout()
        if current != laidOut {
            laidOut = current
            layoutGrid()
            page.layout = current
        }
        // Controls rise in with transforms; `place` keeps their resting spot exact.
        let safe = view.safeAreaInsets
        connection.place(in: CGRect(x: 16, y: safe.top + 4, width: 44, height: 44))
        add.place(in: CGRect(x: bounds.width - 60, y: safe.top + 4, width: 44, height: 44))
        back.place(in: CGRect(x: 16, y: safe.top + 4, width: 44, height: 44))
        let barTop = current.pageBottomBarTop, barHeight = StageLayout.bottomBarHeight
        let buildsFrame = CGRect(x: bounds.width - 16 - barHeight, y: barTop, width: barHeight, height: barHeight)
        builds.place(in: buildsFrame)
        compose.place(in: CGRect(x: 16, y: barTop, width: buildsFrame.minX - 26, height: barHeight))
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
            let sessions = model.sessions(for: project)
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
        if let project = selectedProject {
            page.update(project: project, sessions: model.sessions(for: project), agentName: model.agentName(for:),
                        loading: model.isLoading, error: model.error)
        }
        renderControls()
        if let build = model.updatingTo {
            UpdateCurtain.show(in: view, build: build) { [weak self] in self?.model.cancelUpdate() }
        }
        if laidOut != nil { layoutGrid() }
        sync()
        schedulePortraits()
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
                Task { await self?.model.refresh() }
            }
        ])
        let project = selectedProject
        compose.isEnabled = project != nil
        let building = project.map { project in
            model.buildingProjectIDs.contains(project.id)
                || model.builds(for: project).contains { $0.status == "queued" || $0.status == "running" }
        } ?? false
        if builds.configuration?.showsActivityIndicator != building {
            builds.configuration?.showsActivityIndicator = building
            builds.accessibilityValue = building ? "Building" : nil
        }
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

    /// Makes what is mounted and where the springs head agree with the route.
    /// Safe to call at any moment, any number of times.
    private func sync() {
        guard !syncing else { return }
        syncing = true
        defer {
            syncing = false
            applyScene()
        }
        // The thread level only exists inside its app; it leaves first.
        if spring.value <= 0.001, threadKey != nil, route.thread != threadKey || route.app != selectedID {
            unmountThread()
        }
        if appSpring.value <= 0.001, let app = route.app, app != selectedID {
            unmountThread()
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
        case .app: page.hero
        case .thread: thread?.view
        }
        UIAccessibility.post(notification: .screenChanged, argument: focus)
    }

    private func mountApp(_ id: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        selectedID = id
        page.reset()
        page.update(project: project, sessions: model.sessions(for: project), agentName: model.agentName(for:),
                    loading: model.isLoading, error: model.error)
        ensureHeroPortrait(id)
        renderControls()
        model.selectProject(project)
    }

    private func mountThread(_ key: String) {
        guard let project = selectedProject else { return }
        let sessionID = key.hasPrefix("draft:") ? nil : key
        let controller = ThreadViewController(model: model, project: project, sessionID: sessionID, stage: stage)
        controller.layoutProvider = { [weak self] in self?.layout }
        controller.onBack = { [weak self] in self?.closeThread() }
        controller.onGeometry = { [weak self] in self?.applyScene() }
        thread = controller
        threadKey = key
        addChild(controller)
        controller.view.frame = view.bounds
        // An opaque page that covers the list as it slides in, never text over text.
        controller.view.backgroundColor = Theme.paper
        controller.view.layer.shadowColor = UIColor.black.cgColor
        controller.view.layer.shadowOpacity = 0.14
        controller.view.layer.shadowRadius = 18
        controller.view.layer.shadowOffset = CGSize(width: -6, height: 0)
        controller.view.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
        controller.view.transform = CGAffineTransform(translationX: view.bounds.width, y: 0)
        threadHost.addSubview(controller.view)
        controller.didMove(toParent: self)
        controller.view.layoutIfNeeded()
    }

    private func unmountThread() {
        guard let controller = thread else { return }
        thread = nil
        threadKey = nil
        controller.tearDown()
        stage.endLive(for: controller.project.id)
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
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
        return appTarget == 1
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

    /// Draws one stale portrait, the opened app's first. False when none is stale.
    private func drawNextPortrait() -> Bool {
        if let id = selectedID, ensureHeroPortrait(id) { return true }
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

    /// Draws the opened app's list portrait if stale. True if it drew.
    @discardableResult
    private func ensureHeroPortrait(_ id: String) -> Bool {
        let pose = layout.pagePose(scroll: 0), key = id + portraitKey(id, pose)
        guard page.portraitKey != key else { return false }
        page.portraitKey = key
        page.portrait.image = stage.portrait(for: id, pose: pose, scale: displayScale)
        return true
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
        let moving = appSpring.isAnimating || spring.isAnimating || dragging != nil
        let scroll = grid.contentOffset.y
        var origin = CGPoint(x: width / 2, y: layout.pageHeroTop)
        var poses: [String: PhonePose] = [:]
        var hidePortraits = false
        if let id = selectedID, let index = projects.firstIndex(where: { $0.id == id }) {
            let start = layout.gridPose(cell: layout.cellFrame(index).offsetBy(dx: 0, dy: -scroll), column: index % layout.columns)
            origin = start.center
            var pose = layout.transitionPose(from: start, to: layout.pagePose(scroll: page.offset), progress: a)
            if t > 0.0001, let thread { pose = layout.transitionPose(from: pose, to: thread.pose, progress: t) }
            // A portrait draws the device only where it rests still: in the
            // grid or at the top of its list. Anywhere else the stage does,
            // and the portrait hides once the stage has actually drawn it.
            let resting = !moving && (a == 0 || (a == 1 && t == 0))
            if !resting {
                poses[id] = pose
                hidePortraits = stage.drawn.contains(id)
                if !hidePortraits { stage.requestRender() }
            } else if portraitsHidden || handbackTask != nil {
                // Handing back: the portrait shows now; the stage keeps the
                // device beneath it until the next frame has put it on screen.
                poses[id] = pose
                if handbackTask == nil {
                    handbackTask = Task { [weak self] in
                        await DisplayFrame.next()
                        self?.handbackTask = nil
                        self?.applyScene()
                    }
                }
            }
        }
        portraitsHidden = hidePortraits
        stage.apply(poses)
        stage.setLive(!poses.isEmpty && moving, reason: "navigation")
        page.portrait.isHidden = hidePortraits
        for (id, cell) in cells { cell.portrait.isHidden = id == selectedID && hidePortraits }

        // The other apps drift back and fade; the opened one's name goes first.
        home.alpha = (1 - a * 1.6).clamped()
        home.isHidden = a >= 1 && !moving
        for (index, project) in projects.enumerated() {
            guard let cell = cells[project.id] else { continue }
            if project.id == selectedID {
                cell.layer.transform = CATransform3DIdentity
                cell.alpha = 1
                cell.captionAlpha = (1 - a * 4).clamped()
            } else {
                let frame = layout.cellFrame(index).offsetBy(dx: 0, dy: -scroll)
                cell.layer.transform = layout.recede(frame, from: origin, progress: a)
                cell.alpha = layout.recedeAlpha(progress: a)
                cell.captionAlpha = 1
            }
        }

        // The app's list rises beneath its device, row by row.
        pageHost.isHidden = a <= 0.001
        page.isHidden = t >= 1 && !moving
        page.setArrival(a, reduced: layout.reducedMotion)
        let chrome = ((a - 0.5) / 0.5).clamped()
        for button in [back, compose, builds] { button.alpha = chrome * (1 - t * 2).clamped() }
        compose.transform = CGAffineTransform(translationX: 0, y: (1 - chrome) * 40)
        builds.transform = compose.transform

        // A thread: a flat push. The conversation slides over from the right
        // while the list drifts a third as far left. The device travels on its own.
        page.transform = CGAffineTransform(translationX: layout.reducedMotion ? 0 : -width * 0.3 * t, y: 0)
        thread?.setTransitionProgress(t)
        thread?.view.transform = CGAffineTransform(translationX: width * (1 - t), y: 0)

        // Touches go to the screen the route names, from the first frame of its
        // transition. A conversation on its way out still covers the list, so
        // touches on it stop there instead of reaching rows hidden beneath.
        let onGrid = route == .grid
        let onPage = route.app != nil && route.app == selectedID && route.thread == nil
        let onThread = threadTarget == 1
        home.isUserInteractionEnabled = onGrid
        home.accessibilityElementsHidden = !onGrid
        pageHost.isUserInteractionEnabled = onPage
        pageHost.accessibilityElementsHidden = !onPage
        thread?.view.isUserInteractionEnabled = onThread
        thread?.view.accessibilityElementsHidden = !onThread
        threadHost.swallowsTouches = thread != nil && !onThread
        #if DEBUG
        audit(a: a, t: t, posed: !poses.isEmpty)
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
    private let name = Theme.label("", Theme.font(.headline, 16, .semibold))
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

/// One opened app: its device, its name beneath and its threads beneath that.
/// At rest the device is a portrait in the list's content that shrinks to
/// make room as the list scrolls up; in motion the stage draws it.
@MainActor
final class AppPage: UIScrollView, UIScrollViewDelegate {
    private(set) var project: AppProject?
    var onScroll: (() -> Void)?
    var onOpenThread: ((String) -> Void)?
    var layout: StageLayout? { didSet { if layout != oldValue { arrange() } } }
    /// Tappable, accessible stand-in for the device.
    let hero = UIControl()
    /// The device at rest: a still portrait that scales as the list scrolls.
    let portrait = UIImageView()
    var portraitKey = ""
    private let nameLabel = Theme.label("", Theme.appNameFont())
    private let rows = UIStackView()
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private var rowViews: [String: ThreadRow] = [:]
    private var renderedOrder: [String] = []

    /// Distance scrolled from the resting position.
    var offset: CGFloat { contentOffset.y }

    init() {
        super.init(frame: .zero)
        delegate = self
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        accessibilityIdentifier = "workspace.threads"
        nameLabel.textAlignment = .center
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.6
        nameLabel.accessibilityTraits = .header
        rows.axis = .vertical
        notice.textAlignment = .center
        hero.isAccessibilityElement = true
        hero.accessibilityIdentifier = "project.hero"
        hero.accessibilityTraits = .button
        hero.accessibilityHint = "Shows threads"
        hero.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        portrait.isUserInteractionEnabled = false
        [portrait, hero, nameLabel, rows, notice].forEach(addSubview)
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
            bottomEdgeEffect.style = .soft
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        layer.removeAllAnimations()
        contentOffset = .zero
    }

    func update(project: AppProject, sessions: [ChatSession], agentName: (JSONValue) -> String, loading: Bool, error: String?) {
        if self.project?.id != project.id {
            rowViews.values.forEach { $0.removeFromSuperview() }
            rowViews = [:]
            renderedOrder = []
        }
        self.project = project
        if nameLabel.text != project.name { nameLabel.text = project.name }
        hero.accessibilityLabel = project.name
        hero.accessibilityValue = project.id
        let ids = sessions.map(\.id)
        for id in Array(rowViews.keys) where !ids.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        for session in sessions {
            let row = rowViews[session.id] ?? {
                let row = ThreadRow(sessionID: session.id)
                row.addAction(UIAction { [weak self] _ in self?.onOpenThread?(session.id) }, for: .touchUpInside)
                rowViews[session.id] = row
                return row
            }()
            row.configure(title: session.displayTitle(in: project), agent: agentName(session.modelSelection),
                          date: session.updatedAt, phase: session.phase)
        }
        let message: String? = sessions.isEmpty ? (error ?? (loading ? "Loading threads…" : "No threads yet")) : nil
        let changed = ids != renderedOrder || notice.text != message
        if ids != renderedOrder {
            renderedOrder = ids
            rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0) }
            for (index, id) in ids.enumerated() {
                guard let row = rowViews[id] else { continue }
                rows.addArrangedSubview(row)
                row.showsSeparator = index < ids.count - 1
            }
        }
        notice.text = message
        notice.isHidden = message == nil
        notice.textColor = error == nil ? .secondaryLabel : Theme.failure
        notice.accessibilityIdentifier = error == nil ? "workspace.empty" : "workspace.error"
        if changed { arrange() }
    }

    private func arrange() {
        guard let layout, bounds.width > 0 else { return }
        let width = bounds.width
        // Rows rise in with a transform; bounds and center ignore it, frame would not.
        place(nameLabel, CGRect(x: 28, y: layout.pageNameTop, width: width - 56, height: layout.titleHeight))
        let rowsTop = layout.pageNameTop + layout.titleHeight + 12
        let rowsHeight = renderedOrder.isEmpty ? 0
            : rows.systemLayoutSizeFitting(CGSize(width: width - 24, height: 0), withHorizontalFittingPriority: .required,
                                           verticalFittingPriority: .fittingSizeLevel).height
        rows.frame = CGRect(x: 12, y: rowsTop, width: width - 24, height: rowsHeight)
        rows.layoutIfNeeded()
        let noticeHeight = notice.isHidden ? 0 : notice.sizeThatFits(CGSize(width: width - 64, height: .greatestFiniteMagnitude)).height
        place(notice, CGRect(x: 32, y: rowsTop + 6, width: width - 64, height: noticeHeight))
        let bottom = bounds.height - layout.pageBottomBarTop + 12
        contentInset.bottom = bottom
        let natural = rowsTop + rowsHeight + noticeHeight
        // Any app with threads can be pulled up until its device is compact.
        let room = layout.pageHeroHeight - layout.pageCompactHeight
        contentSize = CGSize(width: width, height: renderedOrder.isEmpty ? natural : max(natural, bounds.height - bottom + room))
        placeHero()
    }

    private func place(_ view: UIView, _ frame: CGRect) {
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    override var frame: CGRect {
        didSet { if frame.size != oldValue.size { arrange() } }
    }

    private func placeHero() {
        guard let layout else { return }
        let pose = layout.pagePose(scroll: offset)
        let width = pose.height * PhonePose.aspect
        hero.frame = CGRect(x: pose.center.x - width / 2, y: pose.center.y - pose.height / 2 + offset, width: width, height: pose.height)
        portrait.bounds = CGRect(origin: .zero, size: DeviceStage.portraitSize(height: pose.height))
        portrait.center = CGPoint(x: pose.center.x, y: pose.center.y + offset)
    }

    /// 0 = still in the grid, 1 = arrived. The name and rows rise in after
    /// the device, each a little later than the one above it.
    func setArrival(_ a: CGFloat, reduced: Bool) {
        let views: [UIView] = [nameLabel, notice] + rows.arrangedSubviews
        for (index, view) in views.enumerated() {
            let order = CGFloat(view === notice ? 1 : (index == 0 ? 0 : index - 1))
            let local = ((a - 0.25 - min(order, 8) * 0.045) / 0.55).clamped()
            let eased = 1 - pow(1 - local, 3)
            view.alpha = eased
            view.transform = reduced ? .identity : CGAffineTransform(translationX: 0, y: (1 - eased) * (70 + min(order, 8) * 14))
        }
    }

    /// Tapping the device moves between its large and compact sizes.
    private func toggle() {
        guard let layout, !renderedOrder.isEmpty else { return }
        Theme.selectionHaptic()
        let room = layout.pageHeroHeight - layout.pageCompactHeight
        setContentOffset(CGPoint(x: 0, y: offset > room * 0.5 ? 0 : room), animated: !Motion.reduced)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        placeHero()
        onScroll?()
    }
}
