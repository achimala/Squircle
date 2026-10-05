import Foundation

final class SquircleClient: NSObject, URLSessionTaskDelegate {
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

    func builds() async throws -> [AppBuild] {
        struct Reply: Decodable { let ok: Bool; let data: [AppBuild] }
        let reply: Reply = try await get(["v1", "builds"])
        guard reply.ok else { throw ClientError.response("Squircle") }
        return reply.data
    }

    func fetchAppMetadata() async throws -> [AppMetadata] {
        struct Reply: Decodable { let ok: Bool; let data: [AppMetadata] }
        do {
            let reply: Reply = try await get(["v1", "apps"])
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

    func browseMacProjects(path: String? = nil) async throws -> MacProjectDirectory {
        struct Reply: Decodable { let ok: Bool; let data: MacProjectDirectory }
        let query = path.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        let reply: Reply = try await perform(request(["v1", "projects"], query: query),
                                             service: "Squircle", exposeAPIError: true)
        guard reply.ok else { throw ClientError.response("Squircle") }
        return reply.data
    }

    func inspectMacProject(project: String, scheme: String? = nil, configuration: String? = nil) async throws -> MacProjectInspection {
        struct Reply: Decodable { let ok: Bool; let data: MacProjectInspection }
        var query = [URLQueryItem(name: "project", value: project)]
        if let scheme { query.append(URLQueryItem(name: "scheme", value: scheme)) }
        if let configuration { query.append(URLQueryItem(name: "configuration", value: configuration)) }
        var request = try request(["v1", "projects", "inspect"], query: query)
        request.timeoutInterval = 60 // Allow the host's bounded 45-second Xcode inspection to return its result.
        let reply: Reply = try await perform(request, service: "Squircle", exposeAPIError: true)
        guard reply.ok else { throw ClientError.response("Squircle") }
        return reply.data
    }

    func importMacProject(project: String, scheme: String, name: String, configuration: String? = nil) async throws -> AppMetadata {
        struct Reply: Decodable { let ok: Bool; let data: AppMetadata }
        var body = ["project": project, "scheme": scheme, "name": name]
        if let configuration { body["configuration"] = configuration }
        var request = try request(["v1", "apps", "import"])
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(body)
        let reply: Reply = try await perform(request, service: "Squircle", exposeAPIError: true)
        guard reply.ok else { throw ClientError.response("Squircle") }
        return reply.data
    }

    func startBuild(_ buildRequest: AppBuildRequest) async throws -> AppBuild {
        struct Reply: Decodable {
            struct Result: Decodable { let job: AppBuild }
            let ok: Bool
            let data: Result
        }
        var request = try request(["v1", "builds"])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(buildRequest)
        let reply: Reply = try await perform(request, service: "Squircle")
        guard reply.ok else { throw ClientError.response("Squircle") }
        return reply.data.job
    }
    func installURL(buildID: String) async throws -> URL {
        struct Reply: Decodable { struct Links: Decodable { let page_url: String }; let ok: Bool; let data: Links }
        var request = try request(["v1", "builds", buildID, "install-link"])
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
        var request = try request(path, query: query)
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
        var request = try request(["v1", "diagnostics"])
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

    private func request(_ components: [String], query: [URLQueryItem] = []) throws -> URLRequest {
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
        request.setValue("Bearer \(configuration.squircleToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func get<T: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> T {
        try await perform(request(path, query: query), service: "Squircle")
    }
    private func perform<T: Decodable>(_ request: URLRequest, service: String, exposeAPIError: Bool = false) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            if exposeAPIError, let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode), ![401, 403].contains(response.statusCode),
               let message = backendMessage(data) {
                throw ClientError.backend(service, response.statusCode, message)
            }
            try validate(response, service: service)
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw ClientError.response(service) }
            return decoded
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClientError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw ClientError.connection(service) }
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
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
