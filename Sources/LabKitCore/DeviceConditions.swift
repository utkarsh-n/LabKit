import Foundation
import Synchronization

/// The phone's power and thermal situation, which LabKit uses in three places:
/// - the render host caps the frame rate at 60 fps when constrained (`FramePacing`);
/// - the haptic hum stops when constrained (`labkit-from-orbitals-spectra.md` §5.2 rule 2); the sound
///   bed stops in Low Power Mode only (§6.3 rule 3; `SoundPolicy.lowPower`);
/// - `device.thermal` is a playful modulation source ("phone heat").
///
/// `current` reads `ProcessInfo` unless a simulator fake has installed an override
/// (`ThermalSource` does this for `-fakeThermal` / `-fakeLowPower` in DEBUG builds), so every
/// module sees the same answer without depending on LabKitSensors.
public struct DeviceConditions: Sendable, Equatable {
  public var thermal: ProcessInfo.ThermalState
  public var lowPower: Bool

  public init(thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false) {
    self.thermal = thermal
    self.lowPower = lowPower
  }

  /// What the operating system reports right now.
  public static var live: DeviceConditions {
    let info = ProcessInfo.processInfo
    return DeviceConditions(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled)
  }

  private static let overrideBox = Mutex<DeviceConditions?>(nil)

  /// The override if one is installed, else `live`.
  public static var current: DeviceConditions { overrideBox.withLock { $0 } ?? live }

  /// Installs (or with `nil` removes) a stand-in for the real conditions. Used by simulator fakes and tests.
  public static func setOverride(_ conditions: DeviceConditions?) { overrideBox.withLock { $0 = conditions } }

  public static var isOverridden: Bool { overrideBox.withLock { $0 != nil } }

  /// Low Power Mode, or thermal state `.serious` or worse.
  public var isConstrained: Bool { lowPower || thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue }

  /// 0, ⅓, ⅔, 1 for nominal, fair, serious, critical (the `device.thermal` source).
  public var thermalLevel: Double { thermal.modulationValue }
}

extension ProcessInfo.ThermalState {
  /// nominal 0, fair ⅓, serious ⅔, critical 1.
  public var modulationValue: Double {
    switch self {
    case .nominal: 0
    case .fair: 1.0 / 3
    case .serious: 2.0 / 3
    case .critical: 1
    @unknown default: 1
    }
  }

  /// A plain word for telemetry ("Nominal", "Fair", "Serious", "Critical").
  public var label: String {
    switch self {
    case .nominal: "Nominal"
    case .fair: "Fair"
    case .serious: "Serious"
    case .critical: "Critical"
    @unknown default: "Unknown"
    }
  }

  /// 0…3 → state (clamped), for launch arguments and tests.
  public init(level: Int) {
    self = ProcessInfo.ThermalState(rawValue: clamped(level, 0, 3)) ?? .nominal
  }
}

/// Frame budget policy for the render host (`ARCHITECTURE.md` §3 "Frame budget").
public enum FramePacing {
  /// At most two command buffers in flight; a third frame is skipped, never waited for.
  public static let maxFramesInFlight = 2
  /// ProMotion rate (Gyre `HoloRenderer.swift:732`, `CADisableMinimumFrameDurationOnPhone`).
  public static let fullRate = 120
  /// The cap under Low Power Mode or serious/critical thermal state.
  public static let constrainedRate = 60
  /// How often the host re-reads the conditions, seconds.
  public static let recheckInterval = 0.5

  /// The frame rate to ask the display for. `requested` (an app override) can only lower it.
  public static func preferredFPS(_ conditions: DeviceConditions, requested: Int? = nil) -> Int {
    let cap = conditions.isConstrained ? constrainedRate : fullRate
    guard let requested, requested > 0 else { return cap }
    return min(requested, cap)
  }
}
