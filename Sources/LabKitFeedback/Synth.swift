#if os(iOS)
import AVFoundation
import Foundation
import LabKitCore
import Synchronization

/// Up to 16 control values written by the main actor every frame and read per sample on the
/// render thread. Gyre used plain Doubles with no lock ("a torn read can't happen on arm64",
/// HumSynth.swift:9-21); under Swift 6 that is a data race, so each slot is an `Atomic<UInt64>`
/// holding the Double's bit pattern with relaxed ordering (a plain load/store on arm64).
public final class SynthControls: Sendable {
  public static let capacity = 16
  private let slots: InlineArray<16, Atomic<UInt64>>

  public init() { slots = InlineArray { _ in Atomic(0) } }

  public subscript(slot: Int) -> Double {
    get { Double(bitPattern: slots[slot].load(ordering: .relaxed)) }
  }

  public func set(_ slot: Int, _ value: Double) {
    slots[slot].store(value.bitPattern, ordering: .relaxed)
  }
}

/// A voice rendered on the audio thread. Its stored DSP state is touched only by `render`,
/// which the audio engine calls serially, hence `@unchecked Sendable` on conformers.
public protocol SynthKernel: AnyObject, Sendable {
  func prepare(sampleRate: Double)
  /// Fill `frames` samples of stereo into deinterleaved `left`/`right` (overwrite, don't add).
  func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, controls: SynthControls)
}

/// A bed that renders silence: for apps that want cues but no continuous voice.
public final class SilentKernel: SynthKernel, @unchecked Sendable {
  public init() {}
  public func prepare(sampleRate: Double) {}
  public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, controls: SynthControls) {
    left.update(repeating: 0, count: frames)
    right.update(repeating: 0, count: frames)
  }
}

/// DSP helpers (HumSynth.swift:78-121).
public enum SynthDSP {
  /// Per-sample one-pole coefficient for a time constant τ (Gyre: τ = 30 ms for every control).
  @inlinable public static func smoothing(tau: Double, sampleRate: Double) -> Double { 1 - exp(-1 / (tau * sampleRate)) }
  /// Equal-power pan, pan −1…1 → (L, R) gains: angle = (pan + 1)·π/4, ×1.414.
  @inlinable public static func pan(_ p: Double) -> (Double, Double) {
    let a = (p + 1) * Double.pi / 4
    return (cos(a) * 1.414, sin(a) * 1.414)
  }
}

/// Host-level gains, written by the main actor and read by the render block.
final class SynthHostGains: Sendable {
  let bed = Atomic<UInt32>(Float(1).bitPattern)
  let cues = Atomic<UInt32>(Float(1).bitPattern)
  var bedGain: Float { Float(bitPattern: bed.load(ordering: .relaxed)) }
  var cueGain: Float { Float(bitPattern: cues.load(ordering: .relaxed)) }
}

/// Owns AVAudioEngine + one AVAudioSourceNode and restarts on configuration changes
/// (HumSynth.swift:40-134). After a media-services reset (mediaserverd restarted) the old engine and node are dead
/// objects: the host drops them, builds a fresh engine and node, and restarts if the app wants sound (LK-FIX). The node renders the app's bed kernel, multiplies it by `bedGain`
/// (smoothed per sample, τ 30 ms), then mixes in any `SonicCue`s queued with `play(_:)`.
/// The render block is built in a `nonisolated static` factory: built inside a @MainActor method
/// it would be MainActor-inferred and carry a `swift_task_isCurrentExecutor` check that traps on
/// the audio thread (verified in SIL; `toolchain-checks.md` §1 finding 6).
@MainActor
public final class SynthHost {
  public let controls = SynthControls()
  public let kernel: any SynthKernel
  /// The cue table this host can play (fixed at init; the render thread reads it without locks).
  public let cues: [SonicCue]
  private var engine = AVAudioEngine()
  private var node: AVAudioSourceNode?
  public private(set) var running = false
  /// Whether the app wants sound (`start()` since the last `stop()`), so a rebuilt engine knows to restart.
  private var wanted = false
  /// Engines built after media-services resets (0 until one happens).
  public private(set) var rebuilds = 0
  private var observer: NSObjectProtocol?
  private var resetObserver: NSObjectProtocol?
  private let gains = SynthHostGains()
  private let queue = CueQueue()
  private let voices: CueVoices
  public var masterVolume: Float = 0.9 {
    didSet { engine.mainMixerNode.outputVolume = masterVolume }
  }

  /// Gain on the bed kernel, 0…1 (ducking, silence rules, activity). Smoothed on the audio thread.
  public var bedGain: Float {
    get { gains.bedGain }
    set { gains.bed.store(clamped(newValue, 0, 1).bitPattern, ordering: .relaxed) }
  }

  /// Gain on cues, 0…1.
  public var cueGain: Float {
    get { gains.cueGain }
    set { gains.cues.store(clamped(newValue, 0, 1).bitPattern, ordering: .relaxed) }
  }

  public init(kernel: any SynthKernel, cues: [SonicCue] = SonicCue.standard) {
    self.kernel = kernel
    self.cues = cues
    voices = CueVoices(table: cues)
    resetObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
    ) { @Sendable [weak self] _ in
      MainActor.assumeIsolated { self?.rebuildAfterMediaReset() }
    }
  }

  isolated deinit {
    // Block-based observers stay registered until removed, even with a weak capture.
    if let observer { NotificationCenter.default.removeObserver(observer) }
    if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    engine.stop()
  }

  /// Media services were reset: every AVAudioEngine and node made before is dead. Drops them, builds a fresh engine
  /// (its node is built on the next `start()`), and starts it again if the app wanted sound. Called by the host's own
  /// `mediaServicesWereResetNotification` observer; safe to call again from the app's reset handler.
  public func rebuildAfterMediaReset() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    engine.stop()
    engine = AVAudioEngine()
    node = nil
    running = false
    rebuilds += 1
    AudioRoute.forgetApplied()
    if wanted { start() }
  }

  public func start() {
    wanted = true
    guard !running else { return }
    AudioRoute.apply()
    if node == nil { build() }
    do {
      try engine.start()
      running = true
    } catch {
      running = false
    }
    if observer == nil {
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { @Sendable [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.running else { return }
          self.running = false
          self.start()
        }
      }
    }
  }

  public func stop() {
    wanted = false
    engine.pause()
    running = false
  }

  /// Queues a cue (lock-free; at most 16 waiting). Returns false if it is not in `cues`, the host
  /// is stopped, or `allowed` rejects every partial (e.g. `SoundPolicy.allowsPartial`).
  @discardableResult
  public func play(_ cue: SonicCue, gain: Float = 1, allowed: (Double) -> Bool = { _ in true }) -> Bool {
    guard running, let index = cues.firstIndex(of: cue) else { return false }
    var mask: UInt8 = 0
    for (i, p) in cue.partials.prefix(8).enumerated() where allowed(p.frequency) { mask |= 1 << UInt8(i) }
    guard mask != 0 else { return false }
    queue.push(index: index, partialMask: mask, gain: clamped(gain, 0, 4))
    return true
  }

  private func build() {
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    let sampleRate = rate > 0 ? rate : 48_000
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
    kernel.prepare(sampleRate: sampleRate)
    voices.prepare(sampleRate: sampleRate)
    let source = Self.makeNode(format: format, kernel: kernel, controls: controls, gains: gains, queue: queue, voices: voices)
    engine.attach(source)
    do {
      // iOS 27: connect(_:to:format:) is deprecated (AVAudioEngine.h:281); this is its replacement (:295).
      try engine.connectNode(source, to: engine.mainMixerNode, format: format)
    } catch {
      engine.detach(source)
      return
    }
    engine.mainMixerNode.outputVolume = masterVolume
    node = source
  }

  private nonisolated static func makeNode(
    format: AVAudioFormat, kernel: any SynthKernel, controls: SynthControls, gains: SynthHostGains,
    queue: CueQueue, voices: CueVoices
  ) -> AVAudioSourceNode {
    AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(abl)
      guard buffers.count >= 2,
        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
        let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
      else { return noErr }
      let n = Int(frameCount)
      kernel.render(frames: n, left: left, right: right, controls: controls)
      voices.finish(frames: n, left: left, right: right, bedGain: gains.bedGain, cueGain: gains.cueGain, queue: queue)
      return noErr
    }
  }
}

/// Gyre's rotor hum as a kernel (HumSynth.swift:85-122), constants verbatim.
public final class RotorHumKernel: SynthKernel, @unchecked Sendable {
  public enum Slot {
    public static let rotorHz = 0, level = 1, pan = 2, hiss = 3, whoosh = 4, wobble = 5, wobbleHz = 6, vibrato = 7
  }
  private var fs = 48_000.0
  private var smooth = 0.0
  private var phaseR = 0.0, phaseW = 0.0, phaseV = 0.0
  private var rotorHz = 0.0, level = 0.0, pan = 0.0, hiss = 0.0, whoosh = 0.0, wobble = 0.0, vibrato = 0.0
  private var low = 0.0, band1 = 0.0, band2 = 0.0
  private var noise = XorShift32(seed: 22222)

  public init() {}

  public func prepare(sampleRate: Double) {
    fs = sampleRate
    smooth = SynthDSP.smoothing(tau: 0.03, sampleRate: sampleRate)
  }

  public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, controls c: SynthControls) {
    let twoPi = 2 * Double.pi
    let wobbleHz = c[Slot.wobbleHz]
    for i in 0..<frames {
      rotorHz += (c[Slot.rotorHz] - rotorHz) * smooth
      level += (c[Slot.level] - level) * smooth
      pan += (c[Slot.pan] - pan) * smooth
      hiss += (c[Slot.hiss] - hiss) * smooth
      whoosh += (c[Slot.whoosh] - whoosh) * smooth
      wobble += (c[Slot.wobble] - wobble) * smooth
      vibrato += (c[Slot.vibrato] - vibrato) * smooth
      phaseV += twoPi * 5.5 / fs
      if phaseV > twoPi { phaseV -= twoPi }
      phaseR += twoPi * rotorHz * (1 + vibrato * sin(phaseV)) / fs
      if phaseR > twoPi * 1000 { phaseR -= twoPi * 1000 }
      phaseW += twoPi * wobbleHz / fs
      if phaseW > twoPi { phaseW -= twoPi }
      let blade = 6 * phaseR
      var tone = sin(blade) * 0.55 + sin(2 * blade + 0.3) * 0.17 + sin(3 * blade + 1.1) * 0.06
      tone += sin(phaseR) * 0.3 + sin(2 * phaseR) * 0.12
      let am = 1 + wobble * sin(phaseW)
      let white = noise.bipolar()
      low += (white - low) * 0.02
      let k = min(0.5, 0.01 + rotorHz * 0.0009)
      band1 += (white - band1) * k
      band2 += (band1 - band2) * k
      let air = band1 - band2
      let s = (tone * level * am + low * hiss * 2.5 + air * whoosh * 1.6) * 0.2
      let (gl, gr) = SynthDSP.pan(pan)
      left[i] = Float(s * gl)
      right[i] = Float(s * gr)
    }
  }
}
#endif
