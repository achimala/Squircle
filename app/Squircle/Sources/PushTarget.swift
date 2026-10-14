import Foundation

/// What a notification or the Live Activity opens: an app, one of its
/// threads, or a build. Built from the Mac's `squircle` payload key.
struct PushTarget: Equatable {
    var project: String?
    var thread: String?
    var build: String?
    /// A built app's bundle ID, to find its app when the project isn't named.
    var bundle: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let info = userInfo["squircle"] as? [String: Any] else { return nil }
        project = info["project"] as? String; thread = info["thread"] as? String
        build = info["build"] as? String; bundle = info["bundle"] as? String
        if project == nil, build == nil, bundle == nil { return nil }
    }

    /// `squircle://app?project=ID[&thread=ID]`, the Live Activity's link.
    init?(url: URL) {
        guard url.scheme == "squircle", url.host == "app",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        project = value("project"); thread = value("thread"); build = nil; bundle = nil
        if project == nil { return nil }
    }
}
