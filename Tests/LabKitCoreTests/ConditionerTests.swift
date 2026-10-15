import XCTest
import simd
@testable import LabKitCore

/// SourceConditioner (sensor → modulation sources) and LabEnvironment accessors.
final class ConditionerTests: XCTestCase {
  private let dt = 1.0 / 120

  private func step(_ c: inout SourceConditioner, _ s: MotionSample, touch: TouchSample = .up, thermal: Double = 0) -> ModSources {
    c.step(motion: s, mic: nil, micGain: 1, pressureKPa: nil, thermal: thermal, touch: touch, dt: dt)
  }

  func testRestingPhoneIsQuiet() {
    var c = SourceConditioner()
    var out = ModSources()
    for _ in 0..<120 { out = step(&c, .resting) }
    XCTAssertEqual(out[.shake], 0)
    XCTAssertEqual(out[.jerk], 0, "no spurious jerk on the first frame")
    XCTAssertEqual(out[.turn], 0)
    XCTAssertEqual(out[.fieldDelta], 0, accuracy: 1e-9)
    XCTAssertEqual(out[.fieldStep], 0, accuracy: 1e-9)
    XCTAssertEqual(out[.field], simd_length(MotionSample.simulatedField), accuracy: 1e-9)
    XCTAssertEqual(out[.pressure], 1)
    // Pitch 60° (leaning back 30° from upright): the screen normal is 60° from vertical → (π/3)/π.
    XCTAssertEqual(out[.tilt], 1.0 / 3, accuracy: 1e-9)
  }

  func testMagnetApproachShowsInDeltaAndStep() {
    var c = SourceConditioner()
    for _ in 0..<240 { _ = step(&c, .resting) }
    var s = MotionSample.resting
    s.magneticField += V3(0, 0, 300)  // a magnet arrives along the screen normal: |B| 45.7 → 262 µT
    let first = step(&c, s)
    XCTAssertGreaterThan(first[.fieldDelta], 200)
    XCTAssertGreaterThan(first[.fieldStep], 200, "a step is a Feel cause (> 5 µT)")
    // Held there: the 0.5 s step decays within a couple of seconds, the 8 s baseline much later.
    var out = first
    for _ in 0..<(120 * 3) { out = step(&c, s) }
    XCTAssertLessThan(out[.fieldStep], 5)
    XCTAssertGreaterThan(out[.fieldDelta], 50)
  }

  func testJerkFollowsAccelerationChange() {
    var c = SourceConditioner()
    _ = step(&c, .resting)
    var s = MotionSample.resting
    s.userAcceleration = V3(1, 0, 0)  // a 1 g step in one frame: raw jerk 120 g/s, τ 0.05 s
    let out = step(&c, s)
    XCTAssertEqual(out[.shake], 1, accuracy: 1e-12)
    XCTAssertEqual(out[.jerk], 120 * (1 - exp(-dt / 0.05)), accuracy: 1e-9)
  }

  func testTouchAndThermalPassThrough() {
    var c = SourceConditioner()
    let out = step(&c, .resting, touch: TouchSample(down: true, position: SIMD2(0.25, 1.5), speed: 500, force: nil), thermal: 2.0 / 3)
    XCTAssertEqual(out[.touchDown], 1)
    XCTAssertEqual(out[.touchSpeed], 0.5)
    XCTAssertEqual(out[.touchX], 0.25)
    XCTAssertEqual(out[.touchY], 1, "clamped to the canvas")
    XCTAssertEqual(out[.touchForce], 1, "no force sensor → 1 while down")
    XCTAssertEqual(out[.thermal], 2.0 / 3)
    let up = step(&c, .resting)
    XCTAssertEqual(up[.touchDown], 0)
    XCTAssertEqual(up[.touchSpeed], 0)
  }

  func testMicSourcesAndReset() {
    var c = SourceConditioner()
    let snap = MicSnapshot(samples: [], level: 0.5, bass: 0.1, onset: 3)
    let out = c.step(motion: .resting, mic: snap, micGain: 2, pressureKPa: 90, thermal: 0, dt: dt)
    XCTAssertEqual(out[.micOnset], 3)
    XCTAssertEqual(out[.micBass], 0.2, accuracy: 1e-7)
    XCTAssertEqual(out[.micLevel], 1, "20·log10(1) + 55 over 45, clamped")
    XCTAssertEqual(out[.pressure], 90 / Atmosphere.seaLevelKPa, accuracy: 1e-12)
    XCTAssertGreaterThan(c.envelope.raw, 0)
    _ = c.step(motion: .resting, mic: nil, micGain: 1, pressureKPa: nil, thermal: 0, dt: dt)
    XCTAssertEqual(c.envelope.value, 0, "the envelope resets when the mic goes away")
  }

  func testEnvironmentSeparatesGravityFromShake() {
    var s = MotionSample.at(MotionSample.pose(pitch: .pi / 2))  // upright, screen vertical
    s.userAcceleration = V3(0.5, 0, 0)  // the phone accelerates to its right at 0.5 g
    let e = LabEnvironment.from(s, gravityScale: 2)
    XCTAssertEqual(e.screenGravityOnly.x, 0, accuracy: 1e-9)
    XCTAssertEqual(e.screenGravityOnly.y, -2 * Gravity.g0, accuracy: 1e-9)
    XCTAssertEqual(e.screenAcceleration.x, 0.5 * Gravity.g0, accuracy: 1e-9)
    XCTAssertEqual(e.screenAcceleration.y, 0, accuracy: 1e-9)
    // The combined vector (Gyre's effective gravity) is gravity − a.
    XCTAssertEqual(e.screenGravity.x, -0.5 * Gravity.g0, accuracy: 1e-9)
    XCTAssertEqual(e.screenNormalGravity, 0, accuracy: 1e-9)
    XCTAssertEqual(e.fieldMicroTesla, simd_length(MotionSample.simulatedField), accuracy: 1e-6)
  }

  func testEnvironmentFlatPhone() {
    let e = LabEnvironment.from(.at(.identity), gravityScale: 1)
    XCTAssertEqual(simd_length(e.screenGravityOnly), 0, accuracy: 1e-9)
    XCTAssertEqual(e.screenNormalGravity, -Gravity.g0, accuracy: 1e-9)
  }

  func testFeelCauses() {
    let causes = FeelCauses()
    var s = ModSources()
    XCTAssertFalse(causes.isLive(s, listen: 1, fingerDown: false))
    XCTAssertTrue(causes.isLive(s, listen: 0, fingerDown: true))
    s[.shake] = 0.2
    XCTAssertTrue(causes.isLive(s, listen: 0, fingerDown: false))
    s[.shake] = 0
    s[.micEnvelope] = 0.5
    XCTAssertFalse(causes.isLive(s, listen: 0, fingerDown: false), "a loud room counts only while Listen > 0")
    XCTAssertTrue(causes.isLive(s, listen: 0.3, fingerDown: false))
    s[.micEnvelope] = 0
    s[.fieldStep] = 6
    XCTAssertTrue(causes.isLive(s, listen: 0, fingerDown: false))
  }
}
