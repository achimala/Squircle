import Metal
import QuartzCore
import UIKit

/// Light drawn around a glass control with handwritten Metal shaders
/// (`Effects.metal`): a flowing spectrum on the outline while the agent works,
/// or a ring of light leaving it when a turn finishes. The view is larger than
/// the shape so the bloom can spill outside it; `inset` is that margin.
@MainActor
final class EffectView: UIView {
    enum Mode: Int32 { case glow = 0, ripple = 1 }

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var mode = Mode.glow
    var inset: CGFloat = 18 { didSet { setNeedsLayout() } }
    var cornerRadius: CGFloat = 22
    /// Eased toward `targetIntensity` every frame so light fades in and out.
    private var intensity: Float = 0
    private var targetIntensity: Float = 0
    private var progress: Float = 0
    private var started = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var completion: (() -> Void)?

    private struct Uniforms {
        var size: SIMD2<Float>
        var shapeOrigin: SIMD2<Float>
        var shapeSize: SIMD2<Float>
        var radius: Float
        var scale: Float
        var time: Float
        var intensity: Float
        var progress: Float
        var dark: Float
        var mode: Int32
    }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "effectVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "effectFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        metalLayer.device = Self.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Turns the glow on or off; it fades rather than snapping.
    func setActive(_ active: Bool, intensity: Float = 1) {
        targetIntensity = active && !Motion.reduced ? intensity : 0
        if targetIntensity > 0 || self.intensity > 0 { startLink() }
    }

    /// One ripple, then `completion`.
    func ripple(completion: (() -> Void)? = nil) {
        guard !Motion.reduced else { completion?(); return }
        mode = .ripple
        progress = 0
        intensity = 1
        targetIntensity = 1
        started = CACurrentMediaTime()
        self.completion = completion
        startLink()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if link == nil, intensity > 0 { draw() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopLink() } else if targetIntensity > 0 || intensity > 0 { startLink() }
    }

    private func startLink() {
        guard link == nil, window != nil else { return }
        let link = CADisplayLink(target: EffectLinkTarget { [weak self] in self?.tick() }, selector: #selector(EffectLinkTarget.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func tick() {
        if mode == .ripple {
            progress = Float((CACurrentMediaTime() - started) / 1.1)
            if progress >= 1 {
                stopLink()
                intensity = 0
                draw()
                let done = completion
                completion = nil
                done?()
                return
            }
        } else {
            intensity += (targetIntensity - intensity) * 0.08
            if abs(intensity - targetIntensity) < 0.005 { intensity = targetIntensity }
            if intensity == 0, targetIntensity == 0 { draw(); stopLink(); return }
        }
        draw()
    }

    private func draw() {
        guard let pipeline = Self.pipeline, let queue = Self.queue, bounds.width > 1,
              let drawable = metalLayer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let scale = Float(metalLayer.contentsScale)
        let shape = bounds.insetBy(dx: inset, dy: inset)
        var uniforms = Uniforms(
            size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            shapeOrigin: SIMD2(Float(shape.minX) * scale, Float(shape.minY) * scale),
            shapeSize: SIMD2(Float(shape.width) * scale, Float(shape.height) * scale),
            radius: Float(min(cornerRadius, shape.height / 2, shape.width / 2)) * scale,
            scale: scale,
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)),
            intensity: intensity,
            progress: progress,
            dark: traitCollection.userInterfaceStyle == .dark ? 1 : 0,
            mode: mode.rawValue)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Breaks the display link's strong reference to its target.
private final class EffectLinkTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { MainActor.assumeIsolated { handler() } }
}
