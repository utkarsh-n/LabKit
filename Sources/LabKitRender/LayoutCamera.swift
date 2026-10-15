import CoreGraphics
import LabKitCore
import simd

/// "SwiftUI layout drives the Metal camera" (HoloRenderer.swift:431-461): the canvas region's
/// global frame (published with onGeometryChange) sets a focus circle; the camera eases toward it
/// with τ = 0.12 s, so folding the console makes the scene swell with no explicit animation.
public struct LayoutCamera: Sendable {
  public struct Setup: Sendable {
    public var viewProj: simd_float4x4
    public var eye: F4
    public var centerPx: SIMD2<Float>
    public var radiusPx: Float
    public var focal: Float
    public var basis: ViewBasis
    public var reversedDepth: Bool
  }

  /// Camera distance in focus radii (GyroModel.cameraDistance = 3.2).
  public var distance: Float = 3.2
  /// Focus radius as a fraction of min(w, h) of the region (GyroModel.bubbleLayout: 0.44).
  public var radiusFraction: CGFloat = 0.44
  public var tau = 0.12
  private var center = CGPoint.zero
  private var radius: CGFloat = 0
  private var extent = CGSize.zero
  public init() {}

  /// Perspective "phone as a window" camera about the focus (depth 0…1 between 0.5 and 10).
  public mutating func perspective(region: CGRect, viewBounds: CGRect, drawableSize size: CGSize, scale: Float, dt: Double) -> Setup {
    let target: (CGPoint, CGFloat) =
      region.width > 1
      ? (CGPoint(x: region.midX, y: region.midY), min(region.width, region.height) * radiusFraction)
      : (CGPoint(x: viewBounds.midX, y: viewBounds.midY * 0.8), viewBounds.width * 0.42)
    if radius == 0 {
      center = target.0
      radius = target.1
    } else {
      let k = CGFloat(approachFactor(dt: dt, tau: tau))
      center.x += (target.0.x - center.x) * k
      center.y += (target.0.y - center.y) * k
      radius += (target.1 - radius) * k
    }
    let w = Float(size.width), h = Float(size.height)
    let cx = Float(center.x) * scale, cy = Float(center.y) * scale
    let rPx = Float(radius) * scale
    let d = distance
    let f = rPx * (d * d - 1).squareRoot()
    let near: Float = 0.5, far: Float = 10
    let a = far / (far - near), b = far * near / (far - near)
    let ox = 2 * cx / w - 1, oy = 1 - 2 * cy / h
    let viewProj = simd_float4x4(
      F4(2 * f / w, 0, 0, 0),
      F4(0, 2 * f / h, 0, 0),
      F4(-ox, -oy, -a, -1),
      F4(ox * d, oy * d, a * d - b, d))
    return Setup(
      viewProj: viewProj, eye: F4(0, 0, d, 0), centerPx: SIMD2(cx, cy), radiusPx: rPx, focal: f,
      basis: ViewBasis(eye: F3(0, 0, d), widthScale: clamped(Float(radius) / 170, 0.7, 1.5)), reversedDepth: false)
  }

  /// Flat 2D camera: scene units x ∈ [−aspect, aspect], y ∈ [−1, 1] map onto the eased region
  /// (for Rheo's tank). z ∈ [−1, 1] → depth [1, 0].
  public mutating func orthographic(region: CGRect, viewBounds: CGRect, drawableSize size: CGSize, scale: Float, dt: Double) -> Setup {
    let r = region.width > 1 ? region : viewBounds
    let target = (CGPoint(x: r.midX, y: r.midY), r.height / 2)
    if radius == 0 {
      center = target.0
      radius = target.1
    } else {
      let k = CGFloat(approachFactor(dt: dt, tau: tau))
      center.x += (target.0.x - center.x) * k
      center.y += (target.0.y - center.y) * k
      radius += (target.1 - radius) * k
    }
    let w = Float(size.width), h = Float(size.height)
    let cx = Float(center.x) * scale, cy = Float(center.y) * scale
    let rPx = Float(radius) * scale
    let sx = 2 * rPx / w, sy = 2 * rPx / h
    let ox = 2 * cx / w - 1, oy = 1 - 2 * cy / h
    let viewProj = simd_float4x4(F4(sx, 0, 0, 0), F4(0, sy, 0, 0), F4(0, 0, -0.5, 0), F4(ox, oy, 0.5, 1))
    return Setup(
      viewProj: viewProj, eye: F4(0, 0, 10, 0), centerPx: SIMD2(cx, cy), radiusPx: rPx, focal: rPx,
      basis: ViewBasis(eye: F3(0, 0, 10), widthScale: 1), reversedDepth: false)
  }

  /// Flat 2D camera in the app's own units: `world` (x right, y up) maps onto the eased canvas
  /// region (points, y down) per `fit`. z ∈ [−1, 1] → depth [1, 0]. With `.stretch` the world's
  /// corners land exactly on the region's corners (Rheo's life-size tank).
  public mutating func orthographic(
    world: CGRect, fit: LabFit = .stretch, region: CGRect, viewBounds: CGRect, drawableSize size: CGSize, scale: Float,
    dt: Double
  ) -> Setup {
    let r = region.width > 1 && region.height > 1 ? region : viewBounds
    if extent == .zero {
      center = CGPoint(x: r.midX, y: r.midY)
      extent = r.size
    } else {
      let k = CGFloat(approachFactor(dt: dt, tau: tau))
      center.x += (r.midX - center.x) * k
      center.y += (r.midY - center.y) * k
      extent.width += (r.width - extent.width) * k
      extent.height += (r.height - extent.height) * k
    }
    radius = min(extent.width, extent.height) / 2
    let s = CGFloat(scale)
    let regionPx = CGRect(
      x: (center.x - extent.width / 2) * s, y: (center.y - extent.height / 2) * s,
      width: extent.width * s, height: extent.height * s)
    let m = Self.orthographicMatrix(world: world, regionPx: regionPx, drawablePx: size, fit: fit)
    let half = Float(min(regionPx.width, regionPx.height) / 2)
    let eye = F3(Float(world.midX), Float(world.midY), 1000)
    return Setup(
      viewProj: m, eye: F4(eye, 0), centerPx: SIMD2(Float(regionPx.midX), Float(regionPx.midY)), radiusPx: half,
      focal: half, basis: ViewBasis(eye: eye, widthScale: 1), reversedDepth: false)
  }

  /// Where `world` lands inside `rect` for a fit mode (same units as `rect`).
  public static func fittedRect(_ world: CGSize, in rect: CGRect, fit: LabFit) -> CGRect {
    guard world.width > 0, world.height > 0 else { return rect }
    switch fit {
    case .stretch:
      return rect
    case .contain, .cover:
      let sx = rect.width / world.width, sy = rect.height / world.height
      let k = fit == .contain ? min(sx, sy) : max(sx, sy)
      let w = world.width * k, h = world.height * k
      return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
  }

  /// The world → clip matrix for a flat projection: `world` (x right, y up) onto `regionPx` (drawable
  /// pixels, origin top-left, y down) in a drawable of `drawablePx`. Pure, for tests and offscreen use.
  ///   x_px = R.minX + (x − W.minX)·sx,  y_px = R.maxY − (y − W.minY)·sy,  depth = 0.5 − 0.5·z
  public static func orthographicMatrix(world: CGRect, regionPx: CGRect, drawablePx: CGSize, fit: LabFit = .stretch)
    -> simd_float4x4
  {
    let target = fittedRect(world.size, in: regionPx, fit: fit)
    let W = Double(drawablePx.width), H = Double(drawablePx.height)
    guard W > 0, H > 0, world.width > 0, world.height > 0 else { return matrix_identity_float4x4 }
    let sx = Double(target.width / world.width), sy = Double(target.height / world.height)
    let ax = 2 * sx / W
    let bx = 2 * (Double(target.minX) - Double(world.minX) * sx) / W - 1
    let ay = 2 * sy / H
    let by = 1 - 2 * (Double(target.maxY) + Double(world.minY) * sy) / H
    return simd_float4x4(
      F4(Float(ax), 0, 0, 0), F4(0, Float(ay), 0, 0), F4(0, 0, -0.5, 0), F4(Float(bx), Float(by), 0.5, 1))
  }

  /// Clip-space xy → drawable pixels (origin top-left), the inverse of the viewport transform.
  public static func clipToPixels(_ clip: F4, drawablePx: CGSize) -> SIMD2<Double> {
    let x = Double(clip.x / clip.w), y = Double(clip.y / clip.w)
    return SIMD2((x + 1) / 2 * Double(drawablePx.width), (1 - y) / 2 * Double(drawablePx.height))
  }
}
