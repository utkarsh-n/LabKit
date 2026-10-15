import Foundation
import Observation
import simd

// Parameters: identity, colour token, detents, formats, the knob spec and the observable store.
// Gyre's KnobSpec (Model/Knobs.swift:54-104) with the changes in labkit-from-orbitals-spectra.md §1.3
// (#1–#8): `icon` instead of `symbol`, an optional palette-resolved `tint`, `ParamFormat` instead of
// closures, lower-bound quantisation, provenance, nudges, and a re-registration clamp.

/// A parameter's stable identity. String-backed so specs, modulation routes, presets and UI can
/// all name a parameter without generics or key paths. Apps declare theirs as static members:
///     extension ParamID { static let gravity: ParamID = "gravity" }
public struct ParamID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible,
  Comparable
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ raw: String) { self.rawValue = raw }
  public init(stringLiteral value: String) { self.rawValue = value }
  public var description: String { rawValue }
  public static func < (a: ParamID, b: ParamID) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Colour token

/// One colour token, stored as **gamma-encoded sRGB** components in 0…1: exactly the numbers the
/// apps pass to `Color(red:green:blue:)`. Metal code never reuses these numbers directly; it takes
/// `linearSRGB` or `linearDisplayP3` (labkit-from-orbitals-spectra.md §2.4). LabKitUI adds
/// `Color(_:opacity:)` and `.color`; LabKitRender adds `.f3`.
public struct LabColor: Sendable, Hashable, Codable {
  public var r: Double, g: Double, b: Double

  public init(_ r: Double, _ g: Double, _ b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }

  /// `"#RRGGBB"` or `"RRGGBB"`, as spectra-lab writes its CSS tokens. Malformed input gives black.
  public init(hex: String) {
    let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let v = s.count == 6 ? (UInt32(s, radix: 16) ?? 0) : 0
    self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
  }

  /// `"#RRGGBB"`, rounded to the nearest 8-bit step.
  public var hex: String {
    func byte(_ c: Double) -> Int { Int((clamped(c.isFinite ? c : 0, 0, 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
  }

  /// sRGB electro-optical transfer function (IEC 61966-2-1): encoded → linear light.
  @inlinable public static func decode(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  /// Inverse transfer function: linear light → encoded.
  @inlinable public static func encode(_ v: Double) -> Double {
    v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
  }

  /// Linear-light sRGB, for an `.rgba16Float` target tagged `extendedLinearSRGB`.
  public var linearSRGB: SIMD3<Float> { SIMD3(Float(Self.decode(r)), Float(Self.decode(g)), Float(Self.decode(b))) }

  /// Linear-light Display P3 (D65), for LabKit's `extendedLinearDisplayP3` drawable.
  /// Matrix linear sRGB → XYZ → linear P3, computed from the primaries (§2.4).
  public var linearDisplayP3: SIMD3<Float> { Self.sRGBToDisplayP3 * linearSRGB }

  /// Linear sRGB → linear Display P3, by columns (rows 0.822462 0.177538 0 / 0.033194 0.966806 0 / 0.017083 0.072397
  /// 0.910520). Built once: `simd_float3x3(rows: [...])` in the getter allocated an array on every call (LK-FIX).
  static let sRGBToDisplayP3 = simd_float3x3(columns: (
    SIMD3(0.822462, 0.033194, 0.017083),
    SIMD3(0.177538, 0.966806, 0.072397),
    SIMD3(0, 0, 0.910520)))

  /// WCAG 2.x relative luminance.
  public var luminance: Double { 0.2126 * Self.decode(r) + 0.7152 * Self.decode(g) + 0.0722 * Self.decode(b) }

  /// WCAG 2.x contrast ratio, 1…21.
  public func contrast(against other: LabColor) -> Double {
    let a = luminance, b = other.luminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// Source-over composite of this colour at `alpha` on `ground`, both gamma-encoded (how SwiftUI
  /// composites opacity on an sRGB layer). Use it to check text drawn at an opacity.
  public func over(_ ground: LabColor, alpha: Double) -> LabColor {
    LabColor(
      ground.r + alpha * (r - ground.r), ground.g + alpha * (g - ground.g), ground.b + alpha * (b - ground.b))
  }

  /// OKLab (Ottosson 2020), for "can these two hues be told apart" checks.
  public var oklab: SIMD3<Double> {
    let lr = Self.decode(r), lg = Self.decode(g), lb = Self.decode(b)
    let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
    let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
    let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
    return SIMD3(
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
  }

  /// Euclidean OKLab distance. About 0.02 is just noticeable; LabKit asks ≥ 0.10 between any
  /// parameter hue and any data hue of one app, and ≥ 0.08 between knobs on one console page.
  public func perceptualDistance(to other: LabColor) -> Double { simd_length(oklab - other.oklab) }

  /// The same hue scaled in linear light until its luminance is `target` (no-op when already darker).
  public func darkened(toLuminance target: Double) -> LabColor {
    let l = luminance
    guard l > target, l > 0 else { return self }
    let k = target / l
    return LabColor(Self.encode(Self.decode(r) * k), Self.encode(Self.decode(g) * k), Self.encode(Self.decode(b) * k))
  }

  public static let white = LabColor(1, 1, 1)
  public static let black = LabColor(0, 0, 0)
}

// MARK: - Detents, scale, provenance-free helpers

/// A labelled stop with physical meaning ("Moon", "Earth", "Ketchup").
public struct Detent: Sendable, Hashable, Codable {
  public var value: Double
  public var label: String
  public init(_ value: Double, _ label: String) {
    self.value = value
    self.label = label
  }
}

public enum ParamScale: Sendable, Hashable, Codable { case linear, logarithmic }

// MARK: - Format

/// How a knob's value turns into words (§3.3). Named cases are testable and give one formatting
/// style across apps; `.custom` is the escape hatch. Every case formats locale-independently.
public enum ParamFormat: Sendable {
  /// `"1.23 g"`; precision is fraction digits, clamped to 0…6 (Orbitals GlassControls.swift:372-376).
  case number(precision: Int, unit: String)
  /// `"×0.25"`
  case multiplier(precision: Int)
  /// `"46%"` of a 0…1 value
  case percent
  /// Three significant figures with an SI prefix: `"12.4 mPa·s"`.
  case si(unit: String)
  /// Rotary-switch position names, indexed by the rounded value.
  case labels([String])
  /// `word` at or below `threshold`, otherwise `then` ("Off", "None").
  indirect case off(threshold: Double, word: String, then: ParamFormat)
  case custom(@Sendable (Double) -> String)

  public func string(_ v: Double) -> String {
    switch self {
    case .number(let p, let unit):
      let s = LabFormat.fixed(v, precision: p)
      return unit.isEmpty ? s : (unit == "%" ? s + unit : "\(s) \(unit)")
    case .multiplier(let p): return "×" + LabFormat.fixed(v, precision: p)
    case .percent: return v.isFinite ? "\(Int((v * 100).rounded()))%" : "—"
    case .si(let unit): return LabFormat.engineering(v, unit: unit)
    case .labels(let names):
      guard !names.isEmpty, v.isFinite else { return "" }
      return names[Int(clamped(v.rounded(), 0, Double(names.count - 1)))]
    case .off(let threshold, let word, let then): return v <= threshold ? word : then.string(v)
    case .custom(let f): return f(v)
    }
  }

  /// The same value as VoiceOver should say it ("12.4 millipascal seconds", "times 0.25").
  public func spoken(_ v: Double) -> String {
    switch self {
    case .labels: return string(v)
    case .percent: return v.isFinite ? "\(Int((v * 100).rounded())) percent" : "unknown"
    case .off(let threshold, let word, let then): return v <= threshold ? word : then.spoken(v)
    default: return LabFormat.spoken(string(v))
    }
  }
}

// MARK: - Spec

/// Range, mapping, quantisation, detents and copy of one parameter (§3.3).
public struct ParamSpec: Identifiable, Sendable {
  public let id: ParamID
  /// Sentence case, one or two words ("Flow index").
  public var title: String
  /// SF Symbol for the puck, readout card and info sheet. Check it against CoreGlyphs'
  /// `name_availability.plist` (`magnet` and `spoon` do not exist). Prototype name: `symbol`.
  public var icon: String
  /// An override. `nil` resolves through `LabPalette.hue(for: id)` (palette table, then the shared
  /// cross-app hues, then the signature), which is what keeps hue identity consistent.
  public var tint: LabColor?
  public var range: ClosedRange<Double>
  public var defaultValue: Double
  public var scale: ParamScale
  /// Where the lit arc starts; bipolar knobs light from their zero (Gravity −1…3 → 0).
  public var origin: Double?
  public var detents: [Detent]
  /// 0 = continuous. Values quantise to `lower + k·step`. `step ≥ 1` on an integer range is a rotary switch.
  public var step: Double
  public var format: ParamFormat
  /// ≤ 110 characters, shown in the floating readout while turning, and as the VoiceOver hint.
  public var hint: String
  /// A paragraph for the info sheet.
  public var detail: String
  /// Quantity symbol, serif italic ("n", "τ_y", "λ"); one `_` marks a subscript. Never case-transformed.
  public var glyph: String?
  /// What VoiceOver says for the glyph ("tau y", "lambda").
  public var glyphSpoken: String
  /// ≤ 36 characters, under the title on card knobs.
  public var descriptor: String
  public var provenance: Provenance

  public init(
    _ id: ParamID, title: String, icon: String, tint: LabColor? = nil,
    range: ClosedRange<Double>, defaultValue: Double, scale: ParamScale = .linear,
    origin: Double? = nil, detents: [Detent] = [], step: Double = 0,
    hint: String, detail: String = "", glyph: String? = nil, glyphSpoken: String = "",
    descriptor: String = "", provenance: Provenance = .modelled, format: ParamFormat
  ) {
    precondition(range.upperBound > range.lowerBound, "ParamSpec \(id): empty range")
    precondition(range.lowerBound.isFinite && range.upperBound.isFinite, "ParamSpec \(id): the range must be finite")
    precondition(scale == .linear || range.lowerBound > 0, "ParamSpec \(id): a log scale needs a positive range")
    self.id = id
    self.title = title
    self.icon = icon
    self.tint = tint
    self.range = range
    // A NaN default would survive min/max and then leak out of `clamp` (which falls back to it).
    self.defaultValue = defaultValue.isFinite ? min(max(defaultValue, range.lowerBound), range.upperBound) : range.lowerBound
    self.scale = scale
    self.origin = origin
    self.detents = detents
    self.step = step.isFinite ? max(0, step) : 0
    self.format = format
    self.hint = hint
    self.detail = detail
    self.glyph = glyph
    self.glyphSpoken = glyphSpoken
    self.descriptor = descriptor
    self.provenance = provenance
  }

  /// The prototype's initialiser (SF Symbol as `symbol`, closure format). Kept so seed code compiles.
  @available(*, deprecated, message: "Use init(_:title:icon:…format: ParamFormat)")
  public init(
    _ id: ParamID, title: String, symbol: String, tint: LabColor,
    range: ClosedRange<Double>, defaultValue: Double, scale: ParamScale = .linear,
    origin: Double? = nil, detents: [Detent] = [], step: Double = 0,
    hint: String, detail: String, glyph: String? = nil,
    format: @escaping @Sendable (Double) -> String
  ) {
    self.init(
      id, title: title, icon: symbol, tint: tint, range: range, defaultValue: defaultValue, scale: scale,
      origin: origin, detents: detents, step: step, hint: hint, detail: detail, glyph: glyph, format: .custom(format))
  }

  /// A rotary switch: whole-number positions, each a click, each named (§3.5: `step ≥ 1`, an integer
  /// range **and** `format: .labels([...])`). A whole-number knob with a unit (Heat 0–90 °C step 1,
  /// Magnet 0–500 mT step 1) stays a continuous knob: its labelled detents capture, VoiceOver nudges
  /// follow the §3.3 table, and it keeps its precision slider (as a switch, Magnet would draw 501
  /// position dots, skip its "1 cm away" detent and take 500 VoiceOver swipes to cross).
  public var isSwitch: Bool {
    guard step >= 1, case .labels = format else { return false }
    return true
  }
  /// Number of switch positions (0 for continuous knobs).
  public var switchCount: Int { isSwitch ? Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1 : 0 }

  /// Value → 0…1 along the sweep. Non-finite input maps to 0.
  public func position(of value: Double) -> Double {
    guard value.isFinite else { return 0 }
    let v = clamp(value)
    if scale == .logarithmic { return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound) }
    return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
  }

  /// 0…1 → value, then quantised. Inverse of `position(of:)` for continuous specs.
  public func value(at position: Double) -> Double {
    let p = position.isFinite ? clamped(position, 0, 1) : 0
    let raw =
      scale == .logarithmic
      ? range.lowerBound * pow(range.upperBound / range.lowerBound, p)
      : range.lowerBound + p * (range.upperBound - range.lowerBound)
    return quantised(raw)
  }

  /// `lower + round((v − lower)/step)·step`, clamped. Anchored at the lower bound (Orbitals
  /// `quantized`, GlassControls.swift:365-370), so a range like 0.25…3 with step 0.1 reaches both ends.
  /// Non-finite input gives the lower bound.
  public func quantised(_ v: Double) -> Double {
    guard v.isFinite else { return range.lowerBound }
    var q = v
    if step > 0 {
      q = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step
      // Kill binary noise (0.1 + 7·0.1 = 0.7999999…) so formatted values and detent lookups stay exact.
      let digits = max(0, min(12, Int(ceil(-log10(step))) + 3))
      let k = pow(10, Double(digits))
      q = (q * k).rounded() / k
    }
    return clamp(q)
  }

  /// Clamped into the range; non-finite gives the default value.
  public func clamp(_ v: Double) -> Double {
    guard v.isFinite else { return defaultValue }
    return min(max(v, range.lowerBound), range.upperBound)
  }

  public var originPosition: Double { position(of: origin ?? range.lowerBound) }

  /// The detent the value sits on, within 0.004 of the sweep (Gyre Knobs.swift:97-99).
  public func detent(at value: Double) -> Detent? {
    let p = position(of: value)
    return detents.first { abs(position(of: $0.value) - p) < 0.004 }
  }

  /// While dragging, the nearest detent within `radius` of the sweep pulls the value in (Gyre GlassKnob.swift:120).
  public func capture(near position: Double, radius: Double = 0.02) -> Detent? {
    var best: (Detent, Double)?
    for d in detents {
      let dist = abs(self.position(of: d.value) - position)
      if dist < radius, dist < (best?.1 ?? .infinity) { best = (d, dist) }
    }
    return best?.0
  }

  /// One VoiceOver swipe, arrow key or ± step (§3.3 nudge table). Switches move one position (Shift: 5);
  /// specs with at most 100 steps move one step (Shift: 5); others move 1/20 of the sweep in position
  /// space (Shift: 1/4), so a log knob moves by a constant ratio. A nudge stops on any labelled detent
  /// it would cross. At a limit it returns the value unchanged (the caller plays `.boundary`).
  public func nudged(_ value: Double, by direction: Int, coarse: Bool = false) -> Double {
    let dir = Double(direction.signum())
    guard dir != 0 else { return value }
    let current = clamp(value)
    if isSwitch { return quantised(current + dir * (coarse ? 5 : 1) * step) }
    let target: Double
    if step > 0, (range.upperBound - range.lowerBound) / step <= 100 + 1e-9 {
      target = quantised(current + dir * (coarse ? 5 : 1) * step)
    } else {
      target = self.value(at: position(of: current) + dir * (coarse ? 0.25 : 0.05))
    }
    return stopAtDetent(from: current, to: target)
  }

  private func stopAtDetent(from a: Double, to b: Double) -> Double {
    let pa = position(of: a), pb = position(of: b)
    let crossed = detents.filter {
      let p = position(of: $0.value)
      return pb > pa ? (p > pa + 1e-9 && p < pb - 1e-9) : (p < pa - 1e-9 && p > pb + 1e-9)
    }
    guard let first = crossed.min(by: { abs(position(of: $0.value) - pa) < abs(position(of: $1.value) - pa) }) else {
      return b
    }
    return first.value
  }

  /// The formatted value ("1.00 g").
  public func formatted(_ value: Double) -> String { format.string(value) }

  /// What VoiceOver reads: the spoken value, then the detent name when the value sits on one
  /// ("1.00 g, Earth"; "13.6 millipascal seconds to the n"). Switches read their label.
  public func accessibilityValue(_ value: Double) -> String {
    let base = format.spoken(value)
    guard !isSwitch, let d = detent(at: value), d.label != format.string(value), d.label != base else { return base }
    return "\(base), \(d.label)"
  }

  /// "Viscosity, eta" when the glyph has a spoken name, else the title.
  public var accessibilityLabel: String { glyphSpoken.isEmpty ? title : "\(title), \(glyphSpoken)" }
}

// MARK: - Values

/// A frame's worth of parameter values: a cheap Sendable copy the engine reads and modulates.
public struct ParamValues: Sendable, Equatable {
  public var storage: [ParamID: Double]
  public init(_ storage: [ParamID: Double] = [:]) { self.storage = storage }
  public subscript(id: ParamID) -> Double {
    get { storage[id] ?? 0 }
    set { storage[id] = newValue }
  }
  /// Rotary-switch position as an enum. A non-finite or out-of-range value (a modulated snapshot gone
  /// bad) gives the default instead of trapping in `Int(_:)`.
  public func choice<E: RawRepresentable>(_ id: ParamID, as _: E.Type, default d: E) -> E where E.RawValue == Int {
    let v = self[id].rounded()
    guard v.isFinite, abs(v) < 1e15 else { return d }
    return E(rawValue: Int(v)) ?? d
  }
}

// MARK: - Store

/// The user-facing knob values: the only parameter state SwiftUI observes. The engine takes a
/// `snapshot()` once per frame (outside any observation scope) and modulates the copy.
///
/// Observation is **per parameter**: a view that reads `store[.gravity]` is invalidated by writes to
/// Gravity only, not by every knob in the store (each value lives in its own observable cell). Turning
/// one knob therefore redraws that knob and whatever reads it, not the whole console and top bar.
@MainActor @Observable
public final class ParamStore {
  public private(set) var specs: [ParamID: ParamSpec] = [:]
  public private(set) var order: [ParamID] = []
  /// One observable cell per registered id. The dictionary itself changes only when an id is first
  /// registered; value writes mutate the cell, so they notify only that cell's readers.
  private var cells: [ParamID: ParamCell] = [:]

  public init(_ specs: [ParamSpec] = []) { register(specs) }

  /// Adds or replaces specs. A re-registered spec keeps its stored value **clamped into the new
  /// range** (§1.3 #8: Rheo swaps Heat's range for lava). With `adoptDefaults`, values reset to the
  /// new specs' defaults instead (a material change that should restore that material's knobs).
  public func register(_ list: [ParamSpec], adoptDefaults: Bool = false) {
    for s in list {
      if specs[s.id] == nil { order.append(s.id) }
      specs[s.id] = s
      let next = adoptDefaults ? s.defaultValue : s.clamp(cells[s.id]?.value ?? s.defaultValue)
      write(s.id, next)
    }
  }

  /// Stores `v` in `id`'s cell, creating the cell on first use. Equal values are not written, so
  /// re-registering or re-applying the same value notifies nobody.
  private func write(_ id: ParamID, _ v: Double) {
    if let cell = cells[id] {
      if cell.value != v { cell.value = v }
    } else {
      cells[id] = ParamCell(v)
    }
  }

  public func contains(_ id: ParamID) -> Bool { specs[id] != nil }

  public func spec(_ id: ParamID) -> ParamSpec {
    guard let s = specs[id] else { preconditionFailure("Unregistered ParamID \(id)") }
    return s
  }

  /// Get: the stored value (or the default). Set: clamped into range; non-finite writes are ignored.
  public subscript(id: ParamID) -> Double {
    get { cells[id]?.value ?? specs[id]?.defaultValue ?? 0 }
    set {
      guard newValue.isFinite else { return }
      write(id, specs[id]?.clamp(newValue) ?? newValue)
    }
  }

  public func isDefault(_ id: ParamID) -> Bool {
    guard let s = specs[id] else { return true }
    return abs(self[id] - s.defaultValue) <= 1e-12 * max(1, abs(s.defaultValue))
  }

  public func reset(_ ids: [ParamID]) {
    for id in ids { if let s = specs[id] { write(id, s.defaultValue) } }
  }

  public func resetAll() { reset(order) }

  /// Writes a preset (clamped). Ids that are not registered are stored as given, so presets may
  /// carry values for specs registered later.
  public func apply(_ preset: [ParamID: Double]) {
    for (id, v) in preset { self[id] = v }
  }

  /// True when every value in `preset` equals the stored value (relative tolerance 1e-9).
  public func matches(_ preset: [ParamID: Double]) -> Bool {
    preset.allSatisfy { id, v in abs(self[id] - v) <= 1e-9 * max(1, abs(v)) }
  }

  public func snapshot() -> ParamValues { ParamValues(cells.mapValues(\.value)) }

  /// The stored values of `ids` only (ids never written are left out, as in `snapshot()`). Inside a view
  /// body this observes just those parameters, so a derived label (the current experiment) doesn't
  /// redraw when an unrelated knob turns.
  public func snapshot(_ ids: some Sequence<ParamID>) -> ParamValues {
    var out = ParamValues()
    for id in ids { if let cell = cells[id] { out[id] = cell.value } }
    return out
  }
}

/// One parameter's value as its own observation scope (see `ParamStore`).
@MainActor @Observable
final class ParamCell {
  var value: Double
  init(_ value: Double) { self.value = value }
}

// MARK: - Console pages and knob focus (value types the UI and the model share)

/// One console page. Pages are data: by default a page's content is `KnobGrid(knobs)`.
public struct ConsolePage: Identifiable, Hashable, Sendable {
  public let id: String
  /// One word: "Fluid".
  public let title: String
  public var knobs: [ParamID]
  public init(_ id: String, title: String, knobs: [ParamID] = []) {
    self.id = id
    self.title = title
    self.knobs = knobs
  }
}

/// What the console shows above itself: nothing, the floating readout of a held knob, or the
/// precision tray of a long-pressed knob. One value, so a readout and a tray never show at once.
public enum KnobFocus: Equatable, Sendable {
  case none
  case held(ParamID)
  case precision(ParamID)

  public var id: ParamID? {
    switch self {
    case .none: nil
    case .held(let id), .precision(let id): id
    }
  }
}
