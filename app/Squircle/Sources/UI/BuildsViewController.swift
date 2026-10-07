import Combine
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
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private let titleLabel = Theme.label("Builds", Theme.font(.headline, 17, .semibold))
    private let close = Theme.glassButton(symbol: "xmark", identifier: "builds.close", accessibilityLabel: "Close builds")
    private let create = Theme.glassButton(symbol: "hammer", title: "Build", identifier: "project.build")
    private let install = Theme.glassButton(symbol: "arrow.down.circle", title: "Install", prominent: true, identifier: "build.install")
    private var rowViews: [String: BuildRow] = [:]
    private var renderedOrder: [String] = []
    private var subscriptions = Set<AnyCancellable>()
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
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = Theme.paper }
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
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            create.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            create.topAnchor.constraint(equalTo: header.topAnchor),
            create.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            create.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: close.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: create.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -12),
            notice.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 20),
            notice.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 32),
            notice.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -32),
            notice.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -110),
            install.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            install.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            install.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            install.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            install.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)
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
        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
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
                    if build.canInstall { self.installBuild(build) }
                    else { self.showMessage(title: BuildRow.statusText(for: build), message: build.previewError) }
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

    private func showMessage(title: String, message: String?) {
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Version, real job state and age. Tapping a finished IPA installs it.
@MainActor
final class BuildRow: UIControl {
    let buildID: String
    private(set) var build: AppBuild?
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }
    private let symbol = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = Theme.label("", Theme.font(.headline, 17, .semibold))
    private let detailLabel = Theme.label("", Theme.font(.subheadline, 15), color: .secondaryLabel, lines: 2)
    private let actionLabel = Theme.label("", Theme.font(.subheadline, 15, .semibold), color: Theme.accent)
    private let separator = UIView()
    private let highlight = UIView()
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(buildID: String) {
        self.buildID = buildID
        super.init(frame: .zero)
        accessibilityIdentifier = "build.row"
        accessibilityValue = buildID
        isAccessibilityElement = true
        accessibilityTraits = .button
        highlight.backgroundColor = Theme.pressedFill
        highlight.layer.cornerRadius = 18
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        spinner.hidesWhenStopped = true
        actionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionLabel.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 3
        let glyph = UIView()
        [symbol, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glyph.addSubview($0) }
        let content = UIStackView(arrangedSubviews: [glyph, text, actionLabel])
        content.alignment = .center
        content.spacing = 14
        content.isUserInteractionEnabled = false
        [highlight, content, separator].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        separator.backgroundColor = .separator
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 30),
            glyph.heightAnchor.constraint(equalToConstant: 30),
            symbol.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), symbol.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 58),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale))
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func statusText(for build: AppBuild) -> String {
        switch build.status {
        case "queued": return "Queued"
        case "running": return "Building"
        case "succeeded": return "Succeeded"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        default: return build.status.capitalized
        }
    }

    func configure(_ build: AppBuild) {
        guard build != self.build else { updateDate(); return }
        self.build = build
        titleLabel.text = build.version.isEmpty ? build.title : build.version
        let symbolName: String?
        let tint: UIColor
        switch build.status {
        case "succeeded": symbolName = "checkmark.circle.fill"; tint = Theme.success
        case "failed": symbolName = "xmark.octagon.fill"; tint = Theme.failure
        case "cancelled": symbolName = "minus.circle.fill"; tint = .secondaryLabel
        case "queued": symbolName = "clock.fill"; tint = .secondaryLabel
        case "running": symbolName = nil; tint = .secondaryLabel
        default: symbolName = "circle.dashed"; tint = .secondaryLabel
        }
        symbol.image = symbolName.map { UIImage(systemName: $0) } ?? nil
        symbol.tintColor = tint
        if symbolName == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        actionLabel.text = build.canInstall ? "Install" : nil
        actionLabel.isHidden = !build.canInstall
        updateDate()
    }

    private func updateDate() {
        guard let build else { return }
        var parts = [Self.statusText(for: build)]
        if build.previewState == "pending" || build.previewState == "running" { parts.append("Capturing screenshot") }
        if build.date.timeIntervalSince1970 > 0 { parts.append(Self.formatter.localizedString(for: build.date, relativeTo: .now)) }
        let detail = parts.joined(separator: " · ")
        if detailLabel.text != detail { detailLabel.text = detail }
        accessibilityLabel = [titleLabel.text, detail, build.canInstall ? "Install" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let animations = { self.highlight.alpha = self.isHighlighted ? 1 : 0 }
            if isHighlighted { animations() } else { UIView.animate(withDuration: 0.25, animations: animations) }
        }
    }
}
