import Foundation

/// Server sequence numbers prevent replayed chunks from duplicating messages.
struct T3ThreadState {
    private(set) var sequence = -1
    private(set) var thread: JSONValue = .null
    mutating func consume(_ item: JSONValue) {
        if item["kind"].string == "snapshot" {
            let snapshot = item["snapshot"]
            guard let seq = snapshot["snapshotSequence"].int, seq >= sequence else { return }
            sequence = seq; thread = snapshot["thread"]; return
        }
        guard item["kind"].string == "event" else { return }
        let event = item["event"]
        guard let seq = event["sequence"].int, seq > sequence else { return }
        sequence = seq
        let p = event["payload"]; var t = thread.object
        switch event["type"].string {
        case "thread.message-sent":
            var m = p.object; m["id"] = p["messageId"]
            var rows = t["messages"]?.array ?? []
            if let i = rows.firstIndex(where: { $0["id"] == p["messageId"] }) {
                let old = rows[i]; let delta = p["text"].string ?? ""
                m["text"] = .string(p["streaming"].bool ? (old["text"].string ?? "") + delta : delta.isEmpty ? old["text"].string ?? "" : delta)
                m["createdAt"] = old["createdAt"]
                rows[i] = .object(m)
            }
            else { rows.append(.object(m)) }
            t["messages"] = .array(rows)
        case "thread.session-set": t["session"] = p["session"]
        case "thread.activity-appended":
            var rows = t["activities"]?.array ?? []
            if !rows.contains(where: { $0["id"] == p["activity"]["id"] }) { rows.append(p["activity"]) }
            t["activities"] = .array(rows)
        case "thread.meta-updated": for (key,value) in p.object where key != "threadId" { t[key] = value }
        case "thread.runtime-mode-set": t["runtimeMode"] = p["runtimeMode"]
        case "thread.interaction-mode-set": t["interactionMode"] = p["interactionMode"]
        case "thread.turn-start-requested":
            var session = t["session"]?.object ?? [:]; session["status"] = .string("running"); t["session"] = .object(session)
        default: break
        }
        thread = .object(t)
    }
    var messages: [ChatMessage] {
        let texts = thread["messages"].array.map { m in
            (m["createdAt"].string ?? "", ChatMessage(id: m["id"].string ?? UUID().uuidString,
                role: m["role"].string ?? "assistant", content: m["text"].string ?? "", isStreaming: m["streaming"].bool))
        }
        let activities = thread["activities"].array.map { a in
            let p = a["payload"]
            let detail = [p["data"]["item"]["command"].string ?? p["detail"].string,
                          p["data"]["item"]["aggregatedOutput"].string,
                          p["data"]["output"].string].compactMap { $0 }.joined(separator:"\n\n")
            return (a["createdAt"].string ?? "", ChatMessage(id: a["id"].string ?? UUID().uuidString,
                role: "tool", content: a["summary"].string ?? a["kind"].string ?? "Activity",
                detail: detail.isEmpty ? p.formatted : detail,
                activity: a["kind"].string, failed: a["tone"].string == "error"))
        }
        return (texts + activities).sorted { $0.0 < $1.0 }.map(\.1)
    }
    var pendingRequests: [JSONValue] {
        let activities = thread["activities"].array
        let finished = Set(activities.filter {
            let kind = $0["kind"].string ?? ""
            return kind.contains("resolved") || kind.contains("responded") || kind.contains("completed") || kind.contains("cancelled") || kind == "user-input.answer-submitted"
        }.compactMap { $0["payload"]["requestId"].string })
        return activities.filter {
            let kind = $0["kind"].string ?? ""
            guard let id = $0["payload"]["requestId"].string else { return false }
            return (kind.contains("approval") || kind.contains("user-input")) && (kind.contains("requested") || kind.contains("opened")) && !finished.contains(id)
        }
    }
}
