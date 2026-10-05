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

/// T3 IDs own navigation and thread membership. The Mac catalog enriches the
/// matching checkout without deriving identity from app names or chat titles.
enum T3AppCatalog {
    static func projects(shell:JSONValue,metadata:[AppMetadata],builds:[AppBuild]) -> [AppProject] {
        let projects = shell["projects"].array.filter { $0["deletedAt"] == .null }
        func owner(_ path:String) -> String? {
            projects.filter {
                let root = $0["workspaceRoot"].string ?? ""
                return !root.isEmpty && (path == root || path.hasPrefix(root + "/"))
            }.max { ($0["workspaceRoot"].string ?? "").count < ($1["workspaceRoot"].string ?? "").count }?["id"].string
        }
        return projects.map { p in
            let id = p["id"].string ?? ""
            let record = metadata.first { owner($0.project) == id }
            let related = builds.filter { $0.request.map { owner($0.project) == id } ?? false }
            let request = record?.buildRequest ?? related.filter { $0.request?.mode == "archive" }.sorted { $0.date > $1.date }.first?.request
            return AppProject(id:id,name:record?.name ?? p["title"].string ?? "App",subtitle:"",
                bundleID:record?.bundleID,canBuild:request?.canSubmit ?? false,updatedAt:p["updatedAt"].date,
                buildRequest:request,metadataID:record?.id,metadataPreview:record?.preview)
        }
    }
}
