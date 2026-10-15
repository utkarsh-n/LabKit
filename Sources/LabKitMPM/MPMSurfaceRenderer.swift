import Foundation
import Metal
import simd
import LabKitMPMTypes

/// The 2.5D fluid look for `MPMSolver` particles (`mpm-metal.md` §14): a splat of every particle into thickness /
/// material-weight / per-particle-state fields over the tank's rectangle (about 8 texels per cell, ¼–½ of the drawable's
/// resolution) with a separable blur and a gradient pass (`encodePrepass`, in the compute phase), then a full-resolution
/// shade inside the scene's second pass (`encodeShade`): a crisp anti-aliased silhouette from the signed distance to the
/// iso-surface, a rounded meniscus at free edges, refraction of the mipmapped `behind` texture, Beer–Lambert
/// absorption, milky subsurface, GGX highlights with a clear coat, a studio reflection that turns with the phone,
/// dry/wet surfaces from the particles' jamming and structure, dye bands, the stress light and the lava glow — or a
/// diagnostic colour map over the same shape. Particles outside the surface are drawn as droplets of their own volume
/// (no foam); inside it they carry a speckle grain. LabKit's bloom and EDR soft-clip finish the frame.
///
/// Use from one isolation domain (the main actor in Rheo); not Sendable. No per-frame heap allocations after the first
/// frame: field textures and pass descriptors are reallocated only when the tank's rectangle on screen changes size.
///
/// Hologram style (`FluidRenderOptions.style = .hologram`, Toothpaste Toy, 13 October 2026): its own, cheaper prepass
/// (three field targets at `holoTexelsPerCell`, no dye compute) feeds `flHoloFragment` and the probability-cloud points
/// instead of the material shade and droplets. The hologram is light drawn over what is already in the target, so it
/// needs no `behind` copy (`encodeHologramShade`); `holoLooks` gives each material its hologram identity, and a ring
/// of earlier thickness fields (G's level 1, one copy per frame) lets fast-moving paste leave short echoes.
public final class MPMSurfaceRenderer {
  public let device: MTLDevice
  public let colorFormat: MTLPixelFormat
  public let depthFormat: MTLPixelFormat
  /// Index = material id (≤ 16). Missing entries use the water-like look.
  public var looks: [FluidLook] = FluidLook.all.map(\.look)
  /// Iso level of the surface (thickness units; a filled region has thickness ≈ 1). 0.5 puts the surface half a
  /// particle spacing outside the outermost particles, so the drawn volume matches the particles' volume.
  public var threshold: Float = 0.5
  /// Minimum half-width of the edge ramp in thickness units (the silhouette is also anti-aliased over ±0.75 px).
  public var softness: Float = 0.012
  /// Splat radius in cells (2 × 2 particles per cell).
  public var splatRadiusCells: Float = 1.2
  /// Blur step of the field, cells (9-tap Gaussian, σ ≈ 1.3 steps): smooths the particle-scale scallops on the free
  /// surface (particles sit half a cell apart) without rounding a poke's hole.
  public var blurStepCells: Float = 0.55
  /// Field texels per grid cell the prepass aims for; the field resolution stays within `minFieldScale`…½ of the
  /// drawable's.
  public var texelsPerCellTarget: Float = 8
  /// Floor of the field's resolution as a share of the drawable's (surface style).
  public var minFieldScale: Float = 0.25
  /// Hologram style: field texels per grid cell (its own, coarser prepass: the shade draws the edge at full resolution
  /// from the signed distance, so the fields only carry the shape and the per-particle state), and its floor.
  public var holoTexelsPerCell: Float = 4
  public var holoMinFieldScale: Float = 0.1
  /// Dye tracer bands: spacing and width, m.
  public var dyeBandSpacing: Double = 0.008
  public var dyeBandWidth: Double = 0.0014
  /// Hologram identity per material (index = material id, ≤ 16); missing entries use `FluidHoloLook.standard`.
  public var holoLooks: [FluidHoloLook] = []
  /// Copies of the thickness field kept for the hologram's echoes (one per frame; at 120 Hz, 24 cover 0.2 s).
  public static let echoCapacity = 24

  private let splat, blur, gradient, shade, dots, particles, streaks, holoShade, cloud: MTLRenderPipelineState
  private let holoSplat, holoBlur: MTLRenderPipelineState
  private let dyeUpdate: MTLComputePipelineState
  private let noDepth: MTLDepthStencilState
  private let lut: MTLTexture
  private var fields: [MTLTexture] = []          // A0, W00, W10, B0, S0, A1, W01, W11, B1, S1 (hologram: H0-H2 = A, W0, W1)
  private static let targetCount = 5            // A, W0, W1, B, S
  private var gradientField: MTLTexture?        // G = (t, ∂t/∂u, ∂t/∂v), mipmapped
  private var fieldSize = SIMD2<Int>(0, 0)
  private var splatPass, blurPassH, blurPassV, gradientPass: MTLRenderPassDescriptor?
  private var holoSplatPass, holoBlurPassH, holoBlurPassV: MTLRenderPassDescriptor?
  private static let holoTargetCount = 3        // H0, H1, H2
  private var dyeBuffer: MTLBuffer?
  private var dyeCapacity = 0
  private var slotOfMaterial = [UInt32](repeating: UInt32(FL_HIDDEN), count: Int(PB_MAX_MATERIALS))
  private var slotLooks = [FluidLookGPU](repeating: FluidLook.waterLike.gpu, count: Int(FL_SLOTS))
  private var slotExts = [FluidLookExtGPU](repeating: FluidLook.waterLike.gpuExt, count: Int(FL_SLOTS))
  private var slotHolo = [FluidHoloLookGPU](repeating: FluidHoloLook.standard.gpu, count: Int(FL_SLOTS))
  private var frame = PrepassFrame()
  // Hologram echoes: a ring of G's level 1 with the time and field rectangle of each copy.
  private var echoes: [MTLTexture] = []
  private var echoTimes = [Float](repeating: -1, count: MPMSurfaceRenderer.echoCapacity)
  private var echoRects = [SIMD4<Float>](repeating: .zero, count: MPMSurfaceRenderer.echoCapacity)
  private var echoHead = 0
  private var blank: MTLTexture?

  /// What the prepass knew, reused by the shade pass of the same frame.
  private struct PrepassFrame {
    var valid = false
    var particleBuffer: MTLBuffer?
    var drawArgs: (MTLBuffer, Int)?
    var splat = FluidSplatUniforms()
    var shade = FluidShadeUniforms()
    var ext = FluidShadeExtGPU()
    var drawableSize = SIMD2<Int>(0, 0)
    var anyGrain = false
    var anyCloud = false
    /// The fields hold the hologram's layout (H0-H2).
    var holo = false
  }

  public init(device: MTLDevice, colorFormat: MTLPixelFormat = .rgba16Float, depthFormat: MTLPixelFormat = .depth32Float) throws {
    self.device = device
    self.colorFormat = colorFormat
    self.depthFormat = depthFormat
    let lib = try MPMPipelines.library(device: device)
    try Self.checkLayout(device: device, library: lib)
    enum Blend { case none, add, premultiplied }
    func pipeline(_ v: String, _ f: String, _ formats: [MTLPixelFormat], depth: MTLPixelFormat, blend: Blend) throws -> MTLRenderPipelineState {
      let d = MTLRenderPipelineDescriptor()
      d.label = "LabKitMPM \(f)"
      guard let vf = lib.makeFunction(name: v), let ff = lib.makeFunction(name: f) else {
        throw MPMError.metal("missing shader function \(v) or \(f)")
      }
      d.vertexFunction = vf
      d.fragmentFunction = ff
      for (i, fmt) in formats.enumerated() {
        let a = d.colorAttachments[i]!
        a.pixelFormat = fmt
        switch blend {
        case .none: break
        case .add:
          a.isBlendingEnabled = true
          a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
          a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .one
          a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .one
        case .premultiplied:
          a.isBlendingEnabled = true
          a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
          a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
      }
      d.depthAttachmentPixelFormat = depth
      do { return try device.makeRenderPipelineState(descriptor: d) } catch {
        throw MPMError.metal("render pipeline \(f): \(error)")
      }
    }
    let field: [MTLPixelFormat] = [.rgba16Float, .rgba16Float, .rgba16Float, .rgba16Float, .rgba16Float]
    splat = try pipeline("flSplatVertex", "flSplatFragment", field, depth: .invalid, blend: .add)
    blur = try pipeline("flFullscreenVertex", "flBlurFragment", field, depth: .invalid, blend: .none)
    gradient = try pipeline("flFullscreenVertex", "flGradientFragment", [.rgba16Float], depth: .invalid, blend: .none)
    shade = try pipeline("flShadeVertex", "flShadeFragment", [colorFormat], depth: depthFormat, blend: .premultiplied)
    dots = try pipeline("flDotVertex", "flDotFragment", [colorFormat], depth: depthFormat, blend: .premultiplied)
    particles = try pipeline("flParticleVertex", "flParticleFragment", [colorFormat], depth: depthFormat, blend: .premultiplied)
    streaks = try pipeline("flStreakVertex", "flStreakFragment", [colorFormat], depth: depthFormat, blend: .premultiplied)
    holoShade = try pipeline("flShadeVertex", "flHoloFragment", [colorFormat], depth: depthFormat, blend: .premultiplied)
    cloud = try pipeline("flCloudVertex", "flCloudFragment", [colorFormat], depth: depthFormat, blend: .premultiplied)
    let holoFields: [MTLPixelFormat] = [.rgba16Float, .rgba16Float, .rgba16Float]
    holoSplat = try pipeline("flHoloSplatVertex", "flHoloSplatFragment", holoFields, depth: .invalid, blend: .add)
    holoBlur = try pipeline("flFullscreenVertex", "flHoloBlurFragment", holoFields, depth: .invalid, blend: .none)
    guard let dyeFn = lib.makeFunction(name: "flDyeUpdate") else { throw MPMError.metal("missing shader function flDyeUpdate") }
    do { dyeUpdate = try device.makeComputePipelineState(function: dyeFn) } catch {
      throw MPMError.metal("compute pipeline flDyeUpdate: \(error)")
    }
    let ds = MTLDepthStencilDescriptor()
    ds.depthCompareFunction = .always
    ds.isDepthWriteEnabled = false
    guard let nd = device.makeDepthStencilState(descriptor: ds) else { throw MPMError.metal("depth state") }
    noDepth = nd
    // LUT: 256 × 4 sRGB-encoded bytes, sampled through an _srgb format so the shader sees linear values.
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: MPMColourMaps.width,
                                                      height: MPMColourMaps.rows, mipmapped: false)
    td.usage = .shaderRead
    td.storageMode = .shared
    guard let t = device.makeTexture(descriptor: td) else { throw MPMError.metal("colour-map texture") }
    MPMColourMaps.bytes.withUnsafeBytes {
      t.replace(region: MTLRegionMake2D(0, 0, MPMColourMaps.width, MPMColourMaps.rows), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: MPMColourMaps.width * 4)
    }
    t.label = "LabKitMPM colour maps"
    lut = t
    // Stand-in for an echo slot that holds nothing yet (transparent: no thickness).
    let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
    bd.usage = .shaderRead
    bd.storageMode = .shared
    if let b = device.makeTexture(descriptor: bd) {
      let zero = [UInt16](repeating: 0, count: 4)
      zero.withUnsafeBytes { b.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
      b.label = "LabKitMPM blank"
      blank = b
    }
  }

  private static func checkLayout(device: MTLDevice, library: MTLLibrary) throws {
    guard let fn = library.makeFunction(name: "flLayoutProbe"),
          let ps = try? device.makeComputePipelineState(function: fn),
          let q = device.makeCommandQueue(), let out = device.makeBuffer(length: 64, options: .storageModeShared),
          let cmd = q.makeCommandBuffer(), let e = cmd.makeComputeCommandEncoder() else {
      throw MPMError.metal("cannot run the render layout probe")
    }
    e.setComputePipelineState(ps)
    e.setBuffer(out, offset: 0, index: 0)
    e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    let v = out.contents().bindMemory(to: UInt32.self, capacity: 16)
    let msl = (0..<13).map { Int(v[$0]) }
    let swift = [MemoryLayout<FluidSplatUniforms>.stride, MemoryLayout<FluidLookGPU>.stride, MemoryLayout<FluidShadeUniforms>.stride,
                 MemoryLayout<FluidSplatUniforms>.offset(of: \.materialSlot)!, MemoryLayout<FluidShadeUniforms>.offset(of: \.keyLight)!,
                 MemoryLayout<FluidShadeUniforms>.offset(of: \.behindLod)!, MemoryLayout<FluidLookExtGPU>.stride,
                 MemoryLayout<FluidShadeExtGPU>.stride, MemoryLayout<FluidDyeParams>.stride,
                 MemoryLayout<FluidHoloLookGPU>.stride, MemoryLayout<FluidHoloUniforms>.stride,
                 MemoryLayout<FluidSplatUniforms>.offset(of: \.bandBuckets)!, MemoryLayout<FluidHoloUniforms>.offset(of: \.misc2)!]
    if msl != swift { throw MPMError.layout("render structs: MSL \(msl) vs Swift \(swift)") }
  }

  // MARK: Prepass

  /// Splat, blur and gradient passes into the renderer's own textures. Call from `encodeCompute`, after
  /// `MPMSolver.encode` on the same command buffer.
  /// - Parameters:
  ///   - tankToClip: tank metres (origin bottom-left, y up, z = 0) → the scene's clip space.
  ///   - drawableSize: the scene target's size in pixels.
  public func encodePrepass(_ cmd: MTLCommandBuffer, solver: MPMSolver, tankToClip: simd_float4x4, drawableSize: SIMD2<Int>,
                            options: FluidRenderOptions) {
    frame.valid = false
    guard drawableSize.x > 0, drawableSize.y > 0 else { return }
    let holo = options.style == .hologram && options.diagnostic == .none
    let tank = solver.domain.size
    let dx = Float(solver.cellSize)
    let W = Float(drawableSize.x), H = Float(drawableSize.y)

    // The tank's rectangle in drawable pixels (y down), with a margin of two splat radii.
    func pixel(_ m: SIMD2<Double>) -> SIMD2<Float> {
      let c = tankToClip * SIMD4<Float>(Float(m.x), Float(m.y), 0, 1)
      let ndc = SIMD2(c.x, c.y) / max(c.w, 1e-6)
      return SIMD2((ndc.x * 0.5 + 0.5) * W, (0.5 - ndc.y * 0.5) * H)
    }
    let c0 = pixel(.zero), c1 = pixel(SIMD2(tank.x, 0)), c2 = pixel(SIMD2(0, tank.y)), c3 = pixel(tank)
    var lo = simd_min(simd_min(c0, c1), simd_min(c2, c3)), hi = simd_max(simd_max(c0, c1), simd_max(c2, c3))
    let cellPx = simd_length(pixel(SIMD2(Double(dx), 0)) - c0)
    guard cellPx > 1e-3 else { return }
    let margin = 2.5 * splatRadiusCells * cellPx
    lo = simd_max((lo - margin).rounded(.down), .zero)
    hi = simd_min((hi + margin).rounded(.up), SIMD2(W, H))
    guard hi.x - lo.x >= 2, hi.y - lo.y >= 2 else { return }
    let density = holo ? holoTexelsPerCell : texelsPerCellTarget
    let floorScale = min(max(holo ? holoMinFieldScale : minFieldScale, 0.05), 0.5)
    let scale = min(max(density / cellPx, floorScale), 0.5)                  // field texels per drawable pixel
    let size = SIMD2(max(Int(((hi.x - lo.x) * scale).rounded(.up)), 2), max(Int(((hi.y - lo.y) * scale).rounded(.up)), 2))
    let rect = SIMD4<Float>(lo.x, lo.y, Float(size.x) / scale, Float(size.y) / scale)
    guard ensureFields(size), ensureDye(capacity: solver.capacity), let dye = dyeBuffer, let G = gradientField,
          let splatPass, let blurPassH, let blurPassV, let gradientPass, let holoSplatPass, let holoBlurPassH,
          let holoBlurPassV else { return }

    // Clip of the field textures from the scene clip: field NDC = scale · scene NDC + offset.
    let sx = W / rect.z, sy = H / rect.w
    let tx = (W - 2 * rect.x) / rect.z - 1, ty = 1 - (H - 2 * rect.y) / rect.w
    let remap = simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, sy, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(tx, ty, 0, 1)))

    // Material slots: the materials in use, in index order; past FL_SLOTS (the hologram: FL_HOLO_SLOTS) they share the
    // last slot.
    let slots = holo ? Int(FL_HOLO_SLOTS) : Int(FL_SLOTS)
    var used = 0
    var anyGrain = false
    var anyCloud = false
    for mi in 0..<Int(PB_MAX_MATERIALS) {
      guard solver.materialsInUse.contains(mi) else { slotOfMaterial[mi] = UInt32(FL_HIDDEN); continue }
      if used < slots {
        slotOfMaterial[mi] = UInt32(used)
        let look = mi < looks.count ? looks[mi] : FluidLook.waterLike
        slotLooks[used] = look.gpu
        slotExts[used] = look.gpuExt
        let holo = mi < holoLooks.count ? holoLooks[mi] : FluidHoloLook.standard
        slotHolo[used] = holo.gpu
        anyGrain = anyGrain || look.grain > 0
        anyCloud = anyCloud || holo.cloud > 0
        used += 1
      } else {
        slotOfMaterial[mi] = UInt32(slots - 1)
      }
    }
    if used == 0 {
      slotLooks[0] = FluidLook.waterLike.gpu; slotExts[0] = FluidLook.waterLike.gpuExt; slotHolo[0] = FluidHoloLook.standard.gpu
      used = 1
    }
    for i in used..<Int(FL_SLOTS) { slotLooks[i] = slotLooks[0]; slotExts[i] = slotExts[0]; slotHolo[i] = slotHolo[0] }

    var su = FluidSplatUniforms()
    su.tankToClip = remap * tankToClip
    su.originCells = SIMD2<Float>(solver.layout.origin)
    su.dx = dx
    su.radiusCells = splatRadiusCells
    su.weight = 1 / (4 * (2.0 / 3.0) * Float.pi * splatRadiusCells * splatRadiusCells)   // 2x2 per cell, sphere profile
    su.diagMode = UInt32(options.diagnostic.rawValue)
    su.speedMax = max(options.speedRange, 1e-3)
    su.dtSub = Float(solver.lastSubstepLength > 0 ? solver.lastSubstepLength : 1.0 / 1200)
    su.tracerFraction = min(max(options.tracers, 0), 1)
    su.streakSeconds = 0.02
    su.pointRadiusPx = 1.6 * max(1, cellPx / 12)
    su.colormap = UInt32(options.diagnostic == .none ? FluidDiagnostic.speed.colourMapRow : options.diagnostic.colourMapRow)
    su.viewportPx = SIMD2(W, H)
    su.gravityKick = solver.lastGravityKick
    su.bandBuckets = options.hologram.bandBucketBits
    withUnsafeMutableBytes(of: &su.materialSlot) { b in
      let p = b.bindMemory(to: UInt32.self)
      for i in 0..<min(p.count, slotOfMaterial.count) { p[i] = slotOfMaterial[i] }
    }

    let st = solver.state
    let drawArgs = (st.counters, MemoryLayout<PBCounters>.offset(of: \.drawArgs)!)
    // 0. Dye bands for particles that are new in their slot (tracers: the surface style only).
    if !holo, let e = cmd.makeComputeCommandEncoder() {
      // Per-frame labels stay longer than 15 UTF-8 bytes: a small (inline) Swift string allocates when it is bridged to
      // NSString, an immortal literal does not.
      e.label = "LabKitMPM fluid dye"
      var dp = FluidDyeParams(originCells: su.originCells, dx: dx, period: Float(dyeBandSpacing), width: Float(dyeBandWidth),
                              time: Float(solver.simulatedTime), drift: 0.012, count: UInt32(solver.capacity))
      e.setComputePipelineState(dyeUpdate)
      e.setBuffer(solver.particleBuffer, offset: 0, index: 0)
      e.setBuffer(dye, offset: 0, index: 1)
      e.setBytes(&dp, length: MemoryLayout<FluidDyeParams>.stride, index: 2)
      e.dispatchThreads(MTLSize(width: solver.capacity, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: min(64, dyeUpdate.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
      e.endEncoding()
    }
    // 1. Splat (the hologram: its three targets)
    if let e = cmd.makeRenderCommandEncoder(descriptor: holo ? holoSplatPass : splatPass) {
      e.label = holo ? "LabKitMPM hologram splat" : "LabKitMPM fluid splat"
      e.setRenderPipelineState(holo ? holoSplat : splat)
      e.setVertexBuffer(solver.particleBuffer, offset: 0, index: 0)
      e.setVertexBytes(&su, length: MemoryLayout<FluidSplatUniforms>.stride, index: 1)
      e.setVertexBuffer(dye, offset: 0, index: 2)
      e.setFragmentBytes(&su, length: MemoryLayout<FluidSplatUniforms>.stride, index: 0)
      e.drawPrimitives(type: .triangleStrip, indirectBuffer: drawArgs.0, indirectBufferOffset: drawArgs.1)
      e.endEncoding()
    }
    // 2. Blur: horizontal (0…n) -> (n…2n), vertical back (step `blurStepCells`, at least 1.4 texels as Gyre)
    let texelsPerCell = cellPx * scale
    let stepTexels = max(1.4, blurStepCells * texelsPerCell)
    if holo {
      encodeBlur(cmd, pass: holoBlurPassH, pipeline: holoBlur, count: Self.holoTargetCount, source: 0,
                 step: SIMD2<Float>(stepTexels / Float(size.x), 0))
      encodeBlur(cmd, pass: holoBlurPassV, pipeline: holoBlur, count: Self.holoTargetCount, source: Self.targetCount,
                 step: SIMD2<Float>(0, stepTexels / Float(size.y)))
    } else {
      encodeBlur(cmd, pass: blurPassH, pipeline: blur, count: Self.targetCount, source: 0,
                 step: SIMD2<Float>(stepTexels / Float(size.x), 0))
      encodeBlur(cmd, pass: blurPassV, pipeline: blur, count: Self.targetCount, source: Self.targetCount,
                 step: SIMD2<Float>(0, stepTexels / Float(size.y)))
    }
    // 3. Thickness gradient, then its mip chain (coarse body thickness for the shade).
    if let e = cmd.makeRenderCommandEncoder(descriptor: gradientPass) {
      e.label = "LabKitMPM fluid gradient"
      e.setRenderPipelineState(gradient)
      e.setFragmentTexture(fields[0], index: 0)
      e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      e.endEncoding()
    }
    // The ring keeps recording while the hologram is drawn (even with no echoes showing), so echoes have their history
    // the moment the paste starts to move.
    let wantsEchoes = holo && options.hologram.ghostLife > 0 && !options.hologram.reduceMotion
    if G.mipmapLevelCount > 1, let b = cmd.makeBlitCommandEncoder() {
      b.label = "LabKitMPM fluid gradient mips"
      b.generateMipmaps(for: G)
      // Hologram echoes: this frame's level 1 into the ring (the shade picks copies of the right ages).
      if wantsEchoes, ensureEchoes(G), echoes.count == Self.echoCapacity {
        let w = max(G.width >> 1, 1), h = max(G.height >> 1, 1)
        b.copy(from: G, sourceSlice: 0, sourceLevel: 1, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
               to: echoes[echoHead], destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        echoTimes[echoHead] = options.hologram.time
        echoRects[echoHead] = rect
        echoHead = (echoHead + 1) % Self.echoCapacity
      }
      b.endEncoding()
    }
    if !wantsEchoes { for i in 0..<echoTimes.count { echoTimes[i] = -1 } }

    var sh = FluidShadeUniforms()
    sh.tankToClip = tankToClip
    sh.tankSize = SIMD2<Float>(tank)
    sh.texel = SIMD2(1 / Float(size.x), 1 / Float(size.y))
    sh.fieldRect = rect
    sh.drawableSize = SIMD2(W, H)
    sh.threshold = threshold
    sh.softness = softness
    sh.texelsPerCell = texelsPerCell
    sh.lutRows = Float(MPMColourMaps.rows)
    sh.diagnostic = UInt32(options.diagnostic.rawValue)
    sh.keyLight = options.keyLight
    sh.fillLight = options.fillLight
    sh.colormap = UInt32(options.diagnostic.colourMapRow)
    sh.glow = max(options.glow, 0)
    sh.grain = max(options.grain, 0)
    sh.tracers = options.tracers > 0 ? 1 : 0
    sh.depth = max(options.depth, 0)
    sh.dx = dx

    var ext = FluidShadeExtGPU()
    ext.glow = SIMD4(options.stressColour, max(options.stressGlow, 0))
    let coarseLod = min(max(log2(max(texelsPerCell * 2.5, 1)), 0), Float(G.mipmapLevelCount - 1))
    ext.view = SIMD4(cellPx / dx, coarseLod, scale, options.droplets ? 1 : 0)
    let up = simd_length(options.environmentUp) > 1e-4 ? simd_normalize(options.environmentUp) : SIMD3<Float>(0, 0.5, 0.866)
    ext.env = SIMD4(up, 0)
    // Meniscus normals from a barely coarser copy of the field: box-filtered mips above level 1 print their texel blocks
    // as stair steps in the highlights; the blur (`blurStepCells`) already removes the particle-scale bumps.
    let normalLod = min(max(log2(max(texelsPerCell * 0.2, 1)), 0), 1, Float(G.mipmapLevelCount - 1))
    let dyeStrength = pow(min(max(options.tracers, 0), 1), 1.5)                // 0.3 → a hint of the lines; 1 → full ink
    ext.misc = SIMD4(Float(solver.simulatedTime.truncatingRemainder(dividingBy: 1000)), dyeStrength, normalLod, 0)

    // Overlays draw into the scene with the scene's own clip transform.
    var overlay = su
    overlay.tankToClip = tankToClip
    frame = PrepassFrame(valid: true, particleBuffer: solver.particleBuffer, drawArgs: drawArgs, splat: overlay, shade: sh,
                         ext: ext, drawableSize: drawableSize, anyGrain: anyGrain && options.grain > 0, anyCloud: anyCloud,
                         holo: holo)
  }

  // MARK: Shade

  /// Full-resolution shade inside the scene's second pass; samples the mipmapped `behind` texture for refraction.
  /// Uses the fields of the last `encodePrepass` (same frame); draws nothing if there was none. Draws a premultiplied-
  /// alpha quad over the tank, then droplets and grain (no depth test or write), and leaves its own pipeline,
  /// depth-stencil state and fragment buffers 0–3 set on `enc`: set yours again before further draws. With the
  /// hologram style it draws the hologram (which does not read `behind`; see `encodeHologramShade`).
  public func encodeShade(_ enc: MTLRenderCommandEncoder, behind: MTLTexture, tankToClip: simd_float4x4, time: Float,
                          options: FluidRenderOptions) {
    guard frame.valid, fields.count == 2 * Self.targetCount, let G = gradientField else { return }
    if options.style == .hologram && options.diagnostic == .none {
      encodeHologramShade(enc, tankToClip: tankToClip, time: time, options: options)
      return
    }
    guard !frame.holo else { return }                                        // the fields hold the hologram's layout
    var sh = frame.shade
    sh.tankToClip = tankToClip
    sh.time = time
    sh.behindLod = Float(max(behind.mipmapLevelCount - 1, 0))
    var ext = frame.ext
    enc.pushDebugGroup("LabKitMPM fluid shade")
    enc.setDepthStencilState(noDepth)
    enc.setRenderPipelineState(shade)
    enc.setVertexBytes(&sh, length: MemoryLayout<FluidShadeUniforms>.stride, index: 0)
    enc.setFragmentTexture(fields[0], index: 0)
    enc.setFragmentTexture(fields[1], index: 1)
    enc.setFragmentTexture(fields[2], index: 2)
    enc.setFragmentTexture(behind, index: 3)
    enc.setFragmentTexture(lut, index: 4)
    enc.setFragmentTexture(fields[3], index: 5)
    enc.setFragmentTexture(G, index: 6)
    enc.setFragmentBytes(&sh, length: MemoryLayout<FluidShadeUniforms>.stride, index: 0)
    slotLooks.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
    slotExts.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
    enc.setFragmentBytes(&ext, length: MemoryLayout<FluidShadeExtGPU>.stride, index: 3)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    guard let pb = frame.particleBuffer, let args = frame.drawArgs else { enc.popDebugGroup(); return }
    var su = frame.splat
    su.tankToClip = tankToClip
    // Droplets (particles the surface does not cover) and grain (speckle inside it).
    if options.droplets || frame.anyGrain {
      enc.setRenderPipelineState(dots)
      enc.setVertexBuffer(pb, offset: 0, index: 0)
      enc.setVertexBytes(&su, length: MemoryLayout<FluidSplatUniforms>.stride, index: 1)
      enc.setVertexBytes(&sh, length: MemoryLayout<FluidShadeUniforms>.stride, index: 2)
      slotLooks.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 3) }
      slotExts.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 4) }
      enc.setVertexBytes(&ext, length: MemoryLayout<FluidShadeExtGPU>.stride, index: 5)
      enc.setVertexTexture(G, index: 0)
      enc.setFragmentTexture(G, index: 0)
      enc.drawPrimitives(type: .triangleStrip, indirectBuffer: args.0, indirectBufferOffset: args.1)
    }
    // Debug overlays (no array literal here: nothing allocates per frame).
    func overlay(_ ps: MTLRenderPipelineState) {
      enc.setRenderPipelineState(ps)
      enc.setVertexBuffer(pb, offset: 0, index: 0)
      enc.setVertexBytes(&su, length: MemoryLayout<FluidSplatUniforms>.stride, index: 1)
      enc.setVertexTexture(lut, index: 0)
      enc.drawPrimitives(type: .triangleStrip, indirectBuffer: args.0, indirectBufferOffset: args.1)
    }
    if options.showFlow { overlay(streaks) }
    if options.showParticles { overlay(particles) }
    enc.popDebugGroup()
  }

  // MARK: Hologram

  /// The hologram (`FluidRenderStyle.hologram`): its shade quad and cloud points (the debug overlays still follow),
  /// drawn as premultiplied light over whatever the encoder's target already holds — no `behind` copy is read, so a
  /// scene that draws only the hologram can stay in one pass (`LabRenderScene.wantsBehindCopy` false). Uses the fields
  /// of the last `encodePrepass` made with the hologram style (same frame); draws nothing otherwise. Leaves its own
  /// pipeline, depth-stencil state and buffers set on `enc`.
  public func encodeHologramShade(_ enc: MTLRenderCommandEncoder, tankToClip: simd_float4x4, time: Float,
                                  options: FluidRenderOptions) {
    guard frame.valid, frame.holo, fields.count == 2 * Self.targetCount, let G = gradientField else { return }
    var sh = frame.shade
    sh.tankToClip = tankToClip
    sh.time = time
    sh.behindLod = 0
    var ext = frame.ext
    let o = options.hologram
    var hu = FluidHoloUniforms()
    let e = simd_length(o.tilt) > 1 ? simd_normalize(o.tilt) : o.tilt
    hu.tilt = Self.f4(o.reduceMotion ? .zero : e, o.time, o.reduceMotion ? 1 : 0)
    hu.scan = SIMD4(max(o.scanlinePeriod, 1e-6), min(max(o.scanlineDepth, 0), 1), o.scanlineSpeed, max(o.bodyGain, 0))
    let lensOn = o.lens > 0 && o.lensRadius > 0
    hu.lens = Self.f4(o.lensCentre, max(o.lensRadius, 0), lensOn ? min(o.lens, 1) : 0)
    let shift = (o.reduceMotion ? SIMD2<Float>.zero : e) * o.lensShift
    hu.lensOptics = Self.f4(shift, min(max(o.lensMagnification, 0), 0.45), max(o.lensSplit, 0))
    hu.band0 = SIMD4(o.bandColours.0, 0)
    hu.band1 = SIMD4(o.bandColours.1, 0)
    hu.band2 = SIMD4(o.bandColours.2, 0)
    hu.shear = SIMD4(o.shearColour, max(o.shearAmount, 0))
    hu.stress = SIMD4(o.stressColour, max(o.stressAmount, 0))
    hu.structure = SIMD4(o.structureColour, max(o.structureAmount, 0))
    let life = max(o.ghostLife, 0.02)
    let echoesOn = o.ghosts > 0.004 && !o.reduceMotion && echoes.count == Self.echoCapacity
    hu.ghostNear = SIMD4(o.ghostNear, echoesOn ? o.ghosts : 0)
    hu.ghostFar = SIMD4(o.ghostFar, life)
    // Three echoes at about ¼, ½ and ¾ of their life: the copy whose age is nearest each target (never this frame's).
    var picks = (-1, -1, -1)
    var ages = SIMD4<Float>(-1, -1, -1, 0)
    if echoesOn {
      for k in 0..<3 {
        let target = life * (0.25 + 0.25 * Float(k))
        var best = -1
        var bestErr = Float.greatestFiniteMagnitude
        for i in 0..<Self.echoCapacity where echoTimes[i] >= 0 {
          let age = o.time - echoTimes[i]
          guard age >= 0.012, age < life else { continue }
          let err = abs(age - target)
          if err < bestErr { bestErr = err; best = i }
        }
        guard best >= 0 else { continue }
        let age = o.time - echoTimes[best]
        switch k {
        case 0: picks.0 = best; ages.x = age; hu.ghostRect0 = echoRects[best]
        case 1: picks.1 = best; ages.y = age; hu.ghostRect1 = echoRects[best]
        default: picks.2 = best; ages.z = age; hu.ghostRect2 = echoRects[best]
        }
      }
    }
    hu.ghostAge = ages
    func flash(_ f: FluidHoloFlash) -> SIMD4<Float> { Self.f4(f.centre, max(f.radius, 0), min(max(f.intensity, 0), 1)) }
    hu.flash0 = flash(o.flashes.0)
    hu.flash1 = flash(o.flashes.1)
    hu.flash2 = flash(o.flashes.2)
    hu.flash3 = flash(o.flashes.3)
    hu.field = Self.f4(o.magnet ?? .zero, o.magnet == nil ? 0 : 1, min(max(o.field, 0), 1))
    hu.iris0 = SIMD4(o.iris.0, 0)
    hu.iris1 = SIMD4(o.iris.1, 0)
    hu.iris2 = SIMD4(o.iris.2, 0)
    hu.iris3 = SIMD4(o.iris.3, 0)
    hu.misc = SIMD4(max(o.cloudGain, 0), o.bands ? 1 : 0, max(o.backdrop, 0), max(o.rimGain, 0))
    // Edge light from the upper left, turning with the tilt (world-anchored light on the rim).
    let lightAngle = Float.pi * 0.72 - (o.reduceMotion ? 0 : e.x * 0.6)
    hu.misc2 = SIMD4(max(o.pixelsPerPoint, 1), lightAngle, max(o.fringeGain, 0), max(o.bandGain, 0))

    enc.pushDebugGroup("LabKitMPM fluid hologram")
    enc.setDepthStencilState(noDepth)
    enc.setRenderPipelineState(holoShade)
    enc.setVertexBytes(&sh, length: MemoryLayout<FluidShadeUniforms>.stride, index: 0)
    enc.setFragmentTexture(fields[0], index: 0)                              // H0
    enc.setFragmentTexture(fields[1], index: 1)                              // H1
    enc.setFragmentTexture(fields[2], index: 2)                              // H2
    enc.setFragmentTexture(G, index: 6)
    let none = blank ?? G
    enc.setFragmentTexture(picks.0 >= 0 ? echoes[picks.0] : none, index: 8)
    enc.setFragmentTexture(picks.1 >= 0 ? echoes[picks.1] : none, index: 9)
    enc.setFragmentTexture(picks.2 >= 0 ? echoes[picks.2] : none, index: 10)
    enc.setFragmentBytes(&sh, length: MemoryLayout<FluidShadeUniforms>.stride, index: 0)
    slotHolo.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
    enc.setFragmentBytes(&ext, length: MemoryLayout<FluidShadeExtGPU>.stride, index: 3)
    enc.setFragmentBytes(&hu, length: MemoryLayout<FluidHoloUniforms>.stride, index: 4)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    guard let pb = frame.particleBuffer, let args = frame.drawArgs else { enc.popDebugGroup(); return }
    var su = frame.splat
    su.tankToClip = tankToClip
    if frame.anyCloud && o.cloudGain > 0 {
      enc.setRenderPipelineState(cloud)
      enc.setVertexBuffer(pb, offset: 0, index: 0)
      enc.setVertexBytes(&su, length: MemoryLayout<FluidSplatUniforms>.stride, index: 1)
      enc.setVertexBytes(&sh, length: MemoryLayout<FluidShadeUniforms>.stride, index: 2)
      slotHolo.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 3) }
      enc.setVertexBytes(&ext, length: MemoryLayout<FluidShadeExtGPU>.stride, index: 4)
      enc.setVertexBytes(&hu, length: MemoryLayout<FluidHoloUniforms>.stride, index: 5)
      enc.setVertexTexture(G, index: 0)
      enc.drawPrimitives(type: .triangleStrip, indirectBuffer: args.0, indirectBufferOffset: args.1)
    }
    func overlay(_ ps: MTLRenderPipelineState) {
      enc.setRenderPipelineState(ps)
      enc.setVertexBuffer(pb, offset: 0, index: 0)
      enc.setVertexBytes(&su, length: MemoryLayout<FluidSplatUniforms>.stride, index: 1)
      enc.setVertexTexture(lut, index: 0)
      enc.drawPrimitives(type: .triangleStrip, indirectBuffer: args.0, indirectBufferOffset: args.1)
    }
    if options.showFlow { overlay(streaks) }
    if options.showParticles { overlay(particles) }
    enc.popDebugGroup()
  }

  private static func f4(_ xy: SIMD2<Float>, _ z: Float, _ w: Float) -> SIMD4<Float> { SIMD4(xy.x, xy.y, z, w) }

  /// The echo ring at G's level-1 size (allocated on first use and when the field's size changes).
  private func ensureEchoes(_ G: MTLTexture) -> Bool {
    let w = max(G.width >> 1, 1), h = max(G.height >> 1, 1)
    if echoes.count == Self.echoCapacity, echoes[0].width == w, echoes[0].height == h { return true }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: G.pixelFormat, width: w, height: h, mipmapped: false)
    d.usage = .shaderRead
    d.storageMode = .private
    var made: [MTLTexture] = []
    for i in 0..<Self.echoCapacity {
      guard let t = device.makeTexture(descriptor: d) else { echoes = []; return false }
      t.label = "LabKitMPM echo \(i)"
      made.append(t)
    }
    echoes = made
    for i in 0..<echoTimes.count { echoTimes[i] = -1 }
    echoHead = 0
    return true
  }

  // MARK: Helpers

  private func encodeBlur(_ cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, pipeline: MTLRenderPipelineState,
                          count: Int, source: Int, step: SIMD2<Float>) {
    guard let e = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
    e.label = "LabKitMPM fluid blur"
    var s = step
    e.setRenderPipelineState(pipeline)
    for i in 0..<count { e.setFragmentTexture(fields[source + i], index: i) }
    e.setFragmentBytes(&s, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    e.endEncoding()
  }

  /// Field textures (¼–½ resolution of the tank rectangle) and their pass descriptors, reallocated when the size changes.
  private func ensureFields(_ size: SIMD2<Int>) -> Bool {
    if size == fieldSize && fields.count == 2 * Self.targetCount && gradientField != nil { return true }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.x, height: size.y, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .private
    var made: [MTLTexture] = []
    let n = Self.targetCount
    for i in 0..<(2 * n) {
      guard let t = device.makeTexture(descriptor: d) else { fields = []; fieldSize = .zero; return false }
      t.label = "LabKitMPM field \(["A", "W0", "W1", "B", "S"][i % n]) \(i / n)"
      made.append(t)
    }
    let gd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.x, height: size.y, mipmapped: true)
    gd.usage = [.renderTarget, .shaderRead]
    gd.storageMode = .private
    guard let g = device.makeTexture(descriptor: gd) else { fields = []; fieldSize = .zero; return false }
    g.label = "LabKitMPM field G (mipmapped)"
    fields = made
    gradientField = g
    fieldSize = size
    splatPass = Self.pass(Array(made[0..<n]), clear: true)
    blurPassH = Self.pass(Array(made[n..<(2 * n)]), clear: false)
    blurPassV = Self.pass(Array(made[0..<n]), clear: false)
    let k = Self.holoTargetCount
    holoSplatPass = Self.pass(Array(made[0..<k]), clear: true)
    holoBlurPassH = Self.pass(Array(made[n..<(n + k)]), clear: false)
    holoBlurPassV = Self.pass(Array(made[0..<k]), clear: false)
    echoes = []                                                              // the ring follows the field's size
    for i in 0..<echoTimes.count { echoTimes[i] = -1 }
    gradientPass = Self.pass([g], clear: false)
    return true
  }

  /// Per-slot dye state (particle tag, dye value), one entry per particle slot of the solver.
  private func ensureDye(capacity: Int) -> Bool {
    if dyeBuffer != nil && dyeCapacity == capacity { return true }
    let bytes = max(capacity, 1) * MemoryLayout<SIMD2<Float>>.stride
    guard let b = device.makeBuffer(length: bytes, options: .storageModeShared) else { dyeBuffer = nil; return false }
    let p = b.contents().bindMemory(to: SIMD2<Float>.self, capacity: max(capacity, 1))
    for i in 0..<max(capacity, 1) { p[i] = SIMD2(-1, 0) }                   // no tag is negative: every slot is new
    b.label = "LabKitMPM dye"
    dyeBuffer = b
    dyeCapacity = capacity
    return true
  }

  private static func pass(_ targets: [MTLTexture], clear: Bool) -> MTLRenderPassDescriptor {
    let d = MTLRenderPassDescriptor()
    for (i, t) in targets.enumerated() {
      d.colorAttachments[i].texture = t
      d.colorAttachments[i].loadAction = clear ? .clear : .dontCare
      d.colorAttachments[i].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      d.colorAttachments[i].storeAction = .store
    }
    return d
  }

  /// Size of the field textures (0 before the first prepass). Diagnostics and tests.
  public var fieldTextureSize: SIMD2<Int> { fieldSize }

  /// Where the fluid is, for app shaders (e.g. props drawn wet where the fluid covers them): the mipmapped thickness
  /// field G = (t, ∂t/∂u, ∂t/∂v) of the last prepass, the drawable-pixel rectangle it covers (origin xy, size zw), and
  /// the iso level. Nil before the first prepass.
  public var surfaceField: (texture: MTLTexture, rect: SIMD4<Float>, threshold: Float)? {
    guard frame.valid, let g = gradientField else { return nil }
    return (g, frame.shade.fieldRect, threshold)
  }
}

/// Mirrors `FLShadeExt` in MPMRender.metal.
struct FluidShadeExtGPU {
  var glow = SIMD4<Float>(0, 0, 0, 0)     // stress-light colour, amount
  var view = SIMD4<Float>(0, 0, 0.5, 1)   // px per metre, coarse LOD, field texels per px, droplets
  var env = SIMD4<Float>(0, 0.5, 0.866, 0)
  var misc = SIMD4<Float>(0, 0, 0, 0)     // time, dye strength, normal LOD of G
}

/// Mirrors `FLDyeParams` in MPMRender.metal.
struct FluidDyeParams {
  var originCells: SIMD2<Float>
  var dx: Float
  var period: Float
  var width: Float
  var time: Float
  var drift: Float
  var count: UInt32
}
