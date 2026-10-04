import UIKit
import QuickLook

@MainActor
final class ToolDetailViewController: UIViewController {
    let message: ChatMessage
    init(_ message: ChatMessage) { self.message = message; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    static func navigation(_ message: ChatMessage) -> UINavigationController { UINavigationController(rootViewController: Self(message)) }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = message.activity ?? "Details"
        view.backgroundColor = Theme.paper
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let text = UITextView(); text.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false; text.isSelectable = true; text.backgroundColor = .clear
        text.font = Theme.font(.body, 14, monospaced: true); text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        text.text = message.detail; text.accessibilityIdentifier = "thread.toolDetails"
        text.accessibilityLabel = "Command, changes and output"
        view.addSubview(text)
        NSLayoutConstraint.activate([text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), text.bottomAnchor.constraint(equalTo: view.bottomAnchor), text.leadingAnchor.constraint(equalTo: view.leadingAnchor), text.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
    }
}

@MainActor
final class CodingActivityViewController: UITableViewController, QLPreviewControllerDataSource {
    private var previewFile: URL?
    let model: SquircleModel
    let references: [String]
    let sessionID: String
    var selected = 0
    var bytes = Data()
    var trace = CodingTrace()
    var loading: Task<Void, Never>?
    private var loadGeneration = UUID()
    var polling: Task<Void, Never>?
    private let summary = UILabel()

    init(model: SquircleModel, references: [String]) {
        self.model = model; self.references = references; sessionID = model.selectedSessionID ?? ""
        super.init(style: .plain)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Coding activity"
        view.backgroundColor = Theme.paper; tableView.backgroundColor = Theme.paper
        tableView.separatorStyle = .none
        tableView.register(ThreadMessageCell.self, forCellReuseIdentifier: ThreadMessageCell.reuseID)
        tableView.accessibilityIdentifier = "coding.activity"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        if references.count > 1 {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Run", menu: UIMenu(children: references.enumerated().map { index, path in
                UIAction(title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) { [weak self] _ in
                    guard let self else { return }; loading?.cancel(); loading = nil; selected = index; bytes = Data(); trace = CodingTrace(); refresh()
                }
            }))
        }
        summary.numberOfLines = 0; summary.font = Theme.font(.footnote, 13); summary.textColor = .secondaryLabel
        summary.text = "Loading coding activity…"
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); polling?.cancel(); polling = nil; loading?.cancel(); loading = nil }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layoutSummary() }
    private func layoutSummary() {
        let size = summary.sizeThatFits(CGSize(width: tableView.bounds.width - 40, height: .greatestFiniteMagnitude))
        let header = tableView.tableHeaderView ?? UIView()
        let height = size.height + 32
        guard header.frame.height != height || header.frame.width != tableView.bounds.width else { return }
        header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height)
        summary.frame = CGRect(x: 20, y: 12, width: tableView.bounds.width - 40, height: size.height)
        header.addSubview(summary); tableView.tableHeaderView = header
    }
    private func refresh() {
        guard loading == nil, references.indices.contains(selected) else { return }
        let path = references[selected]
        let generation = UUID(); loadGeneration = generation
        loading = Task { [weak self] in
            guard let self else { return }
            defer { if self.loadGeneration == generation { self.loading = nil; self.refreshControl?.endRefreshing() } }
            do {
                var incoming = self.bytes
                while true {
                    try Task.checkCancellation()
                    let (chunk, done) = try await model.codingTraceChunk(path, sessionID: sessionID, offset: incoming.count)
                    incoming.append(chunk)
                    guard incoming.count <= 32 * 1024 * 1024 else { throw ClientError.response("Trace exceeds 32 MB") }
                    if done || chunk.isEmpty { break }
                }
                guard incoming != self.bytes else { return }
                let data = incoming
                let parsed = await Task.detached(priority: .userInitiated) { CodingTrace.parse(data) }.value
                try Task.checkCancellation()
                let nearBottom = !self.bytes.isEmpty && tableView.contentOffset.y + tableView.bounds.height >= tableView.contentSize.height - 100
                self.bytes = data; self.trace = parsed
                summary.text = "\(parsed.model.lowercased().contains("claude") ? "Claude Code" : parsed.model) · \(parsed.state)"
                if parsed.authentication.contains("API billing") { summary.text! += "\nThis recorded run used an API key" }
                tableView.reloadData(); layoutSummary()
                if nearBottom && !parsed.messages.isEmpty { tableView.scrollToRow(at: IndexPath(row: parsed.messages.count - 1, section: 0), at: .bottom, animated: false) }
            } catch is CancellationError {} catch {
                guard self.loadGeneration == generation else { return }
                summary.text = "Could not load coding activity. Pull to retry.\n" + error.localizedDescription
                layoutSummary()
            }
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { trace.messages.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ThreadMessageCell.reuseID, for: indexPath) as! ThreadMessageCell
        cell.configure(trace.messages[indexPath.row])
        cell.openDetail = { [weak self] message in self?.present(ToolDetailViewController.navigation(message), animated: true) }
        cell.openAttachment = { [weak self] attachment in
            guard let self else { return }
            Task {
                do {
                    self.previewFile = try await self.model.hermesAttachment(attachment.reference, sessionID: self.sessionID)
                    let preview = QLPreviewController(); preview.dataSource = self; self.present(preview, animated: true)
                } catch {
                    let alert = UIAlertController(title: "Image unavailable", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default)); self.present(alert, animated: true)
                }
            }
        }
        return cell
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewFile == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewFile! as NSURL }
}

@MainActor
final class AppCaptureViewController: UIViewController {
    let data: Data
    let capturedAt: TimeInterval?
    init(data: Data, name: String, capturedAt: TimeInterval?) { self.data = data; self.capturedAt = capturedAt; super.init(nibName: nil, bundle: nil); title = name }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = Theme.paper
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let image = UIImageView(image: UIImage(data: data)); image.contentMode = .scaleAspectFit
        image.accessibilityLabel = "Actual simulator capture"; image.isAccessibilityElement = true
        let label = Theme.label(capturedAt.map { "Captured " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Published simulator capture", Theme.font(.footnote, 13), color: .secondaryLabel)
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [image, label]); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)])
    }
}
