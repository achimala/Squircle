import QuickLook
import UIKit

/// A document in a conversation or on a task, as a line: its symbol in the
/// glyph slot, its name and what it is ("PDF · 6.4 MB · 24 pages"). No card.
/// Tapping it opens the viewer.
final class FileRowView: UIControl {
    var onOpen: ((FileRowView) -> Void)?
    private(set) var source: DocumentSource?
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let name = Theme.label("", Theme.Text.lineStrong)
    private let detail = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private var load: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.preferredSymbolConfiguration = Theme.symbol(Theme.Text.line)
        icon.tintColor = Theme.accent
        icon.contentMode = .center
        spinner.hidesWhenStopped = true
        name.lineBreakMode = .byTruncatingMiddle
        let text = UIStackView(arrangedSubviews: [name, detail])
        text.axis = .vertical
        let glyph = UIView()
        [icon, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; glyph.addSubview($0) }
        let row = UIStackView(arrangedSubviews: [glyph, text])
        row.spacing = Theme.Space.glyphGap
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Theme.Space.glyph), glyph.heightAnchor.constraint(equalToConstant: Theme.Space.glyph),
            icon.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), icon.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "document.row"
        addAction(UIAction { [weak self] _ in
            guard let self, source != nil, !opening else { return }
            Theme.selectionHaptic()
            onOpen?(self)
        }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }

    /// Shows `source` with what `documents` knows of it, and finds out the rest.
    func show(_ source: DocumentSource, documents: DocumentFiles) {
        guard source != self.source else { return }
        self.source = source
        opening = false
        render(documents.info[source])
        load?.cancel()
        load = Task { [weak self] in
            let info = await documents.describe(source)
            guard let self, !Task.isCancelled, self.source == source else { return }
            render(info)
        }
    }

    /// Fetching the file to open it.
    var opening = false {
        didSet {
            if opening { spinner.startAnimating() } else { spinner.stopAnimating() }
            icon.isHidden = opening
        }
    }

    func render(_ info: DocumentFiles.Info?) {
        guard let source else { return }
        icon.image = UIImage(systemName: info?.failed == true ? "exclamationmark.triangle" : source.symbol)
        icon.tintColor = info?.failed == true ? .secondaryLabel : Theme.accent
        name.text = source.name
        var parts = [source.kind]
        if let bytes = info?.bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        if let pages = info?.pages { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if info?.failed == true { parts = ["Can't open this file"] }
        detail.text = parts.joined(separator: " · ")
        accessibilityLabel = source.name + ", " + (detail.text ?? "")
    }
}

/// Quick Look over one document: PDFs page and zoom; text reads as text;
/// share saves it to Files or sends it on.
final class DocumentViewer: QLPreviewController, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(_ url: URL, title: String) { previewItemURL = url; previewItemTitle = title }
    }
    private let item: Item
    private weak var origin: UIView?

    private init(_ url: URL, title: String, origin: UIView?) {
        item = Item(url, title: title)
        self.origin = origin
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        delegate = self
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Fetches the row's document if it isn't on the phone yet, then opens it.
    static func open(_ row: FileRowView, documents: DocumentFiles, from presenter: UIViewController) {
        guard let source = row.source, !row.opening else { return }
        row.opening = true
        Task { [weak row, weak presenter] in
            let url = await documents.file(source)
            guard let row, row.source == source else { return }
            row.opening = false
            row.render(documents.info[source])
            guard let url, let presenter, presenter.presentedViewController == nil, presenter.view.window != nil else { return }
            presenter.present(DocumentViewer(url, title: source.name, origin: row), animated: true)
        }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }
    func previewController(_ controller: QLPreviewController, transitionViewFor item: any QLPreviewItem) -> UIView? { origin }
    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
}
