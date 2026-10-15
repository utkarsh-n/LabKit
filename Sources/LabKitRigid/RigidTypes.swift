// LabKitRigid: SI value types for the Box2D v3.1.1 wrapper.
//
// Units: metres, kilograms, seconds, radians. Densities are areal (kg/m²) because Box2D is a 2D engine:
// for a prop of volumetric density ρ (kg/m³) in a tank of depth d (m), pass ρ·d.
// Frame: the tank frame, origin bottom-left, y up (the same frame as LabKitMPM's colliders).

import simd

/// Identifies one body in one `RigidWorld`. Serial numbers start at 1 and are never reused within a world,
/// so a stale id can never alias a newer body.
public struct RigidBodyID: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let rawValue: Int

  init(rawValue: Int) { self.rawValue = rawValue }

  public static func < (a: RigidBodyID, b: RigidBodyID) -> Bool { a.rawValue < b.rawValue }
  public var description: String { "RigidBodyID(\(rawValue))" }
}

/// Shape of a body, in metres, in the body frame (the body origin is the `position` of its pose).
public enum RigidShape: Sendable, Equatable {
  /// Disc centred on the body origin.
  case circle(radius: Double)
  /// Rectangle centred on the body origin, sides along the body axes.
  case box(halfWidth: Double, halfHeight: Double)
  /// Stadium centred on the body origin: a segment from (−halfLength, 0) to (+halfLength, 0) swept by `radius`.
  case capsule(halfLength: Double, radius: Double)
  /// Convex polygon, vertices in the body frame. Box2D allows at most 8 vertices: `RigidWorld.add` uses the
  /// convex hull, reduces it to 8 vertices if needed, and `RigidWorld.shape(_:)` reports what was built.
  case polygon([SIMD2<Double>])

  /// Area in m² (multiply by an areal density in kg/m² for the mass).
  public var area: Double {
    switch self {
    case .circle(let r): return Double.pi * r * r
    case .box(let hw, let hh): return 4 * hw * hh
    case .capsule(let hl, let r): return Double.pi * r * r + 4 * hl * r
    case .polygon(let v):
      guard v.count >= 3 else { return 0 }
      var twice = 0.0
      for i in v.indices {
        let a = v[i], b = v[(i + 1) % v.count]
        twice += a.x * b.y - b.x * a.y
      }
      return abs(twice) / 2
    }
  }

  /// Largest distance from the body origin to any point of the shape, in metres.
  public var boundingRadius: Double {
    switch self {
    case .circle(let r): return r
    case .box(let hw, let hh): return (hw * hw + hh * hh).squareRoot()
    case .capsule(let hl, let r): return hl + r
    case .polygon(let v): return v.map { simd_length($0) }.max() ?? 0
    }
  }
}

/// How a body moves.
public enum RigidBodyKind: Sendable {
  /// Moved by gravity, contacts, forces and impulses.
  case dynamic
  /// Moved only by `RigidWorld.setTarget` / `setVelocity` (fingers, paddles). Infinite mass: pushes dynamic
  /// bodies, ignores forces.
  case kinematic
  /// Never moves (static scenery).
  case fixed
}

/// Everything needed to create a body. All values SI.
public struct RigidBodySpec: Sendable, Equatable {
  public var kind: RigidBodyKind
  public var shape: RigidShape
  /// Body origin in the tank frame, m.
  public var position: SIMD2<Double>
  /// Rotation about the body origin, rad (counter-clockwise).
  public var angle: Double
  /// Areal density, kg/m² (2D). Mass = density × shape area. Must be > 0 for dynamic bodies; ignored for
  /// kinematic and fixed bodies.
  public var density: Double
  /// Coulomb friction coefficient, usually 0…1. Pairs mix as √(μa·μb).
  public var friction: Double
  /// Coefficient of restitution, 0…1. Pairs mix as max(ea, eb). Applied only above
  /// `RigidWorld.restitutionThreshold` (0.1 m/s with the default length units).
  public var restitution: Double
  /// Linear damping, 1/s.
  public var linearDamping: Double
  /// Angular damping, 1/s.
  public var angularDamping: Double
  /// Fluid-coupled bodies must stay awake (a slowly sinking bead would otherwise freeze mid-fluid), so the
  /// default is false.
  public var enableSleep: Bool
  /// Free for the app (prop kind, material index …). Reported back in `RigidHit`.
  public var userTag: Int
  /// Initial velocity of the body origin, m/s.
  public var velocity: SIMD2<Double>
  /// Initial angular velocity, rad/s.
  public var angularVelocity: Double
  /// Report impacts above `RigidWorld.hitSpeedThreshold` in `RigidWorld.hits` (for haptics and sound).
  public var reportsHits: Bool

  public init(
    kind: RigidBodyKind = .dynamic,
    shape: RigidShape,
    position: SIMD2<Double>,
    angle: Double = 0,
    density: Double = 10,  // water (1000 kg/m³) × 1 cm of depth
    friction: Double = 0.6,
    restitution: Double = 0,
    linearDamping: Double = 0,
    angularDamping: Double = 0,
    enableSleep: Bool = false,
    userTag: Int = 0,
    velocity: SIMD2<Double> = .zero,
    angularVelocity: Double = 0,
    reportsHits: Bool = true
  ) {
    self.kind = kind
    self.shape = shape
    self.position = position
    self.angle = angle
    self.density = density
    self.friction = friction
    self.restitution = restitution
    self.linearDamping = linearDamping
    self.angularDamping = angularDamping
    self.enableSleep = enableSleep
    self.userTag = userTag
    self.velocity = velocity
    self.angularVelocity = angularVelocity
    self.reportsHits = reportsHits
  }
}

/// Where a body is and how it moves, all about the body origin (the point its shape is defined around), so
/// the velocity of any material point p is `velocity(at: p)`. For the circle, box and capsule shapes the body
/// origin is also the centre of mass.
public struct RigidPose: Sendable, Equatable {
  /// Body origin, m.
  public var position: SIMD2<Double>
  /// Rotation, rad, in [−π, π].
  public var angle: Double
  /// Velocity of the body origin, m/s.
  public var velocity: SIMD2<Double>
  /// rad/s, counter-clockwise positive.
  public var angularVelocity: Double

  public init(position: SIMD2<Double>, angle: Double, velocity: SIMD2<Double>, angularVelocity: Double) {
    self.position = position
    self.angle = angle
    self.velocity = velocity
    self.angularVelocity = angularVelocity
  }

  public static let zero = RigidPose(position: .zero, angle: 0, velocity: .zero, angularVelocity: 0)

  /// Velocity of the material point currently at `point` (tank frame), m/s: v + ω × (p − x).
  public func velocity(at point: SIMD2<Double>) -> SIMD2<Double> {
    let r = point - position
    return velocity + angularVelocity * SIMD2(-r.y, r.x)
  }

  /// Maps a point from the body frame to the tank frame.
  public func toWorld(_ local: SIMD2<Double>) -> SIMD2<Double> {
    let c = cos(angle), s = sin(angle)
    return position + SIMD2(c * local.x - s * local.y, s * local.x + c * local.y)
  }
}

/// One impact reported by the last `RigidWorld.step` (Box2D hit event): two shapes met with a normal approach
/// speed above `RigidWorld.hitSpeedThreshold` and the contact pushed back. A resting contact is not a hit.
public struct RigidHit: Sendable, Equatable {
  /// The bodies involved; nil for the tank walls (`RigidWorld.addWalls`).
  public var bodyA: RigidBodyID?
  public var bodyB: RigidBodyID?
  /// `RigidBodySpec.userTag` of each body; nil for the walls.
  public var tagA: Int?
  public var tagB: Int?
  /// Contact point at the start of the step, m (tank frame).
  public var point: SIMD2<Double>
  /// Unit contact normal, pointing from A to B.
  public var normal: SIMD2<Double>
  /// Normal closing speed before the impact, m/s (always positive).
  public var approachSpeed: Double

  public init(
    bodyA: RigidBodyID?, bodyB: RigidBodyID?, tagA: Int?, tagB: Int?,
    point: SIMD2<Double>, normal: SIMD2<Double>, approachSpeed: Double
  ) {
    self.bodyA = bodyA
    self.bodyB = bodyB
    self.tagA = tagA
    self.tagB = tagB
    self.point = point
    self.normal = normal
    self.approachSpeed = approachSpeed
  }

  /// True when `id` is one of the two bodies.
  public func involves(_ id: RigidBodyID) -> Bool { bodyA == id || bodyB == id }
  /// True when one side is a tank wall.
  public var involvesWall: Bool { bodyA == nil || bodyB == nil }
}
