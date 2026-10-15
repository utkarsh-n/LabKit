import CoreGraphics
import Metal
import XCTest
import simd
import LabKitCore
import LabKitMPMTypes
@testable import LabKitMPM

/// Offscreen scene for the surface renderer: an rgba16Float colour target + depth32Float, a mipmapped `behind` texture
/// filled with a flat backdrop colour, and the tank drawn into the middle of the frame.
final class RenderRig {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let renderer: MPMSurfaceRenderer
  let scene, depth, behind: MTLTexture
  let size: SIMD2<Int>
  static let background = SIMD4<Float>(0.1, 0.2, 0.3, 1)

  init(width: Int = 240, height: Int = 400) throws {
    guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    device = d
    queue = d.makeCommandQueue()!
    renderer = try MPMSurfaceRenderer(device: d, colorFormat: .rgba16Float, depthFormat: .depth32Float)
    size = SIMD2(width, height)
    let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
    cd.usage = [.renderTarget, .shaderRead]
    cd.storageMode = .shared
    scene = d.makeTexture(descriptor: cd)!
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
    dd.usage = .renderTarget
    dd.storageMode = .private
    depth = d.makeTexture(descriptor: dd)!
    let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true)
    bd.usage = [.renderTarget, .shaderRead]
    bd.storageMode = .private
    behind = d.makeTexture(descriptor: bd)!
  }

  /// Tank metres → clip: the tank fills 80 % of the frame's width, centred, aspect preserved (orthographic).
  func tankToClip(tank: SIMD2<Double>) -> simd_float4x4 {
    let W = Float(size.x), H = Float(size.y)
    let pxPerM = 0.8 * W / Float(tank.x)
    let sx = 2 * pxPerM / W, sy = 2 * pxPerM / H
    let ox = -Float(tank.x) * pxPerM / W, oy = -Float(tank.y) * pxPerM / H
    return simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, sy, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(ox, oy, 0, 1)))
  }

  /// Renders one frame of `solver`'s current particles; returns RGBA float pixels (row 0 = top).
  func render(_ solver: MPMSolver, options: FluidRenderOptions = FluidRenderOptions()) -> [SIMD4<Float>] {
    let m = tankToClip(tank: solver.domain.size)
    let cmd = queue.makeCommandBuffer()!
    // Behind: flat backdrop colour, mipmapped.
    let bp = MTLRenderPassDescriptor()
    bp.colorAttachments[0].texture = behind
    bp.colorAttachments[0].loadAction = .clear
    bp.colorAttachments[0].clearColor = MTLClearColor(red: Double(Self.background.x), green: Double(Self.background.y),
                                                      blue: Double(Self.background.z), alpha: 1)
    bp.colorAttachments[0].storeAction = .store
    cmd.makeRenderCommandEncoder(descriptor: bp)!.endEncoding()
    let b = cmd.makeBlitCommandEncoder()!
    b.generateMipmaps(for: behind)
    b.endEncoding()
    renderer.encodePrepass(cmd, solver: solver, tankToClip: m, drawableSize: size, options: options)
    let sp = MTLRenderPassDescriptor()
    sp.colorAttachments[0].texture = scene
    sp.colorAttachments[0].loadAction = .clear
    sp.colorAttachments[0].clearColor = bp.colorAttachments[0].clearColor
    sp.colorAttachments[0].storeAction = .store
    sp.depthAttachment.texture = depth
    sp.depthAttachment.loadAction = .clear
    sp.depthAttachment.storeAction = .dontCare
    let e = cmd.makeRenderCommandEncoder(descriptor: sp)!
    renderer.encodeShade(e, behind: behind, tankToClip: m, time: 0, options: options)
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    XCTAssertEqual(cmd.status, .completed, "render failed: \(String(describing: cmd.error))")
    var half = [Float16](repeating: 0, count: size.x * size.y * 4)
    scene.getBytes(&half, bytesPerRow: size.x * 8, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
    return (0..<(size.x * size.y)).map { i in
      SIMD4(Float(half[i * 4]), Float(half[i * 4 + 1]), Float(half[i * 4 + 2]), Float(half[i * 4 + 3]))
    }
  }

  /// The hologram style (Toothpaste Toy): its own prepass, then `encodeHologramShade` over a target cleared to black —
  /// no `behind` texture exists in this path. Returns RGBA float pixels (row 0 = top).
  func renderHologram(_ solver: MPMSolver, options: FluidRenderOptions) -> [SIMD4<Float>] {
    let m = tankToClip(tank: solver.domain.size)
    let cmd = queue.makeCommandBuffer()!
    renderer.encodePrepass(cmd, solver: solver, tankToClip: m, drawableSize: size, options: options)
    let sp = MTLRenderPassDescriptor()
    sp.colorAttachments[0].texture = scene
    sp.colorAttachments[0].loadAction = .clear
    sp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    sp.colorAttachments[0].storeAction = .store
    sp.depthAttachment.texture = depth
    sp.depthAttachment.loadAction = .clear
    sp.depthAttachment.storeAction = .dontCare
    let e = cmd.makeRenderCommandEncoder(descriptor: sp)!
    renderer.encodeHologramShade(e, tankToClip: m, time: options.hologram.time, options: options)
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    XCTAssertEqual(cmd.status, .completed, "render failed: \(String(describing: cmd.error))")
    var half = [Float16](repeating: 0, count: size.x * size.y * 4)
    scene.getBytes(&half, bytesPerRow: size.x * 8, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
    return (0..<(size.x * size.y)).map { i in
      SIMD4(Float(half[i * 4]), Float(half[i * 4 + 1]), Float(half[i * 4 + 2]), Float(half[i * 4 + 3]))
    }
  }

  /// Pixel (column, row from the top) of a tank point in metres.
  func pixel(of p: SIMD2<Double>, tank: SIMD2<Double>) -> SIMD2<Int> {
    let c = tankToClip(tank: tank) * SIMD4<Float>(Float(p.x), Float(p.y), 0, 1)
    return SIMD2(Int((c.x * 0.5 + 0.5) * Float(size.x)), Int((0.5 - c.y * 0.5) * Float(size.y)))
  }
}

final class MPMSurfaceRendererTests: XCTestCase {
  private func pool(material: Int = 0, materials: [ContinuumMaterial] = [ContinuumPresets.waterLike]) throws -> MPMRig {
    let rig = try MPMRig(materials: materials)
    let W = rig.solver.domain.size.x
    rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.04), material: material, temperature: 293.15)
    rig.run(20)
    return rig
  }

  private func distance(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { simd_length(SIMD3(a.x, a.y, a.z) - SIMD3(b.x, b.y, b.z)) }

  func testShadesFluidAndLeavesEmptySpaceAlone() throws {
    let sim = try pool(material: 1, materials: [ContinuumPresets.waterLike, ContinuumPresets.ketchup])
    let r = try RenderRig()
    r.renderer.looks = [FluidLook.waterLike, FluidLook.ketchup]
    let img = r.render(sim.solver)
    let tank = sim.solver.domain.size
    func at(_ p: SIMD2<Double>) -> SIMD4<Float> { let q = r.pixel(of: p, tank: tank); return img[q.y * r.size.x + q.x] }
    XCTAssertTrue(img.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "no NaN/Inf in the scene")
    let inside = at(SIMD2(tank.x / 2, 0.02)), above = at(SIMD2(tank.x / 2, 0.08)), outside = SIMD4<Float>(img[2 * r.size.x + 2])
    print("fluid pixel \(inside), empty tank \(above), outside \(outside)")
    XCTAssertGreaterThan(distance(inside, RenderRig.background), 0.05, "ketchup must change the pixel")
    XCTAssertGreaterThan(inside.x, inside.z, "ketchup reads red")
    XCTAssertLessThan(distance(above, RenderRig.background), 1e-3, "empty part of the tank untouched")
    XCTAssertLessThan(distance(outside, RenderRig.background), 1e-3, "outside the tank untouched")
    XCTAssertGreaterThan(r.renderer.fieldTextureSize.x, 0)
    XCTAssertLessThan(r.renderer.fieldTextureSize.x, r.size.x / 2 + 1, "fields cover the tank rectangle at half resolution")
  }

  func testEveryPresetLookRendersFinite() throws {
    let r = try RenderRig(width: 120, height: 200)
    for (i, entry) in FluidLook.all.enumerated() {
      let sim = try pool(material: 0, materials: [ContinuumPresets.all[i].material])
      sim.solver.debugModifyParticles { $0.temperature = 1450 }       // lava glow path for every look
      r.renderer.looks = [entry.look]
      let img = r.render(sim.solver)
      XCTAssertTrue(img.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x >= 0 }, "\(entry.name): finite, non-negative")
      let q = r.pixel(of: SIMD2(sim.solver.domain.size.x / 2, 0.02), tank: sim.solver.domain.size)
      let p = img[q.y * r.size.x + q.x]
      print(String(format: "%@: (%.3f, %.3f, %.3f)", entry.name, p.x, p.y, p.z))
      if entry.name == "Lava" { XCTAssertGreaterThan(p.x, 1, "lava at 1450 K glows into EDR") }
    }
  }

  func testDiagnosticMapUsesTheColourMap() throws {
    let sim = try pool()
    let r = try RenderRig()
    let img = r.render(sim.solver, options: FluidRenderOptions(diagnostic: .structure))   // λ = 1 -> top of viridis
    let tank = sim.solver.domain.size
    let q = r.pixel(of: SIMD2(tank.x / 2, 0.02), tank: tank)
    let p = img[q.y * r.size.x + q.x]
    // Viridis at 1.0 is yellow (sRGB 253, 231, 37): red and green well above blue.
    print("structure map pixel \(p)")
    XCTAssertGreaterThan(p.x, 3 * p.z)
    XCTAssertGreaterThan(p.y, 3 * p.z)
    let legend = FluidDiagnostic.structure.legend(samples: 2)
    XCTAssertEqual(legend[1].x, 253.0 / 255, accuracy: 1e-9)
    XCTAssertEqual(legend[0].z, 84.0 / 255, accuracy: 1e-9)          // viridis(0) = (68, 1, 84)
  }

  func testOverlaysAndOptions() throws {
    let sim = try pool()
    let r = try RenderRig()
    let plain = r.render(sim.solver)
    let dots = r.render(sim.solver, options: FluidRenderOptions(showParticles: true))
    let flow = r.render(sim.solver, options: FluidRenderOptions(tracers: 0.3, showFlow: true))
    func diff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Int { zip(a, b).filter { simd_length($0 - $1) > 1e-3 }.count }
    XCTAssertGreaterThan(diff(plain, dots), 100, "particle discs drawn")
    XCTAssertGreaterThan(diff(plain, flow), 100, "dye tracers and streaks drawn")
    XCTAssertTrue(dots.allSatisfy { $0.x.isFinite } && flow.allSatisfy { $0.x.isFinite })
  }

  /// The hologram style (FluidRenderStyle.hologram, Toothpaste Toy): light over what the target already holds, drawn
  /// without a `behind` copy; a three-stripe fill (dye bands 1–3 → buckets 0–2) shows each band's own colour; the empty
  /// tank stays dark; the echo ring and the probability cloud leave every pixel finite and non-negative.
  func testHologramDrawsDyeBandsAsLightWithoutBehind() throws {
    let rig = try MPMRig(materials: [ContinuumPresets.toothpaste])
    let W = rig.solver.domain.size.x
    rig.solver.fill(rect: CGRect(x: 0.1 * W, y: 0, width: 0.8 * W, height: 0.04), material: 0, temperature: 293.15, stripes: 3)
    rig.run(10)
    let r = try RenderRig()
    var o = FluidRenderOptions()
    o.style = .hologram
    o.hologram.bandColours = (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
    o.hologram.bandGain = 1
    var img: [SIMD4<Float>] = []
    for f in 0..<4 {                                                         // a few frames: the echo ring fills
      o.hologram.time = Float(f) / 60
      img = r.renderHologram(rig.solver, options: o)
    }
    XCTAssertFalse(r.renderer.fieldTextureSize == .zero)
    XCTAssertTrue(img.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x >= 0 && $0.y >= 0 && $0.z >= 0 },
                  "finite, non-negative light")
    let tank = rig.solver.domain.size
    func at(_ p: SIMD2<Double>) -> SIMD4<Float> { let q = r.pixel(of: p, tank: tank); return img[q.y * r.size.x + q.x] }
    for k in 0..<3 {
      let p = at(SIMD2(0.1 * W + (Double(k) + 0.5) * 0.8 * W / 3, 0.02))
      let c = [p.x, p.y, p.z]
      print("hologram band \(k + 1): \(p)")
      XCTAssertEqual(c.firstIndex(of: c.max()!), k, "band \(k + 1) shows its bucket's colour")
      XCTAssertGreaterThan(c.max()!, 0.02, "band \(k + 1) is lit")
    }
    let above = at(SIMD2(tank.x / 2, 0.08))
    XCTAssertLessThan(simd_length(SIMD3(above.x, above.y, above.z)), 1e-3, "the empty tank stays dark")
  }
}
