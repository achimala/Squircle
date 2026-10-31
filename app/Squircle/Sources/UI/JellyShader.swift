import Metal
import simd
import Foundation

/// Matches `Uniforms` in the shader.
struct JellyUniforms {
    var tint: SIMD4<Float>
    var fill: SIMD4<Float>
    var face: SIMD4<Float>      // lid, happy, squint, worry
    var inverse: SIMD4<Float>   // the blob's deformation, inverted (a b c d)
    var creature: SIMD4<Float>  // centre xy, size, neck reach
    var pose: SIMD4<Float>      // yaw, pitch, roll, squash
    var gaze: SIMD4<Float>
    var bridge: SIMD4<Float>
    var stubs: SIMD4<Float>
    /// Who it is: eye spacing, cube aspect (wide > 1), eye size, corner roundness.
    var look: SIMD4<Float> = JellyUniforms.plainLook
    /// A worker's features (`JellyTraits`): topper, its lean, eye style, mouth.
    var traits: SIMD4<Float> = .zero
    /// A worker's markings: pattern, blush, -, -.
    var marks: SIMD4<Float> = .zero
    var center: SIMD2<Float>
    var half: SIMD2<Float>
    var origin: SIMD2<Float>
    var scale: Float
    var radius: Float
    var pillow: Float
    var time: Float
    var churn: Float
    var opened: Float
    var dark: Float
    /// 0: the jelly; 2: its coverage only (the blur's mask).
    var mode: Float

    /// The app's agent and the overlay's creature: the plain shape.
    static let plainLook = SIMD4<Float>(1, 1, 1, 0.28)

    var isFinite: Bool {
        [tint, fill, face, inverse, creature, pose, gaze, bridge, stubs, look, traits, marks].allSatisfy { v in (0..<4).allSatisfy { v[$0].isFinite } }
            && [center, half, origin].allSatisfy { $0.x.isFinite && $0.y.isFinite } && pillow.isFinite && opened.isFinite
    }

    /// For the blob layer: whether anything it draws has moved.
    func isClose(to o: JellyUniforms) -> Bool {
        func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ e: Float) -> Bool { (0..<4).allSatisfy { Swift.abs(a[$0] - b[$0]) < e } }
        func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { (0..<2).allSatisfy { Swift.abs(a[$0] - b[$0]) < 0.02 } }
        return near(tint, o.tint, 0.002) && near(fill, o.fill, 0.002) && near(inverse, o.inverse, 0.0005)
            && near(face, o.face, 0.003) && near(pose, o.pose, 0.0008) && near(gaze, o.gaze, 0.01)
            && near(bridge, o.bridge, 0.005) && near(stubs, o.stubs, 0.01) && look == o.look && traits == o.traits && marks == o.marks
            && near(creature, o.creature, 0.05) && near(center, o.center) && near(half, o.half) && near(origin, o.origin)
            && Swift.abs(pillow - o.pillow) < 0.02 && radius == o.radius && dark == o.dark && Swift.abs(opened - o.opened) < 0.002
    }
}

/// The jelly's one shader, for the overlay's body, the hero and every
/// sprite. Not tied to the main actor: sprites render on a background task.
enum JellyRenderer {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    /// Compiled from source once, so the overlay framework needs no
    /// separate Metal library.
    static let pipeline: MTLRenderPipelineState? = {
        guard let device else { return nil }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: source, options: nil) } catch {
            #if DEBUG
            print("GlassJelly shader:", error)
            #endif
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "jellyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "jellyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    /// Encodes one jelly into `texture`, cleared first; the caller commits
    /// and presents as its host needs. False if Metal gave no encoder.
    static func encode(_ u: inout JellyUniforms, into texture: MTLTexture, on commands: MTLCommandBuffer,
                       pipeline: MTLRenderPipelineState) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<JellyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 tint;      // rgb, strength
        float4 fill;      // rgb, amount
        float4 face;      // lid, happy, squint, worry
        float4 inverse;   // a b c d
        float4 creature;  // centre xy, size, neck reach
        float4 pose;      // yaw, pitch, roll, squash
        float4 gaze;      // look xy, neck root xy
        float4 bridge;    // waist, catenoid c, end radius, connected
        float4 stubs;     // stub at the root, stub at the cube, cube scale, -
        float4 look;      // eye spacing, cube aspect, eye size, corner roundness
        float4 traits;    // topper, lean, eye style, mouth
        float4 marks;     // pattern, blush, -, -
        float2 center;
        float2 half_;
        float2 origin;
        float scale, radius, pillow, time, churn, opened, dark, mode;
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut jellyVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static float2 rest(float2 p, constant Uniforms& u) {
        float2 d = p - u.center;
        return float2(u.inverse.x * d.x + u.inverse.z * d.y, u.inverse.y * d.x + u.inverse.w * d.y);
    }

    static float roundBox(float2 q, float2 h, float r) {
        float2 b = abs(q) - h + r;
        return length(max(b, 0.0)) + min(max(b.x, b.y), 0.0) - r;
    }

    static float blob(float2 q, constant Uniforms& u) {
        float2 h = u.half_;
        float nx = abs(q.x) / max(1.0, h.x), ny = abs(q.y) / max(1.0, h.y);
        float along = nx > ny ? q.y / max(1.0, h.y) : q.x / max(1.0, h.x);
        return roundBox(q, h, u.radius) - u.pillow * max(0.0, 1.0 - along * along);
    }

    static float smin(float a, float b, float k) {
        float h = max(k - abs(a - b), 0.0) / k;
        return min(a, b) - h * h * k * 0.25;
    }

    static float segment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    static float capsule(float3 p, float3 a, float3 b, float r) {
        float3 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h) - r;
    }

    static float ellipsoid(float3 p, float3 r) {
        float k0 = length(p / r), k1 = length(p / (r * r));
        return k0 * (k0 - 1.0) / max(k1, 1e-4);
    }

    static float2 spin(float2 v, float a) { return float2(cos(a) * v.x - sin(a) * v.y, sin(a) * v.x + cos(a) * v.y); }

    // Two eyes in a face plane (points). Coverage in .a, ink in .rgb.
    static float4 eyes(float2 q, float px, float3 tint, constant Uniforms& u) {
        float lid = u.face.x, happy = u.face.y, squint = u.face.z, worry = u.face.w;
        float3 ink = u.dark > 0.5 ? float3(0.97, 0.95, 0.92) : mix(float3(0.07, 0.05, 0.05), tint * 0.3, 0.2);
        float3 col = float3(0.0);
        float a = 0.0;
        for (int i = 0; i < 2; i++) {
            float sgn = i == 0 ? -1.0 : 1.0;
            float2 c = u.gaze.xy + float2(sgn * 5.2 * u.look.x, -1.2);
            float2 v = q - c;
            float ang = sgn * worry * 0.38;
            v = float2(cos(ang) * v.x - sin(ang) * v.y, sin(ang) * v.x + cos(ang) * v.y);
            float grow = 1.0 + 0.12 * worry;
            // Eye style: beads, tall pills, big rounds, tiny dots, wide ovals, uneven.
            int style = int(u.traits.z + 0.5);
            float2 base = style == 1 ? float2(1.8, 4.4) : style == 2 ? float2(3.2, 3.3) : style == 3 ? float2(1.55, 1.8)
                : style == 4 ? float2(3.3, 2.3) : float2(2.5, 3.6);
            if (style == 5) { base *= i == 0 ? 1.22 : 0.82; }
            float2 rr = float2(base.x, max(0.3, base.y * lid)) * grow;
            float bead = (length(v / rr) - 1.0) * min(rr.x, rr.y);
            float R = 2.7;
            float2 w = v - float2(0.0, R * 0.55);
            float arc = w.y < R * 0.1 ? abs(length(w) - R) - 0.9 : 9.0;
            float2 tip = float2(-sgn * 1.7, 0.0);
            float chevron = min(segment(v, float2(sgn * 1.5, -2.0), tip), segment(v, tip, float2(sgn * 1.5, 2.0))) - 0.85;
            float kb = smoothstep(px, -px, bead) * (1.0 - happy) * (1.0 - squint);
            float ka = smoothstep(px, -px, arc) * happy * (1.0 - squint);
            float ks = smoothstep(px, -px, chevron) * squint;
            float k = clamp(kb + ka + ks, 0.0, 1.0) * 0.95;
            col = col * (1.0 - k) + ink * k;
            a = a * (1.0 - k) + k;
            float gr = style == 2 ? 1.05 : style == 3 ? 0.45 : 0.75;
            float glint = exp(-length_squared((v - float2(-0.36, -0.39) * rr) / gr)) * kb;
            col += float3(glint * 0.9);
            a += glint * 0.4;
        }
        // A mouth: smile, o, :3, flat, open; worried it's an o, squinting flat, happy open.
        int ms = int(u.traits.w + 0.5);
        if (ms > 0) {
            if (worry > 0.5) { ms = 2; } else if (squint > 0.5) { ms = 4; } else if (happy > 0.5 && ms != 3) { ms = 5; }
            float2 m = (q - float2(u.gaze.x * 0.7, 4.1 + u.gaze.y * 0.4)) / 1.35;
            float dm = 9.0;
            if (ms == 1) { float2 w = m - float2(0.0, -1.3); dm = w.y > 0.3 ? abs(length(w) - 1.7) - 0.48 : 9.0; }
            else if (ms == 2) { float2 rm = float2(0.85, 1.05); dm = (length(m / rm) - 1.0) * 0.85; }
            else if (ms == 3) {
                float2 w = float2(abs(m.x) - 0.8, m.y + 0.2);
                dm = w.y > 0.0 ? abs(length(w) - 0.8) - 0.4 : 9.0;
            }
            else if (ms == 4) { dm = segment(m, float2(-1.2, 0.0), float2(1.2, 0.0)) - 0.45; }
            else { float2 w = m - float2(0.0, -0.5); dm = max(length(w) - 1.7, -w.y); }
            float k = smoothstep(px, -px, dm) * 0.95;
            col = col * (1.0 - k) + ink * k;
            a = a * (1.0 - k) + k;
        }
        // Freckles under the eyes.
        if (int(u.marks.x + 0.5) == 4) {
            for (int i = 0; i < 2; i++) {
                float sgn = i == 0 ? -1.0 : 1.0;
                float2 c = float2(sgn * 5.2 * u.look.x, 3.0) + u.gaze.xy * 0.6;
                float d = min(min(length(q - c - float2(-1.1, 0.0)), length(q - c - float2(1.1, 0.1))), length(q - c - float2(0.0, 1.0))) - 0.5;
                float k = smoothstep(px, -px, d) * 0.6;
                col = col * (1.0 - k) + ink * k;
                a = a * (1.0 - k) + k;
            }
        }
        return float4(col, clamp(a, 0.0, 1.0));
    }

    // One material: translucent jelly tinted all through, gently deeper
    // toward its edges, one soft rim of light and one soft warm highlight.
    // Everything added is premultiplied, so nothing is clamped grey.
    static float4 jelly(float3 n, float3 V, float shape, constant Uniforms& u) {
        float3 tint = u.tint.rgb;
        float s = u.tint.a;
        float3 L = normalize(float3(-0.45, -0.8, -0.9));
        float fres = pow(1.0 - clamp(dot(n, V), 0.0, 1.0), 2.0);
        float a = s * (0.42 + 0.22 * fres);
        float3 light = mix(tint, float3(1.0), 0.65);
        // Faces turned up are lighter, turned aside a little deeper.
        float3 col = mix(tint, light, max(shape - 1.0, 0.0)) * a * min(shape, 1.0);
        float rim = fres * 0.18 * (0.5 + 0.5 * dot(normalize(n.xy + 1e-5), normalize(L.xy)));
        col += light * rim;
        a += rim;
        float spec = pow(max(dot(reflect(-L, n), V), 0.0), 14.0) * 0.22;
        col += light * spec;
        a += spec;
        return float4(col, a);
    }

    static float3x3 turn(float yaw, float pitch, float roll) {
        float cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch), cr = cos(roll), sr = sin(roll);
        float3x3 ry = float3x3(float3(cy, 0.0, -sy), float3(0.0, 1.0, 0.0), float3(sy, 0.0, cy));
        float3x3 rx = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, cp, sp), float3(0.0, -sp, cp));
        float3x3 rz = float3x3(float3(cr, sr, 0.0), float3(-sr, cr, 0.0), float3(0.0, 0.0, 1.0));
        return ry * rx * rz;
    }

    // MARK: one 3D field: the body (a rounded slab), the bridge and the cube.

    struct Scene { float3x3 inv; float3 cube; float s; };

    // The pill or panel: its 2D outline extruded, every edge fully rounded.
    static float slab(float3 P, constant Uniforms& u) {
        float d2 = blob(rest(P.xy, u), u);
        float T = clamp(min(u.half_.x, u.half_.y) * 0.55, 8.0, 12.0);
        float2 w = float2(d2 + T, abs(P.z));
        return min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - T;
    }

    // The cube; squashed it keeps its volume (wider and deeper as it shortens).
    static float cubeD(float3 P, Scene sc, constant Uniforms& u) {
        float s = sc.s, squash = u.pose.w;
        float3 l = sc.inv * (P - sc.cube);
        l.y -= s * 0.5 * squash;
        float side = 1.0 / sqrt(max(0.4, 1.0 - squash));
        float asp = sqrt(u.look.y);
        float3 b = float3(s * 0.5 * side * asp, s * 0.5 * (1.0 - squash) / asp, s * 0.4 * side);
        float r = s * u.look.w;
        float3 q = abs(l) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
    }

    // A worker's topper, in the cube's frame: antenna, leaf sprout, ears, tuft, bun.
    static float topperD(float3 P, Scene sc, constant Uniforms& u) {
        int kind = int(u.traits.x + 0.5);
        if (kind == 0) { return 1e4; }
        float s = sc.s, squash = u.pose.w, lean = u.traits.y;
        float3 l = sc.inv * (P - sc.cube);
        l.y -= s * 0.5 * squash;
        float top = -s * 0.5 * (1.0 - squash) / sqrt(u.look.y);
        float3 root = float3(lean * s * 0.14, top + s * 0.06, 0.0);
        if (kind == 1) {
            float3 tip = root + float3(lean * s * 0.2, -s * 0.36, 0.0);
            return min(capsule(l, root, tip, s * 0.055), length(l - tip) - s * 0.12);
        }
        if (kind == 2) {
            float3 mid = root + float3(lean * s * 0.05, -s * 0.2, 0.0);
            float d = capsule(l, root, mid, s * 0.05);
            for (int i = 0; i < 2; i++) {
                float sgn = i == 0 ? -1.0 : 1.0;
                float3 v = l - mid - float3(sgn * s * 0.12, -s * 0.05, 0.0);
                v.xy = spin(v.xy, sgn * 0.5);
                d = min(d, ellipsoid(v, float3(s * 0.14, s * 0.065, s * 0.06)));
            }
            return d;
        }
        if (kind == 3) {
            float d = 1e4;
            for (int i = 0; i < 2; i++) {
                float sgn = i == 0 ? -1.0 : 1.0;
                float3 v = l - float3(sgn * s * 0.27, top - s * 0.02, 0.0);
                v.xy = spin(v.xy, sgn * (0.35 + 0.25 * lean * sgn));
                d = min(d, ellipsoid(v, float3(s * 0.12, s * 0.17, s * 0.08)));
            }
            return d;
        }
        if (kind == 4) {
            float d = 1e4;
            for (int i = -1; i <= 1; i++) {
                float3 tip = root + float3(float(i) * s * 0.13 + lean * s * 0.08, -s * (i == 0 ? 0.3 : 0.22), 0.0);
                d = min(d, capsule(l, root, tip, s * 0.04));
            }
            return d;
        }
        float3 bun = root + float3(0.0, -s * 0.1, 0.0);
        return min(length(l - bun) - s * 0.16, length(l - bun - float3(lean * s * 0.12, -s * 0.16, 0.0)) - s * 0.07);
    }

    static float headD(float3 P, Scene sc, constant Uniforms& u) {
        float d = cubeD(P, sc, u);
        return u.traits.x > 0.5 ? smin(d, topperD(P, sc, u), sc.s * 0.12) : d;
    }

    // The liquid bridge: a catenoid, r(t) = waist·cosh((t − L/2)/c), the
    // shape surface tension pulls a neck between two bodies into.
    static float bridgeD(float3 P, Scene sc, constant Uniforms& u) {
        // It ends inside the cube's near side, not at its centre, so it never
        // pushes out the face.
        // Flattened front to back, so its end inside the cube never bulges
        // the cube's face (the smooth union would show it as a ring).
        P.z *= 1.6;
        float3 a = float3(u.gaze.zw, 0.0);
        float3 toward = sc.cube - a;
        float3 b = sc.cube - normalize(toward + 1e-4) * sc.s * 0.28;
        float3 ba = b - a;
        float L = max(0.001, length(ba));
        float3 dir = ba / L;
        float t = dot(P - a, dir);
        float rEnd = u.bridge.z;
        if (u.bridge.w > 0.5) {
            float tc = clamp(t, 0.0, L);
            float r = min(rEnd, u.bridge.x * cosh((tc - L * 0.5) / max(0.01, u.bridge.y)));
            return (length(P - (a + dir * tc)) - r) * 0.5;
        }
        // Pinched off: each half is a stub drawn back into its body.
        float d = 1e4;
        float la = u.stubs.x, lb = u.stubs.y;
        if (la > 0.3) {
            float tc = clamp(t, 0.0, la);
            float r = mix(rEnd, 2.2, tc / la);
            d = min(d, (length(P - (a + dir * tc)) - r) * 0.5);
        }
        if (lb > 0.3) {
            float tc = clamp(L - t, 0.0, lb);
            float r = mix(rEnd, 2.2, tc / lb);
            d = min(d, (length(P - (b - dir * tc)) - r) * 0.5);
        }
        return d;
    }

    // Menisci: each join is a smooth union, a concave fillet.
    static float scene(float3 P, Scene sc, constant Uniforms& u) {
        float body = slab(P, u), neck = bridgeD(P, sc, u), head = headD(P, sc, u);
        return smin(smin(body, neck, 7.0), head, 7.0);
    }

    // The face, paper and material on a point of the surface.
    static float4 shade(float3 pos, float3 n, float dBody, float dHead, float2 rested, float px, Scene sc, constant Uniforms& u) {
        // Faces turned up a touch lighter, so the cube reads as a cube.
        float shape = 1.0 + 0.25 * (-n.y) - 0.1 * abs(n.x);
        float4 j = jelly(n, float3(0.0, 0.0, -1.0), shape, u);
        float3 col = j.rgb;
        float a = j.a;

        // Paper inside the panel as it opens (its flat front only), so text reads.
        float bevel = clamp(min(u.half_.x, u.half_.y) * 0.8, 5.0, 16.0);
        float depth = clamp(-blob(rested, u) / bevel, 0.0, 1.0);
        float bodyness = smoothstep(2.0, -0.5, dBody);
        float f = u.fill.a * smoothstep(0.15, 0.9, depth) * smoothstep(0.75, 0.97, -n.z) * bodyness;
        // The paper is the same jelly, a breath of its tint in it.
        float3 paper = mix(u.fill.rgb, u.tint.rgb, 0.12 * u.tint.a);
        col = col * (1.0 - f) + paper * f;
        a = a * (1.0 - f) + f;

        // The head has more body than the slab, so its see-through middle
        // never reads as a dark disc over a dark app.
        float head = smoothstep(3.0, 0.0, dHead) * u.tint.a * 0.14;
        col += mix(u.tint.rgb, float3(1.0), u.dark > 0.5 ? 0.15 : 0.35) * head;
        a += head;

        // The face, on the cube's front.
        if (dHead < 3.0) {
            float3 l = sc.inv * (pos - sc.cube);
            // Markings in the body's own tint, deeper (spots, band, cap) or
            // paler (belly), and blush on the cheeks: colour stays the state.
            int mk = int(u.marks.x + 0.5);
            float3 ln = l / sc.s;
            float w = px / sc.s * 1.2;
            float deep = 0.0, pale = 0.0;
            if (mk == 1) {
                float2 f = ln.xy;
                float d = min(min(length(f - float2(0.33, -0.3)) - 0.085, length(f - float2(-0.36, 0.24)) - 0.075),
                              min(length(f - float2(0.3, 0.3)) - 0.06, length(f - float2(-0.1, -0.38)) - 0.06));
                deep = smoothstep(w, -w, d);
            } else if (mk == 2) {
                deep = smoothstep(w, -w, abs(ln.y + 0.31) - 0.06);
            } else if (mk == 3) {
                pale = smoothstep(w, -w, length((ln.xy - float2(0.0, 0.3)) / float2(0.27, 0.13)) - 1.0) * smoothstep(-0.2, -0.32, ln.z);
            } else if (mk == 5) {
                deep = smoothstep(-0.27 + w, -0.27 - w, ln.y);
            } else if (mk == 6) {
                deep = smoothstep(w, -w, abs(fract(ln.y * 4.5 + 0.25) - 0.5) - 0.14) * smoothstep(0.28, 0.4, abs(ln.x));
            }
            float3 deepC = u.dark > 0.5 ? mix(u.tint.rgb, float3(1.0), 0.35) : u.tint.rgb * 0.62;
            float kd = deep * 0.7, kp = pale * 0.75;
            col = col * (1.0 - kd) + deepC * kd;
            a = a * (1.0 - kd) + kd;
            float3 paleC = mix(float3(1.0, 0.98, 0.95), u.tint.rgb, 0.18);
            col = col * (1.0 - kp) + paleC * kp;
            a = a * (1.0 - kp) + kp;
            float front = smoothstep(-sc.s * 0.2, -sc.s * 0.34, l.z) * smoothstep(3.0, 0.5, dHead);
            float4 face = eyes(l.xy / (u.stubs.z * u.look.z), px * 0.9 / (u.stubs.z * u.look.z), u.tint.rgb, u);
            if (u.marks.y > 0.5) {
                float2 fq = l.xy / (u.stubs.z * u.look.z);
                float b = 0.0;
                for (int i = 0; i < 2; i++) {
                    float sgn = i == 0 ? -1.0 : 1.0;
                    b = max(b, exp(-length_squared((fq - float2(sgn * 8.4 * u.look.x, 3.2) - u.gaze.xy * 0.6) / float2(2.1, 1.25))));
                }
                float3 blush = u.dark > 0.5 ? mix(u.tint.rgb, float3(1.0, 0.75, 0.72), 0.5) : mix(u.tint.rgb * 0.75, float3(0.85, 0.3, 0.3), 0.3);
                float kb = b * 0.55 * front;
                col = col * (1.0 - kb) + blush * kb;
                a = a * (1.0 - kb) + kb;
            }
            float k = face.a * front;
            col = col * (1.0 - k) + face.rgb * k;
            a = clamp(a * (1.0 - k) + k, 0.0, 1.0);
        }
        return float4(min(col, float3(a)), a);
    }

    fragment float4 jellyFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = in.position.xy / u.scale + u.origin;
        float px = 1.0 / u.scale;
        Scene sc;
        sc.inv = transpose(turn(u.pose.x, u.pose.y, u.pose.z));
        sc.cube = float3(u.creature.xy, 0.0);
        sc.s = u.creature.z * u.stubs.z;
        float2 q2 = rest(p, u);
        float d2 = blob(q2, u);
        // The outline's slope on screen (before any branch), for the bevel.
        float2 slope = float2(dfdx(d2), dfdy(d2)) * u.scale;
        // How close the cube and the neck come, as seen from the front (a
        // bound on their 3D distance, squashed or turned).
        float near = min(length(p - u.creature.xy) - sc.s * 1.15, segment(p, u.gaze.zw, u.creature.xy) - u.bridge.z);
        // Far from everything: nothing to draw.
        if (min(d2, near) > 10.0) { return float4(0.0); }

        if (near > 8.0) {
            // Only the body here (the joins' smooth unions reach 7 points):
            // its extruded outline is solved directly, no marching.
            float T = clamp(min(u.half_.x, u.half_.y) * 0.55, 8.0, 12.0);
            float wx = d2 + T;
            if (wx - T >= px) { return float4(0.0); }
            float cover = clamp(1.0 - (wx - T) / px, 0.0, 1.0);
            float out = clamp(wx, 0.0, T);
            float z = -sqrt(max(T * T - out * out, 0.0));
            float g = max(length(slope), 1e-4);
            float3 n = wx <= 0.0 ? float3(0.0, 0.0, -1.0) : normalize(float3(slope / g * out, z));
            return shade(float3(p, z), n, 0.0, 1e4, q2, px, sc, u) * cover;
        }

        float3 ro = float3(p, -60.0), rd = float3(0.0, 0.0, 1.0);
        float t = 0.0, dmin = 1e4;
        bool hit = false;
        for (int i = 0; i < 48; i++) {
            float d = scene(ro + rd * t, sc, u);
            dmin = min(dmin, d);
            if (d < 0.02) { hit = true; break; }
            t += d;
            if (t > 120.0) break;
        }
        float cover = hit ? 1.0 : clamp(1.0 - dmin / px, 0.0, 1.0);
        if (cover <= 0.0) { return float4(0.0); }
        float3 pos = ro + rd * t;
        float e = 0.15;
        float3 n = normalize(float3(1, -1, -1) * scene(pos + float3(1, -1, -1) * e, sc, u)
                           + float3(-1, -1, 1) * scene(pos + float3(-1, -1, 1) * e, sc, u)
                           + float3(-1, 1, -1) * scene(pos + float3(-1, 1, -1) * e, sc, u)
                           + float3(1, 1, 1) * scene(pos + float3(1, 1, 1) * e, sc, u));
        return shade(pos, n, slab(pos, u), headD(pos, sc, u), rest(pos.xy, u), px, sc, u) * cover;
    }
    """
}
