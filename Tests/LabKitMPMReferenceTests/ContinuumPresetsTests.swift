// ContinuumPresets (LabKitCore, owned by WP-O): the 13 Rheo presets against rheology-models.md §6 (revision 2) /
// calc/presets2.json, and the rules of §5.3. Fast, constitutive-level only.
import LabKitCore
import LabKitMPMReference
import XCTest

final class ContinuumPresetsTests: XCTestCase {

  func testShelfOrderAndNames() {
    XCTAssertEqual(ContinuumPresets.all.map(\.name),
                   ["Water-like", "Honey", "Ketchup", "Mayonnaise", "Toothpaste", "Oobleck", "Slime", "Silly Putty",
                    "Yogurt", "Quicksand", "MR fluid", "Paint", "Lava"])
    XCTAssertEqual(ContinuumPresets.extras.map(\.name), ["Rheopectic cream", "Ferrofluid", "Blood", "Shampoo", "Glycerol"])
    XCTAssertEqual(ContinuumPresets.named("honey"), ContinuumPresets.honey)
    XCTAssertEqual(ContinuumPresets.named("MR FLUID"), ContinuumPresets.mrFluid)
    XCTAssertEqual(ContinuumPresets.named("glycerol"), ContinuumPresets.glycerol)
    XCTAssertNil(ContinuumPresets.named("custard"))
  }

  /// Every preset is well-formed: positive ρ, G, K; n ∈ (0.15, 1]; a flowing branch; K obeys the §5.3 rule.
  func testPresetsAreWellFormed() {
    for (name, m) in ContinuumPresets.all + ContinuumPresets.extras {
      XCTAssertGreaterThan(m.density, 0, name)
      XCTAssertGreaterThan(m.shearModulus, 0, name)
      XCTAssertGreaterThanOrEqual(m.bulkModulus, 2 * m.shearModulus, name)
      XCTAssertGreaterThan(m.flowIndex, 0.15, name)
      XCTAssertLessThanOrEqual(m.flowIndex, 1, name)
      XCTAssertGreaterThanOrEqual(m.tensionLimit, 0, name)
      XCTAssertTrue(m.consistency > 0 || m.fluidity > 0 || m.dst != nil, "\(name) has no flowing branch")
      XCTAssertEqual(m.wallYieldFactor, 0, name)
      // ≤ 3 % hydrostatic compression over the 154 mm reference tank (§5.3 item 1), up to the 100 Pa rounding.
      let compression = m.density * ContinuumPresets.standardGravity * ContinuumPresets.referenceTankHeight / m.bulkModulus
      XCTAssertLessThanOrEqual(compression, 0.0301, name)
      XCTAssertEqual(m.bulkModulus, ContinuumPresets.oracleBulkModulus(density: m.density, shearModulus: m.shearModulus),
                     accuracy: 0.5, name)
    }
  }

  /// Spot values from presets2.json (the machine-readable copy of §6).
  func testPresetValuesMatchTable() throws {
    let p = ContinuumPresets.self
    XCTAssertEqual(p.waterLike.consistency, 1e-3); XCTAssertEqual(p.waterLike.bulkModulus, 50_300)
    XCTAssertEqual(p.honey.consistency, 15.4); XCTAssertEqual(p.honey.activationEnergy, 85_000)
    XCTAssertEqual(p.ketchup.yieldBroken, 10); XCTAssertEqual(p.ketchup.yieldStructure, 15)
    XCTAssertEqual(p.ketchup.flowIndex, 0.30); XCTAssertEqual(p.ketchup.buildRate, 0.05); XCTAssertEqual(p.ketchup.breakShear, 0.5)
    XCTAssertEqual(p.mayonnaise.yieldBroken + p.mayonnaise.yieldStructure, 80)
    XCTAssertEqual(p.toothpaste.yieldBroken, 150); XCTAssertEqual(p.toothpaste.consistency, 30)
    XCTAssertEqual(p.slime.consistency / p.slime.shearModulus, 0.406, accuracy: 5e-4)
    XCTAssertEqual(p.sillyPutty.consistency / p.sillyPutty.shearModulus, 0.14, accuracy: 1e-12)
    XCTAssertEqual(p.yogurt.consistencyStructure, 2); XCTAssertEqual(p.yogurt.buildRate, 0.01)
    XCTAssertEqual(p.quicksand.structureExponent, 3); XCTAssertEqual(p.quicksand.consistencyStructure, 2e4)
    XCTAssertEqual(p.quicksand.vibrationWeight, 0.2); XCTAssertEqual(p.quicksand.breakShear, 0.5)  // Rheo wave 2 retune
    XCTAssertEqual(p.quicksand.tensionLimit, 1000)  // a shaken bed stays coherent (Rheo wave 2 verification)
    XCTAssertEqual(p.oobleck.tensionLimit, 1500)
    XCTAssertEqual(p.paint.buildRate, 0.5); XCTAssertEqual(p.paint.flowIndex, 0.65)
    XCTAssertEqual(p.lava.referenceTemperature, 1403.15); XCTAssertEqual(p.lava.yieldActivationEnergy, 171_000)
    let d = try XCTUnwrap(p.oobleck.dst)
    XCTAssertEqual(d.phi, 0.52); XCTAssertEqual(d.phiFrictionless, 0.593); XCTAssertEqual(d.phiFrictional, 0.452)
    XCTAssertEqual(d.strainScale, 0.197); XCTAssertEqual(d.onsetStress, 5); XCTAssertEqual(d.onsetForm, 0)
    XCTAssertEqual(d.jamFailureStress, 4000); XCTAssertEqual(d.postFailureViscosity, 2)
    XCTAssertEqual(d.meltTime, 0.15); XCTAssertEqual(d.restMelt, 1); XCTAssertTrue(d.plasticDrive); XCTAssertEqual(d.jamTime, 0.05)
    let f = try XCTUnwrap(p.mrFluid.field)
    XCTAssertEqual(f.yieldSaturation, 46_700, accuracy: 50)          // JSON rounds 271 700·0.315^1.5239 = 46 727 Pa
    XCTAssertEqual(f.saturationField, 157_977.883, accuracy: 0.01)
    XCTAssertEqual(f.clampFractionOfG * p.mrFluid.shearModulus, 1500, accuracy: 1e-9)
    XCTAssertEqual(f.responseTime, 1e-3)
  }

  /// §5.3 numerical rules for G: yield strain τ_y/G ≤ 0.05 for the pastes, and the rested state is λ = 1 (0 for the
  /// rheopectic extra) at the reference temperature.
  func testYieldStrainAndRestedState() {
    let pastes = [ContinuumPresets.ketchup, ContinuumPresets.mayonnaise, ContinuumPresets.toothpaste,
                  ContinuumPresets.yogurt, ContinuumPresets.paint]
    for m in pastes {
      XCTAssertLessThanOrEqual((m.yieldBroken + m.yieldStructure) / m.shearModulus, 0.05 + 1e-12)
    }
    XCTAssertEqual(EVPState.rested(ContinuumPresets.ketchup).structure, 1)
    XCTAssertEqual(EVPState.rested(ContinuumPresets.rheopecticCream).structure, 0)
    XCTAssertEqual(EVPState.rested(ContinuumPresets.lava).temperature, 1403.15)
  }

  /// Oobleck's Han et al. front ratio 1/γ_∞ = 6.96 at φ = 0.52 (§3.4.2).
  func testJammingFrontRatio() {
    XCTAssertEqual(ReferenceLaws.jammingFrontRatio(phi: 0.52), 6.96, accuracy: 0.01)
  }

  /// Each preset survives 1000 steps of steady simple shear at 10 s⁻¹ through EVP.update with finite stress.
  func testEveryPresetUpdatesFinitely() {
    for (name, m) in ContinuumPresets.all + ContinuumPresets.extras {
      var s = EVPState.rested(m)
      var tau = SIMD3<Double>.zero
      for _ in 0..<1000 {
        tau = EVP.update(&s, velocityGradient: EVP.simpleShear(10), dt: 1e-4, material: m, fieldMagnitude: 1e4)
      }
      XCTAssertTrue(tau.x.isFinite && tau.y.isFinite && tau.z.isFinite, name)
      XCTAssertGreaterThan(tau.y, 0, name)
      XCTAssertEqual(s.b11 * s.b22 - s.b12 * s.b12, 1, accuracy: 1e-12, name)
      XCTAssertTrue((0...1).contains(s.structure) && (0...1).contains(s.contact), name)
    }
  }
}
