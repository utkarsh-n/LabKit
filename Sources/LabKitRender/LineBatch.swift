import LabKitCore
import LabKitShaderTypes
import Metal
import simd

extension LabColor {
  public var f3: F3 { F3(Float(r), Float(g), Float(b)) }
}

/// Where the viewer is in the scene frame: toward-eye direction, a screen-aligned right/up pair,
/// and how thick lines should be at this distance (HoloScene.swift:76-84).
public struct ViewBasis: Sendable {
  public var eye = F3(0, 0, 3.2)
  public var toEye = F3(0, 0, 1)
  public var right = F3(1, 0, 0)
  public var up = F3(0, 1, 0)
  public var widthScale: Float = 1
  public init() {}
  public init(eye: F3, toEye: F3 = F3(0, 0, 1), right: F3 = F3(1, 0, 0), up: F3 = F3(0, 1, 0), widthScale: Float) {
    self.eye = eye
    self.toEye = toEye
    self.right = right
    self.up = up
    self.widthScale = widthScale
  }
}

/// CPU builder for one frame of glowing segments (HoloSceneBuilder primitives, HoloScene.swift:88-271).
/// Depth cue, scan band and flicker are baked into the instance colours.
public struct LineBatch {
  public private(set) var lines: [LabLineInstance] = []
  /// Device pixels per point (view.contentScaleFactor).
  public var pxScale: Float = 3
  public private(set) var bandY: Float = 9
  public private(set) var flicker: Float = 1
  public var view = ViewBasis()
  /// Turn off the depth/scan cue for flat 2D overlays.
  public var cueEnabled = true

  public init(capacity: Int = 4096) { lines.reserveCapacity(capacity) }

  /// Starts a frame. Scan band sweeps every 4.2 s over y ∈ [−1.4, 1.4]; flicker
  /// 1 + 0.025·sin(47t)·sin(13.3t). Reduce Motion: band parked at y = 9, flicker 1 (HoloScene.swift:431-432).
  public mutating func begin(view: ViewBasis, time t: Float, reduceMotion: Bool) {
    lines.removeAll(keepingCapacity: true)
    self.view = view
    bandY = reduceMotion ? 9 : -1.4 + 2.8 * (t / 4.2 - floor(t / 4.2))
    flicker = reduceMotion ? 1 : 1 + 0.025 * sin(t * 47) * sin(t * 13.3)
  }

  /// 0.72·(0.35 + 0.65·smoothstep(−1.1, 1, p·toEye))·(1 + 0.9·e^(−((y − band)/0.07)²))·flicker.
  public func cue(_ p: F3) -> Float {
    guard cueEnabled else { return 1 }
    let depth = 0.35 + 0.65 * smoothstep(-1.1, 1.0, simd_dot(p, view.toEye))
    let d = (p.y - bandY) / 0.07
    return 0.72 * depth * (1 + 0.9 * exp(-d * d)) * flicker
  }

  /// w·pxScale·widthScale·(0.75 + 0.25·smoothstep(−1, 1, p·toEye)): nearer is thicker.
  public func width(_ w: Float, _ p: F3) -> Float {
    w * pxScale * view.widthScale * (cueEnabled ? 0.75 + 0.25 * smoothstep(-1, 1, simd_dot(p, view.toEye)) : 1)
  }

  public mutating func seg(_ a: F3, _ b: F3, _ ca: F3, _ cb: F3, alpha: Float = 1, alphaB: Float? = nil, width w: Float) {
    lines.append(
      LabLineInstance(
        a: F4(a, width(w, a)), b: F4(b, width(w, b)),
        ca: F4(ca * cue(a), alpha), cb: F4(cb * cue(b), alphaB ?? alpha)))
  }

  /// A zero-length segment renders as a round dot.
  public mutating func point(_ p: F3, _ color: F3, size: Float, alpha: Float = 1) {
    seg(p, p, color, color, alpha: alpha, width: size)
  }

  public mutating func polyline(_ points: [F3], color: (Int) -> F3, alpha: (Int) -> Float = { _ in 1 }, width: Float) {
    guard points.count > 1 else { return }
    for i in 1..<points.count {
      seg(points[i - 1], points[i], color(i - 1), color(i), alpha: alpha(i - 1), alphaB: alpha(i), width: width)
    }
  }

  /// An axis-aligned rectangle outline in the z = `z` plane (flat 2D overlays: a tank outline, a probe box).
  public mutating func rect(
    _ minimum: F2, _ maximum: F2, z: Float = 0, color: F3, width: Float, alpha: Float = 1, dashed: Bool = false
  ) {
    let corners = [
      F3(minimum.x, minimum.y, z), F3(maximum.x, minimum.y, z), F3(maximum.x, maximum.y, z), F3(minimum.x, maximum.y, z),
    ]
    for i in 0..<4 where !dashed || i % 2 == 0 {
      seg(corners[i], corners[(i + 1) % 4], color, color, alpha: alpha, width: width)
    }
  }

  /// A circle or arc of `radius` in the plane of unit vectors u, v.
  public mutating func ring(
    _ center: F3, _ u: F3, _ v: F3, radius: Float, color: F3, width: Float, alpha: Float = 1,
    segments: Int = 64, start: Float = 0, sweep: Float = 2 * .pi, dashed: Bool = false
  ) {
    let n = max(2, Int(Float(segments) * min(abs(sweep), 2 * .pi) / (2 * .pi)) + 1)
    var prev = center + radius * (cos(start) * u + sin(start) * v)
    for i in 1...n {
      let t = start + sweep * Float(i) / Float(n)
      let p = center + radius * (cos(t) * u + sin(t) * v)
      if !dashed || i % 2 == 0 { seg(prev, p, color, color, alpha: alpha, width: width) }
      prev = p
    }
  }

  /// Shaft from 55% colour to full, plus two head strokes facing the viewer; head = min(0.07, 0.35·len).
  public mutating func arrow(from a: F3, to b: F3, color: F3, width w: Float, alpha: Float = 1) {
    let d = b - a
    let len = simd_length(d)
    guard len > 1e-4 else { return }
    let dir = d / len
    seg(a, b, color * 0.55, color, alpha: alpha, width: w)
    var side = simd_cross(dir, view.toEye)
    if simd_length(side) < 0.2 { side = simd_cross(dir, view.up) }
    side = side.unit
    let head = min(0.07, len * 0.35)
    seg(b, b - dir * head + side * head * 0.55, color, color, alpha: alpha, width: w)
    seg(b, b - dir * head - side * head * 0.55, color, color, alpha: alpha, width: w)
  }

  /// Fades a point that drifts outside the unit focus or toward the eye (HoloScene.swift:253-255).
  public func surroundFade(_ p: F3, from inner: Float = 1.05, to outer: Float = 2.3) -> Float {
    (1 - smoothstep(inner, outer, simd_length(p))) * smoothstep(1.0, 2.0, simd_distance(p, view.eye))
  }

  /// A circle facing the viewer, radius as a function of angle (HoloScene.swift:258-271).
  public mutating func billboard(
    _ center: F3, radius: (Float) -> Float, color: F3, alpha: Float, width: Float, segments: Int = 72, fade: Bool = false
  ) {
    var prev: F3?
    for i in 0...segments {
      let a = Float(i) / Float(segments) * 2 * .pi
      let p = center + (view.right * cos(a) + view.up * sin(a)) * radius(a)
      if let q = prev {
        let f = fade ? surroundFade(p) : 1
        if alpha * f > 0.01 { seg(q, p, color, color, alpha: alpha * f, width: width) }
      }
      prev = p
    }
  }
}

/// Triple-buffered instance upload + instanced draw (HoloRenderer.swift:295-314, 505-514).
public final class LineRenderer {
  private var buffers: [MTLBuffer?] = [nil, nil, nil]
  private let device: MTLDevice
  public let pipeline: MTLRenderPipelineState
  public private(set) var current: MTLBuffer?

  public init(device: MTLDevice, factory: PipelineFactory) throws {
    self.device = device
    pipeline = try factory.make(vertex: "labLineVertex", fragment: "labLineFragment", blend: .add, depth: true)
  }

  /// Copies this frame's instances into slot `frame` (0…2), growing to 2× when short.
  public func upload(_ batch: LineBatch, frame: Int) {
    let needed = max(batch.lines.count, 1) * MemoryLayout<LabLineInstance>.stride
    if (buffers[frame]?.length ?? 0) < needed {
      buffers[frame] = device.makeBuffer(length: needed * 2, options: .storageModeShared)
    }
    guard let b = buffers[frame] else { return }
    batch.lines.withUnsafeBytes { raw in
      if let base = raw.baseAddress { b.contents().copyMemory(from: base, byteCount: raw.count) }
    }
    current = b
  }

  /// Additive, depth-tested (no write), 4-vertex strips, `baseInstance` for sub-ranges.
  public func draw(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, range: Range<Int>) {
    guard let b = current, !range.isEmpty else { return }
    enc.setCullMode(.none)
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(b, offset: 0, index: Int(LabBufferInstances.rawValue))
    enc.setVertexBytes(&uniforms, length: MemoryLayout<LabFrameUniforms>.stride, index: Int(LabBufferFrame.rawValue))
    enc.drawPrimitives(
      type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count, baseInstance: range.lowerBound)
  }
}
