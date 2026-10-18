#if SQUIRCLE_OVERLAY || DEBUG
import Accelerate
import AVFoundation
import UIKit

/// Records the host app's screen from inside the app: the windows under the
/// overlay, 30 times a second, with a dot where each finger is. The overlay
/// is never in it, and there is no system prompt.
///
/// The render server draws each frame straight into the encoder's buffer at
/// the recording's size, off the main thread; the main thread only names
/// the windows. (`drawHierarchy` cost 55 ms of main thread a frame in the
/// simulator, nearly all of it CoreGraphics converting a full-size snapshot
/// pixel by pixel, so the app dropped to 15 fps while recording.)
@MainActor
final class ScreenRecorder: CaptureProducer {
    private let encoder: ScreenEncoder
    private weak var overlay: UIWindow?
    private let display: NSString
    private let scale: CGFloat
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()
    private var lastTick = -1.0
    /// The frame the encoder is drawing; ticks until it finishes are skipped.
    private var drawing: Task<Void, Never>?
    private let touches: TouchTracker

    init?(below overlay: UIWindow) {
        guard let screen = overlay.windowScene?.screen, let server = RenderServer.shared,
              let display = RenderServer.displayName(of: screen) else { return nil }
        // Long side at most 1280 pixels, even dimensions: small enough for cellular.
        let points = screen.bounds.size
        scale = min(screen.scale, 1280 / max(points.width, points.height))
        let size = CGSize(width: (points.width * scale / 2).rounded() * 2, height: (points.height * scale / 2).rounded() * 2)
        guard let encoder = ScreenEncoder(size: size, scale: scale, server: server) else { return nil }
        self.encoder = encoder
        self.display = display
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
        guard drawing == nil, now - lastTick >= 1.0 / 30 * 0.9, let overlay else { return }
        let layers = HostCapture.windows(below: overlay).compactMap { window -> ScreenEncoder.Layer? in
            guard let context = RenderServer.contextID(of: window) else { return nil }
            let origin = window.frame.origin
            return .init(context: context, layer: UInt64(UInt(bitPattern: Unmanaged.passUnretained(window.layer).toOpaque())),
                         transform: CATransform3DConcat(CATransform3DMakeTranslation(origin.x, origin.y, 0),
                                                        CATransform3DMakeScale(scale, scale, 1)))
        }
        guard !layers.isEmpty else { return }
        lastTick = now
        let frame = ScreenEncoder.Frame(time: now, display: display, layers: layers, touches: Array(touches.live.values))
        drawing = Task { [weak self, encoder] in
            await encoder.draw(frame)
            self?.drawing = nil
        }
    }

    deinit {
        link?.invalidate()
        // Dropped without finishing: the file is of no use. (A no-op once handed over.)
        Task { [encoder] in await encoder.discard() }
    }

    private func stopProducing() {
        link?.invalidate()
        link = nil
        _ = touches.detach()
    }

    /// Stops and finishes the file; returns it, how long it ran and its
    /// first picture. Nil (and no file) when it drew no frame or the
    /// writer failed.
    func finish() async -> CaptureOutput? {
        stopProducing()
        let duration = CACurrentMediaTime() - started
        await drawing?.value
        guard let (url, poster) = await encoder.finish() else { return nil }
        return .screen(url: url, duration: duration, poster: poster.map(UIImage.init(cgImage:)))
    }

    func cancel() {
        stopProducing()
        Task { [encoder, drawing] in
            await drawing?.value
            await encoder.discard()
        }
    }
}

/// Owns the file: draws, encodes and finishes frames away from the main thread.
private actor ScreenEncoder {
    struct Layer {
        let context: UInt32
        let layer: UInt64
        let transform: CATransform3D
    }
    struct Frame {
        let time: Double
        let display: NSString
        /// The windows, bottom first.
        let layers: [Layer]
        /// Fingers, in screen points.
        let touches: [CGPoint]
    }
    private enum State { case writing, finishing, handedOver, discarded }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let server: RenderServer
    private let url: URL
    private let size: CGSize
    private let scale: CGFloat
    private var state = State.writing
    private var lastFrame = -1.0
    private var poster: CGImage?
    /// Windows above the bottom one are drawn here, then blended over it.
    private var scratch: CVPixelBuffer?

    init?(size: CGSize, scale: CGFloat, server: RenderServer) {
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
        // IOSurface-backed, so the render server can draw into them.
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.server = server
        self.size = size
        self.scale = scale
    }

    func draw(_ frame: Frame) {
        guard state == .writing, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool,
              let bottom = frame.layers.first else { return }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created, render(bottom, display: frame.display, into: buffer) else { return }
        for layer in frame.layers.dropFirst() {
            guard let scratch = scratchBuffer(like: buffer), render(layer, display: frame.display, into: scratch) else { continue }
            blend(scratch, over: buffer)
        }
        if !frame.touches.isEmpty || poster == nil {
            withContext(buffer) { context in
                for point in frame.touches {
                    let dot = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
                    context.setFillColor(UIColor.white.withAlphaComponent(0.55).cgColor)
                    context.fillEllipse(in: dot)
                    context.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
                    context.setLineWidth(1.5)
                    context.strokeEllipse(in: dot)
                }
                if poster == nil { poster = context.makeImage() }
            }
        }
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: frame.time, preferredTimescale: 600)) { lastFrame = frame.time }
    }

    /// The finished file and its first picture; nil (and no file) when it
    /// drew no frame or the writer failed.
    func finish() async -> (URL, CGImage?)? {
        guard state == .writing else { return nil }
        guard lastFrame >= 0, writer.status == .writing else {
            remove()
            return nil
        }
        state = .finishing
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(lastFrame, 0.1), preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            remove()
            return nil
        }
        state = .handedOver
        return (url, poster)
    }

    /// Stops writing and removes the file, unless it was handed over or is finishing.
    func discard() {
        guard state == .writing else { return }
        remove()
    }

    private func remove() {
        state = .discarded
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    private func render(_ layer: Layer, display: NSString, into buffer: CVPixelBuffer) -> Bool {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return false }
        return server.render(context: layer.context, layer: layer.layer, transform: layer.transform, display: display, into: surface)
    }

    private func scratchBuffer(like buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if let scratch { return scratch }
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &created)
        scratch = created
        return created
    }

    private func blend(_ top: CVPixelBuffer, over bottom: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(top, .readOnly)
        CVPixelBufferLockBaseAddress(bottom, [])
        defer {
            CVPixelBufferUnlockBaseAddress(bottom, [])
            CVPixelBufferUnlockBaseAddress(top, .readOnly)
        }
        func image(_ buffer: CVPixelBuffer) -> vImage_Buffer {
            vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
                          width: vImagePixelCount(CVPixelBufferGetWidth(buffer)), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        }
        var source = image(top), destination = image(bottom)
        vImagePremultipliedAlphaBlend_BGRA8888(&source, &destination, &destination, vImage_Flags(kvImageNoFlags))
    }

    /// A drawing context over the buffer in screen points, top-down as UIKit draws.
    private func withContext(_ buffer: CVPixelBuffer, _ body: (CGContext) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        body(context)
    }
}

/// QuartzCore's render-server snapshot, the call under `drawHierarchy`: it
/// renders one window's committed layers into an IOSurface on the GPU, at
/// any scale, from any thread. Private: this overlay is only in builds
/// Squircle signs for the user's phone, never in App Store exports.
private struct RenderServer: @unchecked Sendable {
    private typealias Snapshot = @convention(c) (mach_port_t, CFDictionary) -> Bool
    private let snapshot: Snapshot
    // The keys and the mode are compared by identity, so they must be QuartzCore's own.
    private let mode, modeLayer, contextID, layerID, displayName, destination, transform: NSString

    static let shared = RenderServer()

    private init?() {
        // RTLD_DEFAULT
        let images = UnsafeMutableRawPointer(bitPattern: -2)
        func constant(_ name: String) -> NSString? {
            dlsym(images, name)?.assumingMemoryBound(to: NSString?.self).pointee
        }
        guard let symbol = dlsym(images, "CARenderServerSnapshot"),
              let mode = constant("kCASnapshotMode"), let modeLayer = constant("kCASnapshotModeLayer"),
              let contextID = constant("kCASnapshotContextId"), let layerID = constant("kCASnapshotLayerId"),
              let displayName = constant("kCASnapshotDisplayName"), let destination = constant("kCASnapshotDestination"),
              let transform = constant("kCASnapshotTransform"),
              UIWindow.instancesRespond(to: Self.contextSelector), UIScreen.instancesRespond(to: Self.displaySelector)
        else { return nil }
        snapshot = unsafeBitCast(symbol, to: Snapshot.self)
        (self.mode, self.modeLayer, self.contextID, self.layerID) = (mode, modeLayer, contextID, layerID)
        (self.displayName, self.destination, self.transform) = (displayName, destination, transform)
    }

    func render(context: UInt32, layer: UInt64, transform matrix: CATransform3D, display: NSString, into surface: IOSurfaceRef) -> Bool {
        let options: NSDictionary = [
            mode: modeLayer, contextID: NSNumber(value: context), layerID: NSNumber(value: layer),
            displayName: display, destination: surface, transform: NSValue(caTransform3D: matrix)
        ]
        // Port 0: the default render server.
        return snapshot(0, options)
    }

    private static let contextSelector = NSSelectorFromString("_contextId")
    private static let displaySelector = NSSelectorFromString("_display")

    /// The window's render-server context.
    @MainActor static func contextID(of window: UIWindow) -> UInt32? {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
        let id = unsafeBitCast(window.method(for: contextSelector), to: Getter.self)(window, contextSelector)
        return id == 0 ? nil : id
    }

    /// The screen's display as the render server names it ("LCD" for the phone's own).
    @MainActor static func displayName(of screen: UIScreen) -> NSString? {
        (screen.perform(displaySelector)?.takeUnretainedValue() as? NSObject)?.value(forKey: "name") as? NSString
    }
}
#endif
