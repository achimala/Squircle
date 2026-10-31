import UIKit

/// The agent's open request over the message field: an approval with its
/// choices, or its questions one at a time. The conversation says which
/// request is open; the card answers through `onRespond`. Answers so far
/// live in `drafts`, shared with Waiting on you.
@MainActor
final class RequestCard {
    enum Change { case appeared, changed }

    let view = Theme.glassSurface(cornerRadius: Theme.Radius.large)
    var onRespond: ((_ request: PendingRequest, _ decision: String?, _ answers: [String: JSONValue]?) -> Void)?
    /// The next question slid in and the card's height changed.
    var onResize: (() -> Void)?

    /// The question card's layout, on the card's glass.
    private let card = WaitingItemView(filled: false)
    /// Who asks: the conversation's own agent, said and shown.
    var asker = (name: "Your agent asks", jelly: JellyLook.agent(.needsYou))
    private var renderedID: String?
    private let drafts: QuestionAnswers

    init(drafts: QuestionAnswers) {
        self.drafts = drafts
        card.translatesAutoresizingMaskIntoConstraints = false
        view.contentView.addSubview(card)
        view.accessibilityIdentifier = "thread.request"
        view.isHidden = true
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.contentView.topAnchor, constant: Theme.Space.card.top),
            card.bottomAnchor.constraint(equalTo: view.contentView.bottomAnchor, constant: -Theme.Space.card.bottom),
            card.leadingAnchor.constraint(equalTo: view.contentView.leadingAnchor, constant: Theme.Space.card.left),
            card.trailingAnchor.constraint(equalTo: view.contentView.trailingAnchor, constant: -Theme.Space.card.right)
        ])
    }

    /// Shows `current` (none hides the card). Nil when it is the request
    /// already shown.
    func show(_ current: PendingRequest?) -> Change? {
        let id = current?.id
        guard id != renderedID else { return nil }
        let appearing = renderedID == nil && current != nil
        renderedID = id
        view.isHidden = current == nil
        if let current {
            if current.isQuestion { renderQuestion(current) } else { renderApproval(current) }
        }
        return appearing ? .appeared : .changed
    }

    /// The card rises out of the message field.
    func rise() {
        view.alpha = 0
        view.transform = CGAffineTransform(translationX: 0, y: 40).scaledBy(x: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.65, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.view.alpha = 1
            self.view.transform = .identity
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Where Waiting on you took you.
    func mark() { view.layer.markSpot(in: view.traitCollection) }

    private func renderApproval(_ current: PendingRequest) {
        card.show(context: asker.name, asker: asker.jelly, question: current.title, detail: current.prompt)
        let choices = WaitingItemView.decisions(current)
        card.answers(choices.map(\.answer), busy: false) { [weak self] index in
            Theme.selectionHaptic()
            self?.onRespond?(current, choices[index].decision, nil)
        }
        card.reply(placeholder: nil, text: "", busy: false, edit: { _ in }) { _ in }
    }

    /// One of the agent's questions at a time, answered by tapping a choice
    /// or typing; the card slides to the next question.
    private func renderQuestion(_ current: PendingRequest, advancing: Bool = false) {
        let key = QuestionAnswers.key(request: current.id)
        let form = QuestionForm(questions: current.questions, draft: drafts[key])
        if advancing, !Motion.reduced {
            let slide = CATransition()
            slide.type = .push
            slide.subtype = .fromRight
            slide.duration = 0.35
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            view.contentView.layer.add(slide, forKey: "question")
        }
        let context = [asker.name, form.question["header"].string].compactMap { $0 }.joined(separator: " · ")
        card.show(context: context, asker: asker.jelly, question: WaitingItemView.title(form), detail: nil)
        // Each tap reads the draft as it is then (typing changes it in between).
        func step(_ make: (QuestionForm) -> QuestionForm.Step) {
            let now = QuestionForm(questions: current.questions, draft: drafts[key])
            Theme.selectionHaptic()
            switch make(now) {
            case .edit(let draft):
                drafts[key] = draft
                let advanced = draft.answers.count != now.draft.answers.count
                renderQuestion(current, advancing: advanced)
                if advanced { onResize?() }
            case .send(let answers):
                card.isUserInteractionEnabled = false
                onRespond?(current, nil, answers)
            }
        }
        card.isUserInteractionEnabled = true
        card.form(form, busy: false) { index in step { index < form.options.count ? $0.choose(index) : $0.confirm() } }
        card.reply(placeholder: "Something else…", text: form.draft.text, busy: false,
                   edit: { [weak self] text in self?.drafts[key].text = text }) { text in step { $0.reply(text) } }
    }
}
