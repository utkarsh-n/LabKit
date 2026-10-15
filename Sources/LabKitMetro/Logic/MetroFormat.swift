import Foundation
import LabKitCore

/// Metro number formatting (spec §4 "Formatting contracts", contract 6): whole-number quantities render with whole
/// digits and no decimals; other quantities keep a fixed precision their units justify. Locale-independent like
/// `LabFormat` (U+2212 for negatives, never "−0", "—" when not finite), so displayed and spoken values agree.
nonisolated public enum MetroFormat {
  /// Whole digits: `120`, `−5`. Rounds half away from zero. "—" when not finite.
  public static func whole(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return LabFormat.fixed(value.rounded(.toNearestOrAwayFromZero), precision: 0)
  }

  /// Whole digits for an integer: `120`, `−5` (U+2212).
  public static func whole(_ value: Int) -> String {
    value < 0 ? "\u{2212}" + String(value.magnitude) : String(value)
  }

  /// A fixed number of fraction digits (0…6): `2.00`. Precision 0 is `whole(_:)`.
  public static func fixed(_ value: Double, precision: Int) -> String {
    precision <= 0 ? whole(value) : LabFormat.fixed(value, precision: precision)
  }

  /// Whether `value` is a whole number (within a relative 1e-9, so 0.1 + 0.2 + 0.7 counts).
  public static func isWhole(_ value: Double) -> Bool {
    guard value.isFinite else { return false }
    return abs(value - value.rounded()) <= 1e-9 * max(1, abs(value))
  }

  /// Joins a formatted value and its unit: no space before °, %, ′ and ″ ("45°", "46%"), one space otherwise
  /// ("120 BPM", "45 °C"), the bare value when the unit is empty.
  public static func join(_ value: String, unit: String) -> String {
    if unit.isEmpty { return value }
    if ["°", "%", "′", "″"].contains(unit) { return value + unit }
    return "\(value) \(unit)"
  }

  /// A whole-number quantity with its unit: `quantity(120, unit: "BPM")` → "120 BPM".
  public static func quantity(_ value: Int, unit: String) -> String { join(whole(value), unit: unit) }

  /// A quantity with a fixed precision and unit: `quantity(2, precision: 2, unit: "Hz")` → "2.00 Hz".
  public static func quantity(_ value: Double, precision: Int, unit: String) -> String {
    join(fixed(value, precision: precision), unit: unit)
  }

  // MARK: ParamSpec

  /// A parameter whose every reachable value is whole: a whole-number step from a whole-number lower bound (Heat 0–90
  /// °C step 1, a stripe count 1–7 step 1). Continuous parameters (step 0) never are.
  public static func isWholeStepped(_ spec: ParamSpec) -> Bool {
    spec.step >= 1 && isWhole(spec.step) && isWhole(spec.range.lowerBound)
  }

  /// The value as Metro shows it: `spec.formatted(value)`, except that a whole-stepped parameter with a `.number`
  /// format shows whole digits whatever precision the format asks for (contract 6). Labels, percentages and custom
  /// formats are the app's words and are left alone.
  public static func formatted(_ spec: ParamSpec, _ value: Double) -> String {
    if isWholeStepped(spec), case .number(_, let unit) = spec.format { return join(whole(value), unit: unit) }
    return spec.formatted(value)
  }

  /// The value split for a hero readout, where the unit is engraved on its own line: `.number` gives the magnitude
  /// (whole digits when whole-stepped) and its unit; `.si` splits "12.4 mPa·s" at its last space; every other format
  /// keeps its words whole with no unit line.
  public static func heroParts(_ spec: ParamSpec, _ value: Double) -> (value: String, unit: String) {
    switch spec.format {
    case .number(let precision, let unit):
      return (isWholeStepped(spec) ? whole(value) : LabFormat.fixed(value, precision: precision), unit)
    case .si:
      let text = spec.formatted(value)
      guard let space = text.lastIndex(of: " ") else { return (text, "") }
      return (String(text[..<space]), String(text[text.index(after: space)...]))
    default:
      return (spec.formatted(value), "")
    }
  }

  /// The value as VoiceOver says it, consistent with `formatted(_:_:)` (spec §4: displayed and spoken precision agree),
  /// followed by the detent name when the value sits on one ("9.81 metres per second squared, Earth").
  public static func spoken(_ spec: ParamSpec, _ value: Double) -> String {
    let base: String
    if isWholeStepped(spec), case .number = spec.format {
      base = LabFormat.spoken(formatted(spec, value))
    } else {
      base = spec.format.spoken(value)
    }
    guard !spec.isSwitch, let detent = spec.detent(at: value), detent.label != formatted(spec, value),
      detent.label != base
    else { return base }
    return "\(base), \(detent.label)"
  }
}
