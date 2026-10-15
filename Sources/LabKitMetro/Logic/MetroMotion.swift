import Foundation
import simd

/// Metro's sensor baseline (spec §13; Metro Station `MotionLighting`): device gravity becomes a bounded screen-space
/// tilt for material response (the lens rim light, refraction, metal light). In portrait, gravity x drives the visual
/// horizontal and gravity z the visual vertical:
///
///     target = clamp(1.7 × (gravity − reference), −1, 1)      filtered += 0.18 × (target − filtered)
///
/// The reference is captured from the first sample after `start()`, so a held tilt keeps its response (no rolling
/// baseline erases it); `stop()` resets the output. Each run has a generation number so a stale queued callback from an
/// earlier run cannot move a restarted stream. The host owns CoreMotion (or LabKitSensors' `MotionSource`), permission,
/// orientation mapping (landscape needs its own axes and a rebase) and the scene lifecycle; this type is pure maths.
nonisolated public struct MetroTiltFilter: Sendable, Equatable {
  public static let gain = Metro.Motion.gravityGain
  public static let lowPassAlpha = Metro.Motion.gravityLowPassAlpha
  public static let sampleRate = Metro.Motion.gravitySampleHz

  /// The filtered screen-space tilt, each axis in −1…1.
  public private(set) var vector: SIMD2<Double> = .zero
  public private(set) var reference: SIMD2<Double>?
  /// Increments on every `start()` and `stop()`.
  public private(set) var generation = 0
  public private(set) var isActive = false

  public init() {}

  /// Begins a run and returns its generation; the next sample becomes the reference.
  @discardableResult
  public mutating func start() -> Int {
    generation &+= 1
    isActive = true
    reference = nil
    vector = .zero
    return generation
  }

  /// Ends the run: output returns to rest.
  public mutating func stop() {
    generation &+= 1
    isActive = false
    reference = nil
    vector = .zero
  }

  /// Re-captures the reference from the next sample (an orientation change); output eases back from where it is.
  public mutating func rebase() { reference = nil }

  /// One gravity sample (device frame, g). `generation` must be the value `start()` returned, or the sample is ignored.
  /// `dt` (seconds since the previous sample) keeps the filter's time constant at any sample rate: at 1/30 s the step
  /// is exactly 0.18. Returns the new vector.
  @discardableResult
  public mutating func update(gravityX: Double, gravityZ: Double, generation sampleGeneration: Int, dt: Double? = nil)
    -> SIMD2<Double>
  {
    guard isActive, sampleGeneration == generation, gravityX.isFinite, gravityZ.isFinite else { return vector }
    let sample = SIMD2(gravityX, gravityZ)
    guard let reference else {
      self.reference = sample
      return vector
    }
    let target = simd_clamp((sample - reference) * Self.gain, SIMD2(repeating: -1), SIMD2(repeating: 1))
    vector += (target - vector) * Self.alpha(dt: dt)
    return vector
  }

  /// The low-pass step for a sample interval: 0.18 at the 30 Hz design rate, 1 − (1 − 0.18)^(30 dt) otherwise.
  public static func alpha(dt: Double?) -> Double {
    guard let dt, dt.isFinite, dt > 0 else { return lowPassAlpha }
    let steps = dt * sampleRate
    if abs(steps - 1) < 1e-12 { return lowPassAlpha }
    return min(1, 1 - pow(1 - lowPassAlpha, steps))
  }
}

/// A clock-synced interior attack/decay for signal pills and event tiles (spec §11; Metro Station `PillTickResponse`,
/// generalised): support min(maximumDuration, 0.8 × the interval to the next event), attack min(preferredAttack,
/// support / 4), smoothstep rise and fall with zero slope at onset, peak and release. A visual cue sampled from the
/// event's real age (no UI timer, no accumulated animation state); it measures neither audio nor actuator intensity.
nonisolated public struct MetroPulseEnvelope: Sendable, Hashable {
  public var maximumDuration: Double
  public var preferredAttack: Double

  /// Metro Station's tuning: 200 ms support, 20 ms attack.
  public static let standard = MetroPulseEnvelope(maximumDuration: 0.200, preferredAttack: 0.020)

  public init(maximumDuration: Double, preferredAttack: Double) {
    self.maximumDuration = maximumDuration.isFinite ? max(0, maximumDuration) : 0
    self.preferredAttack = preferredAttack.isFinite ? max(0, preferredAttack) : 0
  }

  /// The visual support for an event followed by another `interval` seconds later (pass `.infinity` for a lone event).
  public func duration(interval: Double = .infinity) -> Double {
    guard !interval.isNaN, interval > 0 else { return 0 }
    return min(maximumDuration, interval * 0.8)
  }

  public func attack(interval: Double = .infinity) -> Double {
    min(preferredAttack, duration(interval: interval) * 0.25)
  }

  /// 0…1 at `elapsed` seconds after the event; 0 before it, after the support, or for malformed input.
  public func value(elapsed: Double?, interval: Double = .infinity) -> Double {
    guard let elapsed, elapsed.isFinite, elapsed > 0 else { return 0 }
    let support = duration(interval: interval)
    guard support > 0, elapsed < support else { return 0 }
    let attack = attack(interval: interval)
    guard attack > 0 else { return 0 }
    if elapsed <= attack { return Self.smoothstep(elapsed / attack) }
    return 1 - Self.smoothstep((elapsed - attack) / (support - attack))
  }

  static func smoothstep(_ progress: Double) -> Double {
    let t = min(1, max(0, progress))
    return t * t * (3 - 2 * t)
  }
}

/// An optional, domain-driven radius bounce for the isolated lens (spec §13 "Lens bounce"; Metro Station
/// `GlassDialMotion`'s analytic damped curve, re-timed for one event instead of a beat): one outward swell, a compressive
/// overshoot and a small settling rebound over `duration` seconds after the event, scaled by a 0…1 strength. Radius,
/// velocity and acceleration are continuous at both ends; the centre never moves; the result stays inside 0.92…1.09 and
/// rests at exactly 1 before, after, under Reduce Motion and for malformed input.
nonisolated public enum MetroLensPulse {
  /// The dominant outward swell, as a fraction of the duration.
  public static let peakPhase = 0.18039238161291354
  /// The dominant compression.
  public static let compressionPhase = 0.4549894277271932
  /// The full-strength outward excursion (to 1.09).
  public static let maximumExcursion = 0.09
  private static let displacementPeak = 0.5982974279225974

  public static func radiusScale(age: Double, duration: Double, strength: Double = 1, reduceMotion: Bool = false)
    -> Double
  {
    guard !reduceMotion, age.isFinite, duration.isFinite, duration > 0, strength.isFinite else { return 1 }
    let phase = age / duration
    guard phase > 0, phase < 1 else { return 1 }
    let amount = min(1, max(0, strength))
    let scale = 1 + amount * maximumExcursion * displacement(at: phase) / displacementPeak
    return MetroLensRefraction.boundedRadiusScale(scale)
  }

  static func displacement(at phase: Double) -> Double {
    let attack = -expm1(-12 * phase)
    let remaining = 1 - phase
    let release = remaining * remaining * remaining * (1 + 3 * phase + 6 * phase * phase)
    return exp(-1.2 * phase) * attack * attack * release * sin(3 * .pi * phase)
  }
}
