import UIKit
import XCTest
@testable import Squircle

final class SpringTests: XCTestCase {
    func testSpringSettlesWithoutOvershootingFarAndReversesFromVelocity() {
        var value: CGFloat = 0, velocity: CGFloat = 0, peak: CGFloat = 0
        for _ in 0..<120 {
            (value, velocity) = SpringDriver.step(value: value, velocity: velocity, target: 1, dt: 1.0 / 120, parameters: .navigation)
            peak = max(peak, value)
        }
        XCTAssertEqual(value, 1, accuracy: 0.002, "Settles within one second.")
        XCTAssertLessThan(peak, 1.03, "Restrained: at most a whisper of overshoot.")
        // A finger releasing toward Home with velocity keeps moving that way first.
        let (next, _) = SpringDriver.step(value: 0.6, velocity: -3, target: 0, dt: 1.0 / 60, parameters: .navigation)
        XCTAssertLessThan(next, 0.6)
    }

    @MainActor
    func testSpringDriverIsInterruptibleAndReportsRest() {
        let driver = SpringDriver(value: 0)
        var rested: [CGFloat] = []
        driver.onRest = { rested.append($0) }
        driver.animate(to: 1)
        XCTAssertTrue(driver.isAnimating)
        driver.set(0.4)
        XCTAssertFalse(driver.isAnimating, "A finger takes over immediately.")
        XCTAssertEqual(driver.value, 0.4)
        driver.animate(to: 0.4)
        XCTAssertEqual(rested, [0.4], "Animating to the current value settles at once.")
        let expectation = expectation(description: "rest")
        driver.onRest = { _ in expectation.fulfill() }
        driver.animate(to: 0)
        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(driver.value, 0)
    }

}
