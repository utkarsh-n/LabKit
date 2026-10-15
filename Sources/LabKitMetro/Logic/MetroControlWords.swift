import LabKitCore

// Pure crown and Stepper vocabulary (no SwiftUI), so the words and rules are testable on any platform.

/// What a crown's metal face shows at its centre: a short engraved figure ("1") or an SF Symbol.
nonisolated public enum MetroCrownGlyph: Sendable, Hashable {
  case text(String)
  case symbol(String)
}

/// The caption row under a crown: plain text ("±1 BPM"), or the neighbouring semantic states either side of a
/// swap arrow ("Andante ⇄ Allegro"), falling back to `fallback` when that does not fit.
nonisolated public enum MetroCrownFooter: Sendable, Hashable {
  case text(String)
  case neighbours(previous: String, next: String, fallback: String)
}

/// Pure Stepper rules (tested).
nonisolated public enum MetroStepperLogic {
  /// Whether an integer Stepper may move `direction` from `value` (an unchanged clamped target is not a change).
  public static func canStep(_ value: Int, direction: Int, in range: ClosedRange<Int>) -> Bool {
    (direction > 0 && value < range.upperBound) || (direction < 0 && value > range.lowerBound)
  }
}

/// The words a parameter crown shows and speaks (pure, tested).
nonisolated public struct MetroParamCrownWords: Sendable, Equatable {
  public let caption: String
  public let footer: MetroCrownFooter
  public let accessibilityLabel: String
  public let hint: String
  public let increaseLabel: String
  public let decreaseLabel: String

  public init(spec: ParamSpec, value: Double, role: MetroDetentRole) {
    let title = LabFormat.uppercasedLatin(spec.title)
    switch role {
    case .fine:
      caption = "FINE"
      let step = Self.fineStepText(spec)
      footer = .text(step)
      accessibilityLabel = "Fine \(spec.title.lowercased()) crown"
      hint = "Clockwise adds one fine step per notch; counterclockwise subtracts one."
      increaseLabel = "Increase \(spec.title.lowercased()) by one fine step"
      decreaseLabel = "Decrease \(spec.title.lowercased()) by one fine step"
    case .semantic:
      let band = spec.isSwitch ? spec.formatted(value) : MetroParamStepping.band(spec, at: value)?.label
      caption = band.map { "\(title) · \(LabFormat.uppercasedLatin($0))" } ?? title
      let previous = MetroParamStepping.neighbourName(spec, from: value, direction: -1) ?? "—"
      let next = MetroParamStepping.neighbourName(spec, from: value, direction: 1) ?? "—"
      footer =
        spec.detents.isEmpty && !spec.isSwitch
        ? .text(Self.coarseStepText(spec)) : .neighbours(previous: previous, next: next, fallback: "NEXT STOP")
      accessibilityLabel = "\(spec.title) stops crown"
      hint = "Clockwise moves to the next named stop; counterclockwise to the previous one."
      increaseLabel = next == "—" ? "Next \(spec.title.lowercased()) stop" : "Select \(next)"
      decreaseLabel = previous == "—" ? "Previous \(spec.title.lowercased()) stop" : "Select \(previous)"
    }
  }

  /// "±1 °C" for a stepped number, "±1 %" of the sweep for a continuous parameter.
  public static func fineStepText(_ spec: ParamSpec) -> String {
    let steps = spec.step > 0 ? (spec.range.upperBound - spec.range.lowerBound) / spec.step : .infinity
    if spec.isSwitch { return "±1 POSITION" }
    if steps <= MetroParamStepping.maximumFineSteps + 1e-9, case .number(let precision, let unit) = spec.format {
      let text = MetroFormat.isWhole(spec.step) ? MetroFormat.whole(spec.step) : LabFormat.fixed(spec.step, precision: precision)
      return "±" + MetroFormat.join(text, unit: unit)
    }
    return "±1% SWEEP"
  }

  /// What a semantic step does to a parameter without labelled detents, matching `ParamSpec.nudged(coarse: true)`:
  /// "±5 °C" for a parameter of at most 100 steps (five steps), "±¼ SWEEP" otherwise.
  public static func coarseStepText(_ spec: ParamSpec) -> String {
    let steps = spec.step > 0 ? (spec.range.upperBound - spec.range.lowerBound) / spec.step : .infinity
    if steps <= 100 + 1e-9, case .number(let precision, let unit) = spec.format {
      let coarse = 5 * spec.step
      let text = MetroFormat.isWhole(coarse) ? MetroFormat.whole(coarse) : LabFormat.fixed(coarse, precision: precision)
      return "±" + MetroFormat.join(text, unit: unit)
    }
    return "±¼ SWEEP"
  }
}

/// Major labels for a parameter's primary-object scale (pure, tested).
nonisolated public enum MetroParamGaugeLabels {
  /// `majors` labels at evenly spaced positions along the sweep (position space, so a log parameter's labels follow
  /// its scale), each the quantised value as the hero would show it without its unit.
  public static func labels(_ spec: ParamSpec, majors: Int) -> [String] {
    let count = max(2, majors)
    return (0..<count).map { index in
      MetroFormat.heroParts(spec, spec.value(at: Double(index) / Double(count - 1))).value
    }
  }
}

/// One telemetry metric (spec §12): an engineering label, a value at a fixed precision and its unit.
nonisolated public struct MetroMetric: Identifiable, Sendable, Hashable {
  public let label: String
  public let value: String
  public let unit: String
  public let colour: LabColor
  /// What VoiceOver says for the value and unit ("2.00 hertz"); `LabFormat.spoken("value unit")` when nil.
  public let spoken: String?
  public var id: String { label }

  public init(_ label: String, value: String, unit: String, colour: LabColor = Metro.Colour.actionCyan, spoken: String? = nil) {
    self.label = label
    self.value = value
    self.unit = unit
    self.colour = colour
    self.spoken = spoken
  }

  /// A whole-number metric ("INTERVAL 500 ms").
  public init(_ label: String, whole value: Double, unit: String, colour: LabColor = Metro.Colour.actionCyan) {
    self.init(label, value: MetroFormat.whole(value), unit: unit, colour: colour)
  }

  /// A metric at a fixed precision ("BEAT RATE 2.00 Hz").
  public init(_ label: String, value: Double, precision: Int, unit: String, colour: LabColor = Metro.Colour.actionCyan) {
    self.init(label, value: MetroFormat.fixed(value, precision: precision), unit: unit, colour: colour)
  }

  /// The complete spoken value.
  public var spokenValue: String { spoken ?? LabFormat.spoken(MetroFormat.join(value, unit: unit)) }
}
