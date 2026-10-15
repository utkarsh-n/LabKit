# LabKitRigid

Rigid props for LabKit toys: **Box2D v3.1.1** (MIT, vendored unmodified in `Sources/CBox2D`) behind a small Swift API in SI units. Apps `import LabKitRigid` and never see the C API (`internal import CBox2D`; `CBox2D` is not a product). Provenance: `Sources/CBox2D/UPSTREAM.md` / `UPSTREAM.json`; licence: `THIRD_PARTY_NOTICES.md` (bundle it and credit Box2D in the info sheet).

*Written by WP-R on 3 October 2026, to be merged into `LabKit/README.md` once WP-C has written it.*

## Units and frame

- Metres, kilograms, seconds, radians, newtons. `Double` everywhere in the API (Box2D stores `Float`).
- Tank frame: origin bottom-left, y up, the same frame as LabKitMPM's colliders.
- **Densities are areal (kg/m²).** For a prop of density ρ (kg/m³) in a tank of depth d (m), pass ρ·d. Steel in a 1 cm tank: 7850 × 0.01 = 78.5 kg/m².
- Box2D's tolerances are scaled once per process with `b2SetLengthUnitsPerMeter(0.1)` (first `RigidWorld` or `RigidUnits.configure` wins): slop 0.5 mm, restitution and hit thresholds 0.1 m/s, sleep 5 mm/s, maximum speed 40 m/s. That is what makes 2–30 mm props bounce and settle properly.

## API (as shipped)

```swift
public struct RigidBodyID: Hashable, Comparable, Sendable { public let rawValue: Int }   // never reused in a world
public enum RigidShape: Sendable, Equatable {
  case circle(radius: Double), box(halfWidth: Double, halfHeight: Double)
  case capsule(halfLength: Double, radius: Double)        // segment along the body x axis
  case polygon([SIMD2<Double>])                           // convex hull, ≤ 8 vertices after reduction
  var area: Double; var boundingRadius: Double
}
public enum RigidBodyKind: Sendable { case dynamic, kinematic, fixed }
public struct RigidBodySpec: Sendable, Equatable {
  init(kind: = .dynamic, shape:, position:, angle: = 0, density: = 10, friction: = 0.6, restitution: = 0,
       linearDamping: = 0, angularDamping: = 0, enableSleep: = false, userTag: = 0,
       velocity: = .zero, angularVelocity: = 0, reportsHits: = true)
}
public struct RigidPose: Sendable, Equatable {            // all about the body origin
  var position, velocity: SIMD2<Double>; var angle, angularVelocity: Double
  func velocity(at point:) -> SIMD2<Double>; func toWorld(_ local:) -> SIMD2<Double>; static let zero
}
public struct RigidHit: Sendable, Equatable {             // one impact in the last step
  var bodyA, bodyB: RigidBodyID?   /* nil = tank wall */; var tagA, tagB: Int?
  var point, normal: SIMD2<Double>; var approachSpeed: Double   // m/s
  func involves(_:) -> Bool; var involvesWall: Bool
}
public enum RigidUnits {
  static let defaultLengthUnitsPerMetre = 0.1
  static func configure(lengthUnitsPerMetre: Double = 0.1) -> Double   // first call wins
  static var lengthUnitsPerMetre: Double? { get }; static var box2DVersion: String { get }   // "3.1.1"
  static var liveWorldCount: Int { get }
}
public final class RigidWorld {                            // not Sendable (explicitly unavailable)
  init(gravity: SIMD2<Double>, lengthUnitsPerMetre: Double = 0.1)
  let lengthUnitsPerMetre: Double
  var gravity: SIMD2<Double>                               // setting it wakes dynamic bodies; NaN/∞ refused
  var hitSpeedThreshold: Double; var restitutionThreshold: Double   // m/s, default 0.1
  // bodies
  @discardableResult func add(_ spec: RigidBodySpec) -> RigidBodyID
  func remove(_ id:); func removeAll()                     // removeAll keeps the walls
  var bodies: [RigidBodyID] { get }                        // insertion order, walls excluded
  func contains(_:) -> Bool; func spec(_:) -> RigidBodySpec?; func kind(_:) -> RigidBodyKind?; func userTag(_:) -> Int?
  func shape(_:) -> RigidShape                             // what Box2D actually built
  func mass(_:) -> Double                                  // kg; 0 for kinematic/fixed
  func rotationalInertia(_:) -> Double; func centreOfMass(_:) -> SIMD2<Double>
  func pose(_:) -> RigidPose
  func setTransform(_:position:angle:); func setVelocity(_:linear:angular:)
  // tank
  func addWalls(width:height:thickness:top: = true, friction: = 0.6, restitution: = 0); func removeWalls(); var hasWalls: Bool
  // driving
  func setTarget(_:position:angle:dt:)                     // kinematic tools (b2Body_SetTargetTransform)
  func applyImpulse(_:linear:angular:)                     // N·s at the COM, N·m·s about it
  func applyImpulse(_:linear:at:)                          // N·s at a point
  func applyForce(_:_:); func applyTorque(_:_:)            // for the next step only
  func explode(at:radius:falloff: = 0, impulsePerLength:)  // punch
  @discardableResult func beginDrag(_:at:maxForce: = nil, stiffness: = 15, dampingRatio: = 0.9) -> Bool
  func updateDrag(to:); func endDrag(); var draggedBody: RigidBodyID? { get }
  // time and events
  func step(dt: Double, subSteps: Int = 4)
  var hits: [RigidHit] { get }                             // from the last step
  func drainHits() -> [RigidHit]                           // since the last drain, ≤ 64 (weakest dropped)
  var rejectedInputCount: Int { get }                      // NaN/∞ forces, impulses, targets, gravity refused
  func query(point: SIMD2<Double>, radius: Double = 0) -> RigidBodyID?   // dynamic > kinematic > fixed, then nearest
}
```

Unknown or removed ids never crash: queries return neutral values (`RigidPose.zero`, mass 0, a zero-radius circle) and commands do nothing. Programmer errors (non-finite or non-positive sizes, a dynamic body with density 0, non-finite spec values) are preconditions.

## Using it in a toy (Rheo sketch)

```swift
let rigid = RigidWorld(gravity: SIMD2(0, -9.81))
rigid.addWalls(width: 0.0712, height: 0.1014, thickness: 0.01)            // life-size tank, closed top
let ball = rigid.add(RigidBodySpec(shape: .circle(radius: 0.004), position: SIMD2(0.0356, 0.09),
                                   density: 7850 * gap, restitution: 0.4, userTag: Prop.steelBall.rawValue))
let finger = rigid.add(RigidBodySpec(kind: .kinematic, shape: .circle(radius: 0.004), position: start))

// Once per fixed quantum h (1/120 s × time scale), on the main actor:
for (index, id) in coupled.enumerated() {                                  // fluid → body, one frame late
  let j = mpmStats.bodyImpulses[index]                                     // (Jx, Jy, angular) N·s
  rigid.applyImpulse(id, linear: SIMD2(j.x, j.y), angular: j.z)
}
rigid.gravity = screenGravity * gravityKnob
rigid.setTarget(finger, position: fingerPoint, angle: 0, dt: h)
rigid.step(dt: h)                                                          // 4 substeps
// Per display frame: impacts → haptics/sound
for hit in rigid.drainHits() where hit.approachSpeed > 0.15 { haptics.tap(strength: min(1, hit.approachSpeed / 0.8)) }

// Body → fluid: each prop becomes an MPMCollider (LabKitMPM), velocities about the body origin.
func collider(_ id: RigidBodyID, index: Int) -> MPMCollider? {
  let p = rigid.pose(id)
  let shape: MPMCollider.Shape
  switch rigid.shape(id) {
  case .circle(let r): shape = .circle(radius: r)
  case .box(let hw, let hh): shape = .box(halfSize: SIMD2(hw, hh))
  case .capsule(let hl, let r): shape = .capsule(halfLength: hl, radius: r)   // check LabKitMPM's capsule axis
  case .polygon: return nil                                                 // no MPM polygon collider
  }
  return MPMCollider(shape: shape, position: p.position, angle: p.angle, velocity: p.velocity,
                     angularVelocity: p.angularVelocity, friction: rigid.spec(id)?.friction ?? 0.5, bodyIndex: index)
}
```

(The `MPMCollider` initialiser is WP-G's; adapt to what LabKitMPM ships.) For circle, box and capsule props the body origin is the centre of mass, so the angular impulse LabKitMPM reports about the collider position is the one `applyImpulse` expects.

Coupling advice from the research notes (not yet tested against the real solver): the one-frame impulse lag can pump energy into light props in dense fluids. If it does, clamp |Δv| per quantum to about 2·g·h + 0.5·|v_rel| and give coupled props a little linear damping. Do **not** model fluid drag with `linearDamping`: Box2D damps only the carried velocity (v ← h·a + v/(1 + h·c)), so the terminal speed can never fall below g·h ≈ 20 mm/s at 480 substeps/s.

## Threading and global state

`RigidWorld` belongs to one isolation domain (the main actor in Rheo). Box2D's world table (128 slots) and length scale are process-global; `RigidUnits` puts world creation and destruction behind one `Mutex` and fixes the scale before the first world. No Box2D callbacks run during a step (`workerCount = 1`); events are read after it.

## Checks (LabKitRigidTests, one serialised XCTestCase)

Run: `Tools/lk.sh <work-name> env TOOLCHAINS=metal swift test --no-parallel --filter LabKitRigidTests`. Twenty-two tests. Measured on the M1 Max host, 3 October 2026 (WP-R), re-run 4 October 2026 by the WP-R verifier with identical numbers in Debug and Release:

| Check | Pass condition | Measured |
|---|---|---|
| Free fall, 1 s at 120 Hz × 4 substeps | drop within 0.5 % of ½gt² | +0.209 % (4.9152 m vs 4.9050 m; theory for semi-implicit Euler with N = 480 substeps: +1/N = +0.208 %) |
| Resting 1 cm box | centre within 0.5 mm of 5 mm | 4.914 mm (−0.086 mm) |
| Restitution e = 0.8, 4 mm bead, 26 mm drop | apex within 5 % of e²h | 16.53 mm vs 16.64 mm |
| Kinematic tracking, circular path 2 cm at 1 Hz | position < 10 µm, angle < 0.1 mrad; stops dead when the target stops | 3.8 nm, 3.0 µrad; velocity exactly 0 after stopping |
| Impulse → Δv = J/m, Δω = L/I | relative 1e-5 | agree to Float precision (~6e-8) |
| Force balance with `applyForce` | weight-cancelling force: no drift; half weight: ¼gt² within 0.5 % | drift 0.0 m; 2.4576 m vs 2.4525 m (+0.21 %, same discretisation bias) |
| Point query | inside, outside, fingertip radius, walls never picked, dynamic beats fixed | pass |
| Hit events, 4 mm bead, 2 cm drop | exactly one hit, wall + bead + tag, approach within g·dt of √(2gh) | 0.654 vs 0.626 m/s; no hits at rest; none above a 1 m/s threshold |
| Determinism | two identical 20-body runs bitwise equal | pass |
| Sleep | sleep-disabled bead sinking at 3 mm/s keeps sinking; sleep-enabled one freezes | 5.14 mm (model 5.10 mm) vs 0.80 mm in 2 s |
| Drag | bead within 2 mm of the finger after 1 s | 1.10 mm (spring sag g/ω² = 1.1 mm at 15 Hz) |
| Walls and tilt | rests at x = width − r under sideways gravity; closed top holds it upside down | pass |
| Polygon | 12-gon reduced to ≤ 8 vertices; mass = density × built area; a degenerate polygon becomes a disc centred on the body origin | Box2D built 7 vertices (it welds near-collinear points) |
| Point impulse, torque, teleport, wall removal | Δω = (p − c) × J / I and τ·dt/I to 1e-5/1e-4; `setTransform` exact to Float; bead falls out once walls are removed | pass |
| Non-finite gravity | NaN/∞ gravity refused (counted in `rejectedInputCount`), bodies stay finite; a `setTarget` dt that is 0 in Float is refused | pass |
| Lifecycle | worlds destroyed with the wrapper; 300 sequential worlds fit in Box2D's 128 slots | pass |
| Benchmark (informational) | 500 awake balls, 4 substeps | 0.13–0.15 ms per step (Debug Swift, C at -O2) |

iOS: `xcodebuild -scheme LabKitRigid` for `generic/platform=iOS Simulator` and `generic/platform=iOS` both build with 0 warnings. Not yet run on a phone.

## Box2D quirks handled by the wrapper

- `b2MakeRot` uses Bhaskara's cosine approximation (≈ 1.6 mrad error): rotations are built from exact `cos`/`sin`, and poses report `atan2` of the stored rotation.
- `b2Body_SetTargetTransform` ignores "sleepy" targets (below 5 mm/s), which would leave a stopped tool drifting: `setTarget` writes the velocities itself.
- Box2D's hull drops vertices within 1 mm of their neighbours' chord and takes at most 8: `shape(_:)` reports what was built; degenerate polygons fall back to a disc of equal area centred on the body origin (where `RigidShape.circle` is defined).
- Hit approach speeds are read at the start of the step that resolves the contact, so they are within ± g·dt of the true impact speed.
