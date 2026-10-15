import XCTest

@testable import LabKitMetro

/// Crown detent maths (spec §10, §15): the relative tracker (Metro Station `CrownDetentTrackerTests`, ported to XCTest
/// with the same expectations), the rate gate and the directional haptic vocabulary.
final class MetroDetentTests: XCTestCase {
  // MARK: Tracker (ported from Metro Station)

  func testTouchDownHasNoJumpAndFractionalTravelIsHeld() {
    var crown = MetroCrownDetentTracker(detentDegrees: 8)
    crown.begin(angleDegrees: 120)
    XCTAssertEqual(crown.update(angleDegrees: 120), 0)
    for jitter in [120.3, 119.8, 120.1, 119.9, 120.0] {
      XCTAssertEqual(crown.update(angleDegrees: jitter), 0)
    }
    XCTAssertEqual(crown.update(angleDegrees: 125), 0)
    XCTAssertEqual(crown.residualDegrees, 5, accuracy: 1e-12)
    XCTAssertEqual(crown.update(angleDegrees: 129), 1)
    XCTAssertEqual(crown.residualDegrees, 1, accuracy: 1e-12)
    XCTAssertEqual(crown.update(angleDegrees: 135), 0)
    XCTAssertEqual(crown.update(angleDegrees: 136), 1)
    XCTAssertEqual(crown.residualDegrees, 0)
  }

  func testReversingDirectionRequiresExtraTravelWithoutBoundaryChatter() {
    var crown = MetroCrownDetentTracker(detentDegrees: 20)
    crown.begin(angleDegrees: 0)
    XCTAssertEqual(crown.update(angleDegrees: 20), 1)
    for jitter in [19.5, 20.5, 19.8, 20.0] {
      XCTAssertEqual(crown.update(angleDegrees: jitter), 0)
    }
    // Twenty degrees back is inside the reversal hysteresis (20 + 3.6).
    XCTAssertEqual(crown.update(angleDegrees: 0), 0)
    XCTAssertEqual(crown.update(angleDegrees: -3.7), -1)
    XCTAssertEqual(crown.lastDirection, -1)
    XCTAssertLessThan(abs(crown.residualDegrees), 0.2)
    XCTAssertEqual(crown.update(angleDegrees: -23.7), -1)
  }

  func testSeamCrossingsKeepDirectionAndFineThreshold() {
    var clockwise = MetroCrownDetentTracker(detentDegrees: 8)
    clockwise.begin(angleDegrees: 179)
    XCTAssertEqual(clockwise.update(angleDegrees: -177), 0)
    XCTAssertEqual(clockwise.update(angleDegrees: -173), 1)
    var counterclockwise = MetroCrownDetentTracker(detentDegrees: 8)
    counterclockwise.begin(angleDegrees: -179)
    XCTAssertEqual(counterclockwise.update(angleDegrees: 177), 0)
    XCTAssertEqual(counterclockwise.update(angleDegrees: 173), -1)
    let spacing = 300.0 / 210
    var rim = MetroCrownDetentTracker(detentDegrees: spacing)
    rim.begin(angleDegrees: 0)
    XCTAssertEqual(rim.update(angleDegrees: spacing * 0.55), 0)
    XCTAssertEqual(rim.update(angleDegrees: spacing), 1)
  }

  func testLargeJumpsCannotQueueFloodsAndResetDiscardsTheOldGesture() {
    var crown = MetroCrownDetentTracker(detentDegrees: 8)
    crown.begin(angleDegrees: 0)
    XCTAssertEqual(crown.update(angleDegrees: 145), 1)
    XCTAssertLessThan(abs(crown.residualDegrees), crown.detentDegrees)
    for _ in 0..<20 { XCTAssertEqual(crown.update(angleDegrees: 145), 0) }
    XCTAssertEqual(crown.update(angleDegrees: .nan), 0)
    XCTAssertEqual(crown.update(angleDegrees: .infinity), 0)
    // One held fractional degree plus seven fresh degrees.
    XCTAssertEqual(crown.update(angleDegrees: 152), 1)
    crown.reset()
    XCTAssertEqual(crown.residualDegrees, 0)
    XCTAssertEqual(crown.lastDirection, 0)
    XCTAssertEqual(crown.update(angleDegrees: -120), 0)
    XCTAssertEqual(crown.update(angleDegrees: -128), -1)
    let invalid = MetroCrownDetentTracker(detentDegrees: .nan, hysteresisDegrees: .infinity)
    XCTAssertEqual(invalid.detentDegrees, 8)
    XCTAssertEqual(invalid.hysteresisDegrees, 1.44, accuracy: 1e-12)
  }

  func testRolesUseTheManifestSpacingAndHysteresis() {
    let fine = MetroCrownDetentTracker(role: .fine)
    XCTAssertEqual(fine.detentDegrees, 8)
    XCTAssertEqual(fine.hysteresisDegrees, 1.44, accuracy: 1e-12)
    let semantic = MetroCrownDetentTracker(role: .semantic)
    XCTAssertEqual(semantic.detentDegrees, 20)
    XCTAssertEqual(semantic.hysteresisDegrees, 3.6, accuracy: 1e-12)
    // Clamps: spacing 0.1…90, hysteresis 0…45 % of the spacing.
    XCTAssertEqual(MetroCrownDetentTracker(detentDegrees: 500).detentDegrees, 90)
    XCTAssertEqual(MetroCrownDetentTracker(detentDegrees: 0).detentDegrees, 0.1)
    XCTAssertEqual(MetroCrownDetentTracker(detentDegrees: 10, hysteresisDegrees: 9).hysteresisDegrees, 4.5)
    XCTAssertEqual(MetroCrownDetentTracker(detentDegrees: 10, hysteresisDegrees: -1).hysteresisDegrees, 0)
  }

  func testOneStepPerUpdateAcrossAFullTurn() {
    var crown = MetroCrownDetentTracker(role: .fine)
    crown.begin(angleDegrees: 0)
    var steps = 0
    // 360° in 2° increments: 45 notches of 8°, each update at most one.
    for index in 1...180 {
      let step = crown.update(angleDegrees: Double(index) * 2)
      XCTAssertTrue((0...1).contains(step))
      steps += step
    }
    XCTAssertEqual(steps, 45)
  }

  func testWrap() {
    XCTAssertEqual(MetroCrownDetentTracker.wrap(190), -170)
    XCTAssertEqual(MetroCrownDetentTracker.wrap(-190), 170)
    XCTAssertEqual(MetroCrownDetentTracker.wrap(720), 0)
    XCTAssertEqual(MetroCrownDetentTracker.wrap(180), 180)
  }

  // MARK: Gate

  func testGateAdmitsAtMostTwentyStepsASecondWithoutABurst() {
    var gate = MetroDetentGate()
    XCTAssertEqual(gate.minimumInterval, 0.05, accuracy: 1e-15)
    gate.begin()
    XCTAssertEqual(gate.update(visualDelta: nil, detent: 1, now: 0, canStep: { _ in true }), 1)
    // Three more notches inside the interval leave one pending notch, not three.
    XCTAssertEqual(gate.update(visualDelta: 8, detent: 1, now: 0.01, canStep: { _ in true }), 0)
    XCTAssertEqual(gate.update(visualDelta: 8, detent: 1, now: 0.02, canStep: { _ in true }), 0)
    XCTAssertEqual(gate.update(visualDelta: 8, detent: 1, now: 0.03, canStep: { _ in true }), 0)
    XCTAssertEqual(gate.pending, 1)
    XCTAssertEqual(gate.update(visualDelta: 0.1, detent: 0, now: 0.049, canStep: { _ in true }), 0)
    XCTAssertEqual(gate.update(visualDelta: 0.1, detent: 0, now: 0.05, canStep: { _ in true }), 1)
    XCTAssertEqual(gate.pending, 0)
    XCTAssertEqual(gate.update(visualDelta: 0.1, detent: 0, now: 0.2, canStep: { _ in true }), 0)
  }

  func testAPendingNotchCannotFireAgainstANewDirection() {
    var gate = MetroDetentGate()
    gate.begin()
    XCTAssertEqual(gate.update(visualDelta: nil, detent: 1, now: 0, canStep: { _ in true }), 1)
    XCTAssertEqual(gate.update(visualDelta: 8, detent: 1, now: 0.01, canStep: { _ in true }), 0)
    XCTAssertEqual(gate.pending, 1)
    // A small wobble back (≤ 0.5°) keeps it; more clears it.
    XCTAssertEqual(gate.update(visualDelta: -0.4, detent: 0, now: 0.02, canStep: { _ in true }), 0)
    XCTAssertEqual(gate.pending, 1)
    XCTAssertEqual(gate.update(visualDelta: -0.6, detent: 0, now: 0.03, canStep: { _ in true }), 0)
    XCTAssertEqual(gate.pending, 0)
    XCTAssertEqual(gate.update(visualDelta: 0, detent: 0, now: 0.2, canStep: { _ in true }), 0)
  }

  func testARefusedStepUsesNoIntervalAndPlaysNothing() {
    var gate = MetroDetentGate()
    gate.begin()
    var asked: [Int] = []
    XCTAssertEqual(gate.update(visualDelta: nil, detent: 1, now: 0, canStep: { asked.append($0); return false }), 0)
    XCTAssertEqual(asked, [1])
    XCTAssertEqual(gate.lastEmission, -.infinity)
    // The next real step is not delayed by the refused one.
    XCTAssertEqual(gate.update(visualDelta: -9, detent: -1, now: 0.001, canStep: { _ in true }), -1)
    gate.clearPending()
    XCTAssertEqual(gate.pending, 0)
    XCTAssertEqual(gate.update(visualDelta: 0, detent: 0, now: .nan, canStep: { _ in true }), 0)
  }

  func testGateRateFallsBackForInvalidInput() {
    XCTAssertEqual(MetroDetentGate(maximumRate: 0).minimumInterval, 0.05)
    XCTAssertEqual(MetroDetentGate(maximumRate: .infinity).minimumInterval, 0.05)
    XCTAssertEqual(MetroDetentGate(maximumRate: 10).minimumInterval, 0.1, accuracy: 1e-15)
  }

  // MARK: Haptic vocabulary

  func testRolesFeelDistinctInEachDirection() {
    XCTAssertEqual(MetroDetentRole.fine.haptic(direction: 1), Metro.HapticDetents.fineUp)
    XCTAssertEqual(MetroDetentRole.fine.haptic(direction: -1), Metro.HapticDetents.fineDown)
    XCTAssertEqual(MetroDetentRole.semantic.haptic(direction: 1), Metro.HapticDetents.semanticUp)
    XCTAssertEqual(MetroDetentRole.semantic.haptic(direction: -1), Metro.HapticDetents.semanticDown)
    let all = Set(MetroDetentRole.allCases.flatMap { [$0.haptic(direction: 1), $0.haptic(direction: -1)] })
    XCTAssertEqual(all.count, 4)
    XCTAssertEqual(MetroDetentRole.fine.detentDegrees, Metro.Motion.fineDetentDegrees)
    XCTAssertEqual(MetroDetentRole.semantic.detentDegrees, Metro.Motion.coarseDetentDegrees)
  }
}
