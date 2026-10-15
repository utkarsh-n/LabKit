import simd

/// A state that RK4 can combine linearly.
public protocol IntegrableState {
  static func + (lhs: Self, rhs: Self) -> Self
  static func * (lhs: Double, rhs: Self) -> Self
}

extension Double: IntegrableState {}
extension SIMD2: IntegrableState where Scalar == Double {}
extension SIMD3: IntegrableState where Scalar == Double {}
extension SIMD4: IntegrableState where Scalar == Double {}

public enum RK4 {
  /// Classic fourth-order Runge–Kutta. `project` re-imposes constraints on intermediate states
  /// (GyroSim.rk4 normalises the spin axis at every stage, GyroSim.swift:198-207).
  @inlinable
  public static func step<S: IntegrableState>(
    _ y: S, h: Double, project: (S) -> S = { $0 }, _ f: (S) -> S
  ) -> S {
    let k1 = f(y)
    let k2 = f(project(y + (0.5 * h) * k1))
    let k3 = f(project(y + (0.5 * h) * k2))
    let k4 = f(project(y + h * k3))
    return project(y + (h / 6) * (k1 + 2 * k2 + 2 * k3 + k4))
  }
}

/// Gyre's adaptive substep rule (GyroSim.swift:132-141): enough steps that the fastest motion
/// present advances at most `phasePerStep` radians per step: n = clamp(⌈dt·ω_max/0.1⌉, 1, 2000).
@inlinable
public func substepCount(dt: Double, fastestRate: Double, phasePerStep: Double = 0.1, cap: Int = 2000) -> Int {
  guard dt > 0, fastestRate.isFinite else { return 1 }
  return Int(clamped((dt * fastestRate / phasePerStep).rounded(.up), 1, Double(cap)))
}

/// Semi-implicit (symplectic) Euler for particle systems (BubbleWorld.swift:63-64: v += a·dt; p += v·dt).
@inlinable
public func symplecticEuler(_ p: inout F3, _ v: inout F3, acceleration a: F3, dt: Float) {
  v += a * dt
  p += v * dt
}

/// Semi-implicit Euler for any floating-point SIMD vector (2D tank props, Double particles).
@inlinable
public func symplecticEuler<V: SIMD>(_ p: inout V, _ v: inout V, acceleration a: V, dt: V.Scalar)
where V.Scalar: FloatingPoint {
  v += a * dt
  p += v * dt
}

/// Damped spring driven by acceleration: Gyre's bubble wobble (BubbleWorld.swift:92-110).
/// Defaults verbatim: f = 3.2 Hz, ζ = 0.14, drive gain 14, |d| ≤ 0.07, ×0.9 decay when disabled.
public struct DampedSpring: Sendable {
  public var d = F3.zero
  public var v = F3.zero
  public var frequency: Float = 3.2
  public var damping: Float = 0.14
  public var driveGain: Float = 14
  public var limit: Float = 0.07
  public init() {}

  public mutating func step(dt: Float, accel: F3, enabled: Bool) {
    guard dt > 0 else { return }
    let w = 2 * Float.pi * frequency
    let drive = enabled ? accel * driveGain : .zero
    let a = -w * w * d - 2 * damping * w * v + drive
    v += a * dt
    d += v * dt
    let m = simd_length(d)
    if m > limit { d *= limit / m }
    if !enabled { d *= 0.9 }
  }

  public mutating func kick(_ impulse: F3) { v += impulse }
}

/// Fixed-capacity ring, oldest-first iteration (TrailBuffer, BubbleWorld.swift:113-133).
public struct RingBuffer<Element>: Sendable where Element: Sendable {
  public private(set) var storage: [Element]
  private var head = 0
  public private(set) var count = 0
  public init(capacity: Int, fill: Element) { storage = Array(repeating: fill, count: capacity) }
  public var capacity: Int { storage.count }

  public mutating func append(_ e: Element) {
    storage[head] = e
    head = (head + 1) % storage.count
    count = min(count + 1, storage.count)
  }

  public mutating func clear() { count = 0 }

  public var isEmpty: Bool { count == 0 }
  public var isFull: Bool { count == storage.count }

  /// The newest element, if any.
  public var last: Element? { count == 0 ? nil : storage[(head - 1 + storage.count) % storage.count] }

  /// Oldest first.
  public var elements: [Element] {
    var out: [Element] = []
    out.reserveCapacity(count)
    forEach { _, e in out.append(e) }
    return out
  }

  public func forEach(_ body: (Int, Element) -> Void) {
    let start = (head - count + storage.count) % storage.count
    for i in 0..<count { body(i, storage[(start + i) % storage.count]) }
  }
}
