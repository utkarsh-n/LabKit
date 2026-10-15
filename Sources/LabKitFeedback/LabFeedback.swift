#if os(iOS)
import Foundation
import LabKitCore
import Observation
import QuartzCore

/// One object that applies LabKit's haptics and sound policy for an app (§5 and §6 of
/// `labkit-from-orbitals-spectra.md`): paired cues (sound + haptic twin), the sound bed with its
/// silence and ducking rules, the self-trigger guard for the microphone, and the persisted Sound
/// toggle (`"<App>.sound"`, default on, following the ring/silent switch through `.ambient`).
///
/// Wiring, from the app model:
/// ```swift
/// let feedback = LabFeedback(appName: "Rheo", kernel: GloopKernel())
/// feedback.onSelfSound = { [mic] in mic.ignoreOnsets(for: $0) }
/// // scenePhase: feedback.setActive(phase == .active)
/// // per frame:  feedback.micLive = mic.isLive; feedback.updateBed(activity: a, dt: dt)
/// //             if cause { feedback.noteCause() }; feedback.updateHum(wish)
/// // events:     feedback.cue(.detent); feedback.play(.poke); feedback.play(feelEvent)
/// ```
/// `FeedbackSettings` (LabKitUI) binds to `haptics.enabled`, `haptics.strength`, `haptics.humEnabled`
/// and `sound`.
@MainActor @Observable
public final class LabFeedback {
  public let haptics: HapticEngine
  @ObservationIgnored public let synth: SynthHost?

  private var storedSound = true
  /// Sound on/off (bed and cues). Persisted; on by default. The silent switch still mutes it while
  /// the microphone is off (`.ambient`).
  public var sound: Bool {
    get { storedSound }
    set {
      storedSound = newValue
      if let key = persistenceKey { defaults.set(newValue, forKey: key + ".sound") }
      applyRunState()
    }
  }

  /// The microphone is listening (set from `MicListener.isLive` each frame or on change). Ducks the
  /// bed to × 0.3 and suppresses cue partials near `micBand`.
  public var micLive = false

  /// The band the mic drive listens to, Hz (Rheo's Band knob). nil: every cue is muted while the mic is live.
  public var micBand: ClosedRange<Double>?

  /// The simulation is paused: the hum and the bed go quiet; cues and transients stay.
  public var paused = false {
    didSet {
      haptics.paused = paused
      // Silence the bed at once, even if the app stops calling `updateBed` while paused.
      if paused { synth?.bedGain = 0 }
    }
  }

  /// The app is active (scenePhase == .active).
  public private(set) var active = true

  /// Called with `SoundPolicy.selfSoundWindow` (0.2 s) after every cue, poke or feel event the app
  /// plays itself while the mic is live; wire it to `MicListener.ignoreOnsets(for:)`.
  @ObservationIgnored public var onSelfSound: (@MainActor (Double) -> Void)?

  @ObservationIgnored private var policy = SoundPolicy()
  @ObservationIgnored private let persistenceKey: String?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var lowPowerCheck = Throttle(interval: 0.5)

  /// `kernel` is the app's bed voice (nil: no synth at all; `SilentKernel()` for cues only).
  public init(
    appName: String? = nil, kernel: (any SynthKernel)? = nil, cues: [SonicCue] = SonicCue.standard,
    defaults: UserDefaults = .standard
  ) {
    persistenceKey = appName
    self.defaults = defaults
    haptics = HapticEngine(persistenceKey: appName, defaults: defaults)
    synth = kernel.map { SynthHost(kernel: $0, cues: cues) }
    if let key = appName, let v = defaults.object(forKey: key + ".sound") as? Bool { storedSound = v }
  }

  /// The bed's current gain after policy (for telemetry and tests).
  public var bedLevel: Double { policy.bedLevel }

  /// Starts haptics and (if Sound is on) the synth. Call from `.onAppear` / `.active`.
  public func start() { setActive(true) }

  /// Stops everything. Call for any `scenePhase != .active`.
  public func stop() { setActive(false) }

  public func setActive(_ isActive: Bool) {
    active = isActive
    if isActive { haptics.start() } else { haptics.stop() }
    applyRunState()
  }

  private func applyRunState() {
    guard let synth else { return }
    if sound && active {
      if !synth.running { synth.start() }
    } else if synth.running {
      synth.bedGain = 0
      synth.stop()
    }
  }

  private func refreshPolicy() {
    policy.enabled = sound
    policy.active = active
    policy.paused = paused
    policy.micLive = micLive
    policy.micBand = micBand
    if lowPowerCheck.ready(at: CACurrentMediaTime()) { policy.lowPower = DeviceConditions.current.lowPower }
  }

  private func selfSound() {
    if micLive { onSelfSound?(SoundPolicy.selfSoundWindow) }
  }

  // MARK: Events

  /// A haptic transient the app plays itself (opens the mic's self-trigger window when listening).
  public func play(_ tap: HapticTap) {
    haptics.play(tap)
    selfSound()
  }

  /// Rheo's feel events → haptics (§5.3), with the self-trigger window.
  public func play(_ event: FeelEvent) {
    haptics.play(event)
    selfSound()
  }

  /// A paired cue: its sound (if allowed) and its haptic twin.
  public func cue(_ cue: SonicCue, gain: Float = 1) {
    refreshPolicy()
    haptics.play(cue.haptic)
    if let synth {
      let p = policy
      synth.play(cue, gain: gain) { p.allowsPartial(frequency: $0) }
    }
    selfSound()
  }

  // MARK: Continuous channels

  public func noteCause() { haptics.noteCause() }

  public func updateHum(intensity: Float, sharpness: Float) { haptics.updateHum(intensity: intensity, sharpness: sharpness) }

  public func updateHum(_ wish: HumWish) { haptics.updateHum(wish) }

  /// Sets the bed gain from `activity` (0…1): silent when Sound is off, inactive, paused or in Low
  /// Power Mode; ducked to × 0.3 while the mic is live; 0.25 s lag. The app's kernel still sets its
  /// own pitch and timbre through `synth.controls`.
  public func updateBed(activity: Double, dt: Double) {
    refreshPolicy()
    let level = policy.stepBed(activity: activity, dt: dt)
    synth?.bedGain = Float(level)
  }
}
#endif
