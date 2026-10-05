import Combine
import UIKit

/// An app's workspace: its real device at the top of the stage, its name, and
/// a flat list of actual the coding agent threads. Builds live in a secondary sheet.
/// The view is transparent; the device is rendered by the shared stage and
/// follows this list's scroll position.
@MainActor
final class WorkspaceViewController: UIViewController, UIScrollViewDelegate {
    let model: SquircleModel
    private(set) var project: AppProject
    var onBack: (() -> Void)?
    var onScroll: (() -> Void)?
    var onOpenThread: ((String?) -> Void)?
    var onOpenBuilds: (() -> Void)?
    var layoutProvider: (() -> StageLayout?)?

    private let scroll = UIScrollView()
    private let titleLabel = Theme.label("", Theme.appNameFont(), lines: 2)
    private let deviceElement = UIView()
    private let listContainer = UIView()
    private let rows = UIStackView()
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private let topBar = UIView()
    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "project.back", accessibilityLabel: "Apps")
    private let builds = Theme.glassButton(symbol: "shippingbox", title: "Builds", identifier: "project.builds")
    private let compose = Theme.glassButton(symbol: "square.and.pencil", title: "New Thread", prominent: true, identifier: "thread.new")
    private var rowViews: [String: ThreadRow] = [:]
    private var renderedOrder: [String] = []
    private var subscriptions = Set<AnyCancellable>()
    private var deviceTop: NSLayoutConstraint!
    private var deviceHeight: NSLayoutConstraint!
    private var deviceWidth: NSLayoutConstraint!
    private var reveal: CGFloat = 0

    init(model: SquircleModel, project: AppProject) {
        self.model = model
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:project:)") }

    /// The list's distance from its resting top; positive when scrolled up.
    var scrollOffset: CGFloat { scroll.contentOffset.y + scroll.adjustedContentInset.top }

    var accessibilityFocus: Any? { titleLabel }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.accessibilityIdentifier = "workspace.threads"
        view.addSubview(scroll)

        deviceElement.isAccessibilityElement = true
        deviceElement.accessibilityTraits = .image
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        titleLabel.isHidden = true
        rows.axis = .vertical
        notice.textAlignment = .center
        notice.isHidden = true
        [deviceElement, titleLabel, listContainer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview($0)
        }
        [rows, notice].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview($0)
        }
        deviceTop = deviceElement.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor)
        deviceHeight = deviceElement.heightAnchor.constraint(equalToConstant: 200)
        deviceWidth = deviceElement.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            deviceTop, deviceHeight, deviceWidth,
            deviceElement.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: deviceElement.bottomAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            listContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            listContainer.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 12),
            listContainer.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -12),
            listContainer.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.topAnchor.constraint(equalTo: listContainer.topAnchor),
            rows.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            notice.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 24),
            notice.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 20),
            notice.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -20),
            notice.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -8)
        ])

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { await self?.model.refresh(); refresh?.endRefreshing() }
        }, for: .valueChanged)
        scroll.refreshControl = refresh

        topBar.addSubview(back)
        topBar.addSubview(builds)
        view.addSubview(topBar)
        view.addSubview(compose)
        back.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onBack?() }, for: .touchUpInside)
        builds.addAction(UIAction { [weak self] _ in self?.onOpenBuilds?() }, for: .touchUpInside)
        compose.addAction(UIAction { [weak self] _ in self?.onOpenThread?(nil) }, for: .touchUpInside)
        if #available(iOS 26.0, *) {
            scroll.topEdgeEffect.style = .soft
            scroll.bottomEdgeEffect.style = .soft
            let top = UIScrollEdgeElementContainerInteraction()
            top.scrollView = scroll
            top.edge = .top
            topBar.addInteraction(top)
            let bottom = UIScrollEdgeElementContainerInteraction()
            bottom.scrollView = scroll
            bottom.edge = .bottom
            compose.addInteraction(bottom)
        }
        view.accessibilityElements = [back, titleLabel, builds, deviceElement, scroll, compose]

        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        topBar.place(in: CGRect(x: 16, y: safe.top + 4, width: view.bounds.width - 32, height: StageLayout.topBarHeight))
        back.frame = CGRect(x: 0, y: 4, width: 44, height: 44)
        let buildsSize = builds.sizeThatFits(CGSize(width: view.bounds.width * 0.6, height: 44))
        let buildsWidth = min(view.bounds.width * 0.6, ceil(buildsSize.width))
        builds.frame = CGRect(x: topBar.bounds.width - buildsWidth, y: 4, width: buildsWidth, height: max(44, ceil(buildsSize.height)))
        let composeSize = compose.sizeThatFits(CGSize(width: view.bounds.width - 48, height: 60))
        let composeWidth = min(view.bounds.width - 48, max(170, composeSize.width))
        let composeHeight = max(50, composeSize.height)
        compose.place(in: CGRect(x: (view.bounds.width - composeWidth) / 2,
                                 y: view.bounds.height - max(safe.bottom, 16) - composeHeight - 6,
                                 width: composeWidth, height: composeHeight))
        if let layout = layoutProvider?() {
            deviceTop.constant = layout.workspacePhoneTop
            deviceHeight.constant = layout.workspacePhoneHeight
            deviceWidth.constant = layout.workspacePhoneHeight * PhonePose.aspect
        }
        let bottomInset = view.bounds.height - compose.frame.minY + 12
        if scroll.contentInset.bottom != bottomInset {
            scroll.contentInset.bottom = bottomInset
            scroll.verticalScrollIndicatorInsets.bottom = bottomInset
        }
        setReveal(reveal)
    }

    /// Where the title rests now, accounting for the list's scroll position.
    func titleCenter(in target: UIView) -> CGPoint {
        view.layoutIfNeeded()
        return scroll.convert(titleLabel.center, to: target)
    }

    /// 0 = gallery, 1 = workspace. Controls arrive from the edges they belong to.
    func setReveal(_ progress: CGFloat) {
        reveal = progress
        let safe = view.safeAreaInsets
        let arrive = ((progress - 0.45) / 0.55).clamped(-0.1, 1.1)
        topBar.transform = CGAffineTransform(translationX: 0, y: -(1 - arrive) * (safe.top + 80))
        compose.transform = CGAffineTransform(translationX: 0, y: (1 - progress) * (safe.bottom + 140))
        let list = ((progress - 0.08) / 0.92).clamped(-0.2, 1.2)
        listContainer.transform = CGAffineTransform(translationX: 0, y: (1 - list) * view.bounds.height * 0.55)
    }

    /// The title is shown here only at rest; in motion the gallery's own label
    /// travels in its place, so the same text never appears twice.
    func setResting(_ resting: Bool) {
        titleLabel.isHidden = !resting
        view.accessibilityElementsHidden = !resting
    }

    #if DEBUG
    func debugScroll(to offset: CGFloat) {
        view.layoutIfNeeded()
        scroll.contentOffset.y = offset - scroll.adjustedContentInset.top
    }
    #endif

    func zoomSource(for sessionID: String?) -> UIView? {
        if let sessionID, let row = rowViews[sessionID], row.window != nil {
            let visible = row.convert(row.bounds, to: view).intersects(view.bounds.inset(by: view.safeAreaInsets))
            if visible { return row }
        }
        return compose
    }

    // MARK: Content

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onScroll?() }

    private func render() {
        guard isViewLoaded else { return }
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        titleLabel.text = project.name
        let hasScreenshot = model.metadata(for: project)?.preview != nil
            || model.builds(for: project).contains(where: \.previewAvailable)
        deviceElement.accessibilityLabel = hasScreenshot ? "\(project.name) screenshot" : "No screenshot yet"

        let building = model.buildingProjectIDs.contains(project.id)
            || model.builds(for: project).contains { $0.status == "queued" || $0.status == "running" }
        if builds.configuration?.showsActivityIndicator != building {
            builds.configuration?.showsActivityIndicator = building
            builds.accessibilityValue = building ? "Building" : nil
        }

        let sessions = model.sessions(for: project)
        let ids = sessions.map(\.id)
        for id in Array(rowViews.keys) where !ids.contains(id) {
            rowViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for session in sessions {
            let row = rowViews[session.id] ?? {
                let row = ThreadRow(sessionID: session.id)
                row.addAction(UIAction { [weak self] _ in self?.onOpenThread?(session.id) }, for: .touchUpInside)
                rowViews[session.id] = row
                return row
            }()
            row.configure(title: session.displayTitle(in: project), preview: session.preview, date: session.updatedAt,
                          running: model.isRunning && model.selectedSessionID == session.id)
        }
        if ids != renderedOrder {
            renderedOrder = ids
            rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0) }
            for (index, id) in ids.enumerated() {
                guard let row = rowViews[id] else { continue }
                rows.addArrangedSubview(row)
                row.showsSeparator = index < ids.count - 1
            }
        }
        rowViews.values.forEach { $0.updateRelativeDate() }

        let message: String? = model.error ?? (sessions.isEmpty ? (model.isLoading ? "Loading threads…" : "No threads yet") : nil)
        notice.text = message
        notice.isHidden = message == nil
        notice.textColor = model.error == nil ? .secondaryLabel : Theme.failure
        notice.accessibilityIdentifier = model.error == nil ? "workspace.empty" : "workspace.error"
    }
}

/// A flat, full-width thread row: actual title, latest text and recency.
@MainActor
final class ThreadRow: UIControl {
    let sessionID: String
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }
    private let titleLabel = Theme.label("", Theme.font(.headline, 17, .semibold))
    private let previewLabel = Theme.label("", Theme.font(.subheadline, 15), color: .secondaryLabel, lines: 2)
    private let dateLabel = Theme.label("", Theme.font(.subheadline, 15), color: .tertiaryLabel)
    private let runningDot = UIView()
    private let separator = UIView()
    private let highlight = UIView()
    private var date: Date?
    private var running = false
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(sessionID: String) {
        self.sessionID = sessionID
        super.init(frame: .zero)
        accessibilityIdentifier = "thread.row"
        accessibilityValue = sessionID
        isAccessibilityElement = true
        accessibilityTraits = .button

        highlight.backgroundColor = Theme.pressedFill
        highlight.layer.cornerRadius = 18
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        highlight.isUserInteractionEnabled = false
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        runningDot.backgroundColor = Theme.accent
        runningDot.layer.cornerRadius = 4
        runningDot.isHidden = true
        runningDot.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [runningDot, titleLabel, dateLabel])
        heading.alignment = .center
        heading.spacing = 8
        heading.setCustomSpacing(12, after: titleLabel)
        let content = UIStackView(arrangedSubviews: [heading, previewLabel])
        content.axis = .vertical
        content.spacing = 4
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            runningDot.widthAnchor.constraint(equalToConstant: 8),
            runningDot.heightAnchor.constraint(equalToConstant: 8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, preview: String, date: Date, running: Bool) {
        let cleanPreview = preview.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if titleLabel.text != title { titleLabel.text = title }
        if previewLabel.text != cleanPreview { previewLabel.text = cleanPreview }
        previewLabel.isHidden = cleanPreview.isEmpty
        self.date = date
        self.running = running
        runningDot.isHidden = !running
        updateRelativeDate()
    }

    func updateRelativeDate() {
        let text = date.flatMap { $0.timeIntervalSince1970 > 0 ? Self.formatter.localizedString(for: $0, relativeTo: .now) : nil }
        if dateLabel.text != text { dateLabel.text = text }
        accessibilityLabel = [titleLabel.text, previewLabel.isHidden ? nil : previewLabel.text,
                              running ? "the coding agent is working" : nil, text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let animations = { self.highlight.alpha = self.isHighlighted ? 1 : 0 }
            if isHighlighted { animations() } else { UIView.animate(withDuration: 0.25, animations: animations) }
        }
    }
}
