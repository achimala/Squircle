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

    private func shell(_ rows:[[String:Any]]) -> JSONValue { .from(["projects":rows]) }
    private func metadata(path:String,name:String = "Renamed app",request:AppBuildRequest? = nil) -> AppMetadata {
        AppMetadata(id:"mac-app",name:name,project:path,scheme:"App",bundleID:"test.app",summary:"",updatedAt:10,preview:nil,buildRequest:request)
    }
    func testNestedCheckoutOwnsItsRecipeAndSimilarPrefixesStaySeparate() throws {
        let snapshot = shell([["id":"parent","title":"Parent","workspaceRoot":"/src/App"],
            ["id":"nested","title":"Nested","workspaceRoot":"/src/App/Child"],
            ["id":"other","title":"Other","workspaceRoot":"/src/AppTwo"]])
        let b = try build(id:"b",title:"App",path:"/src/App/Child/App.xcodeproj")
        let rows = T3AppCatalog.projects(shell:snapshot,metadata:[metadata(path:"/src/App/Child/App.xcodeproj",request:b.request)],builds:[b])
        XCTAssertEqual(rows.map(\.id),["nested"]); XCTAssertTrue(rows[0].canBuild)
    }
    func testSharedWorkspaceOwnerDoesNotDependOnMacListOrder() {
        let snapshot = shell([["id":"repo","title":"Squircle","workspaceRoot":"/src/Repo"]])
        let main = AppMetadata(id:"main",name:"Squircle",project:"/src/Repo/app/Squircle/Squircle.xcodeproj",scheme:"Squircle",
                               bundleID:"a",summary:"",updatedAt:1,preview:nil)
        let probe = AppMetadata(id:"probe",name:"Squircle Probe",project:"/src/Repo/examples/Probe/Probe.xcodeproj",scheme:"Probe",
                                bundleID:"b",summary:"",updatedAt:2,preview:nil)
        XCTAssertEqual(T3AppCatalog.projects(shell:snapshot,metadata:[probe,main],builds:[]).first?.metadataID,"main")
        XCTAssertEqual(T3AppCatalog.projects(shell:snapshot,metadata:[main,probe],builds:[]).first?.metadataID,"main")
        // Its own nested T3 project gives the second app its own place.
        let nested = shell([["id":"repo","title":"Squircle","workspaceRoot":"/src/Repo"],
                            ["id":"probe-t3","title":"Squircle Probe","workspaceRoot":"/src/Repo/examples/Probe"]])
        let rows = T3AppCatalog.projects(shell:nested,metadata:[probe,main],builds:[])
        XCTAssertEqual(rows.map(\.metadataID),["probe","main"])
    }
    /// Home arranges the apps it shows; catalog records it doesn't show
    /// (another app's overlay, a T3 project gone) keep their places.
    func testArrangingHomeKeepsRecordsItDoesNotShowInPlace() {
        XCTAssertEqual(AppOrder.arranged(["a","x","b","c","y"], showing:["c","a","b"]), ["c","x","a","b","y"])
        XCTAssertEqual(AppOrder.arranged(["a","b"], showing:["b","gone","a"]), ["b","a"])
        let records = ["a","b","c"].map { AppMetadata(id:$0,name:$0,project:"/p",scheme:"s",bundleID:nil,summary:"",updatedAt:0,preview:nil) }
        XCTAssertEqual(AppOrder.apply(["c","a"], to: records).map(\.id), ["c","a","b"])
    }
}
