import UIKit

/// The agent's open request over the message field: an approval with its
/// choices, or its questions one at a time. The conversation says which
/// request is open and whether its answer is on its way; the card answers
/// it as Waiting on you does (`WaitingAnswers`), from the same drafts.
@MainActor
final class RequestCard {
    enum Change { case appeared, changed }

    let view = Theme.glassSurface(cornerRadius: Theme.Radius.large)
    /// The next question slid in and the card's height changed.
    var onResize: (() -> Void)?

    /// The question card's layout, on the card's glass.
    private let card = WaitingItemView(filled: false)
    /// Who asks: the conversation's own agent, said and shown.
    var asker = (name: "Your agent asks", jelly: JellyLook.agent(.needsYou))
    /// The request drawn and whether its answer was on its way then.
    private var rendered: (id: String, busy: Bool)?
    private let answers: WaitingAnswers

    init(answers: WaitingAnswers) {
        self.answers = answers
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

    /// Shows `current` (none hides the card), taking touches unless its
    /// answer is on its way (`busy`). Nil when that is what already shows.
    func show(_ current: PendingRequest?, busy: Bool) -> Change? {
        let now = current.map { (id: $0.id, busy: busy) }
        guard now?.id != rendered?.id || now?.busy != rendered?.busy else { return nil }
        let appearing = rendered == nil && current != nil
        rendered = now
        view.isHidden = current == nil
        if let current { render(current) }
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

    /// The request through the shared answering; the card slides to each
    /// next question.
    private func render(_ current: PendingRequest) {
        answers.configure(card, open: current, asker: asker.name, jelly: asker.jelly) { [weak self] advanced in
            guard let self, advanced else { return }
            if !Motion.reduced {
                let slide = CATransition()
                slide.type = .push
                slide.subtype = .fromRight
                slide.duration = 0.35
                slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                view.contentView.layer.add(slide, forKey: "question")
            }
            onResize?()
        }
    }
}
