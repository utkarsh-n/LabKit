import Foundation
import LabKitCore

/// How a LabKit `ParamSpec` maps onto Metro's two adjustment roles (spec §10, §19), so a `ParamStore` can drive Metro
/// crowns and Steppers without a parallel model:
///
/// - **fine**: one `step` for a stepped parameter with at most 200 steps (Heat 0–90 °C step 1 moves 1 °C), otherwise
///   1/100 of the sweep in position space (a log parameter moves by a constant ratio), quantised; a step that would
///   jump over a labelled detent lands on it, so "Earth" is felt on the way past.
/// - **semantic**: the next labelled detent in that direction (Zero-g → Moon → Mars → Earth → Jupiter); a rotary switch
///   moves one position; a parameter without detents moves a coarse quarter of its sweep (`nudged(coarse:)`).
///
/// Every function returns nil when the value would not change (a domain limit): the caller then emits no event and no
/// feedback (contract: one feedback per accepted change, none for a clamped no-op).
nonisolated public enum MetroParamStepping {
  /// The most steps a stepped parameter may have for a fine move to be one step.
  public static let maximumFineSteps = 200.0
  /// A fine move of a continuous parameter, as a fraction of the sweep.
  public static let continuousFineFraction = 0.01

  public static func step(_ spec: ParamSpec, from value: Double, direction: Int, role: MetroDetentRole) -> Double? {
    role == .fine ? fine(spec, from: value, direction: direction) : semantic(spec, from: value, direction: direction)
  }

  public static func fine(_ spec: ParamSpec, from value: Double, direction: Int) -> Double? {
    let dir = direction.signum()
    guard dir != 0 else { return nil }
    let current = spec.clamp(value)
    let target: Double
    if spec.isSwitch {
      target = spec.quantised(current + Double(dir) * spec.step)
    } else if spec.step > 0, (spec.range.upperBound - spec.range.lowerBound) / spec.step <= maximumFineSteps + 1e-9 {
      target = spec.quantised(current + Double(dir) * spec.step)
    } else {
      target = spec.value(at: spec.position(of: current) + Double(dir) * continuousFineFraction)
    }
    return changed(spec, from: current, to: stopAtDetent(spec, from: current, to: target))
  }

  public static func semantic(_ spec: ParamSpec, from value: Double, direction: Int) -> Double? {
    let dir = direction.signum()
    guard dir != 0 else { return nil }
    let current = spec.clamp(value)
    if spec.isSwitch { return fine(spec, from: current, direction: dir) }
    if let detent = nextDetent(spec, from: current, direction: dir) {
      return changed(spec, from: current, to: spec.clamp(detent.value))
    }
    // Past the last detent (or none at all): a coarse move, which itself stops on any detent it crosses.
    return changed(spec, from: current, to: spec.nudged(current, by: dir, coarse: true))
  }

  /// The number of fine steps across the whole sweep: `range / step` for a stepped parameter with at most 200 steps,
  /// the positions of a switch less one, 100 (1 % each) otherwise.
  public static func fineStepsAcrossSweep(_ spec: ParamSpec) -> Double {
    if spec.isSwitch { return Double(max(1, spec.switchCount - 1)) }
    if spec.step > 0 {
      let steps = (spec.range.upperBound - spec.range.lowerBound) / spec.step
      if steps <= maximumFineSteps + 1e-9 { return max(1, steps.rounded()) }
    }
    return 1 / continuousFineFraction
  }

  /// Rim-scrub travel per fine step, so one trip round a primary object's 300° scale crosses the whole sweep (the
  /// source's 300° for 30…240 BPM is 1.43° per BPM; Heat 0…90 °C step 1 is 3.33° per degree).
  public static func rimDegreesPerStep(_ spec: ParamSpec, scaleDegrees: Double = 300) -> Double {
    scaleDegrees / fineStepsAcrossSweep(spec)
  }

  /// Applies up to `|steps|` fine steps in the sign's direction, stopping at a limit. Returns the new value and the
  /// signed number of steps actually taken (0 at a limit: the caller emits nothing).
  public static func applyFine(_ spec: ParamSpec, from value: Double, steps: Int) -> (value: Double, applied: Int) {
    let direction = steps.signum()
    var current = spec.clamp(value)
    var applied = 0
    for _ in 0..<steps.magnitude {
      guard let next = fine(spec, from: current, direction: direction) else { break }
      current = next
      applied += direction
    }
    return (current, applied)
  }

  /// Whether a step in `direction` would change the value.
  public static func canStep(_ spec: ParamSpec, from value: Double, direction: Int, role: MetroDetentRole) -> Bool {
    step(spec, from: value, direction: direction, role: role) != nil
  }

  /// The labelled detent strictly beyond `value` in `direction`, nearest first.
  public static func nextDetent(_ spec: ParamSpec, from value: Double, direction: Int) -> Detent? {
    let p = spec.position(of: value)
    let candidates = spec.detents.filter {
      let q = spec.position(of: $0.value)
      return direction > 0 ? q > p + 1e-9 : q < p - 1e-9
    }
    return candidates.min { abs(spec.position(of: $0.value) - p) < abs(spec.position(of: $1.value) - p) }
  }

  /// The name a semantic step in `direction` would reach ("Moon"), the switch label for a switch, or nil.
  public static func neighbourName(_ spec: ParamSpec, from value: Double, direction: Int) -> String? {
    if spec.isSwitch {
      guard let next = fine(spec, from: value, direction: direction) else { return nil }
      return spec.formatted(next)
    }
    return nextDetent(spec, from: value, direction: direction)?.label
  }

  /// The labelled detent at or below `value` (the "band" a value is in), for a semantic caption ("Mars").
  public static func band(_ spec: ParamSpec, at value: Double) -> Detent? {
    let p = spec.position(of: value)
    return spec.detents
      .filter { spec.position(of: $0.value) <= p + 1e-9 }
      .max { spec.position(of: $0.value) < spec.position(of: $1.value) }
  }

  static func stopAtDetent(_ spec: ParamSpec, from a: Double, to b: Double) -> Double {
    let pa = spec.position(of: a)
    let pb = spec.position(of: b)
    let crossed = spec.detents.filter {
      let p = spec.position(of: $0.value)
      return pb > pa ? (p > pa + 1e-9 && p < pb - 1e-9) : (p < pa - 1e-9 && p > pb + 1e-9)
    }
    guard let first = crossed.min(by: { abs(spec.position(of: $0.value) - pa) < abs(spec.position(of: $1.value) - pa) })
    else { return b }
    return spec.clamp(first.value)
  }

  static func changed(_ spec: ParamSpec, from a: Double, to b: Double) -> Double? {
    abs(spec.position(of: b) - spec.position(of: a)) > 1e-9 ? b : nil
  }
}

// MARK: - ParamStore driver

extension ParamStore {
  /// One accepted Metro step on a stored parameter (what `MetroParamStepper`, `MetroParamCrown` and `MetroParamGauge`
  /// do): the value moves by `MetroParamStepping.step` and is written **once**; at a domain limit nothing is written and
  /// the result is nil, so the caller emits no event and plays no feedback.
  @discardableResult
  public func metroStep(_ id: ParamID, direction: Int, role: MetroDetentRole) -> Double? {
    guard let next = MetroParamStepping.step(spec(id), from: self[id], direction: direction, role: role) else { return nil }
    self[id] = next
    return self[id]
  }

  /// Up to `|steps|` fine steps written as one change (a rim scrub or a named VoiceOver action). Returns the signed number
  /// of steps taken; 0 (and no write) at a limit.
  @discardableResult
  public func metroApplyFine(_ id: ParamID, steps: Int) -> Int {
    guard steps != 0 else { return 0 }
    let result = MetroParamStepping.applyFine(spec(id), from: self[id], steps: steps)
    if result.applied != 0 { self[id] = result.value }
    return result.applied
  }
}
