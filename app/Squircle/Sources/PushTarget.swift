import Foundation

/// What a notification or the Live Activity opens: an app, maybe one of its
/// threads, or a build. Built from the Mac's `squircle` payload key; a
/// payload that names nothing to open is no target at all.
enum PushTarget: Equatable {
    /// How the payload names an app.
    enum App: Equatable {
        /// A T3 project ID.
        case project(String)
        /// A built app's bundle ID.
        case bundle(String)
        /// The Mac catalog's app ID, for a build whose bundle isn't known.
        case catalog(String)
    }

    case app(App, thread: String?)
    /// A build, and its app when the Mac knows it.
    case build(String, app: App?)
    /// A new question or request: its app's Tasks, at the question
    /// (Home, with everything waiting, when it names no app).
    case waiting(App?, thread: String?)

    init?(userInfo: [AnyHashable: Any]) {
        guard let info = userInfo["squircle"] as? [String: Any] else { return nil }
        let string = { (key: String) in (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let app: App? = string("project").map(App.project) ?? string("bundle").map(App.bundle)
            ?? string("app").map(App.catalog)
        if info["waiting"] as? Bool == true { self = .waiting(app, thread: string("thread")); return }
        if let build = string("build") {
            self = .build(build, app: app)
        } else if let app {
            self = .app(app, thread: string("thread"))
        } else {
            return nil
        }
    }

    /// `squircle://app?project=ID[&thread=ID]`, the Live Activity's link.
    init?(url: URL) {
        guard url.scheme == "squircle", url.host == "app",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let project = items.first(where: { $0.name == "project" })?.value, !project.isEmpty else { return nil }
        self = .app(.project(project), thread: items.first { $0.name == "thread" }?.value)
    }

    var appRef: App? {
        switch self {
        case .app(let app, _): app
        case .build(_, let app): app
        case .waiting(let app, _): app
        }
    }

    // Field views for routing code.
    var project: String? { if case .project(let id) = appRef { id } else { nil } }
    var bundle: String? { if case .bundle(let id) = appRef { id } else { nil } }
    var catalogApp: String? { if case .catalog(let id) = appRef { id } else { nil } }
    var thread: String? {
        switch self {
        case .app(_, let thread), .waiting(_, let thread): thread
        case .build: nil
        }
    }
    var waiting: Bool { if case .waiting = self { true } else { false } }
    var build: String? { if case .build(let id, _) = self { id } else { nil } }
}
