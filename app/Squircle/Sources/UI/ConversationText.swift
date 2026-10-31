import UIKit

/// What the conversation's rows say, as attributed text: your messages, the
/// agent's answers and pieces, and worker lines. Messages are rendered once
/// until their source changes; tables are measured once per width and text
/// size.
@MainActor
final class ConversationText {
    private var rendered: [String: (source: AnyHashable, text: NSAttributedString)] = [:]
    private var tableLayouts: [String: (table: MarkdownTable, width: CGFloat, size: UIContentSizeCategory, layout: MarkdownTableLayout)] = [:]

    func message(_ message: ChatMessage, style: MessageCell.Style) -> NSAttributedString {
        let key = message.id + Self.name(style), source = message.markdown.map(AnyHashable.init) ?? AnyHashable(message.content)
        if let cached = rendered[key], cached.source == source { return cached.text }
        let text: NSAttributedString
        switch style {
        case .user:
            // A reply's quote shows over the bubble, not in it.
            text = NSAttributedString(string: Reply.split(message.content).body, attributes: [.font: Theme.Text.body, .foregroundColor: UIColor.label])
        case .note, .thought, .action, .agent:
            text = Markdown.render(markdown(message), font: Theme.Text.line, color: .secondaryLabel)
        case .answer, .received:
            text = Markdown.render(markdown(message), font: Theme.Text.body, color: message.failed ? Theme.failure : .label)
        case .update:
            let font = Theme.Text.line
            let line = NSMutableAttributedString()
            if let symbol = UIImage(systemName: message.symbol.isEmpty ? "arrow.triangle.merge" : message.symbol, withConfiguration: Theme.symbol(font))?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
                line.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
                line.append(NSAttributedString(string: "\t"))
            }
            line.append(NSAttributedString(string: message.content))
            line.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: Self.slotted(font)],
                               range: NSRange(location: 0, length: line.length))
            text = line
        }
        rendered[key] = (source, text)
        return text
    }

    /// Not `"\(style)"`: describing an enum goes through reflection, on every row shown.
    private static func name(_ style: MessageCell.Style) -> String {
        switch style {
        case .user: "user"
        case .answer: "answer"
        case .received: "received"
        case .note: "note"
        case .thought: "thought"
        case .update: "update"
        case .action: "action"
        case .agent: "agent"
        }
    }

    private var cut: [String: (source: AnyHashable, pieces: [ChatMessage])] = [:]

    /// The app agent's answer as received bubbles, one per paragraph
    /// (`Markdown.paragraphs`). While it still streams, its last paragraph
    /// waits: every one before it is final once the next has begun.
    func bubbles(_ message: ChatMessage) -> [ChatMessage] {
        let source: AnyHashable = [message.markdown.map(AnyHashable.init) ?? AnyHashable(message.content), AnyHashable(message.isStreaming)]
        if let cached = cut[message.id], cached.source == source { return cached.pieces }
        var paragraphs = Markdown.paragraphs(markdown(message))
        if message.isStreaming { paragraphs.removeLast(min(1, paragraphs.count)) }
        let pieces = paragraphs.enumerated().map { index, paragraph in
            var piece = message
            // The first keeps the message's identity.
            if index > 0 { piece.id = message.id + "¶\(index)" }
            piece.content = String(paragraph.characters)
            piece.markdown = paragraph
            return piece
        }
        cut[message.id] = (source, pieces)
        return pieces
    }

    private func markdown(_ message: ChatMessage) -> AttributedString {
        message.markdown ?? Markdown.parse(message.content)
    }

    func table(_ id: String, _ markdown: MarkdownTable, quiet: Bool, width: CGFloat, size: UIContentSizeCategory) -> MarkdownTableLayout {
        if let cached = tableLayouts[id], cached.table == markdown, cached.width == width, cached.size == size { return cached.layout }
        let layout = MarkdownTableLayout(markdown, font: quiet ? Theme.Text.line : Theme.Text.body,
                                         color: quiet ? .secondaryLabel : .label, width: width)
        tableLayouts[id] = (markdown, width, size, layout)
        return layout
    }

    /// "Task from Squircle agent" (`from` names the sender) over the task.
    func agent(_ message: ChatMessage, from: String?) -> NSAttributedString {
        let task = message.agent?.kind == .task
        let label = message.agent == nil ? "" : (task ? "Task from " : "From ") + (from ?? (task ? "the app’s agent" : "an agent"))
        let key = message.id + "agent", source: AnyHashable = [label, message.markdown.map(AnyHashable.init) ?? AnyHashable(message.content)]
        if let cached = rendered[key], cached.source == source { return cached.text }
        let body = Markdown.render(markdown(message), font: Theme.Text.line, color: .label)
        guard !label.isEmpty else { rendered[key] = (source, body); return body }
        let font = Theme.Text.caption
        let text = NSMutableAttributedString()
        if let symbol = UIImage(systemName: task ? "list.bullet.rectangle" : "arrow.down.message",
                                withConfiguration: Theme.symbol(font))?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: label + "\n"))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Theme.Space.tight
        text.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style],
                           range: NSRange(location: 0, length: text.length))
        text.append(body)
        rendered[key] = (source, text)
        return text
    }

    /// A line's glyph in the slot, its text at the slot's end, and wrapped
    /// lines hanging under the text, not the glyph.
    private static func slotted(_ font: UIFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .natural, location: Theme.Space.indent)]
        style.headIndent = Theme.Space.indent
        style.paragraphSpacing = Theme.Space.tight
        // Every line keeps the font's height: a jelly never pushes the lines apart (its row reserves its room).
        style.minimumLineHeight = ceil(font.lineHeight)
        style.maximumLineHeight = ceil(font.lineHeight)
        return style
    }

    /// The state a worker line shows its jelly in: what the news said, or
    /// the worker's live state.
    private static func workerMood(_ line: ActionLine) -> JellyLook.Mood? {
        if case .news(let news) = line.kind { return JellyLook.Mood(news) }
        return line.state.map(JellyLook.Mood.init)
    }

    /// "Started worker · Dark mode  working", with the worker's live state.
    static func action(_ line: ActionLine, expanded: Bool, traits: UITraitCollection) -> NSAttributedString {
        let font = Theme.Text.line, bold = Theme.Text.lineStrong
        let name = line.name ?? "a worker"
        let text = NSMutableAttributedString()
        func add(_ string: String, _ font: UIFont, _ color: UIColor = .label) {
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        let symbol: String
        var state: (String, UIColor)?
        switch line.kind {
        case .news(let news):
            symbol = news == .needsYou ? "questionmark.bubble" : news == .error ? "exclamationmark.bubble" : "checkmark.bubble"
            add("From ", bold); add(name, font)
            state = news == .needsYou ? ("needs you", Theme.warning) : news == .error ? ("stopped with an error", Theme.failure) : ("finished", Theme.success)
        case .build(let news):
            symbol = news.succeeded ? "shippingbox" : "xmark.octagon"
            add("From ", bold); add("Squircle · " + news.app + " build", font)
            state = news.succeeded ? ("ready", Theme.success) : ("failed", Theme.failure)
        case .action(let action) where action.isTracker:
            // Changes to your tasks and the agent's notes: the verb in
            // Line strong, each task's status word in its colour.
            symbol = action.symbol
            for (index, piece) in action.phrase({ line.taskNames[$0] }).enumerated() {
                let space = index == 0 ? "" : " "
                switch piece.role {
                case .verb: add(space + piece.text, bold)
                case .plain: add(space + piece.text, font, .secondaryLabel)
                case .subject: add(space + piece.text, font)
                case .quiet: add(space + piece.text, font, .secondaryLabel)
                case .status(let raw):
                    let status = AppTask.Status(rawValue: raw)
                    add(space + piece.text, bold, status.map(WorkItemPage.color) ?? .secondaryLabel)
                }
            }
        case .action(let action):
            symbol = action.symbol
            switch action.kind {
            case .spawn:
                add(action.verb, bold); add(" · " + name, font)
                if let live = line.state {
                    let colors: [WorkerState: UIColor] = [.working: Theme.working, .done: Theme.success, .needsYou: Theme.warning, .error: Theme.failure]
                    state = (live.word, colors[live] ?? .tertiaryLabel)
                }
            case .send, .answer:
                add(action.verb + " ", bold); add(name, font)
                if let message = action.text?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty, !expanded {
                    let first = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
                    add(" · " + first, font, .secondaryLabel)
                }
            case .read: add("Read ", bold); add(name + "’s reply", font)
            case .archive: add("Archived ", bold); add(name, font)
            case .buildStart:
                add(action.verb, bold); if let app = action.app { add(" of ", bold); add(app, font) }
                switch line.buildStatus {
                case "queued"?: state = ("queued", .tertiaryLabel)
                case "running"?: state = ("building", Theme.working)
                case "succeeded"?: state = ("ready", Theme.success)
                case "failed"?: state = ("failed", Theme.failure)
                case "cancelled"?, "interrupted"?: state = ("stopped", .tertiaryLabel)
                default: break
                }
            default: add(action.verb, bold)
            }
        }
        if line.failed { state = ("failed", Theme.failure) }
        if let (word, color) = state { add("  " + word, font, color) }
        if case .build(let news) = line.kind, !news.succeeded, let reason = news.reason, !reason.isEmpty {
            add("\n" + reason, font, .secondaryLabel)
        }
        // A line about a worker leads with the worker itself: its jelly, in
        // the state it is in now (a still; the Tasks row is where it moves).
        if let worker = line.thread?.raw, let mood = workerMood(line),
           let attachment = JellyAttachment.make(.worker(worker, mood), size: Theme.Glyph.line, font: font, traits: traits) {
            text.insert(NSAttributedString(string: "\t", attributes: [.font: font]), at: 0)
            text.insert(NSAttributedString(attachment: attachment), at: 0)
        } else if let symbol = UIImage(systemName: line.failed ? "exclamationmark" : symbol, withConfiguration: Theme.symbol(font))?
            .withTintColor(line.failed ? Theme.failure : line.running ? Theme.working : .secondaryLabel,
                           renderingMode: .alwaysOriginal) {
            text.insert(NSAttributedString(string: "\t", attributes: [.font: font]), at: 0)
            text.insert(NSAttributedString(attachment: NSTextAttachment(image: symbol)), at: 0)
        }
        text.addAttribute(.paragraphStyle, value: Self.slotted(font), range: NSRange(location: 0, length: text.length))
        if expanded, let message = line.text?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            add("\n", font)
            text.append(Markdown.render(message, font: Theme.Text.line, color: .secondaryLabel))
        }
        return text
    }
}
