import Metal
import MetalKit
import UIKit

/// The hand-off between two lines of text under a glass capsule, drawn with
/// the `lensFragment` shader: the old line rises out through the glass edge,
/// bending as it goes, while the new one rises in from below.
@MainActor
final class LensView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var textures: (MTLTexture, MTLTexture)?
    private var started = CACurrentMediaTime()
    private var duration: CFTimeInterval { 0.62 * Self.slowMotion }
    /// Debug-only slow motion for frame-by-frame review.
    nonisolated(unsafe) static var slowMotion: CFTimeInterval = 1
    private var link: CADisplayLink?
    private var completion: (() -> Void)?

    private struct Uniforms { var size: SIMD2<Float>; var progress: Float }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let loader = device.map(MTKTextureLoader.init(device:))
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "effectVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lensFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        metalLayer.device = Self.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    /// Plays one hand-off from `old` to `new`, both rendered at this view's size.
    /// Returns false when Metal is unavailable, so the caller can fall back.
    @discardableResult
    func play(from old: UIImage, to new: UIImage, completion: @escaping () -> Void) -> Bool {
        guard let loader = Self.loader, let a = old.cgImage, let b = new.cgImage,
              let first = try? loader.newTexture(cgImage: a, options: [.SRGB: false]),
              let second = try? loader.newTexture(cgImage: b, options: [.SRGB: false]) else { return false }
        self.completion?()
        textures = (first, second)
        self.completion = completion
        started = CACurrentMediaTime()
        if link == nil {
            let link = CADisplayLink(target: LensLinkTarget { [weak self] in self?.tick() }, selector: #selector(LensLinkTarget.fire))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        draw(progress: 0)
        return true
    }

    private func tick() {
        let t = min(1, (CACurrentMediaTime() - started) / duration)
        // Ease in-out with a soft landing.
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        draw(progress: Float(eased))
        guard t >= 1 else { return }
        link?.invalidate()
        link = nil
        let done = completion
        completion = nil
        done?()
    }

    private func draw(progress: Float) {
        guard let pipeline = Self.pipeline, let queue = Self.queue, let textures, bounds.width > 1,
              let drawable = metalLayer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)), progress: progress)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(textures.0, index: 0)
        encoder.setFragmentTexture(textures.1, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

private final class LensLinkTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { MainActor.assumeIsolated { handler() } }
}
