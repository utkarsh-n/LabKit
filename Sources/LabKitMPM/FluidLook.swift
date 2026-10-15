import Foundation
import simd
import LabKitMPMTypes

// Appearance types of the fluid surface renderer (ARCHITECTURE.md §5.2). Colours are linear Display P3 (the scene
// target is rgba16Float in extended linear Display P3, as Gyre's). Keep albedo × light below the 0.8 soft-clip knee so
// only highlights, the stress light and the lava glow reach EDR (mpm-metal.md §14.4).

/// How one material looks. The surface model (`MPMRender.metal`): a flat face against the front glass with a rounded
/// meniscus of width `meniscus` at every free edge, Beer–Lambert absorption and refraction of what lies behind for
/// clear fluids, wrap-lit scattering for milky ones, GGX key and fill highlights plus a clear coat, Schlick Fresnel
/// against a studio environment that turns with the phone, and per-particle state: jammed regions go dry and matte,
/// sheared-thin structure goes wet and glossy, lava glows by temperature. Values were tuned by eye on Rheo's back wall
/// (contact sheet `Rheo/Documentation/screenshots/looks-*.png`); the physics does not read any of them.
public struct FluidLook: Sendable, Equatable {
  /// Body colour (linear Display P3).
  public var baseColour: SIMD3<Float>
  /// 0 = clear (the backdrop shows through, tinted by absorption) … 1 = opaque (lit body colour).
  public var opacity: Float
  /// Beer–Lambert absorption per thickness unit, per channel.
  public var absorption: SIMD3<Float>
  /// Thickness → optical depth scale.
  public var absorptionScale: Float
  /// Subsurface tint and wrap-lighting amount.
  public var subsurface: SIMD3<Float>
  public var wrap: Float
  /// Index of refraction (Fresnel F₀) and GGX roughness.
  public var refractiveIndex: Float
  public var roughness: Float
  /// Specular intensity multiplier (GGX highlights and the studio reflection).
  public var specular: Float
  /// 0 = dielectric … 1 = F₀ tinted by `metalTint` (MR fluid's dark metallic sheen).
  public var metallic: Float
  /// Refraction offset of the backdrop per unit surface slope (screen uv); only the meniscus bends light.
  public var refraction: Float
  /// Turbidity: blur level (mip) of the backdrop seen through the fluid.
  public var turbidity: Float
  /// How strongly the body's large-scale thickness bends the normals (0–10): a pillowed, liquid face.
  public var normalScale: Float
  /// Rim light at grazing angles.
  public var rim: Float
  /// Temperature glow (lava): colour multiplier on the blackbody colour, gain (0 = none) and the crust temperature, K
  /// (below it the surface is dark rock).
  public var glowColour: SIMD3<Float>
  public var glowGain: Float
  public var glowOnset: Float
  /// Grain: contrast of the particle speckle that moves with the fluid (sand, paste texture).
  public var grain: Float
  /// How strongly dye tracers show (0–1).
  public var tracerDarkness: Float
  // Additions (October 2026, RENDER wave).
  /// Width of the rounded meniscus at free edges, m.
  public var meniscus: Float
  /// Steepest normal tilt at the very edge of the meniscus (sin θ, 0–0.98): how round the bead reads.
  public var bead: Float
  /// Milky translucency near thin edges (light scattered out of the body), 0–1.
  public var edgeTranslucency: Float
  /// A virtual backlight seen through thin parts (honey, slime), tinted by absorption, 0–1.
  public var transmission: Float
  /// Jammed (frictional-contact) regions go dry and matte: 0 = never … 1 = fully.
  public var jamMatte: Float
  /// Sheared-thin structure (thixotropic λ → 0) goes wet and glossy: 0 = never … 1 = fully.
  public var structureGloss: Float
  /// Dry, dilated regions whiten (oobleck's starch), 0–1.
  public var dryWhiten: Float
  /// A sharp clear coat over the base highlight (paint, ketchup, honey), 0–1.
  public var clearcoat: Float
  /// Dye tracer colour (linear Display P3).
  public var inkColour: SIMD3<Float>
  /// Metallic F₀ tint; zero uses `baseColour`.
  public var metalTint: SIMD3<Float>
  /// Speckle grain size, cells.
  public var grainSize: Float
  /// Lava crust: cracks in the cooled skin show the hotter interior (0 = none).
  public var crust: Float

  public init(baseColour: SIMD3<Float>, opacity: Float, absorption: SIMD3<Float> = SIMD3(1, 1, 1),
              absorptionScale: Float = 1, subsurface: SIMD3<Float> = .zero, wrap: Float = 0.3,
              refractiveIndex: Float = 1.45, roughness: Float = 0.2, specular: Float = 1, metallic: Float = 0,
              refraction: Float = 0, turbidity: Float = 0, normalScale: Float = 3, rim: Float = 0,
              glowColour: SIMD3<Float> = .zero, glowGain: Float = 0, glowOnset: Float = 700, grain: Float = 0,
              tracerDarkness: Float = 0.8, meniscus: Float = 0.0008, bead: Float = 0.9, edgeTranslucency: Float = 0,
              transmission: Float = 0, jamMatte: Float = 0, structureGloss: Float = 0, dryWhiten: Float = 0,
              clearcoat: Float = 0, inkColour: SIMD3<Float> = SIMD3(0.02, 0.06, 0.32), metalTint: SIMD3<Float> = .zero,
              grainSize: Float = 0.16, crust: Float = 0) {
    self.baseColour = baseColour; self.opacity = opacity; self.absorption = absorption
    self.absorptionScale = absorptionScale; self.subsurface = subsurface; self.wrap = wrap
    self.refractiveIndex = refractiveIndex; self.roughness = roughness; self.specular = specular
    self.metallic = metallic; self.refraction = refraction; self.turbidity = turbidity
    self.normalScale = normalScale; self.rim = rim; self.glowColour = glowColour; self.glowGain = glowGain
    self.glowOnset = glowOnset; self.grain = grain; self.tracerDarkness = tracerDarkness
    self.meniscus = meniscus; self.bead = bead; self.edgeTranslucency = edgeTranslucency
    self.transmission = transmission; self.jamMatte = jamMatte; self.structureGloss = structureGloss
    self.dryWhiten = dryWhiten; self.clearcoat = clearcoat; self.inkColour = inkColour; self.metalTint = metalTint
    self.grainSize = grainSize; self.crust = crust
  }

  var gpu: FluidLookGPU {
    FluidLookGPU(albedo: SIMD4(baseColour, opacity), absorption: SIMD4(absorption, absorptionScale),
                 scatter: SIMD4(subsurface, wrap), surface: SIMD4(refractiveIndex, roughness, metallic, refraction),
                 emission: SIMD4(glowColour, glowGain), extra: SIMD4(turbidity, glowOnset, normalScale, rim),
                 texture: SIMD4(grain, tracerDarkness, specular, 0))
  }

  var gpuExt: FluidLookExtGPU {
    let tint = simd_reduce_add(metalTint) > 0 ? metalTint : baseColour
    return FluidLookExtGPU(shape: SIMD4(meniscus, min(max(bead, 0), 0.98), edgeTranslucency, transmission),
                           wet: SIMD4(jamMatte, structureGloss, dryWhiten, clearcoat),
                           ink: SIMD4(inkColour, tracerDarkness), metal: SIMD4(tint, 0),
                           misc: SIMD4(grainSize, crust, 0, 0))
  }

  // MARK: Presets (one per ContinuumPresets material, same names; hues near LabPalette.rheoFluids)

  /// Clear, refractive, glossy; a faint teal in depth. Crimson dye.
  public static let waterLike = FluidLook(
    baseColour: SIMD3(0.55, 0.80, 0.92), opacity: 0, absorption: SIMD3(0.9, 0.22, 0.10), absorptionScale: 0.35,
    subsurface: SIMD3(0.02, 0.09, 0.14), wrap: 0.2, refractiveIndex: 1.333, roughness: 0.03, refraction: 0.05,
    normalScale: 1.5, rim: 0.30, tracerDarkness: 0.7, meniscus: 0.0008, bead: 0.97, transmission: 0.05, clearcoat: 0.4,
    inkColour: SIMD3(0.42, 0.010, 0.05))
  /// Amber and glossy: golden where thin, deep where thick, refracting the wall. Blue dye.
  public static let honey = FluidLook(
    baseColour: SIMD3(0.50, 0.15, 0.010), opacity: 0.05, absorption: SIMD3(0.12, 0.75, 3.2), absorptionScale: 1.0,
    subsurface: SIMD3(0.10, 0.035, 0.003), wrap: 0.35, refractiveIndex: 1.49, roughness: 0.05, refraction: 0.04,
    turbidity: 0.3, normalScale: 2.5, rim: 0.18, tracerDarkness: 0.8, meniscus: 0.0010, bead: 0.95,
    edgeTranslucency: 0.35, transmission: 0.8, clearcoat: 0.5, inkColour: SIMD3(0.02, 0.05, 0.28))
  /// Opaque red, satin; glossier once shaken thin. Mustard dye.
  public static let ketchup = FluidLook(
    baseColour: SIMD3(0.50, 0.022, 0.012), opacity: 0.9, absorption: SIMD3(0.6, 6, 8), absorptionScale: 1.5,
    subsurface: SIMD3(0.55, 0.025, 0.01), wrap: 0.4, refractiveIndex: 1.42, roughness: 0.24, refraction: 0.008,
    turbidity: 1, normalScale: 3, rim: 0.08, tracerDarkness: 0.85, meniscus: 0.0011, bead: 0.9, edgeTranslucency: 0.2,
    transmission: 0.2, structureGloss: 0.6, clearcoat: 0.25, inkColour: SIMD3(0.70, 0.48, 0.03))
  /// Off-white, satin, holds peaks. Blue dye.
  public static let mayonnaise = FluidLook(
    baseColour: SIMD3(0.80, 0.72, 0.46), opacity: 0.97, absorption: SIMD3(1, 1, 1.2), subsurface: SIMD3(0.85, 0.74, 0.45),
    wrap: 0.6, refractiveIndex: 1.46, roughness: 0.30, turbidity: 3, normalScale: 4, rim: 0.06, grain: 0.04,
    tracerDarkness: 0.8, meniscus: 0.0013, bead: 0.86, edgeTranslucency: 0.3, structureGloss: 0.45, clearcoat: 0.1,
    inkColour: SIMD3(0.03, 0.09, 0.42))
  /// Mint-white paste, matte; red stripes as dye.
  public static let toothpaste = FluidLook(
    baseColour: SIMD3(0.60, 0.84, 0.76), opacity: 0.96, subsurface: SIMD3(0.45, 0.88, 0.78), wrap: 0.5,
    refractiveIndex: 1.45, roughness: 0.32, turbidity: 3, normalScale: 4, rim: 0.05, grain: 0.04, tracerDarkness: 0.9,
    meniscus: 0.0015, bead: 0.86, edgeTranslucency: 0.3, structureGloss: 0.3, clearcoat: 0.1,
    inkColour: SIMD3(0.62, 0.015, 0.03))
  /// Milky cornflour: wet and glossy while it flows, dry, matte and whiter where it jams. Blue dye.
  public static let oobleck = FluidLook(
    baseColour: SIMD3(0.80, 0.78, 0.69), opacity: 0.94, absorption: SIMD3(0.4, 0.45, 0.6),
    subsurface: SIMD3(0.88, 0.86, 0.80), wrap: 0.6, refractiveIndex: 1.40, roughness: 0.20, refraction: 0.004,
    turbidity: 4, normalScale: 3, rim: 0.07, grain: 0.05, tracerDarkness: 0.8, meniscus: 0.0008, bead: 0.88,
    edgeTranslucency: 0.4, jamMatte: 1, dryWhiten: 0.6, clearcoat: 0.15, inkColour: SIMD3(0.02, 0.07, 0.40))
  /// Translucent borax blue, glossy. Pink dye.
  public static let slime = FluidLook(
    baseColour: SIMD3(0.03, 0.16, 0.75), opacity: 0.06, absorption: SIMD3(2.6, 1.1, 0.12),
    subsurface: SIMD3(0.015, 0.08, 0.36), wrap: 0.5, refractiveIndex: 1.36, roughness: 0.06, refraction: 0.035,
    turbidity: 0.8, normalScale: 3, rim: 0.2, tracerDarkness: 0.8, meniscus: 0.0013, bead: 0.95, edgeTranslucency: 0.25,
    transmission: 0.55, clearcoat: 0.55, inkColour: SIMD3(0.75, 0.06, 0.32))
  /// Pastel pink-violet, opaque satin. Blue dye.
  public static let sillyPutty = FluidLook(
    baseColour: SIMD3(0.66, 0.20, 0.46), opacity: 1, subsurface: SIMD3(0.60, 0.18, 0.36), wrap: 0.4,
    refractiveIndex: 1.45, roughness: 0.28, normalScale: 5, rim: 0.08, tracerDarkness: 0.8, meniscus: 0.0016,
    bead: 0.9, edgeTranslucency: 0.15, clearcoat: 0.15, inkColour: SIMD3(0.03, 0.05, 0.30))
  /// White with a soft gloss; spoon marks heal slowly. Berry dye.
  public static let yogurt = FluidLook(
    baseColour: SIMD3(0.84, 0.84, 0.80), opacity: 0.95, subsurface: SIMD3(0.90, 0.90, 0.86), wrap: 0.7,
    refractiveIndex: 1.40, roughness: 0.34, turbidity: 4, normalScale: 3, rim: 0.05, grain: 0.02, tracerDarkness: 0.8,
    meniscus: 0.0011, bead: 0.86, edgeTranslucency: 0.4, structureGloss: 0.5, clearcoat: 0.1,
    inkColour: SIMD3(0.34, 0.015, 0.12))
  /// Wet sand: grainy, glossy where it liquefies, dry and pale where it locks. Dark dye.
  public static let quicksand = FluidLook(
    baseColour: SIMD3(0.42, 0.30, 0.16), opacity: 1, subsurface: SIMD3(0.40, 0.28, 0.15), wrap: 0.25,
    refractiveIndex: 1.50, roughness: 0.55, specular: 0.6, normalScale: 2, grain: 0.5, tracerDarkness: 0.7,
    meniscus: 0.0006, bead: 0.8, jamMatte: 0.5, structureGloss: 0.6, dryWhiten: 0.35,
    inkColour: SIMD3(0.06, 0.04, 0.025), grainSize: 0.12)
  /// Black and glossy with a dark metallic sheen. Silver dye.
  public static let mrFluid = FluidLook(
    baseColour: SIMD3(0.006, 0.006, 0.007), opacity: 1, absorption: SIMD3(8, 8, 8), wrap: 0, refractiveIndex: 1.60,
    roughness: 0.10, specular: 1.5, metallic: 0.9, normalScale: 2.5, rim: 0.14, tracerDarkness: 0.6, meniscus: 0.0008,
    bead: 0.92, inkColour: SIMD3(0.55, 0.56, 0.62), metalTint: SIMD3(0.11, 0.115, 0.125))
  public static let paint = FluidLook.paint(colour: SIMD3(0.030, 0.42, 0.075))
  /// Black crust over a temperature glow (blackbody colour, `MPMRender.metal`). The crust cracks show hotter rock.
  public static let lava = FluidLook(
    baseColour: SIMD3(0.012, 0.009, 0.008), opacity: 1, absorption: SIMD3(4, 4, 4), subsurface: SIMD3(0.10, 0.015, 0),
    wrap: 0.2, refractiveIndex: 1.50, roughness: 0.65, specular: 0.6, normalScale: 4, glowColour: SIMD3(1, 1, 1),
    glowGain: 0.9, glowOnset: 900, tracerDarkness: 0, meniscus: 0.0012, bead: 0.85, crust: 1)

  /// Paint in any colour (linear Display P3): saturated, with a glossy clear coat. White dye.
  public static func paint(colour c: SIMD3<Float>) -> FluidLook {
    FluidLook(baseColour: c, opacity: 1, subsurface: 0.5 * c, wrap: 0.3, refractiveIndex: 1.45, roughness: 0.26,
              normalScale: 4, rim: 0.07, tracerDarkness: 0.85, meniscus: 0.0010, bead: 0.9, edgeTranslucency: 0.1,
              structureGloss: 0.2, clearcoat: 0.8, inkColour: SIMD3(0.80, 0.80, 0.78))
  }

  /// The 13 looks in the order and with the names of `ContinuumPresets.all`.
  public static let all: [(name: String, look: FluidLook)] = [
    ("Water-like", waterLike), ("Honey", honey), ("Ketchup", ketchup), ("Mayonnaise", mayonnaise),
    ("Toothpaste", toothpaste), ("Oobleck", oobleck), ("Slime", slime), ("Silly Putty", sillyPutty),
    ("Yogurt", yogurt), ("Quicksand", quicksand), ("MR fluid", mrFluid), ("Paint", paint), ("Lava", lava),
  ]

  /// The look for a preset name (case-insensitive), e.g. "Honey"; nil if unknown.
  public static func named(_ name: String) -> FluidLook? {
    all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.look
  }
}

/// Renderer-private per-look values beyond `FluidLookGPU` (mirrors `FLLookExt` in MPMRender.metal; the layout probe
/// checks the size).
struct FluidLookExtGPU {
  var shape: SIMD4<Float>   // meniscus (m), bead, edge translucency, transmission
  var wet: SIMD4<Float>     // jam matte, structure gloss, dry whitening, clear coat
  var ink: SIMD4<Float>     // dye colour, dye strength
  var metal: SIMD4<Float>   // metallic F₀ tint, unused
  var misc: SIMD4<Float>    // grain size (cells), crust, unused, unused
}

/// A false-colour view of one per-particle quantity over the fluid's shape (normals and highlights stay on).
public enum FluidDiagnostic: Int, Sendable, CaseIterable {
  case none, shearRate, viscosity, stress, structure, jam, temperature, speed

  /// Plain-words title for a legend (British spelling).
  public var title: String {
    switch self {
    case .none: return "Material"
    case .shearRate: return "Shear rate"
    case .viscosity: return "Viscosity"
    case .stress: return "Stress"
    case .structure: return "Structure"
    case .jam: return "Jamming"
    case .temperature: return "Temperature"
    case .speed: return "Speed"
    }
  }
  /// Unit symbol of the legend's end values.
  public var unit: String {
    switch self {
    case .none, .structure, .jam: return ""
    case .shearRate: return "1/s"
    case .viscosity: return "Pa·s"
    case .stress: return "Pa"
    case .temperature: return "K"
    case .speed: return "m/s"
    }
  }
  /// The value range mapped onto the colour map (log₁₀ axis when `logarithmic`); speed uses
  /// `FluidRenderOptions.speedRange` as its upper end.
  public func range(speedRange: Double = 1) -> (lower: Double, upper: Double, logarithmic: Bool) {
    switch self {
    case .none: return (0, 1, false)
    case .shearRate: return (1e-2, 1e3, true)
    case .viscosity: return (1e-3, 1e6, true)
    case .stress: return (1e-1, 1e4, true)
    case .structure, .jam: return (0, 1, false)
    case .temperature: return (273, 1473, false)
    case .speed: return (0, speedRange, false)
    }
  }
  /// LUT row: 0 viridis, 1 magma, 2 inferno, 3 plasma.
  public var colourMapRow: Int {
    switch self {
    case .none, .shearRate, .structure: return 0
    case .stress, .speed: return 1
    case .jam, .temperature: return 2
    case .viscosity: return 3
    }
  }
  /// `samples` legend colours from low to high, as sRGB-encoded components in 0…1 (for SwiftUI `Color(.sRGB, …)`).
  public func legend(samples: Int = 16) -> [SIMD3<Double>] {
    let n = max(samples, 2)
    let row = colourMapRow
    let lut = MPMColourMaps.bytes
    return (0..<n).map { i in
      let x = Int((Double(i) / Double(n - 1) * 255).rounded())
      let o = (row * MPMColourMaps.width + x) * 4
      return SIMD3(Double(lut[o]), Double(lut[o + 1]), Double(lut[o + 2])) / 255
    }
  }
}

/// Per-frame options of `MPMSurfaceRenderer`.
public struct FluidRenderOptions: Sendable, Equatable {
  public var diagnostic: FluidDiagnostic
  /// Multiplier on the temperature glow (lava); 0 = off.
  public var glow: Float
  /// Multiplier on each look's grain.
  public var grain: Float
  /// Strength of the dye tracers (0 = none … 1 = full): horizontal dye bands laid down where each particle first
  /// appears (a fill or a pour), then carried by the flow.
  public var tracers: Float
  /// Multiplier on optical depth (absorption and refraction strength).
  public var depth: Float
  /// Particle discs over the fluid, coloured by the diagnostic (or by a per-particle tag).
  public var showParticles: Bool
  // Additions beyond the contract.
  /// Velocity streaks over the fluid, coloured by speed.
  public var showFlow: Bool
  /// m/s at the top of the speed colour map and of the streak colours.
  public var speedRange: Float
  /// Key and fill lights: direction toward the light (screen frame, z out of the screen) and intensity. Rotate them
  /// with the device tilt to make highlights world-anchored (labkit-from-gyre.md §10.4).
  public var keyLight: SIMD4<Float>
  public var fillLight: SIMD4<Float>
  /// Stress light: emission by shear rate (1–300 s⁻¹, log), times this amount; 0 = off.
  public var stressGlow: Float
  /// Colour of the stress light (linear Display P3).
  public var stressColour: SIMD3<Float>
  /// "Up" in the screen frame for the studio reflection (−gravity, normalised); turn it with the phone.
  public var environmentUp: SIMD3<Float>
  /// Particles outside the drawn surface (spray, cracked fragments) are drawn as droplets of their own volume instead
  /// of being hidden.
  public var droplets: Bool
  // Additions (Toothpaste Toy, 13 October 2026).
  /// `.surface` (the default) is the glossy material look above; `.hologram` draws the fluid as light
  /// (`FluidHologram`, `MPMSurfaceRenderer.holoLooks`). A diagnostic other than `.none` always uses `.surface`.
  public var style: FluidRenderStyle = .surface
  /// The hologram's per-frame settings (read only with `style == .hologram`).
  public var hologram = FluidHologram()

  public init(diagnostic: FluidDiagnostic = .none, glow: Float = 1, grain: Float = 1, tracers: Float = 0, depth: Float = 1,
              showParticles: Bool = false, showFlow: Bool = false, speedRange: Float = 1,
              keyLight: SIMD4<Float> = SIMD4(0.25, 0.45, 0.86, 1.1), fillLight: SIMD4<Float> = SIMD4(-0.7, 0.5, 0.2, 0.45),
              stressGlow: Float = 0, stressColour: SIMD3<Float> = SIMD3(0.10, 0.80, 1.0),
              environmentUp: SIMD3<Float> = SIMD3(0, 0.5, 0.866), droplets: Bool = true) {
    self.diagnostic = diagnostic; self.glow = glow; self.grain = grain; self.tracers = tracers; self.depth = depth
    self.showParticles = showParticles; self.showFlow = showFlow; self.speedRange = speedRange
    self.keyLight = keyLight; self.fillLight = fillLight; self.stressGlow = stressGlow; self.stressColour = stressColour
    self.environmentUp = environmentUp; self.droplets = droplets
  }
}

// MARK: - Hologram style (Toothpaste Toy, 13 October 2026)

/// How `MPMSurfaceRenderer` draws the fluid.
public enum FluidRenderStyle: Sendable, Equatable {
  /// The glossy 2.5D material look (`FluidLook`).
  case surface
  /// The fluid as a projected hologram (`FluidHoloLook`, `FluidHologram`): a luminous translucent body with a crisp
  /// Fresnel rim, contour fringes whose hue turns with the tilt, scanlines, stripe-dye bands, shear / jam / structure
  /// light, event flashes, short-lived echoes of a fast-moving surface, a refracting lens and every particle as a faint
  /// flickering point. A visual style: the physics reads none of it.
  case hologram
}

/// One material's hologram identity (linear Display P3). Keep `body` × `FluidHologram.bodyGain` low (≈ 0.1–0.3): the
/// silhouette comes from the rim, and only rim cores, flashes and the cloud's brightest points reach the bloom.
public struct FluidHoloLook: Sendable, Equatable {
  /// Light of the body (multiplied by `FluidHologram.bodyGain`).
  public var body: SIMD3<Float>
  /// 0 = the body hides what lies behind it … 1 = fully clear (only its light adds).
  public var translucency: Float
  /// Light of the Fresnel rim and its width, m.
  public var rim: SIMD3<Float>
  public var rimWidth: Float
  /// Contour fringes: period, m (fringes parallel to the free edge), amount 0…1, hue phase (turns of the iris palette)
  /// and the hue's drift along the diagonal, turns per metre.
  public var fringePeriod: Float
  public var fringe: Float
  public var fringeHue: Float
  public var fringeDrift: Float
  /// The probability cloud: brightness of each particle's point (0 = none), its radius in cells and its flicker
  /// rate, Hz (each particle has its own phase and a rate within ±40 %).
  public var cloud: Float
  public var cloudRadius: Float
  public var cloudRate: Float
  /// Amber light where the paste jams (frictional contact), 0…1.
  public var jamLight: Float
  /// Temperature glow (lava), 0…1.
  public var heatGlow: Float
  /// Magnetic field lines across the body (MR fluid), 0…1.
  public var fieldLines: Float
  /// Foam: a brighter, denser cloud and a softer body (oobleck), 0…1.
  public var foam: Float
  /// Cyan light where the paste flows (shear rate, yielded particles), 0…1.
  public var shearLight: Float

  public init(body: SIMD3<Float>, translucency: Float = 0.6, rim: SIMD3<Float>, rimWidth: Float = 0.0005,
              fringePeriod: Float = 0.00055, fringe: Float = 0.5, fringeHue: Float = 0, fringeDrift: Float = 6,
              cloud: Float = 0.5, cloudRadius: Float = 0.12, cloudRate: Float = 1.6, jamLight: Float = 0,
              heatGlow: Float = 0, fieldLines: Float = 0, foam: Float = 0, shearLight: Float = 1) {
    self.body = body; self.translucency = translucency; self.rim = rim; self.rimWidth = rimWidth
    self.fringePeriod = fringePeriod; self.fringe = fringe; self.fringeHue = fringeHue; self.fringeDrift = fringeDrift
    self.cloud = cloud; self.cloudRadius = cloudRadius; self.cloudRate = cloudRate; self.jamLight = jamLight
    self.heatGlow = heatGlow; self.fieldLines = fieldLines; self.foam = foam; self.shearLight = shearLight
  }

  /// A neutral cyan-white hologram (the default for every slot).
  public static let standard = FluidHoloLook(body: SIMD3(0.55, 0.80, 0.90), rim: SIMD3(0.70, 0.95, 1.0))

  var gpu: FluidHoloLookGPU {
    FluidHoloLookGPU(
      body: SIMD4(body, min(max(translucency, 0), 1)), rim: SIMD4(rim, max(rimWidth, 1e-5)),
      fringe: SIMD4(max(fringePeriod, 1e-5), min(max(fringe, 0), 1), fringeHue, fringeDrift),
      cloud: SIMD4(max(cloud, 0), max(cloudRadius, 0), max(cloudRate, 0), min(max(jamLight, 0), 1)),
      extra: SIMD4(min(max(heatGlow, 0), 1), min(max(fieldLines, 0), 1), min(max(foam, 0), 1), min(max(shearLight, 0), 1)))
  }
}

/// One discrete event lit in the hologram (an amber flash with attack/decay done by the caller): where, how far its
/// light reaches, how bright now (0…1).
public struct FluidHoloFlash: Sendable, Equatable {
  public var centre: SIMD2<Float>
  public var radius: Float
  public var intensity: Float
  public init(centre: SIMD2<Float>, radius: Float, intensity: Float) {
    self.centre = centre; self.radius = radius; self.intensity = intensity
  }
}

/// Per-frame settings of the hologram style. Colours are linear Display P3; positions and lengths are tank metres.
public struct FluidHologram: Sendable, Equatable {
  /// Bounded, enhanced tilt e (Metro Station spec §14: |e| ≤ 1); turns the fringe hue and the lens's shift. Zero under
  /// Reduce Motion.
  public var tilt: SIMD2<Float> = .zero
  /// Seconds (flicker, scanline scroll, echo ages).
  public var time: Float = 0
  /// No flicker, no scroll, no echoes.
  public var reduceMotion = false
  /// Scanlines in the projector's frame: period (m), depth 0…1, scroll speed (m/s, upward).
  public var scanlinePeriod: Float = 0.0004
  public var scanlineDepth: Float = 0.16
  public var scanlineSpeed: Float = 0.0012
  /// Multiplier on every look's body light.
  public var bodyGain: Float = 1
  /// Multiplier on the rim light.
  public var rimGain: Float = 1
  /// Multiplier on the cloud's points.
  public var cloudGain: Float = 1
  /// Multiplier on the contour fringes.
  public var fringeGain: Float = 1
  /// How much of the backdrop shows through the body (times each look's translucency).
  public var backdrop: Float = 1
  /// Stripe dye: colour of each band 1…7 by bucket (`bandBucket`), and whether bands show at all. The colours are
  /// light colours (about unit brightness): they light the rim at full strength and the body at `bandGain` of it.
  public var bands = true
  public var bandGain: Float = 0.32
  public var bandColours: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (SIMD3(0.08, 0.80, 0.90), SIMD3(0.80, 0.88, 0.92), SIMD3(0.52, 0.30, 1.0))
  /// Band index 1…7 → bucket 0…2 (nil = no colour); index 0 of the array is band 1. The default (a shared array, so
  /// making a `FluidHologram` per frame allocates nothing) gives three stripes cyan · white · violet.
  public var bandBucket: [Int?] = FluidHologram.threeStripes
  public static let threeStripes: [Int?] = [0, 1, 2, 1, 0, 1, 2]
  /// Signal light: cyan where the paste flows, amber where it jams (and for flashes), violet for structure.
  public var shearColour = SIMD3<Float>(0.08, 0.80, 0.90)
  public var shearAmount: Float = 1
  public var stressColour = SIMD3<Float>(1.0, 0.46, 0.08)
  public var stressAmount: Float = 1
  public var structureColour = SIMD3<Float>(0.52, 0.30, 1.0)
  public var structureAmount: Float = 1
  /// Echoes of a fast-moving surface: youngest and oldest colour, amount (0 = off) and how long one lasts, s.
  public var ghostNear = SIMD3<Float>(0.52, 0.30, 1.0)
  public var ghostFar = SIMD3<Float>(0.90, 0.13, 0.66)
  public var ghosts: Float = 1
  public var ghostLife: Float = 0.2
  /// Thin-film palette: four colours around the hue circle (cyan → blue → violet → magenta by default).
  public var iris: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) =
    (SIMD3(0.08, 0.80, 0.90), SIMD3(0.04, 0.14, 1.0), SIMD3(0.52, 0.30, 1.0), SIMD3(0.90, 0.13, 0.66))
  /// The lens: centre and radius (m), strength 0…1 (0 = none), magnification k at the centre (1/(1−k)), shift at the
  /// centre by tilt (m) and the red-to-blue split at its diagonal edges (m).
  public var lensCentre = SIMD2<Float>.zero
  public var lensRadius: Float = 0
  public var lens: Float = 0
  public var lensMagnification: Float = 0.2
  public var lensShift: Float = 0.0004
  public var lensSplit: Float = 0.00017
  /// Up to four amber flashes (events), brightest first.
  public var flashes: (FluidHoloFlash, FluidHoloFlash, FluidHoloFlash, FluidHoloFlash) = (
    FluidHoloFlash(centre: .zero, radius: 0, intensity: 0), FluidHoloFlash(centre: .zero, radius: 0, intensity: 0),
    FluidHoloFlash(centre: .zero, radius: 0, intensity: 0), FluidHoloFlash(centre: .zero, radius: 0, intensity: 0))
  /// Magnetic field lines (looks with `fieldLines`): a dipole at `magnet` (m) or, when nil, a uniform vertical field;
  /// strength 0…1.
  public var magnet: SIMD2<Float>?
  public var field: Float = 0
  /// Drawable pixels per point (line widths).
  public var pixelsPerPoint: Float = 3

  public init() {}

  public static func == (a: FluidHologram, b: FluidHologram) -> Bool {
    a.tilt == b.tilt && a.time == b.time && a.reduceMotion == b.reduceMotion && a.scanlinePeriod == b.scanlinePeriod
      && a.scanlineDepth == b.scanlineDepth && a.scanlineSpeed == b.scanlineSpeed && a.bodyGain == b.bodyGain
      && a.rimGain == b.rimGain && a.cloudGain == b.cloudGain && a.fringeGain == b.fringeGain && a.backdrop == b.backdrop
      && a.bands == b.bands && a.bandGain == b.bandGain && a.bandColours == b.bandColours && a.bandBucket == b.bandBucket
      && a.shearColour == b.shearColour && a.shearAmount == b.shearAmount && a.stressColour == b.stressColour
      && a.stressAmount == b.stressAmount && a.structureColour == b.structureColour
      && a.structureAmount == b.structureAmount && a.ghostNear == b.ghostNear && a.ghostFar == b.ghostFar
      && a.ghosts == b.ghosts && a.ghostLife == b.ghostLife && a.iris == b.iris && a.lensCentre == b.lensCentre
      && a.lensRadius == b.lensRadius && a.lens == b.lens && a.lensMagnification == b.lensMagnification
      && a.lensShift == b.lensShift && a.lensSplit == b.lensSplit && a.flashes == b.flashes && a.magnet == b.magnet
      && a.field == b.field && a.pixelsPerPoint == b.pixelsPerPoint
  }

  /// `FluidSplatUniforms.bandBuckets`: 2 bits per band index 0…7 (band 0 = undyed: none).
  var bandBucketBits: UInt32 {
    var bits = UInt32(FL_BUCKET_NONE)
    for band in 1...7 {
      let b = band - 1 < bandBucket.count ? bandBucket[band - 1] : nil
      let v = b.map { UInt32(min(max($0, 0), 2)) } ?? UInt32(FL_BUCKET_NONE)
      bits |= v << UInt32(2 * band)
    }
    return bits
  }
}
