import AVFoundation
import Foundation
import Network
import UIKit

/// Which conversation: a T3 thread, or a draft T3 hasn't been told about
/// yet (each draft its own, so a late send can't land in a later one). Its
/// identity is the draft or thread ID; the app it belongs to never changes.
enum ConversationID: Hashable {
    case draft(UUID, appID: String, agent: Bool)
    case thread(String, appID: String)
    var threadID: String? { if case .thread(let id, _) = self { return id }; return nil }
    var appID: String { switch self { case .draft(_, let app, _), .thread(_, let app): app } }
    /// A first message to the app's agent.
    var isAgentDraft: Bool { if case .draft(_, _, true) = self { return true }; return false }
    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.draft(let x, _, _), .draft(let y, _, _)): x == y
        case (.thread(let x, _), .thread(let y, _)): x == y
        default: false
        }
    }
    func hash(into hasher: inout Hasher) {
        switch self {
        case .draft(let id, _, _): hasher.combine(0); hasher.combine(id)
        case .thread(let id, _): hasher.combine(1); hasher.combine(id)
        }
    }
}

/// A message on its way to T3, under the conversation that owns it (a
/// draft's moves to its thread once T3 made it). Its message and command
/// IDs are chosen before the first attempt and kept for every resend, and
/// T3 keeps a receipt per command ID, so a lost answer can never turn into
/// a second message. A refused message is no longer pending.
struct PendingSend: Equatable {
    enum Phase: Equatable {
        /// Recordings on their way to the Mac.
        case preparing
        /// T3 making the draft's thread.
        case creating
        /// T3 asked to start the turn; asked again on the next connection
        /// if this one drops before T3 answers.
        case awaitingAcceptance
        /// T3 took it; pending until the message shows in the thread.
        case accepted
    }
    let messageID: String
    let text: String
    let images: Int
    /// Its recordings, by their file on the phone until the Mac has them.
    let captures: [SentCapture]
    let phase: Phase
}

/// How a send ended. `conversation` owns the message now: the thread a
/// draft created, even when the turn then failed.
enum SendOutcome: Equatable {
    case accepted(messageID: String, conversation: ConversationID)
    /// T3 or the Mac refused it, or it never left: the pictures are back in
    /// the owner's field, the text is the caller's to put back.
    case rejected(messageID: String, reason: String, conversation: ConversationID)
    var conversation: ConversationID {
        switch self { case .accepted(_, let c), .rejected(_, _, let c): c }
    }
}

enum SendStart {
    case started(messageID: String, outcome: Task<SendOutcome, Never>)
    case refused(String)
}

/// The connection to T3. Every subscription callback carries the attempt
/// that made it, so one ending during setup fails that attempt, and one from
/// an older attempt changes nothing.
enum ConnectionPhase: Equatable {
    /// Closed for good, or no configuration.
    case stopped
    /// Background time ran out; reconnects on return.
    case suspended
    /// T3 refused this build's session; retrying can't help.
    case refused
    /// An attempt under way, or the wait before the next one.
    case connecting(Attempt)
    case ready(Session)
    struct Attempt: Equatable {
        let id: Int
        /// The first failure in this run of attempts.
        let failingSince: ContinuousClock.Instant?
    }
    struct Session: Equatable {
        let attempt: Int
        let since: ContinuousClock.Instant
    }
}

/// Something fetched from the Mac and kept fresh: never requested, in
/// flight, here, or failed with when to try again. Each keeps what it last had.
enum ResourceState<Value: Equatable>: Equatable {
    case absent
    case loading(previous: Value?)
    case ready(Value, fetchedAt: ContinuousClock.Instant)
    case failed(previous: Value?, failure: String, retryAt: ContinuousClock.Instant)
    var value: Value? {
        switch self {
        case .absent: nil
        case .loading(let previous), .failed(let previous, _, _): previous
        case .ready(let value, _): value
        }
    }
}

/// What a screen needs kept fresh from the Mac while it shows.
enum RefreshNeed: Hashable {
    case tasks(appID: String)
    /// The thread's published media, while the conversation shows.
    case conversation(ConversationID)
}

/// Held for as long as a screen needs something refreshed; released on
/// `end()` or when the lease goes away.
final class RefreshLease {
    private var onEnd: (@MainActor () -> Void)?
    init(_ onEnd: @escaping @MainActor () -> Void) { self.onEnd = onEnd }
    @MainActor func end() { onEnd?(); onEnd = nil }
    deinit { if let onEnd { Task { @MainActor in onEnd() } } }
}

/// Installing a build of this very app: what has been observed of it.
/// "Transferred" means the Mac sent every byte, not that iOS installed it.
enum InstallAttempt: Equatable {
    case none
    case requestingLink(AppBuild)
    /// iOS's prompt is up; nothing fetched yet.
    case prompting(AppBuild, link: URL, deadline: ContinuousClock.Instant)
    /// iOS is fetching the IPA.
    case watching(AppBuild, link: URL, deadline: ContinuousClock.Instant)
    case transferred(AppBuild)
    case ended(String?)
}

@MainActor
final class SquircleModel {
    /// The conversation the model follows: its state, subscription and
    /// field. Nil until a screen opens one.
    private(set) var open: ConversationID? { didSet { changed() } }
    var openConversation: ConversationID? { open }
    var selectedSessionID: String? { open?.threadID }
    private(set) var sessions: [ChatSession] = [] { didSet { if sessions != oldValue { changed() } } }
    private(set) var builds: [AppBuild] = [] { didSet { changed() } }
    private(set) var projects: [AppProject] = [] { didSet { if projects != oldValue { changed() } } }
    private(set) var appMetadata: [AppMetadata] = [] { didSet { changed() } }
    private(set) var selectedProjectID: String? { didSet { changed() } }
    private(set) var buildingProjectIDs = Set<String>() { didSet { changed() } }
    private(set) var connection: ConnectionPhase {
        didSet {
            guard connection != oldValue else { return }
            changed()
            let waiting = connectionWaiters; connectionWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }
    /// Sends waiting for T3's next connection.
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    var connected: Bool { if case .ready = connection { return true }; return false }
    /// Trying to connect, and not yet long enough to call it offline.
    var isLoading: Bool {
        guard case .connecting(let attempt) = connection else { return false }
        return !Self.offline(attempt)
    }
    var status: String {
        switch connection {
        case .stopped: "Closed"
        case .suspended: "Connecting"
        case .refused: "Not signed in"
        case .connecting(let attempt): Self.offline(attempt) ? "Offline" : "Connecting"
        case .ready: isRunning ? "Working" : "Connected"
        }
    }
    /// Not reaching the Mac, past the grace of a brief reconnect.
    var isOffline: Bool {
        switch connection {
        case .stopped, .refused: true
        case .connecting(let attempt): Self.offline(attempt)
        case .ready, .suspended: false
        }
    }
    /// The connection in words: a state, why, and the colour it shows in.
    var connectionSummary: (title: String, detail: String, tint: UIColor) {
        switch connection {
        case .ready: ("Connected", "To \(hostName)", Theme.success)
        case .suspended: ("Paused", "Reconnects when the app is back in front", .secondaryLabel)
        case .stopped: ("Disconnected", error ?? "Not connected to \(hostName)", Theme.warning)
        case .refused: ("Needs pairing again", error ?? "T3 no longer accepts this build’s session", Theme.failure)
        case .connecting(let attempt):
            if Self.offline(attempt) { ("Offline", error ?? "Can’t reach \(hostName)", Theme.warning) }
            else if attempt.failingSince != nil { ("Reconnecting", error ?? "Lost \(hostName); trying again", .secondaryLabel) }
            else { ("Connecting", "To \(hostName)", .secondaryLabel) }
        }
    }
    private static func offline(_ attempt: ConnectionPhase.Attempt) -> Bool {
        attempt.failingSince.map { $0.duration(to: .now) >= reconnectGrace } ?? false
    }
    var error: String? { didSet { changed() } }
    var composerPrefill: String? { didSet { changed() } }
    /// Pictures in each conversation's message field, sent with its next message.
    private var drafts: [ConversationID: [ImageAttachment]] = [:] { didSet { changed() } }
    /// Pictures in the open conversation's field.
    var attachments: [ImageAttachment] { open.flatMap { drafts[$0] } ?? [] }
    private(set) var installAttempt = InstallAttempt.none { didSet { changed() } }
    /// A build of the running app the Mac finished sending; the app steps
    /// aside so iOS can replace it.
    var updatingTo: AppBuild? { if case .transferred(let build) = installAttempt { return build }; return nil }
    /// T3's providers and models, through the service.
    private(set) var catalog = ResourceState<[JSONValue]>.absent { didSet { changed() } }
    var providers: [JSONValue] { catalog.value ?? [] }
    private(set) var devices: JSONValue = .null { didSet { changed(); scheduleSimulatorRefresh() } }
    /// Sessions Squircle is recording for agents, from the Mac.
    private(set) var recording: [JSONValue] = [] { didSet { if recording != oldValue { changed() } } }
    private var simulatorRefresh: Task<Void, Never>?
    /// The open thread's requests, as T3 last reported them.
    private var observedRequests: [JSONValue] = [] { didSet { if observedRequests != oldValue { changed() } } }
    /// Requests answered from here, until T3 reports them resolved: request ID → command ID.
    private var responding: [String: String] = [:] { didSet { changed() } }
    /// Requests waiting for you: T3's, less those being answered.
    var requests: [JSONValue] {
        responding.isEmpty ? observedRequests : observedRequests.filter { responding[$0["payload"]["requestId"].string ?? ""] == nil }
    }
    private(set) var changes: [TurnChanges] = [] { didSet { changed() } }
    /// Every worker Squircle started, archived ones too, by thread ID.
    private(set) var workers: [String: KnownWorker] = [:] { didSet { changed() } }
    /// Model and approval choices made here that T3 hasn't reported back yet.
    private struct LocalChoice: Equatable { var model: JSONValue?; var mode: T3RuntimeMode? }
    private var choices: [ConversationID: LocalChoice] = [:] { didSet { changed() } }
    /// The model you chose last, for new drafts.
    private var preferredModel: JSONValue?
    /// Each app's tasks as the Mac last sent them (History's newest page).
    private var observedTasks: [String: AppTasks] = [:] { didSet { if observedTasks != oldValue { changed() } } }
    /// Older History pages loaded on request, by app.
    private struct OlderHistory: Equatable { var tasks: [AppTask] = []; var next: String? }
    private var olderHistory: [String: OlderHistory] = [:] { didSet { changed() } }
    private var historyLoads: Set<String> = []
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
    /// The open thread as T3 reported it, or a copy kept on the phone.
    private var state = T3ThreadState() { didSet { changed() } }
    /// The open thread's rows and the state they were made from.
    private var transcript = Transcript.empty { didSet { changed() } }
    var messages: [ChatMessage] { transcript.rows }
    private var threadSubscription: String?
    private var refreshing = false
    private var monitor: Task<Void,Never>?
    private var connector: Task<Void,Never>?
    /// The wait before the connector's next attempt; cancelling it retries now.
    private var nap: Task<Void,Never>?
    /// Reconnect was tapped: abandon the attempt under way and start afresh.
    private var retryNow = false
    private var attempts = 0
    private var configLoader: Task<Void,Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Each app's newest preview picture: (version, PNG) by app.
    private var previewCache = BoundedCache<String, (version: String, data: Data)>(budget: 24 << 20, cost: { $0.data.count })
    private var launchReported = false
    private var sessionProjects: [String:String] = [:]
    /// Messages on their way, by the conversation that owns each.
    private var sends: [ConversationID: SendOperation] = [:] { didSet { changed() } }
    /// The thread each sent draft became.
    private var successors: [ConversationID: ConversationID] = [:]
    private var stepDetails: Task<Void,Never>?
    /// Activities the details fetch was last asked for (the fetch itself
    /// retries until it succeeds; `detailsSince` moves only on success).
    private var stepDetailsCount = -1
    /// Threads seen this session, so returning to one shows it at once.
    private var threadCache = BoundedCache<String, Transcript>(budget: 12)
    private var cacheWrite: Task<Void, Never>?
    private let disk = DiskCache()
    private var diskGeneration: UInt64 = 0
    /// Rebuilds the transcript off the main actor; `conversationDirty` asks
    /// for another pass once the one under way is done.
    private var conversationBuild: Task<Void, Never>?
    private var conversationDirty = false
    private var networkWatcher: Task<Void, Never>?
    private var memoryWatcher: Task<Void, Never>?
    private var threadResubscribe: Task<Void, Never>?
    private var debugDrops: Task<Void, Never>?
    private var installWatch: Task<Void, Never>?
    /// How many subscriptions T3 ended soon after a connection came up: the
    /// next attempt waits longer each time.
    private var unstableCount = 0
    private static let subscriptionLost = "T3 stopped sending updates; reconnecting."
    private var media: [JSONValue] { state.media }
    private let commandDispatch: ((JSONValue) async throws -> JSONValue)?
    private let upload: ((URL, String) async throws -> String)?
    private let preferences: UserDefaults
    /// Inside another app's debug overlay, only that app is shown.
    let scopeBundleID: String?
    /// What screens currently need refreshed.
    private var leases: [UUID: RefreshNeed] = [:]
    private static let preferredModelKey = "squircle.t3.preferredModel"
    static let agentInstance = "squircle"

    /// Once a thread has an agent session, T3 cannot migrate it to another provider.
    var availableModelProviders: [JSONValue] {
        guard let open else { return [] }
        guard let thread = open.threadID else {
            // An app agent runs on Squircle's own Claude instance; other
            // threads never do.
            let agentProviders = providers.filter { $0["instanceId"].string == Self.agentInstance }
            if open.isAgentDraft { return agentProviders.isEmpty ? providers : agentProviders }
            return providers.filter { $0["instanceId"].string != Self.agentInstance }
        }
        let instance = state.thread["session"]["providerInstanceId"].string
            ?? state.thread["modelSelection"]["instanceId"].string
            ?? sessions.first(where: { $0.id == thread })?.modelSelection["instanceId"].string
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
    /// Each available provider's default model.
    private var providerDefaults: [JSONValue] {
        availableModelProviders.compactMap { provider in
            guard let option = provider["models"].array.first(where: { $0["isDefault"].bool }) ?? provider["models"].array.first else { return nil }
            return JSONValue.from(["instanceId":provider["instanceId"].string!,"model":option["slug"].string!])
        }
    }
    var quickModelSelections: [JSONValue] {
        var choices: [JSONValue] = []
        let current = modelSelection
        if isValidModel(current) { choices.append(current) }
        for selection in providerDefaults where !choices.contains(where: { sameModel($0, selection) }) { choices.append(selection) }
        return Array(choices.prefix(4))
    }
    private func sameModel(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        lhs["instanceId"] == rhs["instanceId"] && lhs["model"] == rhs["model"]
    }
    private func isValidModel(_ selection: JSONValue) -> Bool {
        availableModelSelections.contains { sameModel($0, selection) }
    }
    /// The open conversation's model: your choice T3 hasn't confirmed yet,
    /// else the thread's, else (a draft) the one you used last.
    var modelSelection: JSONValue {
        guard let open else { return .null }
        if let chosen = choices[open]?.model { return chosen }
        if let thread = open.threadID {
            let saved = state.thread["modelSelection"]
            return saved != .null ? saved : sessions.first(where: { $0.id == thread })?.modelSelection ?? .null
        }
        if let preferredModel, isValidModel(preferredModel) { return preferredModel }
        // An agent draft keeps your preferred model on Squircle's instance.
        if open.isAgentDraft, let model = preferredModel?["model"].string {
            let agentChoice = JSONValue.from(["instanceId": Self.agentInstance, "model": model])
            if isValidModel(agentChoice) { return agentChoice }
        }
        return providerDefaults.first ?? availableModelSelections.first ?? .null
    }
    /// The open conversation's approval mode, the same way.
    var runtimeMode: T3RuntimeMode {
        guard let open else { return .auto }
        if let chosen = choices[open]?.mode { return chosen }
        guard open.threadID != nil else { return .auto }
        return state.thread["runtimeMode"].string.flatMap(T3RuntimeMode.init(rawValue:)) ?? .auto
    }
    func consumeConfig(_ config: JSONValue) {
        let providers = config["providers"].array.filter {
            $0["enabled"].bool && $0["status"].string == "ready" && !($0["instanceId"].string ?? "").isEmpty
        }.map { provider in
            var value = provider.object
            value["models"] = .array(provider["models"].array.filter { !($0["slug"].string ?? "").isEmpty })
            return JSONValue.object(value)
        }.filter { !$0["models"].array.isEmpty }
        catalog = .ready(providers, fetchedAt: .now)
    }

    init(configuration: AppConfiguration? = try? AppConfiguration.load(), preferences: UserDefaults = .standard,
         commandDispatch: ((JSONValue) async throws -> JSONValue)? = nil,
         upload: ((URL, String) async throws -> String)? = nil, scopeBundleID: String? = nil) {
        self.preferences = preferences
        self.scopeBundleID = scopeBundleID
        self.commandDispatch = commandDispatch
        self.upload = upload
        self.configuration = configuration
        client = configuration.map { SquircleClient(configuration:$0) }
        gateway = configuration.map(T3Gateway.init(configuration:))
        connection = configuration == nil ? .stopped : .connecting(.init(id: 0, failingSince: nil))
        preferredModel = preferences.data(forKey: Self.preferredModelKey).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
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
            Task { await StepVideos.list() }
        }
        gateway?.onDisconnect = { [weak self] in
            guard let self else { return }
            if case .ready = connection { connection = .connecting(.init(id: attempts, failingSince: nil)) }
            threadSubscription = nil
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
        closed = true; connection = .stopped
        for task in [connector, nap, configLoader, monitor, networkWatcher, memoryWatcher, stepDetails, cacheWrite, homeWrite,
                     simulatorRefresh, conversationBuild, threadResubscribe, debugDrops, installWatch] { task?.cancel() }
        connector = nil; nap = nil; configLoader = nil; monitor = nil; networkWatcher = nil; memoryWatcher = nil
        stepDetails = nil; cacheWrite = nil; homeWrite = nil; simulatorRefresh = nil; conversationBuild = nil
        threadResubscribe = nil; debugDrops = nil; installWatch = nil
        for case .uploading(_, let upload) in captureTransfers.values { upload.cancel() }
        captureTransfers.removeAll()
        gateway?.close(); client?.invalidate()
        endBackgroundTask()
        let finished = observers.values; observers.removeAll()
        for observer in finished { observer.finish() }
    }
    func refresh() async {
        guard gateway != nil, client != nil else { error = ClientError.configuration.localizedDescription; return }
        // The service doesn't depend on T3: both load at once.
        switch connection {
        case .connecting, .refused: connection = .connecting(.init(id: attempts, failingSince: nil)); keepConnected(); nap?.cancel()
        case .ready, .suspended, .stopped: break
        }
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
    /// The attempt subscriptions belong to now: the one under way or the
    /// one that connected.
    private var currentAttempt: Int? {
        switch connection {
        case .connecting(let attempt): attempt.id
        case .ready(let session): session.attempt
        default: nil
        }
    }
    /// Retry at once, as if nothing had failed yet.
    private func forgetFailures() {
        if case .connecting(let attempt) = connection { connection = .connecting(.init(id: attempt.id, failingSince: nil)) }
    }
    /// Keeps T3's socket up while Squircle is in use: the first attempt is
    /// immediate, then 0.5 s doubling to 15 s. One connector at a time;
    /// `nap?.cancel()` makes it try again now.
    private func keepConnected() {
        guard gateway != nil, connector == nil, case .connecting = connection else { return }
        // T3 ended a subscription soon after the last connection came up:
        // wait before trying again, longer each time.
        let first: Duration = unstableCount == 0 ? .zero : min(.milliseconds(500) * (1 << min(unstableCount, 6)), .seconds(30))
        connector = Task { [weak self] in
            var delay = first
            while let self, case .connecting = connection {
                if delay > .zero, !retryNow {
                    let nap = Task { [delay] in _ = try? await Task.sleep(for: delay) }
                    self.nap = nap; await nap.value; self.nap = nil
                }
                retryNow = false
                guard case .connecting(let previous) = connection else { break }
                attempts += 1
                let attempt = attempts
                connection = .connecting(.init(id: attempt, failingSince: previous.failingSince))
                do { try await openConnection(attempt) }
                catch where Self.isRejected(error) {
                    // Retrying can't fix a refused credential; say what to do.
                    log("T3 refused this build's session: \(error.localizedDescription)")
                    self.error = "T3 no longer accepts this build’s session. Pair Squircle with T3 again on your Mac and install a new build."
                    connection = .refused
                    break
                } catch {
                    log("T3 connect failed: \(error.localizedDescription)")
                    guard case .connecting(let now) = connection, now.id == attempt else { continue }
                    let since = now.failingSince ?? .now
                    connection = .connecting(.init(id: attempt, failingSince: since))
                    // Truly unreachable: say so.
                    if since.duration(to: .now) >= Self.reconnectGrace { self.error = error.localizedDescription }
                    delay = delay == .zero ? .milliseconds(500) : min(delay * 2, .seconds(15))
                }
            }
            guard let self else { return }
            connector = nil
            if connected { await ensureScopedProject() }
        }
    }
    /// Reconnect, tapped: a fresh attempt now, without the backoff or an
    /// attempt stuck waiting on a slow socket. Models load again if they failed.
    func reconnect() async {
        loadProvidersIfDue(force: { if case .failed = catalog { return true }; return false }())
        guard !connected else { await refreshServices(); return }
        error = nil
        switch connection {
        case .refused: connection = .connecting(.init(id: attempts, failingSince: nil))
        case .connecting: forgetFailures()
        case .ready, .suspended, .stopped: return
        }
        if connector != nil { retryNow = true; gateway?.disconnect(notify: false) }
        keepConnected(); nap?.cancel()
    }
    nonisolated static func isRejected(_ error: Error) -> Bool {
        if case ClientError.http(_, let status) = error { return status == 401 || status == 403 }
        return false
    }
    /// One connection attempt: socket, live subscriptions, and the open
    /// thread resubscribed. Its transcript stays on screen meanwhile; T3's
    /// snapshot then brings it up to date. A subscription T3 ends before
    /// this finishes fails the attempt.
    private func openConnection(_ attempt: Int) async throws {
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
                                        ended: { [weak self] in self?.connectionSubscriptionEnded("shell", $0, attempt: attempt) })
            // Its first value is the whole device state.
            try await gateway.subscribe("subscribeDeviceState", receive: { [weak self] in self?.consumeDevices($0) },
                                        ended: { [weak self] in self?.connectionSubscriptionEnded("devices", $0, attempt: attempt) })
            threadSubscription = nil
            if let id = selectedSessionID { try await subscribeThread(id, attempt: attempt) }
            ConnectionTrace.mark("connect.subscribed")
            // The socket may have failed, or T3 ended a subscription, while
            // subscribing; then try again.
            guard gateway.isOpen, case .connecting(let current) = connection, current.id == attempt else { throw ClientError.connection("T3") }
        } catch { gateway.disconnect(notify: false); throw gateway.rejection ?? error }
        connection = .ready(.init(attempt: attempt, since: .now))
        // An unstable connection keeps saying so until it holds.
        if unstableCount == 0 || error != Self.subscriptionLost { error = nil }
        log("T3 connected"); ConnectionTrace.mark("connected")
        loadProvidersIfDue()
        // A thread opened while this attempt was under way.
        if let id = selectedSessionID, threadSubscription == nil { await subscribeOpenThread(id) }
    }
    /// T3 ended the shell or device subscription while the socket stayed
    /// up: the phone would show Connected and never update. During setup
    /// that attempt fails; once connected, start again.
    private func connectionSubscriptionEnded(_ name: String, _ failure: Error?, attempt: Int) {
        guard let gateway, currentAttempt == attempt else { return }
        log("T3 ended the \(name) subscription: \(failure?.localizedDescription ?? "completed")")
        let quick: Bool
        if case .ready(let session) = connection { quick = session.since.duration(to: .now) < .seconds(60) } else { quick = true }
        unstableCount = quick ? unstableCount + 1 : 1
        error = Self.subscriptionLost
        if case .ready = connection { gateway.disconnect(notify: true) } else { gateway.disconnect(notify: false) }
    }
    /// The connection held for a minute: forget earlier instability.
    private func noteStability() {
        guard unstableCount > 0, case .ready(let session) = connection, session.since.duration(to: .now) >= .seconds(60) else { return }
        unstableCount = 0
        if error == Self.subscriptionLost { error = nil }
    }
    /// Loads T3's providers through the service when they're missing,
    /// failed and due a retry, or ten minutes old. The metadata loop calls
    /// this every pass, so a failure recovers without a new connection.
    private func loadProvidersIfDue(force: Bool = false) {
        guard let client, configLoader == nil else { return }
        switch catalog {
        case .loading: return
        case .ready(_, let fetchedAt) where !force && fetchedAt.duration(to: .now) < .seconds(600): return
        case .failed(_, _, let retryAt) where !force && ContinuousClock.now < retryAt: return
        default: break
        }
        let previous = catalog.value
        catalog = .loading(previous: previous)
        configLoader = Task { [weak self] in
            do {
                let config = try await client.providers()
                self?.consumeConfig(config)
            } catch {
                self?.catalog = .failed(previous: previous, failure: error.localizedDescription, retryAt: .now + .seconds(5))
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
        if connection != .stopped { connection = .suspended }
        nap?.cancel()
        // Close cleanly rather than leave a socket that dies while suspended.
        gateway?.disconnect(notify: false); threadSubscription = nil
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
        endBackgroundTask()
        guard let gateway else { return }
        switch connection {
        case .ready:
            // A dead socket reports itself through `onDisconnect`.
            Task { _ = await gateway.probe() }
        case .suspended:
            connection = .connecting(.init(id: attempts, failingSince: nil)); keepConnected(); nap?.cancel()
        case .connecting:
            forgetFailures(); keepConnected(); nap?.cancel()
        case .refused, .stopped: break
        }
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
                guard let before = previous, path.status == .satisfied else { continue }
                switch connection {
                case .ready:
                    if before.status != .satisfied || before.availableInterfaces.map(\.name) != path.availableInterfaces.map(\.name) {
                        _ = await gateway?.probe()
                    }
                case .connecting: forgetFailures(); keepConnected(); nap?.cancel()
                case .suspended, .refused, .stopped: break
                }
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
                               phase:phase,modelSelection:t["modelSelection"],latestTurn:TurnObservation(t["latestTurn"]))
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

    // MARK: Opening conversations

    /// Puts `id` on screen at once: a thread from what was last seen of it
    /// this session (a copy on disk follows a moment later, read off the
    /// main actor), a draft empty. `open(_:)` then subscribes.
    func show(_ id: ConversationID) {
        if let thread = id.threadID {
            guard open != id || (state.sequence < 0 && diskLoad?.id != thread) else { return }
        } else {
            guard open != id else { return }
        }
        saveCurrentThread()
        threadResubscribe?.cancel(); threadResubscribe = nil
        conversationBuild?.cancel(); conversationBuild = nil; conversationDirty = false
        stepDetails?.cancel(); stepDetailsCount = -1
        // A message T3 took needs no echo once nobody looks at it.
        sends = sends.filter { $0.value.phase != .accepted || $0.key == id }
        open = id; error = nil
        if let thread = id.threadID { sessionProjects[thread] = sessionProjects[thread] ?? id.appID }
        ConnectionTrace.mark("thread.open", id.threadID ?? "draft"); tracedRows = false
        guard let thread = id.threadID else {
            state = T3ThreadState(); transcript = .empty; deriveFromState()
            return
        }
        if let cached = threadCache.value(for: thread) {
            ConnectionTrace.mark("thread.cached", "seq=\(cached.state.sequence) memory=true")
            state = cached.state.restored; transcript = cached; deriveFromState()
        } else {
            state = T3ThreadState(); transcript = .empty; deriveFromState()
            guard configuration != nil else { return }
            diskLoad = (thread, Task { [weak self, disk] in
                guard let loaded = await disk.loadThread(thread), let self,
                      selectedSessionID == thread, state.sequence < 0 else { return }
                ConnectionTrace.mark("thread.cached", "seq=\(loaded.sequence) memory=false")
                state = loaded.restored; deriveFromState(); rebuildConversation()
            })
        }
    }
    /// Shows `id` and follows it live: its thread's subscription replaces
    /// the previous one.
    func open(_ id: ConversationID) async {
        show(id)
        guard let gateway else { return }
        let previousSubscription = threadSubscription; threadSubscription = nil
        await gateway.unsubscribe(previousSubscription)
        guard open == id, let thread = id.threadID else { return }
        await subscribeOpenThread(thread)
    }
    /// The thread a sent draft became, for the rest of the session.
    func successor(of id: ConversationID) -> ConversationID? { successors[id] }
    private func subscribeOpenThread(_ id: String) async {
        // While reconnecting, the new connection subscribes the open thread.
        guard selectedSessionID == id, case .ready(let session) = connection else { return }
        do { try await subscribeThread(id, attempt: session.attempt); error = nil }
        catch where Self.isTransient(error) {}
        catch { self.error = error.localizedDescription }
    }
    private func subscribeThread(_ id: String, fresh: Bool = false, attempt: Int) async throws {
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
        }, ended: { [weak self] failure in self?.threadSubscriptionEnded(id, failure, attempt: attempt) })
        guard selectedSessionID == id else { await gateway.unsubscribe(subscription); return }
        threadSubscription = subscription
    }
    private func resubscribeFresh(_ id: String) {
        threadResubscribe?.cancel()
        threadResubscribe = Task { [weak self] in
            guard let self, selectedSessionID == id, case .ready(let session) = connection else { return }
            let previous = threadSubscription; threadSubscription = nil
            await gateway?.unsubscribe(previous)
            try? await subscribeThread(id, fresh: true, attempt: session.attempt)
        }
    }
    /// T3 ended the open thread's subscription with the socket still up.
    /// During setup that attempt fails. Once connected, subscribe again,
    /// waiting longer each time; after a few tries say so.
    private func threadSubscriptionEnded(_ id: String, _ failure: Error?, attempt: Int) {
        guard currentAttempt == attempt, selectedSessionID == id else { return }
        guard case .ready = connection else {
            log("T3 ended thread \(id)'s subscription during setup")
            gateway?.disconnect(notify: false)
            return
        }
        threadSubscription = nil
        log("T3 ended thread \(id)'s subscription: \(failure?.localizedDescription ?? "completed")")
        threadResubscribe?.cancel()
        threadResubscribe = Task { [weak self] in
            var delay: Duration = .seconds(1)
            for retry in 1...5 {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, selectedSessionID == id, currentAttempt == attempt, connected,
                      threadSubscription == nil else { return }
                guard sessions.contains(where: { $0.id == id }) || shell == .null else {
                    error = "This thread is no longer on your Mac."; return
                }
                do { try await subscribeThread(id, attempt: attempt); return }
                catch { if retry >= 3 { self.error = "This thread stopped updating: " + error.localizedDescription } }
                delay = min(delay * 2, .seconds(30))
            }
        }
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
        guard let open, !isRunning, sends[open] == nil, isValidModel(selection) else { return }
        choices[open, default: LocalChoice()].model = selection
        if selection["instanceId"].string != Self.agentInstance, let data = try? JSONEncoder().encode(selection) {
            preferences.set(data, forKey: Self.preferredModelKey); preferredModel = selection
        }
    }
    func chooseRuntimeMode(_ mode: T3RuntimeMode) {
        guard let open else { return }
        choices[open, default: LocalChoice()].mode = mode
    }
    func setRuntimeMode(_ mode: T3RuntimeMode) async {
        guard let open else { return }
        let previous = choices[open]?.mode
        chooseRuntimeMode(mode)
        guard let id = open.threadID else { return }
        do {
            try await dispatch(["type":"thread.runtime-mode.set","threadId":id,"runtimeMode":mode.rawValue])
        } catch {
            if choices[open]?.mode == mode { choices[open]?.mode = previous }
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
    /// Keeps the open thread for a quick return: in memory its rows with the
    /// exact state they came from, on disk the newest state.
    private func saveCurrentThread() {
        guard let id = selectedSessionID, state.sequence >= 0 else { return }
        if transcript.state.sequence >= 0 { threadCache.set(transcript, for: id) }
        cacheWrite?.cancel(); cacheWrite = nil
        writeToDisk(id, state)
    }
    /// Keeps the on-disk copy current without writing on every event.
    private func scheduleCacheWrite() {
        guard let id = selectedSessionID, cacheWrite == nil else { return }
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
        Task { [disk, diskGeneration, state = state.restored] in await disk.saveThread(id, state, generation: diskGeneration) }
    }

    // MARK: Thread

    /// A thread's rows and the state they were made from, as one value: the
    /// only way to pair them is to render that state.
    private struct Transcript {
        let state: T3ThreadState
        let rows: [ChatMessage]
        private init(state: T3ThreadState, rows: [ChatMessage]) { self.state = state; self.rows = rows }
        static let empty = Transcript(state: T3ThreadState(), rows: [])
        nonisolated static func render(_ state: T3ThreadState) async -> Transcript {
            Transcript(state: state, rows: await SquircleModel.conversation(state))
        }
    }
    /// Renders the open thread off the main actor, one pass at a time;
    /// changes during a pass ask for one more. A render made for a thread no
    /// longer open is dropped.
    private func rebuildConversation() {
        conversationDirty = true
        guard conversationBuild == nil else { return }
        conversationBuild = Task { [weak self] in
            while let model = self, model.conversationDirty, !Task.isCancelled {
                model.conversationDirty = false
                let id = model.selectedSessionID, snapshot = model.state
                let rendered = await Transcript.render(snapshot)
                guard !Task.isCancelled else { return }
                if model.selectedSessionID == id {
                    model.transcript = rendered
                    if ConnectionTrace.enabled { model.traceRows(rendered.rows.count) }
                    if let id, rendered.state.sequence >= 0 { model.threadCache.set(rendered, for: id) }
                }
            }
            self?.conversationBuild = nil
        }
    }
    /// Requests and changes follow the open thread's state.
    private func deriveFromState() {
        observedRequests = state.pendingRequests
        if !responding.isEmpty {
            let open = Set(observedRequests.compactMap { $0["payload"]["requestId"].string })
            let still = responding.filter { open.contains($0.key) }
            if still.count != responding.count { responding = still }
        }
        let turnChanges = state.changes
        if turnChanges != changes { changes = turnChanges }
    }

    private var tracedRows = false
    private var tracedEventAt: String?
    private func traceRows(_ count: Int) {
        if !tracedRows, state.isLive {
            tracedRows = true; ConnectionTrace.mark("thread.rows", "rows=\(count) seq=\(state.sequence)")
        }
        if let at = tracedEventAt {
            tracedEventAt = nil
            ConnectionTrace.mark("event.onScreen", String(format: "%.0fms", Date().timeIntervalSince(JSONValue.string(at).date) * 1000))
        }
    }
    func consumeThread(_ item: JSONValue) {
        if item["kind"].string == "synchronized" {
            ConnectionTrace.mark("thread.synchronized"); tracedRows = true
            return
        }
        if ConnectionTrace.enabled {
            switch item["kind"].string {
            case "snapshot": ConnectionTrace.mark("thread.snapshot", "seq=\(item["snapshot"]["snapshotSequence"].int ?? -1)")
            default: if tracedRows, let at = item["event"]["occurredAt"].string { tracedEventAt = at }
            }
        }
        let held = state.sequence
        state.consume(item); rebuildConversation(); deriveFromState()
        // A revert rewrote history the phone can't replay: start from a snapshot.
        if held >= 0, state.sequence < 0, let id = selectedSessionID { resubscribeFresh(id) }
        scheduleCacheWrite()
        if state.activityCount != stepDetailsCount { stepDetailsCount = state.activityCount; scheduleStepDetails() }
        guard let open else { return }
        // T3 has the message: nothing is pending for it any more.
        if let send = sends[open], state.hasMessage(send.messageID) { sends[open] = nil }
        // Choices T3 now reports are T3's again.
        if var choice = choices[open] {
            if let model = choice.model, state.thread["modelSelection"] == model { choice.model = nil }
            if let mode = choice.mode, state.thread["runtimeMode"].string == mode.rawValue { choice.mode = nil }
            choices[open] = choice.model == nil && choice.mode == nil ? nil : choice
        }
        if let last = state.thread["session"]["lastError"].string { error = last }
    }
    /// The open thread is working, or a message T3 just took is about to.
    var isRunning: Bool {
        state.isRunning || open.flatMap { sends[$0] }?.phase == .accepted
    }
    private func dispatch(_ command: [String:Any], commandID: String = UUID().uuidString.lowercased()) async throws {
        var c = command; c["commandId"] = commandID
        c["createdAt"] = ISO8601DateFormatter().string(from:.now)
        let result: JSONValue
        if let commandDispatch { result = try await commandDispatch(.from(c)) }
        else if let gateway { result = try await gateway.call("orchestration.dispatchCommand",.from(c)) }
        else { throw ClientError.configuration }
        if result["status"].string == "rejected" { throw ClientError.backend("T3",0,result.formatted) }
    }
    /// Dispatches `command` until T3 answers or `settled` says T3 already
    /// shows its result. An answer lost with the socket (or a request that
    /// never got out) is asked again on T3's next connection under the same
    /// command ID: T3 answers a command it already took from its receipt
    /// and never runs it twice. Throws only when T3 refuses it, or when T3
    /// can't be reached again (this build's session refused).
    private func deliver(_ command: [String:Any], commandID: String, settled: () -> Bool) async throws {
        var lost: Int?
        while !settled() {
            guard let session = await connection(after: lost) else { throw ClientError.connection("T3") }
            if settled() { return }
            do { return try await dispatch(command, commandID: commandID) }
            catch where Self.isRefusal(error) { throw error }
            catch { lost = session; log("T3's answer to \(command["type"] ?? "") was lost (\(error.localizedDescription)); asking again on the next connection") }
        }
    }
    /// The attempt of T3's ready connection, once there is one other than
    /// `lost`'s; nil if T3 can't be reached again. Without a socket (an
    /// injected dispatch) there is nothing to wait for.
    private func connection(after lost: Int?) async -> Int? {
        guard gateway != nil else { return 0 }
        while true {
            switch connection {
            case .ready(let session) where session.attempt != lost: return session.attempt
            case .refused, .stopped: return nil
            default: await withCheckedContinuation { connectionWaiters.append($0) }
            }
        }
    }
    /// T3 answered and refused: it didn't take the command. Anything else
    /// (a dropped socket) means asking again.
    nonisolated static func isRefusal(_ error: Error) -> Bool {
        switch error {
        case ClientError.backend("T3", 0, _), ClientError.configuration: true
        default: false
        }
    }

    // MARK: Message field

    /// Adds a picture to the open conversation's field; one with the same
    /// `id` is replaced.
    func attach(_ attachment: ImageAttachment) {
        guard let open else { return }
        var field = drafts[open] ?? []
        if let index = field.firstIndex(where: { $0.id == attachment.id }) { field[index] = attachment }
        else { field.append(attachment) }
        drafts[open] = field
        // A recording starts its way to the Mac at once; sending waits for it.
        if attachment.capture != nil { startUpload(attachment) }
    }
    func removeAttachment(_ id: String) {
        guard let open else { return }
        drafts[open]?.removeAll { $0.id == id }
        if case .uploading(_, let upload)? = captureTransfers.removeValue(forKey: id) { upload.cancel() }
    }
    /// A recording in a field on its way to the Mac: under way, there (its
    /// path on the Mac), or failed (sending starts it again). One without an
    /// entry is still only on the phone.
    private enum CaptureTransfer {
        case uploading(generation: Int, Task<String, Error>)
        case uploaded(path: String)
        case failed(String)
    }
    private var captureTransfers: [String: CaptureTransfer] = [:]
    private var uploadGeneration = 0
    private var uploader: ((URL, String) async throws -> String)? {
        if let upload { return upload }
        guard let client else { return nil }
        return { try await client.uploadCapture($0, kind: $1) }
    }
    @discardableResult
    private func startUpload(_ attachment: ImageAttachment) -> Task<String, Error>? {
        guard let capture = attachment.capture, let uploader else { return nil }
        if case .uploading(_, let old)? = captureTransfers[attachment.id] { old.cancel() }
        uploadGeneration += 1
        let generation = uploadGeneration, id = attachment.id
        let task = Task { try await uploader(capture.file, capture.kind.rawValue) }
        captureTransfers[id] = .uploading(generation: generation, task)
        Task { [weak self] in
            let result = await task.result
            // Only this upload's own entry: a newer one replaced it otherwise.
            guard let self, case .uploading(let current, _)? = captureTransfers[id], current == generation else { return }
            switch result {
            case .success(let path): captureTransfers[id] = .uploaded(path: path)
            case .failure(let error): captureTransfers[id] = .failed(error.localizedDescription)
            }
        }
        return task
    }
    /// The message block for `captures`, once each is on the Mac. A failed
    /// upload is tried again; one that made it is not.
    private func captureBlock(_ captures: [ImageAttachment]) async throws -> String {
        var sent: [(label: String, path: String, video: Bool)] = []
        for attachment in captures {
            guard let capture = attachment.capture else { continue }
            let path: String
            switch captureTransfers[attachment.id] {
            case .uploaded(let done)?: path = done
            case .uploading(let generation, let upload)?:
                do { path = try await upload.value } catch {
                    if case .uploading(generation, _)? = captureTransfers[attachment.id] {
                        captureTransfers[attachment.id] = .failed(error.localizedDescription)
                    }
                    throw error
                }
            case .failed?, nil:
                guard let upload = startUpload(attachment) else { throw ClientError.configuration }
                path = try await upload.value
            }
            let video = capture.kind == .video
            // Your own recording plays from the phone's copy.
            if video { StepVideos.set(capture.file, for: "file:" + path) }
            sent.append((capture.sentLabel, path, video))
        }
        return SentCapture.block(sent)
    }
    /// Pictures back into a field, ahead of any added since.
    private func restoreField(_ field: [ImageAttachment], to owner: ConversationID) {
        guard !field.isEmpty else { return }
        let now = drafts[owner] ?? []
        drafts[owner] = field + now.filter { a in !field.contains { $0.id == a.id } }
    }

    // MARK: Sending

    /// One message on its way: everything fixed when it started (where, with
    /// which model, mode and pictures, what the thread already had), its
    /// stable IDs, and how far it got. A later navigation changes none of it.
    private struct SendOperation {
        let messageID: String
        let commandID: String
        let spoken: String
        let field: [ImageAttachment]
        let project: AppProject
        let selection: JSONValue
        let mode: T3RuntimeMode
        /// The thread is the app's agent (its instructions come from the Mac).
        let agentThread: Bool
        let firstMessage: Bool
        let hasInstructions: Bool
        /// The thread a plain draft makes, named before T3 is asked.
        let newThread: String
        let createCommandID: String
        /// The message with its recordings, once they're on the Mac.
        var text: String?
        var phase: PendingSend.Phase
        var pending: PendingSend {
            PendingSend(messageID: messageID, text: spoken, images: field.filter { $0.capture == nil }.count,
                        captures: field.compactMap { $0.capture.map { SentCapture(label: $0.sentLabel, path: $0.file.path) } },
                        phase: phase)
        }
    }
    func pendingSend(for id: ConversationID) -> PendingSend? { sends[id]?.pending }

    /// Starts sending `text` with the open field's pictures from `id`, which
    /// must be open. The pending message exists, and the field is empty,
    /// when this returns. Pictures go back into the field if T3 refuses.
    func startSend(_ spoken: String, in project: AppProject, from id: ConversationID) -> SendStart {
        guard open == id else { return .refused("This conversation is no longer open.") }
        guard sends[id] == nil else { return .refused("Still sending the last message.") }
        let field = drafts[id] ?? []
        guard !spoken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !field.isEmpty else { return .refused("Nothing to send.") }
        let selection = modelSelection
        guard isValidModel(selection) else {
            let reason: String
            switch catalog {
            case .absent, .loading: reason = "Models are still loading."
            case .failed(_, let failure, _): reason = "Couldn’t load the models: " + failure
            case .ready: reason = "Choose an available model."
            }
            loadProvidersIfDue(force: true)
            error = reason
            return .refused(reason)
        }
        let messages = id.threadID == nil ? [] : state.thread["messages"].array
        let operation = SendOperation(
            messageID: UUID().uuidString.lowercased(), commandID: UUID().uuidString.lowercased(),
            spoken: spoken, field: field, project: project, selection: selection, mode: runtimeMode,
            agentThread: id.isAgentDraft || id.threadID.map { agents[project.id] == $0 } == true
                || (id.threadID != nil && state.thread["modelSelection"]["instanceId"].string == Self.agentInstance),
            firstMessage: messages.isEmpty,
            hasInstructions: messages.contains { ($0["text"].string ?? "").contains("sim start --thread") },
            newThread: UUID().uuidString.lowercased(), createCommandID: UUID().uuidString.lowercased(),
            text: nil, phase: .preparing)
        drafts[id] = nil; error = nil
        // Your recording plays in the pending message from the phone's copy.
        for case let capture? in field.map(\.capture) where capture.kind == .video {
            StepVideos.set(capture.file, for: "file:" + capture.file.path)
        }
        sends[id] = operation
        return .started(messageID: operation.messageID, outcome: Task { await deliver(from: id) })
    }
    func send(_ spoken: String, in project: AppProject, from id: ConversationID) async -> SendOutcome? {
        guard case .started(_, let outcome) = startSend(spoken, in: project, from: id) else { return nil }
        return await outcome.value
    }
    /// Takes the send under `origin` as far as it goes: recordings, the
    /// draft's thread, the turn. It ends only when T3 answers, refuses, or
    /// shows the message; a connection lost on the way just means asking
    /// again, with the same IDs, on the next one.
    private func deliver(from origin: ConversationID) async -> SendOutcome {
        guard var operation = sends[origin] else {
            return .rejected(messageID: "", reason: "Nothing to send.", conversation: origin)
        }
        var owner = origin
        let messageID = operation.messageID
        func record(_ phase: PendingSend.Phase) {
            guard sends[owner] != nil else { return }
            operation.phase = phase; sends[owner] = operation
        }
        func reject(_ reason: String) -> SendOutcome {
            sends[owner] = nil
            restoreField(operation.field, to: owner)
            if open == owner || open == origin { error = reason }
            return .rejected(messageID: messageID, reason: reason, conversation: owner)
        }
        let images = operation.field.filter { $0.capture == nil }, captures = operation.field.filter { $0.capture != nil }
        let text: String
        if let ready = operation.text { text = ready } else {
            do { text = try await operation.spoken + captureBlock(captures) }
            catch { return reject("Couldn't send the recording to your Mac: " + error.localizedDescription) }
            operation.text = text; record(.preparing)
        }
        let project = operation.project
        let threadID: String
        switch owner {
        case .thread(let id, _): threadID = id
        case .draft(_, _, agent: true):
            // The Mac creates the agent (its worktree and thread) in the
            // chosen mode, or finds the one it made; the message goes to T3
            // from here, under this send's own ID.
            record(.creating)
            guard let client else { return reject(ClientError.configuration.localizedDescription) }
            do {
                let model = operation.selection["instanceId"].string == Self.agentInstance ? operation.selection["model"].string : nil
                threadID = try await client.startAgent(projectID: project.id, message: "", model: model, mode: operation.mode)
            } catch { return reject(error.localizedDescription) }
            agents[project.id] = threadID
            owner = adopt(draft: origin, becomes: threadID)
        case .draft:
            record(.creating)
            threadID = operation.newThread
            do {
                try await deliver(["type":"thread.create","threadId":threadID,"projectId":project.id,"title":"New thread",
                    "modelSelection":operation.selection.foundation,"runtimeMode":operation.mode.rawValue,"interactionMode":"default",
                    "branch":NSNull(),"worktreePath":NSNull()], commandID: operation.createCommandID,
                    settled: { shell["threads"].array.contains { $0["id"].string == threadID } })
            } catch { return reject(error.localizedDescription) }
            owner = adopt(draft: origin, becomes: threadID)
        }
        record(.awaitingAcceptance)
        var message = text
        let instructions = squircleInstructions(for: project, threadID: threadID)
        if !operation.agentThread, operation.firstMessage {
            message += "\n\n" + project.agentContext + "\nFor signed builds/install links use \(cliCommand). Run help workflow for the documented commands. This app is a native client of T3; T3 manages this thread.\n" + instructions
        } else if !operation.agentThread, !operation.hasInstructions {
            // Threads started before these instructions existed get them once.
            message += AppProject.contextMarker + project.name + ".\n" + instructions
        }
        // T3 stores each picture under its attachments folder and hands
        // the provider its path.
        let uploads: [[String:Any]] = images.enumerated().map { index, image in
            ["type":"image","name":"image-\(index + 1).jpg","mimeType":"image/jpeg","sizeBytes":image.data.count,
             "dataUrl":"data:image/jpeg;base64," + image.data.base64EncodedString()]
        }
        let seed = operation.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // The open thread showing it settles it as surely as T3's answer.
            try await deliver(["type":"thread.turn.start","threadId":threadID,
                "message":["messageId":messageID,"role":"user","text":message,"attachments":uploads],
                "modelSelection":operation.selection.foundation,"runtimeMode":operation.mode.rawValue,
                "interactionMode":"default","titleSeed":String((seed.isEmpty ? (captures.isEmpty ? "Image" : "Recording") : seed).prefix(120))],
                commandID: operation.commandID,
                settled: { sends[owner] == nil || (open == owner && state.hasMessage(messageID)) })
        } catch { return reject(error.localizedDescription) }
        for attachment in captures { captureTransfers[attachment.id] = nil }
        // Pending until the thread shows it, while anyone may look; a
        // thread T3 already shows it in needs nothing more.
        let watched = open == owner || open == origin
        if watched, !(open == owner && state.hasMessage(messageID)) { record(.accepted) } else { sends[owner] = nil }
        return .accepted(messageID: messageID, conversation: owner)
    }
    /// T3 made `thread` for the draft `draft`: the send, its pictures and
    /// choices belong to the thread from now on.
    private func adopt(draft: ConversationID, becomes thread: String) -> ConversationID {
        let id = ConversationID.thread(thread, appID: draft.appID)
        sessionProjects[thread] = draft.appID
        successors[draft] = id
        if let operation = sends.removeValue(forKey: draft) { sends[id] = operation }
        if let field = drafts.removeValue(forKey: draft) { drafts[id] = field }
        if let choice = choices.removeValue(forKey: draft) { choices[id] = choice }
        return id
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
    /// A turn's recording plays inline once downloaded. On a metered
    /// network it shows its poster and downloads when tapped (a long session
    /// is well over 100 MB); an older recording without a poster still
    /// downloads by itself if it's small.
    func autoLoadsRecording(_ id: String) -> Bool {
        guard metered else { return true }
        guard posterless.contains(id) else { return false }
        return (media.first { $0["id"].string == id }?["bytes"].double ?? .infinity) <= 10_000_000
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
    private(set) var posterless = Set<String>()
    /// A recording or clip as a file to play, downloaded once into the
    /// media cache, streamed to disk off the main actor.
    func loadVideo(_ stepID: String) async -> URL? {
        if let url = StepVideos.url(for: stepID) { return url }
        if stepID.hasPrefix("file:") {
            let path = String(stepID.dropFirst("file:".count))
            guard let gateway, let url = await mediaFileURL(path)?.url else { return nil }
            return await StepVideos.file(for: stepID) { await gateway.http.authorizedDownload(url, to: $0) }
        }
        let id = String(stepID.dropFirst("media:".count))
        guard let client, let thread = selectedSessionID else { return nil }
        return await StepVideos.file(for: stepID) { destination in
            (try? await client.downloadMedia(threadID: thread, id: id, to: destination)) != nil
        }
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
    /// Answers a request. It leaves `requests` while the answer is on its
    /// way and for good once T3 reports it resolved; back if T3 refuses.
    func respond(to request: JSONValue, decision: String? = nil, answers: [String:Any]? = nil) async {
        guard let id = selectedSessionID, let requestID = request["payload"]["requestId"].string, responding[requestID] == nil else { return }
        let commandID = UUID().uuidString.lowercased()
        responding[requestID] = commandID
        do {
            var c: [String:Any] = ["threadId":id,"requestId":requestID]
            if let answers { c["type"] = "thread.user-input.respond"; c["answers"] = answers }
            else { c["type"] = "thread.approval.respond"; c["decision"] = decision ?? "decline" }
            try await dispatch(c, commandID: commandID)
        } catch {
            if responding[requestID] == commandID { responding[requestID] = nil }
            self.error = error.localizedDescription
        }
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
    /// Keeps `need` fresh until the lease ends; fetched at once too.
    func keepFresh(_ need: RefreshNeed) -> RefreshLease {
        let id = UUID()
        leases[id] = need
        Task { [weak self] in await self?.refresh(need) }
        return RefreshLease { [weak self] in self?.leases[id] = nil }
    }
    private func refresh(_ need: RefreshNeed) async {
        guard let client else { return }
        switch need {
        case .tasks(let app):
            if let list = try? await client.tasks(projectID: app) { adoptTasks(list, for: app) }
        case .conversation(let conversation):
            guard let thread = conversation.threadID, thread == selectedSessionID,
                  let media = try? await client.threadMedia(threadID: thread) else { return }
            adoptMedia(media, for: thread)
        }
    }
    /// Everything the phone keeps from the Mac's service, in one pass: the
    /// catalog Home shows, simulator sessions, and only what a screen holds
    /// a lease on (an app's tasks, the open thread's media). An unchanged
    /// reply is an empty 304. A pass already under way is joined; `fresh`
    /// waits for it and then asks again, for callers that just changed
    /// something. Returns why the builds or apps couldn't be fetched.
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
        loadProvidersIfDue()
        let needs = Set(leases.values)
        let apps = needs.compactMap { if case .tasks(let app) = $0 { return app }; return nil }
        let thread = selectedSessionID.flatMap { id in
            needs.contains { if case .conversation(let c) = $0 { return c.threadID == id }; return false } ? id : nil
        }
        async let b = client.builds(); async let m = client.fetchAppMetadata(); async let a = try? client.agents()
        async let sims = try? client.simulatorSessions()
        async let lists: [(String, AppTasks)] = withTaskGroup(of: (String, AppTasks)?.self) { group in
            for app in apps { group.addTask { (try? await client.tasks(projectID: app)).map { (app, $0) } } }
            var lists: [(String, AppTasks)] = []
            for await list in group { if let list { lists.append(list) } }
            return lists
        }
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
        for (app, list) in await lists { adoptTasks(list, for: app) }
        if let thread, let media = await published { adoptMedia(media, for: thread) }
        return failure
    }

    // MARK: Tasks

    /// An app's tasks: what the Mac last sent, older History pages loaded
    /// so far, and your edits it hasn't confirmed yet laid over them.
    func tasks(for project: AppProject) -> AppTasks { tasks(app: project.id) }
    private func tasks(app: String) -> AppTasks {
        #if DEBUG
        if var list = demoTasks {
            for (id, edit) in taskEdits { list = Self.apply(edit, to: id, in: list) }
            return list
        }
        #endif
        guard var list = observedTasks[app] else { return AppTasks() }
        if let older = olderHistory[app] {
            let seen = Set(list.tasks.map(\.id) + list.history.map(\.id))
            list.history += older.tasks.filter { !seen.contains($0.id) }
            list.historyNext = older.next
        }
        for (id, edit) in taskEdits { list = Self.apply(edit, to: id, in: list) }
        return list
    }
    /// The newest tasks at once, and History from its first page.
    func refreshTasks() async {
        guard let client, let app = selectedProjectID, let list = try? await client.tasks(projectID: app) else { return }
        olderHistory[app] = nil
        adoptTasks(list, for: app)
    }
    /// The next older page of History, after what's loaded.
    func loadMoreHistory(appID app: String) async {
        guard let client, !historyLoads.contains(app) else { return }
        let cursor: String?
        if let older = olderHistory[app] { cursor = older.next } else { cursor = observedTasks[app]?.historyNext }
        guard let cursor else { return }
        historyLoads.insert(app); defer { historyLoads.remove(app) }
        do {
            let page = try await client.tasks(projectID: app, historyBefore: cursor)
            // A refresh started over meanwhile: this page follows nothing.
            let now = olderHistory[app]?.next ?? observedTasks[app]?.historyNext
            guard now == cursor || olderHistory[app]?.next == cursor else { return }
            var older = olderHistory[app] ?? OlderHistory()
            older.tasks += page.history; older.next = page.historyNext
            olderHistory[app] = older
        } catch { self.error = error.localizedDescription }
    }
    private func adoptTasks(_ list: AppTasks, for app: String) {
        observedTasks[app] = list
        // An edit the Mac has applied is the Mac's now.
        let all = list.tasks + list.history
        for (id, edit) in taskEdits {
            guard let receipt = edit.receipt, let task = all.first(where: { $0.id == id }), (task.revision ?? 0) >= receipt else { continue }
            taskEdits[id] = nil
        }
    }
    /// A status or Top change made here: shown at once, sent once, and laid
    /// over the Mac's tasks until a reply holds it (the revision in its
    /// receipt), so a refresh already on its way can't put the row back.
    private struct PendingTaskEdit {
        let generation: Int
        let status: AppTask.Status?
        let toTop: Bool
        var receipt: UInt64?
    }
    private var taskEdits: [String: PendingTaskEdit] = [:] { didSet { changed() } }
    private var taskEditGeneration = 0
    /// Moves the row at once, before the Mac answers.
    func markTask(_ task: AppTask, status: AppTask.Status? = nil, toTop: Bool = false) {
        taskEditGeneration += 1
        taskEdits[task.id] = PendingTaskEdit(generation: taskEditGeneration, status: status, toTop: toTop)
    }
    private static func apply(_ edit: PendingTaskEdit, to id: String, in list: AppTasks) -> AppTasks {
        var list = list
        guard let index = list.tasks.firstIndex(where: { $0.id == id }) else { return list }
        if let status = edit.status { list.tasks[index].status = status }
        if edit.toTop { list.tasks.insert(list.tasks.remove(at: index), at: 0) }
        return list
    }
    func updateTask(_ task: AppTask, status: AppTask.Status? = nil, toTop: Bool = false) async {
        #if DEBUG
        if let demo = demoTasks {
            demoTasks = Self.apply(PendingTaskEdit(generation: 0, status: status, toTop: toTop), to: task.id, in: demo)
            taskEdits[task.id] = nil
            return
        }
        #endif
        guard let client else { return }
        if let edit = taskEdits[task.id], edit.receipt == nil, edit.status == status, edit.toTop == toTop {} else {
            markTask(task, status: status, toTop: toTop)
        }
        guard let generation = taskEdits[task.id]?.generation else { return }
        do {
            let revision = try await client.updateTask(id: task.id, status: status, toTop: toTop)
            // A later edit of the same task owns the row now.
            guard taskEdits[task.id]?.generation == generation else { return }
            if let revision { taskEdits[task.id]?.receipt = revision } else { taskEdits[task.id] = nil }
        } catch {
            if taskEdits[task.id]?.generation == generation { taskEdits[task.id] = nil }
            self.error = error.localizedDescription
        }
        let app = observedTasks.first { _, list in (list.tasks + list.history).contains { $0.id == task.id } }?.key ?? selectedProjectID
        if let app, let list = try? await client.tasks(projectID: app) { adoptTasks(list, for: app) }
    }
    #if DEBUG
    /// `SQUIRCLE_DEMO_TASKS=1`: made-up tasks kept on the phone, so ticking
    /// through them on a simulator touches nobody's real list.
    private var demoTasks: AppTasks? = SquircleModel.makeDemoTasks() { didSet { changed() } }
    private static func makeDemoTasks() -> AppTasks? {
        guard ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_TASKS"] == "1" else { return nil }
        let asks: [(String, String)] = [
            ("Stack the sims and fan them out", "in_progress"), ("Make the send button smaller", "ready_to_try"),
            ("Dark mode for the build sheet", "ready_to_try"), ("Swipe back from anywhere in a thread", "queued"),
            ("Show the build number on cards", "queued"), ("Faster cold launch", "queued"),
            ("Pin the newest build to the top", "queued"), ("Haptic when a turn finishes", "queued")]
        let tasks = asks.enumerated().map { index, item in
            ["id": "demo-\(index)", "ask": item.0, "status": item.1, "note": "", "order": Double(index),
             "updated_at": 0, "threads": [], "builds": [], "media": []] as [String: Any]
        }
        let data = try? JSONSerialization.data(withJSONObject: ["tasks": tasks, "history": []])
        return data.flatMap { try? JSONDecoder().decode(AppTasks.self, from: $0) }
    }
    #endif
    private var taskMedia = BoundedCache<String, Data>(budget: 16 << 20, cost: \.count)
    /// A picture attached to a task, downloaded once.
    func taskMediaData(task: String, media: String) async -> Data? {
        if let data = taskMedia.value(for: media) { return data }
        guard let client, let data = try? await client.taskMediaFile(taskID: task, id: media) else { return nil }
        taskMedia.set(data, for: media)
        return data
    }
    /// A clip attached to a task as a file to play, through the media cache.
    func taskVideo(task: String, media: String) async -> URL? {
        guard let client else { return nil }
        return await StepVideos.file(for: "task:" + media + ".mp4") { destination in
            (try? await client.downloadTaskMedia(taskID: task, id: media, to: destination)) != nil
        }
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
    /// Opens iOS's install prompt. For a build of this very app, follows
    /// the attempt: once the Mac has sent every byte, iOS is about to replace
    /// Squircle, and `updatingTo` says so. A download that only started, or
    /// failed, never does. Gives up if the person doesn't confirm within
    /// three minutes, or the transfer doesn't finish within fifteen.
    @discardableResult
    func install(_ build: AppBuild) async -> Bool {
        guard let client else { error = ClientError.configuration.localizedDescription; return false }
        let own = build.bundleID != nil && build.bundleID == Bundle.main.bundleIdentifier
        if own { installWatch?.cancel(); installWatch = nil; installAttempt = .requestingLink(build) }
        func fail(_ reason: String) -> Bool {
            if own, installAttempt == .requestingLink(build) { installAttempt = .ended(reason) }
            error = reason; return false
        }
        let url: URL
        do { url = try await client.installURL(buildID: build.id) } catch { return fail(error.localizedDescription) }
        guard await UIApplication.shared.open(url) else { return fail("Couldn’t open the installer.") }
        // Not this app, or the attempt was cancelled meanwhile.
        guard own, installAttempt == .requestingLink(build) else { return true }
        installAttempt = .prompting(build, link: url, deadline: .now + .seconds(180))
        installWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let deadline: ContinuousClock.Instant
                switch installAttempt {
                case .prompting(let b, _, let d) where b.id == build.id: deadline = d
                case .watching(let b, _, let d) where b.id == build.id: deadline = d
                default: return
                }
                guard ContinuousClock.now < deadline else { installAttempt = .ended("The installation didn’t finish."); return }
                switch try? await client.installProgress(link: url) {
                case .transferred?: installAttempt = .transferred(build); return
                case .downloading?:
                    if case .prompting = installAttempt { installAttempt = .watching(build, link: url, deadline: .now + .seconds(900)) }
                default: break
                }
            }
        }
        return true
    }
    func cancelUpdate() { installWatch?.cancel(); installWatch = nil; installAttempt = .ended(nil) }
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
    /// A copy on disk is never live: T3 confirms or replaces it.
    func loadThread(_ id: String) -> T3ThreadState? { (read(threadURL(id)) as T3ThreadState?)?.restored }
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
