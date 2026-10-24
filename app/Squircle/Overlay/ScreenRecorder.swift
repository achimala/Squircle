#if SQUIRCLE_OVERLAY || DEBUG
import AVFoundation
import Metal
import UIKit

/// Records the screen from inside the app: the app's own windows below the
/// overlay, at most 30 times a second, with a dot where each finger is. There
/// is no system prompt. The keyboard (another process since iOS 27) and the
/// status bar are not in it: on the phone the render server draws an app only
/// its own layers, and a whole-display snapshot came back black there.
///
/// No pixel touches the CPU. Each frame is one render-server pass per window
/// into a BGRA surface, then one Metal pass that stacks them, draws the finger
/// dots and writes the 4:2:0 video-range frame H.264 takes, so the encoder
/// converts nothing. The main thread only names the windows. (`drawHierarchy` cost 55 ms of main thread a frame
/// in the simulator. Snapshotting window by window, blending with vImage and
/// handing the encoder BGRA, which it converted with vImage, cost about 9% of
/// a core there besides encoding; this costs about 1%.)
@MainActor
final class ScreenRecorder: CaptureProducer {
    private let encoder: ScreenEncoder
    private weak var overlay: UIWindow?
    private weak var screen: UIScreen?
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
        // The display's own orientation, long side at most 1280 pixels, even
        // dimensions: small enough for cellular.
        let points = screen.fixedCoordinateSpace.bounds.size
        scale = min(screen.scale, 1280 / max(points.width, points.height))
        let size = CGSize(width: (points.width * scale / 2).rounded() * 2, height: (points.height * scale / 2).rounded() * 2)
        // Plays upright in the interface's orientation when recording started.
        let space = screen.fixedCoordinateSpace, interface = screen.coordinateSpace
        let origin = space.convert(CGPoint.zero, to: interface)
        let x = space.convert(CGPoint(x: 1, y: 0), to: interface), y = space.convert(CGPoint(x: 0, y: 1), to: interface)
        let upright = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y,
                                        tx: origin.x * scale, ty: origin.y * scale)
        guard let encoder = ScreenEncoder(size: size, scale: scale, upright: upright, server: server)
        else { return nil }
        self.encoder = encoder
        self.display = display
        self.screen = screen
        self.overlay = overlay
        touches = TouchTracker(origin: started)
        touches.attach(to: overlay.windowScene?.windows.filter { $0 !== overlay } ?? [])
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] _ in self?.tick() }, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime() - started
        guard drawing == nil, now - lastTick >= 1.0 / 30 * 0.9, let overlay, let screen else { return }
        // Each window's points to the recording's pixels, in the display's orientation.
        let interface = screen.coordinateSpace, space = screen.fixedCoordinateSpace
        let origin = interface.convert(CGPoint.zero, to: space)
        let x = interface.convert(CGPoint(x: 1, y: 0), to: space), y = interface.convert(CGPoint(x: 0, y: 1), to: space)
        let toPixels = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y,
                                         tx: origin.x, ty: origin.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layers = HostCapture.windows(below: overlay).prefix(ScreenEncoder.maxLayers).compactMap { window -> ScreenEncoder.Layer? in
            guard let context = RenderServer.contextID(of: window) else { return nil }
            let placed = CGAffineTransform(translationX: window.frame.minX, y: window.frame.minY).concatenating(toPixels)
            return .init(context: context, layer: UInt64(UInt(bitPattern: Unmanaged.passUnretained(window.layer).toOpaque())),
                         transform: CATransform3DMakeAffineTransform(placed))
        }
        guard !layers.isEmpty else { return }
        lastTick = now
        let fingers = touches.live.values.map { interface.convert($0, to: space).applying(.init(scaleX: scale, y: scale)) }
        let frame = ScreenEncoder.Frame(time: now, display: display, layers: layers, touches: fingers)
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

    /// Stops and finishes the file; returns it and how long it ran. Nil (and
    /// no file) when it drew no frame or the writer failed.
    func finish() async -> CaptureOutput? {
        stopProducing()
        let duration = CACurrentMediaTime() - started
        await drawing?.value
        guard let url = await encoder.finish() else { return nil }
        return .screen(url: url, duration: duration)
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
    /// One window: its render-server context and root layer, and its
    /// points to the recording's pixels.
    struct Layer {
        let context: UInt32
        let layer: UInt64
        let transform: CATransform3D
    }
    struct Frame {
        let time: Double
        let display: NSString
        /// The app's windows below the overlay, bottom first.
        let layers: [Layer]
        /// Fingers, in the recording's pixels.
        let touches: [CGPoint]
    }
    /// Windows stacked per frame (the converter's texture slots); an app rarely has more than three.
    static let maxLayers = 8
    private enum State { case writing, finishing, handedOver, discarded }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let server: RenderServer
    private let converter: FrameConverter
    /// What the render server draws each window into (each render clears
    /// its destination); the converter stacks them into each frame. Made as
    /// windows appear.
    private var snapshots: [CVPixelBuffer] = []
    private let size: CGSize
    private let url: URL
    /// The recording's pixels per point.
    private let scale: CGFloat
    private var state = State.writing
    private var lastFrame = -1.0

    init?(size: CGSize, scale: CGFloat, upright: CGAffineTransform, server: RenderServer) {
        guard let converter = FrameConverter.shared else { return nil }
        let surface = Self.surface
        url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_800_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        input.transform = upright
        // The encoder's own format, IOSurface-backed so Metal writes it in place.
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: surface.merging([
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height
        ]) { $1 })
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
        self.converter = converter
        self.size = size
        self.scale = scale
    }

    private static let surface: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                                 kCVPixelBufferMetalCompatibilityKey as String: true]

    /// The surface the render server draws window `index` into.
    private func snapshot(_ index: Int) -> CVPixelBuffer? {
        while snapshots.count <= index {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, Self.surface as CFDictionary, &made)
            guard let made else { return nil }
            snapshots.append(made)
        }
        return snapshots[index]
    }

    func draw(_ frame: Frame) async {
        guard state == .writing, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var drawn: [CVPixelBuffer] = []
        for layer in frame.layers {
            guard let snapshot = snapshot(drawn.count), let surface = CVPixelBufferGetIOSurface(snapshot)?.takeUnretainedValue(),
                  server.render(context: layer.context, layer: layer.layer, transform: layer.transform,
                                display: frame.display, into: surface)
            else { continue }
            drawn.append(snapshot)
        }
        guard !drawn.isEmpty else { return }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { return }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let dots = frame.touches.map { SIMD2(Float($0.x), Float($0.y)) }
        guard await converter.convert(drawn, into: buffer, dots: dots, radius: Float(18 * scale), ring: Float(0.75 * scale)),
              state == .writing, input.isReadyForMoreMediaData
        else { return }
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: frame.time, preferredTimescale: 600)) { lastFrame = frame.time }
    }

    /// The finished file; nil (and no file) when it drew no frame or the
    /// writer failed.
    func finish() async -> URL? {
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
        return url
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
}

/// One GPU pass from the render server's BGRA windows, stacked bottom first,
/// to the encoder's 4:2:0 video-range frame (BT.709), drawing the finger
/// dots on the way.
private final class FrameConverter: @unchecked Sendable {
    // Immutable after init; Metal's device, queue, pipeline and texture cache are thread-safe.
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache

    static let shared = FrameConverter()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "toVideo"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        (self.queue, self.pipeline, self.cache) = (queue, pipeline, cache)
    }

    /// Finger dots and their outline ring: centres, radius and half the
    /// ring's width, in the frame's pixels. True once the GPU has written it.
    func convert(_ sources: [CVPixelBuffer], into frame: CVPixelBuffer, dots: [SIMD2<Float>], radius: Float, ring: Float) async -> Bool {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let layers = sources.prefix(ScreenEncoder.maxLayers).compactMap { texture($0, plane: 0, .bgra8Unorm, width, height) }
        guard !layers.isEmpty, layers.count == min(sources.count, ScreenEncoder.maxLayers),
              let luma = texture(frame, plane: 0, .r8Unorm, width, height),
              let chroma = texture(frame, plane: 1, .rg8Unorm, width / 2, height / 2),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
        else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTextures(layers.map(\.texture), range: 0..<layers.count)
        encoder.setTextures([luma.texture, chroma.texture], range: ScreenEncoder.maxLayers..<ScreenEncoder.maxLayers + 2)
        var layerCount = UInt32(layers.count)
        encoder.setBytes(&layerCount, length: MemoryLayout<UInt32>.size, index: 3)
        var count = UInt32(dots.count), shape = SIMD2(radius, ring)
        let points = dots.isEmpty ? [SIMD2<Float>.zero] : dots
        encoder.setBytes(points, length: MemoryLayout<SIMD2<Float>>.stride * points.count, index: 0)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&shape, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
        // One thread per 2×2 block: four luma samples and their shared chroma.
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (width / 2 + 15) / 16, height: (height / 2 + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: group)
        encoder.endEncoding()
        // The CVMetalTextures must outlive the GPU's use of them.
        return await withCheckedContinuation { done in
            commands.addCompletedHandler { [layers, luma, chroma] finished in
                withExtendedLifetime((layers, luma, chroma)) { done.resume(returning: finished.status == .completed) }
            }
            commands.commit()
        }
    }

    private struct Texture: @unchecked Sendable {
        let owner: CVMetalTexture
        let texture: MTLTexture
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat, _ width: Int, _ height: Int) -> Texture? {
        var made: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, plane, &made)
        guard let made, let texture = CVMetalTextureGetTexture(made) else { return nil }
        return Texture(owner: made, texture: texture)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

    kernel void toVideo(array<texture2d<float, access::read>, 8> layers [[texture(0)]],
                        texture2d<float, access::write> luma [[texture(8)]],
                        texture2d<float, access::write> chroma [[texture(9)]],
                        constant float2 *dots [[buffer(0)]],
                        constant uint &count [[buffer(1)]],
                        constant float2 &shape [[buffer(2)]],
                        constant uint &layerCount [[buffer(3)]],
                        uint2 block [[thread_position_in_grid]]) {
        if (block.x >= chroma.get_width() || block.y >= chroma.get_height()) return;
        float3 sum = 0;
        for (uint i = 0; i < 4; i++) {
            uint2 p = block * 2 + uint2(i & 1, i >> 1);
            // Premultiplied windows, each over the ones below.
            float3 c = 0;
            for (uint l = 0; l < layerCount; l++) {
                float4 top = layers[l].read(p);
                c = top.rgb + c * (1 - top.a);
            }
            float2 at = float2(p) + 0.5;
            for (uint d = 0; d < count; d++) {
                float r = distance(at, dots[d]);
                c = mix(c, float3(1), 0.55 * saturate(shape.x - r + 0.5));
                c = mix(c, float3(0), 0.35 * saturate(shape.y - abs(r - shape.x) + 0.5));
            }
            luma.write(float4(16.0 / 255 + dot(c, kLuma) * 219.0 / 255), p);
            sum += c;
        }
        float3 c = sum * 0.25;
        float y = dot(c, kLuma);
        float2 cbcr = float2((c.b - y) / 1.8556, (c.r - y) / 1.5748);
        chroma.write(float4(128.0 / 255 + cbcr * 224.0 / 255, 0, 0), block);
    }
    """
}

/// QuartzCore's render-server snapshot in layer mode, the call under
/// `drawHierarchy`: it renders one of the app's committed layer trees into an
/// IOSurface on the GPU, at any scale, from any thread. (The whole display
/// without the overlay, `kCASnapshotModeExcludeContextList`, worked in the
/// simulator but drew nothing on the phone, 2026-10-24.) Private: this
/// overlay is only in builds Squircle signs for the user's phone, never in
/// App Store exports.
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

    /// Draws one layer tree as last committed into a BGRA surface, clearing
    /// it first; `matrix` maps the layer's points to the surface's pixels.
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
