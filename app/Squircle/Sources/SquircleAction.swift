import Foundation

/// A Squircle command an agent ran (`squircle thread spawn …`, `build start`,
/// `sim start`, …), read from its Bash command line and output. One Bash call
/// can run several.
struct SquircleAction: Equatable {
    enum Kind: String {
        case spawn, send, read, answer, archive, cleanup, status
        case buildStart, buildStatus, simStart, simStop, simOther
        case restart, fresh, agentOther, perf, media, help, other
    }
    var kind: Kind
    /// The thread it acts on (a worker), when known.
    var thread: String?
    /// A worker's title, from `spawn --title`.
    var title: String?
    var branch: String?
    /// The prompt or message sent.
    var text: String?
    /// The build it started.
    var build: String?
    /// What it built, from `--scheme` or the project's name.
    var app: String?
    /// Squircle refused it (its output is an error), so nothing happened.
    var refused = false
    /// Its output was filtered away, so only a worker Squircle knows of
    /// shows it happened.
    var unconfirmed = false

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

    /// Every Squircle command in `command`, with IDs `result` names.
    static func parse(command: String, result: String? = nil) -> [SquircleAction] {
        guard command.contains("squircle") else { return [] }
        let commands = Shell.commands(command)
        var functions = Set<String>(), variables = Set<String>()
        var defining: String?
        var actions: [SquircleAction] = []
        for words in commands {
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
            if var action = action(Array(words[(start + 1)...]), result: result) {
                let output = Output(result)
                action.refused = output.isError
                action.unconfirmed = action.kind == .spawn && output.isOther
                actions.append(action)
            }
        }
        return actions
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

    private static func action(_ words: [String], result: String?) -> SquircleAction? {
        var positional: [String] = [], options: [String: String] = [:], help = false
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
        if help { return SquircleAction(kind: .help) }
        let group = positional.first ?? "", sub = positional.count > 1 ? positional[1] : ""
        let args = Array(positional.dropFirst(2))
        let target = args.first.flatMap(uuid)
        switch (group, sub) {
        case ("thread", "spawn"):
            let output = Output(result)
            return SquircleAction(kind: .spawn, thread: output.string("id") ?? output.string("thread_id"),
                                  title: options["--title"], branch: options["--branch"], text: options["--prompt"])
        case ("thread", "send"): return SquircleAction(kind: .send, thread: target, text: args.dropFirst().first)
        case ("thread", "answer"): return SquircleAction(kind: .answer, thread: target, text: args.dropFirst().first)
        case ("thread", "read"): return SquircleAction(kind: .read, thread: target)
        case ("thread", "archive"): return SquircleAction(kind: .archive, thread: target)
        case ("thread", "cleanup"): return options["--dry-run"] != nil ? SquircleAction(kind: .status) : SquircleAction(kind: .cleanup)
        case ("thread", _): return SquircleAction(kind: .status)
        case ("build", "start"):
            let project = options["--project"].map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            let output = Output(result)
            return SquircleAction(kind: .buildStart, build: output.string("id") ?? output.string("build_id") ?? output.firstUUID,
                                  app: options["--scheme"] ?? project)
        case ("build", _): return SquircleAction(kind: .buildStatus)
        case ("sim", "start"): return SquircleAction(kind: .simStart)
        case ("sim", "stop"): return SquircleAction(kind: .simStop)
        case ("sim", _): return SquircleAction(kind: .simOther)
        case ("agent", "restart"): return SquircleAction(kind: .restart)
        case ("agent", "fresh"): return SquircleAction(kind: .fresh)
        case ("agent", _): return SquircleAction(kind: .agentOther)
        case ("perf", _): return SquircleAction(kind: .perf)
        case ("media", _): return SquircleAction(kind: .media)
        default: return group.isEmpty ? nil : SquircleAction(kind: .other)
        }
    }

    static func uuid(_ text: String) -> String? {
        UUID(uuidString: text) != nil ? text.lowercased() : nil
    }

    /// A command's output: Squircle's JSON envelope, often cut short by `| head`.
    fileprivate struct Output {
        let text: String
        init(_ text: String?) { self.text = text ?? "" }
        /// `"key": "value"` anywhere in the text, whole or truncated.
        func string(_ key: String) -> String? {
            guard let range = text.range(of: #""\#(key)"\s*:\s*"([^"]*)""#, options: .regularExpression) else { return nil }
            let match = text[range]
            guard let open = match.dropLast().lastIndex(of: "\"") else { return nil }
            return String(match[match.index(after: open)..<match.index(before: match.endIndex)])
        }
        /// Squircle's error envelope, `{"error": {…}, "ok": false}`.
        var isError: Bool {
            text.range(of: #"^\s*\{\s*"error"\s*:\s*\{"#, options: .regularExpression) != nil
        }
        /// Output, but not Squircle's reply (`| grep` filtered it away).
        var isOther: Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("{") && firstUUID == nil
        }
        var firstUUID: String? {
            text.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, options: .regularExpression)
                .map { text[$0].lowercased() }
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
