import CoreGraphics

/// The decisions behind `metroControlOwnsTouches` (spec §9 "Behavioural contract"; Metro Station
/// `ScrollGestureBoundary`), kept free of UIKit so they can be tested anywhere. A touch that **begins** inside a control's
/// marker belongs to the control for its whole sequence: the nearest containing scroll view's pan must wait for (and
/// fail with) the boundary recogniser. A touch that begins anywhere else is declined at once, so ordinary page scrolling
/// never waits on a recogniser that merely might begin. The boundary never cancels touches in the control and is never
/// prevented itself.
nonisolated public enum MetroTouchOwnership {
  /// Whether a touch that begins at `location` (marker coordinates) belongs to the control. A hidden, (nearly)
  /// transparent, empty or detached marker owns nothing; the edge counts as inside (the full native button bounds,
  /// including its top and bottom edges, are protected).
  public static func owns(
    location: CGPoint, markerBounds: CGRect, isHidden: Bool, alpha: Double, sharesWindowWithScrollView: Bool
  ) -> Bool {
    guard sharesWindowWithScrollView, !isHidden, alpha > 0.01, !markerBounds.isEmpty,
      location.x.isFinite, location.y.isFinite
    else { return false }
    return location.x >= markerBounds.minX && location.x <= markerBounds.maxX
      && location.y >= markerBounds.minY && location.y <= markerBounds.maxY
  }

  /// The boundary must be failed by the scroll view's pan before the pan may begin: true only for exactly that pair.
  public static func scrollPanMustWait(isBoundary: Bool, otherIsScrollPan: Bool) -> Bool { isBoundary && otherIsScrollPan }

  /// The boundary recognises alongside everything except the scroll pan it holds back (the control's own gestures,
  /// native Stepper repeat, a crown drag keep working).
  public static func recognisesSimultaneously(otherIsScrollPan: Bool) -> Bool { !otherIsScrollPan }

  /// The boundary may prevent only the scroll pan it guards.
  public static func canPrevent(otherIsScrollPan: Bool) -> Bool { otherIsScrollPan }
}

/// The boundary recogniser's state machine for one touch sequence (multi-touch aware): it begins on the first owned
/// touch, changes while any tracked touch moves, ends only when the last tracked touch lifts, and cancels (or fails, if it
/// never began) when the system cancels or the marker detaches. `UIGestureRecognizer.State` mirrors `phase` one to one.
nonisolated public struct MetroTouchSequence: Sendable, Equatable {
  public enum Phase: Sendable, Equatable { case possible, began, changed, ended, cancelled, failed }

  public private(set) var phase: Phase = .possible
  public private(set) var tracked: Set<Int> = []

  public init() {}

  /// Whether the sequence is holding the scroll pan back.
  public var isActive: Bool { phase == .began || phase == .changed }

  public mutating func touchesBegan(_ ids: some Sequence<Int>) {
    tracked.formUnion(ids)
    if phase == .possible { phase = .began }
  }

  public mutating func touchesMoved() {
    if isActive { phase = .changed }
  }

  public mutating func touchesEnded(_ ids: some Sequence<Int>) {
    tracked.subtract(ids)
    if tracked.isEmpty, isActive { phase = .ended }
  }

  public mutating func touchesCancelled() {
    tracked.removeAll()
    if isActive { phase = .cancelled } else if phase == .possible { phase = .failed }
  }

  /// The delegate declined a touch that began outside the marker: a merely possible boundary fails immediately, so the
  /// unrelated scroll does not wait on it. An active sequence is unaffected.
  public mutating func rejectUnrelated() {
    if phase == .possible { phase = .failed }
  }

  /// The marker left the window or moved to another scroll view.
  public mutating func detach() {
    if isActive { phase = .cancelled } else if phase == .possible { phase = .failed }
    tracked.removeAll()
  }

  /// UIKit's `reset()` after a sequence finishes.
  public mutating func reset() {
    phase = .possible
    tracked.removeAll()
  }
}
