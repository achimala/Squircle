import Foundation

/// Never follow redirects with a diagnostic credential, or use browser cookies.
final class DiagnosticsTransport: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static func endpoint(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw ProbeError("Enter the HTTPS server origin only, for example https://mac.example.ts.net:8443.")
        }
        parts.path = "/v1/diagnostics"
        guard let url = parts.url else { throw ProbeError("Invalid diagnostics URL.") }
        return url
    }

    func send(_ event: DiagnosticEvent, to url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(event)
        let (data, response) = try await session.data(for: request)
        try Self.validateAcknowledgement(data: data, response: response)
    }

    static func validateAcknowledgement(data: Data, response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ProbeError("Server returned no HTTP response.") }
        guard (200..<300).contains(response.statusCode) else { throw ProbeError("Upload rejected (HTTP \(response.statusCode)); event retained.") }
        struct Acknowledgement: Decodable { let ok: Bool }
        guard let ack = try? JSONDecoder().decode(Acknowledgement.self, from: data), ack.ok else {
            throw ProbeError("Server did not confirm acceptance; event retained.")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
