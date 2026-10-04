import Combine
import UIKit

@MainActor
final class ProjectViewController: UIViewController {
    let model: SquircleModel
    private(set) var project: AppProject
    let preview: DevicePreview
    let titleLabel = Studio.label(size: 30, weight: .semibold)
    let headerControls = UIView()
    let listContent = UIView()
    let composerView = UIView()
    var onBack: (() -> Void)?

    private let previewBinding: PreviewBinding
    private let back = GlassButton(symbol: "chevron.left", label: "Your apps", diameter: 44)
    private let buildsButton = GlassButton(symbol: "shippingbox", label: "Builds", diameter: 44)
    private let composeButton = GlassButton(symbol: "square.and.pencil", label: "New thread", diameter: 56)
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private let errorLabel = Studio.label(size: 13, color: Studio.muted)
    private var subscriptions = Set<AnyCancellable>()
    private var rowsKey = ""
    private var threadRows: [StudioListRow] = []

    init(model: SquircleModel, project: AppProject) {
        self.model = model
        self.project = project
        preview = DevicePreview(name: project.name)
        preview.setPose(1)
        previewBinding = PreviewBinding(preview)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(model:project:)") }
    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Studio.canvas
        view.clipsToBounds = true
        [headerControls, preview, titleLabel, listContent, composerView].forEach(view.addSubview)
        headerControls.addSubview(back)
        headerControls.addSubview(buildsButton)
        back.accessibilityIdentifier = "project.back"
        buildsButton.accessibilityIdentifier = "project.builds"
        composeButton.accessibilityIdentifier = "thread.new"
        titleLabel.accessibilityTraits = .header
        titleLabel.lineBreakMode = .byTruncatingTail
        composerView.addSubview(composeButton)
        back.addAction(UIAction { [weak self] _ in
            Studio.haptic()
            self?.onBack?()
        }, for: .touchUpInside)
        buildsButton.addAction(UIAction { [weak self] _ in self?.openBuilds() }, for: .touchUpInside)
        composeButton.addAction(UIAction { [weak self] _ in self?.openThread(nil) }, for: .touchUpInside)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        listContent.addSubview(scroll)
        rows.axis = .vertical
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rows)
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listContent.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listContent.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -112),
            rows.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 26),
            rows.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -26)
        ])
        let refresh = UIRefreshControl()
        refresh.tintColor = Studio.muted
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { await self?.model.refresh(); refresh?.endRefreshing() }
        }, for: .valueChanged)
        scroll.refreshControl = refresh
        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        let top = view.safeAreaInsets.top + 8
        if headerControls.superview === view { place(headerControls, in: CGRect(x: 24, y: top, width: width - 48, height: 44)) }
        back.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        buildsButton.frame = CGRect(x: headerControls.bounds.width - 44, y: 0, width: 44, height: 44)
        let identityY = top + 61
        if preview.superview === view { preview.frame = CGRect(x: 23, y: identityY, width: 60, height: 76) }
        if titleLabel.superview === view {
            let available = max(0, width - 120)
            let size = titleLabel.sizeThatFits(CGSize(width: available, height: 80))
            titleLabel.frame = CGRect(x: 96, y: identityY + (76 - size.height) / 2,
                                     width: min(available, size.width), height: size.height)
        }
        let listTop = identityY + 96
        if listContent.superview === view { place(listContent, in: CGRect(x: 0, y: listTop, width: width, height: max(0, view.bounds.height - listTop))) }
        if composerView.superview === view { place(composerView, in: CGRect(x: width - 82, y: view.bounds.height - view.safeAreaInsets.bottom - 76, width: 56, height: 56)) }
        composeButton.frame = composerView.bounds
    }

    private func place(_ child: UIView, in frame: CGRect) {
        // Layout remains independent of the transition's animated transform.
        child.bounds = CGRect(origin: .zero, size: frame.size)
        child.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    private func render() {
        guard isViewLoaded else { return }
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        titleLabel.text = project.name
        previewBinding.update(model: model, project: project)
        threadRows.forEach { $0.updateRelativeDate() }
        let sessions = model.sessions(for: project)
        let key = project.name + "|" + (model.error ?? "") + "|\(model.isRunning):\(model.selectedSessionID ?? "")|" + sessions.map {
            "\($0.id):\($0.title):\($0.preview):\($0.updatedAt.timeIntervalSince1970)"
        }.joined(separator: "|")
        guard key != rowsKey else { return }
        rowsKey = key
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        threadRows.removeAll()
        errorLabel.text = model.error
        errorLabel.isHidden = model.error == nil
        rows.addArrangedSubview(errorLabel)
        for session in sessions {
            let prefix = project.name + " · "
            let title = session.title.hasPrefix(prefix) ? String(session.title.dropFirst(prefix.count)) : session.title
            let row = StudioListRow(title: title, preview: session.preview, date: session.updatedAt,
                                    active: model.isRunning && model.selectedSessionID == session.id)
            row.accessibilityIdentifier = "thread.row"
            row.accessibilityValue = session.id
            row.addAction(UIAction { [weak self] _ in self?.openThread(session.id) }, for: .touchUpInside)
            rows.addArrangedSubview(row)
            threadRows.append(row)
        }
        view.setNeedsLayout()
    }

    private func openThread(_ id: String?) {
        guard presentedViewController == nil else { return }
        Studio.haptic()
        let controller = ThreadViewController(model: model, project: project, sessionID: id)
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.large()]
        controller.sheetPresentationController?.preferredCornerRadius = 30
        controller.sheetPresentationController?.prefersGrabberVisible = true
        present(controller, animated: true)
    }

    private func openBuilds() {
        guard presentedViewController == nil else { return }
        Studio.haptic()
        let controller = ProjectBuildsViewController(model: model, project: project)
        controller.onNewThread = { [weak self, weak controller] in
            controller?.dismiss(animated: true) { self?.openThread(nil) }
        }
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.large()]
        controller.sheetPresentationController?.preferredCornerRadius = 30
        controller.sheetPresentationController?.prefersGrabberVisible = true
        present(controller, animated: true)
    }
}

@MainActor
private final class StudioListRow: UIControl {
    private let date: Date?
    private let dateLabel = Studio.label(size: 12, color: Studio.muted)
    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(title: String, preview: String, date: Date?, active: Bool = false, trailing: String? = nil) {
        self.date = date
        super.init(frame: .zero)
        let titleLabel = Studio.label(title, size: 20, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = UIStackView()
        heading.axis = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 14
        if active {
            let dot = UIView()
            dot.backgroundColor = Studio.accent
            dot.layer.cornerRadius = 3
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            heading.addArrangedSubview(dot)
        }
        heading.addArrangedSubview(titleLabel)
        dateLabel.textAlignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        heading.addArrangedSubview(dateLabel)
        let content = UIStackView(arrangedSubviews: [heading])
        content.axis = .vertical
        content.spacing = 8
        let cleanPreview = preview.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPreview.isEmpty {
            let subtitle = Studio.label(cleanPreview, size: 14, color: Studio.muted)
            subtitle.lineBreakMode = .byTruncatingTail
            content.addArrangedSubview(subtitle)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isUserInteractionEnabled = false
        addSubview(content)
        let line = UIView()
        line.backgroundColor = Studio.line
        line.translatesAutoresizingMaskIntoConstraints = false
        line.isUserInteractionEnabled = false
        addSubview(line)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 23),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -23),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 74)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = [title, cleanPreview, active ? "Running" : nil, trailing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        updateRelativeDate()
        if let trailing { dateLabel.text = trailing }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func updateRelativeDate() {
        guard let date, date.timeIntervalSince1970 > 0 else { dateLabel.text = nil; return }
        dateLabel.text = Self.dateFormatter.localizedString(for: date, relativeTo: .now)
    }
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Studio.ink.withAlphaComponent(0.035) : .clear }
    }
}

@MainActor
private final class ProjectBuildsViewController: UIViewController {
    var onNewThread: (() -> Void)?
    private let model: SquircleModel
    private var project: AppProject
    private let rows = UIStackView()
    private let create = GlassButton(symbol: "hammer", label: "Create build", diameter: 44)
    private let install = GlassButton(symbol: "arrow.down", label: "Install latest build", diameter: 56)
    private let errorLabel = Studio.label(size: 13, color: Studio.muted)
    private var subscriptions = Set<AnyCancellable>()
    private var renderedKey = ""
    private var isSubmitting = false
    private var latestBuild: AppBuild?

    init(model: SquircleModel, project: AppProject) {
        self.model = model; self.project = project
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Studio.canvas
        let close = GlassButton(symbol: "xmark", label: "Close builds", diameter: 44)
        close.accessibilityIdentifier = "builds.close"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        create.accessibilityIdentifier = "project.build"
        create.addAction(UIAction { [weak self] _ in self?.createBuild() }, for: .touchUpInside)
        install.accessibilityIdentifier = "build.install"
        install.addAction(UIAction { [weak self] _ in
            guard let self, let build = latestBuild else { return }
            installBuild(build)
        }, for: .touchUpInside)
        let title = Studio.label("Builds", size: 25, weight: .semibold)
        title.accessibilityTraits = .header
        let header = UIView()
        let scroll = UIScrollView()
        [header, scroll, install].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        [close, title, create].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rows)
        errorLabel.numberOfLines = 0
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            header.heightAnchor.constraint(equalToConstant: 44),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor), close.topAnchor.constraint(equalTo: header.topAnchor),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            create.trailingAnchor.constraint(equalTo: header.trailingAnchor), create.topAnchor.constraint(equalTo: header.topAnchor),
            create.widthAnchor.constraint(equalToConstant: 44), create.heightAnchor.constraint(equalToConstant: 44),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 26),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -110),
            rows.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 26),
            rows.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -26),
            install.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -26),
            install.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            install.widthAnchor.constraint(equalToConstant: 56), install.heightAnchor.constraint(equalToConstant: 56)
        ])
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { await self?.model.refresh(); refresh?.endRefreshing() }
        }, for: .valueChanged)
        scroll.refreshControl = refresh
        model.objectWillChange.receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render()
    }

    private func render() {
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        let builds = model.builds(for: project)
        latestBuild = builds.first(where: \.canInstall)
        create.isEnabled = !isSubmitting && !model.buildingProjectIDs.contains(project.id)
        install.isHidden = latestBuild == nil
        install.isEnabled = !isSubmitting
        let key = (model.error ?? "") + "|" + builds.map { "\($0.id):\($0.status):\($0.version)" }.joined(separator: "|")
        guard key != renderedKey else { return }
        renderedKey = key
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        errorLabel.text = model.error; errorLabel.isHidden = model.error == nil
        rows.addArrangedSubview(errorLabel)
        for build in builds {
            let row = StudioListRow(title: build.version.isEmpty ? build.title : build.version,
                                    preview: build.status.capitalized, date: build.date,
                                    trailing: build.canInstall ? "Install" : nil)
            row.accessibilityIdentifier = "build.row"
            row.accessibilityValue = build.id
            row.addAction(UIAction { [weak self] _ in
                if build.canInstall { self?.installBuild(build) }
                else { self?.showError(title: build.status.capitalized, message: nil) }
            }, for: .touchUpInside)
            rows.addArrangedSubview(row)
        }
    }

    private func createBuild() {
        guard !isSubmitting else { return }
        guard project.canBuild else {
            let alert = UIAlertController(title: "No build configuration", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "New thread", style: .default) { [weak self, weak alert] _ in
                alert?.dismiss(animated: true) { self?.onNewThread?() }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
            return
        }
        Studio.haptic(); isSubmitting = true; render()
        Task { [weak self] in
            guard let self else { return }
            if await model.startBuild(for: project) == nil {
                showError(title: "Couldn’t build", message: model.error)
            }
            isSubmitting = false; render()
        }
    }

    private func installBuild(_ build: AppBuild) {
        guard !isSubmitting else { return }
        Studio.haptic(); isSubmitting = true; render()
        Task { [weak self] in
            guard let self else { return }
            if let url = await model.installURL(for: build) {
                if await UIApplication.shared.open(url) == false {
                    showError(title: "Couldn’t open installer", message: nil)
                }
            } else { showError(title: "Couldn’t install", message: model.error) }
            isSubmitting = false; render()
        }
    }

    private func showError(title: String, message: String?) {
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
