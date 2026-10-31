import UIKit

/// Secondary sheet: start a build from the app's saved Mac recipe, follow its
/// real status, and open the expiring install link for a finished IPA.
@MainActor
final class BuildsViewController: UIViewController {
    var onNewThread: (() -> Void)?
    private let model: SquircleModel
    private var project: AppProject
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private let notice = Theme.label("", Theme.Text.body, color: .secondaryLabel, lines: 0)
    private let titleLabel = Theme.label("Builds", Theme.Text.bodyStrong)
    private let close = Theme.glassButton(symbol: "xmark", identifier: "builds.close", accessibilityLabel: "Close builds")
    private let create = Theme.glassButton(symbol: "hammer", title: "Build", identifier: "project.build")
    private let install = Theme.glassButton(symbol: "arrow.down.circle", title: "Install", prominent: true, identifier: "build.install")
    private var rowViews: [String: BuildRow] = [:]
    private var renderedOrder: [String] = []
    private var observation: Task<Void, Never>?
    private var isSubmitting = false
    private var latestInstallable: AppBuild?

    init(model: SquircleModel, project: AppProject) {
        self.model = model
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        create.addAction(UIAction { [weak self] _ in self?.createBuild() }, for: .touchUpInside)
        install.addAction(UIAction { [weak self] _ in
            guard let self, let build = latestInstallable else { return }
            installBuild(build)
        }, for: .touchUpInside)

        rows.axis = .vertical
        notice.textAlignment = .center
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        let header = UIView()
        [header, scroll, install].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        [close, titleLabel, create].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        [rows, notice].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview($0) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.group),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Space.group),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.group),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: Theme.Space.tap), close.heightAnchor.constraint(equalToConstant: Theme.Space.tap),
            create.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            create.topAnchor.constraint(equalTo: header.topAnchor),
            create.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            create.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: close.trailingAnchor, constant: Theme.Space.row),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: create.leadingAnchor, constant: -Theme.Space.row),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Space.rowPad),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.row),
            rows.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.row),
            notice.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: Theme.Space.section),
            notice.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.margin),
            notice.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.margin),
            notice.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -110),
            install.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            install.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Space.rowPad),
            install.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            install.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            install.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Theme.Space.margin)
        ])
        if #available(iOS 26.0, *) {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = scroll
            edge.edge = .bottom
            install.addInteraction(edge)
        }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { await self?.model.refresh(); refresh?.endRefreshing() }
        }, for: .valueChanged)
        scroll.refreshControl = refresh
        observation = model.observe(by: self, after: .milliseconds(100)) { $0.render() }
        render()
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private func render() {
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        let builds = model.builds(for: project)
        latestInstallable = builds.first(where: \.canInstall)
        let busy = isSubmitting || model.buildingProjectIDs.contains(project.id)
        create.isEnabled = !busy
        if create.configuration?.showsActivityIndicator != busy { create.configuration?.showsActivityIndicator = busy }
        install.isHidden = latestInstallable == nil
        install.isEnabled = !isSubmitting
        if let latest = latestInstallable {
            let title = latest.version.isEmpty ? "Install" : "Install \(latest.version)"
            if install.configuration?.title != title { install.configuration?.title = title }
        }

        let ids = builds.map(\.id)
        for id in Array(rowViews.keys) where !ids.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        for build in builds {
            let row = rowViews[build.id] ?? {
                let row = BuildRow(buildID: build.id)
                row.addAction(UIAction { [weak self, weak row] _ in
                    guard let self, let build = row?.build else { return }
                    self.showDetail(build)
                }, for: .touchUpInside)
                rowViews[build.id] = row
                return row
            }()
            row.configure(build)
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
        let message = model.error ?? (builds.isEmpty ? (project.canBuild ? "No builds yet" : "No build recipe yet") : nil)
        notice.text = message
        notice.isHidden = message == nil
        notice.textColor = model.error == nil ? .secondaryLabel : Theme.failure
    }

    private func createBuild() {
        guard !isSubmitting else { return }
        guard project.canBuild else {
            let alert = UIAlertController(title: "No build recipe", message: "Ask the coding agent in a thread to set up this app’s Xcode build.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "New Thread", style: .default) { [weak self] _ in self?.onNewThread?() })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
            return
        }
        Theme.selectionHaptic()
        isSubmitting = true
        render()
        Task { [weak self] in
            guard let self else { return }
            if await model.startBuild(for: project) == nil {
                showMessage(title: "Couldn’t start build", message: model.error)
            }
            isSubmitting = false
            render()
        }
    }

    private func installBuild(_ build: AppBuild) {
        guard !isSubmitting else { return }
        Theme.selectionHaptic()
        isSubmitting = true
        render()
        Task { [weak self] in
            guard let self else { return }
            if await !model.install(build) { showMessage(title: "Couldn’t install", message: model.error) }
            isSubmitting = false
            render()
        }
    }

    private func showDetail(_ build: AppBuild) {
        guard presentedViewController == nil else { return }
        Theme.selectionHaptic()
        let navigation = UINavigationController(rootViewController: BuildDetailViewController(model: model, build: build))
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    private func showMessage(title: String, message: String?) {
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Version, real job state and age. Tapping opens the build's detail.
@MainActor
final class BuildRow: UIControl {
    let buildID: String
    private(set) var build: AppBuild?
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }
    private let symbol = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = Theme.label("", Theme.Text.body)
    private let detailLabel = Theme.label("", Theme.Text.line, color: .secondaryLabel, lines: 2)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let separator = UIView()
    private let highlight = UIView()

    init(buildID: String) {
        self.buildID = buildID
        super.init(frame: .zero)
        accessibilityIdentifier = "build.row"
        accessibilityValue = buildID
        isAccessibilityElement = true
        accessibilityTraits = .button
        highlight.backgroundColor = Theme.pressedFill
        highlight.layer.cornerRadius = Theme.Radius.large
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        spinner.hidesWhenStopped = true
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = Theme.Space.tight
        let glyph = UIView()
        [symbol, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glyph.addSubview($0) }
        let content = UIStackView(arrangedSubviews: [glyph, text, chevron])
        content.alignment = .center
        content.spacing = Theme.Space.glyphGap
        content.isUserInteractionEnabled = false
        [highlight, content, separator].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        separator.backgroundColor = .separator
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            glyph.heightAnchor.constraint(equalToConstant: Theme.Space.glyph),
            symbol.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), symbol.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            // With the list's inset, the glyph sits at the margin and the text at 48.
            content.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.rowPad),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.rowPad),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.rowPad),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.rowPad),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.Space.glyph + Theme.Space.glyphGap),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.rowPad),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale))
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A build state's symbol and colour; nil while it runs (a spinner shows).
    static func symbol(for status: String) -> (String?, UIColor) {
        switch status {
        case "succeeded": return ("checkmark.circle", Theme.success)
        case "failed": return ("xmark.octagon", Theme.failure)
        case "cancelled", "interrupted": return ("minus.circle", .secondaryLabel)
        case "queued": return ("clock", .secondaryLabel)
        case "running": return (nil, .secondaryLabel)
        default: return ("circle.dashed", .secondaryLabel)
        }
    }

    static func statusText(for build: AppBuild) -> String {
        switch build.status {
        case "queued": return "Queued"
        case "running": return "Building"
        case "succeeded": return "Succeeded"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "interrupted": return "Interrupted"
        default: return build.status.capitalized
        }
    }

    func configure(_ build: AppBuild) {
        guard build != self.build else { updateDate(); return }
        self.build = build
        titleLabel.text = build.version.isEmpty ? build.title : build.version
        let (symbolName, tint) = Self.symbol(for: build.status)
        symbol.image = symbolName.map { UIImage(systemName: $0) } ?? nil
        symbol.tintColor = tint
        if symbolName == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        updateDate()
    }

    private func updateDate() {
        guard let build else { return }
        var parts = [Self.statusText(for: build)]
        if build.date.timeIntervalSince1970 > 0 { parts.append(Theme.relativeDate.localizedString(for: build.date, relativeTo: .now)) }
        let detail = parts.joined(separator: " · ")
        if detailLabel.text != detail { detailLabel.text = detail }
        accessibilityLabel = [titleLabel.text, detail].compactMap { $0 }.joined(separator: ", ")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let animations = { self.highlight.alpha = self.isHighlighted ? 1 : 0 }
            if isHighlighted { animations() } else { UIView.animate(withDuration: 0.25, animations: animations) }
        }
    }
}
