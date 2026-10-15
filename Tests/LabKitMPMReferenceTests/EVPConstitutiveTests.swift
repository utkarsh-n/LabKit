// EVP.update at constitutive level: V6, V7, V8 and V12 of rheology-models.md §7, plus the return map, the §4.8 clamps
// and the oobleck (DST) behaviour of §4.7. Fast: single particles, prescribed velocity gradients.
import LabKitCore
import LabKitMPMReference
import simd
import XCTest

/// A synthetic Herschel–Bulkley test fluid without thixotropy or tension cap.
func testFluid(rho: Double = 1000, G: Double = 5e3, K: Double = 2e4, ty: Double = 0, k: Double = 1, n: Double = 1)
  -> ContinuumMaterial
{
  ContinuumMaterial(density: rho, shearModulus: G, bulkModulus: K, tensionLimit: .infinity,
                    yieldBroken: ty, consistency: k, flowIndex: n)
}

final class EVPConstitutiveTests: XCTestCase {

  // MARK: V6 Maxwell relaxation

  /// τ follows the backward-Euler discrete Maxwell decay Gγ₀(1 + Δt/λ)^(−n) to ≤ 10⁻⁴·Gγ₀ for λ/Δt = 100, 10, 1.
  func testV6MaxwellRelaxationMatchesBackwardEuler() {
    let g = 1e4, gamma0 = 0.01, lam = 0.01
    let m = testFluid(G: g, K: 2e4, k: g * lam)
    for ratio in [100.0, 10.0, 1.0] {
      let dt = lam / ratio
      var s = EVPState()
      s.setElasticSimpleShear(gamma0)
      XCTAssertEqual(EVP.kirchhoffStress(s, material: m).y, g * gamma0, accuracy: 1e-12)
      var worstBE = 0.0, worstExact = 0.0
      for i in 1...Int((3 * ratio).rounded()) {
        let tau = EVP.update(&s, velocityGradient: simd_double2x2(0), dt: dt, material: m, fieldMagnitude: 0)
        let be = ReferenceLaws.maxwellRelaxationBackwardEuler(steps: i, dt: dt, initial: g * gamma0, relaxationTime: lam)
        let ex = ReferenceLaws.maxwellRelaxation(time: Double(i) * dt, initial: g * gamma0, relaxationTime: lam)
        worstBE = max(worstBE, abs(tau.y - be) / (g * gamma0))
        worstExact = max(worstExact, abs(tau.y - ex) / (g * gamma0))
      }
      XCTAssertLessThanOrEqual(worstBE, 1e-4, "λ/Δt = \(ratio)")
      // The backward-Euler error itself (prototype 1.8e-3 / 1.8e-2 / 0.13 at λ/Δt = 100 / 10 / 1).
      XCTAssertLessThanOrEqual(worstExact, 0.14, "λ/Δt = \(ratio)")
    }
  }

  // MARK: V7 Maxwell start-up and N₁

  func testV7MaxwellStartupAndFirstNormalStress() {
    let g = 1e3, eta = 10.0, lam = eta / g
    let m = testFluid(G: g, K: 2.5e4, k: eta)
    var steadyByWi: [Double: (Double, Double)] = [:]
    for wi in [0.01, 0.1, 0.5, 1.0] {
      let rate = wi / lam, dt = lam / 200
      var s = EVPState()
      var tau = SIMD3<Double>.zero
      var err = 0.0
      for i in 1...2000 {
        tau = EVP.update(&s, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0)
        let t = Double(i) * dt
        if t < 3 * lam {
          let ex = ReferenceLaws.maxwellStartup(time: t, viscosity: eta, rate: rate, relaxationTime: lam)
          err = max(err, abs(tau.y - ex) / (eta * rate))
        }
      }
      let n1 = (tau.x - tau.z) / ReferenceLaws.ucmFirstNormalStress(viscosity: eta, relaxationTime: lam, rate: rate)
      steadyByWi[wi] = (tau.y / (eta * rate), n1)
      if wi <= 0.1 {
        XCTAssertLessThanOrEqual(err, 0.02, "start-up, Wi \(wi)")
        XCTAssertEqual(n1, 1, accuracy: 0.05, "N₁, Wi \(wi)")
      }
    }
    // Regression values of the b̄ₑ model at finite Wi (§4.6; t1_out.txt D: 0.742 / 0.523 and N₁ 0.59).
    XCTAssertEqual(steadyByWi[0.5]!.0, 0.7417, accuracy: 2e-3)
    XCTAssertEqual(steadyByWi[1.0]!.0, 0.5231, accuracy: 2e-3)
    XCTAssertEqual(steadyByWi[0.5]!.1, 0.5945, accuracy: 2e-3)
    // Steady stress deficit ≈ 2Wi² at small Wi (−1.9 % at Wi 0.1).
    XCTAssertEqual(steadyByWi[0.1]!.0, 0.981, accuracy: 2e-3)
  }

  // MARK: V8 thixotropic structure

  func testV8StructureMatchesDiscreteAndExactSolutions() {
    let a0 = 0.05, b1 = 0.5, rate = 2.0
    var m = testFluid(G: 5e3, K: 2e4, k: 1)
    m.buildRate = a0; m.breakShear = b1; m.vibrationWeight = 1      // λ driven by exactly the prescribed total rate
    for dt in [1e-3, 1e-2] {
      var s = EVPState()
      var errD = 0.0, errE = 0.0
      for i in 1...Int((10 / dt).rounded()) {
        EVP.update(&s, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0)
        errD = max(errD, abs(s.structure - ReferenceLaws.structureDiscrete(steps: i, dt: dt, initial: 1, build: a0,
                                                                            breakdown: b1 * rate)))
        errE = max(errE, abs(s.structure - ReferenceLaws.structure(time: Double(i) * dt, initial: 1, build: a0,
                                                                    breakdown: b1 * rate)))
      }
      XCTAssertLessThanOrEqual(errD, 1e-9, "Δt \(dt)")
      XCTAssertLessThanOrEqual(errE, 0.2 * (a0 + b1 * rate) * dt, "Δt \(dt)")
      // Recovery at rest.
      var rest = EVPState(structure: a0 / (a0 + b1 * rate))
      let l0 = rest.structure
      var errR = 0.0
      for i in 1...Int((5 / dt).rounded()) {
        EVP.update(&rest, velocityGradient: simd_double2x2(0), dt: dt, material: m, fieldMagnitude: 0)
        errR = max(errR, abs(rest.structure - ReferenceLaws.structureDiscrete(steps: i, dt: dt, initial: l0, build: a0,
                                                                               breakdown: 0)))
      }
      XCTAssertLessThanOrEqual(errR, 1e-9, "recovery, Δt \(dt)")
    }
  }

  /// Plastic-rate-driven breakdown (w_vib = 0): a Bingham fluid sheared above yield breaks its structure at the
  /// plastic rate, which at steady state equals the imposed rate.
  func testStructureFollowsPlasticRate() {
    var m = testFluid(G: 1e6, K: 2e6, ty: 10, k: 1)
    m.buildRate = 0.05; m.breakShear = 0.5
    var s = EVPState()
    let dt = 1e-4
    for _ in 0..<1000 { EVP.update(&s, velocityGradient: EVP.simpleShear(2), dt: dt, material: m, fieldMagnitude: 0) }
    XCTAssertEqual(s.plasticRate, 2, accuracy: 1e-3)
  }

  // MARK: V12 field and temperature laws

  func testV12CarlsonYieldTableAndClamp() {
    var unclamped = ContinuumPresets.mrFluid
    unclamped.field?.clampFractionOfG = 1e9
    let table: [(Double, Double)] = [(40, 11.8), (400, 118), (4000, 1183), (20_000, 5884), (100_000, 26_172),
                                     (300_000, 44_678)]
    for (h, tau) in table {
      XCTAssertEqual(EVP.fieldYield(fieldMagnitude: h, material: unclamped), tau, accuracy: 0.5 + 1e-4 * tau, "H \(h)")
      XCTAssertEqual(ReferenceLaws.carlsonYield(field: h), tau, accuracy: 0.5 + 1e-4 * tau, "H \(h)")
    }
    XCTAssertEqual(ReferenceLaws.carlsonFluxDensity(field: 100_000) * 1e3, 512, accuracy: 0.5)
    XCTAssertEqual(EVP.fieldYield(fieldMagnitude: 8000, material: ContinuumPresets.mrFluid), 1500, accuracy: 1e-9)
    XCTAssertEqual(EVP.fieldYield(fieldMagnitude: 1e5, material: ContinuumPresets.honey), 0)
    // The field adds to the yield stress of the effective law.
    let law = EVP.flowLaw(for: EVPState(), material: ContinuumPresets.mrFluid, fieldMagnitude: 1000)
    XCTAssertEqual(law.yieldStress, 7.6 + EVP.fieldYield(fieldMagnitude: 1000, material: ContinuumPresets.mrFluid),
                   accuracy: 1e-12)
  }

  func testV12HoneyArrheniusTableAndPipeline() {
    let table: [(Double, Double)] = [(10, 52.7), (15, 28.2), (20, 15.4), (25, 8.57), (30, 4.87), (40, 1.66), (50, 0.604),
                                     (60, 0.234)]
    let eta20 = ReferenceLaws.honeyViscosity(kelvin: 293.15)
    XCTAssertEqual(eta20, 15.4, accuracy: 0.05)
    let honey = ContinuumPresets.honey
    for (c, eta) in table {
      let tk = 273.15 + c
      let aT = EVP.shiftFactor(activationEnergy: honey.activationEnergy, temperature: tk, reference: honey.referenceTemperature)
      XCTAssertEqual(aT * eta20, eta, accuracy: 0.006 * eta, "\(c) °C")
      // Through the full update: steady simple shear at Wi = 10⁻³ returns a_T·k.
      var s = EVPState.rested(honey)
      s.temperature = tk
      let etaT = honey.consistency * aT
      let rate = 1e-3 * honey.shearModulus / etaT, dt = 0.02 * etaT / honey.shearModulus
      var tau = SIMD3<Double>.zero
      for _ in 0..<2000 {
        tau = EVP.update(&s, velocityGradient: EVP.simpleShear(rate), dt: dt, material: honey, fieldMagnitude: 0)
      }
      XCTAssertEqual(tau.y / rate / etaT, 1, accuracy: 1e-4, "\(c) °C")
    }
  }

  func testV12ChengWaterAndGlycerol() {
    XCTAssertEqual(ReferenceLaws.chengWaterViscosity(celsius: 20) * 1e3, 1.005, accuracy: 6e-4)
    XCTAssertEqual(ReferenceLaws.chengWaterViscosity(celsius: 100) * 1e3, 0.283, accuracy: 6e-4)
    XCTAssertEqual(ReferenceLaws.chengGlycerolViscosity(celsius: 20), 1.414, accuracy: 6e-4)
    XCTAssertEqual(ReferenceLaws.chengGlycerolViscosity(celsius: 0), 12.10, accuracy: 6e-3)
    let eaW = ReferenceLaws.effectiveActivationEnergy(
      eta1: ReferenceLaws.chengWaterViscosity(celsius: 15), t1: 288.15,
      eta2: ReferenceLaws.chengWaterViscosity(celsius: 25), t2: 298.15)
    XCTAssertEqual(eaW, 17_500, accuracy: 50)
    let eaG = ReferenceLaws.effectiveActivationEnergy(
      eta1: ReferenceLaws.chengGlycerolViscosity(celsius: 15), t1: 288.15,
      eta2: ReferenceLaws.chengGlycerolViscosity(celsius: 25), t2: 298.15)
    XCTAssertEqual(eaG, 66_000, accuracy: 200)
  }

  // MARK: Return map

  /// The safeguarded Newton solve satisfies Eq. 4.2 to round-off for a spread of laws, never bisects, and matches
  /// the Bingham closed form.
  func testReturnMapSolvesTheScalarEquation() {
    var seed: UInt64 = 0x5eed
    func uniform() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(seed >> 11) / Double(1 << 53)
    }
    for _ in 0..<2000 {
      let law = EVP.FlowLaw(fluidity: uniform() < 0.3 ? pow(10, -3 + 4 * uniform()) : 0,
                            yieldStress: uniform() < 0.7 ? pow(10, 3 * uniform()) : 0,
                            consistency: pow(10, -3 + 5 * uniform()), flowIndex: 0.2 + 0.8 * uniform(),
                            failureStress: uniform() < 0.3 ? pow(10, 1 + 3 * uniform()) : .infinity,
                            failureFluidity: pow(10, -3 + 3 * uniform()))
      let tauTr = pow(10, -1 + 5 * uniform()), mdt = pow(10, -4 + 6 * uniform())
      let r = EVP.returnMap(trialStress: tauTr, muDt: mdt, law: law)
      XCTAssertEqual(r.bisections, 0)
      XCTAssertTrue(r.stress >= 0 && r.stress <= tauTr)
      if law.flows(at: tauTr) {
        let res = r.stress - tauTr + mdt * law.rate(r.stress)
        XCTAssertLessThanOrEqual(abs(res), 1e-10 * tauTr, "law \(law), τ_tr \(tauTr), μ̃Δt \(mdt)")
      } else {
        XCTAssertEqual(r.stress, tauTr)
      }
    }
    // Bingham closed form (§4.3).
    let bingham = EVP.FlowLaw(yieldStress: 10, consistency: 2, flowIndex: 1)
    let mdt = 3.0, tauTr = 50.0
    XCTAssertEqual(EVP.returnMap(trialStress: tauTr, muDt: mdt, law: bingham).stress,
                   (tauTr + mdt * 10 / 2) / (1 + mdt / 2), accuracy: 1e-12)
    // The steady flow-curve inverse.
    let hb = EVP.FlowLaw(yieldStress: 10, consistency: 2, flowIndex: 0.4)
    XCTAssertEqual(hb.stress(atRate: 5), 10 + 2 * pow(5, 0.4), accuracy: 1e-10)
  }

  /// At negligible Wi the discrete steady state is the flow curve τ_y + kγ̇ⁿ.
  func testSteadyHerschelBulkleyFlowCurve() {
    let m = testFluid(G: 1e6, K: 2e6, ty: 10, k: 2, n: 0.4)
    for rate in [0.5, 5.0, 50.0] {
      var s = EVPState()
      var tau = SIMD3<Double>.zero
      let dt = 2e-3 / rate
      for _ in 0..<3000 { tau = EVP.update(&s, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0) }
      let exact = ReferenceLaws.herschelBulkley(rate: rate, yield: 10, consistency: 2, index: 0.4)
      XCTAssertEqual(tau.y / exact, 1, accuracy: 1e-4, "γ̇ \(rate)")
      XCTAssertEqual(s.plasticRate, rate, accuracy: 1e-3 * rate)
    }
    // Below yield the material is an elastic solid: no plastic rate (strain 5 × 10⁻⁶, τ = 5 Pa < τ_y = 10 Pa).
    var s = EVPState()
    for _ in 0..<100 { EVP.update(&s, velocityGradient: EVP.simpleShear(1), dt: 5e-8, material: m, fieldMagnitude: 0) }
    XCTAssertEqual(s.plasticRate, 0)
    XCTAssertEqual(s.b12 / 5e-6, 1, accuracy: 1e-6)
  }

  // MARK: §4.8 robustness clamps

  func testDeterminantGuardAndVolumeClamp() {
    let m = testFluid(G: 1e3, K: 1e4, k: 1)
    var s = EVPState()
    var d = EVP.Diagnostics()
    let crush = EVP.velocityGradient(c11: -900, c12: 0, c21: 0, c22: -900)       // det(I + ΔtC) = 0.01
    let tau = EVP.update(&s, velocityGradient: crush, dt: 1e-3, material: m, fieldMagnitude: 0, diagnostics: &d)
    XCTAssertTrue(d.determinantGuard)
    XCTAssertTrue(tau.x.isFinite && tau.y.isFinite && tau.z.isFinite)
    XCTAssertGreaterThanOrEqual(s.J, EVP.minimumVolumeRatio)
    XCTAssertTrue(d.volumeClamped)
    XCTAssertEqual(s.b11 * s.b22 - s.b12 * s.b12, 1, accuracy: 1e-12)
  }

  func testTensionCapProjectsVolume() {
    // Zero tension (oobleck with the cap off; the Rheo preset holds 1.5 kPa): any dilation is projected back to J = 1, so
    // the material cannot pull.
    var zero = ContinuumPresets.oobleck
    zero.tensionLimit = 0
    var s = EVPState.rested(zero)
    var d = EVP.Diagnostics()
    let pull = EVP.velocityGradient(c11: 10, c12: 0, c21: 0, c22: 10)
    let tau = EVP.update(&s, velocityGradient: pull, dt: 1e-3, material: zero, fieldMagnitude: 0, diagnostics: &d)
    XCTAssertEqual(s.J, 1, accuracy: 1e-15)
    XCTAssertEqual(tau.x + tau.z, 0, accuracy: 1e-9)
    XCTAssertTrue(d.volumeClamped)
    // Water-like (10 Pa): Cauchy tension capped at exactly p_tens.
    let w = ContinuumPresets.waterLike
    var sw = EVPState.rested(w)
    let tw = EVP.update(&sw, velocityGradient: pull, dt: 1e-3, material: w, fieldMagnitude: 0)
    XCTAssertEqual(0.5 * (tw.x + tw.z) / sw.J, w.tensionLimit, accuracy: 1e-9)
  }

  /// Fuzz: every preset and extra under random velocity gradients (10⁻² – 10⁴ s⁻¹, any direction, including
  /// crushing and spinning), time steps (10⁻⁶ – 10⁻² s), fields (0 – 3 × 10⁵ A/m) and temperatures outside the band.
  /// The §4.8 invariants must hold after every update: finite stress, det b̄ₑ = 1, J ∈ [0.6, 1.5], λ and f ∈ [0, 1],
  /// T inside the band, γ̇ₚ ≥ 0, and the returned τ̄ never above the elastic trial.
  func testUpdateKeepsInvariantsUnderRandomInputs() {
    var seed: UInt64 = 0xC0FFEE
    func uniform() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(seed >> 11) / Double(1 << 53)
    }
    func signed(_ lo: Double, _ hi: Double) -> Double { (uniform() < 0.5 ? -1 : 1) * pow(10, lo + (hi - lo) * uniform()) }
    var failures = 0
    for (name, m) in ContinuumPresets.all + ContinuumPresets.extras {
      for _ in 0..<40 {
        var s = EVPState.rested(m)
        s.temperature = m.referenceTemperature + 200 * (uniform() - 0.5) * 2
        let h = 3e5 * uniform()
        for _ in 0..<50 {
          let c = EVP.velocityGradient(c11: signed(-2, 4), c12: signed(-2, 4), c21: signed(-2, 4), c22: signed(-2, 4))
          let dt = pow(10, -6 + 4 * uniform())
          var d = EVP.Diagnostics()
          let tau = EVP.update(&s, velocityGradient: c, dt: dt, material: m, fieldMagnitude: h, diagnostics: &d)
          let ok = tau.x.isFinite && tau.y.isFinite && tau.z.isFinite
            && abs(s.b11 * s.b22 - s.b12 * s.b12 - 1) <= 1e-9
            && s.J >= EVP.minimumVolumeRatio - 1e-12 && s.J <= EVP.maximumVolumeRatio + 1e-12
            && (0...1).contains(s.structure) && (0...1).contains(s.contact)
            && s.temperature >= m.referenceTemperature - EVP.bandBelow(m) - 1e-9
            && s.temperature <= m.referenceTemperature + EVP.temperatureBandAbove + 1e-9
            && s.plasticRate >= 0 && s.plasticRate.isFinite
            && d.stress <= d.trialStress * (1 + 1e-12) + 1e-300
          if !ok {
            failures += 1
            if failures <= 5 { XCTFail("\(name): state \(s), τ \(tau), C \(c), Δt \(dt), H \(h), diagnostics \(d)") }
          }
        }
      }
    }
    XCTAssertEqual(failures, 0)
  }

  func testTemperatureBandAndArrheniusCap() {
    XCTAssertEqual(EVP.shiftFactor(activationEnergy: 5e5, temperature: 253.15, reference: 293.15), EVP.maximumShiftFactor)
    XCTAssertEqual(EVP.shiftFactor(activationEnergy: 0, temperature: 200, reference: 293.15), 1)
    let honey = ContinuumPresets.honey
    XCTAssertEqual(EVP.clampedTemperature(400, material: honey), 293.15 + 80)
    XCTAssertEqual(EVP.clampedTemperature(200, material: honey), 293.15 - 40)
    var s = EVPState.rested(honey)
    s.temperature = 500
    EVP.update(&s, velocityGradient: EVP.simpleShear(1), dt: 1e-4, material: honey, fieldMagnitude: 0)
    XCTAssertEqual(s.temperature, 373.15)
  }

  /// Lava's wider cold band (LK-FIX): the shift factors follow it from 1170 °C down to 900 °C (a_T 0.67 → 17.7 with
  /// E_a = 171 kJ/mol), where the default 40 K band stopped at 1090 °C (a_T 1.54).
  func testLavaStiffensDownTo900C() {
    let lava = ContinuumPresets.lava
    XCTAssertEqual(EVP.bandBelow(lava), 230)
    XCTAssertEqual(EVP.clampedTemperature(273.15 + 800, material: lava), 273.15 + 900, accuracy: 1e-9)
    func aT(_ celsius: Double) -> Double {
      EVP.shiftFactor(activationEnergy: lava.activationEnergy, temperature: EVP.clampedTemperature(273.15 + celsius, material: lava),
                      reference: lava.referenceTemperature)
    }
    XCTAssertEqual(aT(1170), 0.666, accuracy: 0.005)
    XCTAssertEqual(aT(900), 17.7, accuracy: 0.1)
    XCTAssertEqual(aT(800), aT(900))
    var narrow = lava
    narrow.temperatureBandBelow = nil
    XCTAssertEqual(EVP.clampedTemperature(273.15 + 900, material: narrow), lava.referenceTemperature - 40)
    // The steady viscosity at 1 s⁻¹ climbs monotonically through the band as the lava cools.
    var last = 0.0
    for c in stride(from: 1170.0, through: 900, by: -30) {
      var s = EVPState.rested(lava)
      s.temperature = 273.15 + c
      var tau = SIMD3<Double>.zero
      for _ in 0..<4000 { tau = EVP.update(&s, velocityGradient: EVP.simpleShear(1), dt: 2e-4, material: lava, fieldMagnitude: 0) }
      XCTAssertGreaterThan(tau.y, last, "stiffer at \(c) °C")
      last = tau.y
    }
  }

  // MARK: §4.7 oobleck (lagged Wyart–Cates)

  /// The t2_dst.py material (φ = 0.50, ρ 1600, G 20 kPa) used for the §4.7 numbers, with the §4.2 c lagged-f law
  /// (t_melt = 0.05 s, no rest melt toward f = 0, contacts driven by the total rate, τ_jam = 1.5 kPa, no tension)
  /// pinned so the regression stays independent of the Rheo preset.
  private var prototypeOobleck: ContinuumMaterial {
    var m = ContinuumPresets.oobleck
    m.density = 1600; m.shearModulus = 2e4; m.bulkModulus = 6e4; m.activationEnergy = 0
    m.dst?.phi = 0.50
    m.dst?.meltTime = 0.05
    m.dst?.restMelt = 0
    m.dst?.plasticDrive = false
    m.dst?.jamFailureStress = 1500
    m.tensionLimit = 0
    return m
  }

  /// Impact (200 s⁻¹ for 10 ms) jams to about 5 kPa; holding still relaxes the stress over t_jam while f climbs;
  /// the region melts after about 0.3 s (t2_out.txt J: 4997.5 Pa, f 0.624; 208.9 Pa, f 0.861 at +0.05 s; melted by 0.31 s).
  func testOobleckImpactHoldMelt() {
    let m = prototypeOobleck
    let dt = 2e-5
    var s = EVPState()
    var tau = SIMD3<Double>.zero
    for _ in 0..<500 { tau = EVP.update(&s, velocityGradient: EVP.simpleShear(200), dt: dt, material: m, fieldMagnitude: 0) }
    XCTAssertEqual(tau.y, 4997.5, accuracy: 0.01 * 4997.5)
    XCTAssertEqual(s.contact, 0.624, accuracy: 0.01)
    var d = EVP.Diagnostics()
    var jamAt: [Double] = []
    var tauAt: [Double] = []
    var fAt: [Double] = []
    for i in 0..<Int((0.6 / dt).rounded()) {
      tau = EVP.update(&s, velocityGradient: simd_double2x2(0), dt: dt, material: m, fieldMagnitude: 0, diagnostics: &d)
      if i % 2500 == 0 { jamAt.append(d.jam); tauAt.append(tau.y); fAt.append(s.contact) }    // every 0.05 s
    }
    // Index 1 = 0.06 s, 5 = 0.26 s, 6 = 0.31 s (times of the prototype's table).
    XCTAssertEqual(tauAt[1], 208.93, accuracy: 0.05 * 208.93)
    XCTAssertEqual(fAt[1], 0.861, accuracy: 0.02)
    XCTAssertGreaterThan(jamAt[5], 0.5)
    XCTAssertLessThan(jamAt[6], 0.5)
    XCTAssertLessThan(fAt.last!, 0.01)
  }

  /// The same strain (2.0) applied slowly (2 s⁻¹) does not jam (t2_out.txt K: τ 0.085 Pa, f 0.017).
  func testOobleckSlowStrainDoesNotJam() {
    let m = prototypeOobleck
    let dt = 2e-5
    var s = EVPState()
    var tau = SIMD3<Double>.zero
    var d = EVP.Diagnostics()
    var maxJam = 0.0
    for _ in 0..<Int((1 / dt).rounded()) {
      tau = EVP.update(&s, velocityGradient: EVP.simpleShear(2), dt: dt, material: m, fieldMagnitude: 0, diagnostics: &d)
      maxJam = max(maxJam, d.jam)
    }
    XCTAssertEqual(maxJam, 0)
    XCTAssertEqual(tau.y, 0.085, accuracy: 0.01)
    XCTAssertEqual(s.contact, 0.017, accuracy: 0.003)
  }

  /// The Rheo oobleck preset (φ = 0.52) shear-thickens: fast shear gives orders of magnitude more stress than slow.
  func testOobleckPresetThickens() {
    func stress(at rate: Double) -> Double {
      var s = EVPState.rested(ContinuumPresets.oobleck)
      var tau = SIMD3<Double>.zero
      let dt = min(1e-5, 2e-3 / rate)
      for _ in 0..<Int((0.5 / rate / dt).rounded()) {       // strain 0.5
        tau = EVP.update(&s, velocityGradient: EVP.simpleShear(rate), dt: dt, material: ContinuumPresets.oobleck,
                         fieldMagnitude: 0)
      }
      return tau.y
    }
    let slow = stress(at: 1), fast = stress(at: 300)
    XCTAssertLessThan(slow, 1)
    XCTAssertGreaterThan(fast, 1000)
  }

  // MARK: Rest melt (restMelt = 1, the Rheo oobleck preset)

  /// A jammed particle that keeps carrying a load (the inside of a tower holding its own weight: f = 0.9, τ̄ = 300 Pa,
  /// creeping at the jammed rate τ̄/(G·t_jam) = 0.3 s⁻¹) stays jammed with the lagged-f law but liquefies with the rest
  /// melt, within the preset's 0.2–1 s.
  func testOobleckRestMeltReleasesLoadBearingJam() {
    func run(restMelt: Double) -> [Double] {
      var m = ContinuumPresets.oobleck
      m.dst?.restMelt = restMelt
      let dt = 2e-5
      var s = EVPState.rested(m)
      s.setElasticSimpleShear(300 / m.shearModulus)
      s.contact = 0.9
      var d = EVP.Diagnostics()
      var jamAt: [Double] = []
      for i in 1...Int((1.0 / dt).rounded()) {
        EVP.update(&s, velocityGradient: EVP.simpleShear(0.3), dt: dt, material: m, fieldMagnitude: 0, diagnostics: &d)
        if i % 5000 == 0 { jamAt.append(d.jam) }                                   // every 0.1 s
      }
      return jamAt
    }
    let lagged = run(restMelt: 0), melting = run(restMelt: 1)
    XCTAssertGreaterThan(lagged.min()!, 0.99, "lagged-f law: the load-bearing region never melts")
    XCTAssertEqual(melting.last!, 0, "rest melt: liquid again")
    let melted = melting.firstIndex { $0 == 0 }.map { Double($0 + 1) * 0.1 } ?? .infinity
    XCTAssertLessThanOrEqual(melted, 1.0, "melts within 1 s (\(melted) s)")
  }

  /// With the rest melt, steady shear jams only above the gate γ̇ ≈ γ*/t_melt and the onset stress: 1 s⁻¹ stays liquid
  /// for 2 s, 100 s⁻¹ jams (with the preset's plastic drive only partly: under an imposed rate the jam fails at τ_jam,
  /// which breaks contacts, and re-forms, a stick-slip).
  func testOobleckRestMeltRateGate() {
    func jam(at rate: Double, seconds: Double) -> Double {
      let m = ContinuumPresets.oobleck
      let dt = min(2e-5, 2e-3 / rate)
      var s = EVPState.rested(m)
      var d = EVP.Diagnostics()
      var maxJam = 0.0
      for _ in 0..<Int((seconds / dt).rounded()) {
        EVP.update(&s, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0, diagnostics: &d)
        maxJam = max(maxJam, d.jam)
      }
      return maxJam
    }
    XCTAssertEqual(jam(at: 1, seconds: 2), 0)
    XCTAssertGreaterThan(jam(at: 100, seconds: 0.05), 0.3)
  }

  // MARK: Plastic drive (plasticDrive = true, the Rheo oobleck preset)

  /// A jammed particle wobbling elastically (simple shear of 0.5 % amplitude at 120 Hz: a jammed region on a vibrating
  /// floor) re-jams itself on every cycle when contacts are driven by the total rate, and melts within 1 s when they are
  /// driven by the plastic rate. Steady shear at 100 s⁻¹ still jams.
  func testOobleckPlasticDriveIgnoresElasticWobble() {
    func run(plastic: Bool) -> (end: Double, steady: Double) {
      var m = ContinuumPresets.oobleck
      m.dst?.plasticDrive = plastic
      let dt = 2e-5, omega = 2 * Double.pi * 120, amp = 0.005
      var s = EVPState.rested(m)
      s.contact = 0.9
      var d = EVP.Diagnostics()
      for i in 0..<Int((1.0 / dt).rounded()) {
        let rate = amp * omega * cos(omega * Double(i) * dt)
        EVP.update(&s, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0, diagnostics: &d)
      }
      let end = d.jam
      var q = EVPState.rested(m)
      var steady = 0.0
      for _ in 0..<2500 {
        EVP.update(&q, velocityGradient: EVP.simpleShear(100), dt: dt, material: m, fieldMagnitude: 0, diagnostics: &d)
        steady = max(steady, d.jam)
      }
      return (end, steady)
    }
    let total = run(plastic: false), plastic = run(plastic: true)
    XCTAssertGreaterThan(total.end, 0.9, "total-rate drive: the wobble keeps it jammed")
    XCTAssertLessThan(plastic.end, 0.05, "plastic-rate drive: liquid again")
    XCTAssertGreaterThan(plastic.steady, 0.3, "steady shear still jams")
  }
}
