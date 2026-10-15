import Observation
import XCTest

@testable import LabKitCore

/// ParamSpec mapping, quantisation, detents, nudges and formats; ParamStore registration and clamps
/// (labkit-from-orbitals-spectra.md §3.3, §1.3 #5–#8).
final class ParamTests: XCTestCase {
  let gravity = ParamSpec(
    "gravity", title: "Gravity", icon: "arrow.down.to.line", range: -1...3, defaultValue: 1, origin: 0,
    detents: Gravity.detents, step: 0.01, hint: "Local gravity.", glyph: "g", provenance: .live,
    format: .number(precision: 2, unit: "g"))
  let consistency = ParamSpec(
    "consistency", title: "Consistency", icon: "drop.fill", range: 0.001...1000, defaultValue: 0.0136,
    scale: .logarithmic, detents: [Detent(0.001, "Water"), Detent(1.414, "Glycerol")], hint: "How thick it is.",
    glyph: "K", format: .si(unit: "Pa·sⁿ"))
  let drives = ParamSpec(
    "drives", title: "Drives", icon: "slider.horizontal.3", range: 0...4, defaultValue: 0, step: 1,
    hint: "What sound moves.", format: .labels(["Shake", "Gravity", "Stir", "Kicks", "Heat"]))
  let yield = ParamSpec(
    "yield", title: "Yield", icon: "square.stack.3d.down.forward", range: 0.1...1000, defaultValue: 0.1,
    scale: .logarithmic, detents: [Detent(15, "Ketchup"), Detent(85, "Mayonnaise"), Detent(150, "Toothpaste")],
    hint: "Stress needed before it flows at all.", glyph: "τ_y", glyphSpoken: "tau y",
    format: .off(threshold: 0.1, word: "None", then: .si(unit: "Pa")))

  func testMappingRoundTripsAndQuantises() {
    // 6 decades: 0.001…1000; 1 Pa·sⁿ sits at 3/6 of the sweep.
    XCTAssertEqual(consistency.position(of: 1), 0.5, accuracy: 1e-12)
    XCTAssertEqual(consistency.value(at: 0.5), 1, accuracy: 1e-12)
    XCTAssertEqual(gravity.value(at: 0.5), 1, accuracy: 1e-12)
    XCTAssertEqual(gravity.quantised(0.1666), 0.17, accuracy: 1e-12)
    XCTAssertEqual(gravity.position(of: .nan), 0)
    XCTAssertEqual(gravity.quantised(.infinity), -1)
    XCTAssertEqual(gravity.originPosition, 0.25, accuracy: 1e-12)
    XCTAssertTrue(drives.isSwitch)
    XCTAssertEqual(drives.switchCount, 5)
    XCTAssertFalse(gravity.isSwitch)
  }

  /// §1.3 #6: quantisation is anchored at the lower bound, so 0.25…3 with step 0.1 reaches both ends.
  func testQuantisationAnchorsAtTheLowerBound() {
    let s = ParamSpec("g", title: "G", icon: "dial.medium", range: 0.25...3, defaultValue: 1, step: 0.1, hint: "",
      format: .number(precision: 2, unit: ""))
    XCTAssertEqual(s.value(at: 0), 0.25)
    XCTAssertEqual(s.value(at: 1), 3)
    XCTAssertEqual(s.quantised(0.33), 0.35, accuracy: 1e-12)
    XCTAssertEqual(s.quantised(0.95), 0.95, accuracy: 1e-12)
    // Zero-anchored rounding (the prototype) would give 0.3 here and never land on 0.25.
    XCTAssertEqual(s.quantised(0.27), 0.25, accuracy: 1e-12)
    // No binary noise: 0.25 + 7 × 0.1 formats and compares as 0.95.
    XCTAssertEqual(s.quantised(0.949), 0.95)
  }

  func testDetentsCaptureAndAnnounce() {
    XCTAssertEqual(gravity.capture(near: gravity.position(of: 1) + 0.015)?.label, "Earth")
    XCTAssertNil(gravity.capture(near: gravity.position(of: 1) + 0.03))
    XCTAssertEqual(gravity.detent(at: 0.166)?.label, "Moon")
    XCTAssertEqual(gravity.accessibilityValue(1), "1.00 g, Earth")
    XCTAssertEqual(gravity.accessibilityValue(-0.5), "minus 0.50 g")
    XCTAssertEqual(drives.accessibilityValue(2), "Stir")
    XCTAssertEqual(consistency.accessibilityValue(0.0136), "13.6 millipascal seconds to the n")
    XCTAssertEqual(yield.accessibilityValue(0.1), "None")
    XCTAssertEqual(yield.accessibilityValue(15), "15.0 pascals, Ketchup")
    XCTAssertEqual(yield.accessibilityLabel, "Yield, tau y")
    XCTAssertEqual(gravity.accessibilityLabel, "Gravity")
  }

  /// §3.5: a switch needs `.labels`. Rheo's Heat (0–90 °C) and Magnet (0–500 mT) step by 1 but are
  /// knobs with detents: they capture "Room" and "1 cm away", nudge by the §3.3 table and read their detent.
  func testWholeNumberKnobsWithUnitsAreNotSwitches() {
    let heat = ParamSpec("heat", title: "Heat", icon: "thermometer.medium", range: 0...90, defaultValue: 20,
      detents: [Detent(4, "Fridge"), Detent(20, "Room"), Detent(37, "Body")], step: 1, hint: "", glyph: "T",
      format: .number(precision: 0, unit: "°C"))
    let magnet = ParamSpec("magnet", title: "Magnet", icon: "dot.radiowaves.left.and.right", range: 0...500,
      defaultValue: 0, detents: [Detent(0, "Off"), Detent(207, "1 cm away")], step: 1, hint: "", glyph: "B",
      format: .off(threshold: 0, word: "Off", then: .number(precision: 0, unit: "mT")))
    XCTAssertFalse(heat.isSwitch)
    XCTAssertFalse(magnet.isSwitch)
    XCTAssertEqual(heat.switchCount, 0)
    XCTAssertEqual(heat.accessibilityValue(20), "20 degrees Celsius, Room")
    XCTAssertEqual(heat.nudged(19, by: 1), 20)  // ≤ 100 steps: one step
    XCTAssertEqual(heat.nudged(30, by: 1, coarse: true), 35)
    XCTAssertEqual(heat.nudged(34, by: 1, coarse: true), 37)  // stops on Body
    XCTAssertEqual(magnet.nudged(200, by: 1), 207)  // 500 steps: 1/20 of the sweep, stopping on the detent
    XCTAssertEqual(magnet.nudged(300, by: 1), 325)
    XCTAssertEqual(magnet.capture(near: magnet.position(of: 205))?.label, "1 cm away")
    XCTAssertEqual(magnet.accessibilityValue(0), "Off")
  }

  func testNudgesStepStopAtDetentsAndSwitch() {
    // Gravity: 400 steps > 100, so a nudge is 1/20 of the sweep (0.2 g) but stops on a crossed detent.
    XCTAssertEqual(gravity.nudged(0.5, by: 1), 0.7, accuracy: 1e-12)
    XCTAssertEqual(gravity.nudged(0.9, by: 1), 1, accuracy: 1e-12)  // would reach 1.1; stops at Earth
    XCTAssertEqual(gravity.nudged(0, by: 1), 0.166, accuracy: 1e-12)  // Zero-g → Moon
    XCTAssertEqual(gravity.nudged(3, by: 1), 3)  // at the limit: unchanged (the knob plays .boundary)
    XCTAssertEqual(gravity.nudged(1.2, by: -1, coarse: true), 1, accuracy: 1e-12)  // coarse still stops at Earth
    XCTAssertEqual(drives.nudged(4, by: 1), 4)
    XCTAssertEqual(drives.nudged(1, by: 1), 2)
    XCTAssertEqual(drives.nudged(0, by: 1, coarse: true), 4)
    // Log knob: 1/20 of 6 decades = ×10^0.3 per nudge…
    XCTAssertEqual(consistency.nudged(2, by: 1), 2 * pow(10, 0.3), accuracy: 1e-9)
    // …unless it would cross the Glycerol detent (1.414), where it stops.
    XCTAssertEqual(consistency.nudged(1, by: 1), 1.414, accuracy: 1e-12)
    // ≤ 100 steps: one step per nudge.
    let index = ParamSpec("index", title: "Flow index", icon: "chart.line.downtrend.xyaxis", range: 0.2...1,
      defaultValue: 1, step: 0.01, hint: "", format: .number(precision: 2, unit: ""))
    XCTAssertEqual(index.nudged(0.5, by: 1), 0.51, accuracy: 1e-12)
    XCTAssertEqual(index.nudged(0.5, by: -1, coarse: true), 0.45, accuracy: 1e-12)
  }

  func testFormats() {
    XCTAssertEqual(ParamFormat.si(unit: "Pa·s").string(0.0124), "12.4 mPa·s")
    XCTAssertEqual(ParamFormat.multiplier(precision: 2).string(0.25), "×0.25")
    XCTAssertEqual(ParamFormat.percent.string(0.456), "46%")
    XCTAssertEqual(ParamFormat.off(threshold: 0.005, word: "Off", then: .percent).string(0), "Off")
    XCTAssertEqual(ParamFormat.off(threshold: 0.005, word: "Off", then: .percent).string(0.5), "50%")
    XCTAssertEqual(ParamFormat.labels(["Gravity", "Air", "Spin", "Kicks", "Film"]).string(2.4), "Spin")
    XCTAssertEqual(ParamFormat.labels(["Gravity", "Air", "Spin", "Kicks", "Film"]).string(9), "Film")
    XCTAssertEqual(ParamFormat.number(precision: 0, unit: "°C").string(20), "20 °C")
    XCTAssertEqual(ParamFormat.number(precision: 2, unit: "g").string(-0.001), "0.00 g")
    XCTAssertEqual(ParamFormat.custom { "\(Int($0))!" }.string(3), "3!")
    XCTAssertEqual(ParamFormat.multiplier(precision: 2).spoken(0.25), "times 0.25")
    XCTAssertEqual(ParamFormat.percent.spoken(0.46), "46 percent")
  }

  func testSpecInitClampsDefaultAndStep() {
    let s = ParamSpec("x", title: "X", icon: "circle", range: 0...1, defaultValue: 2, step: -1, hint: "",
      format: .percent)
    XCTAssertEqual(s.defaultValue, 1)
    XCTAssertEqual(s.step, 0)
    XCTAssertEqual(s.clamp(.nan), 1)
    // A NaN default or an infinite step must not leak NaN into clamp/quantise (or trap in Int(_:)).
    let odd = ParamSpec("y", title: "Y", icon: "circle", range: 0...1, defaultValue: .nan, step: .infinity, hint: "",
      format: .percent)
    XCTAssertEqual(odd.defaultValue, 0)
    XCTAssertEqual(odd.step, 0)
    XCTAssertEqual(odd.clamp(.nan), 0)
    XCTAssertEqual(odd.quantised(0.4), 0.4)
  }

  /// A modulated snapshot can carry NaN; reading a switch from it must fall back, not trap.
  func testNonFiniteValuesDoNotTrap() {
    XCTAssertEqual(ParamValues(["drives": .nan]).choice("drives", as: Drive.self, default: .gravity), .gravity)
    XCTAssertEqual(ParamValues(["drives": 1e300]).choice("drives", as: Drive.self, default: .gravity), .gravity)
    XCTAssertEqual(ParamValues(["drives": 2.4]).choice("drives", as: Drive.self, default: .gravity), .stir)
    XCTAssertEqual(LabColor(.nan, 1, 0.5).hex, "#00FF80")
  }

  @MainActor func testStoreClampsAndSnapshots() {
    let store = ParamStore([gravity, drives])
    store["gravity"] = 9
    XCTAssertEqual(store.snapshot()["gravity"], 3)
    store["gravity"] = .nan
    XCTAssertEqual(store["gravity"], 3, "non-finite writes are ignored")
    XCTAssertFalse(store.isDefault("gravity"))
    store.reset(["gravity"])
    XCTAssertTrue(store.isDefault("gravity"))
    XCTAssertEqual(store.order, ["gravity", "drives"])
    store.apply(["drives": 3, "gravity": 0.166])
    XCTAssertTrue(store.matches(["drives": 3, "gravity": 0.166]))
    XCTAssertFalse(store.matches(["drives": 2]))
    XCTAssertEqual(store.snapshot().choice("drives", as: Drive.self, default: .shake), .kicks)
    store.resetAll()
    XCTAssertEqual(store["drives"], 0)
  }

  /// §1.3 #8: re-registering a spec clamps the stored value into the new range (Rheo swaps Heat for lava).
  @MainActor func testReRegistrationClampsIntoTheNewRange() {
    let kitchen = ParamSpec("heat", title: "Heat", icon: "thermometer.medium", range: 0...90, defaultValue: 20,
      step: 1, hint: "", glyph: "T", format: .number(precision: 0, unit: "°C"))
    let lava = ParamSpec("heat", title: "Heat", icon: "flame.fill", range: 1050...1200, defaultValue: 1100,
      step: 1, hint: "", glyph: "T", format: .number(precision: 0, unit: "°C"))
    let store = ParamStore([kitchen])
    store["heat"] = 37
    store.register([lava])
    XCTAssertEqual(store["heat"], 1050)
    XCTAssertEqual(store.spec("heat").icon, "flame.fill")
    XCTAssertEqual(store.order, ["heat"], "re-registering does not duplicate the order")
    store.register([kitchen])
    XCTAssertEqual(store["heat"], 90)
    store.register([lava], adoptDefaults: true)
    XCTAssertEqual(store["heat"], 1100)
  }

  /// Observation is per parameter: a view reading Gravity is not invalidated when Drives turns, so
  /// turning one knob redraws that knob, not the whole console and top bar.
  @MainActor func testObservationIsPerParameter() {
    final class Flag: @unchecked Sendable { var fired = false }
    let store = ParamStore([gravity, drives])
    func watching(_ id: ParamID, while change: () -> Void) -> Bool {
      let flag = Flag()
      withObservationTracking { _ = store[id] } onChange: { flag.fired = true }
      change()
      return flag.fired
    }
    XCTAssertFalse(watching("gravity") { store["drives"] = 3 }, "another knob's write")
    XCTAssertFalse(watching("gravity") { store["gravity"] = store["gravity"] }, "an unchanged value")
    XCTAssertTrue(watching("gravity") { store["gravity"] = 0.5 })
    XCTAssertTrue(watching("gravity") { store.reset(["gravity"]) })
    XCTAssertTrue(watching("gravity") { store.apply(["gravity": 2]) })
    XCTAssertFalse(watching("gravity") { store.reset(["drives"]) })
    // A reader of an id registered later is told when it appears.
    XCTAssertTrue(watching("yield") { store.register([yield]) })
    XCTAssertEqual(store.snapshot().storage.count, 3)
    // A partial snapshot reads (and observes) only the ids asked for.
    XCTAssertEqual(store.snapshot(["gravity", "unknown"]).storage, ["gravity": store["gravity"]])
    let flag = Flag()
    withObservationTracking { _ = store.snapshot(["gravity"]) } onChange: { flag.fired = true }
    store["drives"] = 1
    XCTAssertFalse(flag.fired)
  }

  /// §1.3 #14: pages are data and one focus value names the held or long-pressed knob.
  func testConsolePagesAndKnobFocus() {
    let fluid = ConsolePage("fluid", title: "Fluid", knobs: ["yield", "consistency", "index", "packing"])
    XCTAssertEqual(fluid.knobs.count, 4)
    XCTAssertEqual(ConsolePage("view", title: "View").knobs, [])
    XCTAssertNil(KnobFocus.none.id)
    XCTAssertEqual(KnobFocus.held("yield").id, "yield")
    XCTAssertEqual(KnobFocus.precision("gain").id, "gain")
    XCTAssertNotEqual(KnobFocus.held("gain"), .precision("gain"), "a readout and a tray never show at once")
  }

  enum Drive: Int { case shake, gravity, stir, kicks, heat }
}
