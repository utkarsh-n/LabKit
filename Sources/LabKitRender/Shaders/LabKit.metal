#include <metal_stdlib>
#include "../../LabKitShaderTypes/include/LabKitShaderTypes.h"
using namespace metal;

// Shared LabKit shaders, lifted from Gyre/Render/Holo.metal (line numbers in comments).
// App shaders that want the helpers include "LabKitShaderLib.h" (same functions, `static inline`).
#include "LabKitShaderLib.h"

// MARK: - Fullscreen (Holo.metal:183-194)

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut labFullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

/// The world-anchored sky window (Holo.metal:196-206): a fixed camera ray per pixel, rotated into
/// the world, a glow around the focus and a soft vignette.
fragment float4 labBackdropFragment(FSOut in [[stage_in]], constant LabFrameUniforms& u [[buffer(0)]]) {
    float2 px = in.position.xy;
    float f = u.camera.x;
    float3 ray = normalize(float3((px.x - u.viewport.z) / f, -(px.y - u.viewport.w) / f, -1.0));
    float3 c = labSky(labToWorld(ray, u.attitude), u.world);
    float2 rel = (px - u.viewport.zw) / max(u.misc.x, 1.0);
    c += float3(0.010, 0.030, 0.060) * exp(-dot(rel, rel) * 0.55);
    float2 q = in.uv - 0.5;
    c *= 1.0 - dot(q, q) * 0.8;
    return float4(c, 1.0);
}

// MARK: - Glowing lines (Holo.metal:584-651)

struct LineOut {
    float4 position [[position]];
    float2 px;
    float2 sa;
    float2 sb;
    float wa;
    float wb;
    float4 ca;
    float4 cb;
};

vertex LineOut labLineVertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device LabLineInstance* lines [[buffer(LabBufferInstances)]],
                             constant LabFrameUniforms& u [[buffer(LabBufferFrame)]]) {
    LabLineInstance L = lines[iid];
    // Nudge toward the eye so lines drawn on a surface aren't hidden by it.
    float3 pa = L.a.xyz + normalize(u.eye.xyz - L.a.xyz) * 0.015;
    float3 pb = L.b.xyz + normalize(u.eye.xyz - L.b.xyz) * 0.015;
    float4 ka = u.viewProj * float4(pa, 1.0);
    float4 kb = u.viewProj * float4(pb, 1.0);
    LineOut o;
    o.px = 0.0;
    o.sa = 0.0;
    o.sb = 0.0;
    o.wa = L.a.w;
    o.wb = L.b.w;
    o.ca = L.ca;
    o.cb = L.cb;
    if (ka.w < 0.01 || kb.w < 0.01) {
        o.position = float4(10.0, 10.0, 0.5, 1.0);
        return o;
    }
    float2 sa = (ka.xy / ka.w * float2(0.5, -0.5) + 0.5) * u.viewport.xy;
    float2 sb = (kb.xy / kb.w * float2(0.5, -0.5) + 0.5) * u.viewport.xy;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float wmax = max(L.a.w, L.b.w);
    float half_ = wmax * 0.5 + wmax * 2.2 + 2.0;
    float t = (vid & 1) ? 1.0 : 0.0;
    float s = (vid & 2) ? 1.0 : -1.0;
    // Polyline segments butt together without caps, so additive joints don't bead; a lone point gets a dot.
    float cap = len > 1.5 ? 0.0 : half_;
    float2 p = mix(sa, sb, t) + dir * (t * 2.0 - 1.0) * cap + nrm * s * half_;
    float z = mix(ka.z / ka.w, kb.z / kb.w, len > 1.5 ? t : 0.0);
    o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, z, 1.0);
    o.px = p;
    o.sa = sa;
    o.sb = sb;
    return o;
}

fragment float4 labLineFragment(LineOut in [[stage_in]]) {
    float2 d = in.sb - in.sa;
    float len2 = dot(d, d);
    float along = len2 > 1e-6 ? dot(in.px - in.sa, d) / len2 : 0.0;
    float t = saturate(along);
    float dist = length(in.px - (in.sa + d * (len2 > 2.25 ? along : t)));
    float w = mix(in.wa, in.wb, t) * 0.5;
    float4 c = mix(in.ca, in.cb, t);
    float core = 1.0 - smoothstep(w - 0.6, w + 0.9, dist);
    float g = w * 2.2 + 1.5;
    float glow = exp(-dist * dist / (g * g)) * 0.45;
    return float4(c.rgb * c.a * (core + glow), 0.0);
}

// MARK: - Flat quads (2D layers in scene units)

vertex LabQuadOut labQuadVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device LabQuadInstance* quads [[buffer(LabBufferInstances)]],
                                constant LabFrameUniforms& u [[buffer(LabBufferFrame)]]) {
    LabQuadInstance q = quads[iid];
    float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
    float2 lo = q.rect.xy;
    float2 hi = q.rect.zw;
    float2 centre = (lo + hi) * 0.5;
    float2 halfSize = abs(hi - lo) * 0.5;
    float2 local = (corner * 2.0 - 1.0) * halfSize;
    float s = sin(q.params.y);
    float c = cos(q.params.y);
    float2 p = centre + float2(c * local.x - s * local.y, s * local.x + c * local.y);
    LabQuadOut o;
    o.position = u.viewProj * float4(p, q.params.x, 1.0);
    o.uv = corner;
    o.local = local;
    o.halfSize = halfSize;
    o.color = q.color;
    o.params = q.params;
    return o;
}

/// A flat, anti-aliased rounded rectangle in the instance colour, premultiplied (blend `.premultiplied`).
fragment float4 labQuadFragment(LabQuadOut in [[stage_in]]) {
    float sd = labRoundedRectSDF(in.local, in.halfSize, in.params.z);
    float aa = max(fwidth(sd), 1e-6);
    float a = in.color.a * (1.0 - smoothstep(-aa, aa, sd));
    return float4(in.color.rgb * a, a);
}

// MARK: - Bloom (Holo.metal:655-676)

fragment float4 labPrefilterFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float3 c = src.sample(labLinearClamp, in.uv).rgb;
    float peak = max(c.r, max(c.g, c.b));
    return float4(c * smoothstep(0.35, 1.3, peak), 1.0);
}

fragment float4 labCopyFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return float4(src.sample(labLinearClamp, in.uv).rgb, 1.0);
}

fragment float4 labBlurFragment(FSOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                constant float2& texelStep [[buffer(0)]]) {
    float3 c = src.sample(labLinearClamp, in.uv).rgb * 0.2270270270;
    float2 o1 = texelStep * 1.3846153846;
    float2 o2 = texelStep * 3.2307692308;
    c += src.sample(labLinearClamp, in.uv + o1).rgb * 0.3162162162;
    c += src.sample(labLinearClamp, in.uv - o1).rgb * 0.3162162162;
    c += src.sample(labLinearClamp, in.uv + o2).rgb * 0.0702702703;
    c += src.sample(labLinearClamp, in.uv - o2).rgb * 0.0702702703;
    return float4(c, 1.0);
}

// MARK: - Composite (Holo.metal:680-708)

fragment float4 labCompositeFragment(FSOut in [[stage_in]],
                                     texture2d<float> scene [[texture(0)]],
                                     texture2d<float> bloomA [[texture(1)]],
                                     texture2d<float> bloomB [[texture(2)]],
                                     texture2d<float> luma [[texture(3)]],
                                     texture2d<float> chroma [[texture(4)]],
                                     constant LabFrameUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 centre = u.viewport.zw / u.viewport.xy;
    float2 off = (uv - centre) * u.post.z;
    float4 s = scene.sample(labLinearClamp, uv);
    float3 c = float3(scene.sample(labLinearClamp, uv + off).r, s.g, scene.sample(labLinearClamp, uv - off).b);
    c += bloomA.sample(labLinearClamp, uv).rgb * u.post.x;
    c += bloomB.sample(labLinearClamp, uv).rgb * u.post.x * 0.9;
    c *= 1.0 - u.post.y * (0.5 + 0.5 * sin(in.position.y * 2.0944 + u.camera.z * 4.0));
    if (u.eye.w > 0.5) {
        c += labCameraColor(uv, luma, chroma, u.camA, u.camB) * (1.0 - saturate(s.a));
    }
    float headroom = min(u.camera.w, 3.0);
    c = float3(labSoftClip(c.r, headroom), labSoftClip(c.g, headroom), labSoftClip(c.b, headroom));
    return float4(max(c, 0.0), 1.0);
}
