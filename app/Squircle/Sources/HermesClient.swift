import Foundation

struct ChatSession: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let preview: String
    let updatedAt: Date
    let messageCount: Int

    init(id: String, title: String, preview: String = "", updatedAt: Date = .now, messageCount: Int = 0) {
        self.id = id; self.title = title; self.preview = preview
        self.updatedAt = updatedAt; self.messageCount = messageCount
    }

    enum CodingKeys: String, CodingKey { case id, title, preview, lastActive = "last_active", startedAt = "started_at", messageCount = "message_count" }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let name = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New conversation" : name
        preview = try values.decodeIfPresent(String.self, forKey: .preview) ?? ""
        let time = try values.decodeIfPresent(Double.self, forKey: .lastActive)
            ?? values.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        updatedAt = Date(timeIntervalSince1970: time)
        messageCount = try values.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    var content: String
    var isStreaming = false
    var tools: [String] = []
}

struct AppBuild: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let version: String
    let status: String
    let date: Date
    let canInstall: Bool
    let bundleID: String?
    let request: AppBuildRequest?
    let previewAvailable: Bool
    let previewState: String?
    let previewError: String?
    let previewCapturedAt: Date?

    var needsPolling: Bool {
        status == "queued" || status == "running" || previewState == "pending" || previewState == "running"
    }

    enum CodingKeys: String, CodingKey { case id, state, output, createdAt = "created_at", request }
    private struct Output: Decodable {
        let title: String?
        let version: String?
        let build_number: String?
        let ipa_path: String?
        let bundle_id: String?
        let preview_path: String?
        let preview_state: String?
        let preview_error: String?
        let preview_captured_at: Double?
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .state)
        let output = try values.decodeIfPresent(Output.self, forKey: .output)
        request = try values.decodeIfPresent(AppBuildRequest.self, forKey: .request)
        title = output?.title ?? request?.scheme ?? "App build"
        bundleID = output?.bundle_id
        version = [output?.version, output?.build_number.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        canInstall = status == "succeeded" && output?.ipa_path != nil
        previewState = output?.preview_state
        previewError = output?.preview_error
        previewCapturedAt = output?.preview_captured_at.map { Date(timeIntervalSince1970: $0) }
        previewAvailable = !(output?.preview_path ?? "").isEmpty && (previewState == nil || previewState == "succeeded")
        date = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .createdAt))
    }
}

struct AgentApproval: Identifiable, Equatable {
    let id: String
    let runID: String
    let prompt: String
    let command: String
    let choices: [String]
}

/// JSON content can be text or multimodal blocks. Reasoning fields are never projected.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
    var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var text: String {
        if let string { return string }
        return array.compactMap { block in
            let block = block.object
            guard ["text", "input_text", "output_text"].contains(block["type"]?.string ?? "") else { return nil }
            return block["text"]?.string
        }.joined(separator: "\n")
    }
    var identifier: String? {
        if let string { return string }
        if case .number(let number) = self { return String(format: "%.0f", number) }
        return nil
    }
}

struct MessagePage: Decodable {
    let session_id: String
    let data: [WireMessage]
    struct WireMessage: Decodable {
        let id: JSONValue?
        let role: String
        let content: JSONValue?
        let tool_name: String?
        let tool_calls: [JSONValue]?

        func projected(index: Int) -> ChatMessage? {
            guard role == "user" || role == "assistant" || role == "tool" else { return nil }
            let names = tool_calls?.compactMap { $0.object["function"]?.object["name"]?.string } ?? []
            let text = role == "tool" ? "" : content?.text ?? ""
            let tools = role == "tool" ? [tool_name ?? "Tool"] : names
            guard !text.isEmpty || !tools.isEmpty else { return nil }
            return ChatMessage(id: id?.identifier ?? "history-\(index)", role: role, content: text, tools: tools)
        }
    }
    var messages: [ChatMessage] { data.enumerated().compactMap { $0.element.projected(index: $0.offset) } }
}

struct RunStatus: Decodable {
    let run_id: String
    let status: String
    let session_id: String?
    let output: String?
    let approval: RunEvent?
    var terminal: Bool { ["completed", "failed", "cancelled", "interrupted"].contains(status) }
}

struct RunEvent: Decodable {
    let event: String?
    let run_id: String?
    let seq: Int?
    let delta: String?
    let text: String?
    let tool: String?
    let preview: String?
    let output: String?
    let request_id: String?
    let description: String?
    let command: String?
    let choices: [String]?
    let already_streamed: Bool?

    func approval(runID: String) -> AgentApproval? {
        guard let request_id, !request_id.isEmpty else { return nil }
        return AgentApproval(id: request_id, runID: runID,
                             prompt: description ?? "Hermes needs your approval to continue.",
                             command: command ?? "", choices: choices ?? ["once", "deny"])
    }
}

struct SSEFrame: Equatable {
    let id: String?
    let data: String
}

/// Parse framing independently of event payloads; comments and empty events are ignored.
struct SSEParser {
    private var data: [String] = []
    private var id: String?
    private var bytes = 0
    mutating func line(_ rawLine: String) throws -> SSEFrame? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { data = []; id = nil; bytes = 0 }
            return data.isEmpty ? nil : SSEFrame(id: id, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        bytes += line.utf8.count
        guard bytes <= 1_048_576 else { throw ClientError.response("Hermes") }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if parts[0] == "data" { data.append(value) }
        if parts[0] == "id", !value.contains("\0") { id = value }
        return nil
    }
}

/// A separate ephemeral session prevents web cookies, cached credentials, or redirects
/// from moving the bundled credentials away from their configured origins.
final class HermesClient: NSObject, URLSessionTaskDelegate {
    let configuration: AppConfiguration
    private var session: URLSession!

    init(configuration: AppConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.timeoutIntervalForRequest = 45
        sessionConfiguration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
    }

    func sessions() async throws -> [ChatSession] {
        struct Page: Decodable { let data: [ChatSession] }
        let page: Page = try await get(["api", "sessions"], query: [URLQueryItem(name: "limit", value: "200")])
        return page.data
    }

    func createSession(title: String? = nil) async throws -> ChatSession {
        struct Reply: Decodable { let session: ChatSession }
        var body = ["source": "api_server"]
        if let title, !title.isEmpty { body["title"] = title }
        let reply: Reply = try await post(["api", "sessions"], body: body)
        return reply.session
    }

    func messages(sessionID: String) async throws -> MessagePage {
        try await get(["api", "sessions", sessionID, "messages"],
                      query: [URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "order", value: "latest")])
    }

    func renameSession(_ id: String, title: String) async throws -> ChatSession {
        struct Reply: Decodable { let session: ChatSession }
        var request = try request(["api", "sessions", id])
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(["title": title])
        let reply: Reply = try await perform(request, service: "Hermes")
        return reply.session
    }

    func startRun(sessionID: String, text: String, idempotencyKey: String, projectContext: String? = nil) async throws -> String {
        struct Reply: Decodable { let run_id: String }
        var body = ["session_id": sessionID, "input": text]
        let instructions = [configuration.agentInstructions, projectContext].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !instructions.isEmpty { body["instructions"] = instructions }
        let reply: Reply = try await post(["v1", "runs"], body: body, idempotencyKey: idempotencyKey)
        return reply.run_id
    }

    func run(_ id: String) async throws -> RunStatus { try await get(["v1", "runs", id]) }
    func stop(_ id: String) async throws {
        let _: JSONValue = try await post(["v1", "runs", id, "stop"], body: [:])
    }
    func resolve(_ approval: AgentApproval, approved: Bool) async throws {
        let choice = approved ? "once" : "deny"
        guard approval.choices.contains(choice) else { throw ClientError.response("Hermes approval") }
        let _: JSONValue = try await post(["v1", "runs", approval.runID, "approval"],
                                         body: ["request_id": approval.id, "choice": choice])
    }

    func builds() async throws -> [AppBuild] {
        struct Reply: Decodable { let ok: Bool; let data: [AppBuild] }
        let reply: Reply = try await get(["v1", "builds"], squircle: true)
        guard reply.ok else { throw ClientError.response("Squircle") }
        return reply.data
    }

    func fetchAppMetadata() async throws -> [AppMetadata] {
        struct Reply: Decodable { let ok: Bool; let data: [AppMetadata] }
        do {
            let reply: Reply = try await get(["v1", "apps"], squircle: true)
            guard reply.ok else { throw ClientError.response("Squircle") }
            return reply.data
        } catch let error as ClientError where error.isMissing {
            return [] // Older Squircle servers have no persistent app registry.
        }
    }

    func fetchAppPreview(id: String, previewID: String? = nil) async throws -> Data {
        let query = previewID.map { [URLQueryItem(name: "version", value: $0)] } ?? []
        return try await fetchPNG(["v1", "apps", id, "preview"], query: query)
    }
    func startBuild(_ buildRequest: AppBuildRequest) async throws -> AppBuild {
        struct Reply: Decodable {
            struct Result: Decodable { let job: AppBuild }
            let ok: Bool
            let data: Result
        }
        var request = try request(["v1", "builds"], squircle: true)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(buildRequest)
        let reply: Reply = try await perform(request, service: "Squircle")
        guard reply.ok else { throw ClientError.response("Squircle") }
        return reply.data.job
    }
    func installURL(buildID: String) async throws -> URL {
        struct Reply: Decodable { struct Links: Decodable { let page_url: String }; let ok: Bool; let data: Links }
        var request = try request(["v1", "builds", buildID, "install-link"], squircle: true)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"ttl_seconds\":3600}".utf8)
        let reply: Reply = try await perform(request, service: "Squircle")
        guard reply.ok, let url = URL(string: reply.data.page_url), url.scheme == "https",
              url.host == configuration.squircleURL.host, url.port == configuration.squircleURL.port,
              url.user == nil, url.password == nil else { throw ClientError.response("Squircle") }
        return url
    }

    func fetchBuildPreview(id: String) async throws -> Data {
        try await fetchPNG(["v1", "builds", id, "preview"])
    }

    private func fetchPNG(_ path: [String], query: [URLQueryItem] = []) async throws -> Data {
        var request = try request(path, squircle: true, query: query)
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, service: "Squircle")
            guard response.mimeType?.lowercased() == "image/png",
                  data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw ClientError.response("Squircle")
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClientError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw ClientError.connection("Squircle") }
    }

    func reportLaunch(buildID: String, eventID: String, timestamp: Int) async throws {
        guard UUID(uuidString: buildID) != nil else { return }
        var request = try request(["v1", "diagnostics"], squircle: true)
        request.setValue("Bearer \(configuration.diagnosticToken)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "event_id": eventID, "build_id": buildID.lowercased(), "kind": "launch",
            "message": "Squircle opened", "timestamp": timestamp,
            "attributes": ["bundle_id": Bundle.main.bundleIdentifier ?? "", "client": "squircle-ios"]
        ])
        struct Reply: Decodable { let ok: Bool }
        let reply: Reply = try await perform(request, service: "Squircle diagnostics")
        guard reply.ok else { throw ClientError.response("Squircle diagnostics") }
    }

    func events(runID: String, after: Int?, receive: @escaping (RunEvent) async -> Void) async throws {
        var request = try request(["v1", "runs", runID, "events"])
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let after { request.setValue(String(after), forHTTPHeaderField: "Last-Event-ID") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response, service: "Hermes")
            guard let http = response as? HTTPURLResponse,
                  http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
                throw ClientError.response("Hermes")
            }
            var parser = SSEParser()
            var line = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                if byte == 10 {
                    guard let text = String(data: line, encoding: .utf8) else { throw ClientError.response("Hermes") }
                    line.removeAll(keepingCapacity: true)
                    if let frame = try parser.line(text) {
                        guard frame.data != "[DONE]" else { return }
                        guard let event = try? JSONDecoder().decode(RunEvent.self, from: Data(frame.data.utf8)) else {
                            throw ClientError.response("Hermes")
                        }
                        await receive(event)
                    }
                } else {
                    line.append(byte)
                    guard line.count <= 1_048_576 else { throw ClientError.response("Hermes") }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClientError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw ClientError.connection("Hermes") }
    }

    private func request(_ components: [String], squircle: Bool = false, query: [URLQueryItem] = []) throws -> URLRequest {
        var url = squircle ? configuration.squircleURL : configuration.hermesURL
        for component in components {
            guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else {
                throw ClientError.response(squircle ? "Squircle" : "Hermes")
            }
            url.appendPathComponent(component)
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ClientError.configuration }
        if !query.isEmpty { parts.queryItems = query }
        guard let endpoint = parts.url else { throw ClientError.configuration }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(squircle ? configuration.squircleToken : configuration.hermesToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func get<T: Decodable>(_ path: [String], squircle: Bool = false, query: [URLQueryItem] = []) async throws -> T {
        try await perform(request(path, squircle: squircle, query: query), service: squircle ? "Squircle" : "Hermes")
    }
    private func post<T: Decodable>(_ path: [String], body: [String: String], idempotencyKey: String? = nil) async throws -> T {
        var request = try request(path)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        return try await perform(request, service: "Hermes")
    }
    private func perform<T: Decodable>(_ request: URLRequest, service: String) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, service: service)
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw ClientError.response(service) }
            return decoded
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClientError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw ClientError.connection(service) }
    }
    private func validate(_ response: URLResponse, service: String) throws {
        guard let response = response as? HTTPURLResponse else { throw ClientError.response(service) }
        guard (200..<300).contains(response.statusCode) else { throw ClientError.http(service, response.statusCode) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
