import Foundation
import simd
import LabKitCore
import LabKitMPMTypes

// The one place where SI parameters become the GPU's float layout (ARCHITECTURE.md §1 rule 7).

/// Global volume-ratio clamp of the EVP model (rheology-models.md §4.8; the same values as LabKitMPMReference's
/// `EVP.minimumVolumeRatio/maximumVolumeRatio`).
public enum MPMConstants {
  public static let minimumVolumeRatio = 0.6
  public static let maximumVolumeRatio = 1.5
  /// Grid mass unit: kg/m³ of a fluid whose particles have mass 0.25 at 2 × 2 per cell.
  public static let referenceDensity = 1000.0
  /// μ₀, T·m/A.
  public static let vacuumPermeability = 4e-7 * Double.pi
  /// Upstream PB-MPM liquid relaxation α_vol of the cold volume constraint.
  public static let liquidRelaxation = 1.5
  /// Rheometer probe radius, cells.
  public static let probeRadiusCells = 3.0
  /// Virtual magnet reference distance, m (strength is given at 1 cm).
  public static let magnetReferenceDistance = 0.01
  /// Largest finite stand-in for "off" thresholds on the GPU (fast math assumes no infinities).
  static let gpuInfinity: Float = 1e30
  /// Cap on the Kelvin body-force acceleration of the virtual magnet, m/s² (3 g, rheology-models.md §4.8; the GPU's
  /// PB_KELVIN_CAP). The field-induced yield stress is scaled down by the same factor where the cap bites.
  public static let kelvinAccelerationCap = 29.43

  /// Drop of the capped Kelvin potential (m²/s²) along a column of fluid `depth` long that starts at the tank point
  /// nearest to the virtual magnet: Φ(r) = μ0χH²/2ρ with H = H0·(r0/r)³ (r ≥ r0 = 1 cm) outside r_c, where the force
  /// 3μ0χH²/(ρr) reaches the cap, and Φ(r_c) + cap·(r_c − r) inside. It is extra hydrostatic head for the substep rule:
  /// without it the fluid over the magnet compressed (J 0.84–0.90, measured) and its surface dipped 1–1.6 mm.
  public static func kelvinHead(magnet: SIMD2<Double>, strength H0: Double, susceptibility chi: Double, density rho: Double,
                                tank: SIMD2<Double>, depth: Double, cap: Double = kelvinAccelerationCap) -> Double {
    guard H0 > 0, chi > 0, rho > 0, depth > 0, cap > 0 else { return 0 }
    let r0 = magnetReferenceDistance
    let k = vacuumPermeability * chi / rho
    func H(_ r: Double) -> Double { H0 * pow(r0 / max(r, r0), 3) }
    func phiTrue(_ r: Double) -> Double { 0.5 * k * H(r) * H(r) }
    // r_c: 3k·H0²·r0⁶ / r⁷ = cap.
    let rc = max(r0, r0 * pow(3 * k * H0 * H0 / (r0 * cap), 1.0 / 7))
    func phi(_ r: Double) -> Double { r < rc ? phiTrue(rc) + cap * (rc - max(r, r0)) : phiTrue(r) }
    let nearest = SIMD2(min(max(magnet.x, 0), tank.x), min(max(magnet.y, 0), tank.y))
    let rMin = max(simd_length(magnet - nearest), r0)
    return max(phi(rMin) - phi(rMin + depth), 0)
  }
}

/// The temperature band of the flow law (rheology-models.md §4.8; LabKitMPMReference `EVP.clampedTemperature`).
enum LabKitMPMBand {
  static func below(_ m: ContinuumMaterial) -> Double { max(m.temperatureBandBelow ?? 40, 0) }
  static let above = 80.0
}

extension PBMaterial {
  /// Converts one SI material to the GPU table entry. `nativeViscosity` switches the entry to PB-MPM's native liquid
  /// (V13 regression only).
  static func make(_ m: ContinuumMaterial, nativeViscosity: Double? = nil) -> PBMaterial {
    func f(_ x: Double) -> Float {
      if x.isNaN { return 0 }
      if x >= Double(MPMConstants.gpuInfinity) { return MPMConstants.gpuInfinity }
      return Float(x)
    }
    var g = PBMaterial()
    g.model = nativeViscosity == nil ? UInt32(PB_MODEL_EVP) : UInt32(PB_MODEL_LIQUID)
    g.density = f(max(m.density, 1))
    g.shearModulus = f(max(m.shearModulus, 1))
    g.bulkModulus = f(max(m.bulkModulus, 0))
    g.tensionLimit = f(max(m.tensionLimit, 0))
    g.yieldBroken = f(m.yieldBroken)
    g.yieldStructure = f(m.yieldStructure)
    g.structureExponent = f(max(m.structureExponent, 1e-3))
    g.consistency = f(max(m.consistency, 0))
    g.flowIndex = f(min(max(m.flowIndex, 0.15), 1))
    g.consistencyStructure = f(m.consistencyStructure)
    g.fluidity = f(max(m.fluidity, 0))
    g.eaOverR = f(max(m.activationEnergy, 0) / ContinuumMaterial.gasConstant)
    g.eaYieldOverR = f(max(m.yieldActivationEnergy, 0) / ContinuumMaterial.gasConstant)
    g.refTemperature = f(max(m.referenceTemperature, 1))
    g.failureStress = m.failureStress.isFinite ? f(m.failureStress) : MPMConstants.gpuInfinity
    g.failureFluidity = f(max(m.failureFluidity, 0))
    g.buildRate = f(max(m.buildRate, 0))
    g.buildShear = f(max(m.buildShear, 0))
    g.breakRate = f(max(m.breakRate, 0))
    g.breakShear = f(max(m.breakShear, 0))
    g.vibrationWeight = f(min(max(m.vibrationWeight, 0), 1))
    g.jMin = Float(MPMConstants.minimumVolumeRatio)
    g.jMax = Float(MPMConstants.maximumVolumeRatio)
    if let d = m.dst {
      g.dst = 1
      g.phi = f(d.phi); g.phi0 = f(d.phiFrictionless); g.phiM = f(d.phiFrictional)
      g.solventViscosity = f(max(d.solventViscosity, 1e-6)); g.sigmaStar = f(max(d.onsetStress, 1e-6))
      g.onsetForm = UInt32(min(max(d.onsetForm, 0), 1)) | (d.plasticDrive ? 2 : 0); g.gammaStar = f(max(d.strainScale, 1e-6))
      g.meltTime = f(max(d.meltTime, 1e-6)); g.jamTime = f(max(d.jamTime, 0))
      g.jamFailureStress = f(d.jamFailureStress); g.postFailureViscosity = f(max(d.postFailureViscosity, 1e-6))
      g.breakStrain = f(max(d.breakStrain, 1e-6)); g.gapFloor = f(d.gapFloor); g.blendWidth = f(max(d.blendWidth, 1e-6))
      g.restMelt = f(min(max(d.restMelt, 0), 1))
    } else {
      g.dst = 0
      g.blendWidth = 1; g.gammaStar = 1; g.meltTime = 1; g.postFailureViscosity = 1; g.breakStrain = 1
      g.solventViscosity = 1; g.sigmaStar = 1; g.phi0 = 1; g.phiM = 1
    }
    g.bandBelow = f(LabKitMPMBand.below(m))
    g.bandAbove = f(LabKitMPMBand.above)
    if let fr = m.field {
      g.fieldScale = f(max(fr.yieldSaturation, 0))
      g.fieldK = fr.saturationField > 0 ? f(1 / fr.saturationField) : 0
      g.fieldClampFracG = f(max(fr.clampFractionOfG, 0))
      g.fieldDeadZone = f(max(fr.deadZone, 0) / MPMConstants.vacuumPermeability)
      g.susceptibility = f(max(fr.susceptibility, 0))
    }
    g.wallYieldFactor = f(min(max(m.wallYieldFactor, 0), 1))
    g.liquidRelaxation = Float(MPMConstants.liquidRelaxation)
    g.nativeViscosity = f(nativeViscosity ?? 0)
    return g
  }
}

/// Cell layout of a domain at one resolution: SI ↔ solver cells.
struct MPMGridLayout: Equatable {
  /// Effective cell size, m (the width holds a whole number of cells).
  let dx: Double
  /// Interior cells (the tank).
  let interior: SIMD2<Int>
  let periodicX: Bool
  let periodicY: Bool
  /// Cell coordinate of the tank origin: PB_WALL_OFFSET on walled axes, 0 on periodic axes.
  let origin: SIMD2<Double>
  /// Nodes per axis (walled: interior + 9 for the guardian band; periodic: interior).
  let gridSize: SIMD2<Int>
  let bukkitCount: SIMD2<Int>

  init(size: SIMD2<Double>, cellSize: Double, periodicX: Bool = false, periodicY: Bool = false) {
    let nx = max(1, Int((size.x / cellSize).rounded()))
    let d = size.x / Double(nx)
    let ny = max(1, Int((size.y / d).rounded()))
    dx = d
    interior = SIMD2(nx, ny)
    self.periodicX = periodicX; self.periodicY = periodicY
    let wall = Double(PB_WALL_OFFSET)
    origin = SIMD2(periodicX ? 0 : wall, periodicY ? 0 : wall)
    let pad = 2 * Int(PB_WALL_OFFSET) + 1
    gridSize = SIMD2(periodicX ? nx : nx + pad, periodicY ? ny : ny + pad)
    let b = Int(PB_BUKKIT_SIZE)
    bukkitCount = SIMD2((gridSize.x + b - 1) / b, (gridSize.y + b - 1) / b)
  }

  /// Tank size actually simulated, m.
  var size: SIMD2<Double> { SIMD2(Double(interior.x), Double(interior.y)) * dx }
  var nodeCount: Int { gridSize.x * gridSize.y }
  var bukkits: Int { bukkitCount.x * bukkitCount.y }

  func toCells(_ p: SIMD2<Double>) -> SIMD2<Double> { p / dx + origin }
  func toMetres(_ c: SIMD2<Double>) -> SIMD2<Double> { (c - origin) * dx }
}

/// The substep rule of `mpm-metal.md` §12.3 and ARCHITECTURE.md §5.1: the largest of the hydrostatic rule
/// Π = g·dt²·H/Δx² ≤ Π_max, ≤ 1 cell of travel per substep, ≥ 8 substeps per vibration period and the elastic wave rule
/// c_s·dt/Δx ≤ √(k/2) (rheology-models.md §4.10.3). Above the cap, simulated time slows down.
public struct MPMSubstepRule: Sendable, Equatable {
  public var substeps: Int
  /// Simulated seconds this frame (≤ the requested time).
  public var simulatedTime: Double
  public var lagging: Bool
  /// What each rule asked for (diagnostics).
  public var hydrostatic: Int, advection: Int, vibration: Int, elastic: Int

  /// - Parameters:
  ///   - frameTime: requested simulated seconds.
  ///   - peakAcceleration: |g| + |a_frame| + vibration amplitude, m/s².
  ///   - depth: fluid depth H along gravity, m.
  ///   - maxSpeed: last frame's max speed, m/s (× 1.25 margin inside).
  ///   - vibrationFrequency: Hz (0 = none).
  ///   - shearWaveSpeed: largest √(G/ρ) among the materials in use, m/s.
  public static func plan(frameTime: Double, cellSize dx: Double, peakAcceleration: Double, depth: Double,
                          maxSpeed: Double, vibrationFrequency: Double, shearWaveSpeed: Double,
                          quality: MPMQuality) -> MPMSubstepRule {
    let T = max(frameTime, 0)
    let iterations = Double(max(quality.iterations, 1))
    func up(_ x: Double) -> Int { x.isFinite ? max(0, Int(x.rounded(.up))) : Int.max / 4 }
    let sHyd = up(T * (max(peakAcceleration, 0) * max(depth, 0) / (max(quality.hydrostaticLimit, 1e-6) * dx * dx)).squareRoot())
    let sAdv = up(T * max(maxSpeed, 0) * 1.25 / dx)
    let sVib = vibrationFrequency > 0 ? up(8 * vibrationFrequency * T) : 0
    let sEl = up(T * max(shearWaveSpeed, 0) / ((iterations / 2).squareRoot() * dx))
    let needed = max(sHyd, sAdv, sVib, sEl, 2)
    let cap = max(quality.maxSubsteps, 1)
    if needed > cap {
      return MPMSubstepRule(substeps: cap, simulatedTime: T * Double(cap) / Double(needed), lagging: true,
                            hydrostatic: sHyd, advection: sAdv, vibration: sVib, elastic: sEl)
    }
    return MPMSubstepRule(substeps: needed, simulatedTime: T, lagging: false,
                          hydrostatic: sHyd, advection: sAdv, vibration: sVib, elastic: sEl)
  }
}
