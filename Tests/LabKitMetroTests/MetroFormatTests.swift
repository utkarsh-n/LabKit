import LabKitCore
import XCTest

@testable import LabKitMetro

/// Formatting contracts (spec §4, contract 6): whole-number quantities render with whole digits and no decimals; other
/// quantities keep the precision their units justify; displayed and spoken values agree.
final class MetroFormatTests: XCTestCase {
  // MARK: Specs used across the bridge tests

  static let heat = ParamSpec(
    "heat", title: "Heat", icon: "flame", range: 0...90, defaultValue: 20, detents: [Detent(45, "Warm")], step: 1,
    hint: "Warms the paste.", format: .number(precision: 1, unit: "°C"))
  static let gravity = ParamSpec(
    "gravity", title: "Gravity", icon: "arrow.down", range: -1...3, defaultValue: 1,
    detents: [Detent(0, "Zero-g"), Detent(0.165, "Moon"), Detent(0.38, "Mars"), Detent(1, "Earth"), Detent(2.53, "Jupiter")],
    hint: "Pulls the paste down.", format: .number(precision: 2, unit: "g"))
  static let gear = ParamSpec(
    "gear", title: "Gear", icon: "gearshape", range: 0...2, defaultValue: 0, step: 1, hint: "Selects a gear.",
    format: .labels(["Low", "Mid", "High"]))
  static let viscosity = ParamSpec(
    "viscosity", title: "Viscosity", icon: "drop", range: 0.001...100, defaultValue: 0.0124, scale: .logarithmic,
    hint: "Thickens the paste.", format: .si(unit: "Pa·s"))

  // MARK: Numbers

  func testWholeDigits() {
    XCTAssertEqual(MetroFormat.whole(120.0), "120")
    XCTAssertEqual(MetroFormat.whole(119.6), "120")
    XCTAssertEqual(MetroFormat.whole(2.5), "3")
    XCTAssertEqual(MetroFormat.whole(-2.5), "\u{2212}3")
    XCTAssertEqual(MetroFormat.whole(-5.0), "\u{2212}5")
    XCTAssertEqual(MetroFormat.whole(-0.4), "0", "never −0")
    XCTAssertEqual(MetroFormat.whole(.nan), "—")
    XCTAssertEqual(MetroFormat.whole(.infinity), "—")
    XCTAssertEqual(MetroFormat.whole(120), "120")
    XCTAssertEqual(MetroFormat.whole(-5), "\u{2212}5")
    XCTAssertEqual(MetroFormat.whole(0), "0")
    XCTAssertFalse(MetroFormat.whole(1_000_000.0).contains("."))
    XCTAssertFalse(MetroFormat.whole(1_000_000.0).contains(","), "locale-independent: no grouping")
  }

  func testFixedPrecisionKeepsLegitimateDecimals() {
    XCTAssertEqual(MetroFormat.fixed(2, precision: 2), "2.00")
    XCTAssertEqual(MetroFormat.fixed(-0.001, precision: 2), "0.00")
    XCTAssertEqual(MetroFormat.fixed(-1.5, precision: 1), "\u{2212}1.5")
    XCTAssertEqual(MetroFormat.fixed(2.6, precision: 0), "3")
    XCTAssertEqual(MetroFormat.fixed(2.6, precision: -3), "3")
  }

  func testIsWhole() {
    XCTAssertTrue(MetroFormat.isWhole(0.1 + 0.2 + 0.7))
    XCTAssertTrue(MetroFormat.isWhole(-4))
    XCTAssertTrue(MetroFormat.isWhole(1e12))
    XCTAssertFalse(MetroFormat.isWhole(1.5))
    XCTAssertFalse(MetroFormat.isWhole(.nan))
    XCTAssertFalse(MetroFormat.isWhole(.infinity))
  }

  func testUnitsJoin() {
    XCTAssertEqual(MetroFormat.join("45", unit: "°"), "45°")
    XCTAssertEqual(MetroFormat.join("46", unit: "%"), "46%")
    XCTAssertEqual(MetroFormat.join("12", unit: "′"), "12′")
    XCTAssertEqual(MetroFormat.join("120", unit: "BPM"), "120 BPM")
    XCTAssertEqual(MetroFormat.join("45", unit: "°C"), "45 °C")
    XCTAssertEqual(MetroFormat.join("45", unit: ""), "45")
    XCTAssertEqual(MetroFormat.quantity(120, unit: "BPM"), "120 BPM")
    XCTAssertEqual(MetroFormat.quantity(-3, unit: "dB"), "\u{2212}3 dB")
    XCTAssertEqual(MetroFormat.quantity(2, precision: 2, unit: "Hz"), "2.00 Hz")
    XCTAssertEqual(MetroFormat.quantity(500, precision: 0, unit: "ms"), "500 ms")
  }

  // MARK: ParamSpec

  func testWholeSteppedParameters() {
    XCTAssertTrue(MetroFormat.isWholeStepped(Self.heat))
    XCTAssertTrue(MetroFormat.isWholeStepped(Self.gear))
    XCTAssertFalse(MetroFormat.isWholeStepped(Self.gravity), "continuous")
    let halves = ParamSpec("h", title: "Halves", icon: "circle", range: 0...10, defaultValue: 0, step: 0.5, hint: "",
      format: .number(precision: 1, unit: "mm"))
    XCTAssertFalse(MetroFormat.isWholeStepped(halves))
    let odd = ParamSpec("o", title: "Odd", icon: "circle", range: 1...9, defaultValue: 1, step: 2, hint: "",
      format: .number(precision: 2, unit: ""))
    XCTAssertTrue(MetroFormat.isWholeStepped(odd))
    let offset = ParamSpec("f", title: "Offset", icon: "circle", range: 0.5...9.5, defaultValue: 0.5, step: 1, hint: "",
      format: .number(precision: 1, unit: ""))
    XCTAssertFalse(MetroFormat.isWholeStepped(offset), "a whole step from a fractional bound reaches fractions")
  }

  func testWholeSteppedNumbersDropDecimalsWhateverTheFormatPrecision() {
    XCTAssertEqual(Self.heat.formatted(45), "45.0 °C", "LabKit's own format keeps its precision")
    XCTAssertEqual(MetroFormat.formatted(Self.heat, 45), "45 °C")
    XCTAssertEqual(MetroFormat.formatted(Self.heat, 0), "0 °C")
    XCTAssertEqual(MetroFormat.formatted(Self.gravity, 1), "1.00 g", "continuous values keep their precision")
    XCTAssertEqual(MetroFormat.formatted(Self.gear, 1), "Mid", "labels are the app's words")
  }

  func testHeroParts() {
    let heat = MetroFormat.heroParts(Self.heat, 45)
    XCTAssertEqual(heat.value, "45")
    XCTAssertEqual(heat.unit, "°C")
    let gravity = MetroFormat.heroParts(Self.gravity, 0.38)
    XCTAssertEqual(gravity.value, "0.38")
    XCTAssertEqual(gravity.unit, "g")
    let gear = MetroFormat.heroParts(Self.gear, 2)
    XCTAssertEqual(gear.value, "High")
    XCTAssertEqual(gear.unit, "")
    let viscosity = MetroFormat.heroParts(Self.viscosity, 0.0124)
    XCTAssertEqual("\(viscosity.value) \(viscosity.unit)", Self.viscosity.formatted(0.0124))
    XCTAssertEqual(viscosity.unit, "mPa·s")
    XCTAssertFalse(viscosity.value.contains(" "))
  }

  func testSpokenAgreesWithDisplayed() {
    XCTAssertEqual(MetroFormat.spoken(Self.heat, 45), "45 degrees Celsius, Warm")
    XCTAssertEqual(MetroFormat.spoken(Self.heat, 46), "46 degrees Celsius")
    XCTAssertFalse(MetroFormat.spoken(Self.heat, 20).contains("."), "spoken precision matches the whole display")
    let earth = MetroFormat.spoken(Self.gravity, 1)
    XCTAssertTrue(earth.hasPrefix("1.00"), earth)
    XCTAssertTrue(earth.hasSuffix(", Earth"), earth)
    XCTAssertEqual(MetroFormat.spoken(Self.gear, 1), "Mid", "a switch reads its label once")
    XCTAssertEqual(MetroFormat.spoken(Self.viscosity, 0.0124), "12.4 millipascal seconds")
  }

  // MARK: Telemetry metrics

  func testMetricsFormatAndSpeak() {
    let interval = MetroMetric("INTERVAL", whole: 500, unit: "ms")
    XCTAssertEqual(interval.value, "500")
    XCTAssertEqual(interval.unit, "ms")
    let rate = MetroMetric("BEAT RATE", value: 2, precision: 2, unit: "Hz")
    XCTAssertEqual(rate.value, "2.00")
    XCTAssertEqual(rate.spokenValue, "2.00 hertz")
    XCTAssertEqual(rate.colour, Metro.Colour.actionCyan)
    let custom = MetroMetric("PHASE", value: "3/4", unit: "", spoken: "beat 3 of 4")
    XCTAssertEqual(custom.spokenValue, "beat 3 of 4")
    XCTAssertEqual(custom.id, "PHASE")
  }
}
