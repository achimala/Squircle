import AVFoundation
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
    /// Whether the conversation's agent sits by its live step as a jelly
    /// (the overlay's own creature is that jelly already).
    var showsAgentJelly: Bool { get }
}

/// The conversation's table, reporting each layout pass and whether it
/// began at the content's end.
final class ConversationTable: UITableView {
    var onLayout: ((_ wasAtEnd: Bool) -> Void)?

    override func layoutSubviews() {
        let end = max(-contentInset.top, contentSize.height + contentInset.bottom - bounds.height)
        let wasAtEnd = abs(contentOffset.y - end) < 1
        super.layoutSubviews()
        onLayout?(wasAtEnd)
    }

    /// Rows measured against their estimates can shrink the content
    /// under the offset; UIKit then pulls the offset back with an animated
    /// scroll, which starts past the end (nothing showing) and drags through
    /// older rows. That correction lands at once.
    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            resizing = true
            super.contentSize = newValue
            resizing = false
        }
    }
    private var resizing = false

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(contentOffset, animated: animated && !resizing)
    }
}

/// One conversation with a coding agent, full height. A simulator the agent
/// uses shows in the turn that used it (live, then its recording) and as a
/// floating picture the app shows over every conversation (`SimulatorDock`).
@MainActor
final class ThreadViewController: UIViewController, UITableViewDelegate {
    let project: AppProject
    var onBack: (() -> Void)?
    var currentSessionID: String? { conversation.threadID }
    /// Whatever shows this conversation: simulator streams, bringing a
    /// simulator large, and which live simulators are on screen.
    weak var host: ConversationHost?
    private var simulatorFeeds: SimulatorFeeds? { host?.simulatorFeeds }
    /// The app's agent: one conversation per app that runs its threads.
    let isAgent: Bool
    /// The agent's update lines open the app's other threads (nil: a new one).
    var onOpenThread: ((String?) -> Void)?
    /// A finger went down on a line that opens a thread: its page can be made ahead.
    var onPrepareThread: ((String) -> Void)?
    /// A finger started scrolling it instead.
    var onScrollBegan: (() -> Void)?
    /// The app's tasks, with its threads a tab away.
    var onTasks: (() -> Void)?
    /// What waits on you, this app's first.
    var onWaiting: (() -> Void)?
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
    /// The ⋯ menu leads with the Mac connection (the overlay has no Home button for it).
    var showsConnection = false
    var isFull: (() -> Bool)?
    /// The model, approvals and anything without a button of its own.
    private let more = Theme.glassButton(symbol: "ellipsis", identifier: "agent.more", accessibilityLabel: "More")
    /// The model follows one conversation at a time. Whoever shows this one
    /// says whether it is in front (`deactivate`/`reactivate`); in front, it
    /// has the model while the model has this very conversation open.
    private var isActive: Bool { active && model.openConversation == conversation }
    private var active: Bool

    private let model: SquircleModel
    /// Which conversation this is. Only the model's record of a draft
    /// becoming a thread (`successor`) or the app's agent moving on changes it.
    private var conversation: ConversationID {
        didSet {
            guard conversation != oldValue else { return }
            Self.heightCache.set(heights, for: oldValue)
            heights = Self.heightCache.value(for: conversation) ?? [:]
            guesses = [:]
        }
    }
    /// Keeps this conversation's published media fresh while it is in front.
    private var freshness: RefreshLease?
    /// Keeps the app's tasks fresh while the agent's task strip shows.
    private var taskFreshness: RefreshLease?
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
    private let table = ConversationTable(frame: .zero, style: .plain)
    private let composer: Composer
    private lazy var picker = AttachmentPicker(host: self) { [weak self] attachment in self?.model.attach(attachment) }
    private let notice = Theme.label("", Theme.font(.footnote, 13), color: Theme.failure, lines: 3)
    private let requestCard = RequestCard()
    private var request: UIVisualEffectView { requestCard.view }

    private var flyingID: String?
    /// Your message on its way to the Mac, until T3's thread has it.
    private var pendingSend: PendingSend? { model.pendingSend(for: conversation) }
    private var showsConversation: Bool { conversation.threadID != nil || pendingSend != nil }
    /// An expanded turn's summary, pinned to the top while you read inside
    /// that turn; tapping it folds the turn back up.
    private let sticky = SummaryCell(style: .default, reuseIdentifier: nil)
    private var stickyTurn: String?
    /// Measured row heights, so long conversations keep their place while
    /// rows above are measured, expanded or folded.
    /// This conversation's, kept with the others' (`heightCache`) when it
    /// moves on or is put away.
    private var heights: [String: CGFloat] = [:]
    /// Rows' guessed heights until measured, worked out once per row (from
    /// their text) rather than each time the table asks.
    private var guesses: [String: CGFloat] = [:]
    private var guessWidth: CGFloat = 0
    /// Row heights of the most recently visited threads, so a returning
    /// thread lays out at its true size and opens exactly at the bottom.
    private static let heightCache = RecentCache<ConversationID, [String: CGFloat]>(limit: 16)
    private var items: [ThreadItem] = []
    private var itemsByID: [String: ThreadItem] = [:]
    /// The turn the live line belonged to, so only that turn's own finish pulses.
    private var liveTurn: String?
    private var dataSource: UITableViewDiffableDataSource<Int, String>!
    /// Row text rendered once per source; tables measured per width and text size.
    private let rowText = ConversationText()
    private var expanded = Set<String>()
    private var pinToBottom = true
    /// The debug overlay's even inset and the safe area its glass will have
    /// at rest (the glass stretches, so UIKit's own would change every frame).
    private var overlayLayout: (inset: CGFloat, safe: UIEdgeInsets, contentWidth: CGFloat?)?
    /// The composer's distance from the bottom, which follows the safe area.
    private var safeBottom: NSLayoutConstraint?
    private var edgeConstraints: [NSLayoutConstraint] = []
    private var safeArea: UIEdgeInsets { overlayLayout?.safe ?? view.safeAreaInsets }

    /// A thread of `project`, or with nil a new conversation (its agent's
    /// first, with `agent`).
    /// `ahead`: made before its push, off screen; it shows the thread's
    /// copy in memory and leaves the model alone until `resume`.
    /// `composer`: one made a frame earlier, when the page is made ahead in steps.
    init(model: SquircleModel, project: AppProject, sessionID: String?, agent: Bool = false, ahead: Bool = false, composer: Composer? = nil) {
        self.composer = composer ?? Composer(placeholder: "Message")
        self.isAgent = agent
        self.model = model
        self.project = project
        self.conversation = sessionID.map { .thread($0, appID: project.id) } ?? .draft(UUID(), appID: project.id, agent: agent)
        self.active = !ahead
        super.init(nibName: nil, bundle: nil)
        heights = Self.heightCache.value(for: conversation) ?? [:]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Back swipes start anywhere along the left edge.
    func allowsBackSwipe(at point: CGPoint) -> Bool { true }

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
        // In the overlay: how the Mac connection is, first.
        if showsConnection { items.append(ConnectionMenu.section(model)) }
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["SQUIRCLE_TASKS"] == nil { ScrollSweep.start(table) }
        #endif
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.keyboardDismissMode = .interactive
        table.showsVerticalScrollIndicator = false
        table.contentInsetAdjustmentBehavior = .never
        table.delegate = self
        table.onLayout = { [weak self] wasAtEnd in self?.keepEnd(wasAtEnd) }
        table.estimatedRowHeight = 60
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(HeaderCell.self, forCellReuseIdentifier: "header")
        table.register(StepCell.self, forCellReuseIdentifier: "step")
        table.register(GalleryCell.self, forCellReuseIdentifier: "gallery")
        table.register(FigureCell.self, forCellReuseIdentifier: "figure")
        table.register(MarkdownTableCell.self, forCellReuseIdentifier: "table")
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
        // A finger down on a line that opens a thread: its page can start being made.
        table.addGestureRecognizer(TouchDown { [weak self] point in
            guard let self, let path = table.indexPathForRow(at: point),
                  let id = opens(dataSource.itemIdentifier(for: path).flatMap { self.itemsByID[$0] }) else { return }
            onPrepareThread?(id)
        })
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

        requestCard.onRespond = { [weak self] request, decision, answers in
            Task { await self?.model.respond(to: request, decision: decision, answers: answers) }
        }
        requestCard.onResize = { [weak self] in
            guard let self else { return }
            view.setNeedsLayout()
            UIView.animate(withDuration: 0.4) { self.view.layoutIfNeeded() }
        }
        notice.isHidden = true
        notice.accessibilityIdentifier = "thread.error"
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in self?.renderSend() }
        composer.attachMenu = attachMenu()
        composer.onAttachments = { [weak self] attachments in
            for attachment in attachments { self?.model.attach(attachment) }
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
        // While something here waits on you, the strip opens that; else Tasks.
        strip.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if model.waiting.apps.contains(where: { [project] in $0.projectID == project.id }) { onWaiting?() } else { onTasks?() }
        }, for: .touchUpInside)
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
            strip.centerXAnchor.constraint(equalTo: composer.centerXAnchor),
            strip.leadingAnchor.constraint(greaterThanOrEqualTo: composer.leadingAnchor),
            jump.bottomAnchor.constraint(equalTo: strip.topAnchor, constant: -8),
            jump.widthAnchor.constraint(equalToConstant: 34), jump.heightAnchor.constraint(equalToConstant: 34),
            notice.bottomAnchor.constraint(equalTo: strip.topAnchor, constant: -8),
            request.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -8)
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
        guard active else {
            // Made ahead: the thread's copy in memory, its rows worked out and built later (`prepareRows`).
            preparedHeight = 0
            threadTitle = model.sessions.first { $0.id == conversation.threadID }?.displayTitle(in: project) ?? ""
            draftScroll.isHidden = true
            return
        }
        model.selectProject(project)
        // What was last seen of this thread shows right away, at the bottom.
        open(conversation)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsMediaPass()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        setNeedsMediaPass()
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
        // A page made ahead shows only its bottom part until it is ready (`prepareRows`).
        let shown = min(height, preparedHeight ?? height)
        table.frame = CGRect(x: ((width - column) / 2).rounded(), y: height - shown, width: column, height: shown)
        if previous > 0, abs(previous - shown) > 0.5, pinToBottom {
            scrollToBottom()
        } else if previous > 0, abs(previous - shown) > 0.5, !table.isTracking {
            for _ in 0..<3 {
                let y = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - shown - gap)
                if abs(table.contentOffset.y - y) < 0.5 { break }
                table.contentOffset.y = y
                table.layoutIfNeeded()
            }
        }
        placeFade()
        setNeedsMediaPass()
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
        for control in [back, tasks, more, builds] { control.update(\.alpha, to: alpha) }
        jump.update(\.alpha, to: jumpShown ? alpha : 0)
        let shown = progress > 0.001
        if shown != onScreen {
            onScreen = shown
            // `visibleCells` lays the table out first; only simulators need it.
            if hasSimulators { for case let cell as SimulatorCell in table.visibleCells { cell.showing = shown } }
            setNeedsMediaPass()
        }
    }
    /// Some of this conversation is in sight; live simulators stream only then.
    private var onScreen = true

    // MARK: Content

    /// A thread opened over this one closed: it is in front again.
    func reactivate() {
        guard !tornDown, !active else { return }
        outOfSight = false
        covered = false
        active = true
        open(conversation)
        // What arrived while it was covered is not news to watch arrive:
        // it is in place when it shows (`resuming`).
        let wasResuming = resuming
        resuming = true
        render()
        resuming = wasResuming
    }
    /// A thread is opening over this one; it lets go of the model.
    func deactivate() {
        covered = isAgent
        active = false
        freshness = nil
        taskFreshness = nil
    }

    /// Closed and off screen, kept to be shown again: it lets go of the
    /// model and of the simulators it showed.
    func park() {
        Self.heightCache.set(heights, for: conversation)
        deactivate()
        view.endEditing(true)
        if !reportedSimulators.isEmpty { host?.conversation(self, showsSimulators: []) }
        reportedSimulators = []
    }

    /// Parked, it opens again as a new page would: at the bottom, its turns
    /// folded, the field empty, what changed meanwhile already in place.
    func resume() {
        guard !tornDown, !active else { return }
        // Whatever of a page made ahead is not built yet is built now.
        if preparedHeight != nil, items.isEmpty { renderItems() }
        finishRows()
        expanded = []
        composer.text = ""
        pinToBottom = true
        jumpShown = false
        jump.alpha = 0
        jump.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        reactivate()
        scrollToBottom()
        renderSend()
    }
    /// A parked page put to use for another thread of the app: its view,
    /// controls and the table's cells stay; everything of the old thread
    /// goes. Its rows are then built like a page made ahead (`prepareRows`).
    func retarget(to sessionID: String) {
        guard !active, !tornDown, isViewLoaded else { return }
        conversation = .thread(sessionID, appID: project.id)
        items = []
        itemsByID = [:]
        expanded = []
        liveTurn = nil
        stickyTurn = nil
        sticky.isHidden = true
        reportedSimulators = []
        media.seen([:])
        composer.text = ""
        pinToBottom = true
        preparedHeight = 0
        view.setNeedsLayout()
        view.layoutIfNeeded()
        UIView.performWithoutAnimation { dataSource.applySnapshotUsingReloadData(NSDiffableDataSourceSnapshot<Int, String>()) }
        threadTitle = model.sessions.first { $0.id == sessionID }?.displayTitle(in: project) ?? ""
    }

    /// The app's agent under one of its threads: the model keeps its copy
    /// current (`SquircleModel.watch`), and its rows follow it and the rest
    /// of what they show (workers, builds) quietly, a little at a time,
    /// rather than all at once on coming back.
    private var covered = false
    private func renderCovered() {
        guard covered, outOfSight, coveredRender == nil else { return }
        // In frames of its own, never in one that moves something: whether
        // anything changed, then the change with its table at nothing (no
        // rows are built for a page no one sees), then its rows a few a frame.
        coveredRender = Task { [weak self] in
            await DisplayFrame.next()
            guard let self, !Task.isCancelled, outOfSight, let next = currentItems()?.items, next != items else { self?.coveredRender = nil; return }
            await DisplayFrame.next()
            guard !Task.isCancelled, outOfSight else { coveredRender = nil; return }
            if preparedHeight == nil { preparedHeight = 0; view.setNeedsLayout(); view.layoutIfNeeded() }
            let wasResuming = resuming
            resuming = true
            renderItems()
            resuming = wasResuming
            coveredRender = nil
            buildRowsInSlices()
        }
    }
    private var coveredRender: Task<Void, Never>?

    /// Fully covered by a thread and still: its rows can change and be
    /// built a little at a time, unseen. Coming into sight finishes them.
    var outOfSight = false {
        didSet {
            guard outOfSight != oldValue else { return }
            if outOfSight { renderCovered() } else { finishRows() }
        }
    }
    private var slicing: Task<Void, Never>?

    /// Builds the rows not built yet, from the bottom, as many as fit in a
    /// few milliseconds a frame.
    private func buildRowsInSlices() {
        guard slicing == nil, preparedHeight != nil else { return }
        slicing = Task { [weak self] in
            var done = false
            while !done {
                await DisplayFrame.next()
                guard let self, !Task.isCancelled, outOfSight else { return }
                let frame = CACurrentMediaTime()
                var last: CFTimeInterval = 0
                repeat {
                    let started = CACurrentMediaTime()
                    done = prepareRows()
                    last = CACurrentMediaTime() - started
                } while !done && CACurrentMediaTime() - frame + last < 0.004
            }
            self?.slicing = nil
        }
    }

    /// Whatever rows are not built yet are built now.
    private func finishRows() {
        coveredRender?.cancel()
        coveredRender = nil
        slicing?.cancel()
        slicing = nil
        guard preparedHeight != nil else { return }
        preparedHeight = nil
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// `resume` is rendering: rows that changed while parked are not news.
    private var resuming = false

    /// How much of a page made ahead has its rows built, from the bottom:
    /// nil once all of it has.
    private var preparedHeight: CGFloat?
    /// Builds the rows of another quarter screen of a page made ahead, at
    /// its bottom, where it opens. True once the whole page is built.
    func prepareRows() -> Bool {
        guard let built = preparedHeight else { return true }
        // First the rows themselves, from the thread's copy; then their cells.
        if items.isEmpty, model.content(of: conversation) != nil {
            renderItems()
            return false
        }
        let full = view.bounds.height
        let next = built + full / 8
        preparedHeight = next >= full ? nil : next
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return preparedHeight == nil
    }

    /// Puts `id` on screen at once from what was last seen of it, then
    /// follows it live.
    private func open(_ id: ConversationID) {
        conversation = id
        model.show(id)
        freshness = model.keepFresh(.conversation(id))
        Task { [weak self] in
            // A conversation removed or moved on before this ran must not take the model.
            guard let self, !tornDown, active, conversation == id else { return }
            await model.open(id)
            render()
        }
    }

    /// The conversation this one now is, if it changed: a draft whose
    /// thread T3 created (even if its first turn then failed), or the
    /// app's agent the Mac reports after a fresh start or a first send.
    private func successor() -> ConversationID? {
        if let next = model.successor(of: conversation) { return next }
        guard isAgent, pendingSend == nil, let id = model.agentThreadID(for: project), id != conversation.threadID else { return nil }
        return .thread(id, appID: project.id)
    }

    private func render() {
        guard isViewLoaded, !tornDown else { return }
        guard active else { renderCovered(); return }
        if let next = successor() {
            pinToBottom = true
            open(next)
        }
        guard isActive else { return }
        let phase = pendingSend?.phase
        let inFlight = phase == .preparing || phase == .creating || phase == .awaitingAcceptance
        composer.send.isEnabled = !inFlight
        draftScroll.isHidden = showsConversation
        table.isHidden = !showsConversation
        view.accessibilityElements = topControls + [showsConversation ? table : draftScroll, request, notice, jump, strip, composer]
        let session = model.sessions.first { $0.id == conversation.threadID }
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
        if isAgent, taskFreshness == nil { taskFreshness = model.keepFresh(.tasks(appID: project.id)) }
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
        let locked = model.isRunning || pendingSend != nil
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
        case .table: return "table"
        case .summary: return "summary"
        case .live: return "live"
        case .build: return "build"
        case .changes: return "changes"
        case .simulator: return "simulator"
        }
    }

    /// The rows the conversation shows now (nil: nothing to show yet), and its messages.
    private func currentItems() -> (items: [ThreadItem], messages: [ChatMessage])? {
        guard let content = model.content(of: conversation) else { return nil }
        let header: [ThreadItem] = threadTitle.isEmpty ? [] : [.header(threadTitle)]
        let messages = displayedMessages(content.messages)
        return (header + resolve(ThreadItem.items(messages: messages, running: content.running, expanded: expanded,
                                                  builds: model.builds, changes: content.changes,
                                                  simulators: content.simulators, thread: currentSessionID)), messages)
    }

    private func renderItems(animated: Bool = false) {
        guard let (next, messages) = currentItems(), next != items else { return }
        let previous = itemsByID
        // The conversation's rows arriving where only its title showed (a
        // thread not seen yet this session) are its first, not news: they
        // appear at once, not as a stream of rows sliding in mid-push. Your
        // own first message still flies in.
        // Until T3 has caught up with the copy shown, what arrives is what
        // happened while away: in place at once, like a page coming back.
        let quiet = resuming || (flyingID == nil && conversation.threadID != nil && !model.caughtUp)
        let empty = !items.contains { $0.id != "header" } && flyingID == nil
        let first = quiet || empty
        // A turn finishing folds its steps away; let the table animate that.
        let folding = animated || (!quiet && previous["live"] != nil && !next.contains { $0.id == "live" })
        items = next
        itemsByID = [:]
        var ids: [String] = []
        for item in next where itemsByID[item.id] == nil { itemsByID[item.id] = item; ids.append(item.id) }
        hasSimulators = false; hasLiveSimulator = false
        for case .simulator(let use) in next { hasSimulators = true; hasLiveSimulator = hasLiveSimulator || use.live }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let changed = ids.filter { previous[$0] != nil && previous[$0] != itemsByID[$0] }
        for id in changed { guesses[id] = nil }
        let reflowed = changed.filter { !restyledInPlace($0) }
        let inserted = first ? [] : ids.filter { previous[$0] == nil }
        let removed = previous.keys.filter { itemsByID[$0] == nil }.count
        // Rows arriving or leaving while the agent works slide into place;
        // only streaming text, which just grows, updates without animation.
        let structural = !first && (!inserted.isEmpty || removed > 0) && inserted.count + removed <= 16 && !Motion.reduced
        if folding || structural {
            // Changed rows out of view are told first, without animating: an
            // animated update measures every row it reconfigures, wherever it is.
            var before = dataSource.snapshot()
            let away = reflowed.filter { id in before.indexOfItem(id) != nil && dataSource.indexPath(for: id).flatMap(table.cellForRow) == nil }
            if !away.isEmpty {
                before.reconfigureItems(away)
                UIView.performWithoutAnimation { dataSource.apply(before, animatingDifferences: false) }
            }
            snapshot.reconfigureItems(reflowed.filter { !away.contains($0) })
            dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
                guard let self, pinToBottom, flyingID == nil else { return }
                scrollToBottom(animated: true)
            }
        } else if covered, !active {
            // Unseen, with its table at nothing: reloaded, not diffed row by row.
            UIView.performWithoutAnimation { dataSource.applySnapshotUsingReloadData(snapshot) }
        } else if empty, pinToBottom {
            // A whole conversation at once, shown from its end: loading it
            // lays out the rows where the table is, so it goes to where the
            // end will be first, and only the rows that show there are built.
            let known = heights
            let estimate = ids.reduce(0) { $0 + estimatedHeight(of: $1, known: known) }
            table.contentOffset.y = max(-table.contentInset.top, estimate + table.contentInset.bottom - table.bounds.height)
            UIView.performWithoutAnimation { dataSource.applySnapshotUsingReloadData(snapshot) }
        } else {
            snapshot.reconfigureItems(reflowed)
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
        setNeedsMediaPass()
        // The threads its lines open, newest first, ready before one is tapped.
        if onOpenThread != nil {
            var seen = Set<String>()
            model.prefetch(threads: next.reversed().compactMap(opens).filter { seen.insert($0).inserted })
        }
        // Only the turn that was live pulses, when it folds into its own
        // summary; a quick reply with no steps must not light up an older one.
        let wasLive = liveTurn
        liveTurn = itemsByID["live"] == nil ? nil : messages.last(where: { $0.role == "user" })?.id ?? "start"
        if !quiet, previous["live"] != nil, liveTurn == nil, let turn = wasLive, itemsByID["summary:" + turn] != nil {
            celebrate("summary:" + turn)
        }
    }

    /// A row in view whose new content keeps its height is updated where
    /// it is: told to the table, every such row would be measured again on
    /// a fresh cell. False when the table must hear of it (off screen, or
    /// its height changed).
    private func restyledInPlace(_ id: String) -> Bool {
        guard let path = dataSource.indexPath(for: id), let cell = table.cellForRow(at: path), let item = itemsByID[id] else { return false }
        let height = cell.bounds.height
        configure(cell, with: item)
        let fitted = cell.systemLayoutSizeFitting(CGSize(width: table.bounds.width, height: 0), withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel).height
        guard abs(fitted - height) < 0.5 else { return false }
        cell.setNeedsLayout()
        return true
    }

    /// Names and live states for the workers action lines mention.
    private func resolve(_ items: [ThreadItem]) -> [ThreadItem] {
        guard items.contains(where: { if case .action = $0 { return true }; return false }) else { return items }
        let workers = model.workers
        let sessions = Dictionary(model.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item in
            guard case .action(var line) = item else { return item }
            // A spawn whose reply was cut short or shared with other commands
            // is found by its own branch or title, never by another's ID.
            if line.thread == nil, case .action(let action) = line.kind, action.isSpawn {
                let id = workers.first { action.branch != nil && $0.value.branch == action.branch }?.key
                    ?? workers.first { action.title != nil && $0.value.title == action.title }?.key
                    ?? sessions.values.first { action.title != nil && $0.title == action.title }?.id
                line.thread = WorkerID(id)
            }
            guard let id = line.thread?.raw else {
                // Only a worker Squircle knows of shows a filtered spawn happened.
                if case .action(let action) = line.kind, action.isSpawn, action.outcome == .unattributed { return nil }
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

    /// The conversation with your message in place until T3's thread has
    /// it: the same ID, so the row stays put when T3's copy replaces it.
    private func displayedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var messages = messages
        guard let pending = pendingSend, !messages.contains(where: { $0.id == pending.messageID }) else { return messages }
        var message = ChatMessage(id: pending.messageID, role: "user", content: pending.text,
                                  createdAt: ISODate.format(.now))
        message.attachments = (0..<pending.images).map { "local-\($0)" }
        message.captures = pending.captures
        messages.append(message)
        return messages
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

    /// The table measures rows that come into view against their estimates
    /// and applies the difference to its content size in its own layout
    /// pass, without moving its offset: a pinned conversation would then sit
    /// past its end (blank) or show older rows until something scrolled it.
    /// One at its end before that pass stays at its end.
    private func keepEnd(_ wasAtEnd: Bool) {
        guard wasAtEnd, pinToBottom, flyingID == nil, !scrollSpring.isAnimating, !table.isTracking, !table.isDecelerating else { return }
        let bottom = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        if abs(table.contentOffset.y - bottom) > 0.5 { table.contentOffset.y = bottom }
    }

    /// Scrolls the conversation on one spring, laying rows out every frame.
    private lazy var scrollSpring: SpringDriver = {
        let spring = SpringDriver(value: table.contentOffset.y)
        spring.parameters = SpringDriver.Parameters(response: 0.45, damping: 0.92)
        spring.onChange = { [weak self] value in self?.table.contentOffset.y = value }
        return spring
    }()

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollSpring.stop()
        // The finger scrolls: no tap is coming; the scroll has the frames.
        onScrollBegan?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateSticky()
        setNeedsMediaPass()
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
            (cell as? MessageCell)?.configure(message, style: .user, rendered: rowText.message(message, style: .user), expanded: true)
            cell.contentView.alpha = message.id == flyingID ? 0 : 1
        case .update(let message):
            (cell as? MessageCell)?.configure(message, style: .update, rendered: rowText.message(message, style: .update), expanded: true)
        case .agentMessage(let message):
            let open = expanded.contains(message.id)
            (cell as? MessageCell)?.configure(message, style: .agent, rendered: agentText(message), expanded: open)
        case .action(let line):
            let open = expanded.contains(line.id)
            let message = ChatMessage(id: line.id, role: "tool", content: "")
            (cell as? MessageCell)?.configure(message, style: .action, rendered: ConversationText.action(line, expanded: open, traits: view.traitCollection), expanded: open)
        case .answer(let message):
            (cell as? MessageCell)?.configure(message, style: .answer, rendered: rowText.message(message, style: .answer), expanded: true)
        case .note(let message):
            (cell as? MessageCell)?.configure(message, style: .note, rendered: rowText.message(message, style: .note), expanded: expanded.contains(message.id))
        case .thought(let message):
            (cell as? MessageCell)?.configure(message, style: .thought, rendered: rowText.message(message, style: .thought), expanded: expanded.contains(message.id))
        case .step(let message, let first, let last):
            (cell as? StepCell)?.configure(message, first: first, last: last)
        case .earlier(_, let count):
            (cell as? StepCell)?.configureEarlier(count: count, expanded: count == 0)
        case .gallery(let id, let shots):
            guard let cell = cell as? GalleryCell else { return }
            cell.configure(shots, indent: id.hasPrefix("gallery:earlier:") || itemsByID[String(id.dropFirst(8))] != nil ? 56 : 20, id: id,
                           trailing: id.hasPrefix("gallery:sent:"))
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
        case .figure(_, let shots):
            guard let cell = cell as? FigureCell else { return }
            cell.configure(shots, width: table.bounds.width, failed: Set(shots.map(\.step).filter { media.failed("figure:" + $0) }))
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
        case .table(let id, let table, let quiet):
            (cell as? MarkdownTableCell)?.configure(tableLayout(id, table, quiet: quiet), id: id)
        case .summary(let summary):
            (cell as? SummaryCell)?.configure(summary)
        case .live(let status):
            let jelly = host?.showsAgentJelly == true
                ? isAgent ? JellyLook.agent(.working) : conversation.threadID.map { JellyLook.worker($0, .working) } : nil
            (cell as? LiveCell)?.configure(status, jelly: jelly)
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
            let poster = use.recordingID.flatMap { StepImages.data(for: "poster:" + $0, index: 0) }
            cell.configure(use, feeds: simulatorFeeds, video: stepID.flatMap(StepVideos.url(for:)), poster: poster, tappable: tappable)
            cell.showing = onScreen
            cell.onTap = tappable ? { [weak self] in self?.openSimulator(use) } : nil
        }
    }

    // MARK: Media (M06)

    /// The conversation's downloads, nearest what shows first.
    private lazy var media: MediaQueue = {
        let queue = MediaQueue()
        queue.onEnded = { [weak self] key, loaded in
            // A picture that couldn't load shows as failed, not as loading.
            if !loaded, key.hasPrefix("figure:") { self?.reconfigureFigures() }
            self?.setNeedsMediaPass()
        }
        return queue
    }()
    private var mediaPassPending = false
    /// What's on screen changed: look again once, on the next frame.
    /// Also says which live simulators show (`reportVisibleSimulators`):
    /// once the table has settled, not at each offset it passes through.
    private func setNeedsMediaPass() {
        guard !mediaPassPending else { return }
        mediaPassPending = true
        Task { [weak self] in
            await DisplayFrame.next()
            guard let self else { return }
            mediaPassPending = false
            mediaPass()
        }
    }
    /// The media missing from the rows in sight and a screen either side,
    /// each with its distance from the middle of what shows. Nothing while
    /// the conversation is out of sight.
    private func mediaPass() {
        // Only a page in sight shows live simulators.
        if onScreen { reportVisibleSimulators() } else if !reportedSimulators.isEmpty {
            reportedSimulators = []
            host?.conversation(self, showsSimulators: [])
        }
        // A page made ahead loads its pictures and posters too, so they are
        // there when it slides in.
        let preloading = !active && !covered
        guard onScreen || preloading, view.window != nil, table.bounds.height > 0 else { media.seen([:]); return }
        let top = table.contentOffset.y + table.contentInset.top
        let bottom = max(top, table.contentOffset.y + table.bounds.height - table.contentInset.bottom)
        let middle = (top + bottom) / 2, reach = table.bounds.height
        let near = CGRect(x: 0, y: top - reach, width: table.bounds.width, height: bottom - top + 2 * reach)
        var wants: [String: MediaQueue.Want] = [:]
        for path in table.indexPathsForRows(in: near) ?? [] {
            guard let id = dataSource.itemIdentifier(for: path), let item = itemsByID[id] else { continue }
            // Only rows with media: a row's rect measures it, building its cell off screen.
            switch item { case .gallery, .figure, .simulator: break; default: continue }
            let row = table.rectForRow(at: path)
            let distance = Double(abs(min(max(middle, row.minY), row.maxY) - middle))
            let visible = row.maxY > top && row.minY < bottom
            func want(_ key: String, after: Double = 0, whole: Bool = false, _ load: @escaping () async -> Bool) {
                wants[key] = MediaQueue.Want(need: MediaLoads.Need(distance: distance + after, visible: visible, whole: whole), load: load)
            }
            switch item {
            case .gallery(let id, let shots):
                // It rests on its newest; older ones are off to the left.
                for (index, shot) in shots.enumerated() where GalleryCell.image(for: shot) == nil {
                    want("image:\(shot.step)#\(shot.index)", after: Double(shots.count - 1 - index) * GalleryCell.height) { [weak self] in
                        await self?.loadImage(shot, item: id) ?? false
                    }
                }
            case .figure(let id, let shots):
                for shot in shots where FigureCell.image(for: shot) == nil {
                    want("figure:" + shot.step) { [weak self] in await self?.loadFigure(shot, item: id) ?? false }
                }
            case .simulator(let use):
                guard let recording = use.recordingID, StepVideos.url(for: "media:" + recording) == nil else { continue }
                if StepImages.data(for: "poster:" + recording, index: 0) == nil, !model.conversationMedia.posterless.contains(recording) {
                    want("poster:" + recording) { [weak self] in await self?.loadPoster(recording, item: item.id) ?? false }
                }
                // After the pictures around it.
                if model.conversationMedia.autoLoadsRecording(recording) {
                    want("recording:" + recording, after: reach, whole: true) { [weak self] in
                        await self?.loadRecording("media:" + recording, item: item.id) ?? false
                    }
                }
            default: continue
            }
        }
        media.seen(wants)
    }

    private func loadPoster(_ id: String, item: String) async -> Bool {
        guard await model.conversationMedia.recordingPoster(id) != nil else { return false }
        if StepVideos.url(for: "media:" + id) == nil { await reconfigure(item) }
        return true
    }
    private func loadRecording(_ stepID: String, item: String) async -> Bool {
        guard await model.conversationMedia.loadVideo(stepID) != nil else { return false }
        await reconfigure(item)
        return true
    }

    /// Live: large and touchable, through the host. Recorded: the
    /// recording, carrying on from where it plays in place.
    private func openSimulator(_ use: SimulatorUse) {
        if use.live {
            if let host, host.expandsSimulators { host.expandSimulator(use) }
            return
        }
        guard let id = use.recordingID, let window = view.window, let cell = simulatorCell(use.id) else { return }
        let origin = MediaOrigin { [weak self] in self?.simulatorCell(use.id)?.spot }
        MediaViewer.open(.video(poster: cell.poster, size: nil, player: cell.recordingPlayer, url: { [weak self] in
            await self?.model.conversationMedia.loadVideo("media:" + id)
        }), from: origin, in: window)
    }

    private func simulatorCell(_ id: String) -> SimulatorCell? {
        table.visibleCells.lazy.compactMap { $0 as? SimulatorCell }.first { $0.use?.id == id }
    }

    /// The turn's block showing simulator `id`, while it is on screen.
    func simulatorSpot(_ id: String) -> MediaSpot? {
        guard onScreen else { return nil }
        return simulatorCell(id)?.spot
    }

    /// Live simulator blocks at least half on screen.
    private func reportVisibleSimulators() {
        // `visibleCells` lays the table out; without live simulators there is nothing to say.
        guard let host, hasLiveSimulator || !reportedSimulators.isEmpty else { return }
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
    /// Whether the rows include a simulator, and one that is live.
    private var hasSimulators = false
    private var hasLiveSimulator = false

    /// "Task from Squircle agent" over the task; a piece after one of its
    /// tables or pictures has no label.
    private func agentText(_ message: ChatMessage) -> NSAttributedString {
        let from = message.agent?.from.flatMap { id in model.sessions.first { $0.id == id } }?.displayTitle(in: project)
        return rowText.agent(message, from: from)
    }

    private func tableLayout(_ id: String, _ markdown: MarkdownTable, quiet: Bool) -> MarkdownTableLayout {
        rowText.table(id, markdown, quiet: quiet, width: max(200, table.bounds.width - 40), size: traitCollection.preferredContentSizeCategory)
    }

    /// The thread a row opens over the agent: the worker it is about, or
    /// the agent that sent it a message, while T3 still lists that thread.
    /// Nil leaves the row to unfold, or not to be tapped at all.
    private func opens(_ item: ThreadItem?) -> String? {
        guard onOpenThread != nil else { return nil }
        switch item {
        case .update(let message): return message.threadIDs.first
        // T3 no longer lists an archived worker's thread.
        case .action(let line): return line.state == .archived ? nil : line.thread?.raw
        case .agentMessage(let message):
            return message.agent?.from.flatMap { id in model.sessions.contains { $0.id == id } ? id : nil }
        default: return nil
        }
    }

    private func tappable(_ item: ThreadItem?) -> Bool {
        switch item {
        case .agentMessage: return true
        case .action(let line): return opens(item) != nil || line.text?.isEmpty == false
        case .step(let message, _, _): return !message.detail.isEmpty || message.step?.diff != nil
        case .earlier, .summary, .note, .changes: return true
        case .update: return opens(item) != nil
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
        dataSource.itemIdentifier(for: indexPath).map { estimatedHeight(of: $0, known: heights) } ?? 60
    }

    /// A row's measured height, or a guess from its text until it is measured.
    private func estimatedHeight(of id: String, known heights: [String: CGFloat]) -> CGFloat {
        if let known = heights[id] { return known }
        if guessWidth != table.bounds.width { guessWidth = table.bounds.width; guesses = [:] }
        if let guess = guesses[id] { return guess }
        let guess = guessedHeight(of: id)
        guesses[id] = guess
        return guess
    }

    private func guessedHeight(of id: String) -> CGFloat {
        let tableView = table
        let width = max(200, tableView.bounds.width - 40)
        // A guess, from one pass over the bytes: measuring (or even
        // splitting) long texts here cost more than building the rows.
        func lines(_ text: String, per: CGFloat) -> CGFloat {
            var lines: CGFloat = 0, run = 0
            for byte in text.utf8 {
                if byte == 10 { lines += max(1, ceil(CGFloat(run) * per / width)); run = 0 } else if byte & 0xC0 != 0x80 { run += 1 }
            }
            return lines + max(1, ceil(CGFloat(run) * per / width))
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
        case .table(_, let table, let quiet): return CGFloat(table.rows.count + 1) * (quiet ? 26 : 30) + 12
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
        case .update: if let id = opens(item) { onOpenThread?(id) }
        case .agentMessage(let message):
            // "From Dark mode" opens Dark mode; the message under it unfolds.
            if let id = opens(item), (tableView.cellForRow(at: indexPath) as? MessageCell)?.touchedFirstLine == true { onOpenThread?(id) }
            else { toggle(message.id) }
        case .action(let line):
            // What the agent sent reads in full in the worker it went to.
            if let id = opens(item) { onOpenThread?(id) } else if line.text?.isEmpty == false { toggle(line.id) }
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

    private func loadImage(_ shot: Shot, item: String) async -> Bool {
        guard await model.conversationMedia.loadStepImage(shot.step, index: shot.index, attachment: shot.attachment) != nil,
              await GalleryCell.prepare(shot) != nil else { return false }
        await reconfigure(item)
        return true
    }

    /// Its size first, so the conversation makes room once, then the picture.
    private func loadFigure(_ shot: Shot, item: String) async -> Bool {
        if MediaFiles.sizes[shot.step] == nil, await model.conversationMedia.mediaSize(shot.step) != nil { await reconfigure(item) }
        guard await model.conversationMedia.loadStepImage(shot.step, index: shot.index) != nil, await FigureCell.prepare(shot) != nil else { return false }
        await reconfigure(item)
        return true
    }

    private func reconfigureFigures() {
        var snapshot = dataSource.snapshot()
        let figures = snapshot.itemIdentifiers.filter { if case .figure = itemsByID[$0] { true } else { false } }
        guard !figures.isEmpty else { return }
        snapshot.reconfigureItems(figures)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigure(_ item: String) async {
        guard dataSource.indexPath(for: item) != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([item])
        await dataSource.apply(snapshot, animatingDifferences: false)
        if pinToBottom { scrollToBottom(animated: true) }
    }

    /// A screenshot, picture or clip, flown up from where it shows.
    private func showImage(_ shot: Shot) {
        guard let window = view.window, let found = mediaView(shot) else { return }
        let origin = MediaOrigin { [weak self] in self?.mediaView(shot)?.spot }
        if shot.video {
            MediaViewer.open(.video(poster: found.picture, size: MediaFiles.sizes[shot.step], player: found.player, url: { [weak self] in
                await self?.model.conversationMedia.loadVideo(shot.step)
            }), from: origin, in: window)
            return
        }
        guard let picture = found.picture else { return }
        MediaViewer.open(.image(picture, full: { pixels in
            guard let data = StepImages.data(for: shot.step, index: shot.index) else { return nil }
            return await Downsample.image(data) { pixels / max(1, $0.width, $0.height) }
        }), from: origin, in: window)
    }

    /// The gallery frame or figure tile showing `shot`, if one is on screen.
    private func mediaView(_ shot: Shot) -> (spot: MediaSpot, picture: UIImage?, player: AVPlayer?)? {
        for cell in table.visibleCells {
            if let view = (cell as? GalleryCell)?.view(for: shot) { return (view.spot, view.picture, view.inlinePlayer) }
            if let tile = (cell as? FigureCell)?.tile(for: shot) { return (tile.spot, tile.picture, tile.inlinePlayer) }
        }
        return nil
    }

    // MARK: Composer and requests

    private func send() {
        guard isActive else { return }
        let text = composer.text
        let field = model.attachments
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field.isEmpty {
            if model.isRunning { Task { await model.stop() } }
            return
        }
        let source = composer.textOrigin(in: view)
        switch model.startSend(text, in: project, from: conversation) {
        case .refused(let reason):
            model.error = reason
        case .started(let messageID, let outcome):
            Theme.openHaptic()
            // Your pictures show in the conversation from the bytes on hand.
            for (index, image) in field.filter({ $0.capture == nil }).enumerated() { StepImages.set(image.data, for: messageID, index: index) }
            flyingID = Motion.reduced ? nil : messageID
            composer.text = ""
            pinToBottom = true
            render()
            flySend(id: messageID, from: source)
            follow(outcome, text: text)
        }
    }

    /// A message T3 refused goes back into the field.
    private func follow(_ outcome: Task<SendOutcome, Never>, text: String) {
        Task { [weak self] in
            let result = await outcome.value
            guard let self, !tornDown else { return }
            if case .rejected = result, composer.text.isEmpty { composer.text = text }
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

    private var debugRequest: PendingRequest?
    private func renderRequest() {
        guard let change = requestCard.show(debugRequest ?? model.requests.first) else { return }
        view.setNeedsLayout()
        guard change == .appeared, !Motion.reduced else { return }
        // The card rises out of the message field.
        view.layoutIfNeeded()
        requestCard.rise()
    }

    /// Removed from the screen for good: stops everything that could still
    /// change shared state (a removed controller can outlive its view while
    /// a load finishes).
    private var tornDown = false

    func tearDown() {
        Self.heightCache.set(heights, for: conversation)
        tornDown = true
        freshness = nil
        taskFreshness = nil
        observations.forEach { $0.cancel() }
        observations = []
        onBack = nil
        host?.conversation(self, showsSimulators: [])
        host = nil
    }

    #if DEBUG
    /// Verification only: a sample agent question, never sent to T3.
    func debugShowQuestion() {
        debugRequest = PendingRequest(id: "debug", item: ["id": "debug-question", "type": "user_input_request", "requestId": "debug", "questions": [
            ["id": "effects", "header": "Effects", "question": "How bold should the glass effects be?", "multiSelect": false, "options": [
                ["label": "Bold and flashy", "description": "Flowing spectrum glow, shimmer and ripples"],
                ["label": "Calm", "description": "Soft shimmer, restrained glow"]]],
            ["id": "media", "header": "Media", "question": "What should appear inline?", "multiSelect": true, "options": [
                ["label": "Screenshots"], ["label": "Recordings"], ["label": "Diffs"]]]]])
        renderRequest()
    }
    /// Verification only: `SQUIRCLE_MEDIA=N` scrolls to the Nth newest row
    /// of pictures or clips (`SQUIRCLE_MEDIA_KIND=figure|gallery` for one kind).
    func debugScrollToMedia(_ n: Int, kind: String?) {
        let rows = dataSource.snapshot().itemIdentifiers.filter { id in
            switch itemsByID[id] {
            case .gallery: kind != "figure" && kind != "simulator"
            case .figure: kind != "gallery" && kind != "simulator"
            case .simulator(let use): kind == "simulator" && !use.live
            default: false
            }
        }
        guard rows.count >= n, let path = dataSource.indexPath(for: rows[rows.count - n]) else { return }
        table.scrollToRow(at: path, at: .middle, animated: false)
        // `SQUIRCLE_MEDIA_OPEN=SECONDS`: then opens its first picture, as a tap does.
        guard let delay = ProcessInfo.processInfo.environment["SQUIRCLE_MEDIA_OPEN"].flatMap(Double.init),
              let item = itemsByID[rows[rows.count - n]] else { return }
        pinToBottom = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            switch item {
            case .gallery(_, let shots), .figure(_, let shots): if let shot = shots.first { self?.showImage(shot) }
            case .simulator(let use): self?.openSimulator(use)
            default: return
            }
            await MediaViewer.debugDrags(in: self?.view.window)
        }
    }
    /// Verification only: types and sends a real message, as the composer does.
    func debugSend(_ text: String) {
        composer.text = text
        send()
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
