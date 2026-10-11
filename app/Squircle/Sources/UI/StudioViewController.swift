import Combine
import UIKit

/// The root: every app's real device. Home is a grid of still portraits of
/// those devices that scroll natively. Opening an app hands its device to the
/// live 3D stage, which lifts it to the top while the others fall back and
/// its threads rise beneath it; at rest it becomes a portrait in the app's
/// list again. Opening a thread swings the list away as the same device
/// travels into the conversation. Scroll views and one spring per level drive
/// every move, so it follows the finger and can be reversed at any frame.
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
    /// The list swings in 3D inside its own layer, and the conversation turns
    /// inside `threadHost`: separate containers flatten each into its own
    /// plane, so they layer in order instead of slicing through each other.
    private let pageSwing = UIView()
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
    private var selectedID: String?
    private var subscriptions = Set<AnyCancellable>()
    private var laidOut: StageLayout?
    private(set) var thread: ThreadViewController?
    private var dragStart: CGFloat = 0
    /// True while the stage draws the selected device. Otherwise a portrait
    /// in the grid or the app's list shows it and the stage draws nothing.
    private var staged = false
    /// Bumped whenever an app's screen changes; part of each portrait's key.
    private var screenVersions: [String: Int] = [:]
    private var portraitsScheduled = false

    private enum Phase { case grid, toApp, app, toGrid, dragApp, toThread, thread, toPage, dragThread }
    private var phase = Phase.grid
    private var onGrid: Bool { phase == .grid }
    private var onPage: Bool { phase == .app }

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

        page.onScroll = { [weak self] in if self?.staged == true { self?.applyScene() } }
        page.onOpenThread = { [weak self] id in self?.openThread(id) }
        pageSwing.addSubview(page)
        pageHost.addSubview(pageSwing)
        [back, compose, builds].forEach(pageHost.addSubview)
        back.addAction(UIAction { [weak self] _ in self?.closeApp() }, for: .touchUpInside)
        compose.addAction(UIAction { [weak self] _ in self?.openThread(nil) }, for: .touchUpInside)
        builds.addAction(UIAction { [weak self] _ in self?.presentBuilds() }, for: .touchUpInside)

        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(backPanned(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)

        appSpring.onChange = { [weak self] _ in self?.applyScene() }
        appSpring.onRest = { [weak self] value in self?.appRested(at: value) }
        spring.onChange = { [weak self] _ in self?.applyScene() }
        spring.onRest = { [weak self] value in self?.threadRested(at: value) }

        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &subscriptions)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: StudioViewController, _: UITraitCollection) in
            controller.relayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: StudioViewController, _: UITraitCollection) in
            controller.schedulePortraits()
        }
        updateInteractivity()
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
    /// Verification only (never in Release). Holds real, finger-driven states
    /// still for a screen capture: `SQUIRCLE_GRID` (grid scroll in points),
    /// `SQUIRCLE_APP` (open the app with this name), `SQUIRCLE_APP_SCRUB` (0…1
    /// of opening it), `SQUIRCLE_EXPAND` (its list's scroll in points),
    /// `SQUIRCLE_SCRUB` (0…1 of the thread transition) and `SQUIRCLE_DETENT`
    /// (0…2 of the thread's divider). `SQUIRCLE_DEMO=1` loops through them.
    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> CGFloat? { environment[key].flatMap(Double.init).map { CGFloat($0) } }
        if let slow = value("SQUIRCLE_SLOW") { SpringDriver.debugSlowMotion = Double(slow) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            if let y = value("SQUIRCLE_GRID") { grid.contentOffset.y = y; applyScene() }
            guard let name = environment["SQUIRCLE_APP"], let project = projects.first(where: { $0.name == name }) else { return }
            openApp(project.id, begin: false)
            if let scrub = value("SQUIRCLE_APP_SCRUB") {
                phase = .dragApp
                appSpring.set(scrub)
                return
            }
            appSpring.set(1)
            appRested(at: 1)
            if let expand = value("SQUIRCLE_EXPAND") { page.contentOffset.y = expand }
            guard let scrub = value("SQUIRCLE_SCRUB") else { return }
            let sessions = model.sessions(for: project)
            let named = environment["SQUIRCLE_THREAD"].flatMap { title in sessions.first { $0.title == title } }
            openThread(environment["SQUIRCLE_DRAFT"] == "1" ? nil : (named ?? sessions.first)?.id, begin: false)
            phase = .dragThread
            if let detent = value("SQUIRCLE_DETENT") { thread?.debugSetDetent(detent) }
            if environment["SQUIRCLE_DEMO_QUESTION"] == "1" { thread?.debugShowQuestion() }
            let later: (@escaping () -> Void) -> Void = { work in DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work) }
            if environment["SQUIRCLE_DEMO_TAP"] == "1" { later { [weak self] in self?.thread?.debugTapDevice() } }
            if environment["SQUIRCLE_DEMO_LENS"] == "1" { later { [weak self] in self?.thread?.debugLens() } }
            if environment["SQUIRCLE_DEMO_PULSE"] == "1" { later { [weak self] in self?.thread?.debugPulse() } }
            if let text = environment["SQUIRCLE_DEMO_SEND"] { later { [weak self] in self?.thread?.debugFlySend(text) } }
            spring.set(scrub)
            if scrub >= 1 { phase = .toThread; spring.animate(to: 1) }
        }
        if environment["SQUIRCLE_DEMO"] == "1" {
            func cycle() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    switch phase {
                    case .grid: if let first = projects.first { openApp(first.id) }
                    case .app:
                        if let project = selectedProject, let first = model.sessions(for: project).first,
                           thread == nil, Int.random(in: 0...1) == 0 { openThread(first.id) } else { closeApp() }
                    case .thread: closeThread()
                    default: break
                    }
                    cycle()
                }
            }
            cycle()
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
        pageSwing.frame = bounds
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

    // MARK: Model

    private func render() {
        let next = model.projects
        let ids = Set(next.map(\.id))
        if onGrid {
            // Keep what is on screen where it is; new apps join at the end.
            let known = Set(projects.map(\.id))
            let byID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            projects = projects.compactMap { byID[$0.id] } + next.filter { !known.contains($0.id) }
        } else {
            projects = next
        }
        if let selectedID, !ids.contains(selectedID), thread == nil, !onGrid { closeApp() }
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
        applyScene()
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
        if !onGrid, let id = selectedID, let cell = cells[id] {
            let visible = CGRect(x: 0, y: grid.contentOffset.y + layout.gridTop, width: grid.bounds.width,
                                 height: grid.bounds.height - layout.gridTop)
            if !visible.contains(cell.frame) {
                let maxY = max(0, grid.contentSize.height - grid.bounds.height)
                grid.contentOffset.y = (cell.frame.minY - layout.gridTop).clamped(0, maxY)
            }
        }
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

    /// Redraws stale portraits one per main-queue turn, so a grid of many apps
    /// never stalls a frame.
    private func schedulePortraits() {
        guard !portraitsScheduled, laidOut != nil else { return }
        portraitsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            portraitsScheduled = false
            if drawNextPortrait() { schedulePortraits() }
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

    private func ensureCellPortrait(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }), let cell = cells[id] else { return }
        let pose = gridPose(index), key = portraitKey(id, pose)
        guard cell.portraitKey != key else { return }
        cell.portraitKey = key
        cell.portrait.image = stage.portrait(for: id, pose: pose, scale: displayScale)
    }

    /// The stage takes the selected device from a portrait at the same pose.
    /// The portrait hides only once the stage has drawn it, so neither shows
    /// nothing for a frame; `then` runs at that moment.
    private func stageSelected(hiding portrait: UIView, then: (() -> Void)? = nil) {
        guard !staged else { then?(); return }
        staged = true
        applyScene()
        stage.afterNextRender { [weak self, weak portrait] in
            guard let self, staged else { return }
            portrait?.isHidden = true
            then?()
        }
    }

    /// A portrait takes the selected device back at rest. The stage clears a
    /// turn later, once the portrait is on screen beneath it.
    private func unstageSelected(showing portrait: UIView) {
        portrait.isHidden = false
        DispatchQueue.main.async { [weak self] in
            guard let self, phase == .grid || phase == .app else { return }
            staged = false
            stage.setLive(false, reason: "transition")
            applyScene()
        }
    }

    // MARK: Scene

    /// Pushes both transitions and the thread's divider into every layer.
    /// Called only while something moves.
    private func applyScene() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let layout = self.layout
        let a = appSpring.value, t = spring.value
        let scroll = grid.contentOffset.y
        var origin = CGPoint(x: width / 2, y: layout.pageHeroTop)
        var poses: [String: PhonePose] = [:]
        if let id = selectedID, let index = projects.firstIndex(where: { $0.id == id }) {
            let start = layout.gridPose(cell: layout.cellFrame(index).offsetBy(dx: 0, dy: -scroll), column: index % layout.columns)
            origin = start.center
            if staged {
                var pose = layout.transitionPose(from: start, to: layout.pagePose(scroll: page.offset), progress: a)
                if t > 0.0001, let thread, thread.project.id == id {
                    pose = layout.transitionPose(from: pose, to: thread.pose, progress: t)
                }
                poses[id] = pose
            }
        }
        stage.apply(poses)

        // The other apps drift back and fade; the opened one's name goes first.
        home.alpha = (1 - a * 1.6).clamped()
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
        pageHost.isHidden = a < 0.001
        self.page.setArrival(a, reduced: layout.reducedMotion)
        let chrome = ((a - 0.5) / 0.5).clamped()
        for button in [back, compose, builds] { button.alpha = chrome * (1 - t * 2).clamped() }
        compose.transform = CGAffineTransform(translationX: 0, y: (1 - chrome) * 40)
        builds.transform = compose.transform

        // A thread: the list swings away on a hinge at its left edge while the
        // conversation turns in from the right. The device travels on its own.
        if layout.reducedMotion {
            self.page.layer.transform = CATransform3DIdentity
            self.page.alpha = 1 - t
        } else {
            var swing = CATransform3DIdentity
            swing.m34 = -1 / 900
            swing = CATransform3DTranslate(swing, -width * 0.18 * t, 0, -120 * t)
            swing = CATransform3DRotate(swing, 0.32 * t, 0, 1, 0)
            self.page.layer.transform = swing
            self.page.alpha = 1 - 0.85 * t
        }
        thread?.setTransitionProgress(t)
        if let threadView = thread?.view {
            if layout.reducedMotion {
                threadView.layer.transform = CATransform3DMakeTranslation(width * (1 - t), 0, 0)
            } else {
                var arrive = CATransform3DIdentity
                arrive.m34 = -1 / 1100
                arrive = CATransform3DTranslate(arrive, width * (1 - t), 0, 0)
                arrive = CATransform3DRotate(arrive, -0.38 * (1 - t), 0, 1, 0)
                threadView.layer.transform = arrive
            }
        }
    }

    // MARK: App page

    /// `begin: false` stages the device without starting the spring
    /// (verification holds a scrubbed frame).
    private func openApp(_ id: String, begin: Bool = true) {
        let returning = phase == .toGrid && id == selectedID
        guard onGrid || returning, presentedViewController == nil,
              let project = projects.first(where: { $0.id == id }), let cell = cells[id] else { return }
        Theme.openHaptic()
        if !returning {
            selectedID = id
            page.reset()
            page.update(project: project, sessions: model.sessions(for: project), agentName: model.agentName(for:),
                        loading: model.isLoading, error: model.error)
            ensureHeroPortrait(id)
            page.portrait.isHidden = true
            renderControls()
        }
        grid.setContentOffset(grid.contentOffset, animated: false)
        phase = .toApp
        beginMotion("app.open")
        updateInteractivity()
        stageSelected(hiding: cell.portrait) { [weak self] in
            guard let self, begin, phase == .toApp else { return }
            appSpring.animate(to: 1)
        }
    }

    func closeApp() {
        guard [.app, .toApp, .dragApp].contains(phase), presentedViewController == nil else { return }
        Theme.selectionHaptic()
        phase = .toGrid
        beginMotion("app.close")
        updateInteractivity()
        stageSelected(hiding: page.portrait) { [weak self] in
            guard let self, phase == .toGrid else { return }
            appSpring.animate(to: 0)
        }
    }

    private func appRested(at value: CGFloat) {
        stage.setLive(false, reason: "transition")
        if value >= 1, phase == .toApp {
            phase = .app
            if let project = selectedProject { model.selectProject(project) }
            updateInteractivity()
            if let id = selectedID { ensureHeroPortrait(id) }
            unstageSelected(showing: page.portrait)
            UIAccessibility.post(notification: .screenChanged, argument: page.hero)
        } else if value <= 0, phase == .toGrid {
            phase = .grid
            page.reset()
            updateInteractivity()
            render()
            if let id = selectedID, let cell = cells[id] {
                ensureCellPortrait(id)
                unstageSelected(showing: cell.portrait)
            }
            UIAccessibility.post(notification: .screenChanged, argument: selectedID.flatMap { cells[$0] })
        }
    }

    // MARK: Threads

    private func openThread(_ sessionID: String?, begin: Bool = true) {
        guard onPage, presentedViewController == nil, let project = selectedProject else { return }
        Theme.openHaptic()
        model.selectProject(project)
        let controller = ThreadViewController(model: model, project: project, sessionID: sessionID, stage: stage)
        controller.layoutProvider = { [weak self] in self?.layout }
        controller.onBack = { [weak self] in self?.closeThread() }
        controller.onGeometry = { [weak self] in self?.applyScene() }
        thread = controller
        addChild(controller)
        controller.view.frame = view.bounds
        // An opaque page that covers the list as it turns in, never text over text.
        controller.view.backgroundColor = Theme.paper
        controller.view.layer.shadowColor = UIColor.black.cgColor
        controller.view.layer.shadowOpacity = 0.14
        controller.view.layer.shadowRadius = 18
        controller.view.layer.shadowOffset = CGSize(width: -6, height: 0)
        controller.view.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
        controller.view.layer.transform = CATransform3DMakeTranslation(view.bounds.width, 0, 0)
        // Conversations pass beneath the devices.
        threadHost.addSubview(controller.view)
        controller.didMove(toParent: self)
        controller.view.layoutIfNeeded()
        phase = .toThread
        beginMotion("thread.open")
        updateInteractivity()
        stageSelected(hiding: page.portrait) { [weak self] in
            guard let self, begin, phase == .toThread else { return }
            spring.animate(to: 1)
        }
    }

    func closeThread() {
        guard thread != nil, presentedViewController == nil, [.thread, .toThread, .dragThread].contains(phase) else { return }
        view.endEditing(true)
        phase = .toPage
        beginMotion("thread.close")
        updateInteractivity()
        spring.animate(to: 0)
    }

    private func threadRested(at value: CGFloat) {
        stage.setLive(false, reason: "transition")
        if value >= 1, phase == .toThread {
            phase = .thread
            updateInteractivity()
            UIAccessibility.post(notification: .screenChanged, argument: thread?.view)
        } else if value <= 0, phase == .toPage {
            if let thread {
                thread.pausePreview()
                stage.endLive(for: thread.project.id)
                thread.willMove(toParent: nil)
                thread.view.removeFromSuperview()
                thread.removeFromParent()
            }
            thread = nil
            phase = .app
            applyScene()
            updateInteractivity()
            unstageSelected(showing: page.portrait)
            UIAccessibility.post(notification: .screenChanged, argument: page.hero)
        }
    }

    // MARK: Back

    /// Swipe in from the left edge to go back a level, following the finger.
    @objc private func backPanned(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        let threadLevel = thread != nil
        let driver = threadLevel ? spring : appSpring
        switch gesture.state {
        case .began:
            dragStart = driver.value
            driver.stop()
            if !threadLevel { stageSelected(hiding: page.portrait) }
            phase = threadLevel ? .dragThread : .dragApp
            beginMotion(threadLevel ? "thread.drag" : "app.drag")
            updateInteractivity()
        case .changed:
            guard phase == .dragThread || phase == .dragApp else { return }
            driver.set((dragStart - gesture.translation(in: view).x / width).clamped())
        case .ended, .cancelled, .failed:
            guard phase == .dragThread || phase == .dragApp else { return }
            let velocity = -gesture.velocity(in: view).x / width
            let closing = gesture.state == .ended && driver.value + velocity * 0.18 < 0.5
            #if DEBUG
            MotionAudit.shared.note("back", values: ["progress": driver.value, "velocity": velocity, "closing": closing])
            #endif
            if threadLevel {
                if closing { view.endEditing(true) }
                phase = closing ? .toPage : .toThread
            } else {
                phase = closing ? .toGrid : .toApp
            }
            updateInteractivity()
            driver.animate(to: closing ? 0 : 1, initialVelocity: velocity)
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, presentedViewController == nil,
              pan.velocity(in: view).x >= 0 else { return false }
        if let thread { return [.thread, .toThread].contains(phase) && thread.allowsBackSwipe(at: pan.location(in: thread.view)) }
        return [.app, .toApp].contains(phase)
    }

    /// Scrolling waits until a touch is known not to be a back swipe, so the
    /// two never move together.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }

    private func beginMotion(_ name: String) {
        stage.setLive(true, reason: "transition")
        #if DEBUG
        MotionAudit.shared.begin(name, duration: 1.0)
        #endif
    }

    /// Only the resting screen is interactive and visible to VoiceOver/UI tests.
    private func updateInteractivity() {
        home.isUserInteractionEnabled = onGrid
        home.accessibilityElementsHidden = !onGrid
        pageHost.isUserInteractionEnabled = onPage
        pageHost.accessibilityElementsHidden = !onPage
        // Hidden at rest so nothing costs anything behind a conversation.
        home.isHidden = phase == .thread || phase == .app
        page.isHidden = phase == .thread
        thread?.view.accessibilityElementsHidden = phase != .thread
    }

    // MARK: Sheets

    private func presentBuilds() {
        guard let project = selectedProject, presentedViewController == nil, onPage else { return }
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
        guard onGrid, presentedViewController == nil else { return }
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
        switch phase {
        case .thread: closeThread(); return true
        case .app: closeApp(); return true
        default: return false
        }
    }
}

/// A container that is never itself the target of a touch.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
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
