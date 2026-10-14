import AVFoundation
import Foundation
import Network
import UIKit

@MainActor
final class SquircleModel {
    private(set) var sessions: [ChatSession] = [] { didSet { changed() } }
    private(set) var messages: [ChatMessage] = [] { didSet { changed() } }
    private(set) var builds: [AppBuild] = [] { didSet { changed() } }
    private(set) var projects: [AppProject] = [] { didSet { changed() } }
    private(set) var appMetadata: [AppMetadata] = [] { didSet { changed() } }
    private(set) var selectedSessionID: String? { didSet { changed() } }
    private(set) var selectedProjectID: String? { didSet { changed() } }
    private(set) var buildingProjectIDs = Set<String>() { didSet { changed() } }
    private(set) var connected = false { didSet { changed() } }
    private(set) var isRunning = false { didSet { changed() } }
    private(set) var isLoading = false { didSet { changed() } }
    private(set) var status = "Connecting" { didSet { changed() } }
    var error: String? { didSet { changed() } }
    var composerPrefill: String? { didSet { changed() } }
    /// Pictures in the message field, sent with the next message.
    private(set) var attachments: [ImageAttachment] = [] { didSet { changed() } }
    /// A build of the running app whose installation was just confirmed;
    /// the app steps aside so iOS can replace it.
    private(set) var updatingTo: AppBuild? { didSet { changed() } }
    private(set) var providers: [JSONValue] = [] { didSet { changed() } }
    private(set) var devices: JSONValue = .null { didSet { changed(); scheduleSimulatorRefresh() } }
    /// Sessions Squircle is recording for agents, from the Mac.
    private(set) var recording: [JSONValue] = [] { didSet { if recording != oldValue { changed() } } }
    private var simulatorRefresh: Task<Void, Never>?
    private(set) var requests: [JSONValue] = [] { didSet { changed() } }
    private(set) var changes: [TurnChanges] = [] { didSet { changed() } }
    /// Every worker Squircle started, archived ones too, by thread ID.
    private(set) var workers: [String: KnownWorker] = [:] { didSet { changed() } }
    private(set) var modelSelection: JSONValue = .null { didSet { changed() } }
    private(set) var runtimeMode: T3RuntimeMode = .auto { didSet { changed() } }
    /// The selected app's tasks, from the Mac (`squircle task`).
    private(set) var tasks: [String: AppTasks] = [:] { didSet { if tasks != oldValue { changed() } } }
    /// Each app's agent thread, by T3 project ID, from the Mac.
    private(set) var agents: [String: String] = [:] { didSet { if agents != oldValue { shellChanged() } } }
    /// The open draft is a first message to the app's agent.
    private var draftIsAgent = false
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Model changes as an async sequence. A burst coalesces into one element,
    /// so a slow consumer never falls behind.
    var updates: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        return stream
    }
    private func changed() { for observer in observers.values { observer.yield() } }
    /// Calls `action` `delay` after a change, once for all the changes in
    /// between, for as long as `owner` lives. Cancel the task to stop sooner.
    /// (Not a debounce: changes that never pause, such as a view whose own
    /// render touches the model, must not hold every update back forever.)
    func observe<Owner: AnyObject>(by owner: Owner, after delay: Duration,
                                   _ action: @escaping @MainActor (Owner) -> Void) -> Task<Void, Never> {
        Task { [weak owner, updates = self.updates] in
            var pending: Task<Void, Never>?
            var waiting = false
            for await _ in updates {
                guard owner != nil else { break }
                guard !waiting else { continue }
                waiting = true
                pending = Task { [weak owner] in
                    try? await Task.sleep(for: delay)
                    waiting = false
                    guard !Task.isCancelled, let owner else { return }
                    action(owner)
                }
            }
            pending?.cancel()
        }
    }
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
    private var connector: Task<Void,Never>?
    /// The wait before the connector's next attempt; cancelling it retries now.
    private var nap: Task<Void,Never>?
    /// Reconnect was tapped: abandon the attempt under way and start afresh.
    private var retryNow = false
    private var failingSince: ContinuousClock.Instant?
    /// When T3's config (models, about 1 MB) last arrived; it rarely changes,
    /// so a reconnect doesn't fetch it again.
    private var configLoaded: ContinuousClock.Instant?
    private var configLoader: Task<Void,Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Background time ran out and the socket was closed; reconnect on return.
    private var suspended = false
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
    static let agentInstance = "squircle"

    /// Once a thread has an agent session, T3 cannot migrate it to another provider.
    var availableModelProviders: [JSONValue] {
        guard selectedSessionID != nil else {
            // An app agent runs on Squircle's own Claude instance; other
            // threads never do.
            let agentProviders = providers.filter { $0["instanceId"].string == Self.agentInstance }
            if draftIsAgent { return agentProviders.isEmpty ? providers : agentProviders }
            return providers.filter { $0["instanceId"].string != Self.agentInstance }
        }
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
        let saved = preferences.data(forKey: Self.preferredModelKey).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        // An agent draft keeps your preferred model on Squircle's instance.
        let agentChoice = saved.map { JSONValue.from(["instanceId": Self.agentInstance, "model": $0["model"].string ?? ""]) }
        if let saved, isValidModel(saved) {
            modelSelection = saved
        } else if draftIsAgent, let agentChoice, isValidModel(agentChoice) {
            modelSelection = agentChoice
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
            guard let self else { return }
            connected = false; status = "Reconnecting"; threadSubscription = nil
            log("T3 socket dropped; reconnecting")
            keepConnected()
        }
        if gateway != nil { watchNetwork() }
        #if DEBUG
        // Verification only: T3's socket fails every N seconds.
        if let every = ProcessInfo.processInfo.environment["SQUIRCLE_DROP_T3_EVERY"].flatMap(Double.init), every > 0 {
            Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(every))
                    guard let self else { return }
                    gateway?.dropForTesting()
                }
            }
        }
        #endif
    }
    func refresh() async {
        guard gateway != nil, client != nil else { error = ClientError.configuration.localizedDescription; return }
        guard connected else { failingSince = nil; keepConnected(); nap?.cancel(); return }
        await refreshServices()
    }
    /// Builds, app metadata and agents come from the Squircle service, not T3.
    private func refreshServices() async {
        guard !refreshing, let client else { return }; refreshing = true
        defer { refreshing = false }
        do {
            async let listed = client.builds()
            async let metadata = client.fetchAppMetadata()
            builds = try await listed; appMetadata = try await metadata; reconcileProjects(); scheduleHomeWrite()
            if let known = try? await client.agents() { agents = known }
            await ensureScopedProject()
            if !launchReported, let id = Bundle.main.object(forInfoDictionaryKey:"SquircleBuildID") as? String, UUID(uuidString:id) != nil {
                try await client.reportLaunch(buildID:id,eventID:UUID().uuidString,timestamp:Int(Date.now.timeIntervalSince1970)); launchReported = true
            }
        } catch where Self.isTransient(error) {
            // Coming back from the background the network may not be up yet;
            // the metadata loop tries again in a few seconds.
        } catch { self.error = error.localizedDescription }
    }
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if case ClientError.connection = error { return true }
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed, .cancelled].contains(error.code)
    }

    // MARK: Connection

    /// How long T3 may stay unreachable before Squircle says so. Shorter
    /// outages (an app switch, a network handover) reconnect silently.
    static let reconnectGrace: Duration = .seconds(8)
    /// Keeps T3's socket up while Squircle is in use: the first attempt is
    /// immediate, then 0.5 s doubling to 15 s. One connector at a time;
    /// `nap?.cancel()` makes it try again now.
    private func keepConnected() {
        guard gateway != nil, connector == nil, !connected, !suspended else { return }
        isLoading = true
        connector = Task { [weak self] in
            var delay: Duration = .zero
            while let self, !connected, !suspended {
                if delay > .zero, !retryNow {
                    let nap = Task { [delay] in _ = try? await Task.sleep(for: delay) }
                    self.nap = nap; await nap.value; self.nap = nil
                    if suspended { break }
                }
                retryNow = false
                do { try await openConnection() }
                catch where Self.isRejected(error) {
                    // Retrying can't fix a refused credential; say what to do.
                    log("T3 refused this build's session: \(error.localizedDescription)")
                    self.error = "T3 no longer accepts this build’s session. Pair Squircle with T3 again on your Mac and install a new build."
                    status = "Not signed in"; isLoading = false
                    break
                } catch {
                    log("T3 connect failed: \(error.localizedDescription)")
                    let since = failingSince ?? .now; failingSince = since
                    if since.duration(to: .now) >= Self.reconnectGrace {
                        // Truly unreachable: say so, and stop looking busy.
                        self.error = error.localizedDescription; status = "Offline"; isLoading = false
                    }
                    delay = delay == .zero ? .milliseconds(500) : min(delay * 2, .seconds(15))
                }
            }
            guard let self else { return }
            connector = nil; isLoading = false
            if connected { await refreshServices() }
        }
    }
    /// Reconnect, tapped: a fresh attempt now, without the backoff or an
    /// attempt stuck waiting on a slow socket.
    func reconnect() async {
        guard !connected else { await refreshServices(); return }
        failingSince = nil; error = nil; status = "Connecting"; isLoading = true
        if connector != nil { retryNow = true; gateway?.disconnect(notify: false) }
        keepConnected(); nap?.cancel()
    }
    nonisolated static func isRejected(_ error: Error) -> Bool {
        if case ClientError.http(_, let status) = error { return status == 401 || status == 403 }
        return false
    }
    /// One connection attempt: socket, live subscriptions, and the open
    /// thread resubscribed. Its transcript stays on screen meanwhile; T3's
    /// snapshot then brings it up to date. T3's config is about 1 MB, which
    /// a weak cellular link takes a minute to carry, so it loads afterwards
    /// instead of holding the connection up.
    private func openConnection() async throws {
        guard let gateway else { throw ClientError.configuration }
        try await gateway.connect()
        do {
            try await gateway.subscribe("orchestration.subscribeShell") { [weak self] in self?.consumeShell($0) }
            try await gateway.subscribe("subscribeDeviceState") { [weak self] in self?.devices = $0 }
            threadSubscription = nil
            if let id = selectedSessionID { try await subscribeThread(id) }
            devices = try await gateway.call("device.list")
            // The socket may have failed while subscribing; then try again.
            guard gateway.isOpen, !suspended else { throw ClientError.connection("T3") }
        } catch { gateway.disconnect(notify: false); throw gateway.rejection ?? error }
        connected = true; status = isRunning ? "Working" : "Connected"; failingSince = nil; error = nil
        log("T3 connected")
        loadConfig()
        // A thread opened while this attempt was under way.
        if let id = selectedSessionID, threadSubscription == nil { await selectSession(id) }
    }
    private func loadConfig() {
        guard configLoader == nil, configLoaded.map({ $0.duration(to: .now) > .seconds(600) }) ?? true else { return }
        configLoader = Task { [weak self] in
            // A dropped socket fails this; the next connection asks again.
            if let config = try? await self?.gateway?.call("server.getConfig", large: true) {
                self?.consumeConfig(config); self?.configLoaded = .now
            }
            self?.configLoader = nil
        }
    }
    /// Squircle went to the background: hold the socket for as long as iOS
    /// gives (about 30 s), so a quick app switch never drops it.
    func enteredBackground() {
        guard gateway != nil, backgroundTask == .invalid else { return }
        saveCurrentThread()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "T3 connection") { [weak self] in
            MainActor.assumeIsolated { self?.backgroundExpired() }
        }
    }
    private func backgroundExpired() {
        log("T3 background time ran out; closing")
        suspended = true; nap?.cancel()
        // Close cleanly rather than leave a socket that dies while suspended.
        gateway?.disconnect(notify: false); connected = false; threadSubscription = nil; status = "Connecting"
        endBackgroundTask()
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    private func log(_ message: String) {
        #if DEBUG
        NSLog("SQUIRCLE-CONN %@", message)
        #endif
    }
    /// Back in the foreground: reconnect at once if the socket was closed,
    /// otherwise check that it still answers.
    func enteringForeground() {
        endBackgroundTask(); suspended = false
        guard let gateway else { return }
        if connected {
            // A dead socket reports itself through `onDisconnect`.
            Task { _ = await gateway.probe() }
        } else { failingSince = nil; keepConnected(); nap?.cancel() }
    }
    /// The network changed (Wi-Fi to cellular, back online): a socket on the
    /// old path is likely dead, and a waiting reconnect should try now.
    private func watchNetwork() {
        Task { [weak self] in
            var previous: NWPath?
            for await path in NWPathMonitor() {
                guard let self else { return }
                defer { previous = path }
                guard let before = previous, path.status == .satisfied, !suspended else { continue }
                if connected {
                    if before.status != .satisfied || before.availableInterfaces.map(\.name) != path.availableInterfaces.map(\.name) {
                        _ = await gateway?.probe()
                    }
                } else { failingSince = nil; keepConnected(); nap?.cancel() }
            }
        }
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
        projects = T3AppCatalog.projects(shell:shell,metadata:appMetadata,builds:builds)
            .filter { scopeBundleID == nil || $0.bundleID == scopeBundleID }
    }
    func selectProject(_ project: AppProject) {
        selectedProjectID = project.id; UserDefaults.standard.set(project.id,forKey:"squircle.t3.selectedProject")
    }
    /// An app's threads; its agent's own thread only when asked for.
    func sessions(for project: AppProject, includingAgent: Bool = false) -> [ChatSession] {
        let agent = agents[project.id]
        return sessions.filter { sessionProjects[$0.id] == project.id && (includingAgent || $0.id != agent) }
    }
    func agentThreadID(for project: AppProject) -> String? { agents[project.id] }
    /// The Mac's Squircle service, for notification registration.
    var service: SquircleClient? { client }
    /// Restarts the app's agent session, or replaces it with a new thread;
    /// the Mac does it once the agent's turn ends, and the agent view
    /// follows the new thread when the Mac reports it.
    func resetAgent(_ project: AppProject, fresh: Bool) async {
        guard let client else { return }
        do {
            try await client.resetAgent(projectID: project.id, fresh: fresh)
            await refreshMetadata()
        } catch { self.error = error.localizedDescription }
    }
    func builds(for project: AppProject) -> [AppBuild] { builds.filter { $0.request?.key == project.buildRequest?.key && $0.request != nil } }
    func metadata(for project: AppProject) -> AppMetadata? { appMetadata.first { $0.id == project.metadataID } }
    /// Shows a thread immediately from what was last seen of it (this session
    /// or on disk); the live subscription then brings it up to date.
    func prepareSession(_ id: String) {
        guard selectedSessionID != id || state.sequence < 0 else { return }
        saveCurrentThread()
        selectedSessionID = id; requests = []; isRunning = false; draftIsAgent = false
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
        // While reconnecting, the new connection subscribes the open thread.
        guard connected else { return }
        do { try await subscribeThread(id); error = nil }
        catch where Self.isTransient(error) {}
        catch { self.error = error.localizedDescription }
    }
    private func subscribeThread(_ id: String) async throws {
        guard let gateway else { return }
        let subscription = try await gateway.subscribe("orchestration.subscribeThread", .from(["threadId":id])) { [weak self] item in
            guard let self, selectedSessionID == id else { return }
            consumeThread(item)
        }
        guard selectedSessionID == id else { await gateway.unsubscribe(subscription); return }
        threadSubscription = subscription
    }
    /// A new conversation that T3 has not been told about yet. The thread is
    /// created by its first message, so abandoned drafts leave nothing behind.
    func beginDraft(agent: Bool = false) async {
        saveCurrentThread()
        draftIsAgent = agent
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
        if selection["instanceId"].string != Self.agentInstance, let data = try? JSONEncoder().encode(selection) {
            preferences.set(data, forKey: Self.preferredModelKey)
        }
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
    /// Adds a picture to the message field; one with the same `id` is replaced.
    func attach(_ attachment: ImageAttachment) {
        if let index = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[index] = attachment }
        else { attachments.append(attachment) }
        // A recording starts its way to the Mac at once; sending waits for it.
        if let capture = attachment.capture, let client {
            captureUploads[attachment.id]?.cancel()
            captureUploads[attachment.id] = Task { try await client.uploadCapture(capture.file, kind: capture.kind.rawValue) }
        }
    }
    func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
        captureUploads.removeValue(forKey: id)?.cancel()
    }
    /// Uploads of the field's recordings, by attachment ID, to their paths on the Mac.
    private var captureUploads: [String: Task<String, Error>] = [:]
    /// The message block for `captures`, once each is on the Mac.
    private func captureBlock(_ captures: [ImageAttachment]) async throws -> String {
        var sent: [(label: String, path: String, video: Bool)] = []
        for attachment in captures {
            guard let capture = attachment.capture else { continue }
            let upload = captureUploads[attachment.id] ?? Task { [client] in
                guard let client else { throw ClientError.configuration }
                return try await client.uploadCapture(capture.file, kind: capture.kind.rawValue)
            }
            captureUploads[attachment.id] = upload
            let path = try await upload.value
            let video = capture.kind == .video
            // Your own recording plays from the phone's copy.
            if video { StepVideos.set(capture.file, for: "file:" + path) }
            sent.append(((video ? "Screen recording · " : "Performance recording · ") + capture.label, path, video))
        }
        for attachment in captures { captureUploads[attachment.id] = nil }
        return SentCapture.block(sent)
    }
    /// Sends `text` with the field's pictures. Pictures leave the field at
    /// once and come back if T3 does not take the message.
    func send(_ spoken: String, in project: AppProject) async {
        let field = attachments
        let images = field.filter { $0.capture == nil }, captures = field.filter { $0.capture != nil }
        guard !submitting, !spoken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !field.isEmpty else { return }
        guard isValidModel(modelSelection) else { error = "Choose an available model."; return }
        submitting = true
        attachments = []
        defer {
            submitting = false
            if error != nil { attachments = field + attachments.filter { a in !field.contains { $0.id == a.id } } }
        }
        error = nil
        let text: String
        do { text = try await spoken + captureBlock(captures) }
        catch { self.error = "Couldn't send the recording to your Mac: " + error.localizedDescription; return }
        if selectedSessionID == nil, draftIsAgent {
            // The Mac creates the agent (its worktree and thread), with this
            // message unless it carries pictures, which go to T3 from here.
            guard let client else { error = ClientError.configuration.localizedDescription; return }
            do {
                let model = modelSelection["instanceId"].string == Self.agentInstance ? modelSelection["model"].string : nil
                let id = try await client.startAgent(projectID: project.id, message: images.isEmpty ? text : "", model: model)
                agents[project.id] = id; sessionProjects[id] = project.id
                await selectSession(id)
                if images.isEmpty { isRunning = true; status = "Working"; return }
            } catch { self.error = error.localizedDescription; return }
        }
        if selectedSessionID == nil { await createSession(in:project) }
        guard let id = selectedSessionID, error == nil else { return }
        do {
            var message = text
            let instructions = squircleInstructions(for: project, threadID: id)
            // An app agent has its instructions from Squircle's plugin on the Mac.
            let agent = agents[project.id] == id || state.thread["modelSelection"]["instanceId"].string == Self.agentInstance
            if !agent, state.thread["messages"].array.isEmpty {
                message += "\n\n" + project.agentContext + "\nFor signed builds/install links use /Users/anshu/Documents/ChatGPT/RemoteAppDev/target/release/squircle --data-dir /Users/anshu/Documents/ChatGPT/RemoteAppDev/.squircle. Run help workflow for the documented commands. This app is a native client of T3; T3 manages this thread.\n" + instructions
            } else if !agent, !state.thread["messages"].array.contains(where: { ($0["text"].string ?? "").contains("sim start --thread") }) {
                // Threads started before these instructions existed get them once.
                message += AppProject.contextMarker + project.name + ".\n" + instructions
            }
            // T3 stores each picture under its attachments folder and hands
            // the provider its path.
            let uploads: [[String:Any]] = images.enumerated().map { index, image in
                ["type":"image","name":"image-\(index + 1).jpg","mimeType":"image/jpeg","sizeBytes":image.data.count,
                 "dataUrl":"data:image/jpeg;base64," + image.data.base64EncodedString()]
            }
            let seed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            try await dispatch(["type":"thread.turn.start","threadId":id,
                "message":["messageId":UUID().uuidString.lowercased(),"role":"user","text":message,"attachments":uploads],
                "modelSelection":modelSelection.foundation,"runtimeMode":runtimeMode.rawValue,
                "interactionMode":"default","titleSeed":String((seed.isEmpty ? (captures.isEmpty ? "Image" : "Recording") : seed).prefix(120))])
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
            let since = state.detailsVersion == 2 ? state.detailsSince : nil
            guard let (steps, workers) = try? await client.threadSteps(threadID: id, since: since),
                  !Task.isCancelled, selectedSessionID == id else { return }
            if let workers {
                state.detailsVersion = 2
                let known = Self.workers(workers)
                if known != self.workers { self.workers = known }
            }
            if let published = await published, published != media, selectedSessionID == id {
                state.media = published
                messages = conversation()
                scheduleCacheWrite()
            }
            guard !steps.isEmpty else { return }
            for step in steps {
                guard let key = step["id"].string else { continue }
                var merged = state.details[key]?.object ?? [:]
                for (field, value) in step.object where field != "started_at" || merged[field] == nil { merged[field] = value }
                state.details[key] = .object(merged)
                if let at = step["updated_at"].string, at > (state.detailsSince ?? "") { state.detailsSince = at }
            }
            messages = conversation()
            scheduleCacheWrite()
        }
    }
    struct KnownWorker: Equatable {
        let title: String
        let branch: String
        let state: WorkerState?
    }
    private static func workers(_ list: [JSONValue]) -> [String: KnownWorker] {
        Dictionary(list.compactMap { w in
            w["id"].string.map { ($0, KnownWorker(title: w["title"].string ?? "", branch: w["branch"].string ?? "",
                                                  state: WorkerState(rawValue: w["state"].string ?? ""))) }
        }, uniquingKeysWith: { a, _ in a })
    }
    /// T3's conversation with the thread's published recordings in time order.
    private func conversation() -> [ChatMessage] {
        let rows = state.messages
        guard media.contains(where: { $0["simulator"]["session_id"].string == nil }) else { return rows }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let clips = media.compactMap { item -> ChatMessage? in
            // Simulator recordings show as the turn's simulator instead.
            guard item["simulator"]["session_id"].string == nil,
                  let id = item["id"].string, let seconds = item["created_at"].double else { return nil }
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
        if stepID.hasPrefix("file:") {
            let path = String(stepID.dropFirst("file:".count))
            guard let data = await mediaFileData(path) else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension((path as NSString).pathExtension)
            guard (try? data.write(to: url)) != nil else { return nil }
            StepVideos.set(url, for: stepID)
            return url
        }
        let id = String(stepID.dropFirst("media:".count))
        guard let client, let thread = selectedSessionID,
              let data = try? await client.mediaFile(threadID: thread, id: id) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".mp4")
        guard (try? data.write(to: url)) != nil else { return nil }
        StepVideos.set(url, for: stepID)
        return url
    }
    func loadStepImage(_ stepID: String, index: Int, attachment: String? = nil) async -> Data? {
        if let data = StepImages.data(for: stepID, index: index) { return data }
        if let attachment {
            guard let data = await attachmentData(attachment) else { return nil }
            StepImages.set(data, for: stepID, index: index)
            return data
        }
        if stepID.hasPrefix("file:") {
            var data: Data?
            if MediaFiles.isVideo(stepID) {
                if let video = await loadVideo(stepID) { data = await Self.poster(of: video) }
            } else {
                data = await mediaFileData(String(stepID.dropFirst("file:".count)))
            }
            if let data, let image = UIImage(data: data) {
                MediaFiles.sizes[stepID] = image.size
                StepImages.set(data, for: stepID, index: index)
            }
            return data
        }
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
    /// An image sent with a message, through a short-lived URL T3 signs.
    private func attachmentData(_ id: String) async -> Data? {
        guard let url = await signedURL(["_tag":"attachment","attachmentId":id])?.url else { return nil }
        return await signedData(url)
    }
    /// The pixel size of a picture the agent's Markdown shows, from T3
    /// before its bytes arrive, so its place in the conversation is reserved.
    func mediaSize(_ stepID: String) async -> CGSize? {
        if let size = MediaFiles.sizes[stepID] { return size }
        guard !MediaFiles.isVideo(stepID), let size = await mediaFileURL(String(stepID.dropFirst("file:".count)))?.size else { return nil }
        MediaFiles.sizes[stepID] = size
        return size
    }
    /// A file on the Mac the agent's Markdown shows. T3 signs a short-lived
    /// URL for it as it does for its own web client, and only for pictures,
    /// video and documents it can preview.
    private func mediaFileURL(_ path: String) async -> (url: URL, size: CGSize?)? {
        if let signed = MediaFiles.urls[path], signed.expires > .now.addingTimeInterval(30) { return (signed.url, MediaFiles.sizes["file:" + path]) }
        guard let thread = selectedSessionID,
              let signed = await signedURL(["_tag":"media-file","threadId":thread,"path":path]) else { return nil }
        if let expires = signed.expires { MediaFiles.urls[path] = (signed.url, expires) }
        return (signed.url, signed.size)
    }
    private func mediaFileData(_ path: String) async -> Data? {
        guard let url = await mediaFileURL(path)?.url else { return nil }
        return await signedData(url)
    }
    private func signedURL(_ resource: [String:Any]) async -> (url: URL, expires: Date?, size: CGSize?)? {
        guard let gateway, let base = configuration?.t3URL,
              let asset = try? await gateway.call("assets.createUrl", .from(["resource":resource])),
              let relative = asset["relativeUrl"].string, let url = URL(string: relative, relativeTo: base),
              url.host == base.host else { return nil }
        let size = asset["imageDimensions"]["width"].double.flatMap { width in
            asset["imageDimensions"]["height"].double.map { CGSize(width: width, height: $0) }
        }
        return (url, asset["expiresAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }, size)
    }
    private func signedData(_ url: URL) async -> Data? {
        guard let gateway else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(gateway.http.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await gateway.http.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
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
    /// Tells the agent it is being watched in Squircle and how to show its
    /// work there: the simulator, screenshots and recordings.
    func squircleInstructions(for project: AppProject, threadID: String) -> String {
        let cli = "/Users/anshu/Documents/ChatGPT/RemoteAppDev/target/release/squircle --data-dir /Users/anshu/Documents/ChatGPT/RemoteAppDev/.squircle"
        return """
        Squircle shows this thread on the user's iPhone. Whenever you run, check or demonstrate the app in a simulator, first run \(cli) sim start --thread \(threadID) (see sim --help): it opens and boots a simulator, records it, and the user watches it live; the recording appears in your turn. Drive it with the agent-device command it returns and use device_screenshot to look; those screenshots appear in the conversation. Run \(cli) sim stop --thread \(threadID) when done. Don't run agent-device record or device_open yourself. When you make a signed build for the user, include its build job ID in your final reply; Squircle shows it with an Install button. A performance recording the user sends from the app is a linked .perf.json: \(cli) perf show PATH summarizes it (hitches with symbolicated main-thread stacks, timeline); a screen recording is a linked .mp4.
        """
    }
    /// Simulators this app's threads are using right now: sessions Squircle
    /// records for agents, and devices T3 opened for a thread whose turn is
    /// running (an agent or person using T3's device tools directly).
    func activeSimulators(for project: AppProject) -> [SimulatorUse] {
        let threads = Dictionary(sessions(for: project, includingAgent: true).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return activeSimulators(threads: Set(threads.keys), working: Set(threads.values.filter { $0.phase == .working }.map(\.id)))
    }

    private func activeSimulators(threads: Set<String>, working: Set<String>) -> [SimulatorUse] {
        let names = Dictionary(devices["devices"].array.compactMap { d in d["id"].string.map { ($0, d["name"].string ?? "Simulator") } },
                               uniquingKeysWith: { a, _ in a })
        var uses: [SimulatorUse] = recording.compactMap { session in
            guard let thread = session["thread_id"].string, threads.contains(thread), let id = session["id"].string,
                  let target = SimulatorTarget(deviceID: session["device_id"].string, hostID: session["host_id"].string) else { return nil }
            return SimulatorUse(id: id, threadID: thread, target: target, deviceName: session["device_name"].string ?? "Simulator",
                                started: Date(timeIntervalSince1970: session["started_at"].double ?? 0), live: true)
        }
        for session in devices["sessions"].array {
            guard let thread = session["threadId"].string, threads.contains(thread), working.contains(thread),
                  let target = SimulatorTarget(deviceID: session["deviceId"].string, hostID: session["hostId"].string),
                  !uses.contains(where: { $0.threadID == thread && $0.target == target }) else { continue }
            uses.append(SimulatorUse(id: "t3:\(thread):\(target.deviceID)", threadID: thread, target: target,
                                     deviceName: names[target.deviceID] ?? "Simulator",
                                     started: session["openedAt"].string.flatMap(ThreadItem.date) ?? .now, live: true))
        }
        return uses.sorted { $0.started < $1.started }
    }

    /// The selected thread's simulator use: live now, and recorded earlier.
    var threadSimulators: [SimulatorUse] {
        guard let id = selectedSessionID else { return [] }
        let working = isRunning ? Set([id]) : []
        var uses = activeSimulators(threads: [id], working: working)
        for item in media {
            let clip = item["simulator"]
            guard let session = clip["session_id"].string, let mediaID = item["id"].string,
                  let target = SimulatorTarget(deviceID: clip["device_id"].string, hostID: "local") else { continue }
            uses.removeAll { $0.id == session }
            uses.append(SimulatorUse(id: session, threadID: id, target: target, deviceName: clip["device_name"].string ?? "Simulator",
                                     started: Date(timeIntervalSince1970: clip["started_at"].double ?? 0), live: false, recordingID: mediaID))
        }
        return uses.sorted { $0.started < $1.started }
    }

    /// T3 reports every device opened or closed; Squircle's recordings start
    /// and stop with those, so its list is fetched again after each change.
    private func scheduleSimulatorRefresh() {
        simulatorRefresh?.cancel()
        simulatorRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshSimulators()
        }
    }

    func refreshSimulators() async {
        guard let client, let active = try? await client.simulatorSessions() else { return }
        let ended = Set(recording.compactMap { $0["thread_id"].string }).subtracting(active.compactMap { $0["thread_id"].string })
        recording = active
        // A recording just filed belongs in the conversation on screen.
        if let id = selectedSessionID, ended.contains(id) { scheduleStepDetails() }
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
        do { async let b = client.builds(); async let m = client.fetchAppMetadata(); async let a = client.agents()
            builds = try await b; appMetadata = try await m; reconcileProjects()
            if let known = try? await a { agents = known }
            await refreshSimulators()
            await refreshTasks()
        } catch { /* T3 chat remains usable if the build service is temporarily offline. */ }
    }
    func tasks(for project: AppProject) -> AppTasks { tasks[project.id] ?? AppTasks() }
    func refreshTasks() async {
        guard let client, let id = selectedProjectID, let list = try? await client.tasks(projectID: id) else { return }
        tasks[id] = list
    }
    func addTask(_ ask: String, in project: AppProject) async {
        guard let client else { return }
        do { try await client.addTask(projectID: project.id, ask: ask) } catch { self.error = error.localizedDescription }
        await refreshTasks()
    }
    func updateTask(_ task: AppTask, status: AppTask.Status? = nil, toTop: Bool = false) async {
        guard let client else { return }
        do { try await client.updateTask(id: task.id, status: status, toTop: toTop) } catch { self.error = error.localizedDescription }
        await refreshTasks()
    }
    private var taskMedia: [String: Data] = [:]
    /// A picture or clip attached to a task, downloaded once.
    func taskMediaData(task: String, media: String) async -> Data? {
        if let data = taskMedia[media] { return data }
        guard let client, let data = try? await client.taskMediaFile(taskID: task, id: media) else { return nil }
        taskMedia[media] = data
        return data
    }
    /// A clip attached to a task as a file to play.
    func taskVideo(task: String, media: String) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-\(media).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = await taskMediaData(task: task, media: media), (try? data.write(to: url)) != nil else { return nil }
        return url
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
    func buildDetail(id: String) async throws -> (AppBuild, BuildFailure?) {
        guard let client else { throw ClientError.configuration }; return try await client.build(id: id)
    }
    func buildLog(id: String, offset: Int, limit: Int) async throws -> BuildLogPage {
        guard let client else { throw ClientError.configuration }; return try await client.buildLog(id: id, offset: offset, limit: limit)
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
