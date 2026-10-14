import Foundation

/// A worker thread an action names. Only a thread argument or a spawn's own
/// reply makes one, so no other ID in a command's output can pass for it.
struct WorkerID: Hashable {
    let raw: String
    init?(_ text: String?) {
        guard let text, let id = SquircleAction.uuid(text) else { return nil }
        raw = id
    }
}

/// A build an action started, from that command's own reply.
struct BuildID: Hashable {
    let raw: String
    init?(_ text: String?) {
        guard let text, let id = SquircleAction.uuid(text) else { return nil }
        raw = id
    }
}

/// A Squircle command an agent ran (`squircle thread spawn …`, `build start`,
/// `sim start`, …), read from its Bash command line and output. One Bash call
/// can run several; each takes its target and outcome only from output that
/// is provably its own.
struct SquircleAction: Equatable {
    enum Kind: Equatable {
        /// The new worker, once its reply names it.
        case spawn(WorkerID?)
        case send(WorkerID?), read(WorkerID?), answer(WorkerID?), archive(WorkerID?)
        /// The build it started, once its reply names it.
        case buildStart(BuildID?)
        case cleanup, status, buildStatus, simStart, simStop, simOther
        case restart, fresh, agentOther, perf, media, help, other
    }
    /// What Squircle's reply says happened.
    enum Outcome: Equatable {
        /// No output yet.
        case pending
        case succeeded
        /// Squircle refused it (its output is an error), so nothing happened.
        case refused
        /// Output there is, but not provably this command's: filtered by
        /// `| grep`, or several commands' replies that can't be told apart.
        case unattributed
    }
    var kind: Kind
    /// A worker's title, from `spawn --title`.
    var title: String?
    var branch: String?
    /// The prompt or message sent.
    var text: String?
    /// What it built, from `--scheme` or the project's name.
    var app: String?
    var outcome = Outcome.pending

    var refused: Bool { outcome == .refused }
    /// The worker it acts on, when known.
    var worker: WorkerID? {
        switch kind {
        case .spawn(let id), .send(let id), .read(let id), .answer(let id), .archive(let id): id
        default: nil
        }
    }
    var build: BuildID? { if case .buildStart(let id) = kind { id } else { nil } }
    var isSpawn: Bool { if case .spawn = kind { true } else { false } }

    /// Actions that change something show as their own line; lookups fold
    /// into the turn's work like any step.
    var visible: Bool {
        if refused { return false }
        switch kind {
        case .spawn, .send, .read, .answer, .archive, .cleanup, .buildStart, .simStart, .simStop, .restart, .fresh: return true
        default: return false
        }
    }

    var symbol: String {
        switch kind {
        case .spawn: return "person.badge.plus"
        case .send: return "arrow.up.message"
        case .read: return "text.bubble"
        case .answer: return "arrowshape.turn.up.left"
        case .archive, .cleanup: return "archivebox"
        case .status: return "person.2"
        case .buildStart, .buildStatus: return "shippingbox"
        case .simStart, .simOther: return "iphone"
        case .simStop: return "iphone.slash"
        case .restart: return "arrow.clockwise"
        case .fresh: return "sparkles"
        case .perf: return "waveform.path.ecg"
        case .media: return "photo"
        case .agentOther, .help, .other: return "terminal"
        }
    }

    /// What it did, without the worker's name ("Sent to" + the name).
    var verb: String {
        switch kind {
        case .spawn: return "Started worker"
        case .send: return "Sent to"
        case .read: return "Read"
        case .answer: return "Answered"
        case .archive: return "Archived"
        case .cleanup: return "Cleaned up finished workers"
        case .status: return "Checked workers"
        case .buildStart: return "Started build"
        case .buildStatus: return "Checked builds"
        case .simStart: return "Started simulator"
        case .simStop: return "Stopped simulator"
        case .simOther: return "Checked simulators"
        case .restart: return "Restarted"
        case .fresh: return "Started fresh"
        case .agentOther: return "Set up the agent"
        case .perf: return "Read a performance recording"
        case .media: return "Published a recording"
        case .help: return "Read Squircle's help"
        case .other: return "Ran Squircle"
        }
    }

    /// The step's title when it folds with the rest of the turn's work.
    func sentence(worker name: String?) -> String {
        switch kind {
        case .spawn: return verb + " · " + (name ?? title ?? "a worker")
        case .send, .answer, .archive: return verb + " " + (name ?? "a worker")
        case .read: return verb + " " + (name.map { $0 + "’s reply" } ?? "a worker’s reply")
        case .buildStart: return verb + (app.map { " · " + $0 } ?? "")
        default: return verb
        }
    }

    // MARK: Parsing

    /// Every Squircle command in `command`. `result` is the whole call's
    /// output: a lone command owns all of it; several share it only when it
    /// splits into exactly one Squircle reply each, in order. Otherwise
    /// their targets and outcomes stay unknown rather than borrowed.
    static func parse(command: String, result: String? = nil) -> [SquircleAction] {
        let invocations = invocations(command)
        guard !invocations.isEmpty else { return [] }
        let outputs: [Output?]
        if result == nil {
            outputs = invocations.map { _ in nil }
        } else if invocations.count == 1 {
            outputs = [Output(result ?? "")]
        } else if let replies = Output.replies(result ?? ""), replies.count == invocations.count {
            outputs = replies.map(Output.init)
        } else {
            outputs = invocations.map { _ in Output.unattributed }
        }
        return zip(invocations, outputs).compactMap { action($0, output: $1) }
    }

    /// The words after the CLI's name, for each Squircle command in `command`.
    private static func invocations(_ command: String) -> [[String]] {
        guard command.contains("squircle") else { return [] }
        var functions = Set<String>(), variables = Set<String>()
        var defining: String?
        var found: [[String]] = []
        for words in Shell.commands(command) {
            // `S() { …/squircle … "$@"; }` and `S="…/squircle …"` name the CLI.
            if words.count == 2, words[1] == "()" { defining = words[0]; continue }
            if let name = defining {
                defining = nil
                if words.contains(where: isBinary) { functions.insert(name); continue }
            }
            var index = 0
            while index < words.count, let eq = words[index].firstIndex(of: "="), words[index][..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  !words[index].hasPrefix("-") {
                let value = words[index][words[index].index(after: eq)...]
                if value.split(separator: " ").first.map({ isBinary(String($0)) }) == true { variables.insert(String(words[index][..<eq])) }
                index += 1
            }
            // The command itself, not an argument (`grep squircle`).
            while index < words.count, ["env", "exec", "time", "command", "nohup"].contains(words[index]) { index += 1 }
            let start = index
            guard start < words.count, isBinary(words[start]) || functions.contains(words[start])
                    || variables.contains(where: { words[start] == "$" + $0 || words[start] == "${\($0)}" }) else { continue }
            if isAction(Array(words[(start + 1)...])) { found.append(Array(words[(start + 1)...])) }
        }
        return found
    }

    private static func isBinary(_ word: String) -> Bool {
        word == "squircle" || word.hasSuffix("/squircle")
    }

    /// Options that take a value, so their value is not read as an argument.
    private static let valued: Set<String> = [
        "--data-dir", "--server", "--coordinator", "--title", "--branch", "--base", "--prompt", "--model", "--thread", "--device",
        "--id", "--project", "--scheme", "--configuration", "--mode", "--export", "--export-method", "--idempotency-key",
        "--file", "--caption", "--build", "--summary", "--message", "--handoff", "--kind", "--name", "--team", "--bundle-id"
    ]

    private struct Words {
        var positional: [String] = [], options: [String: String] = [:], help = false
        init(_ words: [String]) {
            var index = 0
            while index < words.count {
                let word = words[index]
                if word == "--help" || word == "-h" || word == "help" { help = true }
                if word.hasPrefix("--"), let eq = word.firstIndex(of: "=") {
                    options[String(word[..<eq])] = String(word[word.index(after: eq)...])
                } else if word.hasPrefix("--") {
                    if valued.contains(word), index + 1 < words.count { options[word] = words[index + 1]; index += 1 }
                    else { options[word] = "" }
                } else {
                    positional.append(word)
                }
                index += 1
            }
        }
    }

    /// Bare options (`squircle --version`) are no action.
    private static func isAction(_ words: [String]) -> Bool {
        let parsed = Words(words)
        return parsed.help || !parsed.positional.isEmpty
    }

    private static func action(_ words: [String], output: Output?) -> SquircleAction? {
        let parsed = Words(words)
        let positional = parsed.positional, options = parsed.options
        if parsed.help { return SquircleAction(kind: .help) }
        let group = positional.first ?? "", sub = positional.count > 1 ? positional[1] : ""
        let args = Array(positional.dropFirst(2))
        let target = WorkerID(args.first)
        var action: SquircleAction
        switch (group, sub) {
        case ("thread", "spawn"):
            action = SquircleAction(kind: .spawn(WorkerID(output?.string("id") ?? output?.string("thread_id"))),
                                    title: options["--title"], branch: options["--branch"], text: options["--prompt"])
        case ("thread", "send"): action = SquircleAction(kind: .send(target), text: args.dropFirst().first)
        case ("thread", "answer"): action = SquircleAction(kind: .answer(target), text: args.dropFirst().first)
        case ("thread", "read"): action = SquircleAction(kind: .read(target))
        case ("thread", "archive"): action = SquircleAction(kind: .archive(target))
        case ("thread", "cleanup"): action = SquircleAction(kind: options["--dry-run"] != nil ? .status : .cleanup)
        case ("thread", _): action = SquircleAction(kind: .status)
        case ("build", "start"):
            let project = options["--project"].map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            action = SquircleAction(kind: .buildStart(BuildID(output?.string("id") ?? output?.string("build_id") ?? output?.onlyUUID)),
                                    app: options["--scheme"] ?? project)
        case ("build", _): action = SquircleAction(kind: .buildStatus)
        case ("sim", "start"): action = SquircleAction(kind: .simStart)
        case ("sim", "stop"): action = SquircleAction(kind: .simStop)
        case ("sim", _): action = SquircleAction(kind: .simOther)
        case ("agent", "restart"): action = SquircleAction(kind: .restart)
        case ("agent", "fresh"): action = SquircleAction(kind: .fresh)
        case ("agent", _): action = SquircleAction(kind: .agentOther)
        case ("perf", _): action = SquircleAction(kind: .perf)
        case ("media", _): action = SquircleAction(kind: .media)
        default: action = SquircleAction(kind: .other)
        }
        action.outcome = output?.outcome ?? .pending
        return action
    }

    static func uuid(_ text: String) -> String? {
        UUID(uuidString: text) != nil ? text.lowercased() : nil
    }

    /// One command's output: Squircle's JSON envelope, often cut short by
    /// `| head`, or whatever a filter left of it.
    fileprivate struct Output {
        let text: String
        /// Output that can't be tied to one command.
        var attributable = true
        init(_ text: String) { self.text = text }
        static let unattributed: Output = { var output = Output(""); output.attributable = false; return output }()

        var outcome: Outcome {
            guard attributable else { return .unattributed }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isError { return .refused }
            if trimmed.hasPrefix("{") || onlyUUID != nil { return .succeeded }
            return trimmed.isEmpty ? .succeeded : .unattributed
        }
        /// `"key": "value"` anywhere in the text, whole or truncated.
        func string(_ key: String) -> String? {
            guard attributable, let range = text.range(of: #""\#(key)"\s*:\s*"([^"]*)""#, options: .regularExpression) else { return nil }
            let match = text[range]
            guard let open = match.dropLast().lastIndex(of: "\"") else { return nil }
            return String(match[match.index(after: open)..<match.index(before: match.endIndex)])
        }
        /// Squircle's error envelope, `{"error": {…}, "ok": false}`.
        var isError: Bool {
            text.range(of: #"^\s*\{\s*"error"\s*:\s*\{"#, options: .regularExpression) != nil
        }
        /// The one UUID the output names (`| jq -r .data.id`); none when it
        /// names several, which could be anything's.
        var onlyUUID: String? {
            guard attributable else { return nil }
            let ids = Set(ThreadItem.uuids(in: text))
            return ids.count == 1 ? ids.first : nil
        }

        /// Several commands' output as one Squircle JSON reply each, in
        /// order; the last may be cut short. Nil when anything else is in
        /// it that could carry an ID, so replies can't be paired by position.
        static func replies(_ text: String) -> [String]? {
            let chars = Array(text)
            var replies: [String] = [], outside = ""
            var i = 0
            while i < chars.count {
                guard chars[i] == "{" else { outside.append(chars[i]); i += 1; continue }
                let start = i
                var depth = 0, inString = false, escaped = false
                while i < chars.count {
                    let c = chars[i]
                    i += 1
                    if inString {
                        if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    } else if c == "\"" { inString = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" { depth -= 1; if depth == 0 { break } }
                }
                replies.append(String(chars[start..<i]))
            }
            guard ThreadItem.uuids(in: outside).isEmpty else { return nil }
            return replies
        }
    }
}

/// Just enough of a POSIX shell's word splitting to read the commands an
/// agent ran: quotes, escapes, `$( … )`, heredocs, comments and operators.
enum Shell {
    /// Simple commands, as words with their quoting removed. A `$(cat <<EOF …)`
    /// argument becomes its heredoc's text.
    static func commands(_ source: String) -> [[String]] {
        let chars = Array(source)
        var commands: [[String]] = [], words: [String] = []
        var word = "", inWord = false
        var heredocs: [(delimiter: String, strip: Bool)] = []
        var i = 0
        func endWord() {
            if inWord { words.append(word) }
            word = ""; inWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        /// Skips heredoc bodies that start after a newline.
        func skipHeredocs() {
            for heredoc in heredocs {
                while i < chars.count {
                    var end = i
                    while end < chars.count, chars[end] != "\n" { end += 1 }
                    var line = String(chars[i..<end])
                    if heredoc.strip { line = String(line.drop { $0 == "\t" }) }
                    i = min(chars.count, end + 1)
                    if line == heredoc.delimiter { break }
                }
            }
            heredocs = []
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count {
                    if chars[i + 1] != "\n" { word.append(chars[i + 1]); inWord = true }
                    i += 2
                } else { i += 1 }
            case "'":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
                i += 1
            case "\"":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`\n".contains(chars[i + 1]) {
                        if chars[i + 1] != "\n" { word.append(chars[i + 1]) }
                        i += 2
                    } else if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                        word += substitution(chars, &i)
                    } else { word.append(chars[i]); i += 1 }
                }
                i += 1
            case "$" where i + 1 < chars.count && chars[i + 1] == "'":
                inWord = true
                i += 2
                while i < chars.count, chars[i] != "'" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        let next = chars[i + 1]
                        word.append(["n": "\n", "t": "\t", "r": "\r"][next] ?? next)
                        i += 2
                    } else { word.append(chars[i]); i += 1 }
                }
                i += 1
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                inWord = true
                word += substitution(chars, &i)
            case "#" where !inWord:
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "\n":
                endCommand()
                i += 1
                skipHeredocs()
            case ";", "&", "|", "(", ")":
                // `name()` stays one word so a function definition is visible.
                if c == "(", i + 1 < chars.count, chars[i + 1] == ")", inWord {
                    endWord(); words.append("()"); i += 2; continue
                }
                endCommand()
                i += 1
            case "<", ">":
                // Redirections and their targets are not arguments.
                if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false }
                endWord()
                if c == "<", i + 1 < chars.count, chars[i + 1] == "<" {
                    i += 2
                    if i < chars.count, chars[i] == "<" { i += 1; skipBlanks(chars, &i); _ = rawWord(chars, &i); continue }
                    let strip = i < chars.count && chars[i] == "-"
                    if strip { i += 1 }
                    skipBlanks(chars, &i)
                    heredocs.append((rawWord(chars, &i), strip))
                    continue
                }
                i += 1
                while i < chars.count, ">&|".contains(chars[i]) { i += 1 }
                skipBlanks(chars, &i)
                _ = rawWord(chars, &i)
            case " ", "\t":
                endWord()
                i += 1
            case "{" where !inWord, "}" where !inWord:
                // A brace group's braces are words of their own.
                if i + 1 >= chars.count || " \t\n;".contains(chars[i + 1]) { endCommand(); i += 1 }
                else { word.append(c); inWord = true; i += 1 }
            default:
                word.append(c); inWord = true
                i += 1
            }
        }
        endCommand()
        return commands
    }

    private static func skipBlanks(_ chars: [Character], _ i: inout Int) {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
    }

    /// A heredoc delimiter or redirection target, unquoted.
    private static func rawWord(_ chars: [Character], _ i: inout Int) -> String {
        var word = ""
        while i < chars.count, !" \t\n;&|<>()".contains(chars[i]) {
            if chars[i] == "'" || chars[i] == "\"" {
                let quote = chars[i]; i += 1
                while i < chars.count, chars[i] != quote { word.append(chars[i]); i += 1 }
                i += 1
            } else { word.append(chars[i]); i += 1 }
        }
        return word
    }

    /// `$( … )` from `i`: a heredoc's text when it only cats one, else the
    /// substitution as written.
    private static func substitution(_ chars: [Character], _ i: inout Int) -> String {
        let start = i
        i += 2
        var depth = 1
        var inner = ""
        while i < chars.count, depth > 0 {
            let c = chars[i]
            if c == "'" {
                inner.append(c); i += 1
                while i < chars.count, chars[i] != "'" { inner.append(chars[i]); i += 1 }
                if i < chars.count { inner.append(chars[i]); i += 1 }
                continue
            }
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { i += 1; break } }
            inner.append(c); i += 1
        }
        if let body = heredocBody(inner) { return body }
        return String(chars[start..<i])
    }

    /// The text of `cat <<'EOF' … EOF`.
    private static func heredocBody(_ inner: String) -> String? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cat"), let marker = trimmed.range(of: "<<") else { return nil }
        let rest = trimmed[marker.upperBound...]
        guard let newline = rest.firstIndex(of: "\n") else { return nil }
        let delimiter = rest[..<newline].trimmingCharacters(in: CharacterSet(charactersIn: " -'\""))
        guard !delimiter.isEmpty else { return nil }
        var lines = rest[rest.index(after: newline)...].components(separatedBy: "\n")
        guard let end = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == delimiter }) else { return nil }
        lines = Array(lines[..<end])
        return lines.joined(separator: "\n")
    }
}
