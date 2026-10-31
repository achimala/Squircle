import Foundation

/// A reply to one message, the WhatsApp way. The agent gets the quoted words
/// as a Markdown blockquote before yours (no T3 changes), and your message
/// shows them above its bubble, read back from that same text.
enum Reply {
    /// The longest quote, in characters, before it is cut with an ellipsis.
    static let limit = 160

    /// What a message says, as one short line to quote.
    static func quote(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        // At a word when there is one near the end.
        let word = cut.lastIndex(of: " ").map { cut[..<$0] }.flatMap { $0.count > limit * 2 / 3 ? $0 : nil } ?? cut
        return word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    /// What is sent: the quote as a blockquote, then your words.
    static func compose(quote: String, text: String) -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "> " + quote + (words.isEmpty ? "" : "\n\n" + words)
    }

    /// A sent message's quote and your words after it; nil quote when it
    /// starts with no blockquote.
    static func split(_ content: String) -> (quote: String?, body: String) {
        guard content.hasPrefix(">") else { return (nil, content) }
        var quoted: [Substring] = []
        var rest = content[...]
        while let line = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first, line.hasPrefix(">") {
            quoted.append(line.dropFirst().drop { $0 == " " })
            rest = rest.dropFirst(line.count)
            guard rest.first == "\n" else { break }
            rest = rest.dropFirst()
        }
        let quote = quoted.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !quote.isEmpty else { return (nil, content) }
        return (quote, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether `text` is what `quote` was cut from.
    static func matches(_ quote: String, _ text: String) -> Bool {
        var stem = quote
        if stem.hasSuffix("…") { stem.removeLast() }
        guard !stem.isEmpty else { return false }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ").hasPrefix(stem)
    }
}
