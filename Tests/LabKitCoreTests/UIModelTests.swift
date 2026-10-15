import XCTest

@testable import LabKitCore

/// Value types behind LabKitUI: formats and spoken forms, plot axes, experiments, provenance,
/// the life-size table and copy lint.
final class FormatTests: XCTestCase {
  func testFixedSig3ScientificEngineering() {
    XCTAssertEqual(LabFormat.fixed(-0.001, precision: 2), "0.00")
    XCTAssertEqual(LabFormat.fixed(-1.5, precision: 1), "\u{2212}1.5")
    XCTAssertEqual(LabFormat.fixed(.nan, precision: 1), "—")
    XCTAssertEqual(LabFormat.fixed(1.23456789, precision: 9), "1.234568")
    XCTAssertEqual(LabFormat.sig3(123.4), "123")
    XCTAssertEqual(LabFormat.sig3(12.34), "12.3")
    XCTAssertEqual(LabFormat.sig3(1.234), "1.23")
    XCTAssertEqual(LabFormat.sig3(0.01234), "0.0123")
    XCTAssertEqual(LabFormat.sig3(9.999), "10.0")
    XCTAssertEqual(LabFormat.scientific(0.000123, unit: "s"), "1.23×10⁻⁴ s")
    XCTAssertEqual(LabFormat.scientific(9.999e-5, unit: ""), "1.00×10⁻⁴")
    XCTAssertEqual(LabFormat.engineering(0.0124, unit: "Pa·s"), "12.4 mPa·s")
    XCTAssertEqual(LabFormat.engineering(2.45e9, unit: "Hz"), "2.45 GHz")
    XCTAssertEqual(LabFormat.engineering(300, unit: "Hz"), "300 Hz")
    XCTAssertEqual(LabFormat.engineering(1414, unit: "Pa"), "1.41 kPa")
    XCTAssertEqual(LabFormat.engineering(-0.5, unit: "s"), "\u{2212}500 ms")
    XCTAssertEqual(LabFormat.engineering(1e-20, unit: "m"), "1.00×10⁻²⁰ m")
    XCTAssertEqual(LabFormat.powerOfTen(-3), "10⁻³")
  }

  /// A prefix binds to the unit with its exponent: "320 ms⁻¹" would mean 320 per millisecond, a
  /// million times 0.32 s⁻¹. Reciprocal units therefore take no prefix (Rheo's shear-rate readouts).
  func testEngineeringNeverPrefixesAReciprocalUnit() {
    XCTAssertEqual(LabFormat.engineering(0.32, unit: "s⁻¹"), "0.320 s⁻¹")
    XCTAssertEqual(LabFormat.engineering(3.2, unit: "s⁻¹"), "3.20 s⁻¹")
    XCTAssertEqual(LabFormat.engineering(1200, unit: "s⁻¹"), "1200 s⁻¹")
    XCTAssertEqual(LabFormat.engineering(-0.05, unit: "s⁻¹"), "\u{2212}0.0500 s⁻¹")
    XCTAssertEqual(LabFormat.engineering(3.2e-5, unit: "s⁻¹"), "3.20×10⁻⁵ s⁻¹")
    XCTAssertEqual(LabFormat.engineering(2e7, unit: "s⁻¹"), "2.00×10⁷ s⁻¹")
    XCTAssertEqual(LabFormat.spoken(LabFormat.engineering(0.32, unit: "s⁻¹")), "0.320 per second")
    // Prefixes still bind to an ordinary first factor.
    XCTAssertEqual(LabFormat.engineering(0.0136, unit: "Pa·sⁿ"), "13.6 mPa·sⁿ")
    XCTAssertEqual(ParamFormat.si(unit: "s⁻¹").string(0.5), "0.500 s⁻¹")
  }

  func testSpokenForms() {
    XCTAssertEqual(LabFormat.spoken("3.20 s⁻¹"), "3.20 per second")
    XCTAssertEqual(LabFormat.spoken("12.4 Pa·s"), "12.4 pascal seconds")
    XCTAssertEqual(LabFormat.spoken("12.4 mPa·s"), "12.4 millipascal seconds")
    XCTAssertEqual(LabFormat.spoken("1.23×10⁻⁴ s"), "1.23 times 10 to the minus 4 seconds")
    XCTAssertEqual(LabFormat.spoken("×0.25"), "times 0.25")
    XCTAssertEqual(LabFormat.spoken("×100"), "times 100")
    XCTAssertEqual(LabFormat.spoken("20 °C"), "20 degrees Celsius")
    XCTAssertEqual(LabFormat.spoken("\u{2212}0.50 g"), "minus 0.50 g")
    XCTAssertEqual(LabFormat.spoken("46%"), "46 percent")
    XCTAssertEqual(LabFormat.spoken("207 mT"), "207 millitesla")
    XCTAssertEqual(LabFormat.spoken("48 µT"), "48 microtesla")
    XCTAssertEqual(LabFormat.spoken("2.5 rev/s"), "2.5 revolutions per second")
    XCTAssertEqual(LabFormat.spoken("8.0 mm"), "8.0 millimetres")
    XCTAssertEqual(LabFormat.spoken("1.41 kPa"), "1.41 kilopascals")
    XCTAssertEqual(LabFormat.spoken("Off"), "Off")
  }

  /// Uppercasing turns η into Η and µ into Μ; LabKit uppercases Latin letters only.
  func testUppercasedLatinKeepsSymbols() {
    XCTAssertEqual(LabFormat.uppercasedLatin("η viscosity"), "η VISCOSITY")
    XCTAssertEqual(LabFormat.uppercasedLatin("λ wavelength in µm"), "λ WAVELENGTH IN µM")
    XCTAssertEqual(LabFormat.uppercasedLatin("Thin tank · oobleck"), "THIN TANK · OOBLECK")
    XCTAssertEqual(LabFormat.uppercasedLatin("γ̇ shear rate"), "γ̇ SHEAR RATE")
  }
}

final class PlotAxisTests: XCTestCase {
  func testRheometerLogAxisTicks() {
    let shear = PlotAxis(title: "Shear rate", symbol: "γ̇", unit: "s⁻¹", domain: 1e-3...1e3, scale: .log10)
    // ~300 pt for 6 decades = 50 pt per decade: a major every decade, no minors.
    let t300 = shear.ticks(length: 300)
    XCTAssertEqual(t300.filter(\.isMajor).map(\.label), ["10⁻³", "0.01", "0.1", "1", "10", "100", "1000"])
    XCTAssertTrue(t300.allSatisfy(\.isMajor))
    // 600 pt = 100 pt per decade → minors at 2…9 × 10ᵏ.
    XCTAssertEqual(shear.ticks(length: 600).filter { !$0.isMajor }.count, 6 * 8)
    // 120 pt → every second decade labelled; every decade keeps its major tick (§3.12).
    let t120 = shear.ticks(length: 120)
    XCTAssertEqual(t120.compactMap(\.label), ["10⁻³", "0.1", "10", "1000"])
    XCTAssertEqual(t120.filter(\.isMajor).count, 7)
    XCTAssertTrue(t120.filter { !$0.isMajor }.isEmpty)
    XCTAssertEqual(shear.position(1)!, 0.5, accuracy: 1e-12)
    XCTAssertNil(shear.position(0))
    XCTAssertNil(shear.position(.nan))
    XCTAssertEqual(shear.value(at: 0.5), 1, accuracy: 1e-12)
    XCTAssertEqual(shear.decades, 6, accuracy: 1e-12)
    XCTAssertEqual(shear.caption(), "γ̇ (s⁻¹)")
    XCTAssertEqual(shear.caption(long: true), "Shear rate γ̇ (s⁻¹)")
    XCTAssertEqual(PlotAxis.decadeLabel(4), "10⁴")
  }

  /// The strip plot of §9.6: 0.01…1000 s⁻¹ in about 167 pt labels every second decade at minSpacing 36.
  func testStripPlotLabelsEverySecondDecade() {
    let x = PlotAxis(title: "Shear rate", symbol: "γ̇", unit: "s⁻¹", domain: 0.01...1000, scale: .log10)
    XCTAssertEqual(x.ticks(length: 167, minSpacing: 36).compactMap(\.label), ["0.01", "1", "100"])
  }

  /// A log axis narrower than a decade has no decade to label; it labels 1-2-5 values, else its ends.
  func testSubDecadeLogAxisStillHasLabels() {
    let a = PlotAxis(title: "f", domain: 2...8, scale: .log10)
    XCTAssertEqual(a.ticks(length: 300).compactMap(\.label), ["2", "5"])
    let b = PlotAxis(title: "f", domain: 2.1...2.9, scale: .log10)
    XCTAssertEqual(b.ticks(length: 300).compactMap(\.label), ["2.1", "2.9"])
    let c = PlotAxis(title: "f", domain: 20_000...90_000, scale: .log10)
    XCTAssertEqual(c.ticks(length: 300).compactMap(\.label), ["2×10⁴", "5×10⁴"])
  }

  func testLinearTicksUseOneTwoFive() {
    let t = PlotAxis(title: "Temperature", unit: "°C", domain: 0...90).ticks(length: 300)
    XCTAssertEqual(t.map(\.label), ["0", "20", "40", "60", "80"])
    let small = PlotAxis(title: "x", domain: -0.5...0.5).ticks(length: 200, minSpacing: 40)
    XCTAssertEqual(small.map(\.label), ["\u{2212}0.4", "\u{2212}0.2", "0.0", "0.2", "0.4"])
  }

  func testSeriesBreaksAtGapsAndSamples() {
    let x = PlotAxis(title: "x", domain: 0.1...10, scale: .log10)
    let y = PlotAxis(title: "y", domain: 0.1...10, scale: .log10)
    let s = PlotSeries(
      id: "a", label: "a", colour: .white,
      points: [SIMD2(0.1, 1), SIMD2(1, 1), SIMD2(2, .nan), SIMD2(3, 2), SIMD2(5, 0)],
      provenance: .modelled)
    XCTAssertEqual(s.runs(x: x, y: y).map(\.count), [2, 1])
    let line = PlotSeries.sampled(id: "n", label: "Newtonian", colour: .white, x: x, count: 5) { 2 * $0 }
    XCTAssertEqual(line.points.count, 5)
    XCTAssertEqual(line.points[2].x, 1, accuracy: 1e-12)
    XCTAssertEqual(line.points[4].y, 20, accuracy: 1e-9)
  }

  func testGuides() {
    let x = PlotAxis(title: "γ̇", domain: 0.01...1000, scale: .log10)
    let y = PlotAxis(title: "σ", domain: 0.01...10_000, scale: .log10)
    let iso = PlotGuide.powerLaw(prefactor: 1, exponent: 1, label: "1 Pa·s").polyline(x: x, y: y, samples: 10)
    XCTAssertEqual(iso.count, 11)
    // σ = γ̇: starts at (0.01, 0.01), i.e. the bottom-left corner.
    XCTAssertEqual(iso[0].x, 0, accuracy: 1e-12)
    XCTAssertEqual(iso[0].y, 0, accuracy: 1e-12)
    XCTAssertEqual(PlotGuide.horizontal(y: 15, label: "τ_y").polyline(x: x, y: y).count, 2)
    XCTAssertEqual(PlotGuide.vertical(x: -1, label: "bad").polyline(x: x, y: y).count, 0)
    XCTAssertEqual(PlotGuide.horizontal(y: 15, label: "τ_y").label, "τ_y")
  }
}

final class ExperimentTests: XCTestCase {
  let punch = Experiment(
    "punch", title: "Oobleck punch", subtitle: "Hit it hard and it holds", icon: "hand.raised.fill",
    note: "Punch fast: the grains jam into a solid. Stop, and it flows again.",
    values: ["packing": 0.517, "gravity": 1], material: "oobleck", effects: [.refillsTank, .restartsClock])
  let moon = Experiment(
    "moon", title: "Mayonnaise on the Moon", subtitle: "One-sixth gravity, 85 Pa yield", icon: "moon.fill",
    note: "", values: ["gravity": 0.166], material: "mayonnaise", effects: [.refillsTank, .restartsClock, .resumesPlay])

  func testEffectsSentence() {
    let e: ExperimentEffects = [.refillsTank, .restartsClock, .resumesPlay]
    XCTAssertEqual(e.sentence, "Each experiment refills the tank, restarts the clock and starts playing.")
    XCTAssertEqual(ExperimentEffects.refillsTank.sentence, "Each experiment refills the tank.")
    XCTAssertEqual(ExperimentEffects().sentence, "")
    XCTAssertEqual(
      Experiment.commonEffects([punch, moon]).menuHeader, "Experiments · each refills the tank and restarts the clock.")
    XCTAssertEqual(ExperimentEffects().menuHeader, "Experiments")
  }

  /// Identity is derived: editing any knob the experiment sets reverts the match.
  func testDerivedIdentity() {
    var values = ParamValues(["packing": 0.517, "gravity": 1, "heat": 20])
    XCTAssertEqual(Experiment.matching(values, material: "oobleck", in: [moon, punch])?.id, "punch")
    XCTAssertNil(Experiment.matching(values, material: "ketchup", in: [moon, punch]))
    values["packing"] = 0.52
    XCTAssertNil(Experiment.matching(values, material: "oobleck", in: [moon, punch]))
    XCTAssertEqual(punch.announcement, "Oobleck punch. Punch fast: the grains jam into a solid. Stop, and it flows again.")
    XCTAssertEqual(moon.announcement, "Mayonnaise on the Moon")
  }

  func testProvenanceWordsAndCitations() {
    XCTAssertEqual(Provenance.allCases.map(\.badge), ["measured", "modelled", "live", "simulated", "illustrative"])
    XCTAssertEqual(Provenance.modelled.tint, LabSemantic.value)
    XCTAssertEqual(Provenance.measured.tint, LabSemantic.live)
    XCTAssertEqual(Provenance.illustrative.tint(on: .phosphor), LabGround.phosphor.muted)
    for p in Provenance.allCases { XCTAssertTrue(p.explanation.hasSuffix(".")) }
    let c = Citation(
      "Box2D v3.1.1", publisher: "Erin Catto", url: URL(string: "https://github.com/erincatto/box2d")!, kind: .code,
      licence: "MIT", checked: "2026-10-03")
    XCTAssertEqual(c.label, "Erin Catto · Box2D v3.1.1")
  }
}

final class DisplayAndCopyTests: XCTestCase {
  func testMillimetresPerPoint() {
    XCTAssertEqual(LabDisplay.millimetresPerPoint(modelIdentifier: "iPhone16,2")!, 0.16565, accuracy: 0.00001)
    XCTAssertEqual(LabDisplay.millimetresPerPoint(modelIdentifier: "iPhone14,4")!, 25.4 * 2.88 / 476, accuracy: 1e-9)
    XCTAssertEqual(LabDisplay.millimetresPerPoint(modelIdentifier: "iPhone12,8")!, 0.15583, accuracy: 0.00001)
    XCTAssertNil(LabDisplay.millimetresPerPoint(modelIdentifier: "arm64"))
    XCTAssertNil(LabDisplay.millimetresPerPoint(modelIdentifier: "iPhone99,9"))
    // The life-size tank of §9.2: 430 × 612.3 pt on the 15 Pro Max is 71.2 × 101.4 mm.
    let mm = LabDisplay.millimetresPerPoint(modelIdentifier: LabDisplay.referenceModel)!
    XCTAssertEqual(430 * mm, 71.2, accuracy: 0.05)
    XCTAssertEqual(612.3 * mm, 101.4, accuracy: 0.05)
    XCTAssertFalse(LabDisplay.currentModelIdentifier.isEmpty)
  }

  func testCopyLint() {
    XCTAssertEqual(CopyLint.americanSpellings(in: "The color of the center is gray."), ["color", "center", "gray"])
    XCTAssertEqual(CopyLint.americanSpellings(in: "The colour of the centre; a level meter."), [])
    XCTAssertEqual(
      CopyLint.unknownUINames(in: "Turn up Listen on the Sound page, then the Signals page.", known: ["Signals", "Listen"]),
      ["Sound"])
  }
}
