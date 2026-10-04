import Combine
import Foundation

@MainActor
final class SquircleModel: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var builds: [AppBuild] = []
    @Published private(set) var projects: [AppProject] = []
    @Published private(set) var appMetadata: [AppMetadata] = []
    @Published private(set) var selectedProjectID: String?
    @Published private(set) var buildingProjectIDs: Set<String> = []
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
    private var catalog: AppProjectCatalog
    private var buildMonitor: Task<Void, Never>?
    private var metadataMonitor: Task<Void, Never>?
    private var metadataGeneration = UUID()
    private var loadingOperations = 0
    private var sessionRevision = 0
    private var buildRevision = 0
    private let previewCache = NSCache<NSString, NSData>()
    private var previewRequests: [String: Task<Data, Error>] = [:]
    private var pendingSubmissions: Set<String> = []
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
        selectedProjectID = defaults.string(forKey: "\(preferencePrefix).selectedProject")
        activeRuns = defaults.dictionary(forKey: "\(preferencePrefix).activeRuns") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "\(preferencePrefix).projects"), let stored = try? JSONDecoder().decode(AppProjectCatalog.self, from: data) {
            catalog = stored
        } else { catalog = AppProjectCatalog() }
        self.embeddedBuildID = embeddedBuildID ?? Bundle.main.object(forInfoDictionaryKey: "SquircleBuildID") as? String ?? ""
        previewCache.countLimit = 12
        previewCache.totalCostLimit = 48 * 1024 * 1024
        reconcileProjects()
        if self.client == nil { status = "Connection configuration is missing from this build." }
    }

    func refresh() async {
        guard let client, !isLoading else { return }
        beginLoading()
        defer { endLoading() }
        let selectionAtStart = selectionGeneration
        let revisionAtStart = sessionRevision
        error = nil
        var loadedBuilds = false
        do {
            let listed = try await client.sessions()
            mergeSessions(listed, requestedAtRevision: revisionAtStart)
            connected = true
            // Discover apps from real builds before migrating unassigned chats.
            await refreshBuilds()
            loadedBuilds = true
            let buildError = error
            if selectionGeneration == selectionAtStart, selectedSessionID == nil,
               let project = projects.first(where: { $0.id == selectedProjectID }),
               let first = sessions(for: project).first {
                selectedSessionID = first.id
                persistSelection()
            }
            if selectionGeneration == selectionAtStart {
                if let id = selectedSessionID { await selectSession(id) }
                else { status = "Connected. Start a conversation." }
            }
            if let buildError { error = buildError }
        } catch { show(error); connected = false }
        // The build service has its own availability; its list remains useful
        // even while the agent gateway reconnects.
        if !loadedBuilds { await refreshBuilds() }
        await reportLaunchIfNeeded()
    }

    func selectSession(_ id: String) async {
        guard let client else { return }
        beginLoading()
        defer { endLoading() }
        let generation = UUID()
        selectionGeneration = generation
        stopMonitoring()
        if selectedSessionID != id { messages = [] }
        selectedSessionID = id
        if let projectID = catalog.sessionProjects[id] { selectedProjectID = projectID }
        persistSelection()
        approvals = []
        isRunning = activeRuns[id] != nil || pendingSubmissions.contains(id)
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
        guard let project = projects.first(where: { $0.id == selectedProjectID }) ?? projects.first else { return }
        await createSession(in: project)
    }

    func sessions(for project: AppProject) -> [ChatSession] {
        sessions.filter { catalog.sessionProjects[$0.id] == project.id }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func builds(for project: AppProject) -> [AppBuild] {
        builds.filter { catalog.buildProjects[$0.id] == project.id }.sorted { $0.date > $1.date }
    }

    func metadata(for project: AppProject) -> AppMetadata? {
        appMetadata.first { $0.id == project.metadataID }
    }

    func startMetadataUpdates() {
        guard client != nil, metadataMonitor == nil else { return }
        metadataMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isLoading { await self.refreshMetadata() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func stopMetadataUpdates() {
        metadataMonitor?.cancel()
        metadataMonitor = nil
    }

    func refreshMetadata() async {
        await fetchMetadata()
        reconcileProjects()
    }

    private func fetchMetadata() async {
        guard let client else { return }
        let generation = UUID()
        metadataGeneration = generation
        do {
            let records = try await client.fetchAppMetadata()
            guard generation == metadataGeneration, !Task.isCancelled else { return }
            if records != appMetadata { appMetadata = records }
        } catch is CancellationError { return }
        catch { if generation == metadataGeneration, error is ClientError, self.error == nil { show(error) } }
    }

    /// Build previews are immutable artifacts. Keep a small in-memory cache;
    /// conversation refreshes do not redownload the same captured image.
    func previewData(for build: AppBuild) async throws -> Data {
        guard let client else { throw ClientError.configuration }
        // A manual recapture may replace the image for an existing build.
        let key = "build|\(build.id)|\(build.previewCapturedAt?.timeIntervalSince1970 ?? 0)"
        return try await cachedPreview(key: key) { try await client.fetchBuildPreview(id: build.id) }
    }

    func previewData(for metadata: AppMetadata) async throws -> Data {
        guard let client else { throw ClientError.configuration }
        guard let preview = metadata.preview else { throw ClientError.http("Squircle", 404) }
        let key = "app|\(metadata.id)|\(preview.id)"
        return try await cachedPreview(key: key) { try await client.fetchAppPreview(id: metadata.id, previewID: preview.id) }
    }

    private func cachedPreview(key: String, fetch: @escaping () async throws -> Data) async throws -> Data {
        if let cached = previewCache.object(forKey: key as NSString) { return cached as Data }
        if let pending = previewRequests[key] { return try await pending.value }
        let task = Task { try await fetch() }
        previewRequests[key] = task
        defer { previewRequests[key] = nil }
        let data = try await task.value
        previewCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    func createProject(name: String) -> AppProject {
        let id = catalog.create(name: name)
        reconcileProjects()
        let project = projects.first { $0.id == id }!
        selectProject(project)
        return project
    }

    func selectProject(_ project: AppProject) {
        guard projects.contains(where: { $0.id == project.id }) else { return }
        if selectedProjectID != project.id {
            stopMonitoring()
            selectionGeneration = UUID()
            selectedSessionID = nil
            messages = []
            approvals = []
            isRunning = false
        }
        selectedProjectID = project.id
        persistSelection()
    }

    func createSession(in project: AppProject, title: String? = nil) async {
        guard let client else { return }
        beginLoading()
        defer { endLoading() }
        // A new thread may be opened during a foreground refresh. Invalidate
        // its old selection immediately rather than silently ignoring the tap.
        stopMonitoring()
        selectionGeneration = UUID()
        let creationSelection = selectionGeneration
        selectedProjectID = project.id
        selectedSessionID = nil
        messages = []
        approvals = []
        isRunning = false
        persistSelection()
        do {
            let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let session = try await client.createSession(title: cleanTitle?.isEmpty == false ? cleanTitle : "\(project.name) · \(sessions(for: project).count + 1)")
            catalog.assign(sessionID: session.id, to: project.id)
            sessionRevision += 1
            sessions.insert(session, at: 0)
            reconcileProjects()
            if creationSelection == selectionGeneration { await selectSession(session.id) }
        } catch {
            if creationSelection == selectionGeneration { show(error) }
        }
    }

    func send(_ text: String) async {
        guard let client, !isRunning, !isLoading else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if selectedSessionID == nil { await createSession() }
        guard let sessionID = selectedSessionID, activeRuns[sessionID] == nil,
              !pendingSubmissions.contains(sessionID) else { return }
        pendingSubmissions.insert(sessionID)
        defer {
            pendingSubmissions.remove(sessionID)
            isRunning = selectedSessionID.map { activeRuns[$0] != nil || pendingSubmissions.contains($0) } ?? false
        }
        error = nil
        isRunning = true
        status = "Sending to Hermes…"
        let localID = "pending-\(UUID().uuidString)"
        messages.append(ChatMessage(id: localID, role: "user", content: text))
        let key = UUID().uuidString.lowercased()
        do {
            let project = projects.first { $0.id == catalog.sessionProjects[sessionID] }
            let oldSession = sessions.first { $0.id == sessionID }
            let runID = try await client.startRun(sessionID: sessionID, text: text, idempotencyKey: key, projectContext: project?.agentContext)
            activeRuns[sessionID] = runID
            persistRuns()
            if selectedSessionID == sessionID {
                connected = true
                status = "Hermes is working"
                startMonitoring(sessionID: sessionID, runID: runID)
            }
            if let project, let oldSession, oldSession.messageCount == 0 {
                let prefix = project.name + " · "
                if oldSession.title.hasPrefix(prefix), Int(oldSession.title.dropFirst(prefix.count)) != nil {
                    Task { [weak self] in await self?.nameSession(sessionID, project: project, firstMessage: text) }
                }
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

    @discardableResult
    func startBuild(for project: AppProject) async -> AppBuild? {
        guard let client, !buildingProjectIDs.contains(project.id) else { return nil }
        guard let current = projects.first(where: { $0.id == project.id }), let recipe = current.buildRequest, recipe.canSubmit else {
            error = "Start a conversation to set up this app’s Xcode project and first build."
            return nil
        }
        buildingProjectIDs.insert(project.id)
        defer { buildingProjectIDs.remove(project.id) }
        error = nil
        do {
            let job = try await client.startBuild(recipe.freshSubmission())
            buildRevision += 1
            catalog.assign(buildID: job.id, to: project.id)
            builds.removeAll { $0.id == job.id }
            builds.insert(job, at: 0)
            reconcileProjects()
            status = "Build queued on your Mac."
            ensureBuildMonitor()
            return job
        } catch { show(error); return nil }
    }

    private func refreshBuilds() async {
        guard let client else { return }
        let revision = buildRevision
        async let metadata: Void = fetchMetadata()
        do {
            let listed = try await client.builds()
            if revision == buildRevision { builds = listed }
            else {
                // Preserve acknowledged submissions absent from an older list;
                // use current server status for every job it did include.
                let ids = Set(listed.map(\.id))
                builds = (listed + builds.filter { !ids.contains($0.id) }).sorted { $0.date > $1.date }
            }
        }
        catch { if self.error == nil { show(error) } }
        await metadata
        reconcileProjects()
        ensureBuildMonitor()
    }

    private func reconcileProjects() {
        projects = catalog.reconcile(builds: builds, sessions: sessions, metadata: appMetadata)
        if let id = selectedSessionID, let projectID = catalog.sessionProjects[id] { selectedProjectID = projectID }
        if selectedProjectID == nil { selectedProjectID = projects.first?.id }
        if let data = try? JSONEncoder().encode(catalog) { defaults.set(data, forKey: "\(preferencePrefix).projects") }
        persistSelection()
    }

    private func mergeSessions(_ listed: [ChatSession], requestedAtRevision revision: Int) {
        if revision == sessionRevision { sessions = listed; return }
        // A list that began before a local create/rename cannot erase that
        // acknowledged mutation. The next ordinary refresh is authoritative.
        let local = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var merged = listed.map { local[$0.id] ?? $0 }
        let ids = Set(merged.map(\.id))
        merged.append(contentsOf: sessions.filter { !ids.contains($0.id) })
        sessions = merged.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func nameSession(_ id: String, project: AppProject, firstMessage: String) async {
        guard let client else { return }
        let summary = firstMessage.split(whereSeparator: \.isNewline).joined(separator: " ")
        do {
            let updated = try await client.renameSession(id, title: "\(project.name) · \(summary.prefix(64))")
            sessionRevision += 1
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = updated }
            else { sessions.insert(updated, at: 0) }
            reconcileProjects()
        } catch {
            // Naming is optional metadata; the accepted run continues even if
            // this request cannot reach Hermes.
        }
    }

    private func ensureBuildMonitor() {
        guard buildMonitor == nil, builds.contains(where: { $0.needsPolling }) else { return }
        buildMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                guard let self else { return }
                await self.refreshBuilds()
                if !self.builds.contains(where: { $0.needsPolling }) { break }
            }
            self?.buildMonitor = nil
        }
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
            let revision = sessionRevision
            let updatedSessions = try await client.sessions()
            guard generation == monitorGeneration, selectedSessionID == sessionID else { return }
            mergeSessions(updatedSessions, requestedAtRevision: revision)
            reconcileProjects()
            error = nil
            status = run.status == "completed" ? "Connected to your Mac" : "Run \(run.status)."
        } catch { show(error) }
        await refreshBuilds()
    }

    private func persistSelection() {
        defaults.set(selectedSessionID, forKey: "\(preferencePrefix).selectedSession")
        defaults.set(selectedProjectID, forKey: "\(preferencePrefix).selectedProject")
    }
    private func beginLoading() { loadingOperations += 1; isLoading = true }
    private func endLoading() { loadingOperations = max(0, loadingOperations - 1); isLoading = loadingOperations > 0 }
    private func persistRuns() { defaults.set(activeRuns, forKey: "\(preferencePrefix).activeRuns") }
    private func show(_ error: Error) {
        self.error = (error as? ClientError)?.localizedDescription ?? "The connection could not complete this operation."
    }
}
