import UIKit

/// Native responses to Hermes's server→client requests. Choices come from the
/// server; no guessed approvals, permission bypasses or silent defaults.
@MainActor
final class HermesQuestionPanel: UIView {
    var respond: ((JSONValue) -> Void)?
    private let question: HermesQuestion
    private var fields: [String: UITextField] = [:]
    private var selections: [String: Set<String>] = [:]
    private var lockedAnswers: [String: JSONValue] = [:]

    init(question: HermesQuestion) {
        self.question = question
        super.init(frame: .zero)
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: question.method == "approval" ? 200 : 260),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        stack.addArrangedSubview(Theme.label(question.method == "connection" ? "Connections" : question.title, Theme.font(.headline, 16), lines: 0))
        if let command = question.params["command"].string, !command.isEmpty {
            let label = Theme.label(command, Theme.font(.caption1, 12, monospaced: true), lines: 0)
            stack.addArrangedSubview(label)
        }
        switch question.method {
        case "connection":
            for target in question.params["targets"].array {
                guard let name = target["name"].string else { continue }
                stack.addArrangedSubview(Theme.label(target["display"].string ?? name, Theme.font(.headline, 16), lines: 0))
                let description = ["description", "instructions", "detail"].compactMap { target[$0].string }.joined(separator: "\n")
                if !description.isEmpty { stack.addArrangedSubview(Theme.label(description, Theme.font(.body, 15), lines: 0)) }
                let state = target["state"].string ?? "pending"
                stack.addArrangedSubview(Theme.label(state, Theme.font(.caption1, 12), lines: 0))
                guard ["pending", "initiated", "not_connected", "failed"].contains(state) else { continue }
                for env in target["required_env"].array {
                    guard let key = env["name"].string else { continue }
                    field(name + ":" + key, placeholder: env["prompt"].string ?? key, secure: env["secret"].bool, in: stack)
                    fields[name + ":" + key]?.text = env["default"].string
                }
                if let link = target["connect_url"].string, let url = URL(string: link), ["https", "http"].contains(url.scheme) {
                    button("Open authorization", in: stack) { UIApplication.shared.open(url) }
                } else {
                    button((target["action"].string ?? "Connect").capitalized + " " + name, in: stack) { [weak self] in
                        guard let self else { return }
                        var env: [String: JSONValue] = [:]
                        for (key, field) in self.fields where key.hasPrefix(name + ":") { env[String(key.dropFirst(name.count + 1))] = .string(field.text ?? "") }
                        self.respond?(.object(["targets": .array([.object(["name": .string(name), "status": .string("approved"), "env": .object(env)])])]))
                    }
                }
                button("Skip " + name, in: stack) { [weak self] in self?.respond?(.object(["targets": .array([.object(["name": .string(name), "status": .string("skipped")])])])) }
            }
            button("Continue", in: stack) { [weak self] in self?.respond?(.object(["settled_by": .string("continue")])) }
        case "approval":
            for choice in question.params["choices"].array.compactMap(\.string) {
                let title = ["once": "Allow Once", "session": "Allow for This Session", "always": "Always Allow", "deny": "Deny"][choice] ?? choice
                button(title, in: stack) { [weak self] in self?.respond?(.object(["choice": .string(choice)])) }
            }
        case "clarify":
            lockedAnswers = question.params["answers"].object
            for q in question.params["questions"].array {
                guard let id = q["qid"].string else { continue }
                stack.addArrangedSubview(Theme.label(q["question"].string ?? "Question", Theme.font(.body, 16), lines: 0))
                if let answer = lockedAnswers[id] {
                    stack.addArrangedSubview(Theme.label(answer.string ?? "Skipped", Theme.font(.body, 15), lines: 0)); continue
                }
                for choice in q["choices"].array.compactMap(\.string) {
                    let control = UIButton(type: .system)
                    control.setTitle(choice, for: .normal); control.contentHorizontalAlignment = .leading
                    control.titleLabel?.numberOfLines = 0
                    control.addAction(UIAction { [weak self, weak control] _ in
                        guard let self else { return }
                        if q["multi_select"].bool {
                            var selected = self.selections[id] ?? []
                            if selected.contains(choice) { selected.remove(choice) } else { selected.insert(choice) }
                            self.selections[id] = selected
                            control?.setTitle((selected.contains(choice) ? "✓ " : "") + choice, for: .normal)
                        } else { self.fields[id]?.text = choice }
                    }, for: .touchUpInside)
                    stack.addArrangedSubview(control)
                }
                field(id, placeholder: "Your answer", in: stack)
            }
            button("Send Answers", in: stack) { [weak self] in
                guard let self else { return }
                var answers = self.lockedAnswers
                for (id, field) in self.fields {
                    let parts = Array(self.selections[id] ?? []).sorted() + [field.text ?? ""].filter { !$0.isEmpty }
                    answers[id] = parts.isEmpty ? .null : .string(parts.joined(separator: ", "))
                }
                self.respond?(.object(["answers": .object(answers)]))
            }
            button("Cancel", in: stack) { [weak self] in self?.respond?(.object([:])) }
        default:
            if question.method == "vault.save_login" {
                field("identifier", placeholder: "Username or email", in: stack)
                field("password", placeholder: "Password", secure: true, in: stack)
            } else { field("value", placeholder: question.params["env_var"].string ?? "Value", secure: true, in: stack) }
            button("Submit", in: stack) { [weak self] in
                guard let self else { return }
                let value: String
                if self.question.method == "vault.save_login" {
                    let object = self.fields.mapValues { JSONValue.string($0.text ?? "") }
                    value = JSONValue.object(object).formatted
                } else { value = self.fields["value"]?.text ?? "" }
                self.respond?(.object(["value": .string(value)]))
                self.fields.values.forEach { $0.text = "" }
            }
            button("Cancel", in: stack) { [weak self] in self?.respond?(.object(["value": .string("")])) }
        }
    }
    private func field(_ id: String, placeholder: String, secure: Bool = false, in stack: UIStackView) {
        let field = UITextField(); field.placeholder = placeholder; field.isSecureTextEntry = secure
        field.borderStyle = .roundedRect; field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.accessibilityLabel = placeholder; field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        fields[id] = field; stack.addArrangedSubview(field)
    }
    private func button(_ title: String, in stack: UIStackView, action: @escaping () -> Void) {
        let button = Theme.glassButton(title: title)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside); stack.addArrangedSubview(button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
