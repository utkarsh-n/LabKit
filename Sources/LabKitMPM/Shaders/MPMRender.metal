// MPMRender.metal — LabKit's 2.5D fluid surface renderer for MPM particles (new code, not derived from PB-MPM;
// techniques after screen-space fluid rendering, van der Laan, Green and Sainz 2009, and Gyre's glass-orb refraction).
// Passes per frame (MPMSurfaceRenderer):
//   prepass (encodePrepass, over the tank's screen rectangle at 1/4–1/2 resolution, about 8 texels per cell, own textures):
//     0. flDyeUpdate (compute)              per-slot dye: horizontal bands laid down where a particle first appears
//     1. flSplatVertex / flSplatFragment   particles -> MRT  A: (t, t·diag, t·dye, t·T/1000)
//                                                           W0: t per material slot 0-3, W1: slots 4-6 + t·grain tag
//                                                           B: (t·shear glow, t·contact f, t·structure λ, t·J)
//     2. flBlurFragment x 2                separable 9-tap Gaussian (5 linear taps) on all four targets
//     3. flGradientFragment                G = (t, ∂t/∂u, ∂t/∂v) per field texel, then mipmapped (coarse body thickness)
//   shade (encodeShade, full resolution, inside the scene's second pass):
//     4. flShadeVertex / flShadeFragment   silhouette from the signed distance (t − t₀)/|∇t| (1 px anti-aliasing),
//                                          a rounded meniscus at every free edge + a pillowed body normal, refraction of
//                                          the mipmapped `behind` texture, Beer–Lambert, wrap subsurface, milky edges,
//                                          backlight transmission, Schlick Fresnel, GGX + clear coat, a studio
//                                          reflection that turns with the phone, dry/wet by jam and structure, dye,
//                                          stress light, lava blackbody glow with a cracked crust; or a diagnostic map
//     5. flDotVertex / flDotFragment       particles outside the surface as droplets of their own volume; inside it,
//                                          a speckle grain that moves with the fluid
//     6. (options) flParticleVertex / flStreakVertex: particle discs or velocity streaks over the fluid
//   hologram style (FluidRenderStyle.hologram; Toothpaste Toy, 13 October 2026) replaces 4 and 5 with
//     7. flHoloFragment                    the fluid as light: Fresnel rim, contour fringes, scanlines, stripe-dye bands
//                                          (field S), shear / jam / structure light, event flashes, echoes of the surface
//                                          from a ring of earlier thickness fields, a refracting lens
//     8. flCloudVertex / flCloudFragment   every particle a faint point flickering with its own phase (additive)
//   The splat also writes S: (t·bucket 0, t·bucket 1, t·bucket 2, t·yielded) for every style.
#include <metal_stdlib>
#include "../../LabKitMPMTypes/include/MPMRender.h"
using namespace metal;

constexpr sampler flLinearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler flMipClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);

// Renderer-private structs, mirrored in Swift (FluidLookExtGPU, FluidShadeExtGPU, FluidDyeParams); flLayoutProbe
// reports their sizes.
struct FLLookExt {
    float4 shape;    // x meniscus width (m), y bead (max sin θ), z edge translucency, w backlight transmission
    float4 wet;      // x jam matte, y structure gloss, z dry whitening, w clear coat
    float4 ink;      // rgb dye colour, a dye strength
    float4 metal;    // rgb metallic F0 tint, w unused
    float4 misc;     // x grain size (cells), y lava crust, zw unused
};
struct FLShadeExt {
    float4 glow;     // rgb stress-light colour, a amount (0 = off)
    float4 view;     // x drawable px per metre, y coarse LOD of G, z field texels per drawable px, w droplets on
    float4 env;      // xyz "up" in the screen frame (studio reflection), w unused
    float4 misc;     // x time (s), y dye strength (Tracers), z mip of G for the meniscus normals, w unused
};
struct FLDyeParams {
    float2 originCells;  // cell coordinate of the tank origin
    float dx;            // m per cell
    float period;        // m between dye bands
    float width;         // m, band width
    float time;          // s (pour bands drift with time)
    float drift;         // m/s
    uint count;          // slots to update
};

// Diagnostic value of one particle mapped to [0, 1] (FluidDiagnostic ranges).
static inline float flDiagValue(thread const PBParticle& p, constant FluidSplatUniforms& u) {
    switch (u.diagMode) {
        case FL_DIAG_SHEAR_RATE:  return saturate((log10(max(p.shearRate, 1e-3f)) + 2.0f) / 5.0f);
        case FL_DIAG_VISCOSITY:   return saturate((log10(clamp(p.viscosity, 1e-4f, 1e7f)) + 3.0f) / 9.0f);
        case FL_DIAG_STRESS:      return saturate((log10(max(p.stress, 1e-2f)) + 1.0f) / 5.0f);
        case FL_DIAG_STRUCTURE:   return saturate(p.structure);
        case FL_DIAG_JAM:         return saturate(p.contact);
        case FL_DIAG_TEMPERATURE: return saturate((p.temperature - 273.0f) / 1200.0f);
        case FL_DIAG_SPEED:       return saturate(length(p.displacement - u.gravityKick) * u.dx / u.dtSub / u.speedMax);
        default:                  return 0.0f;
    }
}
static inline float4 flTankClip(constant FluidSplatUniforms& u, float2 cells) {
    return u.tankToClip * float4((cells - u.originCells) * u.dx, 0.0f, 1.0f);
}
static inline float flHash(float x) { return fract(sin(x * 91.3458f) * 47453.5453f); }
static inline float2 flHash2(float x) { return float2(flHash(x), flHash(x + 17.17f)); }

// ------------------------------------------------------------------------------------------------
// 0. Dye: a slot whose particle tag changed holds a new particle (fill, pour, resample): give it the dye value of a
//    horizontal band pattern at its current height (pour bands also drift with time, so a pour shows its layers).
kernel void flDyeUpdate(device const PBParticle* particles [[buffer(0)]], device float2* dye [[buffer(1)]],
                        constant FLDyeParams& d [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= d.count) return;
    float tag = particles[id].tag;
    float2 s = dye[id];
    if (s.x == tag) return;
    float y = (particles[id].position.y - d.originCells.y) * d.dx;
    float phase = fract((y + d.time * d.drift) / d.period);
    float w = 0.5f * d.width / d.period;
    float v = 1.0f - smoothstep(w * 0.6f, w, abs(phase - 0.5f));
    dye[id] = float2(tag, v);
}

// ------------------------------------------------------------------------------------------------
// 1. Splat: one quad per particle slot (triangle strip, 4 vertices, instanced; disabled slots are culled)
struct FLSplatOut {
    float4 position [[position]];
    float2 local;
    float diag [[flat]];
    float dye [[flat]];
    float temperature [[flat]];
    float grainTag [[flat]];
    float glow [[flat]];
    float contact [[flat]];
    float structure [[flat]];
    float dilation [[flat]];
    uint slot [[flat]];
    float4 bucket [[flat]];       // one-hot stripe-dye bucket (xyz), yielded (w)
};
struct FLSplatTargets { half4 a [[color(0)]]; half4 w0 [[color(1)]]; half4 w1 [[color(2)]]; half4 b [[color(3)]];
                        half4 s [[color(4)]]; };

vertex FLSplatOut flSplatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                device const PBParticle* particles [[buffer(0)]],
                                constant FluidSplatUniforms& u [[buffer(1)]],
                                device const float2* dye [[buffer(2)]]) {
    PBParticle p = particles[iid];
    float2 corner = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? 1.0f : -1.0f);
    FLSplatOut o;
    // The footprint covers the particle's own area: radius ∝ √J (a stretched sheet stays smooth, a seam closes), at
    // the same peak weight, so the splat sums to thickness ≈ 1 whatever the local spacing.
    float J = clamp(p.liquidDensity, 0.8f, 2.0f);
    o.position = flTankClip(u, p.position + corner * u.radiusCells * sqrt(J));
    uint slot = (p.flags & PB_FLAG_ENABLED) ? u.materialSlot[min(p.material, uint(PB_MAX_MATERIALS - 1))] : FL_HIDDEN;
    if (slot >= FL_SLOTS) o.position = float4(2, 2, 2, 1);                 // culled: outside the clip volume
    o.local = corner;
    o.diag = flDiagValue(p, u);
    o.dye = dye[iid].y;
    o.temperature = p.temperature * 0.001f;
    o.grainTag = p.tag;
    // Stress light: log shear rate from 1 to 300 1/s.
    o.glow = saturate(log10(max(p.shearRate, 1e-3f)) / 2.47712f);
    o.contact = saturate(p.contact);
    o.structure = saturate(p.structure);
    o.dilation = clamp(p.liquidDensity, 0.0f, 4.0f);
    o.slot = min(slot, FL_SLOTS - 1);
    uint band = (p.flags >> PB_DYE_SHIFT) & PB_DYE_MASK;
    uint bucket = band == 0u ? FL_BUCKET_NONE : ((u.bandBuckets >> (2u * min(band, 7u))) & 3u);
    o.bucket = float4(bucket == 0u ? 1.0f : 0.0f, bucket == 1u ? 1.0f : 0.0f, bucket == 2u ? 1.0f : 0.0f,
                      p.viscosity < FL_UNYIELDED ? 1.0f : 0.0f);
    return o;
}

fragment FLSplatTargets flSplatFragment(FLSplatOut in [[stage_in]], constant FluidSplatUniforms& u [[buffer(0)]]) {
    float r2 = dot(in.local, in.local);
    if (r2 > 1.0f) discard_fragment();
    float t = sqrt(1.0f - r2) * u.weight;                                   // sphere profile, normalised
    FLSplatTargets o;
    o.a = half4(half(t), half(t * in.diag), half(t * in.dye), half(t * in.temperature));
    half4 w0 = half4(0), w1 = half4(0);
    if (in.slot < 4u) w0[in.slot] = half(t); else w1[in.slot - 4u] = half(t);
    w1.a = half(t * in.grainTag);
    o.w0 = w0;
    o.w1 = w1;
    o.b = half4(half(t * in.glow), half(t * in.contact), half(t * in.structure), half(t * in.dilation));
    o.s = half4(in.bucket * t);
    return o;
}

// ------------------------------------------------------------------------------------------------
// 1h. Hologram splat (FluidRenderStyle.hologram): three targets at the hologram's coarser field density (about 4 texels
//     per cell: the shade draws the crisp edge at full resolution from the signed distance, so the fields only carry
//     the shape and the per-particle state):
//       H0 = (t, t·bucket 0, t·bucket 1, t·bucket 2)       stripe-dye bands (PBParticle.flags bits 8-11)
//       H1 = (t·shear glow, t·contact f, t·structure λ, t·yielded)
//       H2 = (t per material slot 0-2, t·T/1000)
struct FLHoloSplatOut {
    float4 position [[position]];
    float2 local;
    float4 h0 [[flat]];
    float4 h1 [[flat]];
    float4 h2 [[flat]];
};
struct FLHoloTargets { half4 h0 [[color(0)]]; half4 h1 [[color(1)]]; half4 h2 [[color(2)]]; };

vertex FLHoloSplatOut flHoloSplatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        device const PBParticle* particles [[buffer(0)]],
                                        constant FluidSplatUniforms& u [[buffer(1)]]) {
    PBParticle p = particles[iid];
    float2 corner = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? 1.0f : -1.0f);
    FLHoloSplatOut o;
    float J = clamp(p.liquidDensity, 0.8f, 2.0f);
    o.position = flTankClip(u, p.position + corner * u.radiusCells * sqrt(J));
    uint slot = (p.flags & PB_FLAG_ENABLED) ? u.materialSlot[min(p.material, uint(PB_MAX_MATERIALS - 1))] : FL_HIDDEN;
    if (slot >= FL_SLOTS) o.position = float4(2, 2, 2, 1);                 // culled
    o.local = corner;
    uint band = (p.flags >> PB_DYE_SHIFT) & PB_DYE_MASK;
    uint bucket = band == 0u ? FL_BUCKET_NONE : ((u.bandBuckets >> (2u * min(band, 7u))) & 3u);
    o.h0 = float4(1.0f, bucket == 0u ? 1.0f : 0.0f, bucket == 1u ? 1.0f : 0.0f, bucket == 2u ? 1.0f : 0.0f);
    o.h1 = float4(saturate(log10(max(p.shearRate, 1e-3f)) / 2.47712f), saturate(p.contact), saturate(p.structure),
                  p.viscosity < FL_UNYIELDED ? 1.0f : 0.0f);
    uint s = min(slot, FL_HOLO_SLOTS - 1u);
    o.h2 = float4(s == 0u ? 1.0f : 0.0f, s == 1u ? 1.0f : 0.0f, s == 2u ? 1.0f : 0.0f, p.temperature * 0.001f);
    return o;
}

fragment FLHoloTargets flHoloSplatFragment(FLHoloSplatOut in [[stage_in]], constant FluidSplatUniforms& u [[buffer(0)]]) {
    float r2 = dot(in.local, in.local);
    if (r2 > 1.0f) discard_fragment();
    float t = sqrt(1.0f - r2) * u.weight;
    FLHoloTargets o;
    o.h0 = half4(in.h0 * t);
    o.h1 = half4(in.h1 * t);
    o.h2 = half4(in.h2 * t);
    return o;
}

// ------------------------------------------------------------------------------------------------
// 2. Separable blur on the four field targets (Gyre Holo.metal:665-676 weights: 9 taps via 5 linear samples)
struct FLFullscreenOut { float4 position [[position]]; float2 uv; };
vertex FLFullscreenOut flFullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FLFullscreenOut o; o.position = float4(p * 2.0f - 1.0f, 0, 1); o.uv = float2(p.x, 1.0f - p.y); return o;
}
static inline half4 flBlur9(texture2d<half> t, float2 uv, float2 o1, float2 o2) {
    const float w0 = 0.2270270270f, w1 = 0.3162162162f, w2 = 0.0702702703f;
    return half4(float4(t.sample(flLinearClamp, uv)) * w0
               + (float4(t.sample(flLinearClamp, uv + o1)) + float4(t.sample(flLinearClamp, uv - o1))) * w1
               + (float4(t.sample(flLinearClamp, uv + o2)) + float4(t.sample(flLinearClamp, uv - o2))) * w2);
}
fragment FLSplatTargets flBlurFragment(FLFullscreenOut in [[stage_in]],
                                       texture2d<half> srcA [[texture(0)]], texture2d<half> srcW0 [[texture(1)]],
                                       texture2d<half> srcW1 [[texture(2)]], texture2d<half> srcB [[texture(3)]],
                                       texture2d<half> srcS [[texture(4)]],
                                       constant float2& texelStep [[buffer(0)]]) {
    float2 o1 = texelStep * 1.3846153846f, o2 = texelStep * 3.2307692308f;
    FLSplatTargets o;
    o.a = flBlur9(srcA, in.uv, o1, o2);
    o.w0 = flBlur9(srcW0, in.uv, o1, o2);
    o.w1 = flBlur9(srcW1, in.uv, o1, o2);
    o.b = flBlur9(srcB, in.uv, o1, o2);
    o.s = flBlur9(srcS, in.uv, o1, o2);
    return o;
}
// The hologram's three targets.
fragment FLHoloTargets flHoloBlurFragment(FLFullscreenOut in [[stage_in]],
                                          texture2d<half> src0 [[texture(0)]], texture2d<half> src1 [[texture(1)]],
                                          texture2d<half> src2 [[texture(2)]], constant float2& texelStep [[buffer(0)]]) {
    float2 o1 = texelStep * 1.3846153846f, o2 = texelStep * 3.2307692308f;
    FLHoloTargets o;
    o.h0 = flBlur9(src0, in.uv, o1, o2);
    o.h1 = flBlur9(src1, in.uv, o1, o2);
    o.h2 = flBlur9(src2, in.uv, o1, o2);
    return o;
}

// ------------------------------------------------------------------------------------------------
// 3. Thickness and its gradient per field texel (central differences of the blurred field; v points down)
fragment half4 flGradientFragment(FLFullscreenOut in [[stage_in]], texture2d<half> A [[texture(0)]]) {
    int2 q = int2(in.position.xy);
    int2 hi = int2(A.get_width() - 1, A.get_height() - 1);
    float c = float(A.read(uint2(q)).r);
    float l = float(A.read(uint2(clamp(q - int2(1, 0), int2(0), hi))).r);
    float r = float(A.read(uint2(clamp(q + int2(1, 0), int2(0), hi))).r);
    float u = float(A.read(uint2(clamp(q - int2(0, 1), int2(0), hi))).r);
    float d = float(A.read(uint2(clamp(q + int2(0, 1), int2(0), hi))).r);
    return half4(half(c), half(0.5f * (r - l)), half(0.5f * (d - u)), 0.0h);
}

// ------------------------------------------------------------------------------------------------
// 4. Shade
struct FLShadeOut { float4 position [[position]]; float2 tank; };

vertex FLShadeOut flShadeVertex(uint vid [[vertex_id]], constant FluidShadeUniforms& u [[buffer(0)]]) {
    float2 corner = float2((vid & 1) ? 1.0f : 0.0f, (vid & 2) ? 1.0f : 0.0f);
    FLShadeOut o;
    o.tank = corner * u.tankSize;
    o.position = u.tankToClip * float4(o.tank, 0.0f, 1.0f);
    return o;
}

struct FLLook { float4 albedo, absorption, scatter, surface, emission, extra, texture; float4 shape, wet, ink, metal, misc; };
static inline FLLook flBlendLooks(constant FluidLookGPU* looks, constant FLLookExt* ext, float4 w0, float3 w1) {
    FLLook L;
    L.albedo = 0; L.absorption = 0; L.scatter = 0; L.surface = 0; L.emission = 0; L.extra = 0; L.texture = 0;
    L.shape = 0; L.wet = 0; L.ink = 0; L.metal = 0; L.misc = 0;
    for (uint i = 0; i < FL_SLOTS; ++i) {
        float w = i < 4u ? w0[i] : w1[i - 4u];
        if (w <= 0.0f) continue;
        L.albedo += w * looks[i].albedo;       L.absorption += w * looks[i].absorption;
        L.scatter += w * looks[i].scatter;     L.surface += w * looks[i].surface;
        L.emission += w * looks[i].emission;   L.extra += w * looks[i].extra;
        L.texture += w * looks[i].texture;
        L.shape += w * ext[i].shape;           L.wet += w * ext[i].wet;
        L.ink += w * ext[i].ink;               L.metal += w * ext[i].metal;
        L.misc += w * ext[i].misc;
    }
    return L;
}
// GGX / Trowbridge-Reitz with Smith-Schlick visibility, Schlick Fresnel (Karis 2013 notation)
static inline float3 flGGX(float3 n, float3 v, float3 l, float rough, float3 F0, float intensity) {
    float3 h = normalize(l + v);
    float NoL = saturate(dot(n, l)), NoV = max(dot(n, v), 1e-3f), NoH = saturate(dot(n, h)), VoH = saturate(dot(v, h));
    float a = max(rough * rough, 2e-3f), a2 = a * a;
    float d = NoH * NoH * (a2 - 1.0f) + 1.0f;
    float D = a2 / (M_PI_F * d * d);
    float k = (rough + 1.0f) * (rough + 1.0f) / 8.0f;
    float Vis = 1.0f / ((NoL * (1.0f - k) + k) * (NoV * (1.0f - k) + k));
    float3 F = F0 + (1.0f - F0) * pow(1.0f - VoH, 5.0f);
    return D * Vis * 0.25f * F * NoL * intensity;
}
// Blackbody colour (Wien's approximation of Planck's law, within 10⁻⁵ of it below 2000 K at these wavelengths, sampled at
// 610, 550 and 465 nm, normalised to red) and a compressed radiance that is 1
// at 1400 K: x ∝ exp(−c₂/(λT)) at 610 nm, raised to 0.35 so a crust at 900 K is a dull red ember, not black.
static inline float3 flBlackbody(float T) {
    T = max(T, 500.0f);
    const float c2 = 1.4388e-2f;
    float3 lam = float3(610e-9f, 550e-9f, 465e-9f);
    float3 e = exp(-(c2 / (lam * T)) + c2 / (lam.x * T));
    float3 rgb = e * pow(lam.x / lam, float3(5.0f));
    return rgb / max(rgb.x, 1e-6f);
}
static inline float flGlowRadiance(float T) {
    const float k = 1.4388e-2f / (610e-9f * 1400.0f) * 0.35f;              // 5.9
    return exp(k * (1.0f - 1400.0f / max(T, 500.0f)));
}
// A soft studio around the tank: a bright soft box overhead, a warm low side light, a dark floor; `up` is the world's
// up in the screen frame, so the reflection turns as the phone tilts.
static inline float3 flStudioEnv(float3 r, float3 up) {
    float y = dot(r, up);
    float3 side = normalize(cross(up, float3(0, 0, 1)) + float3(1e-4f, 0, 0));
    float x = dot(r, side);
    float3 c = mix(float3(0.010f, 0.011f, 0.016f), float3(0.06f, 0.065f, 0.085f), smoothstep(-0.3f, 0.4f, y));
    c += float3(0.18f, 0.20f, 0.24f) * exp(-y * y * 140.0f);                                  // horizon line
    c += float3(1.0f, 1.0f, 1.0f) * smoothstep(0.88f, 0.97f, y) * (1.0f - smoothstep(0.22f, 0.38f, abs(x)));   // soft box
    c += float3(0.45f, 0.34f, 0.24f) * smoothstep(0.80f, 0.95f, x) * (1.0f - smoothstep(0.1f, 0.45f, abs(y)));
    return c;
}

fragment float4 flShadeFragment(FLShadeOut in [[stage_in]],
                                texture2d<half> fieldA [[texture(0)]],
                                texture2d<half> fieldW0 [[texture(1)]],
                                texture2d<half> fieldW1 [[texture(2)]],
                                texture2d<half> behind [[texture(3)]],        // mipmapped copy of what lies behind
                                texture2d<half> lut [[texture(4)]],           // 256 x FL_LUT_ROWS colour maps (sRGB)
                                texture2d<half> fieldB [[texture(5)]],
                                texture2d<half> fieldG [[texture(6)]],        // (t, ∂t/∂u, ∂t/∂v), mipmapped
                                constant FluidShadeUniforms& u [[buffer(0)]],
                                constant FluidLookGPU* looks [[buffer(1)]],
                                constant FLLookExt* ext [[buffer(2)]],
                                constant FLShadeExt& x [[buffer(3)]]) {
    float2 px = in.position.xy;
    float2 uv = (px - u.fieldRect.xy) / u.fieldRect.zw;                     // field textures
    float2 suv = px / u.drawableSize;                                         // behind texture (whole drawable)
    // Tank walls: the splats of particles touching a wall lose the half of their support beyond it, so the thickness
    // falls toward the glass. Compensate within ~2 cells of a wall and drop the gradient's component across it, so the
    // fluid meets the walls flat instead of with a meniscus (wallW = 0 at a wall, 1 two cells inside).
    float2 wallDist = float2(min(in.tank.x, u.tankSize.x - in.tank.x), min(in.tank.y, u.tankSize.y - in.tank.y));
    float2 wallW = saturate(wallDist / (2.0f * u.dx));
    float wallGain = 1.0f / ((0.5f + 0.5f * wallW.x) * (0.5f + 0.5f * wallW.y));
    float4 G = float4(fieldG.sample(flLinearClamp, uv, level(0.0f)));
    float h = G.r * wallGain;
    float2 gpx = G.gb * wallGain * wallW * x.view.z;                         // ∂t per drawable pixel (v down)
    float glen = length(gpx);
    // Signed distance to the iso-surface in pixels (+ inside) and a 1 px anti-aliased silhouette.
    float sd = (h - u.threshold) / max(glen, 1e-5f);
    float ramp = max(0.75f, u.softness / max(glen, 1e-5f));
    float cover = saturate(sd / (2.0f * ramp) + 0.5f);
    if (cover <= 0.0f) discard_fragment();
    sd = max(sd, 0.0f);

    float4 A = float4(fieldA.sample(flLinearClamp, uv)) * wallGain;          // ratios (diag, dye, T) are unchanged
    float4 B = float4(fieldB.sample(flLinearClamp, uv)) * wallGain;
    float4 W0 = float4(fieldW0.sample(flLinearClamp, uv));
    float4 W1 = float4(fieldW1.sample(flLinearClamp, uv));
    float wsum = max(W0.x + W0.y + W0.z + W0.w + W1.x + W1.y + W1.z, 1e-4f);
    FLLook L = flBlendLooks(looks, ext, W0 / wsum, W1.xyz / wsum);
    float hA = max(A.r, 1e-4f);

    // Body thickness at a coarse scale (a few millimetres): thin films and edges are shallower than the bulk.
    float4 Gc = float4(fieldG.sample(flLinearClamp, uv, level(x.view.y)));
    float tc = Gc.r * wallGain;
    float bodyThick = smoothstep(u.threshold, 0.95f, tc);
    float bodySlope = 6.0f * saturate((tc - u.threshold) / (0.95f - u.threshold)) * (1.0f - saturate((tc - u.threshold) / (0.95f - u.threshold)))
                    / (0.95f - u.threshold);                                  // d bodyThick / dt: 0 in the bulk
    float pxPerMm = x.view.x * 1e-3f;
    float sdMm = sd / max(pxPerMm, 1e-3f);

    // Normals: a rounded meniscus of width `shape.x` at every free edge (sin θ falls linearly from `bead` at the
    // silhouette to 0) plus a gentle pillow from the coarse thickness gradient (normalScale); flat elsewhere. The
    // meniscus uses a smoother copy of the field (mip `misc.z`, about 0.6 cell), and only where the
    // thickness is still near the iso level, so particle-scale bumps inside the body never catch the light.
    float rimPx = max(L.shape.x * x.view.x, 1.5f);
    float4 Gn = float4(fieldG.sample(flLinearClamp, uv, level(x.misc.z)));
    float2 gn = Gn.gb * wallGain * wallW * x.view.z;
    float gnl = length(gn);
    float sdN = max((Gn.r * wallGain - u.threshold) / max(gnl, 1e-5f), 0.0f);
    // (The cut-off uses the coarse thickness: an iso-line of the fine field would trace the particle rows as scallops.)
    float edge = saturate(1.0f - sdN / rimPx) * (1.0f - smoothstep(0.80f, 0.98f, tc));
    float2 outward = gnl > 1e-6f ? float2(-gn.x, gn.y) / gnl : (glen > 1e-6f ? float2(-gpx.x, gpx.y) / glen : float2(0.0f));
    float s = L.shape.y * edge * edge * min(1.0f, 0.6f + 0.4f * u.depth);   // eased: no visible inner rim of the bead
    // The pillow's gradient comes from central differences of the coarse thickness itself (the mip-averaged gradient
    // keeps particle-scale noise that streaks the highlights).
    float2 pillow = 0.0f;
    if (L.extra.z > 0.0f && bodySlope > 0.0f) {
        float stepT = exp2(x.view.y);
        float2 du = float2(u.texel.x * stepT, 0.0f), dv = float2(0.0f, u.texel.y * stepT);
        float tl = float(fieldG.sample(flLinearClamp, uv - du, level(x.view.y)).r);
        float tr = float(fieldG.sample(flLinearClamp, uv + du, level(x.view.y)).r);
        float tu = float(fieldG.sample(flLinearClamp, uv - dv, level(x.view.y)).r);
        float td = float(fieldG.sample(flLinearClamp, uv + dv, level(x.view.y)).r);
        float2 gc = float2(tr - tl, td - tu) * 0.5f / stepT;                    // per level-0 texel, v down
        pillow = float2(-gc.x, gc.y) * wallGain * wallW * bodySlope * (x.view.z * pxPerMm) * L.extra.z * 0.12f * u.depth;
    }
    float pl = length(pillow);
    if (pl > 0.7f) pillow *= 0.7f / pl;
    float3 n = normalize(float3(outward * s + pillow, sqrt(max(1.0f - s * s, 0.03f))));
    float3 v = float3(0, 0, 1);
    float NoV = saturate(n.z);

    // Per-particle state: jammed contact → dry and matte; broken structure → wet and glossy; dilation → whiter.
    float jam = saturate(B.y / hA), lam = saturate(B.z / hA), J = B.w / hA;
    float dry = L.wet.x * smoothstep(0.45f, 0.9f, jam);
    float wet = L.wet.y * (1.0f - lam);
    float rough = clamp(L.surface.y * (1.0f - 0.6f * wet) + dry * max(0.75f - L.surface.y, 0.0f), 0.03f, 1.0f);
    float specK = L.texture.z * (1.0f - 0.7f * dry) * (1.0f + 0.4f * wet);

    float ior = max(L.surface.x, 1.0f);
    float f0s = (ior - 1.0f) / (ior + 1.0f); f0s *= f0s;
    float metal = saturate(L.surface.z);
    float3 F0 = mix(float3(f0s), L.metal.rgb, metal);
    float3 F = F0 + (1.0f - F0) * pow(1.0f - NoV, 5.0f);

    // Light from above: how much fluid lies just above this point along world up (four taps 2 mm apart). 0 at the free
    // surface … 1 from about 8 mm down. Milky bodies are brightest just under the surface where the light enters and
    // settle darker below; clear ones deepen in colour. Side-wall loss is compensated as for the surface itself.
    float2 upS = length(x.env.xy) > 1e-3f ? normalize(x.env.xy) : float2(0.0f, 1.0f);
    float2 stepUV = float2(upS.x, -upS.y) * (2.0e-3f * x.view.x * x.view.z) * u.texel;
    float wallX = 1.0f / (0.5f + 0.5f * wallW.x);
    float occ = 0.0f;
    for (int k = 1; k <= 4; ++k) {
        float tk = float(fieldG.sample(flLinearClamp, uv + stepUV * float(k), level(x.view.y)).r) * wallX;
        occ += smoothstep(u.threshold - 0.1f, u.threshold + 0.3f, tk);
    }
    occ *= 0.25f;

    // Optical depth: the gap is the same everywhere, so the body has one colour; only the meniscus wedge is shallower.
    float thin = saturate(0.35f + 0.65f * sd / rimPx);
    float depth = (0.85f + 0.15f * bodyThick) * thin * u.depth;
    float tau = depth * L.absorption.a;
    float3 T = exp(-L.absorption.rgb * tau);

    // Refraction: only curved surface bends the view (the face is flat against the glass); turbidity = behind's mip.
    float2 suvR = suv + float2(-n.x, n.y) * L.surface.w;
    float lod = clamp(L.extra.x + 2.0f * dry, 0.0f, u.behindLod);
    float3 bgR = float3(behind.sample(flMipClamp, suvR, level(lod)).rgb);

    float3 key = normalize(u.keyLight.xyz), fill = normalize(u.fillLight.xyz);
    float wrap = L.scatter.a;
    float dKey = saturate((dot(n, key) + wrap) / (1.0f + wrap));
    float dFill = saturate((dot(n, fill) + wrap) / (1.0f + wrap));
    // Normalised so a flat, face-on surface under the default lights gets ≈ 0.75: a white body lands near 0.6, below
    // the 0.8 soft-clip knee, and only highlights and glow reach EDR (mpm-metal.md §14.4).
    float lightAmt = 0.46f * (0.18f + dKey * u.keyLight.w + dFill * u.fillLight.w);
    float vol = mix(1.16f, 0.80f, occ * sqrt(occ));                                 // light enters through the free surface
    float3 sss = 0.5f * L.scatter.rgb * (1.0f - exp(-tau)) * (0.35f + 0.65f * dKey);
    float edgeGlow = L.shape.z * exp(-sdMm / 0.9f) * (0.4f + 0.6f * dKey);
    // Backlight: the frosted back wall is lit from behind; a clear body shows that light tinted by Beer–Lambert over
    // the gap (`transmission` sets how much of it reaches the eye). It is the refracted wall itself, brightened, so
    // the grid bends at the meniscus and a prop behind the fluid shadows it; it deepens a little below the surface.
    float back = L.shape.w * 9.0f * min(dot(bgR, float3(0.2126f, 0.7152f, 0.0722f)), 0.065f);
    float3 Tb = exp(-L.absorption.rgb * tau * (0.7f + 0.6f * occ));

    float3 body;
    if (u.diagnostic != FL_DIAG_NONE) {
        float d = saturate(A.g / hA);
        float3 cm = float3(lut.sample(flLinearClamp, float2(d, (float(u.colormap) + 0.5f) / u.lutRows)).rgb);
        body = cm * (0.55f + 0.45f * dKey);
    } else {
        float3 albedo = L.albedo.rgb;
        float dilated = smoothstep(1.02f, 1.2f, J);
        albedo = mix(albedo, min(albedo * 1.15f + 0.06f, float3(0.88f)), saturate(L.wet.z * dry * (0.4f + 0.6f * dilated)));
        albedo *= 1.0f - 0.22f * wet;                                         // wet surfaces read darker and richer
        float3 clear = bgR * T + back * Tb + sss;                             // translucent path
        float3 opaque = albedo * lightAmt * vol + sss * 0.25f + L.scatter.rgb * edgeGlow * 0.5f + back * Tb * 0.3f;
        body = mix(clear, opaque, saturate(L.albedo.a));
        // Dye: crisp lines where a band is intact, a faint wash where the flow has mixed it.
        float dye = saturate(A.b / hA);
        float ink = (smoothstep(0.26f, 0.42f, dye) * 0.8f + 0.35f * dye) * x.misc.y * L.ink.a;
        float3 inkC = mix(L.ink.rgb * (0.30f + 0.7f * lightAmt), L.ink.rgb * (0.4f * back + 0.08f), 1.0f - saturate(L.albedo.a));
        body = mix(body, inkC, saturate(ink));
    }

    float3 r = reflect(-v, n);
    float3 envUp = normalize(x.env.xyz + float3(0.0f, 0.6f, 0.0f));
    float3 env = flStudioEnv(r, envUp) * F * (1.0f - rough * 0.75f) * specK;
    float3 spec = min((flGGX(n, v, key, rough, F0, u.keyLight.w * 3.0f)
                     + flGGX(n, v, fill, rough, F0, u.fillLight.w * 3.0f)) * specK, float3(2.5f));   // no fireflies
    float cc = L.wet.w * (1.0f - dry);
    if (cc > 0.0f) {
        const float3 F0c = float3(0.04f);
        float3 Fc = F0c + (1.0f - F0c) * pow(1.0f - NoV, 5.0f);
        spec += cc * min(flGGX(n, v, key, 0.07f, F0c, u.keyLight.w * 3.0f), float3(2.5f));
        env += cc * flStudioEnv(r, envUp) * Fc * 0.6f;
    }
    float2 nk = length(key.xy) > 1e-3f ? normalize(key.xy) : float2(0, 1);
    float rim = L.extra.w * pow(1.0f - NoV, 3.0f) * (0.3f + 0.7f * saturate(dot(outward, nk) * 0.5f + 0.5f)) * edge;

    float3 c = body * (1.0f - F * (1.0f - metal)) * (1.0f - 0.85f * metal) + env + spec + rim;
    // Clear fluids: seen from just below, the free surface is a mirror (total internal reflection), a thin bright
    // line along every upward-facing edge.
    float mirror = (1.0f - saturate(L.albedo.a)) * edge * smoothstep(0.15f, 0.75f, dot(outward, upS));
    c += mirror * mirror * float3(0.30f, 0.33f, 0.36f) * specK;
    if (u.diagnostic == FL_DIAG_NONE) {
        if (L.emission.a > 0.0f && u.glow > 0.0f) {
            // Lava: dark basalt plates over glowing seams. The plates are an advected noise (the splat average of the
            // particles' random tags, ≈ 0.5 ± 0.07), so they drift and tear with the flow; the hotter the rock, the
            // wider the seams (at 1480 K it is all molten, at 1400 K about half crust, below ~1300 K a crust with
            // thin red cracks, below the onset dark rock).
            float Tk = A.a / hA * 1000.0f;
            float onset = max(L.extra.y, 1.0f);
            float molten = smoothstep(onset + 430.0f, onset + 580.0f, Tk);      // ≈ 0.5 at 1400 K, 1 by 1480 K
            float tagN = W1.a / max(G.r, 1e-4f) - 0.5f;
            float seamW = 0.012f + 0.16f * molten * molten;
            float across = abs(tagN) / seamW;                                    // 0 at a crack's centre … 1 at a plate
            float hot = 1.0f - smoothstep(0.15f, 1.0f, across);                 // brightest along the crack's middle
            float plate = L.misc.y * smoothstep(0.75f, 1.2f, across);
            float Tseam = Tk + 40.0f * hot - 140.0f * (1.0f - hot);
            float Tplate = Tk - 200.0f;
            float gSeam = flGlowRadiance(Tseam) * (0.35f + 0.65f * hot);
            float gPlate = flGlowRadiance(Tplate) * 0.5f * (1.0f - smoothstep(0.9f, 2.4f, across));   // red-hot plate rims
            float3 glowC = mix(flBlackbody(Tseam) * gSeam, flBlackbody(Tplate) * gPlate, plate);
            float rock = smoothstep(onset + 40.0f, onset - 120.0f, Tk);          // cold rock: no glow at all
            c = c * (0.25f + 0.75f * plate) + glowC * L.emission.rgb * L.emission.a * u.glow * (1.0f - rock);
        }
        if (x.glow.a > 0.0f) {
            // Stress light: shear rate (log, 1–300 1/s) tints the body toward the light's colour and makes it glow,
            // so it reads on white oobleck as well as on black MR fluid.
            float sg = saturate(B.x / hA);
            float e = x.glow.a * smoothstep(0.2f, 1.0f, sg);
            c = c * (1.0f - 0.45f * e) + x.glow.rgb * e * 0.95f;
        }
    }
    return float4(c * cover, cover);                                          // premultiplied alpha
}

// ------------------------------------------------------------------------------------------------
// 5. Droplets and grain: particles the surface does not cover are drawn as small spheres of their own volume (spray,
//    oobleck fragments, never foam); particles inside it carry a few speckle grains that move with the flow.
struct FLDotOut {
    float4 position [[position]];
    float2 local;                 // cells from the particle centre (grain) or −1…1 across the droplet
    float3 colour [[flat]];
    float alpha [[flat]];
    float mode [[flat]];          // 0 droplet, 1 grain
    float seed [[flat]];
    float size [[flat]];          // grain radius, cells
    float opacity [[flat]];
    float2 tank;                  // tank metres (wall compensation of the coverage test)
};

static inline float flCoverAt(texture2d<half> G, constant FluidShadeUniforms& sh, float2 pxp) {
    float2 uv = (pxp - sh.fieldRect.xy) / sh.fieldRect.zw;
    return float(G.sample(flLinearClamp, uv, level(0.0f)).r);
}

vertex FLDotOut flDotVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            device const PBParticle* particles [[buffer(0)]],
                            constant FluidSplatUniforms& su [[buffer(1)]],
                            constant FluidShadeUniforms& sh [[buffer(2)]],
                            constant FluidLookGPU* looks [[buffer(3)]],
                            constant FLLookExt* ext [[buffer(4)]],
                            constant FLShadeExt& x [[buffer(5)]],
                            texture2d<half> fieldG [[texture(0)]]) {
    PBParticle p = particles[iid];
    float2 corner = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? 1.0f : -1.0f);
    FLDotOut o;
    o.local = corner; o.colour = 0; o.alpha = 0; o.mode = 0; o.seed = p.tag; o.size = 0; o.opacity = 1;
    o.position = float4(2, 2, 2, 1); o.tank = 0;
    uint slot = (p.flags & PB_FLAG_ENABLED) ? su.materialSlot[min(p.material, uint(PB_MAX_MATERIALS - 1))] : FL_HIDDEN;
    if (slot >= FL_SLOTS) return o;
    float4 clip = flTankClip(su, p.position);
    float2 ndc = clip.xy / clip.w;
    float2 pxp = (ndc * float2(0.5f, -0.5f) + 0.5f) * sh.drawableSize;
    float2 m = (p.position - su.originCells) * su.dx;                        // tank metres
    float2 wallW = saturate(float2(min(m.x, sh.tankSize.x - m.x), min(m.y, sh.tankSize.y - m.y)) / (2.0f * su.dx));
    float t = flCoverAt(fieldG, sh, pxp) / ((0.5f + 0.5f * wallW.x) * (0.5f + 0.5f * wallW.y));
    float cellPx = x.view.x * su.dx;
    FluidLookGPU L = looks[slot];
    FLLookExt E = ext[slot];
    float radiusPx;
    if (t >= 0.3f) {                                                          // inside or at the surface: grain only
        if (t < sh.threshold) return o;
        float amp = L.texture.x * sh.grain;
        if (amp < 0.01f || cellPx < 3.0f) return o;
        o.mode = 1; o.alpha = saturate(amp) * 0.75f; o.size = E.misc.x;
        o.colour = min(L.albedo.rgb * 1.7f + 0.08f, float3(0.9f));
        o.local = corner * 0.55f;                                             // cells
        radiusPx = 0.55f * cellPx;
    } else {                                                                  // outside it: a droplet
        if (x.view.w < 0.5f) return o;
        o.mode = 0;
        radiusPx = max(0.30f * cellPx, 1.2f);                                 // disc of the particle's own area
        float3 key = normalize(sh.keyLight.xyz);
        float lightAmt = 0.55f * (0.18f + saturate(key.z) * sh.keyLight.w + 0.6f * sh.fillLight.w);
        float3 opaque = L.albedo.rgb * lightAmt + 0.3f * L.scatter.rgb;
        float3 clearC = L.scatter.rgb * 0.5f + float3(0.02f) + E.shape.w * 0.2f * exp(-L.absorption.rgb * 0.3f);
        o.colour = mix(clearC, opaque, saturate(L.albedo.a));
        o.opacity = mix(0.35f, 1.0f, saturate(L.albedo.a)) * (1.0f - smoothstep(0.22f, 0.3f, t));
        if (sh.diagnostic != FL_DIAG_NONE) o.colour = float3(0.6f);
        if (L.emission.a > 0.0f) {
            float T = p.temperature;
            o.colour += flBlackbody(T) * flGlowRadiance(T) * L.emission.a * sh.glow * 0.8f;
        }
        o.alpha = 1;
    }
    clip.xy += corner * radiusPx * 2.0f / sh.drawableSize * clip.w;
    o.position = clip;
    o.tank = m + corner * radiusPx / x.view.x;
    return o;
}

fragment float4 flDotFragment(FLDotOut in [[stage_in]],
                              constant FluidShadeUniforms& sh [[buffer(0)]],
                              texture2d<half> fieldG [[texture(0)]]) {
    if (in.mode < 0.5f) {                                                     // droplet: a tiny lit sphere
        float r2 = dot(in.local, in.local);
        if (r2 > 1.0f) discard_fragment();
        float aa = max(fwidth(r2), 1e-3f);
        float a = (1.0f - smoothstep(1.0f - aa, 1.0f, r2)) * in.opacity;
        float3 n = float3(in.local.x, in.local.y, sqrt(max(1.0f - r2, 0.0f)));
        float3 key = normalize(sh.keyLight.xyz);
        float3 hv = normalize(key + float3(0, 0, 1));
        float spec = pow(saturate(dot(n, hv)), 40.0f) * 1.2f * sh.keyLight.w;
        float rim = pow(1.0f - n.z, 3.0f) * 0.25f;
        float3 c = in.colour * (0.55f + 0.45f * saturate(dot(n, key))) + spec + rim;
        return float4(c * a + (spec + rim) * (1.0f - in.opacity) * (1.0f - smoothstep(1.0f - aa, 1.0f, r2)), a);
    }
    // Grain: three speckles per particle at hashed offsets; light or dark; clipped to the surface.
    float2 wallW = saturate(float2(min(in.tank.x, sh.tankSize.x - in.tank.x), min(in.tank.y, sh.tankSize.y - in.tank.y))
                            / (2.0f * sh.dx));
    float t = flCoverAt(fieldG, sh, in.position.xy) / ((0.5f + 0.5f * wallW.x) * (0.5f + 0.5f * wallW.y));
    if (t < sh.threshold) discard_fragment();
    float best = 0.0f, tone = 0.0f;
    for (int k = 0; k < 3; ++k) {
        float sk = in.seed * 13.7f + float(k) * 3.1f;
        float2 c = (flHash2(sk) - 0.5f) * 0.6f;
        float r = in.size * (0.55f + 0.7f * flHash(sk + 5.3f));
        float d = length(in.local - c);
        float aa = max(fwidth(d), 1e-4f);
        float m = 1.0f - smoothstep(r - aa, r + aa, d);
        if (m > best) { best = m; tone = flHash(sk + 9.1f); }
    }
    if (best <= 0.0f) discard_fragment();
    float a = best * in.alpha * (0.35f + 0.65f * abs(tone - 0.5f) * 2.0f);
    float3 c = tone > 0.5f ? in.colour : float3(0.0f);                        // light or dark grains
    return float4(c * a, a);
}

// ------------------------------------------------------------------------------------------------
// 6. Debug overlays: particle discs and velocity streaks (alpha blended over the shaded fluid)
struct FLDebugOut { float4 position [[position]]; float2 local; float3 colour; };

static inline float3 flLutColour(texture2d<half> lut, uint row, float t) {
    return float3(lut.sample(flLinearClamp, float2(saturate(t), (float(row) + 0.5f) / float(lut.get_height()))).rgb);
}

vertex FLDebugOut flParticleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   device const PBParticle* particles [[buffer(0)]],
                                   constant FluidSplatUniforms& u [[buffer(1)]],
                                   texture2d<half> lut [[texture(0)]]) {
    PBParticle p = particles[iid];
    float2 corner = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? 1.0f : -1.0f);
    float4 clip = flTankClip(u, p.position);
    clip.xy += corner * u.pointRadiusPx * 2.0f / u.viewportPx * clip.w;
    bool shown = (p.flags & PB_FLAG_ENABLED) && u.materialSlot[min(p.material, uint(PB_MAX_MATERIALS - 1))] != FL_HIDDEN;
    if (!shown) clip = float4(2, 2, 2, 1);
    FLDebugOut o; o.position = clip; o.local = corner;
    o.colour = flLutColour(lut, u.colormap, u.diagMode == FL_DIAG_NONE ? 0.5f + 0.4f * p.tag : flDiagValue(p, u));
    return o;
}
fragment float4 flParticleFragment(FLDebugOut in [[stage_in]]) {
    float r2 = dot(in.local, in.local);
    if (r2 > 1.0f) discard_fragment();
    float a = 1.0f - smoothstep(0.7f, 1.0f, r2);
    return float4(in.colour * a, a);
}

// Streak from x to x - v * streakSeconds, 1.5 px wide, coloured by speed
vertex FLDebugOut flStreakVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 device const PBParticle* particles [[buffer(0)]],
                                 constant FluidSplatUniforms& u [[buffer(1)]],
                                 texture2d<half> lut [[texture(0)]]) {
    PBParticle p = particles[iid];
    float2 vel = (p.displacement - u.gravityKick) / u.dtSub;                  // cells per second
    float4 ca = flTankClip(u, p.position), cb = flTankClip(u, p.position - vel * u.streakSeconds);
    float2 dpx = (ca.xy / ca.w - cb.xy / cb.w) * u.viewportPx * 0.5f;
    float2 side = normalize(float2(-dpx.y, dpx.x) + 1e-6f) * 1.5f * 2.0f / u.viewportPx;
    float4 end = (vid & 2) ? cb : ca;
    float s = (vid & 1) ? 1.0f : -1.0f;
    bool shown = (p.flags & PB_FLAG_ENABLED) && u.materialSlot[min(p.material, uint(PB_MAX_MATERIALS - 1))] != FL_HIDDEN;
    FLDebugOut o;
    o.position = shown ? float4(end.xy + side * s * end.w, end.zw) : float4(2, 2, 2, 1);
    o.local = float2(s, (vid & 2) ? 1.0f : 0.0f);
    o.colour = flLutColour(lut, u.colormap, saturate(length(vel) * u.dx / u.speedMax));
    return o;
}
fragment float4 flStreakFragment(FLDebugOut in [[stage_in]]) {
    float a = (1.0f - abs(in.local.x)) * (1.0f - 0.7f * in.local.y);
    return float4(in.colour * a, a);
}

// ------------------------------------------------------------------------------------------------
// 7. Hologram shade (FluidRenderStyle.hologram). The paste as projected light: a translucent body brighter toward its
//    free edges (a longer path through the shell), a crisp Fresnel rim lit from the key side, thin-film contour fringes
//    whose hue drifts along the diagonal and turns with the tilt, scanlines in the projector's frame, the stripe dye's
//    colour bands (field S), cyan where it flows, amber where it jams or an event flashes, violet structure, field lines
//    for a magnetic look, a temperature glow for lava, short echoes of a fast-moving surface (earlier thickness fields)
//    and the lens (Metro Station spec §14 bounded refraction plus a magnifier; colour split only at diagonal edges).

static inline float flQuintic(float t) { t = saturate(t); return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }

// Thin-film palette: four colours around the hue circle, blended smoothly (phase in turns).
static inline float3 flIris(float phase, constant FluidHoloUniforms& h) {
    float q = fract(phase) * 4.0f;
    float k = floor(q);
    float f = smoothstep(0.0f, 1.0f, q - k);
    int i = int(k);
    float3 c0 = i == 0 ? h.iris0.rgb : (i == 1 ? h.iris1.rgb : (i == 2 ? h.iris2.rgb : h.iris3.rgb));
    float3 c1 = i == 0 ? h.iris1.rgb : (i == 1 ? h.iris2.rgb : (i == 2 ? h.iris3.rgb : h.iris0.rgb));
    return mix(c0, c1, f);
}

struct FLHoloLook { float4 body, rim, fringe, cloud, extra; };

// Signed distance to the iso-surface (drawable px, + inside) at a drawable pixel and its tank point.
static inline float flHoloSD(texture2d<half> G, constant FluidShadeUniforms& u, constant FLShadeExt& x, float2 px,
                             float2 tankP, thread float& glenOut) {
    float2 uv = (px - u.fieldRect.xy) / u.fieldRect.zw;
    float2 wallDist = float2(min(tankP.x, u.tankSize.x - tankP.x), min(tankP.y, u.tankSize.y - tankP.y));
    float2 wallW = saturate(wallDist / (2.0f * u.dx));
    float wallGain = 1.0f / ((0.5f + 0.5f * wallW.x) * (0.5f + 0.5f * wallW.y));
    float4 g = float4(G.sample(flLinearClamp, uv, level(0.0f)));
    float glen = length(g.gb * wallGain * wallW * x.view.z);
    glenOut = glen;
    return (g.r * wallGain - u.threshold) / max(glen, 1e-5f);
}

// One echo: the surface `age` seconds ago (a copy of G's level 1 over its own field rectangle), as a faint fill with a
// brighter outline of its own.
static inline float3 flEcho(texture2d<half> E, float4 rect, float age, float2 px, float wallGain, float iso,
                            constant FluidHoloUniforms& h) {
    float life = max(h.ghostFar.a, 1e-3f);
    if (age <= 0.0f || age >= life || rect.z <= 0.0f) return float3(0.0f);
    float2 euv = (px - rect.xy) / rect.zw;
    if (any(euv < 0.0f) || any(euv > 1.0f)) return float3(0.0f);
    float e = float(E.sample(flLinearClamp, euv, level(0.0f)).r) * wallGain;
    float a = smoothstep(iso - 0.07f, iso + 0.07f, e);
    float outline = 4.0f * a * (1.0f - a);
    float k = age / life;
    float fade = (1.0f - k) * (1.0f - k);
    return mix(h.ghostNear.rgb, h.ghostFar.rgb, k) * (0.035f * a + 0.75f * outline) * fade;
}

static inline float flFlash(float4 f, float2 p) {
    if (f.w <= 0.0f || f.z <= 0.0f) return 0.0f;
    float2 d = (p - f.xy) / f.z;
    return f.w * exp(-dot(d, d) * 2.0f);
}

// The hologram's three material slots (H2.xyz).
static inline FLHoloLook flBlendHolo3(constant FluidHoloLookGPU* looks, float3 w) {
    FLHoloLook L;
    L.body = 0; L.rim = 0; L.fringe = 0; L.cloud = 0; L.extra = 0;
    for (uint i = 0; i < FL_HOLO_SLOTS; ++i) {
        float wi = w[i];
        if (wi <= 0.0f) continue;
        L.body += wi * looks[i].body;     L.rim += wi * looks[i].rim;
        L.fringe += wi * looks[i].fringe; L.cloud += wi * looks[i].cloud;
        L.extra += wi * looks[i].extra;
    }
    return L;
}

// The hologram over what is already drawn (no `behind` copy): premultiplied light, its alpha the share of the chamber
// it hides (cover × (1 − translucency)); echoes and flashes add light only.
fragment float4 flHoloFragment(FLShadeOut in [[stage_in]],
                               texture2d<half> fieldH0 [[texture(0)]],
                               texture2d<half> fieldH1 [[texture(1)]],
                               texture2d<half> fieldH2 [[texture(2)]],
                               texture2d<half> fieldG [[texture(6)]],
                               texture2d<half> echo0 [[texture(8)]],
                               texture2d<half> echo1 [[texture(9)]],
                               texture2d<half> echo2 [[texture(10)]],
                               constant FluidShadeUniforms& u [[buffer(0)]],
                               constant FluidHoloLookGPU* looks [[buffer(1)]],
                               constant FLShadeExt& x [[buffer(3)]],
                               constant FluidHoloUniforms& h [[buffer(4)]]) {
    float pxPerM = x.view.x;
    float ppp = max(h.misc2.x, 1.0f);                                         // drawable px per point
    float2 px0 = in.position.xy;
    float2 p0 = in.tank;
    // The lens: this pixel shows the hologram at `p` — magnified toward the centre, shifted by the tilt (both feathered
    // to nothing at the rim) — and its red and blue edges at ± `split` (diagonal edges only; Metro spec §14).
    float2 p = p0, split = 0.0f;
    float inLens = 0.0f;
    if (h.lens.w > 0.0f && h.lens.z > 0.0f) {
        float2 d = (p0 - h.lens.xy) / h.lens.z;
        float r = length(d);
        if (r < 1.0f) {
            float feather = 1.0f - flQuintic((r - 0.82f) / 0.18f);
            float weight = feather * (1.0f - 0.32f * r * r);
            float m = (1.0f - r * r) * (1.0f - r * r);
            p = p0 - (p0 - h.lens.xy) * (h.lensOptics.z * m * h.lens.w) - h.lensOptics.xy * (weight * h.lens.w);
            float window = r < 0.82f ? flQuintic((r - 0.52f) / 0.30f) : 1.0f - flQuintic((r - 0.82f) / 0.18f);
            float diag = r > 1e-4f ? 2.0f * d.x * d.y / (r * r) : 0.0f;
            float2 radial = r > 1e-4f ? d / r : float2(0.0f);
            split = (h.tilt.xy * 0.5f + radial * 0.25f) * h.lensOptics.w * window * diag * diag * h.lens.w;
            inLens = h.lens.w;
        }
    }
    float2 px = px0 + (p - p0) * float2(pxPerM, -pxPerM);
    float2 uv = (px - u.fieldRect.xy) / u.fieldRect.zw;
    float2 wallDist = float2(min(p.x, u.tankSize.x - p.x), min(p.y, u.tankSize.y - p.y));
    float2 wallW = saturate(wallDist / (2.0f * u.dx));
    float wallGain = 1.0f / ((0.5f + 0.5f * wallW.x) * (0.5f + 0.5f * wallW.y));
    float4 G = float4(fieldG.sample(flLinearClamp, uv, level(0.0f)));
    float th = G.r * wallGain;
    float2 gpx = G.gb * wallGain * wallW * x.view.z;
    float glen = length(gpx);
    float sd = (th - u.threshold) / max(glen, 1e-5f);
    float ramp = max(0.75f, u.softness / max(glen, 1e-5f));
    float cover = saturate(sd / (2.0f * ramp) + 0.5f);
    // Red and blue silhouettes at the lens's diagonal edges.
    float sdR = sd, sdB = sd, coverR = cover, coverB = cover;
    bool chroma = inLens > 0.0f && (abs(split.x) + abs(split.y)) > 1e-7f;
    if (chroma) {
        float2 sp = split * float2(pxPerM, -pxPerM);
        float gR, gB;
        sdR = flHoloSD(fieldG, u, x, px + sp, p + split, gR);
        sdB = flHoloSD(fieldG, u, x, px - sp, p - split, gB);
        coverR = saturate(sdR / (2.0f * max(0.75f, u.softness / max(gR, 1e-5f))) + 0.5f);
        coverB = saturate(sdB / (2.0f * max(0.75f, u.softness / max(gB, 1e-5f))) + 0.5f);
    }
    float coverMax = max(cover, max(coverR, coverB));

    // Echoes of the surface a moment ago, where the paste is no longer.
    float3 echo = 0.0f;
    if (h.ghostNear.a > 0.0f && coverMax < 1.0f) {
        echo = flEcho(echo0, h.ghostRect0, h.ghostAge.x, px, wallGain, u.threshold, h)
             + flEcho(echo1, h.ghostRect1, h.ghostAge.y, px, wallGain, u.threshold, h)
             + flEcho(echo2, h.ghostRect2, h.ghostAge.z, px, wallGain, u.threshold, h);
        echo *= h.ghostNear.a * (1.0f - coverMax);
    }
    if (coverMax <= 0.0f) {
        if (max(echo.r, max(echo.g, echo.b)) < 1e-4f) discard_fragment();
        return float4(echo, 0.0f);                                            // additive light
    }
    sd = max(sd, 0.0f);

    float4 H0 = float4(fieldH0.sample(flLinearClamp, uv));
    float4 H1 = float4(fieldH1.sample(flLinearClamp, uv));
    float4 H2 = float4(fieldH2.sample(flLinearClamp, uv));
    float hA = max(H0.r, 1e-4f);                                              // ratios: the wall gain cancels
    float wsum = max(H2.x + H2.y + H2.z, 1e-4f);
    FLHoloLook L = flBlendHolo3(looks, H2.xyz / wsum);
    float pxPerMm = pxPerM * 1e-3f;

    // Distance from the free edge on a smoother copy of the field (no particle scallops), and how deep in the body.
    float4 Gn = float4(fieldG.sample(flLinearClamp, uv, level(x.misc.z)));
    float2 gn = Gn.gb * wallGain * wallW * x.view.z;
    float gnl = length(gn);
    float sdN = max((Gn.r * wallGain - u.threshold) / max(gnl, 1e-5f), 0.0f);
    float tc = float(fieldG.sample(flLinearClamp, uv, level(x.view.y)).r) * wallGain;
    float deep = smoothstep(0.80f, 0.98f, tc);
    float dMm = mix(sdN / max(pxPerMm, 1e-3f), 8.0f, deep);
    float2 outward = gnl > 1e-6f ? float2(-gn.x, gn.y) / gnl : (glen > 1e-6f ? float2(-gpx.x, gpx.y) / glen : float2(0.0f, 1.0f));
    float2 lightDir = float2(cos(h.misc2.y), sin(h.misc2.y));
    float facing = 0.55f + 0.45f * dot(outward, lightDir);
    float shell = saturate(1.0f - dMm / 2.2f);
    // A coarser distance from the free edge, reliable some 8 mm into the body (the field at about seven cells): the
    // thin film's colour runs in broad bands that follow the paste's shape.
    float lodF = x.view.y + 1.5f;
    float4 Gf = float4(fieldG.sample(flLinearClamp, uv, level(lodF)));
    float gfl = length(Gf.gb * wallGain * wallW * x.view.z);
    float dFilm = clamp((Gf.r * wallGain - u.threshold) / max(gfl, 1e-5f) / max(pxPerMm, 1e-3f), 0.0f, 12.0f);

    // Stripe dye: the three buckets partitioned crisply (a sharp softmax of their shares, so the bands keep clean,
    // anti-aliased edges through the field's blur), with a thin dark seam where two bands meet.
    float3 sb = saturate(H0.gba / hA);
    float sbSum = sb.x + sb.y + sb.z;
    float dyed = saturate(sbSum * 1.15f);
    float top = max(sb.x, max(sb.y, sb.z));
    float3 e3 = exp((sb - top) * 18.0f);
    float3 w3 = e3 / (e3.x + e3.y + e3.z);
    float3 bandC = w3.x * h.band0.rgb + w3.y * h.band1.rgb + w3.z * h.band2.rgb;
    float second = sbSum - top - min(sb.x, min(sb.y, sb.z));
    // How clearly one band dominates here, relative to its own share (a narrow middle band blurred thin still has a
    // clear middle): 0 at a seam, 1 in the middle of a band.
    float dominance = saturate((top - second) / max(top, 1e-3f));
    float seam = (1.0f - smoothstep(0.015f, 0.07f, dominance)) * smoothstep(0.25f, 0.6f, sbSum);
    float bandShown = dyed * h.misc.y;
    float yielded = saturate(H1.a / hA);

    // Thin-film fringes at the rim: iridescent lines parallel to the free edge within ~2 mm of it (the distance
    // estimate is exact there); hue drifts along the diagonal and turns with the tilt; structure λ (violet: memory)
    // deepens them.
    float lam = saturate(H1.z / hA);
    float period = max(L.fringe.x * 1000.0f, 0.05f);
    float ph = dMm / period;
    float hue = L.fringe.z + 0.31f * ph + dot(p, float2(0.7071f)) * L.fringe.w + dot(h.tilt.xy, float2(0.55f, 0.35f));
    float3 iris = flIris(hue, h);
    float lines = 0.5f + 0.5f * cos(6.2831853f * ph);
    lines *= lines;
    lines *= lines;                                                           // thin bright fringes, wide dark gaps
    float aaF = saturate(1.2f - 2.5f * fwidth(ph));
    float zone = smoothstep(0.12f, 0.45f, dMm) * (1.0f - smoothstep(0.9f, 2.2f, dMm));   // inside the rim's core
    float fr = L.fringe.y * h.misc2.z * (0.75f + 0.25f * lam);
    // Interference across the body: fine diagonal lines (a diffraction sheen) whose hue runs along the other diagonal
    // and which slide as the phone tilts, like a hologram sticker. Subtle, and only detail: no broad moving fill.
    float dph = dot(p, float2(0.7071f, -0.7071f)) * 1000.0f / 0.55f + dot(h.tilt.xy, float2(2.2f, 1.4f));
    float dl = 0.5f + 0.5f * cos(6.2831853f * dph);
    dl *= dl; dl *= dl;
    float aaD = saturate(1.2f - 2.5f * fwidth(dph));
    float3 sheen = flIris(L.fringe.z + 0.5f + dot(p, float2(0.7071f)) * L.fringe.w * 1.5f + dot(h.tilt.xy, float2(0.4f, 0.25f)), h);
    // Thin-film colour across the body: hue by the coarse distance from the edge, drifting along the diagonal and
    // turning with the tilt; strongest a few millimetres in, gone in the depth.
    float3 film = flIris(L.fringe.z + 0.25f + dFilm / 3.2f + dot(p, float2(0.7071f)) * L.fringe.w * 0.6f
                         + dot(h.tilt.xy, float2(0.45f, 0.30f)), h);
    float filmK = L.fringe.y * h.misc2.z * smoothstep(0.3f, 1.5f, dFilm) * (1.0f - smoothstep(6.0f, 11.0f, dFilm));
    // Like a hologram sticker, the diffraction lines catch the light in a soft diagonal band that slides with the tilt
    // (a material response to the sensor, bounded; at rest it lies across the chamber's middle).
    float glintAt = dot(p - u.tankSize * 0.5f, float2(0.7071f)) * 1000.0f;   // mm along the diagonal
    float glintC = (h.tilt.x * 0.8f + h.tilt.y * 0.5f) * 40.0f;
    float glint = exp(-((glintAt - glintC) * (glintAt - glintC)) / 220.0f);

    // Scanlines in the projector's frame, scrolling slowly upward.
    float scanPh = (p.y - h.tilt.z * h.scan.z * (1.0f - h.tilt.w)) / max(h.scan.x, 1e-6f);
    float scanAA = 1.0f - smoothstep(0.18f, 0.42f, fwidth(scanPh));
    float scan = 1.0f - h.scan.y * scanAA * (0.5f - 0.5f * cos(6.2831853f * scanPh));
    // Edge-lit gel: the light colour is the band's (dyed paste) or the look's body light; the brightness is a dim,
    // see-through interior, a bright Fresnel shell toward the free surface (a longer path through the gel) and, in dyed
    // paste, each band lit along its own edges like edge-lit acrylic, with a thin dark gap where two bands meet: luminous
    // ribbons that stretch, fold and coil with the paste. The brightest light whitens a little, as light does.
    float foam = L.extra.z;
    float3 lightC = mix(L.body.rgb, bandC * h.misc2.w, bandShown) * h.scan.w;
    float shellLight = exp(-dMm / 0.80f);
    float bandEdge = bandShown * exp(-max(dominance - 0.07f, 0.0f) / 0.12f) * (1.0f - seam);
    float level = (mix(0.10f, 0.18f, bandShown) + 0.82f * shellLight + 0.85f * bandEdge) * (1.0f - 0.35f * deep)
                * (1.0f - 0.25f * foam);
    // Where two bands meet, a thin bright interference line instead of a gap (light adds; it never outlines in black).
    level += 0.55f * seam * bandShown;
    // A white only reads as light (not grey) when it outshines its saturated neighbours: lift achromatic light.
    float cMax = max(lightC.r, max(lightC.g, lightC.b)), cMin = min(lightC.r, min(lightC.g, lightC.b));
    level *= 1.0f + 1.1f * (1.0f - (cMax - cMin) / max(cMax, 1e-4f));
    level *= 1.0f + 0.30f * exp(-p.y / 0.014f);                              // nearer the projector, brighter
    float3 body = lightC * level;
    float lumB = dot(body, float3(0.2126f, 0.7152f, 0.0722f));
    body = mix(body, float3(lumB * 1.1f), smoothstep(0.16f, 0.55f, lumB) * 0.40f);
    body += iris * fr * zone * mix(0.4f, lines, aaF) * 0.85f * h.scan.w * (0.6f + 0.4f * facing);
    body += film * filmK * 0.075f * h.scan.w;
    // Depth contours: thin iridescent lines every 1.8 mm in from the free surface, a holographic relief map of the
    // paste's own shape that follows every fold as it flows; they fade with depth (and where they would alias), and
    // stay quieter over dye bands, which carry their own edges.
    float cph = dFilm / 1.8f;
    float cfw = max(fwidth(cph), 1e-4f);
    float cd = abs(fract(cph + 0.5f) - 0.5f);
    float contour = (1.0f - smoothstep(0.6f * cfw, 1.6f * cfw, cd)) * saturate(1.5f - 2.0f * cfw)
                  * smoothstep(1.2f, 2.2f, dFilm) * (1.0f - smoothstep(5.5f, 9.0f, dFilm)) * (1.0f - 0.6f * bandShown);
    float3 contourC = flIris(L.fringe.z + 0.18f * floor(cph + 0.5f) + dot(h.tilt.xy, float2(0.45f, 0.30f)), h);
    body += contourC * contour * L.fringe.y * h.misc2.z * 0.12f * h.scan.w;
    body += sheen * fr * dl * aaD * (0.05f + 0.16f * glint) * h.scan.w * (1.0f - 0.5f * zone);
    body *= scan;
    // The projector's refresh: a thin brighter line sweeping up through the hologram every 3.6 s (none under Reduce
    // Motion).
    if (h.tilt.w < 0.5f) {
        float sweepY = (fract(h.tilt.z / 3.6f) * 1.3f - 0.15f) * u.tankSize.y;
        float sweep = exp(-abs(p.y - sweepY) / 0.00030f);
        body += (lightC * 0.8f + body * 0.5f) * sweep;
    }

    // Rim: a 1 pt core and a soft Fresnel falloff, lit from the key side; it takes the band's and the fringe's hue.
    float rimPx = max(L.rim.a * pxPerM, 1.0f);
    float3 rimC = mix(mix(L.rim.rgb, bandC, bandShown * 0.6f), iris, saturate(fr * 0.40f));
    float rimK = h.misc.w * facing * (1.0f - 0.85f * deep);
    float rimL = rimK * (exp(-sd / (0.5f * ppp)) * 1.5f + exp(-sd / rimPx) * 0.26f);   // a 1 pt core, a soft shell

    // Signal light: cyan where the paste flows (shear, yielded), amber where it jams or an event flashes, violet
    // structure.
    float sg = saturate(H1.x / hA);
    float shearE = h.shear.a * L.extra.w * smoothstep(0.25f, 1.0f, sg) * (0.3f + 0.7f * yielded);
    body += h.shear.rgb * shearE * 0.16f;
    rimC = mix(rimC, h.shear.rgb, shearE * 0.45f);
    float jam = saturate(H1.y / hA);
    float jamE = h.stress.a * L.cloud.w * smoothstep(0.30f, 0.80f, jam);
    body = mix(body, h.stress.rgb * 0.26f, jamE * 0.6f);
    rimC = mix(rimC, h.stress.rgb, jamE);
    float fl = flFlash(h.flash0, p) + flFlash(h.flash1, p) + flFlash(h.flash2, p) + flFlash(h.flash3, p);
    fl = min(fl, 1.5f) * h.stress.a;
    body += h.stress.rgb * fl * 0.32f;
    rimC = mix(rimC, h.stress.rgb, saturate(fl));
    rimL *= 1.0f + 0.8f * fl;
    body += h.structure.rgb * h.structure.a * lam * zone * fr * 0.05f;

    // Lava: blackbody glow by temperature (amber-white where molten).
    if (L.extra.x > 0.0f) {
        float Tk = H2.a / wsum * 1000.0f;
        body += flBlackbody(Tk) * min(flGlowRadiance(Tk), 2.5f) * L.extra.x * 0.22f;
    }
    // Magnetic looks: field lines of a dipole at the magnet (r = C sin²θ, iso-lines of C on a log scale), or of a
    // uniform vertical field.
    if (L.extra.y > 0.0f && h.field.w > 0.0f) {
        float2 q = (p - h.field.xy) * 1000.0f;                               // mm
        float phL;
        if (h.field.z > 0.5f) {
            float rr = max(length(q), 0.5f);
            float s = q.x / rr;
            phL = log2(rr / max(s * s, 0.03f)) * 2.2f;
        } else {
            phL = q.x / 2.4f;
        }
        float fwL = max(fwidth(phL), 1e-4f);
        float ln = smoothstep(0.44f - fwL * 1.5f, 0.44f, abs(fract(phL) - 0.5f));   // a thin line at each whole phase
        body += h.structure.rgb * ln * L.extra.y * h.field.w * 0.30f * (0.5f + 0.5f * shell);
    }

    // Over the chamber: the body hides part of what lies behind it (premultiplied alpha), its light adds.
    float through = mix(0.30f, 0.90f, saturate(h.misc.z * L.body.a));
    float hide = 1.0f - through;
    float3 c = body + rimC * rimL;
    if (chroma) {
        float rimLR = rimK * (exp(-max(sdR, 0.0f) / (0.5f * ppp)) * 1.5f + exp(-max(sdR, 0.0f) / rimPx) * 0.26f);
        float rimLB = rimK * (exp(-max(sdB, 0.0f) / (0.5f * ppp)) * 1.5f + exp(-max(sdB, 0.0f) / rimPx) * 0.26f);
        float r = (body.r + rimC.r * rimLR) * coverR;
        float g = c.g * cover;
        float b = (body.b + rimC.b * rimLB) * coverB;
        return float4(float3(r, g, b) + echo, coverMax * hide);
    }
    return float4(c * cover + echo, cover * hide);                           // premultiplied alpha
}

// ------------------------------------------------------------------------------------------------
// 8. The probability cloud: every particle a faint point of the band's (or body's) colour whose brightness flickers
//    with its own phase and rate; lone particles outside the surface (spray) read brighter. Additive light.
struct FLCloudOut {
    float4 position [[position]];
    float2 local;
    float3 colour [[flat]];
};

vertex FLCloudOut flCloudVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                device const PBParticle* particles [[buffer(0)]],
                                constant FluidSplatUniforms& su [[buffer(1)]],
                                constant FluidShadeUniforms& sh [[buffer(2)]],
                                constant FluidHoloLookGPU* looks [[buffer(3)]],
                                constant FLShadeExt& x [[buffer(4)]],
                                constant FluidHoloUniforms& h [[buffer(5)]],
                                texture2d<half> fieldG [[texture(0)]]) {
    PBParticle p = particles[iid];
    float2 corner = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? 1.0f : -1.0f);
    FLCloudOut o;
    o.position = float4(2, 2, 2, 1);
    o.local = corner;
    o.colour = 0.0f;
    uint slot = (p.flags & PB_FLAG_ENABLED) ? su.materialSlot[min(p.material, uint(PB_MAX_MATERIALS - 1))] : FL_HIDDEN;
    if (slot >= FL_SLOTS) return o;
    FluidHoloLookGPU L = looks[min(slot, FL_HOLO_SLOTS - 1u)];
    float gain = L.cloud.x * h.misc.x;
    if (gain <= 0.0f) return o;
    float2 m = (p.position - su.originCells) * su.dx;                        // tank metres
    float lensFade = 1.0f;
    if (h.lens.w > 0.0f && h.lens.z > 0.0f) {
        float r = length(m - h.lens.xy) / h.lens.z;
        lensFade = mix(1.0f, smoothstep(0.8f, 1.05f, r), h.lens.w);
    }
    // The point sits at a hashed place in the particle's own share of its cell (fixed per particle), so the lattice the
    // particles start on never reads as a grid of dots.
    float2 jitter = (flHash2(p.tag * 53.13f + 0.71f) - 0.5f) * 0.9f;        // cells
    float4 clip = flTankClip(su, p.position + jitter);
    float2 ndc = clip.xy / clip.w;
    float2 pxp = (ndc * float2(0.5f, -0.5f) + 0.5f) * sh.drawableSize;
    float2 wallW = saturate(float2(min(m.x, sh.tankSize.x - m.x), min(m.y, sh.tankSize.y - m.y)) / (2.0f * su.dx));
    float t = flCoverAt(fieldG, sh, pxp) / ((0.5f + 0.5f * wallW.x) * (0.5f + 0.5f * wallW.y));
    float lone = 1.0f - smoothstep(sh.threshold * 0.5f, sh.threshold, t);
    float nearEdge = 1.0f - smoothstep(sh.threshold, sh.threshold + 0.45f, t);   // within ~a cell of the free surface
    // Own phase and rate (±40 %), raised to the sixth power: a point is mostly faint, with brief bright moments.
    float rate = L.cloud.z * (0.6f + 0.8f * flHash(p.tag * 31.7f + 2.3f));
    float b = h.tilt.w > 0.5f ? 0.3f : 0.5f + 0.5f * sin(6.2831853f * (p.tag * 7.31f + rate * h.tilt.z));
    b = b * b * b;
    b *= b;
    uint band = (p.flags >> PB_DYE_SHIFT) & PB_DYE_MASK;
    uint bucket = band == 0u ? FL_BUCKET_NONE : ((su.bandBuckets >> (2u * min(band, 7u))) & 3u);
    float3 col = bucket == 0u ? h.band0.rgb : (bucket == 1u ? h.band1.rgb : (bucket == 2u ? h.band2.rgb : L.body.rgb));
    if (h.misc.y < 0.5f) col = L.body.rgb;
    col = mix(col, h.stress.rgb, L.cloud.w * h.stress.a * smoothstep(0.3f, 0.8f, p.contact));
    float flowing = p.viscosity < FL_UNYIELDED ? saturate(log10(max(p.shearRate, 1e-3f)) / 2.5f) : 0.0f;
    col = mix(col, h.shear.rgb, 0.4f * flowing * L.extra.w * h.shear.a);
    // A temperature glow (lava): the points are embers in the blackbody colour of their own temperature.
    if (L.extra.x > 0.0f) col = mix(col, flBlackbody(p.temperature) * min(flGlowRadiance(p.temperature), 2.0f) * 1.6f, L.extra.x);
    float bright = gain * (0.12f + 0.88f * b) * (1.0f + 0.8f * L.extra.z) * (1.0f + 0.6f * lone) * lensFade
                 * (0.45f + 0.55f * max(nearEdge, L.extra.z));
    float cellPx = x.view.x * su.dx;
    float radiusPx = max(L.cloud.y * cellPx * (1.0f + 0.5f * L.extra.z), 0.55f * max(h.misc2.x, 1.0f));
    o.colour = col * bright;
    clip.xy += corner * radiusPx * 2.0f / sh.drawableSize * clip.w;
    o.position = clip;
    return o;
}

fragment float4 flCloudFragment(FLCloudOut in [[stage_in]]) {
    float r2 = dot(in.local, in.local);
    if (r2 > 1.0f) discard_fragment();
    float a = exp(-r2 * 4.5f);
    return float4(in.colour * a, 0.0f);
}

// ------------------------------------------------------------------------------------------------
// Layout probe: the host compares these with MemoryLayout<...>.stride (C/Swift view of MPMRender.h and the mirrors).
kernel void flLayoutProbe(device uint* out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    if (id != 0) return;
    out[0] = sizeof(FluidSplatUniforms); out[1] = sizeof(FluidLookGPU); out[2] = sizeof(FluidShadeUniforms);
    out[3] = __builtin_offsetof(FluidSplatUniforms, materialSlot); out[4] = __builtin_offsetof(FluidShadeUniforms, keyLight);
    out[5] = __builtin_offsetof(FluidShadeUniforms, behindLod);
    out[6] = sizeof(FLLookExt); out[7] = sizeof(FLShadeExt); out[8] = sizeof(FLDyeParams);
    out[9] = sizeof(FluidHoloLookGPU); out[10] = sizeof(FluidHoloUniforms);
    out[11] = __builtin_offsetof(FluidSplatUniforms, bandBuckets); out[12] = __builtin_offsetof(FluidHoloUniforms, misc2);
}
