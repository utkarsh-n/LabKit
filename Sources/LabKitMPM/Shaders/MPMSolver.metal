// MPMSolver.metal — LabKit's 2D continuum solver: Position Based MPM with the unified EVP material model.
//
// Derived from PB-MPM (https://github.com/electronicarts/pbmpm), Copyright (c) 2024 Electronic Arts Inc.
// All rights reserved. Redistribution and use in source and binary forms, with or without modification, are permitted
// under the BSD 3-Clause licence reproduced in LICENSE-PBMPM.md, which must accompany this file. THIS SOFTWARE IS
// PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
// Ported from WGSL (main 61749b6 g2p2g/bukkit kernels; siggraph2024 5a2f438 pass semantics) to MSL and modified, 2026:
//   * SI units (gravity, colliders, materials), radians, collider tests at node centres (k + 0.5)
//   * Metal fixes: threadgroup memory zeroed explicitly; grid validity uses < gridSize (upstream <=, which relied on
//     WebGPU robust access); 0/0 grid division guarded; atan2(0,0) guarded; NaN/Inf tests on bit patterns (fast math)
//   * grid clearing made exact across substeps (upstream leaves stale sums when the active tile set shrinks)
//   * binning merged into the solver passes: the last pass counts bukkits, allocate clears grid + counters
//   * source tile kept as float in threadgroup memory; only the destination tile uses int atomics
//   * moving colliders with Coulomb friction, capsule and rounded-box shapes, exact rigid-body impulse sums
//   * PB_MODEL_EVP: the unified elasto-viscoplastic model of rheology-models.md §4 (Appendix A update on the isochoric
//     b̄e) run as an XPBD compliant constraint inside the iterations (§4.10.3, Appendix C); with k = 1, omega = 0,
//     beta = 1 and PB_SIM_EXPLICIT the substep is explicit MLS-MPM (the CPU oracle's scheme)
//   * thin-tank (Hele-Shaw) drag, temperature, magnetic field + Kelvin force, verification forcing, periodic axes
//   * no-SIMD-group fallback for the body-impulse reduction (function constant 0), selected at runtime
#include <metal_stdlib>
#include "../../LabKitMPMTypes/include/MPMShared.h"
using namespace metal;

constant bool kUseSimd [[function_constant(0)]];
#define PB_NEAR_COLLIDER_BIT 0x100u                          // sBodyS: the node lies within a collider's skin

// MSL views of the counter structs with atomics (same layout as MPMShared.h)
struct PBCountersAtomic {
    atomic_uint particleCount;
    atomic_int  freeCount;
    atomic_uint overflow;
    atomic_uint nanResets;
    atomic_uint clamped;
    atomic_uint emitted;
    atomic_uint drained;
    atomic_uint impulseOverflow;
    uint particleDispatch[3];
    atomic_uint injectDropped;
    uint drawArgs[4];
    atomic_uint detClamps;
    uint pad[3];
};
struct PBBukkitDispatchAtomic { atomic_uint groupsX; uint groupsY, groupsZ; atomic_uint particleAllocator; };
struct PBStatsAtomic {
    atomic_uint liveCount, maxSpeedBits, maxStressBits, jammedCount, yieldedCount;
    uint pad0, pad1, pad2;
    atomic_float sumJ, sumStructure, sumKinetic, sumMass, yieldMass, yieldMassLogEta;
    atomic_float probeWeight, probeShear, probeStress, probeSolid, sumTemperature;
    float pad3;
    atomic_uint gridMass[4];
};

// ------------------------------------------------------------------------------------------------
// matrix.inc.wgsl
constant float2x2 kIdentity = float2x2(float2(1, 0), float2(0, 1));
static inline float tr2(float2x2 m) { return m[0][0] + m[1][1]; }
static inline float2x2 outer2(float2 x, float2 y) { return float2x2(x * y.x, x * y.y); }
// Fast math may fold isnan/isinf away; test the exponent bits instead.
static inline bool badf(float x) { return (as_type<uint>(x) & 0x7f800000u) == 0x7f800000u; }
static inline bool bad2(float2 v) { return badf(v.x) || badf(v.y); }
static inline bool bad4(float4 v) { return badf(v.x) || badf(v.y) || badf(v.z) || badf(v.w); }

// ------------------------------------------------------------------------------------------------
// particle.inc.wgsl / simConstants.inc.wgsl / random.inc.wgsl
static inline bool periodicX(constant PBSimConstants& c) { return (c.simFlags & PB_SIM_PERIODIC_X) != 0u; }
static inline bool periodicY(constant PBSimConstants& c) { return (c.simFlags & PB_SIM_PERIODIC_Y) != 0u; }
static inline int wrapIndex(int i, int n) { int r = i % n; return r < 0 ? r + n : r; }
static inline float wrapCoord(float x, float n) {
    float r = x - floor(x / n) * n;
    return (r >= n || r < 0.0f) ? 0.0f : r;
}
static inline float2 projectInsideGuardian(float2 p, uint2 gridSize, float guardian) {
    return clamp(p, float2(guardian), float2(gridSize) - float2(guardian) - float2(1));
}
// Particles: walled axes are clamped into the guardian band, periodic axes wrap.
static inline float2 confine(float2 p, constant PBSimConstants& c) {
    float2 q = projectInsideGuardian(p, c.gridSize, float(PB_GUARDIAN));
    if (periodicX(c)) q.x = wrapCoord(p.x, float(c.gridSize.x));
    if (periodicY(c)) q.y = wrapCoord(p.y, float(c.gridSize.y));
    return q;
}
struct QuadWeights { float2 w[3]; int2 base; };
static inline QuadWeights quadraticWeightInit(float2 position) {
    float2 down = floor(position);
    float2 o = (position - down) - 0.5f;
    QuadWeights q;
    q.w[0] = 0.5f * (0.5f - o) * (0.5f - o);
    q.w[1] = 0.75f - o * o;
    q.w[2] = 0.5f * (0.5f + o) * (0.5f + o);
    q.base = int2(down) - 1;
    return q;
}
static inline uint gridIndex(uint2 v, uint2 gridSize) { return v.y * gridSize.x + v.x; }   // one int4 per node
static inline float decodeFixed(int v) { return float(v) * (1.0f / PB_FIXED_SCALE); }
static inline int encodeFixed(float x, thread bool& clampedFlag) {
    float c = clamp(x, -PB_FIXED_LIMIT, PB_FIXED_LIMIT);
    clampedFlag = clampedFlag || (c != x) || badf(x);
    return badf(x) ? 0 : int(rint(c * PB_FIXED_SCALE));
}
static inline uint hashU(uint input) {   // random.inc.wgsl (PCG-style)
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
// Bukkit from the integer cell (upstream bukkit.inc.wgsl:12-15 divides the float position, which under fast math can
// put a particle 1 ulp below a bukkit edge into the next bukkit, moving its stencil outside the tile).
static inline bool particleBukkit(float2 position, constant PBSimConstants& c, thread uint& index) {
    int2 b = int2(floor(position)) / PB_BUKKIT_SIZE;
    if (any(b < int2(0)) || uint(b.x) >= c.bukkitCount.x || uint(b.y) >= c.bukkitCount.y) return false;
    index = uint(b.y) * c.bukkitCount.x + uint(b.x);
    return true;
}

// ------------------------------------------------------------------------------------------------
// shapes.inc.wgsl, generalised to signed distances. normal points INTO the collider (upstream convention).
struct CollideResult { bool collides; float penetration; float2 normal; float2 pointOnCollider; };

static inline CollideResult collide(constant PBShape& s, float2 pos, float inflate = 0.0f) {
    float2 o = pos - s.position;
    float cr = cos(s.rotation), sr = sin(s.rotation);
    float2 lo = float2(cr * o.x + sr * o.y, -sr * o.x + cr * o.y);     // world -> shape frame
    float sd;
    float2 nl;                                                          // outward normal, shape frame
    if (s.shapeType == PB_SHAPE_CIRCLE) {
        float l = length(lo);
        nl = l > 1e-6f ? lo / l : float2(0, 1);
        sd = l - s.radius;
    } else if (s.shapeType == PB_SHAPE_CAPSULE) {
        float t = clamp(lo.x, -s.halfSize.x, s.halfSize.x);
        float2 dl = lo - float2(t, 0);
        float l = length(dl);
        nl = l > 1e-6f ? dl / l : float2(0, lo.y < 0 ? -1.0f : 1.0f);
        sd = l - s.radius;
    } else {                                                            // (rounded) box
        float2 sg = float2(lo.x < 0 ? -1.0f : 1.0f, lo.y < 0 ? -1.0f : 1.0f);
        float2 q = abs(lo) - s.halfSize;
        float2 qo = max(q, float2(0));
        float outside = length(qo);
        if (outside > 0) { nl = qo / outside * sg; sd = outside - s.radius; }
        else { nl = q.x > q.y ? float2(sg.x, 0) : float2(0, sg.y); sd = max(q.x, q.y) - s.radius; }
    }
    sd -= inflate;
    float2 n = float2(cr * nl.x - sr * nl.y, sr * nl.x + cr * nl.y);   // shape -> world
    CollideResult r;
    r.collides = sd < 0.0f;
    r.penetration = -sd;
    r.normal = -n;
    r.pointOnCollider = pos - sd * n;
    return r;
}
static inline float2 shapeVelocityAt(constant PBShape& s, float2 p) {          // cells per substep
    float2 rr = p - s.position;
    return s.velocity + s.angularVelocity * float2(-rr.y, rr.x);
}
// Grid-level collider response (after upstream g2p2g.wgsl:77-100) in the collider's frame of motion, plus Coulomb
// friction. A node whose displaced position would be inside the body loses the normal relative motion INTO the body.
// Upstream also pushed nodes that already lie inside back to the surface every pass (its `gap` term); that adds a
// repulsion layer whose strength depends on where a face falls between nodes, and biased buoyancy by -50 % to +200 %
// at Δx 1.1-2 mm in this port (LabKit VERIFICATION-GPU.md). Particles inside are still pushed out in pbIntegrate.
static inline float2 applyCollider(constant PBShape& s, float2 gp, float2 d, bool upstreamGap, float skin,
                                   thread bool& touched) {
    float2 u = shapeVelocityAt(s, gp);
    float2 rel = d - u;
    CollideResult r = collide(s, gp + rel, skin);
    touched = touched || r.collides;
    if (r.collides) {
        float gap = upstreamGap ? min(0.0f, dot(r.normal, r.pointOnCollider - gp)) : 0.0f;
        float pen = dot(r.normal, rel) - gap;
        if (pen > 0.0f) {
            rel -= pen * r.normal;
            float2 t = rel - dot(rel, r.normal) * r.normal;
            float tl = length(t);
            if (tl > 0.0f) rel -= t * min(1.0f, s.friction * pen / tl);
        }
        d = rel + u;
    }
    return d;
}

// Grid update for one node: momentum / mass, colliders, verification forcing (last pass only), guardian walls.
// `node` is the tile's (unwrapped) node coordinate; periodic axes have no guardian.
struct NodeState { float4 g; float2 bodyDelta; uint bodyShape; bool nearOverflow; bool nearCollider; };
static inline NodeState gridNodeUpdate(int4 raw, int2 node, constant PBSimConstants& c, constant PBShape* shapes) {
    NodeState s;
    s.nearOverflow = any(abs(raw) > int4(PB_NEAR_OVERFLOW));
    float mass = decodeFixed(raw.z);
    float vol = decodeFixed(raw.w);
    float2 d = mass < 1e-5f ? float2(0) : float2(decodeFixed(raw.x), decodeFixed(raw.y)) / mass;
    float2 gp = float2(node) + 0.5f;
    s.bodyDelta = float2(0);
    s.bodyShape = PB_NO_SHAPE;
    s.nearCollider = false;
    if (mass >= 1e-5f) {
        if (c.forcing.x != 0.0f && c.iteration == c.iterationCount)
            d.x += c.forcing.x * sin(c.forcing.y * (gp.y - c.forcing.z));
        for (uint i = 0; i < c.shapeCount; ++i) {
            if (shapes[i].functionality != PB_FN_COLLIDER) continue;
            float2 after = applyCollider(shapes[i], gp, d, (c.debugFlags & PB_DEBUG_COLLIDER_GAP) != 0u, c.colliderSkin,
                                         s.nearCollider);
            if (shapes[i].bodyIndex >= 0 && any(after != d)) { s.bodyDelta += after - d; s.bodyShape = i; }
            d = after;
        }
    }
    // Guardian (upstream main g2p2g.wgsl:102-122: positions without the +0.5, bounds GuardianSize + 1)
    float2 displaced = float2(node) + d;
    float2 diff = projectInsideGuardian(displaced, c.gridSize, float(PB_GUARDIAN + 1)) - displaced;
    if (periodicX(c)) diff.x = 0.0f;
    if (periodicY(c)) diff.y = 0.0f;
    if (diff.x != 0.0f) { d.x = 0.0f; d.y = mix(d.y, 0.0f, c.borderFriction); }
    if (diff.y != 0.0f) { d.y = 0.0f; d.x = mix(d.x, 0.0f, c.borderFriction); }
    s.g = float4(d, mass, vol);
    return s;
}

// ------------------------------------------------------------------------------------------------
// The unified EVP model (rheology-models.md §4.2-4.4, Appendix A), float32. SI throughout.
struct RheoState { float b11, b12, b22, J, lam, f, T, gdotP; };
struct RheoLaw { float phi0, ty, k, n, invn, tf, phif, sj; };

static inline RheoState stateOf(thread const PBParticle& p) {
    RheoState s;
    s.b11 = p.elastic.x; s.b12 = p.elastic.y; s.b22 = p.elastic.z; s.gdotP = p.elastic.w;
    s.J = p.liquidDensity; s.lam = p.structure; s.f = p.contact; s.T = p.temperature;
    return s;
}
// Arrhenius shift factor a_T = exp[(E_a/R)(1/T − 1/T_ref)] ≤ 1e4, with T limited to the band [T_ref − below, T_ref +
// above] (40 / 80 K, rheology-models.md §4.8, unless the material widens the cold side; LabKitMPMReference
// EVP.clampedTemperature). The particle keeps its true temperature for rendering and cooling; only the flow law sees
// the clamped value (the oracle writes the clamped value back).
static inline float bandTemperature(float T, constant PBMaterial& m) {
    return clamp(T, m.refTemperature - m.bandBelow, m.refTemperature + m.bandAbove);
}
static inline float shiftFactor(float eaOverR, float T, constant PBMaterial& m) {
    if (eaOverR <= 0.0f) return 1.0f;
    return min(exp(min(eaOverR * (1.0f / bandTemperature(T, m) - 1.0f / m.refTemperature), 9.2103404f)), 1e4f);
}
// Carlson MR yield τ_field = min(τ_sat·tanh(|H|/H_sat), clamp·G), after the magnetometer dead zone.
static inline float fieldYield(constant PBMaterial& m, float Hmag, float scale = 1.0f) {
    if (m.fieldScale <= 0.0f) return 0.0f;
    float H = max(Hmag - m.fieldDeadZone, 0.0f);
    return min(scale * m.fieldScale * tanh(min(m.fieldK * H, 12.0f)), m.fieldClampFracG * m.shearModulus);
}
// Effective branch parameters for the current (λ, f, T, H): §4.2 modulators (a)-(d).
static inline RheoLaw rheoLaw(constant PBMaterial& m, float lam, float f, float T, float Hmag, float fieldYieldScale = 1.0f) {
    RheoLaw L;
    float aT = shiftFactor(m.eaOverR, T, m);
    float aTy = shiftFactor(m.eaYieldOverR, T, m);
    float tField = fieldYield(m, Hmag, fieldYieldScale);
    if (m.dst != 0u) {
        float phiJ = f * m.phiM + (1.0f - f) * m.phi0;
        float gap = 1.0f - m.phi / phiJ;
        float sj = smoothstep(0.0f, 1.0f, (m.gapFloor - gap) / m.blendWidth);
        float gm = max(gap, m.gapFloor);
        float etaFluid = aT * m.solventViscosity / (gm * gm);
        float eta = mix(etaFluid, m.shearModulus * m.jamTime, sj);
        L.phi0 = 1.0f / eta; L.ty = tField; L.k = 0.0f; L.n = 1.0f; L.invn = 1.0f;
        L.tf = sj > 0.0f ? m.jamFailureStress : 1e30f; L.phif = sj / m.postFailureViscosity; L.sj = sj;
    } else {
        float lm = lam > 0.0f ? powr(lam, m.structureExponent) : 0.0f;
        L.ty = aTy * (m.yieldBroken + m.yieldStructure * lm) + tField;
        L.k = aT * m.consistency * (1.0f + m.consistencyStructure * lm);
        L.n = m.flowIndex; L.invn = 1.0f / m.flowIndex;
        L.phi0 = m.fluidity / aT; L.tf = m.failureStress; L.phif = m.failureFluidity; L.sj = 0.0f;
    }
    return L;
}
// γ̇p(t) = φ0·t + ((t − τy)₊/k)^(1/n) + φf·(t − τf)₊   (Eq. 4.1; monotone, convex for n ≤ 1)
static inline float rheoFlow(float t, RheoLaw L) {
    float a = L.phi0 * t;
    if (L.k > 0.0f && t > L.ty) a += powr((t - L.ty) / L.k, L.invn);
    if (t > L.tf) a += L.phif * (t - L.tf);
    return a;
}
static inline float rheoDFlow(float t, RheoLaw L) {
    float d = L.phi0;
    if (L.k > 0.0f && t > L.ty) d += L.invn / L.k * powr((t - L.ty) / L.k, L.invn - 1.0f);
    if (t > L.tf) d += L.phif;
    return d;
}

// One particle's constitutive update over a substep with B = dt·∇v (Appendix A `rheo_update`, line for line, with the
// §4.8 det guard). Writes the state, returns the Kirchhoff stress (t11, t12, t22).
static inline float3 rheoUpdate(thread RheoState& s, float2x2 B, float dt, constant PBMaterial& m, float Hmag,
                                thread bool& guarded, float fieldYieldScale = 1.0f) {
    const float G = m.shearModulus;
    // 0. start-of-step equivalent shear stress (lagged driver for the DST contact fraction)
    float dn = 0.5f * (s.b11 - s.b22);
    float tauN = G * sqrt(dn * dn + s.b12 * s.b12);

    // 1. kinematics: f = I + B, J *= det f, fbar = f / sqrt(det f). B[col][row]: c12 = dvx/dy = B[1][0].
    float f11 = 1.0f + B[0][0], f12 = B[1][0], f21 = B[0][1], f22 = 1.0f + B[1][1];
    float detf = f11 * f22 - f12 * f21;
    if (!(detf >= 0.05f)) {                       // CFL breach: rescale B so det(I + sB) = 0.05 (bisection; rare)
        guarded = true;
        float lo = 0.0f, hi = 1.0f;
        for (int i = 0; i < 24; ++i) {
            float sc = 0.5f * (lo + hi);
            float g11 = 1.0f + sc * B[0][0], g22 = 1.0f + sc * B[1][1];
            float dg = g11 * g22 - sc * sc * B[1][0] * B[0][1];
            if (dg > 0.05f) lo = sc; else hi = sc;
        }
        B *= lo;
        f11 = 1.0f + B[0][0]; f12 = B[1][0]; f21 = B[0][1]; f22 = 1.0f + B[1][1];
        detf = max(f11 * f22 - f12 * f21, 0.05f);
    }
    s.J *= detf;
    float r = rsqrt(detf);
    f11 *= r; f12 *= r; f21 *= r; f22 *= r;
    float t11 = f11 * s.b11 + f12 * s.b12, t12 = f11 * s.b12 + f12 * s.b22;
    float t21 = f21 * s.b11 + f22 * s.b12, t22 = f21 * s.b12 + f22 * s.b22;
    float n11 = t11 * f11 + t12 * f12;
    float n12 = t11 * f21 + t12 * f22;
    float n22 = t21 * f21 + t22 * f22;
    float q = rsqrt(n11 * n22 - n12 * n12);
    n11 *= q; n12 *= q; n22 *= q;
    float tr = n11 + n22;
    float d11 = 0.5f * (n11 - n22);
    float tauTr = G * sqrt(d11 * d11 + n12 * n12);       // = ||dev tau||_F / sqrt(2)
    float mdt = G * 0.5f * tr * dt;                        // mu_tilde * dt
    float Dd = B[0][0] - B[1][1], Do = B[1][0] + B[0][1];
    float gTot = sqrt(Dd * Dd + Do * Do) / dt;             // sqrt(2)*||dev D||_F

    // 2-3. modulators and the effective flow law (DST contact fraction first, lagged on tauN)
    if (m.dst != 0u) {
        // df/dt = (γ̇/γ*)(f_ss − f) + (1/t_melt)((1 − w_rest)·f_ss − f), implicit; w_rest = 0 is the lagged-f law.
        // γ̇ is the total rate, or (onsetForm bit 1) the plastic rate of the previous update.
        float cs = (((m.onsetForm & 2u) != 0u) ? s.gdotP : gTot) / m.gammaStar, cm = 1.0f / m.meltTime;
        float cr = cs + cm;
        float fss = ((m.onsetForm & 1u) == 0u) ? (1.0f - exp(-tauN / m.sigmaStar)) : exp(-m.sigmaStar / max(tauN, 1e-6f));
        float ct = cr - cm * m.restMelt;                                 // rate toward f_ss
        s.f += dt * (ct * fss - cr * s.f) / (1.0f + cr * dt);         // = (f + c_t·dt·f_ss)/(1 + c·dt), incremental (float32)
    }
    RheoLaw L = rheoLaw(m, s.lam, s.f, s.T, Hmag, fieldYieldScale);

    // 4. return map on the scalar equation t = tauTr - mdt * gdot_p(t)
    float tNew = tauTr;
    float gP = 0.0f;
    bool flows = (L.phi0 > 0.0f) || (L.k > 0.0f && tauTr > L.ty) || (tauTr > L.tf);
    if (flows && tauTr > 0.0f && mdt > 0.0f) {
        float t0 = tauTr;                                               // every single-branch root is right of the joint root
        if (L.phi0 > 0.0f) t0 = min(t0, tauTr / (1.0f + mdt * L.phi0));
        if (L.k > 0.0f && tauTr > L.ty) { float X = tauTr - L.ty; t0 = min(t0, L.ty + min(X, L.k * powr(X / mdt, L.n))); }
        if (tauTr > L.tf) t0 = min(t0, max(L.tf, (tauTr + mdt * L.phif * L.tf) / (1.0f + mdt * L.phif)));
        float t = t0;
        for (int it = 0; it < 5; ++it) {                               // 4-5 iterations reach float32 precision
            float res = t - tauTr + mdt * rheoFlow(t, L);
            float dres = 1.0f + mdt * rheoDFlow(t, L);
            t = max(t - res / dres, 0.0f);
        }
        tNew = t;
        gP = (tauTr - tNew) / mdt;
        float sc = tNew / tauTr;
        d11 *= sc; n12 *= sc;
        n11 = d11 + 0.5f * tr; n22 = -d11 + 0.5f * tr;
        q = rsqrt(n11 * n22 - n12 * n12);
        n11 *= q; n12 *= q; n22 *= q;
        if (m.dst != 0u && tNew > L.tf) s.f /= (1.0f + dt * L.phif * (tNew - L.tf) / m.breakStrain);
    }
    s.b11 = n11; s.b12 = n12; s.b22 = n22;
    s.gdotP = gP;

    // 5. thixotropic structure (implicit, unconditionally stable)
    float gs = mix(gP, gTot, m.vibrationWeight);
    float A = m.buildRate + m.buildShear * gs, Bk = m.breakRate + m.breakShear * gs;
    s.lam += (A * dt * (1.0f - s.lam) - Bk * dt * s.lam) / (1.0f + (A + Bk) * dt);   // = (λ + A·dt)/(1 + (A + B)·dt)
    s.lam = clamp(s.lam, 0.0f, 1.0f);
    s.f = clamp(s.f, 0.0f, 1.0f);

    // 6. volumetric Kirchhoff part with tensile cap
    s.J = clamp(s.J, m.jMin, m.jMax);
    float tvol = 0.5f * m.bulkModulus * (s.J * s.J - 1.0f);
    if (m.bulkModulus > 0.0f && tvol > s.J * m.tensionLimit) {
        s.J = (m.tensionLimit + sqrt(m.tensionLimit * m.tensionLimit + m.bulkModulus * m.bulkModulus)) / m.bulkModulus;
        tvol = 0.5f * m.bulkModulus * (s.J * s.J - 1.0f);
    }
    float h = 0.5f * (s.b11 + s.b22);
    return float3(G * (s.b11 - h) + tvol, G * s.b12, G * (s.b22 - h) + tvol);
}

// Local |H| (A/m) and ∇|H| (A/m per m): uniform field + virtual dipole-like magnet H0·(r0/r)³.
static inline float magnetField(constant PBSimConstants& c, float2 pos, thread float2& gradH) {
    float H = c.field.z;
    gradH = float2(0);
    if (c.magnet.z > 0.0f) {
        float2 r = pos - c.magnet.xy;                               // cells
        float rl = max(length(r), c.magnet.w);
        float Hm = c.magnet.z * powr(c.magnet.w / rl, 3.0f);
        H += Hm;
        gradH = -3.0f * Hm / (rl * c.dx) * (r / max(length(r), 1e-6f));   // points toward the magnet
    }
    return H;
}

// Kelvin body force a = μ0·χ·|H|·∇|H|/ρ of the virtual magnet, capped at PB_KELVIN_CAP (3 g, rheology-models.md §4.8)
// so the substeps stay affordable. The magnet's field is radial, so the capped force is still the gradient of a
// potential (Φ = μ0χH²/2ρ outside the radius r_c where the force reaches the cap, Φ(r_c) + cap·(r_c − r) inside): a
// free surface still heaps over the magnet. Near the magnet the true force is up to ~2,000 g (207 mT at 1 cm), so the
// cap weakens the drive there by the factor s = cap/a. The field-induced yield stress is scaled by the same s before
// the toy clamp: the ratio of magnetic drive to magnetic yield, which decides whether MR fluid flows to the magnet and
// heaps or holds still, stays physical. Without it the capped drive (≤ 3 g, about 900 Pa over a centimetre) never beat
// the clamped yield (1.5 kPa) and MR fluid froze flat, dipping over the magnet (LK-FIX, measured).
#define PB_KELVIN_CAP 29.43f
static inline float2 kelvinAcceleration(constant PBMaterial& m, float Hmag, float2 gradH, thread float& yieldScale) {
    float2 acc = (4e-7f * M_PI_F * m.susceptibility * Hmag / m.density) * gradH;
    float al = length(acc);
    yieldScale = al > PB_KELVIN_CAP ? PB_KELVIN_CAP / al : 1.0f;
    return acc * yieldScale;
}
static inline float kelvinYieldScale(constant PBMaterial& m, constant PBSimConstants& c, float Hmag, float2 gradH) {
    if (m.susceptibility <= 0.0f || c.magnet.z <= 0.0f || (c.debugFlags & PB_DEBUG_NO_KELVIN_YIELD) != 0u) return 1.0f;
    float scale;
    (void)kelvinAcceleration(m, Hmag, gradH, scale);
    return scale;
}

// ------------------------------------------------------------------------------------------------
// Constraint solve (upstream particleUpdatePBMPM.wgsl / g2p2g.wgsl:365-424, replaced for EVP by the XPBD-EVP step of
// rheology-models.md §4.10.3 / Appendix C). Updates the particle's iteration scratch; returns B to scatter.
static inline float2x2 pbConstrain(thread PBParticle& p, constant PBMaterial& m, constant PBSimConstants& c, float Hmag,
                                   float fieldYieldScale) {
    float2x2 B = p.deformationDisplacement;
    if (m.model == PB_MODEL_LIQUID) {
        // Native PB relaxation viscosity in SI (V13): r = min(1, 8 mu dt / (rho k dx^2)), deviatoric part only.
        float r = min(1.0f, 8.0f * m.nativeViscosity * c.dt / (m.density * float(c.iterationCount) * c.dx * c.dx));
        float e11 = 0.5f * (B[0][0] - B[1][1]);
        float e12 = 0.5f * (B[1][0] + B[0][1]);
        B -= r * float2x2(float2(e11, e12), float2(e12, -e11));
        float alpha = 0.5f * (1.0f / p.liquidDensity - tr2(B) - 1.0f);
        B += m.liquidRelaxation * alpha * kIdentity;
        return B;
    }
    const float G = m.shearModulus;
    const float kappa = 4.0f * c.dt * c.dt / (m.density * c.dx * c.dx);       // 1/Pa: B -= kappa * tau
    float4 it = p.iterate;
    if (c.iteration == 0u)                                                    // warm start a = beta * s(S_n)
        it = float4(c.beta * G * 0.5f * (p.elastic.x - p.elastic.z), c.beta * G * p.elastic.y, 0.0f, 0.0f);
    if (c.omega > 0.0f) {
        RheoState s = stateOf(p);                                             // evaluated on a copy: no state write
        bool guarded = false;
        float3 t = rheoUpdate(s, B, c.dt, m, Hmag, guarded, fieldYieldScale);
        float d = 0.5f * (t.x - t.z), sxy = t.y;
        float tb = sqrt(d * d + sxy * sxy);
        float mdt = G * 0.5f * (s.b11 + s.b22) * c.dt;
        float tbTr = tb + mdt * s.gdotP;                                      // trial stress recovered from gdot_p
        float theta = tbTr > 0.0f ? tb / tbTr : 1.0f;                         // secant <= 1 (>= tangent): conservative
        float w = c.omega / (1.0f + kappa * 2.0f * G * theta);
        it.x += w * (d - it.x);
        it.y += w * (sxy - it.y);
    }
    float d11 = it.x - it.z, d12 = it.y - it.w;
    it.z = it.x; it.w = it.y;
    p.iterate = it;
    B += float2x2(float2(-kappa * d11, -kappa * d12), float2(-kappa * d12, kappa * d11));
    if ((c.simFlags & PB_SIM_EXPLICIT) != 0u) {
        if (c.iteration == 0u) {                                              // volumetric stress, warm-started (oracle)
            float J = p.liquidDensity;
            B -= kappa * 0.5f * m.bulkModulus * (J * J - 1.0f) * kIdentity;
        }
    } else {                                                                  // PB-MPM cold volume constraint
        float alpha = 0.5f * (1.0f / p.liquidDensity - tr2(B) - 1.0f);
        B += m.liquidRelaxation * alpha * kIdentity;
    }
    return B;
}

// ------------------------------------------------------------------------------------------------
// Per-particle body impulse accumulator (impulse ON the shape, grid mass * cells per substep; torque about shape.position).
struct BodyAccum { uint shape; float3 J; uint shape2; float3 J2; };
static inline void bodyAdd(thread BodyAccum& a, uint shape, float2 J, float2 arm) {
    float3 v = float3(J, arm.x * J.y - arm.y * J.x);
    if (a.shape == PB_NO_SHAPE || a.shape == shape) { a.shape = shape; a.J += v; }
    else if (a.shape2 == PB_NO_SHAPE || a.shape2 == shape) { a.shape2 = shape; a.J2 += v; }
    // a third shape on one particle is dropped (never seen in practice)
}

// Thin-tank (Hele-Shaw) decay time t_HS = rho b^2 / (12 mu_HS), gap-averaged power law + wall-slip yield (§4.10.5).
static inline float heleShawTime(RheoLaw L, constant PBMaterial& m, float speed, float b, float tMin) {
    float U = max(speed, 1e-4f);
    float mu = L.phi0 > 0.0f ? 1.0f / L.phi0 : 0.0f;
    if (L.k > 0.0f) {
        float n = L.n;
        float gw = 2.0f * (2.0f * n + 1.0f) * U / (n * b);
        mu += (2.0f * n + 1.0f) / (3.0f * n) * L.k * powr(gw, n - 1.0f);
    }
    mu += m.wallYieldFactor * L.ty * b / (4.0f * U);
    float t = mu > 0.0f ? m.density * b * b / (12.0f * mu) : 1e30f;
    return max(t, tMin);
}

// Integration (upstream particleIntegrate.wgsl / g2p2g.wgsl:207-356): commit the EVP state, then move and apply body
// forces and guards.
static inline void pbIntegrate(thread PBParticle& p, uint index, constant PBMaterial& m, constant PBSimConstants& c,
                               constant PBShape* shapes, device PBCountersAtomic& counters, device uint* freeIndices,
                               thread BodyAccum& body, float gridFill, float Hmag, float2 gradH, float fieldYieldScale) {
    float2x2 B = p.deformationDisplacement;
    float Dd = B[0][0] - B[1][1], Do = B[1][0] + B[0][1];
    p.shearRate = sqrt(Dd * Dd + Do * Do) / c.dt;
    RheoLaw L;
    if (m.model == PB_MODEL_EVP) {
        RheoState s = stateOf(p);
        bool guarded = false;
        float3 t = rheoUpdate(s, B, c.dt, m, Hmag, guarded, fieldYieldScale);
        if (guarded) atomic_fetch_add_explicit(&counters.detClamps, 1u, memory_order_relaxed);
        p.elastic = float4(s.b11, s.b12, s.b22, s.gdotP);
        p.liquidDensity = s.J; p.structure = s.lam; p.contact = s.f;
        float dd = 0.5f * (t.x - t.z);
        float tb = sqrt(dd * dd + t.y * t.y);
        p.stress = tb;
        p.viscosity = s.gdotP > 1e-6f ? min(tb / s.gdotP, 1e30f) : 1e30f;
        L = rheoLaw(m, p.structure, p.contact, p.temperature, Hmag, fieldYieldScale);
    } else {
        p.liquidDensity = max(p.liquidDensity * (tr2(B) + 1.0f), 0.05f);
        p.viscosity = max(m.nativeViscosity, 1e-6f);
        p.stress = p.viscosity * p.shearRate;
        L.phi0 = 1.0f / p.viscosity; L.ty = 0.0f; L.k = 0.0f; L.n = 1.0f; L.invn = 1.0f; L.tf = 1e30f; L.phif = 0.0f; L.sj = 0.0f;
    }
    if (c.thermalTime > 0.0f) {
        float rate = (1.0f + c.surfaceCooling * (1.0f - saturate(gridFill))) / c.thermalTime;
        p.temperature = mix(p.temperature, c.ambientTemperature, 1.0f - exp(-c.dt * rate));
    }

    // Integrate position, then add the next substep's gravity kick (upstream order: x += d; d += g)
    p.position += p.displacement;
    p.displacement += c.gravity;
    if (m.susceptibility > 0.0f && c.magnet.z > 0.0f) {                       // Kelvin force, capped at 3 g (see above)
        float unused;
        p.displacement += kelvinAcceleration(m, Hmag, gradH, unused) * c.dt * c.dt / c.dx;
    }
    if (c.heleShawGap > 0.0f) {
        float speed = length(p.displacement) * c.dx / c.dt;
        float tHS = heleShawTime(L, m, speed, c.heleShawGap, c.heleShawMinTime);
        p.displacement /= 1.0f + c.dt / tHS;
    }

    // Free count may be negative because of emission (upstream)
    atomic_fetch_max_explicit(&counters.freeCount, 0, memory_order_relaxed);
    for (uint i = 0; i < c.shapeCount; ++i) {
        constant PBShape& s = shapes[i];
        if (s.functionality == PB_FN_COLLIDER) {
            CollideResult r = collide(s, p.position);
            if (r.collides) {
                float2 push = -r.penetration * r.normal;
                p.displacement += push;
                if (s.bodyIndex >= 0 && (c.debugFlags & PB_DEBUG_NO_PUSH_IMPULSE) == 0u)
                    bodyAdd(body, i, -p.mass * push, p.position - s.position);
            }
        } else if (s.functionality == PB_FN_GRIP) {
            // Held paste (a tube's bore): moves with the shape; the impulse to hold it is the shape's.
            if (collide(s, p.position).collides) {
                float2 held = shapeVelocityAt(s, p.position);
                if (s.bodyIndex >= 0) bodyAdd(body, i, -p.mass * (held - p.displacement), p.position - s.position);
                p.displacement = held;
            }
        } else if (s.functionality == PB_FN_DRAIN) {
            if (collide(s, p.position).collides && (p.flags & PB_FLAG_ENABLED)) {
                p.flags &= ~PB_FLAG_ENABLED;
                int freeIndex = atomic_fetch_add_explicit(&counters.freeCount, 1, memory_order_relaxed);
                freeIndices[uint(freeIndex)] = index;
                atomic_fetch_add_explicit(&counters.drained, 1u, memory_order_relaxed);
            }
        }
    }
    p.position = confine(p.position, c);

    // Guards: CFL clamp and NaN reset
    float dl = length(p.displacement);
    if (dl > c.maxDisplacement) {
        p.displacement *= c.maxDisplacement / dl;
        atomic_fetch_add_explicit(&counters.clamped, 1u, memory_order_relaxed);
    }
    bool bad = bad2(p.displacement) || bad2(p.position) || bad4(p.elastic) || badf(p.liquidDensity)
            || bad2(p.deformationDisplacement[0]) || bad2(p.deformationDisplacement[1]);
    if (bad) {
        p.displacement = float2(0);
        p.elastic = float4(1, 0, 1, 0);
        p.iterate = float4(0);
        p.deformationDisplacement = float2x2(0);
        p.liquidDensity = 1.0f;
        p.viscosity = 1e30f;
        p.stress = 0.0f;
        p.shearRate = 0.0f;
        p.position = confine(select(p.position, float2(c.gridSize) * 0.5f, bool2(badf(p.position.x), badf(p.position.y))), c);
        atomic_fetch_add_explicit(&counters.nanResets, 1u, memory_order_relaxed);
    }
}

// G2P result (upstream gridToParticle.wgsl / g2p2g.wgsl:146-204) with the grid-volume J correction.
// Upstream relaxes J toward the grid's volume ratio 1/ρ̃ only where the grid is over-filled (compressed). A particle
// whose J fell below 1 on landing (a pour, a splash) and which sits among gaps (under-filled grid) kept that
// compression, and its pressure held the gaps open: poured honey stood as a particle foam 1.2–1.3 × its volume. Here an
// under-filled particle also gives up compression beyond `underfillTolerance` gravity kicks (|g|·dt²/Δx ≈ the PB
// pressure deficit of ⅔ of a cell of liquid), which a free surface's top cell needs to carry itself; with less, the top
// rows creep into the bulk. Next to a collider the fill is low for want of fluid inside the body, so it is left alone.
static inline void g2pFinish(thread PBParticle& p, float2x2 Bsum, float2 d, float volume, bool nearCollider,
                             constant PBSimConstants& c) {
    if (c.useGridVolume != 0u && (c.simFlags & PB_SIM_EXPLICIT) == 0u && volume > 0.0f) {
        float v = 1.0f / volume;
        if (v < 1.0f) p.liquidDensity = mix(p.liquidDensity, v, c.gridVolumeMix);
        else if (!nearCollider && (c.debugFlags & PB_DEBUG_ONE_SIDED_J) == 0u) {
            float floorJ = 1.0f - c.underfillTolerance * length(c.gravity);
            if (p.liquidDensity < floorJ) p.liquidDensity = mix(p.liquidDensity, floorJ, c.gridVolumeMix);
        }
    }
    p.deformationDisplacement = Bsum * 4.0f;     // 4 = 1 / D_p for quadratic B-splines in cell units
    p.displacement = d;
}

// Flush one per-particle body accumulator into threadgroup int atomics. SIMD path: reduce in float per SIMD-group
// first (all threads take part: uniform control flow). Fallback: per-thread atomics at the finer 2^22 scale.
static inline void bodyReduceToThreadgroup(uint shape, float3 J, threadgroup atomic_int* sImp, device PBCountersAtomic& counters) {
    if (kUseSimd) {
        bool pending = shape != PB_NO_SHAPE;
        while (simd_any(pending)) {
            if (pending) {
                uint leader = simd_broadcast_first(shape);
                if (shape == leader) {
                    float3 s = simd_sum(J);
                    uint cnt = simd_sum(1u);
                    if (simd_is_first()) {
                        float3 cl = clamp(s, float3(-1000.0f), float3(1000.0f));
                        if (any(cl != s)) atomic_fetch_add_explicit(&counters.impulseOverflow, 1u, memory_order_relaxed);
                        atomic_fetch_add_explicit(&sImp[leader * 4 + 0], int(rint(cl.x * PB_IMPULSE_SCALE)), memory_order_relaxed);
                        atomic_fetch_add_explicit(&sImp[leader * 4 + 1], int(rint(cl.y * PB_IMPULSE_SCALE)), memory_order_relaxed);
                        atomic_fetch_add_explicit(&sImp[leader * 4 + 2], int(rint(cl.z * PB_IMPULSE_SCALE)), memory_order_relaxed);
                        atomic_fetch_add_explicit(&sImp[leader * 4 + 3], int(cnt), memory_order_relaxed);
                    }
                    pending = false;
                }
            }
        }
    } else if (shape != PB_NO_SHAPE) {
        float3 cl = clamp(J, float3(-8.0f), float3(8.0f));
        if (any(cl != J)) atomic_fetch_add_explicit(&counters.impulseOverflow, 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&sImp[shape * 4 + 0], int(rint(cl.x * PB_IMPULSE_FINE_SCALE)), memory_order_relaxed);
        atomic_fetch_add_explicit(&sImp[shape * 4 + 1], int(rint(cl.y * PB_IMPULSE_FINE_SCALE)), memory_order_relaxed);
        atomic_fetch_add_explicit(&sImp[shape * 4 + 2], int(rint(cl.z * PB_IMPULSE_FINE_SCALE)), memory_order_relaxed);
        atomic_fetch_add_explicit(&sImp[shape * 4 + 3], 1, memory_order_relaxed);
    }
}

// ================================================================================================
// Housekeeping and binning (upstream main: setIndirectArgs, bukkitCount/Allocate/Insert), merged:
//   the last solver pass counts particles per bukkit (pbBukkitCount only re-bins after the CPU injected or cleared),
//   pbBukkitAllocate also zeroes the counts, the insert counters and the grid the last pass read,
//   and writes the particle dispatch and draw args; pbBukkitInsert fills the per-bukkit particle lists.
// ================================================================================================
kernel void pbResetBins(constant PBSimConstants& c [[buffer(0)]],
                        device atomic_uint* bukkitCounts [[buffer(1)]],
                        device PBBukkitDispatchAtomic* dispatch [[buffer(2)]],
                        uint2 id [[thread_position_in_grid]]) {
    if (all(id == uint2(0))) {
        device PBBukkitDispatchAtomic& mine = dispatch[c.bufferParity];
        atomic_store_explicit(&mine.groupsX, 0u, memory_order_relaxed);
        atomic_store_explicit(&mine.particleAllocator, 0u, memory_order_relaxed);
        mine.groupsY = 1; mine.groupsZ = 1;
    }
    if (id.x >= c.bukkitCount.x || id.y >= c.bukkitCount.y) return;
    atomic_store_explicit(&bukkitCounts[id.y * c.bukkitCount.x + id.x], 0u, memory_order_relaxed);
}

kernel void pbBukkitCount(constant PBSimConstants& c [[buffer(0)]],
                          device PBCountersAtomic& counters [[buffer(1)]],
                          device const PBParticle* particles [[buffer(2)]],
                          device atomic_uint* bukkitCounts [[buffer(3)]],
                          uint id [[thread_position_in_grid]]) {
    if (id >= atomic_load_explicit(&counters.particleCount, memory_order_relaxed) || id >= c.particleCapacity) return;
    if ((particles[id].flags & PB_FLAG_ENABLED) == 0u) return;
    uint b;
    if (!particleBukkit(particles[id].position, c, b)) return;
    atomic_fetch_add_explicit(&bukkitCounts[b], 1u, memory_order_relaxed);
}

kernel void pbBukkitAllocate(constant PBSimConstants& c [[buffer(0)]],
                             device atomic_uint* bukkitCounts [[buffer(1)]],
                             device atomic_uint* insertCounters [[buffer(2)]],
                             device PBBukkitDispatchAtomic* dispatch [[buffer(3)]],   // 2 slots
                             device PBBukkitThreadData* threadData [[buffer(4)]],
                             device uint* bukkitIndexStart [[buffer(5)]],
                             device PBCountersAtomic& counters [[buffer(6)]],
                             device int4* gridToClear [[buffer(7)]],
                             uint2 id [[thread_position_in_grid]]) {
    device PBBukkitDispatchAtomic& mine = dispatch[c.bufferParity];
    if (all(id == uint2(0))) {
        // The other slot was last used by the previous substep's passes; zero it for the next allocate.
        device PBBukkitDispatchAtomic& other = dispatch[c.bufferParity ^ 1u];
        atomic_store_explicit(&other.groupsX, 0u, memory_order_relaxed);
        atomic_store_explicit(&other.particleAllocator, 0u, memory_order_relaxed);
        other.groupsY = 1; other.groupsZ = 1;
        uint n = min(atomic_load_explicit(&counters.particleCount, memory_order_relaxed), c.particleCapacity);
        counters.particleDispatch[0] = (n + PB_PARTICLE_GROUP - 1) / PB_PARTICLE_GROUP;
        counters.particleDispatch[1] = 1; counters.particleDispatch[2] = 1;
        counters.drawArgs[0] = 4; counters.drawArgs[1] = n; counters.drawArgs[2] = 0; counters.drawArgs[3] = 0;
    }
    if (id.x >= c.bukkitCount.x || id.y >= c.bukkitCount.y) return;
    // Clear this bukkit's interior nodes of the grid the last pass read (keeps all three grids zero between substeps).
    for (uint y = 0; y < PB_BUKKIT_SIZE; ++y) {
        for (uint x = 0; x < PB_BUKKIT_SIZE; ++x) {
            uint2 node = id * PB_BUKKIT_SIZE + uint2(x, y);
            if (all(node < c.gridSize)) gridToClear[gridIndex(node, c.gridSize)] = int4(0);
        }
    }
    uint b = id.y * c.bukkitCount.x + id.x;
    atomic_store_explicit(&insertCounters[b], 0u, memory_order_relaxed);
    uint count = atomic_exchange_explicit(&bukkitCounts[b], 0u, memory_order_relaxed);
    if (count == 0) return;
    uint groups = (count + PB_TILE_NODES - 1) / PB_TILE_NODES;
    uint residual = count % PB_TILE_NODES;
    uint dispatchStart = atomic_fetch_add_explicit(&mine.groupsX, groups, memory_order_relaxed);
    uint particleStart = atomic_fetch_add_explicit(&mine.particleAllocator, count, memory_order_relaxed);
    bukkitIndexStart[b] = particleStart;
    for (uint i = 0; i < groups; ++i) {
        PBBukkitThreadData t;
        t.rangeStart = particleStart + i * PB_TILE_NODES;
        t.rangeCount = (residual != 0 && i == groups - 1) ? residual : PB_TILE_NODES;
        t.bukkitX = id.x; t.bukkitY = id.y;
        threadData[dispatchStart + i] = t;
    }
}

kernel void pbBukkitInsert(constant PBSimConstants& c [[buffer(0)]],
                           device PBCountersAtomic& counters [[buffer(1)]],
                           device atomic_uint* insertCounters [[buffer(2)]],
                           device const PBParticle* particles [[buffer(3)]],
                           device uint* bukkitParticles [[buffer(4)]],
                           device const uint* bukkitIndexStart [[buffer(5)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= atomic_load_explicit(&counters.particleCount, memory_order_relaxed) || id >= c.particleCapacity) return;
    if ((particles[id].flags & PB_FLAG_ENABLED) == 0u) return;
    uint b;
    if (!particleBukkit(particles[id].position, c, b)) return;
    uint slot = atomic_fetch_add_explicit(&insertCounters[b], 1u, memory_order_relaxed);
    bukkitParticles[bukkitIndexStart[b] + slot] = id;
}

// Mirrored (ghost) grid volume at the tank walls. A wall is a symmetry plane for the fill: mirror images of the
// particles across a plane P (cells) would deposit at node i exactly what the real particles deposit at node 2P − 1 − i.
// Nodes within reach of a wall add that, so fluid resting on the floor or against a wall reads ρ̃ ≈ 1 there instead of
// a free surface's 0.66 / 0.87 / 0.96 in its first three particle rows. Planes: the left wall and floor at the tank
// edge (cell PB_WALL_OFFSET); the right wall and lid ½ cell outside the tank edge, where upstream's guardian test (node
// index without the +0.5) actually stops the fluid (measured: water reaches 0.2–0.3 cell past the right edge). With the
// right plane on the edge, particles past it were counted twice, and the doubled fill kept a resting pool sloshing at
// 2–3 cm/s and swelling by 13 % in 30 s (measured).
static inline float wallMirrorVolume(device const int4* grid, int2 node, constant PBSimConstants& c) {
    int2 m = node;
    bool mx = false, my = false;
    const int lo = PB_WALL_OFFSET;                      // plane at lo:       i' = 2·lo − 1 − i
    if (!periodicX(c)) {
        int hi = int(c.gridSize.x) - PB_WALL_OFFSET - 1; // plane at hi + ½:  i' = 2·hi − i
        if (node.x >= lo - 2 && node.x <= lo + 1) { m.x = 2 * lo - 1 - node.x; mx = true; }
        else if (node.x >= hi - 1 && node.x <= hi + 2) { m.x = 2 * hi - node.x; mx = true; }
    }
    if (!periodicY(c)) {
        int hi = int(c.gridSize.y) - PB_WALL_OFFSET - 1;
        if (node.y >= lo - 2 && node.y <= lo + 1) { m.y = 2 * lo - 1 - node.y; my = true; }
        else if (node.y >= hi - 1 && node.y <= hi + 2) { m.y = 2 * hi - node.y; my = true; }
    }
    float v = 0.0f;
    if (mx) v += decodeFixed(grid[gridIndex(uint2(m.x, node.y), c.gridSize)].w);
    if (my) v += decodeFixed(grid[gridIndex(uint2(node.x, m.y), c.gridSize)].w);
    if (mx && my) v += decodeFixed(grid[gridIndex(uint2(m), c.gridSize)].w);
    return v;
}

// ================================================================================================
// Fused g2p2g (upstream main g2p2g.wgsl), one threadgroup per (bukkit, chunk of up to PB_TILE_NODES particles).
// Pass k of a substep (k = 0..N): src = grid[k % 3], dst = grid[(k + 1) % 3], toBeCleared = grid[(k + 2) % 3].
//   k == 0:      constrain + P2G (no G2P; uses the particle's stored displacement and B, rescaled by dtRatio)
//   0 < k < N:   grid update + G2P + constrain + P2G
//   k == N:      grid update + G2P + commit/integrate + count the particle's new bukkit (no P2G)
// After pass N, grid[N % 3] holds the last P2G and is zeroed by pbBukkitAllocate (after pbEmit has read it).
// ================================================================================================
[[max_total_threads_per_threadgroup(PB_TILE_NODES)]]
kernel void pbG2P2G(constant PBSimConstants& c [[buffer(0)]],
        device PBParticle* particles [[buffer(1)]],
        device const int4* gridSrc [[buffer(2)]],
        device atomic_int* gridDst [[buffer(3)]],
        device int4* gridToBeCleared [[buffer(4)]],
        device const PBBukkitThreadData* threadData [[buffer(5)]],
        device const uint* bukkitParticles [[buffer(6)]],
        constant PBShape* shapes [[buffer(7)]],
        constant PBMaterial* materials [[buffer(8)]],
        device PBCountersAtomic& counters [[buffer(9)]],
        device uint* freeIndices [[buffer(10)]],
        device atomic_int* bodyImpulse [[buffer(11)]],           // PB_MAX_SHAPES x (Jx, Jy, torque, contacts)
        device atomic_uint* bukkitCounts [[buffer(12)]],
        uint tid [[thread_index_in_threadgroup]],
        uint group [[threadgroup_position_in_grid]]) {
    threadgroup float4 sSrc[PB_TILE_NODES];                 // updated grid displacement.xy, mass, volume
    threadgroup float2 sBodyD[PB_TILE_NODES];               // displacement change made by body colliders
    threadgroup uint   sBodyS[PB_TILE_NODES];               // shape index that made it (PB_NO_SHAPE if none) | near-collider bit
    threadgroup atomic_int sDst[PB_TILE_NODES * 4];
    threadgroup atomic_int sImp[PB_MAX_SHAPES * 4];

    const bool doG2P = c.iteration > 0;
    const bool doP2G = c.iteration < c.iterationCount;
    const bool doIntegrate = c.iteration == c.iterationCount;

    PBBukkitThreadData td = threadData[group];
    int2 origin = PB_BUKKIT_SIZE * int2(td.bukkitX, td.bukkitY) - PB_BUKKIT_HALO;
    int2 local = int2(int(tid) % PB_TILE_EDGE, int(tid) / PB_TILE_EDGE);
    int2 node = origin + local;
    int2 gnode = node;
    bool valid = true;
    if (periodicX(c)) gnode.x = wrapIndex(node.x, int(c.gridSize.x)); else valid = valid && node.x >= 0 && node.x < int(c.gridSize.x);
    if (periodicY(c)) gnode.y = wrapIndex(node.y, int(c.gridSize.y)); else valid = valid && node.y >= 0 && node.y < int(c.gridSize.y);
    uint gi = valid ? gridIndex(uint2(gnode), c.gridSize) : 0;

    for (uint k = 0; k < 4; ++k) atomic_store_explicit(&sDst[tid * 4 + k], 0, memory_order_relaxed);
    for (uint k = tid; k < PB_MAX_SHAPES * 4; k += PB_TILE_NODES) atomic_store_explicit(&sImp[k], 0, memory_order_relaxed);
    NodeState ns;
    ns.g = float4(0); ns.bodyDelta = float2(0); ns.bodyShape = PB_NO_SHAPE; ns.nearOverflow = false; ns.nearCollider = false;
    if (doG2P && valid) {
        ns = gridNodeUpdate(gridSrc[gi], node, c, shapes);
        if (ns.nearOverflow) atomic_fetch_add_explicit(&counters.overflow, 1u, memory_order_relaxed);
        if (c.useGridVolume != 0u && (c.debugFlags & PB_DEBUG_NO_WALL_MIRROR) == 0u && ns.g.z > 0.0f)
            ns.g.w += wallMirrorVolume(gridSrc, node, c);
    }
    sSrc[tid] = ns.g;
    sBodyD[tid] = ns.bodyDelta;
    sBodyS[tid] = ns.bodyShape | (ns.nearCollider ? PB_NEAR_COLLIDER_BIT : 0u);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    BodyAccum body;
    body.shape = PB_NO_SHAPE; body.J = float3(0); body.shape2 = PB_NO_SHAPE; body.J2 = float3(0);

    if (tid < td.rangeCount) {
        uint pi = bukkitParticles[td.rangeStart + tid];
        PBParticle p = particles[pi];
        constant PBMaterial& m = materials[min(p.material, uint(PB_MAX_MATERIALS - 1))];
        QuadWeights w = quadraticWeightInit(p.position);
        float2 gradH;
        float Hmag = magnetField(c, p.position, gradH);
        float fieldYieldScale = kelvinYieldScale(m, c, Hmag, gradH);

        if (!doG2P) {                                       // pass 0: rescale to this frame's substep length
            p.displacement *= c.dtRatio;
            p.deformationDisplacement *= c.dtRatio;
        } else {
            float2x2 Bsum = float2x2(0);
            float2 d = float2(0);
            float volume = 0.0f;
            bool nearCollider = false;
            for (int i = 0; i < 3; ++i) {
                for (int j = 0; j < 3; ++j) {
                    float weight = w.w[i].x * w.w[j].y;
                    int2 cell = w.base + int2(i, j);
                    int2 l = cell - origin;
                    uint li = uint(l.y * PB_TILE_EDGE + l.x);
                    float4 n = sSrc[li];
                    float2 wd = weight * n.xy;
                    float2 offset = float2(cell) - p.position + 0.5f;
                    Bsum += outer2(wd, offset);
                    d += wd;
                    volume += weight * n.w;
                    uint bs = sBodyS[li] & 0xFFu;
                    nearCollider = nearCollider || (sBodyS[li] & PB_NEAR_COLLIDER_BIT) != 0u;
                    if (bs < PB_MAX_SHAPES) bodyAdd(body, bs, -weight * p.mass * sBodyD[li], float2(cell) + 0.5f - shapes[bs].position);
                }
            }
            g2pFinish(p, Bsum, d, volume, nearCollider, c);
            if (doIntegrate) {
                pbIntegrate(p, pi, m, c, shapes, counters, freeIndices, body, volume, Hmag, gradH, fieldYieldScale);
                particles[pi] = p;
                uint b;
                if ((p.flags & PB_FLAG_ENABLED) && particleBukkit(p.position, c, b))
                    atomic_fetch_add_explicit(&bukkitCounts[b], 1u, memory_order_relaxed);
            }
        }

        if (doP2G) {
            float2x2 Bc = pbConstrain(p, m, c, Hmag, fieldYieldScale);
            particles[pi].iterate = p.iterate;
            if (doG2P) particles[pi].liquidDensity = p.liquidDensity;
            bool clampedFlag = false;
            for (int i = 0; i < 3; ++i) {
                for (int j = 0; j < 3; ++j) {
                    float weight = w.w[i].x * w.w[j].y;
                    int2 cell = w.base + int2(i, j);
                    int2 l = cell - origin;
                    uint li = uint(l.y * PB_TILE_EDGE + l.x) * 4;
                    float2 offset = float2(cell) - p.position + 0.5f;
                    float wm = weight * p.mass;
                    float2 momentum = wm * (p.displacement + Bc * offset);
                    atomic_fetch_add_explicit(&sDst[li + 0], encodeFixed(momentum.x, clampedFlag), memory_order_relaxed);
                    atomic_fetch_add_explicit(&sDst[li + 1], encodeFixed(momentum.y, clampedFlag), memory_order_relaxed);
                    atomic_fetch_add_explicit(&sDst[li + 2], encodeFixed(wm, clampedFlag), memory_order_relaxed);
                    if (c.useGridVolume != 0u)
                        atomic_fetch_add_explicit(&sDst[li + 3], encodeFixed(p.volume * weight, clampedFlag), memory_order_relaxed);
                }
            }
            if (clampedFlag) atomic_fetch_add_explicit(&counters.overflow, 1u, memory_order_relaxed);
        }
    }

    // Body impulses: reduce, then threadgroup int atomics (all threads take part: uniform control flow)
    bodyReduceToThreadgroup(body.shape, body.J, sImp, counters);
    bodyReduceToThreadgroup(body.shape2, body.J2, sImp, counters);

    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (valid && doP2G) {
        int4 v = int4(atomic_load_explicit(&sDst[tid * 4 + 0], memory_order_relaxed),
                      atomic_load_explicit(&sDst[tid * 4 + 1], memory_order_relaxed),
                      atomic_load_explicit(&sDst[tid * 4 + 2], memory_order_relaxed),
                      atomic_load_explicit(&sDst[tid * 4 + 3], memory_order_relaxed));
        if (any(v != int4(0))) {             // skip untouched nodes only: a mass sum that rounds to 0 can carry momentum
            atomic_fetch_add_explicit(&gridDst[gi * 4 + 0], v.x, memory_order_relaxed);
            atomic_fetch_add_explicit(&gridDst[gi * 4 + 1], v.y, memory_order_relaxed);
            atomic_fetch_add_explicit(&gridDst[gi * 4 + 2], v.z, memory_order_relaxed);
            atomic_fetch_add_explicit(&gridDst[gi * 4 + 3], v.w, memory_order_relaxed);
        }
    }
    if (valid) gridToBeCleared[gi] = int4(0);
    for (uint k = tid; k < c.shapeCount * 4; k += PB_TILE_NODES) {
        int v = atomic_load_explicit(&sImp[k], memory_order_relaxed);
        if (!kUseSimd && (k & 3u) != 3u) v = (v + 2) >> 2;                      // 2^22 -> 2^20
        if (v != 0) atomic_fetch_add_explicit(&bodyImpulse[k], v, memory_order_relaxed);
    }
}

// ================================================================================================
// Particle injection from the CPU (fill, setQuality) and clearing. Deterministic slot assignment: free-list slots first
// (most recently freed first), then new slots from particleCount; pbInjectCommit (one thread) updates the counters.
// ================================================================================================
kernel void pbInject(constant PBSimConstants& c [[buffer(0)]],
                     device PBCountersAtomic& counters [[buffer(1)]],
                     device PBParticle* particles [[buffer(2)]],
                     device const PBParticle* staging [[buffer(3)]],
                     device const uint* freeIndices [[buffer(4)]],
                     uint id [[thread_position_in_grid]]) {
    if (id >= c.injectCount) return;
    int freeN = max(atomic_load_explicit(&counters.freeCount, memory_order_relaxed), 0);
    uint count = atomic_load_explicit(&counters.particleCount, memory_order_relaxed);
    uint slot;
    if (int(id) < freeN) slot = freeIndices[uint(freeN - 1 - int(id))];
    else {
        slot = count + (id - uint(freeN));
        if (slot >= c.particleCapacity) return;
    }
    PBParticle p = staging[id];
    p.displacement += c.gravity / max(c.dtRatio, 1e-6f);   // pass 0 multiplies by dtRatio: the kick lands as g dt^2/dx
    particles[slot] = p;
}

kernel void pbInjectCommit(constant PBSimConstants& c [[buffer(0)]],
                           device PBCountersAtomic& counters [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    if (id != 0) return;
    int freeN = max(atomic_load_explicit(&counters.freeCount, memory_order_relaxed), 0);
    uint count = atomic_load_explicit(&counters.particleCount, memory_order_relaxed);
    uint used = min(c.injectCount, uint(freeN));
    atomic_store_explicit(&counters.freeCount, freeN - int(used), memory_order_relaxed);
    uint extra = c.injectCount - used;
    uint wanted = count + extra;
    uint newCount = min(wanted, c.particleCapacity);
    if (wanted > newCount) atomic_fetch_add_explicit(&counters.injectDropped, wanted - newCount, memory_order_relaxed);
    atomic_store_explicit(&counters.particleCount, newCount, memory_order_relaxed);
}

kernel void pbClearParticles(constant PBSimConstants& c [[buffer(0)]],
                             device PBCountersAtomic& counters [[buffer(1)]],
                             device PBParticle* particles [[buffer(2)]],
                             uint id [[thread_position_in_grid]]) {
    if (id >= c.particleCapacity) return;
    particles[id].flags = 0u;
    if (id == 0) {
        atomic_store_explicit(&counters.particleCount, 0u, memory_order_relaxed);
        atomic_store_explicit(&counters.freeCount, 0, memory_order_relaxed);
    }
}

// ================================================================================================
// Emitters (upstream main particleEmit.wgsl), grid-parallel. Rate in Hz per slot; displacement from the shape plus the
// gravity kick. New particles are counted into bukkitCounts so the next pbBukkitAllocate sees them.
// ================================================================================================
kernel void pbEmit(constant PBSimConstants& c [[buffer(0)]],
                   device PBCountersAtomic& counters [[buffer(1)]],
                   device PBParticle* particles [[buffer(2)]],
                   constant PBShape* shapes [[buffer(3)]],
                   device uint* freeIndices [[buffer(4)]],
                   device const int4* grid [[buffer(5)]],          // the last P2G (grid[N % 3]); volume in .w
                   constant PBMaterial* materials [[buffer(6)]],
                   device atomic_uint* bukkitCounts [[buffer(7)]],
                   uint2 id [[thread_position_in_grid]]) {
    if (any(id >= c.gridSize)) return;
    uint lim = PB_GUARDIAN + 1;                                    // tank cells are lim .. gridSize - lim - 2
    if (!periodicX(c) && (id.x < lim || id.x >= c.gridSize.x - lim - 1)) return;
    if (!periodicY(c) && (id.y < lim || id.y >= c.gridSize.y - lim - 1)) return;
    float2 pos = float2(id);
    float nearestVolume = decodeFixed(grid[gridIndex(id, c.gridSize)].w);
    for (uint si = 0; si < c.shapeCount; ++si) {
        constant PBShape& s = shapes[si];
        if (s.functionality != PB_FN_EMIT) continue;
        if (nearestVolume > 1.5f) continue;                        // upstream e0536f8: no pouring into compressed fluid
        if (!collide(s, pos + 0.5f).collides) continue;
        uint emitEvery = max(1u, uint(1.0f / max(s.emissionRate * c.dt, 1e-6f)));
        uint emitSlot = s.emitMaterial & PB_EMIT_MATERIAL_MASK;
        uint stripes = min((s.emitMaterial >> PB_DYE_SHIFT) & PB_DYE_MASK, PB_MAX_STRIPES);
        // Stripe dye: equal-width bands across the nozzle, numbered 1… from the side that the emission direction
        // rotated by -90° points to (a downward nozzle: band 1 on the left, -x). No direction: across x.
        float vlen = length(s.velocity);
        float2 across = vlen > 1e-6f ? float2(-s.velocity.y, s.velocity.x) / vlen : float2(1.0f, 0.0f);
        float halfWidth = max(s.shapeType == PB_SHAPE_CIRCLE ? s.radius : max(s.halfSize.x, s.halfSize.y) + s.radius, 1e-3f);
        constant PBMaterial& m = materials[min(emitSlot, uint(PB_MAX_MATERIALS - 1))];
        float volumePerParticle = 1.0f / float(PB_PPC_AXIS * PB_PPC_AXIS);
        for (uint i = 0; i < PB_PPC_AXIS; ++i) {
            for (uint j = 0; j < PB_PPC_AXIS; ++j) {
                uint h = hashU(hashU(id.x * PB_PPC_AXIS + i) + hashU(id.y * PB_PPC_AXIS + j));
                if (((h + c.substepIndex) % emitEvery) != 0u) continue;
                uint index;
                int freeSlot = atomic_fetch_sub_explicit(&counters.freeCount, 1, memory_order_relaxed) - 1;
                if (freeSlot >= 0) index = freeIndices[uint(freeSlot)];
                else {
                    index = atomic_fetch_add_explicit(&counters.particleCount, 1u, memory_order_relaxed);
                    if (index >= c.particleCapacity) { atomic_fetch_sub_explicit(&counters.particleCount, 1u, memory_order_relaxed); continue; }
                }
                float2 jitter = float2(-0.2f) + 0.4f * float2(float(hashU(index) % 16u) / 16.0f, float(h % 16u) / 16.0f);
                PBParticle p;
                p.position = confine(pos + (float2(float(i), float(j)) + 0.5f + jitter) / float(PB_PPC_AXIS), c);
                p.displacement = s.velocity + c.gravity;
                p.deformationDisplacement = float2x2(0);
                p.elastic = float4(1, 0, 1, 0);
                p.iterate = float4(0);
                p.liquidDensity = 1.0f;
                p.mass = volumePerParticle * m.density / c.rhoRef;
                p.volume = volumePerParticle;
                p.structure = 1.0f;
                p.contact = 0.0f;
                p.temperature = s.emitTemperature > 0.0f ? s.emitTemperature : c.ambientTemperature;
                p.viscosity = 1e30f;
                p.stress = 0.0f;
                p.shearRate = 0.0f;
                p.material = emitSlot;
                uint band = 0u;
                if (stripes > 0u) {
                    float t = clamp(0.5f + 0.5f * dot(p.position - s.position, across) / halfWidth, 0.0f, 0.99999f);
                    band = min(uint(t * float(stripes)), stripes - 1u) + 1u;
                }
                p.flags = PB_FLAG_ENABLED | (band << PB_DYE_SHIFT);
                p.tag = float(hashU(h ^ (c.substepIndex * 2654435761u)) & 0xFFFFFFu) / 16777216.0f;
                particles[index] = p;
                uint b;
                if (particleBukkit(p.position, c, b)) atomic_fetch_add_explicit(&bukkitCounts[b], 1u, memory_order_relaxed);
                atomic_fetch_add_explicit(&counters.emitted, 1u, memory_order_relaxed);
            }
        }
    }
}

// ================================================================================================
// Telemetry: one pass per frame over particles, threadgroup tree reductions (no SIMD-group functions), then a few
// device atomics per group.
// ================================================================================================
static inline float4 tgSum4(float4 v, threadgroup float4* buf, uint tid) {
    buf[tid] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = PB_PARTICLE_GROUP / 2; s > 0; s >>= 1) {
        if (tid < s) buf[tid] += buf[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float4 r = buf[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return r;
}
static inline float4 tgMax4(float4 v, threadgroup float4* buf, uint tid) {
    buf[tid] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = PB_PARTICLE_GROUP / 2; s > 0; s >>= 1) {
        if (tid < s) buf[tid] = max(buf[tid], buf[tid + s]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float4 r = buf[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return r;
}

[[max_total_threads_per_threadgroup(PB_PARTICLE_GROUP)]]
kernel void pbStats(constant PBSimConstants& c [[buffer(0)]],
                    device PBCountersAtomic& counters [[buffer(1)]],
                    device const PBParticle* particles [[buffer(2)]],
                    constant PBMaterial* materials [[buffer(3)]],
                    device PBStatsAtomic& stats [[buffer(4)]],
                    uint id [[thread_position_in_grid]],
                    uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float4 buf[PB_PARTICLE_GROUP];
    uint n = min(atomic_load_explicit(&counters.particleCount, memory_order_relaxed), c.particleCapacity);
    bool live = id < n && (particles[id].flags & PB_FLAG_ENABLED) != 0u;
    float4 s0 = float4(0), s1 = float4(0), s2 = float4(0), s3 = float4(0), mx = float4(0);
    if (live) {
        PBParticle p = particles[id];
        constant PBMaterial& m = materials[min(p.material, uint(PB_MAX_MATERIALS - 1))];
        float2 kick = c.gravity;                                          // the stored displacement already holds the next kick
        if (m.susceptibility > 0.0f && c.magnet.z > 0.0f) {               // … and the next Kelvin kick
            float2 gH;
            float H = magnetField(c, p.position, gH), unused;
            kick += kelvinAcceleration(m, H, gH, unused) * c.dt * c.dt / c.dx;
        }
        float v = length(p.displacement - kick) * c.dx / c.dt;
        float massKg = p.mass * c.rhoRef * c.dx * c.dx;                   // kg per metre of depth
        bool jammed = false;
        if (m.dst != 0u) {
            float phiJ = p.contact * m.phiM + (1.0f - p.contact) * m.phi0;
            jammed = (1.0f - m.phi / phiJ) < m.gapFloor;
        }
        bool yielded = p.viscosity < 1e29f;
        float logEta = log10(clamp(p.viscosity, 1e-4f, 1e8f));
        s0 = float4(1.0f, jammed ? 1.0f : 0.0f, yielded ? 1.0f : 0.0f, min(p.liquidDensity, 64.0f));
        s1 = float4(p.structure, 0.5f * massKg * v * v, p.mass, yielded ? p.mass : 0.0f);
        float pw = 0.0f;
        if (c.probe.w > 0.0f) {
            float2 r = p.position - c.probe.xy;
            pw = max(0.0f, 1.0f - dot(r, r) / (c.probe.z * c.probe.z));
        }
        s2 = float4(yielded ? p.mass * logEta : 0.0f, pw, pw * p.shearRate, pw * p.stress);
        s3 = float4(pw * ((!yielded || jammed) ? 1.0f : 0.0f), p.temperature, 0.0f, 0.0f);
        mx = float4(v, p.stress, 0.0f, 0.0f);
    }
    s0 = tgSum4(s0, buf, tid);
    s1 = tgSum4(s1, buf, tid);
    s2 = tgSum4(s2, buf, tid);
    s3 = tgSum4(s3, buf, tid);
    mx = tgMax4(mx, buf, tid);
    if (tid == 0 && s0.x > 0.0f) {
        atomic_fetch_add_explicit(&stats.liveCount, uint(rint(s0.x)), memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.jammedCount, uint(rint(s0.y)), memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.yieldedCount, uint(rint(s0.z)), memory_order_relaxed);
        atomic_fetch_max_explicit(&stats.maxSpeedBits, as_type<uint>(mx.x), memory_order_relaxed);
        atomic_fetch_max_explicit(&stats.maxStressBits, as_type<uint>(mx.y), memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.sumJ, s0.w, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.sumStructure, s1.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.sumKinetic, s1.y, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.sumMass, s1.z, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.yieldMass, s1.w, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.yieldMassLogEta, s2.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.probeWeight, s2.y, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.probeShear, s2.z, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.probeStress, s2.w, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.probeSolid, s3.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats.sumTemperature, s3.y, memory_order_relaxed);
    }
}

// Copies the device counters into the frame's readback slot (one thread).
kernel void pbSnapshot(device const PBCounters* counters [[buffer(0)]],
                       device PBCounters* out [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
    if (id == 0) *out = *counters;
}

// Debug: exact sum of the grid's mass (z) and volume (w) fixed-point components, split into 16-bit halves.
// gridMass[0..1] = mass lo/hi, [2..3] = volume lo/hi. Valid while every node value is >= 0 and the node count < 65,536.
[[max_total_threads_per_threadgroup(PB_GRID_GROUP * PB_GRID_GROUP)]]
kernel void pbGridMass(constant PBSimConstants& c [[buffer(0)]],
                       device const int4* grid [[buffer(1)]],
                       device PBStatsAtomic& stats [[buffer(2)]],
                       uint2 id [[thread_position_in_grid]],
                       uint tid [[thread_index_in_threadgroup]]) {
    threadgroup uint4 buf[PB_GRID_GROUP * PB_GRID_GROUP];
    uint4 v = uint4(0);
    if (all(id < c.gridSize)) {
        int4 g = grid[gridIndex(id, c.gridSize)];
        uint m = uint(max(g.z, 0)), vol = uint(max(g.w, 0));
        v = uint4(m & 0xFFFFu, m >> 16, vol & 0xFFFFu, vol >> 16);
    }
    buf[tid] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = (PB_GRID_GROUP * PB_GRID_GROUP) / 2; s > 0; s >>= 1) {
        if (tid < s) buf[tid] += buf[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        for (uint k = 0; k < 4; ++k) atomic_fetch_add_explicit(&stats.gridMass[k], buf[0][k], memory_order_relaxed);
    }
}

// Verification: the EVP update alone on homogeneous material points under scripted velocity gradients (the
// rheology note's Appendix A rheo_shear_test), for constitutive-level parity with LabKitMPMReference (V14).
// out = Kirchhoff stress (t11, t12, t22) after the last update, and γ̇p.
kernel void pbConstitutive(constant PBMaterial* materials [[buffer(0)]],
                           device PBParticle* points [[buffer(1)]],
                           device const PBConstitutiveJob* jobs [[buffer(2)]],
                           device float4* out [[buffer(3)]],
                           constant uint& count [[buffer(4)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= count) return;
    PBConstitutiveJob j = jobs[id];
    PBParticle p = points[id];
    constant PBMaterial& m = materials[min(j.material, uint(PB_MAX_MATERIALS - 1))];
    RheoState s = stateOf(p);
    float2x2 B = float2x2(float2(j.gradient.x, j.gradient.z), float2(j.gradient.y, j.gradient.w)) * j.dt;
    float3 t = float3(0);
    bool guarded = false;
    for (uint i = 0; i < j.steps; ++i) t = rheoUpdate(s, B, j.dt, m, j.fieldMagnitude, guarded);
    p.elastic = float4(s.b11, s.b12, s.b22, s.gdotP);
    p.liquidDensity = s.J; p.structure = s.lam; p.contact = s.f;
    points[id] = p;
    out[id] = float4(t, s.gdotP);
}

// Layout probe: the host compares these with MemoryLayout<...>.stride (C/Swift view of MPMShared.h).
kernel void pbLayoutProbe(device uint* out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    if (id != 0) return;
    out[0] = sizeof(PBParticle); out[1] = sizeof(PBSimConstants); out[2] = sizeof(PBShape); out[3] = sizeof(PBMaterial);
    out[4] = sizeof(PBCounters); out[5] = sizeof(PBBukkitDispatch); out[6] = sizeof(PBStats); out[7] = sizeof(PBBukkitThreadData);
    out[8] = PB_TILE_NODES; out[9] = PB_BUKKIT_SIZE;
    out[10] = __builtin_offsetof(PBParticle, elastic); out[11] = __builtin_offsetof(PBParticle, liquidDensity); out[12] = __builtin_offsetof(PBParticle, tag);
    out[13] = __builtin_offsetof(PBSimConstants, field); out[14] = __builtin_offsetof(PBSimConstants, ambientTemperature);
    out[15] = __builtin_offsetof(PBSimConstants, injectCount); out[16] = __builtin_offsetof(PBMaterial, dst); out[17] = __builtin_offsetof(PBMaterial, restMelt);
    out[18] = __builtin_offsetof(PBCounters, drawArgs); out[19] = __builtin_offsetof(PBStats, gridMass);
}

// SIMD-group probe (the iOS simulator reports only Apple2/Common1 families, so these functions are tested before use).
// Per thread: x = simd_sum(1), y = simd_broadcast_first(tid), z = simd_max(tid), w = simd_any(tid == 5) + 2·simd_is_first().
kernel void pbSimdProbe(device uint4* out [[buffer(0)]],
                        uint tid [[thread_index_in_threadgroup]]) {
    uint s = simd_sum(1u);
    uint b = simd_broadcast_first(tid);
    uint mxv = simd_max(tid);
    uint flags = (simd_any(tid == 5u) ? 1u : 0u) + (simd_is_first() ? 2u : 0u);
    float fs = simd_sum(float(tid) * 0.5f);
    out[tid] = uint4(s, b, mxv, flags + (uint(rint(fs * 2.0f)) << 8));
}
