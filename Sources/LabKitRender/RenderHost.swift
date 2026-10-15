#if os(iOS)
import LabKitCore
import LabKitShaderTypes
import MetalKit
import QuartzCore
import SwiftUI
import simd

/// Keeps AR camera textures alive until the GPU is done with them.
struct KeepAlive: @unchecked Sendable { let refs: [AnyObject] }

/// The generic frame loop on an MTKView (HoloRenderer.swift:261-425), MainActor because the
/// MTKViewDelegate methods are `NS_SWIFT_UI_ACTOR` in the iOS 27 SDK (`MTKView.h:260/267`).
///
/// Frame budget (`ARCHITECTURE.md` §3): at most `FramePacing.maxFramesInFlight` (2) command
/// buffers in flight. The in-flight semaphore is tried with `wait(timeout: .now())`; when both
/// slots are busy the display frame is **skipped** (no advance, no encode, counted in
/// `stats.skippedFrames`) instead of blocking the main thread, and the next frame's dt covers the gap
/// (capped at 1/15 s). Every 0.5 s the host re-reads `DeviceConditions` and asks the display for
/// 60 fps under Low Power Mode or thermal state ≥ serious, 120 fps otherwise.
@MainActor
public final class LabRenderer: NSObject, MTKViewDelegate {
  public let device: MTLDevice
  public let library: MTLLibrary
  public let factory: PipelineFactory
  public let frameEncoder: LabFrameEncoder
  public var lines: LineRenderer { frameEncoder.lines }
  private let queue: MTLCommandQueue
  private var targets: RenderTargets?
  private var camera = LayoutCamera()
  private var clock = FrameClock()
  private let start = CACurrentMediaTime()
  private let inflight = DispatchSemaphore(value: FramePacing.maxFramesInFlight)
  private let statsBox = FrameStatsBox()
  private var frame = 0
  private var skipped = 0
  private var submitted = 0
  private var pacingCheck = Throttle(interval: FramePacing.recheckInterval)
  private var constrained = false
  public weak var scene: (any LabRenderScene)?
  /// Forces the mipmapped `behind` target even when the scene doesn't ask for the copy.
  public var wantsBehindTexture = false
  /// An app cap on the frame rate (it can only lower the policy's 120/60).
  public var requestedFPS: Int?
  public private(set) var preferredFPS = FramePacing.fullRate

  /// Bloom gain, scanline depth, chromatic aberration (HoloRenderer.swift:698: 0.6, 0.04, 0.0022).
  public var bloom: Float {
    get { frameEncoder.bloom }
    set { frameEncoder.bloom = newValue }
  }
  public var scanlines: Float {
    get { frameEncoder.scanlines }
    set { frameEncoder.scanlines = newValue }
  }
  public var aberration: Float {
    get { frameEncoder.aberration }
    set { frameEncoder.aberration = newValue }
  }

  /// GPU time and pacing (GPU times are 1–2 frames old).
  public var stats: FrameStats {
    var s = FrameStats()
    let g = statsBox.snapshot
    s.lastGPUMilliseconds = g.last
    s.gpuMilliseconds = g.ema
    s.skippedFrames = skipped
    s.submittedFrames = submitted
    s.preferredFPS = preferredFPS
    s.constrained = constrained
    return s
  }

  public init?(view: MTKView, scene: any LabRenderScene) {
    guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let encoder = try? LabFrameEncoder(device: device, drawableFormat: view.colorPixelFormat)
    else { return nil }
    queue.label = "LabKit frame queue"
    self.device = device
    self.queue = queue
    self.frameEncoder = encoder
    self.library = encoder.library
    self.factory = encoder.factory
    self.scene = scene
    super.init()
  }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { targets = nil }

  /// The completion handler, built outside the main actor so it is never MainActor-inferred
  /// (it runs on a Metal completion thread).
  private nonisolated static func completion(
    _ semaphore: DispatchSemaphore, _ stats: FrameStatsBox
  ) -> @Sendable (MTLCommandBuffer) -> Void {
    { @Sendable cb in
      stats.record(milliseconds: (cb.gpuEndTime - cb.gpuStartTime) * 1000)
      semaphore.signal()
    }
  }

  private func updatePacing(_ view: MTKView, now: Double) {
    guard pacingCheck.ready(at: now) else { return }
    let conditions = DeviceConditions.current
    constrained = conditions.isConstrained
    let fps = FramePacing.preferredFPS(conditions, requested: requestedFPS)
    preferredFPS = fps
    if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
  }

  public func draw(in view: MTKView) {
    guard let scene else { return }
    let now = CACurrentMediaTime()
    updatePacing(view, now: now)
    // Never block the main thread on the GPU: with both slots busy, skip this display frame.
    guard inflight.wait(timeout: .now()) == .success else {
      skipped += 1
      return
    }
    var slotHeld = true
    defer { if slotHeld { inflight.signal() } }

    let dt = clock.tick(now: now)
    scene.advance(dt: dt)

    let size = view.drawableSize
    guard size.width > 8, size.height > 8 else { return }
    let wantsBehind = scene.wantsBehindCopy || wantsBehindTexture
    if targets?.size != size || (targets?.behind != nil) != wantsBehind {
      targets = RenderTargets(
        device: device, size: size, wantsBehind: wantsBehind, behindMipLevels: RenderTargets.liveBehindMipLevels)
    }
    guard let targets, let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer() else { return }
    cmd.label = "LabKit frame"

    let scale = Float(view.contentScaleFactor)
    let setup: LayoutCamera.Setup
    switch scene.projection {
    case .perspective:
      setup = camera.perspective(region: scene.canvasRegion, viewBounds: view.bounds, drawableSize: size, scale: scale, dt: dt)
    case .orthographic:
      setup = camera.orthographic(region: scene.canvasRegion, viewBounds: view.bounds, drawableSize: size, scale: scale, dt: dt)
    case .orthographicRect(let world, let fit):
      setup = camera.orthographic(
        world: world, fit: fit, region: scene.canvasRegion, viewBounds: view.bounds, drawableSize: size, scale: scale, dt: dt)
    }

    frame = (frame + 1) % 3
    // iOS 27: UIScreen.main is deprecated; use the view's own window scene (HoloRenderer.swift:690).
    let headroom = Float(view.window?.windowScene?.screen.currentEDRHeadroom ?? 1)
    let info = LabFrameInfo(
      setup: setup, time: Float(now - start), dt: dt, frameIndex: frame, pxScale: scale, headroom: headroom,
      cameraDistance: camera.distance, stats: stats)

    cmd.addCompletedHandler(Self.completion(inflight, statsBox))
    slotHeld = false  // the completion handler releases it now
    frameEncoder.encode(cmd, scene: scene, targets: targets, output: drawable.texture, info: info)
    cmd.present(drawable)
    cmd.commit()
    submitted += 1
  }
}

/// The Metal canvas, edge to edge behind the chrome (HoloView, HoloRenderer.swift:718-751).
public struct LabRenderHost: UIViewRepresentable {
  public let scene: any LabRenderScene
  /// An app cap; the host still drops to 60 under Low Power Mode or serious thermal state.
  public var preferredFPS: Int?
  public init(scene: any LabRenderScene, preferredFPS: Int? = nil) {
    self.scene = scene
    self.preferredFPS = preferredFPS
  }

  public final class Coordinator {
    public internal(set) var renderer: LabRenderer?
  }

  public func makeCoordinator() -> Coordinator { Coordinator() }

  public func makeUIView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = LabFormats.drawable
    view.framebufferOnly = true
    view.preferredFramesPerSecond = FramePacing.preferredFPS(DeviceConditions.current, requested: preferredFPS)
    view.isOpaque = true
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    if let layer = view.layer as? CAMetalLayer {
      layer.wantsExtendedDynamicRangeContent = true
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    }
    let renderer = LabRenderer(view: view, scene: scene)
    renderer?.requestedFPS = preferredFPS
    context.coordinator.renderer = renderer
    view.delegate = renderer
    return view
  }

  public func updateUIView(_ view: MTKView, context: Context) {
    view.isPaused = !scene.isRunning
    context.coordinator.renderer?.requestedFPS = preferredFPS
    view.preferredFramesPerSecond = FramePacing.preferredFPS(DeviceConditions.current, requested: preferredFPS)
  }
}
#endif
