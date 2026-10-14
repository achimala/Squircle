#if SQUIRCLE_OVERLAY || DEBUG
import Metal
import UIKit

/// The overlay's bubble: a piece of frosted glass jelly (user, 2026-10-14:
/// "semitransparent frosted glass 3d jelly … instead of being a character
/// inside a bubble it can just be the glassy bubble").
///
/// Three layers share one outline, a squircle whose edge ripples: the app
/// behind, frosted by the system's live blur masked to the outline; a
/// handwritten Metal shader that lights it as a thick, soft cushion (tint
/// that deepens where light travels further through it, a rim lit on the
/// side facing the light, a glint, light focused inside on the far side); and
/// a soft shadow in the jelly's colour, as light through coloured glass casts.
/// It breathes, churns while the agent works, gulps each finished task, hops
/// for your attention, jiggles when a turn is done, squishes under a finger
/// and stretches along its own motion. Text goes in `content`, above it.
@MainActor
final class GlassJelly: UIView {
    var tone = LiveCapsule.Tone.idle {
        didSet {
            guard tone != oldValue else { return }
            toneTime = 0
            squash.velocity += tone == .done ? 4.5 : tone == .needsYou ? 2 : 1.2
        }
    }
    /// Two eyes deep inside the jelly, at `eyeCenter` (points in bounds).
    var eyes = false
    var eyeCenter = CGPoint(x: 22, y: 22)
    /// The jelly's own velocity in points per second; it stretches along it.
    var motion = CGPoint.zero
    /// Holds the text, above the glass; moves with the jelly's squash.
    let content = UIView()

    private let shadow = CAShapeLayer()
    private let frost = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let frostMask = ShapeView()
    private let metal = CAMetalLayer()
    /// Drawn this far outside the bounds, so wobbles and stretches aren't cut.
    private static let margin: CGFloat = 10

    private var squash = Wobble(1, response: 0.4, damping: 0.3)
    private var amp = Wobble(0.012, response: 0.6, damping: 1)
    private var press = Wobble(0, response: 0.18, damping: 0.6)
    private var stretch = (x: Wobble(0, response: 0.25, damping: 0.55), y: Wobble(0, response: 0.25, damping: 0.55))
    private var lid = Wobble(1, response: 0.07, damping: 1)
    private var look = Wobble(0, response: 0.3, damping: 0.75)
    private var tint = (r: Wobble(0, response: 0.35, damping: 1), g: Wobble(0, response: 0.35, damping: 1),
                        b: Wobble(0, response: 0.35, damping: 1), a: Wobble(0, response: 0.35, damping: 1))
    private var time: CGFloat = 0
    private var toneTime: CGFloat = 0
    private var nextBlink: CGFloat = 2
    private var blinkEnd: CGFloat = 0
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var tintSet = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.fillColor = UIColor.clear.cgColor
        shadow.shadowOpacity = 0.45
        shadow.shadowRadius = 7
        shadow.shadowOffset = CGSize(width: 0, height: 5)
        layer.addSublayer(shadow)
        frostMask.shape.fillColor = UIColor.black.cgColor
        frost.mask = frostMask
        frost.isUserInteractionEnabled = false
        addSubview(frost)
        metal.device = JellyRenderer.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        metal.presentsWithTransaction = false
        layer.addSublayer(metal)
        content.isUserInteractionEnabled = false
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A finished task: the jelly swallows it.
    func gulp() { squash.velocity -= 2.4 }

    // Touch: it gives under the finger and springs back.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        press.target = 1
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        release()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        release()
    }
    private func release() {
        press.target = 0
        squash.velocity += 2.5
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        last = nil
        guard window != nil else { return }
        metal.contentsScale = window?.screen.scale ?? 3
        let proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var dt = CGFloat(min(1.0 / 20.0, max(0, now - (last ?? (now - link.duration)))))
        #if DEBUG
        dt /= CGFloat(SpringDriver.debugSlowMotion)
        #endif
        last = now
        time += dt
        toneTime += dt
        step(dt)
        draw()
    }

    // MARK: Motion

    private func toneColor() -> UIColor {
        switch tone {
        case .needsYou: Theme.warning
        case .done: Theme.success
        case .idle, .working: Theme.accent
        }
    }

    private var hop: CGFloat = 0

    private func step(_ dt: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        toneColor().resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        // Clear glass with a warm cast when idle; coloured jelly otherwise.
        let strength: CGFloat = tone == .idle ? 0.35 : 0.75
        (tint.r.target, tint.g.target, tint.b.target, tint.a.target) = (r, g, b, strength)
        if !tintSet {
            tintSet = true
            (tint.r.value, tint.g.value, tint.b.value, tint.a.value) = (r, g, b, strength)
        }
        hop = 0
        switch tone {
        case .idle:
            amp.target = 0.012
            squash.target = 1 + 0.03 * sin(time * 2 * .pi / 3.4)
            look.target = 0
        case .working:
            amp.target = 0.04
            squash.target = 1 + 0.035 * sin(time * 2 * .pi * 0.9)
            look.target = 1.6
        case .needsYou:
            amp.target = 0.025
            squash.target = 1
            look.target = 0
            let p = toneTime.truncatingRemainder(dividingBy: 1.25)
            if p < 0.46 {
                let u = p / 0.46
                hop = -7 * sin(.pi * u)
                // Stretched in the air, squashed as it lands.
                squash.target = 1 + 0.1 * sin(.pi * u)
                if u > 0.9, squash.velocity > -2 { squash.velocity -= 4 }
            }
        case .done:
            amp.target = 0.02
            squash.target = 1
            look.target = 0
        }
        squash.target -= 0.16 * press.value
        // Stretched along its motion, a little behind it.
        let vx = motion.x, vy = motion.y
        stretch.x.target = (abs(vx) / 1800).clamped(0, 0.22)
        stretch.y.target = (abs(vy) / 1800).clamped(0, 0.22)
        if time > nextBlink {
            blinkEnd = time + 0.12
            nextBlink = time + .random(in: 2...5)
        }
        lid.target = time < blinkEnd ? 0.08 : tone == .working ? 0.75 : 1
        for spring in [\GlassJelly.squash, \.amp, \.press, \.lid, \.look] as [ReferenceWritableKeyPath<GlassJelly, Wobble>] {
            self[keyPath: spring].step(dt)
        }
        stretch.x.step(dt); stretch.y.step(dt)
        tint.r.step(dt); tint.g.step(dt); tint.b.step(dt); tint.a.step(dt)
    }

    // MARK: Shape

    /// The outline's geometry this frame, in bounds coordinates.
    private struct Shape {
        var center: CGPoint
        var half: CGSize
        var radius: CGFloat
        var amp: CGFloat
        var time: CGFloat

        /// Signed distance from the rippled rounded box, negative inside.
        func distance(_ p: CGPoint) -> CGFloat {
            let x = p.x - center.x, y = p.y - center.y
            let qx = abs(x) - half.width + radius, qy = abs(y) - half.height + radius
            let outside = hypot(max(qx, 0), max(qy, 0))
            let box = outside + min(max(qx, qy), 0) - radius
            return box - ripple(atan2(y, x)) * min(half.width, half.height)
        }

        func ripple(_ a: CGFloat) -> CGFloat {
            amp * (sin(2 * a + time * 3.1) + 0.7 * sin(3 * a - time * 2.3) + 0.4 * sin(5 * a + time * 4.7))
        }

        /// The zero contour, found along rays from the centre.
        func path() -> CGPath {
            let path = CGMutablePath()
            let far = hypot(half.width, half.height) * 1.6
            let count = 96
            for i in 0..<count {
                let a = CGFloat(i) / CGFloat(count) * 2 * .pi
                let dx = cos(a), dy = sin(a)
                var lo: CGFloat = 0, hi = far
                for _ in 0..<14 {
                    let mid = (lo + hi) / 2
                    if distance(CGPoint(x: center.x + dx * mid, y: center.y + dy * mid)) < 0 { lo = mid } else { hi = mid }
                }
                let p = CGPoint(x: center.x + dx * lo, y: center.y + dy * lo)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        }
    }

    private func currentShape() -> Shape {
        let w = bounds.width, h = bounds.height
        let sy = squash.value * (1 + stretch.y.value - 0.5 * stretch.x.value)
        let sx = (1 / sqrt(max(0.5, squash.value))) * (1 + stretch.x.value - 0.5 * stretch.y.value)
        // Squash and stretch by an absolute amount, so a long pill doesn't
        // grow by more than a square one; its bottom stays on the ground.
        let half = CGSize(width: w / 2 + h / 2 * (sx - 1), height: h / 2 * sy)
        let center = CGPoint(x: w / 2, y: h - half.height + hop)
        return Shape(center: center, half: half, radius: min(half.width, half.height) * 0.86,
                     amp: amp.value, time: time)
    }

    // MARK: Drawing

    private func draw() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let shape = currentShape()
        let path = shape.path()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let margin = Self.margin
        let canvas = bounds.insetBy(dx: -margin, dy: -margin)
        frost.frame = bounds
        frostMask.frame = frost.bounds
        frostMask.shape.path = path
        shadow.frame = bounds
        shadow.shadowPath = path
        shadow.shadowColor = UIColor(red: tint.r.value, green: tint.g.value, blue: tint.b.value, alpha: 1).cgColor
        shadow.shadowOpacity = Float(0.2 + 0.3 * tint.a.value)
        content.frame = bounds
        content.transform = CGAffineTransform(translationX: 0, y: shape.center.y - bounds.midY)
        if metal.frame != canvas {
            metal.frame = canvas
            metal.drawableSize = CGSize(width: canvas.width * metal.contentsScale, height: canvas.height * metal.contentsScale)
        }
        CATransaction.commit()
        render(shape, origin: canvas.origin)
    }

    private func render(_ shape: Shape, origin: CGPoint) {
        guard let pipeline = JellyRenderer.pipeline, let queue = JellyRenderer.queue,
              let drawable = metal.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = JellyUniforms(
            tint: SIMD4(Float(tint.r.value), Float(tint.g.value), Float(tint.b.value), Float(tint.a.value)),
            eye: SIMD4(Float(eyeCenter.x), Float(eyeCenter.y + (shape.center.y - bounds.midY)), Float(lid.value), eyes ? 1 : 0),
            center: SIMD2(Float(shape.center.x), Float(shape.center.y)),
            half: SIMD2(Float(shape.half.width), Float(shape.half.height)),
            origin: SIMD2(Float(origin.x), Float(origin.y)),
            scale: Float(metal.contentsScale), radius: Float(shape.radius), amp: Float(shape.amp), time: Float(shape.time),
            churn: Float(tone == .working ? 1 : 0.3), look: Float(look.value), dark: traitCollection.userInterfaceStyle == .dark ? 1 : 0, pad: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<JellyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// A view whose layer is a shape, for masks.
final class ShapeView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shape: CAShapeLayer { layer as! CAShapeLayer }
}

/// One damped spring on a value.
struct Wobble {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    var parameters: SpringDriver.Parameters

    init(_ value: CGFloat, response: CGFloat, damping: CGFloat) {
        self.value = value
        target = value
        parameters = .init(response: response, damping: damping)
    }

    mutating func step(_ dt: CGFloat) {
        (value, velocity) = SpringDriver.step(value: value, velocity: velocity, target: target, dt: dt, parameters: parameters)
    }
}

/// Matches `Uniforms` in the shader.
struct JellyUniforms {
    var tint: SIMD4<Float>
    var eye: SIMD4<Float>
    var center: SIMD2<Float>
    var half: SIMD2<Float>
    var origin: SIMD2<Float>
    var scale: Float
    var radius: Float
    var amp: Float
    var time: Float
    var churn: Float
    var look: Float
    var dark: Float
    var pad: Float
}

@MainActor
enum JellyRenderer {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    /// Compiled from source once, so the overlay framework needs no
    /// separate Metal library.
    static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "jellyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "jellyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 tint;      // rgb, strength
        float4 eye;       // x, y, open, on
        float2 center;
        float2 half_;
        float2 origin;
        float scale, radius, amp, time, churn, look, dark, pad;
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut jellyVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static float ripple(float a, constant Uniforms& u) {
        return u.amp * (sin(2.0 * a + u.time * 3.1) + 0.7 * sin(3.0 * a - u.time * 2.3) + 0.4 * sin(5.0 * a + u.time * 4.7));
    }

    static float sdf(float2 p, constant Uniforms& u) {
        float2 d = p - u.center;
        float2 q = abs(d) - u.half_ + u.radius;
        float box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.radius;
        return box - ripple(atan2(d.y, d.x), u) * min(u.half_.x, u.half_.y);
    }

    // A cushion: flat on top, rounding down to the edge over `bevel` points.
    static float height(float2 p, float bevel, constant Uniforms& u) {
        float t = clamp(-sdf(p, u) / bevel, 0.0, 1.0);
        return sqrt(1.0 - (1.0 - t) * (1.0 - t));
    }

    fragment float4 jellyFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = in.position.xy / u.scale + u.origin;
        float d = sdf(p, u);
        float px = 1.0 / u.scale;
        float cover = clamp(0.5 - d / px, 0.0, 1.0);
        if (cover <= 0.0) { return float4(0.0); }

        float bevel = max(5.0, min(u.half_.x, u.half_.y) * 0.8);
        float lift = bevel * 0.7;
        float e = 0.6;
        float hx = (height(p + float2(e, 0.0), bevel, u) - height(p - float2(e, 0.0), bevel, u)) / (2.0 * e) * lift;
        float hy = (height(p + float2(0.0, e), bevel, u) - height(p - float2(0.0, e), bevel, u)) / (2.0 * e) * lift;
        float3 n = normalize(float3(-hx, -hy, 1.0));

        float3 L = normalize(float3(-0.45, -0.8, 0.9));
        float fres = pow(1.0 - n.z, 1.6);
        float2 side = normalize(n.xy + 1e-5);
        float facing = 0.5 + 0.5 * dot(side, normalize(-L.xy));
        float3 R = reflect(-L, n);
        float spec = pow(max(R.z, 0.0), 120.0) * 1.3 + pow(max(R.z, 0.0), 14.0) * 0.12;

        float3 tint = u.tint.rgb;
        float s = u.tint.a;
        // Light travels further through the jelly near its edge.
        float absorb = s * (0.1 + 0.8 * fres);
        float3 col = tint * absorb;
        float a = absorb;

        // Light gathered inside, opposite the light, drifting as it churns.
        float t = u.time;
        float2 c1 = u.center + u.half_ * float2(0.38 + 0.1 * sin(t * 1.3 * (0.5 + u.churn)), 0.5 + 0.08 * cos(t * 1.7));
        float2 c2 = u.center + u.half_ * float2(-0.2 + 0.35 * sin(t * 0.9 * u.churn + 1.0), 0.25 + 0.2 * cos(t * 1.1 * u.churn));
        float r0 = min(u.half_.x, u.half_.y);
        float caus = exp(-length_squared((p - c1) / (r0 * float2(0.55, 0.32)))) * 0.55
                   + exp(-length_squared((p - c2) / (r0 * 0.4))) * 0.25 * u.churn;
        float3 glow = mix(tint, float3(1.0), 0.55);
        col += glow * caus * s * 0.9;
        a += caus * s * 0.45;

        // Rim: bright where it faces the light, deeper where it turns away.
        float rim = fres * facing;
        col += float3(1.0) * rim * 0.75;
        a += rim * 0.75;
        float shade = fres * (1.0 - facing);
        col += tint * 0.45 * shade * s;
        a += shade * (0.3 + 0.3 * s);

        // The candy gloss: a soft streak just inside the top edge.
        float2 g0 = u.center + float2(-u.half_.x * 0.08, -u.half_.y * 0.62);
        float2 gq = (p - g0) / float2(max(4.0, u.half_.x - r0 * 0.55), r0 * 0.2);
        float gloss = exp(-pow(length_squared(gq), 2.0)) * 0.7;
        col += float3(gloss);
        a += gloss;

        // A crisp edge, then the glint.
        float edge = smoothstep(1.4, 0.0, abs(d)) * (0.25 + 0.35 * facing);
        col += float3(1.0) * edge;
        a += edge;
        col += float3(spec);
        a += spec;

        // Eyes: two beads deep in the jelly, looking toward the text.
        if (u.eye.w > 0.5) {
            float2 ec = u.eye.xy + float2(u.look, 0.0);
            for (int i = 0; i < 2; i++) {
                float2 c = ec + float2(i == 0 ? -4.6 : 4.6, -1.0);
                float2 q = (p - c) / float2(2.3, max(0.25, 3.3 * u.eye.z));
                float k = smoothstep(1.0 + 1.6 * px * 2.0, 1.0 - 0.6, length(q));
                float3 bead = mix(tint * 0.28, float3(0.06), 0.4 + 0.3 * u.dark);
                col = mix(col, bead * 0.92, k * 0.92);
                a = mix(a, 0.92, k * 0.92);
                float g = exp(-length_squared((p - c - float2(-0.8, -1.3)) / 0.7));
                col += float3(g * 0.9 * k);
                a += g * 0.5 * k;
            }
        }

        a = clamp(a, 0.0, 1.0);
        col = min(col, float3(a));
        return float4(col, a) * cover;
    }
    """
}
#endif
