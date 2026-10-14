import UIKit
import XCTest
@testable import Squircle

/// The overlay's recordings: every path stops the recorder and leaves no
/// orphaned file; hitches are judged against the cadence each frame ran at.
@MainActor
final class OverlayCaptureTests: XCTestCase {
    private final class FakeProducer: CaptureProducer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-\(UUID().uuidString)")
        var output: (URL) -> CaptureOutput?
        var finishing: CheckedContinuation<Void, Never>?
        var holdFinish = false
        private(set) var finished = 0, cancelled = 0

        init(_ output: @escaping (URL) -> CaptureOutput?) {
            self.output = output
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        }

        func finish() async -> CaptureOutput? {
            finished += 1
            if holdFinish { await withCheckedContinuation { finishing = $0 } }
            let result = output(url)
            if result == nil { try? FileManager.default.removeItem(at: url) }
            return result
        }

        func cancel() {
            cancelled += 1
            try? FileManager.default.removeItem(at: url)
        }

        var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    private func session(_ producer: FakeProducer) -> CaptureSession {
        CaptureSession { _, _ in producer }
    }

    func testScreenRecordingWithoutAnyPictureIsStoppedAndRemoved() async {
        let producer = FakeProducer { .screen(url: $0, duration: 3, poster: nil) }
        let capture = session(producer)
        XCTAssertTrue(capture.start(.screen, below: UIWindow()))
        let attachment = await capture.stop(snapshot: nil)
        XCTAssertNil(attachment)
        XCTAssertEqual(producer.finished, 1, "Stopped before deciding there's no thumbnail.")
        XCTAssertFalse(producer.fileExists)
        XCTAssertNil(capture.recording)
        XCTAssertTrue(capture.start(.screen, below: UIWindow()), "Free for the next recording.")
    }

    func testFailedWriterLeavesTheSessionIdle() async {
        let producer = FakeProducer { _ in nil }
        let capture = session(producer)
        XCTAssertTrue(capture.start(.performance, below: UIWindow()))
        let attachment = await capture.stop(snapshot: nil)
        XCTAssertNil(attachment)
        XCTAssertNil(capture.recording)
        XCTAssertFalse(producer.fileExists)
    }

    func testClosingTheOwnerStopsARunningRecording() {
        let producer = FakeProducer { .screen(url: $0, duration: 1, poster: UIImage()) }
        let capture = session(producer)
        XCTAssertTrue(capture.start(.screen, below: UIWindow()))
        capture.cancel()
        XCTAssertEqual(producer.cancelled, 1)
        XCTAssertNil(capture.recording)
        XCTAssertFalse(producer.fileExists)
    }

    func testClosingTheOwnerWhileItFinishesDiscardsTheFile() async {
        let producer = FakeProducer { .performance(url: $0, duration: 1, gaps: [], hitches: 0) }
        producer.holdFinish = true
        let capture = session(producer)
        XCTAssertTrue(capture.start(.performance, below: UIWindow()))
        let stopping = Task { await capture.stop(snapshot: nil) }
        while producer.finishing == nil { await Task.yield() }
        XCTAssertTrue(capture.isStopping)
        capture.cancel()
        producer.finishing?.resume()
        let attachment = await stopping.value
        XCTAssertNil(attachment)
        XCTAssertFalse(producer.fileExists, "Nobody is left to send it.")
        XCTAssertNil(capture.recording)
    }

    func testHitchesUseEachFramesOwnCadenceAndSkipPauses() {
        let fast = 1.0 / 120, slow = 1.0 / 60
        var frames: [FrameTiming] = []
        var t = 0.0
        func frame(_ period: Double, after gap: Double, resumed: Bool = false) {
            t += gap
            frames.append(FrameTiming(time: t, period: period, resumed: frames.isEmpty || resumed))
        }
        frame(fast, after: 0)
        frame(fast, after: fast)
        frame(fast, after: slow)        // late at 120 Hz
        frame(slow, after: fast)        // the display drops to 60 Hz
        frame(slow, after: slow)        // on time at 60 Hz
        frame(slow, after: 30, resumed: true)  // back from the background
        frame(slow, after: slow * 3)    // late at 60 Hz
        let late = FrameGap.all(frames).filter(\.late)
        XCTAssertEqual(late.count, 2)
        XCTAssertEqual(late[0].overdue, slow - fast, accuracy: 1e-9)
        XCTAssertEqual(late[1].overdue, slow * 2, accuracy: 1e-9)
        XCTAssertEqual(FrameGap.all(frames).count, frames.count - 2, "No gap before the first frame or across the pause.")
    }
}
