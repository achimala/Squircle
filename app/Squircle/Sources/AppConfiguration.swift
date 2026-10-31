import Foundation
import Security
import os

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
        let stored = Shared.store(data)
        Shared.lastStore.withLock { $0 = stored }
        return configuration
    }

    /// Squircle's own bundle ID and shared Keychain group, set in
    /// Config/Signing.xcconfig and read from the Info.plist of whichever
    /// bundle this code is in: the app, or the overlay framework in a host app.
    enum Namespace {
        private final class Marker {}
        private static let info = Bundle(for: Marker.self).infoDictionary ?? [:]
        static let appBundleID = info["SquircleAppBundleID"] as? String ?? ""
        static let sharedKeychainGroup = info["SquircleSharedKeychainGroup"] as? String ?? ""
    }

    /// Squircle leaves its paired connection in a team-shared Keychain group,
    /// so the debug overlay Squircle injects into apps it builds reaches the
    /// same Mac with no setup (user decision, 2026-10-06).
    enum Shared {
        private static let group = Namespace.sharedKeychainGroup
        private static let service = "\(group).client"
        /// Team ID from the installed profile. App Store builds have none.
        static let teamID = (provisioningProfile?["TeamIdentifier"] as? [String])?.first
        /// The installed provisioning profile's plist (it sits inside a CMS
        /// signature). Simulator and Xcode-run builds have none.
        static let provisioningProfile: [String: Any]? = {
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                  let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        }()
        private static var query: [String: Any]? {
            guard !group.isEmpty else { return nil }
            return teamID.map { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                          kSecAttrAccount as String: "client.json",
                          kSecAttrAccessGroup as String: "\($0).\(group)"] }
        }
        enum StoreResult: Equatable {
            case stored
            /// No team ID (an App Store or simulator build): nothing is shared.
            case noSharingGroup
            /// The Keychain refused; whatever was stored before is untouched.
            case failed(OSStatus)
        }
        /// How the last `load()` left the shared copy, for the app to report.
        static let lastStore = OSAllocatedUnfairLock<StoreResult?>(initialState: nil)
        @discardableResult
        static func store(_ data: Data) -> StoreResult {
            guard let query else { return .noSharingGroup }
            return replace(data: data, update: { SecItemUpdate(query as CFDictionary, $0 as CFDictionary) },
                           add: { attributes in
                               var item = query; item.merge(attributes) { _, new in new }
                               return SecItemAdd(item as CFDictionary, nil)
                           })
        }
        /// Updates the item in place and adds it only where there is none, so
        /// a failure never leaves the overlay without the previous copy.
        static func replace(data: Data, update: ([String: Any]) -> OSStatus, add: ([String: Any]) -> OSStatus) -> StoreResult {
            let attributes: [String: Any] = [kSecValueData as String: data,
                                             kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let updated = update(attributes)
            if updated == errSecSuccess { return .stored }
            guard updated == errSecItemNotFound else { return .failed(updated) }
            let added = add(attributes)
            return added == errSecSuccess ? .stored : .failed(added)
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
    /// The Mac's service lacks a route this app needs.
    case incompatible(String)

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
        case .incompatible(let route): return "The Mac’s Squircle service doesn’t match this app (it has no \(route)). Update Squircle on the Mac."
        }
    }

    var isMissing: Bool {
        if case .http(_, 404) = self { return true }
        if case .backend(_, 404, _) = self { return true }
        return false
    }
}
