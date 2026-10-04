import Foundation
import Security

/// Stock hermes serve /api/ws protocol. No agent runtime or CLI interception.
@MainActor
final class HermesGateway {
    private let configuration: AppConfiguration
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var connecting: Task<Void, Error>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var ready = false
    private var credentials: JSONValue = .null
    private var serial = 0
    private var receivedSequences: [String: Int] = [:]
    private var receivedOrder = 0
    private(set) var generation = UUID()
    var onEvent: ((JSONValue) -> Void)?
    var onRequest: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 86_400
        c.httpShouldSetCookies = false
        session = URLSession(configuration: c)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ai.dreamslate.Squircle.hermes", kSecAttrAccount as String: configuration.desktopURL?.absoluteString ?? "", kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            credentials = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        }
    }

    func connect() async throws {
        if ready { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await open() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func open() async throws {
        guard let origin = configuration.desktopURL, let initialToken = configuration.desktopToken,
              var url = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { throw ClientError.configuration }
        let token = try await accessToken(fallback: initialToken)
        url.scheme = "wss"; url.path = "/api/ws"
        url.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let endpoint = url.url else { throw ClientError.configuration }
        generation = UUID()
        receivedSequences.removeAll()
        let socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 32 * 1024 * 1024
        self.socket = socket
        socket.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    // Hermes may coalesce newline-delimited JSON-RPC frames.
                    for line in data.split(separator: 10) where !line.isEmpty {
                        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line))
                        self?.receive(frame)
                    }
                }
            } catch { self?.disconnected(socket) }
        }
        do {
            // A round-trip also proves the authenticated upgrade succeeded.
            _ = try await callConnected("client.capabilities", ["server_requests": .bool(true)])
            ready = true
        } catch { disconnected(socket); throw error }
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await connect()
        return try await callConnected(method, params)
    }

    private func callConnected(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        serial += 1
        let id = "ios-\(serial)"
        var params = params
        // Only scoped methods accept profile; control/ping capabilities have closed contracts.
        if method.hasPrefix("session.") || method.hasPrefix("prompt.") || method.hasPrefix("slash.") || method == "command.dispatch" {
            params["profile"] = .string(configuration.hermesProfile)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { [weak self] in
                    do {
                        try await self?.write(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)]))
                    } catch { self?.fail(id, error) }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    self?.fail(id, ClientError.backend("Hermes", 408, "Hermes did not acknowledge the request. Reconnect before retrying a message."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(id, CancellationError()) }
        }
    }

    func answer(id: String, result: JSONValue) async throws {
        // Do not reconnect and send a stale answer to another server generation.
        guard ready else { throw ClientError.connection("Hermes") }
        try await write(.object(["jsonrpc": .string("2.0"), "id": .string(id), "result": result]))
    }

    func decline(id: String, code: Int = -32601, message: String) async throws {
        try await write(.object(["jsonrpc": .string("2.0"), "id": .string(id),
                                 "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    private func write(_ value: JSONValue) async throws {
        guard let socket else { throw ClientError.connection("Hermes") }
        let data = try JSONEncoder().encode(value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ frame: JSONValue) {
        if let method = frame["method"].string {
            if method == "event" {
                receivedOrder += 1
                var payload = frame["params"].object
                payload["_client_order"] = .number(Double(receivedOrder))
                let event = JSONValue.object(payload)
                if let sid = event["session_id"].string, let seq = event["seq"].int { receivedSequences[sid] = seq }
                onEvent?(event)
            }
            else if frame["id"].identifier != nil { onRequest?(frame) }
            return
        }
        guard let id = frame["id"].identifier, let continuation = pending.removeValue(forKey: id) else { return }
        if frame["error"] != .null {
            let text = frame["error"]["message"].string ?? "Hermes rejected the request."
            continuation.resume(throwing: ClientError.backend("Hermes", frame["error"]["code"].int ?? 0, redact(text)))
        } else {
            var result = frame["result"]
            if let sid = result["session_id"].string, result["messages"] != .null {
                var snapshot = result.object
                snapshot["_client_order"] = .number(Double(receivedOrder))
                snapshot["_client_received_seq"] = .number(Double(receivedSequences[sid] ?? 0))
                result = .object(snapshot)
            }
            continuation.resume(returning: result)
        }
    }

    private func fail(_ id: String, _ error: Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }
    private func disconnected(_ task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        ready = false; socket = nil
        task.cancel(with: .goingAway, reason: nil)
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: ClientError.connection("Hermes")) }
        onDisconnect?()
    }
    /// Desktop's REST transcript retains tool bodies that its compact WS history omits.
    func transcript(_ storedID: String) async throws -> [JSONValue] {
        guard let origin = configuration.desktopURL, let fallback = configuration.desktopToken else { throw ClientError.configuration }
        var rows: [JSONValue] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            var components = URLComponents(url: origin.appendingPathComponent("api/sessions").appendingPathComponent(storedID).appendingPathComponent("messages"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "profile", value: configuration.hermesProfile), URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "order", value: "oldest")]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer " + (try await accessToken(fallback: fallback)), forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ClientError.http("Hermes history", (response as? HTTPURLResponse)?.statusCode ?? 0) }
            let result = try JSONDecoder().decode(JSONValue.self, from: data)
            let page = result["messages"].array
            rows += page
            if page.count < 500 { return rows }
            offset += page.count
        }
    }

    /// Stock FileResponse supports byte ranges, so a live trace refresh reads only new bytes.
    func traceChunk(_ path: String, sessionID: String, offset: Int) async throws -> (Data, Bool) {
        guard let origin = configuration.desktopURL, let fallback = configuration.desktopToken else { throw ClientError.configuration }
        var url = URLComponents(url: origin.appendingPathComponent("api/fs/download"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "profile", value: configuration.hermesProfile), URLQueryItem(name: "session_id", value: sessionID)]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + (try await accessToken(fallback: fallback)), forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(offset + 1024 * 1024 - 1)", forHTTPHeaderField: "Range")
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw ClientError.response("Claude activity") }
        if http.statusCode == 416 {
            if let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int($0) }), total < offset {
                throw ClientError.response("Trace was replaced or truncated; reopen activity")
            }
            return (Data(), true)
        }
        guard http.statusCode == 206 || (http.statusCode == 200 && offset == 0) else { throw ClientError.http("Claude activity", http.statusCode) }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 32 * 1024 * 1024 else { throw ClientError.response("Trace exceeds 32 MB") }
        let data = try Data(contentsOf: file)
        let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) }
        return (data, total.map { offset + data.count >= $0 } ?? true)
    }

    func attachment(_ reference: String, sessionID: String) async throws -> URL {
        if reference.hasPrefix("data:"), let comma = reference.firstIndex(of: ","),
           reference[..<comma].contains(";base64"), let data = Data(base64Encoded: String(reference[reference.index(after: comma)...])) {
            guard data.count <= 32 * 1024 * 1024 else { throw ClientError.response("Hermes attachment") }
            let mime = String(reference.dropFirst(5).prefix { $0 != ";" })
            let ext = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif"][mime] ?? "bin"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try data.write(to: file, options: .atomic)
            return file
        }
        guard let origin = configuration.desktopURL, let fallback = configuration.desktopToken else { throw ClientError.configuration }
        var path = reference
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        if path.hasPrefix("sandbox:") { path = String(path.dropFirst(8)) }
        guard !path.contains("://") else { throw ClientError.response("External attachment") }
        var components = URLComponents(url: origin.appendingPathComponent("api/fs/download"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "profile", value: configuration.hermesProfile), URLQueryItem(name: "session_id", value: sessionID)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + (try await accessToken(fallback: fallback)), forHTTPHeaderField: "Authorization")
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ClientError.http("Hermes attachment", (response as? HTTPURLResponse)?.statusCode ?? 0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
    }

    private func accessToken(fallback: String) async throws -> String {
        if let token = credentials["access_token"].string,
           let expiry = credentials["expires_at"].int, Double(expiry) > Date().timeIntervalSince1970 + 120 { return token }
        guard let refresh = credentials["refresh_token"].string ?? configuration.desktopRefreshToken,
              let origin = configuration.desktopURL else { return fallback }
        var request = URLRequest(url: origin.appendingPathComponent("auth/native/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["refresh_token": .string(refresh), "provider": .string("basic")]))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ClientError.http("Hermes", (response as? HTTPURLResponse)?.statusCode ?? 0) }
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let token = result["access_token"].string else { throw ClientError.response("Hermes") }
        credentials = result
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ai.dreamslate.Squircle.hermes", kSecAttrAccount as String: origin.absoluteString]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        return token
    }

    private func redact(_ text: String) -> String {
        [configuration.hermesToken, configuration.desktopToken ?? "", configuration.desktopRefreshToken ?? "", credentials["access_token"].string ?? "", credentials["refresh_token"].string ?? "", configuration.squircleToken, configuration.diagnosticToken]
            .filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
}
