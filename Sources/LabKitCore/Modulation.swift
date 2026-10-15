import Foundation

// The generic form of Gyre's Listen (depth) + Drives (rotary switch) pair (GyroModel.swift:376-405):
// conditioned sensor signals ("sources") are routed through curves, depth and smoothing to
// parameters or to named channels/triggers that the app's engine reads.

public struct ModSourceID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public var description: String { rawValue }
}

extension ModSourceID {
  /// Loudness above the room's own floor, 0…1 (Gyre `envelope`, GyroModel.swift:465-474).
  public static let micEnvelope: ModSourceID = "mic.envelope"
  /// Raw level, (dB + 55)/45 clamped 0…1.
  public static let micLevel: ModSourceID = "mic.level"
  /// RMS below ~150 Hz × gain (MicListener.swift:150-163).
  public static let micBass: ModSourceID = "mic.bass"
  /// Impulse: onset strength 0…12 on the frame it fires, else 0 (MicListener.swift:166-169).
  public static let micOnset: ModSourceID = "mic.onset"
  /// Spectrum thirds 0…1 (GyroModel.swift:522-524: bands 0..<10, 10..<30, 30..<48).
  public static let micLow: ModSourceID = "mic.low"
  public static let micMid: ModSourceID = "mic.mid"
  public static let micHigh: ModSourceID = "mic.high"
  /// |userAcceleration| in g (Telemetry.shakeG).
  public static let shake: ModSourceID = "motion.shake"
  /// |d(userAcceleration)/dt| in g/s, smoothed τ 0.05 s; impulse-like.
  public static let jerk: ModSourceID = "motion.jerk"
  /// |rotationRate| rad/s.
  public static let turn: ModSourceID = "motion.turn"
  /// Angle of the screen normal from vertical / π, 0…1.
  public static let tilt: ModSourceID = "motion.tilt"
  /// |B| µT (calibrated device-motion field).
  public static let field: ModSourceID = "mag.field"
  /// |B| − slow baseline (τ 8 s), µT: "a magnet is approaching".
  public static let fieldDelta: ModSourceID = "mag.delta"
  /// | |B| − its 0.5 s mean |, µT: a magnetometer step (a cause for the Feel hum when > 5 µT).
  public static let fieldStep: ModSourceID = "mag.step"
  /// RMS flicker of |B| about its 0.5 s mean, µT (GyroModel.swift:627-646).
  public static let emf: ModSourceID = "mag.emf"
  /// Barometer pressure / 101.325 kPa (1 at sea level).
  public static let pressure: ModSourceID = "baro.ratio"
  /// ProcessInfo.thermalState: nominal 0, fair 1/3, serious 2/3, critical 1.
  public static let thermal: ModSourceID = "device.thermal"
  public static let lfo1: ModSourceID = "lfo.1"
  public static let lfo2: ModSourceID = "lfo.2"
  /// Finger speed on the canvas, points/s ÷ 1000.
  public static let touchSpeed: ModSourceID = "touch.speed"
  /// Finger down 1 / up 0 (or force if available).
  public static let touchDown: ModSourceID = "touch.down"
  /// Finger position across the canvas, 0 (left) … 1 (right).
  public static let touchX: ModSourceID = "touch.x"
  /// Finger position up the canvas, 0 (bottom) … 1 (top).
  public static let touchY: ModSourceID = "touch.y"
  /// Normalised touch force 0…1 where the hardware reports it, else 1 while down.
  public static let touchForce: ModSourceID = "touch.force"

  /// Every source LabKit's `SourceConditioner` fills, in display order.
  public static let all: [ModSourceID] = [
    .micEnvelope, .micLevel, .micBass, .micOnset, .micLow, .micMid, .micHigh, .shake, .jerk, .turn, .tilt,
    .field, .fieldDelta, .fieldStep, .emf, .pressure, .thermal, .lfo1, .lfo2, .touchSpeed, .touchDown,
    .touchX, .touchY, .touchForce,
  ]

  /// Sources that are impulses (non-zero for one frame), so a route on them should be a trigger.
  public var isImpulse: Bool { self == .micOnset }
}

/// One frame of conditioned source values. Continuous sources hold; impulses last one frame.
public struct ModSources: Sendable {
  public var values: [ModSourceID: Double] = [:]
  public init() {}
  public subscript(id: ModSourceID) -> Double {
    get { values[id] ?? 0 }
    set { values[id] = newValue }
  }
}

public enum ModCurve: Sendable, Hashable {
  case linear
  /// x^γ (γ < 1 boosts quiet input).
  case power(Double)
  case smooth
  /// (e^(k·x) − 1)/(e^k − 1)
  case exponential(Double)
  /// 0 below the threshold, then rescaled 0…1.
  case gate(Double)
  case invert
  /// Divide first: x / full, clamped 0…1 (normalise a physical unit, e.g. µT/100).
  case normalize(Double)

  public func apply(_ x: Double) -> Double {
    switch self {
    case .linear: return x
    case .power(let g): return pow(max(x, 0), g)
    case .smooth: return smoothstep(0.0, 1.0, x)
    case .exponential(let k): return abs(k) < 1e-6 ? x : (exp(k * x) - 1) / (exp(k) - 1)
    case .gate(let t): return x <= t ? 0 : (x - t) / max(1 - t, 1e-6)
    case .invert: return 1 - x
    case .normalize(let full): return clamped(x / max(full, 1e-12), 0, 1)
    }
  }
}

/// How a route's output x = depth·curve(source) lands on its target.
public enum ModMode: Sendable, Hashable {
  /// target += scale·x (Gyre Gravity drive: `p.gravity += depth·m·2`).
  case add(Double)
  /// target ×= 1 + scale·x (Gyre Air drive: `p.air *= 1 + 3·depth·m`).
  case multiply(Double)
  /// target += x·(upper − lower) of the target's range.
  case rangeFraction
  /// Fires a trigger when the (unsmoothed) source crosses `threshold`, strength = x (Gyre Kicks).
  case trigger(threshold: Double)
}

/// A route is active only while a rotary switch sits on `index` (Gyre's Drives knob).
public struct ModGate: Sendable, Hashable {
  public var param: ParamID
  public var index: Int
  public init(_ param: ParamID, _ index: Int) {
    self.param = param
    self.index = index
  }
}

public struct ModRoute: Sendable, Identifiable {
  public var id: String
  public var source: ModSourceID
  /// A registered ParamID is modulated in the frame's ParamValues; any other id is a channel.
  public var target: ParamID
  public var depth: Double
  /// Multiplies `depth` by a knob value (Gyre's Listen knob).
  public var depthParam: ParamID?
  public var gate: ModGate?
  public var curve: ModCurve
  public var mode: ModMode
  /// Per-route smoothing, seconds (0 = none). Gyre smooths in the envelope instead: 0.03 / 0.35.
  public var attack: Double
  public var release: Double
  /// Clamp the modulated value to the spec's range (Gyre doesn't: gravity can reach 5 g).
  public var clampToRange: Bool
  public var enabled: Bool

  public init(
    _ id: String, source: ModSourceID, target: ParamID, depth: Double = 1, depthParam: ParamID? = nil,
    gate: ModGate? = nil, curve: ModCurve = .linear, mode: ModMode = .add(1),
    attack: Double = 0, release: Double = 0, clampToRange: Bool = false, enabled: Bool = true
  ) {
    self.id = id
    self.source = source
    self.target = target
    self.depth = depth
    self.depthParam = depthParam
    self.gate = gate
    self.curve = curve
    self.mode = mode
    self.attack = attack
    self.release = release
    self.clampToRange = clampToRange
    self.enabled = enabled
  }
}

public struct ModTrigger: Sendable, Hashable {
  public var route: String
  public var target: ParamID
  public var strength: Double
}

/// Channel values and triggers produced this frame for non-parameter targets.
public struct ModOutputs: Sendable {
  public var channels: [ParamID: Double] = [:]
  public var triggers: [ModTrigger] = []
  /// Each live route's contribution this frame, depth·curve(source) after smoothing (for meters).
  /// Gated-off, held and disabled routes are absent.
  public var levels: [String: Double] = [:]
  public init() {}
  public subscript(channel: ParamID) -> Double { channels[channel] ?? 0 }
  public func fired(_ target: ParamID) -> ModTrigger? { triggers.first { $0.target == target } }
}

public struct ModulationRouter: Sendable {
  public var routes: [ModRoute]
  private var followers: [String: AttackRelease] = [:]
  private var armed: [String: Bool] = [:]

  public init(_ routes: [ModRoute] = []) { self.routes = routes }

  /// Forgets smoothing and trigger state (e.g. after an experiment preset is applied).
  public mutating func reset() {
    followers.removeAll()
    armed.removeAll()
  }

  /// Modulates `params` in place (a per-frame copy, never the store) and returns channels/triggers.
  /// `holding` lists parameters the user is touching right now: routes onto them are skipped, so a
  /// knob always wins over its drive (house rule 13). Depth 0 also disables a route.
  public mutating func apply(
    _ sources: ModSources, to params: inout ParamValues, specs: [ParamID: ParamSpec], dt: Double,
    holding: Set<ParamID> = []
  ) -> ModOutputs {
    var out = ModOutputs()
    for r in routes where r.enabled {
      if let g = r.gate, Int(params[g.param].rounded()) != g.index {
        followers[r.id]?.reset()
        continue
      }
      if holding.contains(r.target) {
        followers[r.id]?.reset()
        continue
      }
      let depth = r.depth * (r.depthParam.map { params[$0] } ?? 1)
      let raw = sources[r.source]
      if case .trigger(let threshold) = r.mode {
        let above = raw > threshold
        if above, armed[r.id] ?? true, depth > 0.01 {
          let strength = depth * r.curve.apply(raw)
          out.triggers.append(ModTrigger(route: r.id, target: r.target, strength: strength))
          out.levels[r.id] = strength
        }
        armed[r.id] = !above
        continue
      }
      var shaped = r.curve.apply(raw)
      if r.attack > 0 || r.release > 0 {
        var f = followers[r.id] ?? AttackRelease(attack: r.attack, release: r.release)
        shaped = f.step(shaped, dt: dt)
        followers[r.id] = f
      }
      let x = depth * shaped
      out.levels[r.id] = x
      if let spec = specs[r.target] {
        var v = params[r.target]
        switch r.mode {
        case .add(let k): v += k * x
        case .multiply(let k): v *= 1 + k * x
        case .rangeFraction: v += x * (spec.range.upperBound - spec.range.lowerBound)
        case .trigger: break
        }
        params[r.target] = r.clampToRange ? spec.clamp(v) : v
      } else {
        switch r.mode {
        case .add(let k): out.channels[r.target, default: 0] += k * x
        case .multiply(let k): out.channels[r.target, default: 1] *= 1 + k * x
        case .rangeFraction: out.channels[r.target, default: 0] += x
        case .trigger: break
        }
      }
    }
    return out
  }
}

/// Low-frequency oscillator source.
public struct LFO: Sendable {
  public enum Shape: Sendable { case sine, triangle, square, sampleAndHold, saw }
  public var rateHz: Double
  public var shape: Shape
  public private(set) var phase: Double
  private var held = 0.0
  private var rng = XorShift32(seed: 0xC0FFEE)
  public init(rateHz: Double, shape: Shape = .sine, phase: Double = 0) {
    self.rateHz = rateHz
    self.shape = shape
    self.phase = phase
  }
  /// Unipolar 0…1.
  public mutating func step(dt: Double) -> Double {
    let before = phase
    phase = (phase + rateHz * dt).truncatingRemainder(dividingBy: 1)
    switch shape {
    case .sine: return 0.5 + 0.5 * sin(2 * .pi * phase)
    case .triangle: return 1 - abs(2 * phase - 1)
    case .square: return phase < 0.5 ? 1 : 0
    case .saw: return phase
    case .sampleAndHold:
      if phase < before { held = Double(rng.unit()) }
      return held
    }
  }
}
