#if os(iOS)
import Foundation
import LabKitCore
import Synchronization

/// A short sound event paired with a haptic of the same semantic class (spectra-lab `detent(kind)`,
/// `labkit-from-orbitals-spectra.md` §6.3). Each partial is a blip whose pitch falls exponentially to
/// 0.6× and whose gain decays exponentially to 10⁻⁴ over its duration (`feedback.js:65-77`).
public struct SonicCue: Sendable, Hashable {
  public enum Wave: Sendable, Hashable { case triangle, sine }

  public struct Partial: Sendable, Hashable {
    public var frequency: Double  // Hz
    public var duration: Double  // s
    public var gain: Double  // linear amplitude
    public var wave: Wave
    public init(_ frequency: Double, duration: Double, gain: Double, wave: Wave = .triangle) {
      self.frequency = frequency
      self.duration = duration
      self.gain = gain
      self.wave = wave
    }
  }

  public var name: String
  public var partials: [Partial]
  /// The haptic twin played with it.
  public var haptic: HapticTap

  public init(_ name: String, _ partials: [Partial], haptic: HapticTap) {
    self.name = name
    self.partials = partials
    self.haptic = haptic
  }

  /// The lowest partial, Hz.
  public var fundamental: Double { partials.map(\.frequency).min() ?? 0 }

  /// A quantised dial step: 2200 Hz triangle, 12 ms, 0.025 (keep ≥ 45 ms apart).
  public static let tick = SonicCue("tick", [Partial(2200, duration: 0.012, gain: 0.025)], haptic: .tick)
  /// A labelled detent or band edge: 1400 Hz triangle, 35 ms, 0.08.
  public static let detent = SonicCue("detent", [Partial(1400, duration: 0.035, gain: 0.08)], haptic: .detent)
  /// A hard physical threshold: 95 Hz sine 160 ms 0.22 + 1800 Hz 30 ms 0.07. On the phone speaker
  /// the 1800 Hz click is the audible part (the speaker reproduces little below ~200–300 Hz; inferred).
  public static let threshold = SonicCue(
    "threshold",
    [Partial(95, duration: 0.16, gain: 0.22, wave: .sine), Partial(1800, duration: 0.03, gain: 0.07)],
    haptic: .boundary)
  /// Crossing a resonance: 220 Hz sine, 250 ms, 0.12.
  public static let resonance = SonicCue(
    "resonance", [Partial(220, duration: 0.25, gain: 0.12, wave: .sine)], haptic: .poke)
  /// Any button: 900 Hz triangle, 30 ms, 0.05.
  public static let action = SonicCue("action", [Partial(900, duration: 0.03, gain: 0.05)], haptic: .tap)

  /// spectra-lab's values as the default set; apps may retune them.
  public static let standard: [SonicCue] = [tick, detent, threshold, resonance, action]
}

/// Single-producer (main actor), single-consumer (render thread) trigger ring. Lock-free: a slot
/// is written, then the counter is published with release ordering; the render thread reads the
/// counter with acquire ordering. If more than 16 cues pile up between two render calls the oldest
/// are dropped, which is harmless for cues.
final class CueQueue: Sendable {
  static let capacity = 16
  private let slots: InlineArray<16, Atomic<UInt64>>
  private let written = Atomic<Int>(0)

  init() { slots = InlineArray { _ in Atomic(0) } }

  func push(index: Int, partialMask: UInt8, gain: Float) {
    let w = written.load(ordering: .relaxed)
    let packed = UInt64(UInt16(truncatingIfNeeded: index)) | UInt64(partialMask) << 16 | UInt64(gain.bitPattern) << 32
    slots[w & (Self.capacity - 1)].store(packed, ordering: .relaxed)
    written.store(w + 1, ordering: .releasing)
  }

  /// Calls `body(index, mask, gain)` for every trigger after `read`, and advances `read`.
  func drain(_ read: inout Int, _ body: (Int, UInt8, Float) -> Void) {
    let w = written.load(ordering: .acquiring)
    if w - read > Self.capacity { read = w - Self.capacity }
    while read < w {
      let packed = slots[read & (Self.capacity - 1)].load(ordering: .relaxed)
      body(Int(packed & 0xFFFF), UInt8(truncatingIfNeeded: packed >> 16), Float(bitPattern: UInt32(truncatingIfNeeded: packed >> 32)))
      read += 1
    }
  }
}

/// Render-thread state: the bed gain smoother and up to 12 cue voices. Everything lives in
/// buffers allocated at init, so `finish` neither allocates nor retains on the audio thread.
/// Touched only from the render block (serial), hence `@unchecked Sendable`.
final class CueVoices: @unchecked Sendable {
  struct PartialRT {
    var frequency: Double
    var duration: Double
    var gain: Double
    var sine: Bool
  }
  struct Voice {
    var active = false
    var phase = 0.0  // cycles
    var frequency = 0.0
    var frequencyDecay = 1.0
    var amplitude = 0.0
    var amplitudeDecay = 1.0
    var remaining = 0
    var sine = false
  }

  static let voiceCount = 12
  private let partials: UnsafeMutablePointer<PartialRT>
  private let starts: UnsafeMutablePointer<Int>
  private let counts: UnsafeMutablePointer<Int>
  private let cueCount: Int
  private let voices: UnsafeMutablePointer<Voice>
  private var fs = 48_000.0
  private var smooth = 0.0
  private var bed: Float = 1
  private var read = 0
  private var nextVoice = 0

  init(table: [SonicCue]) {
    let flat = table.flatMap { cue in
      cue.partials.prefix(8).map { PartialRT(frequency: $0.frequency, duration: $0.duration, gain: $0.gain, sine: $0.wave == .sine) }
    }
    partials = .allocate(capacity: max(flat.count, 1))
    partials.initialize(from: flat, count: flat.count)
    cueCount = table.count
    starts = .allocate(capacity: max(table.count, 1))
    counts = .allocate(capacity: max(table.count, 1))
    var offset = 0
    for (i, cue) in table.enumerated() {
      let n = min(cue.partials.count, 8)
      (starts + i).initialize(to: offset)
      (counts + i).initialize(to: n)
      offset += n
    }
    voices = .allocate(capacity: Self.voiceCount)
    voices.initialize(repeating: Voice(), count: Self.voiceCount)
  }

  deinit {
    partials.deallocate()
    starts.deallocate()
    counts.deallocate()
    voices.deallocate()
  }

  func prepare(sampleRate: Double) {
    fs = sampleRate
    smooth = SynthDSP.smoothing(tau: 0.03, sampleRate: sampleRate)
  }

  private func trigger(index: Int, mask: UInt8, gain: Float) {
    guard index >= 0, index < cueCount else { return }
    for k in 0..<counts[index] where mask & (1 << UInt8(k)) != 0 {
      let p = partials[starts[index] + k]
      let n = max(1, Int(p.duration * fs))
      let start = max(p.gain * Double(gain), 1e-4)
      voices[nextVoice] = Voice(
        active: true, phase: 0, frequency: p.frequency, frequencyDecay: pow(0.6, 1 / Double(n)),
        amplitude: start, amplitudeDecay: pow(1e-4 / start, 1 / Double(n)), remaining: n, sine: p.sine)
      nextVoice = (nextVoice + 1) % Self.voiceCount
    }
  }

  /// Scales the bed already in `left`/`right` by the smoothed bed gain, then adds the cues.
  func finish(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, bedGain: Float, cueGain: Float,
    queue: CueQueue
  ) {
    let k = Float(smooth)
    for i in 0..<frames {
      bed += (bedGain - bed) * k
      left[i] *= bed
      right[i] *= bed
    }
    queue.drain(&read) { index, mask, gain in trigger(index: index, mask: mask, gain: gain) }
    for v in 0..<Self.voiceCount where voices[v].active {
      var voice = voices[v]
      let n = min(frames, voice.remaining)
      for i in 0..<n {
        let p = voice.phase - voice.phase.rounded(.down)
        // Both waves start at 0 and rise, so a blip never begins with a click.
        let q = p + 0.75 - (p + 0.75).rounded(.down)
        let w = voice.sine ? sin(2 * Double.pi * p) : 4 * abs(q - 0.5) - 1
        let s = Float(w * voice.amplitude) * cueGain
        left[i] += s
        right[i] += s
        voice.phase += voice.frequency / fs
        voice.frequency *= voice.frequencyDecay
        voice.amplitude *= voice.amplitudeDecay
      }
      voice.remaining -= n
      if voice.remaining <= 0 { voice.active = false }
      voices[v] = voice
    }
  }
}
#endif
