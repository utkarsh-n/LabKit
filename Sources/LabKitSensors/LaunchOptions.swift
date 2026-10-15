import Foundation

/// Simulator/test stand-ins, read once from the process arguments (single leading dash, documented
/// in each app's README). Gyre reads these ad hoc in property initialisers
/// (MotionSource.swift:53, MicListener.swift:40, ARController.swift:65-66, RadioSense.swift:31, GyroModel.swift:254-256).
///
/// Example: `xcrun simctl launch booted com.utkarsh.rheo -simSway -fakeMic -startMic -fakeMagnet -fakeShake`
public enum LaunchOptions {
  public static let arguments = ProcessInfo.processInfo.arguments
  public static func has(_ flag: String) -> Bool { arguments.contains(flag) }
  /// `-flag value` → value.
  public static func value(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
  }

  public static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      false
    #endif
  }

  public static var isDebugBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  /// Policy: a fake is honoured in DEBUG builds, or whenever the real hardware is missing
  /// (Gyre's -fakeAR rule, ARController.swift:65-66), so a stray flag can't fake a sensor on a
  /// Release build running on a real phone.
  public static func fake(_ flag: String, hardwareAvailable: Bool) -> Bool {
    #if DEBUG
      has(flag)
    #else
      has(flag) && !hardwareAvailable
    #endif
  }

  /// Sway the simulated phone (yaw ±0.9, pitch ±0.3, roll ±0.25 rad at 0.31/0.23/0.17 rad/s).
  public static let simSway = "-simSway"
  /// A synthetic room (hummed chord plus a clap every 1.6 s) through the real ring and analyser.
  public static let fakeMic = "-fakeMic"
  /// Turn the microphone on at launch (the app reads this in its first `start()`).
  public static let startMic = "-startMic"
  /// New for Rheo's MR fluid: a magnet that approaches and retreats every 6 s (up to 2 mT).
  public static let fakeMagnet = "-fakeMagnet"
  /// New: periodic shakes (0.4 s of 12 Hz at ±1.2 g every 3 s).
  public static let fakeShake = "-fakeShake"
  /// `-fakeThermal 0|1|2|3|cycle`: pretend the phone is nominal/fair/serious/critical (DEBUG only).
  public static let fakeThermal = "-fakeThermal"
  /// Pretend Low Power Mode is on (DEBUG only): 60 fps cap, no hum, no sound bed.
  public static let fakeLowPower = "-fakeLowPower"
  /// Reserved for a scripted poke-and-stir path (deterministic screenshots, UI tests). Not read by LabKit yet.
  public static let fakeTouch = "-fakeTouch"
  public static let fakeAR = "-fakeAR"
  public static let startAR = "-startAR"
  public static let fakeRadio = "-fakeRadio"

  /// Every flag LabKit knows, for a "Simulated" banner or a debug census.
  public static let knownFlags = [
    simSway, fakeMic, startMic, fakeMagnet, fakeShake, fakeThermal, fakeLowPower, fakeTouch, fakeAR, startAR, fakeRadio,
  ]

  /// True when `-startMic` was passed.
  public static var startMicRequested: Bool { has(startMic) }

  /// The known flags present on this launch.
  public static var activeFlags: [String] { knownFlags.filter(has) }
}
