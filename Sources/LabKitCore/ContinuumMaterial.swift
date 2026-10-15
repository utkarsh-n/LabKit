import Foundation

/// SI parameters of LabKit's unified elasto-viscoplastic (EVP) continuum model.
///
/// One parameter set drives both solvers: the GPU MPM engine (`LabKitMPM`, which converts it to its
/// float layout) and the CPU Double oracle (`LabKitMPMReference`). The equations are specified in
/// `Rheo/Documentation/research/rheology-models.md` §4 and Appendix A (`RheoMaterial`); the field
/// comments give the Appendix A name in brackets so the two can be checked against each other.
///
/// The flow law is a sum of monotone branches,
/// `γ̇ₚ(τ) = φ₀·τ + ((τ − τ_y)₊ / k)^(1/n) + φ_f·(τ − τ_f)₊`,
/// solved by a backward-Euler return map on the isochoric elastic left Cauchy–Green tensor, so
/// viscosity and yield never limit the time step. Elasticity (G, K) is explicit and may be softened
/// for the toy (§5 of the rheology note says which groups must stay physical).
public struct ContinuumMaterial: Sendable, Codable, Equatable, Hashable {
  // MARK: Mechanical core
  /// ρ, kg/m³ [rho].
  public var density: Double
  /// G, Pa: shear modulus of the elastic memory (toy value, possibly softened) [G].
  public var shearModulus: Double
  /// K, Pa: 2D bulk modulus of the volumetric law [K].
  public var bulkModulus: Double
  /// Largest Cauchy tension before the material cavitates or tears, Pa [pTens].
  public var tensionLimit: Double

  // MARK: Yield and flow (Herschel–Bulkley + Newtonian + failure branches)
  /// Yield stress of fully broken structure, Pa [ty0]. τ_y = yieldBroken + yieldStructure·λ^structureExponent.
  public var yieldBroken: Double
  /// Extra yield stress carried by intact structure (λ = 1), Pa [dtyLam].
  public var yieldStructure: Double
  /// Exponent m on λ for yield and consistency [mLam].
  public var structureExponent: Double
  /// k, Pa·sⁿ: Herschel–Bulkley consistency; 0 switches the HB branch off [k0].
  public var consistency: Double
  /// n, flow index in (0.15, 1]. Thickening comes from the DST block, never from n > 1 [n].
  public var flowIndex: Double
  /// β: k ← k·(1 + β·λ^m) [betaLam].
  public var consistencyStructure: Double
  /// φ₀ = 1/η₀, 1/(Pa·s): Newtonian branch; 0 = off [fluidity0].
  public var fluidity: Double
  /// τ_f, Pa: failure branch threshold; `.infinity` = off [tauFail].
  public var failureStress: Double
  /// φ_f, 1/(Pa·s): failure-branch fluidity [fluidityFail].
  public var failureFluidity: Double

  // MARK: Temperature (Arrhenius shift factors)
  /// E_a on k and φ₀ (J/mol); 0 = temperature independent [Ea].
  public var activationEnergy: Double
  /// E_a on τ_y (J/mol) [EaY].
  public var yieldActivationEnergy: Double
  /// T_ref, K [Tref].
  public var referenceTemperature: Double
  /// How far below T_ref the shift factors follow the temperature, K; nil = 40 K, the global band of
  /// rheology-models.md §4.8 (the flow law sees T clamped to [T_ref − band, T_ref + 80 K]). A material that is meant to
  /// stiffen over a wide cooling range (lava from 1170 to 900 °C) sets a wider band. Added by LK-FIX, 8 October 2026.
  public var temperatureBandBelow: Double?

  // MARK: Thixotropy (generalised Moore): dλ/dt = (A₀ + A₁γ̇)(1 − λ) − (B₀ + B₁γ̇)λ
  /// A₀, 1/s: rebuild at rest (1/t_build) [A0].
  public var buildRate: Double
  /// A₁: shear-induced build-up (rheopexy) [A1].
  public var buildShear: Double
  /// B₀, 1/s: breakdown at rest [B0].
  public var breakRate: Double
  /// B₁: shear-induced breakdown [B1].
  public var breakShear: Double
  /// w_vib: share of total (not plastic) shear rate that drives λ, so vibration liquefies quicksand [wVib].
  public var vibrationWeight: Double

  // MARK: Discontinuous shear thickening (lagged Wyart–Cates), active when `dst` is non-nil
  public var dst: DST?

  // MARK: Field response (magnetorheological), active when `field` is non-nil
  public var field: FieldResponse?

  /// Share of τ_y acting at walls (1 = no wall slip) [wallYieldFactor, mpm-metal.md §11].
  public var wallYieldFactor: Double

  public struct DST: Sendable, Codable, Equatable, Hashable {
    /// φ: solids volume fraction (the Packing knob) [phi].
    public var phi: Double
    /// φ₀: frictionless jamming fraction [phi0].
    public var phiFrictionless: Double
    /// φ_m: frictional jamming fraction [phim].
    public var phiFrictional: Double
    /// η_s, Pa·s: solvent viscosity [etaS].
    public var solventViscosity: Double
    /// σ*, Pa: onset stress [sStar].
    public var onsetStress: Double
    /// 0: f_eq = 1 − e^(−σ/σ*); 1: f_eq = e^(−σ*/σ) [fForm].
    public var onsetForm: Int
    /// γ*: strain scale of the contact-fraction relaxation [gStar].
    public var strainScale: Double
    /// s: melt time at rest [tMelt].
    public var meltTime: Double
    /// s: jammed creep time [tJam].
    public var jamTime: Double
    /// Pa: stress at which a jammed region fails (cracks) [tauJam].
    public var jamFailureStress: Double
    /// Pa·s: viscosity after failure [etaPost].
    public var postFailureViscosity: Double
    /// Unjamming strain [gBreak].
    public var breakStrain: Double
    /// Floor on φ_J − φ [dphiMin].
    public var gapFloor: Double
    /// Blend width of the jam switch [wJam].
    public var blendWidth: Double
    /// w_rest ∈ [0, 1]: share of the rest melt (rate 1/t_melt) that relaxes the contact fraction toward 0 instead of
    /// toward f_ss(τ̄) [restMelt]. 0 is the lagged-f law of rheology-models.md §4.2 c,
    /// df/dt = (γ̇/γ* + 1/t_melt)(f_ss − f); 1 is df/dt = (γ̇/γ*)(f_ss − f) − f/t_melt, in which frictional contacts
    /// are kept only by ongoing deformation, so a jammed region that carries a static load (its own weight) still
    /// liquefies once the impactor stops (Han, Peters & Jaeger 2016). Steady shear then needs γ̇ ≳ γ*/t_melt to jam.
    public var restMelt: Double
    /// Which shear rate builds frictional contacts [plasticDrive]: false = the total rate γ̇ (rheology-models.md
    /// §4.2 c); true = the plastic (flow) rate γ̇ₚ of the previous update. Contacts form when grains rearrange, i.e.
    /// when the suspension flows; the elastic strain of an already-jammed region (softened G, so far larger than real)
    /// does not rearrange anything. With the total rate a jammed layer on a vibrating floor re-jams itself on every
    /// cycle of its own elastic wobble (measured: 0.8 g at 120 Hz kept 62 % of a 12 mm oobleck layer jammed and a
    /// poked hole open); with the plastic rate it stays liquid. In steady flow the two are equal.
    public var plasticDrive: Bool

    public init(phi: Double, phiFrictionless: Double, phiFrictional: Double, solventViscosity: Double,
                onsetStress: Double, onsetForm: Int, strainScale: Double, meltTime: Double, jamTime: Double,
                jamFailureStress: Double, postFailureViscosity: Double, breakStrain: Double, gapFloor: Double,
                blendWidth: Double, restMelt: Double = 0, plasticDrive: Bool = false) {
      self.phi = phi; self.phiFrictionless = phiFrictionless; self.phiFrictional = phiFrictional
      self.solventViscosity = solventViscosity; self.onsetStress = onsetStress; self.onsetForm = onsetForm
      self.strainScale = strainScale; self.meltTime = meltTime; self.jamTime = jamTime
      self.jamFailureStress = jamFailureStress; self.postFailureViscosity = postFailureViscosity
      self.breakStrain = breakStrain; self.gapFloor = gapFloor; self.blendWidth = blendWidth
      self.restMelt = restMelt
      self.plasticDrive = plasticDrive
    }
  }

  public struct FieldResponse: Sendable, Codable, Equatable, Hashable {
    /// τ_sat, Pa: τ_field = τ_sat·tanh(|H|/H_sat) (Carlson) [fieldScale].
    public var yieldSaturation: Double
    /// H_sat, A/m [1/fieldK].
    public var saturationField: Double
    /// τ_field ≤ fraction·G, for stability [fieldClampFracG].
    public var clampFractionOfG: Double
    /// T₆₃, s: first-order lag of the field response (applied per frame on the CPU).
    public var responseTime: Double
    /// |B| below this (T) is treated as zero, so the Earth's field does nothing.
    public var deadZone: Double
    /// χ_eff for the Kelvin body force toward a magnet; 0 = no body force.
    public var susceptibility: Double

    public init(yieldSaturation: Double, saturationField: Double, clampFractionOfG: Double,
                responseTime: Double, deadZone: Double, susceptibility: Double) {
      self.yieldSaturation = yieldSaturation; self.saturationField = saturationField
      self.clampFractionOfG = clampFractionOfG; self.responseTime = responseTime
      self.deadZone = deadZone; self.susceptibility = susceptibility
    }
  }

  /// A Newtonian fluid at rest with every optional branch off. Presets start from this and override.
  public init(density: Double, shearModulus: Double, bulkModulus: Double, tensionLimit: Double = 0,
              yieldBroken: Double = 0, yieldStructure: Double = 0, structureExponent: Double = 1,
              consistency: Double = 0, flowIndex: Double = 1, consistencyStructure: Double = 0,
              fluidity: Double = 0, failureStress: Double = .infinity, failureFluidity: Double = 0,
              activationEnergy: Double = 0, yieldActivationEnergy: Double = 0, referenceTemperature: Double = 293.15,
              buildRate: Double = 0, buildShear: Double = 0, breakRate: Double = 0, breakShear: Double = 0,
              vibrationWeight: Double = 0, dst: DST? = nil, field: FieldResponse? = nil, wallYieldFactor: Double = 1,
              temperatureBandBelow: Double? = nil) {
    self.density = density; self.shearModulus = shearModulus; self.bulkModulus = bulkModulus
    self.tensionLimit = tensionLimit
    self.yieldBroken = yieldBroken; self.yieldStructure = yieldStructure; self.structureExponent = structureExponent
    self.consistency = consistency; self.flowIndex = flowIndex; self.consistencyStructure = consistencyStructure
    self.fluidity = fluidity; self.failureStress = failureStress; self.failureFluidity = failureFluidity
    self.activationEnergy = activationEnergy; self.yieldActivationEnergy = yieldActivationEnergy
    self.referenceTemperature = referenceTemperature
    self.buildRate = buildRate; self.buildShear = buildShear; self.breakRate = breakRate; self.breakShear = breakShear
    self.vibrationWeight = vibrationWeight; self.dst = dst; self.field = field; self.wallYieldFactor = wallYieldFactor
    self.temperatureBandBelow = temperatureBandBelow
  }

  /// The molar gas constant used by the Arrhenius shift factors, J/(mol·K).
  public static let gasConstant = 8.314462618
}
