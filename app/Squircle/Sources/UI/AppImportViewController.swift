import UIKit

/// A native browser of the connected Mac. Paths and schemes come from the host;
/// importing persists a build recipe there before the app enters the picker.
final class AppImportNavigationController: UINavigationController {
    let model: SquircleModel
    var onImport: ((AppProject) -> Void)?

    init(model: SquircleModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        let browser = MacProjectBrowserController(model: model, path: nil)
        setViewControllers([browser], animated: false)
        modalPresentationStyle = .pageSheet
        navigationBar.tintColor = Studio.ink
        toolbar.tintColor = Studio.ink
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = Studio.canvas
        appearance.titleTextAttributes = [.foregroundColor: Studio.ink]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithTransparentBackground()
        toolbarAppearance.backgroundColor = Studio.canvas
        toolbar.standardAppearance = toolbarAppearance
        toolbar.scrollEdgeAppearance = toolbarAppearance
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 32
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
        let alert = UIAlertController(title: "Go to folder or project", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.text = current
            $0.placeholder = "~/Developer/MyApp"
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.clearButtonMode = .whileEditing
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
        present(alert, animated: true)
    }
}

private class MacImportPage: UITableViewController {
    let model: SquircleModel
    var task: Task<Void, Never>?
    let spinner = UIActivityIndicatorView(style: .medium)
    let message = Studio.label(size: 16, color: Studio.muted)
    let retry = UIButton(type: .system)
    var currentPath: String?
    private let pathButton = UIButton(type: .system)
    private var pathWidth: NSLayoutConstraint?

    init(model: SquircleModel) {
        self.model = model
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { task?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Studio.canvas
        tableView.backgroundColor = Studio.canvas
        tableView.separatorColor = Studio.line
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 58, bottom: 0, right: 24)
        tableView.rowHeight = 64
        tableView.keyboardDismissMode = .onDrag
        tableView.tableFooterView = UIView()
        let backdrop = UIView()
        let stack = UIStackView(arrangedSubviews: [spinner, message, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        message.numberOfLines = 0
        message.textAlignment = .center
        message.accessibilityIdentifier = "import.error"
        retry.setTitle("Retry", for: .normal)
        retry.tintColor = Studio.ink
        retry.addAction(UIAction { [weak self] _ in self?.reload() }, for: .touchUpInside)
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor, constant: -30),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: backdrop.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -28)
        ])
        tableView.backgroundView = backdrop
        pathButton.setImage(UIImage(systemName: "folder"), for: .normal)
        pathButton.tintColor = Studio.muted
        pathButton.titleLabel?.font = Studio.font(13)
        pathButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        pathButton.translatesAutoresizingMaskIntoConstraints = false
        pathWidth = pathButton.widthAnchor.constraint(equalToConstant: 280)
        pathWidth?.isActive = true
        pathButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        pathButton.accessibilityIdentifier = "import.path"
        pathButton.accessibilityLabel = "Go to folder or project on Mac"
        pathButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            (self.navigationController as? AppImportNavigationController)?.enterPath(current: self.currentPath)
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
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            task?.cancel()
        }
    }

    func reload() {}

    func updatePath() {
        let path = currentPath ?? "Mac"
        pathButton.setTitle("  " + path, for: .normal)
        pathWidth?.constant = max(120, min(330, view.bounds.width - 72))
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
        super.init(model: model)
        currentPath = path
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = initialPath.map { ($0 as NSString).lastPathComponent } ?? "Add app"
        if initialPath == nil {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(close))
            close.accessibilityIdentifier = "import.cancel"
            close.accessibilityLabel = "Close"
            navigationItem.leftBarButtonItem = close
        }
        tableView.accessibilityIdentifier = "import.browser"
        reload()
    }

    @objc private func close() { navigationController?.dismiss(animated: true) }

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
                    navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.up"), style: .plain, target: self, action: #selector(parentFolder))
                    navigationItem.rightBarButtonItem?.accessibilityLabel = "Parent folder"
                }
                setState(loading: false, empty: result.entries.isEmpty ? "No projects or folders" : nil)
                tableView.reloadData()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                setState(loading: false, error: error.localizedDescription)
            }
        }
    }

    @objc private func parentFolder() {
        guard let parent = directory?.parentPath else { return }
        (navigationController as? AppImportNavigationController)?.open(path: parent)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { directory?.entries.count ?? 0 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        guard let entry = directory?.entries[indexPath.row] else { return cell }
        cell.backgroundColor = .clear
        var content = cell.defaultContentConfiguration()
        content.text = entry.name
        content.textProperties.font = Studio.font(17)
        content.textProperties.color = Studio.ink
        content.image = UIImage(systemName: entry.kind == .directory ? "folder" : "app.dashed")
        content.imageProperties.tintColor = Studio.muted
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "import.entry"
        cell.accessibilityValue = entry.path
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = directory?.entries[indexPath.row] else { return }
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
    private lazy var add = UIBarButtonItem(title: "Add", style: .done, target: self, action: #selector(importApp))

    init(model: SquircleModel, project: String) {
        projectPath = project
        super.init(model: model)
        currentPath = project
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add app"
        add.accessibilityIdentifier = "import.add"
        navigationItem.rightBarButtonItem = add
        nameField.font = Studio.font(19, .medium)
        nameField.textColor = Studio.ink
        nameField.placeholder = "App name"
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.accessibilityIdentifier = "import.name"
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        schemeButton.tintColor = Studio.ink
        schemeButton.titleLabel?.font = Studio.font(17)
        schemeButton.contentHorizontalAlignment = .trailing
        schemeButton.accessibilityIdentifier = "import.scheme"
        schemeButton.addAction(UIAction { [weak self] _ in self?.chooseScheme() }, for: .touchUpInside)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        tableView.rowHeight = 72
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
                schemeButton.setTitle(result.scheme ?? "Choose", for: .normal)
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

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { inspection == nil ? 0 : 2 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        let control: UIView = indexPath.row == 0 ? nameField : schemeButton
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -24)
        ])
        if indexPath.row == 0 {
            control.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 24).isActive = true
        } else {
            let label = Studio.label("Scheme", size: 17, color: Studio.muted)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 24),
                label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 24),
                label.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
            ])
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        inspection.map { ($0.project as NSString).lastPathComponent }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { inspection?.issue }

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
                let app = try await model.importMacProject(project: inspection.project, scheme: scheme, name: name, configuration: inspection.configuration)
                try Task.checkCancellation()
                (navigationController as? AppImportNavigationController)?.onImport?(app)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                let alert = UIAlertController(title: "Couldn’t add app", message: error.localizedDescription, preferredStyle: .alert)
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
        self.schemes = schemes; self.selected = selected; self.onSelect = onSelect
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scheme"
        tableView.backgroundColor = Studio.canvas
        tableView.separatorColor = Studio.line
        tableView.rowHeight = 60
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { schemes.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        cell.textLabel?.text = schemes[indexPath.row]
        cell.textLabel?.font = Studio.font(17)
        cell.textLabel?.textColor = Studio.ink
        cell.tintColor = Studio.ink
        cell.accessoryType = schemes[indexPath.row] == selected ? .checkmark : .none
        cell.accessibilityTraits = schemes[indexPath.row] == selected ? [.button, .selected] : .button
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { onSelect(schemes[indexPath.row]) }
}
