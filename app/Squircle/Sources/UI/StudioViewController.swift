import Combine
import UIKit

/// The root: one lit stage with every app's real device. Opening an app moves
/// that device to the top of its workspace in the same 3D scene; a single
/// spring drives the scene and UIKit so back is interruptible at any frame.
@MainActor
final class StudioViewController: UIViewController, UIScrollViewDelegate {
    let model: SquircleModel
    private let stage = DeviceStage()
    private let picker = UIScrollView()
    private let topBar = UIView()
    private let connection = Theme.glassButton(title: "Connecting", identifier: "connection.status")
    private let add = Theme.glassButton(symbol: "plus", identifier: "project.add", accessibilityLabel: "Add app")
    private let pages = UIPageControl()
    private let spring = SpringDriver()
    private var items: [String: GalleryItem] = [:]
    private var bindings: [String: ScreenshotBinding] = [:]
    private var projects: [AppProject] = []
    private var selectedID: String?
    private var pendingOpenID: String?
    private var deferredRender = false
    private var isPaging = false
    private var subscriptions = Set<AnyCancellable>()
    private var laidOut: StageLayout?
    private(set) var workspace: WorkspaceViewController?
    private var edgePan: UIScreenEdgePanGestureRecognizer?
    private var dragStart: CGFloat = 0

    private enum Phase { case gallery, opening, workspace, closing, dragging }
    private var phase = Phase.gallery

    init(model: SquircleModel) {
        self.model = model
        selectedID = model.selectedProjectID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        view.backgroundColor = Theme.backdropBottom
        view.addSubview(stage)
        #if DEBUG
        MotionAudit.shared.note("stage.build", values: ["ms": (CACurrentMediaTime() - started) * 1000])
        #endif

        picker.delegate = self
        picker.showsHorizontalScrollIndicator = false
        picker.showsVerticalScrollIndicator = false
        picker.decelerationRate = .fast
        picker.contentInsetAdjustmentBehavior = .never
        picker.alwaysBounceHorizontal = true
        picker.alwaysBounceVertical = false
        picker.clipsToBounds = false
        picker.accessibilityIdentifier = "app.picker"
        view.addSubview(picker)

        topBar.addSubview(connection)
        topBar.addSubview(add)
        view.addSubview(topBar)
        connection.showsMenuAsPrimaryAction = true
        connection.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.subheadline, 15, .semibold)
            return attributes
        }
        connection.configuration?.titleLineBreakMode = .byTruncatingTail
        add.addAction(UIAction { [weak self] _ in self?.presentImport() }, for: .touchUpInside)

        pages.hidesForSinglePage = true
        pages.backgroundStyle = .minimal
        pages.pageIndicatorTintColor = UIColor.label.withAlphaComponent(0.18)
        pages.currentPageIndicatorTintColor = .label
        pages.addAction(UIAction { [weak self] _ in self?.scrollToPage(self?.pages.currentPage ?? 0) }, for: .valueChanged)
        view.addSubview(pages)

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
        #if DEBUG
        MotionAudit.shared.note("gallery.visible", values: ["since_launch_ms": (CACurrentMediaTime() - SquircleApp.launchedAt) * 1000])
        startVerificationHooks()
        #endif
    }

    #if DEBUG
    /// Verification only (never in Release): `SQUIRCLE_SCRUB=0.35` holds the
    /// real open transition at that progress for a screen capture, optionally
    /// with `SQUIRCLE_SCRUB_SCROLL`; `SQUIRCLE_DEMO=1` loops open/close so
    /// motion can be recorded without a UI-test runner loading the simulator.
    private func startVerificationHooks() {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["SQUIRCLE_SCRUB"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let id = selectedID else { return }
                open(id)
                spring.stop()
                phase = .dragging
                if let scroll = environment["SQUIRCLE_SCRUB_SCROLL"].flatMap(Double.init) {
                    workspace?.debugScroll(to: CGFloat(scroll))
                }
                spring.set(CGFloat(value))
                stage.setLive(false, reason: "transition")
            }
        }
        if environment["SQUIRCLE_DEMO"] == "1" {
            func cycle() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    if phase == .gallery, let id = selectedID { open(id) } else if phase == .workspace { close() }
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
        picker.frame = bounds
        let safe = view.safeAreaInsets
        topBar.place(in: CGRect(x: 16, y: safe.top + 4, width: bounds.width - 32, height: StageLayout.topBarHeight))
        let connectionSize = connection.sizeThatFits(CGSize(width: bounds.width - 120, height: 44))
        connection.frame = CGRect(x: 0, y: 4, width: min(bounds.width - 120, ceil(connectionSize.width) + 6),
                                  height: max(44, ceil(connectionSize.height)))
        add.frame = CGRect(x: topBar.bounds.width - 44, y: 4, width: 44, height: 44)
        pages.place(in: CGRect(x: 20, y: bounds.height - safe.bottom - StageLayout.pageControlHeight,
                               width: bounds.width - 40, height: StageLayout.pageControlHeight))
        workspace?.view.frame = bounds
        let current = makeLayout()
        if current != laidOut {
            laidOut = current
            layoutItems()
            picker.contentOffset.x = CGFloat(selectedIndex) * current.pitch
        }
        applyScene()
    }

    private func relayout() {
        laidOut = nil
        view.setNeedsLayout()
    }

    private func makeLayout() -> StageLayout {
        let font = Theme.appNameFont()
        let titleHeight = ceil(font.lineHeight * 2 + 4)
        return StageLayout(size: view.bounds.size, safe: view.safeAreaInsets, titleHeight: titleHeight,
                           reducedMotion: Motion.reduced)
    }

    private var layout: StageLayout { laidOut ?? makeLayout() }
    private var selectedIndex: Int { projects.firstIndex { $0.id == selectedID } ?? 0 }

    // MARK: Model

    private func render() {
        let next = model.projects
        let changed = next.map(\.id) != projects.map(\.id)
        if changed && (picker.isTracking || picker.isDecelerating || isPaging) {
            deferredRender = true
            for project in next { items[project.id]?.update(project: project) }
            return
        }
        projects = next
        if let open = workspace?.project.id { selectedID = open }
        if !projects.contains(where: { $0.id == selectedID }) { selectedID = projects.first?.id }
        let ids = Set(projects.map(\.id))
        for id in Array(items.keys) where !ids.contains(id) {
            items.removeValue(forKey: id)?.removeFromSuperview()
            bindings[id] = nil
        }
        stage.sync(ids: projects.map(\.id))
        for project in projects {
            if let item = items[project.id] { item.update(project: project) }
            else {
                let item = GalleryItem(project: project)
                item.onPage = { [weak self] direction in self?.scrollToPage(self.map { $0.selectedIndex + direction } ?? 0) }
                item.addAction(UIAction { [weak self] _ in self?.tapped(project.id) }, for: .touchUpInside)
                items[project.id] = item
                picker.addSubview(item)
            }
            let binding = bindings[project.id] ?? ScreenshotBinding(id: project.id, stage: stage)
            bindings[project.id] = binding
            binding.update(model: model, project: project)
        }
        pages.numberOfPages = projects.count
        renderConnection()
        if changed && laidOut != nil {
            layoutItems()
            picker.contentOffset.x = CGFloat(selectedIndex) * layout.pitch
        }
        applyScene()
    }

    private func renderConnection() {
        var config = connection.configuration
        let host = model.hostName.split(separator: ".").first.map(String.init) ?? model.hostName
        let offline = !model.connected && !model.isLoading
        let title = model.connected ? host : (offline ? "Offline" : "Connecting")
        let tint: UIColor = model.connected ? Theme.success : (offline ? Theme.warning : .secondaryLabel)
        if config?.title != title || config?.image == nil || connection.accessibilityValue != title {
            config?.title = title
            config?.image = UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8))?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
            config?.imagePadding = 8
            connection.configuration = config
            connection.accessibilityLabel = "Mac connection"
            connection.accessibilityValue = title
            view.setNeedsLayout()
        }
        let detail = model.error ?? (model.connected ? "Connected to \(model.hostName)" : model.status)
        connection.menu = UIMenu(title: detail, children: [
            UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                Task { await self?.model.refresh() }
            }
        ])
    }

    private func layoutItems() {
        let layout = self.layout
        let width = view.bounds.width
        picker.contentSize = CGSize(width: width + CGFloat(max(0, projects.count - 1)) * layout.pitch, height: view.bounds.height)
        let phoneHeight = layout.galleryPhoneHeight
        let phoneWidth = phoneHeight * PhonePose.aspect
        let titleWidth = width - 48
        let top = layout.galleryPhoneCenterY - phoneHeight / 2
        let height = layout.galleryTitleCenterY + layout.titleHeight / 2 - top
        for (index, project) in projects.enumerated() {
            guard let item = items[project.id] else { continue }
            let centerX = CGFloat(index) * layout.pitch + width / 2
            item.place(in: CGRect(x: centerX - titleWidth / 2, y: top, width: titleWidth, height: height))
            item.layoutContent(phoneSize: CGSize(width: phoneWidth, height: phoneHeight),
                               titleCenterY: layout.galleryTitleCenterY - top, titleHeight: layout.titleHeight)
        }
    }

    // MARK: Scene

    /// Pushes the current scroll position, transition progress and workspace
    /// scroll into every layer. Called per frame only while something moves.
    private func applyScene() {
        guard view.bounds.width > 0 else { return }
        let layout = self.layout
        let progress = spring.value
        let position = picker.contentOffset.x / layout.pitch
        let scroll = workspace?.scrollOffset ?? 0
        var poses: [String: PhonePose] = [:]
        let nearest = layout.page(for: picker.contentOffset.x, count: projects.count)
        for (index, project) in projects.enumerated() {
            let offset = CGFloat(index) - position
            let pose: PhonePose
            if project.id == selectedID && progress > 0.0001 {
                pose = layout.transitionPose(galleryOffset: offset, scroll: scroll, progress: progress)
            } else {
                pose = progress > 0.0001 ? layout.neighborPose(offset: offset, progress: progress) : layout.galleryPose(offset: offset)
            }
            if pose.visible { poses[project.id] = pose }
            if let item = items[project.id] {
                let fade = (1 - abs(offset) * 1.4).clamped()
                item.titleLabel.alpha = fade
                item.layer.zPosition = 10 - abs(offset)
                item.setCentered(index == nearest)
            }
        }
        stage.apply(poses)

        let galleryCenter = CGPoint(x: view.bounds.width / 2, y: layout.galleryPhoneCenterY)
        let workspaceCenter = layout.workspacePose(scroll: scroll).center
        let p = progress.clamped()
        stage.glowCenter = CGPoint(x: galleryCenter.x, y: .lerp(galleryCenter.y, workspaceCenter.y, p))
        stage.glowRadius = .lerp(layout.galleryPhoneHeight * 0.85, layout.workspacePhoneHeight * 0.95, p)

        // Gallery controls leave in the first half; workspace controls arrive
        // in the second, so the two sets never cross the status bar together.
        let exit = (progress * 2).clamped(0, 1.1)
        topBar.transform = CGAffineTransform(translationX: 0, y: -(view.safeAreaInsets.top + 80) * exit)
        pages.transform = CGAffineTransform(translationX: 0, y: (view.safeAreaInsets.bottom + 80) * exit)

        // The centered app name travels into the workspace title position.
        if let id = selectedID, let item = items[id] {
            if progress > 0.0001, let workspace {
                // `center` excludes the transform, so this is the resting spot.
                let startCenter = item.convert(item.titleLabel.center, to: view)
                let end = workspace.titleCenter(in: view)
                item.titleLabel.transform = CGAffineTransform(translationX: (end.x - startCenter.x) * progress,
                                                              y: (end.y - startCenter.y) * progress)
                item.titleLabel.alpha = 1
            } else {
                item.titleLabel.transform = .identity
            }
        }
        workspace?.setReveal(progress)
    }

    // MARK: Picker

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === picker else { return }
        applyScene()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingOpenID = nil
        isPaging = false
        stage.setLive(true, reason: "picker")
        #if DEBUG
        MotionAudit.shared.begin("gallery.scroll", duration: 1.4)
        #endif
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let index = layout.targetPage(currentX: scrollView.contentOffset.x, projectedX: targetContentOffset.pointee.x,
                                      velocityX: velocity.x, count: projects.count)
        targetContentOffset.pointee.x = CGFloat(index) * layout.pitch
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
        if let id = pendingOpenID {
            pendingOpenID = nil
            open(id)
        }
    }

    private func settle() {
        guard !projects.isEmpty else { return }
        isPaging = false
        stage.setLive(false, reason: "picker")
        let index = layout.page(for: picker.contentOffset.x, count: projects.count)
        if selectedID != projects[index].id { Theme.selectionHaptic() }
        selectedID = projects[index].id
        pages.currentPage = index
        applyScene()
        if deferredRender {
            deferredRender = false
            render()
        }
    }

    private func scrollToPage(_ page: Int) {
        guard !projects.isEmpty, phase == .gallery else { return }
        let index = max(0, min(projects.count - 1, page))
        pages.currentPage = index
        let target = CGFloat(index) * layout.pitch
        guard abs(picker.contentOffset.x - target) > 1 else { settle(); return }
        isPaging = true
        stage.setLive(true, reason: "picker")
        picker.setContentOffset(CGPoint(x: target, y: 0), animated: !Motion.reduced)
        if Motion.reduced { settle() }
    }

    private func tapped(_ id: String) {
        guard phase == .gallery, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let target = CGFloat(index) * layout.pitch
        if abs(picker.contentOffset.x - target) > 1 { scrollToPage(index) }
        else { selectedID = id; open(id) }
    }

    // MARK: Navigation

    private func open(_ id: String) {
        if workspace?.project.id == id, phase == .closing || phase == .opening {
            phase = .opening
            spring.animate(to: 1)
            return
        }
        guard phase == .gallery, presentedViewController == nil,
              let project = projects.first(where: { $0.id == id }) else { return }
        Theme.openHaptic()
        model.selectProject(project)
        selectedID = id
        let workspace = WorkspaceViewController(model: model, project: project)
        workspace.onBack = { [weak self] in self?.close() }
        workspace.onScroll = { [weak self] in self?.applyScene() }
        workspace.onOpenThread = { [weak self] sessionID in self?.presentThread(sessionID) }
        workspace.onOpenBuilds = { [weak self] in self?.presentBuilds() }
        workspace.layoutProvider = { [weak self] in self?.layout }
        addChild(workspace)
        workspace.view.frame = view.bounds
        view.addSubview(workspace.view)
        workspace.didMove(toParent: self)
        workspace.view.layoutIfNeeded()
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePanned(_:)))
        edge.edges = .left
        workspace.view.addGestureRecognizer(edge)
        edgePan = edge
        self.workspace = workspace
        phase = .opening
        beginMotion("workspace.open")
        updateInteractivity()
        spring.animate(to: 1)
    }

    func close() {
        guard workspace != nil, presentedViewController == nil, phase != .gallery else { return }
        phase = .closing
        beginMotion("workspace.close")
        updateInteractivity()
        spring.animate(to: 0)
    }

    @objc private func edgePanned(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        switch gesture.state {
        case .began:
            guard workspace != nil, presentedViewController == nil, phase != .gallery else { return }
            dragStart = spring.value
            spring.stop()
            phase = .dragging
            beginMotion("workspace.drag")
            updateInteractivity()
        case .changed:
            guard phase == .dragging else { return }
            spring.set((dragStart - gesture.translation(in: view).x / width).clamped())
        case .ended, .cancelled, .failed:
            guard phase == .dragging else { return }
            let velocity = -gesture.velocity(in: view).x / width
            let projected = spring.value + velocity * 0.18
            let closing = gesture.state == .ended && projected < 0.5
            #if DEBUG
            MotionAudit.shared.note("edge", values: ["progress": spring.value, "velocity": velocity, "closing": closing])
            #endif
            phase = closing ? .closing : .opening
            updateInteractivity()
            spring.animate(to: closing ? 0 : 1, initialVelocity: velocity)
        default: break
        }
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
            phase = .workspace
            updateInteractivity()
            UIAccessibility.post(notification: .screenChanged, argument: workspace?.accessibilityFocus)
        } else if value <= 0, phase == .closing {
            if let workspace {
                workspace.willMove(toParent: nil)
                workspace.view.removeFromSuperview()
                workspace.removeFromParent()
            }
            workspace = nil
            edgePan = nil
            phase = .gallery
            applyScene()
            updateInteractivity()
            UIAccessibility.post(notification: .screenChanged, argument: selectedID.flatMap { items[$0] })
        }
    }

    /// Only the resting screen is interactive and visible to VoiceOver/UI tests.
    private func updateInteractivity() {
        let gallery = phase == .gallery
        let resting = phase == .workspace
        picker.isUserInteractionEnabled = gallery
        topBar.isUserInteractionEnabled = gallery
        pages.isUserInteractionEnabled = gallery
        picker.accessibilityElementsHidden = !gallery
        topBar.accessibilityElementsHidden = !gallery
        pages.accessibilityElementsHidden = !gallery
        // Hidden at rest so the gallery costs nothing behind the workspace.
        picker.isHidden = resting
        pages.isHidden = resting
        topBar.isHidden = resting
        workspace?.setResting(resting)
    }

    // MARK: Sheets

    private func presentThread(_ sessionID: String?) {
        guard let workspace, presentedViewController == nil, phase == .workspace else { return }
        Theme.selectionHaptic()
        let controller = ThreadViewController(model: model, project: workspace.project, sessionID: sessionID)
        controller.modalPresentationStyle = .fullScreen
        controller.preferredTransition = .zoom { [weak workspace, weak model] _ in
            workspace?.zoomSource(for: model?.selectedSessionID ?? sessionID)
        }
        present(controller, animated: true)
    }

    private func presentBuilds() {
        guard let workspace, presentedViewController == nil, phase == .workspace else { return }
        Theme.selectionHaptic()
        let controller = BuildsViewController(model: model, project: workspace.project)
        controller.onNewThread = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.presentThread(nil) }
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
        guard phase == .gallery, presentedViewController == nil else { return }
        let importer = AppImportNavigationController(model: model)
        importer.onImport = { [weak self, weak importer] project in
            importer?.dismiss(animated: true) {
                guard let self else { return }
                self.render()
                guard let index = self.projects.firstIndex(where: { $0.id == project.id }) else { return }
                let target = CGFloat(index) * self.layout.pitch
                if abs(self.picker.contentOffset.x - target) > 1, !Motion.reduced {
                    self.pendingOpenID = project.id
                    self.scrollToPage(index)
                } else {
                    self.picker.contentOffset.x = target
                    self.settle()
                    self.open(project.id)
                }
            }
        }
        present(importer, animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard phase == .workspace else { return false }
        close()
        return true
    }
}

/// The tappable, accessible stand-in for one device on the stage. The device
/// itself is rendered by SceneKit behind it; this view carries the name.
@MainActor
final class GalleryItem: UIControl {
    var onPage: ((Int) -> Void)?
    private(set) var project: AppProject
    let titleLabel = Theme.label("", Theme.appNameFont(), lines: 2)
    private var phoneRect = CGRect.zero

    init(project: AppProject) {
        self.project = project
        super.init(frame: .zero)
        clipsToBounds = false
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isAccessibilityElement = false
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)
        isAccessibilityElement = true
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Previous app") { [weak self] _ in self?.onPage?(-1); return true },
            UIAccessibilityCustomAction(name: "Next app") { [weak self] _ in self?.onPage?(1); return true }
        ]
        update(project: project)
        setCentered(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(project: AppProject) {
        self.project = project
        if titleLabel.text != project.name { titleLabel.text = project.name }
        accessibilityLabel = project.name
        accessibilityValue = project.id
    }

    func setCentered(_ centered: Bool) {
        let identifier = centered ? "project.hero" : "project.picker.\(project.id)"
        guard accessibilityIdentifier != identifier else { return }
        accessibilityIdentifier = identifier
        accessibilityTraits = centered ? [.button, .selected] : .button
        accessibilityHint = centered ? "Opens threads and builds" : "Shows this app"
    }

    func layoutContent(phoneSize: CGSize, titleCenterY: CGFloat, titleHeight: CGFloat) {
        phoneRect = CGRect(x: (bounds.width - phoneSize.width) / 2, y: 0, width: phoneSize.width, height: phoneSize.height)
        titleLabel.transform = .identity
        titleLabel.place(in: CGRect(x: 0, y: titleCenterY - titleHeight / 2, width: bounds.width, height: titleHeight))
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(phoneRect.isEmpty ? bounds : phoneRect, in: self) }
        set { super.accessibilityFrame = newValue }
    }

    /// Only the device and its name are tappable, so a neighbor's visible
    /// edge receives its own taps.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let text = titleLabel.textRect(forBounds: titleLabel.bounds, limitedToNumberOfLines: 2)
        let textFrame = CGRect(x: titleLabel.frame.minX + text.minX, y: titleLabel.frame.minY + text.minY,
                               width: text.width, height: text.height)
        return phoneRect.contains(point) || textFrame.insetBy(dx: -12, dy: -8).contains(point)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: 0.16) { self.titleLabel.alpha = self.isHighlighted ? 0.6 : 1 }
        }
    }
}
