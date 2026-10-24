import Foundation
import UIKit

/// A least-recently-used store with a total cost budget. Entries over the
/// budget are evicted oldest first; `evicted` hears about each one.
struct BoundedCache<Key: Hashable, Value> {
    let budget: Int
    private let cost: (Value) -> Int
    private var entries: [Key: (value: Value, cost: Int, used: UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var total = 0
    init(budget: Int, cost: @escaping (Value) -> Int = { _ in 1 }) { self.budget = budget; self.cost = cost }
    var count: Int { entries.count }
    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock += 1; entries[key]?.used = clock
        return entry.value
    }
    /// Without counting as a use.
    func peek(_ key: Key) -> Value? { entries[key]?.value }
    /// Stores `value`; returns the values that no longer fit, the replaced
    /// one included.
    @discardableResult
    mutating func set(_ value: Value, for key: Key) -> [Value] {
        var dropped: [Value] = []
        if let old = removeValue(for: key) { dropped.append(old) }
        clock += 1
        let c = max(0, cost(value))
        entries[key] = (value, c, clock); total += c
        while total > budget, entries.count > 1,
              let oldest = entries.lazy.filter({ $0.key != key }).min(by: { $0.value.used < $1.value.used })?.key,
              let value = removeValue(for: oldest) { dropped.append(value) }
        return dropped
    }
    @discardableResult
    mutating func removeValue(for key: Key) -> Value? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        total -= entry.cost
        return entry.value
    }
    /// Empties the cache; returns what it held.
    @discardableResult
    mutating func removeAll() -> [Value] {
        let values = entries.values.map(\.value)
        entries.removeAll(); total = 0
        return values
    }
}

/// The values used most recently, at most `limit`, the least recently used
/// dropped first. Emptied when the system runs low on memory: everything in
/// it can be measured or loaded again.
@MainActor
final class RecentCache<Key: Hashable, Value> {
    private let limit: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private let pressure: Task<Void, Never>

    init(limit: Int) {
        self.limit = limit
        let emptied = WeakBox<RecentCache>()
        pressure = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                guard let cache = emptied.value else { return }
                cache.removeAll()
            }
        }
        emptied.value = self
    }

    deinit { pressure.cancel() }

    func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ value: Value?, for key: Key) {
        guard let value else { values[key] = nil; order.removeAll { $0 == key }; return }
        values[key] = value
        touch(key)
        while order.count > limit { values[order.removeFirst()] = nil }
    }

    func removeAll() {
        values = [:]
        order = []
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

@MainActor
private final class WeakBox<Object: AnyObject> {
    weak var value: Object?
}

/// Squircle's copies of Home and of threads on disk, read and written off
/// the main actor, one at a time. Every write carries a generation; one
/// older than what a file already holds is dropped, so a slow snapshot never
/// replaces a newer one.
actor DiskCache {
    struct Home: Codable { var shell: JSONValue; var metadata: [AppMetadata] }
    let root: URL?
    private var written: [String: UInt64] = [:]
    init(root: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) { self.root = root }
    /// Copies from T3's protocol 2 (T3 0.1.0). Ones from before it hold
    /// 0.0.45's threads and sequences, and are deleted unread.
    private var homeURL: URL? { root?.appendingPathComponent("squircle-home-v2.json") }
    private var legacy: [URL] { ["squircle-home.json", "squircle-threads"].compactMap { root?.appendingPathComponent($0) } }
    private nonisolated func threadURL(_ id: String) -> URL? {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        return root?.appendingPathComponent("squircle-threads-v2", isDirectory: true).appendingPathComponent(id + ".json")
    }
    func loadHome() -> Home? {
        for url in legacy { try? FileManager.default.removeItem(at: url) }
        return read(homeURL)
    }
    func saveHome(_ home: Home, generation: UInt64) { write(home, to: homeURL, generation: generation) }
    /// A copy on disk is never live: T3 confirms or replaces it. Read off
    /// the actor, several at once (files are replaced whole, never half written).
    nonisolated func loadThread(_ id: String) async -> T3ThreadState? { (read(threadURL(id)) as T3ThreadState?)?.restored }
    func saveThread(_ id: String, _ state: T3ThreadState, generation: UInt64) { write(state, to: threadURL(id), generation: generation) }
    private nonisolated func read<T: Decodable>(_ url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    /// True if `value` was written.
    @discardableResult
    func write<T: Encodable>(_ value: T, to url: URL?, generation: UInt64) -> Bool {
        guard let url, generation > written[url.path] ?? 0, let data = try? JSONEncoder().encode(value) else { return false }
        written[url.path] = generation
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
