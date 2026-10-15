import Foundation

// Colour identity as values (labkit-from-orbitals-spectra.md §2.2–§2.4). Everything here is
// gamma-encoded sRGB (`LabColor`); renderers convert with `linearSRGB` / `linearDisplayP3`.
// Contrast and hue-distance rules are unit tests (LabKitCoreTests/PaletteTests.swift).

/// The neutral family an app sits on. Each app picks one. Values marked "source" are copied from an
/// existing app; the others are proposals that keep the ground's hue cast and meet the contrast floor.
public struct LabGround: Sendable, Hashable, Codable {
  public var name: String
  /// Full-bleed stage behind the Metal canvas.
  public var stage: LabColor
  /// Sheets, launch screen (the `LaunchBackground` asset).
  public var background: LabColor
  /// Opaque `InstrumentPanel` fill. Panels are never glass.
  public var panel: LabColor
  /// Inside plots.
  public var plot: LabColor
  /// Secondary text, panel titles, axis labels.
  public var muted: LabColor
  /// Tertiary text, minor tick labels, hints.
  public var dim: LabColor
  /// White opacity of panel hairlines (0.22 under Increase Contrast).
  public var hairlineAlpha: Double

  public init(
    name: String, stage: LabColor, background: LabColor, panel: LabColor, plot: LabColor, muted: LabColor,
    dim: LabColor, hairlineAlpha: Double = 0.07
  ) {
    self.name = name
    self.stage = stage
    self.background = background
    self.panel = panel
    self.plot = plot
    self.muted = muted
    self.dim = dim
    self.hairlineAlpha = hairlineAlpha
  }

  /// Orbitals / spectra-lab (source: OrbitTheme.swift:4-12, spectra.css:3-12, draw.js:3).
  public static let phosphor = LabGround(
    name: "phosphor", stage: LabColor(0.025, 0.045, 0.040), background: LabColor(0.025, 0.045, 0.040),
    panel: LabColor(0.065, 0.095, 0.083), plot: LabColor(hex: "#040807"),
    muted: LabColor(0.61, 0.71, 0.65), dim: LabColor(hex: "#7e978a"))

  /// Gyre and Rheo. Source: stage black (Gyre ContentView.swift:42), background = Gyre's
  /// `LaunchBackground` (0.006, 0.012, 0.030). Proposal: panel, plot, muted, dim.
  public static let abyss = LabGround(
    name: "abyss", stage: .black, background: LabColor(0.006, 0.012, 0.030),
    panel: LabColor(0.050, 0.060, 0.090), plot: LabColor(0.008, 0.014, 0.032),
    muted: LabColor(0.62, 0.68, 0.78), dim: LabColor(0.50, 0.56, 0.66))

  /// Tether. Source: TetherTheme.swift:4-5. Proposal: plot, muted, dim.
  public static let night = LabGround(
    name: "night", stage: LabColor(0.025, 0.031, 0.065), background: LabColor(0.025, 0.031, 0.065),
    panel: LabColor(0.065, 0.073, 0.130), plot: LabColor(0.015, 0.020, 0.045),
    muted: LabColor(0.64, 0.65, 0.80), dim: LabColor(0.52, 0.53, 0.68))

  public static let all: [LabGround] = [.phosphor, .abyss, .night]
}

/// Meanings that never change between apps (§2.3). A reader who learns "amber = modelled" in
/// Spectra must not see amber mean something else in Rheo.
public enum LabSemantic {
  /// RUN, live signal, level meter, **measured** and **live** provenance, canvas tags (OrbitTheme.phosphor).
  public static let live = LabColor(0.40, 0.96, 0.56)
  /// Default readout number, HOLD, **modelled** provenance, experiment menu (OrbitTheme.amber).
  public static let value = LabColor(1.00, 0.75, 0.37)
  /// Predicted paths and "what if" overlays (OrbitTheme.cyan).
  public static let forecast = LabColor(0.57, 0.89, 1.00)
  /// Limits, hard stops, thresholds (spectra-lab `--ionizing` #ff8f6b).
  public static let warning = LabColor(hex: "#ff8f6b")
  /// Values standing in for a sensor (systemOrange, dark appearance; Gyre TopBar.swift:147).
  public static let simulated = LabColor(1.00, 0.624, 0.039)
  public static let ink = LabColor.white
  /// White opacities for text on any ground.
  public static let bodyAlpha = 0.85  // field-note body (Orbitals TelemetryView.swift:181)
  public static let secondaryAlpha = 0.75  // card-knob descriptor (Orbitals GlassControls.swift:46)
  public static let tertiaryAlpha = 0.62  // compact knob title (Gyre GlassKnob.swift:28)
}

/// A data identity: a fluid, channel or source keeps its hue everywhere (tank, legend, chips).
public struct DataHue: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var name: String
  public var colour: LabColor
  public init(_ id: String, _ name: String, _ colour: LabColor) {
    self.id = id
    self.name = name
    self.colour = colour
  }
}

/// One app's colour identity (§2.4): a ground, **one** signature accent, parameter hues keyed by
/// `ParamID` and data hues keyed by id. Semantic colours are fixed across apps (`LabSemantic`).
public struct LabPalette: Sendable, Hashable {
  public var app: String
  public var ground: LabGround
  /// Global `.tint`, `AccentColor` asset, panel numbers, primary action, selected state. Nothing else.
  public var signature: LabColor
  /// App-specific knob hues. Shared quantities fall back to `sharedHues`.
  public var parameterHues: [ParamID: LabColor]
  /// Ordered: legend order.
  public var dataHues: [DataHue]

  public init(
    app: String, ground: LabGround, signature: LabColor, parameterHues: [ParamID: LabColor] = [:],
    dataHues: [DataHue] = []
  ) {
    self.app = app
    self.ground = ground
    self.signature = signature
    self.parameterHues = parameterHues
    self.dataHues = dataHues
  }

  /// Label colour on a filled signature surface (prominent buttons, selected chips): white when it
  /// reaches 4.5:1, otherwise the ground's background (§2.3; white on Rheo pink is 2.90:1).
  public var onSignature: LabColor { Self.onFill(signature, ground: ground) }

  /// The signature darkened in linear light, hue kept, until white reaches 4.5:1 (luminance 0.1833).
  /// Tint for **system-drawn** fills whose glyph LabKit can't colour: the sheet "Done" checkmark
  /// circle and `Toggle` tracks. Equals `signature` when white already reads on it.
  public var signatureDeep: LabColor { signature.darkened(toLuminance: 0.1833) }

  /// Text colour for a filled `fill`: white when it reaches 4.5:1, else the ground background.
  public static func onFill(_ fill: LabColor, ground: LabGround) -> LabColor {
    fill.contrast(against: .white) >= 4.5 ? .white : ground.background
  }

  /// `parameterHues[id] ?? sharedHues[id] ?? signature`.
  public func hue(for id: ParamID) -> LabColor { parameterHues[id] ?? Self.sharedHues[id] ?? signature }

  /// The data hue with this id, or the signature when the id is unknown.
  public func data(_ id: String) -> LabColor { dataHues.first { $0.id == id }?.colour ?? signature }

  /// Quantities that mean the same thing in every app keep one hue (Gyre Knobs.swift tints).
  /// A convention for identity across apps, not a distinctness guarantee (Listen and Scope are 0.015 apart).
  public static let sharedHues: [ParamID: LabColor] = [
    "gravity": LabColor(1.00, 0.70, 0.28), "time": LabColor(0.72, 0.55, 1.00),
    "magnet": LabColor(0.55, 1.00, 0.45), "listen": LabColor(0.35, 1.00, 0.60),
    "drives": LabColor(1.00, 0.62, 0.85), "gain": LabColor(0.45, 0.85, 1.00),
    "scope": LabColor(0.40, 1.00, 0.55), "air": LabColor(0.55, 0.75, 1.00),
  ]

  // MARK: Presets

  public static let orbitals = LabPalette(
    app: "Orbitals", ground: .phosphor, signature: LabSemantic.live,
    parameterHues: [
      "speed": LabColor(1.00, 0.69, 0.30), "amplitude": LabColor(0.38, 0.70, 1.00),
      "frequency": LabColor(0.35, 0.94, 0.69), "phase": LabColor(0.78, 0.60, 1.00),
    ],
    dataHues: [
      DataHue("a", "Cyan", LabColor(0.10, 0.93, 1.00)), DataHue("b", "Magenta", LabColor(1.00, 0.18, 0.78)),
      DataHue("c", "Yellow", LabColor(1.00, 0.91, 0.18)),
    ])

  /// Gyre: the 17 knob tints of Knobs.swift (labkit-from-gyre.md §4.1); data lives in the linear HoloPalette.
  public static let gyre = LabPalette(
    app: "Gyre", ground: .abyss, signature: LabColor(0.38, 0.88, 1.00),
    parameterHues: [
      "motor": LabColor(0.36, 0.86, 1.00), "inertia": LabColor(0.30, 1.00, 0.82),
      "gravity": LabColor(1.00, 0.70, 0.28), "balance": LabColor(1.00, 0.45, 0.62),
      "friction": LabColor(1.00, 0.50, 0.30), "air": LabColor(0.55, 0.75, 1.00),
      "magnet": LabColor(0.55, 1.00, 0.45), "time": LabColor(0.72, 0.55, 1.00),
      "listen": LabColor(0.35, 1.00, 0.60), "drives": LabColor(1.00, 0.62, 0.85),
      "gain": LabColor(0.45, 0.85, 1.00), "scope": LabColor(0.40, 1.00, 0.55),
      "visual": LabColor(1.00, 0.55, 0.40), "radio": LabColor(0.45, 0.70, 1.00),
      "frost": LabColor(0.80, 0.90, 1.00), "dispersion": LabColor(1.00, 0.55, 0.85),
      "refraction": LabColor(0.50, 0.85, 1.00),
    ])

  public static let tether = LabPalette(
    app: "Tether", ground: .night, signature: LabColor(0.67, 0.58, 1.00),
    dataHues: [
      DataHue("utkarsh", "Utkarsh", LabColor(0.50, 1.00, 0.83)),
      DataHue("partner", "Partner", LabColor(1.00, 0.62, 0.78)),
    ])

  /// Spectra (native port): phosphor ground, live signature; parameter hues from spectra-lab controls.js:131-137.
  /// Known clash to fix in the port: δ rose equals source B, and E₀ equals the E-field trace.
  public static let spectra = LabPalette(
    app: "Spectra", ground: .phosphor, signature: LabSemantic.live,
    parameterHues: [
      "amplitude": LabColor(hex: "#61b3ff"), "angle": LabColor(hex: "#59f0b0"),
      "phase": LabColor(hex: "#c799ff"), "delta": LabColor(hex: "#ff8fb8"),
    ],
    dataHues: [
      DataHue("a", "Source A", LabColor(hex: "#66f58f")), DataHue("b", "Source B", LabColor(hex: "#ff8fb8")),
      DataHue("c", "Source C", LabColor(hex: "#8fd3ff")),
    ])

  /// Rheo: slime-pink signature on Gyre's abyss ground (§2.4). Twenty knobs on five console pages plus
  /// two Rheometer card knobs. Rules (tests): page-mates ≥ 0.114 OKLab apart (rule 0.08), every parameter hue
  /// ≥ 0.10 from every fluid hue, the signature ≥ 0.10 from every parameter hue, every parameter hue
  /// ≥ 7:1 on the panel.
  public static let rheo = LabPalette(
    app: "Rheo", ground: .abyss, signature: LabColor(1.00, 0.35, 0.65),
    parameterHues: [
      // Fluid page
      "yield": LabColor(0.30, 1.00, 0.82), "consistency": LabColor(0.36, 0.86, 1.00),
      "index": LabColor(0.78, 0.60, 1.00), "packing": LabColor(1.00, 0.86, 0.35),
      // World page (gravity, magnet, time are the shared hues)
      "gravity": LabColor(1.00, 0.70, 0.28), "heat": LabColor(1.00, 0.50, 0.30),
      "magnet": LabColor(0.55, 1.00, 0.45), "time": LabColor(0.72, 0.55, 1.00),
      // Touch page
      "finger": LabColor(0.55, 0.90, 1.00), "stir": LabColor(0.82, 0.95, 0.40),
      "shake": LabColor(0.62, 0.62, 1.00), "rate": LabColor(1.00, 0.74, 0.58),
      // Signals page (listen, drives, gain are shared)
      "listen": LabColor(0.35, 1.00, 0.60), "drives": LabColor(1.00, 0.62, 0.85),
      "gain": LabColor(0.45, 0.85, 1.00), "band": LabColor(0.85, 0.80, 1.00),
      // View page
      "glow": LabColor(0.25, 0.95, 1.00), "grain": LabColor(0.95, 0.55, 1.00),
      "tracers": LabColor(0.72, 1.00, 0.25), "depth": LabColor(0.45, 0.60, 1.00),
      // Rheometer card knobs
      "memory": LabColor(1.00, 0.60, 0.50), "rebuild": LabColor(0.60, 1.00, 0.35),
    ],
    dataHues: rheoFluids)

  /// Rheo's 13 fluids, ids matching `ContinuumPresets`. The first five are the checked set of §2.4.
  /// The other eight were picked by WP-C1 near each fluid's real colour and pass the same rules
  /// (≥ 0.10 OKLab from every Rheo parameter hue, ≥ 3:1 on the panel). Pale and red near-twins remain
  /// (oobleck/mayonnaise/yogurt, ketchup/lava): never rely on hue alone to tell those apart.
  public static let rheoFluids: [DataHue] = [
    DataHue("oobleck", "Oobleck", LabColor(0.93, 0.92, 0.86)),  // cornflour white
    DataHue("ketchup", "Ketchup", LabColor(0.92, 0.22, 0.20)),
    DataHue("slime", "Slime", LabColor(0.15, 0.40, 1.00)),  // borax blue (green is Magnet and Listen)
    DataHue("honey", "Honey", LabColor(0.75, 0.45, 0.10)),  // darker than Gravity amber and "modelled"
    DataHue("mrFluid", "MR fluid", LabColor(0.60, 0.62, 0.72)),  // iron grey
    DataHue("waterLike", "Water", LabColor(0.10, 0.55, 0.75)),
    DataHue("mayonnaise", "Mayonnaise", LabColor(0.98, 0.95, 0.80)),
    DataHue("toothpaste", "Toothpaste", LabColor(0.00, 0.75, 0.65)),  // mint gel
    DataHue("sillyPutty", "Silly Putty", LabColor(0.80, 0.45, 0.75)),
    DataHue("yogurt", "Yogurt", LabColor(1.00, 1.00, 1.00)),
    DataHue("quicksand", "Quicksand", LabColor(0.72, 0.62, 0.45)),
    DataHue("paint", "Paint", LabColor(0.20, 0.75, 0.35)),
    DataHue("lava", "Lava", LabColor(0.80, 0.28, 0.10)),  // crust; the glow comes from temperature in the shader
  ]

  /// Rheo's console pages and Rheometer sheet, for the same-page hue rule.
  public static let rheoPageGroups: [[ParamID]] = [
    ["yield", "consistency", "index", "packing"],
    ["gravity", "heat", "magnet", "time"],
    ["finger", "stir", "shake", "rate"],
    ["listen", "drives", "gain", "band"],
    ["glow", "grain", "tracers", "depth"],
    ["yield", "consistency", "index", "packing", "memory", "rebuild"],
  ]
}
