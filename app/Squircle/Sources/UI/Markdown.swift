import UIKit

/// The subset of Markdown coding agents actually write: paragraphs, headings,
/// lists, fenced code, tables, and inline emphasis, code and links.
enum Markdown {
    static func render(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let mono = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: font.pointSize * 0.80, weight: .regular))
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
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: String(text), options: options) {
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
            result.append(NSAttributedString(string: String(text), attributes: [.font: base, .foregroundColor: color]))
        }
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func bold(_ font: UIFont) -> UIFont {
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
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Splits a message at the pictures and clips it embeds (`![alt](path)`,
    /// or a link straight to an image or video file), so each shows in place.
    /// The alt text is a caption and is dropped; the rest of the line stays.
    /// Web URLs and references inside code fences stay text.
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
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            guard !inCode else { pending.append(line); continue }
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
