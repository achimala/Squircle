import XCTest
@testable import Squircle

final class MediaLoadsTests: XCTestCase {
    private var s = MediaLoads.State(limit: 2)
    private func reduce(_ e: MediaLoads.Event) -> MediaLoads.Result {
        let r = MediaLoads.reduce(s, e); s = r.state
        XCTAssertEqual(MediaLoads.violations(in: s), [])
        return r
    }
    private func need(_ distance: Double, visible: Bool = true, whole: Bool = false) -> MediaLoads.Need {
        .init(distance: distance, visible: visible, whole: whole)
    }

    /// Scrolling away cancels what is no longer near; scrolling to new
    /// pictures puts them ahead of ones that went out of sight.
    func testScrollingCancelsAndReprioritizes() {
        _ = reduce(.seen(["a": need(0), "b": need(100)]))
        // Flung on: a is gone, b is still near but out of sight, c and d in sight.
        let flung = reduce(.seen(["b": need(900, visible: false), "c": need(0), "d": need(50)]))
        XCTAssertEqual(flung.effects, [.cancel(key: "a", op: 1), .cancel(key: "b", op: 2)])
        XCTAssertEqual(s.running.count, 2, "a cancelled load holds its place until it ends")
        XCTAssertEqual(reduce(.ended(key: "a", op: 1, loaded: false)).effects, [.start(key: "c", op: 3)])
        XCTAssertTrue(s.failed.isEmpty, "a cancellation is not a failure")
        // b's bytes arrived as it was cancelled: kept, and not loaded again.
        XCTAssertEqual(reduce(.ended(key: "b", op: 2, loaded: true)).effects, [.start(key: "d", op: 4)])
        XCTAssertNil(s.wanted["b"])
        XCTAssertEqual(reduce(.ended(key: "a", op: 1, loaded: true)).disposition, .stale)
    }
}
