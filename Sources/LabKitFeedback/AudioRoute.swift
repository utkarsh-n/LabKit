#if os(iOS)
import AVFoundation

/// The one audio session the synth and the microphone share (Gyre: MicListener.swift:4-20):
/// `.ambient` + `.mixWithOthers` (the ring/silent switch mutes the synth) until the mic listens,
/// then `.playAndRecord` in `.measurement` mode so input arrives without voice processing or
/// automatic gain. With the mic live the silent switch no longer mutes output, which is why
/// `SoundPolicy` ducks the bed.
///
/// Echo-cancelled input is a runtime option, never an assumption (§6.3 rule 4): it exists only on
/// some 2024-or-later iPhones (iOS 18.2+), and only with `.playAndRecord` + `.default` mode
/// (`AVAudioSession.h:181-215`, iPhoneOS27.0 SDK). Set `prefersEchoCancellation` before the mic
/// starts; `apply()` then tries `.default` mode, asks for it if available, and otherwise falls back
/// to `.measurement`. `echoCancelledInputActive` reports what the session actually honoured.
/// Activation is asynchronous (iOS 27 `activate(options:completionHandler:)`): a synchronous
/// `setActive(true)` on the main thread is flagged by the runtime as a hang risk. Engines may start
/// right after `apply()`; AVAudioEngine activates the session itself if it is not active yet.
@MainActor
public enum AudioRoute {
  public static var recording = false
  /// Ask for echo-cancelled input when recording (off by default; the 15 Pro Max likely lacks it).
  public static var prefersEchoCancellation = false
  /// Whether the last `apply()` got echo-cancelled input (known once activation completes).
  public private(set) static var echoCancelledInputActive = false
  /// The configuration last applied, so repeated calls (synth + mic) don't reconfigure the session.
  private static var applied: (recording: Bool, echo: Bool)?
  private static var activations = 0

  public static func apply() {
    let session = AVAudioSession.sharedInstance()
    let wanted = (recording: recording, echo: recording && prefersEchoCancellation)
    if let applied, applied == wanted {
      activate(session)
      return
    }
    applied = wanted
    echoCancelledInputActive = false
    var usedEcho = false
    if recording {
      let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
      if prefersEchoCancellation {
        try? session.setCategory(.playAndRecord, mode: .default, options: options)
        if session.isEchoCancelledInputAvailable {
          usedEcho = (try? session.setPrefersEchoCancelledInput(true)) != nil
        }
      }
      if !usedEcho {
        if session.prefersEchoCancelledInput { try? session.setPrefersEchoCancelledInput(false) }
        try? session.setCategory(.playAndRecord, mode: .measurement, options: options)
      }
    } else {
      try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }
    activate(session, checkEcho: usedEcho)
  }

  private static func activate(_ session: AVAudioSession, checkEcho: Bool = false) {
    activations += 1
    let generation = activations
    session.activate(options: [], completionHandler: Self.activated(generation: generation, checkEcho: checkEcho))
  }

  /// Built outside the main actor: the completion runs on an AVAudioSession queue.
  private nonisolated static func activated(generation: Int, checkEcho: Bool) -> @Sendable (Bool, (any Error)?) -> Void {
    { @Sendable ok, _ in
      let echo = ok && checkEcho && AVAudioSession.sharedInstance().isEchoCancelledInputEnabled
      Task { @MainActor in
        if generation == activations, checkEcho { echoCancelledInputActive = echo }
      }
    }
  }

  /// Whether this phone could give echo-cancelled input for a play-and-record session (asks the
  /// session about `.playAndRecord` + `.default`; does not change the active configuration's mode
  /// unless the mic is off).
  public static var echoCancellationAvailable: Bool {
    AVAudioSession.sharedInstance().isEchoCancelledInputAvailable
  }

  /// Forget the applied configuration, so the next `apply()` sets the category again (after a media-services reset the
  /// session's configuration is gone).
  static func forgetApplied() { applied = nil }

  /// Releases the session (when neither synth nor mic needs it), letting other audio resume.
  public static func deactivate() {
    applied = nil
    AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) { @Sendable _, _ in }
  }

  /// iOS 27 replaces AVAudioSessionInterruptionNotification (deprecated ios(6.0, 27.0),
  /// AVAudioSessionTypes.h:229) with these two (AVAudioSessionTypes.h:316, 321). Gyre handles neither.
  /// Typical wiring: `inactive: { mic.suspend(); synth.stop() }`, `resume: { synth.start(); Task { await mic.resume() } }`.
  public static func observeInterruptions(
    inactive: @escaping @MainActor () -> Void, resume: @escaping @MainActor () -> Void
  ) -> [NSObjectProtocol] {
    let center = NotificationCenter.default
    return [
      center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) {
        @Sendable _ in
        MainActor.assumeIsolated { inactive() }
      },
      center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) {
        @Sendable _ in
        MainActor.assumeIsolated { resume() }
      },
    ]
  }

  /// Media services were reset (rare; e.g. after a crash in mediaserverd): every engine and the
  /// session configuration must be rebuilt. `reset` runs on the main actor after `apply()`.
  public static func observeMediaReset(_ reset: @escaping @MainActor () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
    ) { @Sendable _ in
      MainActor.assumeIsolated {
        forgetApplied()
        apply()
        reset()
      }
    }
  }
}
#endif
