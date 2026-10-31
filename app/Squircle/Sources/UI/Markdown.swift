import UIKit

/// Markdown as agents write it, parsed by Foundation (CommonMark with GitHub
/// tables) and drawn in the app's type. Every line the agent wrote stays a
/// line: a single newline inside a paragraph breaks it, as it does on GitHub
/// comments, because agents rely on that.
enum Markdown {
    static func parse(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func render(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        render(parse(text), font: font, color: color)
    }

    /// Blocks one after another; a blank line's worth of room between them,
    /// except before a list, between a table's rows and after a heading.
    static func render(_ markdown: AttributedString, font: UIFont, color: UIColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let mono = Theme.Text.mono
        var previous: [PresentationIntent.IntentType] = []
        var marked = Set<Int>()
        for (intent, range) in markdown.runs[\.presentationIntent] {
            let blocks = intent?.components ?? []
            if output.length > 0 {
                let last = output.attributes(at: output.length - 1, effectiveRange: nil)
                if let row = row(of: blocks), row == Self.row(of: previous) {
                    output.append(NSAttributedString(string: "\t", attributes: last))
                } else {
                    output.append(NSAttributedString(string: "\n", attributes: last))
                    // A list hangs from the line that introduces it.
                    let header = previous.first.map { if case .header = $0.kind { true } else { false } } ?? false
                    if !header, !blocks.contains(where: isList), table(of: blocks) == nil || table(of: blocks) != table(of: previous) {
                        output.append(NSAttributedString(string: "\n", attributes: [.font: font.withSize(font.pointSize * 0.45)]))
                    }
                }
            }
            output.append(block(markdown[range], blocks, marked: &marked, font: font, mono: mono, color: color))
            previous = blocks
        }
        // Agents end messages with newlines, and a piece cut at a picture
        // can start with one; either is only height.
        while output.string.last?.isNewline == true { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        while output.string.first?.isNewline == true { output.deleteCharacters(in: NSRange(location: 0, length: 1)) }
        return output
    }

    /// One paragraph, heading, code block, quote or table cell.
    private static func block(_ text: AttributedSubstring, _ blocks: [PresentationIntent.IntentType], marked: inout Set<Int>,
                              font: UIFont, mono: UIFont, color: UIColor) -> NSAttributedString {
        var indent: CGFloat = 0, hanging: CGFloat = 0, prefix = "", color = color
        // Each list it nests in indents it a little; its own item shows the
        // marker on its first block, and later blocks line up with the text.
        let items = blocks.indices.filter { if case .listItem = blocks[$0].kind { true } else { false } }
        if let index = items.first, case .listItem(let ordinal) = blocks[index].kind {
            let ordered = index + 1 < blocks.count && blocks[index + 1].kind == .orderedList
            let width: CGFloat = ordered ? 24 : 16
            indent = CGFloat(items.count - 1) * Theme.Space.rowPad
            if marked.insert(blocks[index].identity).inserted {
                prefix = ordered ? "\(ordinal).\t" : "•\t"
                hanging = width
            } else {
                indent += width
            }
        }
        if blocks.contains(where: { $0.kind == .blockQuote }) { indent += Theme.Space.rowPad; color = .secondaryLabel }
        let style = NSMutableParagraphStyle()
        switch blocks.first?.kind {
        case .codeBlock?:
            style.firstLineHeadIndent = indent + Theme.Space.rowPad
            style.headIndent = indent + Theme.Space.rowPad
            style.lineBreakMode = .byCharWrapping
            var code = String(text.characters)
            while code.last?.isNewline == true { code.removeLast() }
            return NSAttributedString(string: code, attributes: [.font: mono, .foregroundColor: color, .paragraphStyle: style])
        case .tableCell?:
            let header = blocks.contains { $0.kind == .tableHeaderRow }
            return inline(text, font: header ? bold(font) : font, mono: mono, color: .secondaryLabel)
        default:
            break
        }
        var base = font
        // Headings stay in the text's own size (one size per message).
        if case .header? = blocks.first?.kind { base = bold(font) }
        if blocks.first?.kind == .thematicBreak { color = .tertiaryLabel }
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        style.lineSpacing = 3
        // List items sit closer together than paragraphs do.
        style.paragraphSpacing = items.isEmpty ? font.pointSize * 0.35 : Theme.Space.tight
        if hanging > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        let result = NSMutableAttributedString(string: prefix, attributes: [.font: base, .foregroundColor: UIColor.secondaryLabel])
        // A new line inside a list item or quote wraps under its text, not
        // its marker.
        result.append(inline(text, font: base, mono: mono, color: color, lineBreak: indent + hanging > 0 ? "\u{2028}" : "\n"))
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func isList(_ block: PresentationIntent.IntentType) -> Bool {
        switch block.kind { case .orderedList, .unorderedList: true; default: false }
    }

    private static func table(of blocks: [PresentationIntent.IntentType]) -> Int? {
        blocks.first { if case .table = $0.kind { true } else { false } }?.identity
    }

    private static func row(of blocks: [PresentationIntent.IntentType]) -> Int? {
        blocks.first { switch $0.kind { case .tableRow, .tableHeaderRow: true; default: false } }?.identity
    }

    /// Emphasis, code and links; line breaks become `lineBreak`.
    static func inline(_ text: AttributedSubstring, font base: UIFont, mono: UIFont, color: UIColor,
                       lineBreak: String = "\n") -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = mono
                attributes[.backgroundColor] = Theme.codeFill
            } else if intent.contains(.stronglyEmphasized) {
                attributes[.font] = bold(base)
            } else if intent.contains(.emphasized), let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
                attributes[.font] = UIFont(descriptor: descriptor, size: base.pointSize)
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link ?? run.imageURL { attributes[.link] = link }
            let string = intent.contains(.softBreak) || intent.contains(.lineBreak) ? lineBreak : String(text[run.range].characters)
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }

    static func bold(_ font: UIFont) -> UIFont {
        font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
    }
}

/// A picture or clip an agent put in its Markdown, by file path on the Mac.
struct MediaReference: Equatable {
    let path: String
    let video: Bool
}

extension Markdown {
    enum Segment: Equatable {
        /// Parsed Markdown, drawn with `render`.
        case text(AttributedString)
        case media(MediaReference)
        case table(MarkdownTable)
        /// A PDF or text file the text links, by path: a file row after
        /// the text that links it, which keeps its words.
        case document(String)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Splits a message at the pictures and clips it embeds (`![alt](path)`,
    /// or a link straight to an image or video file), and at its tables, so
    /// each shows in place. The alt text is a caption and is dropped; the
    /// rest of its paragraph stays. Web URLs and anything in code stay text.
    /// Each document it links (once) follows the text linking it.
    static func segments(_ text: String) -> [Segment] {
        let parsed = parse(text)
        var segments: [Segment] = []
        var start = parsed.startIndex
        var documents: [String] = [], linked = Set<String>()
        func flush(to end: AttributedString.Index) {
            let piece = AttributedString(parsed[start..<end])
            start = end
            if !String(piece.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.text(piece)) }
            segments += documents.map(Segment.document)
            documents = []
        }
        var table: TableCells?
        func finish() {
            if let table { segments.append(.table(table.table)) }
            table = nil
        }
        for run in parsed.runs {
            if let cell = TableCells.Cell(run.presentationIntent) {
                if table?.id != cell.table {
                    finish()
                    flush(to: run.range.lowerBound)
                    table = TableCells(id: cell.table, columns: cell.columns)
                }
                table?.cells[cell.row, default: [:]][cell.column, default: AttributedString()].append(parsed[run.range])
                start = run.range.upperBound
                continue
            }
            finish()
            if let url = run.link, url.scheme == nil || url.isFileURL, DocumentSource.isDocument(url.path), linked.insert(url.path).inserted {
                documents.append(url.path)
            }
            guard let url = run.imageURL ?? run.link, let media = reference(url) else { continue }
            // A link with emphasis inside is several runs, one picture.
            if case .media(media)? = segments.last, start == run.range.lowerBound { start = run.range.upperBound; continue }
            flush(to: run.range.lowerBound)
            segments.append(.media(media))
            start = run.range.upperBound
        }
        finish()
        flush(to: parsed.endIndex)
        return segments
    }

    /// A local file path to an image or video, else nil.
    private static func reference(_ url: URL) -> MediaReference? {
        guard url.scheme == nil || url.isFileURL else { return nil }
        let path = url.path
        guard !path.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { return MediaReference(path: path, video: true) }
        return imageExtensions.contains(ext) ? MediaReference(path: path, video: false) : nil
    }

    /// One table's cells as Foundation hands them out, run by run.
    private struct TableCells {
        struct Cell {
            let table: Int, columns: [PresentationIntent.TableColumn], row: Int, column: Int
            init?(_ intent: PresentationIntent?) {
                var table: (Int, [PresentationIntent.TableColumn])?, row: Int?, column: Int?
                for component in intent?.components ?? [] {
                    switch component.kind {
                    case .table(let columns): table = (component.identity, columns)
                    case .tableHeaderRow: row = 0
                    case .tableRow(let index): row = index
                    case .tableCell(let index): column = index
                    default: break
                    }
                }
                guard let table, let row, let column else { return nil }
                (self.table, columns, self.row, self.column) = (table.0, table.1, row, column)
            }
        }
        let id: Int
        let columns: [PresentationIntent.TableColumn]
        var cells: [Int: [Int: AttributedString]] = [:]

        /// Empty cells and rows have no runs at all, so they are filled in.
        var table: MarkdownTable {
            let rows = (0...(cells.keys.max() ?? 0)).map { row in columns.indices.map { cells[row]?[$0] ?? AttributedString() } }
            return MarkdownTable(header: rows[0], alignments: columns.map(\.alignment), rows: Array(rows.dropFirst()))
        }
    }
}

/// A GitHub-style table: its header, how each column aligns, and its rows,
/// each cell parsed inline Markdown, each row as wide as the header.
struct MarkdownTable: Equatable {
    var header: [AttributedString]
    var alignments: [PresentationIntent.TableColumn.Alignment]
    var rows: [[AttributedString]]
}

/// A table measured for one width: each column's width, each row's height
/// and the text drawn in every cell. Built once per table, width and text
/// size; `MarkdownTableView` only draws it.
struct MarkdownTableLayout {
    /// The header first, then the rows.
    let cells: [[NSAttributedString]]
    let widths: [CGFloat]
    let heights: [CGFloat]
    let size: CGSize
    /// Wider than the width it was laid out for, so it scrolls sideways.
    var overflows: Bool { size.width > available + 0.5 }
    private let available: CGFloat

    static let gap = Theme.Space.group
    static let padding = Theme.Space.row

    init(_ table: MarkdownTable, font: UIFont, color: UIColor, width: CGFloat) {
        available = width
        let mono = Theme.Text.mono
        let header = Markdown.bold(font)
        func render(_ text: AttributedString, row: Int, column: Int) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = [.left: .natural, .center: .center, .right: .right][table.alignments[column]] ?? .natural
            style.lineSpacing = 2
            let cell = NSMutableAttributedString(attributedString: Markdown.inline(text[text.startIndex..<text.endIndex], font: row == 0 ? header : font, mono: mono,
                                                                                    color: row == 0 ? .label : color))
            cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
            return cell
        }
        cells = ([table.header] + table.rows).enumerated().map { row, texts in
            texts.enumerated().map { render($1, row: row, column: $0) }
        }
        func measure(_ text: NSAttributedString, _ width: CGFloat) -> CGSize {
            let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return CGSize(width: ceil(rect.width), height: ceil(rect.height))
        }
        // Each column wants its longest cell on one line, and needs at least
        // its longest word (a long path may still break) and a readable width.
        let columns = table.header.indices
        var natural = columns.map { _ in CGFloat(0) }, least = natural
        let longestWord = min(160, width * 0.45)
        for row in cells {
            for (column, cell) in row.enumerated() where cell.length > 0 {
                natural[column] = max(natural[column], measure(cell, .greatestFiniteMagnitude).width)
                let string = cell.string as NSString
                var widest: CGFloat = 0
                string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byWords) { _, range, _, _ in
                    widest = max(widest, measure(cell.attributedSubstring(from: range), .greatestFiniteMagnitude).width)
                }
                least[column] = max(least[column], min(widest, longestWord))
            }
        }
        // Below a few words' width a column wraps into a word per line;
        // past that the table scrolls instead.
        let narrowest = ceil(font.pointSize * 6)
        least = zip(least, natural).map { min($1, max($0, narrowest)) }
        let room = width - Self.gap * CGFloat(max(0, columns.count - 1))
        let wanted = natural.reduce(0, +), needed = least.reduce(0, +)
        let widths: [CGFloat]
        if wanted <= room {
            widths = natural
        } else if needed <= room {
            // Shared like a browser does: each column gets its least, then
            // the rest in proportion to how much more it wants.
            let extra = (room - needed) / max(1, wanted - needed)
            widths = zip(least, natural).map { floor($0 + ($1 - $0) * extra) }
        } else {
            // Too wide for the screen: it scrolls, so columns can keep a
            // readable width instead of wrapping word by word.
            let readable = max(120, width * 0.5)
            widths = zip(least, natural).map { max($0, min($1, readable)) }
        }
        let measured = cells.map { row in
            row.enumerated().map { column, cell in cell.length > 0 ? measure(cell, widths[column]).height : 0 }.max() ?? 0
        }
        self.widths = widths
        heights = measured.map { max($0, ceil(font.lineHeight)) + Self.padding * 2 }
        size = CGSize(width: widths.reduce(0, +) + Self.gap * CGFloat(max(0, columns.count - 1)), height: heights.reduce(0, +))
    }
}
