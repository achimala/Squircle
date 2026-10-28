#if SQUIRCLE_OVERLAY || DEBUG
import Darwin
import Metal
import ObjectiveC
import QuartzCore
import Synchronization
import UIKit

/// While a performance recording runs, sees what the app's Metal work did
/// without its cooperation: each CAMetalLayer drawable (how long the app
/// waited for it, when it actually reached the screen or that it never did),
/// each command buffer's GPU start and end, each pass's GPU time from the
/// GPU's stage-boundary counters where the device has them, CPU waits on the
/// GPU, and display-link rate requests. It swaps in its hooks when the
/// recording starts and puts the originals back when it stops: nothing of it
/// runs otherwise.
final class GPUProbe: @unchecked Sendable {
    /// Times are CACurrentMediaTime, as Metal's own are.
    struct Layer { let name: String; let pixels: CGSize; let screenShare: Double; let drawables: Int; let withTransaction: Bool; let format: String }
    struct Drawable {
        let layer: Int; let requested: Double; let wait: Double; let thread: UInt64
        /// When the app asked for it to be shown (present or presentDrawable).
        var presentCalled: Double?
        /// When it reached the screen; 0 when it never did.
        var presented: Double?
    }
    struct Buffer {
        let committed: Double; let thread: UInt64
        var label = ""; var gpuStart = 0.0; var gpuEnd = 0.0; var status = 0
    }
    struct Pass {
        let buffer: Int; let kind: String; let target: String
        var label = ""
        /// GPU counter ticks: start/end of the vertex and fragment stages
        /// (render) or of the encoder (compute, blit).
        var ticks: [UInt64] = []
    }
    struct Wait { let kind: String; let start: Double; let end: Double; let thread: UInt64 }
    private struct PendingPass { let pass: Pass; let encoder: AnyObject; let sampleBuffer: MTLCounterSampleBuffer; let index: Int; let count: Int }

    private struct Records {
        var layers: [Layer] = []
        var layerIndex: [ObjectIdentifier: Int] = [:]
        var drawables: [Drawable] = []
        var drawableIndex: [ObjectIdentifier: Int] = [:]
        var buffers: [Buffer] = []
        var passes: [Pass] = []
        var pending: [ObjectIdentifier: [PendingPass]] = [:]
        var waits: [Wait] = []
        var events: [[String: Any]] = []
        var counterCursor = (buffer: 0, index: 0)
        var stopped = false
    }

    private struct Hook { let method: Method; let original: IMP }

    private let records = Mutex(Records())
    private var hooks: [Hook] = []
    private let screenPixels: Double
    private let device: MTLDevice?
    /// One sample buffer set per recording, filled round robin: a pass's
    /// samples are read when its command buffer completes, long before the
    /// ring comes back round.
    private let counterBuffers: [MTLCounterSampleBuffer]
    private static let counterSamples = 4096
    let counterNote: String
    private var calibration: [(gpu: UInt64, seconds: Double)] = []

    @MainActor init() {
        let screen = UIScreen.main
        screenPixels = Double(screen.nativeBounds.width * screen.nativeBounds.height)
        device = MTLCreateSystemDefaultDevice()
        var note = "no Metal device"
        var buffers: [MTLCounterSampleBuffer] = []
        if let device {
            if !device.supportsCounterSampling(.atStageBoundary) {
                note = "this GPU has no stage-boundary counters (the simulator never does)"
            } else if let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) {
                for _ in 0..<4 {
                    let descriptor = MTLCounterSampleBufferDescriptor()
                    descriptor.counterSet = set
                    descriptor.storageMode = .shared
                    descriptor.sampleCount = Self.counterSamples
                    descriptor.label = "Squircle perf"
                    if let buffer = try? device.makeCounterSampleBuffer(descriptor: descriptor) { buffers.append(buffer) }
                }
                note = buffers.isEmpty ? "the GPU refused a counter sample buffer" : "stage-boundary timestamps"
            } else {
                note = "this GPU has no timestamp counter set"
            }
        }
        counterBuffers = buffers
        counterNote = note
        calibrate()
        install()
    }

    deinit { uninstall() }

    // MARK: Hooks

    private func hook(_ cls: AnyClass?, _ name: String, _ make: (IMP) -> Any) {
        guard let cls, let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
              !hooks.contains(where: { $0.method == method }) else { return }
        let original = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(make(original)))
        hooks.append(Hook(method: method, original: original))
    }

    /// Puts every original back; calls already inside a hook finish normally.
    func uninstall() {
        for hook in hooks.reversed() { method_setImplementation(hook.method, hook.original) }
        hooks = []
        records.withLock { $0.stopped = true }
    }

    private func install() {
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        typealias Action = @convention(c) (AnyObject, Selector) -> Void
        typealias WithType = @convention(c) (AnyObject, Selector, UInt) -> AnyObject?

        guard let device, let queue = device.makeCommandQueue() else { return }
        typealias Present = @convention(c) (AnyObject, Selector) -> Void
        typealias PresentWith = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias PresentDrawable = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias PresentDrawableWith = @convention(c) (AnyObject, Selector, AnyObject, Double) -> Void
        // A drawable of our own, only for its class: where present lives.
        let scratch = CAMetalLayer()
        scratch.device = device
        scratch.drawableSize = CGSize(width: 1, height: 1)
        if let drawable = scratch.nextDrawable() {
            let cls: AnyClass = type(of: drawable as AnyObject)
            hook(cls, "present") { imp in
                let original = unsafeBitCast(imp, to: Present.self)
                let block: @convention(block) (AnyObject) -> Void = { [weak self] drawable in
                    self?.presenting(drawable)
                    original(drawable, NSSelectorFromString("present"))
                }
                return block
            }
            for name in ["presentAtTime:", "presentAfterMinimumDuration:"] {
                hook(cls, name) { imp in
                    let original = unsafeBitCast(imp, to: PresentWith.self)
                    let block: @convention(block) (AnyObject, Double) -> Void = { [weak self] drawable, time in
                        self?.presenting(drawable)
                        original(drawable, NSSelectorFromString(name), time)
                    }
                    return block
                }
            }
        }
        hook(CAMetalLayer.self, "nextDrawable") { imp in
            let original = unsafeBitCast(imp, to: Getter.self)
            let block: @convention(block) (AnyObject) -> AnyObject? = { [weak self] layer in
                let start = CACurrentMediaTime()
                let drawable = original(layer, NSSelectorFromString("nextDrawable"))
                self?.drawable(drawable as? CAMetalDrawable, from: layer, requested: start, got: CACurrentMediaTime())
                return drawable
            }
            return block
        }

        let samples = [queue.makeCommandBuffer(), queue.makeCommandBufferWithUnretainedReferences()].compactMap { $0 }
        for sample in samples {
            let cls: AnyClass = type(of: sample)
            hook(cls, "commit") { imp in
                let original = unsafeBitCast(imp, to: Action.self)
                let block: @convention(block) (AnyObject) -> Void = { [weak self] buffer in
                    self?.committing(buffer)
                    original(buffer, NSSelectorFromString("commit"))
                }
                return block
            }
            hook(cls, "presentDrawable:") { imp in
                let original = unsafeBitCast(imp, to: PresentDrawable.self)
                let block: @convention(block) (AnyObject, AnyObject) -> Void = { [weak self] buffer, drawable in
                    self?.presenting(drawable)
                    original(buffer, NSSelectorFromString("presentDrawable:"), drawable)
                }
                return block
            }
            for name in ["presentDrawable:atTime:", "presentDrawable:afterMinimumDuration:"] {
                hook(cls, name) { imp in
                    let original = unsafeBitCast(imp, to: PresentDrawableWith.self)
                    let block: @convention(block) (AnyObject, AnyObject, Double) -> Void = { [weak self] buffer, drawable, time in
                        self?.presenting(drawable)
                        original(buffer, NSSelectorFromString(name), drawable, time)
                    }
                    return block
                }
            }
            for (name, kind) in [("waitUntilScheduled", "wait-scheduled"), ("waitUntilCompleted", "wait-completed")] {
                hook(cls, name) { imp in
                    let original = unsafeBitCast(imp, to: Action.self)
                    let block: @convention(block) (AnyObject) -> Void = { [weak self] buffer in
                        let start = CACurrentMediaTime()
                        original(buffer, NSSelectorFromString(name))
                        self?.waited(kind, from: start)
                    }
                    return block
                }
            }
            guard !counterBuffers.isEmpty else { continue }
            hook(cls, "renderCommandEncoderWithDescriptor:") { imp in
                let original = unsafeBitCast(imp, to: Setter.self)
                let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { [weak self] buffer, descriptor in
                    let selector = NSSelectorFromString("renderCommandEncoderWithDescriptor:")
                    guard let self, let descriptor = descriptor as? MTLRenderPassDescriptor,
                          descriptor.sampleBufferAttachments[0].sampleBuffer == nil,
                          let (sampleBuffer, index) = slot(4),
                          let copy = descriptor.copy() as? MTLRenderPassDescriptor else { return original(buffer, selector, descriptor) }
                    // A copy: the app may reuse its descriptor after the recording.
                    let attachment = copy.sampleBufferAttachments[0]!
                    attachment.sampleBuffer = sampleBuffer
                    attachment.startOfVertexSampleIndex = index
                    attachment.endOfVertexSampleIndex = index + 1
                    attachment.startOfFragmentSampleIndex = index + 2
                    attachment.endOfFragmentSampleIndex = index + 3
                    let encoder = original(buffer, selector, copy)
                    if let encoder {
                        let texture = descriptor.colorAttachments[0].texture ?? descriptor.depthAttachment.texture
                        pending(buffer, Pass(buffer: -1, kind: "render", target: Self.describe(texture)), encoder, sampleBuffer, index, 4)
                    }
                    return encoder
                }
                return block
            }
            // Compute and blit passes without a descriptor get one, through
            // the descriptor method's original.
            if let method = class_getInstanceMethod(cls, NSSelectorFromString("computeCommandEncoderWithDescriptor:")) {
                let withDescriptor = unsafeBitCast(method_getImplementation(method), to: Setter.self)
                let make: @Sendable (GPUProbe, AnyObject, MTLDispatchType?) -> AnyObject? = { probe, buffer, type in
                    let descriptor = MTLComputePassDescriptor()
                    if let type { descriptor.dispatchType = type }
                    guard let (sampleBuffer, index) = probe.slot(2) else { return withDescriptor(buffer, NSSelectorFromString("computeCommandEncoderWithDescriptor:"), descriptor) }
                    descriptor.sampleBufferAttachments[0].sampleBuffer = sampleBuffer
                    descriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = index
                    descriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = index + 1
                    let encoder = withDescriptor(buffer, NSSelectorFromString("computeCommandEncoderWithDescriptor:"), descriptor)
                    if let encoder { probe.pending(buffer, Pass(buffer: -1, kind: "compute", target: ""), encoder, sampleBuffer, index, 2) }
                    return encoder
                }
                hook(cls, "computeCommandEncoder") { imp in
                    let original = unsafeBitCast(imp, to: Getter.self)
                    let block: @convention(block) (AnyObject) -> AnyObject? = { [weak self] buffer in
                        guard let self else { return original(buffer, NSSelectorFromString("computeCommandEncoder")) }
                        return make(self, buffer, nil)
                    }
                    return block
                }
                hook(cls, "computeCommandEncoderWithDispatchType:") { imp in
                    let original = unsafeBitCast(imp, to: WithType.self)
                    let block: @convention(block) (AnyObject, UInt) -> AnyObject? = { [weak self] buffer, type in
                        guard let self, let dispatch = MTLDispatchType(rawValue: type) else {
                            return original(buffer, NSSelectorFromString("computeCommandEncoderWithDispatchType:"), type)
                        }
                        return make(self, buffer, dispatch)
                    }
                    return block
                }
            }
            if let method = class_getInstanceMethod(cls, NSSelectorFromString("blitCommandEncoderWithDescriptor:")) {
                let withDescriptor = unsafeBitCast(method_getImplementation(method), to: Setter.self)
                hook(cls, "blitCommandEncoder") { imp in
                    let original = unsafeBitCast(imp, to: Getter.self)
                    let block: @convention(block) (AnyObject) -> AnyObject? = { [weak self] buffer in
                        let selector = NSSelectorFromString("blitCommandEncoderWithDescriptor:")
                        guard let self, let (sampleBuffer, index) = slot(2) else { return original(buffer, NSSelectorFromString("blitCommandEncoder")) }
                        let descriptor = MTLBlitPassDescriptor()
                        descriptor.sampleBufferAttachments[0].sampleBuffer = sampleBuffer
                        descriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = index
                        descriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = index + 1
                        let encoder = withDescriptor(buffer, selector, descriptor)
                        if let encoder { pending(buffer, Pass(buffer: -1, kind: "blit", target: ""), encoder, sampleBuffer, index, 2) }
                        return encoder
                    }
                    return block
                }
            }
        }
    }

    /// Display links the app creates or retunes while recording: the rate it asks for.
    func watchFrameRates(origin: Double) {
        typealias SetRange = @convention(c) (AnyObject, Selector, CAFrameRateRange) -> Void
        typealias SetFPS = @convention(c) (AnyObject, Selector, Int) -> Void
        hook(CADisplayLink.self, "setPreferredFrameRateRange:") { imp in
            let original = unsafeBitCast(imp, to: SetRange.self)
            let block: @convention(block) (AnyObject, CAFrameRateRange) -> Void = { [weak self] link, range in
                original(link, NSSelectorFromString("setPreferredFrameRateRange:"), range)
                self?.event(["t": CACurrentMediaTime() - origin, "kind": "frame-rate-request", "min": range.minimum, "max": range.maximum,
                             "preferred": range.preferred ?? 0])
            }
            return block
        }
        hook(CADisplayLink.self, "setPreferredFramesPerSecond:") { imp in
            let original = unsafeBitCast(imp, to: SetFPS.self)
            let block: @convention(block) (AnyObject, Int) -> Void = { [weak self] link, fps in
                original(link, NSSelectorFromString("setPreferredFramesPerSecond:"), fps)
                self?.event(["t": CACurrentMediaTime() - origin, "kind": "frame-rate-request", "preferred": fps])
            }
            return block
        }
    }

    // MARK: Recording

    private static func threadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    private func event(_ event: [String: Any]) {
        records.withLock { if $0.events.count < 2_000 { $0.events.append(event) } }
    }

    private func drawable(_ drawable: CAMetalDrawable?, from layer: AnyObject, requested: Double, got: Double) {
        guard let layer = layer as? CAMetalLayer else { return }
        let key = ObjectIdentifier(layer)
        let known = records.withLock { $0.layerIndex[key] }
        let index: Int
        if let known { index = known } else {
            let size = layer.drawableSize
            let owner = layer.delegate.map { String(describing: type(of: $0 as AnyObject)) } ?? (layer.name ?? "CAMetalLayer")
            let info = Layer(name: owner, pixels: size, screenShare: screenPixels > 0 ? Double(size.width * size.height) / screenPixels : 0,
                             drawables: layer.maximumDrawableCount, withTransaction: layer.presentsWithTransaction,
                             format: Self.format(layer.pixelFormat))
            index = records.withLock { records in
                if let raced = records.layerIndex[key] { return raced }
                records.layers.append(info)
                records.layerIndex[key] = records.layers.count - 1
                return records.layers.count - 1
            }
        }
        let thread = Self.threadID()
        let slot: Int? = records.withLock { records in
            guard !records.stopped, records.drawables.count < 60_000 else { return nil }
            records.drawables.append(Drawable(layer: index, requested: requested, wait: got - requested, thread: thread,
                                              presented: drawable == nil ? 0 : nil))
            if let drawable { records.drawableIndex[ObjectIdentifier(drawable)] = records.drawables.count - 1 }
            return records.drawables.count - 1
        }
        guard let slot, let drawable else { return }
        // Called once it is on screen, or with 0 when it never got there.
        Self.onPresented(drawable) { [weak self] time in
            self?.records.withLock { records in
                records.drawables[slot].presented = time
                records.drawableIndex.removeValue(forKey: ObjectIdentifier(drawable))
            }
        }
    }

    private func presenting(_ drawable: AnyObject) {
        let now = CACurrentMediaTime()
        records.withLock { records in
            // Where the presented handler never comes (the simulator), the
            // drawable's identity may be reused: the latest acquisition wins.
            guard let index = records.drawableIndex[ObjectIdentifier(drawable)], records.drawables[index].presentCalled == nil else { return }
            records.drawables[index].presentCalled = now
        }
    }

    /// `addPresentedHandler`, through the runtime: the simulator's SDK
    /// leaves it out of its headers. Nothing when the drawable lacks it.
    private static func onPresented(_ drawable: AnyObject, _ handler: @escaping (Double) -> Void) {
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Time = @convention(c) (AnyObject, Selector) -> Double
        let add = NSSelectorFromString("addPresentedHandler:"), time = NSSelectorFromString("presentedTime")
        guard let cls = object_getClass(drawable), class_respondsToSelector(cls, add), class_respondsToSelector(cls, time) else { return }
        let read = unsafeBitCast(class_getMethodImplementation(cls, time), to: Time.self)
        let block: @convention(block) (AnyObject) -> Void = { shown in handler(read(shown, time)) }
        unsafeBitCast(class_getMethodImplementation(cls, add), to: Add.self)(drawable, add, block as AnyObject)
    }

    private func waited(_ kind: String, from start: Double) {
        let end = CACurrentMediaTime(), thread = Self.threadID()
        records.withLock { if $0.waits.count < 60_000, !$0.stopped { $0.waits.append(Wait(kind: kind, start: start, end: end, thread: thread)) } }
    }

    private func slot(_ count: Int) -> (MTLCounterSampleBuffer, Int)? {
        guard !counterBuffers.isEmpty else { return nil }
        return records.withLock { records in
            guard !records.stopped else { return nil }
            var (buffer, index) = records.counterCursor
            if index + count > Self.counterSamples { (buffer, index) = ((buffer + 1) % counterBuffers.count, 0) }
            records.counterCursor = (buffer, index + count)
            return (counterBuffers[buffer], index)
        }
    }

    private func pending(_ buffer: AnyObject, _ pass: Pass, _ encoder: AnyObject, _ sampleBuffer: MTLCounterSampleBuffer, _ index: Int, _ count: Int) {
        records.withLock {
            $0.pending[ObjectIdentifier(buffer), default: []].append(PendingPass(pass: pass, encoder: encoder, sampleBuffer: sampleBuffer, index: index, count: count))
        }
    }

    private func committing(_ object: AnyObject) {
        guard let buffer = object as? MTLCommandBuffer else { return }
        let record = Buffer(committed: CACurrentMediaTime(), thread: Self.threadID())
        let (index, passes): (Int?, [PendingPass]) = records.withLock { records in
            let passes = records.pending.removeValue(forKey: ObjectIdentifier(object)) ?? []
            guard !records.stopped, records.buffers.count < 60_000 else { return (nil, []) }
            records.buffers.append(record)
            return (records.buffers.count - 1, passes)
        }
        guard let index else { return }
        // Added before the commit, as Metal requires.
        buffer.addCompletedHandler { [weak self] done in
            let timed = passes.map { pending -> Pass in
                var pass = pending.pass
                pass.label = (pending.encoder as? MTLCommandEncoder)?.label ?? ""
                if let data = try? pending.sampleBuffer.resolveCounterRange(pending.index..<pending.index + pending.count) {
                    pass.ticks = data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self).prefix(pending.count)) }
                }
                return pass
            }
            let (label, start, end, status) = (done.label ?? "", done.gpuStartTime, done.gpuEndTime, done.status.rawValue)
            self?.records.withLock { records in
                records.buffers[index].label = label
                records.buffers[index].gpuStart = start
                records.buffers[index].gpuEnd = end
                records.buffers[index].status = Int(status)
                for var pass in timed where records.passes.count < 200_000 {
                    pass = Pass(buffer: index, kind: pass.kind, target: pass.target, label: pass.label, ticks: pass.ticks)
                    records.passes.append(pass)
                }
            }
        }
    }

    /// GPU counter ticks against CACurrentMediaTime, at the start and the end.
    private func calibrate() {
        guard let device, !counterBuffers.isEmpty else { return }
        let (cpu, gpu) = device.sampleTimestamps()
        let now = CACurrentMediaTime()
        // The CPU stamp is mach_absolute_time on some systems and
        // nanoseconds on others: whichever it is closest to.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let mach = Double(mach_absolute_time()), nanos = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let seconds = abs(Double(cpu) - mach) < abs(Double(cpu) - nanos)
            ? Double(cpu) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            : Double(cpu) / 1e9
        // CACurrentMediaTime is mach time in seconds; line the CPU stamp up with it.
        let offset = now - mach * Double(timebase.numer) / Double(timebase.denom) / 1e9
        calibration.append((gpu, seconds + offset))
    }

    // MARK: Export

    /// Stops recording and writes everything as JSON, times in seconds from `origin`.
    func finish(origin: Double) -> [String: Any] {
        calibrate()
        uninstall()
        let records = records.withLock { $0 }
        let r = { (t: Double) in ((t - origin) * 100_000).rounded() / 100_000 }
        // GPU ticks to seconds from the start, through the two calibrations.
        var toTime: ((UInt64) -> Double)?
        if calibration.count >= 2, let first = calibration.first, let last = calibration.last, last.gpu > first.gpu {
            let scale = (last.seconds - first.seconds) / Double(last.gpu - first.gpu)
            toTime = { tick in r(first.seconds + (Double(tick) - Double(first.gpu)) * scale) }
        }
        let thread = { (id: UInt64) in Double(id) }
        let passes: [[String: Any]] = records.passes.compactMap { pass in
            // A missing sample reads as 0 or all ones.
            guard let toTime, !pass.ticks.isEmpty, pass.ticks.allSatisfy({ $0 != 0 && $0 != UInt64.max }) else { return nil }
            let times = pass.ticks.map(toTime)
            var out: [String: Any] = ["buffer": pass.buffer, "kind": pass.kind, "label": pass.label, "target": pass.target,
                                      "start": times.min() ?? 0, "end": times.max() ?? 0]
            if pass.kind == "render", times.count == 4 { out["vertex"] = [times[0], times[1]]; out["fragment"] = [times[2], times[3]] }
            return out
        }
        return [
            "device": device?.name ?? "",
            "counters": counterNote,
            "layers": records.layers.map { layer in
                ["name": layer.name, "pixels": [Double(layer.pixels.width), Double(layer.pixels.height)],
                 "screen_share": (layer.screenShare * 100).rounded() / 100, "max_drawables": layer.drawables,
                 "presents_with_transaction": layer.withTransaction, "format": layer.format] as [String: Any]
            },
            // Threads are system thread IDs, as the sampler's.
            // [layer, requested, wait seconds, presented (0: never shown, -1: unknown), thread, present called (0: never)]
            "drawables": records.drawables.map { d -> [Double] in
                [Double(d.layer), r(d.requested), (d.wait * 100_000).rounded() / 100_000,
                 d.presented.map { $0 > 0 ? r($0) : 0 } ?? -1, thread(d.thread), d.presentCalled.map(r) ?? 0]
            },
            // [committed, gpu start, gpu end, thread, status] (gpu 0: no time reported)
            "command_buffers": records.buffers.map { b -> [Double] in
                [r(b.committed), b.gpuStart > 0 ? r(b.gpuStart) : 0, b.gpuEnd > 0 ? r(b.gpuEnd) : 0, thread(b.thread), Double(b.status)]
            },
            "command_buffer_labels": records.buffers.map(\.label),
            "passes": passes,
            // [kind, start, end, thread]
            "waits": records.waits.map { [$0.kind, r($0.start), r($0.end), thread($0.thread)] as [Any] },
            "events": records.events
        ]
    }

    private static func describe(_ texture: MTLTexture?) -> String {
        guard let texture else { return "" }
        let size = "\(texture.width)×\(texture.height)"
        if let label = texture.label, !label.isEmpty { return label + " " + size }
        return (texture.isFramebufferOnly ? "drawable " : "") + size
    }

    private static func format(_ format: MTLPixelFormat) -> String {
        switch format {
        case .bgra8Unorm: "bgra8"
        case .bgra8Unorm_srgb: "bgra8 sRGB"
        case .rgba16Float: "rgba16f"
        case .bgr10a2Unorm: "bgr10a2"
        case .bgra10_xr: "bgra10 XR"
        case .bgra10_xr_srgb: "bgra10 XR sRGB"
        case .bgr10_xr: "bgr10 XR"
        case .bgr10_xr_srgb: "bgr10 XR sRGB"
        default: "format \(format.rawValue)"
        }
    }
}
#endif
