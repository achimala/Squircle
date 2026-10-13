import AVKit
import UIKit

/// One conversation with a coding agent, on the same stage as Home. The app's
/// device stays with it: docked beside the title, sharing the screen, or nearly
/// full size. A divider between device and conversation moves among those
/// three detents; the device always fills the space above it and shows the
/// thread's live simulator when one is open.
@MainActor
final class ThreadViewController: UIViewController, UITableViewDelegate, UIGestureRecognizerDelegate {
    let project: AppProject
    var onBack: (() -> Void)?
    /// The divider moved; the stage should re-pose the device.
    var onGeometry: (() -> Void)?
    var layoutProvider: (() -> StageLayout?)?
    /// In the debug overlay you are already in the app: the thread opens
    /// docked and the device shows only while its simulator is live.
    var hidesIdleDevice = false
    var hidesDevice: Bool { hidesIdleDevice && stream == nil }
    var currentSessionID: String? { sessionID }
    /// The app's agent: one conversation per app that runs its threads.
    let isAgent: Bool
    /// The agent's update lines open the app's other threads (nil: a new one).
    var onOpenThread: ((String?) -> Void)?
    var onThreads: (() -> Void)?
    var onBuilds: (() -> Void)?
    private let threads = Theme.glassButton(symbol: "list.bullet", identifier: "agent.threads", accessibilityLabel: "Threads")
    private let builds = Theme.glassButton(symbol: "shippingbox", identifier: "agent.builds", accessibilityLabel: "Builds")
    /// The floating buttons at the top left, in reading order.
    private var topControls: [UIView] { isAgent ? [back, threads, builds] : [back] }
    /// The model follows one conversation at a time; a thread opened over
    /// this one takes it and gives it back when it closes.
    private var isActive: Bool { model.selectedSessionID == sessionID }

    private let model: SquircleModel
    private weak var stage: DeviceStage?
    private var sessionID: String?
    private var selectionReady = false
    private var sending = false
    private let draftScroll = UIScrollView()
    private var observations: [Task<Void, Never>] = []

    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "thread.close", accessibilityLabel: "Back to threads")
    private var threadTitle = ""
    private let pickers = PickerBar()
    private var jump: UIButton { pickers.jump }
    private var jumpShown = false
    private let clip = UIView()
    private let fade = CAGradientLayer()
    private let table = UITableView(frame: .zero, style: .plain)
    private let divider = UIView()
    private let grabber = UIView()
    private let deviceTouch = DeviceTouchView()
    private let home = Theme.glassButton(symbol: "house", identifier: "simulator.home", accessibilityLabel: "Simulator Home")
    private let simulator = Theme.glassButton(symbol: "iphone", identifier: "thread.simulator", accessibilityLabel: "Simulator")
    private let simulatorStatus = Theme.label("", Theme.font(.caption1, 12), color: .secondaryLabel)
    private let composer = Composer(placeholder: "Message")
    private let notice = Theme.label("", Theme.font(.footnote, 13), color: Theme.failure, lines: 3)
    private let request = Theme.glassSurface(cornerRadius: 22)
    private let requestTitle = Theme.label("", Theme.font(.subheadline, 15, .semibold), lines: 2)
    private let requestDetail = Theme.label("", Theme.font(.footnote, 12.5, monospaced: true), color: .secondaryLabel, lines: 4)
    private let requestButtons = UIStackView()
    private var renderedRequestID: String?
    /// Progress through the agent's questions in the current request.
    private var questionIndex = 0
    private var questionAnswers: [String: Any] = [:]
    private var questionPicks: [String] = []

    /// A message on its way to the Mac, shown before T3 echoes it back.
    private var pendingSend: (id: String, text: String, known: Set<String>)?
    /// Echoed messages keep the row identity of their local copy.
    private var aliases: [String: String] = [:]
    private var flyingID: String?
    private var showsConversation: Bool { sessionID != nil || pendingSend != nil }
    /// An expanded turn's summary, pinned to the top while you read inside
    /// that turn; tapping it folds the turn back up.
    private let sticky = SummaryCell(style: .default, reuseIdentifier: nil)
    private var stickyTurn: String?
    /// Measured row heights, so long conversations keep their place while
    /// rows above are measured, expanded or folded.
    private var heights: [String: CGFloat] {
        get { Self.heightCache[sessionID ?? ""] ?? [:] }
        set { Self.heightCache[sessionID ?? ""] = newValue }
    }
    /// Row heights per thread, kept across visits so a returning thread lays
    /// out at its true size and opens exactly at the bottom.
    private static var heightCache: [String: [String: CGFloat]] = [:]
    private var items: [ThreadItem] = []
    private var itemsByID: [String: ThreadItem] = [:]
    private var dataSource: UITableViewDiffableDataSource<Int, String>!
    private var rendered: [String: (source: String, text: NSAttributedString)] = [:]
    private var expanded = Set<String>()
    private var pinToBottom = true

    private let detent = SpringDriver(value: 0)
    private var dragStart: CGFloat = 0
    private static let detentKey = "squircle.thread.detent"

    private enum Preview { case automatic, hidden, paused(SimulatorTarget), restarting(SimulatorTarget), visible(SimulatorTarget, T3DeviceStream) }
    private var previewState = Preview.automatic
    /// The agent's open simulator as last seen; nil until first observed.
    private var followedDevice: String??
    /// The device rose to show what the agent opened; it settles back after.
    private var raisedForDevice = false
    private var stream: T3DeviceStream? { if case .visible(_, let stream) = previewState { return stream }; return nil }
    private var frameSize = CGSize(width: 440, height: 956)
    private var orientation = "portrait"
    private var lastInput: CGPoint?

    init(model: SquircleModel, project: AppProject, sessionID: String?, stage: DeviceStage, agent: Bool = false) {
        self.isAgent = agent
        self.model = model
        self.project = project
        self.sessionID = sessionID
        self.stage = stage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var layout: StageLayout {
        layoutProvider?() ?? StageLayout(size: view.bounds.size, safe: view.safeAreaInsets, titleHeight: 41, reducedMotion: Motion.reduced)
    }

    // MARK: Geometry shared with the stage

    /// The lowest the divider may sit: just above the composer.
    private var dividerLimit: CGFloat {
        var floor = request.isHidden ? pickers.frame.minY : request.frame.minY
        // Before the keyboard guide resolves (a thread's first frame on screen)
        // the controls report the top of the view; use where they rest instead.
        let layout = self.layout
        if floor < layout.size.height * 0.5 { floor = layout.size.height - max(layout.safe.bottom, 16) - 100 }
        return floor - 6 - StageLayout.dividerHeight
    }

    var dividerY: CGFloat { layout.divider(detent: detent.value, limit: dividerLimit) }
    var pose: PhonePose {
        guard let morph else { return layout.threadPose(divider: dividerY) }
        // A tap moves the device in one gesture: straight from where it was to
        // where it is going, lifting toward you and turning to show its body.
        let span = morph.to - morph.from
        let t = span == 0 ? 1 : ((detent.value - morph.from) / span).clamped(-0.1, 1.1)
        let end = layout.threadPose(divider: layout.divider(detent: morph.to, limit: dividerLimit))
        var pose = PhonePose.interpolate(morph.pose, end, t)
        let arc = sin(.pi * t.clamped())
        if !layout.reducedMotion {
            pose.depth -= arc * min(morph.pose.height, end.height) * 0.35
            pose.yaw += arc * (morph.to > morph.from ? -0.55 : 0.55)
            pose.pitch -= arc * 0.08
        }
        return pose
    }
    /// The tap-driven move in progress: from which detent and pose, to which detent.
    private var morph: (from: CGFloat, to: CGFloat, pose: PhonePose)?

    /// The simulator owns touches on its display once it is large and live.
    private var simulatorOwnsTouches: Bool { stream?.isInteractive == true && detent.value > 0.6 }

    /// Horizontal back swipes must not start on the live device or the divider.
    func allowsBackSwipe(at point: CGPoint) -> Bool {
        if divider.frame.insetBy(dx: 0, dy: -10).contains(point) { return false }
        if simulatorOwnsTouches, deviceTouch.frame.contains(point) { return false }
        return true
    }

    func focusComposer() { composer.input.becomeFirstResponder() }

    /// The debug overlay's agent closes the overlay instead of going back.
    func setBackButton(symbol: String, label: String) {
        loadViewIfNeeded()
        back.configuration?.image = UIImage(systemName: symbol)
        back.accessibilityLabel = label
    }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.keyboardDismissMode = .interactive
        table.showsVerticalScrollIndicator = false
        table.contentInsetAdjustmentBehavior = .never
        table.delegate = self
        table.estimatedRowHeight = 60
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(HeaderCell.self, forCellReuseIdentifier: "header")
        table.register(StepCell.self, forCellReuseIdentifier: "step")
        table.register(GalleryCell.self, forCellReuseIdentifier: "gallery")
        table.register(SummaryCell.self, forCellReuseIdentifier: "summary")
        table.register(LiveCell.self, forCellReuseIdentifier: "live")
        table.register(BuildCell.self, forCellReuseIdentifier: "build")
        table.register(ChangesCell.self, forCellReuseIdentifier: "changes")
        dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, indexPath, id in
            guard let self, let item = itemsByID[id] else { return UITableViewCell() }
            let cell = table.dequeueReusableCell(withIdentifier: Self.reuseIdentifier(for: item), for: indexPath)
            configure(cell, with: item)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
        table.accessibilityIdentifier = "thread.messages"
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        clip.layer.mask = fade
        clip.addSubview(table)
        draftScroll.backgroundColor = .clear
        draftScroll.keyboardDismissMode = .interactive
        draftScroll.showsVerticalScrollIndicator = false
        draftScroll.accessibilityIdentifier = "thread.draft"
        // Nothing has been said yet: the app's device stands large above, and
        // the prompt and model chips sit right on top of the composer.
        let heading = Theme.label("What’s next?", Theme.font(.title1, 28, .bold), lines: 2)
        heading.translatesAutoresizingMaskIntoConstraints = false
        draftScroll.addSubview(heading)
        let content = draftScroll.contentLayoutGuide, frame = draftScroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            heading.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            heading.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4)
        ])
        clip.addSubview(draftScroll)
        sticky.isHidden = true
        sticky.accessibilityIdentifier = "thread.summary.sticky"
        sticky.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stickyTapped)))
        clip.addSubview(sticky)
        view.addSubview(clip)

        pickers.model.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.modelMenu() ?? []) }])
        pickers.approvals.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.approvalMenu() ?? []) }])
        back.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onBack?() }, for: .touchUpInside)
        [deviceTouch, back, simulatorStatus, divider, home, simulator].forEach(view.addSubview)
        if isAgent {
            back.accessibilityLabel = "Apps"
            threads.addAction(UIAction { [weak self] _ in self?.onThreads?() }, for: .touchUpInside)
            builds.addAction(UIAction { [weak self] _ in self?.onBuilds?() }, for: .touchUpInside)
            [threads, builds].forEach(view.addSubview)
        }

        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        divider.addSubview(grabber)
        divider.isAccessibilityElement = true
        divider.accessibilityIdentifier = "thread.divider"
        divider.accessibilityLabel = "Device size"
        divider.accessibilityTraits = .adjustable
        divider.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dividerPanned(_:))))
        let devicePan = UIPanGestureRecognizer(target: self, action: #selector(dividerPanned(_:)))
        let deviceTap = UITapGestureRecognizer(target: self, action: #selector(deviceTapped))
        devicePan.delegate = self
        deviceTap.delegate = self
        deviceTouch.addGestureRecognizer(devicePan)
        deviceTouch.addGestureRecognizer(deviceTap)
        deviceTouch.onTouch = { [weak self] phase, point in self?.simulatorTouch(phase, at: point) ?? false }
        simulatorStatus.textAlignment = .center
        home.addAction(UIAction { [weak self] _ in
            Theme.selectionHaptic()
            Task { try? await self?.stream?.send(tag: 4, payload: .from(["button": "home"])) }
        }, for: .touchUpInside)
        simulator.showsMenuAsPrimaryAction = true
        simulator.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.simulatorMenu() ?? []) }])

        requestDetail.lineBreakMode = .byTruncatingTail
        requestButtons.spacing = 8
        requestButtons.axis = .vertical
        requestButtons.distribution = .fill
        let requestStack = UIStackView(arrangedSubviews: [requestTitle, requestDetail, requestButtons])
        requestStack.axis = .vertical
        requestStack.spacing = 6
        requestStack.setCustomSpacing(12, after: requestDetail)
        requestStack.translatesAutoresizingMaskIntoConstraints = false
        request.contentView.addSubview(requestStack)
        request.accessibilityIdentifier = "thread.request"
        request.isHidden = true
        notice.isHidden = true
        notice.accessibilityIdentifier = "thread.error"
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in self?.renderSend() }
        jump.alpha = 0
        jump.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        jump.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.selectionHaptic()
            pinToBottom = true
            scrollToBottom(animated: true)
            setJumpShown(false)
        }, for: .touchUpInside)
        [request, notice, pickers, composer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            pickers.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            pickers.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            pickers.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            notice.bottomAnchor.constraint(equalTo: pickers.topAnchor, constant: -8),
            request.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            request.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            request.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -8),
            requestStack.topAnchor.constraint(equalTo: request.contentView.topAnchor, constant: 14),
            requestStack.bottomAnchor.constraint(equalTo: request.contentView.bottomAnchor, constant: -12),
            requestStack.leadingAnchor.constraint(equalTo: request.contentView.leadingAnchor, constant: 16),
            requestStack.trailingAnchor.constraint(equalTo: request.contentView.trailingAnchor, constant: -12)
        ])
        if #available(iOS 26.0, *) {
            table.bottomEdgeEffect.style = .soft
            // Header-less: text scrolling under the floating back button blurs away.
            table.topEdgeEffect.style = .soft
            let top = UIScrollEdgeElementContainerInteraction()
            top.scrollView = table
            top.edge = .top
            back.addInteraction(top)
            let bottom = UIScrollEdgeElementContainerInteraction()
            bottom.scrollView = table
            bottom.edge = .bottom
            composer.addInteraction(bottom)
        }
        view.accessibilityElements = topControls + [deviceTouch, home, simulator, divider, draftScroll, table, request, notice, jump, pickers.model, pickers.approvals, composer]

        detent.parameters = SpringDriver.Parameters(response: 0.42, damping: 0.84)
        detent.onChange = { [weak self] _ in self?.layoutStage() }
        detent.onRest = { [weak self] value in
            self?.morph = nil
            self?.detent.parameters = SpringDriver.Parameters(response: 0.42, damping: 0.84)
            UserDefaults.standard.set(Double(min(1, value.rounded())), forKey: Self.detentKey)
            self?.stage?.setLive(false, reason: "detent")
        }

        observations = [
            model.observe(by: self, after: .milliseconds(50)) { $0.render() },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                    self?.pausePreview()
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    self?.reconcilePreview()
                }
            }
        ]

        renderSimulatorControls(interactive: false)
        model.selectProject(project)
        detent.set(hidesIdleDevice ? 0 : sessionID == nil ? 1 : CGFloat(UserDefaults.standard.double(forKey: Self.detentKey)).clamped())
        let requestedSessionID = sessionID
        if let requestedSessionID {
            // Show what was last seen of this thread right away, at the bottom.
            model.prepareSession(requestedSessionID)
            selectionReady = true
        }
        Task { [weak self] in
            // A thread removed before this ran must not take the model's selection.
            guard let self, !tornDown else { return }
            if let requestedSessionID { await model.selectSession(requestedSessionID) } else { await model.beginDraft(agent: isAgent) }
            selectionReady = true
            render()
        }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        back.frame = CGRect(x: 16, y: safe.top + 4, width: 44, height: 44)
        threads.frame = CGRect(x: 70, y: safe.top + 4, width: 44, height: 44)
        builds.frame = CGRect(x: 124, y: safe.top + 4, width: 44, height: 44)
        layoutStage()
    }

    /// Everything that follows the divider. Runs every frame it moves.
    private func layoutStage() {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        let layout = self.layout
        let width = view.bounds.width, height = view.bounds.height
        let y = dividerY
        let rowHeight = StageLayout.dividerHeight
        // The divider and the simulator's controls arrive as the device
        // leaves its dock; docked, the conversation starts right below it.
        let arrive = ((y - layout.chatDivider) / 150).clamped()
        divider.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
        divider.alpha = arrive
        divider.isUserInteractionEnabled = arrive > 0.05
        grabber.frame = CGRect(x: (width - 36) / 2, y: (rowHeight - 5) / 2, width: 36, height: 5)
        divider.accessibilityValue = detent.value < 0.5 ? "Docked" : detent.value < 1.5 ? "Half" : "Full"

        // Docked, the conversation runs to the top of the screen beneath the
        // floating back button and the device, which floats like a PiP. As
        // the device grows the conversation starts below the divider.
        let clipTop = (y + rowHeight) * arrive
        clip.frame = CGRect(x: 0, y: clipTop, width: width, height: max(0, height - clipTop))
        table.frame = CGRect(x: 0, y: -clipTop, width: width, height: height)
        let fadeLength = CGFloat.lerp(view.safeAreaInsets.top + 20, 14, arrive)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        fade.endPoint = CGPoint(x: 0.5, y: min(1, fadeLength / max(1, clip.bounds.height)))
        CATransaction.commit()
        let floor = request.isHidden ? (notice.isHidden ? pickers.frame.minY : notice.frame.minY) : request.frame.minY
        draftScroll.frame = CGRect(x: 0, y: 0, width: width, height: max(0, floor - clipTop - 8))
        let insets = UIEdgeInsets(top: .lerp(view.safeAreaInsets.top + 54, clipTop + 2, arrive), left: 0, bottom: height - floor + 10, right: 0)
        if table.contentInset != insets {
            let pinned = pinToBottom
            table.contentInset = insets
            if pinned { scrollToBottom() }
        }

        let pose = self.pose
        let phoneWidth = pose.height * PhonePose.aspect
        deviceTouch.frame = CGRect(x: pose.center.x - phoneWidth / 2, y: pose.center.y - pose.height / 2,
                                   width: phoneWidth, height: pose.height).insetBy(dx: -6, dy: -4)
        deviceTouch.isHidden = hidesDevice
        // The simulator's buttons ride on the divider, either side of its grabber.
        for (button, x) in [(home, 20), (simulator, width - 56)] {
            button.transform = .identity
            button.frame = CGRect(x: x, y: y + (rowHeight - 36) / 2, width: 36, height: 36)
            button.transform = CGAffineTransform(scaleX: 0.4 + 0.6 * arrive, y: 0.4 + 0.6 * arrive)
            button.alpha = arrive
            button.isUserInteractionEnabled = arrive > 0.5
        }
        simulatorStatus.frame = CGRect(x: 64, y: y + (rowHeight - 16) / 2 + 14, width: width - 128, height: 16)
        simulatorStatus.alpha = arrive
        onGeometry?()
    }

    /// Floating controls fade as the thread leaves, so they never cross
    /// Home's own controls coming the other way.
    func setTransitionProgress(_ progress: CGFloat) {
        let alpha = ((progress - 0.55) / 0.45).clamped()
        back.alpha = alpha
        threads.alpha = alpha
        builds.alpha = alpha
        pickers.alpha = alpha
        jump.alpha = jumpShown ? alpha : 0
    }

    private func setDetent(_ value: CGFloat, velocity: CGFloat? = nil) {
        stage?.setLive(true, reason: "detent")
        detent.animate(to: value, initialVelocity: velocity)
    }

    // MARK: Divider

    @objc private func dividerPanned(_ gesture: UIPanGestureRecognizer) {
        let layout = self.layout, limit = dividerLimit
        switch gesture.state {
        case .began:
            if morph != nil { morph = nil; detent.parameters = SpringDriver.Parameters(response: 0.42, damping: 0.84) }
            raisedForDevice = false
            detent.stop()
            dragStart = dividerY
            stage?.setLive(true, reason: "detent")
        case .changed:
            let y = min(max(dragStart + gesture.translation(in: view).y, layout.chatDivider), max(layout.chatDivider, limit))
            detent.set(layout.detent(divider: y, limit: limit))
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view).y
            let projected = dividerY + velocity * 0.16
            let stops = (0...2).map { (CGFloat($0), layout.divider(detent: CGFloat($0), limit: limit)) }
            let target = stops.min { abs($0.1 - projected) < abs($1.1 - projected) }?.0 ?? 0
            let span = max(120, (stops[2].1 - stops[0].1) / 2)
            if target != detent.value.rounded() { Theme.selectionHaptic() }
            setDetent(target, velocity: velocity / span)
        default: break
        }
    }

    @objc private func deviceTapped() {
        Theme.selectionHaptic()
        view.endEditing(true)
        let target: CGFloat = detent.target < 0.5 ? 1 : detent.target < 1.5 ? 2 : 1
        morph = (detent.value, target, pose)
        detent.parameters = SpringDriver.Parameters(response: 0.62, damping: 0.86)
        setDetent(target)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !simulatorOwnsTouches
    }

    private func simulatorTouch(_ phase: String, at point: CGPoint) -> Bool {
        guard simulatorOwnsTouches, let stage, let stream else { return false }
        let picture = stage.displayPoint(at: view.convert(point, to: stage), for: project.id)
        let mapped = picture.map { SimulatorSurface.input($0, size: frameSize, orientation: orientation) }
        guard let input = mapped ?? (phase == "begin" ? nil : lastInput) else { return false }
        lastInput = phase == "end" ? nil : input
        stream.touch(phase, point: input)
        return true
    }

    // MARK: Content

    /// A thread opened over this one closed: take the model back.
    func reactivate() {
        Task { [weak self] in
            guard let self, !tornDown else { return }
            if let sessionID { await model.selectSession(sessionID) } else { await model.beginDraft(agent: isAgent) }
            render()
        }
        reconcilePreview()
    }
    /// A thread is opening over this one.
    func deactivate() { pausePreview() }

    private func render() {
        guard isViewLoaded, isActive || !selectionReady else { return }
        guard selectionReady else {
            pickers.model.isEnabled = false
            composer.send.isEnabled = false
            table.isHidden = true
            draftScroll.isHidden = true
            return
        }
        // The Mac may report the app's agent after this opened as a draft.
        if isAgent, sessionID == nil, !sending, pendingSend == nil, let id = model.agentThreadID(for: project) {
            sessionID = id
            model.prepareSession(id)
            Task { [weak self] in await self?.model.selectSession(id) }
        }
        composer.send.isEnabled = !sending
        draftScroll.isHidden = showsConversation
        table.isHidden = !showsConversation
        view.accessibilityElements = topControls + [deviceTouch, home, simulator, divider,
                                      showsConversation ? table : draftScroll, request, notice, jump, pickers.model, pickers.approvals, composer]
        simulator.isEnabled = sessionID != nil
        let session = model.sessions.first { $0.id == sessionID }
        threadTitle = isAgent ? project.name : session?.displayTitle(in: project) ?? ""
        renderAgent()
        renderSend()
        renderRequest()
        let error = model.error ?? (model.connected ? nil : "Reconnecting…")
        if notice.text != error || notice.isHidden != (error == nil) {
            notice.text = error
            notice.isHidden = error == nil
            notice.textColor = model.error == nil ? .secondaryLabel : Theme.failure
            view.setNeedsLayout()
        }
        renderItems()
        followAgentDevice()
        reconcilePreview()
    }

    private func renderAgent() {
        pickers.set(model: model.shortAgentName(for: model.modelSelection), mode: model.runtimeMode)
        pickers.model.isEnabled = true
        composer.placeholderText = "Message"
    }

    private func modelMenu() -> [UIMenuElement] {
        let locked = model.isRunning || sending
        return model.modelMenu.map { section in
            UIMenu(title: section.title, options: .displayInline, children: section.choices.map { choice in
                UIAction(title: choice.name, attributes: locked ? .disabled : [],
                         state: choice.selection == model.modelSelection ? .on : .off) { [weak self] _ in
                    Theme.selectionHaptic()
                    self?.model.chooseModel(choice.selection)
                    self?.render()
                }
            })
        }
    }

    private func approvalMenu() -> [UIMenuElement] {
        T3RuntimeMode.allCases.map { mode in
            UIAction(title: mode.title, image: UIImage(systemName: mode.symbol), state: mode == model.runtimeMode ? .on : .off) { [weak self] _ in
                Theme.selectionHaptic()
                Task { await self?.model.setRuntimeMode(mode) }
            }
        }
    }

    private func renderSend() {
        let stop = model.isRunning && composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let symbol = stop ? "stop.fill" : "arrow.up"
        if composer.send.accessibilityValue != symbol {
            composer.send.accessibilityValue = symbol
            composer.send.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
            composer.send.accessibilityLabel = stop ? "Stop agent" : "Send message"
        }
    }

    private static func reuseIdentifier(for item: ThreadItem) -> String {
        switch item {
        case .header: return "header"
        case .user, .update, .answer, .note, .thought: return "message"
        case .step, .earlier: return "step"
        case .gallery: return "gallery"
        case .summary: return "summary"
        case .live: return "live"
        case .build: return "build"
        case .changes: return "changes"
        }
    }

    private func renderItems(animated: Bool = false) {
        let header: [ThreadItem] = threadTitle.isEmpty ? [] : [.header(threadTitle)]
        let next = header + ThreadItem.items(messages: displayedMessages(), running: model.isRunning, expanded: expanded,
                                             builds: model.builds(for: project), changes: model.changes)
        guard next != items else { return }
        let previous = itemsByID
        let first = items.isEmpty
        // A turn finishing folds its steps away; let the table animate that.
        let folding = animated || (previous["live"] != nil && !next.contains { $0.id == "live" })
        items = next
        itemsByID = [:]
        var ids: [String] = []
        for item in next where itemsByID[item.id] == nil { itemsByID[item.id] = item; ids.append(item.id) }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let changed = ids.filter { previous[$0] != nil && previous[$0] != itemsByID[$0] }
        snapshot.reconfigureItems(changed)
        let inserted = first ? [] : ids.filter { previous[$0] == nil }
        let removed = previous.keys.filter { itemsByID[$0] == nil }.count
        // Rows arriving or leaving while the agent works slide into place;
        // only streaming text, which just grows, updates without animation.
        let structural = !first && (!inserted.isEmpty || removed > 0) && inserted.count + removed <= 16 && !Motion.reduced
        if folding || structural {
            dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
                guard let self, pinToBottom, flyingID == nil else { return }
                scrollToBottom(animated: true)
            }
        } else {
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
                table.layoutIfNeeded()
            }
        }
        // A message in flight scrolls the conversation on its own spring.
        // Pinned, the conversation follows new content on one spring.
        if pinToBottom, flyingID == nil { scrollToBottom(animated: !first && view.window != nil) }
        if !folding, !inserted.isEmpty, inserted.count <= 8 { animateEntrance(of: inserted) }
        updateSticky()
        if previous["live"] != nil, itemsByID["live"] == nil, let finished = next.last(where: { if case .summary = $0 { return true }; return false }) {
            celebrate(finished.id)
        }
    }

    /// The conversation with your just-sent message in place until T3 has it.
    private func displayedMessages() -> [ChatMessage] {
        var messages = model.messages
        if let pending = pendingSend {
            let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let echo = messages.first(where: { $0.role == "user" && !pending.known.contains($0.id)
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == text }) {
                aliases[echo.id] = pending.id
                pendingSend = nil
            } else {
                messages.append(ChatMessage(id: pending.id, role: "user", content: pending.text,
                                            createdAt: ISO8601DateFormatter().string(from: .now)))
            }
        }
        guard !aliases.isEmpty else { return messages }
        return messages.map { message in
            guard let alias = aliases[message.id] else { return message }
            var copy = message
            copy.id = alias
            return copy
        }
    }

    /// The turn that just finished announces itself once it has settled.
    private func celebrate(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, let index = dataSource.indexPath(for: id),
                  let cell = table.cellForRow(at: index) as? SummaryCell else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            cell.celebrate()
        }
    }

    /// New rows rise into place and come into focus, one after another.
    private func animateEntrance(of ids: [String]) {
        guard !Motion.reduced else { return }
        table.layoutIfNeeded()
        for (order, id) in ids.enumerated() {
            guard let index = dataSource.indexPath(for: id), let cell = table.cellForRow(at: index) else { continue }
            if id == flyingID { continue }
            let view = cell.contentView
            // Glass mustn't be faded (it renders wrongly); it rises instead.
            let glassy = cell is MessageCell || cell is SummaryCell || cell is LiveCell || cell is BuildCell || cell is ChangesCell
            if !glassy { view.alpha = 0 }
            view.transform = CGAffineTransform(translationX: 0, y: 16).scaledBy(x: 0.97, y: 0.97)
            UIView.animate(withDuration: 0.6, delay: Double(order) * 0.05, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    private func scrollToBottom(animated: Bool = false) {
        // Rows are measured as they appear, so the true bottom is only known
        // after laying out there; find it, then move there.
        let start = table.contentOffset.y
        func bottom() -> CGFloat { max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height) }
        var target = bottom()
        for _ in 0..<6 {
            table.contentOffset.y = target
            table.layoutIfNeeded()
            let next = bottom()
            if abs(next - target) < 0.5 { break }
            target = next
        }
        guard animated, !Motion.reduced, abs(start - target) > 0.5 else {
            scrollSpring.stop()
            table.contentOffset.y = target
            return
        }
        table.contentOffset.y = start
        if abs(scrollSpring.value - scrollSpring.target) > 0.5, abs(scrollSpring.value - start) < 1 {
            // Already gliding: retarget without losing speed.
            scrollSpring.animate(to: target)
        } else {
            // From far away, glide the last screen rather than racing past every row.
            scrollSpring.set(max(start, target - table.bounds.height * 0.9))
            scrollSpring.animate(to: target)
        }
    }

    /// Scrolls the conversation on one spring, laying rows out every frame.
    private lazy var scrollSpring: SpringDriver = {
        let spring = SpringDriver(value: table.contentOffset.y)
        spring.parameters = SpringDriver.Parameters(response: 0.45, damping: 0.92)
        spring.onChange = { [weak self] value in self?.table.contentOffset.y = value }
        return spring
    }()

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { scrollSpring.stop() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateSticky()
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let bottom = scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height
        pinToBottom = bottom - scrollView.contentOffset.y < 60
        setJumpShown(bottom - scrollView.contentOffset.y > 320)
    }

    /// Finds the expanded turn under the top edge and pins its summary there,
    /// pushed away by the end of that turn like a section header.
    private func updateSticky() {
        let top = table.contentOffset.y + table.contentInset.top
        var pinned: (TurnSummary, CGFloat, CGFloat)?
        for (index, item) in items.enumerated() {
            guard case .summary(let summary) = item, summary.expanded,
                  let path = dataSource.indexPath(for: item.id) else { continue }
            let head = table.rectForRow(at: path)
            guard head.minY < top else { continue }
            // The turn ends at its answer or the next message.
            let end = items[(index + 1)...].firstIndex { if case .answer = $0 { return true }; if case .user = $0 { return true }; if case .update = $0 { return true }; return false }
            let endY = end.flatMap { dataSource.indexPath(for: items[$0].id) }.map { table.rectForRow(at: $0).minY } ?? table.contentSize.height
            guard endY > top + head.height * 0.5 else { continue }
            pinned = (summary, min(top, endY - head.height), head.height)
        }
        guard let (summary, y, height) = pinned else {
            sticky.isHidden = true
            stickyTurn = nil
            return
        }
        if stickyTurn != summary.turn {
            stickyTurn = summary.turn
            sticky.configure(summary)
        }
        sticky.isHidden = false
        sticky.frame = table.convert(CGRect(x: 0, y: y, width: table.bounds.width, height: height), to: clip)
    }

    @objc private func stickyTapped() {
        guard let turn = stickyTurn else { return }
        let id = "summary:" + turn
        toggle(turn)
        // Land with the folded turn's summary at the top.
        if let path = dataSource.indexPath(for: id) {
            let target = table.rectForRow(at: path).minY - table.contentInset.top
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                self.table.contentOffset.y = max(-self.table.contentInset.top, target)
            }
        }
    }

    private func setJumpShown(_ shown: Bool) {
        guard shown != jumpShown else { return }
        jumpShown = shown
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: shown ? 0.62 : 0.9, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.jump.alpha = shown ? 1 : 0
            self.jump.transform = shown ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
        }
    }

    private func configure(_ cell: UITableViewCell, with item: ThreadItem) {
        switch item {
        case .header(let title):
            (cell as? HeaderCell)?.configure(title)
        case .user(let message):
            (cell as? MessageCell)?.configure(message, style: .user, rendered: text(for: message, style: .user), expanded: true)
            cell.contentView.alpha = message.id == flyingID ? 0 : 1
        case .update(let message):
            (cell as? MessageCell)?.configure(message, style: .update, rendered: text(for: message, style: .update), expanded: true)
        case .answer(let message):
            (cell as? MessageCell)?.configure(message, style: .answer, rendered: text(for: message, style: .answer), expanded: true)
        case .note(let message):
            (cell as? MessageCell)?.configure(message, style: .note, rendered: text(for: message, style: .note), expanded: expanded.contains(message.id))
        case .thought(let message):
            (cell as? MessageCell)?.configure(message, style: .thought, rendered: text(for: message, style: .thought), expanded: expanded.contains(message.id))
        case .step(let message, let first, let last):
            (cell as? StepCell)?.configure(message, first: first, last: last)
        case .earlier(_, let count):
            (cell as? StepCell)?.configureEarlier(count: count, expanded: count == 0)
        case .gallery(let id, let shots):
            guard let cell = cell as? GalleryCell else { return }
            cell.configure(shots, indent: id.hasPrefix("gallery:earlier:") || itemsByID[String(id.dropFirst(8))] != nil ? 56 : 20, id: id)
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
            for shot in shots where GalleryCell.image(for: shot) == nil { loadImage(shot, item: id) }
        case .summary(let summary):
            (cell as? SummaryCell)?.configure(summary)
        case .live(let status):
            (cell as? LiveCell)?.configure(status)
        case .changes(let changes, _):
            (cell as? ChangesCell)?.configure(changes)
        case .build(let build, _):
            guard let cell = cell as? BuildCell else { return }
            cell.configure(build, installing: installingBuild == build.id)
            cell.onInstall = { [weak self] build in self?.install(build) }
        }
    }

    private func text(for message: ChatMessage, style: MessageCell.Style) -> NSAttributedString {
        let key = message.id + "\(style)"
        if let cached = rendered[key], cached.source == message.content { return cached.text }
        let text: NSAttributedString
        switch style {
        case .user:
            text = NSAttributedString(string: message.content, attributes: [.font: Theme.font(.body, 17), .foregroundColor: UIColor.label])
        case .note, .thought:
            text = Markdown.render(message.content, font: Theme.font(.subheadline, 15), color: .secondaryLabel)
        case .answer:
            text = Markdown.render(message.content, font: Theme.font(.body, 17), color: message.failed ? Theme.failure : .label)
        case .update:
            let font = Theme.font(.footnote, 13, .medium)
            let line = NSMutableAttributedString()
            if let symbol = UIImage(systemName: "arrow.triangle.merge", withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
                line.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
                line.append(NSAttributedString(string: "  "))
            }
            line.append(NSAttributedString(string: message.content))
            line.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel], range: NSRange(location: 0, length: line.length))
            text = line
        }
        rendered[key] = (message.content, text)
        return text
    }

    private func tappable(_ item: ThreadItem?) -> Bool {
        switch item {
        case .step(let message, _, _): return !message.detail.isEmpty || message.step?.diff != nil
        case .earlier, .summary, .note, .thought, .changes: return true
        case .update(let message): return !message.threadIDs.isEmpty && onOpenThread != nil
        default: return false
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let id = dataSource.itemIdentifier(for: indexPath) { heights[id] = cell.bounds.height }
    }
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let id = dataSource.itemIdentifier(for: indexPath) { heights[id] = cell.bounds.height }
    }
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return 60 }
        if let known = heights[id] { return known }
        let width = max(200, tableView.bounds.width - 40)
        func lines(_ text: String, per: CGFloat) -> CGFloat {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ceil(CGFloat($1.count) * per / width)) }
        }
        switch itemsByID[id] {
        case .header: return 44
        case .user(let message): return lines(message.content, per: 9.2) * 22 + 42
        case .update(let message): return lines(message.content, per: 7.2) * 18 + 24
        case .answer(let message): return lines(message.content, per: 8.6) * 23 + 20
        case .note(let message): return min(4, lines(message.content, per: 7.6)) * 20 + 12
        case .thought: return 52
        case .step, .earlier: return 36
        case .gallery: return GalleryCell.height + 20
        case .summary: return 54
        case .live: return 72
        case .build: return 74
        case .changes: return 46
        case nil: return 60
        }
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        tappable(dataSource.itemIdentifier(for: indexPath).flatMap { itemsByID[$0] })
    }
    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        (tableView.cellForRow(at: indexPath) as? TimelineCell)?.setPressed(true)
    }
    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        (tableView.cellForRow(at: indexPath) as? TimelineCell)?.setPressed(false)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = itemsByID[id] else { return }
        switch item {
        case .step(let message, _, _): showDetail(message)
        case .earlier(let turn, _): toggle(turn)
        case .summary(let summary): toggle(summary.turn)
        case .changes(let changes, _): showChanges(changes)
        case .note(let message), .thought(let message): toggle(message.id)
        case .update(let message): if let id = message.threadIDs.first { onOpenThread?(id) }
        default: break
        }
    }

    private func toggle(_ id: String) {
        Theme.selectionHaptic()
        if !expanded.insert(id).inserted { expanded.remove(id) }
        let keepBottom = pinToBottom
        pinToBottom = false
        renderItems(animated: true)
        pinToBottom = keepBottom
    }

    private var installingBuild: String?
    /// Opens iOS's own install prompt for a build, right from the conversation.
    private func install(_ build: AppBuild) {
        guard installingBuild == nil else { return }
        installingBuild = build.id
        renderItems()
        Task { [weak self] in
            guard let self else { return }
            await model.install(build)
            installingBuild = nil
            var snapshot = dataSource.snapshot()
            let ids = snapshot.itemIdentifiers.filter { $0.hasSuffix(build.id) }
            snapshot.reconfigureItems(ids)
            await dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func showChanges(_ changes: TurnChanges) {
        guard presentedViewController == nil else { return }
        Theme.selectionHaptic()
        present(DiffViewController(title: "Changes") { [weak self] in await self?.model.turnDiff(changes) }, animated: true)
    }

    private func showDetail(_ step: ChatMessage) {
        guard presentedViewController == nil else { return }
        present(StepDetailViewController(step: step), animated: true)
    }

    private var loadingImages = Set<String>()
    private func loadImage(_ shot: Shot, item: String) {
        let key = "\(shot.step)#\(shot.index)"
        guard loadingImages.insert(key).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            let data = await model.loadStepImage(shot.step, index: shot.index)
            loadingImages.remove(key)
            guard data != nil, dataSource.indexPath(for: item) != nil else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([item])
            await dataSource.apply(snapshot, animatingDifferences: false)
            if pinToBottom { scrollToBottom(animated: true) }
        }
    }

    private func showImage(_ shot: Shot) {
        guard presentedViewController == nil else { return }
        if shot.video {
            Task { [weak self] in
                guard let self, let url = await model.loadVideo(shot.step) else { return }
                let player = AVPlayerViewController()
                player.player = AVPlayer(url: url)
                present(player, animated: true) { player.player?.play() }
            }
            return
        }
        guard let data = StepImages.data(for: shot.step, index: shot.index), let image = UIImage(data: data) else { return }
        present(ImageViewController(image: image, title: shot.title), animated: true)
    }

    // MARK: Composer and requests

    private func send() {
        guard selectionReady, !sending else { return }
        let text = composer.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if model.isRunning { Task { await model.stop() } }
            return
        }
        sending = true
        composer.send.isEnabled = false
        Theme.openHaptic()
        let source = composer.textOrigin(in: view)
        let local = "local:" + UUID().uuidString
        pendingSend = (local, text, Set(model.messages.filter { $0.role == "user" }.map(\.id)))
        flyingID = Motion.reduced ? nil : local
        composer.text = ""
        pinToBottom = true
        render()
        flySend(id: local, from: source)
        Task { [weak self] in
            guard let self else { return }
            await model.send(text, in: project)
            sessionID = model.selectedSessionID
            sending = false
            // A message the Mac did not accept goes back into the field.
            if model.error != nil {
                if pendingSend?.id == local { pendingSend = nil }
                if composer.text.isEmpty { composer.text = text }
            }
            render()
        }
    }

    /// As in Messages: your words become their bubble right where you typed
    /// them and the bubble rises out of the field into place while the
    /// conversation makes room. The text sits inside the bubble throughout.
    private func flySend(id: String, from source: CGPoint) {
        view.layoutIfNeeded()
        let start = table.contentOffset.y
        scrollToBottom()
        let end = table.contentOffset.y
        guard !Motion.reduced, let index = dataSource.indexPath(for: id),
              let cell = table.cellForRow(at: index) as? MessageCell else { flyingID = nil; return }
        cell.contentView.alpha = 1
        cell.layoutIfNeeded()
        let bubble = cell.bubble.convert(cell.bubble.bounds, to: view)
        let textFrame = cell.text.convert(cell.text.bounds, to: view)
        let inset = cell.text.textContainerInset
        guard let words = cell.text.snapshotView(afterScreenUpdates: true) else { flyingID = nil; return }
        cell.contentView.alpha = 0
        table.contentOffset.y = start

        let flyer = UIView(frame: bubble)
        flyer.isUserInteractionEnabled = false
        let fill = Theme.glassSurface(cornerRadius: 21, tint: Theme.userGlass)
        fill.frame = flyer.bounds
        flyer.addSubview(fill)
        words.frame = CGRect(x: textFrame.minX - bubble.minX, y: textFrame.minY - bubble.minY,
                             width: textFrame.width, height: textFrame.height)
        flyer.addSubview(words)
        view.insertSubview(flyer, aboveSubview: composer)
        // Start with the first line of text exactly where it was typed.
        let offset = CGPoint(x: words.frame.minX + inset.left, y: words.frame.minY + inset.top)
        flyer.frame.origin = CGPoint(x: source.x - offset.x, y: source.y - offset.y)
        fill.transform = CGAffineTransform(scaleX: 0.94, y: 0.9)
        composer.holdsPlaceholder = true

        let rise = UIViewPropertyAnimator(duration: 0.5, dampingRatio: 0.84) {
            flyer.frame.origin = bubble.origin
            fill.transform = .identity
            self.table.contentOffset.y = end
        }
        rise.addCompletion { [weak self] _ in
            flyer.removeFromSuperview()
            guard let self else { return }
            composer.revealPlaceholder()
            if flyingID == id { flyingID = nil }
            if let index = dataSource.indexPath(for: id) { table.cellForRow(at: index)?.contentView.alpha = 1 }
            if pinToBottom { scrollToBottom(animated: true) }
        }
        rise.startAnimation()
    }

    private var debugRequest: JSONValue?
    private func renderRequest() {
        let current = debugRequest ?? model.requests.first
        let id = current?["id"].string
        guard id != renderedRequestID else { return }
        let appearing = renderedRequestID == nil && current != nil
        renderedRequestID = id
        questionIndex = 0
        questionAnswers = [:]
        questionPicks = []
        request.isHidden = current == nil
        if let current {
            if (current["kind"].string ?? "").contains("user-input") { renderQuestion(current) } else { renderApproval(current) }
        }
        view.setNeedsLayout()
        guard appearing, !Motion.reduced else { return }
        // The card rises out of the message field.
        view.layoutIfNeeded()
        request.alpha = 0
        request.transform = CGAffineTransform(translationX: 0, y: 40).scaledBy(x: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.65, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.request.alpha = 1
            self.request.transform = .identity
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func requestButton(_ title: String, subtitle: String? = nil, prominent: Bool, leading: Bool = false,
                               action: @escaping () -> Void) -> UIButton {
        let button = Theme.glassButton(title: title, prominent: prominent, identifier: "thread.request.\(title)")
        button.configuration?.subtitle = subtitle
        button.configuration?.titleLineBreakMode = .byWordWrapping
        button.configuration?.subtitleLineBreakMode = .byTruncatingTail
        button.configuration?.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = Theme.font(.footnote, 13); return attributes
        }
        if leading {
            button.configuration?.titleAlignment = .leading
            button.contentHorizontalAlignment = .leading
        }
        button.addAction(UIAction { _ in Theme.selectionHaptic(); action() }, for: .touchUpInside)
        requestButtons.addArrangedSubview(button)
        return button
    }

    private func renderApproval(_ current: JSONValue) {
        requestButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let payload = current["payload"]
        requestTitle.text = current["summary"].string ?? "The agent needs your response"
        let detail = payload["detail"].string ?? ""
        if let stack = requestTitle.superview as? UIStackView {
            stack.insertArrangedSubview(requestDetail, at: 1)
            stack.setCustomSpacing(6, after: requestTitle)
            stack.setCustomSpacing(12, after: requestDetail)
        }
        requestDetail.font = Theme.font(.footnote, 12.5, monospaced: true)
        requestDetail.textColor = .secondaryLabel
        requestDetail.text = detail
        requestDetail.isHidden = detail.isEmpty
        if payload["options"].array.isEmpty {
            _ = requestButton("Decline", prominent: false) { [weak self] in Task { await self?.model.respond(to: current, decision: "decline") } }
            _ = requestButton("Allow", prominent: true) { [weak self] in Task { await self?.model.respond(to: current, decision: "accept") } }
        } else {
            for option in payload["options"].array {
                _ = requestButton(option["label"].string ?? "Choose", subtitle: option["warning"].string,
                                  prominent: ["accept", "acceptForSession", "acceptAlways"].contains(option["decision"].string ?? "")) { [weak self] in
                    Task { await self?.model.respond(to: current, decision: option["decision"].string) }
                }
            }
        }
    }

    /// One of the agent's questions at a time, answered by tapping a choice
    /// or typing; the card slides to the next question.
    private func renderQuestion(_ current: JSONValue, advancing: Bool = false) {
        let questions = current["payload"]["questions"].array
        guard questionIndex < questions.count else {
            let answers = questionAnswers
            requestButtons.arrangedSubviews.forEach { $0.isUserInteractionEnabled = false }
            Task { await model.respond(to: current, answers: answers) }
            return
        }
        if advancing, !Motion.reduced {
            let slide = CATransition()
            slide.type = .push
            slide.subtype = .fromRight
            slide.duration = 0.35
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            request.contentView.layer.add(slide, forKey: "question")
        }
        requestButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let question = questions[questionIndex]
        let id = question["id"].string ?? question["header"].string ?? "answer"
        let multiple = question["multiSelect"].bool
        var caption = (question["header"].string ?? "Question").uppercased()
        if questions.count > 1 { caption += "  ·  \(questionIndex + 1) OF \(questions.count)" }
        if let stack = requestTitle.superview as? UIStackView {
            stack.insertArrangedSubview(requestDetail, at: 0)
            stack.setCustomSpacing(4, after: requestDetail)
            stack.setCustomSpacing(14, after: requestTitle)
        }
        requestDetail.font = Theme.font(.caption1, 12, .semibold)
        requestDetail.textColor = Theme.accent
        requestDetail.text = caption
        requestDetail.isHidden = false
        requestTitle.text = question["question"].string ?? "The agent has a question"
        func answer(_ value: String) {
            questionAnswers[id] = value
            questionPicks = []
            questionIndex += 1
            renderQuestion(current, advancing: true)
            view.setNeedsLayout()
            UIView.animate(withDuration: 0.4) { self.view.layoutIfNeeded() }
        }
        for option in question["options"].array {
            let label = option["label"].string ?? option.string ?? "Option"
            let picked = questionPicks.contains(label)
            _ = requestButton(label, subtitle: option["description"].string, prominent: picked, leading: true) { [weak self] in
                guard let self else { return }
                guard multiple else { answer(option["value"].string ?? label); return }
                if let index = questionPicks.firstIndex(of: label) { questionPicks.remove(at: index) } else { questionPicks.append(label) }
                renderQuestion(current)
            }
        }
        let field = UITextField()
        field.placeholder = "Something else…"
        field.font = Theme.font(.body, 16)
        field.returnKeyType = .send
        field.accessibilityIdentifier = "thread.request.other"
        field.addAction(UIAction { [weak field] _ in
            let text = field?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { field?.resignFirstResponder(); answer(multiple ? (self.questionPicks + [text]).joined(separator: ", ") : text) }
        }, for: .editingDidEndOnExit)
        let wrap = UIView()
        wrap.backgroundColor = .tertiarySystemFill
        wrap.layer.cornerRadius = 20
        wrap.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(field)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 44),
            field.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
        ])
        requestButtons.addArrangedSubview(wrap)
        if multiple {
            let next = requestButton(questionIndex == questions.count - 1 ? "Send" : "Next", prominent: true) {
                answer(self.questionPicks.joined(separator: ", "))
            }
            next.isEnabled = !questionPicks.isEmpty
        }
    }

    // MARK: Simulator

    private func simulatorMenu() -> [UIMenuElement] {
        var current: SimulatorTarget?
        switch previewState {
        case .visible(let target, _), .paused(let target), .restarting(let target): current = target
        case .automatic, .hidden: break
        }
        let devices = model.devices["devices"].array.filter { $0["platform"].string == "ios" && !$0["physical"].bool }.map { device in
            UIAction(title: device["name"].string ?? "Simulator", image: UIImage(systemName: "iphone"),
                     state: device["id"].string == current?.deviceID ? .on : .off) { [weak self] _ in self?.open(device) }
        }
        var elements: [UIMenuElement] = [UIMenu(title: devices.isEmpty ? "No simulators on this Mac" : "Simulator", options: .displayInline, children: devices)]
        if case .visible(let target, _) = previewState {
            elements.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Disconnect", image: UIImage(systemName: "eye.slash")) { [weak self] _ in self?.hidePreview() },
                UIAction(title: "Restart Simulator", subtitle: "Closes its running apps", image: UIImage(systemName: "arrow.clockwise"),
                         attributes: .destructive) { [weak self] _ in self?.restart(target) }
            ]))
        }
        return elements
    }

    private func open(_ device: JSONValue) {
        Task { [weak self] in
            guard let self else { return }
            guard selectionReady, sessionID != nil else { return }
            guard let target = await model.openDevice(device) else { return }
            model.rememberSimulator(target.deviceID, for: project)
            pausePreview()
            previewState = .paused(target)
            reconcilePreview()
            if detent.target < 0.5 { setDetent(1) }
        }
    }

    private func restart(_ target: SimulatorTarget) {
        pausePreview()
        previewState = .restarting(target)
        simulator.isEnabled = false
        simulatorStatus.text = "Restarting simulator…"
        Task { [weak self] in
            guard let self else { return }
            let reopened = await model.openDevice(.from(["id": target.deviceID, "hostId": target.hostID]), restart: true)
            previewState = .paused(reopened ?? target)
            simulator.isEnabled = true
            reconcilePreview()
        }
    }

    /// When the agent opens a simulator, it goes live on the device and the
    /// device rises to show it; when the agent closes it, the device settles.
    private func followAgentDevice() {
        guard selectionReady, sessionID != nil else { return }
        let active = model.activeDevice
        let key = active.map { ($0["deviceId"].string ?? "") + "@" + ($0["openedAt"].string ?? "") }
        guard let previous = followedDevice else { followedDevice = .some(key); return }
        guard key != previous else { return }
        followedDevice = .some(key)
        if let active, let target = SimulatorTarget(deviceID: active["deviceId"].string, hostID: active["hostId"].string) {
            model.rememberSimulator(target.deviceID, for: project)
            switch previewState {
            case .visible(let current, let stream) where current != target:
                stream.stop()
                previewState = .automatic
            case .visible, .restarting: break
            default: previewState = .automatic
            }
            if detent.target < 0.5 {
                raisedForDevice = true
                Theme.openHaptic()
                setDetent(1)
            }
        } else {
            pausePreview()
            previewState = .automatic
            if raisedForDevice, detent.target > 0.5, detent.target < 1.5 { setDetent(0) }
            raisedForDevice = false
        }
    }

    private func reconcilePreview() {
        guard selectionReady, sessionID != nil else { return }
        guard UIApplication.shared.applicationState == .active, view.window != nil, parent != nil else { return }
        let target: SimulatorTarget?
        switch previewState {
        case .hidden, .visible, .restarting: return
        case .paused(let chosen): target = chosen
        case .automatic:
            target = model.activeDevice.flatMap { SimulatorTarget(deviceID: $0["deviceId"].string, hostID: $0["hostId"].string) }
        }
        guard let target, let http = model.gateway?.http else { return }
        let stream = T3DeviceStream(http: http, base: model.devices["hubBasePath"].string ?? "/api/device-hub", target: target)
        previewState = .visible(target, stream)
        stream.onFrame = { [weak self] buffer in
            guard let self else { return }
            frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            stage?.setLiveFrame(buffer, for: project.id)
        }
        stream.onScreen = { [weak self] in self?.orientation = $0["orientation"].string ?? "portrait" }
        stream.onStatus = { [weak self] in self?.simulatorStatus.text = $0 }
        stream.onInteractive = { [weak self] ready in self?.renderSimulatorControls(interactive: ready) }
        renderSimulatorControls(interactive: false)
        stream.start()
    }

    private func renderSimulatorControls(interactive: Bool) {
        home.isEnabled = interactive
        home.isHidden = stream == nil
        simulator.configuration?.image = UIImage(systemName: stream == nil ? "iphone" : "ellipsis")
        deviceTouch.accessibilityLabel = interactive ? "Live simulator. Touch to interact." : "\(project.name) device"
    }

    /// Stops the stream but keeps its last picture on the device.
    /// Removed from the screen for good: stops everything that could still
    /// move the shared stage or the device (a removed controller can outlive
    /// its view while a load finishes).
    private var tornDown = false

    func tearDown() {
        tornDown = true
        pausePreview()
        observations.forEach { $0.cancel() }
        observations = []
        detent.stop()
        detent.onChange = nil
        stage?.setLive(false, reason: "detent")
        stage = nil
        onGeometry = nil
        onBack = nil
    }

    func pausePreview() {
        if case .visible(let target, let stream) = previewState {
            stream.stop()
            previewState = .paused(target)
        }
        lastInput = nil
        simulatorStatus.text = nil
        renderSimulatorControls(interactive: false)
    }

    private func hidePreview() {
        pausePreview()
        previewState = .hidden
        stage?.endLive(for: project.id)
    }

    #if DEBUG
    /// Verification only: a sample agent question, never sent to T3.
    func debugShowQuestion() {
        debugRequest = .from(["id": "debug-question", "kind": "user-input.requested", "payload": ["requestId": "debug", "questions": [
            ["id": "effects", "header": "Effects", "question": "How bold should the glass effects be?", "multiSelect": false, "options": [
                ["label": "Bold and flashy", "description": "Flowing spectrum glow, shimmer and ripples"],
                ["label": "Calm", "description": "Soft shimmer, restrained glow"]]],
            ["id": "media", "header": "Media", "question": "What should appear inline?", "multiSelect": true, "options": [
                ["label": "Screenshots"], ["label": "Recordings"], ["label": "Diffs"]]]]]])
        renderRequest()
    }
    /// Verification only: types and sends a real message, as the composer does.
    func debugSend(_ text: String) {
        composer.text = text
        send()
    }
    /// Verification only: the send animation without dispatching to T3.
    func debugFlySend(_ text: String) {
        composer.text = text
        view.layoutIfNeeded()
        let source = composer.textOrigin(in: view)
        let local = "local:debug"
        pendingSend = (local, text, Set(model.messages.filter { $0.role == "user" }.map(\.id)))
        flyingID = local
        composer.text = ""
        pinToBottom = true
        render()
        flySend(id: local, from: source)
    }
    /// Verification only: hands the live line to a new task and back.
    func debugLens() {
        guard let cell = table.visibleCells.compactMap({ $0 as? LiveCell }).first else { return }
        cell.configure(LiveStatus(headline: "Running the unit tests", started: nil))
    }
    func debugTapDevice() { deviceTapped() }
    /// Verification only: replays the finished-turn pulse on the last summary.
    func debugPulse() {
        guard let last = items.last(where: { if case .summary = $0 { return true }; return false }),
              let index = dataSource.indexPath(for: last.id) else { return }
        pinToBottom = false
        table.scrollToRow(at: index, at: .middle, animated: false)
        table.layoutIfNeeded()
        (table.cellForRow(at: index) as? SummaryCell)?.celebrate()
    }
    func debugSetDetent(_ value: CGFloat) {
        view.layoutIfNeeded()
        detent.set(value)
    }
    #endif

    override func accessibilityPerformEscape() -> Bool {
        onBack?()
        return true
    }
}
