// Explicit 2D MLS-MPM reference solver (Double), the CPU physics oracle. Owned by WP-O.
//
// Specification: Rheo/Documentation/research/rheology-models.md §4.4 (per-particle algorithm), §4.5 (planar 2D),
// §4.8 (clamps), §4.9 (time step), §4.10.5 (Hele-Shaw drag) and §7 (verification set-ups). Transfers follow
// Hu et al. 2018 (MLS-MPM) with quadratic B-splines, D⁻¹ = 4/Δx², 2×2 particles per cell by default.
//
// Grid and walls. Nodes sit at (i·Δx, j·Δx). The domain is [0, Lx] × [0, Ly]. A periodic axis has Lx/Δx nodes
// (index wrapped); a non-periodic axis has nodes −3 … N+3 (N = L/Δx), and its two ends can carry walls. Walls are
// PB-MPM-style grid conditions on nodes *at or beyond* the wall (x ≤ 0, x ≥ Lx, y ≤ 0, y ≥ Ly): sticky walls set
// the node velocity to the wall's velocity (no-slip, can move: Couette), slip walls remove the normal component
// when it points into the wall, open sides do nothing (free surface). Kinematic boxes set nodes inside them to the
// box velocity (sticky) and report the reaction force.
//
// One step (`step(dt:)`): P2G with the committed Kirchhoff stress → grid velocity + body force → Hele-Shaw drag →
// walls and boxes → G2P (v, C = ∇v, grid volume) → advect → optional grid-volume J correction, temperature
// relaxation and MR field lag → `EVP.update` with the new C → store stress for the next P2G.

import Foundation
import LabKitCore
import simd

/// A body acceleration field a(x, t) in m/s² (gravity, tilt, vibration, Kolmogorov forcing ...).
public typealias ReferenceBodyForce = @Sendable (_ position: SIMD2<Double>, _ time: Double) -> SIMD2<Double>
/// A magnetic field magnitude |H|(x, t) in A/m.
public typealias ReferenceFieldMagnitude = @Sendable (_ position: SIMD2<Double>, _ time: Double) -> Double

/// One material point (per unit depth).
public struct ReferenceParticle: Sendable {
  /// Position x, m.
  public var position: SIMD2<Double>
  /// Velocity v, m/s.
  public var velocity: SIMD2<Double>
  /// Velocity gradient C = ∇v from the last G2P (APIC affine matrix), column-major (c11 = C[0][0], c12 = C[1][0]).
  public var velocityGradient: simd_double2x2
  /// Rheology state (b̄ₑ, J, λ, f, T, γ̇ₚ).
  public var state: EVPState
  /// Index into the solver's `materials`.
  public var material: Int
  /// Mass per unit depth, kg/m.
  public var mass: Double
  /// Reference volume V⁰ per unit depth, m².
  public var volume: Double
  /// Committed Kirchhoff stress (τ11, τ12, τ22), Pa.
  public var stress: SIMD3<Double>
  /// Where the particle was seeded (Lagrangian coordinate), m.
  public var initialPosition: SIMD2<Double>
  /// Lagged field magnitude |H|_eff, A/m.
  public var fieldMagnitude: Double
  /// Diagnostics of the last update: total equivalent shear rate (1/s) and the DST jam blend s ∈ [0, 1].
  public var shearRate: Double
  public var jam: Double
  /// Grid volume ratio J_grid gathered at the last G2P (1/Σ w·V_node; > 1 near free surfaces).
  public var gridVolumeRatio: Double

  public init(position: SIMD2<Double>, velocity: SIMD2<Double> = .zero, material: Int, mass: Double, volume: Double,
              state: EVPState = EVPState()) {
    self.position = position; self.velocity = velocity
    self.velocityGradient = simd_double2x2(0)
    self.state = state; self.material = material; self.mass = mass; self.volume = volume
    self.stress = .zero; self.initialPosition = position; self.fieldMagnitude = 0
    self.shearRate = 0; self.jam = 0; self.gridVolumeRatio = 1
  }

  /// Cauchy stress σ = τ/J (σ11, σ12, σ22), Pa.
  public var cauchyStress: SIMD3<Double> { stress / state.J }
  /// Pressure p = −½ tr σ, Pa.
  public var pressure: Double { -0.5 * (stress.x + stress.z) / state.J }
  /// Equivalent shear stress of the Cauchy stress, Pa.
  public var equivalentShearStress: Double { EVP.equivalentShearStress(stress) / state.J }
  /// Plastic shear rate of the last update, 1/s.
  public var plasticRate: Double { state.plasticRate }
  /// Secant viscosity τ̄/γ̇ₚ (Pa·s), `.infinity` when not flowing.
  public var secantViscosity: Double {
    state.plasticRate > 0 ? EVP.equivalentShearStress(stress) / state.plasticRate : .infinity
  }
}

/// What a domain edge does.
public enum ReferenceWall: Sendable, Equatable {
  /// Nothing (free surface; keep material away from this edge or particles are clamped into the guard band).
  case open
  /// No-slip wall moving at `velocity` (PB-MPM-style sticky nodes).
  case sticky(velocity: SIMD2<Double>)
  /// Frictionless wall: the normal velocity component is removed when it points into the wall.
  case slip

  /// A fixed no-slip wall.
  public static let fixed = ReferenceWall.sticky(velocity: .zero)
}

/// The four edges of the domain. Ignored on periodic axes.
public struct ReferenceWalls: Sendable, Equatable {
  public var left: ReferenceWall, right: ReferenceWall, bottom: ReferenceWall, top: ReferenceWall
  public init(left: ReferenceWall = .fixed, right: ReferenceWall = .fixed, bottom: ReferenceWall = .fixed,
              top: ReferenceWall = .open) {
    self.left = left; self.right = right; self.bottom = bottom; self.top = top
  }
  /// Sticky floor and side walls, open top: a tank.
  public static let tank = ReferenceWalls()
}

/// Thin-tank (Hele-Shaw) drag, applied implicitly per substep on the grid: v ← v/(1 + Δt/t_HS) (§4.10.5).
public enum ReferenceHeleShaw: Sendable, Equatable {
  /// A fixed drag time t_HS (s), e.g. as numerical damping (V1).
  case fixedTime(Double)
  /// Newtonian gap flow: t_HS = ρb²/(12η) with each particle's density.
  case newtonian(viscosity: Double, gap: Double)
  /// Gap-averaged flow law per particle (§4.10.5 items 1–4): μ_HS = ((2n+1)/(3n))·τ_w(γ̇_w)/γ̇_w with
  /// γ̇_w = 2(2n+1)Ū/(n·b), τ_w from the particle's current flow law with τ_y scaled by `wallYieldFactor`,
  /// μ_HS from the previous step's speed (semi-implicit); t_HS = max(ρb²/(12μ_HS), minimumTime).
  case gapAveraged(gap: Double, minimumTime: Double)
}

/// An axis-aligned kinematic box the material feels as an obstacle moving at `velocity`. Sticky boxes set the nodes
/// inside them to the box velocity (no-slip); slip boxes only remove the relative velocity component pointing into
/// the nearest face (frictionless).
public struct ReferenceBox: Sendable, Equatable {
  public var center: SIMD2<Double>
  public var halfSize: SIMD2<Double>
  public var velocity: SIMD2<Double>
  public var sticky: Bool
  public init(center: SIMD2<Double>, halfSize: SIMD2<Double>, velocity: SIMD2<Double> = .zero, sticky: Bool = true) {
    self.center = center; self.halfSize = halfSize; self.velocity = velocity; self.sticky = sticky
  }
  public func contains(_ p: SIMD2<Double>) -> Bool {
    abs(p.x - center.x) <= halfSize.x && abs(p.y - center.y) <= halfSize.y
  }
  /// Outward normal of the face nearest to `p` (a point inside the box).
  public func nearestFaceNormal(_ p: SIMD2<Double>) -> SIMD2<Double> {
    let d = p - center
    let gapX = halfSize.x - abs(d.x), gapY = halfSize.y - abs(d.y)
    return gapX < gapY ? SIMD2(d.x < 0 ? -1 : 1, 0) : SIMD2(0, d.y < 0 ? -1 : 1)
  }
  /// The node velocity this box imposes on `v` at a node `p` inside it.
  public func constrain(_ v: SIMD2<Double>, at p: SIMD2<Double>) -> SIMD2<Double> {
    if sticky { return velocity }
    let n = nearestFaceNormal(p)
    let vn = simd_dot(v - velocity, n)
    return vn < 0 ? v - vn * n : v
  }
}

/// A complete set-up for `ReferenceSolver2D`.
public struct ReferenceScene: Sendable {
  /// Domain size (m); the domain is [0, size.x] × [0, size.y]. Periodic axes must be whole cells. On a walled axis the
  /// far wall sits on grid node round(size/Δx), so a size that is not a whole number of cells moves it by ≤ ½Δx.
  public var size: SIMD2<Double>
  /// Grid spacing Δx, m.
  public var cellSize: Double
  public var periodicX: Bool
  public var periodicY: Bool
  public var walls: ReferenceWalls
  /// Body acceleration a(x, t), evaluated at grid nodes at the start of each step.
  public var bodyAcceleration: ReferenceBodyForce
  public var particles: [ReferenceParticle]
  public var heleShaw: ReferenceHeleShaw?
  /// PB-MPM grid-volume correction mix (J ← J + mix·(J_grid − J) when J_grid < 1); 0 = off, PB-MPM uses 0.1.
  public var gridVolumeCorrection: Double
  /// With the correction on: an under-filled particle (J_grid ≥ 1) also relaxes J up to 1 − tolerance·|a|·Δt²/Δx (a =
  /// the body acceleration), the GPU's two-sided correction (LK-FIX; tolerance 3 is the GPU default; the GPU's
  /// optional wall mirror is off by default and this oracle has none). nil = off.
  public var gridVolumeUnderfillTolerance: Double?
  /// Ambient temperature (K) that particle temperatures relax to over `thermalTime`; nil = no relaxation.
  public var ambientTemperature: Double?
  public var thermalTime: Double
  /// Magnetic field magnitude |H|(x, t), A/m; nil = no field. Lagged per particle by the material's T₆₃.
  public var magneticField: ReferenceFieldMagnitude?
  /// Kinematic sticky boxes (plates, paddles).
  public var boxes: [ReferenceBox]
  /// Velocity guard after G2P: ‖v‖ ≤ factor·Δx/Δt (counted). §4.8 uses 0.5.
  public var speedLimitFactor: Double

  public init(size: SIMD2<Double>, cellSize: Double, periodicX: Bool = false, periodicY: Bool = false,
              walls: ReferenceWalls = .tank,
              bodyAcceleration: @escaping ReferenceBodyForce = { _, _ in .zero }) {
    self.size = size; self.cellSize = cellSize; self.periodicX = periodicX; self.periodicY = periodicY
    self.walls = walls; self.bodyAcceleration = bodyAcceleration; self.particles = []
    self.heleShaw = nil; self.gridVolumeCorrection = 0; self.gridVolumeUnderfillTolerance = nil
    self.ambientTemperature = nil; self.thermalTime = 1
    self.magneticField = nil; self.boxes = []; self.speedLimitFactor = 0.5
  }

  /// Seeds `particlesPerCell`² particles per grid cell, at rest, inside the rectangle [lower, upper) (cells whose
  /// seed points fall inside `include`, if given). Mass ρ·V⁰ with V⁰ = (Δx/ppc)². Particles start rested at the
  /// material's reference temperature (or `temperature`).
  public mutating func fill(lower: SIMD2<Double>, upper: SIMD2<Double>, material index: Int,
                            _ material: ContinuumMaterial, particlesPerCell ppc: Int = 2,
                            temperature: Double? = nil, velocity: SIMD2<Double> = .zero,
                            include: ((SIMD2<Double>) -> Bool)? = nil) {
    let h = cellSize, v0 = (h / Double(ppc)) * (h / Double(ppc))
    var st = EVPState.rested(material)
    if let t = temperature { st.temperature = t }
    let i0 = Int((lower.x / h).rounded(.down)), i1 = Int((upper.x / h).rounded(.up))
    let j0 = Int((lower.y / h).rounded(.down)), j1 = Int((upper.y / h).rounded(.up))
    for i in i0..<max(i1, i0) {
      for j in j0..<max(j1, j0) {
        for a in 0..<ppc {
          for b in 0..<ppc {
            let p = SIMD2((Double(i) + (Double(a) + 0.5) / Double(ppc)) * h, (Double(j) + (Double(b) + 0.5) / Double(ppc)) * h)
            guard p.x >= lower.x, p.x < upper.x, p.y >= lower.y, p.y < upper.y else { continue }
            if let inc = include, !inc(p) { continue }
            var particle = ReferenceParticle(position: p, velocity: velocity, material: index,
                                             mass: material.density * v0, volume: v0, state: st)
            particle.initialPosition = p
            particles.append(particle)
          }
        }
      }
    }
  }

  // MARK: Body-force helpers

  /// A uniform acceleration.
  public static func uniform(_ g: SIMD2<Double>) -> ReferenceBodyForce { { _, _ in g } }
  /// A uniform acceleration ramped linearly from zero over `duration` seconds (§7: loads ramped over ≥ 0.05 s).
  public static func ramped(_ g: SIMD2<Double>, over duration: Double) -> ReferenceBodyForce {
    { _, t in duration > 0 ? min(1, t / duration) * g : g }
  }
  /// Gravity plus a sinusoidal vibration of peak acceleration `amplitude` (m/s²) along `direction` (§4.2 e).
  public static func vibrating(_ g: SIMD2<Double>, amplitude: Double, frequency: Double,
                               direction: SIMD2<Double> = SIMD2(0, 1)) -> ReferenceBodyForce {
    let d = simd_normalize(direction)
    return { _, t in g + amplitude * sin(2 * .pi * frequency * t) * d }
  }
}

/// Counters of the robustness guards (each should stay 0 in a well-resolved run).
public struct ReferenceCounters: Sendable, Equatable {
  /// det(I + Δt·C) floor hits (§4.8).
  public var determinantGuards = 0
  /// Velocity guard hits after G2P.
  public var speedClamps = 0
  /// Particles clamped back into the guard band of a non-periodic axis.
  public var outOfBounds = 0
  /// Particles whose state or velocity became non-finite (they are frozen in place and counted).
  public var nonFinite = 0
  /// J clamp or tension-cap hits (normal for liquids with a tension limit; informational).
  public var volumeClamps = 0
  /// Bisection fallbacks inside the return-map Newton solve.
  public var newtonBisections = 0
  public init() {}
}

/// The explicit MLS-MPM oracle (quadratic B-splines, Double, SI units). Not Sendable: confine to one thread.
public final class ReferenceSolver2D {
  public let scene: ReferenceScene
  public var materials: [ContinuumMaterial]
  public private(set) var particles: [ReferenceParticle]
  /// Kinematic boxes (mutable between steps: change a box's velocity to start or stop it).
  public var boxes: [ReferenceBox]
  /// Edge conditions (mutable between steps, e.g. to stop a Couette wall).
  public var walls: ReferenceWalls
  /// Body acceleration a(x, t) (mutable between steps).
  public var bodyAcceleration: ReferenceBodyForce
  /// Reaction force of the material on each box over the last step, N per metre of depth.
  public private(set) var boxForces: [SIMD2<Double>]
  public private(set) var time: Double = 0
  public private(set) var stepCount = 0
  public private(set) var counters = ReferenceCounters()

  // Grid layout.
  public let cellSize: Double
  /// Cells along each axis (L/Δx).
  public let cells: SIMD2<Int>
  private let pad = 3
  private let nodeCountX: Int, nodeCountY: Int
  private let offsetX: Int, offsetY: Int
  // Grid channels (index = ix * nodeCountY + iy), kept from the last step for the profile helpers.
  private var gridMass: [Double]
  private var gridMomentum: [SIMD2<Double>]
  private var gridVolume: [Double]
  private var gridDrag: [Double]
  private var gridVelocityStore: [SIMD2<Double>]
  // Per-particle extra acceleration (MR Kelvin force) and drag rate, rebuilt each step.
  private var particleDragRate: [Double]
  private var particleAcceleration: [SIMD2<Double>]
  /// Per particle: cap / |a_Kelvin| where the Kelvin force is capped at 3 g (else 1); scales the field-induced yield.
  private var particleFieldYieldScale: [Double]

  public init(scene: ReferenceScene, materials: [ContinuumMaterial]) {
    self.scene = scene
    self.materials = materials
    self.particles = scene.particles
    self.boxes = scene.boxes
    self.walls = scene.walls
    self.bodyAcceleration = scene.bodyAcceleration
    self.boxForces = Array(repeating: .zero, count: scene.boxes.count)
    self.cellSize = scene.cellSize
    let nx = Int((scene.size.x / scene.cellSize).rounded()), ny = Int((scene.size.y / scene.cellSize).rounded())
    self.cells = SIMD2(nx, ny)
    nodeCountX = scene.periodicX ? nx : nx + 2 * 3 + 1
    nodeCountY = scene.periodicY ? ny : ny + 2 * 3 + 1
    offsetX = scene.periodicX ? 0 : 3
    offsetY = scene.periodicY ? 0 : 3
    let n = nodeCountX * nodeCountY
    gridMass = Array(repeating: 0, count: n)
    gridMomentum = Array(repeating: .zero, count: n)
    gridVolume = Array(repeating: 0, count: n)
    gridDrag = Array(repeating: 0, count: n)
    gridVelocityStore = Array(repeating: .zero, count: n)
    particleDragRate = Array(repeating: 0, count: particles.count)
    particleAcceleration = Array(repeating: .zero, count: particles.count)
    particleFieldYieldScale = Array(repeating: 1, count: particles.count)
    for i in particles.indices {
      let m = materials[particles[i].material]
      particles[i].stress = EVP.kirchhoffStress(particles[i].state, material: m)
      if let field = scene.magneticField { particles[i].fieldMagnitude = field(particles[i].position, 0) }
    }
  }

  // MARK: Time step

  /// The largest P-wave speed √((K + G)/ρ) over the materials in use, m/s.
  public var maximumWaveSpeed: Double {
    var used = Set<Int>()
    for p in particles { used.insert(p.material) }
    return used.map { materials[$0] }.map { (($0.bulkModulus + $0.shearModulus) / $0.density).squareRoot() }.max() ?? 0
  }

  /// The largest particle speed, m/s.
  public var maximumSpeed: Double { particles.map { simd_length($0.velocity) }.max() ?? 0 }

  /// §4.9: Δt = C_e·Δx/(c_p + |v|_max), with C_e = 0.4 the stable limit for quadratic MLS-MPM (the V-suite uses 0.3).
  public func suggestedTimeStep(courant: Double = 0.4) -> Double {
    courant * cellSize / (maximumWaveSpeed + maximumSpeed)
  }

  /// Steps `duration` seconds with a fixed Δt (the last step is shortened to land exactly). Calls `each` after every step.
  public func advance(by duration: Double, dt: Double, each: ((ReferenceSolver2D) -> Void)? = nil) {
    let end = time + duration
    while time < end - 1e-12 * max(1, abs(end)) {
      step(dt: min(dt, end - time))
      each?(self)
    }
  }

  // MARK: Grid helpers

  @inline(__always) private func nodeX(_ i: Int) -> Int {
    if scene.periodicX { let m = i % nodeCountX; return m < 0 ? m + nodeCountX : m }
    return min(max(i + offsetX, 0), nodeCountX - 1)
  }
  @inline(__always) private func nodeY(_ j: Int) -> Int {
    if scene.periodicY { let m = j % nodeCountY; return m < 0 ? m + nodeCountY : m }
    return min(max(j + offsetY, 0), nodeCountY - 1)
  }

  // MARK: The step

  /// Advances the scene by one explicit MLS-MPM substep of length `dt` (s).
  public func step(dt: Double) {
    let h = cellSize, invH = 1 / h, dInv = 4 / (h * h)
    let t = time
    let np = particles.count
    let ncy = nodeCountY

    // Per-particle drag rates and extra accelerations (computed from the committed state and last velocity).
    if particleDragRate.count != np { particleDragRate = Array(repeating: 0, count: np) }
    if particleAcceleration.count != np { particleAcceleration = Array(repeating: .zero, count: np) }
    if particleFieldYieldScale.count != np { particleFieldYieldScale = Array(repeating: 1, count: np) }
    computeParticleForces(time: t)

    // Clear the grid.
    for i in gridMass.indices { gridMass[i] = 0; gridMomentum[i] = .zero; gridVolume[i] = 0; gridDrag[i] = 0 }

    // P2G.
    particles.withUnsafeBufferPointer { ps in
      gridMass.withUnsafeMutableBufferPointer { gm in
        gridMomentum.withUnsafeMutableBufferPointer { gp in
          gridVolume.withUnsafeMutableBufferPointer { gv in
            gridDrag.withUnsafeMutableBufferPointer { gd in
              particleDragRate.withUnsafeBufferPointer { pdr in
                particleAcceleration.withUnsafeBufferPointer { pacc in
                  for pi in 0..<np {
                    let p = ps[pi]
                    let gx = p.position.x * invH, gy = p.position.y * invH
                    let bx = Int((gx - 0.5).rounded(.down)), by = Int((gy - 0.5).rounded(.down))
                    let fx = gx - Double(bx), fy = gy - Double(by)
                    let wx = (0.5 * (1.5 - fx) * (1.5 - fx), 0.75 - (fx - 1) * (fx - 1), 0.5 * (fx - 0.5) * (fx - 0.5))
                    let wy = (0.5 * (1.5 - fy) * (1.5 - fy), 0.75 - (fy - 1) * (fy - 1), 0.5 * (fy - 0.5) * (fy - 0.5))
                    let m = p.mass, k = dt * p.volume * dInv
                    let c = p.velocityGradient
                    let a11 = m * c[0][0] - k * p.stress.x, a12 = m * c[1][0] - k * p.stress.y
                    let a21 = m * c[0][1] - k * p.stress.y, a22 = m * c[1][1] - k * p.stress.z
                    let mv = m * (p.velocity + dt * pacc[pi])
                    let md = m * pdr[pi]
                    for a in 0..<3 {
                      let wa = a == 0 ? wx.0 : (a == 1 ? wx.1 : wx.2)
                      let ix = nodeX(bx + a) * ncy
                      let dx = (Double(a) - fx) * h
                      for b in 0..<3 {
                        let w = wa * (b == 0 ? wy.0 : (b == 1 ? wy.1 : wy.2))
                        let dy = (Double(b) - fy) * h
                        let idx = ix + nodeY(by + b)
                        gm[idx] += w * m
                        gp[idx] += w * (mv + SIMD2(a11 * dx + a12 * dy, a21 * dx + a22 * dy))
                        gv[idx] += w * p.volume
                        gd[idx] += w * md
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // Grid update: velocity, body force, Hele-Shaw drag, walls, boxes.
    var boxImpulse = Array(repeating: SIMD2<Double>.zero, count: boxes.count)
    let walls = self.walls
    let body = self.bodyAcceleration
    let nx = cells.x, ny = cells.y
    for ixs in 0..<nodeCountX {
      let ix = ixs - offsetX
      for iys in 0..<nodeCountY {
        let idx = ixs * ncy + iys
        let m = gridMass[idx]
        guard m > 0 else { gridVelocityStore[idx] = .zero; continue }
        let iy = iys - offsetY
        let xn = SIMD2(Double(ix) * h, Double(iy) * h)
        var v = gridMomentum[idx] / m + dt * body(xn, t)
        if gridDrag[idx] > 0 { v /= (1 + dt * gridDrag[idx] / m) }
        if !scene.periodicY {
          if iy <= 0 { v = applyWall(walls.bottom, v, normal: SIMD2(0, 1)) }
          if iy >= ny { v = applyWall(walls.top, v, normal: SIMD2(0, -1)) }
        }
        if !scene.periodicX {
          if ix <= 0 { v = applyWall(walls.left, v, normal: SIMD2(1, 0)) }
          if ix >= nx { v = applyWall(walls.right, v, normal: SIMD2(-1, 0)) }
        }
        for bi in boxes.indices where boxes[bi].contains(xn) {
          let vc = boxes[bi].constrain(v, at: xn)
          boxImpulse[bi] += m * (v - vc)
          v = vc
        }
        gridVelocityStore[idx] = v
      }
    }
    boxForces = boxImpulse.map { $0 / dt }

    // G2P, advection, then the constitutive update.
    let vmax = scene.speedLimitFactor * h / dt
    let lx = scene.size.x, ly = scene.size.y
    let gvc = scene.gridVolumeCorrection
    let underfill = scene.gridVolumeUnderfillTolerance
    let yieldScales = particleFieldYieldScale
    let ambient = scene.ambientTemperature
    let thermalDecay = ambient != nil && scene.thermalTime > 0 ? 1 - exp(-dt / scene.thermalTime) : 0
    var localCounters = counters
    let mats = materials
    let field = scene.magneticField
    particles.withUnsafeMutableBufferPointer { ps in
      gridVelocityStore.withUnsafeBufferPointer { gvel in
        gridVolume.withUnsafeBufferPointer { gv in
          for pi in 0..<np {
            var p = ps[pi]
            let gx = p.position.x * invH, gy = p.position.y * invH
            let bx = Int((gx - 0.5).rounded(.down)), by = Int((gy - 0.5).rounded(.down))
            let fx = gx - Double(bx), fy = gy - Double(by)
            let wx = (0.5 * (1.5 - fx) * (1.5 - fx), 0.75 - (fx - 1) * (fx - 1), 0.5 * (fx - 0.5) * (fx - 0.5))
            let wy = (0.5 * (1.5 - fy) * (1.5 - fy), 0.75 - (fy - 1) * (fy - 1), 0.5 * (fy - 0.5) * (fy - 0.5))
            var v = SIMD2<Double>.zero
            var c11 = 0.0, c12 = 0.0, c21 = 0.0, c22 = 0.0
            var vol = 0.0
            for a in 0..<3 {
              let wa = a == 0 ? wx.0 : (a == 1 ? wx.1 : wx.2)
              let ix = nodeX(bx + a) * ncy
              let dx = (Double(a) - fx) * h
              for b in 0..<3 {
                let w = wa * (b == 0 ? wy.0 : (b == 1 ? wy.1 : wy.2))
                let dy = (Double(b) - fy) * h
                let idx = ix + nodeY(by + b)
                let vi = gvel[idx]
                v += w * vi
                c11 += w * vi.x * dx; c12 += w * vi.x * dy
                c21 += w * vi.y * dx; c22 += w * vi.y * dy
                vol += w * gv[idx]
              }
            }
            let cMat = simd_double2x2(columns: (SIMD2(c11 * dInv, c21 * dInv), SIMD2(c12 * dInv, c22 * dInv)))
            let speed = simd_length(v)
            if speed > vmax { v *= vmax / speed; localCounters.speedClamps += 1 }
            guard v.x.isFinite, v.y.isFinite, p.state.J.isFinite else {
              localCounters.nonFinite += 1
              p.velocity = .zero; p.velocityGradient = simd_double2x2(0)
              ps[pi] = p
              continue
            }
            p.velocity = v
            p.velocityGradient = cMat
            p.gridVolumeRatio = vol > 0 ? (h * h) / vol : .infinity

            // Advect, wrap periodic axes, keep non-periodic axes inside the guard band.
            var x = p.position + dt * v
            if scene.periodicX { x.x -= lx * (x.x / lx).rounded(.down) } else if x.x < -h || x.x > lx + h {
              x.x = min(max(x.x, -h), lx + h); localCounters.outOfBounds += 1
            }
            if scene.periodicY { x.y -= ly * (x.y / ly).rounded(.down) } else if x.y < -h || x.y > ly + h {
              x.y = min(max(x.y, -h), ly + h); localCounters.outOfBounds += 1
            }
            p.position = x

            let mat = ReferenceSolver2D.fieldScaled(mats[p.material], yieldScales[pi])
            // PB-MPM grid-volume correction (liquids): relax J toward J_grid when the grid says compressed; with
            // `gridVolumeUnderfillTolerance`, an under-filled particle also gives up compression beyond that many
            // body-force kicks |a|·Δt²/Δx (the GPU's two-sided correction, LK-FIX).
            if gvc > 0 && p.gridVolumeRatio < 1 { p.state.J += gvc * (p.gridVolumeRatio - p.state.J) }
            else if gvc > 0, let tol = underfill {
              let floorJ = 1 - tol * simd_length(scene.bodyAcceleration(x, t)) * dt * dt / h
              if p.state.J < floorJ { p.state.J += gvc * (floorJ - p.state.J) }
            }
            // Temperature relaxation toward ambient.
            if let amb = ambient { p.state.temperature += (amb - p.state.temperature) * thermalDecay }
            // MR field lag (first order, T₆₃).
            if let fieldAt = field {
              let target = fieldAt(x, t + dt)
              if let fr = mat.field, fr.responseTime > 0 {
                p.fieldMagnitude += (target - p.fieldMagnitude) * (1 - exp(-dt / fr.responseTime))
              } else {
                p.fieldMagnitude = target
              }
            }
            var diag = EVP.Diagnostics()
            let tau = EVP.update(&p.state, velocityGradient: cMat, dt: dt, material: mat,
                                 fieldMagnitude: p.fieldMagnitude, diagnostics: &diag)
            if diag.determinantGuard { localCounters.determinantGuards += 1 }
            if diag.volumeClamped { localCounters.volumeClamps += 1 }
            localCounters.newtonBisections += diag.bisections
            guard tau.x.isFinite, tau.y.isFinite, tau.z.isFinite else {
              localCounters.nonFinite += 1
              ps[pi] = p
              continue
            }
            p.stress = tau
            p.shearRate = diag.totalRate
            p.jam = diag.jam
            ps[pi] = p
          }
        }
      }
    }
    counters = localCounters
    for bi in boxes.indices { boxes[bi].center += dt * boxes[bi].velocity }
    time += dt
    stepCount += 1
  }

  @inline(__always) private func applyWall(_ wall: ReferenceWall, _ v: SIMD2<Double>, normal: SIMD2<Double>) -> SIMD2<Double> {
    switch wall {
    case .open: return v
    case .sticky(let vw): return vw
    case .slip:
      let vn = simd_dot(v, normal)
      return vn < 0 ? v - vn * normal : v
    }
  }

  /// Hele-Shaw drag rates and the MR Kelvin body force, per particle, from the committed state.
  private func computeParticleForces(time t: Double) {
    let hs = scene.heleShaw
    let field = scene.magneticField
    let h = cellSize
    let mu0 = 4e-7 * Double.pi
    for i in particles.indices {
      let p = particles[i]
      var acc = SIMD2<Double>.zero
      var yieldScale = 1.0
      if let fieldAt = field, let fr = materials[p.material].field, fr.susceptibility > 0 {
        // Kelvin force density μ₀χ|H|∇|H| (linear magnetisation), clamped at 3ρg (§4.8). Where the clamp bites, the
        // field-induced yield is scaled by the same factor (as on the GPU, LK-FIX): the ratio of magnetic drive to
        // magnetic yield stays physical, so MR fluid can still flow to the magnet and heap.
        let e = 0.5 * h
        let hx = (fieldAt(p.position + SIMD2(e, 0), t) - fieldAt(p.position - SIMD2(e, 0), t)) / (2 * e)
        let hy = (fieldAt(p.position + SIMD2(0, e), t) - fieldAt(p.position - SIMD2(0, e), t)) / (2 * e)
        let hm = fieldAt(p.position, t)
        acc = mu0 * fr.susceptibility * hm * SIMD2(hx, hy) / materials[p.material].density
        let cap = 3 * ContinuumPresets.standardGravity
        let am = simd_length(acc)
        if am > cap { yieldScale = cap / am; acc *= yieldScale }
      }
      particleAcceleration[i] = acc
      particleFieldYieldScale[i] = yieldScale
      let m = ReferenceSolver2D.fieldScaled(materials[p.material], yieldScale)
      var rate = 0.0
      switch hs {
      case .none: rate = 0
      case .fixedTime(let tHS)?: rate = tHS > 0 ? 1 / tHS : 0
      case .newtonian(let eta, let b)?: rate = 12 * eta / (m.density * b * b)
      case .gapAveraged(let b, let tMin)?:
        let tHS = ReferenceSolver2D.heleShawTime(material: m, state: p.state, speed: simd_length(p.velocity), gap: b,
                                                 minimumTime: tMin, fieldMagnitude: p.fieldMagnitude)
        rate = tHS > 0 ? 1 / tHS : .infinity
      }
      particleDragRate[i] = rate.isFinite ? rate : 1e30
    }
  }

  /// `m` with its field-induced yield saturation scaled by `s` (before the toy clamp, as on the GPU).
  public static func fieldScaled(_ m: ContinuumMaterial, _ s: Double) -> ContinuumMaterial {
    guard s < 1, m.field != nil else { return m }
    var c = m
    c.field?.yieldSaturation *= s
    return c
  }

  /// Gap-averaged Hele-Shaw drag time t_HS = ρb²/(12·μ_HS) for one particle (§4.10.5), floored at `minimumTime`.
  /// μ_HS = ((2n+1)/(3n))·η_w with η_w = τ_w(γ̇_w)/γ̇_w, γ̇_w = 2(2n+1)Ū/(n·b), and the yield stress scaled by the
  /// material's `wallYieldFactor`. Exact for Newtonian and power-law slot flow; a DST particle uses its blended η.
  public static func heleShawTime(material m: ContinuumMaterial, state s: EVPState, speed: Double, gap b: Double,
                                  minimumTime: Double = 0, fieldMagnitude: Double = 0) -> Double {
    var law = EVP.flowLaw(for: s, material: m, fieldMagnitude: fieldMagnitude)
    law.yieldStress *= m.wallYieldFactor
    let n = law.consistency > 0 ? law.flowIndex : 1
    let u = max(speed, 1e-12)
    let gw = 2 * (2 * n + 1) * u / (n * b)
    let tauW: Double
    if law.fluidity == 0 && !law.failureStress.isFinite && law.consistency > 0 {
      tauW = law.yieldStress + law.consistency * pow(gw, law.flowIndex)       // single HB branch: closed form
    } else if law.consistency == 0 && !law.failureStress.isFinite && law.fluidity > 0 {
      tauW = law.yieldStress + gw / law.fluidity                                // Newtonian (Bingham-like with τ_field)
    } else {
      tauW = law.stress(atRate: gw)
    }
    let muHS = (2 * n + 1) / (3 * n) * tauW / gw
    return max(m.density * b * b / (12 * muHS), minimumTime)
  }

  // MARK: Profiles and diagnostics

  /// Velocities of the grid nodes on row `j` (y = j·Δx) from the last step, x from 0 to Lx (Lx − Δx if periodic).
  public func gridVelocity(atRow j: Int) -> [SIMD2<Double>] {
    let iy = nodeY(j)
    let count = scene.periodicX ? cells.x : cells.x + 1
    return (0..<count).map { gridVelocityStore[nodeX($0) * nodeCountY + iy] }
  }

  /// Mass of the grid nodes on row `j` from the last step.
  public func gridMass(atRow j: Int) -> [Double] {
    let iy = nodeY(j)
    let count = scene.periodicX ? cells.x : cells.x + 1
    return (0..<count).map { gridMass[nodeX($0) * nodeCountY + iy] }
  }

  /// One bin of a particle profile.
  public struct ProfileBin: Sendable {
    public var center: Double
    public var mean: Double
    public var count: Int
  }

  /// Bins particles by coordinate `axis` (0 = x, 1 = y; by `initialPosition` if requested) into `bins` equal bins
  /// over `range` and averages `value` in each. Empty bins have mean 0 and count 0.
  public func profile(axis: Int = 1, bins: Int, range: ClosedRange<Double>, useInitialPosition: Bool = false,
                      _ value: (ReferenceParticle) -> Double) -> [ProfileBin] {
    var sum = Array(repeating: 0.0, count: bins), count = Array(repeating: 0, count: bins)
    let w = (range.upperBound - range.lowerBound) / Double(bins)
    for p in particles {
      let c = (useInitialPosition ? p.initialPosition : p.position)[axis]
      let k = Int(((c - range.lowerBound) / w).rounded(.down))
      guard k >= 0, k < bins else { continue }
      sum[k] += value(p); count[k] += 1
    }
    return (0..<bins).map {
      ProfileBin(center: range.lowerBound + (Double($0) + 0.5) * w, mean: count[$0] > 0 ? sum[$0] / Double(count[$0]) : 0,
                 count: count[$0])
    }
  }

  /// Total particle mass (kg per metre of depth).
  public var totalMass: Double { particles.reduce(0) { $0 + $1.mass } }
  /// Total momentum (kg·m/s per metre of depth).
  public var totalMomentum: SIMD2<Double> { particles.reduce(.zero) { $0 + $1.mass * $1.velocity } }
  /// Kinetic energy (J per metre of depth).
  public var kineticEnergy: Double { particles.reduce(0) { $0 + 0.5 * $1.mass * simd_length_squared($1.velocity) } }

  /// Replaces the particle array (e.g. to impose an initial velocity field or pre-strain); stresses are recomputed.
  public func setParticles(_ new: [ReferenceParticle]) {
    particles = new
    for i in particles.indices {
      particles[i].stress = EVP.kirchhoffStress(particles[i].state, material: materials[particles[i].material])
    }
    particleDragRate = Array(repeating: 0, count: particles.count)
    particleAcceleration = Array(repeating: .zero, count: particles.count)
    particleFieldYieldScale = Array(repeating: 1, count: particles.count)
  }

  /// Mutates particles in place (state, velocity ...); stresses are recomputed from the new states.
  public func modifyParticles(_ body: (inout ReferenceParticle) -> Void) {
    for i in particles.indices {
      body(&particles[i])
      particles[i].stress = EVP.kirchhoffStress(particles[i].state, material: materials[particles[i].material])
    }
  }
}
