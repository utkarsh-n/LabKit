// ReferenceSolver2D smoke tests (tiny MPM scenes) and V10 (Hele-Shaw drag) at constitutive and MPM level.
// Kept small so `swift test` (debug) stays fast; the full V1–V12 suite runs in `labkit-physcheck mpm` (release).
import LabKitCore
import LabKitMPMReference
import simd
import XCTest

final class ReferenceSolverTests: XCTestCase {

  private func explicitDt(_ m: ContinuumMaterial, h: Double, courant: Double = 0.3) -> Double {
    courant * h / ((m.bulkModulus + m.shearModulus) / m.density).squareRoot()
  }

  // MARK: Seeding and bookkeeping

  func testFillSeedsTwoByTwoPerCell() {
    let h = 1e-3
    let m = testFluid()
    var sc = ReferenceScene(size: SIMD2(10 * h, 10 * h), cellSize: h)
    sc.fill(lower: .zero, upper: SIMD2(4 * h, 3 * h), material: 0, m)
    XCTAssertEqual(sc.particles.count, 4 * 3 * 4)
    XCTAssertEqual(sc.particles[0].volume, 0.25 * h * h, accuracy: 1e-20)
    XCTAssertEqual(sc.particles.reduce(0) { $0 + $1.mass }, m.density * 12 * h * h, accuracy: 1e-15)
    XCTAssertEqual(sc.particles[0].position, SIMD2(0.25 * h, 0.25 * h))
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    XCTAssertEqual(s.cells, SIMD2(10, 10))
    XCTAssertEqual(s.maximumWaveSpeed, 5, accuracy: 1e-12)                 // √((K + G)/ρ) = √(25 000/1000)
  }

  /// A uniformly moving, unstressed periodic block translates rigidly: momentum, mass and zero stress are exact.
  func testFreeTranslationConservesMomentum() {
    let h = 1e-3
    let m = testFluid()
    var sc = ReferenceScene(size: SIMD2(6 * h, 6 * h), cellSize: h, periodicX: true, periodicY: true)
    sc.fill(lower: .zero, upper: SIMD2(6 * h, 6 * h), material: 0, m, velocity: SIMD2(0.1, -0.05))
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let p0 = s.totalMomentum, m0 = s.totalMass
    let x0 = s.particles[7].position
    let dt = explicitDt(m, h: h)
    for _ in 0..<50 { s.step(dt: dt) }
    XCTAssertEqual(simd_length(s.totalMomentum - p0) / simd_length(p0), 0, accuracy: 1e-12)
    XCTAssertEqual(s.totalMass, m0)
    var dx = s.particles[7].position - x0 - s.time * SIMD2(0.1, -0.05)
    dx.x -= 6 * h * (dx.x / (6 * h)).rounded(); dx.y -= 6 * h * (dx.y / (6 * h)).rounded()
    XCTAssertLessThan(simd_length(dx), 1e-12)
    XCTAssertLessThan(s.particles.map { simd_length($0.stress) }.max()!, 1e-6)
    XCTAssertEqual(s.counters, ReferenceCounters())
  }

  /// Same scene, same steps: bit-identical particles.
  func testDeterminism() {
    func run() -> [ReferenceParticle] {
      let h = 2e-3
      let m = ContinuumPresets.ketchup
      var sc = ReferenceScene(size: SIMD2(12 * h, 10 * h), cellSize: h, walls: .tank,
                              bodyAcceleration: ReferenceScene.ramped(SIMD2(0, -9.81), over: 0.01))
      sc.fill(lower: SIMD2(2 * h, 0), upper: SIMD2(6 * h, 5 * h), material: 0, m)
      let s = ReferenceSolver2D(scene: sc, materials: [m])
      for _ in 0..<40 { s.step(dt: 1e-4) }
      return s.particles
    }
    let a = run(), b = run()
    XCTAssertEqual(a.count, b.count)
    for i in a.indices {
      XCTAssertEqual(a[i].position, b[i].position)
      XCTAssertEqual(a[i].state, b[i].state)
    }
  }

  // MARK: Tiny physics

  /// A small water column on a sticky floor settles without NaN or guard hits; the mean pressure is ρgH/2.
  func testRestingColumnSettlesToHydrostatic() {
    let h = 2.5e-3, rows = 8, height = Double(rows) * h, rho = 1000.0
    let m = testFluid(rho: rho, G: 5e3, K: 2.5e4, k: 0.05)
    var sc = ReferenceScene(size: SIMD2(4 * h, height + 6 * h), cellSize: h, periodicX: true,
                            walls: ReferenceWalls(bottom: .fixed, top: .open),
                            bodyAcceleration: ReferenceScene.ramped(SIMD2(0, -9.80665), over: 0.05))
    sc.heleShaw = .fixedTime(0.02)
    sc.fill(lower: .zero, upper: SIMD2(4 * h, height), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    s.advance(by: 0.25, dt: explicitDt(m, h: h))
    let meanP = s.particles.reduce(0) { $0 + $1.pressure } / Double(s.particles.count)
    XCTAssertEqual(meanP / (rho * 9.80665 * height / 2), 1, accuracy: 0.05)
    XCTAssertLessThan(s.maximumSpeed, 1e-3)
    XCTAssertEqual(s.counters.nonFinite, 0)
    XCTAssertEqual(s.counters.determinantGuards, 0)
    XCTAssertEqual(s.counters.speedClamps, 0)
  }

  /// Plane Couette (V2 geometry, 8 rows, Newtonian): wall shear stress ηU/h within 3 %, linear profile.
  func testTinyCouette() {
    let gap = 4e-3, rows = 8, u = 0.02
    let h = gap / Double(rows)
    let m = testFluid(k: 1)
    var sc = ReferenceScene(size: SIMD2(4 * h, gap), cellSize: h, periodicX: true,
                            walls: ReferenceWalls(bottom: .fixed, top: .sticky(velocity: SIMD2(u, 0))))
    sc.fill(lower: .zero, upper: SIMD2(4 * h, gap), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    s.advance(by: 0.06, dt: explicitDt(m, h: h))
    let tau = s.particles.reduce(0) { $0 + $1.cauchyStress.y } / Double(s.particles.count)
    XCTAssertEqual(tau / (u / gap), 1, accuracy: 0.03)
    let row = s.gridVelocity(atRow: rows / 2)
    XCTAssertEqual(row.count, 4)
    XCTAssertEqual(row[0].x / (0.5 * u), 1, accuracy: 0.02)
    let bins = s.profile(axis: 1, bins: 4, range: 0...gap) { $0.velocity.x }
    XCTAssertTrue(zip(bins, bins.dropFirst()).allSatisfy { $0.mean < $1.mean })
  }

  /// A kinematic box pushed down into a resting layer feels an upward reaction.
  func testKinematicBoxReaction() {
    let h = 2e-3
    let m = testFluid(k: 0.5)
    var sc = ReferenceScene(size: SIMD2(16 * h, 12 * h), cellSize: h, walls: .tank)
    sc.fill(lower: .zero, upper: SIMD2(16 * h, 6 * h), material: 0, m)
    sc.boxes = [ReferenceBox(center: SIMD2(8 * h, 7 * h), halfSize: SIMD2(2 * h, 1 * h), velocity: SIMD2(0, -0.1))]
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let dt = explicitDt(m, h: h)
    var fy = 0.0
    for _ in 0..<200 { s.step(dt: dt); fy = s.boxForces[0].y }
    XCTAssertGreaterThan(fy, 0)
    XCTAssertEqual(s.boxes[0].center.y, 7 * h - 0.1 * s.time, accuracy: 1e-12)
    XCTAssertEqual(s.counters.nonFinite, 0)
  }

  /// Sticky boxes impose their velocity; frictionless boxes remove only the inward normal component (nearest face).
  func testBoxConstraints() {
    var box = ReferenceBox(center: .zero, halfSize: SIMD2(2, 1), velocity: SIMD2(0, -1))
    XCTAssertEqual(box.constrain(SIMD2(3, 4), at: SIMD2(0, -0.9)), SIMD2(0, -1))
    box.sticky = false
    XCTAssertEqual(box.nearestFaceNormal(SIMD2(0.5, -0.9)), SIMD2(0, -1))
    XCTAssertEqual(box.nearestFaceNormal(SIMD2(1.95, 0.2)), SIMD2(1, 0))
    // Fluid below the plate moving up at 0.5 relative to a plate moving down at 1: pushed to the plate's speed, slip kept.
    XCTAssertEqual(box.constrain(SIMD2(0.3, 0.5), at: SIMD2(0.5, -0.9)), SIMD2(0.3, -1))
    // Moving away from the face faster than the plate: untouched.
    XCTAssertEqual(box.constrain(SIMD2(0.3, -2), at: SIMD2(0.5, -0.9)), SIMD2(0.3, -2))
  }

  func testBodyForceHelpers() {
    let g = SIMD2(0.0, -9.81)
    XCTAssertEqual(ReferenceScene.ramped(g, over: 0.1)(.zero, 0.05), 0.5 * g)
    XCTAssertEqual(ReferenceScene.ramped(g, over: 0.1)(.zero, 1), g)
    XCTAssertEqual(ReferenceScene.uniform(g)(SIMD2(1, 1), 3), g)
    let v = ReferenceScene.vibrating(g, amplitude: 20, frequency: 50)
    XCTAssertEqual(v(.zero, 0.005).y, -9.81 + 20, accuracy: 1e-9)                    // quarter period
  }

  // MARK: Scene modulators

  /// PB-MPM grid-volume correction: a uniform block reads J_grid = 1; a block whose reference volume is 10 % larger
  /// than the space it fills reads J_grid = 1/1.1 and relaxes J by `gridVolumeCorrection` per step.
  func testGridVolumeCorrection() {
    let h = 1e-3
    let m = testFluid(G: 1e3, K: 1e4, k: 1)
    var sc = ReferenceScene(size: SIMD2(4 * h, 4 * h), cellSize: h, periodicX: true, periodicY: true)
    sc.fill(lower: .zero, upper: SIMD2(4 * h, 4 * h), material: 0, m)
    sc.gridVolumeCorrection = 0.1
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    s.step(dt: 1e-5)
    XCTAssertEqual(s.particles[5].gridVolumeRatio, 1, accuracy: 1e-12)
    XCTAssertEqual(s.particles[5].state.J, 1, accuracy: 1e-12)
    s.modifyParticles { $0.volume *= 1.1 }
    s.step(dt: 1e-5)
    XCTAssertEqual(s.particles[5].gridVolumeRatio, 1 / 1.1, accuracy: 1e-12)
    XCTAssertEqual(s.particles[5].state.J, 1 + 0.1 * (1 / 1.1 - 1), accuracy: 1e-9)
  }

  /// Two-sided correction (LK-FIX): a compressed particle in an under-filled neighbourhood relaxes J up to
  /// 1 − tolerance·|a|·Δt²/Δx; without the option it keeps its compression (upstream PB-MPM).
  func testGridVolumeUnderfillRelaxesCompression() {
    let h = 1e-3, dt = 1e-5
    let m = testFluid(G: 1e3, K: 1e4, k: 1)
    for tolerance in [nil, 3.0] as [Double?] {
      var sc = ReferenceScene(size: SIMD2(4 * h, 4 * h), cellSize: h, periodicX: true, periodicY: true,
                              bodyAcceleration: { _, _ in SIMD2(0, -9.81) })
      sc.fill(lower: .zero, upper: SIMD2(4 * h, 4 * h), material: 0, m)
      sc.gridVolumeCorrection = 0.1
      sc.gridVolumeUnderfillTolerance = tolerance
      let s = ReferenceSolver2D(scene: sc, materials: [m])
      s.modifyParticles { $0.volume *= 0.8; $0.state.J = 0.9 }          // J_grid = 1.25: under-filled, but J = 0.9
      s.step(dt: dt)
      let floorJ = 1 - 3 * 9.81 * dt * dt / h
      let j = s.particles[5].state.J
      if tolerance == nil { XCTAssertLessThan(j, 0.9 + 1e-6, "upstream keeps the compression") }
      else { XCTAssertEqual(j, 0.9 + 0.1 * (floorJ - 0.9), accuracy: 2e-3, "relaxes toward the floor") }
    }
  }

  /// The Kelvin clamp also scales the field-induced yield (LK-FIX): far above the clamp the particle's flow law sees
  /// τ_field × cap/|a|, so MR fluid can still flow toward the magnet.
  func testKelvinClampScalesFieldYield() {
    let m = ContinuumPresets.mrFluid
    let s = 0.25
    let scaled = ReferenceSolver2D.fieldScaled(m, s)
    let h = 5e4
    XCTAssertEqual(EVP.fieldYield(fieldMagnitude: h, material: scaled),
                   min(s * m.field!.yieldSaturation * tanh(h / m.field!.saturationField), m.field!.clampFractionOfG * m.shearModulus),
                   accuracy: 1e-9)
    XCTAssertEqual(ReferenceSolver2D.fieldScaled(m, 1), m)
  }

  /// MR Kelvin body force μ₀χ|H|∇|H|/ρ (clamped at 3g) and the first-order field lag T₆₃, and the temperature
  /// relaxation toward ambient, after one step from rest.
  func testFieldForceLagAndTemperatureRelaxation() {
    let h = 1e-3, dt = 1e-5
    let m = ContinuumPresets.mrFluid
    let chi = m.field!.susceptibility
    for gradient in [1e6, 1e9] {                       // a ≈ 23 m/s² (free) and far above the 3g clamp
      let h0 = 1e4
      var sc = ReferenceScene(size: SIMD2(20 * h, 20 * h), cellSize: h,
                              walls: ReferenceWalls(left: .open, right: .open, bottom: .open, top: .open))
      sc.fill(lower: SIMD2(8 * h, 8 * h), upper: SIMD2(12 * h, 12 * h), material: 0, m, temperature: 300)
      sc.magneticField = { x, _ in h0 + gradient * (x.x - 0.008) }       // > 0 on every particle
      sc.ambientTemperature = 290
      sc.thermalTime = 0.5
      let s = ReferenceSolver2D(scene: sc, materials: [m])
      let expected = s.particles.reduce(0.0) { acc, p in
        let a = 4e-7 * Double.pi * chi * (h0 + gradient * (p.position.x - 0.008)) * gradient / m.density
        return acc + p.mass * min(a, 3 * ContinuumPresets.standardGravity)
      }
      s.step(dt: dt)
      XCTAssertEqual(s.totalMomentum.x / (dt * expected), 1, accuracy: 1e-9, "∇|H| = \(gradient)")
      XCTAssertEqual(s.totalMomentum.y, 0, accuracy: 1e-12 * abs(dt * expected))
      XCTAssertEqual(s.particles[0].state.temperature, 300 + (290 - 300) * (1 - exp(-dt / 0.5)), accuracy: 1e-9)
    }
    // Field switched on at t > 0: the particle's |H| lags with T₆₃ = 1 ms.
    var sc = ReferenceScene(size: SIMD2(8 * h, 8 * h), cellSize: h, periodicX: true, periodicY: true)
    sc.fill(lower: .zero, upper: SIMD2(8 * h, 8 * h), material: 0, m)
    sc.magneticField = { _, t in t > 0 ? 5e4 : 0 }
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    s.step(dt: dt)
    XCTAssertEqual(s.particles[0].fieldMagnitude, 5e4 * (1 - exp(-dt / 1e-3)), accuracy: 1e-6)
  }

  // MARK: V10 Hele-Shaw drag

  /// The gap-averaged drag reproduces t_HS = ρb²/(12η) (Newtonian) and dŪ/dt = −cŪⁿ (power law), exactly.
  func testV10HeleShawDragLaws() {
    let rho = 1000.0, b = 5e-3
    let newt = testFluid(rho: rho, G: 100, k: 0.01)
    let t = ReferenceSolver2D.heleShawTime(material: newt, state: EVPState(), speed: 0.1, gap: b)
    XCTAssertEqual(t, ReferenceLaws.heleShawTime(density: rho, gap: b, viscosity: 0.01), accuracy: 1e-15)
    XCTAssertEqual(t, 0.208333, accuracy: 1e-6)
    let pl = testFluid(rho: rho, G: 100, k: 1, n: 0.5)
    let c = ReferenceLaws.powerLawDragCoefficient(consistency: 1, index: 0.5, density: rho, gap: b)
    for u in [1e-3, 1e-2, 5e-2] {
      let tp = ReferenceSolver2D.heleShawTime(material: pl, state: EVPState(), speed: u, gap: b)
      XCTAssertEqual((u / tp) / (c * pow(u, 0.5)), 1, accuracy: 1e-12)
    }
    XCTAssertEqual(ReferenceLaws.powerLawStopTime(initial: 0.05, coefficient: c, index: 0.5) * 1e3, 27.95, accuracy: 0.01)
    // The floor holds.
    XCTAssertEqual(ReferenceSolver2D.heleShawTime(material: newt, state: EVPState(), speed: 0.1, gap: b, minimumTime: 1), 1)
  }

  /// MPM level (8 × 8 periodic block): the Newtonian decay equals v₀(1 + Δt/t_HS)^(−n) to 10⁻¹².
  func testV10HeleShawNewtonianBlock() {
    let h = 1e-3, rho = 1000.0, gap = 5e-3, eta = 0.01
    let m = testFluid(rho: rho, G: 100, K: 2e4, k: eta)
    var sc = ReferenceScene(size: SIMD2(8 * h, 8 * h), cellSize: h, periodicX: true, periodicY: true)
    sc.heleShaw = .gapAveraged(gap: gap, minimumTime: 0)
    sc.fill(lower: .zero, upper: SIMD2(8 * h, 8 * h), material: 0, m, velocity: SIMD2(0.1, 0))
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let dt = explicitDt(m, h: h)
    let tHS = ReferenceLaws.heleShawTime(density: rho, gap: gap, viscosity: eta)
    var worst = 0.0
    for i in 1...60 {
      s.step(dt: dt)
      let v = s.particles.reduce(0) { $0 + $1.velocity.x } / Double(s.particles.count)
      let be = 0.1 * pow(1 + dt / tHS, -Double(i))
      worst = max(worst, abs(v - be) / be)
    }
    XCTAssertLessThanOrEqual(worst, 1e-12)
  }

  /// MPM level: a power-law block stops in finite time t_stop = Ū₀^(1−n)/((1 − n)c), and Ū(t) matches before it.
  func testV10HeleShawPowerLawBlockStops() {
    let h = 1e-3, rho = 1000.0, gap = 5e-3, u0 = 0.05
    let m = testFluid(rho: rho, G: 100, K: 2e4, k: 1, n: 0.5)
    var sc = ReferenceScene(size: SIMD2(4 * h, 4 * h), cellSize: h, periodicX: true, periodicY: true)
    sc.heleShaw = .gapAveraged(gap: gap, minimumTime: 0)
    sc.fill(lower: .zero, upper: SIMD2(4 * h, 4 * h), material: 0, m, velocity: SIMD2(u0, 0))
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let c = ReferenceLaws.powerLawDragCoefficient(consistency: 1, index: 0.5, density: rho, gap: gap)
    let tStop = ReferenceLaws.powerLawStopTime(initial: u0, coefficient: c, index: 0.5)
    let dt = explicitDt(m, h: h)
    while s.time < 0.5 * tStop { s.step(dt: dt) }
    let v = s.particles.reduce(0) { $0 + $1.velocity.x } / Double(s.particles.count)
    let ex = ReferenceLaws.powerLawDragSpeed(time: s.time, initial: u0, coefficient: c, index: 0.5)
    XCTAssertLessThanOrEqual(abs(v - ex) / u0, 0.005)
    while s.time < 1.2 * tStop { s.step(dt: dt) }
    XCTAssertLessThanOrEqual(abs(s.particles.reduce(0) { $0 + $1.velocity.x }) / Double(s.particles.count), 1e-9 * u0)
  }
}
