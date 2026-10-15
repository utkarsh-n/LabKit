import CoreGraphics
import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPMTypes

/// LabKit's GPU continuum engine: PB-MPM's fused `g2p2g` tile infrastructure (EA SEED, BSD-3, ported to Metal) running
/// the unified elasto-viscoplastic material model of `rheology-models.md` §4 as an XPBD compliant constraint.
///
/// Use from one isolation domain (the main actor in Rheo); not Sendable. Each `encode(into:input:)` encodes every
/// substep of one frame into the caller's command buffer; telemetry comes back through a small ring of shared buffers
/// polled without waiting (`stats` is 1–2 frames old). `fill`, `clear` and `setQuality` take effect at the next encode.
public final class MPMSolver {
  public static let maxMaterials = Int(PB_MAX_MATERIALS)
  public static let maxBodies = 16
  public static let maxColliders = 32

  public let device: MTLDevice
  /// The domain actually simulated (`cellSize` is the effective Δx, `size` a whole number of cells).
  public internal(set) var domain: MPMDomain
  public internal(set) var quality: MPMQuality
  public let capacity: Int
  public let verification: MPMVerificationOptions

  /// Friction of the tank's walls and floor on the grid (`MPMDomain.wallFriction`: 0 free slip … 1 no slip), from the
  /// next encode. Toothpaste Toy grips toothpaste with the floor (13 October 2026), so a pile holds on a tilted floor
  /// until its base yields instead of sliding at any tilt.
  public var wallFriction: Double {
    get { domain.wallFriction }
    set { domain.wallFriction = newValue.isFinite ? min(max(newValue, 0), 1) : domain.wallFriction }
  }
  /// ≤ 16; index = particle material id. Changes apply from the next encode.
  public var materials: [ContinuumMaterial] { didSet { materialTableDirty = true } }
  /// Runtime NaN/overflow reporting: prints when the cumulative counters grow (the guards themselves always run).
  public var debugValidation: Bool
  /// Particle temperature relaxes toward the frame's ambient temperature with this time constant, s (0 = off).
  public var thermalTime: Double = 0
  /// Extra cooling at the free surface: the rate is × (1 + surfaceCooling·(1 − local fill)). Lava crust.
  public var surfaceCooling: Double = 0
  /// Collider skin, in cells: grid nodes this close outside a collider's surface already feel it. Grid-node collision
  /// otherwise acts about half a cell inside each face, which cost buoyancy one cell of body height (0.84 of ρgA at
  /// Δx 2 mm for an 11 mm box). With 1 cell, buoyancy is 0.94–1.06 × ρgA for boxes and discs at Δx 1.1–2 mm in the
  /// recorded run (0.99–1.02 at 1.1 mm; one development run reached 1.12 for a disc at 2 mm; VERIFICATION-GPU.md G4).
  /// A multiple of Δx, not metres. The fluid stays about this far from props: draw props `skin · cellSize` larger, or
  /// shrink collider shapes by it, if the gap shows.
  public var colliderSkin: Double = 1

  /// Telemetry of the latest completed frame (polled without waiting).
  public var stats: MPMStats { poll(); return latest }
  /// All particle slots, `PBParticle` layout (112 bytes, `LabKitMPMTypes`). Disabled slots have flags bit 0 clear.
  public var particleBuffer: MTLBuffer { state.particles }
  /// Particle slots in use as last seen by the CPU (live + freed; may trail the GPU by 1–2 frames). Draw with
  /// `indirectDrawArguments` for the GPU's exact count.
  public var particleCount: Int { min(capacity, max(latest.particleSlots, slotEstimate)) }
  /// `MTLDrawPrimitivesIndirectArguments` (4 vertices, one instance per particle slot) kept current by the GPU.
  public var indirectDrawArguments: (buffer: MTLBuffer, offset: Int) {
    (state.counters, MemoryLayout<PBCounters>.offset(of: \.drawArgs)!)
  }
  /// True when the fused pass reduces body impulses with SIMD-group functions (false: threadgroup-atomic fallback).
  public var usesSIMDGroupReduction: Bool { pipelines.usesSIMDGroupReduction }
  /// Result of the runtime SIMD-group probe (nil when the path was forced by `MPMVerificationOptions`).
  public var simdProbePassed: Bool? { pipelines.simdProbePassed }
  /// Materials that were filled or poured since the last `clear()` (the elastic substep rule uses them).
  public internal(set) var materialsInUse: Set<Int> = []
  /// Simulated time since the solver was created, s.
  public internal(set) var simulatedTime: Double = 0

  // MARK: Internal state
  let pipelines: MPMPipelines
  let queue: MTLCommandQueue
  var state: MPMState
  var layout: MPMGridLayout { state.layout }
  var slots: [FrameSlot] = []
  var latest = MPMStats()
  var frameIndex = 0
  var globalSubstep: UInt32 = 0
  var lastSubstepDt: Double = 0
  /// The gravity kick (cells per substep) already inside every particle's stored displacement after the last frame.
  var lastGravityKick = SIMD2<Float>(0, 0)
  var materialTable: [PBMaterial] = []
  var materialTableDirty = true
  var pendingInject: [PendingParticle] = []
  var pendingClear = false
  var needsRebin = false
  var slotEstimate = 0
  var liveEstimate = 0
  var lastInjectFrame = 0
  var laggedField: Double = 0
  var laggedMagnet: Double = 0
  private var reportedNaN = 0, reportedOverflow = 0
  var pendingQuality: MPMQuality?
  var resample: ResampleJob?
  var fillSerial: UInt32 = 0
  /// The tank size passed at init (a quality switch re-fits the cells to it).
  let requestedSize: SIMD2<Double>

  struct PendingParticle {
    var position: SIMD2<Double>   // m
    var velocity: SIMD2<Double>   // m/s
    var material: Int
    var band: Int = 0             // stripe dye band, 0 = none (PBParticle.flags bits 8–11)
    var temperature: Double
    var structure: Double
    var tag: Float
    var carried: PBParticle?      // resampled state (b̄e, J, λ, f, …) to keep
  }

  final class FrameSlot {
    var upload: MTLBuffer
    let readback: MTLBuffer
    var commandBuffer: MTLCommandBuffer?
    var meta = FrameMeta()
    init(upload: MTLBuffer, readback: MTLBuffer) { self.upload = upload; self.readback = readback }
  }
  struct FrameMeta {
    var frameIndex = 0
    var substeps = 0
    var lagging = false
    var dt = 0.0
    var dx = 0.0
    var simulatedTime = 0.0
    var depthFactor = 1.0
    var sampledGridMass = false
    var shapeBodies: [(body: Int, position: SIMD2<Double>)] = []   // per GPU shape slot, frame-start position (m)
  }
  final class ResampleJob {
    let commandBuffer: MTLCommandBuffer
    let particles: MTLBuffer
    let counters: MTLBuffer
    let fromLayout: MPMGridLayout
    let dt: Double
    let quality: MPMQuality
    var cleared = false
    init(commandBuffer: MTLCommandBuffer, particles: MTLBuffer, counters: MTLBuffer, fromLayout: MPMGridLayout, dt: Double,
         quality: MPMQuality) {
      self.commandBuffer = commandBuffer; self.particles = particles; self.counters = counters
      self.fromLayout = fromLayout; self.dt = dt; self.quality = quality
    }
  }

  static let readbackStatsOffset = 0
  static let readbackCountersOffset = 128
  static let readbackImpulseOffset = 256
  static let readbackLength = 256 + Int(PB_MAX_SHAPES) * 16
  static let materialBlock = Int(PB_MAX_MATERIALS) * MemoryLayout<PBMaterial>.stride            // 3,328 B
  static let shapeBlock = Int(PB_MAX_SHAPES) * MemoryLayout<PBShape>.stride                     // 3,072 B

  // MARK: Init

  public init(device: MTLDevice, domain: MPMDomain, quality: MPMQuality, capacity: Int,
              verification: MPMVerificationOptions = MPMVerificationOptions()) throws {
    precondition(MemoryLayout<PBParticle>.stride == 112 && MemoryLayout<PBMaterial>.stride == 208
                 && MemoryLayout<PBShape>.stride == 64 && MemoryLayout<PBSimConstants>.stride == 192,
                 "MPMShared.h layout changed")
    guard let q = device.makeCommandQueue() else { throw MPMError.metal("cannot create a command queue") }
    self.device = device
    self.queue = q
    self.capacity = max(capacity, 1)
    self.verification = verification
    self.quality = quality
    self.requestedSize = domain.size
    self.materials = [ContinuumPresets.waterLike]
    #if DEBUG
    self.debugValidation = true
    #else
    self.debugValidation = false
    #endif
    pipelines = try MPMPipelines(device: device, queue: q, forceSIMD: verification.useSIMDGroupReduction)
    let l = MPMGridLayout(size: domain.size, cellSize: quality.cellSize,
                          periodicX: verification.periodicX, periodicY: verification.periodicY)
    state = try MPMState(device: device, layout: l, capacity: self.capacity, particles: [])
    var d = domain
    d.cellSize = l.dx
    d.size = l.size
    self.domain = d
  }

  // MARK: Particles

  /// Seeds 2 × 2 particles per cell, at rest, at the lattice sites inside `rect` (m, tank frame; half-open). Returns the
  /// number of particles queued; they enter the simulation at the next encode.
  ///
  /// `stripes` > 0 dyes the fill in that many equal-width bands (1…`stripes`, as an `MPMEmitter`'s) across the
  /// shape's extent along the unit vector `across` (default x: vertical stripes), numbered from its low end.
  @discardableResult
  public func fill(rect: CGRect, material: Int, temperature: Double, structure: Double = 1, stripes: Int = 0,
                   across: SIMD2<Double> = SIMD2(1, 0)) -> Int {
    let r = rect.standardized
    return seed(bounds: (SIMD2(Double(r.minX), Double(r.minY)), SIMD2(Double(r.maxX), Double(r.maxY))),
                material: material, temperature: temperature, structure: structure,
                stripes: stripes, across: across) { p in
      p.x >= Double(r.minX) && p.x < Double(r.maxX) && p.y >= Double(r.minY) && p.y < Double(r.maxY)
    }
  }

  /// Seeds 2 × 2 particles per cell at the lattice sites inside `polygon` (m; even-odd rule). `stripes` and `across`
  /// as for `fill(rect:…)`, over the polygon's vertices' extent along `across` (a ribbon: `across` its width).
  @discardableResult
  public func fill(polygon: [SIMD2<Double>], material: Int, temperature: Double, structure: Double = 1,
                   stripes: Int = 0, across: SIMD2<Double> = SIMD2(1, 0)) -> Int {
    guard polygon.count >= 3 else { return 0 }
    var lo = polygon[0], hi = polygon[0]
    for v in polygon { lo = simd_min(lo, v); hi = simd_max(hi, v) }
    return seed(bounds: (lo, hi), material: material, temperature: temperature, structure: structure,
                stripes: stripes, across: across, extent: polygon) { p in
      var inside = false
      var j = polygon.count - 1
      for i in 0..<polygon.count {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
      }
      return inside
    }
  }

  private func seed(bounds: (SIMD2<Double>, SIMD2<Double>), material: Int, temperature: Double, structure: Double,
                    stripes: Int = 0, across: SIMD2<Double> = SIMD2(1, 0), extent: [SIMD2<Double>]? = nil,
                    inside: (SIMD2<Double>) -> Bool) -> Int {
    let l = layout
    let dx = l.dx
    // Stripe dye: the shape's extent along `across` split into equal bands 1…n.
    let bands = min(max(stripes, 0), MPMEmitter.maxStripes)
    let axis = simd_length(across) > 1e-12 ? simd_normalize(across) : SIMD2<Double>(1, 0)
    let corners = extent ?? [bounds.0, SIMD2(bounds.1.x, bounds.0.y), bounds.1, SIMD2(bounds.0.x, bounds.1.y)]
    let lowEnd = corners.map { simd_dot($0, axis) }.min() ?? 0
    let span = max((corners.map { simd_dot($0, axis) }.max() ?? 0) - lowEnd, 1e-12)
    func band(_ site: SIMD2<Double>) -> Int {
      guard bands > 0 else { return 0 }
      let t = min(max((simd_dot(site, axis) - lowEnd) / span, 0), 0.999_999)
      return min(Int(t * Double(bands)), bands - 1) + 1
    }
    let i0 = max(0, Int(floor(bounds.0.x / dx))), i1 = min(l.interior.x - 1, Int(floor(bounds.1.x / dx)))
    let j0 = max(0, Int(floor(bounds.0.y / dx))), j1 = min(l.interior.y - 1, Int(floor(bounds.1.y / dx)))
    guard i0 <= i1, j0 <= j1 else { return 0 }
    fillSerial &+= 1
    var n = 0
    for j in j0...j1 {
      for i in i0...i1 {
        for sj in 0..<Int(PB_PPC_AXIS) {
          for si in 0..<Int(PB_PPC_AXIS) {
            let site = SIMD2(Double(i) + (Double(si) + 0.5) / Double(PB_PPC_AXIS),
                             Double(j) + (Double(sj) + 0.5) / Double(PB_PPC_AXIS)) * dx
            guard inside(site) else { continue }
            let h = Self.hash(UInt32(truncatingIfNeeded: i &* 4 + si), UInt32(truncatingIfNeeded: j &* 4 + sj), UInt32(material))
            let jitter = SIMD2(Double(h & 0xFF) / 255 - 0.5, Double((h >> 8) & 0xFF) / 255 - 0.5) * 0.2 * dx
            let tag = Float(Self.hash(h, fillSerial, 0x9E37_79B9) & 0xFF_FFFF) / Float(1 << 24)
            pendingInject.append(PendingParticle(position: site + jitter, velocity: .zero, material: material,
                                                 band: band(site),
                                                 temperature: temperature, structure: min(max(structure, 0), 1),
                                                 tag: tag, carried: nil))
            n += 1
          }
        }
      }
    }
    if n > 0 { materialsInUse.insert(material) }
    return n
  }

  /// Removes every particle (at the next encode).
  public func clear() {
    pendingClear = true
    pendingInject.removeAll()
    materialsInUse.removeAll()
    slotEstimate = 0
    liveEstimate = 0
    resample?.cleared = true
  }

  /// Switches resolution. The current fluid is copied back from the GPU at the next encode and resampled onto the new
  /// grid when that frame completes (no CPU wait); until then the old grid keeps running.
  public func setQuality(_ q: MPMQuality) {
    if q.cellSize == quality.cellSize && resample == nil && pendingQuality == nil {
      quality = q
      return
    }
    pendingQuality = q
  }

  /// Copies the particle buffer (call only when no frame that uses it is in flight): SI positions and velocities.
  public func debugParticles() -> [MPMParticleSnapshot] {
    let n = min(state.counters.contents().load(as: PBCounters.self).particleCount, UInt32(capacity))
    let p = state.particles.contents().bindMemory(to: PBParticle.self, capacity: capacity)
    let dtSub = lastSubstepDt > 0 ? lastSubstepDt : 1
    var out: [MPMParticleSnapshot] = []
    out.reserveCapacity(Int(n))
    for i in 0..<Int(n) {
      let q = p[i]
      out.append(MPMParticleSnapshot(
        enabled: q.flags & PB_FLAG_ENABLED != 0,
        position: layout.toMetres(SIMD2(Double(q.position.x), Double(q.position.y))),
        velocity: SIMD2(Double(q.displacement.x), Double(q.displacement.y)) * layout.dx / dtSub,
        material: Int(q.material), volumeRatio: Double(q.liquidDensity), structure: Double(q.structure),
        contact: Double(q.contact), temperature: Double(q.temperature), stress: Double(q.stress),
        viscosity: Double(q.viscosity), shearRate: Double(q.shearRate), plasticRate: Double(q.elastic.w),
        elastic: SIMD3(Double(q.elastic.x), Double(q.elastic.y), Double(q.elastic.z)),
        displacementCells: SIMD2(Double(q.displacement.x), Double(q.displacement.y)),
        positionCells: SIMD2(Double(q.position.x), Double(q.position.y)),
        band: Int((q.flags >> PB_DYE_SHIFT) & PB_DYE_MASK)))
    }
    return out
  }

  /// The top of the paste in a vertical strip: the highest live particle with |x − `x`| ≤ `halfWidth`, below `ceiling`
  /// (m), moving slower than `maxSpeed` (m/s; `.infinity` counts every particle: a slow particle has landed, one falling
  /// or being dragged has not) and whose x is outside `excludingX` (m; nil excludes nothing). It reads the
  /// shared particle buffer directly, without copying it or waiting, so a frame in flight may make it a frame old; that
  /// is fine for placing things above the paste (Toothpaste Toy's tube rides on top of its stack). nil when the strip is
  /// empty. Cost: one pass over the particle slots in use.
  public func columnTop(x: Double, halfWidth: Double, below ceiling: Double = .infinity,
                        maxSpeed: Double = .infinity, excludingX excluded: ClosedRange<Double>? = nil) -> Double? {
    let n = min(max(particleCount, Int(state.counters.contents().load(as: PBCounters.self).particleCount)), capacity)
    guard n > 0 else { return nil }
    let p = state.particles.contents().bindMemory(to: PBParticle.self, capacity: capacity)
    let l = layout
    let dx = l.dx
    // Cells: compare in the GPU's own units (one conversion of the limits, none per particle).
    let cx = l.toCells(SIMD2(x, 0)).x
    let cTop = ceiling.isFinite ? l.toCells(SIMD2(0, ceiling)).y : .infinity
    let hw = halfWidth / dx
    // Speeds in cells per substep (the stored displacement carries the next substep's gravity kick, which is taken
    // off; it is far below any useful threshold anyway).
    let maxD = maxSpeed.isFinite && lastSubstepDt > 0 ? maxSpeed * lastSubstepDt / dx : Double.infinity
    let maxD2 = maxD * maxD
    let kick = SIMD2<Double>(Double(lastGravityKick.x), Double(lastGravityKick.y))
    let ex = excluded.map { (l.toCells(SIMD2($0.lowerBound, 0)).x, l.toCells(SIMD2($0.upperBound, 0)).x) }
    var best = -Double.infinity
    for i in 0..<n {
      let q = p[i]
      guard q.flags & PB_FLAG_ENABLED != 0 else { continue }
      let px = Double(q.position.x), py = Double(q.position.y)
      guard abs(px - cx) <= hw, py < cTop, py > best else { continue }
      if maxD.isFinite {
        let d = SIMD2(Double(q.displacement.x), Double(q.displacement.y)) - kick
        if simd_length_squared(d) > maxD2 { continue }
      }
      if let ex, px >= ex.0, px <= ex.1 { continue }
      best = py
    }
    guard best.isFinite else { return nil }
    return l.toMetres(SIMD2(cx, best)).y
  }

  /// Edits particle slots in place (tests and harnesses only: call when no frame that uses the buffer is in flight).
  /// The closure gets each live slot in the GPU's own layout (cells, cells per substep of the last frame).
  public func debugModifyParticles(_ body: (inout PBParticle) -> Void) {
    let n = Int(min(state.counters.contents().load(as: PBCounters.self).particleCount, UInt32(capacity)))
    let p = state.particles.contents().bindMemory(to: PBParticle.self, capacity: capacity)
    for i in 0..<n where p[i].flags & PB_FLAG_ENABLED != 0 { body(&p[i]) }
  }

  /// Verification: sets every live particle's velocity (m/s) and, optionally, its velocity gradient C (1/s; c12 = ∂vx/∂y
  /// = C[1][0]) from fields of the particle's position (m), for frames whose substep will last `substep` seconds (the
  /// next encode must use that substep length, e.g. `fixedSubsteps`). Call with no frame in flight.
  public func debugSetVelocity(substep dt: Double, velocity: (SIMD2<Double>) -> SIMD2<Double>,
                               gradient: ((SIMD2<Double>) -> simd_double2x2)? = nil) {
    let l = layout
    debugModifyParticles { p in
      let x = l.toMetres(SIMD2(Double(p.position.x), Double(p.position.y)))
      p.displacement = SIMD2<Float>(velocity(x) * dt / l.dx)
      if let g = gradient {
        let c = g(x) * dt
        p.deformationDisplacement = simd_float2x2(SIMD2<Float>(Float(c[0][0]), Float(c[0][1])), SIMD2<Float>(Float(c[1][0]), Float(c[1][1])))
      }
    }
    lastSubstepDt = dt
    lastGravityKick = .zero
  }

  /// Converts SI to the solver's cell units for `debugModifyParticles`: position (m) → cells; velocity (m/s) → cells per
  /// substep of the last encoded frame.
  public func debugCells(position: SIMD2<Double>) -> SIMD2<Float> { SIMD2<Float>(layout.toCells(position)) }
  public func debugDisplacement(velocity: SIMD2<Double>) -> SIMD2<Float> {
    SIMD2<Float>(velocity * (lastSubstepDt > 0 ? lastSubstepDt : 0) / layout.dx)
  }
  /// Substep length of the last encoded frame, s.
  public var lastSubstepLength: Double { lastSubstepDt }

  /// The effective cell size Δx, m.
  public var cellSize: Double { layout.dx }
  /// Cells across the tank (width, height).
  public var interiorCells: SIMD2<Int> { layout.interior }

  // MARK: Polling

  /// Reads every completed readback slot (never waits).
  func poll() {
    for slot in slots {
      guard let cb = slot.commandBuffer else { continue }
      switch cb.status {
      case .completed:
        if slot.meta.frameIndex > latest.frameIndex { latest = makeStats(slot, gpu: cb) }
        slot.commandBuffer = nil
      case .error:
        slot.commandBuffer = nil
      default:
        break
      }
    }
    if latest.frameIndex >= lastInjectFrame { liveEstimate = latest.liveParticles }
    if debugValidation && (latest.nanCount > reportedNaN || latest.overflowCount > reportedOverflow) {
      print("LabKitMPM: frame \(latest.frameIndex): NaN resets \(latest.nanCount), fixed-point overflows \(latest.overflowCount) (cumulative)")
      reportedNaN = latest.nanCount
      reportedOverflow = latest.overflowCount
    }
  }

  private func makeStats(_ slot: FrameSlot, gpu cb: MTLCommandBuffer) -> MPMStats {
    let raw = slot.readback.contents()
    let s = raw.load(fromByteOffset: Self.readbackStatsOffset, as: PBStats.self)
    let c = raw.load(fromByteOffset: Self.readbackCountersOffset, as: PBCounters.self)
    let m = slot.meta
    var out = MPMStats()
    out.frameIndex = m.frameIndex
    let live = Int(s.liveCount)
    out.liveParticles = live
    out.maxSpeed = Double(Float(bitPattern: s.maxSpeedBits))
    out.kineticEnergy = Double(s.sumKinetic) * m.depthFactor
    out.meanViscosity = s.yieldMass > 0 ? pow(10, Double(s.yieldMassLogEta) / Double(s.yieldMass)) : 0
    if live > 0 {
      out.yieldedFraction = Double(s.yieldedCount) / Double(live)
      out.jammedFraction = Double(s.jammedCount) / Double(live)
      out.volumeRatio = Double(s.sumJ) / Double(live)
      out.meanStructure = Double(s.sumStructure) / Double(live)
      out.meanTemperature = Double(s.sumTemperature) / Double(live)
    }
    if s.probeWeight > 0 {
      let w = Double(s.probeWeight)
      let rate = Double(s.probeShear) / w, stress = Double(s.probeStress) / w
      out.probe = (rate, stress, stress / max(rate, 1e-6), Double(s.probeSolid) / w)
    }
    let unitMass = MPMConstants.referenceDensity * m.dx * m.dx * m.depthFactor          // kg per grid mass unit
    out.particleMass = Double(s.sumMass) * unitMass
    if m.sampledGridMass {
      let g = s.gridMass
      out.gridMass = (Double(g.1) * 65536 + Double(g.0)) / Double(PB_FIXED_SCALE) * unitMass
    }
    // Body impulses: grid momentum units -> N·s (× depth), torques transferred to each body's reference point.
    let toImpulse = MPMConstants.referenceDensity * pow(m.dx, 3) / max(m.dt, 1e-12) * m.depthFactor
    let toAngular = toImpulse * m.dx
    var bodies = Array(repeating: SIMD3<Double>.zero, count: Self.maxBodies)
    var reference: [Int: SIMD2<Double>] = [:]
    let imp = raw.advanced(by: Self.readbackImpulseOffset).bindMemory(to: Int32.self, capacity: Int(PB_MAX_SHAPES) * 4)
    for (i, sb) in m.shapeBodies.enumerated() where sb.body >= 0 && sb.body < Self.maxBodies {
      let jx = Double(imp[i * 4]) / Double(PB_IMPULSE_SCALE) * toImpulse
      let jy = Double(imp[i * 4 + 1]) / Double(PB_IMPULSE_SCALE) * toImpulse
      var l = Double(imp[i * 4 + 2]) / Double(PB_IMPULSE_SCALE) * toAngular
      let ref = reference[sb.body] ?? sb.position
      reference[sb.body] = ref
      let arm = sb.position - ref
      l += arm.x * jy - arm.y * jx
      bodies[sb.body] += SIMD3(jx, jy, l)
    }
    out.bodyImpulses = bodies
    out.substeps = m.substeps
    out.lagging = m.lagging
    out.simulatedTime = m.simulatedTime
    out.overflowCount = Int(c.overflow)
    out.nanCount = Int(c.nanResets)
    out.clampedDisplacements = Int(c.clamped)
    out.determinantGuards = Int(c.detClamps)
    out.emitted = Int(c.emitted)
    out.drained = Int(c.drained)
    out.droppedOnInject = Int(c.injectDropped)
    out.impulseOverflowCount = Int(c.impulseOverflow)
    out.particleSlots = Int(c.particleCount)
    out.gpuMilliseconds = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
    return out
  }

  // MARK: Helpers

  static func hash(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
    var h = a &* 0x9E37_79B1 ^ (b &* 0x85EB_CA77) ^ (c &* 0xC2B2_AE3D)
    h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
    return h
  }

  func acquireSlot(uploadLength: Int) -> FrameSlot {
    let need = max(uploadLength, 4096)
    if let s = slots.first(where: { $0.commandBuffer == nil }) {
      if s.upload.length < need, let b = device.makeBuffer(length: need * 2, options: .storageModeShared) { s.upload = b }
      return s
    }
    let up = device.makeBuffer(length: need * 2, options: .storageModeShared)!
    let rb = device.makeBuffer(length: Self.readbackLength, options: .storageModeShared)!
    let s = FrameSlot(upload: up, readback: rb)
    slots.append(s)
    return s
  }

  func refreshMaterialTable() {
    guard materialTableDirty else { return }
    var table: [PBMaterial] = []
    let fallback = materials.first ?? ContinuumPresets.waterLike
    for i in 0..<Self.maxMaterials {
      let m = i < materials.count ? materials[i] : fallback
      table.append(PBMaterial.make(m, nativeViscosity: verification.nativeViscosity[i]))
    }
    materialTable = table
    materialTableDirty = false
  }

  // MARK: Encode (substeps, injection, readback): MPMSolver+Encode.swift
}

/// One particle as SI values (tests and harnesses).
public struct MPMParticleSnapshot: Sendable {
  public var enabled: Bool
  public var position: SIMD2<Double>       // m
  public var velocity: SIMD2<Double>       // m/s, includes the next substep's gravity kick
  public var material: Int
  public var volumeRatio: Double           // J
  public var structure: Double             // λ
  public var contact: Double               // f
  public var temperature: Double           // K
  public var stress: Double                // τ̄, Pa
  public var viscosity: Double             // secant, Pa·s (1e30 = unyielded)
  public var shearRate: Double             // 1/s
  public var plasticRate: Double           // 1/s
  public var elastic: SIMD3<Double>        // b̄e (b11, b12, b22)
  public var displacementCells: SIMD2<Double>
  public var positionCells: SIMD2<Double>
  /// Stripe dye band: 0 = none, 1…7 (`PBParticle.flags` bits 8–11; `MPMEmitter.stripes`, `fill(…stripes:)`).
  public var band: Int = 0
}

/// GPU buffers of one grid layout.
final class MPMState {
  let layout: MPMGridLayout
  let particles, counters, freeIndices, bukkitCounts, insertCounters, dispatch, threadData, indexStart, bukkitParticles: MTLBuffer
  let grids: [MTLBuffer]
  let dummy: MTLBuffer

  init(device: MTLDevice, layout: MPMGridLayout, capacity: Int, particles ps: [PBParticle]) throws {
    self.layout = layout
    func buf(_ n: Int) throws -> MTLBuffer {
      guard let b = device.makeBuffer(length: max(n, 16), options: .storageModeShared) else {
        throw MPMError.metal("cannot allocate \(n) bytes")
      }
      memset(b.contents(), 0, b.length)
      return b
    }
    let nb = layout.bukkits
    let pb = try buf(capacity * MemoryLayout<PBParticle>.stride)
    let n = min(ps.count, capacity)
    if n > 0 { ps.withUnsafeBytes { _ = memcpy(pb.contents(), $0.baseAddress!, n * MemoryLayout<PBParticle>.stride) } }
    particles = pb
    let cb = try buf(MemoryLayout<PBCounters>.stride)
    counters = cb
    cb.contents().bindMemory(to: PBCounters.self, capacity: 1).pointee.particleCount = UInt32(n)
    freeIndices = try buf(capacity * 4)
    bukkitCounts = try buf(nb * 4)
    insertCounters = try buf(nb * 4)
    let db = try buf(2 * MemoryLayout<PBBukkitDispatch>.stride)
    dispatch = db
    let d = db.contents().bindMemory(to: PBBukkitDispatch.self, capacity: 2)
    for i in 0..<2 { d[i] = PBBukkitDispatch(groupsX: 0, groupsY: 1, groupsZ: 1, particleAllocator: 0) }
    threadData = try buf((nb + capacity / Int(PB_TILE_NODES) + 1) * MemoryLayout<PBBukkitThreadData>.stride)
    indexStart = try buf(nb * 4)
    bukkitParticles = try buf(capacity * 4)
    grids = [try buf(layout.nodeCount * 16), try buf(layout.nodeCount * 16), try buf(layout.nodeCount * 16)]
    dummy = try buf(256)
  }
}
