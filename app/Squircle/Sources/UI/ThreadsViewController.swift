import UIKit

/// The app's other threads, newest first, and a way to start a new one: the
/// Tasks sheet's Threads tab (`embedded`, no header of its own) or a sheet of
/// its own in the debug overlay. Picking one closes the sheet and pushes it in.
@MainActor
final class ThreadsViewController: UIViewController {
    /// A thread to open; nil starts a new one.
    var onOpen: ((String?) -> Void)?
    private let model: SquircleModel
    private var project: AppProject
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private let notice = Theme.label("", Theme.font(.body, 17), color: .secondaryLabel, lines: 0)
    private let titleLabel = Theme.label("Threads", Theme.font(.headline, 17, .semibold))
    private let close = Theme.glassButton(symbol: "xmark", identifier: "threads.close", accessibilityLabel: "Close threads")
    private let create = Theme.glassButton(symbol: "square.and.pencil", identifier: "threads.new", accessibilityLabel: "New Thread")
    private var rowViews: [String: ThreadRow] = [:]
    private var renderedOrder: [String] = []
    private var observation: Task<Void, Never>?

    private let embedded: Bool

    init(model: SquircleModel, project: AppProject, embedded: Bool = false) {
        self.model = model
        self.project = project
        self.embedded = embedded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = embedded ? nil : Theme.paper }
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        create.addAction(UIAction { [weak self] _ in self?.onOpen?(nil) }, for: .touchUpInside)

        rows.axis = .vertical
        notice.textAlignment = .center
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        let header = UIView()
        [header, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        [close, titleLabel, create].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        [rows, notice].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview($0) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: embedded ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor, constant: embedded ? 0 : 18),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: embedded ? 0 : 44),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            create.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            create.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            create.widthAnchor.constraint(equalToConstant: 44), create.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: embedded ? 0 : 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -12),
            notice.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 20),
            notice.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 32),
            notice.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -32),
            notice.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40)
        ])
        header.isHidden = embedded
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
        let sessions = model.sessions(for: project)
        let ids = sessions.map(\.id)
        for id in Array(rowViews.keys) where !ids.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        for session in sessions {
            let row = rowViews[session.id] ?? {
                let row = ThreadRow(sessionID: session.id)
                row.addAction(UIAction { [weak self] _ in self?.onOpen?(session.id) }, for: .touchUpInside)
                rowViews[session.id] = row
                return row
            }()
            row.configure(title: session.displayTitle(in: project), agent: model.agentName(for: session.modelSelection),
                          date: session.updatedAt, phase: session.phase)
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
        let message = sessions.isEmpty ? (model.error ?? (model.isLoading ? "Loading threads…" : "No threads yet")) : nil
        notice.text = message
        notice.isHidden = message == nil
        notice.textColor = model.error == nil ? .secondaryLabel : Theme.failure
    }
}
