import Foundation

/// The two adjustment roles of a Metro crown (spec §10): **fine** moves a quantity by its smallest meaningful step
/// (8° detents), **semantic** jumps between named states, presets or scales (20° detents). Each has its own detent
/// feel, and the direction is felt too (`Metro.HapticDetents`).
nonisolated public enum MetroDetentRole: String, Sendable, CaseIterable {
  case fine, semantic

  /// Angular spacing of one detent, degrees.
  public var detentDegrees: Double {
    self == .fine ? Metro.Motion.fineDetentDegrees : Metro.Motion.coarseDetentDegrees
  }

  /// The Core Haptics transient for one accepted step in `direction` (> 0 up, < 0 down).
  public func haptic(direction: Int) -> Metro.HapticDetent {
    switch (self, direction > 0) {
    case (.fine, true): Metro.HapticDetents.fineUp
    case (.fine, false): Metro.HapticDetents.fineDown
    case (.semantic, true): Metro.HapticDetents.semanticUp
    case (.semantic, false): Metro.HapticDetents.semanticDown
    }
  }
}

/// Relative angular detents for a touch crown (Metro Station `CrownDetentTracker`, unchanged maths). Clockwise screen
/// angles are positive. Travel accumulates incrementally across the ±180° seam; reversing direction needs the detent
/// plus `hysteresisDegrees` (18 % of the spacing: 1.44° fine, 3.6° semantic). Each update returns at most one step,
/// and a large pointer jump keeps its fractional travel but never queues catch-up notches.
nonisolated public struct MetroCrownDetentTracker: Sendable, Equatable {
  public let detentDegrees: Double
  public let hysteresisDegrees: Double
  public private(set) var residualDegrees: Double = 0
  public private(set) var lastDirection: Int = 0
  private var previousAngle: Double?

  /// `detentDegrees` is clamped to 0.1…90 (8 when not finite); hysteresis defaults to 18 % of it and is clamped to
  /// 0…45 % of it.
  public init(detentDegrees: Double, hysteresisDegrees: Double? = nil) {
    let spacing = detentDegrees.isFinite ? min(90, max(0.1, detentDegrees)) : Metro.Motion.fineDetentDegrees
    self.detentDegrees = spacing
    let ratio = Metro.Motion.reversalHysteresisRatio
    let requested = hysteresisDegrees ?? spacing * ratio
    self.hysteresisDegrees = requested.isFinite ? min(spacing * 0.45, max(0, requested)) : spacing * ratio
  }

  public init(role: MetroDetentRole) { self.init(detentDegrees: role.detentDegrees) }

  /// First touch: initialises the angular history without changing the value.
  public mutating func begin(angleDegrees: Double) {
    reset()
    if angleDegrees.isFinite { previousAngle = Self.wrap(angleDegrees) }
  }

  /// Discards all history (touch end, crossing the centre exclusion).
  public mutating func reset() {
    previousAngle = nil
    residualDegrees = 0
    lastDirection = 0
  }

  /// Accumulates relative motion and returns −1, 0 or +1.
  public mutating func update(angleDegrees: Double) -> Int {
    guard angleDegrees.isFinite else { return 0 }
    let angle = Self.wrap(angleDegrees)
    guard let previousAngle else {
      self.previousAngle = angle
      return 0
    }
    self.previousAngle = angle
    residualDegrees += Self.wrap(angle - previousAngle)
    let direction = residualDegrees > 0 ? 1 : -1
    let reversing = lastDirection != 0 && direction != lastDirection
    let threshold = detentDegrees + (reversing ? hysteresisDegrees : 0)
    // Ignore only floating-point noise at an exact angular threshold.
    guard abs(residualDegrees) + 1e-9 >= threshold else { return 0 }
    residualDegrees -= Double(direction) * threshold
    // Keep fractional travel while discarding further whole steps from a large jump.
    residualDegrees = residualDegrees.truncatingRemainder(dividingBy: detentDegrees)
    if abs(residualDegrees) < 1e-9 { residualDegrees = 0 }
    lastDirection = direction
    return direction
  }

  /// An angle wrapped into −180…180 degrees.
  public static func wrap(_ angle: Double) -> Double {
    var result = angle.truncatingRemainder(dividingBy: 360)
    if result > 180 { result -= 360 }
    if result < -180 { result += 360 }
    return result
  }
}

/// The output side of a crown (Metro Station `TempoCrownControl`): at most one accepted step per `minimumInterval`
/// (20 a second), a pending notch waits for the interval instead of queueing a burst, and moving back by more than half
/// a degree clears it ("a queued notch cannot fire against a new direction"). A step the host cannot take (a domain
/// limit) is dropped without using the interval, so the next real step is not delayed.
nonisolated public struct MetroDetentGate: Sendable, Equatable {
  public let minimumInterval: Double
  public private(set) var pending = 0
  public private(set) var lastEmission = -Double.infinity

  public init(maximumRate: Double = Metro.Motion.detentMaxHz) {
    minimumInterval = maximumRate.isFinite && maximumRate > 0 ? 1 / maximumRate : 0.05
  }

  /// A new gesture: nothing pending, no rate history.
  public mutating func begin() {
    pending = 0
    lastEmission = -.infinity
  }

  /// Drops a pending notch (the finger crossed the centre exclusion).
  public mutating func clearPending() { pending = 0 }

  /// One gesture update. `visualDelta` is this update's angular change in degrees (nil on the first sample), `detent`
  /// the tracker's output, `now` a monotonic clock in seconds. `canStep` says whether the host would accept a step in
  /// that direction. Returns the accepted direction (−1 or +1), or 0.
  public mutating func update(
    visualDelta: Double?, detent: Int, now: Double, canStep: (Int) -> Bool
  ) -> Int {
    if pending != 0, let delta = visualDelta, delta * Double(pending) < -Metro.Motion.pendingReversalDegrees {
      pending = 0
    }
    if detent != 0 { pending = detent > 0 ? 1 : -1 }
    guard pending != 0, now.isFinite, now - lastEmission >= minimumInterval else { return 0 }
    let direction = pending
    pending = 0
    guard canStep(direction) else { return 0 }
    lastEmission = now
    return direction
  }
}
