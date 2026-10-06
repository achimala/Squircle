#include <metal_stdlib>
using namespace metal;

// Light for glass shapes: a ring of soft light leaving a glass outline. Every effect is drawn around a rounded rectangle
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
    int mode;           // 1 ripple
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




fragment float4 effectFragment(VertexOut in [[stage_in]], constant EffectUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * u.size;
    float2 center = u.shapeOrigin + u.shapeSize * 0.5;
    float2 local = p - center;
    float d = roundedBox(local, u.shapeSize * 0.5, u.radius) / u.scale; // points; <0 inside
    float angle = atan2(local.y / max(u.shapeSize.y, 1.0), local.x / max(u.shapeSize.x, 1.0));
    float around = angle / (2.0 * M_PI_F) + 0.5;

    // Ripple: a ring of light leaving the outline and fading as it spreads.
    float travel = u.progress * 46.0;
    float ring = exp(-pow((d - travel) / (3.0 + u.progress * 10.0), 2.0));
    float flash = exp(-abs(d) * 0.8) * (1.0 - smoothstep(0.0, 0.45, u.progress));
    // Soft white light with the faintest cool tint: glass catching light, not colour.
    float3 colour = mix(float3(1.0), float3(0.82, 0.86, 1.0), 0.35 + 0.15 * sin(around * 6.2832));
    float fade = 1.0 - smoothstep(0.35, 1.0, u.progress);
    float a = clamp((ring * 0.9 * fade + flash) * step(-1.0, d) * u.intensity, 0.0, 1.0);
    return float4(colour * a, a);
}

// Lens: two lines of text crossing a glass capsule. Near its top and bottom
// edges the glass bends what is behind it: the text is compressed toward
// the edge, drawn in toward the middle horizontally, split slightly by
// colour, and fades out where the glass curves away.

struct LensUniforms {
    float2 size;     // drawable size, pixels
    float progress;  // 0 old line centred … 1 new line centred
};

static float edgeFactor(float y) {
    // 0 in the middle of the capsule, 1 at its top or bottom edge.
    float e = 1.0 - min(y, 1.0 - y) * 2.0;
    return e * e * e;
}

static float4 lensed(texture2d<float> t, float2 uv, float travel, float strength) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);
    float e = edgeFactor(uv.y);
    float2 centred = uv - 0.5;
    float2 bent = float2(centred.x * (1.0 + 0.12 * e) , centred.y * (1.0 - 0.28 * e * strength)) + 0.5;
    bent.y += travel;
    float2 split = float2(0.0, 0.010 * e * sign(centred.y));
    float4 c = t.sample(s, bent);
    float r = t.sample(s, bent + split).r;
    float b = t.sample(s, bent - split).b;
    c.r = max(c.r, r * c.a); c.b = max(c.b, b * c.a);
    return c * (1.0 - smoothstep(0.55, 0.95, e));
}

fragment float4 lensFragment(VertexOut in [[stage_in]], constant LensUniforms &u [[buffer(0)]],
                             texture2d<float> oldLine [[texture(0)]], texture2d<float> newLine [[texture(1)]]) {
    float p = clamp(u.progress, 0.0, 1.0);
    float travel = 0.72;
    float4 leaving = lensed(oldLine, in.uv, p * travel, 1.0) * (1.0 - smoothstep(0.55, 1.0, p));
    float4 arriving = lensed(newLine, in.uv, -(1.0 - p) * travel, 1.0) * smoothstep(0.0, 0.45, p);
    return arriving + leaving * (1.0 - arriving.a);
}
