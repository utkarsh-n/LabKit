import Foundation

/// Where a number comes from (labkit-from-orbitals-spectra.md §3.10). Every readout, knob, preset
/// and plot series carries one, and the UI shows it as a **word** badge: colour only reinforces it.
public enum Provenance: String, Sendable, Hashable, Codable, CaseIterable {
  /// Interpolated from published measurements (a table, a datasheet, a paper's data points).
  case measured
  /// Calculated from a physical model, a fitted law or the simulation itself.
  case modelled
  /// Read from this phone's sensors right now.
  case live
  /// A stand-in for a sensor: the Simulator, a launch-argument fake, touch-driven tilt, a denied mic.
  case simulated
  /// A display choice, not a quantity: slowed time, exaggerated depth, symbolic directions.
  case illustrative

  /// The word, lowercase.
  public var badge: String { rawValue }

  /// One line, shown in the provenance legend and as the badge's accessibility hint.
  public var explanation: String {
    switch self {
    case .measured: "Interpolated from published measurements."
    case .modelled: "Calculated from a physical model. Trust its shape more than its third digit."
    case .live: "Read from this phone's sensors as you watch."
    case .simulated: "A stand-in for a sensor this device doesn't have or hasn't allowed."
    case .illustrative: "A display choice to make the effect visible, not a measured quantity."
    }
  }

  /// measured, live → `LabSemantic.live`; modelled → `value`; simulated → `simulated`;
  /// illustrative → the ground's muted grey (drawn with a dashed outline).
  public func tint(on ground: LabGround = .abyss) -> LabColor {
    switch self {
    case .measured, .live: LabSemantic.live
    case .modelled: LabSemantic.value
    case .simulated: LabSemantic.simulated
    case .illustrative: ground.muted
    }
  }

  /// `tint(on: .abyss)`.
  public var tint: LabColor { tint(on: .abyss) }
}

/// A source the user can open, with a checked date (house rule: every real-world claim is cited).
public struct Citation: Sendable, Hashable, Codable, Identifiable {
  public enum Kind: String, Sendable, Hashable, Codable { case paper, dataset, datasheet, textbook, standard, web, code }
  public var id: String { url.absoluteString + "#" + title }
  public var title: String
  public var publisher: String
  public var url: URL
  public var kind: Kind
  /// Licence of code or data the app ships ("MIT", "BSD-3-Clause"); empty for references only cited.
  public var licence: String
  /// ISO date the link was last checked ("2026-10-03").
  public var checked: String

  public init(_ title: String, publisher: String, url: URL, kind: Kind, licence: String = "", checked: String) {
    self.title = title
    self.publisher = publisher
    self.url = url
    self.kind = kind
    self.licence = licence
    self.checked = checked
  }

  /// "Publisher · Title" (Orbitals HarmonicPreset `sourceTitle`).
  public var label: String { publisher.isEmpty ? title : "\(publisher)\(LabFormat.separator)\(title)" }
}

// MARK: - Experiments

/// What applying an experiment does besides setting values (§3.11). The copy is generated from
/// this set, so it can't drift from the behaviour.
public struct ExperimentEffects: OptionSet, Sendable, Hashable, Codable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let refillsTank = ExperimentEffects(rawValue: 1 << 0)
  public static let restartsClock = ExperimentEffects(rawValue: 1 << 1)
  public static let clearsHistory = ExperimentEffects(rawValue: 1 << 2)
  public static let resetsCamera = ExperimentEffects(rawValue: 1 << 3)
  public static let resumesPlay = ExperimentEffects(rawValue: 1 << 4)
  public static let switchesView = ExperimentEffects(rawValue: 1 << 5)

  /// The verb phrases in a fixed order ("refills the tank", "restarts the clock", …).
  public var phrases: [String] {
    var parts: [String] = []
    if contains(.refillsTank) { parts.append("refills the tank") }
    if contains(.restartsClock) { parts.append("restarts the clock") }
    if contains(.clearsHistory) { parts.append("clears the recording") }
    if contains(.resetsCamera) { parts.append("recentres the view") }
    if contains(.switchesView) { parts.append("opens the instrument that shows it") }
    if contains(.resumesPlay) { parts.append("starts playing") }
    return parts
  }

  /// "refills the tank, restarts the clock and starts playing" (empty when there are no effects).
  public var clause: String {
    let p = phrases
    switch p.count {
    case 0: return ""
    case 1: return p[0]
    default: return p.dropLast().joined(separator: ", ") + " and " + p[p.count - 1]
    }
  }

  /// "Each experiment refills the tank, restarts the clock and starts playing."
  public var sentence: String { clause.isEmpty ? "" : "Each experiment \(clause)." }

  /// The menu section header: "Experiments · each refills the tank and restarts the clock."
  public var menuHeader: String { clause.isEmpty ? "Experiments" : "Experiments\(LabFormat.separator)each \(clause)." }
}

/// A named starting point: a preset is just values (Gyre), plus copy, sources and side effects.
/// Identity is **derived** by matching live values, never stored (Orbitals `currentHarmonic`).
public struct Experiment: Sendable, Identifiable {
  public var id: String
  /// Sentence case, ≤ 22 characters ("Oobleck punch").
  public var title: String
  /// ≤ 48 characters, numbers welcome ("Shake 17 g at 120 Hz").
  public var subtitle: String
  public var icon: String
  /// 1–2 sentences, shown in a 6.5 s banner after applying, and in the info sheet.
  public var note: String
  /// Unspecified ids keep their value.
  public var values: [ParamID: Double]
  /// A data-hue id, if the experiment selects a material or source.
  public var material: String?
  public var effects: ExperimentEffects
  public var sources: [Citation]
  public var provenance: Provenance

  public init(
    _ id: String, title: String, subtitle: String, icon: String, note: String, values: [ParamID: Double],
    material: String? = nil, effects: ExperimentEffects = [], sources: [Citation] = [],
    provenance: Provenance = .modelled
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.note = note
    self.values = values
    self.material = material
    self.effects = effects
    self.sources = sources
    self.provenance = provenance
  }

  /// True when every value this experiment sets equals `values` (relative 1e-9) and its material, if any, matches.
  public func matches(_ values: ParamValues, material: String?) -> Bool {
    if let m = self.material, m != material { return false }
    return self.values.allSatisfy { id, v in
      guard let current = values.storage[id] else { return false }
      return abs(current - v) <= 1e-9 * max(1, abs(v))
    }
  }

  /// The first experiment whose values all match: editing any knob after applying reverts the menu label.
  public static func matching(_ values: ParamValues, material: String?, in all: [Experiment]) -> Experiment? {
    all.first { $0.matches(values, material: material) }
  }

  /// The effects every experiment in `all` shares: what the menu header can honestly promise.
  public static func commonEffects(_ all: [Experiment]) -> ExperimentEffects {
    guard let first = all.first else { return [] }
    return all.dropFirst().reduce(first.effects) { $0.intersection($1.effects) }
  }

  /// "Oobleck punch. Punch fast: …" for the VoiceOver announcement after applying.
  public var announcement: String { note.isEmpty ? title : "\(title). \(note)" }
}
