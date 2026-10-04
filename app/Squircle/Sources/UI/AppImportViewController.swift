import UIKit

/// A native browser of the connected Mac. Paths and schemes come from the host;
/// importing persists a build recipe there before the app joins the gallery.
final class AppImportNavigationController: UINavigationController {
    let model: SquircleModel
    var onImport: ((AppProject) -> Void)?

    init(model: SquircleModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        setViewControllers([MacProjectBrowserController(model: model, path: nil)], animated: false)
        modalPresentationStyle = .pageSheet
        navigationBar.prefersLargeTitles = true
        navigationBar.tintColor = .label
        toolbar.tintColor = .label
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(path: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "xcodeproj" || ext == "xcworkspace" {
            pushViewController(MacAppImportController(model: model, project: path), animated: true)
        } else {
            pushViewController(MacProjectBrowserController(model: model, path: path), animated: true)
        }
    }

    func enterPath(current: String?) {
        let alert = UIAlertController(title: "Go to Folder or Project", message: "A path on your Mac", preferredStyle: .alert)
        alert.addTextField {
            $0.text = current
            $0.placeholder = "~/Developer/MyApp"
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.clearButtonMode = .whileEditing
            $0.keyboardType = .URL
            $0.accessibilityIdentifier = "import.path.input"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let go = UIAlertAction(title: "Go", style: .default) { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text else { return }
            // Wait until UIKit has removed the alert before pushing a page.
            alert?.dismiss(animated: true) { self?.open(path: value) }
        }
        go.accessibilityIdentifier = "import.path.go"
        alert.addAction(go)
        alert.preferredAction = go
        present(alert, animated: true)
    }
}

private class MacImportPage: UITableViewController {
    let model: SquircleModel
    var task: Task<Void, Never>?
    let spinner = UIActivityIndicatorView(style: .large)
    let message = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    let retry = Theme.glassButton(symbol: "arrow.clockwise", title: "Retry", identifier: "import.retry")
    var currentPath: String?
    private let pathButton = UIButton(type: .system)
    private var pathWidth: NSLayoutConstraint?

    init(model: SquircleModel, style: UITableView.Style) {
        self.model = model
        super.init(style: style)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { task?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.keyboardDismissMode = .onDrag
        let backdrop = UIView()
        let stack = UIStackView(arrangedSubviews: [spinner, message, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        message.textAlignment = .center
        message.accessibilityIdentifier = "import.error"
        retry.addAction(UIAction { [weak self] _ in self?.reload() }, for: .touchUpInside)
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor, constant: -30),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: backdrop.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -32)
        ])
        tableView.backgroundView = backdrop

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "folder")
        config.imagePadding = 6
        config.baseForegroundColor = .label
        config.titleLineBreakMode = .byTruncatingMiddle
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.subheadline, 15, .medium)
            return attributes
        }
        pathButton.configuration = config
        pathButton.translatesAutoresizingMaskIntoConstraints = false
        pathWidth = pathButton.widthAnchor.constraint(equalToConstant: 280)
        pathWidth?.isActive = true
        pathButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        pathButton.accessibilityIdentifier = "import.path"
        pathButton.accessibilityLabel = "Go to folder or project on Mac"
        pathButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            (navigationController as? AppImportNavigationController)?.enterPath(current: currentPath)
        }, for: .touchUpInside)
        toolbarItems = [.flexibleSpace(), UIBarButtonItem(customView: pathButton), .flexibleSpace()]
        setState(loading: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        updatePath()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { task?.cancel() }
    }

    func reload() {}

    func updatePath() {
        let path = (currentPath ?? "Mac").replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
        pathButton.configuration?.title = path
        pathButton.accessibilityValue = currentPath
        pathWidth?.constant = max(140, min(320, view.bounds.width - 80))
    }

    func setPathEnabled(_ enabled: Bool) { pathButton.isEnabled = enabled }

    func setState(loading: Bool, error: String? = nil, empty: String? = nil) {
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        message.text = error ?? empty
        message.isHidden = message.text == nil
        retry.isHidden = error == nil
    }
}

private final class MacProjectBrowserController: MacImportPage {
    private var directory: MacProjectDirectory?
    private let initialPath: String?

    init(model: SquircleModel, path: String?) {
        initialPath = path
        super.init(model: model, style: .insetGrouped)
        currentPath = path
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = initialPath.map { ($0 as NSString).lastPathComponent } ?? "Add App"
        navigationItem.largeTitleDisplayMode = initialPath == nil ? .always : .never
        if initialPath == nil {
            let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.navigationController?.dismiss(animated: true)
            })
            close.accessibilityIdentifier = "import.cancel"
            close.accessibilityLabel = "Close"
            navigationItem.leftBarButtonItem = close
        }
        tableView.accessibilityIdentifier = "import.browser"
        reload()
    }

    override func reload() {
        task?.cancel()
        setState(loading: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await model.browseMacProjects(path: currentPath)
                try Task.checkCancellation()
                directory = result
                currentPath = result.path
                updatePath()
                if result.parentPath != nil {
                    let up = UIBarButtonItem(image: UIImage(systemName: "arrow.up"), primaryAction: UIAction { [weak self] _ in
                        self?.parentFolder()
                    })
                    up.accessibilityLabel = "Parent folder"
                    navigationItem.rightBarButtonItem = up
                }
                setState(loading: false, empty: result.entries.isEmpty ? "No projects or folders here" : nil)
                tableView.reloadData()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                setState(loading: false, error: error.localizedDescription)
            }
        }
    }

    private func parentFolder() {
        guard let parent = directory?.parentPath else { return }
        (navigationController as? AppImportNavigationController)?.open(path: parent)
    }

    private var projects: [MacProjectDirectory.Entry] { directory?.entries.filter { $0.kind != .directory } ?? [] }
    private var folders: [MacProjectDirectory.Entry] { directory?.entries.filter { $0.kind == .directory } ?? [] }
    private func entries(in section: Int) -> [MacProjectDirectory.Entry] {
        projects.isEmpty ? folders : (section == 0 ? projects : folders)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        guard directory != nil else { return 0 }
        return projects.isEmpty || folders.isEmpty ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard directory != nil, !(directory?.entries.isEmpty ?? true) else { return nil }
        if projects.isEmpty { return "Folders" }
        return section == 0 ? "Xcode Projects" : "Folders"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries(in: section).count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let entry = entries(in: indexPath.section)[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.name
        content.textProperties.font = Theme.font(.body, 17, entry.kind == .directory ? .regular : .semibold)
        switch entry.kind {
        case .directory:
            content.image = UIImage(systemName: "folder.fill")
            content.imageProperties.tintColor = .secondaryLabel
        case .project:
            content.image = UIImage(systemName: "hammer.fill")
            content.imageProperties.tintColor = Theme.accent
            content.secondaryText = "Xcode project"
        case .workspace:
            content.image = UIImage(systemName: "square.stack.3d.up.fill")
            content.imageProperties.tintColor = Theme.accent
            content.secondaryText = "Xcode workspace"
        }
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "import.entry"
        cell.accessibilityValue = entry.path
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries(in: indexPath.section)[indexPath.row]
        (navigationController as? AppImportNavigationController)?.open(path: entry.path)
    }
}

private final class MacAppImportController: MacImportPage, UITextFieldDelegate {
    private let projectPath: String
    private var inspection: MacProjectInspection?
    private var selectedScheme: String?
    private let nameField = UITextField()
    private let schemeButton = UIButton(type: .system)
    private var submitting = false
    private lazy var add: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Add", style: .done, target: self, action: #selector(importApp))
        if #available(iOS 26.0, *) { item.style = .prominent }
        item.tintColor = Theme.accent
        return item
    }()

    init(model: SquircleModel, project: String) {
        projectPath = project
        super.init(model: model, style: .insetGrouped)
        currentPath = project
    }
    required init?(coder: NSCoder) { fatalError() }

    private enum Row { case name, scheme, bundle(String), team(String) }
    private var rows: [[Row]] {
        guard let inspection else { return [] }
        var facts: [Row] = []
        if let bundle = inspection.bundleID, !bundle.isEmpty { facts.append(.bundle(bundle)) }
        if let team = inspection.teamID, !team.isEmpty { facts.append(.team(team)) }
        return facts.isEmpty ? [[.name, .scheme]] : [[.name, .scheme], facts]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add App"
        navigationItem.largeTitleDisplayMode = .never
        add.accessibilityIdentifier = "import.add"
        navigationItem.rightBarButtonItem = add
        nameField.font = Theme.font(.body, 17)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.textAlignment = .right
        nameField.textColor = .label
        nameField.placeholder = "App name"
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .done
        nameField.clearButtonMode = .whileEditing
        nameField.delegate = self
        nameField.accessibilityIdentifier = "import.name"
        nameField.accessibilityLabel = "App name"
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        var schemeStyle = UIButton.Configuration.plain()
        schemeStyle.baseForegroundColor = .secondaryLabel
        schemeStyle.image = UIImage(systemName: "chevron.up.chevron.down")
        schemeStyle.imagePlacement = .trailing
        schemeStyle.imagePadding = 6
        schemeStyle.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        schemeStyle.contentInsets = .zero
        schemeButton.configuration = schemeStyle
        schemeButton.contentHorizontalAlignment = .trailing
        schemeButton.accessibilityIdentifier = "import.scheme"
        schemeButton.addAction(UIAction { [weak self] _ in self?.chooseScheme() }, for: .touchUpInside)
        reload()
    }

    override func reload() {
        task?.cancel()
        add.isEnabled = false
        setState(loading: true)
        let scheme = selectedScheme
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await model.inspectMacProject(project: projectPath, scheme: scheme)
                try Task.checkCancellation()
                inspection = result
                selectedScheme = result.scheme
                currentPath = result.project
                updatePath()
                if nameField.text?.isEmpty != false { nameField.text = result.name }
                schemeButton.configuration?.title = result.scheme ?? "Choose"
                schemeButton.accessibilityLabel = result.scheme ?? "Choose scheme"
                setState(loading: false)
                tableView.reloadData()
                nameChanged()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                inspection = nil
                tableView.reloadData()
                setState(loading: false, error: error.localizedDescription)
            }
        }
    }

    @objc private func nameChanged() {
        add.isEnabled = !submitting && inspection?.canImport == true && selectedScheme != nil
            && !(nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }

    private func chooseScheme() {
        guard !submitting, let inspection else { return }
        let choices = MacSchemeController(schemes: inspection.schemes, selected: selectedScheme) { [weak self] scheme in
            guard let self else { return }
            selectedScheme = scheme
            navigationController?.popViewController(animated: true)
            reload()
        }
        navigationController?.pushViewController(choices, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows[section].count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.section][indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.valueCell()
        switch row {
        case .name, .scheme:
            content.text = { if case .name = row { return "Name" }; return "Scheme" }()
            cell.contentConfiguration = content
            let control: UIView = { if case .name = row { return nameField }; return schemeButton }()
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(control)
            NSLayoutConstraint.activate([
                control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 6),
                control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -6),
                control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                control.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 24 + UIFontMetrics(forTextStyle: .body).scaledValue(for: 88)),
                control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
        case .bundle(let value), .team(let value):
            content.text = { if case .bundle = row { return "Bundle ID" }; return "Team" }()
            content.secondaryText = value
            content.secondaryTextProperties.font = Theme.font(.body, 15, monospaced: true)
            cell.contentConfiguration = content
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? inspection.map { ($0.project as NSString).lastPathComponent } : "From Xcode"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == rows.count - 1 ? inspection?.issue : nil
    }

    @objc private func importApp() {
        guard !submitting, let inspection, inspection.canImport, let scheme = selectedScheme,
              let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        view.endEditing(true)
        submitting = true
        nameChanged()
        navigationController?.isModalInPresentation = true
        navigationItem.hidesBackButton = true
        nameField.isEnabled = false
        schemeButton.isEnabled = false
        setPathEnabled(false)
        let progress = UIActivityIndicatorView(style: .medium)
        progress.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progress)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let app = try await model.importMacProject(project: inspection.project, scheme: scheme, name: name,
                                                           configuration: inspection.configuration)
                try Task.checkCancellation()
                (navigationController as? AppImportNavigationController)?.onImport?(app)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                let alert = UIAlertController(title: "Couldn’t Add App", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            submitting = false
            navigationController?.isModalInPresentation = false
            navigationItem.hidesBackButton = false
            navigationItem.rightBarButtonItem = add
            nameField.isEnabled = true
            schemeButton.isEnabled = true
            setPathEnabled(true)
            nameChanged()
        }
    }
}

private final class MacSchemeController: UITableViewController {
    private let schemes: [String]
    private let selected: String?
    private let onSelect: (String) -> Void
    init(schemes: [String], selected: String?, onSelect: @escaping (String) -> Void) {
        self.schemes = schemes
        self.selected = selected
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scheme"
        navigationItem.largeTitleDisplayMode = .never
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { schemes.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = schemes[indexPath.row]
        content.textProperties.font = Theme.font(.body, 17)
        cell.contentConfiguration = content
        cell.tintColor = Theme.accent
        let isSelected = schemes[indexPath.row] == selected
        cell.accessoryType = isSelected ? .checkmark : .none
        cell.accessibilityTraits = isSelected ? [.button, .selected] : .button
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { onSelect(schemes[indexPath.row]) }
}
