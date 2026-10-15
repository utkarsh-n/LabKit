import CoreGraphics
import Foundation
import XCTest

@testable import LabKitMetro

/// The gauge cluster calculation and fixed readout coordinates (spec §5, §8), and incremental rim scrubbing.
final class MetroGeometryTests: XCTestCase {
  func testClusterOnA430PointPhoneGivesThe322PointDial() {
    // 430 pt screen − 2 × 12 pt screen inset.
    let layout = MetroClusterLayout(availableWidth: 430 - 2 * Metro.Spacing.screenInset)
    XCTAssertEqual(layout.pillWidth, 36)
    XCTAssertEqual(layout.diameter, 322)
    XCTAssertEqual(layout.pillHeight, 0.66 * 322, accuracy: 1e-9)
    XCTAssertEqual(layout.width, 406)
  }

  func testClusterBreakpointsAndCaps() {
    let compact = MetroClusterLayout(availableWidth: 340)
    XCTAssertEqual(compact.pillWidth, 30)
    XCTAssertEqual(compact.diameter, 340 - 60 - 12)
    let wide = MetroClusterLayout(availableWidth: 1000)
    XCTAssertEqual(wide.pillWidth, 36)
    XCTAssertEqual(wide.diameter, 360, "gauge max")
    XCTAssertEqual(wide.pillHeight, 218, "pill height max")
    XCTAssertEqual(MetroClusterLayout(availableWidth: 350).pillWidth, 36)
    XCTAssertEqual(MetroClusterLayout(availableWidth: 349.9).pillWidth, 30)
    XCTAssertEqual(MetroClusterLayout(availableWidth: 0).diameter, 1)
    XCTAssertEqual(MetroClusterLayout(availableWidth: .nan).diameter, 1)
  }

  func testReadoutCoordinatesAreFixedFractionsOfTheDiameter() {
    let layout = MetroReadoutLayout(diameter: 322)
    XCTAssertEqual(layout.centreX, 161)
    XCTAssertEqual(layout.valueY, 322 * 0.52, accuracy: 1e-9)
    XCTAssertEqual(layout.unitsY, 322 * 0.665, accuracy: 1e-9)
    XCTAssertEqual(layout.meaningY, 322 * 0.745, accuracy: 1e-9)
    XCTAssertEqual(layout.phaseY, 322 * 0.835, accuracy: 1e-9)
    XCTAssertEqual(layout.readoutWidth, 322 * 0.64, accuracy: 1e-9)
    XCTAssertEqual(layout.valueFontSize, 322 * 0.23, accuracy: 1e-9)
    XCTAssertTrue(layout.showsSupplementaryLines)
    let large = MetroReadoutLayout(diameter: 322, accessibilitySize: true)
    XCTAssertEqual(large.meaningY, 322 * 0.79, accuracy: 1e-9)
    XCTAssertFalse(large.showsSupplementaryLines)
    XCTAssertEqual(large.valueY, layout.valueY, "the value never moves")
    XCTAssertEqual(MetroReadoutLayout(diameter: .infinity).diameter, 1)
  }

  // MARK: Rim scrub

  private let d: CGFloat = 322

  private func rim(_ degrees: Double, radius: Double = 0.4) -> CGPoint {
    let r = Double(d) * radius
    return CGPoint(x: Double(d) / 2 + r * cos(degrees * .pi / 180), y: Double(d) / 2 + r * sin(degrees * .pi / 180))
  }

  func testOnlyTouchesBeginningOutsideThirtyPercentScrub() {
    XCTAssertFalse(MetroRimScrub.beginsOnRim(CGPoint(x: 161, y: 161), diameter: d))
    XCTAssertFalse(MetroRimScrub.beginsOnRim(rim(40, radius: 0.29), diameter: d))
    XCTAssertTrue(MetroRimScrub.beginsOnRim(rim(40, radius: 0.31), diameter: d))
    XCTAssertFalse(MetroRimScrub.beginsOnRim(CGPoint(x: CGFloat.nan, y: 0), diameter: d))
    XCTAssertFalse(MetroRimScrub.beginsOnRim(rim(0), diameter: 0))
  }

  func testScrubbingIsIncrementalAndSchmittQuantised() {
    var scrub = MetroRimScrub(degreesPerStep: 10)
    var total = 0
    let accept: (Int) -> Int = { change in
      total += change
      return change
    }
    // The first touch never maps to an absolute value.
    scrub.begin(at: rim(37), diameter: d)
    XCTAssertEqual(scrub.update(at: rim(37), diameter: d, accept: accept), 0)
    XCTAssertEqual(scrub.update(at: rim(43), diameter: d, accept: accept), 0, "0.6 of a step")
    XCTAssertEqual(scrub.update(at: rim(44), diameter: d, accept: accept), 1, "0.7 of a step")
    // Tremor around the half step cannot flip it back: reversal needs a real 0.30 band.
    XCTAssertEqual(scrub.update(at: rim(41.5), diameter: d, accept: accept), 0)
    XCTAssertEqual(scrub.update(at: rim(43), diameter: d, accept: accept), 0)
    XCTAssertEqual(scrub.update(at: rim(41), diameter: d, accept: accept), 0, "0.4 of a step: inside the band")
    XCTAssertEqual(scrub.update(at: rim(40), diameter: d, accept: accept), -1, "0.3 of a step: through the band")
    XCTAssertEqual(total, 0)
    scrub.end()
    XCTAssertFalse(scrub.isActive)
  }

  func testScrubCrossesTheSeamAndNeverJumpsThroughTheCentre() {
    var scrub = MetroRimScrub(degreesPerStep: 10)
    scrub.begin(at: rim(175), diameter: d)
    XCTAssertEqual(scrub.update(at: rim(-178), diameter: d, accept: { $0 }), 1, "7° across ±180°")
    // Through the centre: history is dropped, emerging opposite does not jump.
    XCTAssertEqual(scrub.update(at: CGPoint(x: 161, y: 161), diameter: d, accept: { $0 }), 0)
    XCTAssertEqual(scrub.update(at: rim(0), diameter: d, accept: { $0 }), 0)
    XCTAssertEqual(scrub.update(at: rim(3), diameter: d, accept: { $0 }), 0)
    XCTAssertEqual(scrub.emitted, 1)
  }

  func testTravelPastALimitIsNotStored() {
    var scrub = MetroRimScrub(degreesPerStep: 10)
    scrub.begin(at: rim(0), diameter: d)
    // The host is at its maximum: forward travel is refused and dropped.
    XCTAssertEqual(scrub.update(at: rim(30), diameter: d, accept: { _ in 0 }), 0)
    XCTAssertEqual(scrub.update(at: rim(60), diameter: d, accept: { _ in 0 }), 0)
    XCTAssertEqual(scrub.position, 0)
    // Turning back responds after 0.65 of a step, not after unwinding 60°.
    XCTAssertEqual(scrub.update(at: rim(53), diameter: d, accept: { $0 }), -1)
  }

  func testLargeJumpsProposeTheWholeTravelAndTheHostDecides() {
    var scrub = MetroRimScrub(degreesPerStep: 10)
    var proposals: [Int] = []
    scrub.begin(at: rim(0), diameter: d)
    XCTAssertEqual(scrub.update(at: rim(35), diameter: d, accept: { proposals.append($0); return min($0, 2) }), 2)
    XCTAssertEqual(proposals, [3])
    XCTAssertEqual(scrub.emitted, 2)
    XCTAssertEqual(scrub.position, 2, "unaccepted travel dropped")
    XCTAssertEqual(MetroRimScrub(degreesPerStep: .nan).degreesPerStep, 10)
    XCTAssertEqual(MetroRimScrub(degreesPerStep: -1).degreesPerStep, 10)
  }
}
