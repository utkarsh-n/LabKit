import CoreGraphics
import Metal
import XCTest
import simd
import LabKitCore
import LabKitMPMTypes
@testable import LabKitMPM

// LabKitMPM on the Mac GPU: `Tools/lk.sh <name> env TOOLCHAINS=metal swift test --filter LabKitMPMTests`.
// Each test encodes frames into its own command buffers and waits on them (the solver itself never waits).

final class MPMRig {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let solver: MPMSolver

  init(domain: MPMDomain = MPMDomain(heleShawGap: 0), quality: MPMQuality = .standard, capacity: Int = 20_000,
       verification: MPMVerificationOptions = MPMVerificationOptions(),
       materials: [ContinuumMaterial] = [ContinuumPresets.waterLike]) throws {
    guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    device = d
    queue = d.makeCommandQueue()!
    solver = try MPMSolver(device: d, domain: domain, quality: quality, capacity: capacity, verification: verification)
    solver.materials = materials
  }

  /// Encodes and runs `frames` frames, waiting on each; returns the stats after the last one.
  @discardableResult
  func run(_ frames: Int, input: MPMFrameInput = MPMFrameInput(), each: ((Int, MPMStats) -> Void)? = nil) -> MPMStats {
    for f in 0..<frames {
      let cmd = queue.makeCommandBuffer()!
      solver.encode(into: cmd, input: input)
      cmd.commit()
      cmd.waitUntilCompleted()
      XCTAssertEqual(cmd.status, .completed, "command buffer failed: \(String(describing: cmd.error))")
      each?(f, solver.stats)
    }
    return solver.stats
  }

  func particleBytes() -> Data {
    Data(bytes: solver.particleBuffer.contents(), count: solver.capacity * MemoryLayout<PBParticle>.stride)
  }
}

final class MPMSolverTests: XCTestCase {

  // MARK: Setup

  func testLayoutProbeAndSIMDSelection() throws {
    let rig = try MPMRig()
    // Init already compared MSL sizeof/offsetof with Swift (throws on mismatch).
    XCTAssertEqual(MemoryLayout<PBParticle>.stride, 112)
    XCTAssertEqual(MemoryLayout<PBSimConstants>.stride, 192)
    XCTAssertNotNil(rig.solver.simdProbePassed)
    print("SIMD-group probe on \(rig.device.name): \(rig.solver.simdProbePassed == true ? "pass" : "FAIL") -> \(rig.solver.usesSIMDGroupReduction ? "SIMD-group" : "threadgroup-atomic fallback") reduction")
    // Life-size tank at 2 mm: 36 cells across, Δx fitted to the width.
    XCTAssertEqual(rig.solver.interiorCells.x, 36)
    XCTAssertEqual(rig.solver.cellSize, 0.0712 / 36, accuracy: 1e-12)
  }

  func testSubstepRule() {
    // Water pool 69 mm deep at Δx 1.96 mm, 1/120 s, Π ≤ 0.085 -> 12 substeps (mpm-metal.md §12.3 table).
    var q = MPMQuality.standard
    q.hydrostaticLimit = 0.085
    let r = MPMSubstepRule.plan(frameTime: 1.0 / 120, cellSize: 0.0706 / 36, peakAcceleration: 9.81, depth: 0.069,
                                maxSpeed: 0, vibrationFrequency: 0, shearWaveSpeed: 0, quality: q)
    XCTAssertEqual(r.hydrostatic, 12)
    XCTAssertEqual(r.substeps, 12)
    XCTAssertFalse(r.lagging)
    // Elastic rule: putty c_s = 4.26 m/s at Δx 2 mm, k = 3 -> 15 substeps.
    let e = MPMSubstepRule.plan(frameTime: 1.0 / 120, cellSize: 0.002, peakAcceleration: 0, depth: 0, maxSpeed: 0,
                                vibrationFrequency: 0, shearWaveSpeed: 4.26, quality: .standard)
    XCTAssertEqual(e.elastic, 15)
    // Vibration rule: 120 Hz drive needs >= 8 per period.
    let v = MPMSubstepRule.plan(frameTime: 1.0 / 120, cellSize: 0.002, peakAcceleration: 0, depth: 0, maxSpeed: 0,
                                vibrationFrequency: 120, shearWaveSpeed: 0, quality: .standard)
    XCTAssertEqual(v.vibration, 8)
    // Over the cap: time dilates proportionally and the frame reports lagging.
    let l = MPMSubstepRule.plan(frameTime: 1.0 / 60, cellSize: 0.0011, peakAcceleration: 9.81, depth: 0.09, maxSpeed: 1,
                                vibrationFrequency: 0, shearWaveSpeed: 0, quality: .standard)
    XCTAssertTrue(l.lagging)
    XCTAssertEqual(l.substeps, 20)
    XCTAssertEqual(l.simulatedTime, 1.0 / 60 * 20 / Double(l.hydrostatic), accuracy: 1e-12)
  }

  func testMaterialConversion() {
    var m = ContinuumPresets.oobleck
    m.failureStress = .infinity
    let g = PBMaterial.make(m)
    XCTAssertEqual(g.model, UInt32(PB_MODEL_EVP))
    XCTAssertEqual(g.failureStress, 1e30)
    XCTAssertEqual(g.dst, 1)
    XCTAssertEqual(g.phi, 0.52, accuracy: 1e-6)
    XCTAssertEqual(g.eaOverR, Float(17_500 / ContinuumMaterial.gasConstant), accuracy: 1e-3)
    let mr = PBMaterial.make(ContinuumPresets.mrFluid)
    XCTAssertEqual(Double(mr.fieldDeadZone), 100e-6 / (4e-7 * Double.pi), accuracy: 1e-3)   // 79.6 A/m
    XCTAssertEqual(Double(mr.fieldK), 6.33e-6, accuracy: 1e-9)
    let native = PBMaterial.make(ContinuumPresets.waterLike, nativeViscosity: 0.01)
    XCTAssertEqual(native.model, UInt32(PB_MODEL_LIQUID))
    XCTAssertEqual(native.nativeViscosity, 0.01, accuracy: 1e-9)
  }

  // MARK: Fill, clear, emit, drain

  func testFillCounts() throws {
    let rig = try MPMRig()
    let dx = rig.solver.cellSize
    // Grid-aligned rectangle of 10 x 20 cells -> 4 particles per cell.
    let n = rig.solver.fill(rect: CGRect(x: 2 * dx, y: 0, width: 10 * dx, height: 20 * dx), material: 0, temperature: 293.15)
    XCTAssertEqual(n, 800)
    // Right triangle with legs of 8 cells along the lattice: count the 2x2 sites strictly below the diagonal.
    let a = 20 * dx, s = 8.1 * dx                 // no lattice site on the hypotenuse
    let tri: [SIMD2<Double>] = [SIMD2(a, 0), SIMD2(a + s, 0), SIMD2(a, s)]
    var expected = 0
    for j in 0..<16 { for i in 0..<16 {
      let x = (Double(i) + 0.5) * 0.5 * dx, y = (Double(j) + 0.5) * 0.5 * dx
      if x + y < s { expected += 1 }
    } }
    let m = rig.solver.fill(polygon: tri, material: 0, temperature: 293.15)
    XCTAssertEqual(m, expected)
    let st = rig.run(1)
    XCTAssertEqual(st.liveParticles, n + m)
    XCTAssertEqual(st.particleSlots, n + m)
    XCTAssertEqual(st.droppedOnInject, 0)
    // A fill that does not fit is cut at capacity and counted.
    let small = try MPMRig(capacity: 100)
    small.solver.fill(rect: CGRect(x: 0, y: 0, width: 10 * dx, height: 10 * dx), material: 0, temperature: 293.15)
    let s2 = small.run(1)
    XCTAssertEqual(s2.liveParticles, 100)
    XCTAssertEqual(s2.droppedOnInject, 300)
  }

  func testClearRemovesEverythingAndRefillWorks() throws {
    let rig = try MPMRig()
    rig.solver.fill(rect: CGRect(x: 0.01, y: 0, width: 0.03, height: 0.03), material: 0, temperature: 293.15)
    XCTAssertGreaterThan(rig.run(5).liveParticles, 0)
    rig.solver.clear()
    let st = rig.run(2)
    XCTAssertEqual(st.liveParticles, 0)
    XCTAssertEqual(st.particleSlots, 0)
    let n = rig.solver.fill(rect: CGRect(x: 0.0, y: 0, width: 0.02, height: 0.02), material: 0, temperature: 293.15)
    XCTAssertEqual(rig.run(3).liveParticles, n)
  }

  func testEmitterPoursAndDrainRemoves() throws {
    let rig = try MPMRig()
    var input = MPMFrameInput()
    input.emitters = [MPMEmitter(position: SIMD2(0.035, 0.08), radius: 0.004, velocity: SIMD2(0, -0.3), material: 0, rate: 3000)]
    let poured = rig.run(60, input: input)
    XCTAssertGreaterThan(poured.liveParticles, 500, "0.5 s at 3000 particles/s")
    XCTAssertLessThan(poured.liveParticles, 2500)
    XCTAssertEqual(poured.emitted, poured.liveParticles)
    XCTAssertEqual(poured.nanCount, 0)
    // A drain over the whole floor area removes the pool.
    var drain = MPMFrameInput()
    drain.drains = [(position: SIMD2(0.0356, 0.0), radius: 0.06)]
    let drained = rig.run(30, input: drain)
    XCTAssertEqual(drained.liveParticles, 0)
    XCTAssertEqual(drained.drained, poured.liveParticles)
    // Freed slots are reused before new ones.
    rig.solver.fill(rect: CGRect(x: 0.0, y: 0, width: 0.01, height: 0.01), material: 0, temperature: 293.15)
    let refilled = rig.run(1)
    XCTAssertEqual(refilled.particleSlots, poured.particleSlots)
  }

  /// An emitter in the tank's bottom-left cell pours there (the first tank row and column are valid emission cells).
  func testEmitterReachesTheFirstCell() throws {
    let rig = try MPMRig()
    let dx = rig.solver.cellSize
    var input = MPMFrameInput(gravity: .zero)
    input.emitters = [MPMEmitter(position: SIMD2(0.5 * dx, 0.5 * dx), radius: 0.9 * dx, material: 0, rate: 4000)]
    let st = rig.run(10, input: input)
    XCTAssertGreaterThan(st.emitted, 0, "the corner cell emits")
    XCTAssertEqual(st.nanCount, 0)
    for p in rig.solver.debugParticles() where p.enabled {
      XCTAssertLessThan(max(p.position.x, p.position.y), 3 * dx, "particles appear in the corner cell")
    }
  }

  // MARK: Dam break: stability, conservation, determinism, binning

  /// Water column 15 x 40 cells (29.7 x 79.1 mm) at the left wall: 2,400 particles.
  private func damBreakRig(verification: MPMVerificationOptions = MPMVerificationOptions(),
                           quality: MPMQuality = .standard) throws -> MPMRig {
    let rig = try MPMRig(domain: MPMDomain(heleShawGap: 0), quality: quality, verification: verification)
    let dx = rig.solver.cellSize
    let n = rig.solver.fill(rect: CGRect(x: 0, y: 0, width: 15 * dx, height: 40 * dx), material: 0, temperature: 293.15)
    XCTAssertEqual(n, 2400)
    return rig
  }

  func testDamBreakThreeSecondsNoNaNOrOverflow() throws {
    let rig = try damBreakRig()
    var peak = 0.0
    var maxSub = 0
    let st = rig.run(360) { _, s in peak = max(peak, s.maxSpeed); maxSub = max(maxSub, s.substeps) }
    print(String(format: "dam break 3 s: live %d, peak v %.3f m/s, v(3 s) %.4f m/s, mean J %.3f, substeps max %d, clamps %d, overflow %d, NaN %d",
                 st.liveParticles, peak, st.maxSpeed, st.volumeRatio, maxSub, st.clampedDisplacements, st.overflowCount, st.nanCount))
    XCTAssertEqual(st.liveParticles, 2400)
    XCTAssertEqual(st.nanCount, 0)
    XCTAssertEqual(st.overflowCount, 0)
    XCTAssertEqual(st.determinantGuards, 0)
    XCTAssertGreaterThan(peak, 0.3, "the column must collapse")
    XCTAssertLessThan(st.maxSpeed, 0.2, "settled after 3 s")
    XCTAssertGreaterThan(st.volumeRatio, 0.9)
    XCTAssertLessThan(st.volumeRatio, 1.05)
    for p in rig.solver.debugParticles() where p.enabled {
      XCTAssertTrue(p.position.x.isFinite && p.position.y.isFinite)
      XCTAssertGreaterThanOrEqual(p.position.y, -0.5 * rig.solver.cellSize)
    }
  }

  func testMassConservation() throws {
    var v = MPMVerificationOptions()
    v.sampleGridMass = true
    let rig = try damBreakRig(verification: v)
    let expected = 2400 * 0.25 * 1000 * pow(rig.solver.cellSize, 2)   // kg per metre of depth (gap 0)
    var worst = 0.0
    rig.run(120) { f, s in
      guard f % 10 == 9, let g = s.gridMass else { return }
      worst = max(worst, abs(g - expected) / expected, abs(s.particleMass - expected) / expected)
    }
    print(String(format: "grid mass vs particle mass: worst relative error %.2e", worst))
    XCTAssertLessThan(worst, 1e-5)
  }

  func testDeterminismBitwise() throws {
    let a = try damBreakRig(), b = try damBreakRig()
    for f in 0..<120 {
      a.run(1); b.run(1)
      if a.particleBytes() != b.particleBytes() { XCTFail("runs diverged at frame \(f + 1)"); return }
    }
    // Serial and concurrent (explicit barriers) encoders give the same bits.
    var serial = MPMVerificationOptions()
    serial.concurrentDispatch = false
    let c = try damBreakRig(verification: serial)
    c.run(120)
    XCTAssertEqual(a.particleBytes(), c.particleBytes(), "serial vs concurrent encoder")
  }

  func testBinningCoverage() throws {
    let rig = try damBreakRig()
    for f in 0..<40 {
      rig.run(1)
      let st = rig.solver.state
      let slot = Int(rig.solver.globalSubstep & 1)
      let d = st.dispatch.contents().bindMemory(to: PBBukkitDispatch.self, capacity: 2)[slot]
      let list = st.bukkitParticles.contents().bindMemory(to: UInt32.self, capacity: rig.solver.capacity)
      let td = st.threadData.contents().bindMemory(to: PBBukkitThreadData.self, capacity: Int(d.groupsX))
      let parts = st.particles.contents().bindMemory(to: PBParticle.self, capacity: rig.solver.capacity)
      var seen = [Int](repeating: 0, count: 2400)
      var wrong = 0
      for g in 0..<Int(d.groupsX) {
        let t = td[g]
        XCTAssertLessThanOrEqual(t.rangeCount, UInt32(PB_TILE_NODES))
        for k in 0..<Int(t.rangeCount) {
          let pi = Int(list[Int(t.rangeStart) + k])
          guard pi < seen.count else { XCTFail("frame \(f + 1): list entry \(pi) out of range (group \(g) start \(t.rangeStart) count \(t.rangeCount), allocator \(d.particleAllocator), groups \(d.groupsX))"); return }
          seen[pi] += 1
          let pos = parts[pi].position
          if Int(floor(pos.x)) / Int(PB_BUKKIT_SIZE) != Int(t.bukkitX) || Int(floor(pos.y)) / Int(PB_BUKKIT_SIZE) != Int(t.bukkitY) { wrong += 1 }
        }
      }
      XCTAssertEqual(seen.filter { $0 != 1 }.count, 0, "frame \(f + 1): every particle exactly once")
      XCTAssertEqual(wrong, 0, "frame \(f + 1): every particle in its own bukkit")
      XCTAssertEqual(Int(d.particleAllocator), 2400)
    }
  }

  // MARK: Rigid-body coupling

  /// Archimedes: a static body submerged in a 70 mm pool. F_y = ρ·g·A·gap within 5 % (mean over t = 2–4 s). Water with
  /// a thin-tank drag (k = 0.05 Pa·s, gap 5 mm) so sloshing dies down, as in mpm-metal.md §9.3.
  static func buoyancy(quality: MPMQuality, circle: Bool, simd: Bool? = nil, shift: Double = 0) throws -> (ratio: Double, fx: Double, particles: Data) {
    var v = MPMVerificationOptions()
    v.useSIMDGroupReduction = simd
    var water = ContinuumPresets.waterLike
    water.consistency = 0.05
    let gap = 0.005
    let rig = try MPMRig(domain: MPMDomain(heleShawGap: gap, heleShawMinTime: 0), quality: quality, verification: v,
                         materials: [water])
    let W = rig.solver.domain.size.x, dx = rig.solver.cellSize
    let half = circle ? SIMD2(0.007, 0.007) : SIMD2(0.011, 0.0055)
    let centre = SIMD2(W / 2, 0.035) + shift * dx
    let lo = centre - half, hi = centre + half
    if circle {
      // The pool minus the disc: one polygon (even-odd rule) with a zero-width bridge from the left wall to the disc.
      let outline = (0...64).map { i in centre + half.x * SIMD2(-cos(Double(i) * .pi / 32), sin(Double(i) * .pi / 32)) }
      rig.solver.fill(polygon: [SIMD2(0, centre.y), SIMD2(0, 0), SIMD2(W, 0), SIMD2(W, 0.07), SIMD2(0, 0.07), SIMD2(0, centre.y)]
                      + outline, material: 0, temperature: 293.15)
    } else {
      for r in [CGRect(x: 0, y: 0, width: W, height: lo.y), CGRect(x: 0, y: hi.y, width: W, height: 0.07 - hi.y),
                CGRect(x: 0, y: lo.y, width: lo.x, height: hi.y - lo.y), CGRect(x: hi.x, y: lo.y, width: W - hi.x, height: hi.y - lo.y)] {
        rig.solver.fill(rect: r, material: 0, temperature: 293.15)
      }
    }
    var input = MPMFrameInput()
    input.colliders = [MPMCollider(shape: circle ? .circle(radius: half.x) : .box(halfSize: half), position: centre,
                                   friction: 0, bodyIndex: 0)]
    var jy = 0.0, jx = 0.0, t = 0.0
    rig.run(480, input: input) { f, s in
      guard f >= 240 else { return }
      jy += s.bodyImpulses[0].y; jx += s.bodyImpulses[0].x; t += s.simulatedTime
    }
    let area = circle ? Double.pi * half.x * half.x : 4 * half.x * half.y
    let archimedes = 1000 * 9.81 * area * gap
    return (jy / t / archimedes, jx / t / archimedes, rig.particleBytes())
  }

  func testBuoyancyFromBodyImpulses() throws {
    for circle in [false, true] {
      let r = try Self.buoyancy(quality: .bench, circle: circle)
      print(String(format: "buoyancy (%@, dx 1.1 mm): F_y / (rho g A gap) = %.4f, F_x / (rho g A gap) = %.4f",
                   circle ? "disc r 7 mm" : "box 22 x 11 mm", r.ratio, r.fx))
      XCTAssertEqual(r.ratio, 1, accuracy: 0.05)
      XCTAssertEqual(r.fx, 0, accuracy: 0.05)
    }
  }

  /// Kinematic tools (Rheo's finger and stir paddle): a capsule dragged through honey meets a drag opposite to its
  /// motion and carries the fluid along; a box paddle spun about its centre meets a resisting torque. Checks the sign
  /// conventions of `bodyImpulses` (impulse ON the body, angular about the collider's frame-start position).
  func testMovingCollidersFeelDragAndTorque() throws {
    let rig = try MPMRig(domain: MPMDomain(heleShawGap: 0.01), materials: [ContinuumPresets.honey])
    let W = rig.solver.domain.size.x
    rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.04), material: 0, temperature: 293.15)
    rig.run(60)
    // Capsule (finger) at mid-depth moving right at 5 cm/s for 0.25 s.
    var x = 0.02
    var jx = 0.0, jy = 0.0, t = 0.0
    for _ in 0..<30 {
      var input = MPMFrameInput()
      input.colliders = [MPMCollider(shape: .capsule(halfLength: 0.002, radius: 0.003), position: SIMD2(x, 0.02),
                                     angle: .pi / 2, velocity: SIMD2(0.05, 0), friction: 0.5, bodyIndex: 3)]
      let s = rig.run(1, input: input)
      x += 0.05 * s.simulatedTime
      jx += s.bodyImpulses[3].x; jy += s.bodyImpulses[3].y; t += s.simulatedTime
      XCTAssertEqual(s.bodyImpulses[0], .zero, "only bodyIndex 3 accumulates")
    }
    let near = rig.solver.debugParticles().filter { $0.enabled && simd_length($0.position - SIMD2(x, 0.02)) < 0.008 }
    let carried = near.map(\.velocity.x).reduce(0, +) / Double(max(near.count, 1))
    print(String(format: "capsule through honey: mean F_x %.3e N, F_y %.3e N, fluid near it %.4f m/s", jx / t, jy / t, carried))
    XCTAssertLessThan(jx, 0, "drag on the finger opposes its motion")
    XCTAssertGreaterThan(carried, 0.005, "the finger carries honey along")
    // Box paddle spinning anticlockwise at 4 rad/s about its centre: the fluid resists (angular impulse < 0).
    var angle = 0.0, L = 0.0
    for _ in 0..<30 {
      var input = MPMFrameInput()
      input.colliders = [MPMCollider(shape: .box(halfSize: SIMD2(0.008, 0.0015)), position: SIMD2(W / 2, 0.02), angle: angle,
                                     angularVelocity: 4, friction: 0.5, bodyIndex: 1)]
      let s = rig.run(1, input: input)
      angle += 4 * s.simulatedTime
      L += s.bodyImpulses[1].z
      XCTAssertEqual(s.nanCount, 0)
    }
    print(String(format: "paddle spinning in honey: angular impulse %.3e N·m·s over 0.25 s", L))
    XCTAssertLessThan(L, 0, "torque on the paddle opposes its spin")
  }

  func testSIMDFallbackMatchesSIMDPath() throws {
    let probe = try MPMRig()
    guard probe.solver.simdProbePassed == true else { throw XCTSkip("SIMD-group functions unavailable on this GPU") }
    let simdRun = try Self.buoyancy(quality: .standard, circle: false, simd: true)
    let fallback = try Self.buoyancy(quality: .standard, circle: false, simd: false)
    print(String(format: "buoyancy SIMD path %.4f, fallback %.4f", simdRun.ratio, fallback.ratio))
    XCTAssertEqual(simdRun.particles, fallback.particles, "impulse reduction must not change the particle state")
    XCTAssertEqual(simdRun.ratio, fallback.ratio, accuracy: 0.005)
  }

  // MARK: Telemetry

  func testStatsSanityAtRest() throws {
    let rig = try MPMRig()
    let W = rig.solver.domain.size.x
    let n = rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.02), material: 0, temperature: 300)
    var input = MPMFrameInput()
    input.probe = SIMD2(W / 2, 0.01)
    let st = rig.run(240, input: input)
    XCTAssertEqual(st.liveParticles, n)
    XCTAssertLessThan(st.maxSpeed, 0.05)
    XCTAssertGreaterThanOrEqual(st.kineticEnergy, 0)
    XCTAssertEqual(st.volumeRatio, 1, accuracy: 0.05)
    XCTAssertEqual(st.meanTemperature, 300, accuracy: 0.01)
    XCTAssertEqual(st.meanStructure, 1, accuracy: 1e-6)
    XCTAssertGreaterThan(st.substeps, 1)
    XCTAssertFalse(st.lagging)
    XCTAssertGreaterThan(st.gpuMilliseconds, 0)
    XCTAssertEqual(st.simulatedTime, 1.0 / 120, accuracy: 1e-12)
    XCTAssertEqual(st.jammedFraction, 0)
    XCTAssertGreaterThanOrEqual(st.probe.shearRate, 0)
    XCTAssertGreaterThan(st.particleMass, 0)
    print(String(format: "stats at rest: v_max %.4f m/s, KE %.2e J, J %.4f, substeps %d, probe gdot %.3f 1/s tau %.4f Pa",
                 st.maxSpeed, st.kineticEnergy, st.volumeRatio, st.substeps, st.probe.shearRate, st.probe.stress))
  }

  // MARK: Quality switch

  func testQualitySwitchResamplesTheFluid() throws {
    let rig = try MPMRig()
    let W = rig.solver.domain.size.x
    rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.03), material: 0, temperature: 293.15)
    let before = rig.run(30)
    let areaBefore = Double(before.liveParticles) * 0.25 * pow(rig.solver.cellSize, 2)
    rig.solver.setQuality(.high)
    rig.run(3)
    XCTAssertEqual(rig.solver.quality, .high)
    XCTAssertEqual(rig.solver.cellSize, 0.0016, accuracy: 0.05 * 0.0016)
    let after = rig.run(30)
    let areaAfter = Double(after.liveParticles) * 0.25 * pow(rig.solver.cellSize, 2)
    print(String(format: "quality switch: %d -> %d particles, area %.3e -> %.3e m^2", before.liveParticles, after.liveParticles, areaBefore, areaAfter))
    XCTAssertEqual(areaAfter / areaBefore, 1, accuracy: 0.1)
    XCTAssertEqual(after.nanCount, 0)
  }
}
