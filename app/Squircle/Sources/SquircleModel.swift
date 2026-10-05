import Combine
import Foundation

@MainActor
final class SquircleModel: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var builds: [AppBuild] = []
    @Published private(set) var projects: [AppProject] = []
    @Published private(set) var appMetadata: [AppMetadata] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var selectedProjectID: String?
    @Published private(set) var buildingProjectIDs = Set<String>()
    @Published private(set) var connected = false
    @Published private(set) var isRunning = false
    @Published private(set) var isLoading = false
    @Published private(set) var status = "Connecting"
    @Published var error: String?
    @Published var composerPrefill: String?
    @Published private(set) var providers: [JSONValue] = []
    @Published private(set) var devices: JSONValue = .null
    @Published private(set) var requests: [JSONValue] = []
    @Published private(set) var modelSelection: JSONValue = .null
    private var pendingModelSelections: [String:JSONValue] = [:]
    var hostName: String { configuration?.t3URL.host ?? "Your Mac" }
    let configuration: AppConfiguration?
    let gateway: T3Gateway?
    private let client: SquircleClient?
    private var shell: JSONValue = .null
    private var state = T3ThreadState()
    private var threadSubscription: String?
    private var refreshing = false
    private var monitor: Task<Void,Never>?
    private var reconnect: Task<Void,Never>?
    private var previewCache: [String:Data] = [:]
    private var launchReported = false
    private var sessionProjects: [String:String] = [:]

    init(configuration: AppConfiguration? = try? AppConfiguration.load()) {
        self.configuration = configuration
        client = configuration.map { SquircleClient(configuration:$0) }
        gateway = configuration.map(T3Gateway.init(configuration:))
        selectedProjectID = UserDefaults.standard.string(forKey:"squircle.t3.selectedProject")
        gateway?.onDisconnect = { [weak self] in
            guard let self else { return }; connected = false; status = "Reconnecting"; reconnect?.cancel()
            reconnect = Task { [weak self] in
                var delay = 1
                while !Task.isCancelled, let self, !self.connected {
                    try? await Task.sleep(for: .seconds(delay)); if Task.isCancelled { return }
                    await self.refresh(); delay = min(delay * 2, 15)
                }
            }
        }
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; isLoading = true
        defer { refreshing = false; isLoading = false }
        guard let gateway, let client else { error = ClientError.configuration.localizedDescription; return }
        do {
            if !connected {
                try await gateway.connect()
                let config = try await gateway.call("server.getConfig")
                providers = config["providers"].array.filter { $0["enabled"].bool && $0["status"].string == "ready" }
                if modelSelection == .null, let first = providers.first {
                    let model = first["models"].array.first(where: { $0["isDefault"].bool }) ?? first["models"].array.first ?? .null
                    modelSelection = .from(["instanceId":first["instanceId"].string ?? "codex","model":model["slug"].string ?? ""])
                }
                devices = try await gateway.call("device.list")
                try await gateway.subscribe("orchestration.subscribeShell") { [weak self] in self?.consumeShell($0) }
                try await gateway.subscribe("subscribeDeviceState") { [weak self] in self?.devices = $0 }
                connected = true; status = "Connected"; error = nil
                if let id = selectedSessionID { await selectSession(id) }
            }
            async let listed = client.builds()
            async let metadata = client.fetchAppMetadata()
            builds = try await listed; appMetadata = try await metadata; reconcileProjects()
            if !launchReported, let id = Bundle.main.object(forInfoDictionaryKey:"SquircleBuildID") as? String, UUID(uuidString:id) != nil {
                try await client.reportLaunch(buildID:id,eventID:UUID().uuidString,timestamp:Int(Date.now.timeIntervalSince1970)); launchReported = true
            }
        } catch { self.error = error.localizedDescription }
    }
    private func consumeShell(_ item: JSONValue) {
        if item["kind"].string == "snapshot" { shell = item["snapshot"] }
        else {
            var s = shell.object
            switch item["kind"].string {
            case "project-upserted", "thread-upserted":
                let key = item["kind"].string == "project-upserted" ? "projects" : "threads"
                let value = item[key == "projects" ? "project" : "thread"]
                var rows = s[key]?.array ?? []
                if let i = rows.firstIndex(where: { $0["id"] == value["id"] }) { rows[i] = value } else { rows.append(value) }
                s[key] = .array(rows)
            case "project-removed", "thread-removed":
                let project = item["kind"].string == "project-removed"; let key = project ? "projects" : "threads"
                s[key] = .array((s[key]?.array ?? []).filter { $0["id"] != item[project ? "projectId" : "threadId"] })
            default: break
            }
            shell = .object(s)
        }
        sessions = shell["threads"].array.filter { $0["deletedAt"] == .null && $0["archivedAt"] == .null }.map { t in
            if let id = t["id"].string { sessionProjects[id] = t["projectId"].string }
            let working = ["running","starting"].contains(t["session"]["status"].string ?? "")
            let phase: ChatSession.Phase = t["hasPendingApprovals"].bool || t["hasPendingUserInput"].bool ? .needsYou : working ? .working : .idle
            return ChatSession(id:t["id"].string ?? "",title:t["title"].string ?? "New thread",updatedAt:t["updatedAt"].date,
                               phase:phase,modelSelection:t["modelSelection"])
        }.sorted { $0.updatedAt > $1.updatedAt }
        reconcileProjects()
    }
    private func reconcileProjects() {
        projects = T3AppCatalog.projects(shell:shell,metadata:appMetadata,builds:builds)
    }
    func selectProject(_ project: AppProject) { selectedProjectID = project.id; UserDefaults.standard.set(project.id,forKey:"squircle.t3.selectedProject") }
    func sessions(for project: AppProject) -> [ChatSession] { sessions.filter { sessionProjects[$0.id] == project.id } }
    func builds(for project: AppProject) -> [AppBuild] { builds.filter { $0.request?.key == project.buildRequest?.key && $0.request != nil } }
    func metadata(for project: AppProject) -> AppMetadata? { appMetadata.first { $0.id == project.metadataID } }
    func selectSession(_ id: String) async {
        selectedSessionID = id; messages = []; requests = []; state = T3ThreadState()
        if let pending = pendingModelSelections[id] { modelSelection = pending }
        guard let gateway else { return }
        await gateway.unsubscribe(threadSubscription); threadSubscription = nil
        do {
            threadSubscription = try await gateway.subscribe("orchestration.subscribeThread", .from(["threadId":id])) { [weak self] item in
                guard let self, selectedSessionID == id else { return }
                consumeThread(item)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    /// A new conversation that T3 has not been told about yet. The thread is
    /// created by its first message, so abandoned drafts leave nothing behind.
    func beginDraft() async {
        selectedSessionID = nil; messages = []; requests = []; state = T3ThreadState(); isRunning = false; error = nil
        await gateway?.unsubscribe(threadSubscription); threadSubscription = nil
    }
    /// "Claude · Fable 5.1" for a T3 model selection.
    func agentName(for selection: JSONValue) -> String {
        guard let provider = providers.first(where: { $0["instanceId"] == selection["instanceId"] }) else {
            return selection["model"].string ?? "Agent"
        }
        let model = provider["models"].array.first { $0["slug"] == selection["model"] }
        let name = model?["name"].string ?? selection["model"].string ?? ""
        let maker = provider["displayName"].string ?? ""
        // "Claude Fable 5.1" already says whose it is.
        return name.hasPrefix(maker) || maker.isEmpty ? name : name.isEmpty ? maker : maker + " · " + name
    }
    func chooseModel(_ selection: JSONValue) {
        modelSelection = selection
        if let id = selectedSessionID { pendingModelSelections[id] = selection }
    }
    func consumeThread(_ item: JSONValue) {
        state.consume(item); messages = state.messages; requests = state.pendingRequests
        isRunning = state.isRunning
        let saved = state.thread["modelSelection"]
        if let id = selectedSessionID, let pending = pendingModelSelections[id] {
            // Live activity still carries the previous server selection until T3
            // accepts a turn with this choice. Preserve the composer's draft.
            if saved == pending { pendingModelSelections.removeValue(forKey:id) }
            modelSelection = pending
        } else if saved != .null { modelSelection = saved }
        status = isRunning ? "Working" : "Connected"
        if let last = state.thread["session"]["lastError"].string { error = last }
    }
    private func dispatch(_ command: [String:Any]) async throws {
        guard let gateway else { throw ClientError.configuration }
        var c = command; c["commandId"] = UUID().uuidString.lowercased()
        c["createdAt"] = ISO8601DateFormatter().string(from:.now)
        let result = try await gateway.call("orchestration.dispatchCommand",.from(c))
        if result["status"].string == "rejected" { throw ClientError.backend("T3",0,result.formatted) }
    }
    func createSession(in project: AppProject, title: String? = nil) async {
        let id = UUID().uuidString.lowercased()
        do {
            try await dispatch(["type":"thread.create","threadId":id,"projectId":project.id,"title":title ?? "New thread",
                "modelSelection":modelSelection.foundation,"runtimeMode":"approval-required","interactionMode":"default",
                "branch":NSNull(),"worktreePath":NSNull()])
            sessionProjects[id] = project.id; await selectSession(id)
        } catch { self.error = error.localizedDescription }
    }
    func send(_ text: String, in project: AppProject) async {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        error = nil
        if selectedSessionID == nil { await createSession(in:project) }
        guard let id = selectedSessionID, error == nil else { return }
        do {
            var message = text
            if state.thread["messages"].array.isEmpty {
                message += "\n\n" + project.agentContext + "\nFor signed builds/install links use /Users/anshu/Documents/ChatGPT/RemoteAppDev/target/release/squircle --data-dir /Users/anshu/Documents/ChatGPT/RemoteAppDev/.squircle. Run help workflow for the documented commands. This app is a native client of T3; T3 manages this thread."
            }
            try await dispatch(["type":"thread.turn.start","threadId":id,
                "message":["messageId":UUID().uuidString.lowercased(),"role":"user","text":message,"attachments":[]],
                "modelSelection":modelSelection.foundation,"runtimeMode":state.thread["runtimeMode"].string ?? "approval-required",
                "interactionMode":"default","titleSeed":String(text.prefix(120))])
            isRunning = true; status = "Working"
        } catch { self.error = error.localizedDescription }
    }
    func stop() async {
        guard let id = selectedSessionID else { return }
        do { try await dispatch(["type":"thread.turn.interrupt","threadId":id]) } catch { self.error = error.localizedDescription }
    }
    func respond(to request: JSONValue, decision: String? = nil, answers: [String:Any]? = nil) async {
        guard let id = selectedSessionID, let requestID = request["payload"]["requestId"].string else { return }
        do {
            var c: [String:Any] = ["threadId":id,"requestId":requestID]
            if let answers { c["type"] = "thread.user-input.respond"; c["answers"] = answers }
            else { c["type"] = "thread.approval.respond"; c["decision"] = decision ?? "decline" }
            try await dispatch(c); requests.removeAll { $0["id"] == request["id"] }
        } catch { self.error = error.localizedDescription }
    }
    func openDevice(_ device: JSONValue, restart: Bool = false) async -> SimulatorTarget? {
        guard let id = selectedSessionID, let gateway else { return nil }
        do {
            guard let chosen = SimulatorTarget(deviceID:device["id"].string,hostID:device["hostId"].string) else { throw ClientError.response("Simulator selection") }
            if restart {
                _ = try await gateway.call("device.shutdown",.from(["hostId":chosen.hostID,"deviceId":chosen.deviceID,"platform":"ios"]))
            }
            let opened = try await gateway.call("device.open",.from(["threadId":id,"hostId":chosen.hostID,
                "deviceId":chosen.deviceID,"platform":"ios","boot":true]))
            guard let target = SimulatorTarget(deviceID:opened["deviceId"].string,hostID:opened["hostId"].string) else { throw ClientError.response("Simulator session") }
            var inventory = devices.object
            var sessions = devices["sessions"].array.filter {
                !($0["threadId"].string == id && $0["hostId"].string == target.hostID && $0["deviceId"].string == target.deviceID)
            }
            sessions.append(opened); inventory["sessions"] = .array(sessions); devices = .object(inventory)
            return target
        } catch { self.error = error.localizedDescription; return nil }
    }
    var activeDevice: JSONValue? {
        devices["sessions"].array.filter { $0["threadId"].string == selectedSessionID }
            .max { ($0["openedAt"].string ?? "") < ($1["openedAt"].string ?? "") }
    }
    func startMetadataUpdates() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetadata(); try? await Task.sleep(for:.seconds(4))
            }
        }
    }
    func stopMetadataUpdates() { monitor?.cancel(); monitor = nil }
    func refreshMetadata() async {
        guard let client else { return }
        do { async let b = client.builds(); async let m = client.fetchAppMetadata()
            builds = try await b; appMetadata = try await m; reconcileProjects()
        } catch { /* T3 chat remains usable if the build service is temporarily offline. */ }
    }
    func previewData(for metadata: AppMetadata) async throws -> Data {
        guard let client else { throw ClientError.configuration }; let key = metadata.id + (metadata.preview?.id ?? "")
        if let data = previewCache[key] { return data }
        let data = try await client.fetchAppPreview(id:metadata.id,previewID:metadata.preview?.id); previewCache[key] = data; return data
    }
    func previewData(for build: AppBuild) async throws -> Data {
        guard let client else { throw ClientError.configuration }; return try await client.fetchBuildPreview(id:build.id)
    }
    func startBuild(for project: AppProject) async -> AppBuild? {
        guard let client, let request = project.buildRequest else { error = "Import this app’s Xcode build recipe first."; return nil }
        buildingProjectIDs.insert(project.id); defer { buildingProjectIDs.remove(project.id) }
        do { let build = try await client.startBuild(request.freshSubmission()); await refreshMetadata(); return build }
        catch { self.error = error.localizedDescription; return nil }
    }
    func installURL(for build: AppBuild) async -> URL? {
        do { return try await client?.installURL(buildID:build.id) } catch { self.error = error.localizedDescription; return nil }
    }
    func browseMacProjects(path: String? = nil) async throws -> MacProjectDirectory {
        guard let client else { throw ClientError.configuration }; return try await client.browseMacProjects(path:path)
    }
    func inspectMacProject(project: String, scheme: String? = nil, configuration: String? = nil) async throws -> MacProjectInspection {
        guard let client else { throw ClientError.configuration }; return try await client.inspectMacProject(project:project,scheme:scheme,configuration:configuration)
    }
    func importMacProject(project: String, scheme: String, name: String, configuration: String? = nil) async throws -> AppProject {
        guard let client else { throw ClientError.configuration }
        let record = try await client.importMacProject(project:project,scheme:scheme,name:name,configuration:configuration)
        let root = URL(fileURLWithPath:project).deletingLastPathComponent().path
        if !shell["projects"].array.contains(where: { let workspace = $0["workspaceRoot"].string ?? ""; return !workspace.isEmpty && (root == workspace || root.hasPrefix(workspace + "/")) }) {
            try await dispatch(["type":"project.create","projectId":UUID().uuidString.lowercased(),"title":name,"workspaceRoot":root])
        }
        appMetadata.removeAll { $0.id == record.id }; appMetadata.append(record)
        // HTTP shell gives an immediate authoritative result after the write.
        if let gateway { shell = try await gateway.http.json("/api/orchestration/shell"); consumeShell(.from(["kind":"snapshot","snapshot":shell.foundation])) }
        guard let app = projects.first(where: { $0.metadataID == record.id }) else { throw ClientError.response("T3 app import") }
        return app
    }
}
