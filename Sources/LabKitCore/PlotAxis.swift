import Foundation

// Plot maths (labkit-from-orbitals-spectra.md §3.12): pure values, so instruments, tests and the
// VoiceOver chart descriptor share one source of truth. `LabPlot` (LabKitUI) draws them.

public struct PlotTick: Sendable, Hashable {
  public var value: Double
  /// 0…1 along the axis.
  public var position: Double
  public var isMajor: Bool
  /// nil for unlabelled ticks.
  public var label: String?
  public init(value: Double, position: Double, isMajor: Bool, label: String?) {
    self.value = value
    self.position = position
    self.isMajor = isMajor
    self.label = label
  }
}

/// One plot axis: linear or log10, with words, quantity symbol and unit.
public struct PlotAxis: Sendable, Hashable {
  public enum Scale: Sendable, Hashable { case linear, log10 }

  public var title: String
  public var symbol: String
  public var unit: String
  public var domain: ClosedRange<Double>
  public var scale: Scale

  public init(
    title: String, symbol: String = "", unit: String = "", domain: ClosedRange<Double>, scale: Scale = .linear
  ) {
    precondition(domain.upperBound > domain.lowerBound, "PlotAxis \(title): empty domain")
    precondition(scale == .linear || domain.lowerBound > 0, "PlotAxis \(title): a log axis needs a positive domain")
    self.title = title
    self.symbol = symbol
    self.unit = unit
    self.domain = domain
    self.scale = scale
  }

  /// "γ̇ (s⁻¹)"; with `long`, "Shear rate γ̇ (s⁻¹)".
  public func caption(long: Bool = false) -> String {
    let head = long ? [title, symbol].filter { !$0.isEmpty }.joined(separator: " ") : (symbol.isEmpty ? title : symbol)
    return unit.isEmpty ? head : "\(head) (\(unit))"
  }

  /// Value → 0…1. Outside the domain extrapolates (the view clips). nil for non-finite values and
  /// for values ≤ 0 on a log axis: those are never drawn.
  public func position(_ v: Double) -> Double? {
    guard v.isFinite else { return nil }
    switch scale {
    case .linear: return (v - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
    case .log10:
      guard v > 0 else { return nil }
      return (Foundation.log10(v) - Foundation.log10(domain.lowerBound))
        / (Foundation.log10(domain.upperBound) - Foundation.log10(domain.lowerBound))
    }
  }

  public func value(at p: Double) -> Double {
    switch scale {
    case .linear: return domain.lowerBound + p * (domain.upperBound - domain.lowerBound)
    case .log10:
      let lo = Foundation.log10(domain.lowerBound), hi = Foundation.log10(domain.upperBound)
      return pow(10, lo + p * (hi - lo))
    }
  }

  /// Decades spanned (0 on a linear axis).
  public var decades: Double {
    scale == .log10 ? Foundation.log10(domain.upperBound) - Foundation.log10(domain.lowerBound) : 0
  }

  /// Ticks for an axis `length` points long.
  /// - Log: a major tick at every decade; when crowded, only every n-th decade is labelled, so labels sit
  ///   at least `minSpacing` apart (the others keep an unlabelled major tick). Minor ticks at 2…9 × 10ᵏ only when every decade is labelled and a decade is at
  ///   least 2 × `minSpacing` long.
  /// - Linear: a 1-2-5 step giving at most `length / minSpacing` labels.
  public func ticks(length: Double, minSpacing: Double = 36) -> [PlotTick] {
    switch scale {
    case .log10: logTicks(length: length, minSpacing: minSpacing)
    case .linear: linearTicks(length: length, minSpacing: minSpacing)
    }
  }

  private func logTicks(length: Double, minSpacing: Double) -> [PlotTick] {
    let lo = Foundation.log10(domain.lowerBound), hi = Foundation.log10(domain.upperBound)
    let first = Int(ceil(lo - 1e-9)), last = Int(floor(hi + 1e-9))
    let perDecade = length / max(hi - lo, 1e-9)
    let every = max(1, Int(ceil(minSpacing / max(perDecade, 1e-9) - 1e-9)))
    var ticks: [PlotTick] = []
    for k in (first - 1)...max(first - 1, last) {
      let decade = pow(10, Double(k))
      // Every decade keeps its major tick (and grid line); a crowded axis only drops labels.
      if k >= first, let p = position(decade) {
        let labelled = (k - first) % every == 0
        ticks.append(PlotTick(value: decade, position: p, isMajor: true, label: labelled ? Self.decadeLabel(k) : nil))
      }
      if every == 1, perDecade >= 2 * minSpacing {
        for m in 2...9 {
          let v = Double(m) * decade
          if v > domain.lowerBound * (1 + 1e-12), v < domain.upperBound * (1 - 1e-12), let p = position(v) {
            ticks.append(PlotTick(value: v, position: p, isMajor: false, label: nil))
          }
        }
      }
    }
    if !ticks.contains(where: { $0.label != nil }) {
      labelWithinDecade(&ticks, from: first - 1, to: max(first - 1, last), length: length, minSpacing: minSpacing)
    }
    return ticks.sorted { $0.value < $1.value }
  }

  /// An axis less than a decade wide (2…8, 20…90) holds no labelled decade: label 1-2-5 × 10ᵏ values at
  /// least `minSpacing` apart instead, or the two ends when not even those fit, so it never shows no numbers.
  private func labelWithinDecade(_ ticks: inout [PlotTick], from k0: Int, to k1: Int, length: Double, minSpacing: Double) {
    var chosen: [(Double, Double)] = []
    for k in k0...(k1 + 1) {
      for m in [1.0, 2, 5] {
        let v = m * pow(10, Double(k))
        guard v >= domain.lowerBound * (1 - 1e-12), v <= domain.upperBound * (1 + 1e-12), let p = position(v) else { continue }
        if let last = chosen.last, (p - last.1) * length < minSpacing { continue }
        chosen.append((v, p))
      }
    }
    if chosen.isEmpty, let p0 = position(domain.lowerBound), let p1 = position(domain.upperBound) {
      chosen = [(domain.lowerBound, p0)]
      if (p1 - p0) * length >= minSpacing { chosen.append((domain.upperBound, p1)) }
    }
    for (v, p) in chosen {
      let text = Self.plainLabel(v)
      if let i = ticks.firstIndex(where: { abs($0.value - v) <= 1e-9 * v }) {
        ticks[i].isMajor = true
        ticks[i].label = text
      } else {
        ticks.append(PlotTick(value: v, position: p, isMajor: true, label: text))
      }
    }
  }

  /// A positive tick value as short as it reads: "0.02", "20", "5000"; "2×10⁴" outside 10⁻³…10⁴.
  static func plainLabel(_ v: Double) -> String {
    let k = Int(floor(Foundation.log10(v) + 1e-9))
    if k < -3 || k > 3 { return LabFormat.scientific(v, digits: 0) }
    return LabFormat.minus(String(format: "%g", Double(String(format: "%.3g", v)) ?? v))
  }

  /// "0.01" … "1000" as decimals (at most four characters), else "10ᵏ" with a superscript ("10⁻³", "10⁴").
  public static func decadeLabel(_ k: Int) -> String {
    switch k {
    case -2: "0.01"
    case -1: "0.1"
    case 0: "1"
    case 1: "10"
    case 2: "100"
    case 3: "1000"
    default: LabFormat.powerOfTen(k)
    }
  }

  private func linearTicks(length: Double, minSpacing: Double) -> [PlotTick] {
    let span = domain.upperBound - domain.lowerBound
    let maxCount = max(1, Int(length / minSpacing))
    let rough = span / Double(maxCount)
    let mag = pow(10, floor(Foundation.log10(rough)))
    let step = [1.0, 2, 5, 10].map { $0 * mag }.first { $0 >= rough * (1 - 1e-9) } ?? 10 * mag
    let digits = max(0, -Int(floor(Foundation.log10(step) + 1e-9)))
    var ticks: [PlotTick] = []
    var i = ceil(domain.lowerBound / step - 1e-9)
    while i * step <= domain.upperBound + step * 1e-9 {
      let v = i * step
      if let p = position(v) {
        ticks.append(PlotTick(value: v, position: p, isMajor: true, label: LabFormat.fixed(v, precision: digits)))
      }
      i += 1
    }
    return ticks
  }
}

/// A sampled curve or point set in data space. Non-finite samples, and non-positive samples on a log
/// axis, break the line: gaps are drawn as gaps, never bridged.
public struct PlotSeries: Sendable, Identifiable {
  public enum Style: Sendable, Hashable {
    /// `glow` is the alpha of a 3.2 × wide under-stroke (spectra-lab `glowLine`), 0 for none.
    case line(width: Double, glow: Double, dash: [Double])
    /// `hollow` rings for measured points; filled dots with a halo for live points.
    case markers(diameter: Double, hollow: Bool)
  }
  public var id: String
  public var label: String
  public var colour: LabColor
  public var points: [SIMD2<Double>]
  public var style: Style
  public var provenance: Provenance
  /// 0…1, multiplies the series' colour (other materials drawn faint at 0.35).
  public var opacity: Double

  public init(
    id: String, label: String, colour: LabColor, points: [SIMD2<Double>], style: Style = .line(width: 2, glow: 0.22, dash: []),
    provenance: Provenance, opacity: Double = 1
  ) {
    self.id = id
    self.label = label
    self.colour = colour
    self.points = points
    self.style = style
    self.provenance = provenance
    self.opacity = opacity
  }

  /// Runs of consecutive drawable points in 0…1 plot space.
  public func runs(x: PlotAxis, y: PlotAxis) -> [[SIMD2<Double>]] {
    var runs: [[SIMD2<Double>]] = []
    var current: [SIMD2<Double>] = []
    for p in points {
      if let px = x.position(p.x), let py = y.position(p.y) {
        current.append(SIMD2(px, py))
      } else if !current.isEmpty {
        runs.append(current)
        current = []
      }
    }
    if !current.isEmpty { runs.append(current) }
    return runs
  }

  /// Samples `f` at `count` points spread evenly in plot space along `x` (log-spaced on a log axis).
  public static func sampled(
    id: String, label: String, colour: LabColor, x: PlotAxis, count: Int = 96, provenance: Provenance = .modelled,
    style: Style = .line(width: 2, glow: 0.22, dash: []), opacity: Double = 1, _ f: (Double) -> Double
  ) -> PlotSeries {
    let n = max(2, count)
    let pts = (0..<n).map { i -> SIMD2<Double> in
      let xv = x.value(at: Double(i) / Double(n - 1))
      return SIMD2(xv, f(xv))
    }
    return PlotSeries(id: id, label: label, colour: colour, points: pts, style: style, provenance: provenance, opacity: opacity)
  }
}

/// Reference lines drawn under the data.
public enum PlotGuide: Sendable, Hashable {
  /// y = prefactor · xᵉ: straight on log-log axes. Iso-viscosity lines on a flow curve are
  /// `powerLaw(prefactor: η, exponent: 1, …)`; a Newtonian fluid lies along one.
  case powerLaw(prefactor: Double, exponent: Double, label: String)
  case vertical(x: Double, label: String)
  /// A yield stress shows as a horizontal floor: `.horizontal(y: τ_y, label: "τ_y")`.
  case horizontal(y: Double, label: String)

  public var label: String {
    switch self {
    case .powerLaw(_, _, let l), .vertical(_, let l), .horizontal(_, let l): l
    }
  }

  /// The guide as a polyline in 0…1 plot space (`samples` points for a power law), clipped to points that exist.
  public func polyline(x: PlotAxis, y: PlotAxis, samples: Int = 48) -> [SIMD2<Double>] {
    switch self {
    case .powerLaw(let k, let n, _):
      return (0...max(1, samples)).compactMap { i in
        let xv = x.value(at: Double(i) / Double(max(1, samples)))
        guard let px = x.position(xv), let py = y.position(k * pow(xv, n)) else { return nil }
        return SIMD2(px, py)
      }
    case .vertical(let xv, _):
      guard let px = x.position(xv) else { return [] }
      return [SIMD2(px, 0), SIMD2(px, 1)]
    case .horizontal(let yv, _):
      guard let py = y.position(yv) else { return [] }
      return [SIMD2(0, py), SIMD2(1, py)]
    }
  }
}
