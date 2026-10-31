import UIKit

/// Answering what waits on you, wherever it shows (the chat where it was
/// asked, the Tasks sheet under its task, Home): questions agents put in
/// the tracker, workers' own questions and approvals (answered straight to
/// the worker), and needs-you tasks. What you've answered so far lives in
/// the model's `QuestionAnswers`, shared with the thread's request card; an
/// answered one leaves every list at once.
@MainActor
final class WaitingAnswers {
    private let model: SquircleModel
    private var drafts: QuestionAnswers { model.questionAnswers }

    init(model: SquircleModel) { self.model = model }

    /// Draws `item` into `view`. `about`: say which task it's for (where
    /// that isn't right above it), after `app`'s name when given (Home);
    /// otherwise only who asks. `changed` runs when a request with several
    /// questions moves to its next one in place.
    func configure(_ view: WaitingItemView, _ item: WaitingList.Item, about: Bool, app: String? = nil, changed: @escaping () -> Void = {}) {
        let id = item.id
        view.itemID = id
        let busy = model.answering.contains(id)
        switch item {
        case .question(let question):
            let asker = question.from ?? (about ? nil : "Your agent asks")
            let context = ((about ? [app] : []) + [asker] + (about ? [question.task] : [])).compactMap { $0 }.joined(separator: " · ")
            let jelly = question.from == nil ? JellyLook.agent(.needsYou) : .worker(question.threadID ?? "", .needsYou)
            view.show(context: context, asker: jelly, question: question.text, detail: nil)
            attach(question, to: view)
            view.answers(question.options.map { WaitingItemView.Answer(title: $0) }, busy: busy) { [weak self] index in
                self?.send(question, question.options[index])
            }
            view.reply(placeholder: "Something else…", text: drafts[id].text, busy: busy,
                       edit: { [weak self] text in self?.drafts[id].text = text }) { [weak self] text in self?.send(question, text) }
        case .request(let request):
            let context = (about ? [app, request.title, request.task] : [request.worker ? request.title : "Your agent asks"])
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let jelly = request.worker ? JellyLook.worker(request.threadID, .needsYou) : .agent(.needsYou)
            view.media([], task: "", documents: model.documents) { _, _ in nil }
            if request.pending.isQuestion {
                questions(view, request.pending, context: { _ in context }, jelly: jelly, busy: busy, changed: { if $0 { changed() } }) { [weak self] answers in
                    guard let self else { return }
                    Task { await self.model.respond(request, answers: answers) }
                }
            } else {
                approval(view, request.pending, context: context, jelly: jelly, busy: busy) { [weak self] decision in
                    guard let self else { return }
                    Task { await self.model.respond(request, decision: decision) }
                }
            }
        }
    }

    /// The open conversation's own request, in its request card: `asker`
    /// heads it, with the question's own header. Answers go to the
    /// conversation's thread; `changed(advanced)` runs when a step redraws
    /// it, `advanced` when it moved on to the next question.
    func configure(_ view: WaitingItemView, open request: PendingRequest, asker: String, jelly: JellyLook, changed: @escaping (Bool) -> Void) {
        view.itemID = QuestionAnswers.key(request: request.id)
        let busy = model.sending(request)
        if request.isQuestion {
            let context = { (form: QuestionForm) in [asker, form.question["header"].string].compactMap { $0 }.joined(separator: " · ") }
            questions(view, request, context: context, jelly: jelly, busy: busy, changed: changed) { [weak self] answers in
                guard let self else { return }
                Task { await self.model.respond(to: request, answers: answers) }
            }
        } else {
            approval(view, request, context: asker, jelly: jelly, busy: busy) { [weak self] decision in
                guard let self else { return }
                Task { await self.model.respond(to: request, decision: decision) }
            }
        }
    }

    /// An approval: its choices as rows, each sending its decision.
    private func approval(_ view: WaitingItemView, _ request: PendingRequest, context: String, jelly: JellyLook, busy: Bool,
                          decide: @escaping (String) -> Void) {
        view.show(context: context, asker: jelly, question: request.title, detail: request.prompt)
        let choices = WaitingItemView.decisions(request)
        view.answers(choices.map(\.answer), busy: busy) { index in
            Theme.selectionHaptic()
            decide(choices[index].decision)
        }
        view.reply(placeholder: nil, text: "", busy: busy, edit: { _ in }) { _ in }
    }

    /// A thread's questions one at a time, from the shared draft; the last
    /// answer sends them all.
    private func questions(_ view: WaitingItemView, _ request: PendingRequest, context: @escaping (QuestionForm) -> String, jelly: JellyLook,
                           busy: Bool, changed: @escaping (Bool) -> Void, send: @escaping ([String: JSONValue]) -> Void) {
        let id = QuestionAnswers.key(request: request.id)
        let form = QuestionForm(questions: request.questions, draft: drafts[id])
        view.show(context: context(form), asker: jelly, question: WaitingItemView.title(form), detail: nil)
        // Each tap reads the draft as it is then (typing changes it in between).
        let step: ((QuestionForm) -> QuestionForm.Step) -> Void = { [weak self, weak view] make in
            guard let self else { return }
            let now = QuestionForm(questions: request.questions, draft: drafts[id])
            Theme.selectionHaptic()
            switch make(now) {
            case .edit(let draft):
                drafts[id] = draft
                if let view, view.itemID == id {
                    questions(view, request, context: context, jelly: jelly, busy: busy, changed: changed, send: send)
                    changed(draft.answers.count != now.draft.answers.count)
                }
            case .send(let answers):
                send(answers)
            }
        }
        view.form(form, busy: busy) { index in step { index < form.options.count ? $0.choose(index) : $0.confirm() } }
        view.reply(placeholder: "Something else…", text: form.draft.text, busy: busy,
                   edit: { [weak self] text in self?.drafts[id].text = text }) { text in step { $0.reply(text) } }
    }

    /// The question's pictures and clips, opened large from their thumbnails
    /// and paged sideways; its documents in Quick Look.
    private func attach(_ question: WaitingList.Question, to view: WaitingItemView) {
        let task = question.taskID, documents = model.documents
        view.media(question.media, task: task, documents: documents) { [weak model] media, height in
            await model?.taskThumbnail(task: task, media: media, height: height)
        }
        view.onOpen = { [weak self, weak view] index in
            guard let self, let view, let window = view.window else { return }
            let items = view.pictures.map { tile, media in
                ViewerItem.task(media, of: task, poster: tile.image(for: .normal), origin: MediaOrigin { [weak tile] in tile.map { MediaSpot($0) } },
                                model: self.model)
            }
            MediaViewer.open(items, at: index, in: window)
        }
        view.onDocument = { row in
            var responder = row.next
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard let presenter = responder as? UIViewController else { return }
            DocumentViewer.open(row, documents: documents, from: presenter)
        }
    }

    private func send(_ question: WaitingList.Question, _ text: String) {
        Theme.selectionHaptic()
        Task { await model.answer(question, text: text) }
    }

}

/// The question card, the same in the chat, in Tasks and on Home (and,
/// without its fill, in the thread's request card over the field): a
/// received bubble from whoever asks. Who asks on one Caption line led by
/// their jelly in the glyph slot, the question in Body, then the answers as
/// a list of rows: a mark in the slot (a circle to pick one, a square to
/// pick several, filled when picked), the label wrapping as long as it
/// needs, its description under it, and a last row to write something
/// else. Several picks go with Send. What the question is about (pictures
/// and clips, documents) sits between the question and the answers: a row
/// of thumbnails, then a line per document. `compact` (Tasks' Needs you)
/// and `deck` (Home): the question in three lines, a short strip of
/// thumbnails, no documents and the command in three lines; the deck has no
/// write-in row and its strip only clips.
final class WaitingItemView: UIView {
    enum Size { case full, compact, deck }

    struct Answer {
        var title: String
        var detail: String?
        /// Nil: tapping it answers. Otherwise one of several, picked or not.
        var picked: Bool?
    }

    /// The item drawn, so a late redraw never lands on a reused view.
    var itemID: String?
    private let size: Size
    private var compact: Bool { size != .full }
    private let filled: Bool
    /// Who asks and the question, above the answers.
    let head = UIStackView()
    private let context = Theme.label("", Theme.Text.caption, color: .secondaryLabel)
    private let jelly = JellyView(.agent(.needsYou), canvas: .roomy(Theme.Glyph.line))
    private let jellySlot = UIView()
    private let title = Theme.label("", Theme.Text.body, lines: 0)
    private let detail = Theme.label("", Theme.Text.mono, color: .secondaryLabel, lines: 6)
    private let rows = UIStackView()
    private let send = Theme.glassButton(title: "Send", prominent: true, identifier: "waiting.send")
    private let field = UITextField()
    private let fieldRow = UIView()
    private var onChoose: ((Int) -> Void)?
    private var onSend: ((String) -> Void)?
    private var onEdit: ((String) -> Void)?
    private var sendIndex = 0
    /// Tapped the picture or clip at this index of `pictures`.
    var onOpen: ((Int) -> Void)?
    var onDocument: ((FileRowView) -> Void)?
    /// Each picture's or clip's thumbnail, and what it shows.
    private(set) var pictures: [(tile: UIButton, media: AppTask.Media)] = []
    private let strip = UIScrollView()
    private let tiles = UIStackView()
    private let files = UIStackView()
    private var shownMedia: (task: String, media: [AppTask.Media])?
    private var loads: [Task<Void, Never>] = []
    private var tileHeight: CGFloat { compact ? Theme.Thumb.row.height : Theme.Thumb.page.height }

    /// `filled` false: no bubble of its own (the request card's glass is its surface).
    init(_ size: Size = .full, filled: Bool = true) {
        self.size = size
        self.filled = filled
        super.init(frame: .zero)
        title.numberOfLines = compact ? 3 : 0
        detail.numberOfLines = compact ? 3 : 6
        if filled {
            backgroundColor = Theme.receivedFill
            layer.cornerRadius = Theme.Radius.large
            layer.cornerCurve = .continuous
        }
        context.lineBreakMode = .byTruncatingTail
        // The jelly's body centred on the words' cap height, not their frame.
        let slot = jellySlot
        slot.addSubview(jelly)
        jelly.translatesAutoresizingMaskIntoConstraints = false
        let about = UIStackView(arrangedSubviews: [slot, context])
        about.spacing = Theme.Space.glyphGap
        about.alignment = .fill
        NSLayoutConstraint.activate([slot.widthAnchor.constraint(equalToConstant: Theme.Glyph.line),
                                     jelly.widthAnchor.constraint(equalToConstant: Theme.Glyph.line),
                                     jelly.heightAnchor.constraint(equalToConstant: Theme.Glyph.line),
                                     jelly.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                                     context.centred(on: jelly.centerYAnchor)])
        rows.axis = .vertical

        field.font = Theme.Text.body
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .send
        field.accessibilityIdentifier = "waiting.reply"
        field.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let text = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            field.resignFirstResponder()
            onSend?(text)
        }, for: .editingDidEndOnExit)
        field.addAction(UIAction { [weak self] _ in self?.onEdit?(self?.field.text ?? "") }, for: .editingChanged)
        // Always in place (only hidden), so a redraw never takes the keyboard away.
        let pencil = OptionRow.mark("pencil", color: .tertiaryLabel)
        let rule = OptionRow.rule()
        [rule, pencil, field].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; fieldRow.addSubview($0) }
        fieldRow.isHidden = true
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: fieldRow.topAnchor),
            rule.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor), rule.trailingAnchor.constraint(equalTo: fieldRow.trailingAnchor),
            fieldRow.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            pencil.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor), pencil.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            pencil.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: pencil.trailingAnchor, constant: Theme.Space.glyphGap),
            field.trailingAnchor.constraint(equalTo: fieldRow.trailingAnchor),
            field.topAnchor.constraint(equalTo: fieldRow.topAnchor, constant: Theme.Space.rowPad),
            field.bottomAnchor.constraint(equalTo: fieldRow.bottomAnchor, constant: -Theme.Space.rowPad)
        ])

        send.addAction(UIAction { [weak self] _ in guard let self else { return }; onChoose?(sendIndex) }, for: .touchUpInside)
        let sendRow = UIStackView(arrangedSubviews: [UIView(), send])
        sendRow.isLayoutMarginsRelativeArrangement = true
        sendRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.row, leading: 0, bottom: Theme.Space.tight, trailing: 0)
        sendRow.isHidden = true

        tiles.spacing = Theme.Space.row
        tiles.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(tiles)
        strip.showsHorizontalScrollIndicator = false
        // On Home a sideways swipe is the deck's: the strip only clips.
        strip.isScrollEnabled = size != .deck
        strip.isHidden = true
        NSLayoutConstraint.activate([
            tiles.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            tiles.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            tiles.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor),
            tiles.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor),
            tiles.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor),
            strip.heightAnchor.constraint(equalToConstant: tileHeight)
        ])
        files.axis = .vertical
        files.isHidden = true

        [about, title].forEach(head.addArrangedSubview)
        head.axis = .vertical
        head.spacing = Theme.Space.tight
        let stack = UIStackView(arrangedSubviews: [head, strip, files, detail, rows, fieldRow, sendRow])
        stack.axis = .vertical
        stack.spacing = Theme.Space.row
        stack.setCustomSpacing(0, after: rows)
        stack.setCustomSpacing(0, after: fieldRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset = filled ? Theme.Space.card : .zero
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Who asks (`asker`: their jelly) and the question; `detail`, an
    /// approval's command, in Mono under it.
    func show(context text: String, asker: JellyLook?, question: String, detail more: String?) {
        context.text = text
        context.isHidden = text.isEmpty
        if let asker { jelly.look = asker }
        jellySlot.isHidden = asker == nil
        context.superview?.isHidden = context.isHidden && jellySlot.isHidden
        title.text = question
        detail.text = more
        // Home keeps to who asks and the question.
        detail.isHidden = size == .deck || (more ?? "").isEmpty
    }

    /// What the question is about, attached to `task`: pictures and clips as
    /// thumbnails (`thumbnail` loads one at a height), documents as lines.
    /// Drawn again only when they change.
    func media(_ media: [AppTask.Media], task: String, documents: DocumentFiles,
               thumbnail: @escaping (AppTask.Media, CGFloat) async -> UIImage?) {
        if let shownMedia, shownMedia.task == task, shownMedia.media == media { return }
        shownMedia = (task, media)
        loads.forEach { $0.cancel() }
        loads = []
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        files.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pictures = media.filter { $0.kind == "image" || $0.kind == "video" }.enumerated().map { index, item in
            (tile(item, index: index, thumbnail: thumbnail), item)
        }
        pictures.forEach { tiles.addArrangedSubview($0.tile) }
        strip.isHidden = pictures.isEmpty
        strip.contentOffset = .zero
        for item in media where item.kind == "file" && !compact {
            let row = FileRowView()
            // Inside the card, on the page's fill.
            row.surfaceColor = Theme.paper
            row.show(.attached(task: task, media: item.id, name: item.name ?? "Document", bytes: item.bytes.map { Int($0) }), documents: documents)
            row.onOpen = { [weak self] row in self?.onDocument?(row) }
            files.addArrangedSubview(row)
        }
        files.isHidden = files.arrangedSubviews.isEmpty
    }

    /// A picture or clip at the strip's height, a phone screen's shape until
    /// its thumbnail gives it its own; a clip carries a play mark.
    private func tile(_ media: AppTask.Media, index: Int, thumbnail: @escaping (AppTask.Media, CGFloat) async -> UIImage?) -> UIButton {
        let height = tileHeight
        let tile = UIButton(type: .custom)
        tile.backgroundColor = Theme.codeFill
        tile.layer.cornerRadius = compact ? Theme.Thumb.rowRadius : Theme.Radius.small
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        tile.imageView?.contentMode = .scaleAspectFill
        tile.contentHorizontalAlignment = .fill
        tile.contentVerticalAlignment = .fill
        let width = tile.widthAnchor.constraint(equalToConstant: (height * 0.46).rounded())
        width.isActive = true
        if media.kind == "video" {
            let play = UIImageView(image: UIImage(systemName: "play.fill"))
            play.tintColor = .white
            play.preferredSymbolConfiguration = Theme.symbol(compact ? Theme.Text.caption : Theme.Text.body)
            play.layer.shadowOpacity = 0.4
            play.layer.shadowRadius = 6
            play.layer.shadowOffset = .zero
            play.isUserInteractionEnabled = false
            play.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(play)
            NSLayoutConstraint.activate([play.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                                         play.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        }
        tile.accessibilityLabel = media.caption.isEmpty ? (media.kind == "video" ? "Clip" : "Picture") : media.caption
        tile.accessibilityIdentifier = "waiting.media"
        tile.addAction(UIAction { [weak self] _ in self?.onOpen?(index) }, for: .touchUpInside)
        loads.append(Task { [weak tile] in
            guard let image = await thumbnail(media, height), !Task.isCancelled, let tile, image.size.height > 0 else { return }
            width.constant = (height * min(max(image.size.width / image.size.height, 0.4), 1.8)).rounded()
            tile.setImage(image, for: .normal)
        })
        return tile
    }

    /// The answers as rows; `send`: Send's title and whether it can be
    /// tapped, for picks of several (its index is after the answers').
    func answers(_ answers: [Answer], busy: Bool, send: (title: String, enabled: Bool)? = nil, choose: @escaping (Int) -> Void) {
        onChoose = choose
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, answer) in answers.enumerated() {
            let row = OptionRow(answer)
            row.isEnabled = !busy
            row.addAction(UIAction { [weak self] _ in self?.onChoose?(index) }, for: .touchUpInside)
            rows.addArrangedSubview(OptionRow.rule())
            rows.addArrangedSubview(row)
        }
        sendIndex = answers.count
        self.send.configuration?.title = send?.title ?? "Send"
        self.send.isEnabled = !busy && send?.enabled == true
        self.send.superview?.isHidden = send == nil
        rows.isHidden = answers.isEmpty
    }

    /// One of a thread's questions as `QuestionForm` has it.
    func form(_ form: QuestionForm, busy: Bool, choose: @escaping (Int) -> Void) {
        let several = form.multiple
        answers(form.options.map { Answer(title: $0.label, detail: $0.detail, picked: several ? $0.picked : nil) }, busy: busy,
                send: several ? (form.isLast ? "Send" : "Next", form.canConfirm) : nil, choose: choose)
    }

    /// The write-in row, last, showing `text`; none without a placeholder,
    /// and never in the deck. `edit` gets each change.
    func reply(placeholder: String?, text: String, busy: Bool, edit: @escaping (String) -> Void, send: @escaping (String) -> Void) {
        onSend = send
        onEdit = edit
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        field.isEnabled = !busy
        fieldRow.isHidden = size == .deck || placeholder == nil
    }

    /// Where Waiting on you took you.
    func mark() { layer.markSpot(in: traitCollection) }

    /// "2 of 3 · Which…" for a thread's question among several.
    static func title(_ form: QuestionForm) -> String {
        let text = form.question["question"].string ?? "A question for you"
        return form.questions.count > 1 ? "\(form.index + 1) of \(form.questions.count) · " + text : text
    }

    /// An approval's choices as rows, each with the decision it sends.
    static func decisions(_ request: PendingRequest) -> [(answer: Answer, decision: String)] {
        guard !request.options.isEmpty else { return [(Answer(title: "Allow"), "accept"), (Answer(title: "Decline"), "decline")] }
        return request.options.compactMap { option in
            option["decision"].string.map { (Answer(title: option["label"].string ?? "Choose", detail: option["warning"].string), $0) }
        }
    }
}

/// One answer: its mark in the glyph slot, its label in Body wrapping as
/// long as it needs, its description in Line, and "Recommended" as a
/// Caption tag in the accent when the asker said so. At least 44 tall.
private final class OptionRow: UIControl {
    static func rule() -> UIView {
        let rule = UIView()
        rule.backgroundColor = .separator
        rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return rule
    }

    /// A mark in Body, centred in the glyph slot.
    static func mark(_ symbol: String, color: UIColor) -> UIImageView {
        let mark = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Theme.symbol(Theme.Text.body)))
        mark.tintColor = color
        mark.contentMode = .center
        return mark
    }

    init(_ answer: WaitingItemView.Answer) {
        super.init(frame: .zero)
        var text = answer.title
        let recommended = text.range(of: "(Recommended)", options: [.caseInsensitive])
        if let recommended { text.removeSubrange(recommended); text = text.trimmingCharacters(in: .whitespaces) }
        let mark = Self.mark(answer.picked == true ? "checkmark.square.fill" : answer.picked == false ? "square" : "circle",
                             color: answer.picked == true ? Theme.accent : .tertiaryLabel)
        let label = Theme.label(text, Theme.Text.body, lines: 0)
        let lines = UIStackView(arrangedSubviews: [label])
        lines.axis = .vertical
        lines.spacing = Theme.Space.tight
        if let detail = answer.detail, !detail.isEmpty {
            lines.addArrangedSubview(Theme.label(detail, Theme.Text.line, color: .secondaryLabel, lines: 0))
        }
        if recommended != nil { lines.addArrangedSubview(Theme.label("Recommended", Theme.Text.caption, color: Theme.accent)) }
        [mark, lines].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.isUserInteractionEnabled = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.tap),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor), mark.widthAnchor.constraint(equalToConstant: Theme.Space.glyph),
            mark.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -Theme.Text.body.capHeight / 2),
            lines.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: Theme.Space.glyphGap),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.rowPad),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.rowPad)
        ])
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityHint = answer.detail
        accessibilityTraits = answer.picked == true ? [.button, .selected] : .button
        accessibilityIdentifier = "waiting.option.\(text)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? Theme.pressedFill : .clear } }
    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.5 } }
}

/// A question or request under its task in the Tasks overview, lined up
/// with the task's text.
final class WaitingCell: UITableViewCell {
    let item = WaitingItemView(.compact)
    private let rule = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = Theme.pressedFill
        selectedBackgroundView = selected
        rule.backgroundColor = .separator
        [item, rule].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            item.topAnchor.constraint(equalTo: contentView.topAnchor),
            item.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Space.rowPad),
            item.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.text),
            item.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.margin),
            rule.leadingAnchor.constraint(equalTo: item.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `last`: the task's last one, ruled off from the next task.
    func setLast(_ last: Bool) { rule.isHidden = !last }
}

/// Everything waiting on you across apps, at the top of Home above the
/// devices: one question or approval at a time, the next a swipe sideways
/// under the finger (native paging), answerable in place. It keeps the
/// tallest one's height however many wait, so the devices stay put.
/// Tapping a question's text opens the conversation that asked it, at the
/// spot.
@MainActor
final class HomeWaitingView: UIView, UIScrollViewDelegate {
    /// Opens the thread that asked, where it asked.
    var onJump: ((_ project: String, _ item: WaitingList.Item) -> Void)?
    /// Its height changed (a request moved on to its next question).
    var onResize: (() -> Void)?
    private let answers: WaitingAnswers
    private let heading = Theme.label("Waiting on you", Theme.Text.caption, color: .secondaryLabel)
    private let count = Theme.label("", Theme.Text.caption, color: .tertiaryLabel)
    private let pages = UIScrollView()
    private var cards: [(id: String, view: HomeWaitingCard)] = []
    private var shown: (list: [(project: String, item: WaitingList.Item)], busy: Set<String>)?

    init(model: SquircleModel) {
        answers = WaitingAnswers(model: model)
        super.init(frame: .zero)
        accessibilityIdentifier = "home.waiting"
        heading.accessibilityTraits = .header
        pages.isPagingEnabled = true
        pages.showsHorizontalScrollIndicator = false
        pages.alwaysBounceHorizontal = false
        // The next one shows past the margin, so there is something to swipe to.
        pages.clipsToBounds = false
        pages.delegate = self
        [heading, count, pages].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { cards.isEmpty }

    /// One page: a card and the gap after it.
    private var step: CGFloat { bounds.width + Theme.Space.row }
    private var headingHeight: CGFloat { ceil(Theme.Text.caption.lineHeight) }

    /// Its height at `width`: the heading and the tallest card.
    func height(width: CGFloat) -> CGFloat {
        guard !cards.isEmpty else { return 0 }
        return headingHeight + Theme.Space.row + cards.map { $0.view.height(width: width) }.max()!
    }

    /// The list, its apps in Home's order. True when what shows changed.
    @discardableResult
    func update(_ list: WaitingList, order: [String], busy: Set<String>) -> Bool {
        let rank = { (id: String) in order.firstIndex(of: id) ?? .max }
        let items = list.apps.sorted { rank($0.projectID) < rank($1.projectID) }
            .flatMap { app in app.items.map { (project: app.projectID, item: $0) } }
        if let shown, shown.busy == busy, shown.list.elementsEqual(items, by: { $0.project == $1.project && $0.item == $1.item }) {
            return false
        }
        shown = (items, busy)
        // The one showing stays showing; answered, the next takes its place.
        let current = page
        let showing = cards.indices.contains(current) ? cards[current].id : nil
        cards.forEach { $0.view.removeFromSuperview() }
        cards = items.map { project, item in
            let card = HomeWaitingCard()
            answers.configure(card.item, item, about: true, app: list.apps.first { $0.projectID == project }?.name ?? "App") { [weak self] in
                self?.onResize?()
            }
            card.addAction(UIAction { [weak self] _ in self?.onJump?(project, item) }, for: .touchUpInside)
            pages.addSubview(card)
            return (item.id, card)
        }
        let target = showing.flatMap { id in cards.firstIndex { $0.id == id } } ?? min(current, max(0, cards.count - 1))
        setNeedsLayout()
        layoutIfNeeded()
        pages.contentOffset.x = CGFloat(target) * step
        showCount()
        return true
    }

    /// The card under the finger's page.
    private var page: Int {
        guard step > 0 else { return 0 }
        return max(0, min(cards.count - 1, Int((pages.contentOffset.x / step).rounded())))
    }

    private func showCount() {
        count.text = cards.count > 1 ? "\(page + 1) of \(cards.count)" : nil
        accessibilityValue = count.text
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { showCount() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width, line = headingHeight
        // Nothing waiting: no heading either.
        heading.isHidden = cards.isEmpty
        count.isHidden = cards.isEmpty
        let headingWidth = ceil(heading.sizeThatFits(CGSize(width: width, height: line)).width)
        heading.frame = CGRect(x: 0, y: 0, width: headingWidth, height: line)
        count.frame = CGRect(x: headingWidth + Theme.Space.tight, y: 0, width: max(0, width - headingWidth - Theme.Space.tight), height: line)
        let top = line + Theme.Space.row
        pages.frame = CGRect(x: 0, y: top, width: step, height: max(0, bounds.height - top))
        for (index, card) in cards.enumerated() {
            card.view.frame = CGRect(x: CGFloat(index) * step, y: 0, width: width, height: card.view.height(width: width))
        }
        pages.contentSize = CGSize(width: CGFloat(cards.count) * step, height: pages.bounds.height)
    }
}

/// One page of Home's deck: the shared card, which opens where it was
/// asked when its question is tapped.
private final class HomeWaitingCard: UIControl {
    let item = WaitingItemView(.deck)

    override init(frame: CGRect) {
        super.init(frame: frame)
        item.translatesAutoresizingMaskIntoConstraints = false
        addSubview(item)
        NSLayoutConstraint.activate([
            item.topAnchor.constraint(equalTo: topAnchor),
            item.bottomAnchor.constraint(equalTo: bottomAnchor),
            item.leadingAnchor.constraint(equalTo: leadingAnchor),
            item.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        // Only taps on who asks and the question open it; the answers are theirs.
        item.head.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func height(width: CGFloat) -> CGFloat {
        return item.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                            verticalFittingPriority: .fittingSizeLevel).height.rounded(.up)
    }

    @objc private func tapped() { sendActions(for: .touchUpInside) }
}
