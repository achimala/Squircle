#include <metal_stdlib>
using namespace metal;

// Light for glass shapes. Every effect is drawn around a rounded rectangle
// (the glass control's own outline), in points scaled to pixels.

struct EffectUniforms {
    float2 size;        // drawable size, pixels
    float2 shapeOrigin; // shape's top-left inside the drawable, pixels
    float2 shapeSize;   // shape size, pixels
    float radius;       // shape corner radius, pixels
    float scale;        // pixels per point
    float time;         // seconds
    float intensity;    // 0…1 overall strength, animated by the host
    float progress;     // 0…1 for one-shot effects
    float dark;         // 1 in dark appearance
    int mode;           // 0 edge glow, 1 ripple
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut effectVertex(uint id [[vertex_id]]) {
    // One triangle covering the drawable.
    float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(corners[id], 0, 1);
    out.uv = float2(corners[id].x * 0.5 + 0.5, 0.5 - corners[id].y * 0.5);
    return out;
}

static float roundedBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Apple-Intelligence-like spectrum: orange, pink, violet, blue, cyan.
static float3 spectrum(float t) {
    const float3 stops[5] = {
        float3(1.00, 0.62, 0.26), float3(1.00, 0.36, 0.64), float3(0.62, 0.40, 1.00),
        float3(0.30, 0.62, 1.00), float3(0.35, 0.90, 0.95)
    };
    float x = fract(t) * 5.0;
    int i = int(floor(x));
    float f = smoothstep(0.0, 1.0, x - float(i));
    return mix(stops[i % 5], stops[(i + 1) % 5], f);
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

fragment float4 effectFragment(VertexOut in [[stage_in]], constant EffectUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * u.size;
    float2 center = u.shapeOrigin + u.shapeSize * 0.5;
    float2 local = p - center;
    float d = roundedBox(local, u.shapeSize * 0.5, u.radius) / u.scale; // points; <0 inside
    float angle = atan2(local.y / max(u.shapeSize.y, 1.0), local.x / max(u.shapeSize.x, 1.0));
    float around = angle / (2.0 * M_PI_F) + 0.5;

    if (u.mode == 0) {
        // Flowing colour around the outline, brighter in drifting lobes.
        float flow = around + u.time * 0.12;
        float wobble = noise(float2(around * 6.0 + u.time * 0.6, u.time * 0.4));
        float3 colour = spectrum(flow + wobble * 0.18);
        float lobes = 0.55 + 0.45 * sin(around * 2.0 * M_PI_F * 2.0 - u.time * 2.2 + wobble * 2.0);
        float rim = exp(-abs(d) * 0.9);                        // crisp light on the edge
        float halo = exp(-max(d, 0.0) * 0.14) * step(0.0, d);  // wide bloom outside
        float inner = exp(-max(-d, 0.0) * 0.3) * step(d, 0.0) * 0.5;
        float a = (rim + halo * 0.75 * lobes + inner * lobes) * u.intensity;
        a *= mix(0.85, 1.0, u.dark);
        a = clamp(a, 0.0, 1.0);
        return float4(colour * a, a);
    }

    // Ripple: a ring of light leaving the outline and fading as it spreads.
    float travel = u.progress * 46.0;
    float ring = exp(-pow((d - travel) / (3.0 + u.progress * 10.0), 2.0));
    float flash = exp(-abs(d) * 0.8) * (1.0 - smoothstep(0.0, 0.45, u.progress));
    float3 colour = spectrum(around + u.progress * 0.5);
    float fade = 1.0 - smoothstep(0.35, 1.0, u.progress);
    float a = clamp((ring * 0.9 * fade + flash) * step(-1.0, d) * u.intensity, 0.0, 1.0);
    return float4(colour * a, a);
}
