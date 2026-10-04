import Foundation

struct AppConfiguration: Decodable {
    let hermesURL: URL
    let hermesToken: String
    let squircleURL: URL
    let squircleToken: String
    let diagnosticToken: String
    let agentInstructions: String?

    enum CodingKeys: String, CodingKey {
        case hermesURL = "hermes_url", hermesToken = "hermes_token"
        case squircleURL = "squircle_url", squircleToken = "squircle_token"
        case diagnosticToken = "diagnostic_token", agentInstructions = "agent_instructions"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hermesURL = try Self.origin(values.decode(String.self, forKey: .hermesURL))
        squircleURL = try Self.origin(values.decode(String.self, forKey: .squircleURL))
        hermesToken = try Self.credential(values.decode(String.self, forKey: .hermesToken))
        squircleToken = try Self.credential(values.decode(String.self, forKey: .squircleToken))
        diagnosticToken = try Self.credential(values.decode(String.self, forKey: .diagnosticToken))
        agentInstructions = try values.decodeIfPresent(String.self, forKey: .agentInstructions)
    }

    static func load(bundle: Bundle = .main) throws -> AppConfiguration {
        guard let url = bundle.url(forResource: "client", withExtension: "json") else {
            throw ClientError.configuration
        }
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { throw ClientError.configuration }
    }

    private static func origin(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text), parts.scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let url = parts.url else { throw ClientError.configuration }
        return url
    }

    private static func credential(_ text: String) throws -> String {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw ClientError.configuration
        }
        return text
    }
}

enum ClientError: LocalizedError {
    case configuration
    case response(String)
    case http(String, Int)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .configuration: return "This build needs its private Mac connection configuration."
        case .response(let service): return "\(service) returned an unreadable response."
        case .http(let service, let status):
            if status == 401 || status == 403 { return "\(service) did not accept this app’s connection credential." }
            if status == 404 { return "That \(service) resource is no longer available."
            }
            return "\(service) could not complete the request (HTTP \(status))."
        case .connection(let service): return "Couldn’t reach \(service). Check that your Mac and Tailscale are online."
        }
    }

    var isMissing: Bool {
        if case .http(_, 404) = self { return true }
        return false
    }
}
