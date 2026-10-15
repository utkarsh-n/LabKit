import Foundation
import Observation

/// The observable sensor baseline for a Metro screen (spec §13): a `MetroTiltFilter` that views can read. The host
/// feeds it device gravity from whatever it owns (CoreMotion's `CMDeviceMotion.gravity`, LabKitSensors' `MotionSource`,
/// a simulator stand-in) and owns permission, orientation mapping and lifecycle:
///
///     let generation = tilt.start()                // the next sample becomes the reference
///     tilt.ingest(gravityX: g.x, gravityZ: g.z, generation: generation, dt: 1 / 30)
///     tilt.stop()                                  // scene inactive, motion off, Reduce Motion: back to rest
///
/// `vector` is the bounded screen-space tilt for `MetroGauge`, `MetroLensSurface` and `MetroCrown` light; it never
/// moves a value, a unit or a control frame (contract 1). A sample stamped with a stale generation is ignored, so a
/// callback queued by an earlier run cannot move a restarted stream.
@MainActor @Observable
public final class MetroTilt {
  private var filter = MetroTiltFilter()

  public init() {}

  /// The filtered tilt, each axis −1…1 (zero when stopped).
  public private(set) var vector: SIMD2<Double> = .zero
  /// Whether a run is active (pass it as `motionActive`).
  public private(set) var isActive = false

  /// Starts a run and returns its generation.
  @discardableResult
  public func start() -> Int {
    let generation = filter.start()
    publish()
    return generation
  }

  public func stop() {
    filter.stop()
    publish()
  }

  /// Re-captures the reference from the next sample (an interface orientation change).
  public func rebase() { filter.rebase() }

  /// The current run's generation.
  public var generation: Int { filter.generation }

  /// One gravity sample in the device frame (g), already mapped for the current interface orientation.
  public func ingest(gravityX: Double, gravityZ: Double, generation: Int, dt: Double? = nil) {
    filter.update(gravityX: gravityX, gravityZ: gravityZ, generation: generation, dt: dt)
    publish()
  }

  /// Sets the tilt directly (a deterministic pose for previews, screenshots and QA), bypassing the filter.
  public func hold(_ pose: SIMD2<Double>) {
    vector = SIMD2(
      pose.x.isFinite ? min(1, max(-1, pose.x)) : 0, pose.y.isFinite ? min(1, max(-1, pose.y)) : 0)
    isActive = true
  }

  private func publish() {
    if vector != filter.vector { vector = filter.vector }
    if isActive != filter.isActive { isActive = filter.isActive }
  }
}
