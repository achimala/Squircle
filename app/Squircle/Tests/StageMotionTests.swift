import UIKit
import XCTest
@testable import Squircle

final class StageMotionTests: XCTestCase {
    private func layout(reduced: Bool = false) -> StageLayout {
        StageLayout(size: CGSize(width: 402, height: 874), safe: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
                    titleHeight: 86, reducedMotion: reduced)
    }

    func testTransitionEndpointsMatchGalleryAndWorkspacePoses() {
        let layout = layout()
        XCTAssertEqual(layout.transitionPose(galleryOffset: 0, scroll: 0, progress: 0), layout.galleryPose(offset: 0))
        let end = layout.transitionPose(galleryOffset: 0, scroll: 0, progress: 1)
        let workspace = layout.workspacePose(scroll: 0)
        XCTAssertEqual(end.center.y, workspace.center.y, accuracy: 0.001)
        XCTAssertEqual(end.height, workspace.height, accuracy: 0.001)
        XCTAssertEqual(end.depth, 0, accuracy: 0.001, "The lift must vanish exactly at rest.")
        XCTAssertLessThan(layout.transitionPose(galleryOffset: 0, scroll: 0, progress: 0.5).depth, 0, "Mid-flight the device lifts toward the viewer.")
    }

    func testDevicesFitTheirRegionsAndNeighborsFaceTheCenter() {
        let layout = layout()
        let center = layout.galleryPose(offset: 0)
        XCTAssertGreaterThan(center.center.y - center.height / 2, layout.safe.top + StageLayout.topBarHeight)
        XCTAssertLessThan(layout.galleryTitleCenterY + layout.titleHeight / 2,
                          layout.size.height - layout.safe.bottom - StageLayout.pageControlHeight + 1)
        XCTAssertLessThanOrEqual(center.height * PhonePose.aspect, layout.size.width * 0.6 + 0.001)
        XCTAssertGreaterThan(layout.galleryPose(offset: -1).yaw, center.yaw, "The left neighbor turns right, toward the center.")
        XCTAssertLessThan(layout.galleryPose(offset: 1).yaw, center.yaw)
        XCTAssertFalse(layout.galleryPose(offset: 2.5).visible, "Far devices are not rendered.")
        XCTAssertFalse(layout.neighborPose(offset: 1, progress: 1).visible, "Neighbors leave the stage in the workspace.")
    }

    func testReducedMotionRemovesTurningRecedingAndLift() {
        let layout = layout(reduced: true)
        for offset in [-1.0, -0.4, 0, 0.6, 1] as [CGFloat] {
            let pose = layout.galleryPose(offset: offset)
            XCTAssertEqual(pose.yaw, 0)
            XCTAssertEqual(pose.depth, 0)
        }
        XCTAssertEqual(layout.workspacePose(scroll: 0).yaw, 0)
        XCTAssertEqual(layout.transitionPose(galleryOffset: 0, scroll: 0, progress: 0.5).depth, 0)
    }

    func testWorkspaceDeviceFollowsListScroll() {
        let layout = layout()
        let rest = layout.workspacePose(scroll: 0)
        XCTAssertEqual(layout.workspacePose(scroll: 100).center.y, rest.center.y - 100, accuracy: 0.001)
        XCTAssertGreaterThan(layout.workspacePose(scroll: -60).height, rest.height, "Pulling down enlarges the device slightly.")
        XCTAssertFalse(layout.workspacePose(scroll: 1000).visible, "A device scrolled away is not rendered.")
    }

    func testPagingMovesAtLeastOneAppOnAFlickAndClampsToCatalog() {
        let layout = layout()
        let pitch = layout.pitch
        XCTAssertEqual(layout.targetPage(currentX: pitch * 0.2, projectedX: pitch * 0.3, velocityX: 0.6, count: 3), 1)
        XCTAssertEqual(layout.targetPage(currentX: pitch * 0.8, projectedX: pitch * 0.7, velocityX: -0.6, count: 3), 0)
        XCTAssertEqual(layout.targetPage(currentX: pitch * 0.4, projectedX: pitch * 3, velocityX: 0, count: 3), 0)
        XCTAssertEqual(layout.targetPage(currentX: pitch * 2, projectedX: pitch * 9, velocityX: 4, count: 3), 2)
        XCTAssertEqual(layout.page(for: -50, count: 3), 0)
    }

    func testSpringSettlesWithoutOvershootingFarAndReversesFromVelocity() {
        var value: CGFloat = 0, velocity: CGFloat = 0, peak: CGFloat = 0
        for _ in 0..<120 {
            (value, velocity) = SpringDriver.step(value: value, velocity: velocity, target: 1, dt: 1.0 / 120, parameters: .navigation)
            peak = max(peak, value)
        }
        XCTAssertEqual(value, 1, accuracy: 0.002, "Settles within one second.")
        XCTAssertLessThan(peak, 1.03, "Restrained: at most a whisper of overshoot.")
        // A finger releasing toward the gallery with velocity keeps moving that way first.
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

    func testPoseInterpolationIsLinearAndKeepsVisibility() {
        let a = PhonePose(center: .zero, height: 100, depth: 10, yaw: 0, shadow: 1, visible: false)
        let b = PhonePose(center: CGPoint(x: 10, y: 20), height: 200, depth: 0, yaw: 1, shadow: 0, visible: true)
        let mid = PhonePose.interpolate(a, b, 0.5)
        XCTAssertEqual(mid.center, CGPoint(x: 5, y: 10))
        XCTAssertEqual(mid.height, 150)
        XCTAssertEqual(mid.yaw, 0.5)
        XCTAssertTrue(mid.visible)
    }
}
