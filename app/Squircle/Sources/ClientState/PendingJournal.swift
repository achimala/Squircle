import Foundation

/// Messages on their way, kept on the phone so one survives the app
/// quitting and is sent again, as itself, when it next runs. One file per
/// message in this app's own Application Support (the app and an app's
/// debug overlay each keep their own; nothing is shared through the
/// Keychain group), readable once the phone has been unlocked since it
/// started, kept out of backups, and removed as soon as T3 has the message
/// or refused it. Writes are atomic and ordered by sequence, so a slow
/// write never replaces a newer one or brings back a removed message.
actor PendingJournal {
    static let schema = 1
    /// Unsent messages may hold this much between them; past it, a new one is refused.
    static let budget = 64 << 20
    let directory: URL?
    private var written: [String: UInt64] = [:]

    private struct File: Codable {
        let schema: Int
        let saved: Delivery.Saved
    }
    struct Contents {
        var saved: [Delivery.Saved] = []
        /// Files that couldn't be read, moved aside rather than lost or resent.
        var unreadable: [String] = []
    }

    init(directory: URL? = PendingJournal.defaultDirectory) { self.directory = directory }
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Squircle", isDirectory: true).appendingPathComponent("pending-sends", isDirectory: true)
    }

    private func url(_ messageID: String) -> URL? {
        guard UUID(uuidString: messageID) != nil else { return nil }
        return directory?.appendingPathComponent(messageID.lowercased() + ".json")
    }

    func load() -> Contents {
        var contents = Contents()
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return contents }
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(File.self, from: data),
               decoded.schema == Self.schema, url(decoded.saved.intent.messageID)?.lastPathComponent == name {
                contents.saved.append(decoded.saved)
            } else {
                // Unreadable, or from a newer build: never resent, never silently dropped.
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
                contents.unreadable.append(name)
            }
        }
        return contents
    }

    /// Saves `saved` unless a later sequence already wrote (or removed) its file.
    func save(_ saved: Delivery.Saved, sequence: UInt64) throws {
        guard let directory, let url = url(saved.intent.messageID) else { throw ClientError.configuration }
        let id = saved.intent.messageID
        guard sequence > written[id] ?? 0 else { return }
        written[id] = sequence
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var folder = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        let data = try JSONEncoder().encode(File(schema: Self.schema, saved: saved))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func forget(_ messageID: String, sequence: UInt64) {
        guard sequence > written[messageID] ?? 0, let url = url(messageID) else { return }
        written[messageID] = sequence
        try? FileManager.default.removeItem(at: url)
    }
}
