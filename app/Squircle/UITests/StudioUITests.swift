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
    func testNewThreadAfterExistingThreadStaysAnEmptyDraft() throws {
        app.launchEnvironment = ["SQUIRCLE_APP":"Squircle"]
        app.launch()
        requireHittable(element("project.hero"),timeout:35)
        selectProject(named:"Squircle")
        pullList(from:0.80,to:0.40)
        let row = elements("thread.row").firstMatch
        requireHittable(row)
        row.tap()
        waitForThread()
        element("thread.close").tap()
        waitForThreadDismissal()
        element("thread.new").tap()
        waitForThread()
        requireHittable(element("draft.models"))
        XCTAssertTrue(app.staticTexts["New thread"].exists)
        XCTAssertTrue(app.staticTexts["What’s next?"].exists)
        XCTAssertFalse(element("thread.messages").exists)
        capture("New thread — quick models")
        let choices = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","draft.model."))
        XCTAssertGreaterThan(choices.count,0)
        choices.element(boundBy:choices.count - 1).tap()
        XCTAssertFalse(element("thread.messages").exists)
        element("thread.close").tap()
        waitForThreadDismissal()
        element("thread.new").tap()
        requireHittable(element("draft.models"))
        XCTAssertTrue(app.staticTexts["New thread"].exists)
        XCTAssertFalse(element("thread.messages").exists)
    }

    @MainActor
    func testDraftApprovalOptions() {
        app.launchEnvironment = ["SQUIRCLE_APP":"Squircle", "SQUIRCLE_SCRUB":"1", "SQUIRCLE_DRAFT":"1"]
        app.launch()
        let agent = element("thread.agent")
        requireHittable(agent, timeout:35)
        XCTAssertTrue(agent.label.hasSuffix(" · Auto"))
        agent.tap()
        for title in ["Ask", "Auto edits", "Auto", "Full access"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout:5))
        }
        capture("Approval mode options")
        app.buttons["Auto edits"].tap()
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label ENDSWITH %@", " · Auto edits"), object:agent)
        XCTAssertEqual(XCTWaiter.wait(for:[changed], timeout:5), .completed)
        agent.tap()
        app.buttons["Auto"].tap()
        let restored = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label ENDSWITH %@", " · Auto"), object:agent)
        XCTAssertEqual(XCTWaiter.wait(for:[restored], timeout:5), .completed)
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
        requireHittable(element("project.hero"))
        XCTAssertEqual(element("project.hero").label, name)
        XCTAssertEqual(element("project.hero").value as? String, originalID, "Reimporting preserves the app's picker and thread identity.")
        XCTAssertEqual(registeredHeroes(named: name).count, originalCopies, "Reimporting the same project and scheme must not duplicate its picker entry.")

        app.terminate()
        app.launch()
        selectProject(named: name)
        XCTAssertEqual(element("project.hero").value as? String, originalID, "The same app identity survives relaunch.")
        requireHittable(element("thread.new"))
        assertImportedAppCanBuild()
        capture("17 — Imported app after relaunch")
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
        capture("01 — Home")
        let picker = app.scrollViews["app.picker"]
        picker.swipeLeft(velocity: .slow)
        if !waitForHeroChange(from: firstApp) {
            picker.swipeRight(velocity: .slow)
            XCTAssertTrue(waitForHeroChange(from: firstApp), "The live carousel should include another registered app.")
        }
        capture("01b — Another app")
        selectProject(named: "Squircle")

        // A fresh installation can legitimately have no mapped thread yet.
        // In that case create one real thread, then navigate it as a user would.
        let firstThread = elements("thread.row").firstMatch
        if !firstThread.waitForExistence(timeout: 5) {
            element("thread.new").tap()
            waitForThread()
            app.textViews["thread.input"].typeText("Verification only. Reply OK and do nothing else.")
            element("thread.send").tap()
            XCTAssertTrue(app.cells["thread.message.user"].waitForExistence(timeout: 30))
            element("thread.close").tap()
            waitForThreadDismissal()
        }
        XCTAssertTrue(firstThread.waitForExistence(timeout: 20), "Home should show the app's real T3 threads.")

        // Pulling the list up makes the device give way; tapping it returns.
        let heroHeight = hero.frame.height
        pullList(from: 0.80, to: 0.40)
        waitUntil("The device shrinks to make room for threads.") { hero.frame.height < heroHeight * 0.8 }
        capture("02 — Threads")
        hero.tap()
        waitUntil("Tapping the device restores the hero.") { hero.frame.height > heroHeight * 0.95 }

        pullList(from: 0.80, to: 0.40)
        requireHittable(firstThread)
        firstThread.tap()
        waitForThread()
        capture("03 — Thread")

        // The divider moves the device among docked, half and full.
        let divider = element("thread.divider")
        requireHittable(divider)
        let screen = app.coordinate(withNormalizedOffset: .zero)
        func dragDivider(toY fraction: CGFloat) {
            let start = screen.withOffset(CGVector(dx: divider.frame.midX, dy: divider.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: screen.withOffset(CGVector(dx: divider.frame.midX, dy: app.frame.height * fraction)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        dragDivider(toY: 0.95)
        waitUntil("Dragging to the bottom makes the device full size.") { divider.value as? String == "Full" }
        capture("03b — Device full")
        dragDivider(toY: 0.55)
        waitUntil("The middle detent shares the screen.") { divider.value as? String == "Half" }
        capture("03c — Device half")
        dragDivider(toY: 0.05)
        waitUntil("Dragging to the top docks the device.") { divider.value as? String == "Docked" }
        element("simulator.surface").tap()
        waitUntil("Tapping the docked device brings it forward.") { divider.value as? String == "Half" }

        // A short back swipe, held still before release, cancels. A long one returns Home.
        backDrag(to: 0.18)
        requireHittable(element("thread.close"))
        capture("03d — Cancelled back swipe")
        backDrag(to: 0.85)
        waitForThreadDismissal()
        requireRestingHome()

        element("project.builds").tap()
        requireHittable(element("builds.close"))
        requireHittable(element("project.build"))
        capture("04 — Builds sheet")
        element("builds.close").tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("builds.close"))
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed)
        requireRestingHome()
        capture("05 — Returned Home")
    }

    /// Interrupts transitions mid-flight with raw coordinate taps and fast
    /// drags, then requires one coherent resting screen. Read-only.
    @MainActor
    func testRapidNavigationStaysConsistent() throws {
        app.launch()
        let hero = element("project.hero")
        requireHittable(hero, timeout: 35)
        selectProject(named: "Squircle")
        let row = elements("thread.row").firstMatch
        guard row.waitForExistence(timeout: 10) else { throw XCTSkip("Needs one existing thread") }
        pullList(from: 0.80, to: 0.40)
        requireHittable(row)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let rowPoint = origin.withOffset(CGVector(dx: row.frame.midX, dy: row.frame.midY))
        let backPoint = origin.withOffset(CGVector(dx: 38, dy: app.windows.firstMatch.frame.minY + 90))

        // Open then immediately go back, before the open transition settles.
        for _ in 0..<4 {
            rowPoint.tap()
            backPoint.tap()
        }
        waitForThreadDismissal()

        // A fast flick still closes; an aborted drag restores the thread.
        row.tap()
        waitForThread()
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.3, dy: app.frame.height * 0.7))
        start.press(forDuration: 0.02, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.6, dy: app.frame.height * 0.7)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        waitForThreadDismissal()
        row.tap()
        waitForThread()
        backDrag(to: 0.12)
        requireHittable(element("thread.close"))
        XCTAssertFalse(element("project.hero").exists, "Home stays hidden behind a resting thread.")
        // Scrolling the conversation vertically must never start a back swipe.
        app.tables["thread.messages"].swipeDown(velocity: .fast)
        app.tables["thread.messages"].swipeUp(velocity: .fast)
        requireHittable(element("thread.close"))
        element("thread.close").tap()
        waitForThreadDismissal()

        // Quick carousel flicks settle on exactly one centered app.
        hero.tap()
        let picker = app.scrollViews["app.picker"]
        for _ in 0..<3 { picker.swipeLeft(velocity: .fast) }
        for _ in 0..<3 { picker.swipeRight(velocity: .fast) }
        requireRestingHome()
        XCTAssertEqual(elements("project.hero").count, 1)
        capture("20 — After rapid navigation")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Reduced Motion: no turning, receding or lift; navigation still works
    /// with short direct moves and the interactive back gesture.
    @MainActor
    func testReducedMotionNavigation() throws {
        app.launchArguments += ["--reduce-motion"]
        app.launch()
        let hero = element("project.hero")
        requireHittable(hero, timeout: 35)
        let first = hero.label
        capture("21 — Reduced motion Home")
        app.scrollViews["app.picker"].swipeLeft(velocity: .slow)
        if !waitForHeroChange(from: first) {
            app.scrollViews["app.picker"].swipeRight(velocity: .slow)
            XCTAssertTrue(waitForHeroChange(from: first))
        }
        selectProject(named: "Squircle")
        let row = elements("thread.row").firstMatch
        guard row.waitForExistence(timeout: 10) else { throw XCTSkip("Needs one existing thread") }
        pullList(from: 0.80, to: 0.40)
        requireHittable(row)
        capture("22 — Reduced motion threads")
        row.tap()
        waitForThread()
        capture("23 — Reduced motion thread")
        backDrag(to: 0.85)
        waitForThreadDismissal()
        requireRestingHome()
    }

    /// Read-only: visits every screen and captures it after it settles.
    /// Prefix comes from SQUIRCLE_CAPTURE_PREFIX (e.g. "dark-").
    @MainActor
    func testVisualTour() throws {
        let prefix = ProcessInfo.processInfo.environment["SQUIRCLE_CAPTURE_PREFIX"] ?? ""
        app.launch()
        let hero = element("project.hero")
        requireHittable(hero, timeout: 35)
        Thread.sleep(forTimeInterval: 3) // Real screenshots finish loading.
        capture(prefix + "30 — Home")
        let picker = app.scrollViews["app.picker"]
        let first = hero.label
        picker.swipeLeft(velocity: .slow)
        _ = waitForHeroChange(from: first)
        Thread.sleep(forTimeInterval: 1)
        capture(prefix + "31 — Home next app")
        selectProject(named: "Squircle")
        Thread.sleep(forTimeInterval: 1)
        capture(prefix + "32 — Squircle")
        pullList(from: 0.80, to: 0.40)
        Thread.sleep(forTimeInterval: 1.5)
        capture(prefix + "33 — Threads")
        let row = elements("thread.row").firstMatch
        if row.waitForExistence(timeout: 10) {
            row.tap()
            waitForThread()
            Thread.sleep(forTimeInterval: 2)
            capture(prefix + "34 — Thread")
            element("thread.close").tap()
            waitForThreadDismissal()
        }
        element("project.builds").tap()
        requireHittable(element("builds.close"))
        Thread.sleep(forTimeInterval: 1.5)
        capture(prefix + "35 — Builds")
        element("builds.close").tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("builds.close"))
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed)
        requireRestingHome()
        element("project.add").tap()
        requireHittable(element("import.path"), timeout: 25)
        Thread.sleep(forTimeInterval: 2)
        capture(prefix + "37 — Add app")
        enterMacPath("/Users/anshu/Documents/ChatGPT/RemoteAppDev/examples/SquircleProbe/SquircleProbe.xcodeproj")
        requireHittable(app.textFields["import.name"], timeout: 45)
        Thread.sleep(forTimeInterval: 1)
        capture(prefix + "38 — Add app details")
        // Deliberately leave Add untouched; this tour never imports.
    }

    /// Apple's automated accessibility audit on each primary screen. Read-only.
    @MainActor
    func testAccessibilityAudit() throws {
        app.launch()
        let hero = element("project.hero")
        requireHittable(hero, timeout: 35)
        selectProject(named: "Squircle")
        try audit("home")
        let row = elements("thread.row").firstMatch
        if row.waitForExistence(timeout: 10) {
            pullList(from: 0.80, to: 0.40)
            try audit("threads")
            row.tap()
            waitForThread()
            try audit("thread")
            element("thread.close").tap()
            waitForThreadDismissal()
        }
        element("project.builds").tap()
        requireHittable(element("builds.close"))
        try audit("builds")
    }

    @MainActor
    private func audit(_ screen: String) throws {
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" } ?? "-"
            print("AUDIT \(screen) \(issue.auditType) \(issue.compactDescription) [\(element)]")
            return false
        }
    }

    @MainActor
    private func requireRestingHome(file: StaticString = #filePath, line: UInt = #line) {
        requireHittable(element("project.hero"), timeout: 15, file: file, line: line)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("thread.close"))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "No thread may remain over Home.", file: file, line: line)
        XCTAssertTrue(element("project.add").isHittable, file: file, line: line)
    }

    /// Every app's threads and New Thread are on Home; selecting is opening.
    @MainActor
    private func openProject(named name: String) {
        selectProject(named: name)
        requireHittable(element("thread.new"))
    }

    /// Vertical drag on the centered app's list, in screen fractions.
    @MainActor
    private func pullList(from: CGFloat, to: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor
    private func waitUntil(_ message: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [met], timeout: timeout), .completed, message, file: file, line: line)
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
        requireHittable(element("thread.new"))
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

    /// A rightward drag across the conversation, well away from the screen edge.
    @MainActor
    private func backDrag(to fraction: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.12, dy: app.frame.height * 0.72))
        let end = origin.withOffset(CGVector(dx: app.frame.width * (0.12 + fraction), dy: app.frame.height * 0.72))
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
        // SQUIRCLE_CAPTURE_DIR (passed as TEST_RUNNER_SQUIRCLE_CAPTURE_DIR)
        // redirects them to a host artifact directory.
        let override = ProcessInfo.processInfo.environment["SQUIRCLE_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output = override ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SquircleVerification", isDirectory: true) {
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
