import Foundation

// The pure, testable half of LabKit's haptic "Feel" channel (`labkit-from-orbitals-spectra.md` §5).
// LabKitFeedback's `HapticEngine` runs these on the device; the Mac harness and XCTest run them here.

/// When the continuous hum may play (§5.2).
public enum HumPolicy: Sendable, Equatable {
  /// Plays only while `noteCause()` was called within the last `maxIdle` seconds (default 8 s);
  /// otherwise the target is 0 and the hum fades out. There is never a hum without a visible cause.
  case causal(maxIdle: Double)
  /// Plays whenever the simulation asks (Gyre's spinning rotor in the hand).
  case ambient

  /// `.causal(maxIdle: 8)`.
  public static let standard = HumPolicy.causal(maxIdle: 8)
}

/// What the simulation would like the hum to feel like this frame, before strength and policy.
public struct HumWish: Sendable, Equatable {
  public var intensity: Double
  public var sharpness: Double
  public init(intensity: Double, sharpness: Double) {
    self.intensity = intensity
    self.sharpness = sharpness
  }
  public static let silent = HumWish(intensity: 0, sharpness: 0.5)
}

/// The hum's level law: causal idle, a first-order lag, and the stop threshold.
///   level += (target − level)·(1 − e^(−dt/τ)), τ = 0.25 s; below 0.02 the hum stops,
/// so a full-level hum fades out in 0.25·ln 50 ≈ 0.98 s once its cause has been gone for 8 s.
/// (The 0.25 s lag and the 8 s idle are LabKit proposals, not Gyre values: tune them on the device.)
public struct HumGovernor: Sendable {
  /// Gyre's stop threshold (`Haptics.swift:55-91`).
  public static let stopLevel = 0.02
  /// Core Haptics parameter sends per second at most (Gyre).
  public static let sendRate = 40.0

  public var policy: HumPolicy
  /// Lag time constant, seconds (both directions).
  public var tau: Double
  public private(set) var level = 0.0
  public private(set) var lastCause = -Double.infinity

  public init(policy: HumPolicy = .standard, tau: Double = 0.25) {
    self.policy = policy
    self.tau = tau
  }

  public mutating func noteCause(at now: Double) { lastCause = now }

  /// Whether a cause is live at `now` under the policy.
  public func causeIsLive(at now: Double) -> Bool {
    switch policy {
    case .ambient: true
    case .causal(let maxIdle): now - lastCause <= maxIdle
    }
  }

  /// Advances the level. `wish` is the simulation's intensity (0…1), `strength` the user's scale
  /// (0.2…1, ×0.6 under VoiceOver), `allowed` is false when the hum must stop at once (haptics or Feel
  /// off, app inactive, paused, Low Power, serious thermal). Returns the level to play; 0 means stop.
  @discardableResult
  public mutating func step(wish: Double, strength: Double, allowed: Bool, now: Double, dt: Double) -> Double {
    guard allowed else {
      level = 0
      return 0
    }
    let target = causeIsLive(at: now) ? clamped(wish, 0, 1) * clamped(strength, 0, 1) : 0
    approach(&level, target, dt: max(dt, 0), tau: tau)
    if level < Self.stopLevel, target < Self.stopLevel { level = 0 }
    return level < Self.stopLevel ? 0 : level
  }

  public var isPlaying: Bool { level >= Self.stopLevel }

  public mutating func reset() { level = 0 }
}

/// Rheo's "feel the goo resist your finger" map (§5.3). Stress at the finger spans six decades
/// (water ≈ 0.01 Pa, jammed oobleck ≈ 10 kPa) and felt vibration is roughly logarithmic, so:
///   σ̃ ← σ̃ + (σ̄ − σ̃)(1 − e^(−Δt/0.03 s))
///   I = clamp(0.15·log₁₀(1 + σ̃ / 0.1 Pa), 0, 1)          (saturates near 460 kPa)
///   S = clamp(0.15 + 0.70·s_f + 0.15·min(1, v_f / 0.5 m/s), 0, 1)
/// with s_f the unyielded-or-jammed fraction near the finger and v_f the finger speed.
/// Constants are proposals to tune on the iPhone 15 Pro Max (the simulator has no haptics).
public struct StressFeel: Sendable {
  public static let referenceStress = 0.1  // Pa
  public static let gain = 0.15
  public static let referenceSpeed = 0.5  // m/s

  /// Smoothing time constant against particle noise, seconds.
  public var tau = 0.03
  /// σ̃, Pa.
  public private(set) var stress = 0.0
  public init() {}

  /// Intensity for an equivalent shear stress in pascals.
  public static func intensity(stress: Double) -> Double {
    clamped(gain * log10(1 + max(stress, 0) / referenceStress), 0, 1)
  }

  /// Sharpness from the solid (unyielded or jammed) fraction 0…1 and the finger speed in m/s.
  public static func sharpness(solidFraction: Double, fingerSpeed: Double) -> Double {
    clamped(0.15 + 0.70 * clamped(solidFraction, 0, 1) + 0.15 * min(1, abs(fingerSpeed) / referenceSpeed), 0, 1)
  }

  /// With no finger in the tank: I = 0.10·√min(1, E_k / E_ref), S = 0.2 (you feel a shake's slosh settle).
  /// E_ref = ½ ρ A_fill (0.1 m/s)², per unit depth, in the same units as `kineticEnergy`.
  public static func slosh(kineticEnergy: Double, reference: Double) -> HumWish {
    guard reference > 0 else { return .silent }
    return HumWish(intensity: 0.10 * min(1, max(kineticEnergy, 0) / reference).squareRoot(), sharpness: 0.2)
  }

  /// E_ref for `slosh`: ½·ρ·A·(0.1 m/s)² (J/m for a 2D tank).
  public static func sloshReference(density: Double, fillArea: Double, speed: Double = 0.1) -> Double {
    0.5 * density * fillArea * speed * speed
  }

  /// One frame with a finger in the fluid: smooths σ̄ and returns the wish.
  public mutating func step(stress sample: Double, solidFraction: Double, fingerSpeed: Double, dt: Double) -> HumWish {
    approach(&stress, max(sample, 0), dt: dt, tau: tau)
    return HumWish(
      intensity: Self.intensity(stress: stress),
      sharpness: Self.sharpness(solidFraction: solidFraction, fingerSpeed: fingerSpeed))
  }

  public mutating func reset() { stress = 0 }
}

/// Transient events that ride on top of the hum (§5.3 "Events").
public enum FeelEvent: Sendable, Equatable {
  /// Stress at the finger crossed the yield stress upward (toothpaste starts to flow) → `.detent`.
  case yield
  /// Jam onset (an oobleck punch) → transient(0.9 + 0.1·fraction, 0.85).
  case jam(fraction: Double)
  /// It liquefied under the finger → `.release`.
  case unjam
  /// Granular jamming texture → transient(intensity, 0.95, minGap 0.025).
  case grain(intensity: Double)
}

/// Detects `FeelEvent`s with hysteresis so nothing chatters:
/// - yield fires when σ̃ ≥ τ_y and re-arms when σ̃ < 0.8·τ_y;
/// - jam fires when the jammed fraction rises through `jamOn`, unjam when it falls through `jamOff`;
/// - grains arrive as a Poisson process at rate min(40 s⁻¹, 200 × |d(jammed fraction)/dt|),
///   intensity uniform in 0.30…0.55 (deterministic xorshift, so tests and screenshots repeat).
public struct FeelEventDetector: Sendable {
  public var yieldRearm = 0.8
  public var jamOn = 0.5
  public var jamOff = 0.3
  public var maxGrainRate = 40.0
  public var grainGain = 200.0
  public private(set) var yielded = false
  public private(set) var jammed = false
  private var lastJam: Double?
  private var rng = XorShift32(seed: 0x5EED_1234)

  public init() {}

  /// `stress` is σ̃ (Pa); `yieldStress` τ_y (Pa) or nil for a material without one.
  public mutating func step(stress: Double, yieldStress: Double?, jammedFraction: Double, dt: Double) -> [FeelEvent] {
    var events: [FeelEvent] = []
    if let ty = yieldStress, ty > 0 {
      if !yielded, stress >= ty {
        yielded = true
        events.append(.yield)
      } else if yielded, stress < yieldRearm * ty {
        yielded = false
      }
    }
    let f = clamped(jammedFraction, 0, 1)
    if !jammed, f >= jamOn {
      jammed = true
      events.append(.jam(fraction: f))
    } else if jammed, f < jamOff {
      jammed = false
      events.append(.unjam)
    }
    if let last = lastJam, dt > 0 {
      let rate = min(maxGrainRate, grainGain * abs(f - last) / dt)
      // Probability of at least one arrival this frame; at most one grain per frame.
      if rate > 0, Double(rng.unit()) < 1 - exp(-rate * dt) {
        events.append(.grain(intensity: 0.30 + 0.25 * Double(rng.unit())))
      }
    }
    lastJam = f
    return events
  }

  public mutating func reset() {
    yielded = false
    jammed = false
    lastJam = nil
  }
}

/// The causes that keep a `.causal` hum alive (§5.2): a finger in the fluid; |user acceleration|
/// above 0.15 g; the mic envelope above its gate while Listen > 0; a magnetometer step |ΔB| > 5 µT
/// within about 0.5 s (`mag.step`).
public struct FeelCauses: Sendable {
  public var shakeThreshold = 0.15  // g
  public var micGate = 0.08  // envelope, 0…1
  public var magnetStep = 5.0  // µT
  public init() {}

  public func isLive(_ sources: ModSources, listen: Double, fingerDown: Bool) -> Bool {
    fingerDown || sources[.touchDown] > 0.5 || sources[.shake] > shakeThreshold
      || (listen > 0 && sources[.micEnvelope] > micGate) || sources[.fieldStep] > magnetStep
  }
}
