import CoreGraphics
import Metal
import XCTest
import simd
import LabKitCore
import LabKitMPMTypes
@testable import LabKitMPM

/// Stripe dye (Toothpaste Toy, 13 October 2026): `PBParticle.flags` bits 8–11 carry a dye band, 0 = none, 1–7 = band.
/// Emitters assign it from the particle's lateral offset across the nozzle (`MPMEmitter.stripes`), fills from the
/// position across the shape (`fill(…stripes:across:)`); the bands ride with the particles, including through a
/// quality-switch resample.
final class MPMDyeTests: XCTestCase {
  /// Mean x of each band 1…n and the particle count per band (index 0 = undyed).
  private func bandStats(_ ps: [MPMParticleSnapshot], bands n: Int) -> (mean: [Double], count: [Int]) {
    var sum = [Double](repeating: 0, count: n + 1), count = [Int](repeating: 0, count: n + 1)
    for p in ps where p.band <= n {
      sum[p.band] += p.position.x
      count[p.band] += 1
    }
    return (zip(sum, count).map { $0.1 > 0 ? $0.0 / Double($0.1) : .nan }, count)
  }

  /// The contract test: a 10 mm nozzle pointing down with three stripes. Every particle it emits is dyed; band 1 is
  /// on the left (−x), band 3 on the right, the bands do not overlap across the nozzle, and each particle's band is the
  /// third of the bore it left from (judged after 6 frames, 5 mm of ribbon).
  func testEmittedParticlesCarryBandsAcrossTheNozzle() throws {
    let rig = try MPMRig(materials: [ContinuumPresets.toothpaste])
    let W = rig.solver.domain.size.x
    let nozzle = SIMD2(W / 2, 0.08), radius = 0.005
    var input = MPMFrameInput(gravity: .zero)                // no fall: the ribbon stays under the nozzle
    // The rate that matches the speed: speed × bore ÷ the area of one particle (2 × 2 per cell), so the ribbon leaves
    // the nozzle without being overfed (and squeezed sideways).
    let dx = rig.solver.cellSize, speed = 0.1
    input.emitters = [MPMEmitter(position: nozzle, radius: radius, velocity: SIMD2(0, -speed), material: 0,
                                 rate: speed * 2 * radius / (dx * dx / 4), stripes: 3)]
    // Each particle's band is the third of the bore it left from.
    let expected: (Double) -> Int = { x in min(max(Int(((x - nozzle.x) / (2 * radius) + 0.5) * 3) + 1, 1), 3) }
    rig.run(6, input: input)
    let fresh = rig.solver.debugParticles().filter(\.enabled)
    let agree = fresh.filter { expected($0.position.x) == $0.band }.count
    print("dye: \(agree)/\(fresh.count) fresh particles in their own third of the bore")
    XCTAssertGreaterThan(fresh.count, 20)
    XCTAssertGreaterThan(Double(agree) / Double(max(fresh.count, 1)), 0.9, "\(agree)/\(fresh.count)")
    let st = rig.run(12, input: input)
    let ps = rig.solver.debugParticles().filter(\.enabled)
    XCTAssertGreaterThan(st.emitted, 100, "0.15 s of extrusion")
    XCTAssertEqual(st.nanCount, 0)
    XCTAssertTrue(ps.allSatisfy { (1...3).contains($0.band) }, "every emitted particle carries a band 1…3")
    let (mean, count) = bandStats(ps, bands: 3)
    print(String(format: "dye: bands 1/2/3 counts %d/%d/%d, mean x − nozzle %.2f / %.2f / %.2f mm", count[1], count[2],
                 count[3], (mean[1] - nozzle.x) * 1000, (mean[2] - nozzle.x) * 1000, (mean[3] - nozzle.x) * 1000))
    for b in 1...3 { XCTAssertGreaterThan(count[b], 10, "band \(b) is present") }
    XCTAssertLessThan(mean[1], mean[2])
    XCTAssertLessThan(mean[2], mean[3])
    XCTAssertEqual(mean[2], nozzle.x, accuracy: 0.6 * rig.solver.cellSize, "band 2 is the middle of the bore")
    let maxLeft = ps.filter { $0.band == 1 }.map(\.position.x).max() ?? .infinity
    let minRight = ps.filter { $0.band == 3 }.map(\.position.x).min() ?? -.infinity
    XCTAssertLessThan(maxLeft, minRight, "band 1 and band 3 sit on opposite sides of the nozzle")
  }

  /// A plain emitter (the default) leaves its particles undyed: existing pours are unchanged.
  func testPlainEmitterLeavesParticlesUndyed() throws {
    let rig = try MPMRig()
    var input = MPMFrameInput(gravity: .zero)
    input.emitters = [MPMEmitter(position: SIMD2(0.035, 0.05), radius: 0.004, velocity: SIMD2(0, -0.1), material: 0,
                                 rate: 3000)]
    rig.run(6, input: input)
    let ps = rig.solver.debugParticles().filter(\.enabled)
    XCTAssertFalse(ps.isEmpty)
    XCTAssertTrue(ps.allSatisfy { $0.band == 0 })
  }

  /// `fill(…stripes:across:)` dyes equal-width bands across the shape (x by default, y on request), and the bands
  /// survive a quality-switch resample onto a finer grid.
  func testFillStripesAndResampleKeepBands() throws {
    let rig = try MPMRig()
    let W = rig.solver.domain.size.x
    rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.012), material: 0, temperature: 293.15, stripes: 3)
    rig.solver.fill(rect: CGRect(x: 0.02, y: 0.03, width: 0.03, height: 0.012), material: 0, temperature: 293.15,
                    stripes: 2, across: SIMD2(0, 1))
    rig.run(1, input: MPMFrameInput(gravity: .zero))
    let ps = rig.solver.debugParticles().filter(\.enabled)
    let floorBand = ps.filter { $0.position.y < 0.012 }
    let ribbon = ps.filter { $0.position.y > 0.03 }
    // Bands are cut at the seeding lattice sites; positions carry a ±0.1 Δx jitter, so skip half a cell at each cut.
    let margin = 0.5 * rig.solver.cellSize
    let clearOfCuts = floorBand.filter { p in [W / 3, 2 * W / 3].allSatisfy { abs(p.position.x - $0) > margin } }
    XCTAssertTrue(clearOfCuts.allSatisfy { p in p.band == min(Int(p.position.x / W * 3), 2) + 1 },
                  "vertical thirds of the floor layer")
    XCTAssertEqual(Set(floorBand.map(\.band)), [1, 2, 3])
    let ribbonClear = ribbon.filter { abs($0.position.y - 0.036) > margin }
    XCTAssertTrue(ribbonClear.allSatisfy { p in p.band == (p.position.y < 0.036 ? 1 : 2) }, "horizontal halves")
    XCTAssertEqual(Set(ribbon.map(\.band)), [1, 2])
    rig.solver.setQuality(.high)
    rig.run(3, input: MPMFrameInput(gravity: .zero))
    XCTAssertEqual(rig.solver.quality, .high)
    let after = rig.solver.debugParticles().filter(\.enabled).filter { $0.position.y < 0.012 }
    let (mean, count) = bandStats(after, bands: 3)
    print(String(format: "dye after resample: counts %d/%d/%d/%d (undyed first), mean x %.1f / %.1f / %.1f mm", count[0],
                 count[1], count[2], count[3], mean[1] * 1000, mean[2] * 1000, mean[3] * 1000))
    XCTAssertEqual(count[0], 0, "no particle lost its dye")
    XCTAssertLessThan(mean[1], mean[2])
    XCTAssertLessThan(mean[2], mean[3])
  }
  // MARK: The tube (Toothpaste Toy, PLAY, 13–14 October 2026): slot emitter, grip, column top, wall friction

  /// A slot emitter (`MPMEmitter.slotLength`, the face of a piston one cell long) fed at speed × width ÷ particle area
  /// lays one row of paste per cell travelled at rest density (a disc over-packs its middle), with the same bands.
  func testSlotEmitterLaysTheRibbonAtRestDensity() throws {
    let rig = try MPMRig(materials: [ContinuumPresets.toothpaste])
    let W = rig.solver.domain.size.x
    let dx = rig.solver.cellSize, radius = 0.004, speed = 0.05
    let nozzle = SIMD2(W / 2, 0.08)
    var input = MPMFrameInput(gravity: .zero)
    input.emitters = [MPMEmitter(position: nozzle, radius: radius, velocity: SIMD2(0, -speed), material: 0,
                                 rate: speed * 2 * radius / (dx * dx / 4), stripes: 3, slotLength: dx)]
    let frames = 36
    let st = rig.run(frames, input: input)
    let ps = rig.solver.debugParticles().filter(\.enabled)
    let expected = speed * Double(frames) * input.dt * 2 * radius / (dx * dx / 4)
    let meanJ = ps.map(\.volumeRatio).reduce(0, +) / Double(max(ps.count, 1))
    print(String(format: "slot: emitted %d (expected %.0f), mean J %.3f", st.emitted, expected, meanJ))
    XCTAssertEqual(Double(st.emitted), expected, accuracy: 0.2 * expected)
    XCTAssertEqual(meanJ, 1, accuracy: 0.1, "at rest density")
    let (mean, count) = bandStats(ps, bands: 3)
    for b in 1...3 { XCTAssertGreaterThan(count[b], 5, "band \(b)") }
    XCTAssertLessThan(mean[1], mean[2])
    XCTAssertLessThan(mean[2], mean[3])
    XCTAssertEqual(st.nanCount, 0)
  }

  /// A grip (`MPMGrip`) carries the paste inside it at its velocity and reports the impulse it takes to hold it on its
  /// body index; the paste outside follows only through the material.
  func testGripCarriesThePasteInsideIt() throws {
    let rig = try MPMRig(materials: [ContinuumPresets.toothpaste])
    let W = rig.solver.domain.size.x
    rig.solver.fill(rect: CGRect(x: W / 2 - 0.01, y: 0, width: 0.02, height: 0.02), material: 0, temperature: 293.15)
    rig.run(30)
    var input = MPMFrameInput()
    let grip = MPMGrip(shape: .box(halfSize: SIMD2(0.003, 0.003)), position: SIMD2(W / 2, 0.012),
                       velocity: SIMD2(0, 0.03), bodyIndex: 15)
    var impulse = SIMD3<Double>.zero
    for f in 0..<12 {
      var g = grip
      g.position.y += 0.03 * Double(f) * input.dt
      input.grips = [g]
      rig.run(1, input: input)
      impulse += rig.solver.stats.bodyImpulses[15]
    }
    let centre = SIMD2(W / 2, 0.012 + 0.03 * 12 * input.dt)
    let held = rig.solver.debugParticles().filter { $0.enabled && simd_length($0.position - centre) < 0.002 }
    let vy = held.map(\.velocity.y).reduce(0, +) / Double(max(held.count, 1))
    print(String(format: "grip: %d held particles, mean vy %.4f m/s, impulse y %.3g N·s", held.count, vy, impulse.y))
    XCTAssertGreaterThan(held.count, 4, "paste stays in the grip")
    XCTAssertEqual(vy, 0.03, accuracy: 0.01, "and moves with it")
    XCTAssertLessThan(impulse.y, 0, "lifting paste pulls the grip down")
  }

  /// `columnTop` finds the highest live particle in a strip (below a ceiling, slower than a speed), nil when empty;
  /// `wallFriction` clamps to 0…1.
  func testColumnTopAndWallFriction() throws {
    let rig = try MPMRig(materials: [ContinuumPresets.toothpaste])
    rig.solver.fill(rect: CGRect(x: 0.02, y: 0, width: 0.02, height: 0.012), material: 0, temperature: 293.15)
    rig.run(1, input: MPMFrameInput(gravity: .zero))
    let dx = rig.solver.cellSize
    let top = try XCTUnwrap(rig.solver.columnTop(x: 0.03, halfWidth: 0.005))
    XCTAssertEqual(top, 0.012, accuracy: dx)
    let capped = try XCTUnwrap(rig.solver.columnTop(x: 0.03, halfWidth: 0.005, below: 0.006))
    XCTAssertLessThan(capped, 0.006)
    XCTAssertGreaterThan(capped, 0.006 - dx)
    XCTAssertNil(rig.solver.columnTop(x: 0.06, halfWidth: 0.004), "an empty strip")
    rig.solver.wallFriction = 3
    XCTAssertEqual(rig.solver.wallFriction, 1)
    rig.solver.wallFriction = -1
    XCTAssertEqual(rig.solver.wallFriction, 0)
    rig.solver.wallFriction = .nan
    XCTAssertEqual(rig.solver.wallFriction, 0)
  }
}
