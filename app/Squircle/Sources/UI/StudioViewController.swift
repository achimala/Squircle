import Combine
import CoreMotion
import UIKit

/// The root: one lit stage holding every app's real device. Home is a carousel
/// of those devices; each app's threads scroll up from beneath its name and
/// the device makes room. Opening a thread slides the conversation in while
/// the same device travels to it. Scroll views and one spring drive the scene,
/// so every move follows the finger and can be reversed at any frame.
@MainActor
final class StudioViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let model: SquircleModel
    private let stage = DeviceStage()
    /// Everything that slides away when a thread opens.
    private let home = UIView()
    private let picker = UIScrollView()
    /// Fades lists out above the bottom controls.
    private let pagesClip = UIView()
    private let pagesFade = CAGradientLayer()
    private let connection = Theme.glassButton(symbol: "macbook", identifier: "connection.status", accessibilityLabel: "Mac connection")
    private let add = Theme.glassButton(symbol: "plus", identifier: "project.add", accessibilityLabel: "Add app")
    private let compose = Theme.glassButton(symbol: "square.and.pencil", title: "New Thread", prominent: true, identifier: "thread.new")
    private let builds = Theme.glassButton(symbol: "shippingbox", identifier: "project.builds", accessibilityLabel: "Builds")
    private let spring = SpringDriver()
    private let motion = CMMotionManager()
    private var pages: [String: AppPage] = [:]
    private var bindings: [String: ScreenshotBinding] = [:]
    private var projects: [AppProject] = []
    private var selectedID: String?
    private var deferredRender = false
    private var subscriptions = Set<AnyCancellable>()
    private var laidOut: StageLayout?
    private(set) var thread: ThreadViewController?
    /// Set before the view loads when hosted by the debug overlay: the
    /// top-right control closes the overlay instead of adding an app.
    var onClose: (() -> Void)?
    /// Hosted by the overlay: the left-edge swipe out of a thread moves the
    /// overlay instead of returning to Home.
    var onBackDrag: ((UIPanGestureRecognizer) -> Void)?
    private var dragStart: CGFloat = 0
    private var tilt = CGPoint.zero
    private var tiltRest: CGPoint?

    private enum Phase { case home, opening, thread, closing, dragging }
    private var phase = Phase.home

    init(model: SquircleModel) {
        self.model = model
        selectedID = model.selectedProjectID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backdropBottom
        view.addSubview(stage)
        view.addSubview(home)
        view.addSubview(stage.overlay)

        picker.delegate = self
        picker.isPagingEnabled = true
        picker.showsHorizontalScrollIndicator = false
        picker.showsVerticalScrollIndicator = false
        picker.contentInsetAdjustmentBehavior = .never
        picker.alwaysBounceHorizontal = true
        picker.isDirectionalLockEnabled = true
        picker.accessibilityIdentifier = "app.picker"
        pagesFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        pagesClip.layer.mask = pagesFade
        pagesClip.addSubview(picker)
        home.addSubview(pagesClip)
        [connection, add, compose, builds].forEach(home.addSubview)
        connection.showsMenuAsPrimaryAction = true
        if onClose != nil {
            add.configuration?.image = UIImage(systemName: "xmark")
            add.accessibilityLabel = "Close"
            add.accessibilityIdentifier = "overlay.close"
            add.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        } else {
            add.addAction(UIAction { [weak self] _ in self?.presentImport() }, for: .touchUpInside)
        }
        compose.addAction(UIAction { [weak self] _ in self?.openThread(nil) }, for: .touchUpInside)
        builds.addAction(UIAction { [weak self] _ in self?.presentBuilds() }, for: .touchUpInside)

        spring.onChange = { [weak self] _ in self?.applyScene() }
        spring.onRest = { [weak self] value in self?.springRested(at: value) }

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
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTilt()
        #if DEBUG
        #if !SQUIRCLE_OVERLAY
        MotionAudit.shared.note("gallery.visible", values: ["since_launch_ms": (CACurrentMediaTime() - SquircleApp.launchedAt) * 1000])
        #endif
        startVerificationHooks()
        #endif
    }

    #if DEBUG
    /// Verification only (never in Release). Holds real, finger-driven states
    /// still for a screen capture: `SQUIRCLE_EXPAND` (0…1 of a list's travel),
    /// `SQUIRCLE_SCRUB` (0…1 of the thread transition) and `SQUIRCLE_DETENT`
    /// (0…2 of the thread's divider). `SQUIRCLE_DEMO=1` loops open/close.
    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> CGFloat? { environment[key].flatMap(Double.init).map { CGFloat($0) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            if let name = environment["SQUIRCLE_APP"], let index = projects.firstIndex(where: { $0.name == name }) {
                picker.contentOffset.x = CGFloat(index) * view.bounds.width
                settle()
            }
            guard let id = selectedID, let page = pages[id] else { return }
            if let expand = value("SQUIRCLE_EXPAND") { page.contentOffset.y = layout.expandedOffset * expand }
            guard let scrub = value("SQUIRCLE_SCRUB") else { return }
            let sessions = model.sessions(for: page.project)
            let named = environment["SQUIRCLE_THREAD"].flatMap { title in sessions.first { $0.title == title } }
            openThread(environment["SQUIRCLE_DRAFT"] == "1" ? nil : (named ?? sessions.first)?.id)
            spring.stop()
            phase = .dragging
            if let detent = value("SQUIRCLE_DETENT") { thread?.debugSetDetent(detent) }
            if environment["SQUIRCLE_DEMO_QUESTION"] == "1" { thread?.debugShowQuestion() }
            if environment["SQUIRCLE_DEMO_TAP"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    SpringDriver.debugSlowMotion = value("SQUIRCLE_SLOW").map(Double.init) ?? 1
                    self?.thread?.debugTapDevice()
                }
            }
            if environment["SQUIRCLE_DEMO_LENS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    if let slow = value("SQUIRCLE_SLOW") { self?.view.window?.layer.speed = Float(1 / slow) }
                    self?.thread?.debugLens()
                }
            }
            if environment["SQUIRCLE_DEMO_PULSE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    if let slow = value("SQUIRCLE_SLOW") { self?.view.window?.layer.speed = Float(1 / slow) }
                    self?.thread?.debugPulse()
                }
            }
            if let text = environment["SQUIRCLE_DEMO_SEND"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    // Slow motion for frame-by-frame review of the flight.
                    if let slow = value("SQUIRCLE_SLOW") { self?.view.window?.layer.speed = Float(1 / slow) }
                    self?.thread?.debugFlySend(text)
                }
            }
            spring.set(scrub)
            if scrub >= 1 { phase = .opening; spring.animate(to: 1) }
        }
        if environment["SQUIRCLE_DEMO"] == "1" {
            func cycle() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    if phase == .home, let id = selectedID, let page = pages[id] {
                        openThread(model.sessions(for: page.project).first?.id)
                    } else if phase == .thread { closeThread() }
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
        pagesClip.frame = bounds
        picker.frame = bounds
        thread?.view.place(in: bounds)
        let current = makeLayout()
        if current != laidOut {
            laidOut = current
            layoutPages()
            picker.contentOffset.x = CGFloat(selectedIndex) * bounds.width
        }
        let safe = view.safeAreaInsets
        connection.frame = CGRect(x: 16, y: safe.top + 4, width: 44, height: 44)
        add.frame = CGRect(x: bounds.width - 60, y: safe.top + 4, width: 44, height: 44)
        let barTop = current.bottomBarTop, barHeight = StageLayout.bottomBarHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pagesFade.frame = bounds
        pagesFade.locations = [0, NSNumber(value: (barTop - 34) / bounds.height), NSNumber(value: (barTop - 2) / bounds.height)]
        CATransaction.commit()
        builds.frame = CGRect(x: bounds.width - 16 - barHeight, y: barTop, width: barHeight, height: barHeight)
        compose.frame = CGRect(x: 16, y: barTop, width: builds.frame.minX - 26, height: barHeight)
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
    private var selectedIndex: Int { projects.firstIndex { $0.id == selectedID } ?? 0 }
    private var selectedProject: AppProject? { projects.first { $0.id == selectedID } }

    // MARK: Model

    private func render() {
        let next = model.projects
        let changed = next.map(\.id) != projects.map(\.id)
        if changed && (picker.isTracking || picker.isDecelerating) {
            deferredRender = true
            return
        }
        projects = next
        if let open = thread?.project.id { selectedID = open }
        if !projects.isEmpty, !projects.contains(where: { $0.id == selectedID }) { selectedID = projects.first?.id }
        let ids = Set(projects.map(\.id))
        for id in Array(pages.keys) where !ids.contains(id) {
            pages.removeValue(forKey: id)?.removeFromSuperview()
            bindings[id] = nil
        }
        stage.sync(ids: projects.map(\.id))
        for project in projects {
            let page = pages[project.id] ?? {
                let page = AppPage(project: project)
                page.onScroll = { [weak self] in self?.applyScene() }
                page.onMoving = { [weak self] moving in self?.stage.setLive(moving, reason: "list") }
                page.onOpenThread = { [weak self] id in self?.openThread(id) }
                page.onPage = { [weak self] direction in self?.scrollToPage((self?.selectedIndex ?? 0) + direction) }
                pages[project.id] = page
                picker.addSubview(page)
                return page
            }()
            page.update(project: project, sessions: model.sessions(for: project), agentName: model.agentName(for:),
                        loading: model.isLoading, error: model.error)
            let binding = bindings[project.id] ?? {
                let binding = ScreenshotBinding(id: project.id, stage: stage)
                binding.onChange = { [weak self] in self?.applyScene() }
                return binding
            }()
            bindings[project.id] = binding
            binding.update(model: model, project: project)
        }
        renderControls()
        if changed && laidOut != nil {
            layoutPages()
            picker.contentOffset.x = CGFloat(selectedIndex) * view.bounds.width
        }
        applyScene()
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

    private func layoutPages() {
        let layout = self.layout
        let size = view.bounds.size
        picker.contentSize = CGSize(width: size.width * CGFloat(max(1, projects.count)), height: size.height)
        for (index, project) in projects.enumerated() {
            guard let page = pages[project.id] else { continue }
            page.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
            page.layout = layout
        }
    }

    // MARK: Scene

    /// Pushes carousel position, every list's scroll, the thread transition
    /// and its divider into every layer. Called only while something moves.
    private func applyScene() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let layout = self.layout
        let progress = spring.value
        let position = picker.contentOffset.x / width
        let lower = max(0, min(projects.count - 1, Int(floor(position))))
        let upper = min(projects.count - 1, lower + 1)
        let fraction = (position - CGFloat(lower)).clamped()
        func expansion(_ index: Int) -> CGFloat {
            projects.indices.contains(index) ? layout.expansion(scroll: pages[projects[index].id]?.offset ?? 0) : 0
        }
        // Neighbors stand a full page apart once a list is being read.
        let spread = CGFloat.lerp(expansion(lower), expansion(upper), fraction)
        let nearest = max(0, min(projects.count - 1, Int(position.rounded())))
        var poses: [String: PhonePose] = [:]
        var focus: PhonePose?
        for (index, project) in projects.enumerated() {
            guard let page = pages[project.id] else { continue }
            let offset = CGFloat(index) - position
            page.isHidden = abs(offset) >= 1.5
            let scroll = page.offset
            var pose = layout.homePose(offset: offset, scroll: scroll, spread: spread)
            let calm = (1 - layout.expansion(scroll: scroll)) * (1 - progress.clamped())
            if !layout.reducedMotion {
                pose.yaw += tilt.x * calm
                pose.pitch += tilt.y * calm
            }
            // The name stays beneath its device, which stands closer than a page.
            page.nameShift = pose.center.x - (width / 2 + offset * width)
            page.setHero(CGRect(x: pose.center.x - offset * width - pose.height * PhonePose.aspect / 2,
                                y: pose.center.y - pose.height / 2, width: pose.height * PhonePose.aspect, height: pose.height),
                         centered: index == nearest, expanded: scroll > layout.expandedOffset * 0.5)
            if progress > 0.0001 {
                if project.id == thread?.project.id, let thread {
                    pose = layout.transitionPose(from: pose, to: thread.pose, progress: progress)

                } else {
                    let direction: CGFloat = offset < 0 ? -1 : 1
                    pose = layout.homePose(offset: offset + direction * progress.clamped() * 1.5, scroll: scroll, spread: spread)
                }
            }
            let hidden = project.id == thread?.project.id && thread?.hidesDevice == true
            if index == nearest, !hidden { focus = pose }
            if pose.visible, !hidden { poses[project.id] = pose }
        }
        stage.apply(poses)
        if let focus {
            stage.glowCenter = focus.center
            stage.glowRadius = max(120, focus.height * 0.95)
        } else if thread?.hidesDevice == true {
            stage.glowRadius = 0
        }
        if !projects.isEmpty {
            stage.setAmbient(from: stage.ambientColor(for: projects[lower].id), to: stage.ambientColor(for: projects[upper].id), mix: fraction)
        }
        if projects.indices.contains(nearest), projects[nearest].id != selectedID, thread == nil {
            selectedID = projects[nearest].id
            Theme.selectionHaptic()
            renderControls()
        }

        // A push: Home leaves to the left as the conversation arrives from the
        // right. The device belongs to both, so it travels on its own.
        home.transform = CGAffineTransform(translationX: -width * progress, y: 0)
        thread?.setTransitionProgress(progress)
        thread?.view.transform = CGAffineTransform(translationX: width * (1 - progress), y: 0)
    }

    // MARK: Carousel

    func scrollViewDidScroll(_ scrollView: UIScrollView) { applyScene() }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stage.setLive(true, reason: "picker")
        #if DEBUG
        MotionAudit.shared.begin("gallery.scroll", duration: 1.4)
        #endif
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    private func settle() {
        stage.setLive(false, reason: "picker")
        applyScene()
        if let selectedProject { model.selectProject(selectedProject) }
        // A list left behind returns to its hero for the next visit.
        for (id, page) in pages where id != selectedID && page.offset != 0 { page.contentOffset.y = 0 }
        if deferredRender {
            deferredRender = false
            render()
        }
    }

    private func scrollToPage(_ page: Int) {
        guard !projects.isEmpty, phase == .home else { return }
        let target = CGFloat(max(0, min(projects.count - 1, page))) * view.bounds.width
        guard abs(picker.contentOffset.x - target) > 1 else { return }
        stage.setLive(true, reason: "picker")
        picker.setContentOffset(CGPoint(x: target, y: 0), animated: !Motion.reduced)
        if Motion.reduced { settle() }
    }

    // MARK: Device tilt

    /// The hero turns a little against the hand holding the phone, so it reads
    /// as an object in space. Renders only when the hand actually moves.
    private func startTilt() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            MainActor.assumeIsolated {
                guard let self, let attitude = data?.attitude, self.phase == .home, !Motion.reduced else { return }
                let now = CGPoint(x: attitude.roll, y: attitude.pitch)
                var rest = self.tiltRest ?? now
                func delta(_ a: CGFloat, _ b: CGFloat) -> CGFloat { atan2(sin(a - b), cos(a - b)) }
                // The resting attitude follows slowly, so any grip is neutral.
                rest.x += delta(now.x, rest.x) * 0.03
                rest.y += delta(now.y, rest.y) * 0.03
                self.tiltRest = rest
                let next = CGPoint(x: (-delta(now.x, rest.x) * 0.55).clamped(-0.22, 0.22),
                                   y: (-delta(now.y, rest.y) * 0.35).clamped(-0.10, 0.10))
                guard abs(next.x - self.tilt.x) > 0.002 || abs(next.y - self.tilt.y) > 0.002 else { return }
                self.tilt = next
                self.applyScene()
            }
        }
    }

    // MARK: Threads

    private func openThread(_ sessionID: String?) {
        guard phase == .home, presentedViewController == nil, let project = selectedProject else { return }
        Theme.openHaptic()
        model.selectProject(project)
        let controller = ThreadViewController(model: model, project: project, sessionID: sessionID, stage: stage)
        controller.layoutProvider = { [weak self] in self?.layout }
        controller.hidesIdleDevice = onClose != nil
        controller.onBack = { [weak self] in
            if let close = self?.onClose { close() } else { self?.closeThread() }
        }
        controller.onGeometry = { [weak self] in self?.applyScene() }
        thread = controller
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.transform = CGAffineTransform(translationX: view.bounds.width, y: 0)
        // Conversations pass beneath the devices.
        view.insertSubview(controller.view, belowSubview: stage.overlay)
        controller.didMove(toParent: self)
        controller.view.layoutIfNeeded()
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(backPanned(_:)))
        pan.edges = .left
        pan.delegate = self
        controller.view.addGestureRecognizer(pan)
        phase = .opening
        beginMotion("thread.open")
        updateInteractivity()
        spring.animate(to: 1)
    }

    func closeThread() {
        guard thread != nil, presentedViewController == nil, phase != .home else { return }
        view.endEditing(true)
        phase = .closing
        beginMotion("thread.close")
        updateInteractivity()
        spring.animate(to: 0)
    }

    /// Opens straight into a conversation, with no trip from Home (overlay).
    func presentThread(_ sessionID: String?) {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        openThread(sessionID)
        guard thread != nil else { return }
        spring.set(1)
        stage.setLive(false, reason: "transition")
        phase = .thread
        updateInteractivity()
    }

    /// Releases the open conversation and its simulator picture (overlay).
    func tearDown() {
        guard let thread else { return }
        thread.pausePreview()
        stage.endLive(for: thread.project.id)
    }

    /// Swipe in from the left edge to go back, following the finger.
    @objc private func backPanned(_ gesture: UIPanGestureRecognizer) {
        if let onBackDrag {
            onBackDrag(gesture)
            return
        }
        let width = max(1, view.bounds.width)
        switch gesture.state {
        case .began:
            guard thread != nil, phase != .home else { return }
            dragStart = spring.value
            spring.stop()
            phase = .dragging
            beginMotion("thread.drag")
            updateInteractivity()
        case .changed:
            guard phase == .dragging else { return }
            spring.set((dragStart - gesture.translation(in: view).x / width).clamped())
        case .ended, .cancelled, .failed:
            guard phase == .dragging else { return }
            let velocity = -gesture.velocity(in: view).x / width
            let closing = gesture.state == .ended && spring.value + velocity * 0.18 < 0.5
            #if DEBUG
            MotionAudit.shared.note("back", values: ["progress": spring.value, "velocity": velocity, "closing": closing])
            #endif
            if closing { view.endEditing(true) }
            phase = closing ? .closing : .opening
            updateInteractivity()
            spring.animate(to: closing ? 0 : 1, initialVelocity: velocity)
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let thread, presentedViewController == nil else { return false }
        return pan.velocity(in: view).x >= 0 && thread.allowsBackSwipe(at: pan.location(in: thread.view))
    }

    /// The conversation's own scrolling waits until a touch is known not to be
    /// a back swipe, so the two never move together.
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

    private func springRested(at value: CGFloat) {
        stage.setLive(false, reason: "transition")
        if value >= 1, phase == .opening {
            phase = .thread
            updateInteractivity()
            UIAccessibility.post(notification: .screenChanged, argument: thread?.view)
        } else if value <= 0, phase == .closing {
            if let thread {
                thread.pausePreview()
                stage.endLive(for: thread.project.id)
                thread.willMove(toParent: nil)
                thread.view.removeFromSuperview()
                thread.removeFromParent()
            }
            thread = nil
            phase = .home
            applyScene()
            updateInteractivity()
            UIAccessibility.post(notification: .screenChanged, argument: selectedID.flatMap { pages[$0]?.hero })
        }
    }

    /// Only the resting screen is interactive and visible to VoiceOver/UI tests.
    private func updateInteractivity() {
        home.isUserInteractionEnabled = phase == .home
        home.accessibilityElementsHidden = phase != .home
        // Hidden at rest so Home costs nothing behind a conversation.
        home.isHidden = phase == .thread
        thread?.view.accessibilityElementsHidden = phase != .thread
    }

    // MARK: Sheets

    private func presentBuilds() {
        guard let project = selectedProject, presentedViewController == nil, phase == .home else { return }
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
        guard phase == .home, presentedViewController == nil else { return }
        let importer = AppImportNavigationController(model: model)
        importer.onImport = { [weak self, weak importer] project in
            importer?.dismiss(animated: true) {
                guard let self else { return }
                self.render()
                guard let index = self.projects.firstIndex(where: { $0.id == project.id }) else { return }
                self.scrollToPage(index)
            }
        }
        present(importer, animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard phase == .thread else { return false }
        closeThread()
        return true
    }
}

/// One app on Home: its name beneath the device and its threads beneath that.
/// The device is rendered by the shared stage behind this transparent list and
/// shrinks to make room as the list scrolls up.
@MainActor
final class AppPage: UIScrollView, UIScrollViewDelegate {
    private(set) var project: AppProject
    var onScroll: (() -> Void)?
    var onMoving: ((Bool) -> Void)?
    var onOpenThread: ((String) -> Void)?
    var onPage: ((Int) -> Void)?
    var layout: StageLayout? { didSet { if layout != oldValue { arrange() } } }
    /// Tappable, accessible stand-in for the device.
    let hero = UIControl()
    private let nameLabel = Theme.label("", Theme.appNameFont())
    private let rows = UIStackView()
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private var rowViews: [String: ThreadRow] = [:]
    private var renderedOrder: [String] = []

    /// Distance scrolled from the resting hero position.
    var offset: CGFloat { contentOffset.y }
    var nameShift: CGFloat = 0 {
        didSet { if nameShift != oldValue { nameLabel.transform = CGAffineTransform(translationX: nameShift, y: 0) } }
    }

    init(project: AppProject) {
        self.project = project
        super.init(frame: .zero)
        delegate = self
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .normal
        accessibilityIdentifier = "workspace.threads"
        nameLabel.textAlignment = .center
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.6
        nameLabel.accessibilityTraits = .header
        rows.axis = .vertical
        notice.textAlignment = .center
        hero.isAccessibilityElement = true
        hero.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Previous app") { [weak self] _ in self?.onPage?(-1); return true },
            UIAccessibilityCustomAction(name: "Next app") { [weak self] _ in self?.onPage?(1); return true }
        ]
        hero.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        [hero, nameLabel, rows, notice].forEach(addSubview)
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
            bottomEdgeEffect.style = .soft
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(project: AppProject, sessions: [ChatSession], agentName: (JSONValue) -> String, loading: Bool, error: String?) {
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
        nameLabel.transform = .identity
        nameLabel.frame = CGRect(x: 28, y: layout.nameTop, width: width - 56, height: layout.titleHeight)
        nameLabel.transform = CGAffineTransform(translationX: nameShift, y: 0)
        let rowsTop = nameLabel.frame.maxY + 14
        let rowsHeight = renderedOrder.isEmpty ? 0
            : rows.systemLayoutSizeFitting(CGSize(width: width - 24, height: 0), withHorizontalFittingPriority: .required,
                                           verticalFittingPriority: .fittingSizeLevel).height
        rows.frame = CGRect(x: 12, y: rowsTop, width: width - 24, height: rowsHeight)
        let noticeHeight = notice.isHidden ? 0 : notice.sizeThatFits(CGSize(width: width - 64, height: .greatestFiniteMagnitude)).height
        notice.frame = CGRect(x: 32, y: rowsTop + 6, width: width - 64, height: noticeHeight)
        let bottom = bounds.height - layout.bottomBarTop + 12
        contentInset.bottom = bottom
        let natural = rowsTop + rowsHeight + noticeHeight
        // Any app with threads can be pulled up to its reading position.
        contentSize = CGSize(width: width, height: renderedOrder.isEmpty ? natural
                             : max(natural, bounds.height - bottom + layout.expandedOffset))
    }

    override var frame: CGRect {
        didSet { if frame.size != oldValue.size { arrange() } }
    }

    /// `rect` is the device's outline in this page's visible coordinates.
    func setHero(_ rect: CGRect, centered: Bool, expanded: Bool) {
        hero.frame = rect.offsetBy(dx: 0, dy: contentOffset.y)
        let identifier = centered ? "project.hero" : "project.picker.\(project.id)"
        if hero.accessibilityIdentifier != identifier {
            hero.accessibilityIdentifier = identifier
            hero.accessibilityTraits = centered ? [.button, .selected] : .button
        }
        hero.accessibilityHint = expanded ? "Shows the device" : "Shows threads"
    }

    /// Tapping the device moves between hero and reading positions.
    private func toggle() {
        guard let layout, !renderedOrder.isEmpty else { return }
        Theme.selectionHaptic()
        onMoving?(true)
        let target = offset > layout.expandedOffset * 0.5 ? 0 : layout.expandedOffset
        setContentOffset(CGPoint(x: 0, y: target), animated: !Motion.reduced)
        if Motion.reduced { onMoving?(false) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onScroll?() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onMoving?(true) }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard let layout, !renderedOrder.isEmpty else { return }
        targetContentOffset.pointee.y = layout.restingOffset(current: offset, projected: targetContentOffset.pointee.y, velocity: velocity.y)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { onMoving?(false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { onMoving?(false) }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { onMoving?(false) }
}
