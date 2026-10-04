import Combine
import Foundation

@MainActor
final class SquircleModel: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var builds: [AppBuild] = []
    @Published private(set) var approvals: [AgentApproval] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRunning = false
    @Published private(set) var connected = false
    @Published private(set) var status = "Connecting to your Mac…"
    @Published private(set) var error: String?

    var isConfigured: Bool { client != nil }
    var hostName: String { configuration?.hermesURL.host ?? "Your Mac" }

    private let configuration: AppConfiguration?
    private let client: HermesClient?
    private let defaults: UserDefaults
    private let preferencePrefix: String
    // These are reconnect pointers, not another conversation database. Hermes
    // remains authoritative for history, approvals, and run outcomes.
    private var activeRuns: [String: String]
    private var monitor: Task<Void, Never>?
    private var monitorGeneration = UUID()
    private var selectionGeneration = UUID()
    private let embeddedBuildID: String
    private let launchEventID = UUID().uuidString.lowercased()
    private let launchTimestamp = Int(Date().timeIntervalSince1970)
    private var launchReported = false

    init(configuration: AppConfiguration? = try? AppConfiguration.load(),
         defaults: UserDefaults = .standard, client: HermesClient? = nil,
         embeddedBuildID: String? = nil) {
        self.configuration = configuration
        self.client = client ?? configuration.map { HermesClient(configuration: $0) }
        self.defaults = defaults
        // Different Mac endpoints must not share session/run pointers.
        preferencePrefix = "squircle.\(configuration?.hermesURL.absoluteString ?? "unconfigured")"
        selectedSessionID = defaults.string(forKey: "\(preferencePrefix).selectedSession")
        activeRuns = defaults.dictionary(forKey: "\(preferencePrefix).activeRuns") as? [String: String] ?? [:]
        self.embeddedBuildID = embeddedBuildID ?? Bundle.main.object(forInfoDictionaryKey: "SquircleBuildID") as? String ?? ""
        if self.client == nil { status = "Connection configuration is missing from this build." }
    }

    func refresh() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        do {
            sessions = try await client.sessions()
            connected = true
            if selectedSessionID == nil, let first = sessions.first {
                selectedSessionID = first.id
                persistSelection()
            }
            if let id = selectedSessionID { await selectSession(id) }
            else { status = "Connected. Start a conversation." }
        } catch { show(error); connected = false }
        // The build service has its own availability; its list remains useful
        // even while the agent gateway reconnects.
        await refreshBuilds()
        await reportLaunchIfNeeded()
    }

    func selectSession(_ id: String) async {
        guard let client else { return }
        let generation = UUID()
        selectionGeneration = generation
        stopMonitoring()
        if selectedSessionID != id { messages = [] }
        selectedSessionID = id
        persistSelection()
        approvals = []
        isRunning = activeRuns[id] != nil
        do {
            let page = try await client.messages(sessionID: id)
            guard generation == selectionGeneration else { return }
            messages = page.messages
            connected = true
            error = nil
            status = isRunning ? "Reconnecting to Hermes…" : "Connected to your Mac"
            if let run = activeRuns[id] { startMonitoring(sessionID: id, runID: run) }
        } catch {
            guard generation == selectionGeneration else { return }
            show(error)
            if (error as? ClientError)?.isMissing == true {
                activeRuns.removeValue(forKey: id)
                selectedSessionID = nil
                messages = []
                isRunning = false
                persistSelection()
                persistRuns()
            }
        }
    }

    func createSession() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let session = try await client.createSession()
            sessions.insert(session, at: 0)
            await selectSession(session.id)
        } catch { show(error) }
    }

    func send(_ text: String) async {
        guard let client, !isRunning, !isLoading else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if selectedSessionID == nil { await createSession() }
        guard let sessionID = selectedSessionID, activeRuns[sessionID] == nil else { return }
        error = nil
        isRunning = true
        status = "Sending to Hermes…"
        let localID = "pending-\(UUID().uuidString)"
        messages.append(ChatMessage(id: localID, role: "user", content: text))
        let key = UUID().uuidString.lowercased()
        do {
            let runID = try await client.startRun(sessionID: sessionID, text: text, idempotencyKey: key)
            activeRuns[sessionID] = runID
            persistRuns()
            if selectedSessionID == sessionID {
                connected = true
                status = "Hermes is working"
                startMonitoring(sessionID: sessionID, runID: runID)
            }
        } catch {
            if selectedSessionID == sessionID {
                isRunning = false
                show(error)
                status = "Submission was not confirmed. Refresh the conversation before sending again."
                // Never silently replay a message after an ambiguous acceptance.
            }
        }
    }

    func stop() async {
        guard let client, let id = selectedSessionID, let runID = activeRuns[id] else { return }
        do {
            try await client.stop(runID)
            if selectedSessionID == id { status = "Stopping Hermes…" }
            // The server, not the tap, decides when cancellation has completed.
        } catch { show(error) }
    }

    func resolveApproval(_ approval: AgentApproval, approved: Bool) async {
        guard let client else { return }
        do {
            try await client.resolve(approval, approved: approved)
            approvals.removeAll { $0.id == approval.id }
            status = approved ? "Approved once. Hermes is continuing." : "Approval denied."
        } catch { show(error) }
    }

    func installURL(for build: AppBuild) async -> URL? {
        guard let client, build.canInstall else { return nil }
        do { return try await client.installURL(buildID: build.id) }
        catch { show(error); return nil }
    }

    private func refreshBuilds() async {
        guard let client else { return }
        do { builds = try await client.builds() }
        catch { if self.error == nil { show(error) } }
    }

    private func reportLaunchIfNeeded() async {
        guard let client, !launchReported, UUID(uuidString: embeddedBuildID) != nil else { return }
        do {
            try await client.reportLaunch(buildID: embeddedBuildID, eventID: launchEventID, timestamp: launchTimestamp)
            launchReported = true
        } catch {
            // Retry the same payload on foreground; launch acknowledgement is
            // useful telemetry, not a prerequisite for chatting with Hermes.
        }
    }

    private func startMonitoring(sessionID: String, runID: String) {
        stopMonitoring()
        let generation = monitorGeneration
        monitor = Task { [weak self] in
            await self?.monitorRun(sessionID: sessionID, runID: runID, generation: generation)
        }
    }

    private func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
        monitorGeneration = UUID()
    }

    private func monitorRun(sessionID: String, runID: String, generation: UUID) async {
        guard let client else { return }
        var lastSequence: Int?
        while !Task.isCancelled && generation == monitorGeneration && selectedSessionID == sessionID {
            do {
                let run = try await client.run(runID)
                guard generation == monitorGeneration, selectedSessionID == sessionID else { return }
                connected = true
                if run.terminal {
                    await finish(run: run, sessionID: sessionID, generation: generation)
                    return
                }
                isRunning = true
                status = run.status == "waiting_for_approval" ? "Hermes needs your approval" : "Hermes is working"
                if let approval = run.approval?.approval(runID: runID), !approvals.contains(where: { $0.id == approval.id }) {
                    approvals.append(approval)
                }
                // Replaying from the start after a fresh history load reconstructs
                // only transient progress; the final persisted history replaces it.
                try await client.events(runID: runID, after: lastSequence) { [weak self] event in
                    guard let self else { return }
                    guard generation == self.monitorGeneration, self.selectedSessionID == sessionID else { return }
                    guard event.run_id == nil || event.run_id == runID else { return }
                    if let seq = event.seq {
                        if let previous = lastSequence, seq <= previous { return }
                        lastSequence = seq
                    }
                    self.consume(event, runID: runID)
                }
            } catch is CancellationError { return }
            catch let failure as ClientError where failure.isMissing {
                guard generation == monitorGeneration else { return }
                // Durable status or the event backlog may expire independently.
                // A status lookup distinguishes them before forgetting the pointer.
                do {
                    let current = try await client.run(runID)
                    guard generation == monitorGeneration else { return }
                    if current.terminal {
                        await finish(run: current, sessionID: sessionID, generation: generation)
                        return
                    }
                    status = "Waiting for Hermes progress…"
                } catch let missing as ClientError where missing.isMissing {
                    guard generation == monitorGeneration else { return }
                    activeRuns.removeValue(forKey: sessionID)
                    persistRuns()
                    isRunning = false
                    approvals = []
                    if let page = try? await client.messages(sessionID: sessionID), generation == monitorGeneration { messages = page.messages }
                    status = "Run status is no longer available. Conversation history has been refreshed."
                    return
                } catch {
                    guard generation == monitorGeneration else { return }
                    connected = false
                    show(error)
                }
            } catch {
                guard generation == monitorGeneration else { return }
                connected = false
                status = "Reconnecting to Hermes…"
                show(error)
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func consume(_ event: RunEvent, runID: String) {
        guard let name = event.event else { return }
        switch name {
        case "message.delta":
            appendProgress(event.delta ?? "", runID: runID)
        case "message.interim":
            if event.already_streamed != true { appendProgress(event.text ?? "", runID: runID) }
            appendProgress("\n\n", runID: runID)
        case "tool.started":
            appendProgress("", runID: runID)
            if let index = messages.firstIndex(where: { $0.id == "run-\(runID)" }), let tool = event.tool {
                messages[index].tools.append(tool)
            }
            status = event.tool.map { "Using \($0)" } ?? "Hermes is working"
        case "tool.completed": status = "Hermes is working"
        case "approval.request":
            if let approval = event.approval(runID: runID), !approvals.contains(where: { $0.id == approval.id }) { approvals.append(approval) }
            status = "Hermes needs your approval"
        case "approval.responded":
            if let id = event.request_id { approvals.removeAll { $0.id == id } }
        case "replay.truncated":
            messages.removeAll { $0.id == "run-\(runID)" }
            status = "Catching up with Hermes…"
        case "run.completed", "run.failed", "run.cancelled", "run.interrupted":
            status = "Updating conversation…"
        default: break // In particular, never display reasoning.available.
        }
    }

    private func appendProgress(_ text: String, runID: String) {
        let id = "run-\(runID)"
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].content += text }
        else { messages.append(ChatMessage(id: id, role: "assistant", content: text, isStreaming: true)) }
    }

    private func finish(run: RunStatus, sessionID: String, generation: UUID) async {
        guard let client, generation == monitorGeneration else { return }
        activeRuns.removeValue(forKey: sessionID)
        persistRuns()
        isRunning = false
        approvals = []
        for index in messages.indices { messages[index].isStreaming = false }
        do {
            let page = try await client.messages(sessionID: sessionID)
            guard generation == monitorGeneration, selectedSessionID == sessionID else { return }
            messages = page.messages
            if let output = run.output, !output.isEmpty, !messages.contains(where: { $0.role == "assistant" && $0.content == output }) {
                messages.append(ChatMessage(id: "result-\(run.run_id)", role: "assistant", content: output))
            }
            let updatedSessions = try await client.sessions()
            guard generation == monitorGeneration, selectedSessionID == sessionID else { return }
            sessions = updatedSessions
            error = nil
            status = run.status == "completed" ? "Connected to your Mac" : "Run \(run.status)."
        } catch { show(error) }
        await refreshBuilds()
    }

    private func persistSelection() { defaults.set(selectedSessionID, forKey: "\(preferencePrefix).selectedSession") }
    private func persistRuns() { defaults.set(activeRuns, forKey: "\(preferencePrefix).activeRuns") }
    private func show(_ error: Error) {
        self.error = (error as? ClientError)?.localizedDescription ?? "The connection could not complete this operation."
    }
}
