import Foundation
import XCTest
@testable import Squircle

final class AppProjectTests: XCTestCase {
    private func build(id: String, title: String, bundle: String? = nil, path: String? = nil,
                       scheme: String? = nil, state: String = "succeeded", date: Int = 10, mode: String = "archive") throws -> AppBuild {
        var json: [String: Any] = ["id": id, "state": state, "created_at": date]
        if state == "succeeded" {
            var output: [String: Any] = ["title": title, "version": "1.0", "build_number": "1", "ipa_path": "/build/app.ipa"]
            if let bundle { output["bundle_id"] = bundle }
            json["output"] = output
        }
        if let path {
            json["request"] = ["project": path, "scheme": scheme ?? title, "configuration": "Release", "mode": mode,
                               "export_options": "/build/ExportOptions.plist", "allow_provisioning_updates": false, "request_id": "old-request"]
        }
        return try JSONDecoder().decode(AppBuild.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testQueuedArchivedAndImportedBuildsResolveToOneAppAndKeepAnotherSeparate() throws {
        var catalog = AppProjectCatalog()
        let builds = try [
            build(id: "queued", title: "Atlas", path: "/src/Atlas.xcworkspace", state: "queued", date: 1),
            build(id: "archive", title: "Atlas", bundle: "test.atlas", path: "/src/Atlas.xcworkspace", date: 2),
            build(id: "imported", title: "Atlas", bundle: "test.atlas", date: 3),
            build(id: "other", title: "Other", bundle: "test.other", path: "/src/Other.xcodeproj", date: 4)
        ]
        let projects = catalog.reconcile(builds: builds, sessions: [])
        let atlas = try XCTUnwrap(projects.first { $0.name == "Atlas" })
        XCTAssertEqual(projects.filter { $0.name == "Atlas" }.count, 1)
        XCTAssertEqual(atlas.bundleID, "test.atlas")
        XCTAssertTrue(atlas.canBuild)
        XCTAssertEqual(atlas.buildRequest?.project, "/src/Atlas.xcworkspace")
        XCTAssertEqual(catalog.buildProjects["queued"], atlas.id)
        XCTAssertEqual(catalog.buildProjects["archive"], atlas.id)
        XCTAssertEqual(catalog.buildProjects["imported"], atlas.id)
        XCTAssertNotEqual(catalog.buildProjects["other"], atlas.id)
    }

    func testLocalIdeaGainsARealRecipeAndExplicitThreadMappingSurvivesRestart() throws {
        var catalog = AppProjectCatalog()
        let id = catalog.create(name: "Mood Tracker")
        var projects = catalog.reconcile(builds: [], sessions: [])
        let idea = try XCTUnwrap(projects.first { $0.id == id })
        XCTAssertFalse(idea.canBuild)
        XCTAssertTrue(idea.agentContext.contains("No Xcode build configuration"))
        catalog.assign(sessionID: "hermes-thread", to: id)
        let actual = try build(id: "build", title: "MoodTracker", bundle: "test.mood", path: "/src/MoodTracker.xcodeproj")
        let sessions = [ChatSession(id: "hermes-thread", title: "Design the empty state")]
        projects = catalog.reconcile(builds: [actual], sessions: sessions)
        let configured = try XCTUnwrap(projects.first { $0.id == id })
        XCTAssertTrue(configured.canBuild)
        XCTAssertEqual(configured.name, "Mood Tracker")
        XCTAssertEqual(catalog.buildProjects["build"], id)
        let bytes = try JSONEncoder().encode(catalog)
        var restored = try JSONDecoder().decode(AppProjectCatalog.self, from: bytes)
        _ = restored.reconcile(builds: [actual], sessions: sessions)
        XCTAssertEqual(restored.sessionProjects["hermes-thread"], id)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Design the empty state"), "Catalog persisted conversation content")
    }

    func testExistingNamedChatsMigrateAndAmbiguousNamesStayInSquircle() throws {
        var catalog = AppProjectCatalog()
        let actual = try build(id: "atlas", title: "Atlas", bundle: "test.atlas", path: "/src/Atlas.xcodeproj")
        let projects = catalog.reconcile(builds: [actual], sessions: [
            ChatSession(id: "specific", title: "Atlas · Development"),
            ChatSession(id: "unassigned", title: "An unrelated conversation")
        ])
        XCTAssertEqual(catalog.sessionProjects["specific"], projects.first { $0.name == "Atlas" }?.id)
        XCTAssertEqual(catalog.sessionProjects["unassigned"], AppProjectCatalog.homeID)
    }

    func testSameDisplayNameWithDifferentKnownBundleIdentifiersDoesNotMergeApps() throws {
        var catalog = AppProjectCatalog()
        let projects = catalog.reconcile(builds: try [
            build(id: "a", title: "Demo", bundle: "test.demoA"),
            build(id: "b", title: "Demo", bundle: "test.demoB", date: 11)
        ], sessions: [])
        XCTAssertEqual(projects.filter { $0.name == "Demo" }.count, 2)
        XCTAssertNotEqual(catalog.buildProjects["a"], catalog.buildProjects["b"])
    }

    func testBuildRecipeContextAndFreshSubmissionKeepExactSettingsWithoutOldRequestID() throws {
        let actual = try build(id: "build", title: "Atlas", bundle: "test.atlas", path: "/src/Atlas.xcworkspace")
        let request = try XCTUnwrap(actual.request)
        let fresh = request.freshSubmission(id: "new-request")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        XCTAssertEqual(body["project"] as? String, "/src/Atlas.xcworkspace")
        XCTAssertEqual(body["mode"] as? String, "archive")
        XCTAssertEqual(body["request_id"] as? String, "new-request")
        XCTAssertEqual(body["allow_provisioning_updates"] as? Bool, false)
        var catalog = AppProjectCatalog()
        let project = try XCTUnwrap(catalog.reconcile(builds: [actual], sessions: []).first { $0.name == "Atlas" })
        XCTAssertTrue(project.agentContext.contains("test.atlas"))
        XCTAssertTrue(project.agentContext.contains("Atlas.xcworkspace"))
        XCTAssertFalse(project.agentContext.contains("old-request"))
    }

    func testLaterSimulatorVerificationDoesNotReplaceAnInstallableArchiveRecipe() throws {
        var catalog = AppProjectCatalog()
        let archive = try build(id: "archive", title: "Atlas", bundle: "test.atlas", path: "/src/Atlas.xcodeproj", date: 1)
        let simulator = try build(id: "simulator", title: "Atlas", bundle: "test.atlas", path: "/src/Atlas.xcodeproj", date: 2, mode: "simulator")
        let project = try XCTUnwrap(catalog.reconcile(builds: [archive, simulator], sessions: []).first { $0.name == "Atlas" })
        XCTAssertEqual(project.buildRequest?.mode, "archive")
        XCTAssertTrue(project.canBuild)
    }
}
