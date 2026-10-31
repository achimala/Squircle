import Foundation

/// Everything waiting on you across apps, as the Mac lists it
/// (`GET /v1/waiting`): questions agents put in the tracker, threads' own
/// questions and approvals, and needs-you tasks neither covers. Per app,
/// oldest first.
struct WaitingList: Decodable, Equatable {
    struct App: Equatable {
        let projectID: String
        let name: String?
        let items: [Item]
    }

    /// A question in the tracker, answered back to the thread that asked.
    struct Question: Equatable {
        let id: String
        let taskID: String
        /// The task it is about, in your words; and its work item's, for a sub-task.
        let ask: String
        let itemAsk: String?
        let text: String
        let options: [String]
        /// The worker that asked; nil for the app's agent.
        let from: String?
        let threadID: String?
        /// When it was asked, to find it in the asking thread's conversation.
        let askedAt: Date?
    }

    /// A thread's own question or approval, answered straight to it.
    struct Request: Equatable {
        let threadID: String
        let title: String
        let worker: Bool
        let ask: String?
        let pending: PendingRequest
    }

    /// A task that needs you for something only it says (its note).
    struct NeedsYou: Equatable {
        let taskID: String
        let ask: String
        let itemAsk: String?
        let note: String
        let threadID: String?
    }

    enum Item: Equatable {
        case question(Question)
        case request(Request)
        case task(NeedsYou)

        /// The thread that asked: where it shows in a conversation.
        var threadID: String? {
            switch self {
            case .question(let q): q.threadID
            case .request(let r): r.threadID
            case .task: nil
            }
        }

        /// Stable across replies, for rows.
        var id: String {
            switch self {
            case .question(let q): "q." + q.id
            case .request(let r): "r." + r.pending.id
            case .task(let t): "t." + t.taskID
            }
        }
    }

    var apps: [App] = []

    var count: Int { apps.reduce(0) { $0 + $1.items.count } }

    init(apps: [App] = []) { self.apps = apps }

    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        apps = value["apps"].array.compactMap { app in
            guard let project = app["project_id"].string else { return nil }
            return App(projectID: project, name: app["app"].string, items: app["items"].array.compactMap(Self.item))
        }
    }

    private static func item(_ value: JSONValue) -> Item? {
        switch value["kind"].string {
        case "question":
            guard let id = value["id"].string, let task = value["task_id"].string, let text = value["text"].string else { return nil }
            return .question(Question(id: id, taskID: task, ask: value["ask"].string ?? "", itemAsk: value["item_ask"].string,
                                      text: text, options: value["options"].array.compactMap(\.string), from: value["from"].string,
                                      threadID: value["thread_id"].string,
                                      askedAt: value["asked_at"].double.map(Date.init(timeIntervalSince1970:))))
        case "request":
            guard let thread = value["thread_id"].string, let request = value["request_id"].string else { return nil }
            return .request(Request(threadID: thread, title: value["title"].string ?? "", worker: value["worker"].bool,
                                    ask: value["ask"].string, pending: PendingRequest(id: request, item: value["item"])))
        case "task":
            guard let task = value["task_id"].string else { return nil }
            return .task(NeedsYou(taskID: task, ask: value["ask"].string ?? "", itemAsk: value["item_ask"].string,
                                  note: value["note"].string ?? "", threadID: value["thread_id"].string))
        default:
            return nil
        }
    }

    /// Without the items in `hidden` (answered here, not yet gone from the Mac's list).
    func without(_ hidden: Set<String>) -> WaitingList {
        guard !hidden.isEmpty else { return self }
        return WaitingList(apps: apps.compactMap { app in
            let items = app.items.filter { !hidden.contains($0.id) }
            return items.isEmpty ? nil : App(projectID: app.projectID, name: app.name, items: items)
        })
    }
}
