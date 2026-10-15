import Foundation

// MARK: Exponential approach — the one easing law Gyre uses everywhere:
//   x += (target − x)·(1 − e^(−dt/τ))
// GyroModel.swift:374 (τ 0.22 centre blend), :411 (0.08 turbulence), :469/:472 (envelope),
// GyroSim.swift:107-109 (0.25 balance, 0.3 inertia, 0.9 air), :160 (0.6 precession),
// HoloRenderer.swift:439 (0.12 layout camera), ARController.swift:246 (0.09 AR glide).

@inlinable public func approachFactor(dt: Double, tau: Double) -> Double {
  tau <= 0 ? 1 : 1 - exp(-dt / tau)
}

@inlinable public func approach(_ x: inout Double, _ target: Double, dt: Double, tau: Double) {
  x += (target - x) * approachFactor(dt: dt, tau: tau)
}

@inlinable public func approach<V: SIMD>(_ x: inout V, _ target: V, dt: Double, tau: Double) where V.Scalar == Double {
  x += (target - x) * approachFactor(dt: dt, tau: tau)
}

/// One-pole follower with separate rise and fall time constants (seconds).
public struct AttackRelease: Sendable, Equatable {
  public var attack: Double
  public var release: Double
  public private(set) var value: Double = 0
  public init(attack: Double, release: Double, value: Double = 0) {
    self.attack = attack
    self.release = release
    self.value = value
  }
  @discardableResult
  public mutating func step(_ target: Double, dt: Double) -> Double {
    approach(&value, target, dt: dt, tau: target > value ? attack : release)
    return value
  }
  public mutating func reset(_ v: Double = 0) { value = v }
}

/// "At most every `interval` seconds" gate on a clock (Gyre: telemetry 0.1 s GyroModel.swift:442,
/// haptic parameters 1/40 s Haptics.swift:84, trail 1/60 s GyroModel.swift:434, spectrum history
/// 0.05 s GyroModel.swift:525, BLE rate 0.5 s RadioSense.swift:77).
public struct Throttle: Sendable {
  public var interval: Double
  public private(set) var last: Double = -.infinity
  public init(interval: Double) { self.interval = interval }
  public init(hz: Double) { self.interval = 1 / hz }
  /// True (and re-arms) when `interval` has elapsed since the last true.
  public mutating func ready(at now: Double) -> Bool {
    guard now - last >= interval else { return false }
    last = now
    return true
  }
}

/// Converts display-link timestamps to a safe frame dt (HoloRenderer.swift:263-265):
/// first frame 1/120 s, then min(now − last, 1/15 s) so a hitch never explodes the physics.
public struct FrameClock: Sendable {
  public static let firstFrame = 1.0 / 120
  public static let maxFrame = 1.0 / 15
  public private(set) var last: Double = 0
  public private(set) var elapsed: Double = 0
  public init() {}
  public mutating func tick(now: Double) -> Double {
    let dt = last == 0 ? Self.firstFrame : min(now - last, Self.maxFrame)
    last = now
    elapsed += dt
    return dt
  }
  public mutating func reset() { last = 0 }
}

/// Simulation time vs. real time: Time knob (0.05…2×, log) and pause (GyroSim.swift:113,130; GyroModel.swift:421).
public struct SimClock: Sendable {
  public var timeScale: Double = 1
  public var paused = false
  public private(set) var simTime: Double = 0
  public private(set) var realTime: Double = 0
  public init() {}
  /// Returns the simulated dt for a real dt, advancing both clocks.
  public mutating func advance(real dt: Double) -> Double {
    realTime += dt
    let s = paused ? 0 : dt * max(timeScale, 0.02)
    simTime += s
    return s
  }
}

/// Fixed-step accumulator for solvers that want a constant step (e.g. Box2D at 120 Hz while the
/// display runs at 60 or 120). Each frame `steps(for:)` says how many steps of `h` to take and keeps
/// the remainder; anything beyond `maxSteps` is dropped (counted in `dropped`) so a hitch cannot
/// snowball into a spiral of ever-longer frames.
public struct FixedStep: Sendable {
  /// Step length, seconds.
  public var h: Double
  public var maxSteps: Int
  public private(set) var accumulator = 0.0
  /// Simulated seconds discarded because a frame needed more than `maxSteps` steps.
  public private(set) var dropped = 0.0

  public init(hz: Double, maxSteps: Int = 8) {
    h = 1 / hz
    self.maxSteps = max(1, maxSteps)
  }

  /// Number of whole steps to run for this frame's (simulated) dt.
  public mutating func steps(for dt: Double) -> Int {
    guard dt > 0, h > 0 else { return 0 }
    accumulator += dt
    var n = Int((accumulator / h + 1e-9).rounded(.down))
    if n > maxSteps {
      dropped += Double(n - maxSteps) * h
      accumulator -= Double(n - maxSteps) * h
      n = maxSteps
    }
    accumulator = max(0, accumulator - Double(n) * h)
    return n
  }

  /// How far the leftover time reaches into the next step, 0…1 (for interpolating poses).
  public var alpha: Double { h > 0 ? clamped(accumulator / h, 0, 1) : 0 }

  public mutating func reset() {
    accumulator = 0
    dropped = 0
  }
}
