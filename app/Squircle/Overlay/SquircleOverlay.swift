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
        // The host app's lifecycle is the overlay's: hold T3's socket in the
        // background, reconnect on return.
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OverlayHost.shared.model?.enteredBackground() }
        })
        observers.append(center.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OverlayHost.shared.model?.enteringForeground() }
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
        // Every touch on the screen asks this window first: the jelly
        // glances at it, in the app or on itself.
        if event?.type == .touches { (rootViewController as? OverlayController)?.noticed(point) }
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
/// The glass's frame is one spring (`FrameSpring`). The bubble's line and the
/// conversation live inside the glass, each laid out at its resting size and
/// stretched to the glass's presented frame on every frame, so nothing can
/// drift from the shape and nothing is cut by its edge. Between shapes the
/// outgoing content blurs and fades out as the incoming one sharpens in. A
/// finger takes the spring over (drag, back swipe) and hands it back with its
/// velocity.
@MainActor
final class OverlayController: UIViewController, UIGestureRecognizerDelegate {
    private let model: SquircleModel
    /// Simulator streams for the turns' live simulators.
    private lazy var feeds = SimulatorFeeds(model: model)
    private var route = OverlayRoute()

    /// The bubble and the panel: one piece of glass jelly.
    private let glass = GlassJelly()
    private let frame = FrameSpring()
    /// 0 → 1 once, when the bubble first appears: it grows and fades in
    /// where it rests. Until the first real layout it has no place at all,
    /// so the spring never starts from a made-up frame.
    private let appear = SpringDriver()
    private var placed = false
    /// 0 = the agent, 1 = a thread over it.
    private let push = SpringDriver()
    /// The one inset between the screen's safe area and the glass, and
    /// between the glass and what it holds, on every side.
    private static let inset: CGFloat = 12
    /// Concentric with the 44-point controls at `inset`.
    private static let panelRadius: CGFloat = 22 + inset
    /// Stretched with the glass; holds the bubble's line at its own size.
    private let bubbleStage = UIView()
    private let bubble = LiveCapsule()
    /// Stretched with the glass; `body` is laid out at `panelSize`.
    private let page = UIView()
    private let body = UIView()
    /// The size the panel's content is laid out at: where it rests (mini or
    /// full), kept while it closes into the bubble.
    private var panelSize = CGSize.zero
    /// A picture of the content at its previous size, stretched with the
    /// glass and blurring out while the content at the new size blurs in.
    private var outgoing: (view: UIView, size: CGSize)?
    /// The panel's grab handle: drag it to resize the panel, up to full
    /// screen or down into the bubble.
    private let handle = UIView()
    private var handlePan: UIPanGestureRecognizer!
    /// The docked panel's height, once the handle has set it.
    private var miniHeight: CGFloat?
    /// While the handle resizes the docked panel (and until it rests): the
    /// conversation is laid out once at this size and pinned to the glass's
    /// bottom edge, which reveals it. Nothing re-lays out per frame.
    private var clipLayout: CGSize?
    /// Docked ↔ full screen (and back): the content is laid out at the
    /// glass's own frame every frame, with the safe area that frame covers,
    /// until the spring rests. Its text column keeps the docked width
    /// (`contentWidth`), so nothing re-wraps; the controls, the field and the
    /// fade move to where they are at the other end.
    private var liveLayout = false
    /// The panel's laid-out safe area (the part of the screen's it covers).
    private var panelSafe = UIEdgeInsets.zero
    /// Where along the handle's path the finger is.
    private enum DragZone { case docked, full, collapse }
    private var dragZone: DragZone?
    private var dragSlop: CGFloat = 0

    private typealias Mounted = (controller: ThreadViewController, host: UIView)
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
    private var bubblePress: UILongPressGestureRecognizer!
    /// A long press captures the app: the screen flashes, and its picture
    /// shrinks from full screen into its slot in the message field as the
    /// panel opens. `flight` runs 0 (full screen) → 1 (in the slot).
    private let flight = SpringDriver()
    /// The flying picture, in a shadow that lifts it off the screen it shows.
    private var flyer: (lift: UIView, picture: UIImageView)?
    private let flash = UIView()
    private let flashFade = SpringDriver()
    private let shutter = UIImpactFeedbackGenerator(style: .rigid)
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
        view.addSubview(glass)
        bubble.isUserInteractionEnabled = false
        bubble.showsTime = false
        bubble.onHeadlineChange = { [weak self] in self?.retarget() }
        // The jelly's eyes sit where the mark was; its colour is the tone.
        bubble.markSlot = 22
        bubble.tintsText = false
        bubble.textColor = .label.withAlphaComponent(0.75)
        bubble.onLineChange = { [weak self] in self?.glass.gulp() }
        bubble.onHeadlineChange = { [weak self] in self?.retarget() }
        bubble.isAccessibilityElement = true
        bubble.accessibilityTraits = .button
        bubble.accessibilityLabel = "Squircle"
        bubbleStage.isUserInteractionEnabled = false
        bubbleStage.addSubview(bubble)
        glass.content.addSubview(bubbleStage)
        let pill = UIView()
        pill.backgroundColor = .tertiaryLabel
        pill.layer.cornerRadius = 2.5
        pill.isUserInteractionEnabled = false
        // The jelly's eyes are where you grab it; no pill.
        pill.isHidden = true
        handle.addSubview(pill)
        handle.isAccessibilityElement = true
        handle.accessibilityTraits = .adjustable
        handle.accessibilityLabel = "Resize"
        handle.accessibilityIdentifier = "overlay.handle"
        body.addSubview(handle)
        page.addSubview(body)
        glass.content.addSubview(page)

        bubbleTap = UITapGestureRecognizer(target: self, action: #selector(openTapped))
        bubblePan = UIPanGestureRecognizer(target: self, action: #selector(glassDragged(_:)))
        movePan = UIPanGestureRecognizer(target: self, action: #selector(glassDragged(_:)))
        backPan = UIPanGestureRecognizer(target: self, action: #selector(backDragged(_:)))
        bubblePress = UILongPressGestureRecognizer(target: self, action: #selector(bubblePressed(_:)))
        bubblePress.minimumPressDuration = 0.35
        // A tap waits only for the finger to lift before the press fails.
        bubbleTap.require(toFail: bubblePress)
        for gesture in [bubbleTap, bubblePress, bubblePan, movePan, backPan] as [UIGestureRecognizer] {
            gesture.delegate = self
            glass.addGestureRecognizer(gesture)
        }
        flash.backgroundColor = .white
        flash.alpha = 0
        flash.isUserInteractionEnabled = false
        // Springy: quick out of the screen, a little overshoot into the
        // slot, no slow crawl at the end. The flash is a soft, short fade.
        flight.parameters = SpringDriver.Parameters(response: 0.5, damping: 0.72)
        flashFade.parameters = SpringDriver.Parameters(response: 0.2, damping: 1)
        flashFade.onChange = { [weak self] value in self?.flash.alpha = 0.4 * value.clamped() }
        flashFade.onRest = { [weak self] _ in self?.flash.removeFromSuperview() }
        flight.onChange = { [weak self] _ in self?.applyFlight() }
        flight.onRest = { [weak self] _ in self?.landed() }
        handlePan = UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:)))
        handlePan.delegate = self
        handle.addGestureRecognizer(handlePan)
        handle.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTapped)))

        frame.onChange = { [weak self] in self?.applyScene() }
        appear.parameters = SpringDriver.Parameters(response: 0.5, damping: 0.68)
        appear.onChange = { [weak self] _ in self?.applyScene() }
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
        guard view.bounds.width > 0, view.window != nil else { return }
        // Rotation or a first layout: rest exactly where the route says.
        if !placed || (!frame.isAnimating && !frame.isHeld) { frame.set(targetFrame) } else { applyScene() }
        if !placed {
            placed = true
            appear.animate(to: 1)
        }
    }

    // MARK: Model

    private var project: AppProject? { model.projects.first }

    private func render() {
        #if DEBUG
        if let demo = demoStatus, project == nil {
            bubble.configure(headline: demo.headline, started: nil, tone: demo.tone)
            retarget()
            return
        }
        #endif
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
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6.1))
                self?.render()
            }
        }
        working = Dictionary(active.map { ($0.id, title($0)) }, uniquingKeysWith: { a, _ in a })

        // What the bubble says: whoever needs you, else what the agent is
        // doing (its live step), else a working thread.
        var headline: String?, tone: LiveCapsule.Tone, started: Date?
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
        #if DEBUG
        if let demo = demoStatus { (headline, tone, started) = (demo.headline, demo.tone, nil) }
        #endif
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

    private var safeBounds: CGRect { view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: Self.inset, dy: Self.inset) }

    private var bubbleSize: CGSize {
        let limit = min(300, view.bounds.width * 0.72)
        bubble.widthLimit = limit
        return CGSize(width: bubble.preferredWidth(limit: limit, height: 44), height: 44)
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
        let height = (miniHeight ?? min(safe.height * 0.66, 600)).clamped(Self.minimumHeight, safe.height)
        let size = CGSize(width: min(safe.width, 390), height: height)
        var y = lower ? bubble.maxY - size.height : bubble.minY
        y = y.clamped(safe.minY, max(safe.minY, min(safe.maxY, keyboardTop - 8) - size.height))
        return CGRect(x: bubble.midX > view.bounds.midX ? safe.maxX - size.width : safe.minX, y: y,
                      width: size.width, height: size.height)
    }

    private var targetFrame: CGRect { !route.open ? bubbleFrame : route.full ? view.bounds : miniFrame }

    /// Shorter than this, a released handle closes the panel.
    private static let minimumHeight: CGFloat = 180

    /// Sends the glass toward wherever the route and anchor now put it.
    private func retarget(velocity: CGPoint? = nil, sizeVelocity: CGSize = .zero) {
        guard view.bounds.width > 0 else { return }
        // A finger on the handle sets the content up itself.
        if !route.open { liveLayout = false }
        if clipLayout == nil, dragZone == nil, route.open || panelSize == .zero {
            let size = route.open && route.full ? view.bounds.size : miniFrame.size
            // The panel showing in full moves to the other panel size live;
            // only content arriving from the bubble cross-blurs.
            let shown = panelSize != .zero && page.alpha > 0.98 && !page.isHidden && outgoing == nil && view.window != nil
            if route.open, shown, size != panelSize { liveLayout = true }
            if !liveLayout { layOutPanel(at: size) }
        }
        // Before its first layout it has no place to move from.
        guard !frame.isHeld, placed else { return }
        let target = targetFrame
        if frame.target != target || velocity != nil { frame.animate(to: target, velocity: velocity, sizeVelocity: sizeVelocity) }
    }

    /// The part of the screen's safe-area insets a panel at `rect` covers.
    private func safeArea(in rect: CGRect) -> UIEdgeInsets {
        let bounds = view.bounds, safe = view.safeAreaInsets
        return UIEdgeInsets(top: max(0, bounds.minY + safe.top - rect.minY), left: max(0, bounds.minX + safe.left - rect.minX),
                            bottom: max(0, rect.maxY - (bounds.maxY - safe.bottom)), right: max(0, rect.maxX - (bounds.maxX - safe.right)))
    }

    /// Lays the panel's content out at a new resting size. If it shows (and
    /// `crossBlur`), a picture of how it was blurs out as the glass stretches.
    private func layOutPanel(at size: CGSize, crossBlur: Bool = true, safe given: UIEdgeInsets? = nil) {
        let safe = given ?? (size == view.bounds.size ? view.safeAreaInsets : .zero)
        guard size != panelSize || safe != panelSafe, size.width > 0 else { return }
        outgoing?.view.removeFromSuperview()
        outgoing = nil
        let showing = crossBlur && panelSize != .zero && page.alpha > 0.02 && !page.isHidden && view.window != nil
        // Cells laid out this moment haven't laid their own contents out
        // yet (labels with no width); finish that before drawing.
        if showing { keepPicture() }
        panelSize = size
        page.transform = .identity
        page.bounds = CGRect(origin: .zero, size: size)
        body.frame = page.bounds
        panelSafe = safe
        // At the top centre, level with the ⋯ button; the strip it grabs runs
        // from the panel's edge to below the buttons.
        handle.frame = CGRect(x: size.width / 2 - 60, y: safe.top, width: 120, height: Self.inset + 44)
        handle.subviews.first?.frame = CGRect(x: 42, y: 7, width: 36, height: 5)
        for mounted in [agent, thread].compactMap({ $0 }) {
            mounted.controller.setOverlayLayout(inset: Self.inset, safe: safe, contentWidth: contentWidth)
            place(mounted, offset: 0)
            mounted.controller.view.layoutIfNeeded()
        }
    }

    /// Keeps a picture of the panel as it shows now, for the morph to blur
    /// out. It copies the glass as drawn on screen: inside the glass, gray
    /// labels and fills are vibrant, which only the render server draws, so
    /// any picture of the content alone loses them.
    private func keepPicture() {
        guard let picture = glass.snapshotView(afterScreenUpdates: false) else { return }
        let size = glass.bounds.size
        let stage = UIView()
        stage.isUserInteractionEnabled = false
        stage.clipsToBounds = true
        stage.backgroundColor = page.backgroundColor
        stage.bounds = CGRect(origin: .zero, size: size)
        picture.frame = stage.bounds
        stage.addSubview(picture)
        glass.content.insertSubview(stage, belowSubview: page)
        outgoing = (stage, size)
    }

    /// How far a size has come from `from` toward `to` (1 there, beyond 1
    /// past it), by whichever of width and height changes.
    private static func progress(_ size: CGSize, from: CGSize, to: CGSize) -> CGFloat {
        var sum: CGFloat = 0, count: CGFloat = 0
        for (value, a, b) in [(size.width, from.width, to.width), (size.height, from.height, to.height)] where abs(b - a) > 1 {
            sum += (value - a) / (b - a)
            count += 1
        }
        return count == 0 ? 1 : sum / count
    }

    // MARK: Scene

    /// Every frame, from the glass's presented frame and the push alone.
    private func applyScene() {
        guard view.bounds.width > 0, panelSize.width > 0 else { return }
        let rect = frame.value
        let bounds = view.bounds, bubbleSize = self.bubbleSize
        let local = CGRect(origin: .zero, size: rect.size)
        // 0 at the bubble's height, 1 at the smallest panel in play; by
        // height alone, so the bubble's own width springing as its text
        // changes never reads as opening. 0…1 mini → full.
        let openHeight = min(panelSize.height, outgoing?.size.height ?? .greatestFiniteMagnitude)
        let opened = clipLayout != nil ? 1 : ((rect.height - bubbleSize.height) / max(1, openHeight - bubbleSize.height)).clamped()
        let fullness = ((rect.height - miniFrame.height) / max(1, bounds.height - miniFrame.height)).clamped()
        // Appearing, it grows in place from its own centre.
        let appeared = appear.value
        glass.transform = .identity
        glass.frame = rect
        if liveLayout, route.open { layOutPanel(at: rect.size, crossBlur: false, safe: safeArea(in: rect)) }
        if appeared != 1 {
            let scale = CGFloat.lerp(0.5, 1, appeared)
            glass.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        glass.alpha = (appeared * 1.6).clamped()
        // Full screen, its corners follow the display's.
        glass.cornerRadius = min(rect.height / 2, rect.width / 2, .lerp(Self.panelRadius, 54, fullness))
        glass.opened = opened
        glass.fill = Theme.paper
        // Clear enough as a bubble to be glass, paper as a panel so text reads.
        glass.fillAmount = .lerp(0.55, .lerp(0.9, 0.97, fullness), opened)
        glass.tone = bubble.tone
        glass.typing = route.open && keyboardTop < view.bounds.maxY
        // Eyes: beside the bubble's line; open, peeking just under the
        // panel's top rim, above its buttons and text (where you grab it).
        let w = rect.width
        glass.bubbleEye = CGPoint(x: w <= bubbleSize.height + 0.5 ? w / 2 : .lerp(w / 2, 20, ((w - 44) / 20).clamped()), y: rect.height / 2)
        glass.panelEye = CGPoint(x: w / 2, y: panelSafe.top + 11)

        // Each content is stretched to the glass: the bubble's line from its
        // own size (laid out at the glass's width while it is just a bubble),
        // the conversation from where it rests.
        let lineWidth = CGFloat.lerp(rect.width, bubbleSize.width, (opened * 10).clamped())
        stretch(bubbleStage, from: CGSize(width: lineWidth, height: bubbleSize.height), into: local)
        if bubble.frame.size != bubbleStage.bounds.size { bubble.frame = bubbleStage.bounds }
        // The line leaves in the first fifth of the opening, before the
        // stretch shows on it.
        bubbleStage.alpha = (1 - opened * 5).clamped()
        if let clip = clipLayout {
            // Revealed from the bottom by the glass, at its laid-out size.
            page.transform = .identity
            if page.bounds.size != clip { page.bounds = CGRect(origin: .zero, size: clip) }
            page.center = CGPoint(x: local.midX, y: local.maxY - clip.height / 2)
            revealTop(max(0, clip.height - rect.height))
        } else {
            stretch(page, from: panelSize, into: local)
            revealTop(0)
        }
        // Mini ↔ full: the content at its old size blurs out as the new one comes in.
        // The conversation arrives in the last 60%, nearly at its own shape.
        var shown = ((opened - 0.4) / 0.6).clamped(), blur: CGFloat = 24
        if let outgoing {
            let arrived = Self.progress(rect.size, from: outgoing.size, to: panelSize).clamped()
            shown *= arrived
            // Blur as much as the sizes differ, enough to hide the two
            // layouts' lines crossing.
            let change = max(abs(outgoing.size.width - panelSize.width), abs(outgoing.size.height - panelSize.height))
            blur = 10 + 14 * (change / 500).clamped()
            stretch(outgoing.view, from: outgoing.size, into: local)
            crossBlur(outgoing.view, visibility: Self.progress(rect.size, from: bubbleSize, to: outgoing.size).clamped() * (1 - arrived),
                      sharpAt: 0.5, blur: 0)
        }
        // The jelly is the paper, so the content only fades (a blur would turn
        // its clear areas black).
        _ = blur
        crossBlur(page, visibility: shown, sharpAt: outgoing == nil ? 0.85 : 0.5, blur: 0)
        page.isHidden = page.alpha == 0 && !route.open
        // Paper under the conversation, so it reads over any app. It is the
        // blurred layer's own background: the blur renders clear areas black.
        let paper = Theme.paper.withAlphaComponent(.lerp(0.93, 1, fullness))
        page.backgroundColor = .clear
        outgoing?.view.backgroundColor = .clear
        body.bringSubviewToFront(handle)
        handle.accessibilityValue = route.full ? "Full screen" : "Small"

        // Flat push: a thread slides in on its own paper over the agent, which
        // drifts a third as far left and fades out first, so text never sits
        // over text.
        let t = push.value.clamped(), width = body.bounds.width
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

    /// The top `y` points of the panel's content are above the glass: the
    /// handle and the conversations' top controls ride the visible edge.
    private func revealTop(_ y: CGFloat) {
        handle.frame.origin.y = y + panelSafe.top
        agent?.controller.setVisibleTop(y)
        thread?.controller.setVisibleTop(y)
    }

    /// Lays a view out at `size` and scales it to fill `rect`.
    private func stretch(_ view: UIView, from size: CGSize, into rect: CGRect) {
        if view.bounds.size != size {
            view.transform = .identity
            view.bounds = CGRect(origin: .zero, size: size)
        }
        view.center = CGPoint(x: rect.midX, y: rect.midY)
        view.transform = CGAffineTransform(scaleX: rect.width / max(1, size.width), y: rect.height / max(1, size.height))
    }

    /// Sharp and opaque from `sharpAt` up; below it blurs (up to `blur`
    /// points) and fades, gone at 0.
    private func crossBlur(_ view: UIView, visibility: CGFloat, sharpAt: CGFloat = 0.85, blur: CGFloat = 24) {
        let v = (visibility / sharpAt).clamped()
        view.alpha = (v * v * (3 - 2 * v))
        Self.blur(view.layer, radius: (1 - v) * blur)
    }

    /// Core Animation's Gaussian blur on a layer, by radius. Private, as
    /// UIKit has no public variable blur on arbitrary views; this code exists
    /// only in the debug overlay and Debug builds.
    private static func blur(_ layer: CALayer, radius: CGFloat) {
        guard radius > 0.3 else {
            if layer.filters != nil { layer.filters = nil }
            return
        }
        if layer.filters == nil {
            guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
                  let filter = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                    .takeUnretainedValue() as? NSObject else { return }
            filter.setValue(true, forKey: "inputNormalizeEdges")
            layer.filters = [filter]
        }
        layer.setValue(radius, forKeyPath: "filters.gaussianBlur.inputRadius")
    }

    private func place(_ mounted: Mounted, offset: CGFloat) {
        let bounds = body.bounds
        if mounted.host.bounds.size != bounds.size {
            mounted.host.transform = .identity
            mounted.host.frame = bounds
            mounted.controller.view.frame = bounds
        }
        mounted.host.transform = CGAffineTransform(translationX: offset, y: 0)
    }

    private func rested() {
        if !frame.isAnimating, !frame.isHeld, liveLayout {
            liveLayout = false
            layOutPanel(at: frame.value.size, crossBlur: false)
            applyScene()
        }
        if !frame.isAnimating, !frame.isHeld, clipLayout != nil {
            // At rest: laid out at its own size once. The conversation keeps
            // its newest line where it was, so nothing moves.
            clipLayout = nil
            layOutPanel(at: frame.value.size, crossBlur: false)
            applyScene()
        }
        if !frame.isAnimating, let stage = outgoing?.view {
            outgoing = nil
            stage.removeFromSuperview()
        }
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
        makeKey()
        route.open = true
        sync()
    }

    /// Captures the app under the overlay and opens with it in the field:
    /// a flash, then the picture flies from full screen into its slot.
    private func captureAndOpen() {
        guard !route.open, project != nil, let window = view.window,
              let image = HostCapture.image(below: window),
              let attachment = ImageAttachment(image, id: HostCapture.attachmentID) else { return open() }
        shutter.impactOccurred(intensity: 1)
        flyer?.lift.removeFromSuperview()
        let lift = UIView(), picture = UIImageView(image: image)
        lift.isUserInteractionEnabled = false
        lift.layer.shadowColor = UIColor.black.cgColor
        lift.layer.shadowOffset = CGSize(width: 0, height: 6)
        lift.layer.shadowRadius = 18
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerCurve = .continuous
        picture.layer.borderColor = UIColor.separator.cgColor
        lift.addSubview(picture)
        view.addSubview(lift)
        flash.frame = view.bounds
        view.addSubview(flash)
        flyer = (lift, picture)
        activeController?.holdAttachment(HostCapture.attachmentID)
        model.attach(attachment)
        route.open = true
        makeKey()
        sync()
        flashFade.set(1)
        flashFade.animate(to: 0)
        flight.set(0)
        flight.animate(to: 1)
    }

    /// The conversation on top: the field the capture lands in.
    private var activeController: ThreadViewController? {
        route.thread != nil && route.thread == threadKey ? thread?.controller ?? agent?.controller : agent?.controller
    }

    /// Every frame of the flight, toward wherever the slot is now (the
    /// panel is opening around it); into the bubble if the panel closed.
    private func applyFlight() {
        guard let (lift, picture) = flyer else { return }
        let t = flight.value
        let target = route.open ? activeController?.attachmentFrame(HostCapture.attachmentID, in: view) ?? bubbleFrame : frame.value
        let start = view.bounds
        lift.frame = CGRect(x: .lerp(start.minX, target.minX, t), y: .lerp(start.minY, target.minY, t),
                            width: .lerp(start.width, target.width, t), height: .lerp(start.height, target.height, t))
        picture.frame = lift.bounds
        // Full screen it hides under the display's own corners.
        let radius = CGFloat.lerp(44, 12, t.clamped())
        picture.layer.cornerRadius = radius
        picture.layer.borderWidth = 1
        lift.layer.shadowPath = UIBezierPath(roundedRect: lift.bounds, cornerRadius: radius).cgPath
        // Lifted as it leaves the screen, settled as it lands.
        lift.layer.shadowOpacity = Float(0.28 * min((t / 0.15).clamped(), ((1 - t) / 0.3).clamped()))
        lift.alpha = route.open ? 1 : (1 - t).clamped()
        view.bringSubviewToFront(lift)
        view.bringSubviewToFront(flash)
        // In its slot and all but still: the thumbnail takes over now,
        // not when the spring's last tremor dies.
        if route.open, abs(1 - t) < 0.01, abs(flight.velocity) < 0.3 {
            flight.stop()
            landed()
        }
    }

    private func landed() {
        flyer?.lift.removeFromSuperview()
        flyer = nil
        agent?.controller.holdAttachment(nil)
        thread?.controller.holdAttachment(nil)
    }

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
        let controller = ThreadViewController(model: model, project: project, sessionID: model.agentThreadID(for: project), agent: true)
        controller.compactControls = true
        controller.setBackButton(symbol: "chevron.down", label: "Minimize")
        controller.onBack = { [weak self] in self?.close() }
        controller.onOpenThread = { [weak self] id in self?.openThread(id) }
        controller.onThreads = { [weak self] in self?.presentThreads() }
        controller.onBuilds = { [weak self] in self?.presentBuilds() }
        agent = host(controller)
    }

    private func mountThread(_ key: String) {
        guard let project else { return }
        agent?.controller.deactivate()
        let controller = ThreadViewController(model: model, project: project, sessionID: key.hasPrefix("draft:") ? nil : key)
        controller.onBack = { [weak self] in self?.closeThread() }
        thread = host(controller)
        threadKey = key
    }

    private func unmountThread() {
        guard let mounted = thread else { return }
        thread = nil
        threadKey = nil
        mounted.controller.tearDown()
        mounted.controller.willMove(toParent: nil)
        mounted.host.removeFromSuperview()
        mounted.controller.removeFromParent()
        agent?.controller.reactivate()
    }

    /// A conversation; a simulator the agent uses shows in its turn (you are
    /// already in the app, so no picture-in-picture).
    private func host(_ controller: ThreadViewController) -> Mounted {
        controller.feeds = feeds
        controller.onToggleFull = { [weak self] in self?.toggleFull() }
        controller.isFull = { [weak self] in self?.route.full ?? false }
        let host = UIView()
        host.clipsToBounds = true
        addChild(controller)
        host.addSubview(controller.view)
        body.insertSubview(host, belowSubview: handle)
        controller.didMove(toParent: self)
        let mounted = (controller, host)
        controller.setOverlayLayout(inset: Self.inset, safe: panelSafe, contentWidth: contentWidth)
        // The system's scroll-edge blur can't draw inside the blurred,
        // stretched layers of the morph, so it would pop in at rest; the
        // overlay always fades the conversation under its controls instead.
        controller.setEdgeEffectsHidden(true)
        host.frame = body.bounds
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
        if gesture === bubbleTap || gesture === bubblePan || gesture === bubblePress { return !route.open }
        // Where the finger went down, not where it is once the pan is
        // recognized: a quick drag has already left the strip by then.
        var point = gesture.location(in: body)
        if let pan = gesture as? UIPanGestureRecognizer {
            let moved = pan.translation(in: body)
            point = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
        }
        if gesture === backPan {
            let velocity = backPan.velocity(in: body)
            return route.open && thread != nil && point.x < 28 && velocity.x > abs(velocity.y)
        }
        if gesture === movePan {
            // Move the mini panel by its top, beside the handle and clear of
            // the buttons.
            let inset = Self.inset
            return route.open && !route.full && point.y < inset + 48 && point.x > inset + 48 && point.x < body.bounds.width - inset - 48
                && !handle.frame.contains(point)
        }
        if gesture === handlePan { return route.open }
        return true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    @objc private func openTapped() { open() }

    @objc private func bubblePressed(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { captureAndOpen() }
    }

    @objc private func handleTapped() { toggleFull() }

    /// The finger moves the panel's top edge along one path. Docked, only
    /// the top moves, revealing the conversation from the bottom. Above the
    /// tallest docked panel it morphs (stretch and cross blur, as the spring
    /// does) toward full screen; shorter than `minimumHeight` it morphs
    /// toward the bubble. Let go, the spring carries on from there with the
    /// finger's speed, or back.
    @objc private func handleDragged(_ gesture: UIPanGestureRecognizer) {
        // From where the pan is recognized: its first translation includes
        // the system's slop, which would make the edge skip.
        let dy = gesture.translation(in: view).y - dragSlop
        switch gesture.state {
        case .began:
            dragSlop = gesture.translation(in: view).y
            dragStart = frame.value
            frame.hold(dragStart)
            dragZone = nil
            follow(top: dragStart.minY)
            return
        case .changed:
            follow(top: dragStart.minY + dy)
        case .ended, .cancelled, .failed:
            let vy = gesture.velocity(in: view).y
            let top = dragStart.minY + dy + vy * 0.15
            let tall = tallestDocked
            frame.release()
            if top < tall.minY - 0.4 * (tall.minY - view.bounds.minY) {
                enter(.full)
                route.full = true
            } else if top > collapseTop + 0.4 * (Self.minimumHeight - bubbleSize.height) {
                enter(.collapse)
                route.full = false
                close()
            } else if top < tall.minY {
                // Most of the way back from full: the tallest docked panel.
                enter(.full)
                route.full = false
                miniHeight = tall.height
            } else if top > collapseTop {
                enter(.collapse)
                route.full = false
            } else {
                route.full = false
                miniHeight = tall.maxY - top
                // Docked under the bubble, the panel's top is the bubble's.
                if !lower { anchor = (anchor?.right ?? true, top + bubbleSize.height / 2) }
            }
            // Revealed from the bottom while only the height changes; a
            // change of width (to or from full screen) is laid out live.
            if clipLayout != nil, route.open, abs(targetFrame.width - frame.value.width) > 0.5 {
                clipLayout = nil
                liveLayout = true
            }
            // The spring takes over: content follows the route again.
            dragZone = nil
            setNeedsUpdateOfSupportedInterfaceOrientations()
            retarget(velocity: CGPoint(x: 0, y: vy), sizeVelocity: CGSize(width: 0, height: -vy))
        default: break
        }
    }

    /// The conversation's column: the docked panel's width, docked or not.
    private var contentWidth: CGFloat { miniFrame.width }

    /// The tallest docked panel: the docked panel's sides and bottom, its top
    /// just under the safe area.
    private var tallestDocked: CGRect {
        let docked = miniFrame, top = safeBounds.minY
        return CGRect(x: docked.minX, y: top, width: docked.width, height: docked.maxY - top)
    }

    /// Shorter than here, the panel heads for the bubble.
    private var collapseTop: CGFloat { tallestDocked.maxY - Self.minimumHeight }

    /// Holds the glass where the finger's top edge puts it on the path.
    private func follow(top: CGFloat) {
        let tall = tallestDocked, full = view.bounds
        let zone: DragZone = top < tall.minY ? .full : top > collapseTop ? .collapse : .docked
        enter(zone)
        let rect: CGRect
        switch zone {
        case .full:
            rect = .lerp(tall, full, ((tall.minY - top) / max(1, tall.minY - full.minY)).clamped())
        case .docked:
            rect = CGRect(x: tall.minX, y: top, width: tall.width, height: tall.maxY - top)
        case .collapse:
            let start = CGRect(x: tall.minX, y: collapseTop, width: tall.width, height: Self.minimumHeight)
            rect = .lerp(start, bubbleFrame, ((top - collapseTop) / max(1, Self.minimumHeight - bubbleSize.height)).clamped())
        }
        frame.hold(rect)
    }

    /// Sets the content up for a part of the path; once per crossing.
    private func enter(_ zone: DragZone) {
        guard zone != dragZone else { return }
        dragZone = zone
        let tall = tallestDocked
        switch zone {
        case .docked:
            liveLayout = false
            // Laid out once, a little taller than the tallest docked panel
            // so the spring's overshoot never shows its edge.
            let size = CGSize(width: tall.width, height: tall.height + 40)
            layOutPanel(at: size, crossBlur: false)
            clipLayout = size
        case .full:
            // Between the tallest docked panel and the full screen the
            // content is laid out live at the glass's frame.
            clipLayout = nil
            outgoing?.view.removeFromSuperview()
            outgoing = nil
            liveLayout = true
        case .collapse:
            // The shortest panel, which stretches into the bubble.
            clipLayout = nil
            liveLayout = false
            layOutPanel(at: CGSize(width: tall.width, height: Self.minimumHeight), crossBlur: false)
        }
        applyScene()
    }

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
        let width = max(1, body.bounds.width)
        switch gesture.state {
        case .began:
            draggingPush = true
            pushStart = push.value
            push.stop()
        case .changed:
            push.set((pushStart - gesture.translation(in: body).x / width).clamped())
        case .ended, .cancelled, .failed:
            draggingPush = false
            let velocity = -gesture.velocity(in: body).x / width
            if gesture.state == .ended, push.value + velocity * 0.18 < 0.5 { route.thread = nil; view.endEditing(true) }
            push.animate(to: route.thread == nil ? 0 : 1, initialVelocity: velocity)
            sync()
        default: break
        }
    }

    /// A touch anywhere (window coordinates).
    func noticed(_ point: CGPoint) {
        guard isViewLoaded else { return }
        glass.look(at: view.convert(point, to: glass))
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
    /// `SQUIRCLE_OVERLAY_OPEN=mini|full|capture` opens the overlay after 4 s
    /// (`capture`: as a long press does);
    /// `SQUIRCLE_OVERLAY_CYCLE=1` loops bubble → mini → full → thread → back
    /// → mini → bubble for recordings (`SQUIRCLE_SLOW` slows the springs).
    private var demoStatus: (headline: String?, tone: LiveCapsule.Tone)?

    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        // `SQUIRCLE_BUBBLE_DEMO=1`: the bubble loops through made-up statuses
        // (short, long, a rapid burst, needs you, done, idle) for recordings.
        if environment["SQUIRCLE_BUBBLE_DEMO"] == "1" {
            let script: [(String?, LiveCapsule.Tone, Double)] = [
                (nil, .idle, 2.5),
                ("Reading SquircleOverlay.swift", .working, 2.4),
                ("Searching for LiveCapsule", .working, 2.4),
                ("Running xcodebuild", .working, 0.15), ("Editing ThreadCells.swift", .working, 0.15),
                ("Editing Theme.swift", .working, 0.15), ("Editing SquircleOverlay.swift", .working, 2.6),
                ("Building Letters Abroad for the iPhone 17 Pro simulator with the overlay", .working, 2.8),
                ("Testing", .working, 2.4),
                ("Needs you · Letters Abroad", .needsYou, 3),
                ("Done · Letters Abroad", .done, 3)
            ]
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                while true {
                    for (headline, tone, pause) in script {
                        guard let self else { return }
                        self.demoStatus = (headline, tone)
                        self.render()
                        try? await Task.sleep(for: .seconds(pause))
                    }
                }
            }
        }
        if let slow = environment["SQUIRCLE_SLOW"].flatMap(Double.init) { SpringDriver.debugSlowMotion = slow }
        if let mode = environment["SQUIRCLE_OVERLAY_OPEN"] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if mode == "capture" { self?.captureAndOpen(); return }
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
    func animate(to rect: CGRect, velocity v: CGPoint? = nil, sizeVelocity: CGSize = .zero) {
        target = rect
        if let v { velocity = [v.x, v.y, sizeVelocity.width, sizeVelocity.height] }
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
private extension CGRect {
    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: .lerp(a.minX, b.minX, t), y: .lerp(a.minY, b.minY, t),
               width: .lerp(a.width, b.width, t), height: .lerp(a.height, b.height, t))
    }
}
#endif
