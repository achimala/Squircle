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
        return view === rootViewController?.view ? nil : view
    }
}

/// A glass overlay over the host app with three rests on one spring:
/// a bubble showing what the agent is doing in this app, a card with the app's
/// threads and a field for a new one, and the full conversation.
@MainActor
final class OverlayController: UIViewController, UIGestureRecognizerDelegate {
    private let model: SquircleModel
    /// 0 bubble, 1 card, 2 full screen.
    private let spring = SpringDriver(value: 0)
    private var level: CGFloat { spring.value.clamped(0, 2) }

    private let surface = Theme.glassSurface(cornerRadius: 22)
    /// Paper under the card's text, so it reads over any app.
    private let veil = UIView()
    private let bubble = LiveCapsule(glass: false)
    private let card = UIView()
    private let grabber = UIView()
    private let nameLabel = Theme.label("", Theme.font(.headline, 17, .semibold))
    private let buildsButton = OverlayController.iconButton("shippingbox", "Builds", "overlay.builds")
    private let expandButton = OverlayController.iconButton("arrow.up.left.and.arrow.down.right", "Full screen", "overlay.expand")
    private let minimizeButton = OverlayController.iconButton("chevron.down", "Minimize", "overlay.minimize")
    private let notice = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel, lines: 3)
    private let live = LiveCapsule(glass: false)
    private let list = UIScrollView()
    private let rows = UIStackView()
    private var rowViews: [String: ThreadRow] = [:]
    private var rowOrder: [String] = []
    private let composer = Composer(placeholder: "New thread")
    /// Clips the full-screen conversation while it grows out of the card.
    private let full = UIView()
    private var studio: StudioViewController?

    /// Bubble center, kept against the side it was left on.
    private var anchor: CGPoint?
    /// Where the card was dragged; nil keeps it beside the bubble.
    private var cardOrigin: CGPoint?
    private var dragStart = CGPoint.zero
    private var levelStart: CGFloat = 0
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

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { level > 1.5 ? .portrait : .all }

    private static func iconButton(_ symbol: String, _ label: String, _ identifier: String) -> UIButton {
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
        view.addSubview(surface)
        full.clipsToBounds = true
        full.layer.cornerCurve = .continuous
        full.isHidden = true
        view.addSubview(full)

        surface.accessibilityIdentifier = "overlay.bubble"
        surface.contentView.clipsToBounds = true
        surface.contentView.layer.cornerCurve = .continuous
        bubble.isUserInteractionEnabled = false
        bubble.showsTime = false
        veil.backgroundColor = Theme.paper.withAlphaComponent(0.72)
        veil.isUserInteractionEnabled = false
        surface.contentView.addSubview(veil)
        surface.contentView.addSubview(bubble)
        surface.contentView.addSubview(card)

        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        nameLabel.lineBreakMode = .byTruncatingTail
        notice.textAlignment = .center
        live.layer.cornerCurve = .continuous
        live.backgroundColor = Theme.pressedFill
        live.accessibilityIdentifier = "overlay.live"
        list.showsVerticalScrollIndicator = false
        list.alwaysBounceVertical = false
        rows.axis = .vertical
        list.addSubview(rows)
        [grabber, nameLabel, buildsButton, expandButton, minimizeButton, notice, live, list, composer].forEach(card.addSubview)

        buildsButton.addAction(UIAction { [weak self] _ in self?.presentBuilds() }, for: .touchUpInside)
        expandButton.addAction(UIAction { [weak self] _ in self?.expand(self?.followedSession) }, for: .touchUpInside)
        minimizeButton.addAction(UIAction { [weak self] _ in self?.settle(to: 0) }, for: .touchUpInside)
        live.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openLive)))
        composer.onSend = { [weak self] in self?.startThread() }
        composer.onChange = { [weak self] in self?.relayout() }

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        surface.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.delegate = self
        surface.addGestureRecognizer(pan)

        spring.onChange = { [weak self] _ in self?.apply() }
        spring.onRest = { [weak self] value in self?.rested(at: value) }
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
        apply()
    }

    // MARK: State

    private var project: AppProject? { model.projects.first }
    private var sessions: [ChatSession] { project.map { model.sessions(for: $0) } ?? [] }
    /// The thread the bubble follows: one waiting on you, else one working.
    private var followedSession: String? {
        let active = sessions.filter { $0.phase != .idle }
        return (active.first { $0.phase == .needsYou } ?? active.first)?.id ?? model.selectedSessionID
    }

    private func render() {
        let sessions = self.sessions
        let active = sessions.filter { $0.phase != .idle }
        let target = active.first { $0.phase == .needsYou } ?? active.first
        // Follow the active thread live, as the conversation does, unless
        // the full conversation is showing another.
        if !starting, studio == nil, let target, model.selectedSessionID != target.id {
            Task { await model.selectSession(target.id) }
        }
        let now = Date.now
        for (id, title) in working where !active.contains(where: { $0.id == id }) {
            finished = ("Done · " + title, now.addingTimeInterval(6))
            pulse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.render() }
        }
        working = Dictionary(uniqueKeysWithValues: active.map { ($0.id, title(of: $0)) })

        var headline: String?, started: Date?, tone = LiveCapsule.Tone.idle
        if let target {
            if target.phase == .needsYou {
                tone = .needsYou; headline = "Needs you · " + title(of: target)
            } else {
                tone = .working
                let status = model.selectedSessionID == target.id ? liveStatus() : nil
                headline = status?.headline ?? title(of: target)
                started = status?.started
            }
        } else if let finished, finished.until > now {
            tone = .done; headline = finished.text
        }
        let bubbleWidth = bubble.bounds.width
        bubble.configure(headline: headline, started: started, tone: tone)
        live.configure(headline: headline, started: started, tone: tone)
        live.isHidden = headline == nil
        surface.accessibilityValue = headline ?? "Idle"

        nameLabel.text = project?.name
        buildsButton.isEnabled = project != nil
        let building = project.map { project in
            model.builds(for: project).contains { $0.status == "queued" || $0.status == "running" }
        } ?? false
        buildsButton.configuration?.baseForegroundColor = building ? Theme.accent : .secondaryLabel
        renderRows(sessions)
        let problem = project == nil && !model.isLoading
            ? (model.error ?? (model.connected ? "Opening this app in T3…" : model.status)) : model.error
        notice.text = problem ?? (sessions.isEmpty ? "No threads yet" : nil)
        notice.textColor = model.error == nil ? .secondaryLabel : Theme.failure
        notice.isHidden = notice.text == nil

        if level < 0.01, bubbleWidth > 0, abs(bubbleSize.width - bubbleWidth) > 0.5, !Motion.reduced {
            UIView.animate(springDuration: 0.5, bounce: 0.15, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) { self.apply() }
        } else {
            relayout()
        }
    }

    private func title(of session: ChatSession) -> String {
        project.map { session.displayTitle(in: $0) } ?? session.title
    }

    private func liveStatus() -> LiveStatus? {
        ThreadItem.items(messages: model.messages, running: model.isRunning).reversed().lazy.compactMap { item -> LiveStatus? in
            if case .live(let status) = item { return status }
            return nil
        }.first
    }

    private func renderRows(_ sessions: [ChatSession]) {
        let shown = Array(sessions.prefix(20))
        let ids = shown.map(\.id)
        for id in Array(rowViews.keys) where !ids.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        for session in shown {
            let row = rowViews[session.id] ?? {
                let row = ThreadRow(sessionID: session.id, compact: true)
                row.addAction(UIAction { [weak self] _ in self?.expand(session.id) }, for: .touchUpInside)
                rowViews[session.id] = row
                return row
            }()
            row.configure(title: title(of: session), agent: model.agentName(for: session.modelSelection),
                          date: session.updatedAt, phase: session.phase)
        }
        guard ids != rowOrder else { return }
        rowOrder = ids
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, id) in ids.enumerated() {
            guard let row = rowViews[id] else { continue }
            row.showsSeparator = index < ids.count - 1
            rows.addArrangedSubview(row)
        }
    }

    // MARK: Geometry

    private var safeBounds: CGRect { view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 10, dy: 6) }

    private var bubbleSize: CGSize {
        CGSize(width: bubble.preferredWidth(limit: min(300, view.bounds.width * 0.72), height: 44), height: 44)
    }

    private var bubbleFrame: CGRect {
        let size = bubbleSize, safe = safeBounds
        var center = anchor ?? CGPoint(x: safe.maxX - size.width / 2, y: safe.maxY - 90)
        center.x = center.x < view.bounds.midX ? safe.minX + size.width / 2 : safe.maxX - size.width / 2
        center.y = center.y.clamped(safe.minY + size.height / 2, max(safe.minY + size.height / 2, safe.maxY - size.height / 2))
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private var cardWidth: CGFloat { min(view.bounds.width - 24, 380) }

    /// Lays out the card's content at its own size; returns its height.
    @discardableResult
    private func layoutCard() -> CGFloat {
        let width = cardWidth
        grabber.frame = CGRect(x: (width - 36) / 2, y: 7, width: 36, height: 5)
        let button: CGFloat = 38
        minimizeButton.frame = CGRect(x: width - 8 - button, y: 13, width: button, height: button)
        expandButton.frame = minimizeButton.frame.offsetBy(dx: -button, dy: 0)
        buildsButton.frame = expandButton.frame.offsetBy(dx: -button, dy: 0)
        nameLabel.frame = CGRect(x: 20, y: 18, width: buildsButton.frame.minX - 24, height: 28)
        var y: CGFloat = 58
        if !live.isHidden {
            live.frame = CGRect(x: 12, y: y, width: width - 24, height: 44)
            live.layer.cornerRadius = 22
            y += 52
        }
        let rowsHeight = rowOrder.isEmpty ? 0 : rows.systemLayoutSizeFitting(
            CGSize(width: width - 8, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        rows.frame = CGRect(x: 0, y: 0, width: width - 8, height: rowsHeight)
        list.contentSize = rows.frame.size
        let visible = min(rowsHeight, 4.5 * 54)
        list.frame = CGRect(x: 4, y: y, width: width - 8, height: visible)
        y += visible
        if !notice.isHidden {
            let height = notice.sizeThatFits(CGSize(width: width - 40, height: .greatestFiniteMagnitude)).height
            notice.frame = CGRect(x: 20, y: y + 8, width: width - 40, height: height)
            y += height + 16
        }
        let composerHeight = composer.systemLayoutSizeFitting(CGSize(width: width - 20, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        composer.frame = CGRect(x: 10, y: y + 6, width: width - 20, height: max(48, composerHeight))
        y = composer.frame.maxY + 10
        card.frame = CGRect(x: 0, y: 0, width: width, height: y)
        return y
    }

    private var cardFrame: CGRect {
        let size = CGSize(width: cardWidth, height: card.bounds.height)
        let safe = safeBounds
        let bubble = bubbleFrame
        var origin = cardOrigin ?? CGPoint(x: bubble.midX < view.bounds.midX ? safe.minX : safe.maxX - size.width,
                                           y: bubble.maxY - size.height)
        let bottom = min(safe.maxY, keyboardTop - 8)
        origin.x = origin.x.clamped(safe.minX, max(safe.minX, safe.maxX - size.width))
        origin.y = origin.y.clamped(safe.minY, max(safe.minY, bottom - size.height))
        return CGRect(origin: origin, size: size)
    }

    private func relayout() {
        layoutCard()
        apply()
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: .lerp(a.minX, b.minX, t), y: .lerp(a.minY, b.minY, t),
               width: .lerp(a.width, b.width, t), height: .lerp(a.height, b.height, t))
    }

    /// Places everything for the spring's current value.
    private func apply() {
        guard view.bounds.width > 0 else { return }
        if card.bounds.width != cardWidth { layoutCard() }
        let level = self.level
        let bubbleFrame = self.bubbleFrame, cardFrame = self.cardFrame
        let frame = level <= 1 ? lerp(bubbleFrame, cardFrame, level) : lerp(cardFrame, view.bounds, level - 1)
        let radius = level <= 1 ? CGFloat.lerp(bubbleFrame.height / 2, 30, level) : .lerp(30, 0, level - 1)
        surface.frame = frame
        Theme.setGlassCorner(surface, radius: radius)
        surface.contentView.layer.cornerRadius = radius
        bubble.frame = CGRect(origin: .zero, size: bubbleFrame.size)
        veil.frame = CGRect(origin: .zero, size: frame.size)
        veil.alpha = (level * 1.6).clamped()
        bubble.alpha = (1 - level * 4).clamped()
        card.alpha = level <= 1 ? ((level - 0.35) / 0.5).clamped() : (1 - (level - 1) * 3).clamped()
        card.isUserInteractionEnabled = level > 0.9 && level < 1.1
        full.isHidden = level <= 1.001 || studio == nil
        full.frame = frame
        full.layer.cornerRadius = radius
        full.alpha = ((level - 1.1) / 0.4).clamped()
        studio?.view.frame = CGRect(origin: CGPoint(x: -frame.minX, y: -frame.minY), size: view.bounds.size)
    }

    // MARK: Gestures

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture is UITapGestureRecognizer { return level < 0.5 }
        // The card moves by its top bar; the bubble by any part.
        return level < 0.5 || (abs(level - 1) < 0.1 && gesture.location(in: card).y < 56)
    }

    @objc private func tapped() {
        Theme.openHaptic()
        layoutCard()
        settle(to: 1)
    }

    @objc private func openLive() { expand(followedSession) }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let onCard = level > 0.5
        switch gesture.state {
        case .began:
            dragStart = onCard ? cardFrame.origin : bubbleFrame.center
        case .changed:
            let t = gesture.translation(in: view)
            if onCard { cardOrigin = CGPoint(x: dragStart.x + t.x, y: dragStart.y + t.y) }
            else { anchor = CGPoint(x: dragStart.x + t.x, y: dragStart.y + t.y) }
            if onCard { apply() } else { surface.center = CGPoint(x: dragStart.x + t.x, y: dragStart.y + t.y) }
        case .ended, .cancelled:
            let v = gesture.velocity(in: view)
            if onCard {
                cardOrigin = CGPoint(x: dragStart.x + gesture.translation(in: view).x + v.x * 0.1,
                                     y: dragStart.y + gesture.translation(in: view).y + v.y * 0.1)
            } else {
                anchor = CGPoint(x: surface.center.x + v.x * 0.15, y: surface.center.y + v.y * 0.15)
            }
            UIView.animate(springDuration: 0.45, bounce: 0.18, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) { self.apply() }
        default: break
        }
    }

    /// The left-edge swipe out of the conversation shrinks it into the card,
    /// following the finger.
    private func backDrag(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        switch gesture.state {
        case .began:
            levelStart = spring.value
            spring.stop()
        case .changed:
            spring.set((levelStart - gesture.translation(in: view).x / width).clamped(1, 2))
        case .ended, .cancelled, .failed:
            let velocity = -gesture.velocity(in: view).x / width
            let closing = gesture.state == .ended && spring.value + velocity * 0.18 < 1.6
            if closing { view.endEditing(true) }
            spring.animate(to: closing ? 1 : 2, initialVelocity: velocity)
        default: break
        }
    }

    // MARK: Moves

    private func settle(to target: CGFloat) {
        if target < 1 { view.endEditing(true) }
        if target > 0, previousKey == nil, let window = view.window, !window.isKeyWindow {
            previousKey = window.windowScene?.keyWindow
            window.makeKey()
        }
        spring.animate(to: target)
    }

    private func rested(at value: CGFloat) {
        if value <= 1.001, let studio {
            studio.tearDown()
            studio.willMove(toParent: nil)
            studio.view.removeFromSuperview()
            studio.removeFromParent()
            self.studio = nil
            render()
        }
        if value <= 0.001 {
            previousKey?.makeKey()
            previousKey = nil
        }
        apply()
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// The conversation grows out of the card to fill the screen.
    private func expand(_ sessionID: String?) {
        guard project != nil else { return }
        Theme.openHaptic()
        view.endEditing(true)
        if studio == nil {
            let studio = StudioViewController(model: model)
            studio.onClose = { [weak self] in self?.settle(to: 1) }
            studio.onBackDrag = { [weak self] gesture in self?.backDrag(gesture) }
            addChild(studio)
            studio.view.frame = view.bounds
            full.addSubview(studio.view)
            studio.didMove(toParent: self)
            studio.presentThread(sessionID)
            self.studio = studio
        }
        settle(to: 2)
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func startThread() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let project else { return }
        composer.text = ""
        view.endEditing(true)
        starting = true
        Task {
            await model.beginDraft()
            await model.send(text, in: project)
            starting = false
            render()
        }
    }

    private func presentBuilds() {
        guard let project, presentedViewController == nil else { return }
        Theme.selectionHaptic()
        let controller = BuildsViewController(model: model, project: project)
        controller.onNewThread = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.expand(nil) }
        }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }

    /// A soft beat when a turn finishes.
    private func pulse() {
        guard !Motion.reduced else { return }
        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1, 1.08, 1]
        beat.keyTimes = [0, 0.35, 1]
        beat.duration = 0.6
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        surface.layer.add(beat, forKey: "pulse")
    }

    private func keyboardMoved(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = view.convert(end, from: nil)
        keyboardTop = frame.minY >= view.bounds.maxY - 1 ? .greatestFiniteMagnitude : frame.minY
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) { self.apply() }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
