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

    /// Opening at the bottom of a long chat: what's in sight goes first,
    /// nearest the middle first, a few at a time, then the rest in order.
    func testNearestInSightFirstWithinTheLimit() {
        let open = reduce(.seen(["top": need(2000, visible: false), "edge": need(300), "middle": need(0), "above": need(900, visible: false)]))
        XCTAssertEqual(open.effects, [.start(key: "middle", op: 1), .start(key: "edge", op: 2)])
        XCTAssertEqual(reduce(.ended(key: "middle", op: 1, loaded: true)).effects, [.start(key: "above", op: 3)])
        XCTAssertNil(s.wanted["middle"], "loaded: never asked again")
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

    /// A recording starts only in sight and finishes even if you scroll away.
    func testRecordingsAreWholeAndInSight() {
        XCTAssertEqual(reduce(.seen(["clip": need(0, visible: false, whole: true)])).effects, [])
        XCTAssertEqual(reduce(.seen(["clip": need(0, whole: true)])).effects, [.start(key: "clip", op: 1)])
        XCTAssertEqual(reduce(.seen(["x": need(0), "y": need(10)])).effects, [.start(key: "x", op: 2)])
        XCTAssertEqual(s.running["clip"]?.cancelling, false)
    }

    /// A failure isn't retried in a loop; it is asked again only after it
    /// has left and come back.
    func testFailureWaitsUntilItReturns() {
        _ = reduce(.seen(["a": need(0)]))
        XCTAssertEqual(reduce(.ended(key: "a", op: 1, loaded: false)).effects, [])
        XCTAssertEqual(reduce(.seen(["a": need(10)])).effects, [])
        _ = reduce(.seen([:]))
        XCTAssertEqual(reduce(.seen(["a": need(0)])).effects, [.start(key: "a", op: 2)])
    }
}
