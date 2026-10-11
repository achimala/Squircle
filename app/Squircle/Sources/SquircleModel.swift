import AVFoundation
import Combine
import Foundation
import UIKit

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
    /// A build of the running app whose installation was just confirmed;
    /// the app steps aside so iOS can replace it.
    @Published private(set) var updatingTo: AppBuild?
    @Published private(set) var providers: [JSONValue] = []
    @Published private(set) var devices: JSONValue = .null
    @Published private(set) var requests: [JSONValue] = []
    @Published private(set) var changes: [TurnChanges] = []
    @Published private(set) var modelSelection: JSONValue = .null
    @Published private(set) var runtimeMode: T3RuntimeMode = .auto
    private var pendingRuntimeModes: [String:T3RuntimeMode] = [:]
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
    private var submitting = false
    private var stepDetails: Task<Void,Never>?
    private var stepDetailsCount = -1
    /// Threads seen this session, so returning to one shows it at once.
    private var threadCache: [String: T3ThreadState] = [:]
    private var cacheWrite: Task<Void, Never>?
    private var media: [JSONValue] { state.media }
    private let commandDispatch: ((JSONValue) async throws -> JSONValue)?
    private let preferences: UserDefaults
    /// Inside another app's debug overlay, only that app is shown.
    let scopeBundleID: String?
    private static let preferredModelKey = "squircle.t3.preferredModel"

    /// Once a thread has an agent session, T3 cannot migrate it to another provider.
    var availableModelProviders: [JSONValue] {
        guard selectedSessionID != nil else { return providers }
        let instance = state.thread["session"]["providerInstanceId"].string
            ?? state.thread["modelSelection"]["instanceId"].string
            ?? sessions.first(where: { $0.id == selectedSessionID })?.modelSelection["instanceId"].string
        guard let instance else { return [] }
        return providers.filter { $0["instanceId"].string == instance }
    }
    var availableModelSelections: [JSONValue] {
        availableModelProviders.flatMap { provider in
            provider["models"].array.map { .from(["instanceId": provider["instanceId"].string!, "model": $0["slug"].string!]) }
        }
    }
    /// Models the picker offers, one section per provider: short names
    /// ("Opus 5.5", not "Claude Opus 5.5"), newest version first and, within
    /// a version, larger models first.
    var modelMenu: [(title: String, choices: [(selection: JSONValue, name: String)])] {
        availableModelProviders.map { provider in
            let maker = provider["displayName"].string ?? ""
            let choices = provider["models"].array.enumerated().compactMap { index, option -> (JSONValue, String, Int)? in
                guard let slug = option["slug"].string, let instance = provider["instanceId"].string else { return nil }
                return (.from(["instanceId": instance, "model": slug]), Self.shortName(option["name"].string ?? slug, maker: maker), index)
            }.sorted { a, b in
                let x = Self.rank(a.1 + " " + (a.0["model"].string ?? "")), y = Self.rank(b.1 + " " + (b.0["model"].string ?? ""))
                if x.version != y.version { return x.version > y.version }
                if x.size != y.size { return x.size > y.size }
                return a.2 < b.2
            }.map { (selection: $0.0, name: $0.1) }
            return (maker, choices)
        }
    }
    /// "Claude Opus 5.5" from provider "Claude" → "Opus 5.5".
    static func shortName(_ name: String, maker: String) -> String {
        guard !maker.isEmpty, name.lowercased().hasPrefix(maker.lowercased() + " ") else { return name }
        return String(name.dropFirst(maker.count + 1))
    }
    /// Version number in a model name and a rough size from its family word.
    static func rank(_ text: String) -> (version: Double, size: Int) {
        let lower = text.lowercased()
        var version = 0.0
        if let range = lower.range(of: #"\d+(?:[.\-]\d+)?"#, options: .regularExpression) {
            version = Double(lower[range].replacingOccurrences(of: "-", with: ".")) ?? 0
        }
        let sizes: [(String, Int)] = [("fable", 5), ("opus", 4), ("sol", 4), ("sonnet", 3), ("astra", 3), ("luna", 2),
                                      ("haiku", 1), ("flash", 1), ("mini", 1), ("nano", 0)]
        let size = sizes.first { lower.contains($0.0) }?.1 ?? 2
        return (version, size)
    }
    func shortAgentName(for selection: JSONValue) -> String {
        guard let provider = providers.first(where: { $0["instanceId"] == selection["instanceId"] }) else {
            return selection["model"].string ?? "Model"
        }
        let option = provider["models"].array.first { $0["slug"] == selection["model"] }
        return Self.shortName(option?["name"].string ?? selection["model"].string ?? "Model", maker: provider["displayName"].string ?? "")
    }
    var quickModelSelections: [JSONValue] {
        var choices: [JSONValue] = []
        if isValidModel(modelSelection) { choices.append(modelSelection) }
        for provider in availableModelProviders {
            if let option = provider["models"].array.first(where: { $0["isDefault"].bool }) ?? provider["models"].array.first {
                let selection = JSONValue.from(["instanceId":provider["instanceId"].string!,"model":option["slug"].string!])
                if !choices.contains(where: { sameModel($0, selection) }) { choices.append(selection) }
            }
        }
        return Array(choices.prefix(4))
    }
    private func sameModel(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        lhs["instanceId"] == rhs["instanceId"] && lhs["model"] == rhs["model"]
    }
    private func isValidModel(_ selection: JSONValue) -> Bool {
        availableModelSelections.contains { sameModel($0, selection) }
    }
    func consumeConfig(_ config: JSONValue) {
        providers = config["providers"].array.filter {
            $0["enabled"].bool && $0["status"].string == "ready" && !($0["instanceId"].string ?? "").isEmpty
        }.map { provider in
            var value = provider.object
            value["models"] = .array(provider["models"].array.filter { !($0["slug"].string ?? "").isEmpty })
            return .object(value)
        }.filter { !$0["models"].array.isEmpty }
        if selectedSessionID == nil { restorePreferredModel() }
    }
    private func restorePreferredModel() {
        if let data = preferences.data(forKey: Self.preferredModelKey),
           let saved = try? JSONDecoder().decode(JSONValue.self, from: data), isValidModel(saved) {
            modelSelection = saved
        } else { modelSelection = quickModelSelections.first ?? availableModelSelections.first ?? .null }
    }

    init(configuration: AppConfiguration? = try? AppConfiguration.load(), preferences: UserDefaults = .standard,
         commandDispatch: ((JSONValue) async throws -> JSONValue)? = nil, scopeBundleID: String? = nil) {
        self.preferences = preferences
        self.scopeBundleID = scopeBundleID
        self.commandDispatch = commandDispatch
        self.configuration = configuration
        client = configuration.map { SquircleClient(configuration:$0) }
        gateway = configuration.map(T3Gateway.init(configuration:))
        selectedProjectID = UserDefaults.standard.string(forKey:"squircle.t3.selectedProject")
        // Home shows the last known apps and threads at once; T3 then replaces them.
        if configuration != nil, let home = Self.loadHome() {
            shell = home.shell; appMetadata = home.metadata; shellChanged()
        }
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
                consumeConfig(config)
                devices = try await gateway.call("device.list")
                try await gateway.subscribe("orchestration.subscribeShell") { [weak self] in self?.consumeShell($0) }
                try await gateway.subscribe("subscribeDeviceState") { [weak self] in self?.devices = $0 }
                connected = true; status = "Connected"; error = nil
                if let id = selectedSessionID { await selectSession(id) }
            }
            async let listed = client.builds()
            async let metadata = client.fetchAppMetadata()
            builds = try await listed; appMetadata = try await metadata; reconcileProjects(); scheduleHomeWrite()
            await ensureScopedProject()
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
        shellChanged()
        scheduleHomeWrite()
    }
    private func shellChanged() {
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
        // Most recently used first; apps never opened keep T3's order after them.
        let used = preferences.dictionary(forKey: Self.lastUsedKey) as? [String: Double] ?? [:]
        let catalog = T3AppCatalog.projects(shell:shell,metadata:appMetadata,builds:builds)
            .filter { scopeBundleID == nil || $0.bundleID == scopeBundleID }
        projects = catalog.enumerated().sorted { a, b in
            let x = used[a.element.id] ?? 0, y = used[b.element.id] ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }
    private static let lastUsedKey = "squircle.t3.lastUsed"
    /// Opening an app's thread makes it the most recently used. The carousel
    /// reorders behind the open thread, never while you're browsing it.
    func selectProject(_ project: AppProject) {
        selectedProjectID = project.id; UserDefaults.standard.set(project.id,forKey:"squircle.t3.selectedProject")
        var used = preferences.dictionary(forKey: Self.lastUsedKey) as? [String: Double] ?? [:]
        used[project.id] = Date.now.timeIntervalSince1970
        preferences.set(used, forKey: Self.lastUsedKey)
        reconcileProjects()
    }
    func sessions(for project: AppProject) -> [ChatSession] { sessions.filter { sessionProjects[$0.id] == project.id } }
    func builds(for project: AppProject) -> [AppBuild] { builds.filter { $0.request?.key == project.buildRequest?.key && $0.request != nil } }
    func metadata(for project: AppProject) -> AppMetadata? { appMetadata.first { $0.id == project.metadataID } }
    /// Shows a thread immediately from what was last seen of it (this session
    /// or on disk); the live subscription then brings it up to date.
    func prepareSession(_ id: String) {
        guard selectedSessionID != id || state.sequence < 0 else { return }
        saveCurrentThread()
        selectedSessionID = id; requests = []; isRunning = false
        stepDetails?.cancel(); stepDetailsCount = -1
        state = threadCache[id] ?? (configuration != nil ? Self.loadThread(id) : nil) ?? T3ThreadState()
        if state.sequence >= 0 { state.fromCache = true }
        messages = conversation(); requests = state.pendingRequests; changes = state.changes; isRunning = state.isRunning
        runtimeMode = pendingRuntimeModes[id] ?? state.thread["runtimeMode"].string.flatMap(T3RuntimeMode.init(rawValue:)) ?? .auto
        if let pending = pendingModelSelections[id] { modelSelection = pending }
        else if state.thread["modelSelection"] != .null { modelSelection = state.thread["modelSelection"] }
    }
    func selectSession(_ id: String) async {
        prepareSession(id)
        guard let gateway else { return }
        let previousSubscription = threadSubscription; threadSubscription = nil
        await gateway.unsubscribe(previousSubscription)
        guard selectedSessionID == id else { return }
        do {
            let subscription = try await gateway.subscribe("orchestration.subscribeThread", .from(["threadId":id])) { [weak self] item in
                guard let self, selectedSessionID == id else { return }
                consumeThread(item)
            }
            guard selectedSessionID == id else { await gateway.unsubscribe(subscription); return }
            threadSubscription = subscription
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    /// A new conversation that T3 has not been told about yet. The thread is
    /// created by its first message, so abandoned drafts leave nothing behind.
    func beginDraft() async {
        saveCurrentThread()
        selectedSessionID = nil; messages = []; requests = []; changes = []; state = T3ThreadState(); isRunning = false; error = nil
        runtimeMode = .auto
        restorePreferredModel()
        let previousSubscription = threadSubscription; threadSubscription = nil
        await gateway?.unsubscribe(previousSubscription)
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
        guard !isRunning, !submitting, isValidModel(selection) else { return }
        modelSelection = selection
        if let data = try? JSONEncoder().encode(selection) { preferences.set(data, forKey: Self.preferredModelKey) }
        if let id = selectedSessionID { pendingModelSelections[id] = selection }
    }
    func chooseRuntimeMode(_ mode: T3RuntimeMode) {
        runtimeMode = mode
        if let id = selectedSessionID { pendingRuntimeModes[id] = mode }
    }
    func setRuntimeMode(_ mode: T3RuntimeMode) async {
        let previous = runtimeMode
        chooseRuntimeMode(mode)
        guard let id = selectedSessionID else { return }
        do {
            try await dispatch(["type":"thread.runtime-mode.set","threadId":id,"runtimeMode":mode.rawValue])
        } catch {
            if pendingRuntimeModes[id] == mode {
                pendingRuntimeModes.removeValue(forKey:id)
                if selectedSessionID == id { runtimeMode = previous }
            }
            self.error = error.localizedDescription
        }
    }
    // MARK: Home cache

    private struct HomeCache: Codable { var shell: JSONValue; var metadata: [AppMetadata] }
    private var homeWrite: Task<Void, Never>?
    private nonisolated static var homeURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("squircle-home.json")
    }
    private nonisolated static func loadHome() -> HomeCache? {
        guard let url = homeURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HomeCache.self, from: data)
    }
    /// Shell events arrive in bursts; the copy on disk trails by a couple of seconds.
    private func scheduleHomeWrite() {
        guard configuration != nil, homeWrite == nil, shell != .null else { return }
        homeWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            homeWrite = nil
            let home = HomeCache(shell: shell, metadata: appMetadata)
            Task.detached(priority: .utility) {
                guard let url = Self.homeURL, let data = try? JSONEncoder().encode(home) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Thread cache

    private nonisolated static var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("squircle-threads", isDirectory: true)
    }
    private nonisolated static func loadThread(_ id: String) -> T3ThreadState? {
        guard let url = cacheDirectory?.appendingPathComponent(id + ".json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T3ThreadState.self, from: data)
    }
    private func saveCurrentThread() {
        guard let id = selectedSessionID, state.sequence >= 0 else { return }
        threadCache[id] = state
        cacheWrite?.cancel(); cacheWrite = nil
        writeToDisk(id, state)
    }
    /// Keeps the on-disk copy current without writing on every event.
    private func scheduleCacheWrite() {
        guard let id = selectedSessionID else { return }
        threadCache[id] = state
        guard cacheWrite == nil else { return }
        cacheWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            cacheWrite = nil
            if selectedSessionID == id { writeToDisk(id, state) }
        }
    }
    private func writeToDisk(_ id: String, _ state: T3ThreadState) {
        guard configuration != nil else { return }
        Task.detached(priority: .utility) {
            guard let directory = Self.cacheDirectory, let data = try? JSONEncoder().encode(state) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
        }
    }

    func consumeThread(_ item: JSONValue) {
        state.consume(item); messages = conversation(); requests = state.pendingRequests
        scheduleCacheWrite()
        let turnChanges = state.changes
        if turnChanges != changes { changes = turnChanges }
        if state.activityCount != stepDetailsCount { stepDetailsCount = state.activityCount; scheduleStepDetails() }
        isRunning = state.isRunning
        let saved = state.thread["modelSelection"]
        if let id = selectedSessionID, let pending = pendingModelSelections[id] {
            // Live activity still carries the previous server selection until T3
            // accepts a turn with this choice. Preserve the composer's draft.
            if saved == pending { pendingModelSelections.removeValue(forKey:id) }
            modelSelection = pending
        } else if saved != .null { modelSelection = saved }
        let savedMode = state.thread["runtimeMode"].string.flatMap(T3RuntimeMode.init(rawValue:))
        if let id = selectedSessionID, let pending = pendingRuntimeModes[id] {
            if savedMode == pending { pendingRuntimeModes.removeValue(forKey:id) }
            runtimeMode = pending
        } else { runtimeMode = savedMode ?? .auto }
        status = isRunning ? "Working" : "Connected"
        if let last = state.thread["session"]["lastError"].string { error = last }
    }
    private func dispatch(_ command: [String:Any]) async throws {
        var c = command; c["commandId"] = UUID().uuidString.lowercased()
        c["createdAt"] = ISO8601DateFormatter().string(from:.now)
        let result: JSONValue
        if let commandDispatch { result = try await commandDispatch(.from(c)) }
        else if let gateway { result = try await gateway.call("orchestration.dispatchCommand",.from(c)) }
        else { throw ClientError.configuration }
        if result["status"].string == "rejected" { throw ClientError.backend("T3",0,result.formatted) }
    }
    private func createSession(in project: AppProject, title: String? = nil) async {
        let id = UUID().uuidString.lowercased()
        do {
            try await dispatch(["type":"thread.create","threadId":id,"projectId":project.id,"title":title ?? "New thread",
                "modelSelection":modelSelection.foundation,"runtimeMode":runtimeMode.rawValue,"interactionMode":"default",
                "branch":NSNull(),"worktreePath":NSNull()])
            pendingRuntimeModes[id] = runtimeMode
            sessionProjects[id] = project.id; await selectSession(id)
        } catch { self.error = error.localizedDescription }
    }
    func send(_ text: String, in project: AppProject) async {
        guard !submitting, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        guard isValidModel(modelSelection) else { error = "Choose an available model."; return }
        submitting = true
        defer { submitting = false }
        error = nil
        if selectedSessionID == nil { await createSession(in:project) }
        guard let id = selectedSessionID, error == nil else { return }
        do {
            var message = text
            let instructions = squircleInstructions(for: project, threadID: id)
            if state.thread["messages"].array.isEmpty {
                message += "\n\n" + project.agentContext + "\nFor signed builds/install links use /Users/anshu/Documents/ChatGPT/RemoteAppDev/target/release/squircle --data-dir /Users/anshu/Documents/ChatGPT/RemoteAppDev/.squircle. Run help workflow for the documented commands. This app is a native client of T3; T3 manages this thread.\n" + instructions
            } else if !state.thread["messages"].array.contains(where: { ($0["text"].string ?? "").contains("Squircle shows it with an Install button") }) {
                // Threads started before these instructions existed get them once.
                message += AppProject.contextMarker + project.name + ".\n" + instructions
            }
            try await dispatch(["type":"thread.turn.start","threadId":id,
                "message":["messageId":UUID().uuidString.lowercased(),"role":"user","text":message,"attachments":[]],
                "modelSelection":modelSelection.foundation,"runtimeMode":runtimeMode.rawValue,
                "interactionMode":"default","titleSeed":String(text.prefix(120))])
            isRunning = true; status = "Working"
        } catch { self.error = error.localizedDescription }
    }
    /// T3 streams tool calls without their inputs or screenshots; the Mac
    /// fills those in shortly after each new activity.
    private func scheduleStepDetails() {
        guard let client, let id = selectedSessionID else { return }
        stepDetails?.cancel()
        stepDetails = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            async let published = try? client.threadMedia(threadID: id)
            guard let steps = try? await client.threadSteps(threadID: id, since: state.detailsSince),
                  !Task.isCancelled, selectedSessionID == id else { return }
            if let published = await published, published != media, selectedSessionID == id {
                state.media = published
                messages = conversation()
                scheduleCacheWrite()
            }
            guard !steps.isEmpty else { return }
            for step in steps {
                guard let key = step["id"].string else { continue }
                var merged = state.details[key]?.object ?? [:]
                for (field, value) in step.object { merged[field] = value }
                state.details[key] = .object(merged)
                if let at = step["updated_at"].string, at > (state.detailsSince ?? "") { state.detailsSince = at }
            }
            messages = conversation()
            scheduleCacheWrite()
        }
    }
    /// T3's conversation with the thread's published recordings in time order.
    private func conversation() -> [ChatMessage] {
        let rows = state.messages
        guard !media.isEmpty else { return rows }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let clips = media.compactMap { item -> ChatMessage? in
            guard let id = item["id"].string, let seconds = item["created_at"].double else { return nil }
            let caption = item["caption"].string.flatMap { $0.isEmpty ? nil : $0 }
            let video = item["kind"].string == "video"
            var message = ChatMessage(id: "media:" + id, role: "tool", content: caption ?? (video ? "Recording" : "Image"),
                                      symbol: video ? "record.circle" : "photo",
                                      createdAt: formatter.string(from: Date(timeIntervalSince1970: seconds)))
            message.step = AgentStep(kind: .device, title: message.content, symbol: message.symbol)
            message.imageCount = 1
            message.videoID = video ? id : nil
            return message
        }
        return (rows + clips).enumerated().sorted { a, b in
            let x = a.element.createdAt, y = b.element.createdAt
            return x == y || x.isEmpty || y.isEmpty ? a.offset < b.offset : x < y
        }.map(\.element)
    }
    /// A recording's file on the phone, downloading it once; its first frame
    /// becomes the gallery picture.
    func loadVideo(_ stepID: String) async -> URL? {
        if let url = StepVideos.url(for: stepID) { return url }
        let id = String(stepID.dropFirst("media:".count))
        guard let client, let thread = selectedSessionID,
              let data = try? await client.mediaFile(threadID: thread, id: id) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".mp4")
        guard (try? data.write(to: url)) != nil else { return nil }
        StepVideos.set(url, for: stepID)
        return url
    }
    func loadStepImage(_ stepID: String, index: Int) async -> Data? {
        if let data = StepImages.data(for: stepID, index: index) { return data }
        if stepID.hasPrefix("media:") {
            let message = messages.first { $0.id == stepID }
            var data: Data?
            if message?.videoID != nil, let url = await loadVideo(stepID) {
                data = await Self.poster(of: url)
            } else if let client, let thread = selectedSessionID {
                data = try? await client.mediaFile(threadID: thread, id: String(stepID.dropFirst("media:".count)))
            }
            if let data { StepImages.set(data, for: stepID, index: index) }
            return data
        }
        guard let client, let thread = selectedSessionID,
              let data = try? await client.stepImage(threadID: thread, callID: stepID, index: index) else { return nil }
        StepImages.set(data, for: stepID, index: index)
        return data
    }
    nonisolated static func poster(of url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }
    /// One turn's unified diff, from T3's checkpoints.
    func turnDiff(_ change: TurnChanges) async -> String? {
        guard let gateway, let thread = selectedSessionID else { return nil }
        do {
            let result = try await gateway.call("orchestration.getTurnDiff", .from(["threadId": thread,
                "fromTurnCount": max(0, change.count - 1), "toTurnCount": change.count]))
            return result["diff"].string
        } catch { self.error = error.localizedDescription; return nil }
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
    /// The simulator this app's agents should use: the one last used for it,
    /// one named after it, or any booted iPhone simulator.
    func simulator(for project: AppProject) -> JSONValue? {
        let simulators = devices["devices"].array.filter { $0["platform"].string == "ios" && !$0["physical"].bool }
        if let saved = preferences.string(forKey: "squircle.simulator." + project.id),
           let match = simulators.first(where: { $0["id"].string == saved }) { return match }
        if let named = simulators.first(where: { ($0["name"].string ?? "").localizedCaseInsensitiveContains(project.name) }) { return named }
        return simulators.first { $0["booted"].bool } ?? simulators.first
    }
    func rememberSimulator(_ deviceID: String, for project: AppProject) {
        preferences.set(deviceID, forKey: "squircle.simulator." + project.id)
    }
    /// Tells the agent it is being watched in Squircle and how to show its
    /// work there: the simulator, screenshots and recordings.
    func squircleInstructions(for project: AppProject, threadID: String) -> String {
        let cli = "/Users/anshu/Documents/ChatGPT/RemoteAppDev/target/release/squircle --data-dir /Users/anshu/Documents/ChatGPT/RemoteAppDev/.squircle"
        var device = "Call device_list, then device_open for an iOS simulator"
        if let simulator = simulator(for: project), let id = simulator["id"].string {
            device = "Call device_open with deviceId \(id) and hostId \(simulator["hostId"].string ?? "local") (\(simulator["name"].string ?? "this app's simulator"), this app's simulator)"
        }
        return """
        Squircle shows this thread on the user's iPhone with the simulator live on a 3D device. Whenever you run, check or demonstrate the app in a simulator, use T3's device tools so the user watches it happen: \(device), then drive it with the agent-device command device_open returns. Use device_screenshot to look at the screen; those screenshots appear in the conversation. To show a flow, record it: agent-device record start /tmp/NAME.mp4 --scope device (with the --config and --session flags device_open gave you), perform the flow, agent-device record stop, then publish the clip into this thread with \(cli) media add --thread \(threadID) --file /tmp/NAME.mp4 --caption 'What it shows'. When you make a signed build for the user, include its build job ID in your final reply; Squircle shows it with an Install button.
        """
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
    /// Apps without a published preview show the newest screenshot an agent
    /// took in their threads. `version` changes as those threads move on.
    func threadScreenshot(for project: AppProject, version: String) async throws -> Data {
        guard let client else { throw ClientError.configuration }; let key = "t3:" + project.id + version
        if let data = previewCache[key] { return data }
        let data = try await client.projectScreenshot(projectID: project.id); previewCache[key] = data; return data
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
    /// Opens iOS's install prompt. For a build of this very app, waits for
    /// the person to confirm (the Mac sees the download start) and then
    /// publishes `updatingTo`.
    @discardableResult
    func install(_ build: AppBuild) async -> Bool {
        guard let client else { error = ClientError.configuration.localizedDescription; return false }
        let url: URL
        do { url = try await client.installURL(buildID: build.id) } catch { self.error = error.localizedDescription; return false }
        guard await UIApplication.shared.open(url) else { error = "Couldn’t open the installer."; return false }
        guard build.bundleID != nil, build.bundleID == Bundle.main.bundleIdentifier else { return true }
        for _ in 0..<180 {
            try? await Task.sleep(for: .seconds(1))
            if (try? await client.installStarted(link: url)) == true { updatingTo = build; return true }
        }
        return true
    }
    func cancelUpdate() { updatingTo = nil }
    func browseMacProjects(path: String? = nil) async throws -> MacProjectDirectory {
        guard let client else { throw ClientError.configuration }; return try await client.browseMacProjects(path:path)
    }
    func inspectMacProject(project: String, scheme: String? = nil, configuration: String? = nil) async throws -> MacProjectInspection {
        guard let client else { throw ClientError.configuration }; return try await client.inspectMacProject(project:project,scheme:scheme,configuration:configuration)
    }
    func importMacProject(project: String, scheme: String, name: String, configuration: String? = nil) async throws -> AppProject {
        guard let client else { throw ClientError.configuration }
        let record = try await client.importMacProject(project:project,scheme:scheme,name:name,configuration:configuration)
        appMetadata.removeAll { $0.id == record.id }; appMetadata.append(record)
        try await ensureOwnProject(record)
        guard let app = projects.first(where: { $0.metadataID == record.id }) else { throw ClientError.response("T3 app import") }
        return app
    }
    /// An app needs a T3 project of its own unless it already owns the
    /// workspace around it; another app may own that one.
    private func ensureOwnProject(_ record: AppMetadata) async throws {
        let root = URL(fileURLWithPath:record.project).deletingLastPathComponent().path
        let catalog = T3AppCatalog.projects(shell:shell,metadata:appMetadata,builds:builds)
        guard !catalog.contains(where: { $0.metadataID == record.id }) else { return }
        if let taken = catalog.first(where: { app in
            shell["projects"].array.contains { $0["id"].string == app.id && $0["workspaceRoot"].string == root }
        }) {
            throw ClientError.backend("T3", 409, "\(taken.name) already uses this folder in T3.")
        }
        try await dispatch(["type":"project.create","projectId":UUID().uuidString.lowercased(),"title":record.name,"workspaceRoot":root])
        // HTTP shell gives an immediate authoritative result after the write.
        if let gateway { shell = try await gateway.http.json("/api/orchestration/shell"); consumeShell(.from(["kind":"snapshot","snapshot":shell.foundation])) }
    }
    /// Inside an app's overlay, that app is always present: one Squircle
    /// built but never gave a T3 project gets one, as Add app would.
    private func ensureScopedProject() async {
        guard let scopeBundleID, projects.isEmpty else { return }
        guard let record = appMetadata.first(where: { $0.bundleID == scopeBundleID }) else {
            error = "Squircle’s Mac catalog has no app with bundle ID \(scopeBundleID)."
            return
        }
        do {
            if shell["projects"] == .null, let gateway {
                shell = try await gateway.http.json("/api/orchestration/shell")
                consumeShell(.from(["kind":"snapshot","snapshot":shell.foundation]))
            }
            try await ensureOwnProject(record)
        } catch { self.error = error.localizedDescription }
    }
}
