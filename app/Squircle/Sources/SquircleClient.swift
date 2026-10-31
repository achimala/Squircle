import Foundation
import os

/// How a model's sessions reach the network. `.offline` never does: every
/// request fails at once as if there were no network and T3's socket never
/// opens. For tests, which must not touch the network.
enum Transport {
    case network, offline

    /// A fresh ephemeral session configuration that goes through this transport.
    func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        if self == .offline { configuration.protocolClasses = [Offline.self] }
        return configuration
    }

    /// Answers every request with "not connected", without opening a socket.
    private final class Offline: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }
}

/// What the Mac's service says changed, on its event stream (`GET /v1/events`).
enum ServiceNotice: Equatable {
    /// The stream is listening: what's fetched from now on misses nothing.
    case ready
    /// `topic`'s reply differs now (for `tasks`, `media` and `log`, the one
    /// for `id`; `media` without an ID: any thread's may).
    case changed(topic: String, id: String?)
}

final class SquircleClient {
    let configuration: AppConfiguration
    private let session: URLSession
    /// The event stream's: it stays open, quiet for as long as nothing changes.
    private let streams: URLSession
    /// The last body and ETag of each list the phone keeps: the service
    /// answers an unchanged one with an empty 304.
    private let validated = OSAllocatedUnfairLock<[URL: (etag: String, data: Data)]>(initialState: [:])

    init(configuration: AppConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.timeoutIntervalForRequest = 45
        sessionConfiguration.timeoutIntervalForResource = 3_600
        let streaming = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? sessionConfiguration
        streaming.timeoutIntervalForRequest = .infinity
        streaming.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: sessionConfiguration, delegate: RefuseRedirects(), delegateQueue: nil)
        streams = URLSession(configuration: streaming, delegate: RefuseRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel(); streams.invalidateAndCancel() }
    /// Cancels everything under way; the client can't be used again.
    func invalidate() { session.invalidateAndCancel(); streams.invalidateAndCancel() }

    /// Holds the service's event stream open and hands each notice to
    /// `receive`, `ready` first. Returns when the service ends it; throws
    /// when it can't be opened or breaks, or when cancelled.
    func events(_ receive: @MainActor (ServiceNotice) async -> Void) async throws {
        try await transport("Squircle") {
            var request = try request(["v1", "events"])
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await streams.bytes(for: request)
            try validate(response, service: "Squircle")
            // Each event is one `data:` line, named by an `event:` line before it.
            var name: Substring?
            for try await line in bytes.lines {
                if line.hasPrefix("event:") {
                    name = line.dropFirst(6).drop { $0 == " " }
                } else if line.hasPrefix("data:") {
                    defer { name = nil }
                    if name == "ready" { await receive(.ready); continue }
                    struct Change: Decodable { let topic: String; let id: String? }
                    guard let change = try? JSONDecoder().decode(Change.self, from: Data(line.utf8.dropFirst(5))) else { continue }
                    await receive(.changed(topic: change.topic, id: change.id))
                }
            }
        }
    }

    func builds() async throws -> [AppBuild] {
        try await get(["v1", "builds"], revalidate: true)
    }

    func build(id: String) async throws -> (AppBuild, BuildFailure?) {
        struct Reply: Decodable { let job: AppBuild; let failure: BuildFailure? }
        let reply: Reply = try await get(["v1", "builds", id])
        return (reply.job, reply.failure)
    }

    func buildLog(id: String, offset: Int, limit: Int) async throws -> BuildLogPage {
        try await get(["v1", "builds", id, "log"], query: [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))
        ])
    }

    func fetchAppMetadata() async throws -> [AppMetadata] {
        do {
            return try await get(["v1", "apps"], revalidate: true)
        } catch let error as ClientError where error.isMissing {
            return [] // Older Squircle servers have no persistent app registry.
        }
    }

    func fetchAppPreview(id: String, previewID: String? = nil) async throws -> Data {
        let query = previewID.map { [URLQueryItem(name: "version", value: $0)] } ?? []
        return try await fetchPNG(["v1", "apps", id, "preview"], query: query)
    }

    func browseMacProjects(path: String? = nil) async throws -> MacProjectDirectory {
        let query = path.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        return try await call(request(["v1", "projects"], query: query), exposeAPIError: true)
    }

    func inspectMacProject(project: String, scheme: String? = nil, configuration: String? = nil) async throws -> MacProjectInspection {
        var query = [URLQueryItem(name: "project", value: project)]
        if let scheme { query.append(URLQueryItem(name: "scheme", value: scheme)) }
        if let configuration { query.append(URLQueryItem(name: "configuration", value: configuration)) }
        var request = try request(["v1", "projects", "inspect"], query: query)
        request.timeoutInterval = 60 // Allow the host's bounded 45-second Xcode inspection to return its result.
        return try await call(request, exposeAPIError: true)
    }

    func importMacProject(project: String, scheme: String, name: String, configuration: String? = nil) async throws -> AppMetadata {
        var body = ["project": project, "scheme": scheme, "name": name]
        if let configuration { body["configuration"] = configuration }
        var request = try request(["v1", "apps", "import"], method: "POST", body: JSONEncoder().encode(body))
        request.timeoutInterval = 60
        return try await call(request, exposeAPIError: true)
    }

    /// Home's order of the catalog's records; the reply is the catalog in it.
    func orderApps(_ ids: [String]) async throws -> [AppMetadata] {
        try await call(request(["v1", "apps", "order"], method: "PUT", body: JSONEncoder().encode(["ids": ids])), exposeAPIError: true)
    }

    /// Each app's agent thread on the Mac, and how to run its CLI.
    func agents() async throws -> AgentDirectory {
        do {
            return try AgentDirectory.decode(try await perform(request(["v1", "agents"]), revalidate: true))
        } catch let error as ClientError where error.isMissing {
            return AgentDirectory() // An older Squircle service has no app agents.
        }
    }

    /// Restarts an app agent's session on its thread.
    func restartAgent(projectID: String) async throws {
        var request = try request(["v1", "agents", "restart"], method: "POST",
                                  body: JSONEncoder().encode(["project_id": projectID]))
        request.timeoutInterval = 60
        try await send(request)
    }

    /// Starts (or finds) an app's agent on the Mac and gives it a message.
    /// Returns its T3 thread ID.
    /// A new agent starts in `mode`; an existing one keeps its own.
    func startAgent(projectID: String, message: String, model: String?, mode: T3RuntimeMode) async throws -> String {
        struct Reply: Decodable { struct Agent: Decodable { let thread_id: String }; let agent: Agent }
        var body = ["project_id": projectID, "message": message, "runtime_mode": mode.rawValue]
        if let model { body["model"] = model }
        var request = try request(["v1", "agents"], method: "POST", body: JSONEncoder().encode(body))
        request.timeoutInterval = 60
        let reply: Reply = try await call(request, exposeAPIError: true)
        return reply.agent.thread_id
    }

    func startBuild(_ buildRequest: AppBuildRequest) async throws -> AppBuild {
        struct Reply: Decodable { let job: AppBuild }
        let reply: Reply = try await call(request(["v1", "builds"], method: "POST", body: JSONEncoder().encode(buildRequest)))
        return reply.job
    }
    /// The `itms-services` link itself, so iOS shows its install prompt over
    /// Squircle instead of detouring through the Mac's install page in Safari.
    func installURL(buildID: String) async throws -> URL {
        struct Links: Decodable { let install_url: String }
        let links: Links = try await call(request(["v1", "builds", buildID, "install-link"], method: "POST",
                                                  body: Data("{\"ttl_seconds\":3600}".utf8)))
        guard let url = URL(string: links.install_url), url.scheme == "itms-services",
              let manifest = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)),
              manifest.scheme == "https", manifest.host == configuration.squircleURL.host,
              manifest.port == configuration.squircleURL.port, manifest.user == nil, manifest.password == nil
        else { throw ClientError.response("Squircle") }
        return url
    }

    /// How far iOS has fetched the link's IPA. It starts only after the
    /// person taps Install in the system prompt; neither step proves the
    /// installation itself.
    func installProgress(link: URL) async throws -> InstallProgress {
        struct Status: Decodable { let download_started_at: Double?; let downloaded_at: Double? }
        guard let manifest = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)) else { throw ClientError.response("Squircle") }
        let token = manifest.deletingLastPathComponent().lastPathComponent
        let status: Status = try await get(["v1", "install-links", token])
        return status.downloaded_at != nil ? .transferred : status.download_started_at != nil ? .downloading : .waiting
    }

    /// Tool-call details, and every worker Squircle started.
    /// `workers` is nil from a service older than the step history.
    func threadSteps(threadID: String, since: String?) async throws -> (steps: [JSONValue], workers: [JSONValue]?) {
        let data: JSONValue = try await get(["v1", "t3", "threads", threadID, "steps"],
                                            query: since.map { [URLQueryItem(name: "since", value: $0)] } ?? [])
        return (data["steps"].array, data["workers"] == .null ? nil : data["workers"].array)
    }

    func stepImage(threadID: String, callID: String, index: Int) async throws -> Data {
        try await base64(get(["v1", "t3", "threads", threadID, "steps", callID, "images", String(index)]))
    }

    /// The newest real screenshot an agent captured in a T3 project's threads.
    func projectScreenshot(projectID: String) async throws -> Data {
        try await base64(get(["v1", "t3", "projects", projectID, "screenshot"]))
    }

    /// Recordings and images agents published into a thread.
    func threadMedia(threadID: String) async throws -> [JSONValue] {
        let data: JSONValue = try await get(["v1", "t3", "threads", threadID, "media"], revalidate: true)
        return data["media"].array
    }

    /// T3's providers and models, trimmed by the service: T3's own config is
    /// about 1 MB, nearly all of it per-folder catalogs the phone never shows.
    func providers() async throws -> JSONValue {
        try await get(["v1", "t3", "providers"])
    }

    /// Simulator sessions Squircle is recording for agents (`squircle sim`).
    func simulatorSessions() async throws -> [JSONValue] {
        let data: JSONValue = try await get(["v1", "sims"], revalidate: true)
        return data["active"].array
    }

    /// Active tasks and History's newest page, or with `historyBefore` (a
    /// previous page's `historyNext`) the next older page.
    func tasks(projectID: String, historyBefore: String? = nil) async throws -> AppTasks {
        var query = [URLQueryItem(name: "project", value: projectID)]
        if let historyBefore { query.append(URLQueryItem(name: "history_before", value: historyBefore)) }
        return try await get(["v1", "tasks"], query: query, revalidate: historyBefore == nil)
    }

    /// The user's own change: a status, or first in its group. Returns the
    /// task's revision that holds it (nil from an older service).
    func updateTask(id: String, status: AppTask.Status?, toTop: Bool) async throws -> UInt64? {
        var body: [String: Any] = ["by_user": true, "to_top": toTop]
        if let status { body["status"] = status.rawValue }
        struct Reply: Decodable { struct Task: Decodable { let revision: UInt64? }; let task: Task? }
        let reply: Reply? = try await envelope(request(["v1", "tasks", id], method: "PATCH",
                                                       body: JSONSerialization.data(withJSONObject: body)), exposeAPIError: true)
        return reply?.task?.revision
    }

    /// Everything waiting on you, across apps.
    func waiting() async throws -> WaitingList {
        try await get(["v1", "waiting"], revalidate: true)
    }

    /// Your answer to a question in the tracker; it goes to the thread that asked.
    func answerQuestion(id: String, text: String) async throws {
        try await send(request(["v1", "questions", id, "answer"], method: "POST",
                               body: JSONSerialization.data(withJSONObject: ["text": text])))
    }

    /// Your answer to a thread's own question (`answers`) or approval
    /// (`decision`), straight to that thread; its app agent is told.
    func respond(threadID: String, requestID: String, decision: String?, answers: JSONValue?) async throws {
        var body: [String: JSONValue] = ["thread_id": .string(threadID), "request_id": .string(requestID)]
        if let decision { body["decision"] = .string(decision) }
        if let answers { body["answers"] = answers }
        try await send(request(["v1", "waiting", "respond"], method: "POST", body: JSONEncoder().encode(JSONValue.object(body))))
    }

    func taskMediaFile(taskID: String, id: String) async throws -> Data {
        try await bytes(request(["v1", "tasks", taskID, "media", id]))
    }

    /// A task's clip, streamed to a file on disk and moved to `destination`.
    func downloadTaskMedia(taskID: String, id: String, to destination: URL) async throws {
        try await download(request(["v1", "tasks", taskID, "media", id]), to: destination)
    }

    func mediaFile(threadID: String, id: String) async throws -> Data {
        try await bytes(request(["v1", "t3", "threads", threadID, "media", id]))
    }

    /// A published recording, streamed to a file on disk and moved to
    /// `destination`: a long one is hundreds of megabytes, never held in memory.
    func downloadMedia(threadID: String, id: String, to destination: URL) async throws {
        try await download(request(["v1", "t3", "threads", threadID, "media", id]), to: destination)
    }

    private func download(_ request: URLRequest, to destination: URL) async throws {
        try await transport("Squircle") {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            try validate(response, service: "Squircle")
            try MediaFileStore.move(file, to: destination)
        }
    }

    /// A simulator recording's poster (a small JPEG), when Squircle took one.
    func mediaPoster(threadID: String, id: String) async throws -> Data {
        try await bytes(request(["v1", "t3", "threads", threadID, "media", id, "poster"]))
    }

    private func fetchPNG(_ path: [String], query: [URLQueryItem] = []) async throws -> Data {
        var request = try request(path, query: query)
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        return try await transport("Squircle") {
            let (data, response) = try await session.data(for: request)
            try validate(response, service: "Squircle")
            guard response.mimeType?.lowercased() == "image/png",
                  data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw ClientError.response("Squircle")
            }
            return data
        }
    }

    /// Puts a recording made in the app on the Mac; returns its path there.
    func uploadCapture(_ file: URL, kind: String) async throws -> String {
        var request = try request(["v1", "captures"], query: [URLQueryItem(name: "kind", value: kind)], method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        struct Reply: Decodable { let path: String }
        return try await transport("Squircle") {
            let (data, response) = try await session.upload(for: request, fromFile: file)
            try validate(response, service: "Squircle")
            guard let reply = try? JSONDecoder().decode(Envelope<Reply>.self, from: data), reply.ok, let path = reply.data?.path
            else { throw ClientError.response("Squircle") }
            return path
        }
    }

    func reportLaunch(buildID: String, eventID: String, timestamp: Int) async throws {
        guard UUID(uuidString: buildID) != nil else { return }
        var request = try request(["v1", "diagnostics"], method: "POST", body: JSONSerialization.data(withJSONObject: [
            "event_id": eventID, "build_id": buildID.lowercased(), "kind": "launch",
            "message": "Squircle opened", "timestamp": timestamp,
            "attributes": ["bundle_id": Bundle.main.bundleIdentifier ?? "", "client": "squircle-ios"]
        ]))
        request.setValue("Bearer \(configuration.diagnosticToken)", forHTTPHeaderField: "Authorization")
        try await send(request, service: "Squircle diagnostics", exposeAPIError: false)
    }

    /// Notifications: this phone's tokens, its Live Activities and what it shows.
    /// The Mac decides what to send and how it reaches Apple.
    func push(_ endpoint: String, _ body: [String: Any]) async throws {
        try await send(request(["v1", "push", endpoint], method: "POST", body: JSONSerialization.data(withJSONObject: body)))
    }

    private func request(_ components: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) throws -> URLRequest {
        var url = configuration.squircleURL
        for component in components {
            guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else {
                throw ClientError.response("Squircle")
            }
            url.appendPathComponent(component)
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ClientError.configuration }
        if !query.isEmpty { parts.queryItems = query }
        guard let endpoint = parts.url else { throw ClientError.configuration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(configuration.squircleToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Every service reply: `{"ok": true, "data": …}`.
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let data: T? }

    /// `revalidate`: for lists fetched again on each change notice; an
    /// unchanged one costs no body.
    private func get<T: Decodable>(_ path: [String], query: [URLQueryItem] = [], revalidate: Bool = false) async throws -> T {
        try await call(request(path, query: query), revalidate: revalidate)
    }
    /// A reply's `data`, which must be there.
    private func call<T: Decodable>(_ request: URLRequest, exposeAPIError: Bool = false, revalidate: Bool = false) async throws -> T {
        guard let data: T = try await envelope(request, exposeAPIError: exposeAPIError, revalidate: revalidate) else {
            throw ClientError.response("Squircle")
        }
        return data
    }
    /// A request whose reply carries nothing but `ok`.
    private func send(_ request: URLRequest, service: String = "Squircle", exposeAPIError: Bool = true) async throws {
        let _: JSONValue? = try await envelope(request, service: service, exposeAPIError: exposeAPIError)
    }
    private func envelope<T: Decodable>(_ request: URLRequest, service: String = "Squircle", exposeAPIError: Bool = false,
                                        revalidate: Bool = false) async throws -> T? {
        let reply: Envelope<T> = try await perform(request, service: service, exposeAPIError: exposeAPIError, revalidate: revalidate)
        guard reply.ok else { throw ClientError.response(service) }
        return reply.data
    }
    private func base64(_ reply: JSONValue) throws -> Data {
        guard let data = reply["data"].string.flatMap({ Data(base64Encoded: $0) }) else { throw ClientError.response("Squircle") }
        return data
    }
    private func bytes(_ request: URLRequest) async throws -> Data {
        try await transport("Squircle") {
            let (data, response) = try await session.data(for: request)
            trace(request, response)
            try validate(response, service: "Squircle")
            return data
        }
    }
    /// Network work with one meaning for failure: cancelled, the service's
    /// own error, or the service couldn't be reached.
    private func transport<T>(_ service: String, _ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ClientError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw ClientError.connection(service) }
    }
    private func perform<T: Decodable>(_ request: URLRequest, service: String = "Squircle", exposeAPIError: Bool = false,
                                       revalidate: Bool = false) async throws -> T {
        try await transport(service) {
            var request = request
            let url = request.url
            let known = revalidate ? url.flatMap { url in validated.withLock { $0[url] } } : nil
            if let known { request.setValue(known.etag, forHTTPHeaderField: "If-None-Match") }
            var (data, response) = try await session.data(for: request)
            trace(request, response)
            if let http = response as? HTTPURLResponse, let url, revalidate {
                if http.statusCode == 304, let known {
                    data = known.data
                    response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) ?? response
                } else if http.statusCode == 200, let etag = http.value(forHTTPHeaderField: "ETag") {
                    let fresh = data
                    validated.withLock { $0[url] = (etag, fresh) }
                }
            }
            if exposeAPIError, let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode), ![401, 403].contains(response.statusCode),
               let message = backendMessage(data) {
                throw ClientError.backend(service, response.statusCode, message)
            }
            try validate(response, service: service)
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw ClientError.response(service) }
            return decoded
        }
    }
    /// Each request and its status, in a `SQUIRCLE_PERF=1` connection trace.
    private func trace(_ request: URLRequest, _ response: URLResponse) {
        let line = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "") \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        Task { @MainActor in ConnectionTrace.mark("http", line) }
    }
    private func backendMessage(_ data: Data) -> String? {
        struct Failure: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
        guard data.count <= 65_536, let failure = try? JSONDecoder().decode(Failure.self, from: data) else { return nil }
        var message = failure.error.message
        for token in [configuration.squircleToken, configuration.diagnosticToken].sorted(by: { $0.count > $1.count }) {
            message = message.replacingOccurrences(of: token, with: "[redacted]")
        }
        message = String(message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : String(message.prefix(1_000))
    }
    private func validate(_ response: URLResponse, service: String) throws {
        guard let response = response as? HTTPURLResponse else { throw ClientError.response(service) }
        guard (200..<300).contains(response.statusCode) else { throw ClientError.http(service, response.statusCode) }
    }
}

enum InstallProgress: Equatable {
    /// The person hasn't confirmed the system prompt yet.
    case waiting
    /// iOS asked for the IPA.
    case downloading
    /// The Mac sent every byte of it.
    case transferred
}

/// `GET /v1/agents`: each app's agent thread by T3 project ID, and the exact
/// command that runs this service's CLI (nil from an older service).
struct AgentDirectory: Equatable {
    var agents: [String: String] = [:]
    var cli: String?
    static func decode(_ reply: JSONValue) throws -> Self {
        guard reply["ok"].bool else { throw ClientError.response("Squircle") }
        let data = reply["data"]
        var agents: [String: String] = [:]
        for agent in data["agents"].array {
            guard let project = agent["project_id"].string, let thread = agent["thread_id"].string else { continue }
            agents[project] = thread
        }
        let cli = data["cli"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(agents: agents, cli: cli?.isEmpty == false ? cli : nil)
    }
}
