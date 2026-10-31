import UIKit

/// One step, opened: an edit as a diff, a command with its output, or the
/// raw record when that is all there is.
final class StepDetailViewController: UIViewController {
    private let step: ChatMessage
    /// What a Squircle action did, as the conversation says it, over its command.
    var headline: NSAttributedString?
    /// Opens the task the action changed.
    var onOpenTask: (() -> Void)?

    init(step: ChatMessage) {
        self.step = step
        super.init(nibName: nil, bundle: nil)
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 32
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26.0, *) { view.backgroundColor = nil } else { view.backgroundColor = Theme.paper }
        let icon = UIImageView(image: UIImage(systemName: step.symbol.isEmpty ? "wrench.and.screwdriver" : step.symbol))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = Theme.symbol(Theme.Text.body)
        let title = Theme.label(step.content, Theme.Text.body, lines: 3)
        if let headline { title.attributedText = headline; title.numberOfLines = 4 }
        let header = UIStackView(arrangedSubviews: headline == nil ? [icon, title] : [title])
        header.spacing = Theme.Space.glyphGap
        header.alignment = .firstBaseline
        var stack: [UIView] = [header]
        if let onOpenTask {
            var config = UIButton.Configuration.filled()
            config.title = "Open in Tasks"
            config.cornerStyle = .capsule
            config.baseBackgroundColor = Theme.accent
            config.baseForegroundColor = Theme.onAccent
            config.buttonSize = .small
            let open = UIButton(configuration: config, primaryAction: UIAction { _ in onOpenTask() })
            open.accessibilityIdentifier = "thread.step.openTask"
            let row = UIStackView(arrangedSubviews: [open, UIView()])
            stack.append(row)
        }
        let top = UIStackView(arrangedSubviews: stack)
        top.axis = .vertical
        top.spacing = Theme.Space.rowPad
        top.alignment = .fill
        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: Theme.Space.tight, left: Theme.Space.margin, bottom: 40, right: Theme.Space.margin)
        text.accessibilityIdentifier = "thread.step.detail"
        text.attributedText = body()
        [top, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.section),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Space.margin),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Space.margin),
            text.topAnchor.constraint(equalTo: top.bottomAnchor, constant: Theme.Space.rowPad),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            text.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func body() -> NSAttributedString {
        let mono = Theme.Text.mono
        if let diff = step.step?.diff {
            return Self.render(diff: diff, font: mono)
        }
        return NSAttributedString(string: step.detail, attributes: [.font: mono, .foregroundColor: UIColor.label])
    }

    /// Line diff: removed lines on red, added on green, unchanged quiet.
    static func render(diff: StepDiff, font: UIFont) -> NSAttributedString {
        let old = diff.old.isEmpty ? [] : diff.old.components(separatedBy: "\n")
        let new = diff.new.isEmpty ? [] : diff.new.components(separatedBy: "\n")
        let output = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        func line(_ text: String, _ mark: String, _ color: UIColor, _ fill: UIColor?) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let fill { attributes[.backgroundColor] = fill }
            output.append(NSAttributedString(string: mark + " " + text + "\n", attributes: attributes))
        }
        for change in lineDiff(old, new) {
            switch change {
            case .same(let text): line(text, " ", .secondaryLabel, nil)
            case .removed(let text): line(text, "−", .label, Theme.failure.withAlphaComponent(0.16))
            case .added(let text): line(text, "+", .label, Theme.success.withAlphaComponent(0.16))
            }
        }
        return output
    }

    enum Change: Equatable { case same(String), removed(String), added(String) }

    /// Line diff (Myers, via the standard library); removals before additions, as git shows them.
    static func lineDiff(_ a: [String], _ b: [String]) -> [Change] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var changes: [Change] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { changes.append(.removed(a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { changes.append(.added(b[j])); j += 1 }
            else { changes.append(.same(a[i])); i += 1; j += 1 }
        }
        return changes
    }
}
