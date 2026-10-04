import XCTest

/// Runs against the configured Mac. Creates verification threads and a real
/// signed build; never edits existing conversations or installs on the phone.
final class StudioUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--motion-audit"]
    }

    @MainActor
    func testBrowseMacProjects() throws {
        let folder = "/Users/anshu/Documents/ChatGPT/RemoteAppDev/examples/SquircleProbe"
        app.launch()
        requireHittable(element("project.add"), timeout: 35)
        element("project.add").tap()
        enterMacPath(folder)
        let project = app.cells.matching(identifier: "import.entry")
            .matching(NSPredicate(format: "value == %@", folder + "/SquircleProbe.xcodeproj")).firstMatch
        requireHittable(project, timeout: 30)
        capture("18 — Mac project folder")
        project.tap()
        requireHittable(app.textFields["import.name"], timeout: 45)
        requireHittable(element("import.scheme"))
        requireEnabled(element("import.add"))

        element("import.scheme").tap()
        let scheme = app.cells.containing(.staticText, identifier: "SquircleProbe").firstMatch
        requireHittable(scheme)
        XCTAssertTrue(scheme.isSelected, "The inspected Xcode scheme should be checkmarked.")
        capture("19 — Actual Xcode schemes")
        scheme.tap()
        requireHittable(app.textFields["import.name"], timeout: 45)
        requireEnabled(element("import.add"))
        XCTAssertEqual(element("import.scheme").label, "SquircleProbe")
        // Scheme selection is read-only; deliberately leave Add untouched.
        app.terminate()
    }

    @MainActor
    func testImportExistingMacAppAndPersistRecipe() throws {
        let name = "Squircle Probe"
        let projectPath = "/Users/anshu/Documents/ChatGPT/RemoteAppDev/examples/SquircleProbe/SquircleProbe.xcodeproj"
        app.launch()
        selectProject(named: name)
        let originalID = try XCTUnwrap(element("project.hero").value as? String)
        XCTAssertNotNil(UUID(uuidString: originalID), "The picker exposes the persistent app identity.")
        let originalCopies = registeredHeroes(named: name).count
        XCTAssertEqual(originalCopies, 1, "The existing Probe is the import fixture; this test must not create another app.")
        // Import a different app from the centered hero, exercising the real
        // picker-to-imported-app selection change as well as idempotence.
        selectProject(named: "Squircle")

        element("project.add").tap()
        requireHittable(element("import.path"), timeout: 25)
        requireHittable(element("import.cancel"))
        capture("12 — Browse apps on Mac")

        enterMacPath("/Users/anshu/Documents/ChatGPT/RemoteAppDev/examples/NoSuchSquircleProject.xcodeproj")
        let error = element("import.error")
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label.length > 0"), object: error)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 30), .completed, "An invalid Mac path should report its real lookup error.")
        capture("13 — Invalid Mac path")

        enterMacPath(projectPath)
        let nameField = app.textFields["import.name"]
        requireHittable(nameField, timeout: 45)
        XCTAssertFalse((nameField.value as? String ?? "").isEmpty, "Inspection should infer the app name.")
        requireHittable(element("import.scheme"))
        replaceText(in: nameField, with: name)
        capture("14 — Inspected Xcode app")
        let add = element("import.add")
        requireEnabled(add)
        add.tap()

        requireHittable(element("thread.new"), timeout: 35)
        XCTAssertFalse(element("import.add").exists, "A successful import dismisses its form and opens the app.")
        requireHittable(element("project.builds"))
        capture("15 — Imported app threads")
        assertImportedAppCanBuild()
        element("project.back").tap()
        requireHittable(element("project.hero"))
        XCTAssertEqual(element("project.hero").label, name)
        XCTAssertEqual(element("project.hero").value as? String, originalID, "Reimporting preserves the app's picker and thread identity.")
        XCTAssertEqual(registeredHeroes(named: name).count, originalCopies, "Reimporting the same project and scheme must not duplicate its picker entry.")

        app.terminate()
        app.launch()
        selectProject(named: name)
        XCTAssertEqual(element("project.hero").value as? String, originalID, "The same app identity survives relaunch.")
        element("project.hero").tap()
        requireHittable(element("thread.new"))
        assertImportedAppCanBuild()
        capture("17 — Imported app after relaunch")
        element("project.back").tap()
        requireHittable(element("project.hero"))
        XCTAssertEqual(registeredHeroes(named: name).count, originalCopies)
    }

    @MainActor
    func testCreateSignedBuildOnMac() throws {
        app.launch()
        openProject(named: "Squircle")
        element("project.builds").tap()
        requireHittable(element("builds.close"))
        let existing = Set(elements("build.row").allElementsBoundByIndex.compactMap { $0.value as? String })
        let build = element("project.build")
        requireHittable(build)
        build.tap()
        let latest = elements("build.row").firstMatch
        let submitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard latest.exists, let id = latest.value as? String else { return false }
            return !existing.contains(id)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [submitted], timeout: 20), .completed)
        capture("10 — Build running on Mac")
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Succeeded"), object: latest)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 180), .completed, "The real Xcode archive and export should finish.")
        XCTAssertTrue(element("build.install").isEnabled)
        capture("11 — Signed build ready")
    }

    @MainActor
    func testNavigationAndMotion() throws {
        app.launch()
        let hero = element("project.hero")
        requireHittable(hero, timeout: 35)
        let firstApp = hero.label
        capture("01 — App picker")
        let picker = app.scrollViews["app.picker"]
        picker.swipeLeft(velocity: .slow)
        if !waitForHeroChange(from: firstApp) {
            picker.swipeRight(velocity: .slow)
            XCTAssertTrue(waitForHeroChange(from: firstApp), "The live picker should include another registered app.")
        }
        capture("01b — Another app")
        selectProject(named: firstApp)
        openProject(named: "Squircle")
        capture("02 — App threads")

        // A short physical edge drag, held still before release, should cancel.
        // The endpoint stays below the gesture's distance threshold; the hold
        // avoids accidentally finishing through release velocity.
        edgeDrag(to: 0.18)
        requireHittable(element("project.builds"))
        requireHittable(element("thread.new"))
        capture("02b — Cancelled edge gesture")
        edgeDrag(to: 0.82)
        requireHittable(element("project.hero"))
        XCTAssertFalse(element("project.builds").exists)
        openProject(named: "Squircle")

        // A fresh installation can legitimately have no mapped thread yet.
        // In that case create an empty real thread, close it, then navigate the
        // persisted thread row exactly as an existing user would.
        let firstThread = elements("thread.row").firstMatch
        if !firstThread.waitForExistence(timeout: 5) {
            element("thread.new").tap()
            waitForThread()
            element("thread.close").tap()
            waitForThreadDismissal()
        }
        XCTAssertTrue(firstThread.waitForExistence(timeout: 20), "The workspace should show its real Hermes thread.")
        reveal(firstThread)
        firstThread.tap()
        waitForThread()
        capture("03 — Existing thread sheet")
        element("thread.close").tap()
        waitForThreadDismissal()

        element("project.builds").tap()
        requireHittable(element("builds.close"))
        requireHittable(element("project.build"))
        capture("04 — Builds sheet")
        element("builds.close").tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("builds.close"))
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed)
        requireHittable(element("project.back"))
        element("project.back").tap()
        requireHittable(element("project.hero"))
        XCTAssertFalse(element("project.builds").exists)
        capture("05 — Returned to picker")
    }

    @MainActor
    func testThreadRoundTrip() throws {
        app.launch()
        let hero = element("project.hero")
        requireHittable(hero, timeout: 35)
        let projectName = hero.label
        XCTAssertFalse(projectName.isEmpty)
        hero.tap()
        requireHittable(element("thread.new"))
        element("thread.new").tap()
        waitForThread()

        let input = app.textViews["thread.input"]
        requireHittable(input)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        capture("06 — Thread keyboard")
        input.typeText("Reply exactly SQUIRCLE_DESIGN_OK. Do not use tools.")
        let send = element("thread.send")
        requireEnabled(send)
        capture("07 — Composed verification message")
        send.tap()

        let reply = exactReply()
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "The live Hermes response should arrive in the native thread.")
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Send message"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 25), .completed, "Wait for the real run to finish before testing persistence.")
        XCTAssertEqual(input.value as? String ?? "", "", "Sending clears the composer without replacing its text view.")
        capture("08 — Live Hermes reply")
        element("thread.close").tap()
        waitForThreadDismissal()

        // The new thread is first in the model's recency-sorted list. Record its
        // actual session ID, then reopen that same server-backed thread after
        // restarting the app, rather than matching a potentially reused title.
        let newThread = elements("thread.row").firstMatch
        XCTAssertTrue(newThread.waitForExistence(timeout: 20))
        let sessionID = try XCTUnwrap(newThread.value as? String, "thread.row exposes its persistent session ID as accessibilityValue.")
        XCTAssertFalse(sessionID.isEmpty)
        app.terminate()
        app.launch()
        openProject(named: projectName)
        let persistedThread = elements("thread.row").matching(NSPredicate(format: "value == %@", sessionID)).firstMatch
        XCTAssertTrue(persistedThread.waitForExistence(timeout: 25), "The same session must remain attached to its app after relaunch.")
        reveal(persistedThread)
        persistedThread.tap()
        waitForThread()
        XCTAssertTrue(exactReply().waitForExistence(timeout: 30), "Reopening must load the persisted Hermes response.")
        capture("09 — Persisted conversation")
        element("thread.close").tap()
        waitForThreadDismissal()
        element("project.back").tap()
        requireHittable(element("project.hero"))
    }

    @MainActor
    private func openProject(named name: String) {
        selectProject(named: name)
        element("project.hero").tap()
        requireHittable(element("thread.new"))
    }

    @MainActor
    private func enterMacPath(_ path: String) {
        requireHittable(element("import.path"))
        element("import.path").tap()
        let input = app.textFields["import.path.input"]
        requireHittable(input)
        replaceText(in: input, with: path)
        requireHittable(element("import.path.go"))
        element("import.path.go").tap()
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        if field.value as? String == text { return }
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty,
           existing != field.placeholderValue {
            let clear = field.buttons.firstMatch
            if clear.exists && clear.isHittable {
                clear.tap()
            } else {
                // App names fit in this field. Tapping its trailing whitespace
                // puts insertion after the text instead of deleting a prefix.
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.utf16.count))
            }
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Enter the complete value before submitting to the Mac.")
    }

    @MainActor
    private func registeredHeroes(named name: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (identifier == %@ OR identifier BEGINSWITH %@)",
            name, "project.hero", "project.picker."
        ))
    }

    @MainActor
    private func assertImportedAppCanBuild() {
        element("project.builds").tap()
        requireHittable(element("builds.close"))
        requireHittable(element("project.build"))
        requireEnabled(element("project.build"))
        capture("16 — Imported app build action")
        // Importing should make the saved recipe usable; do not submit another
        // archive or mutate existing build history just to check its affordance.
        element("builds.close").tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("builds.close"))
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed)
        requireHittable(element("project.back"))
    }

    @MainActor
    private func selectProject(named name: String) {
        let hero = element("project.hero")
        requireHittable(hero, timeout: 35)
        if hero.label == name { return }
        let picker = app.scrollViews["app.picker"]
        for direction in [true, false] {
            for _ in 0..<12 {
                let previous = hero.label
                if direction { picker.swipeLeft(velocity: .slow) }
                else { picker.swipeRight(velocity: .slow) }
                if hero.label == name { return }
                if !waitForHeroChange(from: previous) { break }
                if hero.label == name { return }
            }
        }
        XCTFail("Could not find the registered app \(name) in the live picker.")
    }

    @MainActor
    private func waitForHeroChange(from name: String) -> Bool {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", name), object: element("project.hero"))
        return XCTWaiter.wait(for: [changed], timeout: 2) == .completed
    }

    @MainActor
    private func edgeDrag(to fraction: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 2, dy: app.frame.height * 0.48))
        let end = origin.withOffset(CGVector(dx: app.frame.width * fraction, dy: app.frame.height * 0.48))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    @MainActor
    private func waitForThread() {
        requireHittable(element("thread.close"), timeout: 20)
        XCTAssertTrue(app.textViews["thread.input"].waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Opening thread…"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed, "Thread selection must finish before interaction.")
    }

    @MainActor
    private func waitForThreadDismissal() {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("thread.close"))
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed)
        requireHittable(element("thread.new"))
    }

    @MainActor
    private func exactReply() -> XCUIElement {
        // Match the whole response, so the request text containing this marker
        // cannot make a failed or missing assistant response pass the test.
        app.textViews.matching(NSPredicate(format: "value MATCHES %@", "^\\s*SQUIRCLE_DESIGN_OK\\s*$")).firstMatch
    }

    @MainActor
    private func reveal(_ target: XCUIElement) {
        for _ in 0..<6 {
            if target.isHittable { return }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(target.isHittable, "Expected the target to become visible within the workspace.")
    }

    @MainActor
    private func requireHittable(_ target: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, "Expected a visible interactive control.", file: file, line: line)
    }

    @MainActor
    private func requireEnabled(_ target: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement { elements(identifier).firstMatch }

    @MainActor
    private func elements(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    @MainActor
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        // Keep PNGs directly accessible even when Xcode stalls packaging an
        // xcresult on this SDK. These are unmodified simulator screenshots.
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let output = directory.appendingPathComponent("SquircleVerification", isDirectory: true)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
