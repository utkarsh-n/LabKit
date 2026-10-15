import XCTest
@testable import LabKitCore

/// ModulationRouter: Gyre's drives as routes, gates, triggers, channels, smoothing and overrides.
final class ModulationTests: XCTestCase {
  private func spec(_ id: ParamID, _ range: ClosedRange<Double>, _ value: Double) -> ParamSpec {
    ParamSpec(id, title: id.rawValue, icon: "circle", range: range, defaultValue: value, hint: "", format: .number(precision: 2, unit: ""))
  }

  private var specs: [ParamID: ParamSpec] {
    ["gravity": spec("gravity", -1...3, 1), "air": spec("air", 0...3, 1), "temperature": spec("temperature", 273...373, 293)]
  }

  private let dt = 1.0 / 120

  private func gyreRouter() -> ModulationRouter {
    ModulationRouter([
      ModRoute("gravity", source: .micEnvelope, target: "gravity", depthParam: "listen", gate: ModGate("drives", 0), mode: .add(2)),
      ModRoute("air", source: .micEnvelope, target: "air", depthParam: "listen", gate: ModGate("drives", 1), mode: .multiply(3)),
      ModRoute(
        "kick", source: .micOnset, target: "kick", depthParam: "listen", gate: ModGate("drives", 3), curve: .normalize(5),
        mode: .trigger(threshold: 0)),
      ModRoute("film", source: .micEnvelope, target: "filmShimmer", depthParam: "listen", gate: ModGate("drives", 4)),
    ])
  }

  func testGravityDriveAddsDepthTimesEnvelopeTimesTwo() {
    var router = gyreRouter()
    var p = ParamValues(["gravity": 1, "air": 1, "listen": 0.6, "drives": 0])
    var s = ModSources()
    s[.micEnvelope] = 0.5
    let out = router.apply(s, to: &p, specs: specs, dt: dt)
    XCTAssertEqual(p["gravity"], 1.6, accuracy: 1e-12)  // Gyre: g = 1 + 0.6·0.5·2
    XCTAssertEqual(p["air"], 1)  // gated off
    XCTAssertEqual(out.levels["gravity"] ?? -1, 0.3, accuracy: 1e-12)
    XCTAssertNil(out.levels["air"])
  }

  func testAirDriveMultiplies() {
    var router = gyreRouter()
    var p = ParamValues(["gravity": 1, "air": 1, "listen": 1, "drives": 1])
    var s = ModSources()
    s[.micEnvelope] = 0.5
    _ = router.apply(s, to: &p, specs: specs, dt: dt)
    XCTAssertEqual(p["air"], 2.5, accuracy: 1e-12)  // ×(1 + 3·0.5)
    XCTAssertEqual(p["gravity"], 1)
  }

  func testTriggerIsEdgeDetectedAndRearms() {
    var router = gyreRouter()
    var s = ModSources()
    var p = ParamValues(["listen": 0.6, "drives": 3])
    s[.micOnset] = 7
    XCTAssertEqual(router.apply(s, to: &p, specs: specs, dt: dt).fired("kick")?.strength ?? 0, 0.6, accuracy: 1e-12)
    // Still above threshold next frame: no re-fire.
    XCTAssertNil(router.apply(s, to: &p, specs: specs, dt: dt).fired("kick"))
    // Drops to 0: re-arms; fires again on the next onset with strength 0.6·min(2.5/5, 1) = 0.3.
    s[.micOnset] = 0
    XCTAssertNil(router.apply(s, to: &p, specs: specs, dt: dt).fired("kick"))
    s[.micOnset] = 2.5
    XCTAssertEqual(router.apply(s, to: &p, specs: specs, dt: dt).fired("kick")?.strength ?? 0, 0.3, accuracy: 1e-12)
  }

  func testTriggerNeedsDepthAboveOnePercent() {
    var router = gyreRouter()
    var p = ParamValues(["listen": 0.005, "drives": 3])
    var s = ModSources()
    s[.micOnset] = 12
    XCTAssertTrue(router.apply(s, to: &p, specs: specs, dt: dt).triggers.isEmpty)
  }

  func testUnregisteredTargetIsAChannel() {
    var router = gyreRouter()
    var p = ParamValues(["listen": 0.5, "drives": 4])
    var s = ModSources()
    s[.micEnvelope] = 0.8
    let out = router.apply(s, to: &p, specs: specs, dt: dt)
    XCTAssertEqual(out["filmShimmer"], 0.4, accuracy: 1e-12)
    XCTAssertNil(p.storage["filmShimmer"], "channels never leak into the parameter copy")
  }

  func testRangeFractionAndClamp() {
    var router = ModulationRouter([
      ModRoute("heat", source: .micEnvelope, target: "temperature", depth: 0.5, mode: .rangeFraction, clampToRange: true),
      ModRoute("g", source: .micEnvelope, target: "gravity", mode: .add(10), clampToRange: false),
    ])
    var p = ParamValues(["temperature": 293, "gravity": 1])
    var s = ModSources()
    s[.micEnvelope] = 1
    _ = router.apply(s, to: &p, specs: specs, dt: dt)
    XCTAssertEqual(p["temperature"], 343, accuracy: 1e-9)  // + 0.5·100 K
    XCTAssertEqual(p["gravity"], 11, accuracy: 1e-12)  // unclamped, as Gyre (gravity can exceed the knob)
    s[.micEnvelope] = 2
    p = ParamValues(["temperature": 293, "gravity": 1])
    _ = router.apply(s, to: &p, specs: specs, dt: dt)
    XCTAssertEqual(p["temperature"], 373, accuracy: 1e-9, "clampToRange holds the knob's range")
  }

  func testHeldKnobWins() {
    var router = gyreRouter()
    var p = ParamValues(["gravity": 1, "listen": 1, "drives": 0])
    var s = ModSources()
    s[.micEnvelope] = 1
    let out = router.apply(s, to: &p, specs: specs, dt: dt, holding: ["gravity"])
    XCTAssertEqual(p["gravity"], 1)
    XCTAssertNil(out.levels["gravity"])
  }

  func testDepthZeroDisablesRoute() {
    var router = gyreRouter()
    var p = ParamValues(["gravity": 1, "air": 1, "listen": 0, "drives": 1])
    var s = ModSources()
    s[.micEnvelope] = 1
    _ = router.apply(s, to: &p, specs: specs, dt: dt)
    XCTAssertEqual(p["air"], 1)
  }

  func testAttackReleaseSmoothingAndGateReset() {
    var router = ModulationRouter([
      ModRoute("g", source: .micEnvelope, target: "gravity", gate: ModGate("drives", 0), mode: .add(1), attack: 0.1, release: 1)
    ])
    var s = ModSources()
    s[.micEnvelope] = 1
    var level = 0.0
    for _ in 0..<12 {  // 0.1 s = one attack time constant
      var p = ParamValues(["gravity": 0, "drives": 0])
      level = router.apply(s, to: &p, specs: specs, dt: dt).levels["g"] ?? 0
    }
    XCTAssertEqual(level, 1 - exp(-1), accuracy: 0.01)
    // Gate away and back: the follower restarts from zero.
    var p = ParamValues(["gravity": 0, "drives": 1])
    _ = router.apply(s, to: &p, specs: specs, dt: dt)
    p = ParamValues(["gravity": 0, "drives": 0])
    let restarted = router.apply(s, to: &p, specs: specs, dt: dt).levels["g"] ?? 1
    XCTAssertLessThan(restarted, 0.1)
  }

  func testCurves() {
    XCTAssertEqual(ModCurve.linear.apply(0.3), 0.3)
    XCTAssertEqual(ModCurve.power(0.5).apply(0.25), 0.5, accuracy: 1e-12)
    XCTAssertEqual(ModCurve.smooth.apply(0.5), 0.5, accuracy: 1e-12)
    XCTAssertEqual(ModCurve.exponential(3).apply(1), 1, accuracy: 1e-12)
    XCTAssertEqual(ModCurve.gate(0.2).apply(0.1), 0)
    XCTAssertEqual(ModCurve.gate(0.2).apply(0.6), 0.5, accuracy: 1e-12)
    XCTAssertEqual(ModCurve.invert.apply(0.25), 0.75)
    XCTAssertEqual(ModCurve.normalize(500).apply(250), 0.5)
    XCTAssertEqual(ModCurve.normalize(500).apply(5000), 1)
  }

  /// Rheo's always-on physical routes (labkit-from-gyre.md §6.2).
  func testRheoPhysicalRoutes() {
    var router = ModulationRouter([
      ModRoute("magnet", source: .fieldDelta, target: "magnet", curve: .normalize(500), mode: .add(1)),
      ModRoute("shakeImpulse", source: .jerk, target: "shakeImpulse", curve: .normalize(20), mode: .trigger(threshold: 8)),
      ModRoute("heat", source: .thermal, target: "temperature", depth: 0, mode: .rangeFraction),
    ])
    var p = ParamValues(["temperature": 293])
    var s = ModSources()
    s[.fieldDelta] = 250
    s[.jerk] = 10
    s[.thermal] = 2.0 / 3
    let out = router.apply(s, to: &p, specs: specs, dt: dt)
    XCTAssertEqual(out["magnet"], 0.5, accuracy: 1e-12)
    XCTAssertEqual(out.fired("shakeImpulse")?.strength ?? 0, 0.5, accuracy: 1e-12)
    XCTAssertEqual(p["temperature"], 293, "the thermal route is off by default (depth 0)")
  }

  func testLFOShapes() {
    var sine = LFO(rateHz: 1)
    XCTAssertEqual(sine.step(dt: 0.25), 1, accuracy: 1e-12)
    var tri = LFO(rateHz: 1, shape: .triangle)
    XCTAssertEqual(tri.step(dt: 0.5), 1, accuracy: 1e-12)
    var square = LFO(rateHz: 1, shape: .square)
    XCTAssertEqual(square.step(dt: 0.25), 1)
    XCTAssertEqual(square.step(dt: 0.5), 0)
    var saw = LFO(rateHz: 1, shape: .saw)
    XCTAssertEqual(saw.step(dt: 0.3), 0.3, accuracy: 1e-12)
    var sh = LFO(rateHz: 10, shape: .sampleAndHold)
    var values = Set<Double>()
    for _ in 0..<50 { values.insert(sh.step(dt: 0.02)) }
    XCTAssertGreaterThan(values.count, 3)
    XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
  }

  func testSourceCatalogue() {
    XCTAssertEqual(Set(ModSourceID.all).count, ModSourceID.all.count)
    for id in ["mag.delta", "motion.jerk", "device.thermal", "touch.speed", "touch.down", "touch.x", "touch.y", "touch.force"] {
      XCTAssertTrue(ModSourceID.all.contains(ModSourceID(rawValue: id)), id)
    }
  }
}
