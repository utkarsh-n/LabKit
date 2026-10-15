import Foundation
import LabKitCore
import Observation
import XCTest

@testable import LabKitMetro

/// The ParamSpec / ParamStore bridge (spec §10, §19): fine and semantic roles, detents felt on the way past, limits that
/// write nothing, and the words crowns show and speak.
final class MetroParamBridgeTests: XCTestCase {
  private let heat = MetroFormatTests.heat
  private let gravity = MetroFormatTests.gravity
  private let gear = MetroFormatTests.gear
  private let viscosity = MetroFormatTests.viscosity

  // MARK: Fine

  func testFineMovesOneStepOfASteppedParameter() {
    XCTAssertEqual(MetroParamStepping.fine(heat, from: 20, direction: 1), 21)
    XCTAssertEqual(MetroParamStepping.fine(heat, from: 20, direction: -1), 19)
    XCTAssertEqual(MetroParamStepping.fine(heat, from: 20, direction: 7), 21, "direction is a sign")
    XCTAssertNil(MetroParamStepping.fine(heat, from: 90, direction: 1), "limit: no change, no event")
    XCTAssertNil(MetroParamStepping.fine(heat, from: 0, direction: -1))
    XCTAssertNil(MetroParamStepping.fine(heat, from: 20, direction: 0))
    XCTAssertEqual(MetroParamStepping.fine(heat, from: 200, direction: -1), 89, "an out-of-range value is clamped first")
  }

  func testFineMovesOnePercentOfAContinuousSweepAndStopsOnDetents() throws {
    let up = try XCTUnwrap(MetroParamStepping.fine(gravity, from: 1, direction: 1))
    XCTAssertEqual(up, 1.04, accuracy: 1e-9)
    // 0.36 → 0.40 would jump over Mars (0.38): it lands on it.
    XCTAssertEqual(MetroParamStepping.fine(gravity, from: 0.36, direction: 1), 0.38)
    XCTAssertEqual(MetroParamStepping.fine(gravity, from: 0.40, direction: -1), 0.38)
    // A log parameter moves by a constant ratio.
    let a = try XCTUnwrap(MetroParamStepping.fine(viscosity, from: 0.01, direction: 1))
    let b = try XCTUnwrap(MetroParamStepping.fine(viscosity, from: 1, direction: 1))
    XCTAssertEqual(a / 0.01, b / 1, accuracy: 1e-9)
  }

  func testSwitchesMoveOnePositionInBothRoles() {
    XCTAssertEqual(MetroParamStepping.fine(gear, from: 0, direction: 1), 1)
    XCTAssertEqual(MetroParamStepping.semantic(gear, from: 1, direction: 1), 2)
    XCTAssertNil(MetroParamStepping.semantic(gear, from: 2, direction: 1))
    XCTAssertNil(MetroParamStepping.fine(gear, from: 0, direction: -1))
  }

  // MARK: Semantic

  func testSemanticMovesToTheNextNamedStop() {
    XCTAssertEqual(MetroParamStepping.semantic(gravity, from: 1, direction: 1), 2.53)
    XCTAssertEqual(MetroParamStepping.semantic(gravity, from: 1, direction: -1), 0.38)
    XCTAssertEqual(MetroParamStepping.semantic(gravity, from: 0.5, direction: -1), 0.38)
    XCTAssertEqual(MetroParamStepping.semantic(gravity, from: 0.5, direction: 1), 1)
    XCTAssertEqual(MetroParamStepping.semantic(gravity, from: -1, direction: 1), 0)
    // Past the last stop: a coarse move to the limit, then nothing.
    XCTAssertEqual(MetroParamStepping.semantic(gravity, from: 2.53, direction: 1), 3)
    XCTAssertNil(MetroParamStepping.semantic(gravity, from: 3, direction: 1))
    XCTAssertNil(MetroParamStepping.semantic(gravity, from: -1, direction: -1))
  }

  func testSemanticWithoutNamedStopsMovesCoarsely() {
    XCTAssertEqual(MetroParamStepping.semantic(heat, from: 20, direction: 1), 45, "the Warm stop")
    XCTAssertEqual(MetroParamStepping.semantic(heat, from: 45, direction: 1), 50, "five steps past the last stop")
    XCTAssertEqual(MetroParamStepping.semantic(heat, from: 45, direction: -1), 40)
  }

  func testApplyFineStopsAtLimits() {
    let up = MetroParamStepping.applyFine(heat, from: 88, steps: 5)
    XCTAssertEqual(up.value, 90)
    XCTAssertEqual(up.applied, 2)
    let none = MetroParamStepping.applyFine(heat, from: 90, steps: 3)
    XCTAssertEqual(none.applied, 0)
    let down = MetroParamStepping.applyFine(heat, from: 10, steps: -3)
    XCTAssertEqual(down.value, 7)
    XCTAssertEqual(down.applied, -3)
    XCTAssertEqual(MetroParamStepping.applyFine(heat, from: 10, steps: 0).applied, 0)
  }

  func testRimTravelCrossesTheWholeSweepInOneScale() {
    XCTAssertEqual(MetroParamStepping.fineStepsAcrossSweep(heat), 90)
    XCTAssertEqual(MetroParamStepping.fineStepsAcrossSweep(gravity), 100)
    XCTAssertEqual(MetroParamStepping.fineStepsAcrossSweep(gear), 2)
    XCTAssertEqual(MetroParamStepping.rimDegreesPerStep(heat), 300.0 / 90, accuracy: 1e-12)
    XCTAssertEqual(MetroParamStepping.rimDegreesPerStep(gravity), 3, accuracy: 1e-12)
  }

  func testNeighboursAndBands() {
    XCTAssertEqual(MetroParamStepping.neighbourName(gravity, from: 1, direction: 1), "Jupiter")
    XCTAssertEqual(MetroParamStepping.neighbourName(gravity, from: 1, direction: -1), "Mars")
    XCTAssertNil(MetroParamStepping.neighbourName(gravity, from: 2.53, direction: 1))
    XCTAssertEqual(MetroParamStepping.neighbourName(gear, from: 0, direction: 1), "Mid")
    XCTAssertNil(MetroParamStepping.neighbourName(gear, from: 0, direction: -1))
    XCTAssertEqual(MetroParamStepping.band(gravity, at: 0.5)?.label, "Mars")
    XCTAssertEqual(MetroParamStepping.band(gravity, at: 1)?.label, "Earth")
    XCTAssertNil(MetroParamStepping.band(gravity, at: -0.5))
    XCTAssertTrue(MetroParamStepping.canStep(heat, from: 89, direction: 1, role: .fine))
    XCTAssertFalse(MetroParamStepping.canStep(heat, from: 90, direction: 1, role: .semantic))
  }

  // MARK: ParamStore driver

  @MainActor
  func testTheStoreIsWrittenOncePerAcceptedStepAndNeverAtALimit() {
    let store = ParamStore([heat, gravity])
    XCTAssertEqual(store.metroStep("heat", direction: 1, role: .fine), 21)
    XCTAssertEqual(store["heat"], 21)
    XCTAssertEqual(store.metroStep("gravity", direction: 1, role: .semantic), 2.53)
    XCTAssertEqual(store["gravity"], 2.53)
    store["heat"] = 90
    XCTAssertNil(store.metroStep("heat", direction: 1, role: .fine))
    XCTAssertEqual(store["heat"], 90)
    XCTAssertEqual(store.metroApplyFine("heat", steps: -4), -4)
    XCTAssertEqual(store["heat"], 86)
    XCTAssertEqual(store.metroApplyFine("heat", steps: 0), 0)

    // Observation: one accepted step invalidates readers once; a refused step not at all.
    let changes = ChangeCounter()
    func observe() {
      withObservationTracking { _ = store["heat"] } onChange: { changes.increment() }
    }
    observe()
    store.metroStep("heat", direction: 1, role: .fine)
    XCTAssertEqual(changes.count, 1)
    store["heat"] = 90
    observe()
    store.metroStep("heat", direction: 1, role: .fine)
    store.metroApplyFine("heat", steps: 3)
    XCTAssertEqual(changes.count, 1, "no write at the limit")
  }

  // MARK: Words

  func testFineCrownWords() {
    let words = MetroParamCrownWords(spec: heat, value: 20, role: .fine)
    XCTAssertEqual(words.caption, "FINE")
    XCTAssertEqual(words.footer, .text("±1 °C"))
    XCTAssertEqual(words.increaseLabel, "Increase heat by one fine step")
    XCTAssertEqual(MetroParamCrownWords(spec: gravity, value: 1, role: .fine).footer, .text("±1% SWEEP"))
    XCTAssertEqual(MetroParamCrownWords(spec: gear, value: 1, role: .fine).footer, .text("±1 POSITION"))
  }

  func testSemanticCrownWords() {
    let words = MetroParamCrownWords(spec: gravity, value: 1, role: .semantic)
    XCTAssertEqual(words.caption, "GRAVITY · EARTH")
    XCTAssertEqual(words.footer, .neighbours(previous: "Mars", next: "Jupiter", fallback: "NEXT STOP"))
    XCTAssertEqual(words.increaseLabel, "Select Jupiter")
    XCTAssertEqual(words.decreaseLabel, "Select Mars")
    let top = MetroParamCrownWords(spec: gravity, value: 3, role: .semantic)
    XCTAssertEqual(top.increaseLabel, "Next gravity stop")
    let gearWords = MetroParamCrownWords(spec: gear, value: 1, role: .semantic)
    XCTAssertEqual(gearWords.caption, "GEAR · MID")
    XCTAssertEqual(gearWords.footer, .neighbours(previous: "Low", next: "High", fallback: "NEXT STOP"))
    let plain = ParamSpec(
      "speed", title: "Speed", icon: "hare", range: 0...10, defaultValue: 2, step: 1, hint: "",
      format: .number(precision: 0, unit: "rpm"))
    XCTAssertEqual(MetroParamCrownWords(spec: plain, value: 2, role: .semantic).footer, .text("±5 rpm"))
    XCTAssertEqual(MetroParamCrownWords(spec: viscosity, value: 1, role: .semantic).footer, .text("±¼ SWEEP"))
  }

  func testGaugeLabelsFollowTheScale() {
    let labels = MetroParamGaugeLabels.labels(heat, majors: 8)
    XCTAssertEqual(labels.count, 8)
    XCTAssertEqual(labels.first, "0")
    XCTAssertEqual(labels.last, "90")
    XCTAssertFalse(labels.contains { $0.contains(".") }, "whole-stepped labels have whole digits")
    let log = MetroParamGaugeLabels.labels(viscosity, majors: 3)
    XCTAssertEqual(log.count, 3)
    XCTAssertEqual(MetroParamGaugeLabels.labels(heat, majors: 0).count, 2)
  }

  func testIntegerStepperRule() {
    XCTAssertTrue(MetroStepperLogic.canStep(5, direction: 1, in: 0...10))
    XCTAssertFalse(MetroStepperLogic.canStep(10, direction: 1, in: 0...10))
    XCTAssertFalse(MetroStepperLogic.canStep(0, direction: -1, in: 0...10))
    XCTAssertFalse(MetroStepperLogic.canStep(5, direction: 0, in: 0...10))
  }
}

/// Counts observation callbacks (which arrive synchronously on the writing thread in these tests).
private final class ChangeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func increment() { lock.withLock { value += 1 } }
}
