import UIKit

/// The subset of Markdown coding agents actually write: paragraphs, headings,
/// lists, fenced code, tables, and inline emphasis, code and links.
enum Markdown {
    static func render(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let mono = monospaced(for: font)
        var inCode = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let line: NSAttributedString
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            } else if inCode || (trimmed.hasPrefix("|") && trimmed.hasSuffix("|")) {
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = inCode ? 12 : 0
                style.headIndent = inCode ? 12 : 0
                style.lineBreakMode = inCode ? .byCharWrapping : .byWordWrapping
                line = NSAttributedString(string: raw, attributes: [
                    .font: mono, .foregroundColor: inCode ? color : UIColor.secondaryLabel, .paragraphStyle: style
                ])
            } else if trimmed.isEmpty {
                // A blank line between paragraphs: room to breathe.
                line = NSAttributedString(string: "", attributes: [.font: font.withSize(font.pointSize * 0.75)])
            } else {
                line = paragraph(raw, font: font, mono: mono, color: color)
            }
            output.append(line)
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: line.length > 0
                    ? line.attributes(at: line.length - 1, effectiveRange: nil)
                    : [.font: font.withSize(font.pointSize * 0.45)]))
            }
        }
        // Agents end messages with newlines; a trailing blank line is only height.
        while output.string.hasSuffix("\n") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }

    private static func paragraph(_ raw: String, font: UIFont, mono: UIFont, color: UIColor) -> NSAttributedString {
        var text = Substring(raw)
        let indent = CGFloat(text.prefix { $0 == " " }.count) * 5
        text = text.drop { $0 == " " }
        var base = font
        var prefix = ""
        var hanging: CGFloat = 0
        if text.hasPrefix("#") {
            let level = text.prefix { $0 == "#" }.count
            let rest = text.dropFirst(level)
            if level <= 6, rest.hasPrefix(" ") {
                text = rest.dropFirst()
                base = bold(font.withSize(font.pointSize + (level <= 2 ? 3 : 1)))
            }
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("• ") {
            text = text.dropFirst(2)
            prefix = "•\t"
            hanging = 16
        } else if let dot = text.firstIndex(of: "."), text[..<dot].count <= 3, !text[..<dot].isEmpty,
                  text[..<dot].allSatisfy(\.isNumber), text[text.index(after: dot)...].hasPrefix(" ") {
            prefix = String(text[...dot]) + "\t"
            text = text[text.index(dot, offsetBy: 2)...]
            hanging = 24
        }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        style.lineSpacing = 3
        // List items sit closer together than paragraphs do.
        style.paragraphSpacing = hanging > 0 ? 4 : font.pointSize * 0.35
        if hanging > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        let result = NSMutableAttributedString(string: prefix, attributes: [.font: base, .foregroundColor: UIColor.secondaryLabel])
        result.append(inline(String(text), font: base, mono: mono, color: color))
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Emphasis, code and links within one line of text.
    static func inline(_ text: String, font base: UIFont, mono: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: text, options: options) {
            for run in parsed.runs {
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
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        } else {
            result.append(NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color]))
        }
        return result
    }

    static func monospaced(for font: UIFont) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: font.pointSize * 0.80, weight: .regular))
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
        case text(String)
        case media(MediaReference)
        case table(MarkdownTable)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Splits a message at the pictures and clips it embeds (`![alt](path)`,
    /// or a link straight to an image or video file), and at its tables, so
    /// each shows in place. The alt text is a caption and is dropped; the
    /// rest of the line stays. Web URLs, references and tables inside code
    /// fences stay text.
    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var pending: [String] = []
        func flush() {
            let joined = pending.joined(separator: "\n")
            pending = []
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(.text(joined))
        }
        var inCode = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            guard !inCode else { pending.append(line); continue }
            if let (table, end) = table(lines, at: index - 1) {
                flush()
                segments.append(.table(table))
                index = end
                continue
            }
            let (rest, media) = extractMedia(line)
            guard !media.isEmpty else { pending.append(line); continue }
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { pending.append(rest) }
            flush()
            segments += media.map(Segment.media)
        }
        flush()
        return segments
    }

    private static func extractMedia(_ line: String) -> (String, [MediaReference]) {
        var rest = ""
        var media: [MediaReference] = []
        var index = line.startIndex
        while index < line.endIndex {
            let bang = line[index] == "!"
            let open = bang ? line.index(after: index) : index
            if open < line.endIndex, line[open] == "[",
               let close = line[open...].firstIndex(of: "]"),
               line.index(after: close) < line.endIndex, line[line.index(after: close)] == "(",
               let end = line[close...].firstIndex(of: ")") {
                let target = String(line[line.index(close, offsetBy: 2)..<end])
                if let reference = reference(target) {
                    media.append(reference)
                    index = line.index(after: end)
                    continue
                }
            }
            rest.append(line[index])
            index = line.index(after: index)
        }
        return (rest, media)
    }

    /// A local file path to an image or video, else nil.
    private static func reference(_ target: String) -> MediaReference? {
        var path = target.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("<"), let close = path.firstIndex(of: ">") { path = String(path[path.index(after: path.startIndex)..<close]) }
        else if let space = path.firstIndex(of: " ") { path = String(path[..<space]) }
        if path.hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }
        if path.contains("%") { path = path.removingPercentEncoding ?? path }
        guard !path.isEmpty, !path.contains("://"), !path.hasPrefix("#"), !path.hasPrefix("mailto:") else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { return MediaReference(path: path, video: true) }
        return imageExtensions.contains(ext) ? MediaReference(path: path, video: false) : nil
    }
}

/// A GitHub-style table: its header, how each column aligns, and its rows,
/// as raw cell text (inline Markdown still in it), each as wide as the header.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

extension Markdown {
    /// The table that starts at `lines[start]` and the index of the line
    /// after it: a header row, a delimiter row with as many cells (`---`,
    /// `:--`, `--:`, `:-:`), then every following line with a pipe in it.
    /// Rows with too few cells are padded, extra cells are dropped.
    static func table(_ lines: [String], at start: Int) -> (MarkdownTable, Int)? {
        guard start + 1 < lines.count, hasPipe(lines[start]), hasPipe(lines[start + 1]) else { return nil }
        let header = cells(lines[start])
        let delimiter = cells(lines[start + 1])
        guard !header.isEmpty, header.count == delimiter.count else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in delimiter {
            let dashes = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }), cell.count - dashes.count <= 2 else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        var rows: [[String]] = []
        var end = start + 2
        while end < lines.count, hasPipe(lines[end]) {
            let row = cells(lines[end])
            rows.append(Array((row + Array(repeating: "", count: max(0, header.count - row.count))).prefix(header.count)))
            end += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), end)
    }

    private static func hasPipe(_ line: String) -> Bool {
        var escaped = false
        for character in line {
            if character == "|", !escaped { return true }
            escaped = character == "\\" && !escaped
        }
        return false
    }

    /// A row's cells, trimmed, without its outer pipes; `\|` is a pipe in a cell.
    private static func cells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cell = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            let next = trimmed.index(after: index)
            if character == "\\", next < trimmed.endIndex, trimmed[next] == "|" {
                cell.append("|")
                index = trimmed.index(after: next)
                continue
            }
            if character == "|" { cells.append(cell); cell = "" } else { cell.append(character) }
            index = next
        }
        cells.append(cell)
        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if trimmed.count > 1, trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
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

    static let gap: CGFloat = 18
    static let padding: CGFloat = 8

    init(_ table: MarkdownTable, font: UIFont, color: UIColor, width: CGFloat) {
        available = width
        let mono = Markdown.monospaced(for: font)
        let header = Markdown.bold(font)
        func render(_ text: String, row: Int, column: Int) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = [.leading: .natural, .center: .center, .trailing: .right][table.alignments[column]] ?? .natural
            style.lineSpacing = 2
            let cell = NSMutableAttributedString(attributedString: Markdown.inline(text, font: row == 0 ? header : font, mono: mono,
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
