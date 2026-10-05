import Combine
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

    private let model: SquircleModel
    private weak var stage: DeviceStage?
    private var sessionID: String?
    private var selectionReady = false
    private var sending = false
    private let draftScroll = UIScrollView()
    private let draftOptions = FlowView()
    private var renderedDraftChoices: [JSONValue] = []
    private var subscriptions = Set<AnyCancellable>()

    private let back = Theme.glassButton(symbol: "chevron.left", identifier: "thread.close", accessibilityLabel: "Back to threads")
    private let titleLabel = Theme.label("", Theme.font(.headline, 17, .semibold))
    private let agent = UIButton(configuration: .plain())
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
    private var stream: T3DeviceStream? { if case .visible(_, let stream) = previewState { return stream }; return nil }
    private var frameSize = CGSize(width: 440, height: 956)
    private var orientation = "portrait"
    private var lastInput: CGPoint?

    init(model: SquircleModel, project: AppProject, sessionID: String?, stage: DeviceStage) {
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
        let floor = request.isHidden ? composer.frame.minY : request.frame.minY
        return floor - 6 - StageLayout.dividerHeight
    }

    var dividerY: CGFloat { layout.divider(detent: detent.value, limit: dividerLimit) }
    var pose: PhonePose { layout.threadPose(divider: dividerY) }

    /// The simulator owns touches on its display once it is large and live.
    private var simulatorOwnsTouches: Bool { stream?.isInteractive == true && detent.value > 0.6 }

    /// Horizontal back swipes must not start on the live device or the divider.
    func allowsBackSwipe(at point: CGPoint) -> Bool {
        if divider.frame.insetBy(dx: 0, dy: -10).contains(point) { return false }
        if simulatorOwnsTouches, deviceTouch.frame.contains(point) { return false }
        return true
    }

    func focusComposer() { composer.input.becomeFirstResponder() }

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
        table.register(StepCell.self, forCellReuseIdentifier: "step")
        table.register(GalleryCell.self, forCellReuseIdentifier: "gallery")
        table.register(SummaryCell.self, forCellReuseIdentifier: "summary")
        table.register(LiveCell.self, forCellReuseIdentifier: "live")
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
        [heading, draftOptions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; draftScroll.addSubview($0) }
        let content = draftScroll.contentLayoutGuide, frame = draftScroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            heading.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            draftOptions.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            draftOptions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            draftOptions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            draftOptions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4)
        ])
        clip.addSubview(draftScroll)
        view.addSubview(clip)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        agent.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 8)
        agent.configuration?.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        agent.configuration?.imagePlacement = .trailing
        agent.configuration?.imagePadding = 4
        agent.configuration?.baseForegroundColor = .secondaryLabel
        agent.configuration?.titleLineBreakMode = .byTruncatingTail
        agent.contentHorizontalAlignment = .leading
        agent.showsMenuAsPrimaryAction = true
        agent.accessibilityIdentifier = "thread.agent"
        back.addAction(UIAction { [weak self] _ in Theme.selectionHaptic(); self?.onBack?() }, for: .touchUpInside)
        [deviceTouch, back, titleLabel, agent, simulatorStatus, home, simulator, divider].forEach(view.addSubview)

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
        [request, notice, composer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            notice.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
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
            let bottom = UIScrollEdgeElementContainerInteraction()
            bottom.scrollView = table
            bottom.edge = .bottom
            composer.addInteraction(bottom)
        }
        view.accessibilityElements = [back, titleLabel, agent, deviceTouch, home, simulator, divider, draftScroll, table, request, notice, composer]

        detent.parameters = SpringDriver.Parameters(response: 0.42, damping: 0.84)
        detent.onChange = { [weak self] _ in self?.layoutStage() }
        detent.onRest = { [weak self] value in
            UserDefaults.standard.set(Double(min(1, value.rounded())), forKey: Self.detentKey)
            self?.stage?.setLive(false, reason: "detent")
        }

        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.render() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.pausePreview() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reconcilePreview() }.store(in: &subscriptions)

        renderSimulatorControls(interactive: false)
        model.selectProject(project)
        detent.set(sessionID == nil ? 1 : CGFloat(UserDefaults.standard.double(forKey: Self.detentKey)).clamped())
        let requestedSessionID = sessionID
        Task { [weak self] in
            guard let self else { return }
            if let requestedSessionID { await model.selectSession(requestedSessionID) } else { await model.beginDraft() }
            selectionReady = true
            render()
        }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets, width = view.bounds.width
        back.frame = CGRect(x: 16, y: safe.top + 4, width: 44, height: 44)
        layoutStage()
    }

    /// Everything that follows the divider. Runs every frame it moves.
    private func layoutStage() {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        let layout = self.layout
        let width = view.bounds.width, height = view.bounds.height
        let y = dividerY
        let rowHeight = StageLayout.dividerHeight
        divider.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
        grabber.frame = CGRect(x: (width - 36) / 2, y: (rowHeight - 5) / 2, width: 36, height: 5)
        divider.accessibilityValue = detent.value < 0.5 ? "Docked" : detent.value < 1.5 ? "Half" : "Full"

        let chatTop = layout.chatDivider + rowHeight
        let clipTop = y + rowHeight
        clip.frame = CGRect(x: 0, y: clipTop, width: width, height: max(0, height - clipTop))
        table.frame = CGRect(x: 0, y: chatTop - clipTop, width: width, height: height - chatTop)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        fade.endPoint = CGPoint(x: 0.5, y: min(1, 14 / max(1, clip.bounds.height)))
        CATransaction.commit()
        let floor = request.isHidden ? (notice.isHidden ? composer.frame.minY : notice.frame.minY) : request.frame.minY
        draftScroll.frame = CGRect(x: 0, y: 0, width: width, height: max(0, floor - clipTop - 8))
        let insets = UIEdgeInsets(top: clipTop - chatTop + 8, left: 0, bottom: height - floor + 10, right: 0)
        if table.contentInset != insets {
            let pinned = pinToBottom
            table.contentInset = insets
            if pinned { scrollToBottom() }
        }

        let pose = self.pose
        let phoneWidth = pose.height * PhonePose.aspect
        deviceTouch.frame = CGRect(x: pose.center.x - phoneWidth / 2, y: pose.center.y - pose.height / 2,
                                   width: phoneWidth, height: pose.height).insetBy(dx: -6, dy: -4)
        // Simulator controls arrive as the device leaves its dock.
        let arrive = ((y - layout.chatDivider) / 150).clamped()
        let top = view.safeAreaInsets.top
        let textWidth = width - 70 - CGFloat.lerp(StageLayout.dockHeight * PhonePose.aspect + 30, home.isHidden ? 68 : 118, arrive)
        titleLabel.frame = CGRect(x: 70, y: top + 5, width: textWidth, height: 24)
        agent.frame = CGRect(x: 70, y: top + 27, width: textWidth, height: 26)
        // They take the corner the docked device has just left.
        for (button, x) in [(home, width - 110), (simulator, width - 60)] {
            button.transform = .identity
            button.frame = CGRect(x: x, y: top + 4, width: 44, height: 44)
            button.transform = CGAffineTransform(scaleX: 0.4 + 0.6 * arrive, y: 0.4 + 0.6 * arrive)
            button.alpha = arrive
        }
        simulatorStatus.frame = CGRect(x: 24, y: y - 18, width: width - 48, height: 16)
        simulatorStatus.alpha = arrive
        onGeometry?()
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
        setDetent(detent.target < 0.5 ? 1 : detent.target < 1.5 ? 2 : 1)
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

    private func render() {
        guard isViewLoaded else { return }
        guard selectionReady else {
            titleLabel.text = sessionID == nil ? "New thread" : ""
            agent.isEnabled = false
            composer.send.isEnabled = false
            table.isHidden = true
            draftScroll.isHidden = true
            return
        }
        composer.send.isEnabled = !sending
        draftScroll.isHidden = sessionID != nil
        table.isHidden = sessionID == nil
        view.accessibilityElements = [back, titleLabel, agent, deviceTouch, home, simulator, divider,
                                      sessionID == nil ? draftScroll : table, request, notice, composer]
        simulator.isEnabled = sessionID != nil
        renderDraft()
        let session = model.sessions.first { $0.id == sessionID }
        let title = session?.displayTitle(in: project) ?? "New thread"
        if titleLabel.text != title { titleLabel.text = title }
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
        reconcilePreview()
    }

    private func renderAgent() {
        let name = model.agentName(for: model.modelSelection) + " · " + model.runtimeMode.title
        if agent.configuration?.title != name {
            agent.configuration?.attributedTitle = AttributedString(name, attributes: AttributeContainer([.font: Theme.font(.footnote, 13, .medium)]))
        }
        agent.isEnabled = true
        let providers = model.availableModelProviders.map { provider in
            UIMenu(title: provider["displayName"].string ?? "Agent", options: .displayInline, children: provider["models"].array.map { option in
                let selection = JSONValue.from(["instanceId": provider["instanceId"].string ?? "", "model": option["slug"].string ?? ""])
                return UIAction(title: option["name"].string ?? option["slug"].string ?? "Model",
                                subtitle: provider["displayName"].string,
                                attributes: model.isRunning || sending ? .disabled : [],
                                state: selection == model.modelSelection ? .on : .off) { [weak self] _ in
                    self?.model.chooseModel(selection)
                }
            })
        }
        let approvals = UIMenu(title: "Approvals", options: .displayInline, children: T3RuntimeMode.allCases.map { mode in
            UIAction(title: mode.title, state: mode == model.runtimeMode ? .on : .off) { [weak self] _ in
                Task { await self?.model.setRuntimeMode(mode) }
            }
        })
        agent.menu = UIMenu(children: [approvals] + providers)
    }

    private func renderDraft() {
        guard sessionID == nil else { return }
        let choices = model.quickModelSelections
        // Keep the selected control and valid defaults immediately available.
        let renderedChoices = choices + [model.modelSelection]
        guard renderedChoices != renderedDraftChoices else { return }
        renderedDraftChoices = renderedChoices
        draftOptions.subviews.forEach { $0.removeFromSuperview() }
        let current = model.modelSelection
        func chip(_ title: String, symbol: String?, prominent: Bool, identifier: String) -> UIButton {
            let button = Theme.glassButton(symbol: symbol, title: title, prominent: prominent, identifier: identifier)
            button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            button.configuration?.imagePadding = 6
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 16)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes; attributes.font = Theme.font(.subheadline, 15, .semibold); return attributes
            }
            return button
        }
        for selection in choices {
            let selected = selection["instanceId"] == current["instanceId"] && selection["model"] == current["model"]
            let button = chip(model.agentName(for: selection), symbol: selected ? "checkmark" : nil, prominent: selected,
                              identifier: "draft.model.\(selection["instanceId"].string ?? "").\(selection["model"].string ?? "")")
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            button.addAction(UIAction { [weak self] _ in
                Theme.selectionHaptic()
                self?.model.chooseModel(selection)
                self?.render()
            }, for: .touchUpInside)
            draftOptions.addSubview(button)
        }
        let more = chip("More", symbol: "ellipsis", prominent: false, identifier: "draft.models")
        more.accessibilityLabel = "All models"
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: model.availableModelProviders.map { provider in
            UIMenu(title: provider["displayName"].string ?? "", options: .displayInline, children: provider["models"].array.map { option in
                let selection = JSONValue.from(["instanceId":provider["instanceId"].string!,"model":option["slug"].string!])
                return UIAction(title: option["name"].string ?? option["slug"].string!,
                                state: selection["instanceId"] == current["instanceId"] && selection["model"] == current["model"] ? .on : .off) { [weak self] _ in
                    self?.model.chooseModel(selection)
                    self?.render()
                }
            })
        })
        draftOptions.addSubview(more)
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
        case .user, .answer, .note, .thought: return "message"
        case .step, .earlier: return "step"
        case .gallery: return "gallery"
        case .summary: return "summary"
        case .live: return "live"
        }
    }

    private func renderItems(animated: Bool = false) {
        let next = ThreadItem.items(messages: model.messages, running: model.isRunning, expanded: expanded)
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
        if folding {
            dataSource.apply(snapshot, animatingDifferences: true)
        } else {
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
                table.layoutIfNeeded()
            }
        }
        if pinToBottom { scrollToBottom(animated: !first && (!inserted.isEmpty || folding)) }
        if !folding, !inserted.isEmpty, inserted.count <= 8 { animateEntrance(of: inserted) }
    }

    /// New rows rise into place and come into focus, one after another.
    private func animateEntrance(of ids: [String]) {
        guard !Motion.reduced else { return }
        table.layoutIfNeeded()
        for (order, id) in ids.enumerated() {
            guard let index = dataSource.indexPath(for: id), let cell = table.cellForRow(at: index) else { continue }
            let view = cell.contentView
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: 16).scaledBy(x: 0.97, y: 0.97)
            UIView.animate(withDuration: 0.6, delay: Double(order) * 0.05, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    private func scrollToBottom(animated: Bool = false) {
        table.layoutIfNeeded()
        let bottom = max(-table.contentInset.top, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        guard abs(table.contentOffset.y - bottom) > 0.5 else { return }
        if animated, !Motion.reduced {
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.table.contentOffset.y = bottom
            }
        } else {
            table.contentOffset.y = bottom
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let bottom = scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height
        pinToBottom = bottom - scrollView.contentOffset.y < 60
    }

    private func configure(_ cell: UITableViewCell, with item: ThreadItem) {
        switch item {
        case .user(let message):
            (cell as? MessageCell)?.configure(message, style: .user, rendered: text(for: message, style: .user), expanded: true)
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
            cell.configure(shots, indent: id.hasPrefix("gallery:earlier:") || itemsByID[String(id.dropFirst(8))] != nil ? 56 : 20)
            cell.onTap = { [weak self] shot in self?.showImage(shot) }
            for shot in shots where GalleryCell.image(for: shot) == nil { loadImage(shot, item: id) }
        case .summary(let summary):
            (cell as? SummaryCell)?.configure(summary)
        case .live(let status):
            (cell as? LiveCell)?.configure(status)
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
        }
        rendered[key] = (message.content, text)
        return text
    }

    private func tappable(_ item: ThreadItem?) -> Bool {
        switch item {
        case .step(let message, _, _): return !message.detail.isEmpty || message.step?.diff != nil
        case .earlier, .summary, .note, .thought: return true
        default: return false
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
        case .note(let message), .thought(let message): toggle(message.id)
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
        }
    }

    private func showImage(_ shot: Shot) {
        guard presentedViewController == nil else { return }
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
        composer.text = ""
        pinToBottom = true
        Task { [weak self] in
            guard let self else { return }
            await model.send(text, in: project)
            sessionID = model.selectedSessionID
            sending = false
            render()
            // A message the Mac did not accept goes back into the field.
            if model.error != nil, composer.text.isEmpty { composer.text = text }
        }
    }

    private func renderRequest() {
        let current = model.requests.first
        let id = current?["id"].string
        guard id != renderedRequestID else { return }
        renderedRequestID = id
        request.isHidden = current == nil
        requestButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let current {
            let payload = current["payload"]
            requestTitle.text = current["summary"].string ?? "The agent needs your response"
            let detail = payload["detail"].string ?? ""
            requestDetail.text = detail
            requestDetail.isHidden = detail.isEmpty
            func button(_ title: String, warning: String? = nil, prominent: Bool, action: @escaping () -> Void) {
                let button = Theme.glassButton(title: title, prominent: prominent, identifier: "thread.request.\(title)")
                button.configuration?.subtitle = warning
                button.configuration?.titleLineBreakMode = .byWordWrapping
                button.configuration?.subtitleLineBreakMode = .byWordWrapping
                button.addAction(UIAction { _ in Theme.selectionHaptic(); action() }, for: .touchUpInside)
                requestButtons.addArrangedSubview(button)
            }
            if (current["kind"].string ?? "").contains("user-input") {
                button("Answer", prominent: true) { [weak self] in
                    self?.askQuestions(current, questions: payload["questions"].array, index: 0, answers: [:])
                }
            } else if payload["options"].array.isEmpty {
                button("Decline", prominent: false) { [weak self] in Task { await self?.model.respond(to: current, decision: "decline") } }
                button("Allow", prominent: true) { [weak self] in Task { await self?.model.respond(to: current, decision: "accept") } }
            } else {
                for option in payload["options"].array {
                    button(option["label"].string ?? "Choose", warning: option["warning"].string,
                           prominent: ["accept", "acceptForSession", "acceptAlways"].contains(option["decision"].string ?? "")) { [weak self] in
                        Task { await self?.model.respond(to: current, decision: option["decision"].string) }
                    }
                }
            }
        }
        view.setNeedsLayout()
    }

    private func askQuestions(_ request: JSONValue, questions: [JSONValue], index: Int, answers: [String: Any]) {
        guard index < questions.count else { Task { await model.respond(to: request, answers: answers) }; return }
        let question = questions[index]
        let id = question["id"].string ?? question["header"].string ?? "answer"
        let alert = UIAlertController(title: question["header"].string ?? "Agent question", message: question["question"].string, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Your answer" }
        func answer(_ text: String) {
            var updated = answers
            updated[id] = text
            askQuestions(request, questions: questions, index: index + 1, answers: updated)
        }
        for option in question["options"].array {
            let label = option["label"].string ?? option.string ?? "Option"
            alert.addAction(UIAlertAction(title: label, style: .default) { _ in answer(option["value"].string ?? label) })
        }
        alert.addAction(UIAlertAction(title: "Send answer", style: .default) { [weak alert] _ in answer(alert?.textFields?.first?.text ?? "") })
        alert.addAction(UIAlertAction(title: "Later", style: .cancel))
        present(alert, animated: true)
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
