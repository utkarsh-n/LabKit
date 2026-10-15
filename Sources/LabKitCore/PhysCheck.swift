import Foundation

/// The physcheck harness shape (Tools/physcheck/main.swift:6-10, 198-199), as a reusable type:
/// print PASS/FAIL lines with a measured-vs-theory detail and exit non-zero on any failure.
public struct PhysCheck {
  public private(set) var failures = 0
  public private(set) var results: [(name: String, ok: Bool, detail: String)] = []
  public init() {}

  public mutating func check(_ name: String, _ ok: Bool, _ detail: String) {
    print((ok ? "PASS  " : "FAIL  ") + name + " — " + detail)
    results.append((name, ok, detail))
    if !ok { failures += 1 }
  }

  /// Relative-error check: |measured − theory| / |theory| < tolerance.
  public mutating func near(_ name: String, measured: Double, theory: Double, tolerance: Double, unit: String = "") {
    let err = abs(measured - theory) / max(abs(theory), 1e-300)
    check(
      name, err < tolerance,
      String(format: "measured %.6g%@, theory %.6g%@ (err %.3f%%)", measured, unit, theory, unit, err * 100))
  }

  /// Wall-clock cost of `body`, ms per call.
  public static func cost(iterations: Int, _ body: () -> Void) -> Double {
    let t0 = Date()
    for _ in 0..<iterations { body() }
    return Date().timeIntervalSince(t0) * 1000 / Double(iterations)
  }

  public func finish() -> Never {
    print(failures == 0 ? "\nAll physics checks passed." : "\n\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
  }
}
