import UIKit

/// One step, opened: an edit as a diff, a command with its output, or the
/// raw record when that is all there is.
final class StepDetailViewController: UIViewController {
    private let step: ChatMessage

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
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        let title = Theme.label(step.content, Theme.font(.headline, 17, .semibold), lines: 3)
        let header = UIStackView(arrangedSubviews: [icon, title])
        header.spacing = 10
        header.alignment = .firstBaseline
        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: 4, left: 18, bottom: 40, right: 18)
        text.accessibilityIdentifier = "thread.step.detail"
        text.attributedText = body()
        [header, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            text.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            text.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func body() -> NSAttributedString {
        let mono = Theme.font(.footnote, 12.5, monospaced: true)
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

/// A screenshot, full size, pinch to zoom.
final class ImageViewController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scroll = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage, title: String) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        self.title = title
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIdentifier = "thread.media.full"
        scroll.delegate = self
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scroll)
        scroll.addSubview(imageView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.zoomScale == 1 else { return }
        imageView.frame = scroll.bounds.insetBy(dx: 12, dy: 30)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
