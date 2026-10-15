import Foundation

/// The material presets of LabKit's continuum engine (Rheo's 13 materials plus optional extras), as
/// `ContinuumMaterial` values in SI units. Owned by WP-O.
///
/// Source of every number: `Rheo/Documentation/research/rheology-models.md` §6 (revision 2), whose
/// machine-readable copy is `calc/presets2.json` (written by `presets2.py`). Where the table rounds
/// (for example K "5.0 × 10⁴"), the exact JSON value is used. Provenance tags follow §6:
/// **M** measured (primary source read), **L** literature value or range (secondary source),
/// **C** computed or fitted from M/L data, **T** tuned for the toy.
///
/// Softening rules (§5.3): ρ, g, τ_y, k, n, Newtonian η, Maxwell λ, E_a and the DST/MR laws stay
/// physical. K is always softened (`oracleBulkModulus`: ≤ 3 % hydrostatic compression over a 154 mm
/// tank). G is softened only where the physical value breaks the substep budget (Silly Putty, jammed
/// oobleck, MR on-state), and for Newtonian/paste presets it is a numerical value chosen so that
/// Wi_num = η_eff(γ̇_ref)·γ̇_ref/G ≤ 0.1 and the yield strain τ_y/G ≤ 0.05.
///
/// Fields the presets set beyond §6:
/// - `wallYieldFactor = 0` for every preset: §4.10.5 item 3 recommends omitting the gap yield term
///   (pastes slip on smooth glass). Without slip, mayonnaise in a 5–10 mm cell would never slide.
/// - Initial state is not part of `ContinuumMaterial`: particles start rested (λ = 1, f = 0) at
///   `referenceTemperature` (293.15 K, but 1403.15 K for lava). The rheopectic extra should start at λ = 0.
/// - The J clamp [0.6, 1.5] of §4.8 is global (LabKitMPMReference `EVP.minimumVolumeRatio/maximumVolumeRatio`).
public enum ContinuumPresets {

  // MARK: - Helpers

  /// Standard gravity used by `presets2.py`, m/s².
  public static let standardGravity = 9.80665
  /// Tank height used for the oracle's K rule, m (`presets2.py` TANK_H).
  public static let referenceTankHeight = 0.154

  /// The oracle's softened 2D bulk modulus (§5.3 item 1): K = max(ρ·g·H/compression, 2G), rounded to
  /// the nearest 100 Pa as in `presets2.py`. With the defaults a full tank compresses by at most 3 %.
  public static func oracleBulkModulus(
    density: Double, shearModulus: Double, tankHeight: Double = referenceTankHeight,
    maxCompression: Double = 0.03, gravity: Double = standardGravity
  ) -> Double {
    let k = max(density * gravity * tankHeight / maxCompression, 2 * shearModulus)
    return (k / 100).rounded() * 100
  }

  /// Carlson's MR yield saturation τ_sat = C·271 700·φ^1.5239 Pa (§3.8; C = 1 hydrocarbon oil,
  /// 0.95 silicone oil, 1.16 water). φ = 0.315 (LORD MRF-132DG) gives 46.7 kPa.
  public static func carlsonYieldSaturation(solidsFraction phi: Double, carrier c: Double = 1) -> Double {
    c * 271_700 * pow(phi, 1.5239)
  }

  /// Carlson's saturation field H_sat = 1/(6.33 × 10⁻⁶) A/m = 1.58 × 10⁵ A/m (§3.8, §4.2 d).
  public static let carlsonSaturationField = 1 / 6.33e-6

  // MARK: - The 13 Rheo presets (§6.1, §6.2)

  /// Water-like. ρ, η = 1.0 mPa·s at 20 °C and E_a = 17.5 kJ/mol (effective Arrhenius between 15 and
  /// 25 °C): M/C (Cheng 2008). G = 100 Pa is numerical (λ_num = 10 µs), tension limit 10 Pa: T.
  public static let waterLike = ContinuumMaterial(
    density: 1000, shearModulus: 100, bulkModulus: 50_300, tensionLimit: 10,
    consistency: 1.0e-3, flowIndex: 1,
    activationEnergy: 17_500, referenceTemperature: 293.15,
    wallYieldFactor: 0)

  /// Honey. η = 15.4 Pa·s at 20 °C, E_a = 85 kJ/mol (viscosity halves every 6 K): L (Saxena, Panicker &
  /// Gautam 2014, brand II). G = 10 kPa is numerical (Wi_num = 0.046 at 30 s⁻¹): T.
  public static let honey = ContinuumMaterial(
    density: 1420, shearModulus: 1.0e4, bulkModulus: 71_500, tensionLimit: 50,
    consistency: 15.4, flowIndex: 1,
    activationEnergy: 85_000, referenceTemperature: 293.15,
    wallYieldFactor: 0)

  /// Ketchup. Herschel–Bulkley τ_y = 10 + 15λ Pa, k = 8 Pa·s^0.3, n = 0.30 inside the Koocheki 2009
  /// ranges (τ_y 4–30, k 8–18, n 0.22–0.30): L; the broken/rested split, t_build = 20 s, k_break = 0.5
  /// and E_a = 10 kJ/mol: T. G = 500 Pa (stiffened; yield strain 0.05, Wi_num 0.094): T.
  public static let ketchup = ContinuumMaterial(
    density: 1120, shearModulus: 500, bulkModulus: 56_400, tensionLimit: 30,
    yieldBroken: 10, yieldStructure: 15, structureExponent: 1,
    consistency: 8.0, flowIndex: 0.30,
    activationEnergy: 10_000, referenceTemperature: 293.15,
    buildRate: 1.0 / 20, breakShear: 0.5,
    wallYieldFactor: 0)

  /// Mayonnaise. τ_y = 60 + 20λ Pa, k = 10 Pa·s^0.35, n = 0.35 within the Heliyon 2020 study and
  /// application-note ranges: L; t_build = 50 s, k_break = 0.2, E_a = 10 kJ/mol: T. G = 2 kPa: T.
  /// ℓ_y = τ_y/(ρg) = 8.9 mm: a blob stands 1–2 cm tall (5 cm on the Moon).
  public static let mayonnaise = ContinuumMaterial(
    density: 920, shearModulus: 2000, bulkModulus: 46_300, tensionLimit: 120,
    yieldBroken: 60, yieldStructure: 20, structureExponent: 1,
    consistency: 10, flowIndex: 0.35,
    activationEnergy: 10_000, referenceTemperature: 293.15,
    buildRate: 1.0 / 50, breakShear: 0.2,
    wallYieldFactor: 0)

  /// Toothpaste. τ_y = 150 Pa within the 41–286 Pa reports (TA Instruments RH025 and toothpaste
  /// studies): L; k = 30 Pa·s^0.35, n = 0.35, E_a = 10 kJ/mol: T. G = 5 kPa: T. No thixotropy.
  public static let toothpaste = ContinuumMaterial(
    density: 1350, shearModulus: 5000, bulkModulus: 68_000, tensionLimit: 200,
    yieldBroken: 150,
    consistency: 30, flowIndex: 0.35,
    activationEnergy: 10_000, referenceTemperature: 293.15,
    wallYieldFactor: 0)

  /// Oobleck (cornstarch in water, about 1.2:1 by mass). Lagged Wyart–Cates DST block (§4.2 c):
  /// φ₀ = 0.593, φ_m = 0.452, γ* = 0.197: M (Han, Wyart, Peters & Jaeger 2018); φ = 0.52 from the
  /// 1.2:1 recipe via Han's eq. 11: C; σ* = 5 Pa with the WC form 1 − e^(−σ/σ*) (kitchen reports
  /// 2.6–8 Pa; Han's density-matched fit is 20.4 Pa with this form, never mix forms): L/T; solvent
  /// η_s = 1 mPa·s with water's E_a = 17.5 kJ/mol; jam branch (t_jam = 0.05 s, τ_jam = 4 kPa,
  /// η_post = 2 Pa·s, γ_break = 0.1, Δφ_min = 0.01, w_jam = 0.02): T. G = 20 kPa for the jammed solid
  /// (physical ≫ 10⁶ Pa, softened).
  ///
  /// Rest melt (Rheo wave 2, 8 October 2026): `restMelt = 1`, t_melt = 0.15 s. With the §4.2 c law (`restMelt = 0`)
  /// a jammed region that carries its own weight keeps τ̄ ≫ σ*, so f stays at f_ss ≈ 1 and towers and holes stand
  /// forever (measured in the Rheo tank: 56 % of a 60/30 mm step stayed jammed for 3 s; a 0.5 m/s poke left 93 %
  /// jammed). Han, Peters & Jaeger 2016 (Nat. Commun. 7, 12243) report that the jammed region liquefies once the
  /// impactor stops: contacts need ongoing deformation. With w_rest = 1 they relax toward none at rest, so steady
  /// shear jams only above γ̇ ≈ γ*/t_melt ≈ 1.3 s⁻¹ *and* σ* (the strain-rate gate plus the stress law). Measured on
  /// the GPU in the 71 mm tank (Δx 2 mm, 120 Hz): the step levels in 0.9 s; a 2 cm/s finger meets about 0.2 kPa and
  /// jams ≤ 1 % of the pool, a 0.5 m/s poke meets 7 kPa and jams 95 %, whose jammed fraction then halves in about
  /// 0.15–0.2 s and the surface is flat (≤ 3 mm) about 0.5–1.7 s after release: T (form I, rate from Han 2016's
  /// "liquefies once the impactor stops", tuned to 0.2–1 s).
  /// τ_jam 1.5 → 4 kPa (same date): the jammed solid cracked so early that a 0.5 m/s finger met only 7 kPa, below what
  /// a fingertip pushes in Rheo; at 4 kPa it meets 14 kPa (Han 2018's front law gives ρkU² ≈ 2–9 kPa at 0.5–1 m/s,
  /// before the jammed column reaches the floor of a shallow pool, Mukhopadhyay 2018): T.
  /// Plastic drive (same date): contacts are built by the flow rate γ̇ₚ, not the total rate, so the elastic wobble of a
  /// jammed region (G softened ≥ 50×, so its strain rates are ≥ 50× too large) does not keep re-jamming it. Measured on
  /// the GPU with a 12 mm layer on a floor vibrating at 120 Hz after a poke: at 0.8 g the total-rate law kept 62 % jammed
  /// and the hole open; the plastic-rate law kept 4 % and the hole closed; rest levelling, pokes and the melt are
  /// unchanged within 0.2 s: T.
  /// Tension limit 0 → 1.5 kPa (same date): with none, a layer on a floor vibrating above 1 g tore itself into a sparse
  /// jammed cloud (the solver's floor lets fluid leave it; a real liquid layer is held down by the air). A dense starch
  /// suspension holds together by capillary suction where grains poke through its surface, up to about γ/a ≈ 0.07 N/m ÷
  /// 7.5 µm ≈ 9 kPa (Brown & Jaeger 2012); 1.5 kPa keeps a 17 g layer coherent, still lets a jam crack, and leaves the
  /// refill after a slow poke as fast as with none (3 kPa slowed it): T.
  public static let oobleck = ContinuumMaterial(
    density: 1230, shearModulus: 2.0e4, bulkModulus: 61_900, tensionLimit: 1500,
    consistency: 0, flowIndex: 1,
    activationEnergy: 17_500, referenceTemperature: 293.15,
    dst: ContinuumMaterial.DST(
      phi: 0.52, phiFrictionless: 0.593, phiFrictional: 0.452, solventViscosity: 1.0e-3,
      onsetStress: 5.0, onsetForm: 0, strainScale: 0.197, meltTime: 0.15, jamTime: 0.05,
      jamFailureStress: 4000, postFailureViscosity: 2.0, breakStrain: 0.1, gapFloor: 0.01, blendWidth: 0.02,
      restMelt: 1, plasticDrive: true),
    wallYieldFactor: 0)

  /// Slime (PVA–borax, 2.75 wt % PVA, 1.25 wt % borax). Nearly Maxwellian: G₀ = 1.11 kPa (J₀ = 0.9 × 10⁻³
  /// Pa⁻¹) and λ = 0.402 s, so η₀ = 447 Pa·s: M (Ramlawi, Hossain, Shetty & Ewoldt 2024). E_a = 42 kJ/mol
  /// (borate–diol complex): L (Schultz & Myers 1969). λ here = 447/1100 = 0.406 s.
  public static let slime = ContinuumMaterial(
    density: 1010, shearModulus: 1100, bulkModulus: 50_800, tensionLimit: 2000,
    consistency: 447, flowIndex: 1,
    activationEnergy: 42_000, referenceTemperature: 293.15,
    wallYieldFactor: 0)

  /// Silly Putty. E ≈ 1.7 MPa (G ≈ 567 kPa), λ ≈ 0.10–0.14 s, slow-compression η ≈ 8 × 10⁴ Pa·s: L
  /// (Cross 2012). G softened 28× to 20 kPa with λ = 0.14 s kept, so η_toy = G·λ = 2.8 × 10³ Pa·s
  /// (§5.3 item 3): bounce and snap times are real, slow creep is 28× faster than real. E_a = 40 kJ/mol:
  /// T (no source found).
  public static let sillyPutty = ContinuumMaterial(
    density: 1100, shearModulus: 2.0e4, bulkModulus: 55_400, tensionLimit: 4000,
    consistency: 2.0e4 * 0.14, flowIndex: 1,
    activationEnergy: 40_000, referenceTemperature: 293.15,
    wallYieldFactor: 0)

  /// Yogurt (stirred). Thixotropic Herschel–Bulkley: τ_y = 5 + 25λ Pa, k = 4·(1 + 2λ) Pa·s^0.4,
  /// n = 0.40; slow, partial recovery (t_build = 100 s, k_break = 0.2); E_a = 15 kJ/mol. Form: L
  /// (Tiu–Boger-type structural models); values: T. G = 800 Pa (Wi_num 0.096, yield strain 0.037): T.
  public static let yogurt = ContinuumMaterial(
    density: 1040, shearModulus: 800, bulkModulus: 52_400, tensionLimit: 40,
    yieldBroken: 5, yieldStructure: 25, structureExponent: 1,
    consistency: 4.0, flowIndex: 0.40, consistencyStructure: 2.0,
    activationEnergy: 15_000, referenceTemperature: 293.15,
    buildRate: 1.0 / 100, breakShear: 0.2,
    wallYieldFactor: 0)

  /// Quicksand. ρ ≈ 2000 kg/m³: L (Khaldoun, Eiser, Wegdam & Bonn 2005). Coussot-type viscosity
  /// bifurcation through the bounded Moore λ (§3.6): τ_y = 150λ³ Pa, k = 0.05·(1 + 2 × 10⁴λ³) Pa·s,
  /// t_build = 10 s, k_break = 1, and w_vib = 0.5 so shaking (total, not only plastic, shear rate)
  /// liquefies it: form L (Coussot et al. 2002), values T. Single phase: it cannot segregate (§3.6).
  /// Rested yield 60 → 150 Pa (Rheo wave 2, 8 October 2026): an 8 mm steel ball in the thin tank presses about
  /// 2.9 N/m, which a 2D yield-stress bed carries only above about 60 Pa (bearing ≈ 12·τ_y·r), so at 60 Pa the "ball
  /// rests on firm quicksand" demonstration sank before any shaking: T. Yield strain τ_y/G = 0.03.
  /// k_break 1 → 0.5 and w_vib 0.5 → 0.2 (same date): with one strain unit breaking the structure and half the total
  /// rate counted, the elastic ringing of a fresh fill and a prop's landing unbuilt a quarter of the rested bed and a
  /// glass marble sank through "firm" quicksand; now the bed keeps λ ≈ 0.9 under the marble, and a 3 g shake at 50 Hz
  /// (which yields the bed) still liquefies it to λ ≈ 0.1 within about 2 s and the marble sinks (Khaldoun 2005:
  /// liquefaction needs a sufficient stress): T.
  /// Tension limit 0 → 1 kPa (Rheo wave 2 verification, same date): with none, the 40 mm bed on a floor shaking at 3 g
  /// (50 Hz) left the floor every cycle (the solver's floor lets fluid leave it; a real saturated bed is held down by the
  /// air and the water's suction) and puffed up into a sparse cloud 77 mm tall that stayed 58 mm tall 2 s after the
  /// shaking stopped. Wet sand holds together by capillary suction between grains at its surface (kilopascals for
  /// sub-millimetre grains); 1 kPa keeps the bed ≤ 51 mm while shaken and back to 44 mm after, and the bed still
  /// liquefies (λ ≈ 0.05): T.
  public static let quicksand = ContinuumMaterial(
    density: 2000, shearModulus: 5000, bulkModulus: 100_700, tensionLimit: 1000,
    yieldBroken: 0, yieldStructure: 150, structureExponent: 3,
    consistency: 0.05, flowIndex: 1, consistencyStructure: 2.0e4,
    activationEnergy: 17_500, referenceTemperature: 293.15,
    buildRate: 1.0 / 10, breakShear: 0.5, vibrationWeight: 0.2,
    wallYieldFactor: 0)

  /// MR fluid (LORD MRF-132DG-like). ρ = 3060 kg/m³ and φ = 0.315 from the datasheet's 80.98 wt %
  /// solids: M/C. Off state Bingham τ_y0 = 7.6 Pa, μ_p = 0.178 Pa·s fitted to MRF-132LD (Yang 2001,
  /// Table 2.1): C. Field yield τ_field = τ_sat·tanh(|H|/H_sat) with τ_sat = 271 700·φ^1.5239 = 46.7 kPa
  /// and H_sat = 1.58 × 10⁵ A/m (Carlson, quoted by COMSOL 2016): M; clamped at 0.05·G = 1.5 kPa; first-order
  /// lag T₆₃ = 1 ms (Kubík et al. 2022: 0.8–1.4 ms); 100 µT magnetometer dead zone: T. χ₀ = 1.91·φ^1.133·10.97
  /// = 5.66 is the initial slope of Carlson's B–H law (C), used for the Kelvin body force. E_a = 20 kJ/mol on k: T.
  public static let mrFluid = ContinuumMaterial(
    density: 3060, shearModulus: 3.0e4, bulkModulus: 154_000, tensionLimit: 50,
    yieldBroken: 7.6,
    consistency: 0.18, flowIndex: 1,
    activationEnergy: 20_000, referenceTemperature: 293.15,
    field: ContinuumMaterial.FieldResponse(
      yieldSaturation: carlsonYieldSaturation(solidsFraction: 0.315), saturationField: carlsonSaturationField,
      clampFractionOfG: 0.05, responseTime: 1.0e-3, deadZone: 100e-6,
      susceptibility: 1.91 * pow(0.315, 1.133) * 10.97),
    wallYieldFactor: 0)

  /// Paint (architectural latex). Fit τ_y = 3 Pa, k = 3.5 Pa·s^0.65, n = 0.65 to the coatings targets
  /// (25–100 Pa·s at low shear, ICI 0.1–0.2 Pa·s at 10⁴ s⁻¹; gives 37.8 Pa·s at 0.1 s⁻¹ and 0.140 Pa·s at
  /// 10⁴ s⁻¹): C from L. Thixotropy (τ_y = 3 + 2λ, t_build = 2 s, k_break = 0.05) and E_a = 15 kJ/mol: T.
  /// G = 500 Pa: T.
  public static let paint = ContinuumMaterial(
    density: 1300, shearModulus: 500, bulkModulus: 65_400, tensionLimit: 20,
    yieldBroken: 3.0, yieldStructure: 2.0, structureExponent: 1,
    consistency: 3.5, flowIndex: 0.65,
    activationEnergy: 15_000, referenceTemperature: 293.15,
    buildRate: 1.0 / 2, breakShear: 0.05,
    wallYieldFactor: 0)

  /// Lava (basalt near 1130 °C). Bingham τ_y = 100 Pa (70 and 120 Pa measured), μ_p = 700 Pa·s
  /// (650–750): L (Shaw et al. 1968, Makaopuhi). ρ = 2600: L. E_a = 171 kJ/mol on both k and τ_y, from the
  /// Kīlauea pāhoehoe pair (116 Pa·s at 1150 °C, 167 at 1115 °C, Chevrel et al. 2018 summary): C from S,
  /// two points only. T_ref = 1403.15 K, so lava particles start at 1130 °C. G = 50 kPa (glass ≈ 10¹⁰ Pa,
  /// irrelevant). No tension.
  /// Cold band 230 K (LK-FIX, 8 October 2026): the shift factors follow the temperature down to 900 °C instead of
  /// stopping at T_ref − 40 K = 1090 °C, so lava erupted at 1170 °C (a_T = 0.67) keeps stiffening as it cools, to
  /// a_T = 17.7 at 900 °C (k 12.4 kPa·s, τ_y 1.8 kPa) with the same Arrhenius law: T. Real basalt stiffens far more
  /// below about 1100 °C as it crystallises (orders of magnitude); this extrapolates the two-point E_a and is a toy.
  public static let lava = ContinuumMaterial(
    density: 2600, shearModulus: 5.0e4, bulkModulus: 130_900, tensionLimit: 0,
    yieldBroken: 100,
    consistency: 700, flowIndex: 1,
    activationEnergy: 171_000, yieldActivationEnergy: 171_000, referenceTemperature: 1403.15,
    wallYieldFactor: 0, temperatureBandBelow: 230)

  /// The 13 Rheo presets in shelf order, with display names (UI copy).
  public static let all: [(name: String, material: ContinuumMaterial)] = [
    ("Water-like", waterLike),
    ("Honey", honey),
    ("Ketchup", ketchup),
    ("Mayonnaise", mayonnaise),
    ("Toothpaste", toothpaste),
    ("Oobleck", oobleck),
    ("Slime", slime),
    ("Silly Putty", sillyPutty),
    ("Yogurt", yogurt),
    ("Quicksand", quicksand),
    ("MR fluid", mrFluid),
    ("Paint", paint),
    ("Lava", lava),
  ]

  // MARK: - Optional extras (§6.4)

  /// Rheopectic cream: structure *builds* under shear and decays at rest (§3.7). τ_y = 2 + 40λ Pa,
  /// A₀ = 0, A₁ = 0.05, B₀ = 0.02 s⁻¹: form L, values T. k = 5 Pa·s^0.5, n = 0.5, ρ = 1010, G = 1 kPa: T.
  /// Start its particles at λ = 0 (the rested state of a rheopectic material).
  public static let rheopecticCream = ContinuumMaterial(
    density: 1010, shearModulus: 1000, bulkModulus: oracleBulkModulus(density: 1010, shearModulus: 1000),
    tensionLimit: 40,
    yieldBroken: 2, yieldStructure: 40, structureExponent: 1,
    consistency: 5, flowIndex: 0.5,
    buildRate: 0, buildShear: 0.05, breakRate: 0.02, breakShear: 0,
    wallYieldFactor: 0)

  /// Ferrofluid (Ferrotec APG 512a): Newtonian η = 0.12 Pa·s, ρ = 1236 kg/m³, χ₀ = 1.2023, M_s = 28.7 kA/m:
  /// M (Gollwitzer et al. 2009, Table 1). No yield stress; the Kelvin body force uses χ₀. `saturationField`
  /// is M_s/χ₀ (where the linear law would reach saturation) and is unused while `yieldSaturation` is 0.
  /// Rosensweig spikes are an analytic overlay, not emergent (§3.10). G = 500 Pa numerical: T.
  public static let ferrofluid = ContinuumMaterial(
    density: 1236, shearModulus: 500, bulkModulus: oracleBulkModulus(density: 1236, shearModulus: 500),
    tensionLimit: 10,
    consistency: 0.12, flowIndex: 1,
    field: ContinuumMaterial.FieldResponse(
      yieldSaturation: 0, saturationField: 28_700 / 1.2023, clampFractionOfG: 0.05,
      responseTime: 1.0e-3, deadZone: 100e-6, susceptibility: 1.2023),
    wallYieldFactor: 0)

  /// Blood, Carreau (η₀ = 0.056, η_∞ = 0.00345 Pa·s, λ = 3.313 s, n = 0.3568: L, Cho & Kensey 1991) mapped
  /// onto the sum-of-rates law (§3.2): φ₀ = 1/(η₀ − η_∞), k = (η₀ − η_∞)·λ^(n−1). **The parallel η_∞ cannot be
  /// represented** (the flow law is a sum of rates, i.e. branches in series), so above about 100 s⁻¹ this
  /// under-predicts the viscosity (≈ 0.3 mPa·s instead of 3.7 mPa·s at 1000 s⁻¹). ρ = 1060: L. G = 100 Pa: T.
  public static let blood = ContinuumMaterial(
    density: 1060, shearModulus: 100, bulkModulus: oracleBulkModulus(density: 1060, shearModulus: 100),
    tensionLimit: 10,
    consistency: (0.056 - 0.00345) * pow(3.313, 0.3568 - 1), flowIndex: 0.3568,
    fluidity: 1 / (0.056 - 0.00345),
    wallYieldFactor: 0)

  /// Shampoo (wormlike micelles): single-mode Maxwell with η₀ = 8 Pa·s and λ = 0.2 s (within η₀ 5–10 Pa·s,
  /// λ 0.05–0.5 s): L/T. G = η₀/λ = 40 Pa. The b̄ₑ model thins above Wi ≈ 0.3 (§4.6), as micelles do.
  public static let shampoo = ContinuumMaterial(
    density: 1020, shearModulus: 40, bulkModulus: oracleBulkModulus(density: 1020, shearModulus: 40),
    tensionLimit: 100,
    consistency: 8, flowIndex: 1,
    wallYieldFactor: 0)

  /// Glycerol: η = 1.414 Pa·s at 20 °C (Cheng 2008 formula): C. Temperature uses the effective Arrhenius
  /// E_a = 66.0 kJ/mol between 15 and 25 °C (C); the better VFT fit η = exp(−11.657 + 1558.36/(T − 163.20)) Pa·s
  /// (§3.1) cannot be expressed by `ContinuumMaterial`, so the Arrhenius form drifts outside about ±10 K.
  /// ρ = 1261: L. G = 1 kPa (Wi_num 0.042 at 30 s⁻¹): T.
  public static let glycerol = ContinuumMaterial(
    density: 1261, shearModulus: 1000, bulkModulus: oracleBulkModulus(density: 1261, shearModulus: 1000),
    tensionLimit: 50,
    consistency: 1.414, flowIndex: 1,
    activationEnergy: 66_000, referenceTemperature: 293.15,
    wallYieldFactor: 0)

  /// The optional extras (§6.4), not on Rheo's default shelf.
  public static let extras: [(name: String, material: ContinuumMaterial)] = [
    ("Rheopectic cream", rheopecticCream),
    ("Ferrofluid", ferrofluid),
    ("Blood", blood),
    ("Shampoo", shampoo),
    ("Glycerol", glycerol),
  ]

  /// Looks a preset (or extra) up by its display name, ignoring case.
  public static func named(_ name: String) -> ContinuumMaterial? {
    (all + extras).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.material
  }
}
