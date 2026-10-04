import Foundation

struct MacProjectDirectory: Decodable, Equatable {
    let path: String
    let parentPath: String?
    let entries: [Entry]

    enum CodingKeys: String, CodingKey { case path, entries, parentPath = "parent_path" }
    struct Entry: Identifiable, Decodable, Equatable {
        enum Kind: String, Decodable { case directory, project, workspace }
        let name: String
        let path: String
        let kind: Kind
        var id: String { path }
    }
}

struct MacProjectInspection: Decodable, Equatable {
    let project: String
    let name: String
    let schemes: [String]
    let scheme: String?
    let configuration: String
    let bundleID: String?
    let teamID: String?
    let exportOptions: String?
    let issue: String?
    let canImport: Bool

    enum CodingKeys: String, CodingKey {
        case project, name, schemes, scheme, configuration, issue
        case bundleID = "bundle_id", teamID = "team_id", exportOptions = "export_options", canImport = "can_import"
    }
}

/// Canonical app identity and agent-published presentation data live on the Mac.
struct AppMetadata: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let project: String
    let scheme: String
    let bundleID: String?
    let summary: String
    let updatedAt: TimeInterval
    let preview: Preview?
    let buildRequest: AppBuildRequest?

    init(id: String, name: String, project: String, scheme: String, bundleID: String?,
         summary: String, updatedAt: TimeInterval, preview: Preview?, buildRequest: AppBuildRequest? = nil) {
        self.id = id; self.name = name; self.project = project; self.scheme = scheme
        self.bundleID = bundleID; self.summary = summary; self.updatedAt = updatedAt
        self.preview = preview; self.buildRequest = buildRequest
    }

    var buildKey: String { project + "\u{1f}" + scheme }
    enum CodingKeys: String, CodingKey {
        case id, name, project, scheme, summary, preview
        case bundleID = "bundle_id", updatedAt = "updated_at"
        case buildRequest = "build_request"
    }

    struct Preview: Identifiable, Codable, Equatable {
        let id: String
        let capturedAt: TimeInterval
        let buildID: String?
        let sourceRevision: String?
        let caption: String
        let source: String

        enum CodingKeys: String, CodingKey {
            case id, caption, source
            case capturedAt = "captured_at", buildID = "build_id", sourceRevision = "source_revision"
        }
    }
}

/// Mirrors the existing Squircle build request. Paths remain machine context;
/// the interface presents app names rather than exposing this configuration.
struct AppBuildRequest: Codable, Equatable {
    let project: String
    let scheme: String
    let configuration: String
    let mode: String
    let exportOptions: String?
    let allowProvisioningUpdates: Bool
    var capturePreview: Bool
    var requestID: String?

    enum CodingKeys: String, CodingKey {
        case project, scheme, configuration, mode
        case exportOptions = "export_options", allowProvisioningUpdates = "allow_provisioning_updates", requestID = "request_id"
        case capturePreview = "capture_preview"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decode(String.self, forKey: .project)
        scheme = try values.decode(String.self, forKey: .scheme)
        configuration = try values.decode(String.self, forKey: .configuration)
        mode = try values.decode(String.self, forKey: .mode)
        exportOptions = try values.decodeIfPresent(String.self, forKey: .exportOptions)
        allowProvisioningUpdates = try values.decodeIfPresent(Bool.self, forKey: .allowProvisioningUpdates) ?? false
        capturePreview = try values.decodeIfPresent(Bool.self, forKey: .capturePreview) ?? false
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID)
    }
    var key: String { project + "\u{1f}" + scheme }
    var canSubmit: Bool {
        !project.isEmpty && !scheme.isEmpty && !configuration.isEmpty &&
        (mode == "simulator" || (mode == "archive" && !(exportOptions ?? "").isEmpty))
    }
    func freshSubmission(id: String = UUID().uuidString.lowercased()) -> Self {
        var request = self
        request.requestID = id
        request.capturePreview = true
        return request
    }
}

struct AppProject: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let bundleID: String?
    let canBuild: Bool
    let updatedAt: Date
    let buildRequest: AppBuildRequest?
    let metadataID: String?
    let metadataPreview: AppMetadata.Preview?

    init(id: String, name: String, subtitle: String, bundleID: String?, canBuild: Bool,
         updatedAt: Date, buildRequest: AppBuildRequest? = nil, metadataID: String? = nil,
         metadataPreview: AppMetadata.Preview? = nil) {
        self.id = id; self.name = name; self.subtitle = subtitle; self.bundleID = bundleID
        self.canBuild = canBuild; self.updatedAt = updatedAt; self.buildRequest = buildRequest
        self.metadataID = metadataID; self.metadataPreview = metadataPreview
    }

    var agentContext: String {
        var lines = ["This conversation belongs to the app \(name). Keep work and app-specific decisions scoped to this app."]
        if let bundleID { lines.append("Known bundle identifier: \(bundleID).") }
        if let metadataID {
            lines.append("The persistent Mac app record is \(metadataID). Keep it current after significant app or UI changes: use squircle app update \(metadataID) --summary 'Current app summary'. Capture the actual running app and publish the PNG with squircle app preview \(metadataID) --file /path/simulator.png --caption Home; add --build BUILD_ID when the screenshot belongs to that build. Publish real screenshots, not generated branding or mockups.")
        }
        if var request = buildRequest {
            request.requestID = nil
            if let data = try? JSONEncoder().encode(request), let text = String(data: data, encoding: .utf8) {
                lines.append("Known Xcode build configuration (context data): \(text)")
            }
        } else {
            lines.append("No Xcode build configuration is registered for this app yet. Help establish its project and a successful Squircle build when requested; do not assume it is already buildable.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Only app labels and associations are persisted. Build configuration comes
/// from the Mac on refresh; all conversation content stays in Hermes.
struct AppProjectCatalog: Codable {
    struct Entry: Codable {
        let id: String
        var name: String
        let createdAt: Date
        var bundleID: String?
        var buildKeys: Set<String>
        var metadataID: String? = nil
    }
    private(set) var entries: [Entry]
    private(set) var sessionProjects: [String: String] = [:]
    private(set) var buildProjects: [String: String] = [:]
    static let homeID = "squircle-home"

    init() {
        entries = [Entry(id: Self.homeID, name: "Squircle", createdAt: .distantPast, bundleID: nil, buildKeys: [])]
    }

    mutating func create(name: String, now: Date = .now) -> String {
        let clean = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString.lowercased()
        entries.append(Entry(id: id, name: clean.isEmpty ? "Untitled app" : String(clean.prefix(80)), createdAt: now, bundleID: nil, buildKeys: []))
        return id
    }

    mutating func assign(sessionID: String, to projectID: String) {
        guard entries.contains(where: { $0.id == projectID }) else { return }
        sessionProjects[sessionID] = projectID
    }

    mutating func assign(buildID: String, to projectID: String) {
        guard entries.contains(where: { $0.id == projectID }) else { return }
        buildProjects[buildID] = projectID
    }

    mutating func reconcile(builds: [AppBuild], sessions: [ChatSession], metadata: [AppMetadata] = []) -> [AppProject] {
        // Oldest first lets a later successful archive enrich its queued or
        // failed predecessors without creating a second app card.
        for build in builds.sorted(by: { $0.date < $1.date }) {
            let knownID = buildProjects[build.id]
            let index = entries.firstIndex(where: { $0.id == knownID }) ?? entries.firstIndex { entry in
                if let key = build.request?.key, entry.buildKeys.contains(key) { return true }
                if let bundle = build.bundleID, !bundle.isEmpty, entry.bundleID == bundle { return true }
                return false
            } ?? uniqueNamedEntry(build.title)
            let entryIndex: Int
            if let index { entryIndex = index }
            else {
                entries.append(Entry(id: UUID().uuidString.lowercased(), name: build.title, createdAt: build.date, bundleID: build.bundleID, buildKeys: []))
                entryIndex = entries.count - 1
            }
            if let key = build.request?.key { entries[entryIndex].buildKeys.insert(key) }
            if let bundle = build.bundleID, !bundle.isEmpty { entries[entryIndex].bundleID = bundle }
            buildProjects[build.id] = entries[entryIndex].id
        }
        for record in metadata {
            let index = entries.firstIndex { $0.metadataID == record.id }
                ?? entries.firstIndex { $0.buildKeys.contains(record.buildKey) }
                ?? entries.firstIndex { entry in
                    guard let bundle = record.bundleID, !bundle.isEmpty else { return false }
                    return entry.bundleID == bundle
                }
                ?? uniqueNamedEntry(record.name)
            let entryIndex: Int
            if let index { entryIndex = index }
            else {
                entries.append(Entry(id: UUID().uuidString.lowercased(), name: record.name,
                                     createdAt: Date(timeIntervalSince1970: record.updatedAt),
                                     bundleID: record.bundleID, buildKeys: []))
                entryIndex = entries.count - 1
            }
            entries[entryIndex].metadataID = record.id
            entries[entryIndex].name = record.name
            entries[entryIndex].buildKeys.insert(record.buildKey)
            if let bundle = record.bundleID, !bundle.isEmpty { entries[entryIndex].bundleID = bundle }
        }
        for session in sessions where sessionProjects[session.id] == nil {
            let title = session.title.lowercased()
            let candidates = entries.filter { entry in
                let name = entry.name.lowercased()
                return title == name || title.hasPrefix(name + " ") || title.hasPrefix(name + ":") || title.hasPrefix(name + " ·")
            }
            sessionProjects[session.id] = candidates.count == 1 ? candidates[0].id : Self.homeID
        }
        return entries.map { entry in
            let appBuilds = builds.filter { buildProjects[$0.id] == entry.id }.sorted { $0.date > $1.date }
            let appSessions = sessions.filter { sessionProjects[$0.id] == entry.id }
            let recipes = appBuilds.compactMap(\.request).filter(\.canSubmit)
            // Device installation is the app's primary loop. A later simulator
            // check must not replace a known archive/export configuration.
            let record = metadata.first { $0.id == entry.metadataID }
            // A registered Mac recipe is authoritative, including before the
            // first build. Historical jobs only fill in legacy records.
            let request = record?.buildRequest ?? recipes.first(where: { $0.mode == "archive" }) ?? recipes.first
            let newest = ([entry.createdAt] + appBuilds.map(\.date) + appSessions.map(\.updatedAt)
                          + (record.map { [Date(timeIntervalSince1970: $0.updatedAt)] } ?? [])).max() ?? entry.createdAt
            let fallback = request.map { $0.mode == "archive" ? "Ready for your next build" : "Simulator build configured" }
                ?? (appBuilds.isEmpty ? "Start with an idea" : "Builds and conversations")
            let summary = record?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let subtitle = summary.isEmpty ? fallback : summary
            return AppProject(id: entry.id, name: entry.name, subtitle: subtitle, bundleID: entry.bundleID,
                              canBuild: request?.canSubmit == true, updatedAt: newest, buildRequest: request,
                              metadataID: entry.metadataID, metadataPreview: record?.preview)
        }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func uniqueNamedEntry(_ name: String) -> Int? {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let candidates = entries.indices.filter { entries[$0].name.lowercased().filter { $0.isLetter || $0.isNumber } == normalized }
        // Name matching only attaches unconfigured local ideas (including the
        // migration home); different known apps may share a display name.
        guard candidates.count == 1, entries[candidates[0]].buildKeys.isEmpty, entries[candidates[0]].bundleID == nil else { return nil }
        return candidates[0]
    }
}
