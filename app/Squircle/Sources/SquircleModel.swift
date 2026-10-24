import AVFoundation
import Foundation
import Network
import UIKit

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
    /// The connection as screens show it, from M01's state.
    var connection: ConnectionPhase {
        guard let link else { return .stopped }
        switch link.state.phase {
        case .stopped: return .stopped
        case .suspended: return .suspended
        case .refused: return .refused
        case .connecting(let a), .synchronizing(let a, _), .retrying(let a, _): return .connecting(.init(id: a.id, failingSince: a.failingSince))
        case .ready(let session): return .ready(.init(attempt: session.attempt, since: session.since))
        }
    }
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
        attempt.failingSince.map { $0.duration(to: .now) >= Link.grace } ?? false
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
    private var observedRequests: [PendingRequest] = [] { didSet { if observedRequests != oldValue { changed() } } }
    /// Requests waiting for you: T3's, less those being answered.
    var requests: [PendingRequest] {
        let answering = commands.answering
        return answering.isEmpty ? observedRequests : observedRequests.filter { !answering.contains($0.id) }
    }
    private(set) var changes: [TurnChanges] = [] { didSet { changed() } }
    /// Every worker Squircle started, archived ones too, by thread ID.
    private(set) var workers: [String: KnownWorker] = [:] { didSet { changed() } }
    /// Model and approval choices made here that T3 hasn't reported back yet.
    private struct LocalChoice: Equatable { var model: JSONValue?; var mode: T3RuntimeMode? }
    private var choices: [ConversationID: LocalChoice] = [:] { didSet { changed() } }
    /// The model you chose last, for new drafts.
    private var preferredModel: JSONValue?
    private var taskLists = TaskLists() { didSet { if taskLists != oldValue { changed() } } }
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
    /// M01: T3's socket and subscriptions.
    private let link: LinkRuntime?
    private let client: SquircleClient?
    /// M03: messages on their way, and where the unfinished ones are kept.
    private var delivery = Delivery.State() { didSet { changed() } }
    private let journal: PendingJournal?
    private var journalSequence: UInt64 = 0
    /// The fields messages were sent with, to put back if T3 refuses one.
    private var sentFields: [String: [ImageAttachment]] = [:]
    private var sendWaiters: [String: AsyncStream<SendOutcome>.Continuation] = [:]
    /// M04: addressed commands and what they show meanwhile.
    private var commands = Commands.State() { didSet { changed() } }
    private var commandWaiters: [String: [CheckedContinuation<Commands.Settlement, Never>]] = [:]
    private var settledCommands: [(id: String, settlement: Commands.Settlement)] = []
    /// The newest edit of each task proposed here, by task.
    private var taskEditIDs: [String: String] = [:]
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
    private var refreshing = false
    private var monitor: Task<Void,Never>?
    private var configLoader: Task<Void,Never>?
    /// Each app's newest preview picture: (version, PNG) by app.
    private var previewCache = BoundedCache<String, (version: String, data: Data)>(budget: 24 << 20, cost: { $0.data.count })
    private var launchReported = false
    private var sessionProjects: [String:String] = [:]
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
    private var debugDrops: Task<Void, Never>?
    private var installWatch: Task<Void, Never>?
    private var media: [JSONValue] { state.media }
    /// Pictures, recordings and files the open conversation shows.
    private(set) lazy var conversationMedia = ConversationMedia(
        client: client, gateway: gateway, base: configuration?.t3URL,
        thread: { [weak self] in self?.selectedSessionID },
        message: { [weak self] id in self?.messages.first { $0.id == id } },
        published: { [weak self] in self?.media ?? [] })
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
        let instance = state.thread["providerInstanceId"].string
            ?? state.thread["modelSelection"]["instanceId"].string
            ?? sessions.first(where: { $0.id == thread })?.modelSelection["instanceId"].string
        guard let instance else { return [] }
        return providers.filter { $0["instanceId"].string == instance }
    }
    var availableModelSelections: [JSONValue] {
        availableModelProviders.flatMap { provider in
            provider["models"].array.map { ["instanceId": provider["instanceId"], "model": $0["slug"]] }
        }
    }
    /// Models the picker offers, one section per provider.
    var modelMenu: [(title: String, choices: [(selection: JSONValue, name: String)])] {
        ModelNames.menu(availableModelProviders)
    }
    func shortAgentName(for selection: JSONValue) -> String {
        guard let provider = providers.first(where: { $0["instanceId"] == selection["instanceId"] }) else {
            return selection["model"].string ?? "Model"
        }
        let option = provider["models"].array.first { $0["slug"] == selection["model"] }
        return ModelNames.short(option?["name"].string ?? selection["model"].string ?? "Model", maker: provider["displayName"].string ?? "")
    }
    /// Each available provider's default model.
    private var providerDefaults: [JSONValue] {
        availableModelProviders.compactMap { provider in
            guard let option = provider["models"].array.first(where: { $0["isDefault"].bool }) ?? provider["models"].array.first else { return nil }
            return ["instanceId": provider["instanceId"], "model": option["slug"]]
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
            let agentChoice: JSONValue = ["instanceId": .string(Self.agentInstance), "model": .string(model)]
            if isValidModel(agentChoice) { return agentChoice }
        }
        return providerDefaults.first ?? availableModelSelections.first ?? .null
    }
    /// The open conversation's approval mode, the same way.
    var runtimeMode: T3RuntimeMode {
        guard let open else { return .auto }
        if let thread = open.threadID, let pending = commands.mode(for: thread) { return pending }
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

    /// `journal`: where unfinished messages are kept (each host its own; none without a configuration).
    init(configuration: AppConfiguration? = try? AppConfiguration.load(), preferences: UserDefaults = .standard,
         commandDispatch: ((JSONValue) async throws -> JSONValue)? = nil,
         upload: ((URL, String) async throws -> String)? = nil, scopeBundleID: String? = nil,
         journal: PendingJournal?? = nil) {
        self.preferences = preferences
        self.scopeBundleID = scopeBundleID
        self.commandDispatch = commandDispatch
        self.upload = upload
        self.configuration = configuration
        client = configuration.map { SquircleClient(configuration:$0) }
        gateway = configuration.map(T3Gateway.init(configuration:))
        link = gateway.map(LinkRuntime.init(gateway:))
        self.journal = journal ?? (configuration == nil ? nil : PendingJournal())
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
        #if DEBUG
        if demoApps != nil { reconcileProjects() }
        #endif
        link?.host = self
        if link == nil {
            // No socket (an injected dispatch, or no configuration): nothing to wait for.
            deliver(.sessionReady(attempt: 0)); command(.sessionReady(attempt: 0))
        }
        if let journal = self.journal {
            // Messages that were on their way when the app last quit go again, as themselves.
            Task { [weak self] in
                let contents = await journal.load()
                guard let self, !closed else { return }
                #if DEBUG
                NSLog("SQUIRCLE-FSM M03 restored %d unfinished message(s)", contents.saved.count)
                #endif
                if !contents.saved.isEmpty { deliver(.restore(contents.saved)) }
                if !contents.unreadable.isEmpty { error = "A message kept on this phone couldn’t be read, so it wasn’t sent." }
            }
        }
        link?.send(.start)
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
        closed = true
        for task in [configLoader, monitor, networkWatcher, memoryWatcher, stepDetails, cacheWrite, homeWrite,
                     simulatorRefresh, conversationBuild, debugDrops, installWatch] { task?.cancel() }
        configLoader = nil; monitor = nil; networkWatcher = nil; memoryWatcher = nil
        stepDetails = nil; cacheWrite = nil; homeWrite = nil; simulatorRefresh = nil; conversationBuild = nil
        debugDrops = nil; installWatch = nil
        for case .uploading(_, let upload) in captureTransfers.values { upload.cancel() }
        captureTransfers.removeAll()
        // Unfinished messages stay on disk for the next run; their waiters end here.
        for waiter in sendWaiters.values { waiter.finish() }
        sendWaiters.removeAll()
        let waiting = commandWaiters.values.flatMap { $0 }; commandWaiters.removeAll()
        for waiter in waiting { waiter.resume(returning: .superseded) }
        link?.close(); client?.invalidate()
        let finished = observers.values; observers.removeAll()
        for observer in finished { observer.finish() }
    }
    func refresh() async {
        guard gateway != nil, client != nil else { error = ClientError.configuration.localizedDescription; return }
        // The service doesn't depend on T3: both load at once.
        if connection == .refused { link?.send(.reconnect) } else { link?.send(.retryNow) }
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

    /// Reconnect, tapped: a fresh attempt now, without the backoff or an
    /// attempt stuck waiting on a slow socket. Models load again if they failed.
    func reconnect() async {
        loadProvidersIfDue(force: { if case .failed = catalog { return true }; return false }())
        guard !connected else { await refreshServices(); return }
        link?.send(.reconnect)
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
    /// Squircle went to the background: the socket is held for as long as
    /// iOS gives (about 30 s), so a quick app switch never drops it.
    func enteredBackground() {
        guard gateway != nil else { return }
        saveCurrentThread()
        link?.send(.background)
    }
    private func log(_ message: String) {
        #if DEBUG
        NSLog("SQUIRCLE-CONN %@", message)
        #endif
    }
    /// Back in the foreground: reconnect at once if the socket was closed,
    /// otherwise check that it still answers.
    func enteringForeground() { link?.send(.foreground) }
    /// The network changed (Wi-Fi to cellular, back online): a socket on the
    /// old path is likely dead, and a waiting reconnect should try now.
    private func watchNetwork() {
        networkWatcher = Task { [weak self] in
            var previous: NWPath?
            for await path in NWPathMonitor() {
                guard let self else { return }
                defer { previous = path }
                conversationMedia.metered = path.isExpensive || path.isConstrained
                #if DEBUG
                if ProcessInfo.processInfo.environment["SQUIRCLE_METERED"] == "1" { conversationMedia.metered = true }
                #endif
                guard let before = previous, path.status == .satisfied else { continue }
                let changed = before.status != .satisfied || before.availableInterfaces.map(\.name) != path.availableInterfaces.map(\.name)
                link?.send(.networkChanged(changed: changed))
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
        if item["kind"].string == "snapshot", item["resolvedRepositoryIdentityRoots"] != .null {
            // Only a refresh of some projects' metadata; it carries no threads.
            var s = shell.object, projects = s["projects"]?.array ?? []
            for project in item["snapshot"]["projects"].array {
                if let i = projects.firstIndex(where: { $0["id"] == project["id"] }) { projects[i] = project } else { projects.append(project) }
            }
            s["projects"] = .array(projects); shell = .object(s)
        }
        else if item["kind"].string == "snapshot" {
            // Archived threads are T3's archive, never Home.
            var s = item["snapshot"].object; s["archivedThreads"] = nil; shell = .object(s)
            ConnectionTrace.mark("shell.snapshot")
        }
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
            // An archived thread leaves the active shell; one leaving the archive
            // (unarchived, deleted) changes nothing here.
            case "thread.updated" where item["location"].string == "archive":
                s["threads"] = .array((s["threads"]?.array ?? []).filter { $0["id"] != item["thread"]["id"] })
            case "project.updated", "thread.updated":
                let key = item["kind"].string == "project.updated" ? "projects" : "threads"
                let value = item[key == "projects" ? "project" : "thread"]
                var rows = s[key]?.array ?? []
                if let i = rows.firstIndex(where: { $0["id"] == value["id"] }) { rows[i] = value } else { rows.append(value) }
                s[key] = .array(rows)
            case "thread.removed" where item["location"].string == "archive": break
            case "project.removed", "thread.removed":
                let project = item["kind"].string == "project.removed"; let key = project ? "projects" : "threads"
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
            // `status` is `idle` or the latest run's; a question or approval is `pendingRuntimeRequest`.
            let status = t["status"].string ?? "idle"
            let phase: ChatSession.Phase = t["pendingRuntimeRequest"] != .null || status == "waiting" ? .needsYou
                : T3ThreadState.activeRunStatuses.contains(status) ? .working : .idle
            return ChatSession(id:t["id"].string ?? "",title:t["title"].string ?? "New thread",updatedAt:t["updatedAt"].date,
                               phase:phase,modelSelection:t["modelSelection"],latestTurn:TurnObservation(shell: t))
        }.sorted { $0.updatedAt > $1.updatedAt }
        reconcileProjects()
        observeCreations()
        if commands.entries.contains(where: { if case .project = $0.intent.kind { return true }; return false }) {
            command(.projectsObserved(roots: Set(shell["projects"].array.compactMap { $0["workspaceRoot"].string })))
        }
        if ConnectionTrace.enabled, liveShell, !tracedHome, !projects.isEmpty {
            tracedHome = true; ConnectionTrace.mark("home.live", "projects=\(projects.count) threads=\(sessions.count)")
        }
    }
    private var tracedHome = false, liveShell = false
    private func reconcileProjects() {
        #if DEBUG
        if let demoApps { projects = demoApps; return }
        #endif
        // An order you gave Home shows at once, until the Mac shows it.
        let metadata = commands.appOrder.map { AppOrder.apply($0, to: appMetadata) } ?? appMetadata
        projects = T3AppCatalog.projects(shell:shell,metadata:metadata,builds:builds)
            .filter { scopeBundleID == nil || $0.bundleID == scopeBundleID }
    }
    /// Home's apps, as the user just arranged them: shown at once, sent
    /// once (M04), and kept on the Mac.
    func arrangeApps(_ ids: [String]) {
        #if DEBUG
        if let demo = demoApps {
            demoApps = ids.compactMap { id in demo.first { $0.id == id } } + demo.filter { !ids.contains($0.id) }
            reconcileProjects(); return
        }
        #endif
        guard client != nil else { return }
        let visible = ids.compactMap { id in projects.first { $0.id == id }?.metadataID }
        let order = AppOrder.arranged(AppOrder.apply(commands.appOrder ?? [], to: appMetadata).map(\.id), showing: visible)
        startCommand(.appOrder(order), command: nil)
    }
    /// Bumped when Home's order is adopted from the Mac's reply, so a list
    /// read before it can't put the old order back.
    private var catalogGeneration = 0
    #if DEBUG
    /// `SQUIRCLE_DEMO_APPS=1`: made-up apps kept on the phone, so arranging
    /// Home on a simulator touches nobody's real catalog.
    private var demoApps: [AppProject]? = ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_APPS"] == "1"
        ? ["Squircle", "Weather", "Recipes", "Habits", "Budget", "Trails", "Notes", "Sketch"].enumerated().map {
            AppProject(id: "demo-app-\($0.offset)", name: $0.element, subtitle: "", bundleID: nil, canBuild: false)
        } : nil
    #endif
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
    func builds(for project: AppProject) -> [AppBuild] { T3AppCatalog.builds(builds, of: project.id, agent: agents[project.id], shell: shell) }
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
        conversationBuild?.cancel(); conversationBuild = nil; conversationDirty = false
        stepDetails?.cancel(); stepDetailsCount = -1
        // Nothing more will be seen of the thread left behind here.
        if let previous = open?.threadID, previous != id.threadID { command(.left(thread: previous)) }
        // A message T3 took needs no echo once nobody looks at it.
        deliver(.watch(id))
        open = id; error = nil
        link?.send(.follow(id.threadID))
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
    /// the previous one (M01 follows the open conversation's thread).
    func open(_ id: ConversationID) async { show(id) }
    /// The thread a sent draft became, for the rest of the session.
    func successor(of id: ConversationID) -> ConversationID? { successors[id] }
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
        guard let open, !isRunning, delivery.entry(for: open) == nil, isValidModel(selection) else { return }
        choices[open, default: LocalChoice()].model = selection
        if selection["instanceId"].string != Self.agentInstance, let data = try? JSONEncoder().encode(selection) {
            preferences.set(data, forKey: Self.preferredModelKey); preferredModel = selection
        }
    }
    func chooseRuntimeMode(_ mode: T3RuntimeMode) {
        guard let open else { return }
        choices[open, default: LocalChoice()].mode = mode
    }
    /// A draft's mode is a choice for its first message; a thread's is a
    /// command T3 shows back (until then, and only if T3 refuses it, not).
    func setRuntimeMode(_ mode: T3RuntimeMode) async {
        guard let open else { return }
        guard let thread = open.threadID else { chooseRuntimeMode(mode); return }
        await propose(.mode(thread: thread, mode), command: ["type": "thread.runtime-mode.set", "threadId": .string(thread), "runtimeMode": .string(mode.rawValue)])
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
            case "snapshot": ConnectionTrace.mark("thread.snapshot", "seq=\(item["snapshotSequence"].int ?? -1)")
            default: if tracedRows, let at = item["event"]["occurredAt"].string { tracedEventAt = at }
            }
        }
        let held = state.sequence
        state.consume(item); rebuildConversation(); deriveFromState()
        // A revert rewrote history the phone can't replay: start from a snapshot.
        if held >= 0, state.sequence < 0, let id = selectedSessionID { link?.send(.followReverted(threadID: id)) }
        scheduleCacheWrite()
        if state.itemCount != stepDetailsCount { stepDetailsCount = state.itemCount; scheduleStepDetails() }
        observeOpenThread()
        guard let open else { return }
        // Choices T3 now reports are T3's again.
        if var choice = choices[open] {
            if let model = choice.model, state.thread["modelSelection"] == model { choice.model = nil }
            if let mode = choice.mode, state.thread["runtimeMode"].string == mode.rawValue { choice.mode = nil }
            choices[open] = choice.model == nil && choice.mode == nil ? nil : choice
        }
        if let last = shell["threads"].array.first(where: { $0["id"].string == selectedSessionID })?["lastError"].string { error = last }
    }
    /// The open thread is working, or a message T3 just took is about to.
    var isRunning: Bool {
        state.isRunning || open.flatMap(pendingSend(for:))?.phase == .accepted
    }
    /// The one way a command reaches T3: exactly as given, answered with
    /// how it ended. An injected dispatch (tests) stands in for T3's socket.
    private func t3Dispatch(_ command: JSONValue) async -> CommandOutcome {
        if let commandDispatch {
            do {
                let result = try await commandDispatch(command)
                return result["status"].string == "rejected" ? .refused("T3 rejected the command: \(result.formatted)") : .accepted(result)
            } catch { return .service(error) }
        }
        guard let gateway else { return .refused(ClientError.configuration.localizedDescription) }
        return await gateway.dispatch(command)
    }
    /// What the open thread shows settles messages and commands waiting on it.
    private func observeOpenThread() {
        guard let thread = selectedSessionID else { return }
        for entry in delivery.entries.values {
            switch entry.stage {
            case .sending(let r), .accepted(let r):
                if r.threadID == thread, state.hasMessage(entry.intent.messageID) {
                    deliver(.messageObserved(threadID: thread, messageID: entry.intent.messageID))
                }
            case .preparing, .creating: break
            }
        }
        // A copy on disk may lack what T3 has since: only T3's own state settles a command.
        guard state.isLive, commands.entries.contains(where: { $0.intent.kind.thread == thread }) else { return }
        command(.threadObserved(.init(threadID: thread, pendingRequests: Set(state.pendingRequests.map(\.id)),
                                      runtimeMode: state.thread["runtimeMode"].string, running: state.isRunning,
                                      activeTurn: state.activeRunID)))
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

    // MARK: Sending (M03)

    func pendingSend(for id: ConversationID) -> PendingSend? {
        guard let entry = delivery.entry(for: id) else { return nil }
        let phase: PendingSend.Phase
        switch entry.stage {
        case .preparing: phase = .preparing
        case .creating: phase = .creating
        case .sending: phase = .awaitingAcceptance
        case .accepted: phase = .accepted
        }
        return PendingSend(messageID: entry.intent.messageID, text: entry.intent.spoken, images: entry.intent.pictures.count,
                           captures: entry.intent.recordings.map { SentCapture(label: Self.attachment($0).capture!.sentLabel, path: $0.path) },
                           phase: phase)
    }
    /// What unfinished messages hold on the phone, roughly as saved.
    private var pendingBytes: Int {
        delivery.entries.values.reduce(0) { total, entry in
            total + entry.intent.spoken.utf8.count + entry.intent.recordings.reduce(0) { $0 + $1.thumbnail.count }
                + entry.intent.pictures.reduce(0) { $0 + $1.jpeg.count } * 3
        }
    }

    /// Starts sending `text` with the open field's pictures from `id`, which
    /// must be open. The pending message exists, and the field is empty,
    /// when this returns. Pictures go back into the field if T3 refuses.
    func startSend(_ spoken: String, in project: AppProject, from id: ConversationID) -> SendStart {
        guard open == id else { return .refused("This conversation is no longer open.") }
        guard delivery.entry(for: id) == nil else { return .refused("Still sending the last message.") }
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
        let pictures = field.filter { $0.capture == nil }, recordings = field.filter { $0.capture != nil }
        // Never drop an unsent message to make room: refuse the new one instead.
        guard pendingBytes + pictures.reduce(0, { $0 + $1.data.count }) * 3 <= PendingJournal.budget else {
            return .refused("Too many messages are still waiting to send from this phone.")
        }
        let mode = runtimeMode.rawValue
        let destination: Delivery.Destination
        switch id {
        case .thread(let thread, _): destination = .thread(thread)
        case .draft(_, _, agent: true):
            // The Mac creates the agent (its worktree and thread) in the chosen mode, or finds the one it made.
            destination = .agent(model: selection["instanceId"].string == Self.agentInstance ? selection["model"].string : nil)
        case .draft:
            let thread = UUID().uuidString.lowercased()
            destination = .newThread(id: thread, command: Delivery.createCommand(threadID: thread, projectID: project.id, selection: selection,
                                                                                 mode: mode, identity: .fresh()))
        }
        // The app's agent gets its instructions from the Mac; other threads get Squircle's once.
        let messages = id.threadID == nil ? [] : state.projection["messages"].array
        let agentThread = id.isAgentDraft || id.threadID.map { agents[project.id] == $0 } == true
            || (id.threadID != nil && state.thread["modelSelection"]["instanceId"].string == Self.agentInstance)
        var context = ""
        let instructionsThread: String? = switch destination { case .thread(let t), .newThread(let t, _): t; case .agent: nil }
        if !agentThread, let thread = instructionsThread {
            let instructions = squircleInstructions(for: project, threadID: thread)
            if messages.isEmpty {
                context = "\n\n" + project.agentContext + "\nFor signed builds/install links use \(cliCommand). Run help workflow for the documented commands. This app is a native client of T3; T3 manages this thread.\n" + instructions
            } else if !messages.contains(where: { ($0["text"].string ?? "").contains("sim start --thread") }) {
                // Threads started before these instructions existed get them once.
                context = AppProject.contextMarker + project.name + ".\n" + instructions
            }
        }
        let seed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = Delivery.Intent(
            messageID: UUID().uuidString.lowercased(), origin: id, projectID: project.id, destination: destination, spoken: spoken,
            pictures: pictures.map { .init(id: $0.id, jpeg: $0.data) },
            recordings: recordings.compactMap { a in a.capture.map { .init(id: a.id, kind: $0.kind.rawValue, path: $0.file.path, label: $0.label, thumbnail: a.data) } },
            selection: selection, mode: mode, context: context,
            titleSeed: String((seed.isEmpty ? (recordings.isEmpty ? "Image" : "Recording") : seed).prefix(120)), turn: .fresh())
        drafts[id] = nil; error = nil
        // Your recording plays in the pending message from the phone's copy.
        for case let capture? in field.map(\.capture) where capture.kind == .video {
            StepVideos.set(capture.file, for: "file:" + capture.file.path)
        }
        sentFields[intent.messageID] = field
        let (stream, continuation) = AsyncStream.makeStream(of: SendOutcome.self, bufferingPolicy: .bufferingNewest(1))
        sendWaiters[intent.messageID] = continuation
        deliver(.submit(intent))
        let messageID = intent.messageID
        return .started(messageID: messageID, outcome: Task {
            for await outcome in stream { return outcome }
            return .rejected(messageID: messageID, reason: "Squircle closed.", conversation: id)
        })
    }
    func send(_ spoken: String, in project: AppProject, from id: ConversationID) async -> SendOutcome? {
        guard case .started(_, let outcome) = startSend(spoken, in: project, from: id) else { return nil }
        return await outcome.value
    }
    /// M03's one executor: reduce, then run what the reduction asks for.
    private func deliver(_ event: Delivery.Event) {
        let reduction = Delivery.reduce(delivery, event)
        #if DEBUG
        for violation in Delivery.violations(in: reduction.state) { NSLog("SQUIRCLE-FSM M03 %@", violation) }
        if case .protocolFault(let fault) = reduction.disposition { NSLog("SQUIRCLE-FSM M03 fault %@", fault) }
        #endif
        delivery = reduction.state
        run(reduction.effects[...])
    }
    /// Runs `effects` in order; what follows a save waits until it is on disk.
    private func run(_ effects: ArraySlice<Delivery.Effect>) {
        var rest = effects
        while let effect = rest.popFirst() {
            guard case .save(let entry) = effect else { perform(effect); continue }
            guard let journal else { continue }
            journalSequence += 1
            let sequence = journalSequence, after = rest
            Task { [weak self] in
                do {
                    try await journal.save(.init(intent: entry.intent, stage: entry.stage), sequence: sequence)
                    self?.run(after)
                } catch {
                    self?.deliver(.saveFailed(messageID: entry.intent.messageID, reason: error.localizedDescription))
                }
            }
            return
        }
    }
    private func perform(_ effect: Delivery.Effect) {
        switch effect {
        case .save: break
        case .forget(let id):
            journalSequence += 1
            let sequence = journalSequence
            if let journal { Task { await journal.forget(id, sequence: sequence) } }
        case .prepare(let intent):
            let field = sentFields[intent.messageID] ?? intent.recordings.map(Self.attachment)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await intent.spoken + captureBlock(field.filter { $0.capture != nil })
                    deliver(.prepared(messageID: intent.messageID, text: text))
                } catch {
                    deliver(.prepareFailed(messageID: intent.messageID, reason: "Couldn't send the recording to your Mac: " + error.localizedDescription))
                }
            }
        case .createThread(let id, let command, let attempt):
            Task { [weak self] in
                guard let outcome = await self?.t3Dispatch(command) else { return }
                self?.deliver(.createAnswered(messageID: id, attempt: attempt, outcome))
            }
        case .ensureAgent(let id, let project, let model, let mode):
            Task { [weak self] in
                guard let self else { return }
                guard let client else { deliver(.createAnswered(messageID: id, attempt: nil, .refused(ClientError.configuration.localizedDescription))); return }
                do {
                    let thread = try await client.startAgent(projectID: project, message: "", model: model, mode: T3RuntimeMode(rawValue: mode) ?? .auto)
                    deliver(.created(messageID: id, threadID: thread))
                } catch { deliver(.createAnswered(messageID: id, attempt: nil, .service(error))) }
            }
        case .dispatch(let id, let command, let attempt):
            #if DEBUG
            NSLog("SQUIRCLE-FSM M03 turn %@ command %@ session %d", id, command["commandId"].string ?? "", attempt)
            #endif
            Task { [weak self] in
                guard let outcome = await self?.t3Dispatch(command) else { return }
                #if DEBUG
                NSLog("SQUIRCLE-FSM M03 turn %@ answered %@", id, String(describing: outcome).prefix(120).description)
                #endif
                self?.deliver(.turnAnswered(messageID: id, attempt: attempt, outcome))
            }
        case .adopt(let draft, let thread, let agentOf):
            if let project = agentOf, let id = thread.threadID { agents[project] = id }
            adopt(draft: draft, becomes: thread)
        case .restoreField(let owner, let intent):
            restoreField(sentFields[intent.messageID] ?? (intent.pictures.compactMap(Self.attachment) + intent.recordings.map(Self.attachment)), to: owner)
        case .settle(let id, let settlement):
            let field = sentFields.removeValue(forKey: id)
            let outcome: SendOutcome
            switch settlement {
            case .accepted(let owner):
                for attachment in field ?? [] where attachment.capture != nil { captureTransfers[attachment.id] = nil }
                outcome = .accepted(messageID: id, conversation: owner)
            case .rejected(let owner, let reason): outcome = .rejected(messageID: id, reason: reason, conversation: owner)
            }
            if let waiter = sendWaiters.removeValue(forKey: id) { waiter.yield(outcome); waiter.finish() }
        case .report(let owner, let reason):
            if let open, open == owner || successors[open] == owner { error = reason }
        }
    }
    /// A field picture or recording as it was saved with its message.
    private static func attachment(_ picture: Delivery.Picture) -> ImageAttachment? {
        UIImage(data: picture.jpeg).flatMap { ImageAttachment($0, id: picture.id) }
    }
    private static func attachment(_ recording: Delivery.Recording) -> ImageAttachment {
        let kind = ImageAttachment.Capture.Kind(rawValue: recording.kind) ?? .video
        return ImageAttachment(capture: .init(kind: kind, file: URL(fileURLWithPath: recording.path), label: recording.label),
                               thumbnail: UIImage(data: recording.thumbnail) ?? UIImage(), id: recording.id)
    }
    /// T3 made `thread` for the draft `draft`: its pictures and choices
    /// belong to the thread from now on.
    private func adopt(draft: ConversationID, becomes id: ConversationID) {
        guard let thread = id.threadID else { return }
        sessionProjects[thread] = draft.appID
        successors[draft] = id
        if let field = drafts.removeValue(forKey: draft) { drafts[id] = field }
        if let choice = choices.removeValue(forKey: draft) { choices[id] = choice }
    }
    /// What the shell and the Mac's agents show settles drafts being made.
    private func observeCreations() {
        for entry in delivery.entries.values {
            guard case .creating = entry.stage else { continue }
            switch entry.intent.destination {
            case .newThread(let thread, _):
                if shell["threads"].array.contains(where: { $0["id"].string == thread }) { deliver(.threadObserved(thread)) }
            case .agent:
                if let thread = agents[entry.intent.projectID] { deliver(.agentObserved(projectID: entry.intent.projectID, threadID: thread)) }
            case .thread: break
            }
        }
    }

    // MARK: Commands (M04)

    /// Proposes a command and waits until it is taken, refused or replaced.
    @discardableResult
    private func propose(_ kind: Commands.Kind, command body: [String: JSONValue]?) async -> Commands.Settlement {
        let id = startCommand(kind, command: body)
        return await settlement(of: id)
    }
    private func startCommand(_ kind: Commands.Kind, command body: [String: JSONValue]?) -> String {
        let identity = CommandIdentity.fresh()
        let intent = Commands.Intent(identity: identity, kind: kind, command: body.map(identity.stamp))
        if command(.propose(intent)) != .applied { settle(intent.id, .superseded) }
        return intent.id
    }
    private func settlement(of id: String) async -> Commands.Settlement {
        if let known = settledCommands.last(where: { $0.id == id }) { return known.settlement }
        guard commands.entry(id) != nil || commands.queued.values.contains(where: { $0.id == id }) else { return .done }
        return await withCheckedContinuation { commandWaiters[id, default: []].append($0) }
    }
    private func settle(_ id: String, _ settlement: Commands.Settlement) {
        settledCommands.append((id, settlement))
        if settledCommands.count > 32 { settledCommands.removeFirst(settledCommands.count - 32) }
        for waiter in commandWaiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: settlement) }
    }
    /// M04's one executor.
    @discardableResult
    private func command(_ event: Commands.Event) -> Disposition {
        let reduction = Commands.reduce(commands, event)
        #if DEBUG
        for violation in Commands.violations(in: reduction.state) { NSLog("SQUIRCLE-FSM M04 %@", violation) }
        if case .protocolFault(let fault) = reduction.disposition { NSLog("SQUIRCLE-FSM M04 fault %@", fault) }
        #endif
        let order = commands.appOrder
        commands = reduction.state
        if commands.appOrder != order { reconcileProjects() }
        for effect in reduction.effects { perform(effect) }
        return reduction.disposition
    }
    private func perform(_ effect: Commands.Effect) {
        switch effect {
        case .dispatch(let id, let body, let attempt):
            Task { [weak self] in
                guard let outcome = await self?.t3Dispatch(body) else { return }
                self?.command(.answered(id: id, attempt: attempt, outcome))
            }
        case .editTask(let id, let task, let status, let toTop):
            Task { [weak self] in
                guard let self else { return }
                guard let client else { command(.answered(id: id, attempt: 0, .refused(ClientError.configuration.localizedDescription))); return }
                do {
                    let revision = try await client.updateTask(id: task, status: status, toTop: toTop)
                    command(.answered(id: id, attempt: 0, .accepted(.object(revision.map { ["revision": .number(Double($0))] } ?? [:]))))
                } catch { command(.answered(id: id, attempt: 0, .service(error))) }
                await readTasks(containing: task)
            }
        case .orderApps(let id, let ids):
            Task { [weak self] in
                guard let self else { return }
                guard let client else { command(.answered(id: id, attempt: 0, .refused(ClientError.configuration.localizedDescription))); return }
                do {
                    let catalog = try await client.orderApps(ids)
                    catalogGeneration += 1
                    if catalog != appMetadata { appMetadata = catalog }
                    command(.answered(id: id, attempt: 0, .accepted(.null)))
                } catch { command(.answered(id: id, attempt: 0, .service(error))) }
            }
        case .readTasks(let task):
            Task { [weak self] in await self?.readTasks(containing: task) }
        case .settle(let id, let settlement): settle(id, settlement)
        case .report(let reason): error = reason
        }
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
        let clips = media.compactMap { item -> ChatMessage? in
            // Simulator recordings show as the turn's simulator instead.
            guard item["simulator"]["session_id"].string == nil,
                  let id = item["id"].string, let seconds = item["created_at"].double else { return nil }
            let caption = item["caption"].string.flatMap { $0.isEmpty ? nil : $0 }
            let video = item["kind"].string == "video"
            var message = ChatMessage(id: "media:" + id, role: "tool", content: caption ?? (video ? "Recording" : "Image"),
                                      symbol: video ? "record.circle" : "photo",
                                      createdAt: ISODate.format(Date(timeIntervalSince1970: seconds)))
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
    /// One turn's unified diff, from T3's checkpoints.
    func turnDiff(_ change: TurnChanges) async -> String? {
        guard let gateway, let thread = selectedSessionID else { return nil }
        do {
            let result = try await gateway.call("orchestration.getTurnDiff", ["threadId": .string(thread),
                "fromTurnCount": .int(max(0, change.count - 1)), "toTurnCount": .int(change.count)])
            return result["diff"].string
        } catch { self.error = error.localizedDescription; return nil }
    }
    /// Stops the run going now (never a later one, if T3's answer is lost).
    func stop() async {
        guard let id = selectedSessionID, let run = state.activeRunID else { return }
        await propose(.interrupt(thread: id, turn: run),
                      command: ["type": "run.interrupt", "threadId": .string(id), "runId": .string(run)])
    }
    /// Answers a request. It leaves `requests` while the answer is on its
    /// way and for good once T3 reports it resolved; back only if T3 refuses.
    /// An approval needs its decision: none is ever assumed.
    func respond(to request: PendingRequest, decision: String? = nil, answers: [String: JSONValue]? = nil) async {
        let requestID = request.id
        guard let id = selectedSessionID, !commands.answering.contains(requestID) else { return }
        var c: [String: JSONValue] = ["type": "runtime-request.respond", "threadId": .string(id), "requestId": .string(requestID)]
        let kind: Commands.Kind
        if let answers {
            kind = .answer(thread: id, request: requestID, answers: .object(answers)); c["answers"] = .object(answers)
        } else if let decision {
            kind = .approval(thread: id, request: requestID, decision: decision); c["decision"] = .string(decision)
        } else { log("Request \(requestID) offered no decision; nothing sent"); return }
        await propose(kind, command: c)
    }
    /// Tells the agent it is being watched in Squircle and how to show its
    /// work there: the simulator, screenshots and recordings.
    func squircleInstructions(for project: AppProject, threadID: String) -> String {
        let cli = cliCommand
        return """
        Squircle shows this thread on the user's iPhone. Whenever you run, check or demonstrate the app in a simulator, first run \(cli) sim start --thread \(threadID) (see sim --help): it opens and boots a simulator, records it, and the user watches it live; the recording appears in your turn. Then call device_open with the deviceId it returns, drive it with the agent-device command that gives and use device_screenshot to look; those screenshots appear in the conversation. Run \(cli) sim stop --thread \(threadID) when done. Don't run agent-device record, or device_open on any other simulator. When you make a signed build for the user, include its build job ID in your final reply; Squircle shows it with an Install button. A performance recording the user sends from the app is a linked .perf.json: \(cli) perf show PATH summarizes it (hitches with symbolicated main-thread stacks, timeline); a screen recording is a linked .mp4.
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
        link?.send(.tick(now: .now))
        loadProvidersIfDue()
        let needs = Set(leases.values)
        let apps = needs.compactMap { if case .tasks(let app) = $0 { return app }; return nil }
        let thread = selectedSessionID.flatMap { id in
            needs.contains { if case .conversation(let c) = $0 { return c.threadID == id }; return false } ? id : nil
        }
        let generation = catalogGeneration
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
            if newMetadata != appMetadata, generation == catalogGeneration { appMetadata = newMetadata }
            reconcileProjects()
            if commands.appOrder != nil { command(.appsObserved(order: appMetadata.map(\.id))) }
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
        if let list = demoTasks { return list }
        #endif
        return taskLists.list(app: app, edits: commands.taskEdits)
    }
    /// The newest tasks at once, and History from its first page.
    func refreshTasks() async {
        guard let client, let app = selectedProjectID, let list = try? await client.tasks(projectID: app) else { return }
        adoptTasks(list, for: app, fresh: true)
    }
    /// The next older page of History, after what's loaded.
    func loadMoreHistory(appID app: String) async {
        guard let client, !historyLoads.contains(app) else { return }
        guard let cursor = taskLists.nextPage(app: app) else { return }
        historyLoads.insert(app); defer { historyLoads.remove(app) }
        do {
            let page = try await client.tasks(projectID: app, historyBefore: cursor)
            taskLists.append(page, after: cursor, app: app)
        } catch { self.error = error.localizedDescription }
    }
    private func adoptTasks(_ list: AppTasks, for app: String, fresh: Bool = false) {
        taskLists.adopt(list, for: app, fresh: fresh)
        // An edit the Mac shows is the Mac's now.
        guard commands.entries.contains(where: { if case .task = $0.intent.kind { return true }; return false }) else { return }
        command(.tasksObserved((list.tasks + list.history).map { .init(id: $0.id, status: $0.status, revision: $0.revision) }))
    }
    /// Reads the list of the app `task` is in (the open app's if not known yet).
    private func readTasks(containing task: String) async {
        guard let client else { return }
        let app = taskLists.app(containing: task) ?? selectedProjectID
        if let app, let list = try? await client.tasks(projectID: app) { adoptTasks(list, for: app) }
    }
    /// A status or Top change made here: shown at once, sent once (M04),
    /// and laid over the Mac's tasks until the Mac shows it.
    func markTask(_ task: AppTask, status: AppTask.Status? = nil, toTop: Bool = false) {
        #if DEBUG
        if let demo = demoTasks { demoTasks = TaskLists.apply((task.id, status, toTop), in: demo); return }
        #endif
        guard client != nil else { return }
        taskEditIDs[task.id] = startCommand(.task(id: task.id, status: status, toTop: toTop), command: nil)
    }
    /// Sends the edit `markTask` showed (or makes it now) and waits until the Mac took it.
    func updateTask(_ task: AppTask, status: AppTask.Status? = nil, toTop: Bool = false) async {
        #if DEBUG
        if demoTasks != nil { return }
        #endif
        guard client != nil else { return }
        let pending = taskEditIDs[task.id].flatMap { id in
            (commands.entries.map(\.intent) + commands.queued.values).first { $0.id == id && $0.kind == .task(id: task.id, status: status, toTop: toTop) }
        }
        let id = pending?.id ?? startCommand(.task(id: task.id, status: status, toTop: toTop), command: nil)
        taskEditIDs[task.id] = id
        _ = await settlement(of: id)
        if taskEditIDs[task.id] == id { taskEditIDs[task.id] = nil }
    }
    #if DEBUG
    /// `SQUIRCLE_DEMO_TASKS=1`: made-up tasks kept on the phone, so ticking
    /// through them on a simulator touches nobody's real list.
    private var demoTasks: AppTasks? = SquircleModel.makeDemoTasks() { didSet { changed() } }
    private static func makeDemoTasks() -> AppTasks? {
        guard ProcessInfo.processInfo.environment["SQUIRCLE_DEMO_TASKS"] == "1" else { return nil }
        // Workers on some of them, so the crew shows: (title, state).
        let asks: [(String, String, [(String, String)])] = [
            ("Workers should ask before restarting the service", "needs_you", [("Workers inherit approvals", "needs-you")]),
            ("Stack the sims and fan them out", "in_progress", [("Sim deck", "working")]),
            ("Make the task pills look alive, like agents", "in_progress", [("Jelly crew prototype", "working"), ("Jelly crew doc", "working")]),
            ("Faster cold launch", "in_progress", [("Launch trace", "error"), ("Old profile", "done")]),
            ("Make the send button smaller", "ready_to_try", []), ("Dark mode for the build sheet", "ready_to_try", []),
            ("Swipe back from anywhere in a thread", "queued", []), ("Show the build number on cards", "queued", []),
            ("Pin the newest build to the top", "queued", []), ("Haptic when a turn finishes", "queued", [])]
        let tasks = asks.enumerated().map { index, item in
            let threads = item.2.enumerated().map { ["id": "demo-worker-\(index)-\($0.offset)", "title": $0.element.0, "state": $0.element.1] }
            return ["id": "demo-\(index)", "ask": item.0, "status": item.1, "note": "", "order": Double(index),
                    "updated_at": 0, "threads": threads, "builds": [], "media": []] as [String: Any]
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
        let id = UUID().uuidString.lowercased()
        if case .refused(let reason) = await propose(.project(id: id, root: root),
                                                     command: ["type": "project.create", "projectId": .string(id), "title": .string(record.name), "workspaceRoot": .string(root)]) {
            throw ClientError.backend("T3", 0, reason)
        }
        // HTTP shell gives an immediate authoritative result after the write.
        if let gateway { shell = try await gateway.http.json("/api/orchestration/shell"); consumeShell(["kind": "snapshot", "snapshot": shell]) }
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
                consumeShell(["kind": "snapshot", "snapshot": shell])
            }
            try await ensureOwnProject(record)
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: M01's host

extension SquircleModel: LinkHost {
    func linkWillConnect() async { await homeLoad?.value; homeLoad = nil }
    var shellCursor: Int? { shell["snapshotSequence"].int }
    func linkReceived(shell item: JSONValue) { consumeShell(item, batched: true) }
    func linkReceived(devices value: JSONValue) { consumeDevices(value) }
    func threadCursor(_ id: String) async -> Int? {
        if let load = diskLoad, load.id == id { await load.task.value }
        if diskLoad?.id == id { diskLoad = nil }
        return selectedSessionID == id && state.sequence >= 0 ? state.sequence : nil
    }
    func linkReceived(thread id: String, _ item: JSONValue) {
        guard selectedSessionID == id else { return }
        consumeThread(item)
    }
    func threadExists(_ id: String) -> Bool { shell == .null || sessions.contains { $0.id == id } }
    func linkChanged() { changed() }
    func linkSessionReady(_ session: Link.Session) {
        log("T3 connected")
        loadProvidersIfDue()
        deliver(.sessionReady(attempt: session.attempt)); command(.sessionReady(attempt: session.attempt))
        Task { [weak self] in await self?.ensureScopedProject() }
    }
    func linkSessionLost() {
        log("T3 connection lost"); ConnectionTrace.mark("disconnected")
        deliver(.sessionLost); command(.sessionLost)
    }
    func linkReport(_ report: Link.Report) {
        switch report {
        case .set(let notice):
            if notice == .refused { log("T3 refused this build's session") }
            error = notice.text
        case .clearAny: error = nil
        case .clearAnyUnlessLost: if error != Link.Notice.lost.text { error = nil }
        case .clearLost: if error == Link.Notice.lost.text { error = nil }
        case .clearThread:
            if error == Link.Notice.threadGone.text || error?.hasPrefix(Link.Notice.threadStopped("").text) == true { error = nil }
        }
    }
}
