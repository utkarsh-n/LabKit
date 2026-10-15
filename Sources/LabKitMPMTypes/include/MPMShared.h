// MPMShared.h — structs and constants shared by Swift (through the LabKitMPMTypes C target) and MSL
// (Sources/LabKitMPM/Shaders/*.metal include this file by relative path).
//
// Derived from PB-MPM (https://github.com/electronicarts/pbmpm), Copyright (c) 2024 Electronic Arts Inc.
// All rights reserved. Redistribution and use in source and binary forms, with or without modification, are
// permitted under the BSD 3-Clause licence reproduced in LICENSE-PBMPM.md (next to this target and in
// LabKit/THIRD_PARTY_NOTICES.md), which must accompany this file. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT
// HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
// Ported from WGSL to Metal and modified for LabKit, 2026: SI units, the unified EVP material model
// (rheology-models.md §4, Appendix A/C) as an XPBD compliant constraint, moving colliders, rigid-body impulses,
// merged binning, exact grid clearing, periodic verification domains, threadgroup sizes for Apple GPUs.
//
// Units inside the solver (the Swift host converts at the boundary, mpm-metal.md §4):
//   position        cells; node k sits at k + 0.5; tank origin at cell (4, 4) on walled axes, (0, 0) on periodic axes
//   displacement    cells per substep = v·dt/dx (the stored value already holds the next substep's gravity kick)
//   B               dimensionless    = dt·∇v (upstream "deformationDisplacement"); B[col][row], row = velocity component
//   mass            grid mass units  = (ρ/ρ_ref)·area in cells²
//   material, stress, temperature, field: SI (Pa, Pa·s, K, A/m)
#ifndef LABKIT_MPM_SHARED_H
#define LABKIT_MPM_SHARED_H

#ifdef __METAL_VERSION__
#include <metal_stdlib>
typedef metal::float2 pb_float2;
typedef metal::float4 pb_float4;
typedef metal::float2x2 pb_float2x2;
typedef metal::uint2 pb_uint2;
typedef uint pb_uint;
typedef int pb_int;
#else
#include <simd/simd.h>
#include <stdint.h>
typedef simd_float2 pb_float2;
typedef simd_float4 pb_float4;
typedef simd_float2x2 pb_float2x2;
typedef simd_uint2 pb_uint2;
typedef uint32_t pb_uint;
typedef int32_t pb_int;
#endif

// ---- Tiling -------------------------------------------------------------------------------------------
// Upstream main: BukkitSize 6 + halo 1 = 8x8 tile = 64 threads (src/sim.js:13-18). One g2p2g threadgroup = one
// tile = PB_TILE_NODES threads = up to PB_TILE_NODES particles of one bukkit. 3.6 KB of threadgroup memory:
// fits the iOS simulator (512 threads, 16 KB) and the A17 Pro (1,024 threads, 32 KB).
#define PB_BUKKIT_SIZE 6
#define PB_BUKKIT_HALO 1
#define PB_TILE_EDGE 8                                // PB_BUKKIT_SIZE + 2 * PB_BUKKIT_HALO (literal so Swift imports it)
#define PB_TILE_NODES 64                              // PB_TILE_EDGE * PB_TILE_EDGE
#define PB_PARTICLE_GROUP 64                          // particle-parallel passes (upstream ParticleDispatchSize)
#define PB_GRID_GROUP 8                               // grid/bukkit-parallel passes are 8x8 (upstream GridDispatchSize)
#define PB_GUARDIAN 3                                 // upstream GuardianSize
#define PB_WALL_OFFSET 4                              // tank origin in cells on a walled axis (G + 1)
#define PB_MAX_SHAPES 48                              // colliders + emitters + drains per substep
#define PB_MAX_MATERIALS 16
#define PB_PPC_AXIS 2                                 // particles per cell axis (fill, emit)

#ifdef __METAL_VERSION__
static_assert(PB_TILE_EDGE == PB_BUKKIT_SIZE + 2 * PB_BUKKIT_HALO && PB_TILE_NODES == PB_TILE_EDGE * PB_TILE_EDGE, "tile size");
#else
_Static_assert(PB_TILE_EDGE == PB_BUKKIT_SIZE + 2 * PB_BUKKIT_HALO && PB_TILE_NODES == PB_TILE_EDGE * PB_TILE_EDGE, "tile size");
#endif

// ---- Fixed point --------------------------------------------------------------------------------------
// Upstream: multiplier 10^7, truncation (simConstants.inc.wgsl:19-27). Here: 2^24, round to nearest.
// int32 headroom is 2^31 / 2^24 = 128 grid units per node component (mpm-metal.md §8).
#define PB_FIXED_SCALE 16777216.0f        // 2^24
#define PB_FIXED_LIMIT 120.0f             // per-contribution clamp (counted in PBCounters.overflow)
#define PB_NEAR_OVERFLOW (1 << 30)        // node sums beyond 64 grid units also count as overflow
#define PB_IMPULSE_SCALE 1048576.0f       // 2^20 per (grid mass * cells per substep) in the device sums
#define PB_IMPULSE_FINE_SCALE 4194304.0f  // 2^22: threadgroup sums of the no-SIMD-group fallback (shifted >> 2 on flush)
#define PB_NO_SHAPE 255u

// ---- Enumerations -------------------------------------------------------------------------------------
#define PB_MODEL_LIQUID   0u   // upstream PB liquid: volume constraint + native relaxation viscosity (V13 only)
#define PB_MODEL_EVP      1u   // unified elasto-viscoplastic model (rheology-models.md §4) as an XPBD constraint

#define PB_SHAPE_BOX      0u   // rounded box: halfSize + radius
#define PB_SHAPE_CIRCLE   1u
#define PB_SHAPE_CAPSULE  2u   // segment along local x of half length halfSize.x, radius

#define PB_FN_EMIT        0u
#define PB_FN_COLLIDER    1u
#define PB_FN_DRAIN       2u
// Grip (Toothpaste Toy, 13 October 2026): particles inside the shape move with it (displacement set to the shape's
// velocity every substep: a kinematic no-slip hold, the paste in a tube's bore); the impulse is reported on bodyIndex.
#define PB_FN_GRIP        3u

#define PB_FLAG_ENABLED   1u
// Stripe dye (Toothpaste Toy, 13 October 2026): PBParticle.flags bits 8-11 hold a dye band, 0 = none, 1-7 = band
// index. Emitters carry their stripe count in PBShape.emitMaterial bits 8-11 (bits 0-7: the material slot), so PBShape
// keeps its 64-byte layout. Every other flags bit is reserved; nothing but enable/disable and the dye writes them.
#define PB_DYE_SHIFT      8u
#define PB_DYE_MASK       0xFu
#define PB_MAX_STRIPES    7u
#define PB_EMIT_MATERIAL_MASK 0xFFu

#define PB_SIM_PERIODIC_X 1u   // simFlags: x wraps (no guardian band); verification domains
#define PB_SIM_PERIODIC_Y 2u
#define PB_SIM_EXPLICIT   4u   // explicit parity mode: k = 1, omega = 0, beta = 1, volumetric stress warm-started,
                               // no PB volume constraint, no grid-volume J correction (V14)

#define PB_DEBUG_NO_PUSH_IMPULSE 1u  // debugFlags: leave the particle push-out out of the body impulses
#define PB_DEBUG_COLLIDER_GAP    2u  // debugFlags: upstream collider gap term (nodes already inside are pushed to the surface)
#define PB_DEBUG_NO_WALL_MIRROR  4u  // debugFlags: no mirrored (ghost) grid volume at the tank walls
#define PB_DEBUG_ONE_SIDED_J     8u  // debugFlags: upstream one-sided grid-volume J correction (compression only)
#define PB_DEBUG_NO_KELVIN_YIELD 16u  // debugFlags: the field-induced yield ignores the Kelvin cap (before LK-FIX)

// ---- Particle: 112 bytes, 16-byte aligned ------------------------------------------------------------
typedef struct {
    pb_float2   position;                 // 0   cells
    pb_float2   displacement;             // 8   cells per substep
    pb_float2x2 deformationDisplacement;  // 16  B = dt·∇v (dimensionless)
    pb_float4   elastic;                  // 32  b̄e: b11, b12, b22 (isochoric elastic left Cauchy-Green, det 1); w: last γ̇p (1/s)
    pb_float4   iterate;                  // 48  XPBD scratch between iterations: applied a11, a12; already scattered p11, p12 (Pa)
    float liquidDensity;                  // 64  J: volume ratio (upstream name)
    float mass;                           // 68  grid mass units
    float volume;                         // 72  cells² at rest (1 / ppc)
    float structure;                      // 76  thixotropic λ in [0, 1]
    float contact;                        // 80  Wyart-Cates frictional contact fraction f in [0, 1]
    float temperature;                    // 84  K
    float viscosity;                      // 88  secant τ̄/γ̇p of the last commit (Pa·s); 1e30 = unyielded
    float stress;                         // 92  equivalent shear stress τ̄ of the last commit (Pa)
    float shearRate;                      // 96  equivalent total shear rate γ̇ (1/s)
    pb_uint material;                     // 100 index into the PBMaterial table
    pb_uint flags;                        // 104 bit 0 enabled; bits 8-11 dye band (PB_DYE_SHIFT)
    float tag;                            // 108 per-particle random tag in [0, 1) (grain, tracers)
} PBParticle;

// ---- Per-dispatch constants (setBytes), 192 bytes -----------------------------------------------------
typedef struct {
    pb_uint2 gridSize;           // 0   nodes (== cells) in x, y
    pb_uint2 bukkitCount;        // 8   ceil(gridSize / PB_BUKKIT_SIZE)
    float dt;                    // 16  s, this substep
    float dx;                    // 20  m per cell
    pb_float2 gravity;           // 24  cells per substep² = g_eff·dt²/dx (gravity − frame acceleration − vibration)
    pb_uint iteration;           // 32  fused pass index k = 0..iterationCount
    pb_uint iterationCount;      // 36  N = G2P solves per substep
    pb_uint shapeCount;          // 40
    pb_uint substepIndex;        // 44  global substep counter (emission hash)
    float borderFriction;        // 48  tank walls: 0 free slip .. 1 no slip
    float maxDisplacement;       // 52  cells per substep, CFL guard
    pb_uint useGridVolume;       // 56  upstream useGridVolumeForLiquid
    pb_uint particleCapacity;    // 60
    pb_float4 field;             // 64  uniform H.xy (A/m, tank frame), |H|, unused
    pb_float4 magnet;            // 80  virtual magnet position.xy (cells), H0 (A/m at r0; 0 = off), r0 (cells)
    pb_float4 forcing;           // 96  verification body force b_x = amp·sin(k·(y − y0)): amp (cells/substep²), k (rad/cell), y0 (cells)
    pb_float4 probe;             // 112 rheometer probe: position.xy (cells), radius (cells), enabled (> 0)
    float ambientTemperature;    // 128 K
    float thermalTime;           // 132 s; particle T relaxes toward ambient; 0 = off
    float surfaceCooling;        // 136 extra cooling factor at the free surface (low grid fill)
    float heleShawGap;           // 140 m; 0 disables the thin-tank wall drag
    float heleShawMinTime;       // 144 s; floor on t_HS (rheology-models.md §4.10.5 item 4)
    float rhoRef;                // 148 kg/m³ of grid mass unit 1
    float gridVolumeMix;         // 152 upstream 0.1: J relaxes toward the grid volume when compressed
    float dtRatio;               // 156 pass 0 rescales d and B by dt_new/dt_old (dt changed between frames); else 1
    float omega;                 // 160 XPBD relaxation ω (1 production, 0 explicit)
    float beta;                  // 164 warm start β of the deviatoric stress (1)
    pb_uint debugFlags;          // 168 PB_DEBUG_*
    pb_uint bufferParity;        // 172 which dispatch-args slot allocate writes
    pb_uint simFlags;            // 176 PB_SIM_*
    pb_uint injectCount;         // 180 particles in the inject staging buffer
    float colliderSkin;          // 184 cells: grid nodes this close outside a collider already feel it (buoyancy correction)
    float underfillTolerance;    // 188 J deficit an under-filled particle keeps, in gravity kicks |gravity| (two-sided J correction)
} PBSimConstants;

// ---- Collider / emitter / drain shapes, 64 bytes ------------------------------------------------------
typedef struct {
    pb_float2 position;          // cells (centre; torque arm origin)
    pb_float2 halfSize;          // box half extents (cells); capsule: (half length, 0)
    pb_float2 velocity;          // cells per substep; emitters: initial displacement
    float radius;                // cells: circle radius, capsule radius, box corner rounding
    float rotation;              // radians
    float angularVelocity;       // radians per substep
    float friction;              // Coulomb coefficient applied at the grid
    pb_uint shapeType;           // PB_SHAPE_*
    pb_uint functionality;       // PB_FN_*
    pb_uint emitMaterial;        // bits 0-7 material slot; bits 8-11 stripes across the nozzle (0 = plain)
    float emissionRate;          // Hz per emitter slot (2x2 slots per cell)
    pb_int bodyIndex;            // >= 0: accumulate fluid impulses for this shape; -1: static
    float emitTemperature;       // K for emitted particles; <= 0 = ambient
} PBShape;

// ---- Material table (SI), 208 bytes: the unified EVP model (RheoMaterial of rheology-models.md App. A) --
typedef struct {
    pb_uint model;               // PB_MODEL_*
    float density;               // ρ, kg/m³
    float shearModulus;          // G, Pa
    float bulkModulus;           // K, Pa (tension cap; volumetric stress in explicit parity mode)
    float tensionLimit;          // p_tens, Pa
    float yieldBroken;           // τ_y0, Pa
    float yieldStructure;        // Δτ_λ, Pa
    float structureExponent;     // m
    float consistency;           // k, Pa·s^n (0 = HB branch off)
    float flowIndex;             // n
    float consistencyStructure;  // β_λ: k *= 1 + β_λ·λ^m
    float fluidity;              // φ0 = 1/η0, 1/(Pa·s)
    float eaOverR;               // E_a/R on k and φ0, K
    float eaYieldOverR;          // E_a,y/R on τ_y, K
    float refTemperature;        // K
    float failureStress;         // τ_f, Pa (1e30 = off)
    float failureFluidity;       // φ_f, 1/(Pa·s)
    float buildRate;             // A0, 1/s
    float buildShear;            // A1
    float breakRate;             // B0, 1/s
    float breakShear;            // B1
    float vibrationWeight;       // w_vib
    float jMin;                  // J clamp
    float jMax;
    pb_uint dst;                 // 1 = Wyart-Cates block on
    float phi;                   // φ
    float phi0;                  // φ0 (frictionless jamming)
    float phiM;                  // φm (frictional jamming)
    float solventViscosity;      // η_s, Pa·s
    float sigmaStar;             // σ*, Pa
    pb_uint onsetForm;           // bit 0 — 0: 1 - e^(-σ/σ*), 1: e^(-σ*/σ); bit 1 — contacts driven by γ̇p, not γ̇
    float gammaStar;             // γ*
    float meltTime;              // t_melt, s
    float jamTime;               // t_jam, s
    float jamFailureStress;      // τ_jam, Pa
    float postFailureViscosity;  // η_post, Pa·s
    float breakStrain;           // γ_break
    float gapFloor;              // Δφ_min
    float blendWidth;            // w_jam
    float fieldScale;            // τ_sat, Pa (0 = no MR yield)
    float fieldK;                // 1/H_sat, m/A
    float fieldClampFracG;       // τ_field <= fraction·G
    float fieldDeadZone;         // A/m subtracted from |H|
    float susceptibility;        // χ for the Kelvin body force (0 = non-magnetic)
    float wallYieldFactor;       // share of τ_y acting at the thin-tank faces
    float liquidRelaxation;      // α_vol of the PB volume constraint (upstream 1.5)
    float nativeViscosity;       // μ of the native relaxation (PB_MODEL_LIQUID only), Pa·s
    float restMelt;              // w_rest: share of the rest melt that relaxes f toward 0 (0 = lagged-f law)
    float bandBelow;             // K: the shift factors see T ≥ T_ref − bandBelow (40 unless the material widens it)
    float bandAbove;             // K: … and T ≤ T_ref + bandAbove (80)
    float materialPad0, materialPad1;
} PBMaterial;

typedef struct {
    pb_uint rangeStart;
    pb_uint rangeCount;
    pb_uint bukkitX;
    pb_uint bukkitY;
} PBBukkitThreadData;

// Dispatch-args slot written by pbBukkitAllocate: MTLDispatchThreadgroupsIndirectArguments + allocator.
typedef struct {
    pb_uint groupsX, groupsY, groupsZ;
    pb_uint particleAllocator;   // particle slots handed out to bukkits (upstream g_bukkitParticleAlloctor)
} PBBukkitDispatch;

// Device counters (one buffer; atomics in MSL), 80 bytes
typedef struct {
    pb_uint particleCount;       // 0  slots in use (live + freed)
    pb_int  freeCount;           // 4  free list length (may go negative transiently, upstream semantics)
    pb_uint overflow;            // 8  fixed-point contributions clamped, or node sums beyond 2^30
    pb_uint nanResets;           // 12 particles reset by the NaN guard
    pb_uint clamped;             // 16 displacement clamps by the CFL guard
    pb_uint emitted;             // 20
    pb_uint drained;             // 24
    pb_uint impulseOverflow;     // 28 body impulse contributions clamped
    pb_uint particleDispatch[3]; // 32 MTLDispatchThreadgroupsIndirectArguments for particle-parallel kernels
    pb_uint injectDropped;       // 44 injected particles that did not fit
    pb_uint drawArgs[4];         // 48 MTLDrawPrimitivesIndirectArguments: 4 vertices, particle slots, 0, 0
    pb_uint detClamps;           // 64 det(I + B) guards that fired
    pb_uint pad[3];              // 68
} PBCounters;

// Verification job of pbConstitutive: one homogeneous material point under a fixed velocity gradient, 32 bytes.
typedef struct {
    pb_float4 gradient;          // c11 = ∂vx/∂x, c12 = ∂vx/∂y, c21 = ∂vy/∂x, c22 = ∂vy/∂y (1/s)
    float dt;                    // s per update
    pb_uint steps;               // updates to run
    pb_uint material;            // index into the material table
    float fieldMagnitude;        // |H|, A/m
} PBConstitutiveJob;

// Frame statistics (one per readback slot; uint and float atomics in MSL), 96 bytes
typedef struct {
    pb_uint liveCount;           // 0
    pb_uint maxSpeedBits;        // 4  float bits of max |v| (m/s)
    pb_uint maxStressBits;       // 8  float bits of max τ̄ (Pa)
    pb_uint jammedCount;         // 12
    pb_uint yieldedCount;        // 16
    pb_uint pad0, pad1, pad2;    // 20
    float sumJ;                  // 32
    float sumStructure;          // 36
    float sumKinetic;            // 40 J per metre of depth
    float sumMass;               // 44 grid units
    float yieldMass;             // 48 grid units, yielded particles
    float yieldMassLogEta;       // 52 Σ m·log10(η_secant), yielded particles
    float probeWeight;           // 56
    float probeShear;            // 60 Σ w·γ̇
    float probeStress;           // 64 Σ w·τ̄
    float probeSolid;            // 68 Σ w·(unyielded or jammed)
    float sumTemperature;        // 72
    float pad3;                  // 76
    pb_uint gridMass[4];         // 80 debug: exact grid mass / volume as 16-bit-half sums (lo, hi, lo, hi)
} PBStats;

#endif
