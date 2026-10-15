import Foundation

// The pure half of LabKit's sound policy (`labkit-from-orbitals-spectra.md` §6.3). LabKitFeedback's
// `SynthHost` and `LabFeedback` apply it on the device.

/// Log-to-pitch mapping (spectra-lab `pitchFor`, with the domain made explicit):
///   f = base · 2^(±octaves · (log10 x − log10 lo) / (log10 hi − log10 lo))
/// `inverted` makes larger x sound lower (Rheo: thicker fluids sound lower). x is clamped to the domain.
public func logPitch(
  _ x: Double, domain: ClosedRange<Double>, base: Double = 110, octaves: Double = 4, inverted: Bool = false
) -> Double {
  let lo = log10(max(domain.lowerBound, .leastNormalMagnitude))
  let hi = log10(max(domain.upperBound, .leastNormalMagnitude))
  guard hi > lo else { return base }
  let p = clamped((log10(max(x, .leastNormalMagnitude)) - lo) / (hi - lo), 0, 1)
  return base * pow(2, (inverted ? -1 : 1) * octaves * p)
}

/// Silence, ducking and cue suppression rules for the sound bed and cues (§6.3 rules 3–4).
/// - The bed is silent when sound is off, the app is inactive, the simulation is paused, or Low
///   Power Mode is on; otherwise it follows `activity` with the hum's 0.25 s lag.
/// - With the microphone live the bed is ducked to × 0.3, and any cue partial whose frequency lies
///   inside the band the app listens to, widened by one octave each side, is suppressed.
/// - Cues stay in Low Power Mode and while paused (they answer a user action).
public struct SoundPolicy: Sendable {
  public static let micDuck = 0.3
  public static let lag = 0.25
  /// After every cue or poke the app plays itself, mic onsets are ignored for this long (§5.2 rule 6).
  public static let selfSoundWindow = 0.2

  public var enabled = true
  public var active = true
  public var paused = false
  public var lowPower = false
  public var micLive = false
  /// The band the microphone drive listens to, Hz (Rheo's Band knob). nil = the whole range.
  public var micBand: ClosedRange<Double>?
  public private(set) var bedLevel = 0.0

  public init() {}

  public var bedAllowed: Bool { enabled && active && !paused && !lowPower }
  public var cuesAllowed: Bool { enabled && active }

  /// Advances the bed gain toward `activity` (0…1) and returns it (0 when silenced).
  @discardableResult
  public mutating func stepBed(activity: Double, dt: Double) -> Double {
    let target = bedAllowed ? clamped(activity, 0, 1) * (micLive ? Self.micDuck : 1) : 0
    if !bedAllowed {
      bedLevel = 0
    } else {
      approach(&bedLevel, target, dt: max(dt, 0), tau: Self.lag)
    }
    return bedLevel
  }

  /// Whether a cue partial at `frequency` Hz may sound now.
  public func allowsPartial(frequency: Double) -> Bool {
    guard cuesAllowed else { return false }
    guard micLive else { return true }
    guard let band = micBand else { return false }
    return frequency < band.lowerBound / 2 || frequency > band.upperBound * 2
  }
}
