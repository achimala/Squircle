import UIKit

/// The agent's open request over the message field: an approval with its
/// choices, or its questions one at a time. The conversation says which
/// request is open; the card answers through `onRespond`.
@MainActor
final class RequestCard {
    enum Change { case appeared, changed }

    let view = Theme.glassSurface(cornerRadius: 22)
    var onRespond: ((_ request: PendingRequest, _ decision: String?, _ answers: [String: JSONValue]?) -> Void)?
    /// The next question slid in and the card's height changed.
    var onResize: (() -> Void)?

    private let title = Theme.label("", Theme.font(.subheadline, 15, .semibold), lines: 2)
    private let detail = Theme.label("", Theme.font(.footnote, 12.5, monospaced: true), color: .secondaryLabel, lines: 4)
    private let buttons = UIStackView()
    private var renderedID: String?
    /// Progress through the agent's questions in the current request.
    private var questionIndex = 0
    private var questionAnswers: [String: JSONValue] = [:]
    private var questionPicks: [String] = []

    init() {
        detail.lineBreakMode = .byTruncatingTail
        buttons.spacing = 8
        buttons.axis = .vertical
        buttons.distribution = .fill
        let stack = UIStackView(arrangedSubviews: [title, detail, buttons])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(12, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.contentView.addSubview(stack)
        view.accessibilityIdentifier = "thread.request"
        view.isHidden = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: view.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.contentView.trailingAnchor, constant: -12)
        ])
    }

    /// Shows `current` (none hides the card). Nil when it is the request
    /// already shown.
    func show(_ current: PendingRequest?) -> Change? {
        let id = current?.id
        guard id != renderedID else { return nil }
        let appearing = renderedID == nil && current != nil
        renderedID = id
        questionIndex = 0
        questionAnswers = [:]
        questionPicks = []
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

    private func button(_ title: String, subtitle: String? = nil, prominent: Bool, leading: Bool = false,
                        action: @escaping () -> Void) -> UIButton {
        let button = Theme.glassButton(title: title, prominent: prominent, identifier: "thread.request.\(title)")
        button.configuration?.subtitle = subtitle
        button.configuration?.titleLineBreakMode = .byWordWrapping
        button.configuration?.subtitleLineBreakMode = .byTruncatingTail
        button.configuration?.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = Theme.font(.footnote, 13); return attributes
        }
        if leading {
            button.configuration?.titleAlignment = .leading
            button.contentHorizontalAlignment = .leading
        }
        button.addAction(UIAction { _ in Theme.selectionHaptic(); action() }, for: .touchUpInside)
        buttons.addArrangedSubview(button)
        return button
    }

    private func renderApproval(_ current: PendingRequest) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        title.text = current.title
        let text = current.prompt
        if let stack = title.superview as? UIStackView {
            stack.insertArrangedSubview(detail, at: 1)
            stack.setCustomSpacing(6, after: title)
            stack.setCustomSpacing(12, after: detail)
        }
        detail.font = Theme.font(.footnote, 12.5, monospaced: true)
        detail.textColor = .secondaryLabel
        detail.text = text
        detail.isHidden = text.isEmpty
        if current.options.isEmpty {
            _ = button("Decline", prominent: false) { [weak self] in self?.onRespond?(current, "decline", nil) }
            _ = button("Allow", prominent: true) { [weak self] in self?.onRespond?(current, "accept", nil) }
        } else {
            for option in current.options {
                _ = button(option["label"].string ?? "Choose", subtitle: option["warning"].string,
                           prominent: ["accept", "acceptForSession", "acceptAlways"].contains(option["decision"].string ?? "")) { [weak self] in
                    self?.onRespond?(current, option["decision"].string, nil)
                }
            }
        }
    }

    /// One of the agent's questions at a time, answered by tapping a choice
    /// or typing; the card slides to the next question.
    private func renderQuestion(_ current: PendingRequest, advancing: Bool = false) {
        let questions = current.questions
        guard questionIndex < questions.count else {
            buttons.arrangedSubviews.forEach { $0.isUserInteractionEnabled = false }
            onRespond?(current, nil, questionAnswers)
            return
        }
        if advancing, !Motion.reduced {
            let slide = CATransition()
            slide.type = .push
            slide.subtype = .fromRight
            slide.duration = 0.35
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            view.contentView.layer.add(slide, forKey: "question")
        }
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let question = questions[questionIndex]
        let id = question["id"].string ?? question["header"].string ?? "answer"
        let multiple = question["multiSelect"].bool
        var caption = (question["header"].string ?? "Question").uppercased()
        if questions.count > 1 { caption += "  ·  \(questionIndex + 1) OF \(questions.count)" }
        if let stack = title.superview as? UIStackView {
            stack.insertArrangedSubview(detail, at: 0)
            stack.setCustomSpacing(4, after: detail)
            stack.setCustomSpacing(14, after: title)
        }
        detail.font = Theme.font(.caption1, 12, .semibold)
        detail.textColor = Theme.accent
        detail.text = caption
        detail.isHidden = false
        title.text = question["question"].string ?? "The agent has a question"
        func answer(_ value: String) {
            questionAnswers[id] = .string(value)
            questionPicks = []
            questionIndex += 1
            renderQuestion(current, advancing: true)
            onResize?()
        }
        for option in question["options"].array {
            let label = option["label"].string ?? option.string ?? "Option"
            let picked = questionPicks.contains(label)
            _ = button(label, subtitle: option["description"].string, prominent: picked, leading: true) { [weak self] in
                guard let self else { return }
                guard multiple else { answer(option["value"].string ?? label); return }
                if let index = questionPicks.firstIndex(of: label) { questionPicks.remove(at: index) } else { questionPicks.append(label) }
                renderQuestion(current)
            }
        }
        let field = UITextField()
        field.placeholder = "Something else…"
        field.font = Theme.font(.body, 16)
        field.returnKeyType = .send
        field.accessibilityIdentifier = "thread.request.other"
        field.addAction(UIAction { [weak field] _ in
            let text = field?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { field?.resignFirstResponder(); answer(multiple ? (self.questionPicks + [text]).joined(separator: ", ") : text) }
        }, for: .editingDidEndOnExit)
        let wrap = UIView()
        wrap.backgroundColor = .tertiarySystemFill
        wrap.layer.cornerRadius = 20
        wrap.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(field)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 44),
            field.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
        ])
        buttons.addArrangedSubview(wrap)
        if multiple {
            let next = button(questionIndex == questions.count - 1 ? "Send" : "Next", prominent: true) {
                answer(self.questionPicks.joined(separator: ", "))
            }
            next.isEnabled = !questionPicks.isEmpty
        }
    }
}
