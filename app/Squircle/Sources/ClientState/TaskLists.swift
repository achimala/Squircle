import Foundation

/// Each app's tasks as the Mac last sent them (History's newest page), plus
/// the older History pages loaded on request.
struct TaskLists: Equatable {
    typealias Edit = (id: String, status: AppTask.Status?, toTop: Bool)
    private struct Older: Equatable { var tasks: [AppTask] = []; var next: String? }
    private(set) var observed: [String: AppTasks] = [:]
    private var older: [String: Older] = [:]

    /// What `app` shows: the Mac's list, the older History loaded so far
    /// after it, and `edits` the Mac hasn't confirmed yet laid over.
    func list(app: String, edits: [Edit]) -> AppTasks {
        guard var list = observed[app] else { return AppTasks() }
        if let older = older[app] {
            let seen = Set(list.tasks.map(\.id) + list.history.map(\.id))
            list.history += older.tasks.filter { !seen.contains($0.id) }
            list.historyNext = older.next
        }
        for edit in edits { list = Self.apply(edit, in: list) }
        return list
    }
    /// The newest list from the Mac; with `fresh`, History starts over from its first page.
    mutating func adopt(_ list: AppTasks, for app: String, fresh: Bool = false) {
        if fresh { older[app] = nil }
        observed[app] = list
    }
    /// Where the next older History page starts, if there is one.
    func nextPage(app: String) -> String? {
        if let older = older[app] { return older.next }
        return observed[app]?.historyNext
    }
    /// Adds the page that followed `cursor`, unless a refresh started over meanwhile.
    mutating func append(_ page: AppTasks, after cursor: String, app: String) {
        let now = older[app]?.next ?? observed[app]?.historyNext
        guard now == cursor || older[app]?.next == cursor else { return }
        var pages = older[app] ?? Older()
        pages.tasks += page.history; pages.next = page.historyNext
        older[app] = pages
    }
    /// The app whose list holds `task`, a sub-task included.
    func app(containing task: String) -> String? {
        observed.first { _, list in list.everyTask.contains { $0.id == task } }?.key
    }
    static func apply(_ edit: Edit, in list: AppTasks) -> AppTasks {
        var list = list
        if let index = list.tasks.firstIndex(where: { $0.id == edit.id }) {
            if let status = edit.status { list.tasks[index].status = status }
            if edit.toTop { list.tasks.insert(list.tasks.remove(at: index), at: 0) }
            return list
        }
        // A sub-task: ticked in place, under its work item.
        for (item, task) in list.tasks.enumerated() {
            guard let index = task.subtasks.firstIndex(where: { $0.id == edit.id }) else { continue }
            if let status = edit.status { list.tasks[item].subtasks[index].status = status }
            return list
        }
        return list
    }
}
