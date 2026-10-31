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
    /// Opens Tasks at one task (a work item or sub-task, by ID).
    var onOpenTask: ((String) -> Void)?
    var onBuilds: (() -> Void)?
    private let tasks = Theme.glassButton(symbol: "checklist", identifier: "agent.tasks", accessibilityLabel: "Tasks")
    /// Open tasks at a glance, just above the field; tapping opens Tasks.
    private let strip = TaskStrip()
    private var stripGap: NSLayoutConstraint?
    private var stripCollapsed: NSLayoutConstraint?
    private let builds = Theme.glassButton(symbol: "shippingbox", identifier: "agent.builds", accessibilityLabel: "Builds")
    /// The floating buttons at the top, in reading order.
    private var topControls: [UIView] {
        guard !embedded else { return [] }
        guard isAgent else { return [back, more] }
        return compactControls ? [more] : [back, tasks, builds, more]
    }
    /// Shown inside a task's page, under its header (Tasks): no top
    /// controls, and the conversation starts right at its top. Set before it loads.
    var embedded = false
    /// The task this thread was opened from in Tasks, named on its back button.
    var crumb: String? {
        didSet { if crumb != oldValue, isViewLoaded { renderCrumb() } }
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
            // A reply belongs to the conversation it quotes.
            reply = nil
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
    /// Your message sent while you read further up: it lands below, where
    /// you are left, and the jump button shows in the accent until you go
    /// down to it.
    private var sentBelow: String?
    private let clip = UIView()
    private let fade = CAGradientLayer()
    private let table = ConversationTable(frame: .zero, style: .plain)
    private let composer: Composer
    private lazy var picker = AttachmentPicker(host: self) { [weak self] attachment in self?.model.attach(attachment) }
    private let notice = Theme.label("", Theme.Text.line, color: Theme.failure, lines: 3)
    /// Answers the questions shown in the conversation, as Waiting on you does.
    private lazy var answers = WaitingAnswers(model: model)
    private lazy var requestCard = RequestCard(answers: answers)
    private var request: UIVisualEffectView { requestCard.view }

    private var flyingID: String?
    /// The message you are replying to: its row and the words quoted, shown
    /// over the field until you send or cancel.
    private var reply: (row: String, quote: String)? {
        didSet { if reply?.row != oldValue?.row || reply?.quote != oldValue?.quote { renderReply() } }
    }
    /// Swipe a message right to reply (`replyPanned`).
    private lazy var replyPan = UIPanGestureRecognizer(target: self, action: #selector(replyPanned(_:)))
    /// Shows behind the swiped message as it moves aside.
    private let replyGlyph = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill", withConfiguration: Theme.symbol(Theme.Text.body)))
    /// The row being swiped, or springing back, and how far it sits aside.
    private var swiped: String?
    private var swipeFrom: CGFloat = 0
    private var swipeArmed = false
    private lazy var swipeSpring: SpringDriver = {
        let spring = SpringDriver()
        spring.onChange = { [weak self] _ in self?.renderSwipe() }
        spring.onRest = { [weak self] _ in self?.renderSwipe() }
        return spring
    }()
    /// The row a reply's quote took you to, marked once the scroll arrives.
    private var marking: String?
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
    private var items: [ThreadItem] = [] { didSet { openTurns = Self.openTurns(in: items) } }
    private var itemsByID: [String: ThreadItem] = [:]
    /// The room around each row, from its neighbours (`halfGap`).
    private var gaps: [String: RowGap] = [:]

    /// What a row is, for the room around it.
    private enum RowKind { case sent, received, text, line, card, media }
    private func kind(_ item: ThreadItem) -> RowKind {
        switch item {
        case .user: .sent
        // What you attached sits right above your words.
        case .gallery(let id, _) where id.hasPrefix("gallery:sent:"): .sent
        case .answer: isAgent ? .received : .text
        case .header, .agentMessage, .note, .thought: .text
        case .update, .action, .step, .earlier, .summary, .changes, .live, .document: .line
        case .build, .question: .card
        case .gallery, .figure, .table, .simulator: .media
        }
    }

    /// Half the deck's gap between two neighbouring rows (each row keeps its
    /// half): 4 between one sender's bubbles, 8 between lines and between
    /// pictures, 24 before your message, 16 between anything else.
    private static func halfGap(_ above: RowKind?, _ below: RowKind?) -> CGFloat {
        guard let above, let below else { return Theme.Space.tight }
        switch (above, below) {
        case (.sent, .sent), (.received, .received): return Theme.Space.tight / 2
        case (_, .sent): return Theme.Space.section / 2
        case (.line, .line), (.media, .media): return Theme.Space.row / 2
        default: return Theme.Space.group / 2
        }
    }

    /// The app agent's received bubbles still to land, in order. The first
    /// rises while `riser` runs; the rest wait unseen in their places.
    private var landing: [String] = []
    private var riser: (id: String, view: UIView, animator: UIViewPropertyAnimator)?
    /// Each expanded turn's summary row and the row its turn ends at (its
    /// answer or the next message; nil: the end of the conversation), found
    /// when the rows change so scrolling only measures them.
    private var openTurns: [(summary: TurnSummary, head: String, end: String?)] = []
    private static func openTurns(in items: [ThreadItem]) -> [(summary: TurnSummary, head: String, end: String?)] {
        var turns: [(summary: TurnSummary, head: String, end: String?)] = []
        var waiting = 0
        for item in items {
            switch item {
            case .summary(let summary) where summary.expanded:
                turns.append((summary, item.id, nil))
            case .answer, .user, .update:
                while waiting < turns.count { turns[waiting].end = item.id; waiting += 1 }
            default: continue
            }
        }
        return turns
    }
    /// The turn the live line belonged to, so only that turn's own finish pulses.
    private var liveTurn: String?
    private var dataSource: UITableViewDiffableDataSource<Int, String>!
    /// Row text rendered once per source; tables measured per width and text size.
    private let rowText = ConversationText()
    private var expanded = Set<String>()
    private var pinToBottom = true { didSet { if pinToBottom { held = nil } } }
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
        // Made ahead, it waits off screen until its host shows it.
        self.inSight = !ahead
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
                    Task { await self?.model.restartAgent(project) }
                }
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
        table.onLayout = { [weak self] wasAtEnd in self?.keepEnd(wasAtEnd); self?.hold() }
        table.estimatedRowHeight = 60
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(HeaderCell.self, forCellReuseIdentifier: "header")
        table.register(StepCell.self, forCellReuseIdentifier: "step")
        table.register(GalleryCell.self, forCellReuseIdentifier: "gallery")
        table.register(FigureCell.self, forCellReuseIdentifier: "figure")
        table.register(MarkdownTableCell.self, forCellReuseIdentifier: "table")
        table.register(DocumentCell.self, forCellReuseIdentifier: "document")
        table.register(SummaryCell.self, forCellReuseIdentifier: "summary")
        table.register(LiveCell.self, forCellReuseIdentifier: "live")
        table.register(BuildCell.self, forCellReuseIdentifier: "build")
        table.register(ChangesCell.self, forCellReuseIdentifier: "changes")
        table.register(SimulatorCell.self, forCellReuseIdentifier: "simulator")
        table.register(QuestionCell.self, forCellReuseIdentifier: "question")
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
        let heading = Theme.label("What’s next?", Theme.Text.title, lines: 2)
        heading.translatesAutoresizingMaskIntoConstraints = false
        draftScroll.addSubview(heading)
        let content = draftScroll.contentLayoutGuide, frame = draftScroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            heading.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Theme.Space.margin),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.Space.margin),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Space.margin),
            heading.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.Space.tight)
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
        renderCrumb()
        if isAgent {
            back.accessibilityLabel = "Apps"
            tasks.addAction(UIAction { [weak self] _ in self?.onTasks?() }, for: .touchUpInside)
            builds.addAction(UIAction { [weak self] _ in self?.onBuilds?() }, for: .touchUpInside)
            [tasks, builds].forEach(view.addSubview)
        }
        view.addSubview(more)
        [back, tasks, builds, more].forEach { $0.isHidden = !topControls.contains($0) }

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
        composer.onCancelQuote = { [weak self] in self?.reply = nil }
        // Swipe a message right to reply. Scrolling waits until a touch is
        // known not to be one, so the two never move together.
        replyPan.delegate = self
        table.addGestureRecognizer(replyPan)
        table.panGestureRecognizer.require(toFail: replyPan)
        replyGlyph.isHidden = true
        table.insertSubview(replyGlyph, at: 0)
        jump.alpha = 0
        jump.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        jump.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Theme.selectionHaptic()
            pinToBottom = true
            sentBelow = nil
            scrollToBottom(animated: true)
            renderJump()
        }, for: .touchUpInside)
        jump.configuration?.preferredSymbolConfigurationForImage = Theme.symbol(Theme.Text.line)
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
            jump.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.rowPad),
            request.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            request.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ]
        NSLayoutConstraint.activate(edgeConstraints + [
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Space.margin),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.margin),
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
        // On the margin, a row's gap apart.
        let x = overlayLayout?.inset ?? Theme.Space.margin, y = safeArea.top + (overlayLayout?.inset ?? Theme.Space.tight)
        let size = Theme.Space.tap, stride = size + Theme.Space.row
        let crumbWidth = min(back.intrinsicContentSize.width, view.bounds.width - 2 * x - 2 * size - Theme.Space.row)
        back.place(in: CGRect(x: x, y: y, width: crumb == nil ? size : max(size, crumbWidth), height: size))
        tasks.place(in: CGRect(x: x + stride, y: y, width: size, height: size))
        builds.place(in: CGRect(x: x + 2 * stride, y: y, width: size, height: size))
        more.place(in: CGRect(x: view.bounds.width - x - size, y: y, width: size, height: size))
        layoutConversation()
    }

    /// The bottom of the top controls, without the overlay's shift.
    private var controlsBottom: CGFloat { embedded ? safeArea.top : safeArea.top + (overlayLayout?.inset ?? 4) + 44
    }

    /// The back button names the task it returns to, or is a plain chevron.
    private func renderCrumb() {
        back.configuration?.title = crumb
        back.configuration?.titleLineBreakMode = .byTruncatingTail
        back.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Text.lineStrong
            return attributes
        }
        back.configuration?.imagePadding = Theme.Space.tight
        back.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: crumb == nil ? 11 : Theme.Space.group)
        back.accessibilityLabel = crumb.map { "Back to \($0)" } ?? (isAgent ? "Apps" : "Back to threads")
        view.setNeedsLayout()
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
        let insets = UIEdgeInsets(top: controlsBottom + Theme.Space.row, left: 0, bottom: height - floor + Theme.Space.rowPad, right: 0)
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
        inSight = progress > 0.001
    }
    /// Some of this conversation is in sight, as its host's route says: live
    /// simulators stream and its jelly draws only then.
    var inSight = true {
        didSet {
            guard inSight != oldValue else { return }
            // `visibleCells` lays the table out first; only simulators need it.
            if hasSimulators { for case let cell as SimulatorCell in table.visibleCells { cell.showing = inSight } }
            liveCell?.inSight = inSight
            setNeedsMediaPass()
        }
    }
    /// The live line's cell, whose jelly follows `inSight`.
    private weak var liveCell: LiveCell?

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

    /// Out of sight for a while (a page swiped past, a thread over it): it
    /// lets go of the model and of the simulators it showed, and keeps its
    /// draft, folds and place for `reveal`.
    func hide() {
        deactivate()
        view.endEditing(true)
        if !reportedSimulators.isEmpty { host?.conversation(self, showsSimulators: []) }
        reportedSimulators = []
    }

    /// In sight again, as it was left; what changed meanwhile already in place.
    func reveal() {
        guard !tornDown, !active else { return }
        buildRows()
        reactivate()
        renderSend()
    }

    /// Closed and off screen, kept to be opened again (`resume`); its host
    /// brings it back into sight.
    func park() {
        Self.heightCache.set(heights, for: conversation)
        hide()
        inSight = false
    }

    /// Parked, it opens again as a new page would: at the bottom, its turns
    /// folded, the field empty, what changed meanwhile already in place.
    func resume() {
        guard !tornDown, !active else { return }
        buildRows()
        expanded = []
        composer.text = ""
        pinToBottom = true
        sentBelow = nil
        jumpShown = false
        renderJumpTint()
        jump.alpha = 0
        jump.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        reactivate()
        scrollToBottom()
        renderSend()
    }

    /// Whatever of a page made ahead is not built yet is built now.
    private func buildRows() {
        if preparedHeight != nil, items.isEmpty { renderItems() }
        finishRows()
    }
    /// A parked page put to use for another thread of the app: its view,
    /// controls and the table's cells stay; everything of the old thread
    /// goes. Its rows are then built like a page made ahead (`prepareRows`).
    func retarget(to sessionID: String) {
        guard !active, !tornDown, isViewLoaded else { return }
        conversation = .thread(sessionID, appID: project.id)
        items = []
        itemsByID = [:]
        gaps = [:]
        landing = []
        expanded = []
        liveTurn = nil
        stickyTurn = nil
        sticky.isHidden = true
        reportedSimulators = []
        media.seen([:])
        composer.text = ""
        pinToBottom = true
        sentBelow = nil
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
    /// app's agent the Mac reports after a first send (or a new agent, its
    /// old thread archived).
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
        // Caught up with T3 without a row changing: the spot may be found now.
        applyFocus()
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
            composer.send.configuration?.image = UIImage(systemName: symbol, withConfiguration: composer.sendSymbol)
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
        case .document: return "document"
        case .summary: return "summary"
        case .live: return "live"
        case .build: return "build"
        case .changes: return "changes"
        case .simulator: return "simulator"
        case .question: return "question"
        }
    }

    /// The rows the conversation shows now (nil: nothing to show yet), and its messages.
    private func currentItems() -> (items: [ThreadItem], messages: [ChatMessage])? {
        guard let content = model.content(of: conversation) else { return nil }
        // Embedded, its task's header names it already.
        let header: [ThreadItem] = threadTitle.isEmpty || embedded ? [] : [.header(threadTitle)]
        let messages = displayedMessages(content.messages)
        let rows = resolve(ThreadItem.items(messages: messages, running: content.running, expanded: expanded,
                                            builds: model.builds, changes: content.changes,
                                            simulators: content.simulators, thread: currentSessionID))
        var placed = ThreadItem.placing(openQuestions, in: rows)
        // The app's agent texts you: one received bubble per paragraph.
        if isAgent {
            placed = placed.flatMap { item -> [ThreadItem] in
                guard case .answer(let message) = item else { return [item] }
                return rowText.bubbles(message).map(ThreadItem.answer)
            }
        }
        return (header + placed, messages)
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
        let previousGaps = gaps
        let kinds = ids.map { kind(itemsByID[$0]!) }
        gaps = Dictionary(uniqueKeysWithValues: ids.indices.map { index in
            (ids[index], RowGap(top: Self.halfGap(index > 0 ? kinds[index - 1] : nil, kinds[index]),
                                bottom: Self.halfGap(kinds[index], index + 1 < kinds.count ? kinds[index + 1] : nil)))
        })
        hasSimulators = false; hasLiveSimulator = false
        for case .simulator(let use) in next { hasSimulators = true; hasLiveSimulator = hasLiveSimulator || use.live }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        // A row whose neighbours changed takes its new room.
        let changed = ids.filter { previous[$0] != nil && (previous[$0] != itemsByID[$0] || previousGaps[$0] != gaps[$0]) }
        for id in changed { guesses[id] = nil }
        let reflowed = changed.filter { !restyledInPlace($0) }
        let inserted = first ? [] : ids.filter { previous[$0] == nil }
        let arrived = isAgent ? inserted.filter { if case .answer = itemsByID[$0] { true } else { false } } : []
        if !arrived.isEmpty, !Motion.reduced { landing += arrived }
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
        if !folding, !inserted.isEmpty, inserted.count <= 8 { animateEntrance(of: inserted.filter { !arrived.contains($0) }) }
        if !arrived.isEmpty {
            // Under Reduce Motion they are simply there, with one tap.
            if Motion.reduced { Theme.openHaptic() } else { landNext() }
        }
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
        applyFocus()
    }

    // MARK: Focus

    /// What Waiting on you opened this conversation at (`WaitingList.Item.id`),
    /// until it shows: a question's card where it was asked, or the open request.
    private var focus: String?

    /// Opens at `item`: scrolled to where it was asked and marked, as soon
    /// as the conversation has it. A scroll takes over.
    func focus(on item: String) {
        focus = item
        // A thread's open request is the newest thing in it, its card at the end.
        pinToBottom = item.hasPrefix("r.")
        applyFocus()
    }

    private func applyFocus() {
        guard let target = focus, isActive, preparedHeight == nil, table.bounds.height > 0 else { return }
        if target.hasPrefix("r.") {
            guard model.requests.first.map({ QuestionAnswers.key(request: $0.id) }) == target else { return }
            focus = nil
            scrollToBottom()
            requestCard.mark()
            return
        }
        // Everything T3 has of the thread first, so the card sits where it was asked.
        guard conversation.threadID == nil || model.caughtUp else { return }
        let row = "ask:" + target
        guard let path = dataSource.indexPath(for: row) else {
            // Answered meanwhile: nothing to show.
            if !model.waiting.apps.contains(where: { $0.items.contains { $0.id == target } }) { focus = nil }
            return
        }
        focus = nil
        scrollSpring.stop()
        held = row
        for _ in 0..<6 where hold() { table.layoutIfNeeded() }
        let bottom = table.contentSize.height + table.contentInset.bottom - table.bounds.height
        setJumpShown(bottom - table.contentOffset.y > 320)
        (table.cellForRow(at: path) as? QuestionCell)?.mark()
    }

    /// The card Waiting on you brought you to, kept in place as rows around
    /// it are measured or arrive (as the end is when pinned), until you
    /// scroll or the conversation goes to its end.
    private var held: String?

    /// Puts the held card low on screen, what led up to it above, its top
    /// never under the controls. True when it moved.
    @discardableResult
    private func hold() -> Bool {
        guard let row = held, !pinToBottom, !table.isTracking, !table.isDecelerating, !scrollSpring.isAnimating,
              let path = dataSource.indexPath(for: row) else { return false }
        let rect = table.rectForRow(at: path)
        let visible = table.bounds.height - table.contentInset.top - table.contentInset.bottom
        let low = rect.maxY + 28 - table.contentInset.top - visible
        let top = rect.minY - 16 - table.contentInset.top
        let end = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        let y = min(max(-table.contentInset.top, min(low, top)), end)
        guard abs(table.contentOffset.y - y) > 0.5 else { return false }
        table.contentOffset.y = y
        return true
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

    /// What this thread asked you in the tracker and you haven't answered yet.
    private var openQuestions: [(question: WaitingList.Question, busy: Bool)] {
        guard let thread = conversation.threadID else { return [] }
        let busy = model.answering
        return model.waiting.apps.first { $0.projectID == project.id }?.items.compactMap { item in
            guard case .question(let question) = item, question.threadID == thread else { return nil }
            return (question, busy.contains(item.id))
        } ?? []
    }

    /// Names and live states for the workers action lines mention.
    private func resolve(_ items: [ThreadItem]) -> [ThreadItem] {
        guard items.contains(where: { if case .action = $0 { return true }; return false }) else { return items }
        let workers = model.workers
        let sessions = Dictionary(model.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tasks = model.tasks(for: project).everyTask
        let asks = Dictionary(tasks.map { ($0.id.lowercased(), $0.ask) }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item in
            guard case .action(var line) = item else { return item }
            if let action = line.action, action.isTracker {
                for id in action.tasks { line.taskAsks[id] = asks[id] }
                // A new ask is found by its words; a replaced one opens what replaced it.
                switch action.kind {
                case .taskAdd: line.task = tasks.first { $0.ask == action.text }?.id
                case .taskReplace: line.task = action.replacement.flatMap { asks[$0] == nil ? nil : $0 } ?? action.task
                default: line.task = action.task.flatMap { asks[$0] == nil ? nil : $0 }
                }
                return .action(line)
            }
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
        #if DEBUG
        if let debugReply { messages += debugReply }
        #endif
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

    /// The next of the agent's bubbles lands: it rises on the same spring as
    /// your sent bubble, with a soft tap, and the one after it starts once
    /// it settles. One gone or out of sight is simply there.
    private func landNext() {
        guard riser == nil else { return }
        table.layoutIfNeeded()
        while let id = landing.first {
            guard let path = dataSource.indexPath(for: id), let cell = table.cellForRow(at: path) else {
                landing.removeFirst()
                continue
            }
            let view = cell.contentView
            view.alpha = 1
            view.transform = CGAffineTransform(translationX: 0, y: Theme.Space.group).scaledBy(x: 0.97, y: 0.97)
            Theme.openHaptic()
            let animator = UIViewPropertyAnimator(duration: 0.5, dampingRatio: 0.84) { view.transform = .identity }
            animator.addCompletion { [weak self] _ in
                view.transform = .identity
                guard let self, riser?.id == id else { return }
                riser = nil
                landing.removeAll { $0 == id }
                // Next frame: a cell reused mid-rise finishes it from inside the table's own layout.
                Task { [weak self] in await DisplayFrame.next(); self?.landNext() }
            }
            riser = (id, view, animator)
            animator.startAnimation()
            return
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
        spring.onRest = { [weak self] _ in self?.flashMarked() }
        return spring
    }()

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollSpring.stop()
        marking = nil
        // The finger takes over from wherever Waiting on you was taking it.
        focus = nil
        held = nil
        // The finger scrolls: no tap is coming; the scroll has the frames.
        onScrollBegan?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateSticky()
        setNeedsMediaPass()
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let bottom = scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height
        pinToBottom = bottom - scrollView.contentOffset.y < 60
        if pinToBottom { sentBelow = nil }
        renderJump()
    }

    /// The jump button shows while you read well above the end, or with
    /// your own message sent below you; it carries the accent then.
    private func renderJump() {
        let bottom = table.contentSize.height + table.contentInset.bottom - table.bounds.height
        renderJumpTint()
        setJumpShown(!pinToBottom && (sentBelow != nil || bottom - table.contentOffset.y > 320))
    }

    private func renderJumpTint() {
        let color = sentBelow == nil ? UIColor.label : Theme.accent
        guard jump.tintColor != color else { return }
        jump.tintColor = color
        // The glass button draws its symbol in its own colour; this one is
        // drawn in ours.
        jump.configuration?.image = UIImage(systemName: "arrow.down")?.withTintColor(color, renderingMode: .alwaysOriginal)
        jump.accessibilityLabel = sentBelow == nil ? "Jump to latest" : "Sent below, jump to latest"
    }

    /// Finds the expanded turn under the top edge and pins its summary there,
    /// pushed away by the end of that turn like a section header.
    private func updateSticky() {
        let top = table.contentOffset.y + table.contentInset.top
        var pinned: (TurnSummary, CGFloat, CGFloat)?
        for (summary, id, end) in openTurns {
            guard let path = dataSource.indexPath(for: id) else { continue }
            let head = table.rectForRow(at: path)
            guard head.minY < top else { continue }
            let endY = end.flatMap { dataSource.indexPath(for: $0) }.map { table.rectForRow(at: $0).minY } ?? table.contentSize.height
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
        (cell as? TimelineCell)?.gap = gaps[item.id] ?? .line
        if let riser, riser.view === cell.contentView, riser.id != item.id {
            // Reused for another row mid-rise: that bubble has landed.
            riser.animator.stopAnimation(false)
            riser.animator.finishAnimation(at: .end)
        }
        // Your message in flight, and the agent's bubbles waiting to land, keep their place unseen.
        if cell is MessageCell {
            cell.contentView.alpha = item.id == flyingID || (landing.contains(item.id) && riser?.id != item.id) ? 0 : 1
        }
        // Only the row being swiped to reply sits aside.
        if item.id != swiped, cell.contentView.transform.tx != 0 { cell.contentView.transform = .identity }
        switch item {
        case .header(let title):
            (cell as? HeaderCell)?.configure(title)
        case .user(let message):
            guard let cell = cell as? MessageCell else { return }
            let quote = Reply.split(message.content).quote
            cell.configure(message, style: .user, rendered: rowText.message(message, style: .user), expanded: true, quote: quote)
            cell.onQuote = quote == nil ? nil : { [weak self] in self?.goToQuote(from: message.id) }
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
            let style: MessageCell.Style = isAgent ? .received : .answer
            (cell as? MessageCell)?.configure(message, style: style, rendered: rowText.message(message, style: style), expanded: true)
        case .note(let message):
            (cell as? MessageCell)?.configure(message, style: .note, rendered: rowText.message(message, style: .note), expanded: expanded.contains(message.id))
        case .thought(let message):
            (cell as? MessageCell)?.configure(message, style: .thought, rendered: rowText.message(message, style: .thought), expanded: expanded.contains(message.id))
        case .step(let message):
            (cell as? StepCell)?.configure(message)
        case .earlier(_, let count):
            (cell as? StepCell)?.configureEarlier(count: count, expanded: count == 0)
        case .gallery(let id, let shots):
            guard let cell = cell as? GalleryCell else { return }
            // Under a step, pictures start where its text does.
            cell.configure(shots, indent: id.hasPrefix("gallery:earlier:") || itemsByID[String(id.dropFirst(8))] != nil ? Theme.Space.text : Theme.Space.margin, id: id,
                           trailing: id.hasPrefix("gallery:sent:"))
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
        case .figure(_, let shots):
            guard let cell = cell as? FigureCell else { return }
            cell.configure(shots, width: table.bounds.width, failed: Set(shots.map(\.step).filter { media.failed("figure:" + $0) }))
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
        case .table(let id, let table, let quiet):
            (cell as? MarkdownTableCell)?.configure(tableLayout(id, table, quiet: quiet), id: id)
        case .document(_, let path):
            guard let cell = cell as? DocumentCell, let thread = currentSessionID else { return }
            cell.row.show(.linked(thread: thread, path: path), documents: model.documents)
            cell.row.onOpen = { [weak self] row in
                guard let self else { return }
                DocumentViewer.open(row, documents: model.documents, from: self)
            }
        case .summary(let summary):
            (cell as? SummaryCell)?.configure(summary)
        case .live(let status):
            let jelly = host?.showsAgentJelly == true
                ? isAgent ? JellyLook.agent(.working) : conversation.threadID.map { JellyLook.worker($0, .working) } : nil
            guard let cell = cell as? LiveCell else { return }
            cell.configure(status, jelly: jelly)
            cell.inSight = inSight
            liveCell = cell
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
            cell.showing = inSight
            cell.onTap = tappable ? { [weak self] in self?.openSimulator(use) } : nil
        case .question(let item, _):
            guard let cell = cell as? QuestionCell else { return }
            answers.configure(cell.item, item, about: false) { [weak self] in
                // The next of several questions: the row takes its new height.
                UIView.performWithoutAnimation { self?.table.performBatchUpdates(nil) }
            }
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
        if inSight { reportVisibleSimulators() } else if !reportedSimulators.isEmpty {
            reportedSimulators = []
            host?.conversation(self, showsSimulators: [])
        }
        // A page made ahead loads its pictures and posters too, so they are
        // there when it slides in.
        let preloading = !active && !covered
        // Each load is for this thread as it is now, whatever opens later.
        guard inSight || preloading, view.window != nil, table.bounds.height > 0,
              let thread = conversation.threadID else { media.seen([:]); return }
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
                        await self?.loadImage(shot, item: id, in: thread) ?? false
                    }
                }
            case .figure(let id, let shots):
                for shot in shots where FigureCell.image(for: shot) == nil {
                    want("figure:" + shot.step) { [weak self] in await self?.loadFigure(shot, item: id, in: thread) ?? false }
                }
            case .simulator(let use):
                guard let recording = use.recordingID, StepVideos.url(for: "media:" + recording) == nil else { continue }
                if StepImages.data(for: "poster:" + recording, index: 0) == nil, !model.conversationMedia.hasNoPoster(recording, in: thread) {
                    want("poster:" + recording) { [weak self] in await self?.loadPoster(recording, item: item.id, in: thread) ?? false }
                }
                // After the pictures around it.
                if model.conversationMedia.autoLoadsRecording(recording, in: thread) {
                    want("recording:" + recording, after: reach, whole: true) { [weak self] in
                        await self?.loadRecording("media:" + recording, item: item.id, in: thread) ?? false
                    }
                }
            default: continue
            }
        }
        media.seen(wants)
    }

    private func loadPoster(_ id: String, item: String, in thread: String) async -> Bool {
        guard await model.conversationMedia.recordingPoster(id, in: thread) != nil else { return false }
        if StepVideos.url(for: "media:" + id) == nil { await reconfigure(item) }
        return true
    }
    private func loadRecording(_ stepID: String, item: String, in thread: String) async -> Bool {
        guard await model.conversationMedia.loadVideo(stepID, in: thread) != nil else { return false }
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
        openMedia { if case .recording(let other) = $0 { other.id == use.id } else { false } }
    }

    private func simulatorCell(_ id: String) -> SimulatorCell? {
        table.visibleCells.lazy.compactMap { $0 as? SimulatorCell }.first { $0.use?.id == id }
    }

    /// The turn's block showing simulator `id`, while it is on screen.
    func simulatorSpot(_ id: String) -> MediaSpot? {
        guard inSight else { return nil }
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
        case .action(let line): return opens(item) != nil || line.text?.isEmpty == false || line.step != nil
        case .step(let message): return !message.detail.isEmpty || message.step?.diff != nil
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
        case .document: return 70
        case .summary: return 54
        case .live: return 72
        case .build: return 74
        case .changes: return 46
        case .simulator: return SimulatorCell.height + 16
        case .question: return 190
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
        case .step(let message): showDetail(message)
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
            // Anything else shows the command it came from, and opens its task.
            if let id = opens(item) { onOpenThread?(id) } else if line.text?.isEmpty == false { toggle(line.id) }
            else if let step = line.step { showDetail(step, line: line) }
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

    private func showDetail(_ step: ChatMessage, line: ActionLine? = nil) {
        guard presentedViewController == nil else { return }
        let detail = StepDetailViewController(step: step)
        if let line {
            detail.headline = ConversationText.action(line, expanded: false, traits: traitCollection)
            if let task = line.task, let onOpenTask {
                detail.onOpenTask = { [weak self, weak detail] in
                    guard self != nil else { return }
                    detail?.dismiss(animated: true) { onOpenTask(task) }
                }
            }
        }
        present(detail, animated: true)
    }

    private func loadImage(_ shot: Shot, item: String, in thread: String) async -> Bool {
        guard await model.conversationMedia.loadStepImage(shot.step, index: shot.index, attachment: shot.attachment, in: thread) != nil,
              await GalleryCell.prepare(shot) != nil else { return false }
        await reconfigure(item)
        return true
    }

    /// Its size first, so the conversation makes room once, then the picture.
    private func loadFigure(_ shot: Shot, item: String, in thread: String) async -> Bool {
        if MediaFiles.sizes[shot.step] == nil, await model.conversationMedia.mediaSize(shot.step, in: thread) != nil { await reconfigure(item) }
        guard await model.conversationMedia.loadStepImage(shot.step, index: shot.index, in: thread) != nil, await FigureCell.prepare(shot) != nil else { return false }
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
        openMedia { if case .shot(let other, _, _) = $0 { other == shot } else { false } }
    }

    /// A picture, clip or recording in the conversation, in the row `row`.
    private enum Medium {
        case shot(Shot, row: String, gallery: Bool)
        case recording(SimulatorUse)
    }

    /// The one `opened` picks, flown up from where it shows; the
    /// conversation's other pictures and clips page in on either side, in
    /// its order, loading as they come.
    private func openMedia(_ opened: (Medium) -> Bool) {
        guard let window = view.window, let thread = conversation.threadID else { return }
        var media: [Medium] = []
        for id in dataSource.snapshot().itemIdentifiers {
            switch itemsByID[id] {
            case .gallery(_, let shots): media += shots.map { .shot($0, row: id, gallery: true) }
            case .figure(_, let shots): media += shots.map { .shot($0, row: id, gallery: false) }
            case .simulator(let use) where !use.live && use.recordingID != nil: media.append(.recording(use))
            default: continue
            }
        }
        guard let index = media.firstIndex(where: opened) else { return }
        MediaViewer.open(media.map { viewerItem($0, in: thread) }, at: index, in: window)
    }

    private func viewerItem(_ medium: Medium, in thread: String) -> ViewerItem {
        let media = model.conversationMedia
        switch medium {
        case .shot(let shot, let row, let gallery):
            let found = mediaView(shot)
            let origin = MediaOrigin(locate: { [weak self] in self?.mediaView(shot)?.spot },
                                     reveal: { [weak self] in self?.reveal(row, shot: shot) })
            let inline = found?.picture ?? (gallery ? GalleryCell.image(for: shot) : FigureCell.image(for: shot))
            let decode: @MainActor (CGFloat) async -> UIImage? = { [weak media] pixels in
                guard let data = await media?.loadStepImage(shot.step, index: shot.index, attachment: shot.attachment, in: thread) else { return nil }
                return await Downsample.image(data) { pixels / max(1, $0.width, $0.height) }
            }
            guard shot.video else {
                return ViewerItem(media: .image(inline, size: MediaFiles.sizes[shot.step], full: decode), origin: origin)
            }
            return ViewerItem(media: .video(poster: inline, size: MediaFiles.sizes[shot.step], player: found?.player, still: { await decode(1600) }, url: { [weak media] in
                await media?.loadVideo(shot.step, in: thread)
            }), origin: origin)
        case .recording(let use):
            let id = use.recordingID ?? ""
            let cell = simulatorCell(use.id)
            let origin = MediaOrigin(locate: { [weak self] in self?.simulatorCell(use.id)?.spot },
                                     reveal: { [weak self] in self?.reveal(use.id, shot: nil) })
            return ViewerItem(media: .video(poster: cell?.poster, size: nil, player: cell?.recordingPlayer, still: { [weak media] in
                guard let data = await media?.recordingPoster(id, in: thread) else { return nil }
                return await Downsample.image(data) { 1600 / max(1, $0.width, $0.height) }
            }, url: { [weak media] in
                await media?.loadVideo("media:" + id, in: thread)
            }), origin: origin)
        }
    }

    /// Behind the media viewer, scrolls the conversation so row `row` shows,
    /// and in a gallery `shot`, for the viewer to go home to.
    private func reveal(_ row: String, shot: Shot?) {
        guard let path = dataSource.indexPath(for: row) else { return }
        scrollSpring.stop()
        bringIntoSight(table.rectForRow(at: path))
        table.layoutIfNeeded()
        let spot: MediaSpot?
        if let shot {
            (table.cellForRow(at: path) as? GalleryCell)?.reveal(shot)
            spot = mediaView(shot)?.spot
        } else {
            spot = (table.cellForRow(at: path) as? SimulatorCell)?.spot
        }
        if let spot { bringIntoSight(spot.view.convert(spot.view.bounds, to: table)) }
    }

    /// Centres `rect` (in the table's content) unless it already shows whole.
    private func bringIntoSight(_ rect: CGRect) {
        let top = table.contentOffset.y + table.contentInset.top
        let height = table.bounds.height - table.contentInset.top - table.contentInset.bottom
        guard rect.minY < top || rect.maxY > top + height else { return }
        let bottom = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        table.contentOffset.y = min(bottom, max(-table.contentInset.top, rect.midY - height / 2 - table.contentInset.top))
        pinToBottom = bottom - table.contentOffset.y < 60
        setJumpShown(bottom - table.contentOffset.y > 320)
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
        let typed = composer.text
        let field = model.attachments
        if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field.isEmpty {
            if model.isRunning { Task { await model.stop() } }
            return
        }
        let source = composer.textOrigin(in: view)
        // The agent reads what you answer as a blockquote before your words.
        let quoted = reply
        let text = quoted.map { Reply.compose(quote: $0.quote, text: typed) } ?? typed
        switch model.startSend(text, in: project, from: conversation) {
        case .refused(let reason):
            model.error = reason
        case .started(let messageID, let outcome):
            Theme.openHaptic()
            // Your pictures show in the conversation from the bytes on hand.
            for (index, image) in field.filter({ $0.capture == nil }).enumerated() { StepImages.set(image.data, for: messageID, index: index) }
            // At the end, the conversation follows your message up out of
            // the field; reading further up, you stay where you are and it
            // lands below.
            let following = pinToBottom
            flyingID = following && !Motion.reduced ? messageID : nil
            if !following { sentBelow = messageID }
            composer.text = ""
            reply = nil
            render()
            if following { flySend(id: messageID, from: source) } else { renderJump() }
            follow(outcome, text: typed, reply: quoted)
        }
    }

    /// A message T3 refused goes back into the field.
    private func follow(_ outcome: Task<SendOutcome, Never>, text: String, reply quoted: (row: String, quote: String)?) {
        Task { [weak self] in
            let result = await outcome.value
            guard let self, !tornDown else { return }
            if case .rejected = result, composer.text.isEmpty {
                composer.text = text
                if reply == nil { reply = quoted }
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
        // A reply's quote rides over its bubble.
        let quoteFrame = cell.quoteFrame
        let quote = quoteFrame.flatMap { cell.contentView.resizableSnapshotView(from: $0, afterScreenUpdates: true, withCapInsets: .zero) }
        cell.contentView.alpha = 0
        table.contentOffset.y = start

        let flyer = UIView(frame: bubble)
        flyer.isUserInteractionEnabled = false
        let fill = Theme.glassSurface(cornerRadius: Theme.Radius.large, tint: Theme.userGlass)
        fill.frame = flyer.bounds
        flyer.addSubview(fill)
        words.frame = CGRect(x: textFrame.minX - bubble.minX, y: textFrame.minY - bubble.minY,
                             width: textFrame.width, height: textFrame.height)
        flyer.addSubview(words)
        if let quote, let quoteFrame {
            let origin = cell.contentView.convert(quoteFrame.origin, to: view)
            quote.frame = CGRect(origin: CGPoint(x: origin.x - bubble.minX, y: origin.y - bubble.minY), size: quoteFrame.size)
            flyer.addSubview(quote)
        }
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
        defer { applyFocus() }
        requestCard.asker = isAgent || conversation.threadID == nil ? ("Your agent asks", .agent(.needsYou))
            : (threadTitle.isEmpty ? "Asks you" : threadTitle, .worker(conversation.threadID ?? "", .needsYou))
        let current = debugRequest ?? model.requests.first
        guard let change = requestCard.show(current, busy: current.map(model.sending) ?? false) else { return }
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
    #if DEBUG
    /// Verification only: `SQUIRCLE_DEMO_REPLY=1` (with `SQUIRCLE_APP`) has the
    /// app's agent answer a made-up message in three paragraphs, to watch
    /// its bubbles land.
    private var debugReply: [ChatMessage]?
    func debugReplyArrives() {
        let now = ISODate.format(.now)
        debugReply = [ChatMessage(id: "debug-ask", role: "user", content: "How did the chat stage go?", createdAt: now),
                      ChatMessage(id: "debug-reply", role: "assistant", content: """
            The chat stage is in: the agent's replies are bubbles now, one per paragraph.

            Still to check:

            - the landing haptic on a real reply
            - dark mode

            I'll send you a build once Tasks is merged too.
            """, createdAt: now)]
        render()
    }
    #endif
    func debugShowQuestion() {
        debugRequest = PendingRequest(id: "debug", item: ["id": "debug-question", "type": "user_input_request", "requestId": "debug", "questions": [
            ["id": "media", "header": "Media", "question": "What should appear inline?", "multiSelect": true, "options": [
                ["label": "Screenshots (Recommended)", "description": "What the simulator showed at each step, in a row that scrolls sideways"],
                ["label": "Recordings"], ["label": "Diffs"]]],
            ["id": "effects", "header": "Effects", "question": "How bold should the glass effects be?", "multiSelect": false, "options": [
                ["label": "Bold and flashy", "description": "Flowing spectrum glow, shimmer and ripples"],
                ["label": "Calm", "description": "Soft shimmer, restrained glow"]]]]])
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
        pinToBottom = false
        table.scrollToRow(at: path, at: .middle, animated: false)
        renderJump()
        // `SQUIRCLE_MEDIA_OPEN=SECONDS`: then opens its first picture, as a tap does.
        guard let delay = ProcessInfo.processInfo.environment["SQUIRCLE_MEDIA_OPEN"].flatMap(Double.init),
              let item = itemsByID[rows[rows.count - n]] else { return }
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
    /// Verification only: `SQUIRCLE_ACTION=N` scrolls to the Nth newest
    /// tracker line; `SQUIRCLE_ACTION_OPEN=1` then taps it, `=task` its
    /// Open in Tasks too.
    func debugScrollToAction(_ n: Int, open: String?) async {
        let rows = dataSource.snapshot().itemIdentifiers.filter { if case .action(let line) = itemsByID[$0] { line.action?.isTracker == true } else { false } }
        guard rows.count >= n, let path = dataSource.indexPath(for: rows[rows.count - n]) else { return }
        pinToBottom = false
        table.scrollToRow(at: path, at: .middle, animated: false)
        guard open != nil else { return }
        tableView(table, didSelectRowAt: path)
        guard open == "task" else { return }
        try? await Task.sleep(for: .seconds(2))
        (presentedViewController as? StepDetailViewController)?.onOpenTask?()
    }
    /// Verification only: scrolls `points` up from where it is, as a finger
    /// leaving the end would.
    func debugScrollUp(_ points: CGFloat) {
        pinToBottom = false
        table.contentOffset.y = max(-table.contentInset.top, table.contentOffset.y - points)
        renderJump()
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

// MARK: Replies

extension ThreadViewController: UIGestureRecognizerDelegate {
    /// How far a message moves before letting go replies to it, and where
    /// the back swipe's edge ends (a reply swipe starts inside the content).
    private static let replyReach: CGFloat = 56
    private static let backEdge: CGFloat = 28

    /// Follows the finger one to one, then resists ever more, as a scroll view's edge does.
    private static func rubber(_ x: CGFloat) -> CGFloat {
        let free: CGFloat = 40, give: CGFloat = 60
        guard x > free else { return max(0, x) }
        return free + give * (1 - 1 / ((x - free) * 0.55 / give + 1))
    }

    /// What a row says, to quote or copy; nil for rows you can't reply to.
    private func words(_ item: ThreadItem?) -> String? {
        let text: String
        switch item {
        case .user(let message): text = Reply.split(message.content).body
        case .answer(let message), .agentMessage(let message): text = Self.plain(message)
        case .question(.question(let question), _): text = question.text
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A message as it reads on screen, without its Markdown.
    private static func plain(_ message: ChatMessage) -> String {
        let markdown = message.markdown ?? Markdown.parse(message.content)
        return Markdown.render(markdown, font: Theme.Text.body, color: .label).string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// The whole message a received bubble or piece was cut from, when it says more.
    private func wholeMessage(_ id: String) -> String? {
        guard case .answer = itemsByID[id] else { return nil }
        let base = String(id.prefix { $0 != "¶" && $0 != "#" })
        guard let message = model.content(of: conversation)?.messages.first(where: { $0.id == base }) else { return nil }
        let whole = Self.plain(message).trimmingCharacters(in: .whitespacesAndNewlines)
        return whole == words(itemsByID[id]) ? nil : whole
    }

    private func startReply(_ id: String) {
        guard let text = words(itemsByID[id]) else { return }
        reply = (id, Reply.quote(text))
        composer.input.becomeFirstResponder()
    }

    private func renderReply() {
        composer.showQuote(reply?.quote)
        guard isViewLoaded, view.window != nil else { return }
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.view.layoutIfNeeded() }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === replyPan else { return true }
        let velocity = replyPan.velocity(in: table)
        let space = view.window ?? view
        let start = replyPan.location(in: space).x - replyPan.translation(in: space).x
        // Rightwards and mostly sideways, away from the back swipe's edge.
        guard isActive, start > Self.backEdge, velocity.x > 0, velocity.x > abs(velocity.y) * 1.5 else { return false }
        let point = replyPan.location(in: table) - replyPan.translation(in: table)
        guard let path = table.indexPathForRow(at: point), let id = dataSource.itemIdentifier(for: path),
              id != flyingID, riser?.id != id, !landing.contains(id) else { return false }
        return words(itemsByID[id]) != nil
    }

    @objc private func replyPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            let point = pan.location(in: table) - pan.translation(in: table)
            guard let path = table.indexPathForRow(at: point), let id = dataSource.itemIdentifier(for: path) else { return }
            // Caught springing back: carry on from where it is.
            let caught = swiped == id ? swipeSpring.value : 0
            if swiped != id { swipeSpring.set(0) }
            swiped = id
            swipeFrom = caught
            swipeArmed = false
        case .changed:
            guard swiped != nil else { return }
            let offset = Self.rubber(swipeFrom + pan.translation(in: table).x)
            swipeSpring.set(offset)
            let armed = offset >= Self.replyReach
            if armed != swipeArmed {
                swipeArmed = armed
                if armed { Theme.lightHaptic() }
            }
        default:
            if pan.state == .ended, swipeArmed, let id = swiped { startReply(id) }
            swipeArmed = false
            swipeSpring.animate(to: 0)
        }
    }

    /// The swiped row sits aside by the spring's value, the reply glyph
    /// fading in behind it; at rest it is back and the glyph gone.
    private func renderSwipe() {
        let offset = swipeSpring.value
        let resting = offset <= 0.01 && replyPan.state != .changed && replyPan.state != .began
        guard let id = swiped, let path = dataSource.indexPath(for: id) else {
            replyGlyph.isHidden = true
            return
        }
        let cell = table.cellForRow(at: path)
        cell?.contentView.transform = resting ? .identity : CGAffineTransform(translationX: offset, y: 0)
        if resting { swiped = nil }
        replyGlyph.isHidden = resting || cell == nil
        guard let cell, !resting else { return }
        let surface: UIView = (cell as? MessageCell)?.surface ?? (cell as? QuestionCell)?.item ?? cell.contentView
        let progress = min(1, offset / Self.replyReach)
        replyGlyph.tintColor = swipeArmed ? Theme.accent : .secondaryLabel
        replyGlyph.alpha = progress
        replyGlyph.transform = CGAffineTransform(scaleX: 0.5 + 0.5 * progress, y: 0.5 + 0.5 * progress)
        let mid = surface.convert(CGPoint(x: 0, y: surface.bounds.midY), to: table).y
        replyGlyph.center = CGPoint(x: max(Theme.Space.margin, (Theme.Space.margin + offset) / 2), y: mid)
    }

    @objc func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard isActive, let id = dataSource.itemIdentifier(for: indexPath), let text = words(itemsByID[id]) else { return nil }
        let whole = wholeMessage(id)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            var actions = [
                UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in self?.startReply(id) },
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = text }
            ]
            if let whole {
                actions.append(UIAction(title: "Copy Message", image: UIImage(systemName: "doc.on.doc.fill")) { _ in UIPasteboard.general.string = whole })
            }
            return UIMenu(children: actions)
        }
    }

    @objc func tableView(_ tableView: UITableView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                   highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        lifted(at: indexPath)
    }

    @objc func tableView(_ tableView: UITableView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                   dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        lifted(at: indexPath)
    }

    /// The message itself lifts with the menu: its bubble or card, or its text.
    private func lifted(at path: IndexPath) -> UITargetedPreview? {
        guard let cell = table.cellForRow(at: path) else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        if let cell = cell as? MessageCell {
            let surface = cell.surface
            if surface === cell.text {
                // Plain text: a little room around it, on the page's colour.
                let room = surface.bounds.insetBy(dx: -Theme.Space.row, dy: -Theme.Space.row)
                parameters.visiblePath = UIBezierPath(roundedRect: room, cornerRadius: Theme.Radius.small)
                parameters.backgroundColor = Theme.paper
            } else {
                parameters.visiblePath = UIBezierPath(roundedRect: surface.bounds, cornerRadius: Theme.Radius.large)
            }
            return UITargetedPreview(view: surface, parameters: parameters)
        }
        if let cell = cell as? QuestionCell {
            parameters.visiblePath = UIBezierPath(roundedRect: cell.item.bounds, cornerRadius: Theme.Radius.large)
            return UITargetedPreview(view: cell.item, parameters: parameters)
        }
        return nil
    }

    /// Tapping a reply's quote goes to the message it quotes and marks it.
    private func goToQuote(from id: String) {
        guard case .user(let message)? = itemsByID[id], let quote = Reply.split(message.content).quote else { return }
        let rows = dataSource.snapshot().itemIdentifiers
        guard let end = rows.firstIndex(of: id),
              let target = rows[..<end].last(where: { words(itemsByID[$0]).map { Reply.matches(quote, $0) } ?? false }),
              let path = dataSource.indexPath(for: target) else { return }
        Theme.selectionHaptic()
        focus = nil
        held = nil
        pinToBottom = false
        sentBelow = nil
        marking = target
        // Rows are measured as they appear: find where it really sits, then go there.
        let start = table.contentOffset.y
        func centred() -> CGFloat {
            let rect = table.rectForRow(at: path)
            let visible = table.bounds.height - table.contentInset.top - table.contentInset.bottom
            let end = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
            return min(max(-table.contentInset.top, rect.midY - table.contentInset.top - visible / 2), end)
        }
        var y = centred()
        for _ in 0..<6 {
            table.contentOffset.y = y
            table.layoutIfNeeded()
            let next = centred()
            if abs(next - y) < 0.5 { break }
            y = next
        }
        renderJump()
        guard !Motion.reduced, abs(start - y) > 0.5 else {
            scrollSpring.stop()
            table.contentOffset.y = y
            flashMarked()
            return
        }
        table.contentOffset.y = start
        // From far away, glide the last screen rather than racing past every row.
        let screen = table.bounds.height * 0.9
        scrollSpring.set(start > y ? min(start, y + screen) : max(start, y - screen))
        scrollSpring.animate(to: y)
    }

    private func flashMarked() {
        guard let id = marking else { return }
        marking = nil
        guard let path = dataSource.indexPath(for: id) else { return }
        (table.cellForRow(at: path) as? TimelineCell)?.flash()
        renderJump()
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

