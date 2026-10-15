import CoreGraphics
import LabKitCore
import LabKitShaderTypes
import Metal
import XCTest
import simd

@testable import LabKitRender

/// The render host's contract: the package metallib loads, every pipeline builds, the flat camera
/// maps a tank onto its canvas region, and the two-phase scene pass hands `encodeScene` a mipmapped
/// copy of what lies behind. Runs on the iOS Simulator (xcodebuild test) and on the Mac
/// (`TOOLCHAINS=metal swift test`).
final class ShaderBundleTests: XCTestCase {
  func testPackageMetallibLoads() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let library = try LabShaders.library(device: device)
    for name in LabShaders.functionNames {
      XCTAssertNotNil(library.makeFunction(name: name), "missing \(name)")
    }
  }

  func testSharedLayoutsMatchTheHeader() {
    XCTAssertEqual(MemoryLayout<LabLineInstance>.stride, 64)
    XCTAssertEqual(MemoryLayout<LabQuadInstance>.stride, 48)
    XCTAssertEqual(MemoryLayout<LabMeshVertex>.stride, 32)
    XCTAssertEqual(MemoryLayout<LabFrameUniforms>.stride, 2 * 64 + 8 * 16)
  }

  @MainActor func testPipelinesBuild() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let library = try LabShaders.library(device: device)
    let factory = PipelineFactory(device: device, lab: library)
    for format in [MTLPixelFormat.rgba16Float, .bgra8Unorm] {
      _ = try PostChain(factory: factory, drawableFormat: format)
    }
    _ = try LineRenderer(device: device, factory: factory)
    _ = try QuadRenderer(device: device, factory: factory)
    for blend in [LabBlend.none, .add, .alpha, .premultiplied] {
      _ = try factory.make(vertex: "labFullscreenVertex", fragment: "labBackdropFragment", blend: blend, depth: true)
    }
    XCTAssertNotNil(DepthStates.make(device, reversed: false))
    XCTAssertNotNil(DepthStates.make(device, reversed: true))
    XCTAssertThrowsError(try factory.make(vertex: "labFullscreenVertex", fragment: "noSuchFragment", blend: .none, depth: false))
    let encoder = try LabFrameEncoder(device: device)
    XCTAssertEqual(encoder.post.composite.label, "labFullscreenVertex · labCompositeFragment", "pipelines are always labelled")
  }

  func testRenderTargetsBehindIsMipmapped() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let plain = try XCTUnwrap(RenderTargets(device: device, size: CGSize(width: 1290, height: 2796)))
    XCTAssertNil(plain.behind)
    let t = try XCTUnwrap(RenderTargets(device: device, size: CGSize(width: 1290, height: 2796), wantsBehind: true))
    let behind = try XCTUnwrap(t.behind)
    XCTAssertEqual(behind.pixelFormat, t.scene.pixelFormat)
    XCTAssertEqual(behind.width, t.scene.width)
    XCTAssertEqual(t.behindMipCount, 12, "1290×2796 → ⌊log2 2796⌋ + 1 levels")
    XCTAssertEqual(t.halfA.width, 645)
    XCTAssertEqual(t.quarterA.height, 699)
  }

  // MARK: Orthographic tank

  /// Rheo's life-size tank: 71.2 × 101.4 mm (origin bottom-left, y up) on the 15 Pro Max canvas
  /// region x 0–430, y 59–671 pt at 3 px/pt in a 1290 × 2796 px drawable.
  func testOrthographicMatrixMapsTankCornersToCanvasRegion() {
    let tank = CGRect(x: 0, y: 0, width: 0.0712, height: 0.1014)
    let regionPt = CGRect(x: 0, y: 59, width: 430, height: 612)
    let regionPx = CGRect(x: 0, y: 177, width: 1290, height: 1836)
    let drawable = CGSize(width: 1290, height: 2796)
    let m = LayoutCamera.orthographicMatrix(world: tank, regionPx: regionPx, drawablePx: drawable)
    func px(_ x: Double, _ y: Double) -> SIMD2<Double> {
      LayoutCamera.clipToPixels(m * F4(Float(x), Float(y), 0, 1), drawablePx: drawable)
    }
    assertNear(px(0, 0), SIMD2(0, 2013), "bottom-left corner → region bottom-left (y down)")
    assertNear(px(0.0712, 0), SIMD2(1290, 2013), "bottom-right")
    assertNear(px(0, 0.1014), SIMD2(0, 177), "top-left")
    assertNear(px(0.0712, 0.1014), SIMD2(1290, 177), "top-right")
    assertNear(px(0.0356, 0.0507), SIMD2(645, 1095), "centre")
    // Depth: z ∈ [−1, 1] → [1, 0].
    XCTAssertEqual((m * F4(0, 0, 1, 1)).z, 0, accuracy: 1e-6)
    XCTAssertEqual((m * F4(0, 0, -1, 1)).z, 1, accuracy: 1e-6)

    // The eased camera converges on the same matrix.
    var cam = LayoutCamera()
    var setup = cam.orthographic(
      world: tank, region: regionPt, viewBounds: CGRect(x: 0, y: 0, width: 430, height: 932), drawableSize: drawable,
      scale: 3, dt: 1.0 / 120)
    for _ in 0..<10 {
      setup = cam.orthographic(
        world: tank, region: regionPt, viewBounds: CGRect(x: 0, y: 0, width: 430, height: 932), drawableSize: drawable,
        scale: 3, dt: 1.0 / 120)
    }
    for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(setup.viewProj[c][r], m[c][r], accuracy: 1e-5) } }
    XCTAssertEqual(setup.centerPx.x, 645, accuracy: 1e-3)
    XCTAssertEqual(setup.centerPx.y, 1095, accuracy: 1e-3)
  }

  /// The plain flat camera (`.orthographic`, Gyre's planned 2D mode): y ∈ [−1, 1] spans the region's
  /// height, x uses the same scale, origin at the region centre, y up; z ∈ [−1, 1] → depth [1, 0].
  func testPlainOrthographicMapsUnitsOntoRegion() {
    var cam = LayoutCamera()
    let regionPt = CGRect(x: 0, y: 59, width: 430, height: 612)
    let drawable = CGSize(width: 1290, height: 2796)
    let setup = cam.orthographic(
      region: regionPt, viewBounds: CGRect(x: 0, y: 0, width: 430, height: 932), drawableSize: drawable, scale: 3,
      dt: 1.0 / 120)
    func px(_ x: Float, _ y: Float) -> SIMD2<Double> {
      LayoutCamera.clipToPixels(setup.viewProj * F4(x, y, 0, 1), drawablePx: drawable)
    }
    let aspect = Float(430.0 / 612.0)
    assertNear(px(0, 0), SIMD2(645, 1095), "origin → region centre")
    assertNear(px(0, 1), SIMD2(645, 177), "y = +1 → region top")
    assertNear(px(0, -1), SIMD2(645, 2013), "y = −1 → region bottom")
    assertNear(px(aspect, 0), SIMD2(1290, 1095), "x = +aspect → region right edge")
    assertNear(px(-aspect, 0), SIMD2(0, 1095), "x = −aspect → region left edge")
    XCTAssertEqual((setup.viewProj * F4(0, 0, 1, 1)).z, 0, accuracy: 1e-6)
    XCTAssertEqual((setup.viewProj * F4(0, 0, -1, 1)).z, 1, accuracy: 1e-6)
    XCTAssertEqual(setup.radiusPx, 918, accuracy: 1e-3)
  }

  func testOrthographicFitModes() {
    let world = CGRect(x: -1, y: -1, width: 2, height: 2)  // a square
    let region = CGRect(x: 100, y: 200, width: 400, height: 800)
    let drawable = CGSize(width: 600, height: 1200)
    let contain = LayoutCamera.orthographicMatrix(world: world, regionPx: region, drawablePx: drawable, fit: .contain)
    let cover = LayoutCamera.orthographicMatrix(world: world, regionPx: region, drawablePx: drawable, fit: .cover)
    func px(_ m: simd_float4x4, _ x: Float, _ y: Float) -> SIMD2<Double> {
      LayoutCamera.clipToPixels(m * F4(x, y, 0, 1), drawablePx: drawable)
    }
    // Contain: 400 × 400 centred at (300, 600).
    assertNear(px(contain, -1, 1), SIMD2(100, 400), "contain top-left")
    assertNear(px(contain, 1, -1), SIMD2(500, 800), "contain bottom-right")
    // Cover: 800 × 800 centred, overflowing left and right.
    assertNear(px(cover, -1, 1), SIMD2(-100, 200), "cover top-left")
    assertNear(px(cover, 1, -1), SIMD2(700, 1000), "cover bottom-right")
    XCTAssertEqual(LayoutCamera.fittedRect(CGSize(width: 2, height: 1), in: region, fit: .stretch), region)
  }

  private func assertNear(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: 0.01, message, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: 0.01, message, file: file, line: line)
  }

  // MARK: Two-phase scene

  /// encodeBehind paints the left half red; encodeScene (after the copy) mirrors `behind` into the
  /// right half and draws a green LabKit quad. The scene target must show red on both sides, which
  /// only happens if pass 2 saw the copy; the copy's top mip must hold the average.
  @MainActor func testBehindCopyFeedsTheSecondPass() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let size = CGSize(width: 64, height: 32)
    let targets = try XCTUnwrap(RenderTargets(device: device, size: size, wantsBehind: true))
    let encoder = try LabFrameEncoder(device: device, drawableFormat: .rgba16Float)
    let scene = try TwoPhaseScene(device: device, encoder: encoder)
    let output = try XCTUnwrap(makeTexture(device, size, usage: [.renderTarget, .shaderRead]))
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let cmd = try XCTUnwrap(queue.makeCommandBuffer())
    let world = CGRect(x: 0, y: 0, width: 2, height: 1)
    let regionPx = CGRect(origin: .zero, size: size)
    let m = LayoutCamera.orthographicMatrix(world: world, regionPx: regionPx, drawablePx: size)
    let setup = LayoutCamera.Setup(
      viewProj: m, eye: F4(1, 0.5, 1000, 0), centerPx: SIMD2(32, 16), radiusPx: 16, focal: 16,
      basis: ViewBasis(eye: F3(1, 0.5, 1000), widthScale: 1), reversedDepth: false)
    encoder.bloom = 0
    encoder.scanlines = 0
    encoder.aberration = 0
    encoder.encode(cmd, scene: scene, targets: targets, output: output, info: LabFrameInfo(setup: setup, time: 0, dt: 1.0 / 120, frameIndex: 0, pxScale: 1))
    // Read back through shared buffers (the simulator GPU has no unified memory).
    let w = Int(size.width), h = Int(size.height)
    let sceneBytes = try XCTUnwrap(device.makeBuffer(length: w * h * 8, options: .storageModeShared))
    let topBytes = try XCTUnwrap(device.makeBuffer(length: 8, options: .storageModeShared))
    let blit = try XCTUnwrap(cmd.makeBlitCommandEncoder())
    blit.copy(
      from: targets.scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
      to: sceneBytes, destinationOffset: 0, destinationBytesPerRow: w * 8, destinationBytesPerImage: w * h * 8)
    let behind = try XCTUnwrap(targets.behind)
    blit.copy(
      from: behind, sourceSlice: 0, sourceLevel: behind.mipmapLevelCount - 1, sourceOrigin: MTLOrigin(),
      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: topBytes, destinationOffset: 0, destinationBytesPerRow: 8,
      destinationBytesPerImage: 8)
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    XCTAssertNil(cmd.error)
    XCTAssertTrue(encoder.lastFrameSplit)
    XCTAssertEqual(scene.calls, ["compute", "behind", "scene"])

    let pixels = rgba16F(sceneBytes, count: w * h)
    func at(_ x: Int, _ y: Int) -> SIMD4<Float> { pixels[y * w + x] }
    let left = at(8, 16), right = at(56, 16), quad = at(32, 4)
    XCTAssertEqual(left.x, 1, accuracy: 0.01, "behind layer: red")
    XCTAssertEqual(left.y, 0, accuracy: 0.01)
    XCTAssertEqual(right.x, 1, accuracy: 0.01, "pass 2 sampled the copy (mirrored red)")
    XCTAssertEqual(right.z, 0, accuracy: 0.01)
    XCTAssertEqual(quad.y, 1, accuracy: 0.01, "LabKit quad drawn over it in pass 2")
    let top = rgba16F(topBytes, count: 1)[0]
    XCTAssertEqual(top.x, 0.5, accuracy: 0.02, "top mip = average of half red, half black")
    XCTAssertEqual(targets.behindMipCount, 7)
  }

  @MainActor func testSinglePassWhenNoCopyWanted() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let size = CGSize(width: 32, height: 32)
    let targets = try XCTUnwrap(RenderTargets(device: device, size: size))
    let encoder = try LabFrameEncoder(device: device, drawableFormat: .rgba16Float)
    let scene = try TwoPhaseScene(device: device, encoder: encoder)
    scene.split = false
    let output = try XCTUnwrap(makeTexture(device, size, usage: [.renderTarget, .shaderRead]))
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let cmd = try XCTUnwrap(queue.makeCommandBuffer())
    let m = LayoutCamera.orthographicMatrix(world: CGRect(x: 0, y: 0, width: 2, height: 1), regionPx: CGRect(origin: .zero, size: size), drawablePx: size)
    let setup = LayoutCamera.Setup(
      viewProj: m, eye: F4(1, 0.5, 1000, 0), centerPx: SIMD2(16, 16), radiusPx: 16, focal: 16,
      basis: ViewBasis(eye: F3(1, 0.5, 1000), widthScale: 1), reversedDepth: false)
    encoder.encode(cmd, scene: scene, targets: targets, output: output, info: LabFrameInfo(setup: setup, time: 0, dt: 1.0 / 120, frameIndex: 1, pxScale: 1))
    cmd.commit()
    cmd.waitUntilCompleted()
    XCTAssertNil(cmd.error)
    XCTAssertFalse(encoder.lastFrameSplit)
    XCTAssertEqual(scene.calls, ["compute", "behind", "scene"], "behind still precedes scene in one pass")
  }

  // MARK: Helpers

  private func makeTexture(_ device: MTLDevice, _ size: CGSize, usage: MTLTextureUsage) -> MTLTexture? {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(size.width), height: Int(size.height), mipmapped: false)
    d.usage = usage
    d.storageMode = .private
    return device.makeTexture(descriptor: d)
  }

  private func rgba16F(_ buffer: MTLBuffer, count: Int) -> [SIMD4<Float>] {
    let raw = buffer.contents().bindMemory(to: UInt16.self, capacity: count * 4)
    return (0..<count).map { i in
      SIMD4(
        Float(Float16(bitPattern: raw[i * 4])), Float(Float16(bitPattern: raw[i * 4 + 1])),
        Float(Float16(bitPattern: raw[i * 4 + 2])), Float(Float16(bitPattern: raw[i * 4 + 3])))
    }
  }
}

/// A scene in a 2 × 1 world: behind = red left half; scene = right half mirrors `behind`, plus a green quad.
@MainActor private final class TwoPhaseScene: LabRenderScene {
  var isRunning = true
  var reduceMotion = true
  var canvasRegion = CGRect.zero
  var projection: LabProjection { .orthographicRect(CGRect(x: 0, y: 0, width: 2, height: 1)) }
  var drawsBackdrop: Bool { false }
  var split = true
  var wantsBehindCopy: Bool { split }
  var calls: [String] = []
  private let flat: QuadRenderer
  private let mirror: QuadRenderer

  init(device: MTLDevice, encoder: LabFrameEncoder) throws {
    flat = try QuadRenderer(device: device, factory: encoder.factory)
    // A test fragment compiled at runtime from source, linked with LabKit's quad vertex.
    let source = """
      #include <metal_stdlib>
      using namespace metal;
      struct LabQuadOut {
        float4 position [[position]];
        float2 uv [[user(lab_uv)]];
        float2 local [[user(lab_local)]];
        float2 halfSize [[user(lab_half)]];
        float4 color [[user(lab_color)]];
        float4 params [[user(lab_params)]];
      };
      fragment float4 testMirrorBehind(LabQuadOut in [[stage_in]], texture2d<float> behind [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float2 uv = in.position.xy / float2(behind.get_width(), behind.get_height());
        return float4(behind.sample(s, float2(1.0 - uv.x, uv.y), level(0.0)).rgb, 1.0);
      }
      """
    let lib = try device.makeLibrary(source: source, options: nil)
    mirror = try QuadRenderer(device: device, factory: encoder.factory, fragment: "testMirrorBehind", fragmentLibrary: lib, blend: .none)
  }

  func advance(dt: Double) {}
  func encodeCompute(_ cmd: MTLCommandBuffer, context: LabFrameContext) { calls.append("compute") }

  func encodeBehind(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext) {
    calls.append("behind")
    flat.draw(enc, quads: [LabQuadInstance(rect: CGRect(x: 0, y: 0, width: 1, height: 1), color: F4(1, 0, 0, 1))], uniforms: &uniforms, depth: context.depth.always)
  }

  func encodeScene(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext) {
    calls.append("scene")
    guard let behind = context.targets.behind, wantsBehindCopy else { return }
    enc.setFragmentTexture(behind, index: 0)
    mirror.draw(enc, quads: [LabQuadInstance(rect: CGRect(x: 1, y: 0, width: 1, height: 1), color: F4(0, 0, 0, 1))], uniforms: &uniforms, depth: context.depth.always)
    flat.draw(enc, quads: [LabQuadInstance(rect: CGRect(x: 0.9, y: 0.8, width: 0.2, height: 0.2), color: F4(0, 1, 0, 1), z: 0.5)], uniforms: &uniforms, depth: context.depth.always)
  }
}
