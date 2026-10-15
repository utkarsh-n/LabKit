import Accelerate
import Foundation

/// The latest microphone window and per-buffer features (MicListener.swift:22-31). Sendable value.
public struct MicSnapshot: Sendable {
  /// The most recent samples, oldest first.
  public var samples: [Float]
  /// RMS of the latest input buffer.
  public var level: Float
  /// RMS below about 150 Hz.
  public var bass: Float
  /// Strength of a transient since the last snapshot (rms / running average, ≤ 12); 0 if none.
  public var onset: Float
  public var sampleRate: Double
  public init(samples: [Float], level: Float, bass: Float, onset: Float, sampleRate: Double = 48_000) {
    self.samples = samples
    self.level = level
    self.bass = bass
    self.onset = onset
    self.sampleRate = sampleRate
  }
  public static let silent = MicSnapshot(samples: [], level: 0, bass: 0, onset: 0)
}

/// Per-buffer level, bass and onset analysis, run on the audio thread under the ring's lock
/// (MicListener.swift:147-171). Constants verbatim.
public struct OnsetAnalyser: Sendable {
  public private(set) var level: Float = 0
  public private(set) var bass: Float = 0
  public private(set) var pendingOnset: Float = 0
  private var lowpass: Float = 0
  private var average: Float = 0
  private var clock = 0.0
  private var lastOnset = -1.0
  private var quietUntil = 0.0
  public var sampleRate: Double
  public init(sampleRate: Double = 48_000) { self.sampleRate = sampleRate }

  public mutating func analyse(_ x: UnsafeBufferPointer<Float>) {
    let n = x.count
    guard n > 0 else { return }
    let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
    var sum: Float = 0
    var bassSum: Float = 0
    for s in x {
      sum += s * s
      lowpass += (s - lowpass) * a
      bassSum += lowpass * lowpass
    }
    let rms = (sum / Float(n)).squareRoot()
    level = rms
    bass = (bassSum / Float(n)).squareRoot()
    let dt = Double(n) / sampleRate
    clock += dt
    if rms > average * 1.9 + 0.004, clock - lastOnset > 0.12, clock > quietUntil {
      pendingOnset = max(pendingOnset, min(rms / max(average, 0.002), 12))
      lastOnset = clock
    }
    average += (rms - average) * Float(min(1, dt / 0.25))
  }

  /// Returns and clears the pending onset.
  public mutating func consumeOnset() -> Float {
    defer { pendingOnset = 0 }
    return pendingOnset
  }

  /// Ignore transients for a moment, e.g. while our own haptic click rings through the case
  /// (GyroModel.swift:653, 812: 0.2 s).
  public mutating func ignoreOnsets(for seconds: Double) { quietUntil = clock + seconds }

  public mutating func reset() {
    level = 0
    bass = 0
    pendingOnset = 0
  }
}

/// Loudness above the room's own background, 0…1 (GyroModel.swift:465-474). Constants verbatim:
/// dB = 20·log10(level·gain); raw = clamp((dB + 55)/45); the floor falls in 0.4 s, rises in 20 s;
/// above = max(0, raw − floor − 0.04)/max(1 − floor, 0.25); attack 30 ms, release 350 ms toward min(above·1.5, 1).
public struct EnvelopeFollower: Sendable {
  public private(set) var floor = 0.0
  public private(set) var value = 0.0
  public private(set) var raw = 0.0
  public init() {}
  @discardableResult
  public mutating func step(level: Double, gain: Double, dt: Double) -> Double {
    let db = 20 * log10(max(level * gain, 1e-6))
    raw = clamped((db + 55) / 45, 0, 1)
    approach(&floor, raw, dt: dt, tau: raw < floor ? 0.4 : 20)
    let above = max(0, raw - floor - 0.04) / max(1 - floor, 0.25)
    approach(&value, min(above * 1.5, 1), dt: dt, tau: above > value ? 0.03 : 0.35)
    return value
  }
  public mutating func reset() {
    floor = 0
    value = 0
  }
}

/// Triggered oscilloscope with phosphor persistence and XY delay embedding (GyroModel.swift:478-510).
public struct ScopeData: Sendable {
  public var trace: [Float] = []
  /// Earlier traces, oldest first (≤ 3).
  public var history: [[Float]] = []
  /// (x(t), x(t + lag)) pairs.
  public var xy: [SIMD2<Float>] = []
  public var active = false
  public init() {}

  public mutating func update(_ s: [Float], gain: Double, window: Int = 1024, points: Int = 192, lag: Int = 48) {
    let n = s.count
    guard n >= window + 900 else { return }
    let g = Float(gain) * 5
    let hysteresis = 0.02 / g
    var start = n - window
    var i = n - window
    while i > n - window - 900, i > 1 {
      if s[i - 1] < -hysteresis, s[i] >= 0 {
        start = i
        break
      }
      i -= 1
    }
    var next = [Float](repeating: 0, count: points)
    for k in 0..<points { next[k] = tanh(s[start + k * window / points] * g) }
    if !trace.isEmpty {
      history.append(trace)
      if history.count > 3 { history.removeFirst() }
    }
    trace = next
    xy.removeAll(keepingCapacity: true)
    for k in 0..<300 {
      let j = n - 700 + k * 2
      xy.append(SIMD2(tanh(s[j] * g), tanh(s[j + lag] * g)))
    }
    active = true
  }
}

/// Log-band spectrum, verbatim from Gyre/Sensors/Spectrum.swift: Hann-windowed 2048-pt real FFT,
/// 48 log bands 45 Hz–15 kHz, level = clamp((10·log10(p) − 8)/46), release τ 0.22 s, peaks τ 0.9 s.
/// Not Sendable (owns an FFTSetup); confine to the engine's actor.
public final class Spectrum {
  public static let size = 2048
  public static let bandCount = 48

  private let setup: FFTSetup
  private var window = [Float](repeating: 0, count: size)
  private var windowed = [Float](repeating: 0, count: size)
  private var real = [Float](repeating: 0, count: size / 2)
  private var imag = [Float](repeating: 0, count: size / 2)
  private var power = [Float](repeating: 0, count: size / 2)
  private var edges: [Int] = []
  public private(set) var bands = [Float](repeating: 0, count: bandCount)
  public private(set) var peaks = [Float](repeating: 0, count: bandCount)

  public init(sampleRate: Double = 48_000, low: Double = 45, high: Double = 15_000) {
    setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    for i in 0...Self.bandCount {
      let f = low * pow(high / low, Double(i) / Double(Self.bandCount))
      edges.append(min(max(Int(f / sampleRate * Double(Self.size)), 1), Self.size / 2 - 1))
    }
  }

  deinit { vDSP_destroy_fftsetup(setup) }

  public func reset() {
    for i in 0..<Self.bandCount {
      bands[i] = 0
      peaks[i] = 0
    }
  }

  /// Mean of bands in a range (Gyre thirds: 0..<10 bass, 10..<30 mid, 30..<48 treble).
  public func mean(_ r: Range<Int>) -> Float { bands[r].reduce(0, +) / Float(r.count) }

  public func update(_ samples: [Float], gain: Float, dt: Float) {
    let n = Self.size
    guard samples.count >= n else { return }
    samples.withUnsafeBufferPointer { s in
      vDSP_vmul(s.baseAddress! + (samples.count - n), 1, window, 1, &windowed, 1, vDSP_Length(n))
    }
    real.withUnsafeMutableBufferPointer { rp in
      imag.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        windowed.withUnsafeBufferPointer { w in
          w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
          }
        }
        vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
        power.withUnsafeMutableBufferPointer { pp in
          vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(n / 2))
        }
      }
    }
    let release = exp(-dt / 0.22)
    let peakRelease = exp(-dt / 0.9)
    let g2 = gain * gain
    for b in 0..<Self.bandCount {
      let a = edges[b]
      let c = max(edges[b + 1], a + 1)
      var sum: Float = 0
      for k in a..<c { sum += power[k] }
      let p = sum / Float(c - a) * g2
      let level = min(max((10 * log10(p + 1e-9) - 8) / 46, 0), 1)
      bands[b] = max(level, bands[b] * release)
      peaks[b] = max(bands[b], peaks[b] * peakRelease)
    }
  }
}

/// Magnetometer flicker ("EMF") and its rate from zero crossings (GyroModel.swift:627-646).
public struct EMFMeter: Sendable {
  public private(set) var emf = 0.0
  public private(set) var hz = 0.0
  private var mean = 0.0
  private var variance = 0.0
  private var lastSign = 0.0
  private var crossings = 0
  private var window = 0.0
  public init() {}
  public mutating func step(fieldMagnitude magnitude: Double, dt: Double) {
    approach(&mean, magnitude, dt: dt, tau: 0.5)
    let deviation = magnitude - mean
    approach(&variance, deviation * deviation, dt: dt, tau: 0.4)
    emf = variance.squareRoot()
    let sign: Double = deviation >= 0 ? 1 : -1
    if sign != lastSign, abs(deviation) > emf * 0.2 {
      crossings += 1
      lastSign = sign
    }
    window += dt
    if window >= 0.5 {
      hz += (Double(crossings) / 2 / window - hz) * 0.4
      crossings = 0
      window = 0
    }
  }
}
