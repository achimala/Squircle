import Foundation

/// What a shell command is doing, in a few words ("Building with
/// xcodebuild", "Reading Theme.swift"), for a live line that has only the
/// raw command: T3 sends a running command without the agent's own
/// description of it. The main program wins over `cd`, variables, wrappers
/// and whatever its output is piped through.
enum CommandLabel {
    static func label(_ command: String) -> String {
        var variables: [String: String] = [:]
        let commands = Shell.parse(unwrapped(command)).compactMap { program($0, variables: &variables) }
        // A pipe's head says what runs; its tail only trims the output.
        let heads = commands.filter { !$0.piped && !noise.contains($0.name) }
        let main = heads.first { !leadIn($0) } ?? heads.first ?? commands.first { !noise.contains($0.name) }
        guard let main else { return commands.contains { $0.name == "sleep" } ? "Waiting" : "Running a command" }
        return describe(main)
    }

    /// What else a command that runs Squircle does, besides it ("Merging"),
    /// or nil when the rest only sets up, reads its replies or trims them.
    static func besidesSquircle(_ command: String) -> String? {
        var variables: [String: String] = [:]
        let quiet: Set<String> = ["squircle", "grep", "head", "tail", "cut", "jq", "python", "python3", "wc", "sort", "uniq", "tr", "cat", "ls", "git"]
        let rest = Shell.parse(unwrapped(command)).compactMap { program($0, variables: &variables) }
            .filter { !$0.piped && !noise.contains($0.name) && !quiet.contains($0.name) || ($0.name == "git" && !["status", "log", "diff", "show", "branch", "rev-parse"].contains(gitSubcommand($0))) }
        // Only work that changes or builds something earns its own line.
        let looks = ["Running ", "Reading", "Searching", "Finding", "Listing", "Counting", "Checking git", "Checking branches", "Querying", "Fetching", "Copying", "Creating folders", "Checking simulators", "Capturing"]
        return rest.filter { !leadIn($0) }.map(describe).first { line in !looks.contains { line.hasPrefix($0) } }
    }

    /// One command reduced to its program and arguments.
    struct Program {
        var name: String
        var arguments: [String]
        var piped: Bool
        var output: String?
        /// Arguments that aren't options.
        var operands: [String] { arguments.filter { !$0.hasPrefix("-") } }
        var subcommand: String? { operands.first }
    }

    /// Commands that only set the scene.
    private static let noise: Set<String> = [
        "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "true", "false", ":", "sleep", "[", "[[", "test",
        "echo", "printf", "wait", "trap", "local", "read", "shift", "return", "exit", "break", "continue", "done", "fi", "esac",
        "for", "while", "until", "case", "select", "function"
    ]
    /// Steps that prepare for the next command (`git add -A && git commit`).
    private static func leadIn(_ p: Program) -> Bool {
        (p.name == "git" && ["add", "status"].contains(gitSubcommand(p))) || ["mkdir", "rm"].contains(p.name)
    }
    /// Words that run the next one.
    private static let wrappers: Set<String> = [
        "env", "sudo", "time", "nohup", "exec", "command", "builtin", "nice", "caffeinate", "xcrun", "npx", "bunx", "pnpx",
        "then", "do", "else", "elif", "if", "!", "{", "xargs"
    ]
    /// Wrapper options that take a value.
    private static let valued: Set<String> = ["--sdk", "-sdk", "--toolchain", "-n", "-u", "-I", "-L", "-P"]

    /// Codex runs everything as `/bin/zsh -lc '…'`.
    private static func unwrapped(_ command: String) -> String {
        let words = Shell.commands(command).first ?? []
        if words.count == 3, ["zsh", "bash", "sh"].contains(AgentStep.file(words[0])), ["-lc", "-c"].contains(words[1]) { return words[2] }
        return command
    }

    /// `variables` keeps what earlier commands assigned, so `$S sim start`
    /// after `S=…/squircle` names its program.
    private static func program(_ command: Shell.Command, variables: inout [String: String]) -> Program? {
        // `name() { … }` defines a function; its body says what it runs.
        if command.words.last == "()" { return nil }
        var words = command.words[...]
        while let first = words.first {
            if let eq = first.firstIndex(of: "="), eq != first.startIndex,
               first[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                variables[String(first[..<eq])] = String(first[first.index(after: eq)...])
                words = words.dropFirst(); continue
            }
            var name = AgentStep.file(first)
            if first.hasPrefix("$") {
                let variable = first.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                // A path with spaces (`S='…/Application Support/…/squircle'`) is one program.
                guard let value = variables[variable],
                      let program = value.hasSuffix("/squircle") ? value : Shell.commands(value).first?.first else { return nil }
                name = AgentStep.file(program)
            }
            // An array's elements (`T=(--platform ios)`), not a command.
            if name.hasPrefix("-") { return nil }
            if wrappers.contains(name) {
                words = words.dropFirst()
                while let option = words.first, option.hasPrefix("-") {
                    words = words.dropFirst()
                    if valued.contains(option) { words = words.dropFirst() }
                }
                continue
            }
            // `timeout 60 cmd`, `uv run cmd`, `bundle exec cmd`.
            if ["timeout", "gtimeout"].contains(name) {
                words = words.dropFirst().drop { $0.hasPrefix("-") }.dropFirst(); continue
            }
            if words.count > 1, (["uv", "poetry", "pipenv", "pnpm", "yarn"].contains(name) && words.dropFirst().first == "exec")
                || (["uv", "poetry", "pipenv"].contains(name) && words.dropFirst().first == "run")
                || (name == "bundle" && words.dropFirst().first == "exec") {
                words = words.dropFirst(2); continue
            }
            return Program(name: name, arguments: Array(words.dropFirst()), piped: command.piped, output: command.output)
        }
        return nil
    }

    private static func describe(_ p: Program) -> String {
        let sub = p.subcommand ?? ""
        let paths = p.operands.filter(looksLikeFile)
        func files(_ verb: String) -> String {
            paths.count == 1 ? verb + " " + AgentStep.file(paths[0]) : paths.isEmpty ? "Running \(p.name)" : "\(verb) \(paths.count) files"
        }
        switch p.name {
        case "xcodebuild":
            if p.arguments.contains(where: { $0 == "test" || $0 == "test-without-building" }) { return "Testing with xcodebuild" }
            if p.arguments.contains("archive") { return "Archiving with xcodebuild" }
            if p.arguments.contains(where: { ["-list", "-showBuildSettings", "-version", "-showsdks"].contains($0) }) { return "Reading the Xcode project" }
            return "Building with xcodebuild"
        case "cargo", "swift", "go", "npm", "pnpm", "yarn", "bun", "make", "gradle", "gradlew", "mvn", "dotnet", "deno", "xcodegen":
            return tool(p.name, sub, p)
        case "tsc": return "Checking types"
        case "swiftc", "clang", "gcc", "cc", "rustc": return "Compiling"
        case "git": return git(p)
        case "gh":
            let operands = p.operands
            if operands.starts(with: ["pr", "create"]) { return "Opening a pull request" }
            return "Running gh" + (operands.first.map { " " + $0 } ?? "")
        case "cat", "head", "tail", "less", "more", "bat", "nl", "wc":
            if let output = p.output, p.name == "cat" { return "Writing " + AgentStep.file(output) }
            return files(p.name == "wc" ? "Counting lines in" : "Reading")
        case "sed":
            if p.arguments.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }) { return files("Editing") }
            return files("Reading")
        case "tee": return files("Writing")
        case "grep", "rg", "ag", "ack", "egrep", "fgrep": return "Searching with \(p.name)"
        case "find", "fd", "mdfind": return "Finding files"
        case "ls", "tree", "du": return "Listing files"
        case "curl", "wget", "http", "xh":
            let host = p.operands.lazy.compactMap { URL(string: $0)?.host }.first
            return "Fetching " + (host ?? "a URL")
        case "open": return "Opening " + (p.operands.first.map(AgentStep.file) ?? "a file")
        case "rm", "trash": return "Removing files"
        case "mkdir": return "Creating folders"
        case "cp", "ditto", "rsync": return "Copying files"
        case "mv": return "Moving files"
        case "sqlite3": return "Querying a database"
        case "simctl": return simctl(sub)
        case "agent-device": return "Using the simulator"
        case "python", "python3", "node", "ruby", "perl", "bash", "zsh", "sh":
            if let script = p.arguments.first(where: { !$0.hasPrefix("-") }), looksLikeFile(script), !p.arguments.contains("-c"), !p.arguments.contains("-e") {
                return "Running " + AgentStep.file(script)
            }
            return "Running " + (p.name == "python3" ? "python" : p.name)
        case "pip", "pip3", "brew", "pod", "gem":
            return ["install", "add"].contains(sub) ? "Installing packages" : "Running \(p.name) \(sub)".trimmingCharacters(in: .whitespaces)
        default: return "Running " + p.name
        }
    }

    /// Build tools that name their action: `cargo test`, `npm run build`.
    private static func tool(_ name: String, _ sub: String, _ p: Program) -> String {
        let name = name == "gradlew" ? "gradle" : name
        var action = sub
        if ["npm", "pnpm", "yarn", "bun", "deno"].contains(name), ["run", "task"].contains(sub) { action = p.operands.dropFirst().first ?? "" }
        if name == "make", action.isEmpty { return "Building with make" }
        if name == "xcodegen" { return "Generating the Xcode project" }
        if looksLikeFile(action) { return "Running " + AgentStep.file(action) }
        switch action {
        case "build", "b", "assemble", "compile", "package", "publish": return "Building with \(name)"
        case "test", "t", "nextest": return "Testing with \(name)"
        case "check", "clippy", "lint", "vet", "typecheck", "tsc": return "Checking with \(name)"
        case "fmt", "format": return "Formatting with \(name)"
        case "install", "i", "add", "ci", "fetch", "resolve", "get", "restore": return "Installing packages"
        case "run", "start", "dev", "serve", "preview":
            return "Running " + (name == "cargo" || name == "swift" || name == "go" ? "with \(name)" : "\(name) \(action)")
        case "": return "Running \(name)"
        default: return "Running \(name) \(action)"
        }
    }

    /// `git -C path`, `git -c key=value` come before the subcommand.
    private static func gitSubcommand(_ p: Program) -> String {
        var arguments = p.arguments[...]
        while let first = arguments.first, first.hasPrefix("-") {
            arguments = arguments.dropFirst()
            if first == "-C" || first == "-c" { arguments = arguments.dropFirst() }
        }
        return arguments.first ?? ""
    }

    private static func git(_ p: Program) -> String {
        switch gitSubcommand(p) {
        case "commit": return "Committing"
        case "status": return "Checking git status"
        case "diff", "show": return "Reading changes"
        case "log", "reflog", "blame", "shortlog": return "Reading git history"
        case "add", "rm", "mv": return "Staging changes"
        case "push": return "Pushing"
        case "pull", "fetch": return "Pulling"
        case "checkout", "switch": return "Switching branches"
        case "branch": return "Checking branches"
        case "merge": return "Merging"
        case "rebase": return "Rebasing"
        case "cherry-pick": return "Cherry-picking"
        case "stash": return "Stashing changes"
        case "reset", "restore": return "Restoring files"
        case "worktree": return "Managing worktrees"
        case "clone": return "Cloning"
        case "grep": return "Searching with git grep"
        case "": return "Running git"
        case let sub: return "Running git " + sub
        }
    }

    private static func simctl(_ sub: String) -> String {
        switch sub {
        case "boot": return "Booting a simulator"
        case "install": return "Installing on the simulator"
        case "launch": return "Launching on the simulator"
        case "io": return "Capturing the simulator"
        case "list": return "Checking simulators"
        default: return "Using the simulator"
        }
    }

    /// A path or a name with an extension, not a pattern or an expression.
    private static func looksLikeFile(_ word: String) -> Bool {
        guard !word.isEmpty, !word.contains(where: { " \n*?{}$=;'\"".contains($0) }) else { return false }
        return word.contains("/") || word.split(separator: ".").last.map { $0.count <= 6 && $0.count < word.count && $0.allSatisfy(\.isLetter) } == true
    }
}
