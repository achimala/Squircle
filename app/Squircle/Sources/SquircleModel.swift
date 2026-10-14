import AVFoundation
import Foundation
import Network
import UIKit

/// How a message the conversation sent ended, addressed to the conversation
/// that sent it.
enum SendOutcome: Equatable {
    /// T3 took it, in this thread (new when the conversation was a draft).
    case sent(threadID: String)
    case failed(String)
}

@MainActor
final class SquircleModel {
    /// The conversation on screen: a T3 thread, or a draft T3 hasn't been
    /// told about yet (each draft its own, so a late send can't land in a
    /// later one).
    enum Conversation: Hashable {
        case thread(String)
        case draft(UUID, projectID: String?, agent: Bool)
    }
    private(set) var open: Conversation = .draft(UUID(), projectID: nil, agent: false) { didSet { changed() } }
    var selectedSessionID: String? { if case .thread(let id) = open { return id }; return nil }
    /// The open draft is a first message to the app's agent.
    private var draftIsAgent: Bool { if case .draft(_, _, true) = open { return true }; return false }
    private(set) var sessions: [ChatSession] = [] { didSet { changed() } }
    private(set) var messages: [ChatMessage] = [] { didSet { changed() } }
    private(set) var builds: [AppBuild] = [] { didSet { changed() } }
    private(set) var projects: [AppProject] = [] { didSet { changed() } }
    private(set) var appMetadata: [AppMetadata] = [] { didSet { changed() } }
    private(set) var selectedProjectID: String? { didSet { changed() } }
    private(set) var buildingProjectIDs = Set<String>() { didSet { changed() } }
    private(set) var connected = false { didSet { changed() } }
    private(set) var isRunning = false { didSet { changed() } }
    private(set) var isLoading = false { didSet { changed() } }
    private(set) var status = "Connecting" { didSet { changed() } }
    var error: String? { didSet { changed() } }
    var composerPrefill: String? { didSet { changed() } }
    /// Pictures in each conversation's message field, sent with its next message.
    private var drafts: [Conversation: [ImageAttachment]] = [:] { didSet { changed() } }
    /// Pictures in the open conversation's field.
    var attachments: [ImageAttachment] { drafts[open] ?? [] }
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
    /// The exact command that runs the Mac's Squircle CLI, from the service.
    private(set) var cli: String?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var closed = false
    /// Model changes as an async sequence. A burst coalesces into one element,
    /// so a slow consumer never falls behind.
    var updates: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        guard !closed else { continuation.finish(); return stream }
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
    /// Reading the last Home from disk; the first connection waits for it so
    /// T3 can resume the shell from its sequence instead of resending it.
    private var homeLoad: Task<Void, Never>?
    /// Reading the open thread from disk; its subscription resumes from it.
    private var diskLoad: (id: String, task: Task<Void, Never>)?
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
    /// Each app's newest preview picture: (version, PNG) by app.
    private var previewCache = BoundedCache<String, (version: String, data: Data)>(budget: 24 << 20, cost: { $0.data.count })
    private var launchReported = false
    private var sessionProjects: [String:String] = [:]
    /// Conversations with a send under way.
    private var submitting = Set<Conversation>()
    private var stepDetails: Task<Void,Never>?
    /// Activities the details fetch was last asked for (the fetch itself
    /// retries until it succeeds; `detailsSince` moves only on success).
    private var stepDetailsCount = -1
    /// Threads seen this session, so returning to one shows it at once.
    private var threadCache = BoundedCache<String, CachedThread>(budget: 12)
    private struct CachedThread { var state: T3ThreadState; var messages: [ChatMessage] }
    private var cacheWrite: Task<Void, Never>?
    private let disk = DiskCache()
    private var diskGeneration: UInt64 = 0
    /// Rebuilds `messages` off the main actor; `conversationDirty` asks for
    /// another pass once the one under way is done.
    private var conversationBuild: Task<Void, Never>?
    private var conversationDirty = false
    private var networkWatcher: Task<Void, Never>?
    private var memoryWatcher: Task<Void, Never>?
    private var threadResubscribe: Task<Void, Never>?
    private var debugDrops: Task<Void, Never>?
    private var installWatch: Task<Void, Never>?
    /// When the current connection came up, and how many subscriptions T3
    /// ended soon after one did: the next attempt waits longer each time.
    private var connectedAt: ContinuousClock.Instant?
    private var unstableCount = 0
    private static let subscriptionLost = "T3 stopped sending updates; reconnecting."
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
        if case .failed(let status) = AppConfiguration.Shared.lastStore.withLock({ $0 }) {
            error = "Squircle couldn’t share its Mac connection with app overlays (Keychain error \(status)). Apps you build may show as unpaired."
        }
        // Home shows the last known apps and threads; T3 then replaces them.
        if configuration != nil {
            homeLoad = Task { [weak self, disk] in
                guard let home = await disk.loadHome(), let self, shell == .null else { return }
                shell = home.shell; if appMetadata.isEmpty { appMetadata = home.metadata }; shellChanged()
            }
        }
        gateway?.onDisconnect = { [weak self] in
            guard let self else { return }
            connected = false; status = "Reconnecting"; threadSubscription = nil; connectedAt = nil
            log("T3 socket dropped; reconnecting"); ConnectionTrace.mark("disconnected")
            keepConnected()
        }
        if gateway != nil { watchNetwork() }
        watchMemory()
        #if DEBUG
        // Verification only: T3's socket fails every N seconds.
        if let every = ProcessInfo.processInfo.environment["SQUIRCLE_DROP_T3_EVERY"].flatMap(Double.init), every > 0 {
            debugDrops = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(every))
                    guard let self else { return }
                    gateway?.dropForTesting()
                }
            }
        }
        #endif
    }
    /// Ends this model for good: every task it started stops, T3's socket
    /// closes and both HTTP sessions are invalidated, so nothing it owns
    /// outlives it. Observers' update streams finish.
    func close() {
        guard !closed else { return }
        saveCurrentThread()
        closed = true; suspended = true
        for task in [connector, nap, configLoader, monitor, networkWatcher, memoryWatcher, stepDetails, cacheWrite, homeWrite,
                     simulatorRefresh, conversationBuild, threadResubscribe, debugDrops, installWatch] { task?.cancel() }
        connector = nil; nap = nil; configLoader = nil; monitor = nil; networkWatcher = nil; memoryWatcher = nil
        stepDetails = nil; cacheWrite = nil; homeWrite = nil; simulatorRefresh = nil; conversationBuild = nil
        threadResubscribe = nil; debugDrops = nil; installWatch = nil
        for upload in captureUploads.values { upload.cancel() }
        captureUploads.removeAll()
        gateway?.close(); client?.invalidate()
        endBackgroundTask()
        connected = false; status = "Closed"
        let finished = observers.values; observers.removeAll()
        for observer in finished { observer.finish() }
    }
    func refresh() async {
        guard gateway != nil, client != nil else { error = ClientError.configuration.localizedDescription; return }
        // The service doesn't depend on T3: both load at once.
        if !connected { failingSince = nil; keepConnected(); nap?.cancel() }
        await refreshServices()
    }
    /// Builds, app metadata and agents come from the Squircle service, not T3.
    private func refreshServices() async {
        guard !refreshing, let client else { return }; refreshing = true
        defer { refreshing = false }
        do {
            if let failure = await refreshMetadata() { throw failure }
            scheduleHomeWrite()
            ConnectionTrace.mark("services.builds+apps")
            if connected { await ensureScopedProject() }
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
        // T3 ended a subscription soon after the last connection came up:
        // wait before trying again, longer each time.
        let first: Duration = unstableCount == 0 ? .zero : min(.milliseconds(500) * (1 << min(unstableCount, 6)), .seconds(30))
        connector = Task { [weak self] in
            var delay = first
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
            if connected { await ensureScopedProject() }
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
    /// snapshot then brings it up to date. Models load afterwards from the
    /// service, which trims T3's 1 MB config.
    private func openConnection() async throws {
        guard let gateway else { throw ClientError.configuration }
        ConnectionTrace.mark("connect.start")
        await homeLoad?.value; homeLoad = nil
        try await gateway.connect()
        do {
            // With a shell already held, T3 sends only what changed since
            // (or a fresh snapshot when it can't).
            var shellRequest: [String: Any] = ["requestCompletionMarker": true]
            if let sequence = shell["snapshotSequence"].int { shellRequest["afterSequence"] = sequence }
            try await gateway.subscribe("orchestration.subscribeShell", .from(shellRequest), receive: { [weak self] in self?.consumeShell($0, batched: true) },
                                        ended: { [weak self] in self?.connectionSubscriptionEnded("shell", $0) })
            // Its first value is the whole device state.
            try await gateway.subscribe("subscribeDeviceState", receive: { [weak self] in self?.consumeDevices($0) },
                                        ended: { [weak self] in self?.connectionSubscriptionEnded("devices", $0) })
            threadSubscription = nil
            if let id = selectedSessionID { try await subscribeThread(id) }
            ConnectionTrace.mark("connect.subscribed")
            // The socket may have failed while subscribing; then try again.
            guard gateway.isOpen, !suspended else { throw ClientError.connection("T3") }
        } catch { gateway.disconnect(notify: false); throw gateway.rejection ?? error }
        connected = true; status = isRunning ? "Working" : "Connected"; failingSince = nil; connectedAt = .now
        // An unstable connection keeps saying so until it holds.
        if unstableCount == 0 || error != Self.subscriptionLost { error = nil }
        log("T3 connected"); ConnectionTrace.mark("connected")
        loadConfig()
        // A thread opened while this attempt was under way.
        if let id = selectedSessionID, threadSubscription == nil { await selectSession(id) }
    }
    /// T3 ended the shell or device subscription while the socket stayed
    /// up: the phone would show Connected and never update. Start again.
    private func connectionSubscriptionEnded(_ name: String, _ failure: Error?) {
        guard let gateway, connected else { return }
        log("T3 ended the \(name) subscription: \(failure?.localizedDescription ?? "completed")")
        let quick = connectedAt.map { $0.duration(to: .now) < .seconds(60) } ?? true
        unstableCount = quick ? unstableCount + 1 : 1
        error = Self.subscriptionLost
        gateway.disconnect(notify: true)
    }
    /// The connection held for a minute: forget earlier instability.
    private func noteStability() {
        guard unstableCount > 0, connected, let connectedAt, connectedAt.duration(to: .now) >= .seconds(60) else { return }
        unstableCount = 0
        if error == Self.subscriptionLost { error = nil }
    }
    private func loadConfig() {
        guard configLoader == nil, configLoaded.map({ $0.duration(to: .now) > .seconds(600) }) ?? true else { return }
        configLoader = Task { [weak self] in
            // A failure here is retried on the next connection.
            if let config = try? await self?.client?.providers() {
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
        networkWatcher = Task { [weak self] in
            var previous: NWPath?
            for await path in NWPathMonitor() {
                guard let self else { return }
                defer { previous = path }
                metered = path.isExpensive || path.isConstrained
                #if DEBUG
                if ProcessInfo.processInfo.environment["SQUIRCLE_METERED"] == "1" { metered = true }
                #endif
                guard let before = previous, path.status == .satisfied, !suspended else { continue }
                if connected {
                    if before.status != .satisfied || before.availableInterfaces.map(\.name) != path.availableInterfaces.map(\.name) {
                        _ = await gateway?.probe()
                    }
                } else { failingSince = nil; keepConnected(); nap?.cancel() }
            }
        }
    }
    /// Memory pressure: drop what can be fetched again. The open thread and
    /// files being played stay.
    private func watchMemory() {
        memoryWatcher = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                guard let self else { return }
                StepImages.removeAll(); MediaFiles.urls.removeAll()
                previewCache.removeAll(); taskMedia.removeAll()
                let id = selectedSessionID, kept = id.flatMap { self.threadCache.peek($0) }
                threadCache.removeAll()
                if let id, let kept { threadCache.set(kept, for: id) }
            }
        }
    }
    /// T3 bumps the device state's `revision` every few seconds with nothing
    /// else changed; only a real change reaches the screen and the Mac.
    private func consumeDevices(_ value: JSONValue) {
        func content(_ v: JSONValue) -> JSONValue { var o = v.object; o["revision"] = nil; return .object(o) }
        guard content(value) != content(devices) else { return }
        devices = value
    }
    private func consumeShell(_ item: JSONValue, batched: Bool = false) {
        liveShell = true
        if item["kind"].string == "snapshot" { shell = item["snapshot"]; ConnectionTrace.mark("shell.snapshot") }
        else if item["kind"].string == "synchronized" {
            // Up to date with T3, whether or not anything changed.
            if ConnectionTrace.enabled, !tracedHome, !projects.isEmpty { tracedHome = true; ConnectionTrace.mark("home.live", "synchronized") }
            return
        }
        else {
            // Replayed and live events overlap; each applies once, and the
            // shell remembers how far it got for the next resume.
            let sequence = item["sequence"].int
            if let sequence, let held = shell["snapshotSequence"].int, sequence <= held { return }
            var s = shell.object
            if let sequence { s["snapshotSequence"] = .number(Double(sequence)) }
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
        guard batched else { shellChanged(); scheduleHomeWrite(); return }
        // A resumed shell arrives as many events at once: Home follows
        // once they're all in.
        guard !shellPending else { return }
        shellPending = true
        Task { [weak self] in
            guard let self, shellPending else { return }
            shellPending = false; shellChanged(); scheduleHomeWrite()
        }
    }
    private var shellPending = false
    private func shellChanged() {
        sessions = shell["threads"].array.filter { $0["deletedAt"] == .null && $0["archivedAt"] == .null }.map { t in
            if let id = t["id"].string { sessionProjects[id] = t["projectId"].string }
            let working = ["running","starting"].contains(t["session"]["status"].string ?? "")
            let phase: ChatSession.Phase = t["hasPendingApprovals"].bool || t["hasPendingUserInput"].bool ? .needsYou : working ? .working : .idle
            return ChatSession(id:t["id"].string ?? "",title:t["title"].string ?? "New thread",updatedAt:t["updatedAt"].date,
                               phase:phase,modelSelection:t["modelSelection"])
        }.sorted { $0.updatedAt > $1.updatedAt }
        reconcileProjects()
        if ConnectionTrace.enabled, liveShell, !tracedHome, !projects.isEmpty {
            tracedHome = true; ConnectionTrace.mark("home.live", "projects=\(projects.count) threads=\(sessions.count)")
        }
    }
    private var tracedHome = false, liveShell = false
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
    private func adopt(_ directory: AgentDirectory) {
        agents = directory.agents
        if let command = directory.cli { cli = command }
    }
    /// The Mac's Squircle service, for notification registration.
    var service: SquircleClient? { client }
    /// Restarts the app's agent session, or replaces it with a new thread;
    /// the Mac does it once the agent's turn ends, and the agent view
    /// follows the new thread when the Mac reports it.
    func resetAgent(_ project: AppProject, fresh: Bool) async {
        guard let client else { return }
        do {
            try await client.resetAgent(projectID: project.id, fresh: fresh)
            await refreshMetadata(fresh: true)
        } catch { self.error = error.localizedDescription }
    }
    func builds(for project: AppProject) -> [AppBuild] { builds.filter { $0.request?.key == project.buildRequest?.key && $0.request != nil } }
    func metadata(for project: AppProject) -> AppMetadata? { appMetadata.first { $0.id == project.metadataID } }
    /// Shows a thread immediately from what was last seen of it this
    /// session; a copy on disk follows a moment later, read off the main
    /// actor. The live subscription then brings it up to date.
    func prepareSession(_ id: String) {
        guard selectedSessionID != id || (state.sequence < 0 && diskLoad?.id != id) else { return }
        saveCurrentThread()
        threadResubscribe?.cancel(); threadResubscribe = nil
        open = .thread(id); requests = []; isRunning = false
        ConnectionTrace.mark("thread.open", id); tracedRows = false
        stepDetails?.cancel(); stepDetailsCount = -1
        if let cached = threadCache.value(for: id) {
            show(cached.state, messages: cached.messages)
        } else {
            show(T3ThreadState(), messages: [])
            guard configuration != nil else { return }
            diskLoad = (id, Task { [weak self, disk] in
                guard let loaded = await disk.loadThread(id), let self,
                      selectedSessionID == id, state.sequence < 0 else { return }
                show(loaded, messages: nil)
            })
        }
    }
    /// Puts `restored` on screen as the open thread's state; `messages` nil
    /// derives them.
    private func show(_ restored: T3ThreadState, messages derived: [ChatMessage]?) {
        guard let id = selectedSessionID else { return }
        ConnectionTrace.mark("thread.cached", "seq=\(restored.sequence) memory=\(derived != nil)")
        state = restored
        if state.sequence >= 0 { state.fromCache = true }
        if let derived { conversationBuild?.cancel(); conversationBuild = nil; conversationDirty = false; messages = derived }
        else { rebuildConversation() }
        requests = state.pendingRequests; changes = state.changes; isRunning = state.isRunning
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
    private func subscribeThread(_ id: String, fresh: Bool = false) async throws {
        guard let gateway else { return }
        if let load = diskLoad, load.id == id { await load.task.value }
        if diskLoad?.id == id { diskLoad = nil }
        guard selectedSessionID == id else { return }
        // Holding the thread up to some point (this session or on disk), T3
        // sends only the events since, or a snapshot when it can't: a long
        // agent thread's snapshot is over half a megabyte.
        var request: [String: Any] = ["threadId": id, "requestCompletionMarker": true]
        if !fresh, state.sequence >= 0 { request["afterSequence"] = state.sequence }
        let subscription = try await gateway.subscribe("orchestration.subscribeThread", .from(request), receive: { [weak self] item in
            guard let self, selectedSessionID == id else { return }
            consumeThread(item)
        }, ended: { [weak self] failure in self?.threadSubscriptionEnded(id, failure) })
        guard selectedSessionID == id else { await gateway.unsubscribe(subscription); return }
        threadSubscription = subscription
    }
    private func resubscribeFresh(_ id: String) {
        threadResubscribe?.cancel()
        threadResubscribe = Task { [weak self] in
            guard let self, selectedSessionID == id, connected else { return }
            let previous = threadSubscription; threadSubscription = nil
            await gateway?.unsubscribe(previous)
            try? await subscribeThread(id, fresh: true)
        }
    }
    /// T3 ended the open thread's subscription with the socket still up.
    /// Subscribe again, waiting longer each time; after a few tries say so.
    private func threadSubscriptionEnded(_ id: String, _ failure: Error?) {
        guard selectedSessionID == id, connected else { return }
        threadSubscription = nil
        log("T3 ended thread \(id)'s subscription: \(failure?.localizedDescription ?? "completed")")
        threadResubscribe?.cancel()
        threadResubscribe = Task { [weak self] in
            var delay: Duration = .seconds(1)
            for attempt in 1...5 {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, selectedSessionID == id, connected, threadSubscription == nil else { return }
                guard sessions.contains(where: { $0.id == id }) || shell == .null else {
                    error = "This thread is no longer on your Mac."; return
                }
                do { try await subscribeThread(id); return }
                catch { if attempt >= 3 { self.error = "This thread stopped updating: " + error.localizedDescription } }
                delay = min(delay * 2, .seconds(30))
            }
        }
    }
    /// A new conversation that T3 has not been told about yet. The thread is
    /// created by its first message, so abandoned drafts leave nothing behind.
    func beginDraft(agent: Bool = false) async {
        saveCurrentThread()
        threadResubscribe?.cancel(); threadResubscribe = nil
        // Pictures left in drafts nobody can reach any more.
        drafts = drafts.filter { key, _ in if case .draft = key { return submitting.contains(key) }; return true }
        open = .draft(UUID(), projectID: selectedProjectID, agent: agent)
        messages = []; requests = []; changes = []; state = T3ThreadState(); isRunning = false; error = nil
        conversationBuild?.cancel(); conversationBuild = nil; conversationDirty = false
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
        guard !isRunning, !submitting.contains(open), isValidModel(selection) else { return }
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
    // MARK: Caches on disk

    private var homeWrite: Task<Void, Never>?
    /// Shell events arrive in bursts; the copy on disk trails by a couple of seconds.
    private func scheduleHomeWrite() {
        guard configuration != nil, homeWrite == nil, shell != .null else { return }
        homeWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            homeWrite = nil
            let home = DiskCache.Home(shell: shell, metadata: appMetadata)
            diskGeneration += 1
            Task { [disk, diskGeneration] in await disk.saveHome(home, generation: diskGeneration) }
        }
    }
    private func saveCurrentThread() {
        guard let id = selectedSessionID, state.sequence >= 0 else { return }
        threadCache.set(CachedThread(state: state, messages: messages), for: id)
        cacheWrite?.cancel(); cacheWrite = nil
        writeToDisk(id, state)
    }
    /// Keeps the on-disk copy current without writing on every event.
    private func scheduleCacheWrite() {
        guard let id = selectedSessionID else { return }
        threadCache.set(CachedThread(state: state, messages: messages), for: id)
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
        diskGeneration += 1
        Task { [disk, diskGeneration] in await disk.saveThread(id, state, generation: diskGeneration) }
    }

    // MARK: Thread

    /// Derives `messages` from the open thread off the main actor, one pass
    /// at a time; changes during a pass ask for one more.
    private func rebuildConversation() {
        conversationDirty = true
        guard conversationBuild == nil else { return }
        conversationBuild = Task { [weak self] in
            while let model = self, model.conversationDirty, !Task.isCancelled {
                model.conversationDirty = false
                let id = model.selectedSessionID, snapshot = model.state
                let rows = await Self.conversation(snapshot)
                guard !Task.isCancelled else { return }
                if model.selectedSessionID == id {
                    model.messages = rows
                    if ConnectionTrace.enabled { model.traceRows(rows.count) }
                    if let id, model.threadCache.peek(id) != nil {
                        model.threadCache.set(CachedThread(state: model.state, messages: rows), for: id)
                    }
                }
            }
            self?.conversationBuild = nil
        }
    }

    private var tracedRows = false
    private var tracedEventAt: String?
    private func traceRows(_ count: Int) {
        if !tracedRows, state.sequence >= 0, !state.fromCache {
            tracedRows = true; ConnectionTrace.mark("thread.rows", "rows=\(count) seq=\(state.sequence)")
        }
        if let at = tracedEventAt {
            tracedEventAt = nil
            ConnectionTrace.mark("event.onScreen", String(format: "%.0fms", Date().timeIntervalSince(JSONValue.string(at).date) * 1000))
        }
    }
    func consumeThread(_ item: JSONValue) {
        if item["kind"].string == "synchronized" { ConnectionTrace.mark("thread.synchronized"); tracedRows = true; return }
        if ConnectionTrace.enabled {
            switch item["kind"].string {
            case "snapshot": ConnectionTrace.mark("thread.snapshot", "seq=\(item["snapshot"]["snapshotSequence"].int ?? -1)")
            default: if tracedRows, let at = item["event"]["occurredAt"].string { tracedEventAt = at }
            }
        }
        let held = state.sequence
        state.consume(item); rebuildConversation(); requests = state.pendingRequests
        // A revert rewrote history the phone can't replay: start from a snapshot.
        if held >= 0, state.sequence < 0, let id = selectedSessionID { resubscribeFresh(id) }
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
    /// Adds a picture to the open conversation's field; one with the same
    /// `id` is replaced.
    func attach(_ attachment: ImageAttachment) {
        var field = drafts[open] ?? []
        if let index = field.firstIndex(where: { $0.id == attachment.id }) { field[index] = attachment }
        else { field.append(attachment) }
        drafts[open] = field
        // A recording starts its way to the Mac at once; sending waits for it.
        if let capture = attachment.capture, let client {
            captureUploads[attachment.id]?.cancel()
            captureUploads[attachment.id] = Task { try await client.uploadCapture(capture.file, kind: capture.kind.rawValue) }
        }
    }
    func removeAttachment(_ id: String) {
        drafts[open]?.removeAll { $0.id == id }
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
    /// Everything a send needs, fixed when it starts: where it goes, with
    /// which model, mode and pictures, and what the thread already had. A
    /// later navigation changes none of it.
    private struct SendContext {
        let origin: Conversation
        let project: AppProject
        let selection: JSONValue
        let mode: T3RuntimeMode
        let field: [ImageAttachment]
        /// The thread is the app's agent (its instructions come from the Mac).
        let agentThread: Bool
        let firstMessage: Bool
        let hasInstructions: Bool
    }
    /// Sends `text` with the field's pictures to `threadID`, or from the open
    /// draft when nil (`agent`: the app's agent draft). Pictures leave the
    /// field at once and go back into that conversation's field if T3 does
    /// not take the message. Selection changes only when the draft that
    /// sent is still open: its new thread takes its place.
    func send(_ spoken: String, in project: AppProject, to threadID: String?, agent: Bool) async -> SendOutcome {
        let origin: Conversation
        if let threadID { origin = .thread(threadID) }
        else if case .draft(_, let projectID, let isAgent) = open, projectID == nil || projectID == project.id, isAgent == agent { origin = open }
        else { return .failed("This draft is no longer open.") }
        guard origin == open else { return .failed("This conversation is no longer open.") }
        guard !submitting.contains(origin) else { return .failed("Still sending the last message.") }
        let field = drafts[origin] ?? []
        guard !spoken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !field.isEmpty else { return .failed("Nothing to send.") }
        guard isValidModel(modelSelection) else { error = "Choose an available model."; return .failed("Choose an available model.") }
        let messages = threadID == nil ? [] : state.thread["messages"].array
        let context = SendContext(
            origin: origin, project: project, selection: modelSelection, mode: runtimeMode, field: field,
            agentThread: agent || threadID.map { agents[project.id] == $0 } == true
                || (threadID != nil && state.thread["modelSelection"]["instanceId"].string == Self.agentInstance),
            firstMessage: messages.isEmpty,
            hasInstructions: messages.contains { ($0["text"].string ?? "").contains("sim start --thread") })
        submitting.insert(origin); drafts[origin] = nil; error = nil
        defer { submitting.remove(origin) }
        var created: String?
        let outcome = await deliver(spoken, context, created: &created)
        if case .failed(let reason) = outcome {
            // Back into the field it came from (the new thread's, if one was made).
            let home: Conversation = created.map(Conversation.thread) ?? origin
            let now = drafts[home] ?? []
            drafts[home] = field + now.filter { a in !field.contains { $0.id == a.id } }
            if open == origin || open == home { error = reason }
        }
        return outcome
    }
    /// `created`: the thread this send made, if it got that far.
    private func deliver(_ spoken: String, _ context: SendContext, created: inout String?) async -> SendOutcome {
        let images = context.field.filter { $0.capture == nil }, captures = context.field.filter { $0.capture != nil }
        let text: String
        do { text = try await spoken + captureBlock(captures) }
        catch { return .failed("Couldn't send the recording to your Mac: " + error.localizedDescription) }
        let project = context.project
        let id: String
        switch context.origin {
        case .thread(let thread): id = thread
        case .draft(_, _, agent: true):
            // The Mac creates the agent (its worktree and thread) in the chosen
            // mode, with this message unless it carries pictures, which go to
            // T3 from here.
            guard let client else { return .failed(ClientError.configuration.localizedDescription) }
            do {
                let model = context.selection["instanceId"].string == Self.agentInstance ? context.selection["model"].string : nil
                id = try await client.startAgent(projectID: project.id, message: images.isEmpty ? text : "", model: model, mode: context.mode)
            } catch { return .failed(error.localizedDescription) }
            agents[project.id] = id; sessionProjects[id] = project.id; created = id
            if open == context.origin { await selectSession(id) }
            if images.isEmpty {
                if selectedSessionID == id { isRunning = true; status = "Working" }
                return .sent(threadID: id)
            }
        case .draft:
            id = UUID().uuidString.lowercased()
            do {
                try await dispatch(["type":"thread.create","threadId":id,"projectId":project.id,"title":"New thread",
                    "modelSelection":context.selection.foundation,"runtimeMode":context.mode.rawValue,"interactionMode":"default",
                    "branch":NSNull(),"worktreePath":NSNull()])
            } catch { return .failed(error.localizedDescription) }
            pendingRuntimeModes[id] = context.mode; sessionProjects[id] = project.id; created = id
            if open == context.origin { await selectSession(id) }
        }
        var message = text
        let instructions = squircleInstructions(for: project, threadID: id)
        if !context.agentThread, context.firstMessage {
            message += "\n\n" + project.agentContext + "\nFor signed builds/install links use \(cliCommand). Run help workflow for the documented commands. This app is a native client of T3; T3 manages this thread.\n" + instructions
        } else if !context.agentThread, !context.hasInstructions {
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
        do {
            try await dispatch(["type":"thread.turn.start","threadId":id,
                "message":["messageId":UUID().uuidString.lowercased(),"role":"user","text":message,"attachments":uploads],
                "modelSelection":context.selection.foundation,"runtimeMode":context.mode.rawValue,
                "interactionMode":"default","titleSeed":String((seed.isEmpty ? (captures.isEmpty ? "Image" : "Recording") : seed).prefix(120))])
        } catch { return .failed(error.localizedDescription) }
        if selectedSessionID == id { isRunning = true; status = "Working" }
        return .sent(threadID: id)
    }
    /// T3 streams tool calls without their inputs or screenshots; the Mac
    /// fills those in shortly after each new activity. A failed fetch tries
    /// again, waiting longer each time, for as long as the thread is open.
    private func scheduleStepDetails() {
        guard client != nil, let id = selectedSessionID else { return }
        stepDetails?.cancel()
        stepDetails = Task { [weak self] in
            var wait: Duration = .milliseconds(400)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let done = await self?.fetchStepDetails(id), !done else { return }
                wait = max(.seconds(2), min(wait * 2, .seconds(60)))
            }
        }
    }
    /// Fetches the thread's step details and media, then commits both at
    /// once to that thread if it is still open. False: try again later.
    private func fetchStepDetails(_ id: String) async -> Bool {
        guard let client, selectedSessionID == id else { return true }
        let since = state.detailsVersion == 2 ? state.detailsSince : nil
        let stepsStart = ContinuousClock.now
        defer { ConnectionTrace.mark("steps", "since=\(since != nil) \(stepsStart.duration(to: .now))") }
        let steps: [JSONValue], workers: [JSONValue]?, published: [JSONValue]
        do {
            async let media = client.threadMedia(threadID: id)
            (steps, workers) = try await client.threadSteps(threadID: id, since: since)
            published = try await media
        } catch { return Task.isCancelled }
        // Navigation while either was under way: the details belong to `id`
        // only, never to whichever thread is open now.
        guard !Task.isCancelled, selectedSessionID == id else { return true }
        if let workers {
            state.detailsVersion = 2
            let known = Self.workers(workers)
            if known != self.workers { self.workers = known }
        }
        var changed = false
        if published != media { state.media = published; changed = true }
        for step in steps {
            guard let key = step["id"].string else { continue }
            var merged = state.details[key]?.object ?? [:]
            for (field, value) in step.object where field != "started_at" || merged[field] == nil { merged[field] = value }
            state.details[key] = .object(merged)
            if let at = step["updated_at"].string, at > (state.detailsSince ?? "") { state.detailsSince = at }
            changed = true
        }
        if changed { rebuildConversation(); scheduleCacheWrite() }
        return true
    }
    /// `squircle media add` writes on the Mac without any T3 activity, so the
    /// open thread's media is checked on the regular refresh too.
    private func adoptMedia(_ published: [JSONValue], for id: String) {
        guard selectedSessionID == id, published != media else { return }
        state.media = published
        rebuildConversation(); scheduleCacheWrite()
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
    /// T3's conversation with the thread's published recordings in time
    /// order. Runs off the main actor: long histories take a while.
    private nonisolated static func conversation(_ state: T3ThreadState) async -> [ChatMessage] {
        let rows = state.messages, media = state.media
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
    /// Cellular, a personal hotspot or Low Data Mode.
    private var metered = false
    /// A turn's recording plays inline once downloaded; on a metered network
    /// only a small one downloads by itself, a large one shows its poster
    /// until tapped (a long session is well over 100 MB).
    func autoLoadsRecording(_ id: String) -> Bool {
        guard metered else { return true }
        let bytes = media.first { $0["id"].string == id }?["bytes"].double ?? .infinity
        return bytes <= 15_000_000
    }
    /// The poster Squircle took when it stopped recording, if any.
    func recordingPoster(_ id: String) async -> Data? {
        let key = "poster:" + id
        if let data = StepImages.data(for: key, index: 0) { return data }
        guard !posterless.contains(id), let client, let thread = selectedSessionID else { return nil }
        do {
            let data = try await client.mediaPoster(threadID: thread, id: id)
            StepImages.set(data, for: key, index: 0)
            return data
        } catch ClientError.http(_, 404) { posterless.insert(id); return nil }
        catch { return nil }
    }
    /// Recordings made before Squircle took posters.
    private var posterless = Set<String>()
    func loadVideo(_ stepID: String) async -> URL? {
        if let url = StepVideos.url(for: stepID) { return url }
        if stepID.hasPrefix("file:") {
            let path = String(stepID.dropFirst("file:".count))
            guard let data = await mediaFileData(path) else { return nil }
            let url = StepVideos.directory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension((path as NSString).pathExtension)
            guard (try? data.write(to: url)) != nil else { return nil }
            StepVideos.set(url, for: stepID)
            return url
        }
        let id = String(stepID.dropFirst("media:".count))
        guard let client, let thread = selectedSessionID,
              let data = try? await client.mediaFile(threadID: thread, id: id) else { return nil }
        let url = StepVideos.directory.appendingPathComponent(id + ".mp4")
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
            let id = String(stepID.dropFirst("media:".count))
            if message?.videoID != nil, let poster = await recordingPoster(id) {
                data = poster
            } else if message?.videoID != nil, autoLoadsRecording(id), let url = await loadVideo(stepID) {
                data = await Self.poster(of: url)
            } else if message?.videoID != nil {
                data = nil
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
              let relative = asset["relativeUrl"].string, let url = T3HTTP.assetURL(relative, base: base) else { return nil }
        let size = asset["imageDimensions"]["width"].double.flatMap { width in
            asset["imageDimensions"]["height"].double.map { CGSize(width: width, height: $0) }
        }
        return (url, asset["expiresAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }, size)
    }
    private func signedData(_ url: URL) async -> Data? {
        await gateway?.http.authorizedData(url)
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
        let cli = cliCommand
        return """
        Squircle shows this thread on the user's iPhone. Whenever you run, check or demonstrate the app in a simulator, first run \(cli) sim start --thread \(threadID) (see sim --help): it opens and boots a simulator, records it, and the user watches it live; the recording appears in your turn. Drive it with the agent-device command it returns and use device_screenshot to look; those screenshots appear in the conversation. Run \(cli) sim stop --thread \(threadID) when done. Don't run agent-device record or device_open yourself. When you make a signed build for the user, include its build job ID in your final reply; Squircle shows it with an Install button. A performance recording the user sends from the app is a linked .perf.json: \(cli) perf show PATH summarizes it (hitches with symbolicated main-thread stacks, timeline); a screen recording is a linked .mp4.
        """
    }
    /// How the Mac's service says to run its CLI; plain `squircle` (on the
    /// agent's PATH) from a service too old to say.
    var cliCommand: String { cli ?? "squircle" }
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
        adoptSimulators(active)
    }
    private func adoptSimulators(_ active: [JSONValue]) {
        guard active != recording else { return }
        let ended = Set(recording.compactMap { $0["thread_id"].string }).subtracting(active.compactMap { $0["thread_id"].string })
        recording = active
        // A recording just filed belongs in the conversation on screen.
        if let id = selectedSessionID, ended.contains(id) { scheduleStepDetails() }
    }
    func startMetadataUpdates() {
        ConnectionTrace.mark("metadata.start", "running=\(monitor != nil)")
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMetadata(); try? await Task.sleep(for:.seconds(4))
            }
        }
    }
    func stopMetadataUpdates() { ConnectionTrace.mark("metadata.stop"); monitor?.cancel(); monitor = nil }
    /// Everything the phone keeps from the Mac's service, fetched at once:
    /// one round trip per poll, and an unchanged reply is an empty 304.
    /// A refresh already under way is joined; `fresh` waits for it and then
    /// asks again, for callers that just changed something. Returns why the
    /// builds or apps couldn't be fetched, if they couldn't.
    @discardableResult
    func refreshMetadata(fresh: Bool = false) async -> Error? {
        if let running = metadataRefresh {
            let error = await running.value
            if !fresh { return error }
        }
        let refresh = Task { await fetchMetadata() }
        metadataRefresh = refresh
        let error = await refresh.value
        if metadataRefresh == refresh { metadataRefresh = nil }
        return error
    }
    private var metadataRefresh: Task<Error?, Never>?
    private func fetchMetadata() async -> Error? {
        guard let client else { return nil }
        let pollStart = ContinuousClock.now
        defer { ConnectionTrace.mark("poll", "\(pollStart.duration(to: .now))") }
        noteStability()
        let project = selectedProjectID, thread = selectedSessionID
        async let b = client.builds(); async let m = client.fetchAppMetadata(); async let a = try? client.agents()
        async let sims = try? client.simulatorSessions()
        async let list: AppTasks? = { guard let project else { return nil }; return try? await client.tasks(projectID: project) }()
        async let published: [JSONValue]? = { guard let thread else { return nil }; return try? await client.threadMedia(threadID: thread) }()
        let failure: Error?
        do {
            let (newBuilds, newMetadata) = try await (b, m)
            if newBuilds != builds { builds = newBuilds }
            if newMetadata != appMetadata { appMetadata = newMetadata }
            reconcileProjects()
            failure = nil
        } catch { failure = error }  // T3 chat remains usable if the build service is temporarily offline.
        if let known = await a { adopt(known) }
        if let active = await sims { adoptSimulators(active) }
        if let project, let tasks = await list { self.tasks[project] = tasks }
        if let thread, let media = await published { adoptMedia(media, for: thread) }
        return failure
    }
    func tasks(for project: AppProject) -> AppTasks { tasks[project.id] ?? AppTasks() }
    func refreshTasks() async {
        guard let client, let id = selectedProjectID, let list = try? await client.tasks(projectID: id) else { return }
        tasks[id] = taskEdits.reduce(list) { list, edit in Self.apply(edit.value, to: edit.key, in: list) }
    }
    func addTask(_ ask: String, in project: AppProject) async {
        guard let client else { return }
        do { try await client.addTask(projectID: project.id, ask: ask) } catch { self.error = error.localizedDescription }
        await refreshTasks()
    }
    /// Swiped status and Top changes the Mac hasn't confirmed yet. A refresh
    /// already on its way would otherwise put the row back for a moment.
    private var taskEdits: [String: (status: AppTask.Status?, toTop: Bool)] = [:]
    /// Moves the row at once, before the Mac answers.
    func markTask(_ task: AppTask, status: AppTask.Status? = nil, toTop: Bool = false) {
        taskEdits[task.id] = (status, toTop)
        for (project, list) in tasks { tasks[project] = Self.apply((status, toTop), to: task.id, in: list) }
    }
    private static func apply(_ edit: (status: AppTask.Status?, toTop: Bool), to id: String, in list: AppTasks) -> AppTasks {
        var list = list
        guard let index = list.tasks.firstIndex(where: { $0.id == id }) else { return list }
        if let status = edit.status { list.tasks[index].status = status }
        if edit.toTop { list.tasks.insert(list.tasks.remove(at: index), at: 0) }
        return list
    }
    func updateTask(_ task: AppTask, status: AppTask.Status? = nil, toTop: Bool = false) async {
        guard let client else { return }
        markTask(task, status: status, toTop: toTop)
        do { try await client.updateTask(id: task.id, status: status, toTop: toTop) } catch { self.error = error.localizedDescription }
        taskEdits[task.id] = nil
        await refreshTasks()
    }
    private var taskMedia = BoundedCache<String, Data>(budget: 16 << 20, cost: \.count)
    /// A picture or clip attached to a task, downloaded once.
    func taskMediaData(task: String, media: String) async -> Data? {
        if let data = taskMedia.value(for: media) { return data }
        guard let client, let data = try? await client.taskMediaFile(taskID: task, id: media) else { return nil }
        taskMedia.set(data, for: media)
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
        guard let client else { throw ClientError.configuration }; let version = metadata.preview?.id ?? ""
        if let cached = previewCache.value(for: metadata.id), cached.version == version { return cached.data }
        let data = try await client.fetchAppPreview(id:metadata.id,previewID:metadata.preview?.id)
        previewCache.set((version, data), for: metadata.id); return data
    }
    /// Apps without a published preview show the newest screenshot an agent
    /// took in their threads. `version` changes as those threads move on.
    func threadScreenshot(for project: AppProject, version: String) async throws -> Data {
        guard let client else { throw ClientError.configuration }; let key = "t3:" + project.id
        if let cached = previewCache.value(for: key), cached.version == version { return cached.data }
        let data = try await client.projectScreenshot(projectID: project.id)
        previewCache.set((version, data), for: key); return data
    }
    func previewData(for build: AppBuild) async throws -> Data {
        guard let client else { throw ClientError.configuration }; return try await client.fetchBuildPreview(id:build.id)
    }
    func startBuild(for project: AppProject) async -> AppBuild? {
        guard let client, let request = project.buildRequest else { error = "Import this app’s Xcode build recipe first."; return nil }
        buildingProjectIDs.insert(project.id); defer { buildingProjectIDs.remove(project.id) }
        do { let build = try await client.startBuild(request.freshSubmission()); await refreshMetadata(fresh: true); return build }
        catch { self.error = error.localizedDescription; return nil }
    }
    /// Opens iOS's install prompt. For a build of this very app, watches the
    /// download: once the Mac has sent every byte, iOS is about to replace
    /// Squircle, and `updatingTo` says so. A download that only started, or
    /// failed, never does. Gives up if the person doesn't confirm within
    /// three minutes, or the transfer doesn't finish within fifteen.
    @discardableResult
    func install(_ build: AppBuild) async -> Bool {
        guard let client else { error = ClientError.configuration.localizedDescription; return false }
        let url: URL
        do { url = try await client.installURL(buildID: build.id) } catch { self.error = error.localizedDescription; return false }
        guard await UIApplication.shared.open(url) else { error = "Couldn’t open the installer."; return false }
        guard build.bundleID != nil, build.bundleID == Bundle.main.bundleIdentifier else { return true }
        installWatch?.cancel()
        installWatch = Task { [weak self] in
            let started = ContinuousClock.now
            var confirmed = false
            while !Task.isCancelled, started.duration(to: .now) < (confirmed ? .seconds(900) : .seconds(180)) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                switch try? await client.installProgress(link: url) {
                case .transferred?: updatingTo = build; return
                case .downloading?: confirmed = true
                default: break
                }
            }
        }
        return true
    }
    func cancelUpdate() { installWatch?.cancel(); installWatch = nil; updatingTo = nil }
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

/// Squircle's copies of Home and of threads on disk, read and written off
/// the main actor, one at a time. Every write carries a generation; one
/// older than what a file already holds is dropped, so a slow snapshot never
/// replaces a newer one.
actor DiskCache {
    struct Home: Codable { var shell: JSONValue; var metadata: [AppMetadata] }
    let root: URL?
    private var written: [String: UInt64] = [:]
    init(root: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) { self.root = root }
    private var homeURL: URL? { root?.appendingPathComponent("squircle-home.json") }
    private func threadURL(_ id: String) -> URL? {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        return root?.appendingPathComponent("squircle-threads", isDirectory: true).appendingPathComponent(id + ".json")
    }
    func loadHome() -> Home? { read(homeURL) }
    func saveHome(_ home: Home, generation: UInt64) { write(home, to: homeURL, generation: generation) }
    func loadThread(_ id: String) -> T3ThreadState? { read(threadURL(id)) }
    func saveThread(_ id: String, _ state: T3ThreadState, generation: UInt64) { write(state, to: threadURL(id), generation: generation) }
    private func read<T: Decodable>(_ url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    /// True if `value` was written.
    @discardableResult
    func write<T: Encodable>(_ value: T, to url: URL?, generation: UInt64) -> Bool {
        guard let url, generation > written[url.path] ?? 0, let data = try? JSONEncoder().encode(value) else { return false }
        written[url.path] = generation
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
