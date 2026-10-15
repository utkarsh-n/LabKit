import Foundation

/// Number formatting shared by readouts, knobs and plot labels (labkit-from-orbitals-spectra.md §2.5).
/// Locale-independent on purpose: readouts are instruments, and parity vectors compare strings.
/// Conventions: a normal space between number and unit, a middle dot inside compound units (Pa·s),
/// superscript exponents (s⁻¹), U+2212 for negatives, "×0.25" multipliers, "46%" without a space.
public enum LabFormat {
  /// The universal separator between quantities in one line (Orbitals).
  public static let separator = " · "

  /// Fixed fraction digits, clamped to 0…6. Never "−0.00"; U+2212 for negatives; "—" when not finite.
  public static func fixed(_ v: Double, precision: Int) -> String {
    guard v.isFinite else { return "—" }
    let digits = min(6, max(0, precision))
    let s = String(format: "%.\(digits)f", v)
    if let d = Double(s), d == 0 { return String(format: "%.\(digits)f", 0.0) }
    return minus(s)
  }

  /// Three significant figures (spectra-lab `sig3`): ≥ 100 → 0 dp, ≥ 10 → 1 dp, ≥ 1 → 2 dp, else 3 s.f.
  public static func sig3(_ x: Double) -> String {
    guard x.isFinite else { return "—" }
    let a = abs(x)
    if a == 0 { return "0" }
    if a >= 99.95 { return minus(String(format: "%.0f", x)) }
    if a >= 9.995 { return minus(String(format: "%.1f", x)) }
    if a >= 0.9995 { return minus(String(format: "%.2f", x)) }
    let e = Int(floor(log10(a)))
    return minus(String(format: "%.\(max(0, 2 - e))f", x))
  }

  /// `"1.23×10⁻⁴ s"` (spectra-lab `sci`).
  public static func scientific(_ v: Double, unit: String = "", digits: Int = 2) -> String {
    guard v.isFinite else { return "—" }
    if v == 0 { return unit.isEmpty ? "0" : "0 \(unit)" }
    var e = Int(floor(log10(abs(v))))
    var m = v / pow(10, Double(e))
    // 9.999 rounds to "10.00": renormalise.
    if abs((m * pow(10, Double(digits))).rounded()) >= 10 * pow(10, Double(digits)) {
      e += 1
      m = v / pow(10, Double(e))
    }
    let s = "\(minus(String(format: "%.\(max(0, digits))f", m)))×10\(superscript(e))"
    return unit.isEmpty ? s : "\(s) \(unit)"
  }

  /// SI prefix with three significant figures: `"12.4 mPa·s"`, `"2.45 GHz"`, `"300 Hz"`.
  /// Falls back to `scientific` outside 10⁻¹⁵…10²¹.
  ///
  /// A prefix binds to the first unit symbol **with its exponent** ("ms⁻¹" is per millisecond, 1000 s⁻¹),
  /// so a unit whose first factor is a reciprocal takes no prefix: 0.32 s⁻¹ is `"0.320 s⁻¹"`, never
  /// `"320 ms⁻¹"`; outside 10⁻³…10⁶ it falls back to `scientific` ("3.20×10⁻⁵ s⁻¹").
  public static func engineering(_ v: Double, unit: String) -> String {
    guard v.isFinite else { return "—" }
    if v == 0 { return unit.isEmpty ? "0" : "0 \(unit)" }
    let a = abs(v)
    if !takesPrefix(unit) {
      guard a >= 1e-3, a < 1e6 else { return scientific(v, unit: unit) }
      return "\(sig3(v)) \(unit)"
    }
    if a >= 1e21 || a < 1e-15 { return scientific(v, unit: unit) }
    for (p, s) in prefixes where a >= s * 0.9995 {
      let body = sig3(v / s)
      let u = p + unit
      return u.isEmpty ? body : "\(body) \(u)"
    }
    return scientific(v, unit: unit)
  }

  /// False when the unit's first factor (before any "·" or "/") carries a negative exponent ("s⁻¹",
  /// "m⁻²·s"): an SI prefix there would scale the reciprocal, not the number.
  static func takesPrefix(_ unit: String) -> Bool {
    guard let first = unit.split(whereSeparator: { $0 == "·" || $0 == "/" }).first else { return true }
    return !first.contains("⁻")
  }

  static let prefixes: [(String, Double)] = [
    ("E", 1e18), ("P", 1e15), ("T", 1e12), ("G", 1e9), ("M", 1e6), ("k", 1e3), ("", 1),
    ("m", 1e-3), ("µ", 1e-6), ("n", 1e-9), ("p", 1e-12), ("f", 1e-15),
  ]

  /// `"10⁻³"`, for log-axis labels.
  public static func powerOfTen(_ exponent: Int) -> String { "10" + superscript(exponent) }

  public static func superscript(_ n: Int) -> String {
    String(String(n).map { superscripts[$0] ?? $0 })
  }

  /// Uppercases Latin letters only, so quantity symbols survive UPPERCASE labels: "η viscosity" →
  /// "η VISCOSITY", never "Η VISCOSITY"; "µT" keeps its micro sign (§2.5, §7.2).
  public static func uppercasedLatin(_ s: String) -> String {
    var out = ""
    for ch in s {
      if ch.isLetter, ch != "µ", ch.unicodeScalars.allSatisfy({ $0.value < 0x0250 }) {
        out += ch.uppercased()
      } else {
        out.append(ch)
      }
    }
    return out
  }

  /// Typographic minus (U+2212). VoiceOver reads it as "minus".
  public static func minus(_ s: String) -> String { s.hasPrefix("-") ? "\u{2212}" + s.dropFirst() : s }

  // MARK: Spoken forms (§4.2 rule 3)

  /// A display string as VoiceOver should say it. Superscript exponents become "to the n", a
  /// negative exponent on a unit becomes "per …", "·" becomes a space, "×" becomes "times",
  /// U+2212 becomes "minus", and known SI units become words ("mPa·s" → "millipascal seconds",
  /// "°C" → "degrees Celsius"). Unknown text passes through with the symbol rules applied.
  ///
  ///     spoken("3.20 s⁻¹")       == "3.20 per second"
  ///     spoken("1.23×10⁻⁴ s")    == "1.23 times 10 to the minus 4 seconds"
  ///     spoken("×0.25")          == "times 0.25"
  public static func spoken(_ text: String) -> String {
    var words: [String] = []
    for token in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
      words.append(spokenToken(token))
    }
    return words.joined(separator: " ")
  }

  private static func spokenToken(_ token: String) -> String {
    if token == "·" { return "" }
    // Mantissa×10ⁿ
    if let r = token.range(of: "×10"), let next = token[r.upperBound...].first,
      next == "⁻" || superscriptDigits[next] != nil
    {
      let head = String(token[..<r.lowerBound])
      let exp = String(token[r.upperBound...])
      let lead = head.isEmpty ? "times" : "\(spokenNumber(head)) times"
      return "\(lead) 10 to the \(spokenExponent(exp))"
    }
    if token.hasPrefix("×") { return "times " + spokenNumber(String(token.dropFirst())) }
    if token.hasSuffix("%"), Double(token.dropLast().replacingOccurrences(of: "\u{2212}", with: "-")) != nil {
      return spokenNumber(String(token.dropLast())) + " percent"
    }
    if Double(token.replacingOccurrences(of: "\u{2212}", with: "-")) != nil { return spokenNumber(token) }
    return spokenUnit(token)
  }

  private static func spokenNumber(_ s: String) -> String {
    s.hasPrefix("\u{2212}") ? "minus " + s.dropFirst() : s
  }

  private static func spokenExponent(_ sup: String) -> String {
    var out = ""
    for ch in sup {
      if ch == "⁻" { out += "minus " } else if let d = superscriptDigits[ch] { out.append(d) } else if ch == "ⁿ" {
        out += "n"
      } else { out.append(ch) }
    }
    return out
  }

  /// "Pa·s" → "pascal seconds"; "s⁻¹" → "per second"; "mPa·sⁿ" → "millipascal seconds to the n".
  static func spokenUnit(_ unit: String) -> String {
    if let w = unitWords[unit] { return w }
    // Split a trailing superscript exponent off the whole unit ("s⁻¹", "Pa·sⁿ", "m²").
    var base = unit
    var exp = ""
    while let last = base.last, superscriptDigits[last] != nil || last == "⁻" || last == "ⁿ" {
      exp = String(last) + exp
      base.removeLast()
    }
    if !exp.isEmpty, !base.isEmpty {
      let b = spokenUnit(base)
      if exp == "⁻¹" { return "per " + singular(b) }
      if exp.hasPrefix("⁻") { return "per \(singular(b)) to the \(spokenExponent(String(exp.dropFirst())))" }
      if exp == "²" { return "square " + b }
      return "\(b) to the \(spokenExponent(exp))"
    }
    // Compound unit with "·": speak each factor.
    if unit.contains("·") {
      let parts = unit.split(separator: "·").map { spokenUnit(String($0)) }
      // "pascal seconds": every factor but the last is singular.
      return parts.enumerated().map { $0.offset < parts.count - 1 ? singular($0.element) : $0.element }.joined(
        separator: " ")
    }
    if unit.contains("/") {
      let parts = unit.split(separator: "/", maxSplits: 1).map { spokenUnit(String($0)) }
      if parts.count == 2 { return "\(parts[0]) per \(singular(parts[1]))" }
    }
    // SI prefix + known base.
    if let first = unit.first, unit.count > 1, let p = prefixWords[first], let w = unitWords[String(unit.dropFirst())] {
      return p + w
    }
    return unit.replacingOccurrences(of: "·", with: " ")
  }

  /// "millipascals" → "millipascal": the first factors of a compound unit are singular ("pascal seconds").
  private static func singular(_ w: String) -> String {
    for plural in ["pascals", "seconds", "metres", "revolutions", "amperes", "grams", "newtons", "joules", "watts", "volts"]
    where w.hasSuffix(plural) {
      return String(w.dropLast())
    }
    return w
  }

  static let unitWords: [String: String] = [
    "Pa": "pascals", "s": "seconds", "Hz": "hertz", "m": "metres", "mm": "millimetres", "g": "g",
    "°C": "degrees Celsius", "K": "kelvin", "T": "tesla", "A": "amperes", "kg": "kilograms", "rev": "revolutions",
    "N": "newtons", "J": "joules", "W": "watts", "V": "volts", "%": "percent", "°": "degrees", "dBFS": "decibels full scale",
    "dB": "decibels", "rpm": "revolutions per minute", "s⁻¹": "per second", "Pa·s": "pascal seconds",
  ]
  static let prefixWords: [Character: String] = [
    "E": "exa", "P": "peta", "T": "tera", "G": "giga", "M": "mega", "k": "kilo", "m": "milli", "µ": "micro",
    "μ": "micro", "n": "nano", "p": "pico", "f": "femto",
  ]
  static let superscripts: [Character: Character] = [
    "-": "⁻", "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
  ]
  static let superscriptDigits: [Character: Character] = [
    "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
  ]
}
