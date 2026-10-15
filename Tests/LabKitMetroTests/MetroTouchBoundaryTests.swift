import CoreGraphics
import XCTest

@testable import LabKitMetro

/// The InstrumentControlTouchBoundary decisions (spec §9; Metro Station `ScrollGestureBoundary`): a touch that begins
/// on a control owns its whole sequence; any other touch scrolls the page without waiting.
final class MetroTouchBoundaryTests: XCTestCase {
  private let bounds = CGRect(x: 0, y: 0, width: 300, height: 48)

  private func owns(_ point: CGPoint, hidden: Bool = false, alpha: Double = 1, sameWindow: Bool = true) -> Bool {
    MetroTouchOwnership.owns(
      location: point, markerBounds: bounds, isHidden: hidden, alpha: alpha, sharesWindowWithScrollView: sameWindow)
  }

  func testTouchesBeginningOnTheControlIncludingItsEdgesAreOwned() {
    XCTAssertTrue(owns(CGPoint(x: 150, y: 24)))
    // The full native button bounds, top and bottom edges included.
    XCTAssertTrue(owns(CGPoint(x: 0, y: 0)))
    XCTAssertTrue(owns(CGPoint(x: 300, y: 48)))
    XCTAssertTrue(owns(CGPoint(x: 150, y: 48)))
    XCTAssertTrue(owns(CGPoint(x: 150, y: 0)))
  }

  func testTouchesBeginningElsewhereAreDeclined() {
    XCTAssertFalse(owns(CGPoint(x: 150, y: -0.5)))
    XCTAssertFalse(owns(CGPoint(x: 150, y: 48.5)))
    XCTAssertFalse(owns(CGPoint(x: -1, y: 24)))
    XCTAssertFalse(owns(CGPoint(x: 301, y: 24)))
    XCTAssertFalse(owns(CGPoint(x: CGFloat.nan, y: 24)))
    XCTAssertFalse(owns(CGPoint(x: CGFloat.infinity, y: 24)))
  }

  func testHiddenTransparentEmptyOrDetachedMarkersOwnNothing() {
    let centre = CGPoint(x: 150, y: 24)
    XCTAssertFalse(owns(centre, hidden: true))
    XCTAssertFalse(owns(centre, alpha: 0))
    XCTAssertFalse(owns(centre, alpha: 0.01))
    XCTAssertTrue(owns(centre, alpha: 0.02))
    XCTAssertFalse(owns(centre, sameWindow: false))
    XCTAssertFalse(
      MetroTouchOwnership.owns(
        location: .zero, markerBounds: .zero, isHidden: false, alpha: 1, sharesWindowWithScrollView: true))
  }

  func testOnlyTheGuardedScrollPanWaitsAndOnlyItCanBePrevented() {
    XCTAssertTrue(MetroTouchOwnership.scrollPanMustWait(isBoundary: true, otherIsScrollPan: true))
    XCTAssertFalse(MetroTouchOwnership.scrollPanMustWait(isBoundary: true, otherIsScrollPan: false))
    XCTAssertFalse(MetroTouchOwnership.scrollPanMustWait(isBoundary: false, otherIsScrollPan: true))
    // The control's own gestures (native Stepper repeat, a crown drag) keep recognising alongside the boundary.
    XCTAssertTrue(MetroTouchOwnership.recognisesSimultaneously(otherIsScrollPan: false))
    XCTAssertFalse(MetroTouchOwnership.recognisesSimultaneously(otherIsScrollPan: true))
    XCTAssertTrue(MetroTouchOwnership.canPrevent(otherIsScrollPan: true))
    XCTAssertFalse(MetroTouchOwnership.canPrevent(otherIsScrollPan: false))
  }

  // MARK: Sequence

  func testAHeldTouchHoldsTheScrollBackUntilItLifts() {
    var sequence = MetroTouchSequence()
    XCTAssertEqual(sequence.phase, .possible)
    XCTAssertFalse(sequence.isActive)
    sequence.touchesBegan([1])
    XCTAssertEqual(sequence.phase, .began)
    XCTAssertTrue(sequence.isActive)
    // Held still across many redraws, then moved: still active.
    sequence.touchesMoved()
    XCTAssertEqual(sequence.phase, .changed)
    for _ in 0..<100 { sequence.touchesMoved() }
    XCTAssertTrue(sequence.isActive)
    sequence.touchesEnded([1])
    XCTAssertEqual(sequence.phase, .ended)
    XCTAssertFalse(sequence.isActive)
    sequence.reset()
    XCTAssertEqual(sequence.phase, .possible)
    XCTAssertTrue(sequence.tracked.isEmpty)
  }

  func testMultiTouchEndsOnlyWithTheLastFinger() {
    var sequence = MetroTouchSequence()
    sequence.touchesBegan([1])
    sequence.touchesBegan([2])
    XCTAssertEqual(sequence.tracked, [1, 2])
    sequence.touchesEnded([1])
    XCTAssertTrue(sequence.isActive)
    sequence.touchesEnded([2])
    XCTAssertEqual(sequence.phase, .ended)
  }

  func testUnrelatedTouchesFailAPossibleBoundaryAtOnce() {
    var sequence = MetroTouchSequence()
    sequence.rejectUnrelated()
    XCTAssertEqual(sequence.phase, .failed)
    // An active sequence is unaffected by a second, unrelated finger elsewhere.
    var active = MetroTouchSequence()
    active.touchesBegan([1])
    active.rejectUnrelated()
    XCTAssertTrue(active.isActive)
  }

  func testCancellationAndDetachment() {
    var cancelled = MetroTouchSequence()
    cancelled.touchesBegan([1])
    cancelled.touchesCancelled()
    XCTAssertEqual(cancelled.phase, .cancelled)
    XCTAssertTrue(cancelled.tracked.isEmpty)

    var neverBegan = MetroTouchSequence()
    neverBegan.touchesCancelled()
    XCTAssertEqual(neverBegan.phase, .failed)

    var detached = MetroTouchSequence()
    detached.touchesBegan([7])
    detached.detach()
    XCTAssertEqual(detached.phase, .cancelled)
    XCTAssertTrue(detached.tracked.isEmpty)

    var idle = MetroTouchSequence()
    idle.detach()
    XCTAssertEqual(idle.phase, .failed)
  }

  func testEndedSequencesIgnoreLateEvents() {
    var sequence = MetroTouchSequence()
    sequence.touchesBegan([1])
    sequence.touchesEnded([1])
    sequence.touchesMoved()
    XCTAssertEqual(sequence.phase, .ended)
    sequence.touchesCancelled()
    XCTAssertEqual(sequence.phase, .ended)
  }
}
