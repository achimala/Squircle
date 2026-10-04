import Foundation

struct DiagnosticEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case launch, log, crash }

    let eventID: String
    let buildID: String
    let kind: Kind
    let message: String
    let timestamp: Int
    var attributes: [String: String]
    var id: String { eventID }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", buildID = "build_id"
        case kind, message, timestamp, attributes
    }

    init(buildID: String, kind: Kind, message: String,
         eventID: String = UUID().uuidString, timestamp: Int = Int(Date().timeIntervalSince1970),
         attributes: [String: String] = [:]) {
        // Foundation emits uppercase UUIDs; the server's wire format is canonical
        // lowercase. Normalize recovered IDs too, without changing their identity.
        self.eventID = UUID(uuidString: eventID)?.uuidString.lowercased() ?? eventID
        self.buildID = buildID
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
        self.attributes = attributes
    }
}

struct ProbeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Persists before acknowledging an enqueue; capacity errors never silently discard evidence.
final class PersistentEventQueue {
    static let eventByteLimit = 1_048_576
    static let messageByteLimit = 512 * 1024
    private let file: URL
    private let maxCount: Int
    private let maxBytes: Int
    private(set) var events: [DiagnosticEvent]

    init(file: URL, maxCount: Int = 128, maxBytes: Int = 8 * 1_048_576) throws {
        self.file = file
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= maxBytes else { throw ProbeError("Stored queue exceeds its size limit; preserve and inspect it.") }
            events = try JSONDecoder().decode([DiagnosticEvent].self, from: data)
        } else {
            events = []
        }
    }

    func append(_ event: DiagnosticEvent) throws {
        guard UUID(uuidString: event.eventID) != nil, !event.buildID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProbeError("An event needs a UUID and a nonempty build ID.")
        }
        guard event.timestamp >= 0, !event.message.isEmpty,
              event.message.utf8.count <= Self.messageByteLimit else {
            throw ProbeError("Message must be nonempty and at most 512 KiB, with a valid timestamp; evidence retained.")
        }
        guard try JSONEncoder().encode(event).count < Self.eventByteLimit else {
            throw ProbeError("Event exceeds 1 MiB; original evidence has not been purged.")
        }
        if events.contains(where: { $0.id == event.id }) { return }
        guard events.count < maxCount else { throw ProbeError("Queue full (\(maxCount) events). Retry uploads before adding more.") }
        try commit(events + [event])
    }

    func acknowledge(_ id: String) throws {
        try commit(events.filter { $0.id != id })
    }

    private func commit(_ next: [DiagnosticEvent]) throws {
        let data = try JSONEncoder().encode(next)
        guard data.count <= maxBytes else { throw ProbeError("Queue storage limit reached. Retry uploads first.") }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        events = next
    }
}
