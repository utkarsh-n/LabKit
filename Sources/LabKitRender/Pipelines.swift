import Foundation
import LabKitShaderTypes
import Metal

/// The package's compiled shaders. Xcode compiles every `.metal` in this target into
/// `default.metallib` inside the target's resource bundle; `Bundle.module` finds it.
public enum LabShaders {
  public static let functionNames = [
    "labFullscreenVertex", "labBackdropFragment", "labLineVertex", "labLineFragment",
    "labPrefilterFragment", "labCopyFragment", "labBlurFragment", "labCompositeFragment",
    "labQuadVertex", "labQuadFragment",
  ]

  public static func library(device: MTLDevice) throws -> MTLLibrary {
    try device.makeDefaultLibrary(bundle: .module)
  }
}

public enum LabRenderError: Error, CustomStringConvertible {
  case missingFunction(String)
  case deviceFailure(String)
  public var description: String {
    switch self {
    case .missingFunction(let name): "Metal function '\(name)' is not in the library"
    case .deviceFailure(let what): "Metal device could not make \(what)"
    }
  }
}

/// Colour blending for a pipeline.
public enum LabBlend: Sendable {
  case none
  /// RGB one/one, alpha untouched: glow.
  case add
  /// Straight alpha: src·a + dst·(1 − a).
  case alpha
  /// Premultiplied alpha: src + dst·(1 − a) (LabKit's quad fragment outputs this).
  case premultiplied
}

public enum LabFormats {
  public static let scene: MTLPixelFormat = .rgba16Float
  public static let depth: MTLPixelFormat = .depth32Float
  public static let drawable: MTLPixelFormat = .rgba16Float
}

/// Gyre's local `pipeline(vertex, fragment, format:, blend:, depth:)` (HoloRenderer.swift:98-126),
/// generalised to take functions from any library (app shaders + LabKit shaders can mix).
public struct PipelineFactory {
  public let device: MTLDevice
  public let lab: MTLLibrary
  public init(device: MTLDevice, lab: MTLLibrary) {
    self.device = device
    self.lab = lab
  }

  /// A render pipeline. Functions may come from different libraries (LabKit's and the app's).
  /// The label defaults to "vertex · fragment"; it is never set to nil (setLabel:nil asserts under
  /// Metal API validation, seen in the prototype's smoke run).
  public func make(
    vertex: String, fragment: String, vertexLibrary: MTLLibrary? = nil, fragmentLibrary: MTLLibrary? = nil,
    format: MTLPixelFormat = LabFormats.scene, blend: LabBlend, depth: Bool, label: String? = nil
  ) throws -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.label = label ?? "\(vertex) · \(fragment)"
    guard let vf = (vertexLibrary ?? lab).makeFunction(name: vertex) else { throw LabRenderError.missingFunction(vertex) }
    guard let ff = (fragmentLibrary ?? lab).makeFunction(name: fragment) else {
      throw LabRenderError.missingFunction(fragment)
    }
    d.vertexFunction = vf
    d.fragmentFunction = ff
    if depth { d.depthAttachmentPixelFormat = LabFormats.depth }
    let a = d.colorAttachments[0]!
    a.pixelFormat = format
    switch blend {
    case .none:
      a.isBlendingEnabled = false
    case .add:
      // RGB one/one, alpha zero/one: glow accumulates, alpha (the AR camera mask) is untouched.
      a.isBlendingEnabled = true
      a.rgbBlendOperation = .add
      a.alphaBlendOperation = .add
      a.sourceRGBBlendFactor = .one
      a.destinationRGBBlendFactor = .one
      a.sourceAlphaBlendFactor = .zero
      a.destinationAlphaBlendFactor = .one
    case .alpha:
      a.isBlendingEnabled = true
      a.rgbBlendOperation = .add
      a.alphaBlendOperation = .add
      a.sourceRGBBlendFactor = .sourceAlpha
      a.destinationRGBBlendFactor = .oneMinusSourceAlpha
      a.sourceAlphaBlendFactor = .one
      a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    case .premultiplied:
      a.isBlendingEnabled = true
      a.rgbBlendOperation = .add
      a.alphaBlendOperation = .add
      a.sourceRGBBlendFactor = .one
      a.destinationRGBBlendFactor = .oneMinusSourceAlpha
      a.sourceAlphaBlendFactor = .one
      a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    return try device.makeRenderPipelineState(descriptor: d)
  }

  /// A compute pipeline from LabKit's library or the app's (Rheo's MPM kernels come from its own).
  public func makeCompute(_ function: String, library: MTLLibrary? = nil, label: String? = nil) throws
    -> MTLComputePipelineState
  {
    guard let f = (library ?? lab).makeFunction(name: function) else { throw LabRenderError.missingFunction(function) }
    let d = MTLComputePipelineDescriptor()
    d.label = label ?? function
    d.computeFunction = f
    return try device.makeComputePipelineState(descriptor: d, options: [], reflection: nil)
  }
}

/// Depth states for standard (0 near) and reversed (1 near, ARKit) projections (HoloRenderer.swift:157-168).
public struct DepthStates {
  public let always: MTLDepthStencilState
  public let write: MTLDepthStencilState
  public let test: MTLDepthStencilState

  public static func make(_ device: MTLDevice, reversed: Bool) -> DepthStates? {
    func state(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
      let d = MTLDepthStencilDescriptor()
      d.depthCompareFunction = compare
      d.isDepthWriteEnabled = write
      return device.makeDepthStencilState(descriptor: d)
    }
    let cmp: MTLCompareFunction = reversed ? .greaterEqual : .lessEqual
    guard let a = state(.always, write: false), let w = state(cmp, write: true), let t = state(cmp, write: false) else {
      return nil
    }
    return DepthStates(always: a, write: w, test: t)
  }
}

/// Offscreen targets (HoloRenderer.swift:235-253): half-float scene + depth32, bloom at ½ and ¼,
/// all `.private`; optional mipmapped `behind` copy for refraction (glass orb / fluid lensing).
public struct RenderTargets {
  public let size: CGSize
  public let scene: MTLTexture
  public let depth: MTLTexture
  public let halfA: MTLTexture
  public let halfB: MTLTexture
  public let quarterA: MTLTexture
  public let quarterB: MTLTexture
  public let behind: MTLTexture?

  /// Mip levels `LabRenderer` gives `behind`: lod 0…7 (1/128 size). The fluid shade samples lod ≤ 6 (turbidity ≤ 4,
  /// + 2 at a dry edge) and Gyre's frosted orb ≤ 5.4. The full chain of a 1290 × 2796 target has 12 levels, and each
  /// level costs the blit's mip generation about 10 driver heap allocations on the main thread every frame (LK-FIX,
  /// measured on the M1 Max: 110 for 12 levels, 70 for 8).
  public static let liveBehindMipLevels = 8

  public init?(device: MTLDevice, size: CGSize, wantsBehind: Bool = false) {
    self.init(device: device, size: size, wantsBehind: wantsBehind, behindMipLevels: nil)
  }

  /// As above, with at most `behindMipLevels` (≥ 1) mip levels in `behind`; nil = the full chain.
  public init?(device: MTLDevice, size: CGSize, wantsBehind: Bool, behindMipLevels: Int?) {
    func tex(_ w: Int, _ h: Int, _ format: MTLPixelFormat = LabFormats.scene, _ label: String) -> MTLTexture? {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
      d.usage = format == LabFormats.depth ? [.renderTarget] : [.renderTarget, .shaderRead]
      d.storageMode = .private
      let t = device.makeTexture(descriptor: d)
      t?.label = label
      return t
    }
    let w = Int(size.width), h = Int(size.height)
    guard let s = tex(w, h, LabFormats.scene, "LabKit scene"), let z = tex(w, h, LabFormats.depth, "LabKit depth"),
      let ha = tex(w / 2, h / 2, LabFormats.scene, "LabKit bloom ½ A"), let hb = tex(w / 2, h / 2, LabFormats.scene, "LabKit bloom ½ B"),
      let qa = tex(w / 4, h / 4, LabFormats.scene, "LabKit bloom ¼ A"), let qb = tex(w / 4, h / 4, LabFormats.scene, "LabKit bloom ¼ B")
    else { return nil }
    var behind: MTLTexture?
    if wantsBehind {
      // Same format and size as the scene (a blit copy needs both), with a full mip chain for
      // frosted/turbid refraction (Gyre glass orb: lod = 0.4·frost + scuff·5).
      let mips = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LabFormats.scene, width: max(w, 1), height: max(h, 1), mipmapped: true)
      if let cap = behindMipLevels { mips.mipmapLevelCount = min(max(cap, 1), mips.mipmapLevelCount) }
      mips.usage = [.shaderRead]
      mips.storageMode = .private
      behind = device.makeTexture(descriptor: mips)
      guard behind != nil else { return nil }
      behind?.label = "LabKit behind (mipmapped)"
    }
    self.size = size
    scene = s
    depth = z
    halfA = ha
    halfB = hb
    quarterA = qa
    quarterB = qb
    self.behind = behind
  }

  /// Mip levels in `behind` (0 without it).
  public var behindMipCount: Int { behind?.mipmapLevelCount ?? 0 }
}

/// Bloom (prefilter → blur ½ H,V at 1.4 texels → copy to ¼ → blur H,V at 2.2 texels) and the
/// composite into the drawable (HoloRenderer.swift:403-424).
public struct PostChain {
  public let prefilter: MTLRenderPipelineState
  public let copy: MTLRenderPipelineState
  public let blur: MTLRenderPipelineState
  public let composite: MTLRenderPipelineState
  /// One render pass descriptor per pass of the chain, made once and re-pointed at this frame's texture: a fresh
  /// `MTLRenderPassDescriptor` costs 4 heap allocations, 28 per frame for the chain's 7 passes (LK-FIX, measured with
  /// libmalloc's `malloc_logger` on the main thread).
  private let passes: PassCache

  /// The chain's reusable pass descriptors (load `.dontCare`, store `.store`; Metal copies a descriptor's state when
  /// it makes the encoder, so re-pointing one afterwards is safe).
  private final class PassCache {
    let descriptors: [MTLRenderPassDescriptor] = (0..<7).map { _ in PostChain.pass(nil, clear: false) }
    func pass(_ index: Int, _ texture: MTLTexture) -> MTLRenderPassDescriptor {
      let d = descriptors[index]
      d.colorAttachments[0].texture = texture
      return d
    }
  }

  public init(factory f: PipelineFactory, drawableFormat: MTLPixelFormat) throws {
    prefilter = try f.make(vertex: "labFullscreenVertex", fragment: "labPrefilterFragment", blend: .none, depth: false)
    copy = try f.make(vertex: "labFullscreenVertex", fragment: "labCopyFragment", blend: .none, depth: false)
    blur = try f.make(vertex: "labFullscreenVertex", fragment: "labBlurFragment", blend: .none, depth: false)
    composite = try f.make(
      vertex: "labFullscreenVertex", fragment: "labCompositeFragment", format: drawableFormat, blend: .none, depth: false)
    passes = PassCache()
  }

  /// A single-colour-attachment pass on `texture` (clear to black at `alpha`, or don't care), stored.
  public static func pass(_ texture: MTLTexture?, clear: Bool, alpha: Double = 1) -> MTLRenderPassDescriptor {
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = texture
    d.colorAttachments[0].loadAction = clear ? .clear : .dontCare
    d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: alpha)
    d.colorAttachments[0].storeAction = .store
    return d
  }

  public func encode(
    _ cmd: MTLCommandBuffer, targets t: RenderTargets, drawable: MTLTexture, uniforms: inout LabFrameUniforms,
    luma: MTLTexture, chroma: MTLTexture
  ) {
    fullscreen(cmd, prefilter, from: t.scene, to: t.halfA, pass: 0)
    blurPass(cmd, from: t.halfA, to: t.halfB, step: SIMD2(1.4 / Float(t.halfA.width), 0), pass: 1)
    blurPass(cmd, from: t.halfB, to: t.halfA, step: SIMD2(0, 1.4 / Float(t.halfA.height)), pass: 2)
    fullscreen(cmd, copy, from: t.halfA, to: t.quarterA, pass: 3)
    blurPass(cmd, from: t.quarterA, to: t.quarterB, step: SIMD2(2.2 / Float(t.quarterA.width), 0), pass: 4)
    blurPass(cmd, from: t.quarterB, to: t.quarterA, step: SIMD2(0, 2.2 / Float(t.quarterA.height)), pass: 5)
    let final = passes.pass(6, drawable)
    let made = cmd.makeRenderCommandEncoder(descriptor: final)
    final.colorAttachments[0].texture = nil   // never hold on to a drawable's texture between frames
    guard let enc = made else { return }
    enc.setRenderPipelineState(composite)
    enc.setFragmentTexture(t.scene, index: 0)
    enc.setFragmentTexture(t.halfA, index: 1)
    enc.setFragmentTexture(t.quarterA, index: 2)
    enc.setFragmentTexture(luma, index: 3)
    enc.setFragmentTexture(chroma, index: 4)
    enc.setFragmentBytes(&uniforms, length: MemoryLayout<LabFrameUniforms>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }

  private func fullscreen(_ cmd: MTLCommandBuffer, _ p: MTLRenderPipelineState, from: MTLTexture, to: MTLTexture, pass: Int) {
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: passes.pass(pass, to)) else { return }
    enc.setRenderPipelineState(p)
    enc.setFragmentTexture(from, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }

  private func blurPass(_ cmd: MTLCommandBuffer, from: MTLTexture, to: MTLTexture, step: SIMD2<Float>, pass: Int) {
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: passes.pass(pass, to)) else { return }
    var s = step
    enc.setRenderPipelineState(blur)
    enc.setFragmentTexture(from, index: 0)
    enc.setFragmentBytes(&s, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
  }
}
