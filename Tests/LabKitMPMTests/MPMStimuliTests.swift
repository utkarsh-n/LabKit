import CoreGraphics
import Metal
import XCTest
import simd
import LabKitCore
import LabKitMPMTypes
@testable import LabKitMPM

/// Body forces and stimuli of MPMFrameInput: temperature relaxation, frame acceleration, vibration, magnet (Kelvin force).
final class MPMStimuliTests: XCTestCase {
  private func pool(_ m: ContinuumMaterial, depth: Double = 0.03, temperature: Double = 293.15) throws -> MPMRig {
    let rig = try MPMRig(domain: MPMDomain(heleShawGap: 0.01), materials: [m])
    rig.solver.fill(rect: CGRect(x: 0, y: 0, width: rig.solver.domain.size.x, height: depth), material: 0, temperature: temperature)
    return rig
  }

  func testTemperatureRelaxesToAmbient() throws {
    let rig = try pool(ContinuumPresets.honey, temperature: 350)
    rig.solver.thermalTime = 0.5
    var input = MPMFrameInput()
    input.ambientTemperature = 293.15
    let st = rig.run(60, input: input)                       // 0.5 s = one time constant
    let expected = 293.15 + (350 - 293.15) * exp(-1)
    print(String(format: "mean T after 0.5 s: %.2f K (expected %.2f K)", st.meanTemperature, expected))
    XCTAssertEqual(st.meanTemperature, expected, accuracy: 0.5)
  }

  func testFrameAccelerationTiltsThePool() throws {
    let rig = try pool(ContinuumPresets.waterLike)
    rig.run(60)
    let x0 = rig.solver.debugParticles().map(\.position.x).reduce(0, +)
    var input = MPMFrameInput()
    input.frameAcceleration = SIMD2(5, 0)                    // the tank accelerates right; the fluid feels −a
    rig.run(60, input: input)
    let x1 = rig.solver.debugParticles().map(\.position.x).reduce(0, +)
    let n = Double(rig.solver.debugParticles().count)
    print(String(format: "mean x moved %.2f mm under a = +5 m/s²", (x1 - x0) / n * 1000))
    XCTAssertLessThan((x1 - x0) / n, -0.002, "fluid piles up against the trailing (left) wall")
  }

  func testVibrationAddsSubstepsAndEnergy() throws {
    let rig = try pool(ContinuumPresets.waterLike)
    let rest = rig.run(60)
    var input = MPMFrameInput()
    input.vibration = (amplitude: 30, frequency: 240)       // ≥ 8 substeps per period: 16 per 1/120 s
    var ke = 0.0
    let st = rig.run(60, input: input) { _, s in ke = max(ke, s.kineticEnergy) }
    print("vibration: substeps \(rest.substeps) -> \(st.substeps), peak KE \(ke) J (rest \(rest.kineticEnergy) J)")
    XCTAssertGreaterThanOrEqual(st.substeps, 16)
    XCTAssertGreaterThan(ke, 10 * max(rest.kineticEnergy, 1e-12))
    XCTAssertEqual(st.nanCount, 0)
  }

  func testMagnetPullsMRFluidAndStiffensIt() throws {
    // A virtual magnet 1 cm above a 20 mm pool (1.5e5 A/m at 1 cm; the Kelvin force is capped at 3 g, so the fluid
    // near the magnet feels about 2 g net upward, where the true force is about 2,000 g). LK-FIX: both a ferrofluid and
    // MR fluid are pulled up to the magnet, as real ones leap to a magnet held above them, and MR fluid's field yield
    // (τ_field ≤ 0.05 G = 1.5 kPa, scaled where the cap bites) makes the fluid between pool and magnet carry hundreds of
    // pascals where the bare fluid yields at 7.6 Pa. Before LK-FIX this test asked for a ≥ 0.3 mm bulge and a solid
    // probe: the pool stayed down, held by upstream PB-MPM's one-sided volume handling (measured: the two-sided
    // correction and the wall mirror together let it go; either alone does not). Stiffening against a finger is judged
    // in labkit-gpucheck M5b.
    func run(_ m: ContinuumMaterial) throws -> (h0: Double, h1: Double, stats: MPMStats) {
      let rig = try pool(m, depth: 0.02)
      rig.run(60)
      let W = rig.solver.domain.size.x
      let magnet = SIMD2(W / 2, 0.03)                        // 1 cm above the surface
      func nearTop() -> Double {
        let ps = rig.solver.debugParticles().filter { $0.enabled && abs($0.position.x - magnet.x) < 0.01 }
        return ps.map(\.position.y).max() ?? 0
      }
      let h0 = nearTop()
      var input = MPMFrameInput()
      input.magnet = (position: magnet, strength: 1.5e5)
      input.probe = SIMD2(W / 2, 0.015)
      let st = rig.run(120, input: input)
      return (h0, nearTop(), st)
    }
    let ferro = try run(ContinuumPresets.ferrofluid)
    let mr = try run(ContinuumPresets.mrFluid)
    print(String(format: "Magnet above: ferrofluid surface %.1f -> %.1f mm; MR fluid %.1f -> %.1f mm, probe stress %.1f Pa, solid fraction %.2f",
                 ferro.h0 * 1000, ferro.h1 * 1000, mr.h0 * 1000, mr.h1 * 1000, mr.stats.probe.stress, mr.stats.probe.solidFraction))
    XCTAssertGreaterThan(ferro.h1, 0.025, "the Kelvin force pulls ferrofluid up to the magnet")
    XCTAssertGreaterThan(mr.h1, 0.025, "… and MR fluid")
    XCTAssertGreaterThan(mr.stats.probe.stress, 100, "the field yield: far more stress than MR fluid's 7.6 Pa field-free yield")
    XCTAssertEqual(ferro.stats.nanCount + mr.stats.nanCount, 0)
  }


}
