import AVKit
import UIKit

/// What a conversation needs from whatever shows it (the app or the debug
/// overlay). Every capability is explicit: a host that can't bring a live
/// simulator large says so, and the conversation then draws live simulators
/// as plain previews instead of buttons that do nothing.
@MainActor
protocol ConversationHost: AnyObject {
    /// Shared simulator streams the turn's live simulator plays from.
    var simulatorFeeds: SimulatorFeeds { get }
    /// Whether `expandSimulator` brings a live simulator large and touchable.
    var expandsSimulators: Bool { get }
    func expandSimulator(_ use: SimulatorUse)
    /// Live simulator blocks at least half on screen in `conversation`;
    /// empty when it goes away.
    func conversation(_ conversation: ThreadViewController, showsSimulators ids: Set<String>)
}

/// The values used most recently, at most `limit`, the least recently used
/// dropped first. Emptied when the system runs low on memory: everything in
/// it can be measured or loaded again.
@MainActor
final class RecentCache<Key: Hashable, Value> {
    private let limit: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private let pressure: Task<Void, Never>

    init(limit: Int) {
        self.limit = limit
        let emptied = WeakBox<RecentCache>()
        pressure = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                guard let cache = emptied.value else { return }
                cache.removeAll()
            }
        }
        emptied.value = self
    }

    deinit { pressure.cancel() }

    func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ value: Value?, for key: Key) {
        guard let value else { values[key] = nil; order.removeAll { $0 == key }; return }
        values[key] = value
        touch(key)
        while order.count > limit { values[order.removeFirst()] = nil }
    }

    func removeAll() {
        values = [:]
        order = []
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

@MainActor
private final class WeakBox<Object: AnyObject> {
    weak var value: Object?
}

/// One conversation with a coding agent, full height. A simulator the agent
/// uses shows in the turn that used it (live, then its recording) and as a
/// floating picture the app shows over every conversation (`SimulatorDock`).
@MainActor
final class ThreadViewController: UIViewController, UITableViewDelegate {
    let project: AppProject
    var onBack: (() -> Void)?
    var currentSessionID: String? { sessionID }
    /// Whatever shows this conversation: simulator streams, bringing a
    /// simulator large, and which live simulators are on screen.
    weak var host: ConversationHost?
    /// Transitional, for a host not yet adopting `ConversationHost`: live
    /// simulators play from these as previews only.
    @available(*, deprecated, message: "Set host")
    var feeds: SimulatorFeeds? {
        get { legacyFeeds }
        set { legacyFeeds = newValue }
    }
    private var legacyFeeds: SimulatorFeeds?
    private var simulatorFeeds: SimulatorFeeds? { host?.simulatorFeeds ?? legacyFeeds }
    /// The app's agent: one conversation per app that runs its threads.
    let isAgent: Bool
    /// The agent's update lines open the app's other threads (nil: a new one).
    var onOpenThread: ((String?) -> Void)?
    /// The app's tasks, with its threads a tab away.
    var onTasks: (() -> Void)?
    var onBuilds: (() -> Void)?
    private let tasks = Theme.glassButton(symbol: "checklist", identifier: "agent.tasks", accessibilityLabel: "Tasks")
    /// Open tasks at a glance, just above the field; tapping opens Tasks.
    private let strip = TaskStrip()
    private var stripGap: NSLayoutConstraint?
    private var stripCollapsed: NSLayoutConstraint?
    private let builds = Theme.glassButton(symbol: "shippingbox", identifier: "agent.builds", accessibilityLabel: "Builds")
    /// The floating buttons at the top, in reading order.
    private var topControls: [UIView] {
        guard isAgent else { return [back, more] }
        return compactControls ? [more] : [back, tasks, builds, more]
    }
    /// The debug overlay's agent shows only ⋯ (its handle closes it, and
    /// Threads and Builds move into the menu). Set before it loads.
    var compactControls = false
    /// The overlay's full-screen toggle, offered in the ⋯ menu.
    var onToggleFull: (() -> Void)?
    var isFull: (() -> Bool)?
    /// The model, approvals and anything without a button of its own.
    private let more = Theme.glassButton(symbol: "ellipsis", identifier: "agent.more", accessibilityLabel: "More")
    /// The model follows one conversation at a time; a thread opened over
    /// this one takes it and gives it back when it closes.
    private var isActive: Bool { model.selectedSessionID == sessionID }

    private let model: SquircleModel
    private var sessionID: String?
    private var selectionReady = false
    private var sending = false
    private var shownAttachments = 0
    private let draftScroll = UIScrollView()
    private var observations: [Task<Void, Never>] = []

    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "thread.close", accessibilityLabel: "Back to threads")
    private var threadTitle = ""
    /// Jump to the latest message, just above the field at the trailing edge.
    private let jump = Theme.glassButton(symbol: "arrow.down", identifier: "thread.jump", accessibilityLabel: "Jump to latest")
    private var jumpShown = false
    private let clip = UIView()
    private let fade = CAGradientLayer()
    private let table = UITableView(frame: .zero, style: .plain)
    private let composer = Composer(placeholder: "Message")
    private lazy var picker = AttachmentPicker(host: self) { [weak self] image in
        if let attachment = ImageAttachment(image) { self?.model.attach(attachment) }
    }
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
    private var pendingSend: (id: String, text: String, images: Int, known: Set<String>)?
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
        get { Self.heightCache.value(for: sessionID ?? "") ?? [:] }
        set { Self.heightCache.set(newValue, for: sessionID ?? "") }
    }
    /// Row heights of the most recently visited threads, so a returning
    /// thread lays out at its true size and opens exactly at the bottom.
    private static let heightCache = RecentCache<String, [String: CGFloat]>(limit: 16)
    private var items: [ThreadItem] = []
    private var itemsByID: [String: ThreadItem] = [:]
    /// The turn the live line belonged to, so only that turn's own finish pulses.
    private var liveTurn: String?
    private var dataSource: UITableViewDiffableDataSource<Int, String>!
    private var rendered: [String: (source: String, text: NSAttributedString)] = [:]
    private var expanded = Set<String>()
    private var pinToBottom = true
    /// The debug overlay's even inset and the safe area its glass will have
    /// at rest (the glass stretches, so UIKit's own would change every frame).
    private var overlayLayout: (inset: CGFloat, safe: UIEdgeInsets, contentWidth: CGFloat?)?
    /// The composer's distance from the bottom, which follows the safe area.
    private var safeBottom: NSLayoutConstraint?
    private var edgeConstraints: [NSLayoutConstraint] = []
    private var safeArea: UIEdgeInsets { overlayLayout?.safe ?? view.safeAreaInsets }

    init(model: SquircleModel, project: AppProject, sessionID: String?, agent: Bool = false) {
        self.isAgent = agent
        self.model = model
        self.project = project
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Back swipes start anywhere along the left edge.
    func allowsBackSwipe(at point: CGPoint) -> Bool { true }

    func focusComposer() { composer.input.becomeFirstResponder() }

    /// The debug overlay's agent closes the overlay instead of going back.
    func setBackButton(symbol: String, label: String) {
        loadViewIfNeeded()
        back.configuration?.image = UIImage(systemName: symbol)
        back.accessibilityLabel = label
    }

    /// Lays the controls out at one inset from every edge of `safe`, for
    /// the debug overlay's glass. `contentWidth` keeps the conversation's
    /// column that wide, centred, however wide the view: docked and full
    /// screen then wrap every line alike, and the overlay can morph between
    /// them laying this out every frame (with the safe area it covers so
    /// far) without a line re-wrapping.
    func setOverlayLayout(inset: CGFloat, safe: UIEdgeInsets, contentWidth: CGFloat? = nil) {
        loadViewIfNeeded()
        guard overlayLayout?.inset != inset || overlayLayout?.safe != safe || overlayLayout?.contentWidth != contentWidth else { return }
        let rebuild = overlayLayout?.inset != inset
        overlayLayout = (inset, safe, contentWidth)
        if rebuild {
            view.keyboardLayoutGuide.usesBottomSafeArea = false
            NSLayoutConstraint.deactivate(edgeConstraints)
            let rest = composer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            rest.priority = .defaultLow
            let bottom = composer.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -inset - safe.bottom)
            safeBottom = bottom
            edgeConstraints = [
                composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
                composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
                composer.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -inset),
                bottom,
                rest,
                jump.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
                request.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
                request.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset)
            ]
            NSLayoutConstraint.activate(edgeConstraints)
        }
        safeBottom?.constant = -inset - safe.bottom
        view.setNeedsLayout()
    }

    /// The system's scroll edge blur can't draw inside a blurred or pictured
    /// layer, so the debug overlay hides it while the glass morphs; the
    /// conversation fades out under the top controls instead.
    func setEdgeEffectsHidden(_ hidden: Bool) {
        loadViewIfNeeded()
        guard #available(iOS 26.0, *) else { return }
        clip.layer.mask = hidden ? fade : nil
        table.topEdgeEffect.isHidden = hidden
        table.bottomEdgeEffect.isHidden = hidden
        table.setNeedsLayout()
        table.layoutIfNeeded()
    }

    /// More ways to attach, below the photo ones: the debug overlay's
    /// screenshot and recordings of the app under it.
    var appAttachments: [UIMenuElement] = [] {
        didSet { if isViewLoaded { composer.attachMenu = attachMenu() } }
    }

    private func attachMenu() -> UIMenu {
        let photos = picker.menu
        guard !appAttachments.isEmpty else { return photos }
        return UIMenu(children: [UIMenu(options: .displayInline, children: photos.children),
                                 UIMenu(options: .displayInline, children: appAttachments)])
    }

    /// The debug overlay's capture is flying into the field: keep its
    /// thumbnail hidden until it lands (nil: show it).
    func holdAttachment(_ id: String?) {
        loadViewIfNeeded()
        composer.held = id.map { [$0] } ?? []
    }

    /// Where an attachment's thumbnail is now (or will appear) in `view`.
    func attachmentFrame(_ id: String, in view: UIView) -> CGRect {
        composer.thumbnailFrame(id, in: view)
    }

    // MARK: Menu

    /// Model and approvals, plus whatever has no button here.
    private func moreMenu() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if isAgent, compactControls {
            items.append(UIAction(title: "Tasks", image: UIImage(systemName: "checklist")) { [weak self] _ in self?.onTasks?() })
            items.append(UIAction(title: "Builds", image: UIImage(systemName: "shippingbox")) { [weak self] _ in self?.onBuilds?() })
        }
        if let onToggleFull {
            let full = isFull?() ?? false
            items.append(UIAction(title: full ? "Make Small" : "Full Screen",
                                  image: UIImage(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")) { _ in onToggleFull() })
        }
        if isAgent, model.agentThreadID(for: project) != nil {
            let project = project
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Restart Agent", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    Task { await self?.model.resetAgent(project, fresh: false) }
                },
                UIMenu(title: "Start Fresh", image: UIImage(systemName: "sparkles"), children: [
                    UIAction(title: "Start Fresh", subtitle: "New conversation; this one stays in Threads", attributes: .destructive) { [weak self] _ in
                        Task { await self?.model.resetAgent(project, fresh: true) }
                    }
                ])
            ]))
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIMenu(title: "Model", subtitle: model.shortAgentName(for: model.modelSelection), image: UIImage(systemName: "cpu"), children: modelMenu()),
            UIMenu(title: "Approvals", subtitle: model.runtimeMode.title, image: UIImage(systemName: model.runtimeMode.symbol), children: approvalMenu())
        ]))
        return items
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
        table.register(FigureCell.self, forCellReuseIdentifier: "figure")
        table.register(SummaryCell.self, forCellReuseIdentifier: "summary")
        table.register(LiveCell.self, forCellReuseIdentifier: "live")
        table.register(BuildCell.self, forCellReuseIdentifier: "build")
        table.register(ChangesCell.self, forCellReuseIdentifier: "changes")
        table.register(SimulatorCell.self, forCellReuseIdentifier: "simulator")
        dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, indexPath, id in
            guard let self, let item = itemsByID[id] else { return UITableViewCell() }
            let cell = table.dequeueReusableCell(withIdentifier: Self.reuseIdentifier(for: item), for: indexPath)
            configure(cell, with: item)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
        table.accessibilityIdentifier = "thread.messages"
        // iOS 26 blurs the top scroll edge itself; earlier systems fade it.
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        if #unavailable(iOS 26.0) { clip.layer.mask = fade }
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

        // Built when opened, so live updates never reset a menu you are reading.
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreMenu() ?? []) }])
        back.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onBack?() }, for: .touchUpInside)
        view.addSubview(back)
        if isAgent {
            back.accessibilityLabel = "Apps"
            tasks.addAction(UIAction { [weak self] _ in self?.onTasks?() }, for: .touchUpInside)
            builds.addAction(UIAction { [weak self] _ in self?.onBuilds?() }, for: .touchUpInside)
            [tasks, builds].forEach(view.addSubview)
        }
        view.addSubview(more)
        [back, tasks, builds, more].forEach { $0.isHidden = !topControls.contains($0) }

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
        composer.attachMenu = attachMenu()
        composer.onImages = { [weak self] images in
            for image in images { if let attachment = ImageAttachment(image) { self?.model.attach(attachment) } }
        }
        composer.onRemoveAttachment = { [weak self] id in self?.model.removeAttachment(id) }
        jump.alpha = 0
        jump.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        jump.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.selectionHaptic()
            pinToBottom = true
            scrollToBottom(animated: true)
            setJumpShown(false)
        }, for: .touchUpInside)
        jump.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        jump.configuration?.contentInsets = .zero
        strip.isHidden = true
        strip.addAction(UIAction { [weak self] _ in self?.onTasks?() }, for: .touchUpInside)
        [request, notice, jump, strip, composer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        let stripGap = strip.bottomAnchor.constraint(equalTo: composer.topAnchor)
        let stripCollapsed = strip.heightAnchor.constraint(equalToConstant: 0)
        self.stripGap = stripGap
        self.stripCollapsed = stripCollapsed
        edgeConstraints = [
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            jump.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            request.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            request.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ]
        NSLayoutConstraint.activate(edgeConstraints + [
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stripGap, stripCollapsed,
            strip.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            jump.bottomAnchor.constraint(equalTo: strip.topAnchor, constant: -8),
            jump.widthAnchor.constraint(equalToConstant: 34), jump.heightAnchor.constraint(equalToConstant: 34),
            notice.bottomAnchor.constraint(equalTo: strip.topAnchor, constant: -8),
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
            for control in [back, more] {
                let top = UIScrollEdgeElementContainerInteraction()
                top.scrollView = table
                top.edge = .top
                control.addInteraction(top)
            }
            let bottom = UIScrollEdgeElementContainerInteraction()
            bottom.scrollView = table
            bottom.edge = .bottom
            composer.addInteraction(bottom)
        }
        view.accessibilityElements = topControls + [draftScroll, table, request, notice, jump, strip, composer]

        observations = [model.observe(by: self, after: .milliseconds(50)) { $0.render() }]
        model.selectProject(project)
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
        // Bounds and centre: the overlay's handle may be shifting them.
        let x = overlayLayout?.inset ?? 16, y = safeArea.top + (overlayLayout?.inset ?? 4)
        back.place(in: CGRect(x: x, y: y, width: 44, height: 44))
        tasks.place(in: CGRect(x: x + 54, y: y, width: 44, height: 44))
        builds.place(in: CGRect(x: x + 108, y: y, width: 44, height: 44))
        more.place(in: CGRect(x: view.bounds.width - x - 44, y: y, width: 44, height: 44))
        layoutConversation()
    }

    /// The bottom of the top controls, without the overlay's shift.
    private var controlsBottom: CGFloat { safeArea.top + (overlayLayout?.inset ?? 4) + 44
    }

    /// The conversation runs the full height beneath the floating controls.
    private func layoutConversation() {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        let width = view.bounds.width, height = view.bounds.height
        clip.frame = view.bounds
        // Taller or shorter (the overlay's handle), what shows at the bottom
        // stays where it was: the conversation grows and shrinks at its top.
        // Rows coming into view are measured, which can change the content's
        // height, so the offset is settled against the content's end.
        let previous = table.bounds.height
        let gap = table.contentSize.height + table.contentInset.bottom - (table.contentOffset.y + previous)
        let column = min(width, overlayLayout?.contentWidth ?? width)
        table.frame = CGRect(x: ((width - column) / 2).rounded(), y: 0, width: column, height: height)
        if previous > 0, abs(previous - height) > 0.5, pinToBottom {
            scrollToBottom()
        } else if previous > 0, abs(previous - height) > 0.5, !table.isTracking {
            for _ in 0..<3 {
                let y = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - height - gap)
                if abs(table.contentOffset.y - y) < 0.5 { break }
                table.contentOffset.y = y
                table.layoutIfNeeded()
            }
        }
        placeFade()
        // The jump button floats over the conversation; it takes no row.
        let field = strip.isHidden ? composer.frame.minY : strip.frame.minY
        let floor = request.isHidden ? (notice.isHidden ? field : notice.frame.minY) : request.frame.minY
        draftScroll.frame = CGRect(x: 0, y: 0, width: width, height: max(0, floor - 8))
        let insets = UIEdgeInsets(top: controlsBottom + 6, left: 0, bottom: height - floor + 10, right: 0)
        if table.contentInset != insets {
            let pinned = pinToBottom
            table.contentInset = insets
            if pinned { scrollToBottom() }
        }
    }

    /// The conversation fades out under the top controls, from the top of
    /// what shows.
    private func placeFade() {
        let height = max(1, view.bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        let faded = overlayLayout == nil ? safeArea.top + 20 : controlsBottom
        fade.startPoint = CGPoint(x: 0.5, y: min(1, visibleTop / height))
        fade.endPoint = CGPoint(x: 0.5, y: min(1, (visibleTop + faded) / height))
        CATransaction.commit()
    }

    /// The debug overlay's handle reveals this view from the bottom without
    /// laying it out again: the top `y` points are hidden above its glass.
    /// The top controls and the fade ride the visible top edge.
    func setVisibleTop(_ y: CGFloat) {
        guard y != visibleTop else { return }
        visibleTop = y
        let shift = CGAffineTransform(translationX: 0, y: y)
        for control in [back, tasks, builds, more] { control.transform = shift }
        placeFade()
    }
    private var visibleTop: CGFloat = 0

    /// Floating controls fade as the thread leaves, so they never cross
    /// Home's own controls coming the other way.
    func setTransitionProgress(_ progress: CGFloat) {
        let alpha = ((progress - 0.55) / 0.45).clamped()
        back.alpha = alpha
        tasks.alpha = alpha
        more.alpha = alpha
        builds.alpha = alpha
        jump.alpha = jumpShown ? alpha : 0
        let shown = progress > 0.001
        if shown != onScreen {
            onScreen = shown
            for case let cell as SimulatorCell in table.visibleCells { cell.showing = shown }
        }
    }
    /// Some of this conversation is in sight; live simulators stream only then.
    private var onScreen = true

    // MARK: Content

    /// A thread opened over this one closed: take the model back.
    func reactivate() {
        Task { [weak self] in
            guard let self, !tornDown else { return }
            if let sessionID { await model.selectSession(sessionID) } else { await model.beginDraft(agent: isAgent) }
            render()
        }
    }
    /// A thread is opening over this one.
    func deactivate() {}

    private func render() {
        guard isViewLoaded, isActive || !selectionReady else { return }
        guard selectionReady else {
            composer.send.isEnabled = false
            table.isHidden = true
            draftScroll.isHidden = true
            return
        }
        // The Mac may report the app's agent after this opened as a draft,
        // or a new one after a fresh start.
        if isAgent, !sending, pendingSend == nil, let id = model.agentThreadID(for: project), id != sessionID {
            sessionID = id
            pinToBottom = true
            model.prepareSession(id)
            Task { [weak self] in await self?.model.selectSession(id) }
        }
        composer.send.isEnabled = !sending
        draftScroll.isHidden = showsConversation
        table.isHidden = !showsConversation
        view.accessibilityElements = topControls + [showsConversation ? table : draftScroll, request, notice, jump, strip, composer]
        let session = model.sessions.first { $0.id == sessionID }
        threadTitle = isAgent ? project.name : session?.displayTitle(in: project) ?? ""
        renderAgent()
        renderStrip()
        let attached = model.attachments.count
        composer.show(model.attachments)
        if attached != shownAttachments, view.window != nil {
            UIView.animate(springDuration: 0.4, bounce: 0.15, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
                self.view.layoutIfNeeded()
            }
        }
        shownAttachments = attached
        renderSend()
        renderRequest()
        // A brief reconnect is silent; the model reports one that keeps failing.
        let error = model.error
        if notice.text != error || notice.isHidden != (error == nil) {
            notice.text = error
            notice.isHidden = error == nil
            notice.textColor = model.error == nil ? .secondaryLabel : Theme.failure
            view.setNeedsLayout()
        }
        renderItems()
    }

    /// Shown on the app's agent while it has open tasks.
    private func renderStrip() {
        let open = isAgent ? model.tasks(for: project).tasks.filter { $0.status.open } : []
        let hidden = open.isEmpty
        strip.configure(open)
        guard hidden != strip.isHidden else { return }
        strip.isHidden = hidden
        stripCollapsed?.isActive = hidden
        stripGap?.constant = hidden ? 0 : -8
        view.setNeedsLayout()
    }

    private func renderAgent() {
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
        let stop = model.isRunning && composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty
        let symbol = stop ? "stop.fill" : "arrow.up"
        if composer.send.accessibilityValue != symbol {
            composer.send.accessibilityValue = symbol
            composer.send.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: composer.sendSymbolSize, weight: .bold))
            composer.send.accessibilityLabel = stop ? "Stop agent" : "Send message"
        }
    }

    private static func reuseIdentifier(for item: ThreadItem) -> String {
        switch item {
        case .header: return "header"
        case .user, .update, .answer, .note, .thought, .agentMessage, .action: return "message"
        case .step, .earlier: return "step"
        case .gallery: return "gallery"
        case .figure: return "figure"
        case .summary: return "summary"
        case .live: return "live"
        case .build: return "build"
        case .changes: return "changes"
        case .simulator: return "simulator"
        }
    }

    private func renderItems(animated: Bool = false) {
        let header: [ThreadItem] = threadTitle.isEmpty ? [] : [.header(threadTitle)]
        let messages = displayedMessages()
        let next = header + resolve(ThreadItem.items(messages: messages, running: model.isRunning, expanded: expanded,
                                                     builds: model.builds, changes: model.changes,
                                                     simulators: model.threadSimulators))
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
        reportVisibleSimulators()
        // Only the turn that was live pulses, when it folds into its own
        // summary; a quick reply with no steps must not light up an older one.
        let wasLive = liveTurn
        liveTurn = itemsByID["live"] == nil ? nil : messages.last(where: { $0.role == "user" })?.id ?? "start"
        if previous["live"] != nil, liveTurn == nil, let turn = wasLive, itemsByID["summary:" + turn] != nil {
            celebrate("summary:" + turn)
        }
    }

    /// Names and live states for the workers action lines mention.
    private func resolve(_ items: [ThreadItem]) -> [ThreadItem] {
        guard items.contains(where: { if case .action = $0 { return true }; return false }) else { return items }
        let workers = model.workers
        let sessions = Dictionary(model.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item in
            guard case .action(var line) = item else { return item }
            // A spawn's output is often cut short before it names the thread.
            if line.thread == nil, case .action(let action) = line.kind, action.kind == .spawn {
                line.thread = workers.first { action.branch != nil && $0.value.branch == action.branch }?.key
                    ?? workers.first { action.title != nil && $0.value.title == action.title }?.key
                    ?? sessions.values.first { action.title != nil && $0.title == action.title }?.id
            }
            guard let id = line.thread else {
                if case .action(let action) = line.kind, action.unconfirmed { return nil }
                line.name = line.title
                return .action(line)
            }
            let session = sessions[id], known = workers[id]
            line.name = session?.displayTitle(in: project) ?? known?.title ?? line.title
            switch (session?.phase, known?.state) {
            case (.working?, _): line.state = .working
            case (.needsYou?, _): line.state = .needsYou
            case (.idle?, .error?): line.state = .error
            case (.idle?, _): line.state = .done
            case (nil, let state): line.state = state ?? .archived
            }
            return .action(line)
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
                var message = ChatMessage(id: pending.id, role: "user", content: pending.text,
                                          createdAt: ISO8601DateFormatter().string(from: .now))
                message.attachments = (0..<pending.images).map { "local-\($0)" }
                messages.append(message)
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
        reportVisibleSimulators()
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
        case .agentMessage(let message):
            let open = expanded.contains(message.id)
            (cell as? MessageCell)?.configure(message, style: .agent, rendered: agentText(message), expanded: open)
        case .action(let line):
            let open = expanded.contains(line.id)
            let message = ChatMessage(id: line.id, role: "tool", content: "")
            (cell as? MessageCell)?.configure(message, style: .action, rendered: actionText(line, expanded: open), expanded: open)
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
            cell.configure(shots, indent: id.hasPrefix("gallery:earlier:") || itemsByID[String(id.dropFirst(8))] != nil ? 56 : 20, id: id,
                           trailing: id.hasPrefix("gallery:sent:"))
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
            for shot in shots where GalleryCell.image(for: shot) == nil { loadImage(shot, item: id) }
        case .figure(let id, let shots):
            guard let cell = cell as? FigureCell else { return }
            cell.configure(shots, width: table.bounds.width)
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
            for shot in shots where FigureCell.image(for: shot) == nil { loadFigure(shot, item: id) }
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
        case .simulator(let use):
            guard let cell = cell as? SimulatorCell else { return }
            let stepID = use.recordingID.map { "media:" + $0 }
            let tappable = !use.live || host?.expandsSimulators == true
            cell.configure(use, feeds: simulatorFeeds, video: stepID.flatMap(StepVideos.url(for:)), tappable: tappable)
            cell.showing = onScreen
            cell.onTap = tappable ? { [weak self] in self?.openSimulator(use) } : nil
            if let stepID, StepVideos.url(for: stepID) == nil { loadRecording(stepID, item: item.id) }
        }
    }

    private var loadingRecordings = Set<String>()
    private func loadRecording(_ stepID: String, item: String) {
        guard loadingRecordings.insert(stepID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            let url = await model.loadVideo(stepID)
            loadingRecordings.remove(stepID)
            guard url != nil, dataSource.indexPath(for: item) != nil else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([item])
            await dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// Live: large over the conversation. Recorded: the recording, full screen.
    private func openSimulator(_ use: SimulatorUse) {
        if use.live {
            if let host, host.expandsSimulators { host.expandSimulator(use) }
            return
        }
        guard let id = use.recordingID, presentedViewController == nil else { return }
        Task { [weak self] in
            guard let self, let url = await model.loadVideo("media:" + id) else { return }
            let player = AVPlayerViewController()
            player.player = AVPlayer(url: url)
            present(player, animated: true) { player.player?.play() }
        }
    }

    /// Live simulator blocks at least half on screen.
    private func reportVisibleSimulators() {
        guard let host else { return }
        let visible = table.bounds.inset(by: table.contentInset)
        var ids = Set<String>()
        for cell in table.visibleCells {
            guard let cell = cell as? SimulatorCell, let use = cell.use, use.live else { continue }
            let frame = cell.convert(cell.screen.frame, to: table)
            if frame.intersection(visible).height > frame.height * 0.5 { ids.insert(use.id) }
        }
        if ids != reportedSimulators {
            reportedSimulators = ids
            host.conversation(self, showsSimulators: ids)
        }
    }
    private var reportedSimulators = Set<String>()

    private func text(for message: ChatMessage, style: MessageCell.Style) -> NSAttributedString {
        let key = message.id + "\(style)"
        if let cached = rendered[key], cached.source == message.content { return cached.text }
        let text: NSAttributedString
        switch style {
        case .user:
            text = NSAttributedString(string: message.content, attributes: [.font: Theme.font(.body, 17), .foregroundColor: UIColor.label])
        case .note, .thought, .action, .agent:
            text = Markdown.render(message.content, font: Theme.font(.subheadline, 15), color: .secondaryLabel)
        case .answer:
            text = Markdown.render(message.content, font: Theme.font(.body, 17), color: message.failed ? Theme.failure : .label)
        case .update:
            let font = Theme.font(.footnote, 13, .medium)
            let line = NSMutableAttributedString()
            if let symbol = UIImage(systemName: message.symbol.isEmpty ? "arrow.triangle.merge" : message.symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
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

    /// "Task from Squircle agent" over the task, rendered.
    private func agentText(_ message: ChatMessage) -> NSAttributedString {
        let from = message.agent?.from.flatMap { id in model.sessions.first { $0.id == id } }?.displayTitle(in: project)
        let task = message.agent?.kind == .task
        let label = (task ? "Task from " : "From ") + (from ?? (task ? "the app’s agent" : "an agent"))
        let key = message.id + "agent"
        if let cached = rendered[key], cached.source == label + message.content { return cached.text }
        let font = Theme.font(.footnote, 13, .semibold)
        let text = NSMutableAttributedString()
        if let symbol = UIImage(systemName: task ? "list.bullet.rectangle" : "arrow.down.message",
                                withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: label + "\n"))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        text.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style],
                           range: NSRange(location: 0, length: text.length))
        text.append(Markdown.render(message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                                    font: Theme.font(.subheadline, 15), color: .label))
        rendered[key] = (label + message.content, text)
        return text
    }

    /// "Started worker · Dark mode  working", with the worker's live state.
    private func actionText(_ line: ActionLine, expanded: Bool) -> NSAttributedString {
        let font = Theme.font(.subheadline, 15), bold = Theme.font(.subheadline, 15, .semibold)
        let name = line.name ?? "a worker"
        let text = NSMutableAttributedString()
        func add(_ string: String, _ font: UIFont, _ color: UIColor = .label) {
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        let symbol: String
        var state: (String, UIColor)?
        switch line.kind {
        case .news(let news):
            symbol = news == .needsYou ? "questionmark.bubble" : news == .error ? "exclamationmark.bubble" : "checkmark.bubble"
            add("From ", bold); add(name, font)
            state = news == .needsYou ? ("needs you", Theme.warning) : news == .error ? ("stopped with an error", Theme.failure) : ("finished", Theme.success)
        case .action(let action):
            symbol = action.symbol
            switch action.kind {
            case .spawn:
                add(action.verb, bold); add(" · " + name, font)
                if let live = line.state {
                    let colors: [WorkerState: UIColor] = [.working: Theme.accent, .done: Theme.success, .needsYou: Theme.warning, .error: Theme.failure]
                    state = (live.word, colors[live] ?? .tertiaryLabel)
                }
            case .send, .answer:
                add(action.verb + " ", bold); add(name, font)
                if let message = action.text?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty, !expanded {
                    let first = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
                    add(" · " + first, font, .secondaryLabel)
                }
            case .read: add("Read ", bold); add(name + "’s reply", font)
            case .archive: add("Archived ", bold); add(name, font)
            case .buildStart: add(action.verb, bold); if let app = action.app { add(" · " + app, font) }
            default: add(action.verb, bold)
            }
        }
        if line.failed { state = ("failed", Theme.failure) }
        if let (word, color) = state { add("  " + word, Theme.font(.footnote, 13, .medium), color) }
        if let symbol = UIImage(systemName: line.failed ? "exclamationmark" : symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.footnote, 13, .medium)))?
            .withTintColor(line.failed ? Theme.failure : line.running ? Theme.accent : .secondaryLabel, renderingMode: .alwaysOriginal) {
            text.insert(NSAttributedString(string: "  ", attributes: [.font: font]), at: 0)
            text.insert(NSAttributedString(attachment: NSTextAttachment(image: symbol)), at: 0)
        }
        // Wrapped lines start under the text, not the icon.
        let hanging = NSMutableParagraphStyle()
        hanging.headIndent = 27
        hanging.paragraphSpacing = 4
        text.addAttribute(.paragraphStyle, value: hanging, range: NSRange(location: 0, length: text.length))
        if expanded, let message = line.text?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            add("\n", font)
            text.append(Markdown.render(message, font: Theme.font(.subheadline, 15), color: .secondaryLabel))
        }
        return text
    }

    private func tappable(_ item: ThreadItem?) -> Bool {
        switch item {
        case .agentMessage: return true
        case .action(let line): return line.text?.isEmpty == false || (line.thread != nil && line.state != .archived && onOpenThread != nil)
        case .step(let message, _, _): return !message.detail.isEmpty || message.step?.diff != nil
        case .earlier, .summary, .note, .changes: return true
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
        case .agentMessage(let message): return min(9, lines(message.content, per: 7.6)) * 20 + 40
        case .action: return 34
        case .answer(let message): return lines(message.content, per: 8.6) * 23 + 20
        case .note(let message): return min(4, lines(message.content, per: 7.6)) * 20 + 12
        case .thought: return 52
        case .step, .earlier: return 36
        case .gallery: return GalleryCell.height + 20
        case .figure(_, let shots): return FigureCell.height(shots, width: tableView.bounds.width)
        case .summary: return 54
        case .live: return 72
        case .build: return 74
        case .changes: return 46
        case .simulator: return SimulatorCell.height + 16
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
        case .note(let message): toggle(message.id)
        case .update(let message): if let id = message.threadIDs.first { onOpenThread?(id) }
        case .agentMessage(let message): toggle(message.id)
        case .action(let line):
            // T3 no longer lists an archived worker's thread.
            if line.text?.isEmpty == false { toggle(line.id) } else if let id = line.thread, line.state != .archived { onOpenThread?(id) }
        default: break
        }
    }

    private func toggle(_ id: String) {
        Theme.selectionHaptic()
        if !expanded.insert(id).inserted { expanded.remove(id) }
        let keepBottom = pinToBottom
        pinToBottom = false
        renderItems(animated: true)
        // A note's fold isn't part of its item, so its row refreshes itself.
        if case .note = itemsByID[id] {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([id])
            dataSource.apply(snapshot, animatingDifferences: true)
        }
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
            let data = await model.loadStepImage(shot.step, index: shot.index, attachment: shot.attachment)
            loadingImages.remove(key)
            guard data != nil, dataSource.indexPath(for: item) != nil else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([item])
            await dataSource.apply(snapshot, animatingDifferences: false)
            if pinToBottom { scrollToBottom(animated: true) }
        }
    }

    /// Its size first, so the conversation makes room once, then the picture.
    private func loadFigure(_ shot: Shot, item: String) {
        guard loadingImages.insert(shot.step).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            if MediaFiles.sizes[shot.step] == nil, await model.mediaSize(shot.step) != nil { await reconfigure(item) }
            let data = await model.loadStepImage(shot.step, index: shot.index)
            loadingImages.remove(shot.step)
            if data != nil { await reconfigure(item) }
        }
    }

    private func reconfigure(_ item: String) async {
        guard dataSource.indexPath(for: item) != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([item])
        await dataSource.apply(snapshot, animatingDifferences: false)
        if pinToBottom { scrollToBottom(animated: true) }
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
        let images = model.attachments
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, images.isEmpty {
            if model.isRunning { Task { await model.stop() } }
            return
        }
        sending = true
        composer.send.isEnabled = false
        Theme.openHaptic()
        let source = composer.textOrigin(in: view)
        let local = "local:" + UUID().uuidString
        // Your pictures show in the conversation from the bytes on hand.
        for (index, image) in images.enumerated() { StepImages.set(image.data, for: local, index: index) }
        pendingSend = (local, text, images.count, Set(model.messages.filter { $0.role == "user" }.map(\.id)))
        flyingID = Motion.reduced ? nil : local
        composer.text = ""
        pinToBottom = true
        render()
        flySend(id: local, from: source)
        let origin = sessionID
        Task { [weak self, model, project, isAgent] in
            let outcome = await model.send(text, in: project, to: origin, agent: isAgent)
            // The answer belongs to the conversation that sent it: a draft
            // becomes the thread T3 created, and nothing else moves.
            guard let self, !tornDown else { return }
            sending = false
            switch outcome {
            case .sent(let id):
                if sessionID == origin, origin == nil || origin == id { sessionID = id }
            case .failed:
                // A message the Mac did not accept goes back into the field.
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

    /// Removed from the screen for good: stops everything that could still
    /// change shared state (a removed controller can outlive its view while
    /// a load finishes).
    private var tornDown = false

    func tearDown() {
        tornDown = true
        observations.forEach { $0.cancel() }
        observations = []
        onBack = nil
        host?.conversation(self, showsSimulators: [])
        host = nil
        legacyFeeds = nil
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
        pendingSend = (local, text, 0, Set(model.messages.filter { $0.role == "user" }.map(\.id)))
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
    /// Verification only: replays the finished-turn pulse on the last summary.
    func debugPulse() {
        guard let last = items.last(where: { if case .summary = $0 { return true }; return false }),
              let index = dataSource.indexPath(for: last.id) else { return }
        pinToBottom = false
        table.scrollToRow(at: index, at: .middle, animated: false)
        table.layoutIfNeeded()
        (table.cellForRow(at: index) as? SummaryCell)?.celebrate()
    }
    #endif

    override func accessibilityPerformEscape() -> Bool {
        onBack?()
        return true
    }
}
