import UIKit
import Combine

final class StudioViewController: UIViewController {
    let model: SquircleModel
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let connection = Studio.label("Connecting", size: 12, color: Studio.muted)
    private let dot = UIView()
    private var subscriptions = Set<AnyCancellable>()
    private var renderedKey = ""
    private var layoutIdentity = ""
    private var heroes: [String: ProjectHero] = [:]
    private var workspaceTransition: WorkspaceTransition?
    private var galleryIndex = 0
    private var galleryProjectID: String?

    init(model: SquircleModel) { self.model = model; galleryProjectID = model.selectedProjectID; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); render() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Studio.canvas
        scroll.alwaysBounceVertical = true; scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10), stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -22), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40)])
        let refresh = UIRefreshControl(); refresh.tintColor = Studio.accent
        refresh.addAction(UIAction { [weak self, weak refresh] _ in Task { await self?.model.refresh(); refresh?.endRefreshing() } }, for: .valueChanged)
        scroll.refreshControl = refresh
        model.objectWillChange.receive(on: DispatchQueue.main).debounce(for: .milliseconds(90), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render()
    }

    private func render() {
        guard presentedViewController == nil else { return }
        if let id = galleryProjectID, let index = model.projects.firstIndex(where: { $0.id == id }) { galleryIndex = index }
        connection.text = model.connected ? "Mac online" : "Mac offline"
        dot.backgroundColor = model.connected ? UIColor(red: 0.20, green: 0.69, blue: 0.45, alpha: 1) : Studio.muted
        for project in model.projects { heroes[project.id]?.update(build: model.builds(for: project).first(where: { $0.canInstall })) }
        let key = "\(galleryIndex):\(model.error ?? "")|" + model.projects.map { project in
            "\(project.id):\(project.name):\(project.subtitle):" + model.builds(for: project).prefix(3).map { "\($0.id):\($0.status):\($0.version)" }.joined(separator: ";")
        }.joined(separator: "|")
        guard key != renderedKey || stack.arrangedSubviews.isEmpty else { return }
        renderedKey = key
        let identity = "\(galleryIndex):\(model.error ?? "")|" + model.projects.map { "\($0.id):\($0.name):\($0.subtitle)" }.joined(separator: "|")
        if identity == layoutIdentity, !heroes.isEmpty {
            for project in model.projects {
                heroes[project.id]?.update(build: model.builds(for: project).first(where: { $0.canInstall }) ?? model.builds(for: project).first)
            }
            return
        }
        layoutIdentity = identity
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }; heroes.removeAll()
        let meta = UIView(); meta.heightAnchor.constraint(equalToConstant: 35).isActive = true
        let wordmark = Studio.label("squircle", size: 17, weight: .semibold)
        let mark = AppGlyphView(); mark.filled = false
        let add = UIButton(type: .system)
        add.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .light)), for: .normal)
        add.tintColor = Studio.ink; add.accessibilityLabel = "Create app"; add.accessibilityIdentifier = "project.add"
        add.addAction(UIAction { [weak self] _ in self?.createProject() }, for: .touchUpInside)
        [wordmark, mark, add].forEach { meta.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([mark.leadingAnchor.constraint(equalTo: meta.leadingAnchor, constant: -7), mark.centerYAnchor.constraint(equalTo: meta.centerYAnchor), mark.widthAnchor.constraint(equalToConstant: 35), mark.heightAnchor.constraint(equalToConstant: 35), wordmark.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6), wordmark.centerYAnchor.constraint(equalTo: meta.centerYAnchor), add.trailingAnchor.constraint(equalTo: meta.trailingAnchor, constant: 6), add.centerYAnchor.constraint(equalTo: meta.centerYAnchor), add.widthAnchor.constraint(equalToConstant: 44), add.heightAnchor.constraint(equalToConstant: 44)])
        stack.addArrangedSubview(meta); stack.setCustomSpacing(18, after: meta)
        let title = Studio.label("Your apps", size: 40, weight: .semibold)
        title.accessibilityTraits = .header
        title.heightAnchor.constraint(equalToConstant: 53).isActive = true
        stack.addArrangedSubview(title); stack.setCustomSpacing(12, after: title)
        if model.projects.isEmpty {
            let empty = Studio.label(model.isLoading ? "Finding your apps…" : "Your next app starts here.", size: 20, color: Studio.muted)
            empty.numberOfLines = 0; empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            stack.addArrangedSubview(empty)
        }
        if let error = model.error {
            let message = Studio.label(error, size: 13, color: Studio.muted); message.numberOfLines = 0
            stack.addArrangedSubview(message)
        }
        galleryIndex = min(galleryIndex, max(0, model.projects.count - 1))
        let ordered = model.projects.isEmpty ? [] : [model.projects[galleryIndex]] + model.projects.enumerated().filter { $0.offset != galleryIndex }.map(\.element)
        for (index, project) in ordered.enumerated() {
            if index == 0 {
                let hero = ProjectHero(model: model, project: project, build: model.builds(for: project).first(where: { $0.canInstall }) ?? model.builds(for: project).first)
                hero.heightAnchor.constraint(equalToConstant: min(540, max(430, view.bounds.height * 0.59))).isActive = true
                hero.addAction(UIAction { [weak self, weak hero] _ in self?.open(project, source: hero) }, for: .touchUpInside)
                heroes[project.id] = hero; stack.addArrangedSubview(hero)
                hero.setPosition(galleryIndex + 1, count: model.projects.count)
                hero.onPage = { [weak self] direction in
                    guard let self, !self.model.projects.isEmpty else { return }
                    self.galleryIndex = (self.galleryIndex + direction + self.model.projects.count) % self.model.projects.count
                    self.galleryProjectID = self.model.projects[self.galleryIndex].id
                    UIView.transition(with: self.stack, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, options: .transitionCrossDissolve) { self.render() }
                }
            } else {
                let row = ProjectRow(project: project)
                row.heightAnchor.constraint(equalToConstant: 78).isActive = true
                row.addAction(UIAction { [weak self] _ in self?.open(project, source: nil) }, for: .touchUpInside)
                stack.addArrangedSubview(row)
            }
        }
    }

    private func createProject() {
        Studio.haptic()
        let alert = UIAlertController(title: "New app", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "App name"; $0.autocapitalizationType = .words; $0.accessibilityIdentifier = "project.name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            let project = self.model.createProject(name: name)
            self.render(); self.open(project, source: nil)
        })
        present(alert, animated: true)
    }

    private func open(_ project: AppProject, source: ProjectHero?) {
        guard presentedViewController == nil else { return }
        Studio.haptic(); model.selectProject(project); galleryProjectID = project.id
        let detail = ProjectViewController(model: model, project: project)
        let transition = WorkspaceTransition(source: source)
        workspaceTransition = transition
        detail.transitioningDelegate = transition; detail.modalPresentationStyle = .overFullScreen
        present(detail, animated: true)
    }
}

private final class ProjectRow: UIControl {
    private let icon: AppGlyphView
    private let title: UILabel
    private let subtitle: UILabel
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let separator = UIView()
    init(project: AppProject) {
        icon = AppGlyphView(probe: project.name.localizedCaseInsensitiveContains("probe"))
        title = Studio.label(project.name, size: 17, weight: .regular)
        subtitle = Studio.label(project.name.localizedCaseInsensitiveContains("probe") ? "Diagnostics" : project.subtitle, size: 12, color: Studio.muted)
        super.init(frame: .zero)
        backgroundColor = .clear
        [title,subtitle,chevron,separator].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        chevron.tintColor = Studio.muted; separator.backgroundColor = Studio.line
        isAccessibilityElement = true; accessibilityLabel = project.name; accessibilityTraits = .button
        accessibilityIdentifier = "project.row.\(project.name)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 17, y: 15, width: 48, height: 48)
        separator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        title.frame = CGRect(x: 0, y: 23, width: bounds.width-30, height: 23)
        subtitle.frame = CGRect(x: 0, y: 49, width: bounds.width-30, height: 19)
        chevron.frame = CGRect(x: bounds.width-30, y: 30, width: 10, height: 16)
    }
}

final class ProjectViewController: UIViewController {
    let model: SquircleModel
    private(set) var project: AppProject
    let preview: DevicePreview
    private let previewBinding: PreviewBinding
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let rows = UIStackView()
    private let section = UISegmentedControl(items: ["Threads", "Builds"])
    private let workSummary = Studio.label(size: 15, color: Studio.muted)
    private let captureCaption = Studio.label(size: 11, color: Studio.muted)
    private let buildCaption = Studio.label(size: 13, color: Studio.muted)
    private let buildTitle = Studio.label(size: 20, weight: .semibold)
    private let errorLabel = Studio.label(size: 13, color: Studio.muted)
    private let install = UIButton(type: .system)
    private let newThread = UIButton(type: .system)
    private let buildButton = GlassButton(symbol: "hammer", label: "Create build")
    private var tokens = Set<AnyCancellable>()
    private var latestBuild: AppBuild?
    private var rowsKey = ""
    private var isSubmitting = false

    init(model: SquircleModel, project: AppProject) {
        self.model = model; self.project = project
        preview = DevicePreview(name: project.name, probe: project.name.localizedCaseInsensitiveContains("probe"))
        preview.setPose(1)
        previewBinding = PreviewBinding(preview)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = Studio.canvas
        let back = GlassButton(symbol: "chevron.left", label: "Your apps")
        back.accessibilityIdentifier = "project.back"; buildButton.accessibilityIdentifier = "project.build"
        back.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        buildButton.addAction(UIAction { [weak self] _ in self?.createBuild() }, for: .touchUpInside)
        let top = UIView(); view.addSubview(top); top.translatesAutoresizingMaskIntoConstraints = false
        [back,buildButton].forEach { top.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        let word = Studio.label("\(project.name)", size: 14, weight: .medium); word.textAlignment = .center
        top.addSubview(word); word.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4), top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22), top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22), top.heightAnchor.constraint(equalToConstant: 49), back.leadingAnchor.constraint(equalTo: top.leadingAnchor), back.topAnchor.constraint(equalTo: top.topAnchor), back.widthAnchor.constraint(equalToConstant: 44), back.heightAnchor.constraint(equalToConstant: 44), buildButton.trailingAnchor.constraint(equalTo: top.trailingAnchor), buildButton.topAnchor.constraint(equalTo: top.topAnchor), buildButton.widthAnchor.constraint(equalToConstant: 44), buildButton.heightAnchor.constraint(equalToConstant: 44), word.centerXAnchor.constraint(equalTo: top.centerXAnchor), word.centerYAnchor.constraint(equalTo: back.centerYAnchor), word.widthAnchor.constraint(lessThanOrEqualTo: top.widthAnchor, constant: -115)])
        view.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false; scroll.alwaysBounceVertical = true
        content.axis = .vertical; content.spacing = 20; content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -120)])
        let title = Studio.label(project.name, size: 34, weight: .bold); title.accessibilityTraits = .header
        content.addArrangedSubview(title)
        workSummary.numberOfLines = 3; workSummary.isHidden = true
        content.addArrangedSubview(workSummary)
        errorLabel.numberOfLines = 0; errorLabel.isHidden = true; content.addArrangedSubview(errorLabel)
        let stage = UIView(); stage.backgroundColor = .clear
        stage.heightAnchor.constraint(equalToConstant: min(275, view.bounds.height*0.29)).isActive = true
        stage.addSubview(preview); preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([preview.topAnchor.constraint(equalTo: stage.topAnchor, constant: 9), preview.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -10), preview.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 30), preview.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -30)])
        content.addArrangedSubview(stage)
        captureCaption.textAlignment = .center; captureCaption.numberOfLines = 2; captureCaption.isHidden = true
        content.addArrangedSubview(captureCaption)
        let buildBar = UIView(); buildBar.heightAnchor.constraint(equalToConstant: 53).isActive = true
        [buildTitle,buildCaption,install].forEach { buildBar.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        var installStyle = UIButton.Configuration.filled(); installStyle.title = "Install"; installStyle.baseBackgroundColor = Studio.ink; installStyle.baseForegroundColor = .white; installStyle.cornerStyle = .capsule; installStyle.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 22, bottom: 13, trailing: 22)
        install.configuration = installStyle; install.accessibilityIdentifier = "build.install"
        install.addAction(UIAction { [weak self] _ in guard let self, let build = self.latestBuild else { return }; self.installBuild(build) }, for: .touchUpInside)
        NSLayoutConstraint.activate([buildTitle.leadingAnchor.constraint(equalTo: buildBar.leadingAnchor), buildTitle.topAnchor.constraint(equalTo: buildBar.topAnchor), buildTitle.trailingAnchor.constraint(lessThanOrEqualTo: install.leadingAnchor, constant: -15), buildCaption.leadingAnchor.constraint(equalTo: buildBar.leadingAnchor), buildCaption.topAnchor.constraint(equalTo: buildTitle.bottomAnchor, constant: 3), install.trailingAnchor.constraint(equalTo: buildBar.trailingAnchor), install.centerYAnchor.constraint(equalTo: buildBar.centerYAnchor)])
        content.addArrangedSubview(buildBar)
        section.selectedSegmentIndex = 0; section.accessibilityIdentifier = "project.sections"
        section.setTitleTextAttributes([.font: Studio.font(14, .medium), .foregroundColor: Studio.muted], for: .normal)
        section.setTitleTextAttributes([.foregroundColor: Studio.ink], for: .selected)
        section.selectedSegmentTintColor = Studio.canvas; section.backgroundColor = .clear
        section.setBackgroundImage(UIImage(), for: .normal, barMetrics: .default)
        section.setBackgroundImage(UIImage(), for: .selected, barMetrics: .default)
        section.setDividerImage(UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        section.addAction(UIAction { [weak self] _ in self?.rowsKey = ""; self?.render() }, for: .valueChanged)
        section.heightAnchor.constraint(equalToConstant: 38).isActive = true
        content.addArrangedSubview(section)
        rows.axis = .vertical; rows.spacing = 0; content.addArrangedSubview(rows)
        configureComposer()
        let refresh = UIRefreshControl(); refresh.addAction(UIAction { [weak self, weak refresh] _ in Task { await self?.model.refresh(); refresh?.endRefreshing() } }, for: .valueChanged); scroll.refreshControl = refresh
        model.objectWillChange.receive(on: DispatchQueue.main).debounce(for: .milliseconds(100), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &tokens)
        render()
    }

    private func configureComposer() {
        let glass = UIVisualEffectView(effect: Studio.glass()); glass.layer.cornerRadius = 29; glass.clipsToBounds = true
        view.addSubview(glass); glass.translatesAutoresizingMaskIntoConstraints = false
        newThread.setTitle("New thread", for: .normal); newThread.setTitleColor(Studio.ink, for: .normal)
        newThread.titleLabel?.font = Studio.font(16, .medium)
        newThread.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)), for: .normal)
        newThread.tintColor = Studio.accent
        var config = UIButton.Configuration.plain(); config.imagePadding = 10; newThread.configuration = config
        newThread.accessibilityIdentifier = "thread.new"
        newThread.addAction(UIAction { [weak self] _ in self?.openThread(nil) }, for: .touchUpInside)
        glass.contentView.addSubview(newThread); newThread.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([glass.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12), glass.centerXAnchor.constraint(equalTo: view.centerXAnchor), glass.heightAnchor.constraint(equalToConstant: 56), glass.widthAnchor.constraint(equalToConstant: 184), newThread.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor), newThread.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor), newThread.topAnchor.constraint(equalTo: glass.contentView.topAnchor), newThread.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor)])
    }

    private func render() {
        if let current = model.projects.first(where: { $0.id == project.id }) { project = current }
        previewBinding.update(model: model, project: project)
        let metadata = model.metadata(for: project)
        workSummary.text = metadata?.summary
        workSummary.isHidden = metadata?.summary.isEmpty != false
        if let capture = metadata?.preview {
            let date = Date(timeIntervalSince1970: capture.capturedAt)
            let label = capture.caption.isEmpty ? "Simulator capture" : capture.caption
            captureCaption.text = "\(label) · \(date.formatted(date: .omitted, time: .shortened))"
            captureCaption.isHidden = false
        } else { captureCaption.isHidden = true }
        let builds = model.builds(for: project)
        latestBuild = builds.first(where: { $0.canInstall })
        let current = builds.first
        errorLabel.text = model.error; errorLabel.isHidden = model.error == nil
        buildTitle.text = latestBuild.map { $0.version.isEmpty ? "Ready to try" : $0.version } ?? (current == nil ? "Your first build" : current!.status.capitalized)
        buildCaption.text = latestBuild == nil ? "Build it on your Mac" : "Ready for your iPhone"
        if let current, ["queued", "running"].contains(current.status) { buildCaption.text = "Building on your Mac…" }
        install.isHidden = latestBuild == nil
        buildButton.isEnabled = !isSubmitting && !model.buildingProjectIDs.contains(project.id)
        let sessions = model.sessions(for: project)
        let key = "\(section.selectedSegmentIndex)|" + sessions.map { "\($0.id):\($0.title):\($0.messageCount)" }.joined(separator: "|") + builds.map { "\($0.id):\($0.status)" }.joined(separator: "|")
        guard key != rowsKey else { return }; rowsKey = key
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if section.selectedSegmentIndex == 0 {
            if sessions.isEmpty {
                addEmpty("What are we making?", subtitle: "Start a thread for your next idea.")
            } else {
                for session in sessions {
                    let prefix = project.name + " · "
                    let title = session.title.hasPrefix(prefix) ? String(session.title.dropFirst(prefix.count)) : session.title
                    let row = StudioListRow(title: title, subtitle: session.preview.isEmpty ? "Continue with Hermes" : session.preview, symbol: "bubble.left", trailing: "chevron.right")
                    row.accessibilityIdentifier = "thread.row"
                    row.accessibilityValue = session.id
                    row.addAction(UIAction { [weak self] _ in self?.openThread(session.id) }, for: .touchUpInside)
                    rows.addArrangedSubview(row)
                }
            }
        } else {
            if builds.isEmpty { addEmpty("Nothing to install. Yet.", subtitle: "Ask Hermes to make your first build.") }
            for build in builds {
                let row = StudioListRow(title: build.version.isEmpty ? build.title : build.version, subtitle: "\(build.status.capitalized) · \(build.date.formatted(date: .abbreviated, time: .shortened))", symbol: build.canInstall ? "app.badge.checkmark" : "hammer", trailing: build.canInstall ? "arrow.down" : "chevron.right")
                row.accessibilityIdentifier = "build.row"
                row.accessibilityValue = build.id
                row.addAction(UIAction { [weak self] _ in
                    if build.canInstall { self?.installBuild(build) }
                    else { self?.showBuildStatus(build) }
                }, for: .touchUpInside)
                rows.addArrangedSubview(row)
            }
        }
    }
    private func addEmpty(_ title: String, subtitle: String) {
        let box = UIStackView(); box.axis = .vertical; box.spacing = 7
        box.isLayoutMarginsRelativeArrangement = true; box.layoutMargins = UIEdgeInsets(top: 17, left: 1, bottom: 18, right: 1)
        box.addArrangedSubview(Studio.label(title, size: 17, weight: .medium))
        let sub = Studio.label(subtitle, size: 13, color: Studio.muted); sub.numberOfLines = 0; box.addArrangedSubview(sub)
        rows.addArrangedSubview(box)
    }
    private func openThread(_ id: String?) {
        guard presentedViewController == nil else { return }
        Studio.haptic()
        let controller = ThreadViewController(model: model, project: project, sessionID: id)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]; sheet.preferredCornerRadius = 34
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(controller, animated: true)
    }
    private func installBuild(_ build: AppBuild) {
        guard !isSubmitting else { return }; isSubmitting = true; install.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            if let url = await self.model.installURL(for: build) { await UIApplication.shared.open(url) }
            else { self.showError() }
            self.isSubmitting = false; self.install.isEnabled = true
        }
    }
    private func createBuild() {
        guard !isSubmitting else { return }
        if !project.canBuild {
            let alert = UIAlertController(title: "Make the first build", message: "Start a thread and ask Hermes to set up this app on your Mac.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Start thread", style: .default) { [weak self] _ in self?.openThread(nil) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true); return
        }
        Studio.haptic(); isSubmitting = true; buildButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            if await self.model.startBuild(for: self.project) == nil { self.showError() }
            self.isSubmitting = false; self.section.selectedSegmentIndex = 1; self.rowsKey = ""; self.render()
        }
    }
    private func showError() {
        let alert = UIAlertController(title: "Couldn’t finish", message: model.error ?? "Please try again.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func showBuildStatus(_ build: AppBuild) {
        let alert = UIAlertController(title: build.status.capitalized, message: "\(build.title)\n\(build.date.formatted())", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}

private final class StudioListRow: UIControl {
    private let title: UILabel
    private let subtitle: UILabel
    private let symbol: UIImageView
    private let trailing: UIImageView
    private let line = UIView()
    init(title: String, subtitle: String, symbol: String, trailing: String) {
        self.title = Studio.label(title, size: 16, weight: .medium)
        self.subtitle = Studio.label(subtitle.replacingOccurrences(of: "\n", with: " "), size: 12, color: Studio.muted)
        self.symbol = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .light)))
        self.trailing = UIImageView(image: UIImage(systemName: trailing, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)))
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 75).isActive = true
        [self.title,self.subtitle,self.symbol,self.trailing,line].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        self.symbol.tintColor = Studio.accent; self.trailing.tintColor = Studio.muted; line.backgroundColor = Studio.line
        isAccessibilityElement = true; accessibilityLabel = "\(title), \(subtitle)"; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        symbol.frame = CGRect(x: 0, y: 24, width: 23, height: 23); symbol.contentMode = .scaleAspectFit
        title.frame = CGRect(x: 39, y: 16, width: bounds.width-66, height: 23)
        subtitle.frame = CGRect(x: 39, y: 42, width: bounds.width-66, height: 18)
        trailing.frame = CGRect(x: bounds.width-13, y: 29, width: 10, height: 15)
        line.frame = CGRect(x: 39, y: bounds.height-0.5, width: bounds.width-39, height: 0.5)
    }
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? UIColor.black.withAlphaComponent(0.03) : .clear } }
}
