#if SQUIRCLE_OVERLAY || DEBUG
import Combine
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
    DispatchQueue.main.async {
        MainActor.assumeIsolated { OverlayHost.shared.start(bundleID: bundleID, configuration: configuration) }
    }
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

/// Touches that miss the overlay's own controls reach the app beneath.
final class OverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view?.accessibilityIdentifier == OverlayController.passthrough || view === rootViewController?.view ? nil : view
    }
}

/// The overlay over the host app. A glass bubble shows what the agent is
/// doing in this app; it materializes into a glass panel at the same place,
/// as Liquid Glass shapes merge. The panel shows the app's threads or one
/// thread, each either mini (floating over the app while you use it) or full
/// screen; size and content change independently.
@MainActor
final class OverlayController: UIViewController, UIGestureRecognizerDelegate {
    static let passthrough = "overlay.passthrough"
    private enum Size { case bubble, mini, full }

    private let model: SquircleModel
    private var size = Size.bubble
    /// 0 shows the thread list, 1 the open thread; a finger can scrub it.
    private let push = SpringDriver(value: 0)

    /// Lets the bubble and panel glass flow into each other.
    private let group = Theme.glassGroup(spacing: 30)
    private let bubbleGlass = UIVisualEffectView(effect: Theme.glassEffect(interactive: true))
    private let bubble = LiveCapsule(glass: false)
    private let panel = UIVisualEffectView(effect: nil)
    /// Everything on the panel; follows its frame and bounds, never clipped
    /// by a moving mask.
    private let content = UIView()
    /// Paper under the text, so it reads over any app.
    private let veil = UIView()
    private let list = OverlayListView()
    private var thread: (controller: ThreadViewController, stage: DeviceStage, page: UIView)?
    private let grabber = UIView()
    private let resizeButton = OverlayController.iconButton("arrow.up.left.and.arrow.down.right", "Full screen", "overlay.resize")
    private let minimizeButton = OverlayController.iconButton("chevron.down", "Minimize", "overlay.minimize")

    /// Bubble center; the panel opens from the bubble's corner and the two
    /// always share this place.
    private var anchor: CGPoint?
    private var dragOrigin = CGPoint.zero
    private var movePan: UIPanGestureRecognizer!
    private var backPan: UIPanGestureRecognizer!
    private var pushStart: CGFloat = 0
    private var keyboardTop = CGFloat.greatestFiniteMagnitude
    private weak var previousKey: UIWindow?
    private var subscriptions = Set<AnyCancellable>()
    /// Threads working at the last render, so a finish can be shown.
    private var working: [String: String] = [:]
    private var finished: (text: String, until: Date)?
    /// A new thread is being created; don't follow another meanwhile.
    private var starting = false

    init(model: SquircleModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { size == .full ? .portrait : .all }

    static func iconButton(_ symbol: String, _ label: String, _ identifier: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        return button
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        group.frame = view.bounds
        group.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        group.accessibilityIdentifier = Self.passthrough
        group.contentView.accessibilityIdentifier = Self.passthrough
        view.addSubview(group)
        group.contentView.addSubview(panel)
        group.contentView.addSubview(bubbleGlass)

        bubbleGlass.accessibilityIdentifier = "overlay.bubble"
        bubbleGlass.isAccessibilityElement = true
        bubbleGlass.accessibilityTraits = .button
        bubble.isUserInteractionEnabled = false
        bubble.showsTime = false
        bubbleGlass.contentView.addSubview(bubble)

        panel.isHidden = true
        // Above the glass, not inside it: the container would merge the
        // conversation's own glass controls into the panel.
        view.addSubview(content)
        // The panel's own rounded shape; content follows its bounds.
        content.clipsToBounds = true
        content.layer.cornerCurve = .continuous
        veil.isUserInteractionEnabled = false
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        [veil, list, grabber, resizeButton, minimizeButton].forEach(content.addSubview)

        list.onOpenThread = { [weak self] id in self?.openThread(id) }
        list.onBuilds = { [weak self] in self?.presentBuilds() }
        list.onStart = { [weak self] text in self?.startThread(text) }
        resizeButton.addAction(UIAction { [weak self] _ in self?.resize() }, for: .touchUpInside)
        minimizeButton.addAction(UIAction { [weak self] _ in self?.minimize() }, for: .touchUpInside)

        bubbleGlass.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
        let bubblePan = UIPanGestureRecognizer(target: self, action: #selector(bubbleDragged(_:)))
        bubbleGlass.addGestureRecognizer(bubblePan)
        movePan = UIPanGestureRecognizer(target: self, action: #selector(panelDragged(_:)))
        movePan.delegate = self
        content.addGestureRecognizer(movePan)
        backPan = UIPanGestureRecognizer(target: self, action: #selector(backDragged(_:)))
        backPan.delegate = self
        content.addGestureRecognizer(backPan)

        push.onChange = { [weak self] _ in self?.layoutPages() }
        push.onRest = { [weak self] value in if value <= 0.001 { self?.closeThread() } }
        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.keyboardMoved(note) }
            .store(in: &subscriptions)
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        place()
    }

    // MARK: State

    private var project: AppProject? { model.projects.first }

    private func render() {
        guard let project else {
            list.update(project: nil, sessions: [], model: model, live: nil)
            return
        }
        let sessions = model.sessions(for: project)
        let active = sessions.filter { $0.phase != .idle }
        let target = active.first { $0.phase == .needsYou } ?? active.first
        // Follow the active thread live, as its conversation does, while no
        // thread is open in the panel.
        if !starting, thread == nil, let target, model.selectedSessionID != target.id {
            Task { await model.selectSession(target.id) }
        }
        let now = Date.now
        for (id, title) in working where !active.contains(where: { $0.id == id }) {
            finished = ("Done · " + title, now.addingTimeInterval(6))
            pulse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.render() }
        }
        working = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0.displayTitle(in: project)) })

        // The open thread, else the one followed.
        let shown = thread.flatMap { open in sessions.first { $0.id == open.controller.currentSessionID } } ?? target
        var status: (headline: String?, started: Date?, tone: LiveCapsule.Tone, session: String?) = (nil, nil, .idle, nil)
        if let shown, shown.phase != .idle {
            if shown.phase == .needsYou {
                status = ("Needs you · " + shown.displayTitle(in: project), nil, .needsYou, shown.id)
            } else {
                let live = model.selectedSessionID == shown.id ? liveStatus() : nil
                status = (live?.headline ?? shown.displayTitle(in: project), live?.started, .working, shown.id)
            }
        } else if let finished, finished.until > now {
            status = (finished.text, nil, .done, nil)
        }
        let width = bubble.headline == status.headline ? nil : bubble.bounds.width
        bubble.configure(headline: status.headline, started: status.started, tone: status.tone)
        bubbleGlass.accessibilityLabel = "Squircle"
        bubbleGlass.accessibilityValue = status.headline ?? "Idle"
        list.update(project: project, sessions: sessions, model: model,
                    live: target.map { _ in (status.headline, status.started, status.tone, target?.id) })
        if let build = model.updatingTo {
            UpdateCurtain.show(in: view, build: build) { [weak self] in self?.model.cancelUpdate() }
        }
        if size == .bubble, let width, abs(bubbleSize.width - width) > 0.5, !Motion.reduced {
            UIView.animate(springDuration: 0.5, bounce: 0.15, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) { self.place() }
        } else {
            place()
        }
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
        var center = anchor ?? CGPoint(x: safe.maxX, y: safe.maxY - 90)
        center.x = center.x < view.bounds.midX ? safe.minX + size.width / 2 : safe.maxX - size.width / 2
        center.y = center.y.clamped(safe.minY + size.height / 2, max(safe.minY + size.height / 2, safe.maxY - size.height / 2))
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The mini panel grows from the bubble's corner: the same side, and the
    /// same bottom (or top) edge.
    private var miniFrame: CGRect {
        let safe = safeBounds, bubble = bubbleFrame
        let size = CGSize(width: min(view.bounds.width - 20, 380), height: min(safe.height * 0.62, 560))
        let right = bubble.midX > view.bounds.midX
        var y = bubble.midY > view.bounds.midY ? bubble.maxY - size.height : bubble.minY
        y = y.clamped(safe.minY, max(safe.minY, min(safe.maxY, keyboardTop - 8) - size.height))
        return CGRect(x: right ? safe.maxX - size.width : safe.minX, y: y, width: size.width, height: size.height)
    }

    private var panelFrame: CGRect { size == .full ? view.bounds : miniFrame }

    /// Places everything for the current size, without animating by itself.
    private func place() {
        guard view.bounds.width > 0 else { return }
        let bubble = bubbleFrame
        bubbleGlass.frame = bubble
        Theme.setGlassCorner(bubbleGlass, radius: bubble.height / 2)
        self.bubble.frame = CGRect(origin: .zero, size: bubble.size)
        let frame = panelFrame
        panel.frame = frame
        Theme.setGlassCorner(panel, radius: size == .full ? 0 : 30)
        content.layer.cornerRadius = size == .full ? 0 : 30
        content.bounds = CGRect(origin: .zero, size: frame.size)
        content.center = CGPoint(x: frame.midX, y: frame.midY)
        content.isHidden = panel.isHidden
        veil.frame = content.bounds
        veil.backgroundColor = Theme.paper.withAlphaComponent(size == .full ? 1 : 0.72)
        let top: CGFloat = size == .full ? view.safeAreaInsets.top + 2 : 8
        grabber.frame = CGRect(x: (frame.width - 36) / 2, y: 6, width: 36, height: 5)
        grabber.alpha = size == .full ? 0 : 1
        minimizeButton.frame = CGRect(x: frame.width - 46, y: top, width: 38, height: 38)
        resizeButton.frame = minimizeButton.frame.offsetBy(dx: -38, dy: 0)
        resizeButton.configuration?.image = UIImage(systemName: size == .full
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        resizeButton.accessibilityLabel = size == .full ? "Make small" : "Full screen"
        layoutPages()
    }

    private func layoutPages() {
        let bounds = content.bounds
        let p = push.value
        list.headerTop = size == .full ? view.safeAreaInsets.top : 0
        list.keyboardInset = size == .full && keyboardTop < .greatestFiniteMagnitude ? view.bounds.height - keyboardTop : 0
        list.transform = .identity
        list.frame = bounds
        list.transform = CGAffineTransform(translationX: -bounds.width * 0.3 * p, y: 0)
        list.alpha = 1 - p
        list.isHidden = p > 0.999
        if let thread {
            thread.page.transform = .identity
            thread.page.frame = bounds
            thread.page.transform = CGAffineTransform(translationX: bounds.width * (1 - p), y: 0)
            thread.stage.frame = thread.page.bounds
            // Full screen, the conversation sits on Squircle's own lit
            // backdrop, which its glass is drawn for.
            thread.stage.showsBackdrop = size == .full
            thread.controller.view.frame = thread.page.bounds
            thread.controller.view.layoutIfNeeded()
            stagePose()
        }
    }

    private func stagePose() {
        guard let thread, let project else { return }
        thread.stage.apply(thread.controller.hidesDevice ? [:] : [project.id: thread.controller.pose])
    }

    // MARK: Moves

    @objc private func open() {
        guard size == .bubble else { return }
        Theme.openHaptic()
        size = .mini
        place()
        panel.isHidden = false
        content.isHidden = false
        // The panel's content rises from the bubble as the glass forms.
        content.alpha = 0
        content.transform = shrink(toward: bubbleFrame)
        makeKey()
        UIView.animate(springDuration: 0.5, bounce: 0.18, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
            self.bubbleGlass.effect = nil
            self.bubble.alpha = 0
            self.panel.effect = Theme.glassEffect()
            self.content.alpha = 1
            self.content.transform = .identity
        } completion: { _ in
            if self.size != .bubble { self.bubbleGlass.isHidden = true }
        }
    }

    private func minimize() {
        guard size != .bubble else { return }
        view.endEditing(true)
        let wasFull = size == .full
        size = .bubble
        bubbleGlass.isHidden = false
        UIView.animate(springDuration: 0.5, bounce: 0.12, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
            if wasFull {
                // Back to its small size as it goes, so it gathers into the bubble.
                self.panel.frame = self.miniFrame
                Theme.setGlassCorner(self.panel, radius: 30)
                self.content.layer.cornerRadius = 30
                self.content.bounds = CGRect(origin: .zero, size: self.miniFrame.size)
                self.content.center = CGPoint(x: self.miniFrame.midX, y: self.miniFrame.midY)
                self.layoutPages()
            }
            self.panel.effect = nil
            self.content.alpha = 0
            self.content.transform = self.shrink(toward: self.bubbleFrame)
            self.bubbleGlass.effect = Theme.glassEffect(interactive: true)
            self.bubble.alpha = 1
        } completion: { _ in
            guard self.size == .bubble else { return }
            self.panel.isHidden = true
            self.content.isHidden = true
            self.content.transform = .identity
            self.previousKey?.makeKey()
            self.previousKey = nil
            self.setNeedsUpdateOfSupportedInterfaceOrientations()
            self.render()
        }
    }

    /// Mini ↔ full screen, for whichever page is showing; the content lays
    /// itself out at each size as the glass grows.
    private func resize() {
        guard size != .bubble else { return }
        Theme.selectionHaptic()
        view.endEditing(true)
        size = size == .full ? .mini : .full
        setNeedsUpdateOfSupportedInterfaceOrientations()
        UIView.animate(springDuration: 0.5, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
            self.place()
            self.content.layoutIfNeeded()
        }
    }

    /// A transform that shrinks the panel's content toward the bubble.
    private func shrink(toward bubble: CGRect) -> CGAffineTransform {
        let frame = panel.frame
        let point = CGPoint(x: bubble.midX - frame.minX - frame.width / 2, y: bubble.midY - frame.minY - frame.height / 2)
        return CGAffineTransform(translationX: point.x, y: point.y).scaledBy(x: 0.6, y: 0.6)
            .translatedBy(x: -point.x * 0.5, y: -point.y * 0.5)
    }

    private func makeKey() {
        guard let window = view.window, !window.isKeyWindow else { return }
        previousKey = window.windowScene?.keyWindow
        window.makeKey()
    }

    // MARK: Pages

    private func openThread(_ sessionID: String?) {
        guard let project else { return }
        Theme.openHaptic()
        view.endEditing(true)
        if let thread { tearDown(thread) }
        let stage = DeviceStage()
        stage.showsBackdrop = false
        stage.sync(ids: [project.id])
        let controller = ThreadViewController(model: model, project: project, sessionID: sessionID, stage: stage)
        controller.hidesIdleDevice = true
        controller.onBack = { [weak self] in self?.push.animate(to: 0) }
        controller.onGeometry = { [weak self] in self?.stagePose() }
        let page = UIView()
        page.clipsToBounds = true
        addChild(controller)
        page.addSubview(stage)
        page.addSubview(controller.view)
        page.addSubview(stage.overlay)
        content.insertSubview(page, belowSubview: grabber)
        controller.didMove(toParent: self)
        thread = (controller, stage, page)
        controller.setTransitionProgress(1)
        layoutPages()
        push.animate(to: 1)
    }

    private func closeThread() {
        guard let thread else { return }
        tearDown(thread)
        self.thread = nil
        render()
    }

    private func tearDown(_ thread: (controller: ThreadViewController, stage: DeviceStage, page: UIView)) {
        thread.controller.pausePreview()
        thread.stage.endLive(for: thread.controller.project.id)
        thread.controller.willMove(toParent: nil)
        thread.page.removeFromSuperview()
        thread.controller.removeFromParent()
    }

    private func startThread(_ text: String) {
        guard let project else { return }
        starting = true
        Task {
            await model.beginDraft()
            await model.send(text, in: project)
            starting = false
            if let id = model.selectedSessionID { openThread(id) }
            render()
        }
    }

    private func presentBuilds() {
        guard let project, presentedViewController == nil else { return }
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
        let point = gesture.location(in: content)
        if gesture === backPan {
            // Back: from the panel's left edge, rightward, while a thread is open.
            let velocity = backPan.velocity(in: content)
            return thread != nil && point.x < 28 && velocity.x > abs(velocity.y)
        }
        if gesture === movePan {
            // Move: by the panel's top while it floats over the app.
            return size == .mini && point.y < 44 && point.x > 60 && point.x < content.bounds.width - 90
        }
        return true
    }

    @objc private func bubbleDragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: dragOrigin = bubbleGlass.center
        case .changed:
            let t = gesture.translation(in: view)
            bubbleGlass.center = CGPoint(x: dragOrigin.x + t.x, y: dragOrigin.y + t.y)
        case .ended, .cancelled:
            let v = gesture.velocity(in: view)
            anchor = CGPoint(x: bubbleGlass.center.x + v.x * 0.15, y: bubbleGlass.center.y + v.y * 0.15)
            settle()
        default: break
        }
    }

    /// Moving the panel moves the bubble with it: they share one place.
    @objc private func panelDragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: dragOrigin = panel.center
        case .changed:
            let t = gesture.translation(in: view)
            panel.center = CGPoint(x: dragOrigin.x + t.x, y: dragOrigin.y + t.y)
        case .ended, .cancelled:
            let v = gesture.velocity(in: view)
            let frame = panel.frame.offsetBy(dx: v.x * 0.12, dy: v.y * 0.12)
            let lower = frame.midY > view.bounds.midY
            anchor = CGPoint(x: frame.midX > view.bounds.midX ? view.bounds.maxX : 0,
                             y: lower ? frame.maxY - 22 : frame.minY + 22)
            settle()
        default: break
        }
    }

    @objc private func backDragged(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, content.bounds.width)
        switch gesture.state {
        case .began:
            pushStart = push.value
            push.stop()
        case .changed:
            push.set((pushStart - gesture.translation(in: content).x / width).clamped())
        case .ended, .cancelled, .failed:
            let velocity = -gesture.velocity(in: content).x / width
            let back = gesture.state == .ended && push.value + velocity * 0.18 < 0.5
            if back { view.endEditing(true) }
            push.animate(to: back ? 0 : 1, initialVelocity: velocity)
        default: break
        }
    }

    private func settle() {
        UIView.animate(springDuration: 0.45, bounce: 0.18, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.place() }
    }

    /// A soft beat when a turn finishes.
    private func pulse() {
        guard !Motion.reduced, size == .bubble else { return }
        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1, 1.08, 1]
        beat.keyTimes = [0, 0.35, 1]
        beat.duration = 0.6
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bubbleGlass.layer.add(beat, forKey: "pulse")
    }

    private func keyboardMoved(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = view.convert(end, from: nil)
        keyboardTop = frame.minY >= view.bounds.maxY - 1 ? .greatestFiniteMagnitude : frame.minY
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) {
            self.place()
            self.content.layoutIfNeeded()
        }
    }
}

/// The app's threads in the overlay: what's running now, every thread, and a
/// field to start a new one.
@MainActor
final class OverlayListView: UIView {
    var onOpenThread: ((String?) -> Void)?
    var onBuilds: (() -> Void)?
    var onStart: ((String) -> Void)?
    /// Room above the header (the status bar at full screen).
    var headerTop: CGFloat = 0 { didSet { if headerTop != oldValue { setNeedsLayout() } } }
    var keyboardInset: CGFloat = 0 { didSet { if keyboardInset != oldValue { setNeedsLayout() } } }

    private let nameLabel = Theme.label("", Theme.font(.headline, 17, .semibold))
    private let buildsButton = OverlayController.iconButton("shippingbox", "Builds", "overlay.builds")
    private let live = LiveCapsule(glass: false)
    private var liveSession: String?
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private var rowViews: [String: ThreadRow] = [:]
    private var rowOrder: [String] = []
    private let notice = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel, lines: 3)
    private let composer = Composer(placeholder: "New thread")

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.lineBreakMode = .byTruncatingTail
        notice.textAlignment = .center
        live.backgroundColor = Theme.pressedFill
        live.layer.cornerCurve = .continuous
        live.accessibilityIdentifier = "overlay.live"
        live.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openLive)))
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        rows.axis = .vertical
        scroll.addSubview(rows)
        buildsButton.addAction(UIAction { [weak self] _ in self?.onBuilds?() }, for: .touchUpInside)
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in self?.setNeedsLayout() }
        [scroll, notice, live, nameLabel, buildsButton, composer].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(project: AppProject?, sessions: [ChatSession], model: SquircleModel,
                live status: (headline: String?, started: Date?, tone: LiveCapsule.Tone, session: String?)?) {
        nameLabel.text = project?.name
        buildsButton.isEnabled = project != nil
        let building = project.map { project in
            model.builds(for: project).contains { $0.status == "queued" || $0.status == "running" }
        } ?? false
        buildsButton.configuration?.baseForegroundColor = building ? Theme.accent : .secondaryLabel
        live.configure(headline: status?.headline, started: status?.started, tone: status?.tone ?? .idle)
        liveSession = status?.session
        live.isHidden = status?.headline == nil

        let shown = Array(sessions.prefix(30))
        let ids = shown.map(\.id)
        for id in Array(rowViews.keys) where !ids.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        for session in shown {
            let row = rowViews[session.id] ?? {
                let row = ThreadRow(sessionID: session.id, compact: true)
                row.addAction(UIAction { [weak self] _ in self?.onOpenThread?(session.id) }, for: .touchUpInside)
                rowViews[session.id] = row
                return row
            }()
            row.configure(title: project.map { session.displayTitle(in: $0) } ?? session.title,
                          agent: model.agentName(for: session.modelSelection), date: session.updatedAt, phase: session.phase)
        }
        if ids != rowOrder {
            rowOrder = ids
            rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
            for (index, id) in ids.enumerated() {
                guard let row = rowViews[id] else { continue }
                row.showsSeparator = index < ids.count - 1
                rows.addArrangedSubview(row)
            }
        }
        let problem = project == nil && !model.isLoading
            ? (model.error ?? (model.connected ? "Opening this app in T3…" : model.status)) : model.error
        notice.text = problem ?? (sessions.isEmpty ? "No threads yet" : nil)
        notice.textColor = model.error == nil ? .secondaryLabel : Theme.failure
        notice.isHidden = notice.text == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let top = headerTop + 14
        buildsButton.frame = CGRect(x: width - 46 - 76, y: top - 6, width: 38, height: 38)
        nameLabel.frame = CGRect(x: 20, y: top, width: buildsButton.frame.minX - 24, height: 26)
        var y = top + 38
        if !live.isHidden {
            live.frame = CGRect(x: 12, y: y, width: width - 24, height: 44)
            live.layer.cornerRadius = 22
            y += 52
        }
        let composerHeight = max(48, composer.systemLayoutSizeFitting(CGSize(width: width - 20, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
        let bottom = bounds.height - max(safeAreaInsets.bottom, keyboardInset) - 10
        composer.frame = CGRect(x: 10, y: bottom - composerHeight, width: width - 20, height: composerHeight)
        let rowsHeight = rowOrder.isEmpty ? 0 : rows.systemLayoutSizeFitting(
            CGSize(width: width - 8, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        rows.frame = CGRect(x: 0, y: 0, width: width - 8, height: rowsHeight)
        scroll.contentSize = rows.frame.size
        scroll.frame = CGRect(x: 4, y: y, width: width - 8, height: max(0, composer.frame.minY - 6 - y))
        let noticeHeight = notice.sizeThatFits(CGSize(width: width - 40, height: .greatestFiniteMagnitude)).height
        notice.frame = CGRect(x: 20, y: y + 16, width: width - 40, height: noticeHeight)
    }

    @objc private func openLive() { onOpenThread?(liveSession) }

    private func send() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.text = ""
        endEditing(true)
        onStart?(text)
    }
}
#endif
