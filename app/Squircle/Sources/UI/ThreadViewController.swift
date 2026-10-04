import Combine
import UIKit

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
    private let titleLabel = UILabel()
    private let projectLabel = UILabel()
    private let footer = UIStackView()
    private let approvalContainer = UIStackView()
    private let statusLabel = UILabel()
    private let input = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let composer = UIVisualEffectView()
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
        overrideUserInterfaceStyle = .light
        view.backgroundColor = ThreadPalette.ivory
        buildHeader()
        buildConversation()
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
        updateInputHeight()
        let height = table.bounds.height
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

    private func buildHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        let close = UIButton(type: .system)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
        close.tintColor = ThreadPalette.ink
        close.backgroundColor = ThreadPalette.stone
        close.layer.cornerRadius = 22
        close.accessibilityLabel = "Close thread"
        close.accessibilityIdentifier = "thread.close"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) }, for: .touchUpInside)
        header.addSubview(close)

        projectLabel.text = project.name
        projectLabel.font = ThreadPalette.font(12, weight: .medium, style: .caption1)
        projectLabel.textColor = ThreadPalette.muted
        projectLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = "New thread"
        titleLabel.font = ThreadPalette.font(17, weight: .medium)
        titleLabel.textColor = ThreadPalette.ink
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        let titles = UIStackView(arrangedSubviews: [projectLabel, titleLabel])
        titles.axis = .vertical
        titles.spacing = 4
        titles.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titles)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            titles.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 14),
            titles.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            titles.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            titles.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4)
        ])
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
        table.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
        table.scrollIndicatorInsets = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 5)
        table.register(ThreadMessageCell.self, forCellReuseIdentifier: ThreadMessageCell.reuseID)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func buildComposer() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.axis = .vertical
        footer.spacing = 10
        view.addSubview(footer)
        approvalContainer.axis = .vertical
        approvalContainer.isHidden = true
        footer.addArrangedSubview(approvalContainer)

        statusLabel.font = ThreadPalette.font(12, style: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = ThreadPalette.muted
        statusLabel.numberOfLines = 3
        statusLabel.isHidden = true
        footer.addArrangedSubview(statusLabel)

        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = UIColor.white.withAlphaComponent(0.45)
            glass.isInteractive = true
            composer.effect = glass
        } else {
            composer.effect = UIBlurEffect(style: .systemThinMaterial)
        }
        composer.layer.cornerRadius = 28
        composer.layer.cornerCurve = .continuous
        composer.clipsToBounds = true
        footer.addArrangedSubview(composer)
        let content = composer.contentView

        input.translatesAutoresizingMaskIntoConstraints = false
        input.delegate = self
        input.backgroundColor = .clear
        input.textColor = ThreadPalette.ink
        input.tintColor = ThreadPalette.accent
        input.font = ThreadPalette.font(17)
        input.adjustsFontForContentSizeCategory = true
        input.textContainerInset = UIEdgeInsets(top: 13, left: 0, bottom: 13, right: 0)
        input.textContainer.lineFragmentPadding = 0
        input.isScrollEnabled = false
        input.keyboardDismissMode = .interactive
        input.accessibilityLabel = "Message Hermes"
        input.accessibilityIdentifier = "thread.input"
        input.returnKeyType = .default
        content.addSubview(input)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "Message Hermes…"
        placeholder.font = input.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = ThreadPalette.muted
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        input.addSubview(placeholder)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.backgroundColor = ThreadPalette.accent
        sendButton.tintColor = .white
        sendButton.layer.cornerRadius = 21
        sendButton.accessibilityIdentifier = "thread.send"
        sendButton.addAction(UIAction { [weak self] _ in self?.sendOrStop() }, for: .touchUpInside)
        content.addSubview(sendButton)
        inputHeight = input.heightAnchor.constraint(equalToConstant: 50)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            table.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            input.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            input.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            input.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),
            inputHeight,
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 13),
            sendButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 42),
            sendButton.heightAnchor.constraint(equalToConstant: 42)
        ])
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
                input.font = ThreadPalette.font(17)
                placeholder.font = input.font
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
        let title = model.sessions.first(where: { $0.id == model.selectedSessionID })?.title ?? "New thread"
        let prefix = project.name + " · "
        titleLabel.text = title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title

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
        statusLabel.text = status
        statusLabel.isHidden = status.isEmpty
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
        let card = ThreadApprovalCard(approval: approval)
        card.respond = { [weak self, weak card] allowed in
            guard let self, !resolvingApproval else { return }
            resolvingApproval = true
            card?.setResponding(true)
            Task {
                await self.model.resolveApproval(approval, approved: allowed)
                self.resolvingApproval = false
                card?.setResponding(false)
            }
        }
        approvalContainer.addArrangedSubview(card)
        UIAccessibility.post(notification: .announcement, argument: "Hermes needs your approval.")
    }

    private func updateSendButton() {
        let running = !isOpening && model.isRunning
        let symbol = running ? "stop.fill" : "arrow.up"
        sendButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: running ? 13 : 18, weight: .semibold)), for: .normal)
        sendButton.accessibilityLabel = running ? "Stop response" : "Send message"
        sendButton.isEnabled = !isOpening && (running || (!model.isLoading && !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.35
        placeholder.isHidden = !input.text.isEmpty
    }

    private func sendOrStop() {
        if model.isRunning {
            Task { await model.stop() }
            return
        }
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isOpening, !model.isLoading, !text.isEmpty else { return }
        input.text = ""
        updateInputHeight()
        updateSendButton()
        wasNearBottom = true
        scrollToBottom(animated: !UIAccessibility.isReduceMotionEnabled)
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
        let height = min(max(50, desired), maximum)
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

private enum ThreadPalette {
    static let ivory = UIColor(red: 0.965, green: 0.955, blue: 0.935, alpha: 1)
    static let ink = UIColor(red: 0.12, green: 0.13, blue: 0.12, alpha: 1)
    static let muted = UIColor(white: 0.5, alpha: 1)
    static let accent = UIColor(red: 0.39, green: 0.43, blue: 0.86, alpha: 1)
    static let stone = UIColor(red: 0.921, green: 0.910, blue: 0.888, alpha: 1)
    static func font(_ size: CGFloat, weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }
}

private final class ThreadMessageCell: UITableViewCell {
    static let reuseID = "thread.message"
    private let bubble = UIView()
    private let text = UITextView()
    private let tools = UIButton(type: .system)
    private let toolDetails = UILabel()
    private let content = UIStackView()
    private var contentLeading: NSLayoutConstraint!
    private var contentTrailing: NSLayoutConstraint!
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
        content.spacing = 9
        bubble.addSubview(content)

        text.backgroundColor = .clear
        text.isEditable = false
        text.isSelectable = true
        text.isScrollEnabled = false
        text.textContainerInset = .zero
        text.textContainer.lineFragmentPadding = 0
        text.adjustsFontForContentSizeCategory = true
        text.linkTextAttributes = [.foregroundColor: ThreadPalette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        content.addArrangedSubview(text)

        tools.contentHorizontalAlignment = .leading
        tools.tintColor = ThreadPalette.muted
        tools.titleLabel?.font = ThreadPalette.font(12, style: .caption1)
        tools.titleLabel?.adjustsFontForContentSizeCategory = true
        tools.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            toolsExpanded.toggle()
            updateTools()
            var ancestor = self.superview
            while let current = ancestor {
                if let table = current as? UITableView { table.performBatchUpdates(nil); break }
                ancestor = current.superview
            }
        }, for: .touchUpInside)
        content.addArrangedSubview(tools)
        toolDetails.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 11, weight: .regular))
        toolDetails.adjustsFontForContentSizeCategory = true
        toolDetails.textColor = ThreadPalette.muted
        toolDetails.numberOfLines = 0
        content.addArrangedSubview(toolDetails)
        contentLeading = content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor)
        contentTrailing = content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -14),
            contentLeading, contentTrailing
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ next: ChatMessage) {
        if message?.id != next.id { toolsExpanded = false }
        let changedText = message?.content != next.content || message?.role != next.role
        message = next
        let user = next.role == "user"
        bubble.backgroundColor = user ? ThreadPalette.stone : .clear
        contentLeading.constant = user ? 16 : 0
        contentTrailing.constant = user ? -16 : 0
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
        tools.setTitle("\(toolsExpanded ? "⌄" : "›")  \(title)", for: .normal)
        tools.accessibilityLabel = "\(toolsExpanded ? "Hide" : "Show") tool details, \(title)"
        toolDetails.text = names.joined(separator: "\n")
        toolDetails.isHidden = names.isEmpty || !toolsExpanded
    }

    private static func markdown(_ source: String, isUser: Bool) -> NSAttributedString {
        let baseFont = ThreadPalette.font(17)
        var value = (isUser ? nil : try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        value.font = baseFont
        value.foregroundColor = ThreadPalette.ink
        for run in value.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                value[run.range].font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
                value[run.range].backgroundColor = ThreadPalette.stone
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) { value[run.range].font = UIFont(descriptor: descriptor, size: baseFont.pointSize) }
            }
        }
        let result = NSMutableAttributedString(value)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 26)
        paragraph.paragraphSpacing = 10
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}

private final class ThreadApprovalCard: UIView {
    var respond: ((Bool) -> Void)?
    private let allow = UIButton(type: .system)
    private let deny = UIButton(type: .system)

    init(approval: AgentApproval) {
        super.init(frame: .zero)
        backgroundColor = ThreadPalette.stone
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        let title = UILabel()
        title.text = "Your approval"
        title.font = ThreadPalette.font(12, weight: .semibold, style: .caption1)
        title.textColor = ThreadPalette.accent
        title.adjustsFontForContentSizeCategory = true
        let prompt = UILabel()
        prompt.text = approval.prompt
        prompt.font = ThreadPalette.font(14)
        prompt.textColor = ThreadPalette.ink
        prompt.numberOfLines = 0
        prompt.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [title, prompt])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        if !approval.command.isEmpty {
            let command = UITextView()
            command.text = approval.command
            command.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            command.adjustsFontForContentSizeCategory = true
            command.textColor = ThreadPalette.ink
            command.backgroundColor = .clear
            command.textContainerInset = .zero
            command.textContainer.lineFragmentPadding = 0
            command.isEditable = false
            command.isSelectable = true
            command.accessibilityLabel = "Command requiring approval"
            stack.addArrangedSubview(command)
            command.heightAnchor.constraint(equalToConstant: min(90, max(36, CGFloat(approval.command.split(separator: "\n").count) * 18))).isActive = true
        }
        var allowStyle = UIButton.Configuration.filled()
        allowStyle.title = "Allow once"
        allowStyle.baseBackgroundColor = ThreadPalette.accent
        allowStyle.baseForegroundColor = .white
        allowStyle.cornerStyle = .capsule
        allow.configuration = allowStyle
        var denyStyle = UIButton.Configuration.plain()
        denyStyle.title = "Deny"
        denyStyle.baseForegroundColor = ThreadPalette.ink
        deny.configuration = denyStyle
        allow.addAction(UIAction { [weak self] _ in self?.respond?(true) }, for: .touchUpInside)
        deny.addAction(UIAction { [weak self] _ in self?.respond?(false) }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [deny, UIView(), allow])
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func setResponding(_ value: Bool) { allow.isEnabled = !value; deny.isEnabled = !value }
}
