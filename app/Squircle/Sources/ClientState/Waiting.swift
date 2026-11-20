import Foundation

/// Everything waiting on you across apps, as the Mac lists it
/// (`GET /v1/waiting`): only what blocks an agent until you act, questions
/// agents put in the tracker and threads' own questions and approvals. Per
/// app, oldest first.
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
        /// The task it is about, by name.
        let task: String
        let text: String
        let options: [String]
        /// The screenshots, clips and documents it is about, kept with its task.
        let media: [AppTask.Media]
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
        /// The task that links the thread, by name.
        let task: String?
        let pending: PendingRequest
    }

    /// One of your approvals on a work item: its plan round, or its passing
    /// review, bound to what it names (a digest, or the reviewed commit).
    struct Approval: Equatable {
        enum Gate: String { case plan, merge }
        let gate: Gate
        let taskID: String
        let task: String
        let round: Int
        /// The plan's digest, or the reviewed commit.
        let bind: String
        /// The plan's first picture, or the branch film's still (a path on the Mac).
        let picture: String?
        let detail: String
        let summary: String?
    }

    enum Item: Equatable {
        case question(Question)
        case request(Request)
        case approval(Approval)

        /// The thread that asked: where it shows in a conversation.
        var threadID: String? {
            switch self {
            case .question(let q): q.threadID
            case .request(let r): r.threadID
            case .approval: nil
            }
        }

        /// Stable across replies, for rows.
        var id: String {
            switch self {
            case .question(let q): "q." + q.id
            case .request(let r): "r." + r.pending.id
            case .approval(let a): "a.\(a.taskID).\(a.gate.rawValue).\(a.round)"
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
            return .question(Question(id: id, taskID: task, task: value["task_title"].string ?? value["ask"].string ?? "",
                                      text: text, options: value["options"].array.compactMap(\.string),
                                      media: value["media"].array.compactMap(Self.media), from: value["from"].string,
                                      threadID: value["thread_id"].string,
                                      askedAt: value["asked_at"].double.map(Date.init(timeIntervalSince1970:))))
        case "request":
            guard let thread = value["thread_id"].string, let request = value["request_id"].string else { return nil }
            return .request(Request(threadID: thread, title: value["title"].string ?? "", worker: value["worker"].bool,
                                    task: value["task_title"].string ?? value["ask"].string, pending: PendingRequest(id: request, item: value["item"])))
        case "approval":
            guard let task = value["task_id"].string, let gate = value["gate"].string.flatMap(Approval.Gate.init),
                  let round = value["round"].double else { return nil }
            let bind = gate == .plan ? value["bind"]["digest"].string : value["bind"]["head"].string
            guard let bind else { return nil }
            return .approval(Approval(gate: gate, taskID: task, task: value["task_title"].string ?? "", round: Int(round), bind: bind,
                                      picture: value["picture"].string, detail: value["detail"].string ?? "",
                                      summary: value["summary"].string))
        default:
            return nil
        }
    }

    private static func media(_ value: JSONValue) -> AppTask.Media? {
        guard let id = value["id"].string, let kind = value["kind"].string else { return nil }
        return AppTask.Media(id: id, kind: kind, caption: value["caption"].string ?? "", name: value["name"].string, bytes: value["bytes"].double)
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
