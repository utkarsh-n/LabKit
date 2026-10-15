import XCTest
import simd
@testable import LabKitCore

/// Integrators and clocks: RK4, the substep rule, symplectic Euler, springs, rings, fixed steps, frame/sim clocks.
final class IntegratorTests: XCTestCase {
  func testRK4HarmonicOscillatorConservesEnergy() {
    let w = 2 * Double.pi
    var y = SIMD2<Double>(1, 0)  // (x, v): SIMD2 conforms to IntegrableState
    let h = 1.0 / 120
    for _ in 0..<(120 * 100) { y = RK4.step(y, h: h) { SIMD2($0.y, -w * w * $0.x) } }
    let e = 0.5 * y.y * y.y + 0.5 * w * w * y.x * y.x
    XCTAssertEqual(e, 0.5 * w * w, accuracy: 0.5 * w * w * 1e-4)
    XCTAssertEqual(y.x, 1, accuracy: 1e-3, "back where it started after 100 whole periods")
  }

  func testRK4ProjectKeepsConstraint() {
    // Rotation about z of a unit vector, renormalised at every stage (Gyre's spin-axis projection).
    let omega = V3(0, 0, 3)
    var v = V3(1, 0, 0)
    for _ in 0..<1000 { v = RK4.step(v, h: 0.01, project: { simd_normalize($0) }) { simd_cross(omega, $0) } }
    XCTAssertEqual(simd_length(v), 1, accuracy: 1e-12)
    XCTAssertEqual(atan2(v.y, v.x), wrapAngle(30), accuracy: 1e-6)
  }

  func testRK4FourthOrderConvergence() {
    func err(_ h: Double) -> Double {
      var x = 1.0
      let n = Int((1 / h).rounded())
      for _ in 0..<n { x = RK4.step(x, h: h) { -$0 } }
      return abs(x - exp(-1))
    }
    let ratio = err(0.1) / err(0.05)
    XCTAssertEqual(log2(ratio), 4, accuracy: 0.2)
  }

  func testSubstepRule() {
    // GyroSim at 12,000 rpm (×2 for the blade): ⌈(1/120)·2513/0.1⌉ = 210.
    XCTAssertEqual(substepCount(dt: 1.0 / 120, fastestRate: 12_000 * 2 * .pi / 60 * 2), 210)
    XCTAssertEqual(substepCount(dt: 1.0 / 120, fastestRate: 0), 1)
    XCTAssertEqual(substepCount(dt: 0, fastestRate: 1e9), 1)
    XCTAssertEqual(substepCount(dt: 1, fastestRate: 1e9), 2000, "capped")
    XCTAssertEqual(substepCount(dt: 1.0 / 60, fastestRate: .infinity), 1, "non-finite rates don't explode")
  }

  func testSymplecticEulerFreeFall() {
    var p = SIMD2<Double>(0, 10)
    var v = SIMD2<Double>(1, 0)
    let g = SIMD2<Double>(0, -Gravity.g0)
    let dt = 1e-4
    for _ in 0..<10_000 { symplecticEuler(&p, &v, acceleration: g, dt: dt) }
    XCTAssertEqual(p.x, 1, accuracy: 1e-9)
    XCTAssertEqual(p.y, 10 - 0.5 * Gravity.g0, accuracy: 1e-3)
    XCTAssertEqual(v.y, -Gravity.g0, accuracy: 1e-9)
  }

  func testDampedSpringRingsDownAndClamps() {
    var s = DampedSpring()
    s.kick(F3(0.3, 0, 0))
    var peak: Float = 0
    for _ in 0..<(120 * 10) {
      s.step(dt: 1.0 / 120, accel: .zero, enabled: true)
      peak = max(peak, simd_length(s.d))
    }
    XCTAssertLessThanOrEqual(peak, s.limit + 1e-6, "|d| ≤ 0.07")
    XCTAssertLessThan(simd_length(s.d), 1e-3, "ζ = 0.14 at 3.2 Hz rings down within 10 s")
    var off = DampedSpring()
    off.d = F3(0.05, 0, 0)
    off.step(dt: 1.0 / 120, accel: F3(5, 0, 0), enabled: false)
    XCTAssertLessThan(off.d.x, 0.05, "×0.9 decay and no drive when disabled")
  }

  func testRingBufferOrder() {
    var r = RingBuffer(capacity: 3, fill: 0)
    XCTAssertTrue(r.isEmpty)
    XCTAssertNil(r.last)
    for i in 1...5 { r.append(i) }
    XCTAssertTrue(r.isFull)
    XCTAssertEqual(r.elements, [3, 4, 5])
    XCTAssertEqual(r.last, 5)
    r.clear()
    XCTAssertEqual(r.elements, [])
  }

  func testFixedStepAccumulatesAndCaps() {
    var f = FixedStep(hz: 120, maxSteps: 4)
    XCTAssertEqual(f.steps(for: 1.0 / 60), 2)
    XCTAssertEqual(f.steps(for: 1.0 / 240), 0)
    XCTAssertEqual(f.alpha, 0.5, accuracy: 1e-9)
    XCTAssertEqual(f.steps(for: 1.0 / 240), 1)
    XCTAssertEqual(f.steps(for: 1.0 / 15), 4, "a 1/15 s hitch is capped at 4 steps")
    XCTAssertEqual(f.dropped, 4.0 / 120, accuracy: 1e-9)
    var total = 0
    var g = FixedStep(hz: 120)
    for _ in 0..<120 { total += g.steps(for: 1.0 / 120) }
    XCTAssertEqual(total, 120, "one step per 120 Hz frame, no drift")
  }

  func testFrameClockFirstFrameAndCap() {
    var c = FrameClock()
    XCTAssertEqual(c.tick(now: 100), 1.0 / 120)
    XCTAssertEqual(c.tick(now: 100 + 1.0 / 60), 1.0 / 60, accuracy: 1e-12)
    XCTAssertEqual(c.tick(now: 105), 1.0 / 15, "a hitch never explodes the physics")
  }

  func testSimClockTimeScaleAndPause() {
    var c = SimClock()
    c.timeScale = 0.25
    XCTAssertEqual(c.advance(real: 0.1), 0.025, accuracy: 1e-12)
    c.timeScale = 0
    XCTAssertEqual(c.advance(real: 0.1), 0.002, accuracy: 1e-12, "time scale floors at 0.02")
    c.paused = true
    XCTAssertEqual(c.advance(real: 0.1), 0)
    XCTAssertEqual(c.realTime, 0.3, accuracy: 1e-12)
  }

  func testThrottleAndAttackRelease() {
    var t = Throttle(hz: 10)
    XCTAssertTrue(t.ready(at: 0))
    XCTAssertFalse(t.ready(at: 0.05))
    XCTAssertTrue(t.ready(at: 0.1))
    var ar = AttackRelease(attack: 0.03, release: 0.35)
    ar.step(1, dt: 0.03)
    XCTAssertEqual(ar.value, 1 - exp(-1), accuracy: 1e-12)
    let top = ar.value
    ar.step(0, dt: 0.35)
    XCTAssertEqual(ar.value, top * exp(-1), accuracy: 1e-12)
  }

  func testMathHelpers() {
    XCTAssertEqual(lerp(2, 4, 0.25), 2.5)
    XCTAssertEqual(remap(5, from: 0...10, to: 100...200), 150)
    XCTAssertEqual(wrapAngle(2.5 * .pi), 0.5 * .pi, accuracy: 1e-12)
    XCTAssertEqual(smoothstep(0.0, 1.0, 0.5), 0.5)
    let n = perpendicular(to: V3(0, 0, 1))
    XCTAssertEqual(simd_dot(n, V3(0, 0, 1)), 0, accuracy: 1e-12)
    XCTAssertEqual(V2(3, 4).length, 5)
  }
}
