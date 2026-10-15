import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers
import LabKitCore
import LabKitMPM

// Surface renderer checks: GPU time at the iPhone 15 Pro Max drawable size and a PNG contact sheet of every look.

/// Backdrop (slate gradient with grid lines, as the sibling's offline check) and an SDR composite (Gyre soft clip at
/// headroom 1, sRGB OETF), compiled at run time: the harness has no Metal resources of its own.
private let helperSource = """
#include <metal_stdlib>
using namespace metal;
struct FSOut { float4 position [[position]]; float2 uv; };
vertex FSOut gcFullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o; o.position = float4(p * 2.0f - 1.0f, 0, 1); o.uv = float2(p.x, 1.0f - p.y); return o;
}
fragment float4 gcBackdrop(FSOut in [[stage_in]], constant float2& sizePx [[buffer(0)]]) {
    float2 px = in.uv * sizePx;
    float g = 0.10f + 0.06f * (1.0f - in.uv.y);
    float2 a = abs(fract(px / 16.0f) - 0.5f), b = abs(fract(px / 80.0f) - 0.5f);
    float lines = max(step(0.44f, max(a.x, a.y)) * 0.06f, step(0.48f, max(b.x, b.y)) * 0.22f);
    return float4(float3(g * 0.9f, g, g * 1.15f) + lines * float3(0.55f, 0.75f, 0.85f), 1);
}
static inline float softClip(float x) { float k = 0.8f, h = 1.0f; return x <= k ? x : k + (h - k) * (1.0f - exp(-(x - k) / (h - k))); }
fragment float4 gcComposite(FSOut in [[stage_in]], texture2d<half> scene [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = float3(scene.sample(s, in.uv).rgb);
    c = saturate(float3(softClip(c.r), softClip(c.g), softClip(c.b)));
    float3 o = select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, 12.92f * c, c <= 0.0031308f);
    return float4(o, 1);
}
"""

final class RenderBench {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let renderer: MPMSurfaceRenderer
  let backdrop, composite: MTLRenderPipelineState

  init(device: MTLDevice) throws {
    self.device = device
    queue = device.makeCommandQueue()!
    renderer = try MPMSurfaceRenderer(device: device)
    let lib = try device.makeLibrary(source: helperSource, options: nil)
    func rp(_ f: String, _ fmt: MTLPixelFormat) throws -> MTLRenderPipelineState {
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = lib.makeFunction(name: "gcFullscreen")
      d.fragmentFunction = lib.makeFunction(name: f)
      d.colorAttachments[0].pixelFormat = fmt
      return try device.makeRenderPipelineState(descriptor: d)
    }
    backdrop = try rp("gcBackdrop", .rgba16Float)
    composite = try rp("gcComposite", .rgba8Unorm)
  }

  func texture(_ w: Int, _ h: Int, _ f: MTLPixelFormat, mips: Bool = false, shared: Bool = false) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: mips)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = shared ? .shared : .private
    return device.makeTexture(descriptor: d)!
  }

  struct Targets { let scene, depth, behind: MTLTexture; let size: SIMD2<Int> }
  func targets(_ w: Int, _ h: Int) -> Targets {
    Targets(scene: texture(w, h, .rgba16Float), depth: texture(w, h, .depth32Float), behind: texture(w, h, .rgba16Float, mips: true),
            size: SIMD2(w, h))
  }

  func encodeBehind(_ cmd: MTLCommandBuffer, _ t: Targets) {
    let p = MTLRenderPassDescriptor()
    p.colorAttachments[0].texture = t.behind
    p.colorAttachments[0].loadAction = .dontCare
    p.colorAttachments[0].storeAction = .store
    let e = cmd.makeRenderCommandEncoder(descriptor: p)!
    var s = SIMD2<Float>(Float(t.size.x), Float(t.size.y))
    e.setRenderPipelineState(backdrop)
    e.setFragmentBytes(&s, length: 8, index: 0)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    e.endEncoding()
    let b = cmd.makeBlitCommandEncoder()!
    b.generateMipmaps(for: t.behind)
    b.endEncoding()
  }

  /// Scene pass 2 as LabKitRender does it: copy of `behind` as the background, then the fluid shade.
  func encodeScene(_ cmd: MTLCommandBuffer, _ t: Targets, tankToClip: simd_float4x4, options: FluidRenderOptions) {
    let b = cmd.makeBlitCommandEncoder()!
    b.copy(from: t.behind, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
           sourceSize: MTLSize(width: t.size.x, height: t.size.y, depth: 1), to: t.scene, destinationSlice: 0, destinationLevel: 0,
           destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    b.endEncoding()
    let p = MTLRenderPassDescriptor()
    p.colorAttachments[0].texture = t.scene
    p.colorAttachments[0].loadAction = .load
    p.colorAttachments[0].storeAction = .store
    p.depthAttachment.texture = t.depth
    p.depthAttachment.loadAction = .clear
    p.depthAttachment.storeAction = .dontCare
    let e = cmd.makeRenderCommandEncoder(descriptor: p)!
    renderer.encodeShade(e, behind: t.behind, tankToClip: tankToClip, time: 0, options: options)
    e.endEncoding()
  }

  /// Orthographic tank → clip with the tank at `rect` (pixels, y down) inside a drawable of `size`.
  static func tankToClip(tank: SIMD2<Double>, rect: CGRect, size: SIMD2<Int>) -> simd_float4x4 {
    let W = Float(size.x), H = Float(size.y)
    let sx = Float(rect.width) / Float(tank.x) * 2 / W, sy = Float(rect.height) / Float(tank.y) * 2 / H
    let ox = Float(rect.minX) * 2 / W - 1, oy = 1 - Float(rect.maxY) * 2 / H
    return simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, sy, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(ox, oy, 0, 1)))
  }
}

func checkRenderTiming(_ device: MTLDevice, _ report: Report) throws {
  print("\n== R1 Surface renderer GPU time at the iPhone 15 Pro Max drawable (1290 × 2796; life-size tank 1290 × 1837 px) ==")
  print("| Δx | particles | field textures (half res) | prepass ms median (p90) | shade ms median (p90) |")
  print("|---|---|---|---|---|")
  let bench = try RenderBench(device: device)
  let size = SIMD2(1290, 2796)
  let t = bench.targets(size.x, size.y)
  var detail: [String] = []
  for (name, q) in [("2.0 mm", MPMQuality.standard), ("1.1 mm", MPMQuality.bench)] {
    let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01), quality: q, materials: [ContinuumPresets.ketchup])
    let tank = rig.solver.domain.size
    rig.solver.fill(rect: CGRect(x: 0, y: 0, width: 0.044, height: 0.066), material: 0, temperature: 293.15)
    let st = rig.run(36)                                              // t = 0.3 s: a splashing shape
    let h = Double(size.x) * tank.y / tank.x
    let m = RenderBench.tankToClip(tank: tank, rect: CGRect(x: 0, y: (Double(size.y) - h) / 2, width: Double(size.x), height: h), size: size)
    var pre: [Double] = [], shade: [Double] = []
    for _ in 0..<40 {
      let c1 = bench.queue.makeCommandBuffer()!
      bench.renderer.encodePrepass(c1, solver: rig.solver, tankToClip: m, drawableSize: size, options: FluidRenderOptions())
      c1.commit()
      let c0 = bench.queue.makeCommandBuffer()!
      bench.encodeBehind(c0, t)
      c0.commit()
      let c2 = bench.queue.makeCommandBuffer()!
      bench.encodeScene(c2, t, tankToClip: m, options: FluidRenderOptions())
      c2.commit()
      c2.waitUntilCompleted()
      pre.append((c1.gpuEndTime - c1.gpuStartTime) * 1000)
      shade.append((c2.gpuEndTime - c2.gpuStartTime) * 1000)
    }
    pre.sort(); shade.sort()
    let f = bench.renderer.fieldTextureSize
    print("| \(name) | \(st.liveParticles) | \(f.x) × \(f.y) | \(fmt(pre[20], 3)) (\(fmt(pre[36], 3))) | \(fmt(shade[20], 3)) (\(fmt(shade[36], 3))) |")
    detail.append("\(name) \(st.liveParticles) particles: prepass \(fmt(pre[20], 2)) ms + shade \(fmt(shade[20], 2)) ms")
  }
  report.add("R1", "renderer GPU time at 1290 × 2796 (M1 Max)", pass: nil, detail.joined(separator: "; "))
}

/// Contact sheet: the 13 looks on a ketchup-shaped dam break at t = 0.3 s, then diagnostics and overlays.
func writeContactSheet(_ device: MTLDevice, path: String, _ report: Report) throws {
  print("\n== R2 Contact sheet → \(path) ==")
  let bench = try RenderBench(device: device)
  let pw = 240, ph = 342
  let panels: [(String, Int?, FluidRenderOptions)] = FluidLook.all.indices.map { (FluidLook.all[$0].name, $0, FluidRenderOptions()) } + [
    ("Shear rate", 2, FluidRenderOptions(diagnostic: .shearRate)),
    ("Stress", 2, FluidRenderOptions(diagnostic: .stress)),
    ("Speed + flow", 0, FluidRenderOptions(diagnostic: .speed, showFlow: true)),
    ("Tracers + particles", 0, FluidRenderOptions(tracers: 0.25, showParticles: true)),
  ]
  let cols = 6, rows = (panels.count + cols - 1) / cols
  let sheet = bench.texture(pw * cols, ph * rows, .rgba8Unorm, shared: true)
  let t = bench.targets(pw, ph)
  let out = bench.texture(pw, ph, .rgba8Unorm)
  // One simulation per material (each look on its own physics), snapshot at t = 0.3 s.
  var sims: [Int: Rig] = [:]
  for (i, p) in panels.enumerated() {
    guard let mi = p.1 else { continue }
    let rig: Rig
    if let r = sims[mi] { rig = r } else {
      let m = ContinuumPresets.all[mi].material
      rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01), quality: .standard, materials: [m])
      rig.solver.fill(rect: CGRect(x: 0, y: 0, width: 0.044, height: 0.066), material: 0, temperature: m.referenceTemperature)
      rig.run(36)
      if ContinuumPresets.all[mi].name == "Lava" {                   // hot core, cooler skin
        rig.solver.debugModifyParticles { p in p.temperature = Float(1450 - 2.5 * max(0, Double(p.position.y) - 12)) }
      }
      sims[mi] = rig
    }
    bench.renderer.looks = [FluidLook.all[mi].look]
    let tank = rig.solver.domain.size
    let m = RenderBench.tankToClip(tank: tank, rect: CGRect(x: 0, y: 0, width: pw, height: ph), size: SIMD2(pw, ph))
    let cmd = bench.queue.makeCommandBuffer()!
    bench.encodeBehind(cmd, t)
    bench.renderer.encodePrepass(cmd, solver: rig.solver, tankToClip: m, drawableSize: SIMD2(pw, ph), options: p.2)
    bench.encodeScene(cmd, t, tankToClip: m, options: p.2)
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = out
    rp.colorAttachments[0].loadAction = .dontCare
    rp.colorAttachments[0].storeAction = .store
    let e = cmd.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(bench.composite)
    e.setFragmentTexture(t.scene, index: 0)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    e.endEncoding()
    let b = cmd.makeBlitCommandEncoder()!
    b.copy(from: out, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: pw, height: ph, depth: 1),
           to: sheet, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: (i % cols) * pw, y: (i / cols) * ph, z: 0))
    b.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    if let err = cmd.error { print("  render error: \(err)") }
  }
  let w = sheet.width, h = sheet.height
  var bytes = [UInt8](repeating: 0, count: w * h * 4)
  sheet.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
  let ok: Bool = bytes.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dst, img, nil)
    return CGImageDestinationFinalize(dst)
  }
  report.add("R2", "contact sheet written", pass: ok ? nil : false,
             "\(path) (\(panels.count) panels: \(panels.map(\.0).joined(separator: ", ")))")
}
