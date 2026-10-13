#if SQUIRCLE_OVERLAY || DEBUG
import UIKit

/// Entry point called from the framework's load-time constructor. The overlay
/// exists only in builds Squircle signs for your phone; an App Store build
/// carries no provisioning profile.
@_cdecl("squircle_overlay_start")
public func squircleOverlayStart() {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    guard AppConfiguration.Shared.teamID != nil, !bundleID.isEmpty, bundleID != "ai.dreamslate.Squircle" else { return }
    // Squircle's paired connection; without it the overlay stays off.
    guard let configuration = try? AppConfiguration.Shared.load() else { return }
    Task { @MainActor in OverlayHost.shared.start(bundleID: bundleID, configuration: configuration) }
}

/// Attaches one overlay window to the host app's foreground scene.
@MainActor
final class OverlayHost {
    static let shared = OverlayHost()
    private var model: SquircleModel?
    private var window: OverlayWindow?
    private var observers: [NSObjectProtocol] = []

    func start(bundleID: String, configuration: AppConfiguration) {
        guard model == nil else { return }
        model = SquircleModel(configuration: configuration, scopeBundleID: bundleID)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { OverlayHost.shared.activate(note.object as? UIWindowScene) }
        })
        observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OverlayHost.shared.model?.stopMetadataUpdates() }
        })
        activate(nil)
    }

    private func activate(_ scene: UIWindowScene?) {
        guard let model else { return }
        let scene = scene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene, scene.activationState == .foregroundActive else { return }
        if window?.windowScene !== scene {
            let window = OverlayWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.tintColor = Theme.accent
            window.rootViewController = OverlayController(model: model)
            window.isHidden = false
            self.window = window
        }
        model.startMetadataUpdates()
        Task { await model.refresh() }
    }
}

/// Touches that miss the overlay's glass reach the app beneath.
final class OverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === rootViewController?.view ? nil : view
    }
}

/// Where the overlay is. Everything on screen is derived from it and from
/// two springs that move toward what it implies.
struct OverlayRoute: Equatable {
    var open = false
    var full = false
    /// A thread over the agent: a T3 thread ID, or `draft:<uuid>` for a new
    /// one. Kept while the overlay is closed, so it reopens where you were.
    var thread: String?
}

/// The app's agent, over the app. One piece of glass is the bubble (what the
/// agent and its workers are doing) and, tapped, the panel holding the
/// agent's conversation with its Threads and Builds buttons; the panel floats
/// over the app (mini) or fills the screen. Other threads push in over the
/// agent inside the panel.
///
/// The glass's frame is one spring (`FrameSpring`); the bubble's line and the
/// conversation live inside the glass, laid out from that frame on every
/// frame, so nothing can drift from the shape. A finger takes the spring over
/// (drag, back swipe) and hands it back with its velocity.
@MainActor
final class OverlayController: UIViewController, UIGestureRecognizerDelegate {
    private let model: SquircleModel
    private var route = OverlayRoute()

    private let glass = UIVisualEffectView(effect: Theme.glassEffect())
    private let frame = FrameSpring()
    /// 0 = the agent, 1 = a thread over it.
    private let push = SpringDriver()
    private let bubble = LiveCapsule(glass: false)
    /// The panel's content, inside the glass and clipped by it.
    private let page = UIView()
    /// Paper under the conversation, so it reads over any app.
    private let veil = UIView()
    private let resizeButton = Theme.glassButton(symbol: "arrow.up.left.and.arrow.down.right",
                                                 identifier: "overlay.resize", accessibilityLabel: "Full screen")

    private typealias Mounted = (controller: ThreadViewController, stage: DeviceStage, host: UIView)
    /// Mounted once the app is known and kept, so opening shows it at once.
    private var agent: Mounted?
    /// Changes only while `push` is at 0, i.e. off screen.
    private var thread: Mounted?
    private var threadKey: String?

    /// Bubble side and height; the panel opens from the bubble's corner.
    private var anchor: (right: Bool, y: CGFloat)?
    private var dragStart = CGRect.zero
    private var pushStart: CGFloat = 0
    private var draggingPush = false
    private var keyboardTop = CGFloat.greatestFiniteMagnitude
    private weak var previousKey: UIWindow?
    private var observations: [Task<Void, Never>] = []
    /// Sessions working at the last render, so a finish can be shown.
    private var working: [String: String] = [:]
    private var finished: (text: String, until: Date)?
    private var bubblePan: UIPanGestureRecognizer!
    private var bubbleTap: UITapGestureRecognizer!
    private var movePan: UIPanGestureRecognizer!
    private var backPan: UIPanGestureRecognizer!

    init(model: SquircleModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { route.open && route.full ? .portrait : .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        glass.accessibilityIdentifier = "overlay.bubble"
        glass.contentView.clipsToBounds = true
        glass.contentView.layer.cornerCurve = .continuous
        view.addSubview(glass)
        bubble.isUserInteractionEnabled = false
        bubble.showsTime = false
        bubble.isAccessibilityElement = true
        bubble.accessibilityTraits = .button
        bubble.accessibilityLabel = "Squircle"
        glass.contentView.addSubview(bubble)
        veil.isUserInteractionEnabled = false
        glass.contentView.addSubview(veil)
        page.addSubview(resizeButton)
        glass.contentView.addSubview(page)
        resizeButton.addAction(UIAction { [weak self] _ in self?.toggleFull() }, for: .touchUpInside)

        bubbleTap = UITapGestureRecognizer(target: self, action: #selector(openTapped))
        bubblePan = UIPanGestureRecognizer(target: self, action: #selector(glassDragged(_:)))
        movePan = UIPanGestureRecognizer(target: self, action: #selector(glassDragged(_:)))
        backPan = UIPanGestureRecognizer(target: self, action: #selector(backDragged(_:)))
        for gesture in [bubbleTap, bubblePan, movePan, backPan] as [UIGestureRecognizer] {
            gesture.delegate = self
            glass.addGestureRecognizer(gesture)
        }

        frame.onChange = { [weak self] in self?.applyScene() }
        frame.onRest = { [weak self] in self?.rested() }
        push.onChange = { [weak self] value in
            if value <= 0.001 { self?.sync() } else { self?.applyScene() }
        }
        push.onRest = { [weak self] _ in self?.rested() }
        observations = [
            model.observe(by: self, after: .milliseconds(100)) { $0.render() },
            Task { [weak self] in
                for await note in NotificationCenter.default.notifications(named: UIResponder.keyboardWillChangeFrameNotification) {
                    self?.keyboardMoved(note)
                }
            }
        ]
        render()
        #if DEBUG
        startVerificationHooks()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Rotation or a first layout: rest exactly where the route says.
        if !frame.isAnimating, !frame.isHeld { frame.set(targetFrame) } else { applyScene() }
    }

    // MARK: Model

    private var project: AppProject? { model.projects.first }

    private func render() {
        guard let project else {
            bubble.configure(headline: model.error, started: nil, tone: model.error == nil ? .idle : .needsYou)
            retarget()
            return
        }
        if agent == nil { mountAgent(project) }
        let sessions = model.sessions(for: project, includingAgent: true)
        let agentID = model.agentThreadID(for: project)
        func title(_ session: ChatSession) -> String { session.id == agentID ? project.name : session.displayTitle(in: project) }
        let active = sessions.filter { $0.phase != .idle }
        let now = Date.now
        for (id, name) in working where !active.contains(where: { $0.id == id }) {
            finished = ("Done · " + name, now.addingTimeInterval(6))
            pulse()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6.1))
                self?.render()
            }
        }
        working = Dictionary(active.map { ($0.id, title($0)) }, uniquingKeysWith: { a, _ in a })

        // What the bubble says: whoever needs you, else what the agent is
        // doing (its live step), else a working thread.
        let headline: String?, tone: LiveCapsule.Tone, started: Date?
        if let waiting = active.first(where: { $0.phase == .needsYou }) {
            (headline, tone, started) = ("Needs you · " + title(waiting), .needsYou, nil)
        } else if let busy = active.first(where: { $0.id == agentID }) ?? active.first {
            let live = model.selectedSessionID == busy.id ? liveStatus() : nil
            (headline, tone, started) = (live?.headline ?? title(busy), .working, live?.started)
        } else if let finished, finished.until > now {
            (headline, tone, started) = (finished.text, .done, nil)
        } else {
            (headline, tone, started) = (nil, .idle, nil)
        }
        bubble.configure(headline: headline, started: started, tone: tone)
        bubble.accessibilityValue = headline ?? "Idle"
        if let build = model.updatingTo {
            UpdateCurtain.show(in: view, build: build) { [weak self] in self?.model.cancelUpdate() }
        }
        retarget()
    }

    private func liveStatus() -> LiveStatus? {
        ThreadItem.items(messages: model.messages, running: model.isRunning).reversed().lazy.compactMap { item -> LiveStatus? in
            if case .live(let status) = item { return status }
            return nil
        }.first
    }

    // MARK: Geometry

    private var safeBounds: CGRect { view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 10, dy: 6) }

    private var bubbleSize: CGSize {
        CGSize(width: bubble.preferredWidth(limit: min(300, view.bounds.width * 0.72), height: 44), height: 44)
    }

    private var bubbleFrame: CGRect {
        let size = bubbleSize, safe = safeBounds
        let right = anchor?.right ?? true
        let y = (anchor?.y ?? safe.maxY - 90).clamped(safe.minY + size.height / 2, max(safe.minY + size.height / 2, safe.maxY - size.height / 2))
        return CGRect(x: right ? safe.maxX - size.width : safe.minX, y: y - size.height / 2, width: size.width, height: size.height)
    }

    /// The bubble sits in the lower half: the panel grows up from it.
    private var lower: Bool { bubbleFrame.midY > view.bounds.midY }

    /// The mini panel shares the bubble's side and its bottom (or top) edge,
    /// and rises above the keyboard.
    private var miniFrame: CGRect {
        let safe = safeBounds, bubble = bubbleFrame
        let size = CGSize(width: min(view.bounds.width - 20, 390), height: min(safe.height * 0.66, 600))
        var y = lower ? bubble.maxY - size.height : bubble.minY
        y = y.clamped(safe.minY, max(safe.minY, min(safe.maxY, keyboardTop - 8) - size.height))
        return CGRect(x: bubble.midX > view.bounds.midX ? safe.maxX - size.width : safe.minX, y: y,
                      width: size.width, height: size.height)
    }

    private var targetFrame: CGRect { !route.open ? bubbleFrame : route.full ? view.bounds : miniFrame }

    /// Sends the glass toward wherever the route and anchor now put it.
    private func retarget(velocity: CGPoint? = nil) {
        guard view.bounds.width > 0, !frame.isHeld else { return }
        let target = targetFrame
        if frame.target != target || velocity != nil { frame.animate(to: target, velocity: velocity) }
    }

    // MARK: Scene

    /// Every frame, from the glass's presented frame and the push alone.
    private func applyScene() {
        guard view.bounds.width > 0 else { return }
        let rect = frame.value
        let mini = miniFrame, bounds = view.bounds
        let bubbleSize = self.bubbleSize
        // 0 at bubble size, 1 at mini size and beyond; 0…1 mini → full.
        let opened = ((rect.height - bubbleSize.height) / max(1, mini.height - bubbleSize.height)).clamped()
        let fullness = ((rect.height - mini.height) / max(1, bounds.height - mini.height)).clamped()
        glass.frame = rect
        let radius = min(rect.height / 2, rect.width / 2, .lerp(30, 0, fullness))
        Theme.setGlassCorner(glass, radius: radius)
        glass.contentView.layer.cornerRadius = radius

        // The bubble's line stays where it was on screen as the glass grows
        // from its corner, fading as soon as the shape leaves it.
        let right = rect.midX > bounds.midX || (anchor?.right ?? true)
        let low = lower
        bubble.frame = CGRect(x: right ? rect.width - bubbleSize.width : 0, y: low ? rect.height - bubbleSize.height : 0,
                              width: bubbleSize.width, height: bubbleSize.height)
        bubble.alpha = (1 - opened * 4).clamped()
        bubble.isHidden = bubble.alpha == 0

        // The conversation is laid out at least at mini size and pinned to
        // the same corner, so the glass reveals it instead of squeezing it.
        // Opening, it never grows past where it is headed: the glass's
        // overshoot shows paper, not a relayout.
        var size = CGSize(width: max(rect.width, mini.width), height: max(rect.height, mini.height))
        if route.open {
            let target = frame.target.size
            size = CGSize(width: max(mini.width, min(size.width, target.width)), height: max(mini.height, min(size.height, target.height)))
        }
        page.frame = CGRect(x: right ? rect.width - size.width : 0, y: low ? rect.height - size.height : 0,
                            width: size.width, height: size.height)
        page.alpha = ((opened - 0.2) / 0.6).clamped()
        page.isHidden = page.alpha == 0 && !route.open
        veil.frame = glass.contentView.bounds
        veil.alpha = page.alpha
        let paper = Theme.paper.withAlphaComponent(.lerp(0.74, 1, fullness))
        veil.backgroundColor = paper
        let full = route.full
        resizeButton.configuration?.image = UIImage(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        resizeButton.accessibilityLabel = full ? "Make small" : "Full screen"
        resizeButton.frame = CGRect(x: page.bounds.width - 60, y: page.safeAreaInsets.top + 4, width: 44, height: 44)

        // Flat push: a thread slides in on its own paper over the agent, which
        // drifts a third as far left and fades out first, so text never sits
        // over text.
        let t = push.value.clamped(), width = page.bounds.width
        if let agent {
            place(agent, offset: -width * 0.3 * t)
            agent.host.alpha = (1 - t * 2).clamped()
            agent.controller.setTransitionProgress(1 - t)
        }
        if let thread {
            place(thread, offset: width * (1 - t))
            // Only while the agent still shows beneath it.
            thread.host.backgroundColor = paper.withAlphaComponent(paper.cgColor.alpha * ((1 - t) * 2).clamped())
            thread.controller.setTransitionProgress(t)
        }

        // Touches go where the route is headed, from the first frame.
        let onThread = route.thread != nil && route.thread == threadKey && thread != nil
        page.isUserInteractionEnabled = route.open
        agent?.host.isUserInteractionEnabled = route.open && !onThread
        thread?.host.isUserInteractionEnabled = route.open && onThread
        page.accessibilityElementsHidden = !route.open
        bubble.accessibilityElementsHidden = route.open
    }

    private func place(_ mounted: Mounted, offset: CGFloat) {
        let bounds = page.bounds
        if mounted.host.bounds.size != bounds.size {
            mounted.host.transform = .identity
            mounted.host.frame = bounds
            mounted.stage.frame = bounds
            mounted.controller.view.frame = bounds
            mounted.stage.overlay.frame = bounds
        }
        mounted.host.transform = CGAffineTransform(translationX: offset, y: 0)
        pose(mounted)
    }

    private func pose(_ mounted: Mounted) {
        guard let project else { return }
        mounted.stage.apply(mounted.controller.hidesDevice ? [:] : [project.id: mounted.controller.pose])
    }

    private func rested() {
        sync()
        guard !frame.isAnimating, !push.isAnimating else { return }
        if !route.open {
            previousKey?.makeKey()
            previousKey = nil
        }
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    // MARK: Navigation

    private func open() {
        guard !route.open, project != nil else { return }
        Theme.openHaptic()
        hostWillBeCovered()
        makeKey()
        route.open = true
        sync()
    }

    /// The point where the panel starts to cover the host app. Image
    /// attachments capture the app's screen here and hand it to the agent.
    private func hostWillBeCovered() {}

    private func close() {
        guard route.open else { return }
        Theme.selectionHaptic()
        view.endEditing(true)
        route.open = false
        sync()
    }

    private func toggleFull() {
        guard route.open else { return }
        Theme.selectionHaptic()
        route.full.toggle()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        sync()
    }

    private func openThread(_ id: String?) {
        guard route.open, agent != nil else { return }
        Theme.openHaptic()
        view.endEditing(true)
        route.thread = id ?? "draft:" + UUID().uuidString
        sync()
    }

    private func closeThread() {
        guard route.thread != nil else { return }
        view.endEditing(true)
        route.thread = nil
        sync()
    }

    /// Makes what is mounted and where the springs head agree with the route.
    /// Safe to call at any moment, any number of times.
    private func sync() {
        guard !draggingPush else { return }
        if push.value <= 0.001, threadKey != nil, route.thread != threadKey { unmountThread() }
        if push.value <= 0.001, thread == nil, let key = route.thread { mountThread(key) }
        let target: CGFloat = route.thread != nil && route.thread == threadKey && thread != nil ? 1 : 0
        if push.target != target || (!push.isAnimating && push.value != target) { push.redirect(to: target) }
        retarget()
        applyScene()
    }

    private func mountAgent(_ project: AppProject) {
        let stage = DeviceStage()
        let controller = ThreadViewController(model: model, project: project, sessionID: model.agentThreadID(for: project),
                                              stage: stage, agent: true)
        controller.hidesIdleDevice = true
        controller.setBackButton(symbol: "chevron.down", label: "Minimize")
        controller.onBack = { [weak self] in self?.close() }
        controller.onOpenThread = { [weak self] id in self?.openThread(id) }
        controller.onThreads = { [weak self] in self?.presentThreads() }
        controller.onBuilds = { [weak self] in self?.presentBuilds() }
        agent = host(controller, stage: stage)
    }

    private func mountThread(_ key: String) {
        guard let project else { return }
        agent?.controller.deactivate()
        let stage = DeviceStage()
        let controller = ThreadViewController(model: model, project: project, sessionID: key.hasPrefix("draft:") ? nil : key,
                                              stage: stage)
        controller.hidesIdleDevice = true
        controller.onBack = { [weak self] in self?.closeThread() }
        thread = host(controller, stage: stage)
        threadKey = key
    }

    private func unmountThread() {
        guard let mounted = thread else { return }
        thread = nil
        threadKey = nil
        mounted.controller.tearDown()
        mounted.stage.endLive(for: mounted.controller.project.id)
        mounted.controller.willMove(toParent: nil)
        mounted.host.removeFromSuperview()
        mounted.controller.removeFromParent()
        agent?.controller.reactivate()
    }

    /// A conversation on its own stage; the device shows only while the
    /// agent's simulator is live (you are already in the app).
    private func host(_ controller: ThreadViewController, stage: DeviceStage) -> Mounted {
        stage.showsBackdrop = false
        if let project { stage.sync(ids: [project.id]) }
        let host = UIView()
        host.clipsToBounds = true
        addChild(controller)
        host.addSubview(stage)
        host.addSubview(controller.view)
        host.addSubview(stage.overlay)
        page.insertSubview(host, belowSubview: resizeButton)
        controller.didMove(toParent: self)
        let mounted = (controller, stage, host)
        controller.onGeometry = { [weak self] in self?.pose(mounted) }
        host.frame = page.bounds
        controller.view.frame = host.bounds
        controller.setTransitionProgress(1)
        return mounted
    }

    private func makeKey() {
        guard let window = view.window, !window.isKeyWindow else { return }
        previousKey = window.windowScene?.keyWindow
        window.makeKey()
    }

    // MARK: Sheets

    private func presentThreads() {
        guard let project, presentedViewController == nil, route.open, route.thread == nil else { return }
        Theme.selectionHaptic()
        let controller = ThreadsViewController(model: model, project: project)
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

    private func presentBuilds() {
        guard let project, presentedViewController == nil, route.open else { return }
        Theme.selectionHaptic()
        let controller = BuildsViewController(model: model, project: project)
        controller.onNewThread = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.openThread(nil) }
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }

    // MARK: Gestures

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === bubbleTap || gesture === bubblePan { return !route.open }
        // Where the finger went down, not where it is once the pan is
        // recognized: a quick drag has already left the strip by then.
        var point = gesture.location(in: page)
        if let pan = gesture as? UIPanGestureRecognizer {
            let moved = pan.translation(in: page)
            point = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
        }
        if gesture === backPan {
            let velocity = backPan.velocity(in: page)
            return route.open && thread != nil && point.x < 28 && velocity.x > abs(velocity.y)
        }
        if gesture === movePan {
            // Move the mini panel by its top, between its buttons.
            return route.open && !route.full && point.y < 52 && point.x > 176 && point.x < page.bounds.width - 64
        }
        return true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    @objc private func openTapped() { open() }

    /// The glass and everything in it follow the finger; on release they
    /// spring to the nearer side with the finger's speed.
    @objc private func glassDragged(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            dragStart = frame.value
            frame.hold(dragStart)
        case .changed:
            frame.hold(dragStart.offsetBy(dx: t.x, dy: t.y))
        case .ended, .cancelled, .failed:
            let v = gesture.velocity(in: view)
            // Where it would coast to decides the side and height it rests at.
            let rest = dragStart.offsetBy(dx: t.x + v.x * 0.12, dy: t.y + v.y * 0.12)
            let bubbleHeight = bubbleSize.height
            let y = !route.open ? rest.midY
                : rest.midY > view.bounds.midY ? rest.maxY - bubbleHeight / 2 : rest.minY + bubbleHeight / 2
            anchor = (rest.midX > view.bounds.midX, y)
            frame.release()
            retarget(velocity: v)
        default: break
        }
    }

    @objc private func backDragged(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, page.bounds.width)
        switch gesture.state {
        case .began:
            draggingPush = true
            pushStart = push.value
            push.stop()
        case .changed:
            push.set((pushStart - gesture.translation(in: page).x / width).clamped())
        case .ended, .cancelled, .failed:
            draggingPush = false
            let velocity = -gesture.velocity(in: page).x / width
            if gesture.state == .ended, push.value + velocity * 0.18 < 0.5 { route.thread = nil; view.endEditing(true) }
            push.animate(to: route.thread == nil ? 0 : 1, initialVelocity: velocity)
            sync()
        default: break
        }
    }

    /// A soft beat when a turn finishes.
    private func pulse() {
        guard !Motion.reduced, !route.open else { return }
        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1, 1.08, 1]
        beat.keyTimes = [0, 0.35, 1]
        beat.duration = 0.6
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glass.layer.add(beat, forKey: "pulse")
    }

    private func keyboardMoved(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = view.convert(end, from: nil)
        keyboardTop = frame.minY >= view.bounds.maxY - 1 ? .greatestFiniteMagnitude : frame.minY
        retarget()
    }

    override func accessibilityPerformEscape() -> Bool {
        if route.thread != nil { closeThread(); return true }
        if route.open { close(); return true }
        return false
    }

    #if DEBUG
    /// Verification only, in Squircle Debug with `SQUIRCLE_OVERLAY_DEMO`:
    /// `SQUIRCLE_OVERLAY_OPEN=mini|full` opens the overlay after 4 s;
    /// `SQUIRCLE_OVERLAY_CYCLE=1` loops bubble → mini → full → thread → back
    /// → mini → bubble for recordings (`SQUIRCLE_SLOW` slows the springs).
    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        if let slow = environment["SQUIRCLE_SLOW"].flatMap(Double.init) { SpringDriver.debugSlowMotion = slow }
        if let mode = environment["SQUIRCLE_OVERLAY_OPEN"] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.open()
                if mode == "full" { self?.toggleFull() }
            }
        }
        guard environment["SQUIRCLE_OVERLAY_CYCLE"] == "1" else { return }
        let pause = environment["SQUIRCLE_OVERLAY_PAUSE"].flatMap(Double.init) ?? 2.5
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            let steps: [@MainActor (OverlayController) -> Void] = [
                { $0.open() }, { $0.toggleFull() }, { overlay in
                    let sessions = overlay.project.map { overlay.model.sessions(for: $0) } ?? []
                    overlay.openThread(sessions.first?.id)
                }, { $0.closeThread() }, { $0.toggleFull() }, { $0.close() },
                // Interrupted: closing while it opens, opening while it closes.
                { $0.open() }, { $0.close() }, { $0.open() }, { $0.close() }
            ]
            while true {
                for (index, step) in steps.enumerated() {
                    guard let self else { return }
                    step(self)
                    let interrupted = index >= 6
                    try? await Task.sleep(for: .seconds(interrupted ? 0.25 * SpringDriver.debugSlowMotion : pause))
                }
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }
    #endif
}

/// The glass's frame as one spring: origin and size move together toward a
/// target, keep their velocity when retargeted, and can be held by a finger.
@MainActor
final class FrameSpring {
    private(set) var value = CGRect.zero
    private(set) var target = CGRect.zero
    /// Points per second for x, y, width and height.
    private var velocity: [CGFloat] = [0, 0, 0, 0]
    /// Slightly underdamped, so the glass lands with a little give.
    var parameters = SpringDriver.Parameters(response: 0.46, damping: 0.8)
    var onChange: (() -> Void)?
    var onRest: (() -> Void)?
    var isAnimating: Bool { link != nil }
    private(set) var isHeld = false
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    /// Jumps there and rests.
    func set(_ rect: CGRect) {
        stopLink()
        velocity = [0, 0, 0, 0]
        value = rect
        target = rect
        onChange?()
    }

    /// A finger holds it here.
    func hold(_ rect: CGRect) {
        isHeld = true
        set(rect)
    }

    func release() { isHeld = false }

    /// Retargets from the presented frame, keeping its momentum unless a
    /// finger's velocity is given.
    func animate(to rect: CGRect, velocity v: CGPoint? = nil) {
        target = rect
        if let v { velocity = [v.x, v.y, 0, 0] }
        if Motion.reduced {
            set(rect)
            onRest?()
            return
        }
        guard link == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var dt = min(1.0 / 30.0, max(0, now - (lastTimestamp ?? (now - link.duration))))
        #if DEBUG
        dt /= SpringDriver.debugSlowMotion
        #endif
        lastTimestamp = now
        var current = [value.minX, value.minY, value.width, value.height]
        let goal = [target.minX, target.minY, target.width, target.height]
        var resting = true
        for i in 0..<4 {
            (current[i], velocity[i]) = SpringDriver.step(value: current[i], velocity: velocity[i], target: goal[i],
                                                          dt: CGFloat(dt), parameters: parameters)
            if abs(current[i] - goal[i]) > 0.2 || abs(velocity[i]) > 2 { resting = false }
        }
        if resting {
            set(target)
            onRest?()
        } else {
            value = CGRect(x: current[0], y: current[1], width: max(1, current[2]), height: max(1, current[3]))
            onChange?()
        }
    }
}
#endif
