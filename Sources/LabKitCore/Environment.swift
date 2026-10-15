import Foundation
import simd

/// One reading of the phone's motion sensors (MotionSource.swift:6-35), framework-free so the
/// environment and the Mac harness can use it.
public struct MotionSample: Sendable, Equatable {
  /// Rotates phone-frame vectors into the world frame (Z up).
  public var attitude: simd_quatd
  /// Gyroscope, bias-corrected, phone frame, rad/s.
  public var rotationRate: V3
  /// Phone frame, g.
  public var gravity: V3
  /// Accelerometer minus gravity, phone frame, g.
  public var userAcceleration: V3
  /// Calibrated magnetometer, phone frame, µT.
  public var magneticField: V3
  public var fieldCalibrated: Bool
  /// Seconds (CMLogItem.timestamp when live) — lets apps measure the real sensor rate.
  public var timestamp: Double

  public init(
    attitude: simd_quatd, rotationRate: V3, gravity: V3, userAcceleration: V3, magneticField: V3,
    fieldCalibrated: Bool, timestamp: Double = 0
  ) {
    self.attitude = attitude
    self.rotationRate = rotationRate
    self.gravity = gravity
    self.userAcceleration = userAcceleration
    self.magneticField = magneticField
    self.fieldCalibrated = fieldCalibrated
    self.timestamp = timestamp
  }

  public static func pose(pitch: Double, yaw: Double = 0, roll: Double = 0) -> simd_quatd {
    simd_quatd(angle: yaw, axis: V3(0, 0, 1)) * simd_quatd(angle: pitch, axis: V3(1, 0, 0))
      * simd_quatd(angle: roll, axis: V3(0, 1, 0))
  }

  /// A magnetic field like the northern hemisphere's, µT, world frame (MotionSource.swift:25).
  public static let simulatedField = V3(0, 22, -40)

  public static func at(_ q: simd_quatd, rate: V3 = .zero, field: V3 = simulatedField) -> MotionSample {
    MotionSample(
      attitude: q, rotationRate: rate, gravity: q.inverse.act(V3(0, 0, -1)),
      userAcceleration: .zero, magneticField: q.inverse.act(field), fieldCalibrated: true)
  }

  /// Held upright, leaning back 30° (pitch 60°), as you'd hold it to look at the screen.
  public static let resting = at(pose(pitch: 60 * .pi / 180))
}

public enum Gravity {
  public static let g0 = 9.80665
  /// Gravity knob detents (Knobs.swift:125-128), in g.
  public static let detents: [Detent] = [
    Detent(-1, "Inverted"), Detent(0, "Zero-g"), Detent(0.166, "Moon"), Detent(0.38, "Mars"),
    Detent(1, "Earth"), Detent(2.53, "Jupiter"),
  ]
}

public enum Atmosphere {
  public static let seaLevelKPa = 101.325
  /// Air knob detents (Knobs.swift:158).
  public static let detents: [Detent] = [Detent(0, "Vacuum"), Detent(1, "Sea level")]
}

/// Sensor-derived surroundings for one physics step (generalises GyroEnvironment, GyroSim.swift:17-23).
public struct LabEnvironment: Sendable {
  /// Phone (or AR bubble) frame → world (Z up).
  public var attitude = simd_quatd.identity
  /// Effective gravity in the world frame, m/s²: (0, 0, −g0·scale) − linear acceleration (GyroSim.swift:110).
  public var gravityWorld = V3(0, 0, -Gravity.g0)
  /// Phone's angular velocity, world frame, rad/s (real time).
  public var deviceRate = V3.zero
  /// Phone's acceleration minus gravity, world frame, m/s².
  public var linearAccel = V3.zero
  /// Magnetic field, world frame, tesla.
  public var magneticField = V3.zero
  public var pressureKPa: Double?
  /// Density relative to sea level (Air knob × barometer ratio).
  public var airDensity = 1.0
  /// Rheo adds a Temperature knob; Gyre has none.
  public var temperatureK = 293.15
  public var timeScale = 1.0
  /// Gravity alone (scaled by the Gravity knob), world frame, m/s², without the phone's own acceleration.
  public var staticGravityWorld = V3(0, 0, -Gravity.g0)
  public init() {}

  /// Gravity in the phone frame, m/s² (+x right, +y toward the top of the phone, +z out of the screen).
  public var gravityDevice: V3 { attitude.inverse.act(gravityWorld) }
  /// In-plane gravity for a 2D tank drawn on the screen (x right, y up), m/s². Includes the phone's
  /// own acceleration (a shake), as Gyre's effective gravity does.
  public var screenGravity: SIMD2<Double> {
    let g = gravityDevice
    return SIMD2(g.x, g.y)
  }

  /// In-plane gravity alone (× the Gravity knob), m/s², without the shake. Use this with
  /// `screenAcceleration` when a solver takes the frame acceleration separately (Rheo's MPM input),
  /// so a shake is not counted twice.
  public var screenGravityOnly: SIMD2<Double> {
    let g = attitude.inverse.act(staticGravityWorld)
    return SIMD2(g.x, g.y)
  }

  /// The phone's own in-plane acceleration (x right, y up), m/s²: the tank's frame acceleration.
  /// Contents feel −a.
  public var screenAcceleration: SIMD2<Double> {
    let a = attitude.inverse.act(linearAccel)
    return SIMD2(a.x, a.y)
  }

  /// Gravity along the screen normal (+ out of the screen), m/s²: how flat the phone lies.
  public var screenNormalGravity: Double { attitude.inverse.act(staticGravityWorld).z }

  /// |B| in microtesla.
  public var fieldMicroTesla: Double { simd_length(magneticField) * 1e6 }

  /// Builds the frame's environment the way GyroModel.advance does (GyroModel.swift:414-418).
  public static func from(
    _ s: MotionSample, gravityScale: Double, air: Double = 1, pressureKPa: Double? = nil,
    useBarometer: Bool = false, temperatureK: Double = 293.15, timeScale: Double = 1
  ) -> LabEnvironment {
    var e = LabEnvironment()
    let a = s.attitude
    e.attitude = a
    e.deviceRate = a.act(s.rotationRate)
    e.linearAccel = a.act(s.userAcceleration) * Gravity.g0
    e.magneticField = a.act(s.magneticField) * 1e-6
    e.staticGravityWorld = V3(0, 0, -Gravity.g0 * gravityScale)
    e.gravityWorld = e.staticGravityWorld - e.linearAccel
    e.pressureKPa = pressureKPa
    let ratio = useBarometer ? (pressureKPa ?? Atmosphere.seaLevelKPa) / Atmosphere.seaLevelKPa : 1
    e.airDensity = air * ratio
    e.temperatureK = temperatureK
    e.timeScale = timeScale
    return e
  }
}

/// One frame of finger input on the canvas, filled by the app from `CanvasRegion(onTouch:)`.
public struct TouchSample: Sendable, Equatable {
  public var down: Bool
  /// Position in the canvas, normalised: x 0 (left) … 1 (right), y 0 (bottom) … 1 (top).
  public var position: SIMD2<Double>
  /// Finger speed, points per second.
  public var speed: Double
  /// Normalised force 0…1 if the hardware reports it, else nil.
  public var force: Double?
  public init(down: Bool, position: SIMD2<Double> = SIMD2(0.5, 0.5), speed: Double = 0, force: Double? = nil) {
    self.down = down
    self.position = position
    self.speed = speed
    self.force = force
  }
  public static let up = TouchSample(down: false)
}

/// Turns raw sensor readings into normalised modulation sources once per frame (§6.1 of
/// `labkit-from-gyre.md`): mic envelope/level/bass/onset/thirds, shake, jerk (τ 0.05 s), turn, tilt,
/// |B|, ΔB against an 8 s baseline, the 0.5 s magnetometer step, EMF flicker, barometer ratio,
/// thermal level, two LFOs and touch.
public struct SourceConditioner: Sendable {
  public var envelope = EnvelopeFollower()
  public var emf = EMFMeter()
  public var lfo1 = LFO(rateHz: 0.25)
  public var lfo2 = LFO(rateHz: 1.3, shape: .triangle)
  /// Baseline time constant for `mag.delta`, seconds.
  public var fieldBaselineTau = 8.0
  /// Mean time constant for `mag.step`, seconds.
  public var fieldStepTau = 0.5
  private var lastAccel: V3?
  private var jerk = 0.0
  private var fieldBaseline: Double?
  private var fieldMean: Double?
  public init() {}

  public mutating func step(
    motion s: MotionSample, mic: MicSnapshot?, micGain: Double, spectrum: Spectrum? = nil,
    pressureKPa: Double?, thermal: Double, touch: TouchSample = .up, dt: Double
  ) -> ModSources {
    var out = ModSources()
    if let mic {
      let level = Double(mic.level) * micGain
      out[.micEnvelope] = envelope.step(level: Double(mic.level), gain: micGain, dt: dt)
      out[.micLevel] = clamped((20 * log10(max(level, 1e-6)) + 55) / 45, 0, 1)
      out[.micBass] = Double(mic.bass) * micGain
      out[.micOnset] = Double(mic.onset)
      if let spectrum {
        out[.micLow] = Double(spectrum.mean(0..<10))
        out[.micMid] = Double(spectrum.mean(10..<30))
        out[.micHigh] = Double(spectrum.mean(30..<48))
      }
    } else {
      envelope.reset()
    }
    out[.shake] = s.userAcceleration.length
    let rawJerk = (s.userAcceleration - (lastAccel ?? s.userAcceleration)).length / max(dt, 1e-3)
    lastAccel = s.userAcceleration
    approach(&jerk, rawJerk, dt: dt, tau: 0.05)
    out[.jerk] = jerk
    out[.turn] = s.rotationRate.length
    out[.tilt] = acos(clamped(-s.gravity.unit.z, -1, 1)) / .pi
    let b = s.magneticField.length
    out[.field] = b
    var baseline = fieldBaseline ?? b
    approach(&baseline, b, dt: dt, tau: fieldBaselineTau)
    fieldBaseline = baseline
    out[.fieldDelta] = max(0, b - baseline)
    var mean = fieldMean ?? b
    approach(&mean, b, dt: dt, tau: fieldStepTau)
    fieldMean = mean
    out[.fieldStep] = abs(b - mean)
    emf.step(fieldMagnitude: b, dt: dt)
    out[.emf] = emf.emf
    out[.pressure] = (pressureKPa ?? Atmosphere.seaLevelKPa) / Atmosphere.seaLevelKPa
    out[.thermal] = thermal
    out[.lfo1] = lfo1.step(dt: dt)
    out[.lfo2] = lfo2.step(dt: dt)
    out[.touchDown] = touch.down ? 1 : 0
    out[.touchSpeed] = touch.down ? touch.speed / 1000 : 0
    out[.touchX] = clamped(touch.position.x, 0, 1)
    out[.touchY] = clamped(touch.position.y, 0, 1)
    out[.touchForce] = touch.down ? clamped(touch.force ?? 1, 0, 1) : 0
    return out
  }
}
