// MPMRender.h — render-side structs shared by Swift and MSL for LabKit's 2.5D fluid surface renderer
// (MPMSurfaceRenderer, Shaders/MPMRender.metal). New code (not derived from PB-MPM). Owned by WP-G.
#ifndef LABKIT_MPM_RENDER_H
#define LABKIT_MPM_RENDER_H
#include "MPMShared.h"

#ifdef __METAL_VERSION__
typedef metal::float4x4 fl_float4x4;
#else
typedef simd_float4x4 fl_float4x4;
#endif

#define FL_DIAG_NONE        0u
#define FL_DIAG_SHEAR_RATE  1u   // log10(γ̇)  in [-2, 3]   1/s
#define FL_DIAG_VISCOSITY   2u   // log10(η)  in [-3, 6]   Pa·s
#define FL_DIAG_STRESS      3u   // log10(τ)  in [-1, 4]   Pa
#define FL_DIAG_STRUCTURE   4u   // λ         in [0, 1]
#define FL_DIAG_JAM         5u   // f         in [0, 1]
#define FL_DIAG_TEMPERATURE 6u   // T         in [273, 1473] K
#define FL_DIAG_SPEED       7u   // |v|       in [0, speedMax] m/s

#define FL_SLOTS 7u              // materials blended on screen at once: W0.rgba = slots 0-3, W1.rgb = slots 4-6
#define FL_HIDDEN 255u           // materialSlot value of a material that is not drawn
#define FL_LUT_ROWS 4u           // colour-map LUT rows: 0 viridis, 1 magma, 2 inferno, 3 plasma (all CC0)

// Splat pass (vertex + fragment) into the half-resolution field targets; also the debug overlays.
// 208 bytes (192 before the hologram's band buckets, 13 October 2026).
typedef struct {
    fl_float4x4 tankToClip;      // 0   tank metres (origin bottom-left, y up, z = 0) -> clip of the pass it is used in
    pb_float2 originCells;       // 64  cell coordinate of the tank origin (4, 4 on walled axes)
    float dx;                    // 72  m per cell
    float radiusCells;           // 76  splat radius, cells (1.2 for 2x2 particles per cell)
    float weight;                // 80  1 / interior splat sum, so a full region has thickness ~1
    pb_uint diagMode;            // 84  FL_DIAG_*
    float speedMax;              // 88  m/s, FL_DIAG_SPEED range and streak colour
    float dtSub;                 // 92  s, to turn displacement into velocity
    float tracerFraction;        // 96  share of particles that carry dye (0 = none)
    float streakSeconds;         // 100 flow streak length = |v| * streakSeconds
    float pointRadiusPx;         // 104 particle view disc radius
    pb_uint colormap;            // 108 LUT row of the debug overlays
    pb_float2 viewportPx;        // 112 size of the target the overlays draw into (pixels)
    pb_float2 gravityKick;       // 120 cells per substep, subtracted from displacement for speed
    pb_uint materialSlot[PB_MAX_MATERIALS];   // 128 material index -> weight slot 0..6 (FL_HIDDEN = not drawn)
    pb_uint bandBuckets;         // 192 hologram: 2 bits per dye band 0-7 (bits 2b..2b+1) -> colour bucket 0-2, 3 = none
    pb_uint pad0;                // 196
    float pad1;                  // 200
    float pad2;                  // 204
} FluidSplatUniforms;

// Per-slot appearance (linear Display P3 values), 112 bytes.
typedef struct {
    pb_float4 albedo;            // rgb body colour, a: opacity (0 clear .. 1 opaque)
    pb_float4 absorption;        // rgb Beer-Lambert coefficient per thickness unit, a: thickness -> optical depth scale
    pb_float4 scatter;           // rgb subsurface tint, a: wrap-lighting amount
    pb_float4 surface;           // x IOR, y GGX roughness, z sheen metalness, w refraction strength (uv per unit slope)
    pb_float4 emission;          // rgb glow colour, a: temperature glow gain (lava); 0 = none
    pb_float4 extra;             // x backdrop blur LOD (turbidity), y glow onset temperature (K), z normal height scale, w rim
    pb_float4 texture;           // x grain amplitude, y tracer darkness, z specular intensity, w unused
} FluidLookGPU;

// Shade pass (full resolution, inside the scene's second pass), 192 bytes.
typedef struct {
    fl_float4x4 tankToClip;      // 0   tank metres -> drawable clip (bounds the shade quad to the tank)
    pb_float2 tankSize;          // 64  m
    pb_float2 texel;             // 72  1 / field texture size
    pb_float4 fieldRect;         // 80  drawable pixels covered by the field textures: origin xy, size zw
    pb_float2 drawableSize;      // 96  pixels
    float threshold;             // 104 iso level of the surface (thickness units, ~0.35)
    float softness;              // 108 half-width of the edge ramp (thickness units)
    float texelsPerCell;         // 112 field texels per grid cell (normal and blur scale)
    float time;                  // 116 s
    float lutRows;               // 120 rows in the LUT texture
    pb_uint diagnostic;          // 124 FL_DIAG_* (0 = material look)
    pb_float4 keyLight;          // 128 xyz direction (toward light), w intensity
    pb_float4 fillLight;         // 144 xyz direction, w intensity
    pb_uint colormap;            // 160 LUT row
    float glow;                  // 164 multiplier on emission gain
    float grain;                 // 168 multiplier on grain amplitude
    float tracers;               // 172 multiplier on tracer darkness (0 = dye hidden)
    float depth;                 // 176 multiplier on optical depth
    float dx;                    // 180 m per cell
    float behindLod;             // 184 highest mip level of the behind texture
    float pad0;                  // 188
} FluidShadeUniforms;

// ---- Hologram style (FluidRenderStyle.hologram; Toothpaste Toy, 13 October 2026) --------------------------------
// The hologram has its own, coarser prepass (flHoloSplat*, about 4 texels per cell, three targets):
//   H0 = (t, t·bucket 0, t·bucket 1, t·bucket 2): each particle's stripe dye band (PBParticle.flags bits 8-11) sorted
//        into three colour buckets by FluidSplatUniforms.bandBuckets;
//   H1 = (t·shear glow, t·contact, t·structure, t·yielded): yielded = the particle flows (secant viscosity below
//        FL_UNYIELDED);
//   H2 = (t per material slot 0-2, t·T/1000): up to FL_HOLO_SLOTS materials blend (more share the last slot).
// The surface style's splat also writes S = (t·bucket 0-2, t·yielded) as its fifth target. The hologram shade
// (flHoloFragment) draws the paste as light over whatever is already in the target (no `behind` copy): a Fresnel rim,
// contour fringes, scanlines, band colours, shear/jam/structure light, event flashes, echoes of the surface a fraction
// of a second ago (a ring of earlier thickness fields), and a refracting lens; the cloud pass (flCloudVertex) draws
// every particle as a faint point that flickers with its own phase. A visual style only: the solver reads none of it.
#define FL_UNYIELDED 1.0e29f     // PBParticle.viscosity at or above this: unyielded (the solver stores 1e30)
#define FL_BUCKET_NONE 3u        // bandBuckets value of a band without a colour
#define FL_HOLO_SLOTS 3u         // materials the hologram blends on screen at once (H2.xyz)

// Per material slot, 80 bytes (linear Display P3 colours).
typedef struct {
    pb_float4 body;              // rgb body light, a translucency (0 hides the backdrop .. 1 lets it all through)
    pb_float4 rim;               // rgb Fresnel rim light, a rim width (m)
    pb_float4 fringe;            // x contour fringe period (m), y amount 0..1, z hue phase (turns), w diagonal drift (turns/m)
    pb_float4 cloud;             // x point brightness, y point radius (cells), z flicker rate (Hz), w jam light (amber) 0..1
    pb_float4 extra;             // x temperature glow (lava) 0..1, y field lines (MR) 0..1, z foam 0..1, w shear light 0..1
} FluidHoloLookGPU;

// Per frame, 432 bytes.
typedef struct {
    pb_float4 tilt;              // 0   xy bounded tilt e (Metro §14), z time (s), w reduce motion (1 = no flicker/scroll)
    pb_float4 scan;              // 16  x scanline period (m), y depth 0..1, z scroll speed (m/s), w body gain
    pb_float4 lens;              // 32  xy centre (m), z radius (m), w strength 0..1 (0 = no lens)
    pb_float4 lensOptics;        // 48  xy tilt shift at the centre (m), z magnification k (0..0.4), w chromatic split (m)
    pb_float4 band0;             // 64  rgb bucket 0 colour, a unused
    pb_float4 band1;             // 80  rgb bucket 1 colour
    pb_float4 band2;             // 96  rgb bucket 2 colour
    pb_float4 shear;             // 112 rgb shear light (cyan), a amount
    pb_float4 stress;            // 128 rgb event / jam light (amber), a amount
    pb_float4 structure;         // 144 rgb structure light (violet), a amount
    pb_float4 ghostNear;         // 160 rgb youngest echo, a amount (0 = no echoes)
    pb_float4 ghostFar;          // 176 rgb oldest echo, a fade time (s)
    pb_float4 ghostAge;          // 192 xyz ages of the three echoes (s, < 0 = none), w unused
    pb_float4 ghostRect0;        // 208 field rectangle of each echo (drawable px: origin xy, size zw)
    pb_float4 ghostRect1;        // 224
    pb_float4 ghostRect2;        // 240
    pb_float4 flash0;            // 256 xy centre (m), z radius (m), w intensity 0..1
    pb_float4 flash1;            // 272
    pb_float4 flash2;            // 288
    pb_float4 flash3;            // 304
    pb_float4 field;             // 320 xy magnet (m), z 1 = dipole at xy, 0 = uniform vertical field, w field 0..1
    pb_float4 iris0;             // 336 thin-film palette: four colours around the hue circle
    pb_float4 iris1;             // 352
    pb_float4 iris2;             // 368
    pb_float4 iris3;             // 384
    pb_float4 misc;              // 400 x cloud gain, y bands shown 0..1, z backdrop through the body 0..1, w rim gain
    pb_float4 misc2;             // 416 x pixels per point, y edge light angle (rad), z fringe gain, w band light in the body
} FluidHoloUniforms;

#endif
