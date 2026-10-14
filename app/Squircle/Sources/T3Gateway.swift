import Foundation
import Security

extension JSONValue {
    static func from(_ value: Any) -> Self {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let json = try? JSONDecoder().decode(Self.self, from: data) else { return .null }
        return json
    }
    var date: Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return string.flatMap { f.date(from: $0) } ?? .distantPast
    }
}

/// The paired session is isolated from cookies and stored in the device Keychain.
final class T3HTTP: NSObject, URLSessionTaskDelegate {
    let configuration: AppConfiguration
    let token: String
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 45
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    init(configuration: AppConfiguration) {
        self.configuration = configuration
        let account = configuration.t3URL.absoluteString
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.dreamslate.Squircle.T3", kSecAttrAccount as String: account]
        // A newly paired personal build deliberately replaces an expired session.
        var item = key
        item[kSecValueData as String] = Data(configuration.t3Token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(key as CFDictionary); SecItemAdd(item as CFDictionary, nil)
        token = configuration.t3Token
        super.init()
    }
    func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("?") else { throw ClientError.configuration }
        var parts = URLComponents(url: configuration.t3URL, resolvingAgainstBaseURL: false)!
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        var r = URLRequest(url: parts.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }
    func json(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var r = try request(path)
        if let body { r.httpMethod = "POST"; r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: r)
        guard let h = response as? HTTPURLResponse else { throw ClientError.response("T3") }
        guard (200..<300).contains(h.statusCode) else { throw ClientError.http("T3", h.statusCode) }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func socketRequest(_ path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        let ticket = try await json("/api/auth/websocket-ticket", body: .object([:]))
        guard let value = ticket["ticket"].string else { throw ClientError.response("T3") }
        var r = try request(path, query: query + [URLQueryItem(name: "wsTicket", value: value)])
        var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        c.scheme = "wss"; r.url = c.url
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        return r
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Effect RPC JSON framing, pinned to the installed T3 0.0.45 contract.
@MainActor
final class T3Gateway {
    let http: T3HTTP
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscriptions: [String: (JSONValue) -> Void] = [:]
    /// When T3 last sent anything; T3 answers every Ping, so silence means a dead socket.
    private var lastFrame = ContinuousClock.now
    var onDisconnect: (() -> Void)?
    var isOpen: Bool { socket != nil }
    init(configuration: AppConfiguration) { http = T3HTTP(configuration: configuration) }
    func connect() async throws {
        disconnect(notify: false)
        let ws = http.session.webSocketTask(with: try await http.socketRequest("/ws"))
        disconnect(notify: false)
        socket = ws; ws.maximumMessageSize = 32 * 1024 * 1024; ws.resume(); lastFrame = .now
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    self?.lastFrame = .now
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    let frame = try JSONDecoder().decode(JSONValue.self, from: data)
                    for item in frame.array.isEmpty ? [frame] : frame.array { self?.receive(item) }
                }
            } catch { self?.drop(ws) }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                // A half-open socket (a network change, a suspended app) never
                // errors on its own; no reply to two pings means it's gone.
                if lastFrame.duration(to: .now) > .seconds(40) { drop(ws); return }
                do { try await write(.from(["_tag":"Ping"])) } catch { drop(ws); return }
            }
        }
    }
    /// Whether T3 still answers on this socket, within `timeout`.
    func probe(timeout: Duration = .seconds(4)) async -> Bool {
        guard let ws = socket else { return false }
        let asked = ContinuousClock.now
        Task { try? await write(.from(["_tag":"Ping"])) }
        while asked.duration(to: .now) < timeout {
            if lastFrame > asked { return true }
            guard socket === ws else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        drop(ws)
        return false
    }
    private func drop(_ ws: URLSessionWebSocketTask) {
        if socket === ws { disconnect(notify: true) }
    }
    func disconnect(notify: Bool = false) {
        receiver?.cancel(); heartbeat?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
        receiver = nil; heartbeat = nil
        let waiting = pending; pending.removeAll(); subscriptions.removeAll()
        for p in waiting.values { p.resume(throwing: ClientError.connection("T3")) }
        if notify { onDisconnect?() }
    }
    #if DEBUG
    /// Verification only: the socket fails as if the network dropped it.
    func dropForTesting() { socket?.cancel(with: .abnormalClosure, reason: nil) }
    #endif
    /// Requests made while the socket is being replaced wait for the new one
    /// instead of failing; nothing was sent, so nothing can run twice.
    private func open() async throws {
        let start = ContinuousClock.now
        while socket == nil {
            guard start.duration(to: .now) < .seconds(15), !Task.isCancelled else { throw ClientError.connection("T3") }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    func call(_ method: String, _ payload: JSONValue = .object([:])) async throws -> JSONValue {
        try await open()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    do { try await write(.from(["_tag":"Request", "id":id, "tag":method, "payload":payload.foundation, "headers":[]])) }
                    catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    self?.pending.removeValue(forKey: id)?.resume(throwing: ClientError.backend("T3",408,"T3 did not acknowledge this request. Refresh the thread before retrying."))
                }
            }
        } onCancel: { Task { @MainActor in self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) } }
    }
    @discardableResult
    func subscribe(_ method: String, _ payload: JSONValue = .object([:]), receive: @escaping (JSONValue) -> Void) async throws -> String {
        let id = UUID().uuidString; subscriptions[id] = receive
        do { try await write(.from(["_tag":"Request","id":id,"tag":method,"payload":payload.foundation,"headers":[]])) }
        catch { subscriptions.removeValue(forKey: id); throw error }
        return id
    }
    func unsubscribe(_ id: String?) async {
        guard let id else { return }; subscriptions.removeValue(forKey: id)
        try? await write(.from(["_tag":"Interrupt","requestId":id]))
    }
    private func write(_ value: JSONValue) async throws {
        guard let socket else { throw ClientError.connection("T3") }
        try await socket.send(.string(String(decoding: JSONEncoder().encode(value), as: UTF8.self)))
    }
    func receive(_ frame: JSONValue) {
        let id = frame["requestId"].identifier ?? ""
        switch frame["_tag"].string {
        case "Chunk":
            for value in frame["values"].array { subscriptions[id]?(value) }
            Task { try? await write(.from(["_tag":"Ack","requestId":id])) }
        case "Exit":
            let exit = frame["exit"]
            if exit["_tag"].string == "Success" { pending.removeValue(forKey:id)?.resume(returning:exit["value"]) }
            else { pending.removeValue(forKey:id)?.resume(throwing: ClientError.backend("T3",0,"T3 rejected the request: \(exit["cause"].formatted.prefix(700))")) }
            subscriptions.removeValue(forKey:id)
        case "Ping": Task { try? await write(.from(["_tag":"Pong"])) }
        default: break
        }
    }
}

extension JSONValue {
    var foundation: Any {
        switch self { case .null: return NSNull(); case .bool(let x): return x; case .number(let x): return x; case .string(let x): return x
        case .array(let x): return x.map(\.foundation); case .object(let x): return x.mapValues(\.foundation) }
    }
}
