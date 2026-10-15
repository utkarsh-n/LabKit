import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPMTypes

extension MPMSolver {
  /// Encodes every substep of one frame (`mpm-metal.md` §6.1) into `cmd`, plus the frame's telemetry readback. Never
  /// waits on the GPU.
  public func encode(into cmd: MTLCommandBuffer, input: MPMFrameInput) {
    poll()
    finishQualitySwitchIfReady()
    refreshMaterialTable()
    let l = layout
    let dx = l.dx
    let opts = verification
    let clearing = pendingClear
    let injecting = pendingInject
    let rebin = needsRebin || clearing || !injecting.isEmpty
    pendingClear = false
    pendingInject.removeAll(keepingCapacity: true)
    needsRebin = false

    // ---- Plan the frame: substeps, dt, time dilation (MPMSubstepRule)
    let T = min(max(input.dt.isFinite ? input.dt : 0, 0), 1.0 / 15)
    let gBase = input.gravity - input.frameAcceleration
    let vibA = abs(input.vibration.amplitude), vibF = max(input.vibration.frequency, 0)
    let explicitMode = opts.explicitParity
    let iterations = explicitMode ? 1 : max(quality.iterations, 1)
    var inUse = materialsInUse
    for e in input.emitters { inUse.insert(e.material); materialsInUse.insert(e.material) }
    let shearWave = inUse.compactMap { $0 < materials.count ? materials[$0] : nil }
      .map { ($0.shearModulus / max($0.density, 1)).squareRoot() }.max() ?? 0
    let count = (clearing ? 0 : liveEstimate) + injecting.count
    let area = Double(count) * 0.25 * dx * dx
    let gl = simd_length(gBase)
    let chord = gl > 1e-6 ? l.size.x * abs(gBase.y / gl) + l.size.y * abs(gBase.x / gl) : l.size.x
    let depth = min(area / max(chord, dx), simd_length(l.size))
    var q = quality
    q.iterations = iterations
    let peak = simd_length(input.gravity) + simd_length(input.frameAcceleration) + vibA
    // The magnet's capped Kelvin potential is extra hydrostatic head for the materials it pulls (Π rule).
    var magneticHead = 0.0
    if let mag = input.magnet, mag.strength > 0 {
      for i in inUse where i < materials.count {
        guard let fr = materials[i].field, fr.susceptibility > 0 else { continue }
        magneticHead = max(magneticHead, MPMConstants.kelvinHead(
          magnet: mag.position, strength: max(laggedMagnet, mag.strength), susceptibility: fr.susceptibility,
          density: materials[i].density, tank: l.size, depth: depth))
      }
    }
    var rule = MPMSubstepRule.plan(frameTime: T, cellSize: dx, peakAcceleration: peak,
                                   depth: depth + magneticHead / max(peak, 1e-6), maxSpeed: latest.maxSpeed,
                                   vibrationFrequency: vibF, shearWaveSpeed: shearWave, quality: q)
    if let fixed = opts.fixedSubsteps {
      rule.substeps = max(fixed, 1); rule.simulatedTime = T; rule.lagging = false
    }
    let S = T > 0 ? rule.substeps : 0
    let dt = S > 0 ? rule.simulatedTime / Double(S) : (lastSubstepDt > 0 ? lastSubstepDt : 1.0 / 1200)
    let dtRatio = (S > 0 && lastSubstepDt > 0) ? dt / lastSubstepDt : 1

    // ---- Field lag (first order, T63 of the slowest field-responsive material in use), per frame on the CPU
    let t63 = inUse.compactMap { $0 < materials.count ? materials[$0].field?.responseTime : nil }.max() ?? 0
    let lagK = t63 > 0 ? 1 - exp(-rule.simulatedTime / t63) : 1
    laggedField += (simd_length(input.magneticField) - laggedField) * lagK
    laggedMagnet += ((input.magnet?.strength ?? 0) - laggedMagnet) * lagK

    // ---- Shapes: colliders (≤ 32), drains, emitters; frame-start pose extrapolated per substep
    struct ShapeSpec { var shape: PBShape; var velocity: SIMD2<Double>; var angularVelocity: Double; var position: SIMD2<Double>; var angle: Double }
    var specs: [ShapeSpec] = []
    var shapeBodies: [(body: Int, position: SIMD2<Double>)] = []
    for col in input.colliders.prefix(Self.maxColliders) {
      var s = PBShape()
      s.functionality = UInt32(PB_FN_COLLIDER)
      switch col.shape {
      case .circle(let r): s.shapeType = UInt32(PB_SHAPE_CIRCLE); s.radius = Float(r / dx)
      case .box(let h): s.shapeType = UInt32(PB_SHAPE_BOX); s.halfSize = SIMD2<Float>(h / dx); s.radius = 0
      case .capsule(let hl, let r): s.shapeType = UInt32(PB_SHAPE_CAPSULE); s.halfSize = SIMD2(Float(hl / dx), 0); s.radius = Float(r / dx)
      }
      s.friction = Float(max(col.friction, 0))
      let body = (col.bodyIndex.map { $0 >= 0 && $0 < Self.maxBodies ? $0 : -1 }) ?? -1
      s.bodyIndex = Int32(body)
      specs.append(ShapeSpec(shape: s, velocity: col.velocity, angularVelocity: col.angularVelocity, position: col.position, angle: col.angle))
      shapeBodies.append((body, col.position))
    }
    for d in input.drains where specs.count < Int(PB_MAX_SHAPES) {
      var s = PBShape()
      s.functionality = UInt32(PB_FN_DRAIN); s.shapeType = UInt32(PB_SHAPE_CIRCLE); s.radius = Float(d.radius / dx); s.bodyIndex = -1
      specs.append(ShapeSpec(shape: s, velocity: .zero, angularVelocity: 0, position: d.position, angle: 0))
      shapeBodies.append((-1, d.position))
    }
    for g in input.grips where specs.count < Int(PB_MAX_SHAPES) {
      var s = PBShape()
      s.functionality = UInt32(PB_FN_GRIP)
      switch g.shape {
      case .circle(let r): s.shapeType = UInt32(PB_SHAPE_CIRCLE); s.radius = Float(r / dx)
      case .box(let h): s.shapeType = UInt32(PB_SHAPE_BOX); s.halfSize = SIMD2<Float>(h / dx); s.radius = 0
      case .capsule(let hl, let r): s.shapeType = UInt32(PB_SHAPE_CAPSULE); s.halfSize = SIMD2(Float(hl / dx), 0); s.radius = Float(r / dx)
      }
      let body = (g.bodyIndex.map { $0 >= 0 && $0 < Self.maxBodies ? $0 : -1 }) ?? -1
      s.bodyIndex = Int32(body)
      specs.append(ShapeSpec(shape: s, velocity: g.velocity, angularVelocity: 0, position: g.position, angle: g.angle))
      shapeBodies.append((body, g.position))
    }
    var emitting = false
    for e in input.emitters where specs.count < Int(PB_MAX_SHAPES) && e.rate > 0 && e.material >= 0 && e.material < Self.maxMaterials {
      var s = PBShape()
      s.functionality = UInt32(PB_FN_EMIT); s.shapeType = UInt32(PB_SHAPE_CIRCLE); s.radius = Float(e.radius / dx); s.bodyIndex = -1
      s.emitMaterial = UInt32(e.material) | (UInt32(min(max(e.stripes, 0), MPMEmitter.maxStripes)) << PB_DYE_SHIFT)
      var slotsInShape = max(4 * Double.pi * e.radius * e.radius / (dx * dx), 1)
      var angle = 0.0
      if let length = e.slotLength, length > 0 {
        // A slot: a box `radius` across (local x, the velocity turned +90°) and `length / 2` along the velocity. Its
        // area counts whole lattice rows: the cells whose centres it covers (at least one row).
        let v = simd_length(e.velocity) > 1e-12 ? simd_normalize(e.velocity) : SIMD2<Double>(0, -1)
        angle = atan2(v.x, -v.y)
        s.shapeType = UInt32(PB_SHAPE_BOX)
        s.halfSize = SIMD2<Float>(Float(e.radius / dx), Float(length / 2 / dx))
        s.radius = 0
        slotsInShape = max(4 * (2 * e.radius / dx) * max((length / dx).rounded(), 1), 1)
      }
      s.emissionRate = Float(e.rate / slotsInShape)
      s.emitTemperature = Float(e.temperature ?? 0)
      specs.append(ShapeSpec(shape: s, velocity: e.velocity, angularVelocity: 0, position: e.position, angle: angle))
      shapeBodies.append((-1, e.position))
      emitting = true
    }

    // ---- Upload slot: materials, shapes per substep, inject staging
    let shapeBase = Self.materialBlock
    let injectOffset = shapeBase + Self.shapeBlock * max(S, 1)
    let injectBytes = injecting.count * MemoryLayout<PBParticle>.stride
    let slot = acquireSlot(uploadLength: injectOffset + injectBytes)
    let up = slot.upload.contents()
    materialTable.withUnsafeBytes { _ = memcpy(up, $0.baseAddress!, min($0.count, Self.materialBlock)) }
    for s in 0..<max(S, 1) {
      let t = (Double(s) + 0.5) * dt
      let dst = up.advanced(by: shapeBase + s * Self.shapeBlock).bindMemory(to: PBShape.self, capacity: Int(PB_MAX_SHAPES))
      for (i, spec) in specs.enumerated() {
        var sh = spec.shape
        sh.position = SIMD2<Float>(l.toCells(spec.position + spec.velocity * t))
        sh.rotation = Float(spec.angle + spec.angularVelocity * t)
        sh.velocity = SIMD2<Float>(spec.velocity * dt / dx)
        sh.angularVelocity = Float(spec.angularVelocity * dt)
        dst[i] = sh
      }
    }
    if !injecting.isEmpty {
      let dst = up.advanced(by: injectOffset).bindMemory(to: PBParticle.self, capacity: injecting.count)
      for (i, pp) in injecting.enumerated() { dst[i] = makeParticle(pp, layout: l, dt: dt, dtRatio: dtRatio) }
    }
    memset(slot.readback.contents(), 0, slot.readback.length)

    // ---- Constants
    var c = PBSimConstants()
    c.gridSize = SIMD2(UInt32(l.gridSize.x), UInt32(l.gridSize.y))
    c.bukkitCount = SIMD2(UInt32(l.bukkitCount.x), UInt32(l.bukkitCount.y))
    c.dt = Float(dt)
    c.dx = Float(dx)
    c.iterationCount = UInt32(iterations)
    c.shapeCount = UInt32(specs.count)
    c.borderFriction = Float(min(max(domain.wallFriction, 0), 1))
    c.maxDisplacement = 2
    c.useGridVolume = 1
    c.particleCapacity = UInt32(capacity)
    c.field = SIMD4(Float(input.magneticField.x), Float(input.magneticField.y), Float(laggedField), 0)
    if let mag = input.magnet, laggedMagnet > 0 {
      let p = l.toCells(mag.position)
      c.magnet = SIMD4(Float(p.x), Float(p.y), Float(laggedMagnet), Float(MPMConstants.magnetReferenceDistance / dx))
    }
    if opts.shearForcingAmplitude != 0 && opts.shearForcingWavelength > 0 {
      c.forcing = SIMD4(Float(opts.shearForcingAmplitude * dt * dt / dx), Float(2 * Double.pi * dx / opts.shearForcingWavelength),
                        Float(l.origin.y), 0)
    }
    if let pr = input.probe {
      let p = l.toCells(pr)
      c.probe = SIMD4(Float(p.x), Float(p.y), Float(MPMConstants.probeRadiusCells), 1)
    }
    c.ambientTemperature = Float(input.ambientTemperature)
    c.thermalTime = Float(max(thermalTime, 0))
    c.surfaceCooling = Float(max(surfaceCooling, 0))
    c.heleShawGap = Float(max(domain.heleShawGap, 0))
    c.heleShawMinTime = Float(max(domain.heleShawMinTime, 0))
    c.rhoRef = Float(MPMConstants.referenceDensity)
    c.gridVolumeMix = Float(opts.gridVolumeMix)
    c.dtRatio = Float(dtRatio)
    c.colliderSkin = Float(max(colliderSkin, 0))
    c.omega = explicitMode ? 0 : Float(opts.omega)
    c.beta = explicitMode ? 1 : Float(opts.warmStart)
    c.debugFlags = (opts.excludePushOutImpulse ? UInt32(PB_DEBUG_NO_PUSH_IMPULSE) : 0)
      | (opts.upstreamColliderGap ? UInt32(PB_DEBUG_COLLIDER_GAP) : 0)
      | (opts.wallMirrorVolume ? 0 : UInt32(PB_DEBUG_NO_WALL_MIRROR))
      | (opts.twoSidedVolumeCorrection ? 0 : UInt32(PB_DEBUG_ONE_SIDED_J))
      | (opts.kelvinYieldScaling ? 0 : UInt32(PB_DEBUG_NO_KELVIN_YIELD))
    c.underfillTolerance = Float(max(opts.underfillTolerance, 0))
    c.simFlags = (l.periodicX ? UInt32(PB_SIM_PERIODIC_X) : 0) | (l.periodicY ? UInt32(PB_SIM_PERIODIC_Y) : 0)
      | (explicitMode ? UInt32(PB_SIM_EXPLICIT) : 0)
    func gravityKick(at time: Double) -> SIMD2<Float> {
      var g = gBase
      if vibA > 0 && vibF > 0 { g.y -= vibA * sin(2 * Double.pi * vibF * time) }
      return SIMD2<Float>(g * dt * dt / dx)
    }
    c.gravity = gravityKick(at: simulatedTime)

    // ---- Encode
    let concurrent = opts.concurrentDispatch
    guard let e = cmd.makeComputeCommandEncoder(dispatchType: concurrent ? .concurrent : .serial) else { return }
    e.label = "LabKitMPM"
    let st = state
    let P = pipelines
    func barrier() { if concurrent { e.memoryBarrier(scope: .buffers) } }
    func setC(_ k: inout PBSimConstants, _ index: Int) { e.setBytes(&k, length: MemoryLayout<PBSimConstants>.stride, index: index) }
    let grid8 = MTLSize(width: 8, height: 8, depth: 1)
    let line64 = MTLSize(width: 64, height: 1, depth: 1)
    let gridThreads = MTLSize(width: l.gridSize.x, height: l.gridSize.y, depth: 1)
    let bukkitThreads = MTLSize(width: l.bukkitCount.x, height: l.bukkitCount.y, depth: 1)
    let capacityThreads = MTLSize(width: capacity, height: 1, depth: 1)
    let countersArgs = MemoryLayout<PBCounters>.offset(of: \.particleDispatch)!

    func allocateAndInsert(parity: UInt32, clear grid: MTLBuffer) {
      var k = c
      k.bufferParity = parity
      e.setComputePipelineState(P.bukkitAllocate)
      setC(&k, 0)
      e.setBuffer(st.bukkitCounts, offset: 0, index: 1); e.setBuffer(st.insertCounters, offset: 0, index: 2)
      e.setBuffer(st.dispatch, offset: 0, index: 3); e.setBuffer(st.threadData, offset: 0, index: 4)
      e.setBuffer(st.indexStart, offset: 0, index: 5); e.setBuffer(st.counters, offset: 0, index: 6)
      e.setBuffer(grid, offset: 0, index: 7)
      e.dispatchThreads(bukkitThreads, threadsPerThreadgroup: grid8)
      barrier()
      e.setComputePipelineState(P.bukkitInsert)
      setC(&k, 0)
      e.setBuffer(st.counters, offset: 0, index: 1); e.setBuffer(st.insertCounters, offset: 0, index: 2)
      e.setBuffer(st.particles, offset: 0, index: 3); e.setBuffer(st.bukkitParticles, offset: 0, index: 4)
      e.setBuffer(st.indexStart, offset: 0, index: 5)
      e.dispatchThreadgroups(indirectBuffer: st.counters, indirectBufferOffset: countersArgs, threadsPerThreadgroup: line64)
      barrier()
    }

    if clearing {
      e.setComputePipelineState(P.clearParticles)
      setC(&c, 0); e.setBuffer(st.counters, offset: 0, index: 1); e.setBuffer(st.particles, offset: 0, index: 2)
      e.dispatchThreads(capacityThreads, threadsPerThreadgroup: line64)
      barrier()
    }
    if !injecting.isEmpty {
      var k = c
      k.injectCount = UInt32(injecting.count)
      e.setComputePipelineState(P.inject)
      setC(&k, 0); e.setBuffer(st.counters, offset: 0, index: 1); e.setBuffer(st.particles, offset: 0, index: 2)
      e.setBuffer(slot.upload, offset: injectOffset, index: 3); e.setBuffer(st.freeIndices, offset: 0, index: 4)
      e.dispatchThreads(MTLSize(width: injecting.count, height: 1, depth: 1), threadsPerThreadgroup: line64)
      barrier()
      e.setComputePipelineState(P.injectCommit)
      setC(&k, 0); e.setBuffer(st.counters, offset: 0, index: 1)
      e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
      barrier()
    }
    if rebin {
      var k = c
      k.bufferParity = globalSubstep & 1
      e.setComputePipelineState(P.resetBins)
      setC(&k, 0); e.setBuffer(st.bukkitCounts, offset: 0, index: 1); e.setBuffer(st.dispatch, offset: 0, index: 2)
      e.dispatchThreads(bukkitThreads, threadsPerThreadgroup: grid8)
      barrier()
      e.setComputePipelineState(P.bukkitCount)
      setC(&k, 0); e.setBuffer(st.counters, offset: 0, index: 1); e.setBuffer(st.particles, offset: 0, index: 2)
      e.setBuffer(st.bukkitCounts, offset: 0, index: 3)
      e.dispatchThreads(capacityThreads, threadsPerThreadgroup: line64)
      barrier()
      allocateAndInsert(parity: globalSubstep & 1, clear: st.grids[0])
    }

    let N = iterations
    let impulseOffset = Self.readbackImpulseOffset
    for s in 0..<S {
      c.dt = Float(dt)
      c.gravity = gravityKick(at: simulatedTime + Double(s + 1) * dt)
      c.substepIndex = globalSubstep
      c.dtRatio = s == 0 ? Float(dtRatio) : 1
      let shapeOffset = shapeBase + s * Self.shapeBlock
      let slotOffset = Int(globalSubstep & 1) * MemoryLayout<PBBukkitDispatch>.stride
      for k in 0...N {
        c.iteration = UInt32(k)
        e.setComputePipelineState(P.g2p2g)
        setC(&c, 0)
        e.setBuffer(st.particles, offset: 0, index: 1)
        e.setBuffer(st.grids[k % 3], offset: 0, index: 2)
        e.setBuffer(st.grids[(k + 1) % 3], offset: 0, index: 3)
        e.setBuffer(st.grids[(k + 2) % 3], offset: 0, index: 4)
        e.setBuffer(st.threadData, offset: 0, index: 5)
        e.setBuffer(st.bukkitParticles, offset: 0, index: 6)
        e.setBuffer(slot.upload, offset: shapeOffset, index: 7)
        e.setBuffer(slot.upload, offset: 0, index: 8)
        e.setBuffer(st.counters, offset: 0, index: 9)
        e.setBuffer(st.freeIndices, offset: 0, index: 10)
        e.setBuffer(slot.readback, offset: impulseOffset, index: 11)
        e.setBuffer(st.bukkitCounts, offset: 0, index: 12)
        e.dispatchThreadgroups(indirectBuffer: st.dispatch, indirectBufferOffset: slotOffset,
                               threadsPerThreadgroup: MTLSize(width: Int(PB_TILE_NODES), height: 1, depth: 1))
        barrier()
      }
      if emitting {
        e.setComputePipelineState(P.emit)
        setC(&c, 0)
        e.setBuffer(st.counters, offset: 0, index: 1); e.setBuffer(st.particles, offset: 0, index: 2)
        e.setBuffer(slot.upload, offset: shapeOffset, index: 3); e.setBuffer(st.freeIndices, offset: 0, index: 4)
        e.setBuffer(st.grids[N % 3], offset: 0, index: 5); e.setBuffer(slot.upload, offset: 0, index: 6)
        e.setBuffer(st.bukkitCounts, offset: 0, index: 7)
        e.dispatchThreads(gridThreads, threadsPerThreadgroup: grid8)
        barrier()
      }
      if opts.sampleGridMass && s == S - 1 {
        e.setComputePipelineState(P.gridMass)
        setC(&c, 0); e.setBuffer(st.grids[N % 3], offset: 0, index: 1)
        e.setBuffer(slot.readback, offset: Self.readbackStatsOffset, index: 2)
        // Whole threadgroups only: the tree reduction needs every slot of the group written.
        e.dispatchThreadgroups(MTLSize(width: (l.gridSize.x + 7) / 8, height: (l.gridSize.y + 7) / 8, depth: 1),
                               threadsPerThreadgroup: grid8)
        barrier()
      }
      allocateAndInsert(parity: (globalSubstep + 1) & 1, clear: st.grids[N % 3])
      globalSubstep &+= 1
    }

    if S > 0 { lastGravityKick = c.gravity }

    // ---- Telemetry into the slot
    e.setComputePipelineState(P.stats)
    setC(&c, 0)
    e.setBuffer(st.counters, offset: 0, index: 1); e.setBuffer(st.particles, offset: 0, index: 2)
    e.setBuffer(slot.upload, offset: 0, index: 3); e.setBuffer(slot.readback, offset: Self.readbackStatsOffset, index: 4)
    e.dispatchThreadgroups(indirectBuffer: st.counters, indirectBufferOffset: countersArgs, threadsPerThreadgroup: line64)
    barrier()
    e.setComputePipelineState(P.snapshot)
    e.setBuffer(st.counters, offset: 0, index: 0); e.setBuffer(slot.readback, offset: Self.readbackCountersOffset, index: 1)
    e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    e.endEncoding()

    // ---- Quality switch: copy the state back without waiting; resample when this frame completes
    if let nq = pendingQuality, resample == nil {
      let bytes = capacity * MemoryLayout<PBParticle>.stride
      if let snap = device.makeBuffer(length: bytes, options: .storageModeShared),
         let snapCounters = device.makeBuffer(length: MemoryLayout<PBCounters>.stride, options: .storageModeShared),
         let b = cmd.makeBlitCommandEncoder() {
        b.copy(from: st.particles, sourceOffset: 0, to: snap, destinationOffset: 0, size: bytes)
        b.copy(from: st.counters, sourceOffset: 0, to: snapCounters, destinationOffset: 0, size: MemoryLayout<PBCounters>.stride)
        b.endEncoding()
        resample = ResampleJob(commandBuffer: cmd, particles: snap, counters: snapCounters, fromLayout: l,
                               dt: S > 0 ? dt : lastSubstepDt, quality: nq)
        pendingQuality = nil
      }
    }

    // ---- Bookkeeping
    frameIndex += 1
    var meta = FrameMeta()
    meta.frameIndex = frameIndex
    meta.substeps = S
    meta.lagging = rule.lagging && opts.fixedSubsteps == nil
    meta.dt = dt
    meta.dx = dx
    meta.simulatedTime = S > 0 ? rule.simulatedTime : 0
    meta.depthFactor = domain.heleShawGap > 0 ? domain.heleShawGap : 1
    meta.sampledGridMass = opts.sampleGridMass && S > 0
    meta.shapeBodies = shapeBodies
    slot.meta = meta
    slot.commandBuffer = cmd
    if clearing { slotEstimate = 0; liveEstimate = 0 }
    if !injecting.isEmpty || clearing {
      slotEstimate = min(capacity, max(slotEstimate, latest.particleSlots) + injecting.count)
      liveEstimate += injecting.count
      lastInjectFrame = frameIndex
    }
    if S > 0 { lastSubstepDt = dt }
    simulatedTime += meta.simulatedTime
  }

  // MARK: Injection

  private func makeParticle(_ pp: PendingParticle, layout l: MPMGridLayout, dt: Double, dtRatio: Double) -> PBParticle {
    let mi = min(max(pp.material, 0), Self.maxMaterials - 1)
    let rho = mi < materials.count ? materials[mi].density : (materials.first?.density ?? 1000)
    var p = pp.carried ?? PBParticle()
    let c = l.toCells(pp.position)
    p.position = SIMD2<Float>(c)
    // Pass 0 multiplies by dtRatio, so stage d / dtRatio (pbInject adds the gravity kick the same way).
    p.displacement = SIMD2<Float>(pp.velocity * dt / l.dx / max(dtRatio, 1e-9))
    if pp.carried == nil {
      p.deformationDisplacement = simd_float2x2()
      p.elastic = SIMD4(1, 0, 1, 0)
      p.liquidDensity = 1
      p.contact = 0
      p.viscosity = 1e30
      p.stress = 0
      p.shearRate = 0
    } else {
      p.deformationDisplacement = simd_float2x2(p.deformationDisplacement.columns.0 / Float(max(dtRatio, 1e-9)),
                                                p.deformationDisplacement.columns.1 / Float(max(dtRatio, 1e-9)))
    }
    p.iterate = .zero
    p.volume = 1 / Float(PB_PPC_AXIS * PB_PPC_AXIS)
    p.mass = p.volume * Float(rho / MPMConstants.referenceDensity)
    p.structure = Float(pp.structure)
    p.temperature = Float(pp.temperature)
    p.material = UInt32(mi)
    p.flags = UInt32(PB_FLAG_ENABLED) | (UInt32(min(pp.band, Int(PB_MAX_STRIPES))) << PB_DYE_SHIFT)
    p.tag = pp.tag
    return p
  }

  // MARK: Quality switch

  /// When the copy-back of a pending `setQuality` has completed, resample the fluid onto the new grid (CPU, once) and
  /// swap in fresh buffers. Never waits.
  func finishQualitySwitchIfReady() {
    guard let job = resample else { return }
    let status = job.commandBuffer.status
    guard status == .completed || status == .error else { return }
    resample = nil
    let newLayout = MPMGridLayout(size: requestedSize, cellSize: job.quality.cellSize,
                                  periodicX: job.fromLayout.periodicX, periodicY: job.fromLayout.periodicY)
    var carried: [PendingParticle] = []
    if status == .completed && !job.cleared {
      let n = Int(min(job.counters.contents().load(as: PBCounters.self).particleCount, UInt32(capacity)))
      let src = job.particles.contents().bindMemory(to: PBParticle.self, capacity: capacity)
      let old = (0..<n).map { src[$0] }.filter { $0.flags & PB_FLAG_ENABLED != 0 }
      carried = Self.resample(old, from: job.fromLayout, to: newLayout, dt: job.dt, capacity: capacity)
    }
    guard let fresh = try? MPMState(device: device, layout: newLayout, capacity: capacity, particles: []) else { return }
    state = fresh
    quality = job.quality
    domain.cellSize = newLayout.dx
    domain.size = newLayout.size
    pendingInject = carried + pendingInject
    needsRebin = true
    slotEstimate = 0
    liveEstimate = 0
    lastSubstepDt = 0
  }

  /// Resamples particles onto another lattice. A new lattice site (2 × 2 per new cell) is filled when an old particle
  /// lies within 0.75 old particle spacings of it, i.e. inside the old fluid's footprint; it takes the state (b̄e, J, λ,
  /// f, T, material) of the nearest old particle and the mean velocity of the old particles within one new cell.
  /// Area is kept to about a quarter spacing along free surfaces; nothing is created far from the old fluid.
  static func resample(_ old: [PBParticle], from a: MPMGridLayout, to b: MPMGridLayout, dt: Double, capacity: Int) -> [PendingParticle] {
    guard !old.isEmpty else { return [] }
    let ppc = Int(PB_PPC_AXIS)
    let spacing = a.dx / Double(ppc)
    let reach = 0.75 * spacing
    // Hash grid of the old particles, one bucket per old spacing.
    var buckets: [SIMD2<Int>: [Int]] = [:]
    var positions: [SIMD2<Double>] = []
    var velocities: [SIMD2<Double>] = []
    positions.reserveCapacity(old.count)
    for (i, p) in old.enumerated() {
      let x = a.toMetres(SIMD2(Double(p.position.x), Double(p.position.y)))
      positions.append(x)
      velocities.append(SIMD2(Double(p.displacement.x), Double(p.displacement.y)) * a.dx / max(dt, 1e-9))
      buckets[SIMD2(Int((x.x / spacing).rounded(.down)), Int((x.y / spacing).rounded(.down))), default: []].append(i)
    }
    func neighbours(of x: SIMD2<Double>, within r: Double) -> [Int] {
      let lo = SIMD2(Int(((x.x - r) / spacing).rounded(.down)), Int(((x.y - r) / spacing).rounded(.down)))
      let hi = SIMD2(Int(((x.x + r) / spacing).rounded(.down)), Int(((x.y + r) / spacing).rounded(.down)))
      var out: [Int] = []
      for j in lo.y...hi.y { for i in lo.x...hi.x { if let l = buckets[SIMD2(i, j)] { out += l } } }
      return out.filter { simd_length_squared(positions[$0] - x) <= r * r }
    }
    // Candidate new cells: those under any old particle, plus one ring.
    var cells = Set<SIMD2<Int>>()
    for x in positions {
      let c = SIMD2(Int((x.x / b.dx).rounded(.down)), Int((x.y / b.dx).rounded(.down)))
      for dj in -1...1 { for di in -1...1 { cells.insert(c &+ SIMD2(di, dj)) } }
    }
    let sorted = cells.filter { $0.x >= 0 && $0.y >= 0 && $0.x < b.interior.x && $0.y < b.interior.y }
      .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    var out: [PendingParticle] = []
    for c in sorted {
      for sj in 0..<ppc {
        for si in 0..<ppc {
          let site = SIMD2(Double(c.x) + (Double(si) + 0.5) / Double(ppc), Double(c.y) + (Double(sj) + 0.5) / Double(ppc)) * b.dx
          let near = neighbours(of: site, within: reach)
          guard let best = near.min(by: { simd_length_squared(positions[$0] - site) < simd_length_squared(positions[$1] - site) })
          else { continue }
          if out.count >= capacity { return out }
          let around = neighbours(of: site, within: 0.5 * b.dx + spacing)
          var v = SIMD2<Double>.zero
          for k in around { v += velocities[k] }
          v /= Double(max(around.count, 1))
          let src = old[best]
          out.append(PendingParticle(position: site, velocity: v, material: Int(src.material),
                                     band: Int((src.flags >> PB_DYE_SHIFT) & PB_DYE_MASK),
                                     temperature: Double(src.temperature), structure: Double(src.structure),
                                     tag: src.tag, carried: src))
        }
      }
    }
    return out
  }
}
