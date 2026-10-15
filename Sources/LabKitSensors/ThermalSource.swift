import Foundation
import LabKitCore
import Observation

/// The phone's thermal state and Low Power Mode as a live, observable source (`device.thermal`,
/// a playful "phone heat" input, off by default in apps) plus the constraint flag the render host,
/// haptics and sound use. In DEBUG builds `-fakeThermal 0…3` (or `cycle`, stepping every 8 s) and
/// `-fakeLowPower` stand in for a hot phone; the fake is installed as `DeviceConditions` override so
/// the 60 fps cap and the hum/bed stop rules can be checked in the simulator.
@MainActor @Observable
public final class ThermalSource {
  public private(set) var conditions: DeviceConditions
  @ObservationIgnored public let isFake: Bool
  @ObservationIgnored private let fakeCycle: Bool
  @ObservationIgnored private var fakeTime = 0.0
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  /// Seconds per step of `-fakeThermal cycle`.
  public static let cycleStep = 8.0

  public var state: ProcessInfo.ThermalState { conditions.thermal }
  public var lowPower: Bool { conditions.lowPower }
  /// 0, ⅓, ⅔, 1: the `device.thermal` modulation value.
  public var level: Double { conditions.thermalLevel }
  /// Low Power or thermal ≥ serious.
  public var isConstrained: Bool { conditions.isConstrained }

  public init() {
    let thermalArg = LaunchOptions.fake(LaunchOptions.fakeThermal, hardwareAvailable: true)
      ? Self.fakeThermalValue(LaunchOptions.value(after: LaunchOptions.fakeThermal)) : nil
    let lowPower = LaunchOptions.fake(LaunchOptions.fakeLowPower, hardwareAvailable: true)
    fakeCycle = thermalArg == "cycle"
    isFake = thermalArg != nil || lowPower
    if isFake {
      let level = thermalArg.flatMap(Int.init) ?? 0
      conditions = DeviceConditions(thermal: ProcessInfo.ThermalState(level: level), lowPower: lowPower)
    } else {
      conditions = .live
    }
  }

  /// The `-fakeThermal` value: `0`…`3` or `cycle`; anything else (no value, or the next flag such as
  /// `-fakeMic` in `-fakeThermal -fakeMic`) means the documented default, 2 (serious).
  nonisolated static func fakeThermalValue(_ raw: String?) -> String {
    guard let raw else { return "2" }
    if raw == "cycle" { return raw }
    if let level = Int(raw), (0...3).contains(level) { return raw }
    return "2"
  }

  /// Starts observing (live) or installs the fake override.
  public func start() {
    if isFake {
      DeviceConditions.setOverride(conditions)
      return
    }
    guard observers.isEmpty else { return }
    conditions = .live
    let center = NotificationCenter.default
    let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    observers = [
      center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: refresh),
      center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: refresh),
    ]
  }

  public func stop() {
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers.removeAll()
  }

  /// Call once per frame from `advance(dt:)` when the app uses `device.thermal`; it only matters
  /// for `-fakeThermal cycle`. Returns the modulation level.
  @discardableResult
  public func sample(dt: Double) -> Double {
    if fakeCycle {
      fakeTime += dt
      let step = Int(fakeTime / Self.cycleStep) % 4
      let next = DeviceConditions(thermal: ProcessInfo.ThermalState(level: step), lowPower: conditions.lowPower)
      if next != conditions {
        conditions = next
        DeviceConditions.setOverride(next)
      }
    }
    return conditions.thermalLevel
  }

  private func refresh() {
    let now = DeviceConditions.live
    if now != conditions { conditions = now }
  }
}
