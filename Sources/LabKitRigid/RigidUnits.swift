// LabKitRigid: Box2D's process-global state, behind one lock.
//
// Box2D v3.1.1 keeps three things per process, not per world (oss-integration-lessons.md §3.5):
//   - the world table `b2_worlds[128]`, scanned by `b2CreateWorld` without a lock (src/world.c);
//   - `b2_lengthUnitsPerMeter`, which scales every tolerance (src/core.c, src/constants.h);
//   - the assert hook and the allocator.
// LabKitRigid sets the length units once, before the first world, and serialises world creation and
// destruction. Stepping different worlds from different threads is not supported by this wrapper
// (`RigidWorld` is not Sendable; Rheo keeps its one world on the main actor).

internal import CBox2D
import Synchronization

public enum RigidUnits {
  /// Box2D's tolerances are physical values tuned for 0.1–10 m bodies (slop 5 mm, restitution and hit
  /// thresholds 1 m/s, sleep 5 cm/s). 0.1 scales them by 1/10 (slop 0.5 mm, thresholds 0.1 m/s, sleep
  /// 5 mm/s), which suits 2–30 mm props: with the defaults a 4 mm bead does not bounce at all.
  public static let defaultLengthUnitsPerMetre: Double = 0.1

  /// Fixes Box2D's length scale for the life of the process and returns the value in effect. The first call
  /// (or the first `RigidWorld.init`) wins; later calls with a different value are ignored, because changing
  /// the scale under live worlds would change their tolerances mid-flight.
  @discardableResult
  public static func configure(lengthUnitsPerMetre: Double = defaultLengthUnitsPerMetre) -> Double {
    precondition(
      lengthUnitsPerMetre.isFinite && lengthUnitsPerMetre > 0,
      "RigidUnits.configure: lengthUnitsPerMetre must be positive and finite")
    return box2DGlobals.withLock { state in
      configureLocked(&state, lengthUnitsPerMetre)
    }
  }

  /// The length scale in effect, or nil before the first `configure` / `RigidWorld`.
  public static var lengthUnitsPerMetre: Double? {
    box2DGlobals.withLock { $0.lengthUnitsPerMetre }
  }

  /// Version of the linked Box2D, e.g. "3.1.1" (for credits and diagnostics).
  public static var box2DVersion: String {
    let v = b2GetVersion()
    return "\(v.major).\(v.minor).\(v.revision)"
  }

  /// Number of live `RigidWorld`s in this process (Box2D allows 128).
  public static var liveWorldCount: Int {
    box2DGlobals.withLock { $0.liveWorlds }
  }

  // MARK: - Internal

  /// Configures the units (first call wins), then builds the world definition from `b2DefaultWorldDef()` —
  /// which reads `b2_lengthUnitsPerMeter`, so it must come after configuration — and creates the world.
  static func createWorld(gravity: b2Vec2, lengthUnitsPerMetre requested: Double) -> (b2WorldId, Double) {
    precondition(
      requested.isFinite && requested > 0,
      "RigidWorld: lengthUnitsPerMetre must be positive and finite")
    return box2DGlobals.withLock { state in
      let units = configureLocked(&state, requested)
      precondition(state.liveWorlds < 128, "RigidWorld: Box2D allows at most 128 live worlds per process")
      var def = b2DefaultWorldDef()  // never zero-initialise: Box2D checks a cookie set here
      def.gravity = gravity
      def.workerCount = 1  // single-threaded: a handful of props costs microseconds
      def.enableSleep = true  // per body: RigidBodySpec.enableSleep (default false)
      def.enableContinuous = true  // fast small beads must not tunnel through the tank walls
      let id = b2CreateWorld(&def)
      state.liveWorlds += 1
      return (id, units)
    }
  }

  static func destroyWorld(_ id: b2WorldId) {
    box2DGlobals.withLock { state in
      b2DestroyWorld(id)
      state.liveWorlds -= 1
    }
  }

  private static func configureLocked(_ state: inout Box2DGlobals, _ requested: Double) -> Double {
    if let current = state.lengthUnitsPerMetre { return current }
    b2SetLengthUnitsPerMeter(Float(requested))
    state.lengthUnitsPerMetre = requested
    return requested
  }
}

struct Box2DGlobals: Sendable {
  var lengthUnitsPerMetre: Double?
  var liveWorlds = 0
}

/// Guards everything process-global in Box2D (see the file header).
let box2DGlobals = Mutex(Box2DGlobals())
