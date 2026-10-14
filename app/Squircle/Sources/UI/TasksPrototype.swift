#if DEBUG
import UIKit

/// Design prototype only (never in Release): two layouts for task tracking,
/// filled with the Squircle agent's real requests of 2026-10-14. Shown by
/// `SQUIRCLE_TASKS=sheet|strip|strip-open`; nothing here talks to the service.
enum TaskPrototype {
    enum Status: CaseIterable {
        case needsYou, inProgress, readyToTry, queued, done

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .inProgress: "In progress"
            case .readyToTry: "Ready to try"
            case .queued: "Queued"
            case .done: "Done"
            }
        }
        var color: UIColor {
            switch self {
            case .needsYou: Theme.accent
            case .inProgress: Theme.warning
            case .readyToTry: Theme.success
            case .queued, .done: .tertiaryLabel
            }
        }
    }

    struct Item {
        /// The ask in the user's own words, trimmed.
        let ask: String
        let status: Status
        /// What it is waiting on or linked to, in a few words.
        let detail: String
        var build: String? = nil
    }

    static let items: [Item] = [
        Item(ask: "Build some kind of task tracking UI, I keep losing track", status: .needsYou,
             detail: "Pick one of two layouts"),
        Item(ask: "Codex worker: fresh look for bugs, invalid states, code smells", status: .inProgress,
             detail: "Codex review · shows you the list before any fixes"),
        Item(ask: "Jelly dude runs at 10fps, freezes, shimmer never stops", status: .inProgress,
             detail: "Jelly on device · working 14m"),
        Item(ask: "Stack the sims and fan them out when tapped", status: .inProgress,
             detail: "Stack sim PiPs · working 3m"),
        Item(ask: "Show workers and messages between threads in the transcript", status: .inProgress,
             detail: "Actions in the transcript · working 11m"),
        Item(ask: "The worked line pulses when I send", status: .inProgress,
             detail: "Stray pulse on send · working 15m"),
        Item(ask: "In-app perf traces, sent to the agent", status: .readyToTry,
             detail: "Squircle 47", build: "47"),
        Item(ask: "Screen recordings in the attachments menu", status: .readyToTry,
             detail: "Squircle 47", build: "47"),
        Item(ask: "Build Letters Abroad with the new stuff", status: .readyToTry,
             detail: "Letters Abroad 12", build: "12"),
        Item(ask: "Worker prompts as a formatted header, not a chat bubble", status: .queued,
             detail: "After: actions in the transcript"),
        Item(ask: "Don't truncate reasoning, I want to read it", status: .queued,
             detail: "After: actions in the transcript"),
        Item(ask: "Agents clean up branches and worktrees", status: .done, detail: "Merged"),
        Item(ask: "Agent forgets its role after compaction", status: .done, detail: "Merged"),
        Item(ask: "Restart or start fresh a confused agent", status: .done, detail: "Squircle 46")
    ]

    static func count(_ status: Status) -> Int { items.filter { $0.status == status }.count }

    static func dot(_ color: UIColor, size: CGFloat = 8) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = size / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: size),
                                     dot.heightAnchor.constraint(equalToConstant: size)])
        return dot
    }

    static func install(_ build: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = Theme.onAccent
        config.title = "Install"
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 13, bottom: 6, trailing: 13)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.subheadline, 15, .semibold)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

/// Layout A: a Tasks sheet beside Threads and Builds, grouped by what each
/// task needs; done work folds into one line, and every thread stays a tap away.
@MainActor
final class TasksSheetPrototype: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = Theme.paper }
        let close = Theme.glassButton(symbol: "xmark", accessibilityLabel: "Close tasks")
        let add = Theme.glassButton(symbol: "plus", accessibilityLabel: "Add task")
        let title = Theme.label("Tasks", Theme.font(.headline, 17, .semibold))
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .vertical
        for status in TaskPrototype.Status.allCases where status != .done {
            let items = TaskPrototype.items.filter { $0.status == status }
            guard !items.isEmpty else { continue }
            stack.addArrangedSubview(header(status, count: items.count))
            for (index, item) in items.enumerated() {
                stack.addArrangedSubview(row(item, separator: index < items.count - 1))
            }
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        }
        stack.addArrangedSubview(footer("Done today", value: "\(TaskPrototype.count(.done))"))
        stack.addArrangedSubview(footer("All threads", value: "14"))

        let header = UIView()
        [header, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        [close, title, add].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: 44),
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            add.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            add.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 44), add.heightAnchor.constraint(equalToConstant: 44),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40)
        ])
    }

    private func header(_ status: TaskPrototype.Status, count: Int) -> UIView {
        let name = Theme.label(status.title, Theme.font(.subheadline, 15, .semibold), color: status.color)
        let number = Theme.label("\(count)", Theme.font(.subheadline, 15, .semibold), color: .tertiaryLabel)
        let line = UIStackView(arrangedSubviews: [name, number, UIView()])
        line.spacing = 6
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 0, bottom: 4, trailing: 0)
        return line
    }

    private func row(_ item: TaskPrototype.Item, separator: Bool) -> UIView {
        let ask = Theme.label(item.ask, Theme.font(.body, 17), lines: 2)
        let detail = Theme.label(item.detail, Theme.font(.subheadline, 15), color: .secondaryLabel)
        let text = UIStackView(arrangedSubviews: [ask, detail])
        text.axis = .vertical
        text.spacing = 3
        let line = UIStackView(arrangedSubviews: [text])
        line.alignment = .center
        line.spacing = 12
        if let build = item.build { line.addArrangedSubview(TaskPrototype.install(build)) }
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        guard separator else { return line }
        let rule = UIView()
        rule.backgroundColor = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: line.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
        return line
    }

    private func footer(_ title: String, value: String) -> UIView {
        let name = Theme.label(title, Theme.font(.body, 17), color: .secondaryLabel)
        let number = Theme.label(value, Theme.font(.body, 17), color: .tertiaryLabel)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        let line = UIStackView(arrangedSubviews: [name, UIView(), number, chevron])
        line.spacing = 8
        line.alignment = .center
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        return line
    }
}

/// Layout B: open work as one glass line above the field, in the
/// conversation; tapping it rises into the open tasks, one line each.
@MainActor
final class TaskStripPrototype: UIView {
    private let surface = Theme.glassSurface(cornerRadius: 22, interactive: true)
    private let list = UIStackView()
    private let summary = UIStackView()
    var expanded = false { didSet { list.isHidden = !expanded } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (status, word) in [(TaskPrototype.Status.needsYou, "needs you"), (.inProgress, "working"),
                               (.readyToTry, "to try")] {
            let part = UIStackView(arrangedSubviews: [TaskPrototype.dot(status.color, size: 7),
                Theme.label("\(TaskPrototype.count(status)) \(word)", Theme.font(.subheadline, 15, .medium),
                            color: status == .needsYou ? .label : .secondaryLabel)])
            part.spacing = 5
            part.alignment = .center
            summary.addArrangedSubview(part)
        }
        let chevron = UIImageView(image: UIImage(systemName: "chevron.up"))
        chevron.tintColor = .secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        summary.addArrangedSubview(UIView())
        summary.addArrangedSubview(chevron)
        summary.spacing = 12
        summary.alignment = .center

        list.axis = .vertical
        list.spacing = 2
        list.isHidden = true
        for item in TaskPrototype.items where item.status != .done {
            list.addArrangedSubview(line(item))
        }
        let column = UIStackView(arrangedSubviews: [list, summary])
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        surface.contentView.addSubview(column)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: 11),
            column.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor, constant: -11),
            column.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -14)
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { expanded.toggle() }

    private func line(_ item: TaskPrototype.Item) -> UIView {
        let ask = Theme.label(item.ask, Theme.font(.subheadline, 15))
        ask.lineBreakMode = .byTruncatingTail
        ask.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let views: [UIView] = [TaskPrototype.dot(item.status.color, size: 7), ask]
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = 9
        row.alignment = .center
        if let build = item.build {
            row.addArrangedSubview(TaskPrototype.install(build))
        }
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        return row
    }
}
#endif
