#if SQUIRCLE_OVERLAY || DEBUG
import AVFoundation
import UIKit

/// Records the host app's screen from inside the app: the windows under the
/// overlay, drawn as they were last shown, 30 times a second (15 if drawing
/// gets expensive), with a dot where each finger is. The overlay is never in
/// it, and there is no system prompt. Video and Metal layers the app draws
/// itself may show as their last snapshot or blank.
@MainActor
final class ScreenRecorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let url: URL
    private let size: CGSize
    private let scale: CGFloat
    private weak var overlay: UIWindow?
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()
    private var lastFrame = -1.0
    private var interval = 1.0 / 30
    private var cost = 0.0
    private(set) var poster: UIImage?
    private let touches: TouchTracker

    init?(below overlay: UIWindow) {
        guard let screen = overlay.windowScene?.screen else { return nil }
        // Long side at most 1280 pixels, even dimensions: small enough for cellular.
        let points = screen.bounds.size
        scale = min(screen.scale, 1280 / max(points.width, points.height))
        size = CGSize(width: (points.width * scale / 2).rounded() * 2, height: (points.height * scale / 2).rounded() * 2)
        url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_800_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.overlay = overlay
        touches = TouchTracker(origin: started)
        touches.attach(to: overlay.windowScene?.windows.filter { $0 !== overlay } ?? [])
        let link = CADisplayLink(target: Ticker { [weak self] _ in self?.tick() }, selector: #selector(Ticker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime() - started
        guard now - lastFrame >= interval * 0.9, input.isReadyForMoreMediaData,
              let overlay, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let begin = CACurrentMediaTime()
        draw(below: overlay, into: buffer)
        // Drawing costs the app time; if it costs much, draw half as often.
        cost = cost * 0.9 + (CACurrentMediaTime() - begin) * 0.1
        interval = cost > 0.012 ? 1.0 / 15 : 1.0 / 30
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: now, preferredTimescale: 600)) { lastFrame = now }
    }

    private func draw(below overlay: UIWindow, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        // UIKit draws top-down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        for window in HostCapture.windows(below: overlay) {
            window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
        }
        for point in touches.live.values {
            let dot = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
            context.setFillColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            context.fillEllipse(in: dot)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: dot)
        }
        UIGraphicsPopContext()
        if poster == nil, let image = context.makeImage() { poster = UIImage(cgImage: image) }
    }

    /// Stops and finishes the file; returns it and how long it ran.
    func finish() async -> (url: URL, duration: Double)? {
        link?.invalidate()
        link = nil
        _ = touches.detach()
        let duration = CACurrentMediaTime() - started
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(lastFrame, 0.1), preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return (url, duration)
    }
}
#endif
