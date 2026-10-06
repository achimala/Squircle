import Foundation
import Security

struct AppConfiguration: Decodable {
    let t3URL: URL
    let t3Token: String
    let squircleURL: URL
    let squircleToken: String
    let diagnosticToken: String
    enum CodingKeys: String, CodingKey {
        case t3URL = "t3_url", t3Token = "t3_token"
        case squircleURL = "squircle_url", squircleToken = "squircle_token"
        case diagnosticToken = "diagnostic_token"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t3URL = try Self.origin(c.decode(String.self, forKey: .t3URL))
        squircleURL = try Self.origin(c.decode(String.self, forKey: .squircleURL))
        t3Token = try Self.credential(c.decode(String.self, forKey: .t3Token))
        squircleToken = try Self.credential(c.decode(String.self, forKey: .squircleToken))
        diagnosticToken = try Self.credential(c.decode(String.self, forKey: .diagnosticToken))
    }
    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "client", withExtension: "json") else { throw ClientError.configuration }
        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        Shared.store(data)
        return configuration
    }

    /// Squircle leaves its paired connection in a team-shared Keychain group,
    /// so the debug overlay Squircle injects into apps it builds reaches the
    /// same Mac with no setup (user decision, 2026-10-06).
    enum Shared {
        private static let service = "ai.dreamslate.squircle.shared.client"
        /// Team ID from the installed profile. App Store builds have none.
        static let teamID: String? = {
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                  let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
                  let teams = (plist as? [String: Any])?["TeamIdentifier"] as? [String] else { return nil }
            return teams.first
        }()
        private static var query: [String: Any]? {
            teamID.map { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                          kSecAttrAccount as String: "client.json",
                          kSecAttrAccessGroup as String: "\($0).ai.dreamslate.squircle.shared"] }
        }
        static func store(_ data: Data) {
            guard let query else { return }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemDelete(query as CFDictionary); SecItemAdd(item as CFDictionary, nil)
        }
        static func load() throws -> AppConfiguration {
            guard var query else { throw ClientError.configuration }
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
                throw ClientError.configuration
            }
            return try JSONDecoder().decode(AppConfiguration.self, from: data)
        }
    }
    private static func origin(_ text: String) throws -> URL {
        guard let c = URLComponents(string: text), c.scheme == "https", c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", let url = c.url else { throw ClientError.configuration }
        return url
    }
    private static func credential(_ text: String) throws -> String {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw ClientError.configuration }
        return text
    }
}

enum ClientError: LocalizedError {
    case configuration
    case response(String)
    case http(String, Int)
    case backend(String, Int, String)
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
        case .backend(_, _, let message): return message
        }
    }

    var isMissing: Bool {
        if case .http(_, 404) = self { return true }
        if case .backend(_, 404, _) = self { return true }
        return false
    }
}
