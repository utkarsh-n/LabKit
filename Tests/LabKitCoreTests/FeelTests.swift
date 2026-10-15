import XCTest
@testable import LabKitCore

/// The pure halves of the haptics and sound policy: hum governor, Rheo's stress map and events,
/// the sound bed rules, logPitch, device conditions and frame pacing.
final class FeelTests: XCTestCase {
  // MARK: Hum governor (§5.2)

  func testCausalHumFadesAfterEightSecondsIdle() {
    var g = HumGovernor()
    let dt = 1.0 / 120
    g.noteCause(at: 0)
    var t = 0.0
    var level = 0.0
    while t < 2 {
      level = g.step(wish: 1, strength: 1, allowed: true, now: t, dt: dt)
      t += dt
    }
    XCTAssertEqual(level, 1, accuracy: 1e-3, "rises to the wish with a 0.25 s lag")
    while t < 8 {
      level = g.step(wish: 1, strength: 1, allowed: true, now: t, dt: dt)
      t += dt
    }
    XCTAssertGreaterThan(level, 0.99, "still live just inside the 8 s idle")
    // Cause gone for > 8 s: fades out with τ 0.25 s and stops below 0.02, about 0.98 s later.
    var stoppedAt: Double?
    while t < 12 {
      level = g.step(wish: 1, strength: 1, allowed: true, now: t, dt: dt)
      if level == 0, stoppedAt == nil { stoppedAt = t }
      t += dt
    }
    let fade = (stoppedAt ?? 99) - 8
    XCTAssertEqual(fade, 0.25 * log(50), accuracy: 0.03)
    XCTAssertFalse(g.isPlaying)
  }

  func testAmbientHumNeedsNoCause() {
    var g = HumGovernor(policy: .ambient)
    var level = 0.0
    for i in 0..<240 { level = g.step(wish: 0.5, strength: 0.85, allowed: true, now: Double(i) / 120, dt: 1.0 / 120) }
    XCTAssertEqual(level, 0.425, accuracy: 1e-3, "wish × strength")
  }

  func testDisallowedHumStopsAtOnce() {
    var g = HumGovernor(policy: .ambient)
    for i in 0..<240 { g.step(wish: 1, strength: 1, allowed: true, now: Double(i) / 120, dt: 1.0 / 120) }
    XCTAssertTrue(g.isPlaying)
    XCTAssertEqual(g.step(wish: 1, strength: 1, allowed: false, now: 2, dt: 1.0 / 120), 0)
    XCTAssertEqual(g.level, 0, "paused / Low Power / thermal / inactive: no fade, a stop")
  }

  func testQuietWishNeverPlays() {
    var g = HumGovernor(policy: .ambient)
    var played = false
    for i in 0..<600 { played = played || g.step(wish: 0.015, strength: 1, allowed: true, now: Double(i) / 120, dt: 1.0 / 120) > 0 }
    XCTAssertFalse(played, "below 0.02 the hum stays off")
  }

  // MARK: Rheo's stress → hum map (§5.3 table)

  /// The note's table values are rounded to two places, so the tolerance is 0.006.
  func testStressIntensityTable() {
    XCTAssertLessThan(StressFeel.intensity(stress: 0.0125), 0.02, "water at the finger is silent, which is honest")
    XCTAssertEqual(StressFeel.intensity(stress: 17.7), 0.34, accuracy: 0.006)  // glycerol
    XCTAssertEqual(StressFeel.intensity(stress: 125), 0.47, accuracy: 0.006)  // honey
    XCTAssertEqual(StressFeel.intensity(stress: 37.6), 0.39, accuracy: 0.006)  // ketchup
    XCTAssertEqual(StressFeel.intensity(stress: 120), 0.46, accuracy: 0.006)  // mayonnaise
    XCTAssertEqual(StressFeel.intensity(stress: 11_400), 0.76, accuracy: 0.006)  // oobleck punch
    XCTAssertEqual(StressFeel.intensity(stress: 36_400), 0.83, accuracy: 0.006)  // MR fluid near a magnet
    XCTAssertEqual(StressFeel.intensity(stress: 1e9), 1)
    XCTAssertEqual(StressFeel.intensity(stress: -5), 0)
  }

  func testSharpnessAndSlosh() {
    XCTAssertEqual(StressFeel.sharpness(solidFraction: 0, fingerSpeed: 0.1), 0.18, accuracy: 1e-12)  // honey row
    XCTAssertEqual(StressFeel.sharpness(solidFraction: 1, fingerSpeed: 1), 1)  // jammed oobleck punch
    XCTAssertEqual(StressFeel.sharpness(solidFraction: 0.5, fingerSpeed: 0.1), 0.53, accuracy: 1e-12)  // mayonnaise
    let ref = StressFeel.sloshReference(density: 1000, fillArea: 0.005)
    XCTAssertEqual(ref, 0.025, accuracy: 1e-12)
    XCTAssertEqual(StressFeel.slosh(kineticEnergy: ref, reference: ref).intensity, 0.1, accuracy: 1e-12)
    XCTAssertEqual(StressFeel.slosh(kineticEnergy: ref / 4, reference: ref).intensity, 0.05, accuracy: 1e-12)
    XCTAssertEqual(StressFeel.slosh(kineticEnergy: ref, reference: ref).sharpness, 0.2)
  }

  func testStressSmoothing() {
    var f = StressFeel()
    let w = f.step(stress: 125, solidFraction: 0, fingerSpeed: 0.1, dt: 0.03)
    XCTAssertEqual(f.stress, 125 * (1 - exp(-1)), accuracy: 1e-9)
    XCTAssertLessThan(w.intensity, StressFeel.intensity(stress: 125))
    for _ in 0..<60 { _ = f.step(stress: 125, solidFraction: 0, fingerSpeed: 0.1, dt: 1.0 / 120) }
    XCTAssertEqual(f.stress, 125, accuracy: 0.01)
  }

  func testFeelEventsHaveHysteresis() {
    var d = FeelEventDetector()
    XCTAssertEqual(d.step(stress: 10, yieldStress: 15, jammedFraction: 0, dt: 0.01), [])
    XCTAssertEqual(d.step(stress: 16, yieldStress: 15, jammedFraction: 0, dt: 0.01), [.yield])
    XCTAssertEqual(d.step(stress: 13, yieldStress: 15, jammedFraction: 0, dt: 0.01), [], "no re-arm above 0.8 τ_y")
    XCTAssertEqual(d.step(stress: 16, yieldStress: 15, jammedFraction: 0, dt: 0.01), [])
    _ = d.step(stress: 11, yieldStress: 15, jammedFraction: 0, dt: 0.01)  // < 12: re-armed
    XCTAssertEqual(d.step(stress: 16, yieldStress: 15, jammedFraction: 0, dt: 0.01), [.yield])

    var j = FeelEventDetector()
    let onset = j.step(stress: 0, yieldStress: nil, jammedFraction: 0.6, dt: 0.01)
    XCTAssertTrue(onset.contains(.jam(fraction: 0.6)))
    XCTAssertFalse(j.step(stress: 0, yieldStress: nil, jammedFraction: 0.4, dt: 0.01).contains(.unjam))
    XCTAssertTrue(j.step(stress: 0, yieldStress: nil, jammedFraction: 0.2, dt: 0.01).contains(.unjam))
  }

  func testGrainRateFollowsJamChange() {
    var d = FeelEventDetector()
    let dt = 1.0 / 120
    var grains = 0
    var f = 0.0
    // Jammed fraction sweeping 0.2 → 0.45 and back (no jam onset), |df/dt| = 0.5 /s → rate min(40, 100) = 40 /s.
    for i in 0..<1200 {
      f = 0.325 + 0.125 * (i / 30 % 2 == 0 ? 1 : -1) * (Double(i % 30) / 30 * 2 - 1)
      for e in d.step(stress: 0, yieldStress: nil, jammedFraction: f, dt: dt) {
        if case .grain(let x) = e {
          grains += 1
          XCTAssertTrue((0.30...0.55).contains(x))
        }
      }
    }
    // 10 s at up to 40 /s with at most one per frame: expect a few hundred, well short of 1200.
    XCTAssertGreaterThan(grains, 150)
    XCTAssertLessThan(grains, 450)
    var still = FeelEventDetector()
    var none = 0
    for _ in 0..<600 { none += still.step(stress: 0, yieldStress: nil, jammedFraction: 0.1, dt: dt).count }
    XCTAssertEqual(none, 0, "no change, no grains")
  }

  // MARK: Sound policy (§6.3)

  func testLogPitch() {
    // spectra-lab: 110·2^(4·(log10 f − 5.5)/(21.5 − 5.5)).
    XCTAssertEqual(logPitch(pow(10, 5.5), domain: pow(10, 5.5)...pow(10, 21.5)), 110, accuracy: 1e-9)
    XCTAssertEqual(logPitch(pow(10, 21.5), domain: pow(10, 5.5)...pow(10, 21.5)), 1760, accuracy: 1e-6)
    XCTAssertEqual(logPitch(pow(10, 13.5), domain: pow(10, 5.5)...pow(10, 21.5)), 440, accuracy: 1e-6)
    // Rheo's gloop: 880·2^(−3p) over 1 mPa·s…100 kPa·s: water 880 Hz, a near-solid 110 Hz.
    XCTAssertEqual(logPitch(1e-3, domain: 1e-3...1e5, base: 880, octaves: 3, inverted: true), 880, accuracy: 1e-9)
    XCTAssertEqual(logPitch(1e5, domain: 1e-3...1e5, base: 880, octaves: 3, inverted: true), 110, accuracy: 1e-9)
    XCTAssertEqual(logPitch(1e9, domain: 1e-3...1e5, base: 880, octaves: 3, inverted: true), 110, accuracy: 1e-9, "clamped")
  }

  func testBedSilenceAndDucking() {
    var p = SoundPolicy()
    for _ in 0..<240 { p.stepBed(activity: 1, dt: 1.0 / 120) }
    XCTAssertEqual(p.bedLevel, 1, accuracy: 1e-3)
    p.micLive = true
    for _ in 0..<240 { p.stepBed(activity: 1, dt: 1.0 / 120) }
    XCTAssertEqual(p.bedLevel, 0.3, accuracy: 1e-3, "ducked to × 0.3 with the mic live")
    for flag in [\SoundPolicy.paused, \SoundPolicy.lowPower] {
      var q = p
      q[keyPath: flag] = true
      XCTAssertEqual(q.stepBed(activity: 1, dt: 1.0 / 120), 0)
      XCTAssertTrue(q.cuesAllowed, "cues stay when paused or in Low Power")
    }
    var off = p
    off.enabled = false
    XCTAssertEqual(off.stepBed(activity: 1, dt: 1.0 / 120), 0)
    XCTAssertFalse(off.cuesAllowed)
    var inactive = p
    inactive.active = false
    XCTAssertFalse(inactive.cuesAllowed)
  }

  func testCueSuppressionAroundMicBand() {
    var p = SoundPolicy()
    XCTAssertTrue(p.allowsPartial(frequency: 1400))
    p.micLive = true
    p.micBand = 60...250  // Rheo listening for bass
    XCTAssertFalse(p.allowsPartial(frequency: 95), "inside the band")
    XCTAssertFalse(p.allowsPartial(frequency: 400), "within one octave above")
    XCTAssertTrue(p.allowsPartial(frequency: 1800), "the threshold cue keeps its click")
    XCTAssertTrue(p.allowsPartial(frequency: 25))
    p.micBand = nil
    XCTAssertFalse(p.allowsPartial(frequency: 1800), "listening to everything: no cues while the mic is live")
  }

  // MARK: Device conditions and frame pacing

  func testFramePacingCap() {
    XCTAssertEqual(FramePacing.maxFramesInFlight, 2)
    XCTAssertEqual(FramePacing.preferredFPS(DeviceConditions()), 120)
    XCTAssertEqual(FramePacing.preferredFPS(DeviceConditions(thermal: .fair)), 120)
    XCTAssertEqual(FramePacing.preferredFPS(DeviceConditions(thermal: .serious)), 60)
    XCTAssertEqual(FramePacing.preferredFPS(DeviceConditions(thermal: .critical)), 60)
    XCTAssertEqual(FramePacing.preferredFPS(DeviceConditions(lowPower: true)), 60)
    XCTAssertEqual(FramePacing.preferredFPS(DeviceConditions(), requested: 30), 30)
    XCTAssertEqual(FramePacing.preferredFPS(DeviceConditions(lowPower: true), requested: 120), 60, "an app can only lower it")
  }

  func testThermalLevelsAndOverride() {
    XCTAssertEqual(ProcessInfo.ThermalState(level: 0).modulationValue, 0)
    XCTAssertEqual(ProcessInfo.ThermalState(level: 1).modulationValue, 1.0 / 3)
    XCTAssertEqual(ProcessInfo.ThermalState(level: 2).modulationValue, 2.0 / 3)
    XCTAssertEqual(ProcessInfo.ThermalState(level: 9).modulationValue, 1)
    XCTAssertEqual(ProcessInfo.ThermalState.serious.label, "Serious")
    let fake = DeviceConditions(thermal: .serious, lowPower: false)
    DeviceConditions.setOverride(fake)
    XCTAssertTrue(DeviceConditions.isOverridden)
    XCTAssertEqual(DeviceConditions.current, fake)
    XCTAssertTrue(DeviceConditions.current.isConstrained)
    DeviceConditions.setOverride(nil)
    XCTAssertFalse(DeviceConditions.isOverridden)
    XCTAssertEqual(DeviceConditions.current, DeviceConditions.live)
  }
}
