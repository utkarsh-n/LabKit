import Foundation
import simd
import LabKitMPMTypes

// Public value types of LabKitMPM (ARCHITECTURE.md §5.2). Everything here is SI (metres, seconds, kilograms, kelvin,
// A/m) in Double; the solver converts to its float cell units in one place (MPMSolver+Encode.swift).

/// The tank the continuum lives in: a rectangle in the screen plane, origin bottom-left, y up.
public struct MPMDomain: Sendable, Equatable {
  /// Inside size of the tank, m (width, height).
  public var size: SIMD2<Double>
  /// Requested cell size, m. `MPMSolver` uses its `MPMQuality.cellSize` instead and fits a whole number of cells across
  /// the width; `MPMSolver.domain.cellSize` reports the cell size actually used.
  public var cellSize: Double
  /// Gap between the tank's front and back glass, m (thin-tank Hele-Shaw drag); 0 = off. `rheology-models.md`
  /// §4.10.5 recommends an effective 10 mm.
  public var heleShawGap: Double
  /// Floor on the Hele-Shaw decay time t_HS = ρb²/(12μ), s, so in-plane rheology (not gap friction) governs everything
  /// faster than this (§4.10.5 item 4).
  public var heleShawMinTime: Double
  /// Tank walls and floor: 0 free slip … 1 no slip (upstream PB-MPM default 0.5).
  public var wallFriction: Double

  public init(size: SIMD2<Double> = MPMDomain.lifeSizeTank, cellSize: Double = 0.002, heleShawGap: Double = 0.01,
              heleShawMinTime: Double = 0.1, wallFriction: Double = 0.5) {
    self.size = size; self.cellSize = cellSize; self.heleShawGap = heleShawGap
    self.heleShawMinTime = heleShawMinTime; self.wallFriction = wallFriction
  }

  /// 71.2 × 101.4 mm: the life-size tank on the iPhone 15 Pro Max (ARCHITECTURE.md §5.1).
  public static let lifeSizeTank = SIMD2<Double>(0.0712, 0.1014)
}

/// Resolution and effort. The substep count per frame is chosen by the solver (`MPMSubstepRule`), capped here.
public struct MPMQuality: Sendable, Equatable {
  /// Cell size Δx, m.
  public var cellSize: Double
  /// Cap on substeps per encoded frame; above it simulated time slows down (`MPMStats.lagging`).
  public var maxSubsteps: Int
  /// PB-MPM iterations (G2P solves) per substep. Default 3 (`mpm-metal.md` §12.5).
  public var iterations: Int
  /// Hydrostatic number limit Π = g·dt²·H/Δx² (`mpm-metal.md` §12.3): 0.07 keeps the volume loss of a resting
  /// pool ≤ 5 %; 0.15 is a ≤ 10 % "toy" setting.
  public var hydrostaticLimit: Double

  public init(cellSize: Double, maxSubsteps: Int, iterations: Int = 3, hydrostaticLimit: Double = 0.07) {
    self.cellSize = cellSize; self.maxSubsteps = maxSubsteps; self.iterations = iterations
    self.hydrostaticLimit = hydrostaticLimit
  }

  /// Δx 2.0 mm: the 120 Hz default.
  public static let standard = MPMQuality(cellSize: 0.002, maxSubsteps: 20, iterations: 3)
  /// Δx 1.6 mm: the 60 Hz quality mode.
  public static let high = MPMQuality(cellSize: 0.0016, maxSubsteps: 32, iterations: 3)
  /// Δx 1.1 mm: Mac benchmarks and verification.
  public static let bench = MPMQuality(cellSize: 0.0011, maxSubsteps: 64, iterations: 3)
}

/// A shape the fluid feels, in metres (tank frame, origin bottom-left, y up). Kinematic: the solver moves it with its
/// velocity through the frame's substeps; the fluid's reaction is summed per `bodyIndex`.
public struct MPMCollider: Sendable, Equatable {
  public enum Shape: Sendable, Equatable {
    case circle(radius: Double)
    case box(halfSize: SIMD2<Double>)
    /// Segment along the local x axis of half length `halfLength`, rounded by `radius`.
    case capsule(halfLength: Double, radius: Double)
  }
  public var shape: Shape
  /// Pose at the start of the frame, m and rad.
  public var position: SIMD2<Double>
  public var angle: Double
  /// m/s and rad/s; the substeps extrapolate the pose linearly through the frame.
  public var velocity: SIMD2<Double>
  public var angularVelocity: Double
  /// Coulomb friction coefficient at the fluid contact.
  public var friction: Double
  /// 0..<16: accumulate fluid impulses for this collider in `MPMStats.bodyImpulses[bodyIndex]` (props, finger).
  public var bodyIndex: Int?

  public init(shape: Shape, position: SIMD2<Double>, angle: Double = 0, velocity: SIMD2<Double> = .zero,
              angularVelocity: Double = 0, friction: Double = 0.4, bodyIndex: Int? = nil) {
    self.shape = shape; self.position = position; self.angle = angle; self.velocity = velocity
    self.angularVelocity = angularVelocity; self.friction = friction; self.bodyIndex = bodyIndex
  }
}

/// A circular source that pours `material` at `rate` particles per second (2 × 2 slots per cell).
///
/// Stripe dye: with `stripes` > 0 every emitted particle carries a dye band 1…`stripes` (`MPMParticleSnapshot.band`,
/// `PBParticle.flags` bits 8–11): equal-width bands across the nozzle, perpendicular to `velocity`, numbered from the
/// side the velocity turned by −90° points to (a downward nozzle: band 1 at −x). The bands are advected with the
/// particles, so a striped ribbon's stripes stretch, fold and coil with the flow.
public struct MPMEmitter: Sendable, Equatable {
  public var position: SIMD2<Double>
  public var radius: Double
  public var velocity: SIMD2<Double>
  public var material: Int
  public var rate: Double
  /// Temperature of the poured fluid, K; nil = the frame's ambient temperature.
  public var temperature: Double?
  /// Dye bands across the nozzle: 0 = plain (no dye), 1…`maxStripes` (larger values are clamped).
  public var stripes: Int
  /// nil: the source is a disc of `radius`. A length (m): a slot `2·radius` wide across `velocity` and this long along
  /// it, centred on `position`, the face of a piston. A disc fed at a steady rate packs its middle tighter than its
  /// edges (more of the disc lies upstream of the middle), so a disc nozzle extrudes an over-compressed core that
  /// springs apart when it leaves; a slot one cell long, fed at speed × width ÷ particle area, lays exactly one row of
  /// paste per cell travelled, at rest density.
  public var slotLength: Double?

  /// The most dye bands a particle can carry (flags bits 8–11 hold 1…7).
  public static let maxStripes = Int(PB_MAX_STRIPES)

  public init(position: SIMD2<Double>, radius: Double, velocity: SIMD2<Double> = .zero, material: Int, rate: Double,
              temperature: Double? = nil, stripes: Int = 0, slotLength: Double? = nil) {
    self.position = position; self.radius = radius; self.velocity = velocity; self.material = material
    self.rate = rate; self.temperature = temperature; self.stripes = stripes; self.slotLength = slotLength
  }
}

/// A region that holds the paste inside it (Toothpaste Toy's tube bore, 13 October 2026): every substep, particles inside
/// move with the grip's velocity (a kinematic no-slip hold). The paste outside is pulled or pushed only through the
/// material itself, so a ribbon hanging from a lifted grip stretches and tears where its own yield stress gives. With an
/// emitter at the same place moving the grip at the extrusion speed, it is a positive-displacement nozzle. The impulse
/// it takes to hold the paste is summed in `MPMStats.bodyImpulses[bodyIndex]` like a collider's.
public struct MPMGrip: Sendable, Equatable {
  /// The held region (a collider's shapes), its centre at the start of the frame (m, tank frame) and its angle (rad).
  public var shape: MPMCollider.Shape
  public var position: SIMD2<Double>
  public var angle: Double
  /// m/s; the substeps move the grip and the paste in it linearly through the frame.
  public var velocity: SIMD2<Double>
  /// 0..<16: report the holding impulse in `MPMStats.bodyImpulses[bodyIndex]`.
  public var bodyIndex: Int?

  public init(shape: MPMCollider.Shape, position: SIMD2<Double>, angle: Double = 0, velocity: SIMD2<Double> = .zero,
              bodyIndex: Int? = nil) {
    self.shape = shape; self.position = position; self.angle = angle; self.velocity = velocity; self.bodyIndex = bodyIndex
  }
}

/// Everything the solver needs for one encoded frame.
public struct MPMFrameInput: Sendable {
  /// Simulated seconds this frame (already × time scale, ≤ 1/15).
  public var dt: Double
  /// m/s², tank frame.
  public var gravity: SIMD2<Double>
  /// m/s², the tank's own acceleration (shake); the fluid feels −a.
  public var frameAcceleration: SIMD2<Double>
  /// Floor vibration as an oscillating body force along the tank's y axis: amplitude in m/s², frequency in Hz.
  public var vibration: (amplitude: Double, frequency: Double)
  /// K.
  public var ambientTemperature: Double
  /// H, A/m, tank frame (uniform).
  public var magneticField: SIMD2<Double>
  /// Virtual magnet: position (m) and field strength at 1 cm, A/m. The field falls off as (1 cm / r)³.
  public var magnet: (position: SIMD2<Double>, strength: Double)?
  /// ≤ 32 (the tank walls are implicit).
  public var colliders: [MPMCollider]
  /// Pour.
  public var emitters: [MPMEmitter]
  /// Scoop / erase: particles inside are removed.
  public var drains: [(position: SIMD2<Double>, radius: Double)]
  /// Where the rheometer samples (m); nil = no probe values.
  public var probe: SIMD2<Double>?
  /// Grips (≤ 32 shapes in all with the colliders, drains and emitters): paste inside moves with them.
  public var grips: [MPMGrip]

  public init(dt: Double = 1.0 / 120, gravity: SIMD2<Double> = SIMD2(0, -9.81), frameAcceleration: SIMD2<Double> = .zero,
              vibration: (amplitude: Double, frequency: Double) = (0, 0), ambientTemperature: Double = 293.15,
              magneticField: SIMD2<Double> = .zero, magnet: (position: SIMD2<Double>, strength: Double)? = nil,
              colliders: [MPMCollider] = [], emitters: [MPMEmitter] = [],
              drains: [(position: SIMD2<Double>, radius: Double)] = [], probe: SIMD2<Double>? = nil,
              grips: [MPMGrip] = []) {
    self.dt = dt; self.gravity = gravity; self.frameAcceleration = frameAcceleration; self.vibration = vibration
    self.ambientTemperature = ambientTemperature; self.magneticField = magneticField; self.magnet = magnet
    self.colliders = colliders; self.emitters = emitters; self.drains = drains; self.probe = probe
    self.grips = grips
  }
}

/// Telemetry from the latest *completed* frame (1–2 frames old). Counters marked cumulative count since the solver
/// was created.
public struct MPMStats: Sendable {
  public var liveParticles: Int = 0
  /// m/s (the next substep's gravity kick removed).
  public var maxSpeed: Double = 0
  /// J (per metre of depth × the Hele-Shaw gap, or per metre of depth when the gap is 0).
  public var kineticEnergy: Double = 0
  /// Pa·s: mass-weighted geometric mean of the secant viscosity τ̄/γ̇ₚ over the yielded (flowing) particles.
  public var meanViscosity: Double = 0
  public var yieldedFraction: Double = 0
  public var jammedFraction: Double = 0
  /// Mean J (1 = no compression).
  public var volumeRatio: Double = 1
  /// Probe average within 3 cells of `MPMFrameInput.probe`: total shear rate (1/s), equivalent shear stress τ̄ (Pa),
  /// apparent viscosity τ̄/γ̇ (Pa·s), share of unyielded or jammed material.
  public var probe: (shearRate: Double, stress: Double, viscosity: Double, solidFraction: Double) = (0, 0, 0, 0)
  /// Per bodyIndex (16 entries): impulse on the body over the frame (Jx, Jy in N·s; angular in N·m·s about the frame-
  /// start position of the first collider with that index), × the Hele-Shaw gap (per metre of depth when it is 0).
  public var bodyImpulses: [SIMD3<Double>] = Array(repeating: .zero, count: MPMSolver.maxBodies)
  public var substeps: Int = 0
  /// True when the substep rule wanted more than `maxSubsteps`: simulated time ran slower than requested.
  public var lagging: Bool = false
  /// Cumulative fixed-point clamps and near-overflow node sums.
  public var overflowCount: Int = 0
  /// Cumulative NaN/Inf particle resets.
  public var nanCount: Int = 0
  /// GPU time of the whole command buffer the frame was encoded into, ms.
  public var gpuMilliseconds: Double = 0

  // Additions beyond the contract (names may grow).
  /// Simulated seconds this frame actually advanced (less than requested when lagging).
  public var simulatedTime: Double = 0
  /// Particle slots in use (live + freed).
  public var particleSlots: Int = 0
  /// Cumulative CFL displacement clamps, det(I + B) guards, emitted, drained and injected-but-dropped particles.
  public var clampedDisplacements: Int = 0
  public var determinantGuards: Int = 0
  public var emitted: Int = 0
  public var drained: Int = 0
  public var droppedOnInject: Int = 0
  /// Body-impulse contributions that hit the clamp (cumulative).
  public var impulseOverflowCount: Int = 0
  /// Mean structure λ and mean temperature (K) of the live particles.
  public var meanStructure: Double = 0
  public var meanTemperature: Double = 0
  /// Σ particle mass, kg (per metre of depth × gap, as `kineticEnergy`).
  public var particleMass: Double = 0
  /// Debug (`MPMVerificationOptions.sampleGridMass`): exact Σ grid mass of the last P2G of the frame, same unit.
  public var gridMass: Double? = nil
  /// Monotone frame counter of the encode that produced these stats (0 = none yet).
  public var frameIndex: Int = 0

  public init() {}
}

/// Switches for verification harnesses and tests (`labkit-gpucheck`, `LabKitMPMTests`). Apps leave the defaults.
public struct MPMVerificationOptions: Sendable, Equatable {
  /// Periodic axes (no walls; the domain wraps). The domain size must be a whole number of cells.
  public var periodicX: Bool = false
  public var periodicY: Bool = false
  /// Explicit parity mode (V14): one iteration, ω = 0, β = 1, the volumetric stress ½K(J² − 1) warm-started like the
  /// deviatoric one, no PB volume constraint and no grid-volume J correction — explicit MLS-MPM, the CPU oracle's scheme.
  public var explicitParity: Bool = false
  /// Bypass the substep rule.
  public var fixedSubsteps: Int? = nil
  /// Body force b_x = amplitude·sin(2π·y/wavelength) on the grid (Kolmogorov flow, V4): m/s² and m.
  public var shearForcingAmplitude: Double = 0
  public var shearForcingWavelength: Double = 0
  /// nil = select the SIMD-group reduction by a runtime probe; true/false forces a path.
  public var useSIMDGroupReduction: Bool? = nil
  /// Concurrent compute encoder with explicit buffer barriers (default) or a serial encoder.
  public var concurrentDispatch: Bool = true
  /// Material ids that run PB-MPM's native liquid (volume constraint + relaxation viscosity μ, Pa·s) instead of the
  /// EVP model (V13 regression).
  public var nativeViscosity: [Int: Double] = [:]
  /// XPBD relaxation ω and warm start β of the EVP constraint (rheology-models.md §4.10.3). Production: 1, 1.
  public var omega: Double = 1
  public var warmStart: Double = 1
  /// Grid-volume J correction mix (upstream 0.1).
  public var gridVolumeMix: Double = 0.1
  /// Two-sided grid-volume J correction (LK-FIX, 8 October 2026). Upstream relaxes J toward 1/ρ̃ only where the grid
  /// is over-filled; a particle that landed compressed among gaps kept its pressure and held the gaps open (a pour
  /// stood as a particle foam 1.2–1.3 × its volume). With this on, an under-filled particle away from colliders also
  /// relaxes its J up to 1 − `underfillTolerance`·|g|·dt²/Δx, where |g| is the frame's gravity (at 0 g: up to 1).
  /// Default on.
  public var twoSidedVolumeCorrection: Bool = true
  /// Compression an under-filled particle keeps, in substep gravity kicks |g|·dt²/Δx. A free surface's top rows need
  /// about 2 of them to carry their own weight; with less they creep into the bulk (measured). Default 3.
  public var underfillTolerance: Double = 3
  /// The tank walls and floor are symmetry planes for the grid fill (mirrored ghost volume), so fluid against them
  /// reads ρ̃ ≈ 1 instead of a free surface's 0.66–0.96 and the two-sided correction leaves it alone (without it the
  /// wall rows kept giving up compression and the pool compacted into them; Rheo's toothpaste demo then leaned 2.0 mm
  /// instead of 0.8). Default on.
  public var wallMirrorVolume: Bool = true
  /// Where the virtual magnet's Kelvin force is capped (3 g), the field-induced yield stress is scaled by the same
  /// factor, so the ratio of magnetic drive to magnetic yield stays physical and MR fluid can flow to the magnet and
  /// heap (LK-FIX). Off = the field yield ignores the cap (before LK-FIX: MR fluid froze flat). Default on.
  public var kelvinYieldScaling: Bool = true
  /// Sample the exact grid mass of the frame's last P2G into `MPMStats.gridMass`.
  public var sampleGridMass: Bool = false
  /// Leave the particle push-out out of the body impulses (grid-side parity checks).
  public var excludePushOutImpulse: Bool = false
  /// Upstream PB-MPM collider semantics: grid nodes already inside a collider are pushed back to its surface every pass
  /// (the `gap` term of g2p2g.wgsl). Off by default (see VERIFICATION-GPU.md, buoyancy).
  public var upstreamColliderGap: Bool = false

  public init() {}
}

public enum MPMError: Error, CustomStringConvertible {
  case metal(String)
  case layout(String)

  public var description: String {
    switch self {
    case .metal(let s): return "LabKitMPM Metal setup failed: \(s)"
    case .layout(let s): return "LabKitMPM struct layout mismatch between Swift and MSL: \(s)"
    }
  }
}
