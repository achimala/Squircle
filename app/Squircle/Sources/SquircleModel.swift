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

    @Published private(set) var hermesQuestions: [HermesQuestion] = []
    @Published private(set) var hermesControl: JSONValue = .null
    @Published var composerPrefill: String?
    private var gateway: HermesGateway?
    private var gatewayWatch: Task<Void, Never>?
    private var gatewayGeneration: UUID?
    private var replayEpoch: String?
    private var runtimeIDs: [String: String] = [:]
    private var conversations: [String: HermesConversation] = [:]
    private var turnVersions: [String: Int] = [:]
    private var attaching: Set<String> = []
    private var bufferedEvents: [JSONValue] = []
    private var bufferedRequests: [JSONValue] = []
    private var sessionListRefresh: Task<Void, Never>?

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
    private var importGeneration = UUID()
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
        if let configuration, configuration.desktopURL != nil {
            let gateway = HermesGateway(configuration: configuration)
            self.gateway = gateway
            gateway.onEvent = { [weak self] in self?.receiveHermesEvent($0) }
            gateway.onRequest = { [weak self] in self?.receiveHermesRequest($0) }
            gateway.onDisconnect = { [weak self] in
                self?.connected = false
                self?.status = "Reconnecting to Hermes…"
            }
        }
        reconcileProjects()
        if self.client == nil { status = "Connection configuration is missing from this build." }
    }

    func refresh() async {
        guard client != nil, !isLoading else { return }
        beginLoading()
        defer { endLoading() }
        let selectionAtStart = selectionGeneration
        let revisionAtStart = sessionRevision
        error = nil
        var loadedBuilds = false
        do {
            let listed = try await listHermesSessions()
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
        if gateway != nil { await selectDesktopSession(id); return }
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
        // A retained gallery/workspace view may predate registration on the
        // Mac. Resolve its stable local identity before reading the record ID.
        let current = projects.first { $0.id == project.id } ?? project
        return appMetadata.first { $0.id == current.metadataID }
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

    func browseMacProjects(path: String? = nil) async throws -> MacProjectDirectory {
        guard let client else { throw ClientError.configuration }
        return try await client.browseMacProjects(path: path)
    }

    func inspectMacProject(project: String, scheme: String? = nil, configuration: String? = nil) async throws -> MacProjectInspection {
        guard let client else { throw ClientError.configuration }
        return try await client.inspectMacProject(project: project, scheme: scheme, configuration: configuration)
    }

    func importMacProject(project: String, scheme: String, name: String, configuration: String? = nil) async throws -> AppProject {
        guard let client else { throw ClientError.configuration }
        try Task.checkCancellation()
        let generation = UUID()
        importGeneration = generation
        let selectionAtStart = selectionGeneration
        beginLoading()
        defer { endLoading() }
        let record = try await client.importMacProject(project: project, scheme: scheme, name: name, configuration: configuration)
        // A list started before this acknowledged write cannot erase the app.
        metadataGeneration = UUID()
        appMetadata.removeAll { $0.id == record.id }
        appMetadata.append(record)
        reconcileProjects()
        guard let imported = projects.first(where: { $0.metadataID == record.id }) else { throw ClientError.response("Squircle") }
        try Task.checkCancellation()
        if generation == importGeneration, selectionAtStart == selectionGeneration { selectProject(imported) }
        return imported
    }

    func selectProject(_ project: AppProject) {
        guard projects.contains(where: { $0.id == project.id }) else { return }
        if selectedProjectID != project.id {
            stopMonitoring()
            selectionGeneration = UUID()
            selectedSessionID = nil
            messages = []
            hermesQuestions = []
            hermesControl = .null
            approvals = []
            isRunning = false
        }
        selectedProjectID = project.id
        persistSelection()
    }

    func createSession(in project: AppProject, title: String? = nil) async {
        if gateway != nil { await createDesktopSession(in: project, title: title); return }
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
        if gateway != nil { await sendDesktop(text); return }
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
        if let gateway, let id = selectedSessionID, let runtime = runtimeIDs[id] {
            do { _ = try await gateway.call("session.interrupt", ["session_id": .string(runtime)]); status = "Stopping Hermes…" }
            catch { show(error) }
            return
        }
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

extension SquircleModel {
    func codingTraceChunk(_ path: String, sessionID: String, offset: Int) async throws -> (Data, Bool) {
        guard let gateway else { throw ClientError.configuration }
        return try await gateway.traceChunk(path, sessionID: sessionID, offset: offset)
    }

    private func listHermesSessions() async throws -> [ChatSession] {
        guard let gateway else { return try await client?.sessions() ?? [] }
        try await gateway.connect()
        ensureGatewayWatch()
        let result = try await gateway.call("session.list", ["limit": .number(500)])
        return try JSONDecoder().decode([ChatSession].self, from: JSONEncoder().encode(result["sessions"]))
    }

    private func ensureGatewayWatch() {
        guard gatewayWatch == nil else { return }
        gatewayGeneration = gateway?.generation
        gatewayWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let gateway = self.gateway else { return }
                do {
                    try await gateway.connect()
                    if gatewayGeneration != gateway.generation {
                        gatewayGeneration = gateway.generation
                        for id in Array(runtimeIDs.keys) where id != selectedSessionID { try await attachDesktop(id) }
                        if let id = selectedSessionID { try await attachDesktop(id) }
                    }
                    _ = try await gateway.call("ping")
                    connected = true
                } catch { connected = false; show(error) }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private func selectDesktopSession(_ id: String) async {
        beginLoading(); defer { endLoading() }
        selectionGeneration = UUID()
        selectedSessionID = id
        if let projectID = catalog.sessionProjects[id] { selectedProjectID = projectID }
        persistSelection()
        publishDesktop(id)
        do {
            try await attachDesktop(id)
            ensureGatewayWatch()
            connected = true; error = nil
        } catch { show(error) }
    }

    private func attachDesktop(_ id: String) async throws {
        guard let gateway, !attaching.contains(id) else { return }
        attaching.insert(id)
        defer {
            attaching.remove(id)
            if attaching.isEmpty {
                let events = bufferedEvents; bufferedEvents = []
                for event in events { receiveHermesEvent(event) }
                let requests = bufferedRequests; bufferedRequests = []
                for request in requests { receiveHermesRequest(request) }
            }
        }
        let oldRuntime = runtimeIDs[id]
        let oldSequence = conversations[id]?.lastSequence ?? 0
        let snapshot = try await gateway.call("session.resume", ["session_id": .string(id), "source": .string("desktop"), "close_on_disconnect": .bool(false)])
        guard let runtime = snapshot["session_id"].string else { throw ClientError.response("Hermes") }
        runtimeIDs[id] = runtime
        // Reuse the live projection only when the replay can bridge the gap.
        let replay = try await gateway.call("session.events.since", ["session_id": .string(runtime), "last_seen": .number(Double(oldSequence))])
        if oldRuntime == runtime, oldSequence > 0, !replay["truncated"].bool, conversations[id] != nil {
            for event in replay["events"].array { conversations[id]?.consume(event) }
            conversations[id]?.questions = snapshot["open_requests"].array.compactMap(HermesConversation.question).filter { HermesQuestion.supported.contains($0.method) }
            conversations[id]?.running = snapshot["running"].bool || snapshot["info"]["running"].bool
        } else {
            var conversation = HermesConversation()
            conversation.hydrate(snapshot)
            // The snapshot already contains historical events. Only frames received
            // after its response belong on top; replaying the whole ring duplicates history.
            let boundary = snapshot["_client_order"].int ?? 0
            for event in bufferedEvents where event["session_id"].string == runtime && (event["_client_order"].int ?? 0) > boundary { conversation.consume(event) }
            conversation.lastSequence = max(conversation.lastSequence, replay["latest_seq"].int ?? 0)
            conversations[id] = conversation
        }
        if conversations[id]?.running == false, let rows = try? await gateway.transcript(id) {
            let boundary = snapshot["_client_order"].int ?? 0
            let started = bufferedEvents.contains { $0["session_id"].string == runtime && $0["type"].string == "message.start" && ($0["_client_order"].int ?? 0) > boundary }
            if !started { conversations[id]?.messages = HermesConversation.project(rows) }
        }
        let control = try await gateway.call("session.control.read", ["session_id": .string(runtime)])
        conversations[id]?.control = control["control"] == .null ? control : control["control"]
        publishDesktop(id)
    }

    private func createDesktopSession(in project: AppProject, title: String?) async {
        guard let gateway else { return }
        beginLoading(); defer { endLoading() }
        error = nil
        let name = title ?? "\(project.name) · \(sessions(for: project).count + 1)"
        var params: [String: JSONValue] = ["source": .string("desktop"), "title": .string(name), "close_on_disconnect": .bool(false), "idempotency_key": .string(UUID().uuidString)]
        if let path = metadata(for: project)?.project ?? project.buildRequest?.project {
            params["cwd"] = .string(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            params["cwd_explicit"] = .bool(true)
        }
        do {
            attaching.insert("__creating__")
            defer {
                attaching.remove("__creating__")
                let events = bufferedEvents; bufferedEvents = []
                for event in events { receiveHermesEvent(event) }
                let requests = bufferedRequests; bufferedRequests = []
                for request in requests { receiveHermesRequest(request) }
            }
            let snapshot = try await gateway.call("session.create", params)
            guard let id = snapshot["stored_session_id"].string, let runtime = snapshot["session_id"].string else { throw ClientError.response("Hermes") }
            runtimeIDs[id] = runtime
            var conversation = HermesConversation(); conversation.hydrate(snapshot); conversations[id] = conversation
            catalog.assign(sessionID: id, to: project.id)
            sessions.insert(ChatSession(id: id, title: name), at: 0); sessionRevision += 1
            selectedSessionID = id; selectedProjectID = project.id
            reconcileProjects(); publishDesktop(id); ensureGatewayWatch()
        } catch { show(error) }
    }

    private func sendDesktop(_ rawText: String, depth: Int = 0) async {
        guard let gateway, depth < 5 else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if selectedSessionID == nil { await createSession() }
        guard let id = selectedSessionID else { return }
        do {
            if runtimeIDs[id] == nil { try await attachDesktop(id) }
            guard let runtime = runtimeIDs[id] else { return }
            error = nil
            if text.range(of: #"^/[^\s/]*(?:\s|$)"#, options: .regularExpression) != nil {
                let result = try await gateway.call("slash.exec", ["session_id": .string(runtime), "command": .string(text)])
                switch result["type"].string {
                case "alias": await sendDesktop(result["target"].string ?? "", depth: depth + 1)
                case "prefill": composerPrefill = result["message"].string
                case "send", "skill":
                    if let message = result["message"].string {
                        _ = try await gateway.call("prompt.submit", ["session_id": .string(runtime), "text": .string(message)])
                    }
                default:
                    if let output = result["output"].string, !output.isEmpty { conversations[id]?.notice(output) }
                }
                for key in ["warning", "notice", "error"] {
                    if let text = result[key].string, !text.isEmpty { conversations[id]?.notice(text, failed: key == "error") }
                }
                let control = try await gateway.call("session.control.read", ["session_id": .string(runtime)])
                conversations[id]?.control = control["control"]
                publishDesktop(id)
                return
            }
            let localID = "pending-\(UUID().uuidString)"
            conversations[id]?.messages.append(ChatMessage(id: localID, role: "user", content: text))
            publishDesktop(id)
            _ = try await gateway.call("prompt.submit", ["session_id": .string(runtime), "text": .string(text)])
            connected = true
        } catch {
            show(error)
            status = "Submission was not confirmed. Reconnect before retrying."
        }
    }

    private func receiveHermesEvent(_ event: JSONValue) {
        let type = event["type"].string ?? ""
        if type == "gateway.ready" {
            let epoch = event["payload"]["replay_epoch"].string
            if replayEpoch != nil, replayEpoch != epoch {
                for id in conversations.keys { conversations[id]?.lastSequence = 0 }
            }
            replayEpoch = epoch
            return
        }
        if type == "sessions.changed" || type == "session.title" { scheduleDesktopListRefresh() }
        if type == "session.reclaimed" {
            guard let runtime = event["payload"]["session_id"].string,
                  let id = runtimeIDs.first(where: { $0.value == runtime })?.key else { return }
            var scoped = event.object; scoped.removeValue(forKey: "seq")
            conversations[id]?.consume(.object(scoped)); runtimeIDs.removeValue(forKey: id); publishDesktop(id)
            return
        }
        let globalIgnore: Set<String> = ["sessions.changed", "cron.changed", "projects.changed", "platforms.changed", "skin.changed", "setup.ready", "pet.changed", "pairing.changed"]
        if (event["session_id"].string ?? "").isEmpty {
            if !globalIgnore.contains(type), let id = selectedSessionID {
                var global = event.object; global.removeValue(forKey: "seq")
                conversations[id]?.consume(.object(global)); publishDesktop(id)
            }
            return
        }
        guard let runtime = event["session_id"].string,
              let id = runtimeIDs.first(where: { $0.value == runtime || $0.key == runtime })?.key else {
            if !attaching.isEmpty { bufferedEvents.append(event) }
            return
        }
        if attaching.contains(id) { bufferedEvents.append(event); return }
        if type == "message.start" { turnVersions[id, default: 0] += 1 }
        conversations[id]?.consume(event)
        publishDesktop(id)
        if type == "message.complete" || (type == "session.resume_progress" && event["payload"]["status"].string == "complete") { refreshDesktopHistory(id) }
        if type == "session.reclaimed" { runtimeIDs.removeValue(forKey: id) }
    }

    private func refreshDesktopHistory(_ id: String) {
        guard let gateway, runtimeIDs[id] != nil else { return }
        let version = turnVersions[id, default: 0]
        Task { [weak self] in
            do {
                let rows = try await gateway.transcript(id)
                guard let self, self.turnVersions[id, default: 0] == version, self.conversations[id]?.running == false else { return }
                let projected = HermesConversation.project(rows)
                // Keep native transient activity (child rollups, notices) absent from stored history.
                let transient = self.conversations[id]?.messages.filter { $0.role == "activity" || $0.role == "notice" } ?? []
                self.conversations[id]?.messages = projected + transient
                self.publishDesktop(id)
            } catch { /* Live reply remains visible if history is temporarily unavailable. */ }
        }
    }

    private func scheduleDesktopListRefresh() {
        guard sessionListRefresh == nil else { return }
        sessionListRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            defer { self.sessionListRefresh = nil }
            let revision = self.sessionRevision
            if let listed = try? await self.listHermesSessions() {
                self.mergeSessions(listed, requestedAtRevision: revision)
                self.reconcileProjects()
            }
        }
    }

    private func receiveHermesRequest(_ frame: JSONValue) {
        guard let gateway, let question = HermesConversation.question(frame) else { return }
        let desktopOnly = ["preview.read", "preview.act", "terminal.read", "window.read", "tour"]
        if desktopOnly.contains(question.method) {
            // Let an attached Desktop window answer its own GUI requests.
            Task { try? await gateway.decline(id: question.id, code: 4404, message: "This phone does not own the Hermes Desktop window.") }
            return
        }
        let supported = HermesQuestion.supported
        guard supported.contains(question.method) else {
            Task { try? await gateway.decline(id: question.id, message: "This Hermes request is not supported by this client: \(question.method)") }
            return
        }
        guard let id = runtimeIDs.first(where: { $0.value == question.sessionID })?.key else {
            if !attaching.isEmpty { bufferedRequests.append(frame) }
            return
        }
        if conversations[id]?.questions.contains(where: { $0.id == question.id }) == false { conversations[id]?.questions.append(question) }
        publishDesktop(id)
    }

    func answerHermes(_ question: HermesQuestion, result: JSONValue) async {
        guard let gateway else { return }
        do {
            if question.method == "connection" {
                _ = try await gateway.call("connection.respond", ["profile": .string(configuration?.hermesProfile ?? "default"), "op_id": question.params["op_id"], "owner": .object(["type": .string("session"), "session_id": .string(question.sessionID)]), "result": result])
                return // The server's connection.update is authoritative.
            }
            let reply = try await gateway.call("request.answer", ["id": .string(question.id), "result": result])
            if let id = runtimeIDs.first(where: { $0.value == question.sessionID })?.key {
                conversations[id]?.questions.removeAll { $0.id == question.id }
                if reply["status"].string == "expired" { conversations[id]?.notice("This request has already ended.") }
                publishDesktop(id)
            }
        } catch { show(error) }
    }

    func openHermesChild(_ id: String) async { await selectDesktopSession(id) }

    private func publishDesktop(_ id: String) {
        guard selectedSessionID == id else { return }
        let conversation = conversations[id] ?? HermesConversation()
        messages = conversation.messages
        hermesQuestions = conversation.questions
        hermesControl = conversation.control
        isRunning = conversation.running
        status = conversation.status
        approvals = []
    }
}

extension SquircleModel {
    func performHermesControl(_ action: String) async {
        guard let gateway, let id = selectedSessionID, let runtime = runtimeIDs[id] else { return }
        do {
            let result = try await gateway.call("session.control", ["session_id": .string(runtime), "action": .string(action)])
            conversations[id]?.control = result["control"]
            if let text = result["dispatch"]["output"].string, !text.isEmpty { conversations[id]?.notice(text) }
            publishDesktop(id)
        } catch { show(error) }
    }
}


extension SquircleModel {
    func hermesAttachment(_ reference: String, sessionID: String? = nil) async throws -> URL {
        guard let gateway, let id = sessionID ?? selectedSessionID else { throw ClientError.configuration }
        return try await gateway.attachment(reference, sessionID: id)
    }
}
