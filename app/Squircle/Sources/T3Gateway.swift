import Foundation

extension JSONValue {
    var date: Date { string.flatMap(ISODate.parse) ?? .distantPast }
}

/// T3's timestamps ("2026-10-15T09:41:07.123Z", or with an offset), parsed
/// by hand: every shell update dates every thread, and a date formatter
/// per call cost the phone tens of milliseconds a frame.
enum ISODate {
    static func parse(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { parse(utf8: $0) } ?? (try? Date(text, strategy: .iso8601))
    }
    /// The way T3 writes dates: "2026-10-15T09:41:07.123Z".
    static func format(_ date: Date) -> String { date.formatted(style) }
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func parse(utf8 b: UnsafeBufferPointer<UInt8>) -> Date? {
        func digits(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= b.count else { return nil }
            var value = 0
            for i in at..<at + count {
                let d = Int(b[i]) - 48
                guard (0...9).contains(d) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        func byte(_ at: Int) -> UInt8 { at < b.count ? b[at] : 0 }
        guard let year = digits(0, 4), byte(4) == 45, let month = digits(5, 2), byte(7) == 45, let day = digits(8, 2),
              byte(10) == 84 || byte(10) == 116 || byte(10) == 32,
              let hour = digits(11, 2), byte(13) == 58, let minute = digits(14, 2), byte(16) == 58, let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var i = 19
        var fraction = 0.0
        if byte(i) == 46 || byte(i) == 44 {
            i += 1
            var scale = 0.1
            let start = i
            while i < b.count, (48...57).contains(b[i]) { fraction += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
            guard i > start else { return nil }
        }
        var offset = 0
        switch byte(i) {
        case 90, 122: i += 1
        case 43, 45:
            let sign = byte(i) == 45 ? -1 : 1
            guard let h = digits(i + 1, 2) else { return nil }
            var m = 0
            if byte(i + 3) == 58, let mm = digits(i + 4, 2) { m = mm; i += 6 }
            else if let mm = digits(i + 3, 2) { m = mm; i += 5 }
            else { i += 3 }
            offset = sign * (h * 3600 + m * 60)
        default: return nil
        }
        guard i == b.count else { return nil }
        // Days since 1970-01-01 in the proleptic Gregorian calendar.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}

/// Verification only (DEBUG, `SQUIRCLE_PERF=1`): timed connection marks
/// appended to Documents/connection-trace.log, to measure the real path on a
/// simulator. A no-op otherwise.
@MainActor
enum ConnectionTrace {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.environment["SQUIRCLE_PERF"] == "1"
    private static let start = ContinuousClock.now
    private static let file: FileHandle? = {
        guard enabled, let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("connection-trace.log") else { return nil }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    static func mark(_ event: String, _ detail: @autoclosure () -> String = "") {
        guard enabled, let file else { return }
        let ms = start.duration(to: .now).components
        let line = String(format: "%.3f %d %@ %@\n", Date().timeIntervalSince1970,
                          Int(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000), event, detail())
        file.write(Data(line.utf8))
    }
    #else
    static let enabled = false
    @inline(__always) static func mark(_ event: String, _ detail: @autoclosure () -> String = "") {}
    #endif
}

/// Refuses every redirect. A session's delegate is this, not the session's
/// owner, so the session never keeps its owner alive.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// The paired session is isolated from cookies; its credential comes from
/// the build's configuration.
final class T3HTTP {
    let configuration: AppConfiguration
    let token: String
    let session: URLSession
    /// The RPC socket's session. URLSession's request timeout would fail a
    /// socket write still queued after 45 s (a Ping behind a picture on a
    /// slow uplink); the gateway's heartbeat judges the socket instead.
    let socketSession: URLSession
    init(configuration: AppConfiguration) {
        self.configuration = configuration
        token = configuration.t3Token
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 45
        #if DEBUG
        // Verification only: T3's traffic through a local HTTPS proxy
        // (host:port), which can slow, stall or cut the link.
        if let proxy = ProcessInfo.processInfo.environment["SQUIRCLE_T3_PROXY"], let colon = proxy.lastIndex(of: ":"),
           let port = Int(proxy[proxy.index(after: colon)...]) {
            c.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": String(proxy[..<colon]), "HTTPSPort": port]
        }
        #endif
        session = URLSession(configuration: c, delegate: RefuseRedirects(), delegateQueue: nil)
        let socket = c.copy() as! URLSessionConfiguration
        socket.timeoutIntervalForRequest = .infinity
        socketSession = URLSession(configuration: socket, delegate: RefuseRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel(); socketSession.invalidateAndCancel() }
    /// Cancels everything under way; the sessions can't be used again.
    func invalidate() { session.invalidateAndCancel(); socketSession.invalidateAndCancel() }
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
    /// T3's RPC socket accepts the session's bearer on the upgrade, like any
    /// HTTPS request: no ticket round trip (a second TLS connection on a
    /// cold start) before the socket can open.
    func bearerSocketRequest(_ path: String) throws -> URLRequest {
        var r = try request(path)
        var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        c.scheme = "wss"; r.url = c.url
        return r
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
    /// The URL for an asset path T3 returned, only if it is a plain path on
    /// T3's own origin: the bearer goes nowhere else.
    static func assetURL(_ relative: String, base: URL) -> URL? {
        guard relative.hasPrefix("/"), !relative.hasPrefix("//"), !relative.contains("\\"),
              let url = URL(string: relative, relativeTo: base)?.absoluteURL, sameOrigin(url, base) else { return nil }
        return url
    }
    /// Same HTTPS scheme, host and effective port, and no user info.
    static func sameOrigin(_ url: URL, _ base: URL) -> Bool {
        guard let a = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let b = URLComponents(url: base, resolvingAgainstBaseURL: true),
              a.scheme?.lowercased() == "https", b.scheme?.lowercased() == "https",
              a.user == nil, a.password == nil,
              let host = a.host?.lowercased(), host == b.host?.lowercased() else { return false }
        return (a.port ?? 443) == (b.port ?? 443)
    }
    /// Bytes at a T3 URL, with the bearer, only on T3's origin.
    func authorizedData(_ url: URL) async -> Data? {
        guard Self.sameOrigin(url, configuration.t3URL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
    /// A T3 file streamed to disk and moved to `destination`, with the
    /// bearer, only on T3's origin. False if it couldn't be fetched.
    func authorizedDownload(_ url: URL, to destination: URL) async -> Bool {
        guard Self.sameOrigin(url, configuration.t3URL) else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (file, response) = try? await session.download(for: request) else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return (try? MediaFileStore.move(file, to: destination)) != nil
    }
}

/// Effect RPC JSON framing, pinned to the installed T3 0.0.45 contract.
@MainActor
final class T3Gateway {
    let http: T3HTTP
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    /// How each request ended: T3's Exit, or the socket going first.
    private enum Reply {
        case exit(JSONValue)
        /// It never left the phone.
        case notSent
        /// Written (perhaps only in part); the socket went before T3 answered.
        case lost(Error)
        case cancelled
    }
    private var pending: [String: CheckedContinuation<Reply, Never>] = [:]
    /// Live subscriptions: their values, and how they end if T3 ends them.
    /// A dropped socket ends none of them; `onDisconnect` covers that.
    private var subscriptions: [String: (receive: (JSONValue) -> Void, ended: (Error?) -> Void)] = [:]
    /// When T3 last sent anything; T3 answers every Ping, so silence means a dead socket.
    private var lastFrame = ContinuousClock.now
    /// Requests being written. A large one (a message with pictures) takes
    /// as long as the link needs, and a Ping queued behind it can't be
    /// answered sooner: silence only counts while none is under way, from
    /// when the last one finished.
    private var requestsWriting = 0
    private var requestsWritten = ContinuousClock.now
    /// Request bytes T3 hasn't shown it has read. A finished write may still
    /// sit in the send buffer (megabytes on a slow uplink), so T3 gets as
    /// long as the slowest link it should work on needs to receive them.
    /// T3 answers Pings in order, so a Pong covers every byte queued before
    /// its Ping; other frames prove nothing about what T3 has read.
    private var queuedBytes = 0
    private var readBytes = 0
    /// `queuedBytes` when each unanswered Ping was queued, oldest first.
    private var pings: [Int] = []
    private var unanswered: Int { queuedBytes - readBytes }
    private static let slowestLink = 16_000.0 // bytes/s: 128 kbit/s
    private let silenceAllowed: Duration = .seconds(40)
    /// T3 has said nothing for longer than `limit` with nothing of ours in the way.
    private func silent(beyond limit: Duration, since asked: ContinuousClock.Instant) -> Bool {
        guard requestsWriting == 0 else { return false }
        let allowed = limit + .seconds(Double(unanswered) / Self.slowestLink)
        return max(lastFrame, requestsWritten, asked).duration(to: .now) > allowed
    }
    var onDisconnect: (() -> Void)?
    /// Why T3 refused the last socket's upgrade, if it did.
    private(set) var rejection: Error?
    var isOpen: Bool { socket != nil }
    init(configuration: AppConfiguration) { http = T3HTTP(configuration: configuration) }
    /// Closes the socket and the HTTP session for good.
    func close() { onDisconnect = nil; disconnect(notify: false); http.invalidate() }
    func connect() async throws {
        disconnect(notify: false)
        ConnectionTrace.mark("socket.start")
        let ws = http.socketSession.webSocketTask(with: try http.bearerSocketRequest("/ws"))
        disconnect(notify: false); rejection = nil
        socket = ws; ws.maximumMessageSize = 32 * 1024 * 1024; ws.resume(); lastFrame = .now; requestsWritten = .now
        receiver = Task { [weak self] in
            var first = true
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    self?.lastFrame = .now
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    if ConnectionTrace.enabled, first { ConnectionTrace.mark("socket.firstFrame"); first = false }
                    let decodeStart = ContinuousClock.now
                    let frame = try JSONDecoder().decode(JSONValue.self, from: data)
                    let decoded = ContinuousClock.now
                    for item in frame.array.isEmpty ? [frame] : frame.array { self?.receive(item) }
                    if ConnectionTrace.enabled, data.count > 8192 {
                        ConnectionTrace.mark("frame", "\(data.count)B decode=\(decodeStart.duration(to: decoded)) apply=\(decoded.duration(to: .now))")
                    }
                }
            } catch {
                #if DEBUG
                if self?.socket === ws { NSLog("SQUIRCLE-CONN T3 socket failed: %@", String(describing: error)) }
                #endif
                // A refused upgrade is not a network blip: say why.
                let status = (ws.response as? HTTPURLResponse)?.statusCode ?? 101
                self?.drop(ws, error: status == 101 ? nil : ClientError.http("T3", status))
            }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                // A half-open socket (a network change, a suspended app) never
                // errors on its own; no reply to two pings means it's gone.
                if silent(beyond: silenceAllowed, since: lastFrame) { drop(ws); return }
                do { try await ping() } catch { drop(ws); return }
            }
        }
    }
    /// Whether T3 still answers on this socket, within `timeout`.
    func probe(timeout: Duration = .seconds(8)) async -> Bool {
        guard let ws = socket else { return false }
        let asked = ContinuousClock.now
        Task { try? await ping() }
        while !silent(beyond: timeout, since: asked) {
            if lastFrame > asked { return true }
            guard socket === ws else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        drop(ws)
        return false
    }
    private func drop(_ ws: URLSessionWebSocketTask, error: Error? = nil) {
        guard socket === ws else { return }
        rejection = error; disconnect(notify: true, error: error)
    }
    func disconnect(notify: Bool = false, error: Error? = nil) {
        receiver?.cancel(); heartbeat?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
        receiver = nil; heartbeat = nil; requestsWriting = 0
        queuedBytes = 0; readBytes = 0; pings.removeAll()
        let waiting = pending; pending.removeAll(); subscriptions.removeAll()
        for p in waiting.values { p.resume(returning: .lost(error ?? ClientError.connection("T3"))) }
        if notify { onDisconnect?() }
    }
    #if DEBUG
    /// Verification only: the socket fails as if the network dropped it.
    func dropForTesting() { socket?.cancel(with: .abnormalClosure, reason: nil) }
    #endif
    /// One request and how it ended. Without a socket it is never sent:
    /// whoever asked waits for T3's next connection, not for a time limit.
    private func request(_ method: String, _ payload: JSONValue) async -> Reply {
        guard socket != nil else { return .notSent }
        let id = UUID().uuidString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[id] = continuation
                // T3 answers every request; a socket that dies first ends it.
                Task {
                    do { try await write(["_tag": "Request", "id": .string(id), "tag": .string(method), "payload": payload, "headers": []], request: true) }
                    catch is NotWritten { pending.removeValue(forKey: id)?.resume(returning: .notSent) }
                    catch { pending.removeValue(forKey: id)?.resume(returning: .lost(error)) }
                }
            }
        } onCancel: { Task { @MainActor in self.pending.removeValue(forKey: id)?.resume(returning: .cancelled) } }
    }
    /// A read-only request: its value, or why there is none.
    func call(_ method: String, _ payload: JSONValue = .object([:])) async throws -> JSONValue {
        switch await request(method, payload) {
        case .exit(let exit):
            guard exit["_tag"].string == "Success" else { throw ClientError.backend("T3", 0, "T3 rejected the request: \(exit["cause"].formatted.prefix(700))") }
            return exit["value"]
        case .notSent: throw ClientError.connection("T3")
        case .lost(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }
    /// An orchestration command, sent exactly as given (its identity was
    /// fixed with its intent), and how T3 answered: only a typed refusal
    /// proves nothing ran; a lost answer is `unknown`, never a refusal.
    func dispatch(_ command: JSONValue) async -> CommandOutcome {
        switch await request("orchestration.dispatchCommand", command) {
        case .exit(let exit): return .t3(exit: exit)
        case .notSent: return .notSent("Not connected to T3.")
        case .lost(let error): return .unknown(error.localizedDescription)
        case .cancelled: return .unknown("Cancelled after it was sent.")
        }
    }
    /// `ended` runs if T3 finishes or rejects the subscription while the
    /// socket stays up: nil for an (unexpected) success, else why.
    @discardableResult
    func subscribe(_ method: String, _ payload: JSONValue = .object([:]), receive: @escaping (JSONValue) -> Void,
                   ended: @escaping (Error?) -> Void) async throws -> String {
        let id = UUID().uuidString; track(id, receive: receive, ended: ended)
        do { try await write(["_tag": "Request", "id": .string(id), "tag": .string(method), "payload": payload, "headers": []], request: true) }
        catch { subscriptions.removeValue(forKey: id); throw error is NotWritten ? ClientError.connection("T3") : error }
        return id
    }
    func track(_ id: String, receive: @escaping (JSONValue) -> Void, ended: @escaping (Error?) -> Void) {
        subscriptions[id] = (receive, ended)
    }
    var subscriptionCount: Int { subscriptions.count }
    func unsubscribe(_ id: String?) async {
        guard let id else { return }; subscriptions.removeValue(forKey: id)
        try? await write(["_tag": "Interrupt", "requestId": .string(id)])
    }
    /// No socket to write on: nothing left the phone.
    private struct NotWritten: Error {}
    private func write(_ value: JSONValue, request: Bool = false) async throws {
        guard let socket else { throw NotWritten() }
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        guard request else { return try await socket.send(.string(text)) }
        requestsWriting += 1; queuedBytes += text.utf8.count
        defer {
            if self.socket === socket { requestsWriting -= 1; requestsWritten = .now }
        }
        try await socket.send(.string(text))
    }
    private func ping() async throws {
        guard socket != nil else { throw ClientError.connection("T3") }
        pings.append(queuedBytes)
        try await write(["_tag": "Ping"])
    }
    func receive(_ frame: JSONValue) {
        let id = frame["requestId"].identifier ?? ""
        switch frame["_tag"].string {
        case "Chunk":
            for value in frame["values"].array { subscriptions[id]?.receive(value) }
            Task { try? await write(["_tag": "Ack", "requestId": .string(id)]) }
        case "Exit":
            let exit = frame["exit"]
            pending.removeValue(forKey: id)?.resume(returning: .exit(exit))
            let failure = exit["_tag"].string == "Success" ? nil
                : ClientError.backend("T3",0,"T3 rejected the request: \(exit["cause"].formatted.prefix(700))")
            subscriptions.removeValue(forKey:id)?.ended(failure)
        case "Ping": Task { try? await write(["_tag": "Pong"]) }
        case "Pong": if !pings.isEmpty { readBytes = max(readBytes, pings.removeFirst()) }
        default: break
        }
    }
}
