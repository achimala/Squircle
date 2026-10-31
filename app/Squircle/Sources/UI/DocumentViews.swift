import PDFKit
import QuickLook
import UIKit

/// A document in a conversation or on a task, in the same family as the
/// bubbles and pictures beside it: a plain fill at the bubbles' radius. A
/// PDF shows its first page on top, its name and "PDF · 27 pages · 6.4 MB"
/// under it; a text file leads with a tile naming its type. Its height is
/// set by its kind alone, so nothing moves as the file arrives. Tapping it
/// opens the viewer.
final class FileRowView: UIControl {
    var onOpen: ((FileRowView) -> Void)?
    private(set) var source: DocumentSource?
    /// The fill behind it; a row inside a card takes the page's.
    var surfaceColor: UIColor = Theme.receivedFill { didSet { surface.backgroundColor = surfaceColor } }
    private let surface = UIView()
    /// A PDF's first page, as wide as the row.
    private let preview = UIImageView()
    private let previewTile = TypeTile()
    private var previewHeight: NSLayoutConstraint!
    /// A text file's type.
    private let tile = TypeTile()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let name = Theme.label("", Theme.Text.lineStrong)
    private let detail = Theme.label("", Theme.Text.line, color: .secondaryLabel)
    private var load: Task<Void, Never>?
    private var drawing: Task<Void, Never>?
    private var documents: DocumentFiles?
    /// Where the downloaded PDF is, once it is.
    private var file: URL?
    private static let pages = NSCache<NSString, UIImage>()
    static let previewHeight: CGFloat = 160
    static let maxWidth: CGFloat = 300

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.backgroundColor = surfaceColor
        surface.layer.cornerRadius = Theme.Radius.large
        surface.layer.cornerCurve = .continuous
        surface.clipsToBounds = true
        surface.isUserInteractionEnabled = false
        preview.contentMode = .top
        preview.clipsToBounds = true
        preview.backgroundColor = Theme.codeFill
        spinner.hidesWhenStopped = true
        name.lineBreakMode = .byTruncatingMiddle
        let text = UIStackView(arrangedSubviews: [name, detail])
        text.axis = .vertical
        let footer = UIStackView(arrangedSubviews: [tile, text, spinner])
        footer.spacing = Theme.Space.row
        footer.alignment = .center
        footer.isLayoutMarginsRelativeArrangement = true
        let padding = Theme.Space.bubble
        footer.directionalLayoutMargins = NSDirectionalEdgeInsets(top: padding.top, leading: padding.left, bottom: padding.bottom, trailing: padding.right)
        let column = UIStackView(arrangedSubviews: [preview, footer])
        column.axis = .vertical
        previewTile.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(previewTile)
        [surface].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        column.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(column)
        previewHeight = preview.heightAnchor.constraint(equalToConstant: Self.previewHeight)
        let full = surface.widthAnchor.constraint(equalTo: widthAnchor)
        full.priority = .defaultHigh
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            surface.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth), full,
            surface.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            column.topAnchor.constraint(equalTo: surface.topAnchor),
            column.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            previewHeight,
            previewTile.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            previewTile.centerYAnchor.constraint(equalTo: preview.centerYAnchor)
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
        didSet {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.surface.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            }
        }
    }

    private var isPDF: Bool { source?.kind == "PDF" }

    /// Shows `source` with what `documents` knows of it, and finds out the rest.
    func show(_ source: DocumentSource, documents: DocumentFiles) {
        guard source != self.source else { return }
        self.source = source
        self.documents = documents
        opening = false
        file = nil
        preview.image = nil
        drawing?.cancel()
        // A PDF has its page on top; a text file its type at the front.
        preview.isHidden = !isPDF
        previewHeight.isActive = isPDF
        tile.isHidden = isPDF
        tile.kind = source.typeLabel
        previewTile.kind = source.typeLabel
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
        didSet { if opening { spinner.startAnimating() } else { spinner.stopAnimating() } }
    }

    func render(_ info: DocumentFiles.Info?) {
        guard let source else { return }
        name.text = source.name
        var parts = [source.kind]
        if let pages = info?.pages { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if let bytes = info?.bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        if info?.failed == true { parts = ["Can't open this file"] }
        detail.text = parts.joined(separator: " · ")
        accessibilityLabel = source.name + ", " + (detail.text ?? "")
        // Once it is on the phone, its first page.
        if isPDF, info?.pages != nil, file == nil, let documents {
            Task { [weak self] in
                let url = await documents.file(source)
                guard let self, self.source == source else { return }
                file = url
                drawPage()
            }
        }
        previewTile.isHidden = preview.image != nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        drawPage()
    }

    /// The first page at the preview's width, its top showing.
    private func drawPage() {
        guard isPDF, let file, let source, preview.bounds.width > 0 else { return }
        let width = preview.bounds.width
        let key = "\(source.hashValue):\(width)" as NSString
        if let page = Self.pages.object(forKey: key) { showPage(page); return }
        guard drawing == nil else { return }
        let scale = traitCollection.displayScale
        drawing = Task { [weak self] in
            let page = await Self.firstPage(file, width: width, scale: scale)
            guard let self else { return }
            drawing = nil
            guard let page, self.source == source else { return }
            Self.pages.setObject(page, forKey: key)
            showPage(page)
        }
    }

    private func showPage(_ page: UIImage) {
        guard preview.image !== page else { return }
        preview.image = page
        previewTile.isHidden = true
    }

    private nonisolated static func firstPage(_ url: URL, width: CGFloat, scale: CGFloat) async -> UIImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0 else { return nil }
        let size = CGSize(width: width, height: width * box.height / box.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / box.width, y: -size.height / box.height)
            cg.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .cropBox, to: cg)
        }
    }
}

/// A small page-shaped tile naming a file's type ("PDF", "MD", "JSON").
private final class TypeTile: UIView {
    private let label = Theme.label("", Theme.Text.monoStrong, color: .secondaryLabel)
    var kind = "" { didSet { label.text = kind } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.codeFill
        layer.cornerRadius = Theme.Radius.small
        layer.cornerCurve = .continuous
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 40), heightAnchor.constraint(equalToConstant: 48),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
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
