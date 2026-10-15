import Foundation

/// Physical size of a point, for drawing things life-size (labkit-from-orbitals-spectra.md §9.2).
/// iOS has no public physical-ppi API, so this is a model-identifier table:
/// mm per point = 25.4 × (physical pixels per point) / ppi, where pixels per point is the panel's
/// native scale (2.88 on the 12/13 mini, which downsample a 3× canvas). Unknown models give `nil`:
/// then an app hides its "LIFE-SIZE" tag and fits the scene instead.
public enum LabDisplay {
  /// iPhone 15 Pro Max (`iPhone16,2`): 460 ppi at 3 px/pt → 0.16565 mm per point.
  public static let referenceModel = "iPhone16,2"

  /// Millimetres per point for a model identifier ("iPhone16,2"), or nil when unknown.
  public static func millimetresPerPoint(modelIdentifier id: String) -> Double? {
    guard let panel = panels[id] else { return nil }
    return 25.4 * panel.pixelsPerPoint / panel.ppi
  }

  /// The running device's model identifier. In the Simulator this is the simulated model
  /// (`SIMULATOR_MODEL_IDENTIFIER`); on a Mac it is the machine name ("arm64"), which the table doesn't know.
  public static var currentModelIdentifier: String {
    if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return sim }
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// `millimetresPerPoint(modelIdentifier: currentModelIdentifier)`.
  public static var currentMillimetresPerPoint: Double? { millimetresPerPoint(modelIdentifier: currentModelIdentifier) }

  struct Panel: Sendable {
    let ppi: Double
    let pixelsPerPoint: Double
  }

  /// Apple's published ppi per model (iPhone 11 and later). All are 3× panels except the 2× LCD models and the minis.
  static let panels: [String: Panel] = [
    // iPhone 11 family
    "iPhone12,1": Panel(ppi: 326, pixelsPerPoint: 2),  // iPhone 11
    "iPhone12,3": Panel(ppi: 458, pixelsPerPoint: 3),  // iPhone 11 Pro
    "iPhone12,5": Panel(ppi: 458, pixelsPerPoint: 3),  // iPhone 11 Pro Max
    "iPhone12,8": Panel(ppi: 326, pixelsPerPoint: 2),  // iPhone SE (2nd generation)
    // iPhone 12 family
    "iPhone13,1": Panel(ppi: 476, pixelsPerPoint: 2.88),  // iPhone 12 mini (1080 px over 375 pt)
    "iPhone13,2": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 12
    "iPhone13,3": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 12 Pro
    "iPhone13,4": Panel(ppi: 458, pixelsPerPoint: 3),  // iPhone 12 Pro Max
    // iPhone 13 family and SE 3
    "iPhone14,4": Panel(ppi: 476, pixelsPerPoint: 2.88),  // iPhone 13 mini
    "iPhone14,5": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 13
    "iPhone14,2": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 13 Pro
    "iPhone14,3": Panel(ppi: 458, pixelsPerPoint: 3),  // iPhone 13 Pro Max
    "iPhone14,6": Panel(ppi: 326, pixelsPerPoint: 2),  // iPhone SE (3rd generation)
    // iPhone 14 family
    "iPhone14,7": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 14
    "iPhone14,8": Panel(ppi: 458, pixelsPerPoint: 3),  // iPhone 14 Plus
    "iPhone15,2": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 14 Pro
    "iPhone15,3": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 14 Pro Max
    // iPhone 15 family
    "iPhone15,4": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 15
    "iPhone15,5": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 15 Plus
    "iPhone16,1": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 15 Pro
    "iPhone16,2": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 15 Pro Max (the reference device)
    // iPhone 16 family
    "iPhone17,1": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 16 Pro
    "iPhone17,2": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 16 Pro Max
    "iPhone17,3": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 16
    "iPhone17,4": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 16 Plus
    "iPhone17,5": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 16e
    // iPhone 17 family. Every identifier in this table was checked against the CoreSimulator device-type
    // profiles (Xcode 27 beta); ppi values are Apple's published specs. iPhone 17e (iPhone18,5) is left out: ppi unchecked.
    "iPhone18,1": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 17 Pro
    "iPhone18,2": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 17 Pro Max
    "iPhone18,3": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone 17
    "iPhone18,4": Panel(ppi: 460, pixelsPerPoint: 3),  // iPhone Air
  ]
}
