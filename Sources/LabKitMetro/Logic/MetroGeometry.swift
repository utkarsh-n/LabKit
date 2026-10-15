import CoreGraphics
import Foundation

/// The gauge cluster calculation (spec §5): a primary object flanked by two vertical signal pills.
///
///     clusterWidth = min(available, 490)      pillWidth = clusterWidth < 350 ? 30 : 36
///     D = min(360, clusterWidth − 2 pillWidth − 12)      pillHeight = min(218, 0.66 D)
///
/// On a 430 pt-wide iPhone the dial is 322 pt.
nonisolated public struct MetroClusterLayout: Sendable, Equatable {
  public let diameter: CGFloat
  public let pillWidth: CGFloat
  public let pillHeight: CGFloat
  public let gap: CGFloat
  /// D + 2 pillWidth + 2 gap.
  public var width: CGFloat { diameter + 2 * pillWidth + 2 * gap }

  public init(availableWidth: CGFloat) {
    let available = availableWidth.isFinite ? max(0, availableWidth) : 0
    let cluster = min(available, Metro.Layout.clusterMax)
    let pill = cluster < Metro.Layout.pillWidthBreakpoint ? Metro.Layout.pillWidthCompact : Metro.Layout.pillWidthRegular
    gap = Metro.Layout.clusterGap
    pillWidth = pill
    diameter = max(1, min(Metro.Layout.gaugeMax, cluster - 2 * pill - 2 * Metro.Layout.clusterGap))
    pillHeight = min(Metro.Layout.pillHeightMax, Metro.Layout.pillHeightRatio * diameter)
  }
}

/// Fixed readout coordinates inside a primary object of diameter D (spec §8): value at y 0.52 D, units 0.665 D,
/// meaning 0.745 D (0.79 D at accessibility sizes, where units and phase are hidden), phase 0.835 D, all centred.
/// They never depend on tilt, the lens radius or the drawing (contract 1).
nonisolated public struct MetroReadoutLayout: Sendable, Equatable {
  public let diameter: CGFloat
  public let accessibilitySize: Bool

  public init(diameter: CGFloat, accessibilitySize: Bool = false) {
    self.diameter = diameter.isFinite ? max(1, diameter) : 1
    self.accessibilitySize = accessibilitySize
  }

  public var centreX: CGFloat { diameter / 2 }
  public var valueY: CGFloat { diameter * Metro.Gauge.readoutYRatio }
  public var unitsY: CGFloat { diameter * Metro.Gauge.unitsYRatio }
  public var meaningY: CGFloat {
    diameter * (accessibilitySize ? Metro.Gauge.meaningYAccessibilityRatio : Metro.Gauge.meaningYRatio)
  }
  public var phaseY: CGFloat { diameter * Metro.Gauge.phaseYRatio }
  public var readoutWidth: CGFloat { diameter * Metro.Gauge.readoutWidthRatio }
  public var valueFontSize: CGFloat { diameter * Metro.Typography.heroValueRatio }
  /// Units and phase metadata are decorative engraving: hidden at accessibility sizes (the spoken value keeps them).
  public var showsSupplementaryLines: Bool { !accessibilitySize }
}

/// Incremental rim scrubbing for a primary object (spec §8; Metro Station `GaugeView`): angular travel accumulates
/// across the ±π seam instead of mapping the first touch to an absolute value, only touches that begin outside 0.30 D
/// count, and the output is quantised with Schmitt hysteresis (a step after 0.65 of a step of travel, reversal needs a
/// real 0.30 band) so tremor around a half step cannot flip it. The host applies each proposed change and reports how
/// much it accepted; travel past a domain limit is not stored, so turning back responds at once.
nonisolated public struct MetroRimScrub: Sendable, Equatable {
  /// Degrees of rim travel per whole step.
  public let degreesPerStep: Double
  public static let stepThreshold = 0.65
  /// Continuous position in steps since the scrub began.
  public private(set) var position: Double = 0
  /// Whole steps accepted since the scrub began.
  public private(set) var emitted = 0
  private var previousAngle: Double?
  public private(set) var isActive = false

  public init(degreesPerStep: Double) {
    self.degreesPerStep = degreesPerStep.isFinite && degreesPerStep > 0 ? degreesPerStep : 10
  }

  /// Whether a touch that starts at `location` (relative to the object's top-left corner) may scrub.
  public static func beginsOnRim(_ location: CGPoint, diameter: CGFloat) -> Bool {
    let d = Double(diameter)
    guard d > 0, location.x.isFinite, location.y.isFinite else { return false }
    return hypot(Double(location.x) - d / 2, Double(location.y) - d / 2) >= d * Double(Metro.Gauge.scrubInnerRadiusRatio)
  }

  public mutating func begin(at location: CGPoint, diameter: CGFloat) {
    isActive = true
    position = 0
    emitted = 0
    previousAngle = Self.angle(location, diameter: diameter)
  }

  public mutating func end() {
    isActive = false
    previousAngle = nil
    position = 0
    emitted = 0
  }

  /// One drag sample. `accept` receives the proposed whole-step change and returns the change the host applied (0 at a
  /// limit). Returns the applied change. A finger within 0.20 D of the centre drops its angular history, so emerging on
  /// the other side cannot jump.
  public mutating func update(at location: CGPoint, diameter: CGFloat, accept: (Int) -> Int) -> Int {
    guard isActive, let angle = Self.angle(location, diameter: diameter) else {
      previousAngle = nil
      return 0
    }
    defer { previousAngle = angle }
    guard let previousAngle else { return 0 }
    var delta = angle - previousAngle
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    guard abs(delta) > 1e-5 else { return 0 }
    position += delta * 180 / .pi / degreesPerStep
    let target: Int
    if position >= Double(emitted) + Self.stepThreshold {
      target = Int(floor(position + (1 - Self.stepThreshold)))
    } else if position <= Double(emitted) - Self.stepThreshold {
      target = Int(ceil(position - (1 - Self.stepThreshold)))
    } else {
      return 0
    }
    let proposed = target - emitted
    guard proposed != 0 else { return 0 }
    let applied = accept(proposed)
    emitted += applied
    // At a limit the unaccepted travel is dropped, as the source clamps its tempo to 30…240.
    if applied != proposed { position = Double(emitted) }
    return applied
  }

  static func angle(_ location: CGPoint, diameter: CGFloat) -> Double? {
    let d = Double(diameter)
    guard d > 0, location.x.isFinite, location.y.isFinite else { return nil }
    let dx = Double(location.x) - d / 2
    let dy = Double(location.y) - d / 2
    guard hypot(dx, dy) >= d * 0.20 else { return nil }
    return atan2(dy, dx)
  }
}
