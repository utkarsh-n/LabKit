// LabKit MSL helpers (header-only, `static inline`), lifted from Gyre/Render/Holo.metal.
// Included by LabKit.metal and, through MTL_HEADER_SEARCH_PATHS, by app shaders.
#pragma once
#include <metal_stdlib>
#include "../../LabKitShaderTypes/include/LabKitShaderTypes.h"
using namespace metal;

constexpr sampler labLinearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler labCubeSampler(filter::linear, mip_filter::linear);
constexpr sampler labMipClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);

static inline float3 labToWorld(float3 v, float4x4 attitude) { return (attitude * float4(v, 0.0)).xyz; }

/// What `labQuadVertex` hands a fragment function. App fragments for LabKit quads declare
/// `LabQuadOut in [[stage_in]]` with this exact struct so the two libraries link.
struct LabQuadOut {
    float4 position [[position]];
    float2 uv [[user(lab_uv)]];            // 0…1 across the quad, y up
    float2 local [[user(lab_local)]];      // scene units from the quad centre (unrotated frame)
    float2 halfSize [[user(lab_half)]];    // half extents, scene units
    float4 color [[user(lab_color)]];      // LabQuadInstance.color
    float4 params [[user(lab_params)]];    // LabQuadInstance.params
};

/// Screen uv (0…1, origin top-left) of a fragment in a target the size of the drawable: use it to
/// sample `context.targets.behind` (or any full-screen texture).
static inline float2 labScreenUV(float4 fragPosition, constant LabFrameUniforms& u) {
    return fragPosition.xy / max(u.viewport.xy, float2(1.0));
}

/// Samples the mipmapped `behind` copy at a screen uv plus a refraction offset, at a mip LOD
/// (0 = sharp; Gyre's glass orb used lod = 0.4·frost + scuff·5 for frosting/turbidity).
static inline float4 labSampleBehind(texture2d<float> behind, float2 screenUV, float2 offset, float lod) {
    return behind.sample(labMipClamp, screenUV + offset, level(lod));
}

/// Rounded-rectangle signed distance (negative inside), for quads: p from the centre, b half size, r radius.
static inline float labRoundedRectSDF(float2 p, float2 b, float r) {
    r = min(r, min(b.x, b.y));
    float2 d = abs(p) - (b - r);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// Holo.metal:59-82
static inline float labHash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

static inline float labNoise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float a = labHash13(i);
    float b = labHash13(i + float3(1, 0, 0));
    float c = labHash13(i + float3(0, 1, 0));
    float d = labHash13(i + float3(1, 1, 0));
    float e = labHash13(i + float3(0, 0, 1));
    float g = labHash13(i + float3(1, 0, 1));
    float h = labHash13(i + float3(0, 1, 1));
    float k = labHash13(i + float3(1, 1, 1));
    return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y), mix(mix(e, g, f.x), mix(h, k, f.x), f.y), f.z);
}

static inline float labFbm(float3 p) {
    return 0.55 * labNoise(p) + 0.30 * labNoise(p * 2.03 + 11.7) + 0.15 * labNoise(p * 4.07 + 3.1);
}

// Holo.metal:84-87: anti-aliased grid line of given spacing; fw = fwidth(coord).
static inline float labLineMask(float coord, float spacing, float fw) {
    float d = abs(fract(coord / spacing + 0.5) - 0.5) * spacing;
    return 1.0 - smoothstep(0.0, fw * 1.2 + 1e-5, d);
}

// Holo.metal:91-123: dark sky over a darker floor, glowing horizon, 15° grid, north tick.
// world = (north azimuth, has north, —, —). Uses fwidth: call from fragment shaders only.
static inline float3 labSky(float3 d, float4 world) {
    const float twoPi = 2.0 * M_PI_F;
    float z = clamp(d.z, -1.0, 1.0);
    float lat = asin(z);
    float lon = atan2(d.y, d.x);
    float fwLat = fwidth(lat);
    float lonAlt = fract(lon / twoPi + 1.0) * twoPi;
    float fwLon = min(fwidth(lon), fwidth(lonAlt));

    float3 skyTop = float3(0.003, 0.006, 0.022);
    float3 skyHorizon = float3(0.018, 0.030, 0.075);
    float3 groundHorizon = float3(0.020, 0.012, 0.032);
    float3 groundLow = float3(0.002, 0.002, 0.005);
    float3 c = z >= 0.0 ? mix(skyHorizon, skyTop, sqrt(z)) : mix(groundHorizon, groundLow, pow(-z, 0.45));
    c += float3(0.05, 0.075, 0.16) * exp(-abs(z) * 38.0);

    float spacing = M_PI_F / 12.0;
    float poleFade = 1.0 - smoothstep(0.86, 0.97, abs(z));
    float lat15 = labLineMask(lat, spacing, fwLat);
    float lon15 = labLineMask(lon, spacing, fwLon) * poleFade;
    float lon90 = labLineMask(lon, M_PI_F * 0.5, fwLon) * poleFade;
    float3 lineColor = z >= 0.0 ? float3(0.035, 0.065, 0.15) : float3(0.07, 0.035, 0.11);
    c += lineColor * max(lat15, lon15) + lineColor * 0.25 * lon90;
    c += float3(0.10, 0.16, 0.32) * (1.0 - smoothstep(0.0, fwLat * 1.5 + 1e-5, abs(lat)));

    if (world.y > 0.5) {
        float dl = lon - world.x;
        dl -= twoPi * round(dl / twoPi);
        float north = 1.0 - smoothstep(0.0, fwLon * 1.6 + 1e-5, abs(dl));
        c += float3(0.30, 0.06, 0.10) * north * (1.0 - smoothstep(0.06, 0.3, abs(z)));
    }
    return c;
}

// Holo.metal:146-153: ARKit YCbCr planes → linear RGB (BT.601, γ 2.2).
static inline float3 labCameraColor(float2 uv, texture2d<float> luma, texture2d<float> chroma, float4 camA, float4 camB) {
    float2 img = float2(camA.x * uv.x + camA.z * uv.y + camB.x, camA.y * uv.x + camA.w * uv.y + camB.y);
    float y = luma.sample(labLinearClamp, img).r;
    float2 c = chroma.sample(labLinearClamp, img).rg - 0.5;
    float3 rgb = float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
    return pow(saturate(rgb), float3(2.2));
}

// Holo.metal:680-685: linear below 0.8, then an exponential shoulder up to the EDR headroom.
static inline float labSoftClip(float x, float headroom) {
    float k = 0.8;
    float h = max(headroom, 1.0);
    if (x <= k) return x;
    return k + (h - k) * (1.0 - exp(-(x - k) / (h - k)));
}

// Holo.metal:242-257: thin-film reflectance at 640/530/450 nm, film index 1.33.
static inline float3 labThinFilm(float thicknessNm, float cosI, float n) {
    float sinT2 = (1.0 - cosI * cosI) / (n * n);
    float cosT = sqrt(max(1.0 - sinT2, 0.0));
    float3 phase = 4.0 * M_PI_F * n * thicknessNm * cosT / float3(640.0, 530.0, 450.0);
    return 0.5 - 0.5 * cos(phase);
}
