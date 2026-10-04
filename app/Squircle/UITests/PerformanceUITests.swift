import XCTest

/// Comparable performance probes for any Squircle UI version. Uses only the
/// shared accessibility identifiers, read-only navigation, and no thread or
/// build creation.
final class PerformanceUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--motion-audit"]
    }

    @MainActor
    func testLaunchToInteractiveGallery() throws {
        var samples: [Double] = []
        for _ in 0..<3 {
            app.terminate()
            let start = Date()
            app.launch()
            XCTAssertTrue(waitHittable(element("project.hero"), timeout: 40))
            samples.append(Date().timeIntervalSince(start))
        }
        print("PERF launch_to_hero_s \(samples.map { String(format: "%.3f", $0) }.joined(separator: ","))")
    }

    @MainActor
    func testIdleGalleryCPU() throws {
        app.launch()
        XCTAssertTrue(waitHittable(element("project.hero"), timeout: 40))
        Thread.sleep(forTimeInterval: 4) // Let launch refresh and preview loads settle.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            Thread.sleep(forTimeInterval: 5)
        }
    }

    @MainActor
    func testNavigationCPUAndMemory() throws {
        app.launch()
        let hero = element("project.hero")
        XCTAssertTrue(waitHittable(hero, timeout: 40))
        Thread.sleep(forTimeInterval: 3)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        let picker = app.scrollViews["app.picker"]
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            picker.swipeLeft(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
            picker.swipeRight(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertTrue(waitHittable(hero, timeout: 10))
            hero.tap()
            XCTAssertTrue(waitHittable(element("thread.new"), timeout: 15))
            element("project.back").tap()
            XCTAssertTrue(waitHittable(hero, timeout: 15))
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitHittable(_ target: XCUIElement, timeout: TimeInterval) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }
}
