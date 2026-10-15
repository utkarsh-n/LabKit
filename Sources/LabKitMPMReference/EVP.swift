// The unified elasto-viscoplastic (EVP) constitutive update, Double precision (CPU oracle). Owned by WP-O.
//
// Specification: Rheo/Documentation/research/rheology-models.md §4.1–§4.8 and Appendix B (the verified Swift
// Double core function), which this file follows line for line, with three additions the note asks for:
//   - the det f guard of §4.8 (the GPU does it in G2P; here it is inside the update and reported),
//   - a bracketed (safeguarded) Newton iteration, which falls back to bisection if a step ever leaves the bracket,
//   - the temperature band and the Arrhenius cap of §4.8.
// Conventions (§0.2): C = ∇v with c11 = ∂vx/∂x, c12 = ∂vx/∂y, c21 = ∂vy/∂x, c22 = ∂vy/∂y. In `simd_double2x2`
// (column-major) that is c11 = C[0][0], c21 = C[0][1], c12 = C[1][0], c22 = C[1][1]. Stresses are Kirchhoff
// (τ = Jσ), returned as (τ11, τ12, τ22). Equivalent shear stress τ̄ = √(s11² + s12²); equivalent shear rate
// γ̇ = √((c11 − c22)² + (c12 + c21)²); both equal τ_xy and γ̇ in simple shear.

import Foundation
import LabKitCore
import simd

/// Per-particle rheology state (§4.1): 8 Doubles, mirroring `RheoState` of the GPU kernel.
public struct EVPState: Sendable, Equatable, Hashable {
  /// Isochoric elastic left Cauchy–Green tensor b̄ₑ (symmetric, det = 1).
  public var b11: Double, b12: Double, b22: Double
  /// Elastic volume ratio J.
  public var J: Double
  /// Thixotropic structure λ ∈ [0, 1] (1 = fully built).
  public var structure: Double
  /// Fraction of frictional contacts f ∈ [0, 1] (DST).
  public var contact: Double
  /// Temperature, K.
  public var temperature: Double
  /// Plastic shear rate of the last update, 1/s (diagnostic).
  public var plasticRate: Double

  public init(b11: Double = 1, b12: Double = 0, b22: Double = 1, J: Double = 1, structure: Double = 1,
              contact: Double = 0, temperature: Double = 293.15, plasticRate: Double = 0) {
    self.b11 = b11; self.b12 = b12; self.b22 = b22; self.J = J
    self.structure = structure; self.contact = contact; self.temperature = temperature; self.plasticRate = plasticRate
  }

  /// A stress-free, rested particle of `material`: b̄ₑ = I, J = 1, f = 0, T = T_ref, and λ = 1, except for a
  /// purely rheopectic material (no rest build-up, shear build-up, rest decay), whose rested state is λ = 0.
  public static func rested(_ material: ContinuumMaterial) -> EVPState {
    let rheopectic = material.buildRate == 0 && material.buildShear > 0 && material.breakRate > 0
    return EVPState(structure: rheopectic ? 0 : 1, temperature: material.referenceTemperature)
  }

  /// b̄ₑ = F Fᵀ for a simple-shear elastic strain F = [[1, γ], [0, 1]] (det F = 1), the V6 initial state.
  public mutating func setElasticSimpleShear(_ gamma: Double) {
    b11 = 1 + gamma * gamma; b12 = gamma; b22 = 1
  }

  /// Equivalent (Kirchhoff) shear stress G·√(d² + b12²), d = ½(b11 − b22).
  public func equivalentShearStress(shearModulus g: Double) -> Double {
    let d = 0.5 * (b11 - b22)
    return g * (d * d + b12 * b12).squareRoot()
  }
}

/// The single-particle EVP update and the laws it is built from.
public enum EVP {
  // MARK: Robustness clamps (§4.8)

  /// J ∈ [0.6, 1.5]. `ContinuumMaterial` has no per-material J clamp, so the §4.8 values are global.
  public static let minimumVolumeRatio = 0.6
  public static let maximumVolumeRatio = 1.5
  /// det(I + Δt·C) floor: below it C is rescaled so the determinant equals this value (a CFL breach).
  public static let minimumDeterminant = 0.05
  /// Arrhenius shift factors are capped at 10⁴ (glass-like freezing would stall the solver).
  public static let maximumShiftFactor = 1.0e4
  /// The temperature used by the update is clamped to [T_ref − 40 K, T_ref + 80 K] (a material's
  /// `temperatureBandBelow` replaces the 40 K).
  public static let temperatureBandBelow = 40.0
  public static let temperatureBandAbove = 80.0
  /// Newton stops when |Δτ̄| ≤ 10⁻¹⁴·τ̄_tr, after at most 40 iterations (Appendix B).
  public static let newtonTolerance = 1.0e-14
  public static let maximumNewtonIterations = 40

  // MARK: Flow law

  /// The effective flow law of one step: γ̇ₚ(τ̄) = φ₀·τ̄ + ((τ̄ − τ_y)₊/k)^(1/n) + φ_f·(τ̄ − τ_f)₊ (Eq. 4.1).
  public struct FlowLaw: Sendable, Equatable {
    /// φ₀ = 1/η₀, 1/(Pa·s) (0 = off).
    public var fluidity: Double
    /// τ_y, Pa.
    public var yieldStress: Double
    /// k, Pa·sⁿ (0 = Herschel–Bulkley branch off).
    public var consistency: Double
    /// n ∈ (0, 1].
    public var flowIndex: Double
    /// τ_f, Pa (`.infinity` = off).
    public var failureStress: Double
    /// φ_f, 1/(Pa·s).
    public var failureFluidity: Double

    public init(fluidity: Double = 0, yieldStress: Double = 0, consistency: Double = 0, flowIndex: Double = 1,
                failureStress: Double = .infinity, failureFluidity: Double = 0) {
      self.fluidity = fluidity; self.yieldStress = yieldStress; self.consistency = consistency
      self.flowIndex = flowIndex; self.failureStress = failureStress; self.failureFluidity = failureFluidity
    }

    /// Plastic shear rate γ̇ₚ(τ̄), 1/s.
    @inlinable public func rate(_ t: Double) -> Double {
      var a = fluidity * t
      if consistency > 0 && t > yieldStress { a += pow((t - yieldStress) / consistency, 1 / flowIndex) }
      if t > failureStress { a += failureFluidity * (t - failureStress) }
      return a
    }

    /// dγ̇ₚ/dτ̄.
    @inlinable public func slope(_ t: Double) -> Double {
      var d = fluidity
      if consistency > 0 && t > yieldStress {
        let invn = 1 / flowIndex
        d += invn / consistency * pow((t - yieldStress) / consistency, invn - 1)
      }
      if t > failureStress { d += failureFluidity }
      return d
    }

    /// True if any branch can flow at stress `t`.
    public func flows(at t: Double) -> Bool {
      fluidity > 0 || (consistency > 0 && t > yieldStress) || t > failureStress
    }

    /// The steady flow curve τ̄(γ̇): the stress at which the plastic rate equals `shearRate` (≥ 0), by bisection
    /// on the monotone law. Returns `yieldStress` (or the smallest flowing stress) as γ̇ → 0.
    public func stress(atRate shearRate: Double) -> Double {
      guard shearRate > 0 else { return fluidity > 0 ? 0 : min(yieldStress, failureStress) }
      var lo = 0.0, hi = max(1.0, yieldStress)
      var guardCount = 0
      while rate(hi) < shearRate && guardCount < 400 { lo = hi; hi *= 2; guardCount += 1 }
      for _ in 0..<200 {
        let mid = 0.5 * (lo + hi)
        if rate(mid) < shearRate { lo = mid } else { hi = mid }
        if hi - lo <= 1e-15 * hi { break }
      }
      return 0.5 * (lo + hi)
    }
  }

  /// What one update did, for diagnostics, rendering and tests.
  public struct Diagnostics: Sendable, Equatable {
    /// Trial equivalent shear stress τ̄_tr (Kirchhoff), Pa.
    public var trialStress = 0.0
    /// Equivalent shear stress after the return map τ̄ₙ₊₁ (Kirchhoff), Pa.
    public var stress = 0.0
    /// Total equivalent shear rate γ̇_tot, 1/s.
    public var totalRate = 0.0
    /// Plastic shear rate γ̇ₚ, 1/s.
    public var plasticRate = 0.0
    /// DST jam blend s ∈ [0, 1] (0 = flowing suspension, 1 = jammed solid).
    public var jam = 0.0
    /// Arrhenius shift factor a_T applied to k and φ₀.
    public var shiftFactor = 1.0
    /// Field-induced yield stress τ_field, Pa.
    public var fieldYield = 0.0
    /// The effective flow law of this step.
    public var law = FlowLaw()
    /// Newton iterations used (0 when elastic or closed form).
    public var iterations = 0
    /// Bisection fallbacks taken inside the safeguarded Newton solve.
    public var bisections = 0
    /// True if det(I + Δt·C) was below `minimumDeterminant` and C was rescaled.
    public var determinantGuard = false
    /// True if J hit the [0.6, 1.5] clamp or the tension cap.
    public var volumeClamped = false
    public init() {}

    /// Secant viscosity τ̄/γ̇ₚ (Pa·s); `.infinity` when not flowing.
    public var secantViscosity: Double { plasticRate > 0 ? stress / plasticRate : .infinity }
  }

  // MARK: Modulators

  /// Arrhenius shift factor a_T = exp[(E_a/R)(1/T − 1/T_ref)], capped at `maximumShiftFactor` (1 when E_a ≤ 0).
  public static func shiftFactor(activationEnergy ea: Double, temperature t: Double, reference tRef: Double) -> Double {
    guard ea > 0 else { return 1 }
    return min(exp(ea / ContinuumMaterial.gasConstant * (1 / t - 1 / tRef)), maximumShiftFactor)
  }

  /// τ_field = min(τ_sat·tanh(|H|/H_sat), c_clamp·G) (Carlson law with the toy clamp, §4.2 d). 0 without a field response.
  public static func fieldYield(fieldMagnitude h: Double, material m: ContinuumMaterial) -> Double {
    guard let f = m.field, f.yieldSaturation > 0, f.saturationField > 0 else { return 0 }
    return min(f.yieldSaturation * tanh(abs(h) / f.saturationField), f.clampFractionOfG * m.shearModulus)
  }

  /// The temperature the update uses: T clamped to [T_ref − band, T_ref + 80 K], band = the material's
  /// `temperatureBandBelow` or 40 K.
  public static func clampedTemperature(_ t: Double, material m: ContinuumMaterial) -> Double {
    min(max(t, m.referenceTemperature - bandBelow(m)), m.referenceTemperature + temperatureBandAbove)
  }
  /// The cold side of the temperature band for `m`, K.
  public static func bandBelow(_ m: ContinuumMaterial) -> Double { max(m.temperatureBandBelow ?? temperatureBandBelow, 0) }

  /// Steady contact fraction f_ss(τ̄) of the DST block: form 0 = 1 − e^(−τ̄/σ*) (WC/Han), form 1 = e^(−σ*/τ̄).
  public static func steadyContact(stress t: Double, dst d: ContinuumMaterial.DST) -> Double {
    d.onsetForm == 0 ? 1 - exp(-t / d.onsetStress) : exp(-d.onsetStress / max(t, 1e-6))
  }

  /// The DST jam blend s and blended Newtonian viscosity for contact fraction f (§4.2 c).
  public static func jamBlend(contact f: Double, dst d: ContinuumMaterial.DST, shearModulus g: Double, shiftFactor aT: Double)
    -> (jam: Double, viscosity: Double)
  {
    let phiJ = f * d.phiFrictional + (1 - f) * d.phiFrictionless
    let gap = 1 - d.phi / phiJ
    var x = min(max((d.gapFloor - gap) / d.blendWidth, 0), 1)
    x = x * x * (3 - 2 * x)
    let gm = max(gap, d.gapFloor)
    let eta = (1 - x) * aT * d.solventViscosity / (gm * gm) + x * g * d.jamTime
    return (x, eta)
  }

  /// The effective flow law for a state that is *not* advanced (λ, f and T as stored): used by the Hele-Shaw
  /// drag and by rheometer-style diagnostics. The update itself advances f first (lagged-f law).
  public static func flowLaw(for s: EVPState, material m: ContinuumMaterial, fieldMagnitude h: Double = 0) -> FlowLaw {
    let t = clampedTemperature(s.temperature, material: m)
    let aT = shiftFactor(activationEnergy: m.activationEnergy, temperature: t, reference: m.referenceTemperature)
    let aTy = shiftFactor(activationEnergy: m.yieldActivationEnergy, temperature: t, reference: m.referenceTemperature)
    let tField = fieldYield(fieldMagnitude: h, material: m)
    if let d = m.dst {
      let (x, eta) = jamBlend(contact: min(max(s.contact, 0), 1), dst: d, shearModulus: m.shearModulus, shiftFactor: aT)
      return FlowLaw(fluidity: 1 / eta, yieldStress: tField, consistency: 0, flowIndex: 1,
                     failureStress: x > 0 ? d.jamFailureStress : .infinity, failureFluidity: x / d.postFailureViscosity)
    }
    let lm = pow(max(s.structure, 0), m.structureExponent)
    return FlowLaw(fluidity: m.fluidity / aT,
                   yieldStress: aTy * (m.yieldBroken + m.yieldStructure * lm) + tField,
                   consistency: aT * m.consistency * (1 + m.consistencyStructure * lm),
                   flowIndex: m.flowIndex,
                   failureStress: m.failureStress, failureFluidity: m.failureFluidity)
  }

  // MARK: Return map

  /// Solves the scalar backward-Euler return equation τ̄ = τ̄_tr − μ̃Δt·γ̇ₚ(τ̄) (Eq. 4.2) for τ̄ ∈ [0, τ̄_tr].
  /// Newton from the minimum of the single-branch roots converges monotonically for n ≤ 1 (§4.3); the bracket
  /// [lo, hi] with r(lo) ≤ 0 ≤ r(hi) is kept anyway and any step that leaves it (or is not finite) bisects.
  public static func returnMap(trialStress tauTr: Double, muDt mdt: Double, law: FlowLaw)
    -> (stress: Double, iterations: Int, bisections: Int)
  {
    guard tauTr > 0, mdt > 0, law.flows(at: tauTr) else { return (tauTr, 0, 0) }
    var t0 = tauTr
    if law.fluidity > 0 { t0 = min(t0, tauTr / (1 + mdt * law.fluidity)) }
    if law.consistency > 0 && tauTr > law.yieldStress {
      let x = tauTr - law.yieldStress
      t0 = min(t0, law.yieldStress + min(x, law.consistency * pow(x / mdt, law.flowIndex)))
    }
    if tauTr > law.failureStress {
      t0 = min(t0, max(law.failureStress,
                       (tauTr + mdt * law.failureFluidity * law.failureStress) / (1 + mdt * law.failureFluidity)))
    }
    var lo = 0.0, hi = tauTr
    let r0 = t0 - tauTr + mdt * law.rate(t0)
    if r0 >= 0 { hi = t0 } else { lo = t0 }        // theory: r(t0) ≥ 0; keep the bracket honest either way
    var t = t0
    var iterations = 0, bisections = 0
    for _ in 0..<maximumNewtonIterations {
      iterations += 1
      let res = t - tauTr + mdt * law.rate(t)
      if res == 0 { break }
      if res > 0 { hi = min(hi, t) } else { lo = max(lo, t) }
      let dres = 1 + mdt * law.slope(t)
      var tn = max(t - res / dres, 0)
      if !(tn.isFinite) || tn < lo || tn > hi {     // safeguard: bisect the bracket
        tn = 0.5 * (lo + hi); bisections += 1
      }
      if abs(tn - t) <= newtonTolerance * tauTr { t = tn; break }
      t = tn
    }
    return (t, iterations, bisections)
  }

  // MARK: The update

  /// Advances one particle's state over `dt` given its velocity gradient `c` (from G2P) and the field magnitude
  /// |H| (A/m, already lagged), and returns the Kirchhoff stress (τ11, τ12, τ22). §4.4 step 4.
  @discardableResult
  public static func update(_ s: inout EVPState, velocityGradient c: simd_double2x2, dt: Double,
                            material: ContinuumMaterial, fieldMagnitude: Double) -> SIMD3<Double>
  {
    var diagnostics = Diagnostics()
    return update(&s, velocityGradient: c, dt: dt, material: material, fieldMagnitude: fieldMagnitude,
                  diagnostics: &diagnostics)
  }

  /// `update(_:velocityGradient:dt:material:fieldMagnitude:)` that also reports what happened.
  @discardableResult
  public static func update(_ s: inout EVPState, velocityGradient c: simd_double2x2, dt: Double,
                            material m: ContinuumMaterial, fieldMagnitude h: Double,
                            diagnostics diag: inout Diagnostics) -> SIMD3<Double>
  {
    let g = m.shearModulus
    diag = Diagnostics()
    // 1. Lagged start-of-step stress (driver of the DST contact fraction).
    let dn = 0.5 * (s.b11 - s.b22)
    let tauN = g * (dn * dn + s.b12 * s.b12).squareRoot()

    // 2. Kinematics: f = I + Δt·C (with the det guard), J ← J·det f, b̄_tr = f̄ b̄ f̄ᵀ renormalised to det 1.
    var c11 = c[0][0], c12 = c[1][0], c21 = c[0][1], c22 = c[1][1]
    var detf = (1 + dt * c11) * (1 + dt * c22) - dt * dt * c12 * c21
    if !(detf > minimumDeterminant) {
      // det(I + sΔtC) = 1 + s·Δt·trC + s²·Δt²·detC; take the smallest s ∈ (0, 1] where it equals the floor.
      let a = dt * dt * (c11 * c22 - c12 * c21), b = dt * (c11 + c22), q = 1 - minimumDeterminant
      var sc = 1.0
      if abs(a) < 1e-300 {
        sc = b < 0 ? min(1, -q / b) : 1
      } else {
        let disc = b * b - 4 * a * q
        if disc >= 0 {
          let r = disc.squareRoot()
          let roots = [(-b - r) / (2 * a), (-b + r) / (2 * a)].filter { $0 > 0 && $0 <= 1 }
          sc = roots.min() ?? 1
        }
      }
      c11 *= sc; c12 *= sc; c21 *= sc; c22 *= sc
      detf = (1 + dt * c11) * (1 + dt * c22) - dt * dt * c12 * c21
      if !(detf > 0) { c11 = 0; c12 = 0; c21 = 0; c22 = 0; detf = 1 }
      diag.determinantGuard = true
    }
    s.J *= detf
    let r = 1 / detf.squareRoot()
    let f11 = (1 + dt * c11) * r, f12 = dt * c12 * r, f21 = dt * c21 * r, f22 = (1 + dt * c22) * r
    let t11 = f11 * s.b11 + f12 * s.b12, t12 = f11 * s.b12 + f12 * s.b22
    let t21 = f21 * s.b11 + f22 * s.b12, t22 = f21 * s.b12 + f22 * s.b22
    var n11 = t11 * f11 + t12 * f12, n12 = t11 * f21 + t12 * f22, n22 = t21 * f21 + t22 * f22
    var q = 1 / (n11 * n22 - n12 * n12).squareRoot()
    n11 *= q; n12 *= q; n22 *= q

    // 3. Trial values.
    let tr = n11 + n22
    var d11 = 0.5 * (n11 - n22)
    let tauTr = g * (d11 * d11 + n12 * n12).squareRoot()
    let mdt = g * 0.5 * tr * dt
    let gTot = ((c11 - c22) * (c11 - c22) + (c12 + c21) * (c12 + c21)).squareRoot()
    diag.trialStress = tauTr
    diag.totalRate = gTot

    // 4. Modulators: temperature band, Arrhenius, field yield; DST contact update and jam blend.
    s.temperature = clampedTemperature(s.temperature, material: m)
    let aT = shiftFactor(activationEnergy: m.activationEnergy, temperature: s.temperature, reference: m.referenceTemperature)
    let aTy = shiftFactor(activationEnergy: m.yieldActivationEnergy, temperature: s.temperature,
                          reference: m.referenceTemperature)
    let tField = fieldYield(fieldMagnitude: h, material: m)
    diag.shiftFactor = aT
    diag.fieldYield = tField
    var law: FlowLaw
    if let d = m.dst {
      // df/dt = (γ̇/γ*)(f_ss − f) + (1/t_melt)((1 − w_rest)·f_ss − f), implicit (w_rest = 0: the lagged-f law).
      // γ̇ is the total rate, or (plasticDrive) the plastic rate of the previous update.
      let cRate = (d.plasticDrive ? s.plasticRate : gTot) / d.strainScale + 1 / d.meltTime
      let toward = cRate - min(max(d.restMelt, 0), 1) / d.meltTime
      let fss = steadyContact(stress: tauN, dst: d)
      s.contact = (s.contact + toward * dt * fss) / (1 + cRate * dt)
      let (x, eta) = jamBlend(contact: s.contact, dst: d, shearModulus: g, shiftFactor: aT)
      law = FlowLaw(fluidity: 1 / eta, yieldStress: tField, consistency: 0, flowIndex: 1,
                    failureStress: x > 0 ? d.jamFailureStress : .infinity, failureFluidity: x / d.postFailureViscosity)
      diag.jam = x
    } else {
      let lm = pow(max(s.structure, 0), m.structureExponent)
      law = FlowLaw(fluidity: m.fluidity / aT,
                    yieldStress: aTy * (m.yieldBroken + m.yieldStructure * lm) + tField,
                    consistency: aT * m.consistency * (1 + m.consistencyStructure * lm),
                    flowIndex: m.flowIndex,
                    failureStress: m.failureStress, failureFluidity: m.failureFluidity)
    }
    diag.law = law

    // 5. Return map (backward Euler on the scalar equation), corrector, renormalisation.
    var gP = 0.0
    var tNew = tauTr
    if law.flows(at: tauTr) && tauTr > 0 && mdt > 0 {
      let solved = returnMap(trialStress: tauTr, muDt: mdt, law: law)
      tNew = solved.stress
      diag.iterations = solved.iterations
      diag.bisections = solved.bisections
      gP = (tauTr - tNew) / mdt
      let sc = tNew / tauTr
      d11 *= sc; n12 *= sc
      n11 = d11 + 0.5 * tr; n22 = -d11 + 0.5 * tr
      q = 1 / (n11 * n22 - n12 * n12).squareRoot()
      n11 *= q; n12 *= q; n22 *= q
      // 6. DST strain-induced unjamming.
      if let d = m.dst, tNew > law.failureStress {
        s.contact /= (1 + dt * law.failureFluidity * (tNew - law.failureStress) / d.breakStrain)
      }
    }
    s.b11 = n11; s.b12 = n12; s.b22 = n22
    s.plasticRate = gP
    diag.stress = tNew
    diag.plasticRate = gP

    // 7. Structure (generalised Moore, implicit): driving rate mixes plastic and total rates by w_vib.
    let gs = (1 - m.vibrationWeight) * gP + m.vibrationWeight * gTot
    let A = m.buildRate + m.buildShear * gs, B = m.breakRate + m.breakShear * gs
    s.structure = min(max((s.structure + A * dt) / (1 + (A + B) * dt), 0), 1)
    s.contact = min(max(s.contact, 0), 1)

    // 8. Volume: J clamp, volumetric Kirchhoff stress ½K(J² − 1), tensile cap (plastic dilation).
    let jc = min(max(s.J, minimumVolumeRatio), maximumVolumeRatio)
    if jc != s.J { diag.volumeClamped = true; s.J = jc }
    let k = m.bulkModulus, pt = m.tensionLimit
    var tvol = 0.5 * k * (s.J * s.J - 1)
    if tvol > s.J * pt && k > 0 {
      s.J = (pt + (pt * pt + k * k).squareRoot()) / k
      tvol = 0.5 * k * (s.J * s.J - 1)
      diag.volumeClamped = true
    }

    // 9. Kirchhoff stress τ = G·dev b̄ₑ + τ_v·I.
    let hm = 0.5 * (s.b11 + s.b22)
    return SIMD3(g * (s.b11 - hm) + tvol, g * s.b12, g * (s.b22 - hm) + tvol)
  }

  /// The Kirchhoff stress of a committed state without advancing it: G·dev b̄ₑ + ½K(J² − 1)·I.
  /// Used for the first P2G of a scene whose particles start pre-strained (V6).
  public static func kirchhoffStress(_ s: EVPState, material m: ContinuumMaterial) -> SIMD3<Double> {
    let hm = 0.5 * (s.b11 + s.b22)
    let tvol = 0.5 * m.bulkModulus * (s.J * s.J - 1)
    return SIMD3(m.shearModulus * (s.b11 - hm) + tvol, m.shearModulus * s.b12, m.shearModulus * (s.b22 - hm) + tvol)
  }

  /// Equivalent shear stress of a stress triple (τ11, τ12, τ22): √(¼(τ11 − τ22)² + τ12²).
  @inlinable public static func equivalentShearStress(_ t: SIMD3<Double>) -> Double {
    let d = 0.5 * (t.x - t.z)
    return (d * d + t.y * t.y).squareRoot()
  }

  /// Plane-strain in-plane bulk modulus from a 3D one (§4.5): K₂D = K₃D + G/3.
  public static func planeStrainBulkModulus(bulk3D k: Double, shearModulus g: Double) -> Double { k + g / 3 }

  /// Simple-shear velocity gradient u = γ̇·y: C = [[0, γ̇], [0, 0]].
  public static func simpleShear(_ rate: Double) -> simd_double2x2 {
    simd_double2x2(columns: (SIMD2(0, 0), SIMD2(rate, 0)))
  }

  /// A velocity gradient from its components in the §0.2 convention.
  public static func velocityGradient(c11: Double, c12: Double, c21: Double, c22: Double) -> simd_double2x2 {
    simd_double2x2(columns: (SIMD2(c11, c21), SIMD2(c12, c22)))
  }
}
