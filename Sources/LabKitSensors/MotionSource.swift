#if os(iOS)
import CoreMotion
import Foundation
import LabKitCore
import simd

/// Core Motion device motion, PULLED once per render frame (no handler, no queue: one clock),
/// plus the barometer on request. Without motion hardware it simulates a phone you tilt by
/// dragging; `-simSway` makes it sway; `-fakeMagnet` / `-fakeShake` add stimuli (on a real phone
/// too, in DEBUG builds only, layered over the live readings so MR-fluid routes can be checked
/// without a magnet).
/// Lifted from Gyre/Sensors/MotionSource.swift:40-140; MainActor because the MTKView delegate
/// (NS_SWIFT_UI_ACTOR in MTKView.h:260/267) pulls it from `draw(in:)` on the main thread.
@MainActor
public final class MotionSource {
  private let manager = CMMotionManager()
  private let altimeter = CMAltimeter()
  public private(set) var isLive = false
  public private(set) var pressureKPa: Double?
  public let barometerAvailable = CMAltimeter.isRelativeAltitudeAvailable()
  /// Touching CMAltimeter at all (even `stopRelativeAltitudeUpdates`) is a TCC motion access: without
  /// NSMotionUsageDescription iOS kills the app (seen on the iPhone 15 Pro Max, 13 Oct 2026). Only stop what we started.
  private var barometerRunning = false
  private var invertAttitude: Bool?
  /// The latest raw reading.
  public private(set) var last = MotionSample.resting
  /// Measured sample rate from timestamps (Hz), for honesty in telemetry.
  public private(set) var measuredRate = 0.0
  private var lastStamp = 0.0

  public var simYaw = 0.0
  public var simPitch = 60.0 * .pi / 180
  public var simRoll = 0.0
  public var simSway: Bool
  public var simMagnet: Bool
  public var simShake: Bool
  private var simTime = 0.0

  /// True when the device has motion hardware (false in the simulator).
  public let hardwareAvailable: Bool

  public init() {
    let hw = CMMotionManager().isDeviceMotionAvailable
    hardwareAvailable = hw
    simSway = LaunchOptions.fake(LaunchOptions.simSway, hardwareAvailable: hw)
    simMagnet = LaunchOptions.fake(LaunchOptions.fakeMagnet, hardwareAvailable: hw)
    simShake = LaunchOptions.fake(LaunchOptions.fakeShake, hardwareAvailable: hw)
  }

  /// Any reading is synthetic: no live motion, or a fake stimulus layered on top.
  public var isSimulated: Bool { !isLive || simMagnet || simShake }

  public func start(rateHz: Double = 120) {
    guard manager.isDeviceMotionAvailable else {
      isLive = false
      return
    }
    guard !manager.isDeviceMotionActive else { return }
    manager.deviceMotionUpdateInterval = 1.0 / rateHz
    manager.showsDeviceMovementDisplay = false
    let frames = CMMotionManager.availableAttitudeReferenceFrames()
    // Magnetometer-corrected yaw stops the world frame from slowly drifting.
    let frame: CMAttitudeReferenceFrame =
      frames.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical
    manager.startDeviceMotionUpdates(using: frame)
    isLive = true
  }

  public func stop() {
    manager.stopDeviceMotionUpdates()
    if barometerRunning { stopBarometer() }
  }

  /// Opt-in; prompts for NSMotionUsageDescription the first time.
  public func startBarometer() {
    guard barometerAvailable, !barometerRunning else { return }
    barometerRunning = true
    // Explicitly @Sendable (labkit-from-orbitals-spectra.md §5.7): the compiler then forbids touching
    // main-actor state synchronously. Delivery is on .main, so assumeIsolated holds (and checks).
    altimeter.startRelativeAltitudeUpdates(to: .main) { @Sendable [weak self] data, _ in
      guard let kPa = data?.pressure.doubleValue else { return }
      MainActor.assumeIsolated { self?.pressureKPa = kPa }
    }
  }

  public func stopBarometer() {
    guard barometerRunning else { return }
    barometerRunning = false
    altimeter.stopRelativeAltitudeUpdates()
    pressureKPa = nil
  }

  public func sample(dt: Double) -> MotionSample {
    simTime += dt
    if isLive {
      if let m = manager.deviceMotion {
        let s = convert(m)
        if s.timestamp > lastStamp, lastStamp > 0 {
          approach(&measuredRate, 1 / (s.timestamp - lastStamp), dt: dt, tau: 1)
        }
        lastStamp = s.timestamp
        last = s
      }
      return overlay(last)
    }
    last = simulate(dt: dt)
    return overlay(last)
  }

  /// The fake stimuli, added on top of a live or simulated reading.
  private func overlay(_ sample: MotionSample) -> MotionSample {
    var s = sample
    if simMagnet {
      // A bar magnet swinging past the phone: up to ~2 mT at closest approach, every 6 s.
      let closeness = pow(0.5 + 0.5 * sin(2 * .pi * simTime / 6), 6)
      s.magneticField += s.attitude.inverse.act(V3(0, 0, 1)) * 2000 * closeness
    }
    if simShake {
      // 0.4 s bursts of 12 Hz shaking at ±1.2 g along the phone's x axis, every 3 s.
      let t = simTime.truncatingRemainder(dividingBy: 3)
      if t < 0.4 { s.userAcceleration += V3(1.2 * sin(2 * .pi * 12 * simTime), 0, 0) }
    }
    return s
  }

  /// Drag-to-tilt for the simulated phone: 0.008 rad per point (GyroModel.swift:753-755).
  public func simulatedTilt(dx: Double, dy: Double) {
    simYaw -= dx * 0.008
    simPitch = clamped(simPitch - dy * 0.008, -0.2, .pi - 0.2)
  }

  private func convert(_ m: CMDeviceMotion) -> MotionSample {
    let cq = m.attitude.quaternion
    var q = simd_quatd(ix: cq.x, iy: cq.y, iz: cq.z, r: cq.w).normalized
    let gravity = V3(m.gravity.x, m.gravity.y, m.gravity.z)
    // Confirm the quaternion's direction against measured gravity once the phone is tilted
    // enough for the two conventions to disagree (MotionSource.swift:102-109).
    if invertAttitude == nil, simd_length(gravity) > 0.5 {
      let direct = simd_dot(q.inverse.act(V3(0, 0, -1)), gravity)
      let inverted = simd_dot(q.act(V3(0, 0, -1)), gravity)
      if abs(direct - inverted) > 0.3 { invertAttitude = inverted > direct }
    }
    if invertAttitude == true { q = q.inverse }
    let field = m.magneticField
    return MotionSample(
      attitude: q,
      rotationRate: V3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
      gravity: gravity,
      userAcceleration: V3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
      magneticField: V3(field.field.x, field.field.y, field.field.z),
      fieldCalibrated: field.accuracy != .uncalibrated,
      timestamp: m.timestamp)
  }

  private func simulate(dt: Double) -> MotionSample {
    var yaw = simYaw
    var pitch = simPitch
    var roll = simRoll
    if simSway {
      yaw += 0.9 * sin(simTime * 0.31)
      pitch += 0.3 * sin(simTime * 0.23 + 1)
      roll += 0.25 * sin(simTime * 0.17)
    }
    let q = MotionSample.pose(pitch: pitch, yaw: yaw, roll: roll)
    var rate = V3.zero
    if dt > 0 {
      var delta = q * last.attitude.inverse
      if delta.real < 0 { delta = simd_quatd(vector: -delta.vector) }
      let angle = delta.angle
      if angle.isFinite, angle > 1e-9 { rate = q.inverse.act(delta.axis * angle / dt) }
    }
    var s = MotionSample.at(q, rate: rate, field: MotionSample.simulatedField)
    s.timestamp = simTime
    return s
  }
}
#endif
