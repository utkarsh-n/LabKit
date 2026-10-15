#if os(iOS)
import CoreHaptics
import Foundation
import LabKitCore
import Observation
import QuartzCore
import UIKit

/// A named transient: intensity and sharpness 0…1 (CHHapticEventParameter values) and the minimum
/// time since the last admitted transient of any kind (one shared admission clock).
public struct HapticTap: Sendable, Hashable {
  public var intensity: Float
  public var sharpness: Float
  public var minGap: Double
  public init(_ intensity: Float, _ sharpness: Float, minGap: Double = 0) {
    self.intensity = intensity
    self.sharpness = sharpness
    self.minGap = minGap
  }
}

/// The merged vocabulary (`labkit-from-orbitals-spectra.md` §5.4). Taps already deduplicated by
/// state (a detent entered, a new switch position, a double-tap) have minGap 0 and are never
/// dropped; taps from a continuous stream have ≥ 0.035 s.
extension HapticTap {
  /// Every button and menu open (Orbitals `.touch`).
  public static let tap = HapticTap(0.64, 0.50, minGap: 0.028)
  /// Knob grab, tray open, slider begin (Gyre `GlassKnob.swift:106`).
  public static let grab = HapticTap(0.45, 0.70, minGap: 0.035)
  /// 24 per sweep; keyboard nudges (Gyre `:133`; interval from Orbitals `:100`).
  public static let tick = HapticTap(0.32, 0.90, minGap: 0.045)
  /// Entering a labelled detent; Rheo's yield crossing (Gyre `:125`).
  public static let detent = HapticTap(0.90, 0.30)
  /// A rotary switch position (Gyre `:114`).
  public static let switchClick = HapticTap(0.90, 0.35)
  /// Knob or slider release; unjam (Orbitals `.release`).
  public static let release = HapticTap(0.34, 0.38, minGap: 0.035)
  /// End stop, failed action, "Feel a detent" (Orbitals `.boundary`).
  public static let boundary = HapticTap(0.95, 0.64, minGap: 0.090)
  /// Double-tap reset, page reset (Gyre `:89`; `GyroModel.swift:298`).
  public static let reset = HapticTap(0.70, 0.40)
  /// Fold, expand, pause, chrome toggles (Gyre fold/expand/toggle merged).
  public static let soft = HapticTap(0.40, 0.55, minGap: 0.035)
  /// A material or object tile chosen (`GyroModel.swift:287`).
  public static let select = HapticTap(0.70, 0.55)
  /// AR placement (`GyroModel.swift:333`).
  public static let place = HapticTap(0.85, 0.35)
  /// Touching the simulated world (`GyroModel.swift:818`).
  public static let poke = HapticTap(0.90, 0.45, minGap: 0.050)
  /// A sound-driven kick; an "oobleck monster" burst (`GyroModel.swift:676`).
  public static let ripple = HapticTap(0.75, 0.50, minGap: 0.050)
  /// A droplet pinches off (Rheo §5.3).
  public static let pinch = HapticTap(0.40, 0.30, minGap: 0.050)
  /// Magnetometer crackle base tap (`GyroModel.swift:712-718`); `crackle(…)` adds 0.4·depth.
  public static let crackle = HapticTap(0.35, 1, minGap: 0.030)

  // Prototype (Gyre) names, kept as deprecated aliases.
  @available(*, deprecated, renamed: "grab") public static var knobGrab: HapticTap { .grab }
  @available(*, deprecated, renamed: "tick") public static var knobTick: HapticTap { .tick }
  @available(*, deprecated, renamed: "detent") public static var knobDetent: HapticTap { .detent }
  @available(*, deprecated, renamed: "switchClick") public static var knobSwitch: HapticTap { .switchClick }
  @available(*, deprecated, renamed: "reset") public static var knobReset: HapticTap { .reset }
  @available(*, deprecated, renamed: "reset") public static var modeChange: HapticTap { .reset }
  @available(*, deprecated, renamed: "soft") public static var fold: HapticTap { .soft }
  @available(*, deprecated, renamed: "soft") public static var expand: HapticTap { .soft }
  @available(*, deprecated, renamed: "soft") public static var toggle: HapticTap { .soft }
  @available(*, deprecated, message: "VoiceOver steps use selection(); keyboard nudges use .tick")
  public static var knobNudge: HapticTap { HapticTap(0.4, 0.8) }
}

/// Core Haptics for lab toys, with two causal channels (§5.2):
/// - **Feedback** (transients): every tap answers something the user did. One shared admission
///   clock coalesces bursts; cached players; UIKit `.rigid` fallback without Core Haptics.
/// - **Feel** (the continuous hum): the simulation's push-back, at most 40 parameter sends a second.
///   `HumPolicy.causal(maxIdle: 8)` by default: it plays only while `noteCause()` was called in the
///   last 8 s, follows its target with a 0.25 s lag and stops below 0.02.
///
/// Stop rules: everything stops on `stop()` (call it for any `scenePhase != .active`) and on
/// `didEnterBackground`. The hum alone stops while `paused`, in Low Power Mode and at thermal
/// state ≥ `.serious`; transients stay. `strength` (0.2…1, default 0.85) scales both channels;
/// under VoiceOver the hum plays at strength × 0.6. With a persistence key the user settings are
/// stored as `"<key>.haptics"`, `"<key>.hapticStrength"` and `"<key>.feel"`.
///
/// Swift 6: Core Haptics handlers and notification observers are `{ @Sendable … }` closures that hop
/// to the main actor (§5.7), built in `nonisolated static` factories where they touch the engine.
@MainActor @Observable
public final class HapticEngine {
  public typealias HumPolicy = LabKitCore.HumPolicy

  public static let parameterRate = HumGovernor.sendRate
  public static let strengthRange: ClosedRange<Float> = 0.2...1
  public static let defaultStrength: Float = 0.85
  public static let voiceOverHumScale: Float = 0.6

  @ObservationIgnored public let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

  private var storedEnabled = true
  private var storedStrength = HapticEngine.defaultStrength
  private var storedFeel = true

  /// Haptics on/off (both channels). Persisted.
  public var enabled: Bool {
    get { storedEnabled }
    set {
      storedEnabled = newValue
      if !newValue { stopHum() }
      save()
    }
  }

  /// One Strength slider, 0.2…1 (Off is `enabled`), multiplies every transient and the hum. Persisted.
  public var strength: Float {
    get { storedStrength }
    set {
      storedStrength = clamped(newValue.isFinite ? newValue : Self.defaultStrength, Self.strengthRange.lowerBound, Self.strengthRange.upperBound)
      save()
    }
  }

  /// The "Feel the simulation" switch for the continuous channel. Persisted.
  public var humEnabled: Bool {
    get { storedFeel }
    set {
      storedFeel = newValue
      if !newValue { stopHum() }
      save()
    }
  }

  /// `.causal(maxIdle: 8)` by default; Gyre opts into `.ambient`.
  public var humPolicy: HumPolicy = .standard

  /// The simulation is paused: the hum stops, transients stay (knobs still work while paused).
  public var paused = false {
    didSet { if paused { stopHum() } }
  }

  /// The hum's current level after policy, lag and strength (0 when silent). Not observed.
  public var humLevel: Float { Float(governor.level) }
  /// Whether the hum player is running. Not observed.
  public var isHumPlaying: Bool { humRunning }
  /// Low Power or serious thermal state, as last checked.
  public var isConstrained: Bool { constrained }

  @ObservationIgnored private let persistenceKey: String?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var engine: CHHapticEngine?
  @ObservationIgnored private var engineRunning = false
  @ObservationIgnored private var players: [HapticTap: any CHHapticPatternPlayer] = [:]
  @ObservationIgnored private var freePlayers: [Int: any CHHapticPatternPlayer] = [:]
  @ObservationIgnored private var hum: CHHapticAdvancedPatternPlayer?
  @ObservationIgnored private var humRunning = false
  @ObservationIgnored private var governor = HumGovernor()
  @ObservationIgnored private var lastHumUpdate: CFTimeInterval = 0
  @ObservationIgnored private var lastSend: CFTimeInterval = 0
  @ObservationIgnored private var lastAdmit: CFTimeInterval = -.infinity
  @ObservationIgnored private var crackleDue = 0.0
  @ObservationIgnored private var conditionsCheck = Throttle(interval: 0.25)
  @ObservationIgnored private var constrained = DeviceConditions.current.isConstrained
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .rigid)
  @ObservationIgnored private let selectionGenerator = UISelectionFeedbackGenerator()
  @ObservationIgnored private let notificationGenerator = UINotificationFeedbackGenerator()

  /// `persistenceKey` is the app's name ("Rheo"); nil keeps the settings in memory only.
  public init(persistenceKey: String? = nil, defaults: UserDefaults = .standard) {
    self.persistenceKey = persistenceKey
    self.defaults = defaults
    if let key = persistenceKey {
      if let v = defaults.object(forKey: key + ".haptics") as? Bool { storedEnabled = v }
      if let v = defaults.object(forKey: key + ".hapticStrength") as? Double {
        storedStrength = clamped(Float(v), Self.strengthRange.lowerBound, Self.strengthRange.upperBound)
      }
      if let v = defaults.object(forKey: key + ".feel") as? Bool { storedFeel = v }
    }
    observers = Self.observe(self)
  }

  isolated deinit {
    for o in observers { NotificationCenter.default.removeObserver(o) }
  }

  /// One observer set for the engine's lifetime, no timers (Orbitals `OrbitalHaptics.swift:47-56`).
  private nonisolated static func observe(_ owner: HapticEngine) -> [NSObjectProtocol] {
    let center = NotificationCenter.default
    let background: @Sendable (Notification) -> Void = { [weak owner] _ in
      Task { @MainActor in owner?.stop() }
    }
    let conditions: @Sendable (Notification) -> Void = { [weak owner] _ in
      Task { @MainActor in owner?.refreshConditions(force: true) }
    }
    return [
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: background),
      center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: conditions),
      center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: conditions),
    ]
  }

  private func save() {
    guard let key = persistenceKey else { return }
    defaults.set(storedEnabled, forKey: key + ".haptics")
    defaults.set(Double(storedStrength), forKey: key + ".hapticStrength")
    defaults.set(storedFeel, forKey: key + ".feel")
  }

  // MARK: Lifecycle

  /// Prepares the engine (cheap to call again). Call on `.active` and, to hide restart latency
  /// after an auto-shutdown, on knob grab or touch-down.
  public func start() {
    guard supported else { return }
    _ = try? prepareEngine()
  }

  /// Stops everything: the hum, any playing transients and the engine.
  public func stop() {
    stopHum()
    for p in players.values { try? p.stop(atTime: CHHapticTimeImmediate) }
    engine?.stop(completionHandler: nil)
    engineRunning = false
    lastAdmit = -.infinity
  }

  private var canPlay: Bool { enabled && UIApplication.shared.applicationState == .active }

  /// One shared admission clock: a burst coalesces instead of queuing.
  private func admit(_ minGap: Double) -> Bool {
    guard canPlay else { return false }
    let now = CACurrentMediaTime()
    guard now - lastAdmit >= minGap else { return false }
    lastAdmit = now
    return true
  }

  // MARK: Transients

  public func play(_ tap: HapticTap) {
    guard admit(tap.minGap) else { return }
    let level = clamped(tap.intensity * strength, 0, 1)
    if supported, let player = cachedPlayer(for: tap) {
      fire(player, control: strength, fallbackLevel: level)
    } else {
      fallback(level: level)
    }
  }

  /// A free transient (crackle, granular texture). Intensity is scaled by `strength`.
  public func transient(intensity: Float, sharpness: Float, minGap: CFTimeInterval = 0.03) {
    guard admit(minGap) else { return }
    let level = clamped(intensity * strength, 0, 1)
    let bucket = Int((clamped(sharpness, 0, 1) * 10).rounded())
    if supported, let player = freePlayer(sharpnessBucket: bucket) {
      fire(player, control: level, fallbackLevel: level)
    } else {
      fallback(level: level)
    }
  }

  /// The system selection tick: pickers, chips, toggles, VoiceOver steps.
  public func selection() {
    guard admit(0.035) else { return }
    selectionGenerator.selectionChanged()
  }

  /// The system success pattern: an experiment applied, reset all.
  public func success() {
    guard admit(0.06) else { return }
    notificationGenerator.notificationOccurred(.success)
  }

  /// Rheo's feel events (§5.3): yield → `.detent`, jam → transient(0.9 + 0.1·f, 0.85),
  /// unjam → `.release`, grain → transient(i, 0.95, minGap 0.025).
  public func play(_ event: FeelEvent) {
    switch event {
    case .yield: play(.detent)
    case .jam(let f): transient(intensity: Float(0.9 + 0.1 * clamped(f, 0, 1)), sharpness: 0.85, minGap: 0)
    case .unjam: play(.release)
    case .grain(let i): transient(intensity: Float(i), sharpness: 0.95, minGap: 0.025)
    }
  }

  /// A rising buzz that ends in a click (Gyre `spinUp`, Haptics.swift:113-142): 0.55 s continuous
  /// (0.9, 0.3) with intensity curve 0.1→1 and sharpness −0.3→0.4, click (1, 0.9) at duration + 0.01 s.
  /// Rheo's Refill pour.
  public func ramp(duration: Double = 0.55, from: Float = 0.1, to: Float = 1, click: Bool = true) {
    guard canPlay, supported, let engine = try? prepareEngine() else { return }
    var events = [
      CHHapticEvent(
        eventType: .hapticContinuous,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9 * strength),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
        ], relativeTime: 0, duration: duration)
    ]
    if click {
      events.append(
        CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
          ], relativeTime: duration + 0.01))
    }
    let end = max(duration - 0.05, 0.01)
    let curve = CHHapticParameterCurve(
      parameterID: .hapticIntensityControl,
      controlPoints: [.init(relativeTime: 0, value: from), .init(relativeTime: end, value: to)],
      relativeTime: 0)
    let sharp = CHHapticParameterCurve(
      parameterID: .hapticSharpnessControl,
      controlPoints: [.init(relativeTime: 0, value: -0.3), .init(relativeTime: end, value: 0.4)],
      relativeTime: 0)
    if let pattern = try? CHHapticPattern(events: events, parameterCurves: [curve, sharp]),
      let player = try? engine.makePlayer(with: pattern)
    {
      try? player.start(atTime: CHHapticTimeImmediate)
    }
  }

  /// Geiger-style crackle for a strong field (GyroModel.swift:712-718): above 120 µT, rate =
  /// min((B − 100)/30, 30) clicks/s with 0.3…1.7× jitter, intensity 0.35 + 0.4·depth, sharpness 1.
  public func crackle(fieldMicroTesla field: Double, depth: Double, clock: Double) {
    guard depth > 0.01, field > 120, clock >= crackleDue else { return }
    let rate = min((field - 100) / 30, 30)
    crackleDue = clock + Double.random(in: 0.3...1.7) / rate
    transient(intensity: Float(0.35 + 0.4 * depth), sharpness: 1, minGap: HapticTap.crackle.minGap)
  }

  // MARK: Feel (the continuous hum)

  /// A cause is live this frame (finger in the fluid, a shake, a loud room, a moving magnet).
  public func noteCause() { governor.noteCause(at: CACurrentMediaTime()) }

  /// Call every frame with the simulation's wish (0…1). Policy, the 0.25 s fade, strength and the
  /// ≤ 40 Hz send rate are applied here. Sharpness is sent as an offset from the base 0.5.
  public func updateHum(intensity: Float, sharpness: Float) {
    let now = CACurrentMediaTime()
    let dt = lastHumUpdate == 0 ? 1.0 / 120 : min(0.1, max(0, now - lastHumUpdate))
    lastHumUpdate = now
    refreshConditions(force: false)
    governor.policy = humPolicy
    let allowed = enabled && humEnabled && !paused && !constrained && supported
      && UIApplication.shared.applicationState == .active
    var scale = strength
    if UIAccessibility.isVoiceOverRunning { scale *= Self.voiceOverHumScale }
    let level = governor.step(wish: Double(intensity), strength: Double(scale), allowed: allowed, now: now, dt: dt)
    guard level > 0 else {
      silenceHumPlayer()
      return
    }
    guard now - lastSend >= 1.0 / Self.parameterRate else { return }
    lastSend = now
    do {
      let player = try humPlayer()
      if !humRunning {
        try player.start(atTime: CHHapticTimeImmediate)
        humRunning = true
      }
      try player.sendParameters(
        [
          CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(level), relativeTime: 0),
          CHHapticDynamicParameter(
            parameterID: .hapticSharpnessControl, value: clamped(sharpness, 0, 1) - 0.5, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    } catch {
      hum = nil
      humRunning = false
    }
  }

  /// Convenience for a `HumWish` from `StressFeel`.
  public func updateHum(_ wish: HumWish) {
    updateHum(intensity: Float(wish.intensity), sharpness: Float(wish.sharpness))
  }

  public func stopHum() {
    governor.reset()
    silenceHumPlayer()
  }

  private func silenceHumPlayer() {
    if humRunning { try? hum?.stop(atTime: CHHapticTimeImmediate) }
    humRunning = false
  }

  private func refreshConditions(force: Bool) {
    guard force || conditionsCheck.ready(at: CACurrentMediaTime()) else { return }
    constrained = DeviceConditions.current.isConstrained
    if constrained { stopHum() }
  }

  // MARK: Engine

  private func prepareEngine() throws -> CHHapticEngine {
    let current: CHHapticEngine
    if let engine {
      current = engine
    } else {
      current = try CHHapticEngine()
      current.playsHapticsOnly = true
      // The hum is causal and idles most of the time, so let the engine shut itself down (§5.6).
      current.isAutoShutdownEnabled = true
      Self.wire(current, to: self)
      engine = current
    }
    if !engineRunning {
      try current.start()
      engineRunning = true
    }
    return current
  }

  /// Handlers run on a Core Haptics queue. Explicitly `@Sendable` so they are NOT inferred
  /// MainActor-isolated (verified in SIL: a plain closure here is `global_actor MainActor`).
  private nonisolated static func wire(_ e: CHHapticEngine, to owner: HapticEngine) {
    e.resetHandler = { @Sendable [weak owner] in
      Task { @MainActor in owner?.engineDidReset() }
    }
    e.stoppedHandler = { @Sendable [weak owner] _ in
      Task { @MainActor in owner?.engineDidStop() }
    }
  }

  private func engineDidStop() {
    engineRunning = false
    hum = nil
    humRunning = false
  }

  private func engineDidReset() {
    players.removeAll()
    freePlayers.removeAll()
    engineDidStop()
  }

  private func cachedPlayer(for tap: HapticTap) -> (any CHHapticPatternPlayer)? {
    if let p = players[tap] { return p }
    guard let p = makeTransient(intensity: tap.intensity, sharpness: tap.sharpness) else { return nil }
    players[tap] = p
    return p
  }

  private func freePlayer(sharpnessBucket: Int) -> (any CHHapticPatternPlayer)? {
    if let p = freePlayers[sharpnessBucket] { return p }
    guard let p = makeTransient(intensity: 1, sharpness: Float(sharpnessBucket) / 10) else { return nil }
    freePlayers[sharpnessBucket] = p
    return p
  }

  private func makeTransient(intensity: Float, sharpness: Float) -> (any CHHapticPatternPlayer)? {
    do {
      let engine = try prepareEngine()
      let event = CHHapticEvent(
        eventType: .hapticTransient,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
      return try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
    } catch {
      return nil
    }
  }

  private func humPlayer() throws -> CHHapticAdvancedPatternPlayer {
    if let hum { return hum }
    let engine = try prepareEngine()
    let event = CHHapticEvent(
      eventType: .hapticContinuous,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
      ], relativeTime: 0, duration: 30)
    let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
    player.loopEnabled = true
    hum = player
    return player
  }

  /// The event carries the tap's own intensity; `hapticIntensityControl` scales it by strength.
  private func fire(_ player: any CHHapticPatternPlayer, control: Float, fallbackLevel: Float) {
    do {
      _ = try prepareEngine()
      try player.sendParameters(
        [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: control, relativeTime: 0)],
        atTime: CHHapticTimeImmediate)
      try player.start(atTime: CHHapticTimeImmediate)
    } catch {
      players.removeAll()
      freePlayers.removeAll()
      engineRunning = false
      fallback(level: fallbackLevel)
    }
  }

  /// UIKit path without Core Haptics or after an engine error (Orbitals `OrbitalHaptics.swift:188`).
  private func fallback(level: Float) {
    impact.impactOccurred(intensity: CGFloat(clamped(level, 0, 1)))
  }
}
#endif
