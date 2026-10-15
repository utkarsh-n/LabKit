import CoreGraphics
import Foundation
import LabKitCore
import LabKitShaderTypes
import Metal
import Synchronization
import simd

/// How the scene frame maps onto the canvas region.
public enum LabProjection: Sendable, Equatable {
  /// Gyre's "phone as a window" camera about the focus circle.
  case perspective
  /// Flat: y ∈ [−1, 1] spans the region's height, x uses the same scale, origin at the region centre.
  case orthographic
  /// Flat, in your own units: `world` (x right, y up; e.g. a tank in metres with its origin
  /// bottom-left) maps onto the canvas region. With `.stretch` the world's corners land exactly on
  /// the region's corners; Rheo sizes the world from the region × `LabMetrics.millimetresPerPoint`
  /// so the tank is drawn life-size.
  case orthographicRect(CGRect, fit: LabFit = .stretch)
}

/// How a world rectangle fits the canvas region.
public enum LabFit: Sendable, Equatable {
  /// Corners to corners (scale may differ in x and y).
  case stretch
  /// Uniform scale, the whole world visible, centred (letterboxed).
  case contain
  /// Uniform scale, the region filled, centred (cropped).
  case cover
}

/// GPU timing and pacing, from the latest completed frames.
public struct FrameStats: Sendable, Equatable {
  /// Command-buffer GPU time of the latest completed frame, ms (gpuEndTime − gpuStartTime).
  public var lastGPUMilliseconds = 0.0
  /// Smoothed GPU time, ms (exponential, factor 0.1 per frame).
  public var gpuMilliseconds = 0.0
  /// Display frames skipped because `FramePacing.maxFramesInFlight` frames were still on the GPU.
  public var skippedFrames = 0
  /// Frames submitted.
  public var submittedFrames = 0
  /// The rate the display was asked for (60 when constrained).
  public var preferredFPS = FramePacing.fullRate
  /// Low Power or serious thermal state at the last check.
  public var constrained = false
  public init() {}
}

/// Collects GPU times from command-buffer completion handlers (any thread).
final class FrameStatsBox: Sendable {
  private let state = Mutex((last: 0.0, ema: 0.0))
  func record(milliseconds ms: Double) {
    guard ms.isFinite, ms >= 0 else { return }
    state.withLock { s in
      s.last = ms
      s.ema = s.ema == 0 ? ms : s.ema + (ms - s.ema) * 0.1
    }
  }
  var snapshot: (last: Double, ema: Double) { state.withLock { $0 } }
}

/// Everything a scene needs while encoding one frame.
public struct LabFrameContext {
  public let device: MTLDevice
  /// The frame's offscreen targets. `targets.behind` (mipmapped) holds the backdrop and the
  /// `encodeBehind` layer during `encodeScene` when the scene `wantsBehindCopy`.
  public let targets: RenderTargets
  public let setup: LayoutCamera.Setup
  public let depth: DepthStates
  /// Seconds since the renderer started (real time).
  public let time: Float
  /// This frame's dt, seconds (FrameClock: first 1/120, then ≤ 1/15).
  public let dt: Double
  /// 0…2, matches the triple-buffered per-frame resources.
  public let frameIndex: Int
  /// Device pixels per point.
  public let pxScale: Float
  public let drawableSize: SIMD2<Int>
  /// Pacing and GPU time from earlier frames (1–2 frames old).
  public let stats: FrameStats

  public init(
    device: MTLDevice, targets: RenderTargets, setup: LayoutCamera.Setup, depth: DepthStates, time: Float, dt: Double,
    frameIndex: Int, pxScale: Float = 1, drawableSize: SIMD2<Int>? = nil, stats: FrameStats = FrameStats()
  ) {
    self.device = device
    self.targets = targets
    self.setup = setup
    self.depth = depth
    self.time = time
    self.dt = dt
    self.frameIndex = frameIndex
    self.pxScale = pxScale
    self.drawableSize = drawableSize ?? SIMD2(Int(targets.size.width), Int(targets.size.height))
    self.stats = stats
  }

  /// World (scene) → clip transform for this frame, e.g. Rheo's `tankToClip`.
  public var viewProj: simd_float4x4 { setup.viewProj }
}

/// The app side of the render loop. The renderer OWNS TIME: it calls `advance(dt:)` exactly once
/// per drawn frame (HoloRenderer.swift:261-272), so there are no timers and the engine never
/// runs while the view is paused. Everything per-frame on the conforming model should be
/// `@ObservationIgnored`; SwiftUI sees only a small telemetry struct republished at 10 Hz.
///
/// Frame order: `advance` → `buildLines` → `fillUniforms` → `encodeCompute` → scene pass 1
/// (backdrop, `encodeBehind`) → [if `wantsBehindCopy`: blit to the mipmapped `behind` texture +
/// generate mipmaps → scene pass 2 (load)] → `encodeScene` → lines → bloom ½, ¼ → EDR composite.
@MainActor
public protocol LabRenderScene: AnyObject {
  var isRunning: Bool { get }
  var reduceMotion: Bool { get }
  /// The canvas region's global frame from `CanvasRegion(onFrame:)`, in points.
  var canvasRegion: CGRect { get }
  /// Default `.perspective`.
  var projection: LabProjection { get }
  /// Default true.
  var drawsBackdrop: Bool { get }
  /// Default false: one scene pass, as before. True splits the scene pass around a mipmapped copy
  /// of everything drawn so far, which `encodeScene` may sample as `context.targets.behind`.
  var wantsBehindCopy: Bool { get }
  /// Step sensors → modulation → physics → feedback → telemetry. The ONLY place simulation time moves.
  func advance(dt: Double)
  /// Compute and offscreen passes on the frame's command buffer, before any scene pass
  /// (Rheo: MPM substeps, fluid splat/blur).
  func encodeCompute(_ cmd: MTLCommandBuffer, context: LabFrameContext)
  /// Opaque layer drawn after the backdrop, before the `behind` copy (Rheo: tank back wall, props behind the fluid).
  func encodeBehind(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext)
  /// Layers drawn after the `behind` mip copy; may sample `context.targets.behind` (Rheo: fluid shade,
  /// front glass, overlays). Without `wantsBehindCopy` it follows `encodeBehind` in the same pass.
  func encodeScene(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext)
  /// Glowing overlay lines for this frame (drawn after `encodeScene`, additive).
  func buildLines(_ batch: inout LineBatch, context: LabFrameContext)
  /// App fields in the shared uniforms (world.x north azimuth etc.).
  func fillUniforms(_ u: inout LabFrameUniforms)
}

extension LabRenderScene {
  public var drawsBackdrop: Bool { true }
  public var projection: LabProjection { .perspective }
  public var wantsBehindCopy: Bool { false }
  public func encodeCompute(_ cmd: MTLCommandBuffer, context: LabFrameContext) {}
  public func encodeBehind(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext) {}
  public func encodeScene(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext) {}
  public func buildLines(_ batch: inout LineBatch, context: LabFrameContext) {}
  public func fillUniforms(_ u: inout LabFrameUniforms) {}
}

/// Per-frame inputs the host supplies to `LabFrameEncoder`.
public struct LabFrameInfo {
  public var setup: LayoutCamera.Setup
  public var time: Float
  public var dt: Double
  public var frameIndex: Int
  public var pxScale: Float
  /// EDR headroom of the screen (1 = SDR).
  public var headroom: Float
  /// Camera distance in focus radii (perspective); any value for flat projections.
  public var cameraDistance: Float
  public var stats: FrameStats
  public init(
    setup: LayoutCamera.Setup, time: Float, dt: Double, frameIndex: Int, pxScale: Float, headroom: Float = 1,
    cameraDistance: Float = 3.2, stats: FrameStats = FrameStats()
  ) {
    self.setup = setup
    self.time = time
    self.dt = dt
    self.frameIndex = frameIndex
    self.pxScale = pxScale
    self.headroom = headroom
    self.cameraDistance = cameraDistance
    self.stats = stats
  }
}

/// Encodes one complete frame for a `LabRenderScene` into a command buffer: uniforms, lines,
/// compute, the (optionally two-phase) scene pass, bloom and the EDR composite into `output`.
/// `LabRenderer` drives it from an MTKView; tests and offscreen snapshots drive it directly.
@MainActor
public final class LabFrameEncoder {
  public let device: MTLDevice
  public let library: MTLLibrary
  public let factory: PipelineFactory
  public let lines: LineRenderer
  public let post: PostChain
  public let depth: DepthStates
  private let backdrop: MTLRenderPipelineState
  private let blankLuma: MTLTexture
  private let blankChroma: MTLTexture
  private var batch = LineBatch()
  /// The scene's two pass descriptors (clear, then load after the `behind` copy), made once and re-pointed at the
  /// frame's targets: a fresh descriptor costs 4–5 heap allocations a frame (LK-FIX, measured).
  private let firstPass = PostChain.pass(nil, clear: true, alpha: 1)
  private let secondPass: MTLRenderPassDescriptor = {
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].loadAction = .load
    d.colorAttachments[0].storeAction = .store
    d.depthAttachment.loadAction = .load
    d.depthAttachment.storeAction = .dontCare
    return d
  }()
  /// Bloom gain, scanline depth, chromatic aberration (HoloRenderer.swift:698: 0.6, 0.04, 0.0022).
  public var bloom: Float = 0.6
  public var scanlines: Float = 0.04
  public var aberration: Float = 0.0022
  /// Uniforms of the last encoded frame (after the scene's own edits), for inspection.
  public private(set) var lastUniforms = LabFrameUniforms()
  /// Whether the last frame was split around a `behind` copy.
  public private(set) var lastFrameSplit = false

  public init(device: MTLDevice, library: MTLLibrary? = nil, drawableFormat: MTLPixelFormat = LabFormats.drawable) throws {
    let lib = try library ?? LabShaders.library(device: device)
    let factory = PipelineFactory(device: device, lab: lib)
    guard let depth = DepthStates.make(device, reversed: false) else { throw LabRenderError.deviceFailure("depth states") }
    let luma = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
    let chroma = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false)
    guard let bl = device.makeTexture(descriptor: luma), let bc = device.makeTexture(descriptor: chroma) else {
      throw LabRenderError.deviceFailure("placeholder textures")
    }
    self.device = device
    self.library = lib
    self.factory = factory
    self.depth = depth
    backdrop = try factory.make(vertex: "labFullscreenVertex", fragment: "labBackdropFragment", blend: .none, depth: true)
    post = try PostChain(factory: factory, drawableFormat: drawableFormat)
    lines = try LineRenderer(device: device, factory: factory)
    blankLuma = bl
    blankChroma = bc
  }

  /// The frame context `encode` will hand the scene (also useful before encoding, e.g. for `advance`).
  public func context(targets: RenderTargets, info: LabFrameInfo) -> LabFrameContext {
    LabFrameContext(
      device: device, targets: targets, setup: info.setup, depth: depth, time: info.time, dt: info.dt,
      frameIndex: info.frameIndex, pxScale: info.pxScale,
      drawableSize: SIMD2(Int(targets.size.width), Int(targets.size.height)), stats: info.stats)
  }

  /// Encodes the frame. `output` is the drawable (or any texture of the post chain's format and the targets' size).
  public func encode(
    _ cmd: MTLCommandBuffer, scene: any LabRenderScene, targets: RenderTargets, output: MTLTexture, info: LabFrameInfo
  ) {
    let context = context(targets: targets, info: info)
    let setup = info.setup
    batch.pxScale = info.pxScale
    batch.cueEnabled = scene.projection == .perspective
    batch.begin(view: setup.basis, time: info.time, reduceMotion: scene.reduceMotion)
    scene.buildLines(&batch, context: context)
    lines.upload(batch, frame: info.frameIndex)

    var u = LabFrameUniforms()
    u.viewProj = setup.viewProj
    u.attitude = matrix_identity_float4x4
    u.viewport = F4(Float(targets.size.width), Float(targets.size.height), setup.centerPx.x, setup.centerPx.y)
    u.camera = F4(setup.focal, info.cameraDistance, info.time, info.headroom)
    u.post = F4(bloom, scene.reduceMotion ? 0 : scanlines, aberration, scene.reduceMotion ? 1 : 0)
    u.misc = F4(setup.radiusPx, batch.bandY, batch.flicker, 0)
    u.eye = setup.eye
    u.camA = F4(1, 0, 0, 1)
    scene.fillUniforms(&u)

    scene.encodeCompute(cmd, context: context)

    let split = scene.wantsBehindCopy && targets.behind != nil
    lastFrameSplit = split
    let first = firstPass
    first.colorAttachments[0].texture = targets.scene
    first.depthAttachment.texture = targets.depth
    first.depthAttachment.loadAction = .clear
    first.depthAttachment.clearDepth = 1
    first.depthAttachment.storeAction = split ? .store : .dontCare
    if let enc = cmd.makeRenderCommandEncoder(descriptor: first) {
      enc.label = split ? "LabKit scene: behind" : "LabKit scene"
      bind(enc, &u)
      if scene.drawsBackdrop {
        enc.setDepthStencilState(depth.always)
        enc.setRenderPipelineState(backdrop)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      }
      scene.encodeBehind(enc, uniforms: &u, context: context)
      if !split { front(enc, scene: scene, uniforms: &u, context: context) }
      enc.endEncoding()
    }

    if split, let behind = targets.behind {
      if let blit = cmd.makeBlitCommandEncoder() {
        blit.label = "LabKit behind copy"
        blit.copy(
          from: targets.scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
          sourceSize: MTLSize(width: targets.scene.width, height: targets.scene.height, depth: 1),
          to: behind, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.generateMipmaps(for: behind)
        blit.endEncoding()
      }
      let second = secondPass
      second.colorAttachments[0].texture = targets.scene
      second.depthAttachment.texture = targets.depth
      if let enc = cmd.makeRenderCommandEncoder(descriptor: second) {
        enc.label = "LabKit scene: front"
        bind(enc, &u)
        front(enc, scene: scene, uniforms: &u, context: context)
        enc.endEncoding()
      }
    }

    post.encode(cmd, targets: targets, drawable: output, uniforms: &u, luma: blankLuma, chroma: blankChroma)
    lastUniforms = u
  }

  private func bind(_ enc: MTLRenderCommandEncoder, _ u: inout LabFrameUniforms) {
    enc.setFrontFacing(.counterClockwise)
    enc.setVertexBytes(&u, length: MemoryLayout<LabFrameUniforms>.stride, index: Int(LabBufferFrame.rawValue))
    enc.setFragmentBytes(&u, length: MemoryLayout<LabFrameUniforms>.stride, index: Int(LabFragmentFrame.rawValue))
  }

  private func front(
    _ enc: MTLRenderCommandEncoder, scene: any LabRenderScene, uniforms u: inout LabFrameUniforms, context: LabFrameContext
  ) {
    scene.encodeScene(enc, uniforms: &u, context: context)
    enc.setDepthStencilState(depth.test)
    lines.draw(enc, uniforms: &u, range: 0..<batch.lines.count)
  }
}
