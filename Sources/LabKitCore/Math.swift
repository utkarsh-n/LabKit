import simd

// Lifted from Gyre/Physics/MathUtil.swift (whole file), made public, plus Double overloads.

public typealias V2 = SIMD2<Double>
public typealias V3 = SIMD3<Double>
public typealias F2 = SIMD2<Float>
public typealias F3 = SIMD3<Float>
public typealias F4 = SIMD4<Float>

extension SIMD3 where Scalar == Double {
  @inlinable public var length: Double { simd_length(self) }
  /// Unit vector, or +Z when the vector is too small to have a direction.
  @inlinable public var unit: V3 {
    let l = simd_length(self)
    return l > 1e-12 ? self / l : V3(0, 0, 1)
  }
  @inlinable public var f: F3 { F3(Float(x), Float(y), Float(z)) }
}

extension SIMD3 where Scalar == Float {
  @inlinable public var unit: F3 {
    let l = simd_length(self)
    return l > 1e-7 ? self / l : F3(0, 0, 1)
  }
  @inlinable public var d: V3 { V3(Double(x), Double(y), Double(z)) }
}

extension SIMD2 where Scalar == Double {
  @inlinable public var length: Double { simd_length(self) }
  @inlinable public var f: F2 { F2(Float(x), Float(y)) }
}

extension SIMD2 where Scalar == Float {
  @inlinable public var d: V2 { V2(Double(x), Double(y)) }
}

extension simd_quatd {
  public static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
  @inlinable public var float: simd_quatf {
    simd_quatf(ix: Float(imag.x), iy: Float(imag.y), iz: Float(imag.z), r: Float(real))
  }
}

extension simd_quatf {
  @inlinable public var double: simd_quatd {
    simd_quatd(ix: Double(imag.x), iy: Double(imag.y), iz: Double(imag.z), r: Double(real))
  }
}

@inlinable public func clamped<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

@inlinable public func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
  let t = clamped((x - e0) / (e1 - e0), 0, 1)
  return t * t * (3 - 2 * t)
}

@inlinable public func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
  let t = clamped((x - e0) / (e1 - e0), 0, 1)
  return t * t * (3 - 2 * t)
}

/// Linear interpolation a + (b − a)·t (unclamped).
@inlinable public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// Maps x from one range onto another, linearly and unclamped.
@inlinable public func remap(_ x: Double, from a: ClosedRange<Double>, to b: ClosedRange<Double>) -> Double {
  let span = a.upperBound - a.lowerBound
  let t = span == 0 ? 0 : (x - a.lowerBound) / span
  return b.lowerBound + (b.upperBound - b.lowerBound) * t
}

/// Any unit vector perpendicular to `v`.
@inlinable public func perpendicular(to v: V3) -> V3 {
  let helper = abs(v.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0)
  return simd_normalize(simd_cross(v, helper))
}

/// Wraps an angle into (-π, π].
@inlinable public func wrapAngle(_ a: Double) -> Double {
  var x = a.truncatingRemainder(dividingBy: 2 * .pi)
  if x > .pi { x -= 2 * .pi }
  if x <= -.pi { x += 2 * .pi }
  return x
}

// From Gyre/Render/GyroMeshes.swift:264-278.
extension simd_float4x4 {
  public init(translation t: F3) {
    self = matrix_identity_float4x4
    columns.3 = F4(t, 1)
  }

  public init(scale s: F3) {
    self = simd_float4x4(diagonal: F4(s, 1))
  }

  /// Columns are the given axes, then a translation.
  public init(basis x: F3, _ y: F3, _ z: F3, origin: F3) {
    self.init(F4(x, 0), F4(y, 0), F4(z, 0), F4(origin, 1))
  }
}

/// Deterministic xorshift32 (Gyre: BubbleWorld.swift:24-29, HumSynth.swift:107-110, MicListener.swift:199-201).
public struct XorShift32: Sendable {
  public var state: UInt32
  public init(seed: UInt32 = 0x9E37_79B9) { state = seed == 0 ? 1 : seed }
  @inlinable public mutating func next() -> UInt32 {
    state ^= state << 13
    state ^= state >> 17
    state ^= state << 5
    return state
  }
  /// 0…1
  @inlinable public mutating func unit() -> Float { Float(next()) / Float(UInt32.max) }
  /// −1…1 white noise sample.
  @inlinable public mutating func bipolar() -> Double { Double(next()) / Double(UInt32.max) * 2 - 1 }
}
