import Combine
import UIKit

/// One Hermes conversation. Assistant text reads as a page; the user's own
/// messages sit in quiet bubbles. Close, compose, send/stop and approvals are
/// the only glass. Streaming updates mutate visible cells in place.
@MainActor
final class ThreadViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
    private let model: SquircleModel
    private let project: AppProject
    private let initialSessionID: String?
    private var subscriptions = Set<AnyCancellable>()
    private var messages: [ChatMessage] = []
    private var isOpening = true
    private var initialScrollNeeded = true
    private var shownApproval: AgentApproval?
    private var resolvingApproval = false
    private var lastViewportHeight: CGFloat = 0
    private var wasNearBottom = true

    private let table = UITableView(frame: .zero, style: .plain)
    private let header = UIView()
    private let close = Theme.glassButton(symbol: "xmark", identifier: "thread.close", accessibilityLabel: "Close thread")
    private let titleLabel = Theme.label("New thread", Theme.font(.headline, 17, .semibold))
    private let projectLabel = Theme.label("", Theme.font(.caption1, 12, .medium), color: .secondaryLabel)
    private let footer = UIStackView()
    private let approvalContainer = UIStackView()
    private let statusRow = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = Theme.label("", Theme.font(.footnote, 13), color: .secondaryLabel, lines: 3)
    private let composerGroup = Theme.glassGroup(spacing: 10)
    private let field = Theme.glassSurface(cornerRadius: 24, interactive: true)
    private let input = UITextView()
    private let placeholder = Theme.label("Message Hermes", Theme.font(.body, 17), color: .placeholderText)
    private let sendButton = Theme.glassButton(symbol: "arrow.up", prominent: true, identifier: "thread.send", accessibilityLabel: "Send message")
    private var inputHeight: NSLayoutConstraint!

    init(model: SquircleModel, project: AppProject, sessionID: String?) {
        self.model = model
        self.project = project
        initialSessionID = sessionID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:project:sessionID:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        buildConversation()
        buildHeader()
        buildComposer()
        bindModel()
        render()
        Task { [weak self] in
            guard let self else { return }
            model.selectProject(project)
            if let id = initialSessionID { await model.selectSession(id) }
            else { await model.createSession(in: project) }
            isOpening = false
            render()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let topInset = header.frame.maxY + 6 - view.safeAreaInsets.top
        let bottomInset = view.bounds.height - footer.frame.minY + 10 - view.safeAreaInsets.bottom
        if table.contentInset.top != topInset || table.contentInset.bottom != bottomInset {
            table.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
            table.verticalScrollIndicatorInsets = table.contentInset
        }
        updateInputHeight()
        let height = table.bounds.height - bottomInset
        if height != lastViewportHeight {
            let shouldFollow = wasNearBottom || initialScrollNeeded
            lastViewportHeight = height
            if shouldFollow { scrollToBottom(animated: false) }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if DEBUG
        MotionAudit.shared.begin("thread.open")
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        #if DEBUG
        MotionAudit.shared.begin("thread.close")
        #endif
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private func buildHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        header.addSubview(close)
        projectLabel.text = project.name
        projectLabel.textAlignment = .center
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        let titles = UIStackView(arrangedSubviews: [projectLabel, titleLabel])
        titles.axis = .vertical
        titles.spacing = 1
        titles.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titles)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            titles.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titles.leadingAnchor.constraint(greaterThanOrEqualTo: close.trailingAnchor, constant: 10),
            titles.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor, constant: 4),
            titles.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor, constant: -4),
            titles.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titles.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, constant: -116)
        ])
        if #available(iOS 26.0, *) {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = table
            edge.edge = .top
            header.addInteraction(edge)
        }
    }

    private func buildConversation() {
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 100
        table.keyboardDismissMode = .interactive
        table.alwaysBounceVertical = true
        table.contentInsetAdjustmentBehavior = .always
        table.register(ThreadMessageCell.self, forCellReuseIdentifier: ThreadMessageCell.reuseID)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        if #available(iOS 26.0, *) {
            // Titles sit directly over long histories; a hard edge keeps them legible.
            table.topEdgeEffect.style = .hard
            table.bottomEdgeEffect.style = .soft
        }
    }

    private func buildComposer() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.axis = .vertical
        footer.spacing = 10
        view.addSubview(footer)
        approvalContainer.axis = .vertical
        approvalContainer.isHidden = true
        footer.addArrangedSubview(approvalContainer)

        statusSpinner.hidesWhenStopped = true
        statusRow.addArrangedSubview(statusSpinner)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.spacing = 8
        statusRow.alignment = .center
        statusRow.isLayoutMarginsRelativeArrangement = true
        statusRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        statusRow.isHidden = true
        footer.addArrangedSubview(statusRow)

        composerGroup.translatesAutoresizingMaskIntoConstraints = false
        footer.addArrangedSubview(composerGroup)
        let groupContent = composerGroup.contentView
        [field, sendButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; groupContent.addSubview($0) }

        input.translatesAutoresizingMaskIntoConstraints = false
        input.delegate = self
        input.backgroundColor = .clear
        input.textColor = .label
        input.tintColor = Theme.accent
        input.font = Theme.font(.body, 17)
        input.adjustsFontForContentSizeCategory = true
        input.textContainerInset = UIEdgeInsets(top: 13, left: 0, bottom: 13, right: 0)
        input.textContainer.lineFragmentPadding = 0
        input.isScrollEnabled = false
        input.keyboardDismissMode = .interactive
        input.accessibilityLabel = "Message Hermes"
        input.accessibilityIdentifier = "thread.input"
        field.contentView.addSubview(input)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        input.addSubview(placeholder)

        sendButton.addAction(UIAction { [weak self] _ in self?.sendOrStop() }, for: .touchUpInside)
        inputHeight = input.heightAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            field.leadingAnchor.constraint(equalTo: groupContent.leadingAnchor),
            field.topAnchor.constraint(equalTo: groupContent.topAnchor),
            field.bottomAnchor.constraint(equalTo: groupContent.bottomAnchor),
            field.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            sendButton.trailingAnchor.constraint(equalTo: groupContent.trailingAnchor),
            sendButton.bottomAnchor.constraint(equalTo: groupContent.bottomAnchor, constant: -1),
            sendButton.widthAnchor.constraint(equalToConstant: 46),
            sendButton.heightAnchor.constraint(equalToConstant: 46),
            input.leadingAnchor.constraint(equalTo: field.contentView.leadingAnchor, constant: 18),
            input.trailingAnchor.constraint(equalTo: field.contentView.trailingAnchor, constant: -14),
            input.topAnchor.constraint(equalTo: field.contentView.topAnchor),
            input.bottomAnchor.constraint(equalTo: field.contentView.bottomAnchor),
            inputHeight,
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 13)
        ])
        if #available(iOS 26.0, *) {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = table
            edge.edge = .bottom
            footer.addInteraction(edge)
        }
    }

    private func bindModel() {
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(80), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateInputHeight()
                table.reloadData()
            }
            .store(in: &subscriptions)
    }

    private func render() {
        guard isViewLoaded else { return }
        let nearBottom = isNearBottom && !table.isDragging && !table.isDecelerating
        let next = isOpening ? [] : model.messages
        let oldIDs = messages.map(\.id)
        let newIDs = next.map(\.id)
        let oldMessages = messages
        messages = next
        let title = model.sessions.first(where: { $0.id == model.selectedSessionID })?.displayTitle(in: project) ?? "New thread"
        if titleLabel.text != title { titleLabel.text = title }

        UIView.performWithoutAnimation {
            if oldIDs == newIDs {
                var heightChanged = false
                for index in messages.indices where oldMessages[index] != messages[index] {
                    if let cell = table.cellForRow(at: IndexPath(row: index, section: 0)) as? ThreadMessageCell {
                        cell.configure(messages[index])
                        heightChanged = true
                    }
                }
                if heightChanged { table.performBatchUpdates(nil) }
            } else if newIDs.starts(with: oldIDs), newIDs.count > oldIDs.count {
                table.insertRows(at: (oldIDs.count..<newIDs.count).map { IndexPath(row: $0, section: 0) }, with: .none)
            } else {
                table.reloadData()
            }
            table.layoutIfNeeded()
        }
        if nearBottom || initialScrollNeeded {
            scrollToBottom(animated: false)
            if !messages.isEmpty { initialScrollNeeded = false }
        }
        renderApproval()
        let terminalNotice = model.status.hasPrefix("Run ") || model.status.hasPrefix("Submission ") ? model.status : ""
        let status = model.error ?? (isOpening ? "Opening thread…" : model.isRunning ? model.status : terminalNotice)
        if statusLabel.text != status { statusLabel.text = status }
        statusLabel.textColor = model.error == nil ? .secondaryLabel : Theme.failure
        statusRow.isHidden = status.isEmpty
        let working = model.error == nil && (isOpening || model.isRunning)
        if working != statusSpinner.isAnimating { working ? statusSpinner.startAnimating() : statusSpinner.stopAnimating() }
        updateSendButton()
    }

    private func renderApproval() {
        let approval = isOpening ? nil : model.approvals.first
        guard approval != shownApproval else { return }
        shownApproval = approval
        resolvingApproval = false
        approvalContainer.arrangedSubviews.forEach { approvalContainer.removeArrangedSubview($0); $0.removeFromSuperview() }
        approvalContainer.isHidden = approval == nil
        guard let approval else { return }
        let panel = ApprovalPanel(approval: approval)
        panel.respond = { [weak self, weak panel] allowed in
            guard let self, !resolvingApproval else { return }
            resolvingApproval = true
            panel?.setResponding(true)
            Task {
                await self.model.resolveApproval(approval, approved: allowed)
                self.resolvingApproval = false
                panel?.setResponding(false)
            }
        }
        approvalContainer.addArrangedSubview(panel)
        UIAccessibility.post(notification: .announcement, argument: "Hermes needs your approval.")
    }

    private func updateSendButton() {
        let running = !isOpening && model.isRunning
        let symbol = running ? "stop.fill" : "arrow.up"
        if sendButton.configuration?.image != UIImage(systemName: symbol) {
            sendButton.configuration?.image = UIImage(systemName: symbol)
        }
        sendButton.accessibilityLabel = running ? "Stop response" : "Send message"
        sendButton.isEnabled = !isOpening && (running || (!model.isLoading && !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        placeholder.isHidden = !input.text.isEmpty
    }

    private func sendOrStop() {
        if model.isRunning {
            Task { await model.stop() }
            return
        }
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isOpening, !model.isLoading, !text.isEmpty else { return }
        Theme.selectionHaptic()
        input.text = ""
        updateInputHeight()
        updateSendButton()
        wasNearBottom = true
        scrollToBottom(animated: !Motion.reduced)
        Task { await model.send(text) }
    }

    func textViewDidChange(_ textView: UITextView) {
        updateInputHeight()
        updateSendButton()
    }

    private func updateInputHeight() {
        guard input.bounds.width > 0 else { return }
        let desired = input.sizeThatFits(CGSize(width: input.bounds.width, height: .greatestFiniteMagnitude)).height
        let maximum = min(180, max(100, view.bounds.height * 0.23))
        let height = min(max(48, desired), maximum)
        if abs(inputHeight.constant - height) > 0.5 { inputHeight.constant = height }
        input.isScrollEnabled = desired > maximum
    }

    private var isNearBottom: Bool {
        table.contentSize.height + table.adjustedContentInset.bottom - table.contentOffset.y - table.bounds.height < 100
    }

    private func scrollToBottom(animated: Bool) {
        guard table.bounds.height > 0 else { return }
        let y = max(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        table.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        wasNearBottom = true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === table { wasNearBottom = isNearBottom }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ThreadMessageCell.reuseID, for: indexPath) as! ThreadMessageCell
        cell.configure(messages[indexPath.row])
        return cell
    }
}

private final class ThreadMessageCell: UITableViewCell {
    static let reuseID = "thread.message"
    private let bubble = UIView()
    private let text = UITextView()
    private let tools = UIButton(type: .system)
    private let toolDetails = Theme.label("", Theme.font(.caption1, 12, monospaced: true), color: .secondaryLabel, lines: 0)
    private let content = UIStackView()
    private var userConstraints: [NSLayoutConstraint] = []
    private var assistantConstraints: [NSLayoutConstraint] = []
    private var message: ChatMessage?
    private var toolsExpanded = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 22
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 8
        bubble.addSubview(content)

        text.backgroundColor = .clear
        text.isEditable = false
        text.isSelectable = true
        text.isScrollEnabled = false
        text.textContainerInset = .zero
        text.textContainer.lineFragmentPadding = 0
        text.adjustsFontForContentSizeCategory = true
        text.linkTextAttributes = [.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        content.addArrangedSubview(text)

        var toolStyle = UIButton.Configuration.plain()
        toolStyle.contentInsets = .zero
        toolStyle.imagePadding = 6
        toolStyle.baseForegroundColor = .secondaryLabel
        toolStyle.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption1)
        toolStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.footnote, 13, .medium)
            return attributes
        }
        tools.configuration = toolStyle
        tools.contentHorizontalAlignment = .leading
        tools.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            toolsExpanded.toggle()
            updateTools()
            var ancestor = superview
            while let current = ancestor {
                if let table = current as? UITableView { table.performBatchUpdates(nil); break }
                ancestor = current.superview
            }
        }, for: .touchUpInside)
        content.addArrangedSubview(tools)
        content.addArrangedSubview(toolDetails)

        let readable = contentView.readableContentGuide
        userConstraints = [
            bubble.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: readable.leadingAnchor, constant: 44),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 11),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -11)
        ]
        assistantConstraints = [
            bubble.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -2)
        ]
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7)
        ])
        NSLayoutConstraint.activate(assistantConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ next: ChatMessage) {
        if message?.id != next.id { toolsExpanded = false }
        let changedText = message?.content != next.content || message?.role != next.role
        let wasUser = message?.role == "user"
        message = next
        let user = next.role == "user"
        if user != wasUser || userConstraints.first?.isActive != user {
            NSLayoutConstraint.deactivate(user ? assistantConstraints : userConstraints)
            NSLayoutConstraint.activate(user ? userConstraints : assistantConstraints)
        }
        bubble.backgroundColor = user ? Theme.userBubble : .clear
        if changedText || text.attributedText.length == 0 {
            let selection = text.selectedRange
            text.attributedText = Self.markdown(next.content, isUser: user)
            if selection.length > 0, NSMaxRange(selection) <= text.attributedText.length { text.selectedRange = selection }
        }
        text.isHidden = next.content.isEmpty
        updateTools()
    }

    private func updateTools() {
        let names = message?.tools ?? []
        tools.isHidden = names.isEmpty
        let title = names.count == 1 ? names[0] : "\(names.count) tool steps"
        tools.configuration?.title = title
        tools.configuration?.image = UIImage(systemName: toolsExpanded ? "chevron.down" : "wrench.and.screwdriver")
        tools.accessibilityLabel = "\(toolsExpanded ? "Hide" : "Show") tool details, \(title)"
        toolDetails.text = names.joined(separator: "\n")
        toolDetails.isHidden = names.isEmpty || !toolsExpanded
    }

    private static func markdown(_ source: String, isUser: Bool) -> NSAttributedString {
        let baseFont = Theme.font(.body, 17)
        var value = (isUser ? nil : try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        value.font = baseFont
        value.foregroundColor = UIColor.label
        for run in value.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                value[run.range].font = Theme.font(.body, 15, monospaced: true)
                value[run.range].backgroundColor = Theme.codeFill
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) {
                    value[run.range].font = UIFont(descriptor: descriptor, size: baseFont.pointSize)
                }
            }
        }
        let result = NSMutableAttributedString(value)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = UIFontMetrics(forTextStyle: .body).scaledValue(for: isUser ? 2 : 4)
        paragraph.paragraphSpacing = isUser ? 6 : 12
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// Hermes asks before a sensitive step. Interactive glass groups the decision.
private final class ApprovalPanel: UIView {
    var respond: ((Bool) -> Void)?
    private let allow = Theme.glassButton(title: "Allow Once", prominent: true, identifier: "approval.allow")
    private let deny = Theme.glassButton(title: "Deny", identifier: "approval.deny")

    init(approval: AgentApproval) {
        super.init(frame: .zero)
        let surface = Theme.glassSurface(cornerRadius: 26)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        let title = Theme.label("Approval needed", Theme.font(.footnote, 13, .semibold), color: Theme.accent)
        let prompt = Theme.label(approval.prompt, Theme.font(.subheadline, 15), lines: 0)
        let stack = UIStackView(arrangedSubviews: [title, prompt])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(stack)
        if !approval.command.isEmpty {
            let command = UITextView()
            command.text = approval.command
            command.font = Theme.font(.caption1, 12, monospaced: true)
            command.adjustsFontForContentSizeCategory = true
            command.textColor = .label
            command.backgroundColor = Theme.codeFill
            command.layer.cornerRadius = 12
            command.layer.cornerCurve = .continuous
            command.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            command.textContainer.lineFragmentPadding = 0
            command.isEditable = false
            command.isSelectable = true
            command.accessibilityLabel = "Command requiring approval"
            stack.addArrangedSubview(command)
            command.heightAnchor.constraint(equalToConstant: min(110, max(40, CGFloat(approval.command.split(separator: "\n").count) * 18 + 16))).isActive = true
        }
        allow.addAction(UIAction { [weak self] _ in self?.respond?(true) }, for: .touchUpInside)
        deny.addAction(UIAction { [weak self] _ in self?.respond?(false) }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [deny, allow])
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor, constant: -14)
        ])
        accessibilityElements = [title, prompt] + stack.arrangedSubviews.filter { $0 is UITextView } + [deny, allow]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func setResponding(_ value: Bool) {
        allow.isEnabled = !value
        deny.isEnabled = !value
        allow.configuration?.showsActivityIndicator = value
    }
}
