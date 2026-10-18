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
        let key = message.id + "\(style)", source = message.markdown.map(AnyHashable.init) ?? AnyHashable(message.content)
        if let cached = rendered[key], cached.source == source { return cached.text }
        let text: NSAttributedString
        switch style {
        case .user:
            text = NSAttributedString(string: message.content, attributes: [.font: Theme.font(.body, 17), .foregroundColor: UIColor.label])
        case .note, .thought, .action, .agent:
            text = Markdown.render(markdown(message), font: Theme.font(.subheadline, 15), color: .secondaryLabel)
        case .answer:
            text = Markdown.render(markdown(message), font: Theme.font(.body, 17), color: message.failed ? Theme.failure : .label)
        case .update:
            let font = Theme.font(.footnote, 13, .medium)
            let line = NSMutableAttributedString()
            if let symbol = UIImage(systemName: message.symbol.isEmpty ? "arrow.triangle.merge" : message.symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
                line.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
                line.append(NSAttributedString(string: "  "))
            }
            line.append(NSAttributedString(string: message.content))
            line.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel], range: NSRange(location: 0, length: line.length))
            text = line
        }
        rendered[key] = (source, text)
        return text
    }

    private func markdown(_ message: ChatMessage) -> AttributedString {
        message.markdown ?? Markdown.parse(message.content)
    }

    func table(_ id: String, _ markdown: MarkdownTable, quiet: Bool, width: CGFloat, size: UIContentSizeCategory) -> MarkdownTableLayout {
        if let cached = tableLayouts[id], cached.table == markdown, cached.width == width, cached.size == size { return cached.layout }
        let layout = MarkdownTableLayout(markdown, font: quiet ? Theme.font(.subheadline, 15) : Theme.font(.body, 17),
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
        let body = Markdown.render(markdown(message), font: Theme.font(.subheadline, 15), color: .label)
        guard !label.isEmpty else { rendered[key] = (source, body); return body }
        let font = Theme.font(.footnote, 13, .semibold)
        let text = NSMutableAttributedString()
        if let symbol = UIImage(systemName: task ? "list.bullet.rectangle" : "arrow.down.message",
                                withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: label + "\n"))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        text.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style],
                           range: NSRange(location: 0, length: text.length))
        text.append(body)
        rendered[key] = (source, text)
        return text
    }

    private static let lineJelly = JellyCanvas.tight(20)

    /// The state a worker line shows its jelly in: what the news said, or
    /// the worker's live state.
    private static func workerMood(_ line: ActionLine) -> JellyLook.Mood? {
        if case .news(let news) = line.kind { return JellyLook.Mood(news) }
        return line.state.map(JellyLook.Mood.init)
    }

    /// "Started worker · Dark mode  working", with the worker's live state.
    static func action(_ line: ActionLine, expanded: Bool, traits: UITraitCollection) -> NSAttributedString {
        let font = Theme.font(.subheadline, 15), bold = Theme.font(.subheadline, 15, .semibold)
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
        case .action(let action):
            symbol = action.symbol
            switch action.kind {
            case .spawn:
                add(action.verb, bold); add(" · " + name, font)
                if let live = line.state {
                    let colors: [WorkerState: UIColor] = [.working: Theme.accent, .done: Theme.success, .needsYou: Theme.warning, .error: Theme.failure]
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
                add(action.verb, bold); if let app = action.app { add(" · " + app, font) }
                switch line.buildStatus {
                case "queued"?: state = ("queued", .tertiaryLabel)
                case "running"?: state = ("building", Theme.accent)
                case "succeeded"?: state = ("ready", Theme.success)
                case "failed"?: state = ("failed", Theme.failure)
                case "cancelled"?, "interrupted"?: state = ("stopped", .tertiaryLabel)
                default: break
                }
            default: add(action.verb, bold)
            }
        }
        if line.failed { state = ("failed", Theme.failure) }
        if let (word, color) = state { add("  " + word, Theme.font(.footnote, 13, .medium), color) }
        if case .build(let news) = line.kind, !news.succeeded, let reason = news.reason, !reason.isEmpty {
            add("\n" + reason, Theme.font(.footnote, 13), .secondaryLabel)
        }
        // A line about a worker leads with the worker itself: its jelly, in
        // the state it is in now (a still; the Tasks row is where it moves).
        var lead: CGFloat = 27
        if let worker = line.thread?.raw, let mood = workerMood(line),
           let image = JellySprites.shared.image(.worker(worker, mood), Self.lineJelly, traits: traits) {
            let attachment = NSTextAttachment(image: image)
            let size = image.size, body = Self.lineJelly.body
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - Self.lineJelly.size) / 2 - (size.height - body.maxY), width: size.width, height: size.height)
            text.insert(NSAttributedString(string: " ", attributes: [.font: font]), at: 0)
            text.insert(NSAttributedString(attachment: attachment), at: 0)
            lead = size.width + 4
        } else if let symbol = UIImage(systemName: line.failed ? "exclamationmark" : symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.footnote, 13, .medium)))?
            .withTintColor(line.failed ? Theme.failure : line.running ? Theme.accent : .secondaryLabel, renderingMode: .alwaysOriginal) {
            text.insert(NSAttributedString(string: "  ", attributes: [.font: font]), at: 0)
            text.insert(NSAttributedString(attachment: NSTextAttachment(image: symbol)), at: 0)
        }
        // Wrapped lines start under the text, not the icon.
        let hanging = NSMutableParagraphStyle()
        hanging.headIndent = lead
        hanging.paragraphSpacing = 4
        text.addAttribute(.paragraphStyle, value: hanging, range: NSRange(location: 0, length: text.length))
        if expanded, let message = line.text?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            add("\n", font)
            text.append(Markdown.render(message, font: Theme.font(.subheadline, 15), color: .secondaryLabel))
        }
        return text
    }
}
