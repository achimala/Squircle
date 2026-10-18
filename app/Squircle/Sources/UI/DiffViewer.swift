import UIKit

/// A unified diff, parsed once off the main thread into flat lines.
struct ParsedDiff: Sendable {
    enum Kind: UInt8, Sendable { case context, added, removed, hunk }
    struct Line: Sendable {
        let kind: Kind
        let old: Int32
        let new: Int32
        let text: String
    }
    struct File: Sendable {
        let path: String
        var additions = 0
        var deletions = 0
        var lines: [Line] = []
    }
    var files: [File] = []
    /// Longest line in characters, for the sideways scroll width.
    var widest = 0

    static func parse(_ diff: String) -> ParsedDiff {
        var result = ParsedDiff()
        var current: File?
        var old: Int32 = 0, new: Int32 = 0
        // Lines the current hunk still owes on each side. Inside a hunk every
        // line is a change or context, even "-- comment" or "++i"; between
        // hunks only "@@" matters and headers ("---", "index", …) are skipped.
        var oldLeft = 0, newLeft = 0
        func flush() { if let current { result.files.append(current) } }
        diff.enumerateLines { raw, _ in
            if raw.hasPrefix("diff --git ") {
                flush()
                let path = raw.components(separatedBy: " b/").last ?? raw
                current = File(path: path)
                oldLeft = 0; newLeft = 0
                return
            }
            guard current != nil else { return }
            guard oldLeft > 0 || newLeft > 0 else {
                guard raw.hasPrefix("@@") else { return }
                // @@ -a,b +c,d @@ context (",b" and ",d" default to 1)
                let parts = raw.split(separator: " ")
                if parts.count > 2 {
                    let a = parts[1].dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                    let c = parts[2].dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                    old = Int32(a.first ?? "") ?? 0
                    new = Int32(c.first ?? "") ?? 0
                    oldLeft = a.count > 1 ? Int(a[1]) ?? 0 : 1
                    newLeft = c.count > 1 ? Int(c[1]) ?? 0 : 1
                }
                current?.lines.append(Line(kind: .hunk, old: 0, new: 0, text: raw))
                return
            }
            if raw.hasPrefix("\\") { return }  // "\ No newline at end of file"
            let body = String(raw.dropFirst().prefix(600)).replacingOccurrences(of: "\t", with: "    ")
            result.widest = max(result.widest, body.count)
            switch raw.first {
            case "+":
                current?.lines.append(Line(kind: .added, old: 0, new: new, text: body)); new += 1; newLeft -= 1; current?.additions += 1
            case "-":
                current?.lines.append(Line(kind: .removed, old: old, new: 0, text: body)); old += 1; oldLeft -= 1; current?.deletions += 1
            default:
                current?.lines.append(Line(kind: .context, old: old, new: new, text: body)); old += 1; new += 1; oldLeft -= 1; newLeft -= 1
            }
        }
        flush()
        return result
    }
}

/// Code changes, file by file. One fixed-height row per diff line, laid out
/// by hand, so only the visible rows ever exist even for very large diffs.
/// Lines don't wrap; the whole diff scrolls sideways together.
final class DiffViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let titleText: String
    private let load: () async -> String?
    private var diff = ParsedDiff()
    private var collapsed = Set<Int>()
    private let sideways = UIScrollView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let status = Theme.label("", Theme.font(.subheadline, 15), color: .secondaryLabel)
    private let spinner = UIActivityIndicatorView(style: .medium)
    static let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let rowHeight: CGFloat = 19
    static let gutter: CGFloat = 76

    init(title: String, load: @escaping () async -> String?) {
        self.titleText = title
        self.load = load
        super.init(nibName: nil, bundle: nil)
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 32
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let heading = Theme.label(titleText, Theme.font(.headline, 17, .semibold))
        heading.accessibilityTraits = .header
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        table.estimatedRowHeight = Self.rowHeight
        table.sectionHeaderHeight = 44
        table.estimatedSectionHeaderHeight = 44
        table.sectionHeaderTopPadding = 0
        table.separatorStyle = .none
        table.backgroundColor = .systemBackground
        table.register(DiffLineCell.self, forCellReuseIdentifier: "line")
        table.register(DiffFileHeader.self, forHeaderFooterViewReuseIdentifier: "file")
        table.accessibilityIdentifier = "diff.lines"
        sideways.addSubview(table)
        sideways.delegate = self
        sideways.alwaysBounceHorizontal = false
        sideways.showsHorizontalScrollIndicator = true
        sideways.isDirectionalLockEnabled = true
        spinner.startAnimating()
        [heading, sideways, status, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            status.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            sideways.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            sideways.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sideways.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sideways.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        Task { [weak self] in
            guard let self, let text = await load() else {
                self?.spinner.stopAnimating()
                self?.status.text = "Couldn’t load the changes"
                return
            }
            let parsed = await Task.detached(priority: .userInitiated) { ParsedDiff.parse(text) }.value
            diff = parsed
            spinner.stopAnimating()
            let added = parsed.files.reduce(0) { $0 + $1.additions }, removed = parsed.files.reduce(0) { $0 + $1.deletions }
            status.text = "\(parsed.files.count) file\(parsed.files.count == 1 ? "" : "s")  ·  +\(added)  −\(removed)"
            view.setNeedsLayout()
            table.reloadData()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let char = ("0" as NSString).size(withAttributes: [.font: Self.font]).width
        let width = max(sideways.bounds.width, Self.gutter + 24 + CGFloat(diff.widest) * char)
        if table.frame.size != CGSize(width: width, height: sideways.bounds.height) {
            table.frame = CGRect(x: 0, y: 0, width: width, height: sideways.bounds.height)
            sideways.contentSize = CGSize(width: width, height: sideways.bounds.height)
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { diff.files.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        collapsed.contains(section) ? 0 : diff.files[section].lines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath) as! DiffLineCell
        cell.show(diff.files[indexPath.section].lines[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "file") as! DiffFileHeader
        let file = diff.files[section]
        header.contentOffsetX = sideways.contentOffset.x
        header.show(path: file.path, additions: file.additions, deletions: file.deletions,
                    collapsed: collapsed.contains(section), visibleWidth: sideways.bounds.width) { [weak self] in
            guard let self else { return }
            if !collapsed.insert(section).inserted { collapsed.remove(section) }
            Theme.selectionHaptic()
            tableView.reloadSections([section], with: .fade)
        }
        return header
    }

    /// File headers stay readable however far the code scrolls sideways.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === sideways else { return }
        for case let header as DiffFileHeader in table.subviews { header.contentOffsetX = sideways.contentOffset.x }
    }
}

/// One diff line: old and new line numbers, then the code. Laid out by hand.
final class DiffLineCell: UITableViewCell {
    private let numbers = UILabel()
    private let code = UILabel()
    private static let addedFill = Theme.success.withAlphaComponent(0.13)
    private static let removedFill = Theme.failure.withAlphaComponent(0.13)
    private static let hunkFill = Theme.accent.withAlphaComponent(0.08)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        numbers.font = UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        numbers.textColor = .tertiaryLabel
        code.font = DiffViewController.font
        code.lineBreakMode = .byClipping
        contentView.addSubview(numbers)
        contentView.addSubview(code)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ line: ParsedDiff.Line) {
        switch line.kind {
        case .added:
            backgroundColor = Self.addedFill
            numbers.text = "      " + String(format: "%5d", line.new)
            code.text = "+ " + line.text
            code.textColor = .label
        case .removed:
            backgroundColor = Self.removedFill
            numbers.text = String(format: "%5d", line.old)
            code.text = "− " + line.text
            code.textColor = .label
        case .context:
            backgroundColor = .clear
            numbers.text = String(format: "%5d %5d", line.old, line.new)
            code.text = "  " + line.text
            code.textColor = .secondaryLabel
        case .hunk:
            backgroundColor = Self.hunkFill
            numbers.text = nil
            code.text = line.text
            code.textColor = Theme.accent
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = contentView.bounds.height
        numbers.frame = CGRect(x: 8, y: 0, width: DiffViewController.gutter - 12, height: height)
        code.frame = CGRect(x: DiffViewController.gutter, y: 0, width: contentView.bounds.width - DiffViewController.gutter, height: height)
    }
}

/// A file's name and its size of change; tap to fold the file.
final class DiffFileHeader: UITableViewHeaderFooterView {
    private let glass = Theme.glassSurface(cornerRadius: 16)
    private let name = Theme.label("", Theme.font(.footnote, 13, .semibold, monospaced: true))
    private let stats = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private var action: (() -> Void)?
    private var visibleWidth: CGFloat = 0
    var contentOffsetX: CGFloat = 0 { didSet { setNeedsLayout() } }

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        name.lineBreakMode = .byTruncatingHead
        stats.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .center
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        contentView.addSubview(glass)
        [name, stats, chevron].forEach { glass.contentView.addSubview($0) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(path: String, additions: Int, deletions: Int, collapsed: Bool, visibleWidth: CGFloat, action: @escaping () -> Void) {
        name.text = path
        let text = NSMutableAttributedString(string: "+\(additions)", attributes: [.foregroundColor: Theme.success])
        text.append(NSAttributedString(string: " −\(deletions)", attributes: [.foregroundColor: Theme.failure]))
        stats.attributedText = text
        chevron.transform = collapsed ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity
        self.visibleWidth = visibleWidth
        self.action = action
        accessibilityLabel = "\(path), \(additions) added, \(deletions) removed"
        setNeedsLayout()
    }

    @objc private func tapped() { action?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, min(visibleWidth, bounds.width) - 20)
        glass.frame = CGRect(x: 10 + contentOffsetX, y: 6, width: width, height: bounds.height - 10)
        let statsWidth = stats.intrinsicContentSize.width
        chevron.frame = CGRect(x: 12, y: 0, width: 14, height: glass.bounds.height)
        stats.frame = CGRect(x: glass.bounds.width - statsWidth - 12, y: 0, width: statsWidth, height: glass.bounds.height)
        name.frame = CGRect(x: 32, y: 0, width: max(0, stats.frame.minX - 40), height: glass.bounds.height)
    }
}
