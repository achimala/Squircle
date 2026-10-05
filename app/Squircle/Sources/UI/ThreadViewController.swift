import Combine
import UIKit

/// One conversation with a coding agent, on the same stage as Home. The app's
/// device stays with it: docked beside the title, sharing the screen, or nearly
/// full size. A divider between device and conversation moves among those
/// three detents; the device always fills the space above it and shows the
/// thread's live simulator when one is open.
@MainActor
final class ThreadViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    let project: AppProject
    var onBack: (() -> Void)?
    /// The divider moved; the stage should re-pose the device.
    var onGeometry: (() -> Void)?
    var layoutProvider: (() -> StageLayout?)?

    private let model: SquircleModel
    private weak var stage: DeviceStage?
    private var sessionID: String?
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
        table.dataSource = self
        table.delegate = self
        table.estimatedRowHeight = 80
        table.register(MessageCell.self, forCellReuseIdentifier: "message")
        table.register(StepsCell.self, forCellReuseIdentifier: "steps")
        table.register(WorkingCell.self, forCellReuseIdentifier: "working")
        table.accessibilityIdentifier = "thread.messages"
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        clip.layer.mask = fade
        clip.addSubview(table)
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
        requestButtons.distribution = .fillEqually
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
        view.accessibilityElements = [back, titleLabel, agent, deviceTouch, home, simulator, divider, table, request, notice, composer]

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
        if sessionID != nil { detent.set(CGFloat(UserDefaults.standard.double(forKey: Self.detentKey)).clamped()) }
        Task { [weak self] in
            guard let self else { return }
            if let sessionID { await model.selectSession(sessionID) } else { await model.beginDraft() }
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
        if sessionID == nil { sessionID = model.selectedSessionID }
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
        let name = model.agentName(for: model.modelSelection)
        if agent.configuration?.title != name {
            agent.configuration?.attributedTitle = AttributedString(name, attributes: AttributeContainer([.font: Theme.font(.footnote, 13, .medium)]))
        }
        agent.isEnabled = !model.isRunning
        agent.menu = UIMenu(children: model.providers.map { provider in
            UIMenu(title: provider["displayName"].string ?? "Agent", options: .displayInline, children: provider["models"].array.map { option in
                let selection = JSONValue.from(["instanceId": provider["instanceId"].string ?? "", "model": option["slug"].string ?? ""])
                return UIAction(title: option["name"].string ?? option["slug"].string ?? "Model",
                                subtitle: provider["displayName"].string,
                                state: selection == model.modelSelection ? .on : .off) { [weak self] _ in
                    self?.model.chooseModel(selection)
                }
            })
        })
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

    private func renderItems() {
        let next = ThreadItem.items(messages: model.messages, running: model.isRunning)
        guard next != items else { return }
        let sameRows = next.map(\.id) == items.map(\.id)
        let changed = sameRows ? next.indices.filter { next[$0] != items[$0] } : []
        items = next
        if sameRows {
            // Streaming: refresh only the rows whose text grew, then let the
            // table re-measure them without reloading anything else.
            UIView.performWithoutAnimation {
                for index in changed {
                    if let cell = table.cellForRow(at: IndexPath(row: index, section: 0)) { configure(cell, with: next[index]) }
                }
                table.beginUpdates()
                table.endUpdates()
            }
        } else {
            table.reloadData()
            table.layoutIfNeeded()
        }
        if pinToBottom { scrollToBottom() }
    }

    private func scrollToBottom() {
        table.layoutIfNeeded()
        let bottom = table.contentSize.height + table.contentInset.bottom - table.bounds.height
        table.contentOffset.y = max(-table.contentInset.top, bottom)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let bottom = scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height
        pinToBottom = bottom - scrollView.contentOffset.y < 60
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let identifier: String
        switch item { case .message: identifier = "message"; case .steps: identifier = "steps"; case .working: identifier = "working" }
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath)
        configure(cell, with: item)
        return cell
    }

    private func configure(_ cell: UITableViewCell, with item: ThreadItem) {
        switch item {
        case .message(let message):
            (cell as? MessageCell)?.configure(message, rendered: text(for: message), expanded: expanded.contains(message.id))
        case .steps(let id, let steps):
            guard let cell = cell as? StepsCell else { return }
            cell.configure(steps, expanded: expanded.contains(id))
            cell.onSelect = { [weak self] step in self?.showDetail(step) }
            cell.onExpand = { [weak self] in self?.toggle(id) }
        case .working:
            (cell as? WorkingCell)?.animate()
        }
    }

    private func text(for message: ChatMessage) -> NSAttributedString {
        if let cached = rendered[message.id], cached.source == message.content { return cached.text }
        let text: NSAttributedString
        switch message.role {
        case "user":
            text = NSAttributedString(string: message.content, attributes: [.font: Theme.font(.body, 17), .foregroundColor: UIColor.label])
        case "thinking":
            text = Markdown.render(message.content, font: Theme.font(.subheadline, 15), color: .secondaryLabel)
        default:
            text = Markdown.render(message.content, font: Theme.font(.body, 17), color: message.failed ? Theme.failure : .label)
        }
        rendered[message.id] = (message.content, text)
        return text
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .message(let message) = items[indexPath.row], message.role == "thinking" { toggle(message.id) }
    }

    private func toggle(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
        guard let index = items.firstIndex(where: { $0.id == id || $0.id == "steps:" + id }),
              let cell = table.cellForRow(at: IndexPath(row: index, section: 0)) else { return }
        configure(cell, with: items[index])
        table.beginUpdates()
        table.endUpdates()
    }

    private func showDetail(_ step: ChatMessage) {
        guard !step.detail.isEmpty, presentedViewController == nil else { return }
        let detail = UIViewController()
        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = .clear
        text.font = Theme.font(.footnote, 13, monospaced: true)
        text.text = step.detail
        text.textContainerInset = UIEdgeInsets(top: 28, left: 16, bottom: 30, right: 16)
        text.accessibilityIdentifier = "thread.step.detail"
        detail.view = text
        if let sheet = detail.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(detail, animated: true)
    }

    // MARK: Composer and requests

    private func send() {
        let text = composer.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if model.isRunning { Task { await model.stop() } }
            return
        }
        Theme.openHaptic()
        composer.text = ""
        pinToBottom = true
        Task { [weak self] in
            guard let self else { return }
            await model.send(text, in: project)
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
            func button(_ title: String, prominent: Bool, action: @escaping () -> Void) {
                let button = Theme.glassButton(title: title, prominent: prominent, identifier: "thread.request.\(title)")
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
                    button(option["label"].string ?? "Choose", prominent: option["decision"].string == "accept") { [weak self] in
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
            // A simulator belongs to a T3 thread; a draft becomes one first.
            if model.selectedSessionID == nil { await model.createSession(in: project) }
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
