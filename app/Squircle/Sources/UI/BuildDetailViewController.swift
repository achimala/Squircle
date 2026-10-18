import UIKit

/// One build: its state, version, timing and source, and for a failure the
/// Mac's reading of why (failing step, Xcode's errors with their source), with
/// the full log one push away.
@MainActor
final class BuildDetailViewController: UIViewController {
    private let model: SquircleModel
    private let buildID: String
    private var build: AppBuild
    private var failure: BuildFailure?
    /// The build state the failure was fetched for; refetch when it changes.
    private var fetchedState: String?
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let symbol = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = Theme.label("", Theme.font(.title2, 24, .bold))
    private let versionLabel = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private let facts = UIStackView()
    private let reason = UIStackView()
    private let logButton = Theme.glassButton(symbol: "doc.plaintext", title: "Full Log", identifier: "build.log")
    private let install = Theme.glassButton(symbol: "arrow.down.circle", title: "Install", prominent: true, identifier: "build.detail.install")
    private var observation: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var fetch: Task<Void, Never>?
    private var renderedFacts: [String] = []
    private struct Reason: Equatable { let failure: BuildFailure?; let fallback: String? }
    private var renderedReason: Reason?

    init(model: SquircleModel, build: AppBuild) {
        self.model = model
        self.buildID = build.id
        self.build = build
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = Theme.paper }
        navigationItem.title = "Build"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        logButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            navigationController?.pushViewController(BuildLogViewController(model: model, build: build), animated: true)
        }, for: .touchUpInside)
        install.addAction(UIAction { [weak self] _ in self?.installBuild() }, for: .touchUpInside)

        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        spinner.hidesWhenStopped = true
        let glyph = UIView()
        [symbol, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glyph.addSubview($0) }
        let status = UIStackView(arrangedSubviews: [glyph, statusLabel])
        status.spacing = 10
        status.alignment = .center
        facts.axis = .vertical
        facts.spacing = 10
        reason.axis = .vertical
        reason.spacing = 14
        let logRow = UIStackView(arrangedSubviews: [logButton, UIView()])
        content.axis = .vertical
        content.spacing = 6
        content.addArrangedSubview(status)
        content.addArrangedSubview(versionLabel)
        content.setCustomSpacing(24, after: versionLabel)
        content.addArrangedSubview(facts)
        content.setCustomSpacing(28, after: facts)
        content.addArrangedSubview(reason)
        content.setCustomSpacing(24, after: reason)
        content.addArrangedSubview(logRow)

        scroll.alwaysBounceVertical = true
        [scroll, install].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 30), glyph.heightAnchor.constraint(equalToConstant: 30),
            symbol.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), symbol.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -22),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -110),
            install.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            install.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            install.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            install.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        setContentScrollView(scroll, for: .top)
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if !build.status.isTerminalBuildState { renderFacts() }
            }
        }
        render()
    }

    private func render() {
        if let current = model.builds.first(where: { $0.id == buildID }) { build = current }
        if fetchedState != build.status, fetch == nil {
            let state = build.status
            fetch = Task { [weak self] in
                guard let self else { return }
                if let (job, failure) = try? await model.buildDetail(id: buildID) {
                    build = job
                    self.failure = failure
                    fetchedState = state
                }
                fetch = nil
                render()
            }
        }
        let (name, tint) = BuildRow.symbol(for: build.status)
        symbol.image = name.map { UIImage(systemName: $0) } ?? nil
        symbol.tintColor = tint
        if name == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        statusLabel.text = BuildRow.statusText(for: build)
        statusLabel.textColor = build.status == "failed" ? Theme.failure : .label
        versionLabel.text = [build.title, build.version].filter { !$0.isEmpty }.joined(separator: " ")
        install.isHidden = !build.canInstall
        if build.canInstall, !build.version.isEmpty { install.configuration?.title = "Install \(build.version)" }
        renderFacts()
        renderReason()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private func renderFacts() {
        var rows: [(String, String)] = []
        if let step = failure?.step { rows.append(("Failed during", step)) }
        rows.append(("Started", Self.dateFormatter.string(from: build.date)))
        let end = build.status.isTerminalBuildState ? build.updatedAt : .now
        if let took = Self.durationFormatter.string(from: max(0, end.timeIntervalSince(build.date))) {
            rows.append((build.status.isTerminalBuildState ? "Took" : "Running for", took))
        }
        if let request = build.request {
            let kind = request.mode == "simulator" ? "Simulator" : "Device"
            rows.append(("Build", "\(kind) · \(request.scheme) · \(request.configuration)"))
        }
        if let revision = build.sourceRevision {
            rows.append(("Source", String(revision.prefix(8)) + (build.sourceDirty == true ? " with uncommitted changes" : "")))
        }
        let flat = rows.flatMap { [$0.0, $0.1] }
        guard flat != renderedFacts else { return }
        renderedFacts = flat
        facts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (name, value) in rows {
            let key = Theme.label(name, Theme.font(.subheadline, 15), color: .secondaryLabel)
            key.setContentHuggingPriority(.required, for: .horizontal)
            key.setContentCompressionResistancePriority(.required, for: .horizontal)
            let text = Theme.label(value, Theme.font(.subheadline, 15), lines: 0)
            text.textAlignment = .right
            let row = UIStackView(arrangedSubviews: [key, text])
            row.spacing = 16
            row.alignment = .firstBaseline
            facts.addArrangedSubview(row)
        }
    }

    private func renderReason() {
        let succeeded = build.status == "succeeded"
        let shown = Reason(failure: succeeded ? nil : failure, fallback: succeeded ? nil : build.error.map(Self.withoutLogPath))
        guard shown != renderedReason else { return }
        renderedReason = shown
        let fallback = shown.fallback
        reason.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let issues = shown.failure?.errors ?? []
        if !issues.isEmpty {
            reason.addArrangedSubview(Theme.label(issues.count == 1 ? "Error" : "\(issues.count) errors", Theme.font(.headline, 17, .semibold)))
            issues.forEach { reason.addArrangedSubview(issueView($0)) }
        } else if let message = shown.failure?.message ?? fallback {
            reason.addArrangedSubview(Theme.label("Error", Theme.font(.headline, 17, .semibold)))
            reason.addArrangedSubview(Theme.label(message, Theme.font(.body, 17), lines: 0))
        }
        if let commands = shown.failure?.failedCommands, !commands.isEmpty {
            let title = Theme.label("Failed commands", Theme.font(.headline, 17, .semibold))
            reason.addArrangedSubview(title)
            reason.setCustomSpacing(6, after: title)
            for command in commands {
                reason.addArrangedSubview(Theme.label(command, Theme.font(.footnote, 13), color: .secondaryLabel, lines: 3))
            }
        }
        reason.isHidden = reason.arrangedSubviews.isEmpty
    }

    private func issueView(_ issue: BuildFailure.Issue) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.addArrangedSubview(Theme.label(issue.message, Theme.font(.body, 17, .medium), color: Theme.failure, lines: 0))
        if let file = issue.file {
            let place = issue.line.map { "\(file):\($0)" } ?? file
            let label = Theme.label(place, .monospacedSystemFont(ofSize: 13, weight: .regular), color: .secondaryLabel, lines: 0)
            label.lineBreakMode = .byTruncatingHead
            stack.addArrangedSubview(label)
        }
        if let detail = issue.detail {
            if issue.file == nil {
                stack.addArrangedSubview(Theme.label(detail, Theme.font(.subheadline, 15), color: .secondaryLabel, lines: 0))
            } else {
                stack.addArrangedSubview(CodeExcerpt(detail))
            }
        }
        return stack
    }

    private static func withoutLogPath(_ error: String) -> String {
        guard let range = error.range(of: "; see /", options: .backwards) else { return error }
        return String(error[..<range.lowerBound])
    }

    private func installBuild() {
        Theme.selectionHaptic()
        install.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            if await !model.install(build), presentedViewController == nil {
                let alert = UIAlertController(title: "Couldn’t install", message: model.error, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            install.isEnabled = true
        }
    }
}

/// The compiler's source excerpt, scrolled sideways rather than wrapped.
@MainActor
private final class CodeExcerpt: UIView {
    init(_ text: String) {
        super.init(frame: .zero)
        backgroundColor = Theme.codeFill
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        let label = Theme.label(text, .monospacedSystemFont(ofSize: 12, weight: .regular), color: .label, lines: 0)
        [scroll, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll)
        scroll.addSubview(label)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalTo: label.heightAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The build's log, newest at the bottom; follows a running build.
@MainActor
final class BuildLogViewController: UIViewController {
    private let model: SquircleModel
    private let build: AppBuild
    private let text = UITextView()
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private var loader: Task<Void, Never>?
    /// The phone shows at most this much of the end of a log.
    private static let tailBytes = 262_144

    init(model: SquircleModel, build: AppBuild) {
        self.model = model
        self.build = build
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { loader?.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = Theme.paper }
        navigationItem.title = "Log"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in
            guard let self, let log = text.text, !log.isEmpty else { return }
            let share = UIActivityViewController(activityItems: [log], applicationActivities: nil)
            share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
            present(share, animated: true)
        })
        text.isEditable = false
        text.alwaysBounceVertical = true
        text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        text.accessibilityIdentifier = "build.log.text"
        notice.textAlignment = .center
        [text, notice].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: view.topAnchor),
            text.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            notice.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
        setContentScrollView(text, for: .top)
        notice.text = "Loading…"
        loader = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        do {
            let probe = try await model.buildLog(id: build.id, offset: 0, limit: 1)
            let size = probe.size ?? 0
            var offset = max(0, size - Self.tailBytes)
            let first = try await model.buildLog(id: build.id, offset: offset, limit: Self.tailBytes)
            offset = first.nextOffset
            var body = first.text
            // Start at a line boundary when the tail cuts into one.
            if size > Self.tailBytes, let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
            append(body, scrollToEnd: true)
            notice.text = body.isEmpty ? "No log yet" : nil
            // Follow a build that is still running.
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                let running = !(model.builds.first(where: { $0.id == build.id })?.status ?? build.status).isTerminalBuildState
                let page = try await model.buildLog(id: build.id, offset: offset, limit: Self.tailBytes)
                offset = page.nextOffset
                if !page.text.isEmpty {
                    let atEnd = text.contentOffset.y >= text.contentSize.height - text.bounds.height - 40
                    append(page.text, scrollToEnd: atEnd)
                    notice.text = nil
                }
                if !running && !page.hasMore { break }
            }
        } catch is CancellationError {
        } catch {
            if text.text.isEmpty { notice.text = error.localizedDescription }
        }
    }

    private func append(_ chunk: String, scrollToEnd: Bool) {
        let attributed = NSMutableAttributedString()
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        chunk.enumerateLines { line, _ in
            let failing = line.contains("error: ") || line.hasPrefix("** ") && line.hasSuffix(" FAILED **")
            attributed.append(NSAttributedString(string: line + "\n", attributes: [
                .font: font, .foregroundColor: failing ? Theme.failure : UIColor.label
            ]))
        }
        text.textStorage.append(attributed)
        if scrollToEnd {
            text.layoutIfNeeded()
            text.scrollRangeToVisible(NSRange(location: max(0, text.textStorage.length - 1), length: 1))
        }
    }
}

extension String {
    /// Queued and running builds are the only states that still change.
    var isTerminalBuildState: Bool { self != "queued" && self != "running" }
}
