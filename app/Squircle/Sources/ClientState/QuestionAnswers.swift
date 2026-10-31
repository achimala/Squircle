import Foundation

/// Your answer to something that asks, while you give it: a thread's
/// questions answered so far, the choices picked on a multi-select one and
/// what you typed. It stays until the answer is taken or what asked is gone,
/// so a refused or lost send leaves it as you left it.
struct AnswerDraft: Equatable {
    var answers: [String: JSONValue] = [:]
    var picks: [String] = []
    var text = ""
}

/// Every draft answer, by what asks (`WaitingList.Item.id`; a thread's
/// request is the same in the conversation and in Waiting on you). The one
/// owner both presentations read and change.
@MainActor
final class QuestionAnswers {
    private var drafts: [String: AnswerDraft] = [:]

    static func key(request id: String) -> String { "r." + id }

    subscript(key: String) -> AnswerDraft {
        get { drafts[key] ?? AnswerDraft() }
        set { drafts[key] = newValue == AnswerDraft() ? nil : newValue }
    }

    /// The answer was taken.
    func accepted(_ key: String) { drafts[key] = nil }

    /// Forgets drafts for what no longer asks (`asking`: everything still listed or on its way).
    func keep(_ asking: Set<String>) { drafts = drafts.filter { asking.contains($0.key) } }
}

/// A thread's questions as you answer them, one at a time: which one shows,
/// what's picked, and what a tap or typed reply does. The last answer is
/// never written into the draft, so after a failed send the last question
/// shows again with your picks and text.
struct QuestionForm {
    struct Option { let label: String; let value: String; let detail: String?; let picked: Bool }
    enum Step {
        /// Stay or move on with this draft.
        case edit(AnswerDraft)
        /// Every answer: send them.
        case send([String: JSONValue])
    }

    let questions: [JSONValue]
    let draft: AnswerDraft

    private static func key(_ question: JSONValue) -> String { question["id"].string ?? question["header"].string ?? "answer" }

    /// The question showing: the first one not answered.
    var index: Int { questions.firstIndex { draft.answers[Self.key($0)] == nil } ?? max(0, questions.count - 1) }
    var question: JSONValue { questions.isEmpty ? .null : questions[index] }
    var isLast: Bool { index >= questions.count - 1 }
    var multiple: Bool { question["multiSelect"].bool }
    var options: [Option] {
        question["options"].array.map { option in
            let label = option["label"].string ?? option.string ?? "Option"
            return Option(label: label, value: option["value"].string ?? label, detail: option["description"].string,
                          picked: draft.picks.contains(label))
        }
    }
    /// A multi-select question sends its picks with this; nothing to send yet without one.
    var canConfirm: Bool { !draft.picks.isEmpty }

    /// A tap on a choice: the answer, or on a multi-select one, picking it or not.
    func choose(_ option: Int) -> Step {
        let option = options[option]
        guard multiple else { return answer(option.value) }
        var draft = draft
        if let at = draft.picks.firstIndex(of: option.label) { draft.picks.remove(at: at) } else { draft.picks.append(option.label) }
        return .edit(draft)
    }

    /// The typed reply, with the picks on a multi-select question.
    func reply(_ text: String) -> Step { answer(multiple ? (draft.picks + [text]).joined(separator: ", ") : text) }

    /// A multi-select question's picks (and anything typed) as its answer.
    func confirm() -> Step {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer((draft.picks + (text.isEmpty ? [] : [text])).joined(separator: ", "))
    }

    private func answer(_ value: String) -> Step {
        var answers = draft.answers
        answers[Self.key(question)] = .string(value)
        if isLast { return .send(answers) }
        return .edit(AnswerDraft(answers: answers))
    }
}
