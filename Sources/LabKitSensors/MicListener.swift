#if os(iOS)
import AVFoundation
import Foundation
import LabKitCore
import LabKitFeedback
import Synchronization

public enum MicState: Sendable, Equatable { case off, starting, on, denied, failed }

/// The record permission, for a `PermissionGate` before the first raise of Listen.
public enum MicPermission: Sendable, Equatable { case undetermined, granted, denied }

/// The ring and its analyser, shared between the tap thread and the main actor. `Mutex` makes it
/// Sendable with no `@unchecked` (replaces Gyre's NSLock-guarded fields, MicListener.swift:42-55).
/// Nothing is persisted: 16384 samples, constantly overwritten, zeroed on stop.
final class MicRing: Sendable {
  struct State {
    var ring = [Float](repeating: 0, count: 16384)
    var head = 0
    var analyser = OnsetAnalyser()
  }

  let state = Mutex(State())

  func write(_ x: UnsafeBufferPointer<Float>, sampleRate: Double) {
    state.withLock { s in
      let mask = s.ring.count - 1
      for v in x {
        s.ring[s.head] = v
        s.head = (s.head + 1) & mask
      }
      s.analyser.sampleRate = sampleRate
      s.analyser.analyse(x)
    }
  }

  func snapshot(count: Int, sampleRate: Double) -> MicSnapshot {
    state.withLock { s in
      let mask = s.ring.count - 1
      var out = [Float](repeating: 0, count: count)
      let start = (s.head - count) & mask
      for i in 0..<count { out[i] = s.ring[(start + i) & mask] }
      let onset = s.analyser.consumeOnset()
      return MicSnapshot(samples: out, level: s.analyser.level, bass: s.analyser.bass, onset: onset, sampleRate: sampleRate)
    }
  }

  func ignoreOnsets(for seconds: Double) { state.withLock { $0.analyser.ignoreOnsets(for: seconds) } }

  func clear() {
    state.withLock { s in
      for i in s.ring.indices { s.ring[i] = 0 }
      s.analyser.reset()
    }
  }
}

/// Microphone for scopes, spectra and modulation. Lifted from Gyre/Sensors/MicListener.swift:36-212.
/// Swift 6: the tap uses iOS 27's `installAudioTap` whose provider is `@Sendable` and receives an
/// `AVReadOnlyAudioPCMBuffer` (AVFAudio.swiftinterface:63), so no MainActor-inferred closure runs on
/// the audio thread and there is no deprecation warning.
@MainActor
public final class MicListener {
  public private(set) var state: MicState = .off
  public let fake: Bool
  private let engine = AVAudioEngine()
  private let ring = MicRing()
  public private(set) var sampleRate = 48_000.0
  private var fakeTime = 0.0
  private var fakeNoise = XorShift32(seed: 1)
  private var suspended = false

  public init() {
    fake = LaunchOptions.fake(LaunchOptions.fakeMic, hardwareAvailable: !LaunchOptions.isSimulator)
  }

  /// The microphone is delivering samples (real or fake).
  public var isLive: Bool { state == .on }

  /// The current record permission (the fake reports granted).
  public var permission: MicPermission {
    if fake { return .granted }
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return .granted
    case .denied: return .denied
    default: return .undetermined
    }
  }

  /// Just-in-time permission on the tap that needs it.
  public func start() async -> MicState {
    guard state != .on, state != .starting else { return state }
    if fake {
      state = .on
      return state
    }
    switch AVAudioApplication.shared.recordPermission {
    case .granted: break
    case .denied:
      state = .denied
      return state
    default:
      state = .starting
      let granted = await AVAudioApplication.requestRecordPermission()
      // `stop()` while the prompt was up cancels the start.
      guard state == .starting else { return state }
      guard granted else {
        state = .denied
        return state
      }
    }
    begin()
    return state
  }

  private func begin() {
    AudioRoute.recording = true
    AudioRoute.apply()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { return fail() }
    sampleRate = format.sampleRate
    input.removeTap(onBus: 0)
    do {
      try Self.installTap(on: input, ring: ring, sampleRate: format.sampleRate, format: format)
      try engine.start()
      state = .on
    } catch {
      input.removeTap(onBus: 0)
      fail()
    }
  }

  /// Built in a nonisolated context so the closure is not MainActor-isolated.
  private nonisolated static func installTap(
    on input: AVAudioInputNode, ring: MicRing, sampleRate: Double, format: AVAudioFormat
  ) throws {
    try input.installAudioTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
      guard case .float(let span) = buffer.channelData(0) else { return }
      span.withUnsafeBufferPointer { ring.write($0, sampleRate: sampleRate) }
    }
  }

  private func fail() {
    AudioRoute.recording = false
    AudioRoute.apply()
    state = .failed
  }

  public func stop() {
    if !fake, state == .on {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      AudioRoute.recording = false
      AudioRoute.apply()
    }
    state = .off
    ring.clear()
  }

  /// Ignore transients for a moment, e.g. while our own haptic click rings through the case.
  public func ignoreOnsets(for seconds: Double) { ring.ignoreOnsets(for: seconds) }

  /// Stops listening because the session went inactive (`AudioRoute.observeInterruptions`'s
  /// `inactive`), remembering to come back on `resume()`.
  public func suspend() {
    guard state == .on else { return }
    suspended = true
    stop()
  }

  /// Restarts after `suspend()` (`AudioRoute.observeInterruptions`'s `resume`).
  public func resume() async {
    guard suspended else { return }
    suspended = false
    _ = await start()
  }

  /// The latest `count` samples and features. Advances the fake room by `dt` when faking.
  public func snapshot(count: Int = 2048, dt: Double) -> MicSnapshot {
    if fake, state == .on { synthesize(dt) }
    return ring.snapshot(count: count, sampleRate: sampleRate)
  }

  /// A hummed G-major chord (196/294/392 Hz) swelling at 0.18 Hz, plus a 50 ms clap every 1.6 s
  /// (MicListener.swift:187-211). Goes through the same ring and analyser as the real mic.
  private func synthesize(_ dt: Double) {
    let rate = 48_000.0
    let n = min(Int(dt * rate), 4096)
    guard n > 0 else { return }
    var buffer = [Float](repeating: 0, count: n)
    for i in 0..<n {
      let t = fakeTime + Double(i) / rate
      let swell = 0.5 + 0.5 * sin(2 * .pi * 0.18 * t)
      var s = 0.22 * swell * (sin(2 * .pi * 196 * t) + 0.6 * sin(2 * .pi * 294 * t + 0.4) + 0.25 * sin(2 * .pi * 392 * t))
      let beat = t.truncatingRemainder(dividingBy: 1.6)
      if beat < 0.05 { s += fakeNoise.bipolar() * 0.7 * exp(-beat * 70) }
      buffer[i] = Float(s)
    }
    fakeTime += Double(n) / rate
    sampleRate = rate
    buffer.withUnsafeBufferPointer { ring.write($0, sampleRate: rate) }
  }
}
#endif
