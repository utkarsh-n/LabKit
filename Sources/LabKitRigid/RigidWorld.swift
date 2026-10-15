// LabKitRigid: one Box2D v3.1.1 world behind an SI, Swift-only API.
//
// Apps never see the C API (`internal import CBox2D`). Every Box2D call that v3.2 changes lives in this file
// (mouse joint, overlap queries, body/shape definitions) or in RigidUnits.swift (world definition fields,
// world creation), so an upgrade touches only LabKitRigid's sources and is re-verified by LabKitRigidTests.

internal import CBox2D
import simd

/// One Box2D world: rigid props, kinematic tools and the tank walls.
///
/// Not Sendable: create, step and destroy it in the single isolation domain that owns the simulation
/// (the main actor in Rheo). Box2D state that is process-global is handled by `RigidUnits`.
///
/// Ids that are unknown or already removed are tolerated: queries return neutral values (`RigidPose.zero`,
/// zero mass, a zero-radius circle) and commands do nothing. Use `contains(_:)` to check.
public final class RigidWorld {
  /// Box2D's length scale for this process (see `RigidUnits`). Usually `RigidUnits.defaultLengthUnitsPerMetre`.
  public let lengthUnitsPerMetre: Double

  /// Gravity, m/s², tank frame. Setting it wakes every dynamic body. A non-finite value (e.g. a bad sensor
  /// sample) is refused: gravity keeps its previous value and `rejectedInputCount` goes up.
  public var gravity: SIMD2<Double> {
    didSet {
      guard Self.isFinite(gravity) else {
        gravity = oldValue  // no observer re-entry: assigning inside didSet does not call didSet again
        rejectedInputCount += 1
        return
      }
      guard gravity != oldValue else { return }
      b2World_SetGravity(worldID, Self.vec(gravity))
      // Wake in insertion order (not dictionary order) so the awake set, and hence the solver, stays
      // reproducible from run to run.
      for id in order {
        if let entry = entries[id], entry.kind == .dynamic { b2Body_SetAwake(entry.body, true) }
      }
    }
  }

  /// Impacts slower than this (m/s, normal approach speed) are not reported in `hits`.
  /// Default 1 m/s × `lengthUnitsPerMetre` (0.1 m/s).
  public var hitSpeedThreshold: Double {
    get { Double(b2World_GetHitEventThreshold(worldID)) }
    set { b2World_SetHitEventThreshold(worldID, Float(max(0, newValue))) }
  }

  /// Impacts slower than this (m/s) do not bounce, whatever their restitution.
  /// Default 1 m/s × `lengthUnitsPerMetre` (0.1 m/s).
  public var restitutionThreshold: Double {
    get { Double(b2World_GetRestitutionThreshold(worldID)) }
    set { b2World_SetRestitutionThreshold(worldID, Float(max(0, newValue))) }
  }

  /// Impacts from the most recent `step`, in Box2D's order. Empty after a step without impacts.
  public private(set) var hits: [RigidHit] = []

  /// The most impacts `drainHits()` keeps between drains; beyond it the weakest are dropped.
  public static let hitBacklogLimit = 64

  /// Forces, impulses, targets, transforms, velocities and gravity values refused because they were NaN or
  /// infinite (e.g. a bad GPU readback or sensor sample), or a `setTarget` dt that is not positive in Float.
  public private(set) var rejectedInputCount = 0

  /// Every body added with `add(_:)` and not yet removed, in the order added. Walls are not included.
  public var bodies: [RigidBodyID] { order }

  /// The body held by `beginDrag`, if any.
  public var draggedBody: RigidBodyID? { drag?.id }

  /// True after `addWalls` until `removeWalls`.
  public var hasWalls: Bool { wallBody != nil }

  // MARK: Private state

  private struct Entry {
    let body: b2BodyId
    let kind: RigidBodyKind
    var spec: RigidBodySpec  // as built: `shape` is what Box2D actually got
  }

  private let worldID: b2WorldId
  private let anchor: b2BodyId  // static, shapeless: the ground end of the drag joint
  private var entries: [RigidBodyID: Entry] = [:]
  private var order: [RigidBodyID] = []
  private var nextSerial = 1
  private var wallBody: b2BodyId?
  private var drag: (id: RigidBodyID, joint: b2JointId)?
  private var backlog: [RigidHit] = []

  // MARK: Life cycle

  /// Creates a world. The first world (or `RigidUnits.configure`) fixes Box2D's length scale for the process;
  /// a different `lengthUnitsPerMetre` passed later is ignored (check `self.lengthUnitsPerMetre`).
  public init(gravity: SIMD2<Double>, lengthUnitsPerMetre: Double = RigidUnits.defaultLengthUnitsPerMetre) {
    precondition(Self.isFinite(gravity), "RigidWorld: gravity must be finite")
    let (world, units) = RigidUnits.createWorld(gravity: Self.vec(gravity), lengthUnitsPerMetre: lengthUnitsPerMetre)
    worldID = world
    self.lengthUnitsPerMetre = units
    self.gravity = gravity
    var anchorDef = b2DefaultBodyDef()  // static, at the origin, no shapes, no user data
    anchorDef.type = b2_staticBody
    anchor = b2CreateBody(world, &anchorDef)
  }

  deinit {
    RigidUnits.destroyWorld(worldID)
  }

  // MARK: Bodies

  /// Adds a body and returns its id. Sizes must be positive and positions finite (precondition).
  @discardableResult
  public func add(_ spec: RigidBodySpec) -> RigidBodyID {
    precondition(Self.isFinite(spec.position) && spec.angle.isFinite, "RigidWorld.add: position and angle must be finite")
    precondition(Self.isFinite(spec.velocity) && spec.angularVelocity.isFinite, "RigidWorld.add: velocities must be finite")
    precondition(spec.density.isFinite && spec.density >= 0, "RigidWorld.add: density must be ≥ 0 (kg/m²)")
    // Box2D gives a zero-density dynamic body zero mass: gravity skips it and contacts cannot move it.
    precondition(spec.kind != .dynamic || spec.density > 0, "RigidWorld.add: a dynamic body needs density > 0")

    let id = RigidBodyID(rawValue: nextSerial)
    nextSerial += 1

    var bodyDef = b2DefaultBodyDef()
    bodyDef.type = Self.bodyType(spec.kind)
    bodyDef.position = Self.vec(spec.position)
    bodyDef.rotation = Self.rot(spec.angle)
    bodyDef.linearDamping = Float(max(0, spec.linearDamping))
    bodyDef.angularDamping = Float(max(0, spec.angularDamping))
    bodyDef.enableSleep = spec.enableSleep
    bodyDef.userData = UnsafeMutableRawPointer(bitPattern: id.rawValue)  // shape → body → id, for hits and queries
    let body = b2CreateBody(worldID, &bodyDef)

    var shapeDef = b2DefaultShapeDef()
    shapeDef.density = Float(spec.density)
    shapeDef.material.friction = Float(max(0, spec.friction))
    shapeDef.material.restitution = Float(max(0, spec.restitution))
    shapeDef.enableHitEvents = spec.reportsHits
    let built = Self.attach(spec.shape, to: body, shapeDef)

    var stored = spec
    stored.shape = built
    entries[id] = Entry(body: body, kind: spec.kind, spec: stored)
    order.append(id)

    if spec.velocity != .zero || spec.angularVelocity != 0 {
      setVelocity(id, linear: spec.velocity, angular: spec.angularVelocity)
    }
    return id
  }

  /// Removes a body (and ends a drag on it). Unknown ids are ignored.
  public func remove(_ id: RigidBodyID) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    if drag?.id == id { endDrag() }
    b2DestroyBody(entry.body)
    order.removeAll { $0 == id }
  }

  /// Removes every body added with `add(_:)`. The walls stay (see `removeWalls`). Ids are not reused.
  public func removeAll() {
    endDrag()
    for id in order { if let entry = entries[id] { b2DestroyBody(entry.body) } }
    entries.removeAll()
    order.removeAll()
    backlog.removeAll()
    hits.removeAll()
  }

  public func contains(_ id: RigidBodyID) -> Bool { entries[id] != nil }

  /// The spec the body was built from; `shape` is the shape Box2D actually got.
  public func spec(_ id: RigidBodyID) -> RigidBodySpec? { entries[id]?.spec }

  /// The shape Box2D actually got (polygons may have been reduced; see `RigidShape.polygon`).
  public func shape(_ id: RigidBodyID) -> RigidShape { entries[id]?.spec.shape ?? .circle(radius: 0) }

  public func kind(_ id: RigidBodyID) -> RigidBodyKind? { entries[id]?.kind }

  public func userTag(_ id: RigidBodyID) -> Int? { entries[id]?.spec.userTag }

  /// Mass in kg (density × area for dynamic bodies; 0 for kinematic and fixed bodies, which have infinite mass).
  public func mass(_ id: RigidBodyID) -> Double {
    guard let entry = entries[id] else { return 0 }
    return Double(b2Body_GetMass(entry.body))
  }

  /// Rotational inertia about the centre of mass, kg·m² (0 for kinematic and fixed bodies).
  public func rotationalInertia(_ id: RigidBodyID) -> Double {
    guard let entry = entries[id] else { return 0 }
    return Double(b2Body_GetRotationalInertia(entry.body))
  }

  /// Centre of mass in the tank frame, m.
  public func centreOfMass(_ id: RigidBodyID) -> SIMD2<Double> {
    guard let entry = entries[id] else { return .zero }
    return Self.vec(b2Body_GetWorldCenterOfMass(entry.body))
  }

  /// Position, angle and velocities, all about the body origin.
  public func pose(_ id: RigidBodyID) -> RigidPose {
    guard let entry = entries[id] else { return .zero }
    let p = b2Body_GetPosition(entry.body)
    let q = b2Body_GetRotation(entry.body)
    return RigidPose(
      position: Self.vec(p),
      angle: atan2(Double(q.s), Double(q.c)),  // exact; Box2D's b2Rot_GetAngle uses a fast approximation
      velocity: Self.vec(b2Body_GetWorldPointVelocity(entry.body, p)),
      angularVelocity: Double(b2Body_GetAngularVelocity(entry.body)))
  }

  /// Teleports a body (no sweep: it can end up overlapping others, which Box2D then pushes apart).
  public func setTransform(_ id: RigidBodyID, position: SIMD2<Double>, angle: Double) {
    guard let entry = entries[id] else { return }
    guard Self.isFinite(position), angle.isFinite else { rejectedInputCount += 1; return }
    b2Body_SetTransform(entry.body, Self.vec(position), Self.rot(angle))
  }

  /// Sets the velocity of the body origin (m/s) and the angular velocity (rad/s). Ignored for fixed bodies.
  public func setVelocity(_ id: RigidBodyID, linear: SIMD2<Double>, angular: Double) {
    guard let entry = entries[id] else { return }
    guard Self.isFinite(linear), angular.isFinite else { rejectedInputCount += 1; return }
    // Box2D stores the centre-of-mass velocity: v_com = v_origin + ω × (com − origin).
    let r = Self.vec(b2Body_GetWorldCenterOfMass(entry.body)) - Self.vec(b2Body_GetPosition(entry.body))
    let vCom = linear + angular * SIMD2(-r.y, r.x)
    b2Body_SetLinearVelocity(entry.body, Self.vec(vCom))
    b2Body_SetAngularVelocity(entry.body, Float(angular))
  }

  // MARK: Tank walls

  /// Static walls around the rectangle [0, width] × [0, height] (origin bottom-left, y up), each `thickness`
  /// thick and lying outside the rectangle, so the inner faces are exactly at x = 0, x = width, y = 0 and
  /// y = height. Replaces earlier walls. `top: false` leaves the tank open at the top.
  public func addWalls(
    width: Double, height: Double, thickness: Double,
    top: Bool = true, friction: Double = 0.6, restitution: Double = 0
  ) {
    precondition(width > 0 && height > 0 && thickness > 0, "RigidWorld.addWalls: sizes must be positive")
    removeWalls()
    var bodyDef = b2DefaultBodyDef()
    bodyDef.type = b2_staticBody
    let body = b2CreateBody(worldID, &bodyDef)  // no user data: hits and queries report walls as nil
    var shapeDef = b2DefaultShapeDef()
    shapeDef.material.friction = Float(max(0, friction))
    shapeDef.material.restitution = Float(max(0, restitution))
    let w = width, h = height, t = thickness
    var slabs: [(half: SIMD2<Double>, centre: SIMD2<Double>)] = [
      (SIMD2(w / 2 + t, t / 2), SIMD2(w / 2, -t / 2)),  // floor
      (SIMD2(t / 2, h / 2 + t), SIMD2(-t / 2, h / 2)),  // left
      (SIMD2(t / 2, h / 2 + t), SIMD2(w + t / 2, h / 2)),  // right
    ]
    if top { slabs.append((SIMD2(w / 2 + t, t / 2), SIMD2(w / 2, h + t / 2))) }
    for slab in slabs {
      var polygon = b2MakeOffsetBox(Float(slab.half.x), Float(slab.half.y), Self.vec(slab.centre), b2Rot_identity)
      _ = b2CreatePolygonShape(body, &shapeDef, &polygon)
    }
    wallBody = body
  }

  public func removeWalls() {
    guard let body = wallBody else { return }
    b2DestroyBody(body)
    wallBody = nil
  }

  // MARK: Driving bodies

  /// Moves a kinematic tool (finger, paddle) so that it reaches `position`/`angle` after the next `step(dt:)`,
  /// using `b2Body_SetTargetTransform`. Also works on dynamic bodies (sets their velocity). Fixed: ignored.
  public func setTarget(_ id: RigidBodyID, position: SIMD2<Double>, angle: Double, dt: Double) {
    guard let entry = entries[id], entry.kind != .fixed else { return }
    // dt must also survive the conversion to Float (a positive Double below ~1e-38 becomes 0 or subnormal,
    // and 1/dt would then be infinite).
    guard Self.isFinite(position), angle.isFinite, dt.isFinite, Float(dt).isNormal, dt > 0 else {
      rejectedInputCount += 1
      return
    }
    let body = entry.body
    let target = b2Transform(p: Self.vec(position), q: Self.rot(angle))
    b2Body_SetTargetTransform(body, target, Float(dt))
    // Box2D 3.1.1 (src/body.c, b2Body_SetTargetTransform) returns *without writing the velocity* when the
    // requested motion is below the body's sleep threshold (5 mm/s here), so a finger that stops would leave
    // the tool drifting at its previous speed. Write the velocities explicitly, with the same formula; the
    // angle step is computed exactly here (Box2D's b2RelativeAngle uses a polynomial atan2).
    let c1 = b2Body_GetWorldCenterOfMass(body)
    let c2 = b2TransformPoint(target, b2Body_GetLocalCenterOfMass(body))
    b2Body_SetLinearVelocity(body, b2MulSV(1 / Float(dt), b2Sub(c2, c1)))
    let q1 = b2Body_GetRotation(body), q2 = target.q
    let sinDelta = Double(q2.s) * Double(q1.c) - Double(q2.c) * Double(q1.s)
    let cosDelta = Double(q2.c) * Double(q1.c) + Double(q2.s) * Double(q1.s)
    b2Body_SetAngularVelocity(body, Float(atan2(sinDelta, cosDelta) / dt))
  }

  /// Applies an impulse (N·s) at the centre of mass and an angular impulse (N·m·s) about it, e.g. the fluid's
  /// reaction from LabKitMPM's `bodyImpulses`. Δv = J/m and Δω = L/I immediately. Non-finite input is refused.
  public func applyImpulse(_ id: RigidBodyID, linear: SIMD2<Double>, angular: Double) {
    guard let entry = entries[id] else { return }
    guard Self.isFinite(linear), angular.isFinite else { rejectedInputCount += 1; return }
    if linear != .zero { b2Body_ApplyLinearImpulseToCenter(entry.body, Self.vec(linear), true) }
    if angular != 0 { b2Body_ApplyAngularImpulse(entry.body, Float(angular), true) }
  }

  /// Applies an impulse (N·s) at a point in the tank frame (adds the matching angular impulse), e.g. a poke.
  public func applyImpulse(_ id: RigidBodyID, linear: SIMD2<Double>, at point: SIMD2<Double>) {
    guard let entry = entries[id] else { return }
    guard Self.isFinite(linear), Self.isFinite(point) else { rejectedInputCount += 1; return }
    b2Body_ApplyLinearImpulse(entry.body, Self.vec(linear), Self.vec(point), true)
  }

  /// Applies a force (N) at the centre of mass for the next `step` only (Box2D clears forces after each
  /// step), e.g. a magnet on a steel ball or buoyancy. Non-finite input is refused.
  public func applyForce(_ id: RigidBodyID, _ f: SIMD2<Double>) {
    guard let entry = entries[id] else { return }
    guard Self.isFinite(f) else { rejectedInputCount += 1; return }
    b2Body_ApplyForceToCenter(entry.body, Self.vec(f), true)
  }

  /// Applies a torque (N·m) for the next `step` only.
  public func applyTorque(_ id: RigidBodyID, _ torque: Double) {
    guard let entry = entries[id] else { return }
    guard torque.isFinite else { rejectedInputCount += 1; return }
    b2Body_ApplyTorque(entry.body, Float(torque), true)
  }

  /// Pushes dynamic bodies away from `point` (a punch): full strength within `radius`, fading to zero over
  /// `falloff` beyond it. `impulsePerLength` (N·s/m) acts on the part of each outline that faces the blast;
  /// negative values pull inwards.
  public func explode(at point: SIMD2<Double>, radius: Double, falloff: Double = 0, impulsePerLength: Double) {
    guard Self.isFinite(point), radius.isFinite, falloff.isFinite, impulsePerLength.isFinite else {
      rejectedInputCount += 1
      return
    }
    var def = b2DefaultExplosionDef()
    def.position = Self.vec(point)
    def.radius = Float(max(0, radius))
    def.falloff = Float(max(0, falloff))
    def.impulsePerLength = Float(impulsePerLength)
    b2World_Explode(worldID, &def)
  }

  // MARK: Dragging (a soft spring to the finger, so the prop still collides and feels the fluid)

  /// Grabs a dynamic body at `point` (tank frame) with a spring of `stiffness` Hz and `dampingRatio`, capped at
  /// `maxForce` N (default 100 × weight at 9.81 m/s²). Returns false for unknown, kinematic or fixed bodies.
  /// Ends any earlier drag. The spring sags by g/(2π·stiffness)² under gravity: 1.1 mm at the default 15 Hz
  /// (Box2D's samples use 5 Hz, which would hang a prop 1 cm below the finger).
  @discardableResult
  public func beginDrag(
    _ id: RigidBodyID, at point: SIMD2<Double>,
    maxForce: Double? = nil, stiffness: Double = 15, dampingRatio: Double = 0.9
  ) -> Bool {
    endDrag()
    guard let entry = entries[id], entry.kind == .dynamic, Self.isFinite(point) else { return false }
    var def = b2DefaultMouseJointDef()
    def.bodyIdA = anchor
    def.bodyIdB = entry.body
    def.target = Self.vec(point)
    def.hertz = Float(max(0.1, stiffness))
    def.dampingRatio = Float(max(0, dampingRatio))
    let weight = Double(b2Body_GetMass(entry.body)) * 9.81
    def.maxForce = Float(max(0, maxForce ?? 100 * weight))
    let joint = b2CreateMouseJoint(worldID, &def)
    b2Body_SetAwake(entry.body, true)
    drag = (id, joint)
    return true
  }

  /// Moves the drag target (tank frame, m).
  public func updateDrag(to point: SIMD2<Double>) {
    guard let drag, b2Joint_IsValid(drag.joint) else { return }
    guard Self.isFinite(point) else { rejectedInputCount += 1; return }
    b2MouseJoint_SetTarget(drag.joint, Self.vec(point))
    if let entry = entries[drag.id] { b2Body_SetAwake(entry.body, true) }
  }

  public func endDrag() {
    guard let current = drag else { return }
    if b2Joint_IsValid(current.joint) { b2DestroyJoint(current.joint) }
    drag = nil
  }

  // MARK: Stepping and events

  /// Advances the world by `dt` seconds with `subSteps` solver substeps (Box2D's default is 4). Fills `hits`.
  /// Call with fixed `dt` (Rheo: one 1/120 s quantum per call) for reproducible results.
  public func step(dt: Double, subSteps: Int = 4) {
    guard dt.isFinite, dt > 0 else { hits = []; return }
    b2World_Step(worldID, Float(dt), Int32(clamping: max(1, subSteps)))
    collectHits()
  }

  /// Every impact since the previous call (at most `hitBacklogLimit`; the weakest are dropped first), oldest
  /// first. Use it when several `step`s run per display frame and the app plays haptics once per frame.
  public func drainHits() -> [RigidHit] {
    defer { backlog.removeAll(keepingCapacity: true) }
    return backlog
  }

  // MARK: Queries

  /// The body under `point` (tank frame), or within `radius` of it (a fingertip). Prefers dynamic over
  /// kinematic over fixed bodies, then the one whose centre of mass is nearest. Walls are never returned.
  public func query(point: SIMD2<Double>, radius: Double = 0) -> RigidBodyID? {
    guard Self.isFinite(point), radius.isFinite else { return nil }
    var centre = Self.vec(point)
    var proxy = b2MakeProxy(&centre, 1, Float(max(0, radius)))
    var found: [b2ShapeId] = []
    withUnsafeMutablePointer(to: &found) { context in
      _ = b2World_OverlapShape(
        worldID, &proxy, b2DefaultQueryFilter(),
        { shape, context in
          context?.assumingMemoryBound(to: [b2ShapeId].self).pointee.append(shape)
          return true  // keep going
        }, context)
    }
    var best: (id: RigidBodyID, rank: Int, distance: Double)?
    for shape in found {
      guard let id = bodyID(of: shape), let entry = entries[id] else { continue }
      let rank = entry.kind == .dynamic ? 0 : entry.kind == .kinematic ? 1 : 2
      let distance = simd_distance(Self.vec(b2Body_GetWorldCenterOfMass(entry.body)), point)
      if let current = best, (current.rank, current.distance) <= (rank, distance) { continue }
      best = (id, rank, distance)
    }
    return best?.id
  }

  // MARK: Private helpers

  private func collectHits() {
    let events = b2World_GetContactEvents(worldID)
    var stepHits: [RigidHit] = []
    if events.hitCount > 0, let raw = events.hitEvents {
      stepHits.reserveCapacity(Int(events.hitCount))
      for i in 0..<Int(events.hitCount) {
        let event = raw[i]
        let a = bodyID(of: event.shapeIdA), b = bodyID(of: event.shapeIdB)
        stepHits.append(
          RigidHit(
            bodyA: a, bodyB: b,
            tagA: a.flatMap { entries[$0]?.spec.userTag }, tagB: b.flatMap { entries[$0]?.spec.userTag },
            point: Self.vec(event.point), normal: Self.vec(event.normal),
            approachSpeed: Double(event.approachSpeed)))
      }
    }
    hits = stepHits
    guard !stepHits.isEmpty else { return }
    backlog.append(contentsOf: stepHits)
    while backlog.count > Self.hitBacklogLimit {
      guard let weakest = backlog.indices.min(by: { backlog[$0].approachSpeed < backlog[$1].approachSpeed }) else {
        break
      }
      backlog.remove(at: weakest)
    }
  }

  private func bodyID(of shape: b2ShapeId) -> RigidBodyID? {
    guard b2Shape_IsValid(shape) else { return nil }
    guard let raw = b2Body_GetUserData(b2Shape_GetBody(shape)) else { return nil }  // walls, anchor
    let id = RigidBodyID(rawValue: Int(bitPattern: raw))
    return entries[id] != nil ? id : nil
  }

  /// Creates the Box2D shape and returns the shape actually built.
  private static func attach(_ shape: RigidShape, to body: b2BodyId, _ def: b2ShapeDef) -> RigidShape {
    var def = def
    switch shape {
    case .circle(let radius):
      precondition(radius.isFinite && radius > 0, "RigidShape.circle: radius must be positive")
      var circle = b2Circle(center: b2Vec2(x: 0, y: 0), radius: Float(radius))
      _ = b2CreateCircleShape(body, &def, &circle)
      return shape
    case .box(let halfWidth, let halfHeight):
      precondition(
        halfWidth.isFinite && halfHeight.isFinite && halfWidth > 0 && halfHeight > 0,
        "RigidShape.box: half sizes must be positive")
      var polygon = b2MakeBox(Float(halfWidth), Float(halfHeight))
      _ = b2CreatePolygonShape(body, &def, &polygon)
      return shape
    case .capsule(let halfLength, let radius):
      precondition(
        halfLength.isFinite && radius.isFinite && halfLength >= 0 && radius > 0,
        "RigidShape.capsule: halfLength must be ≥ 0 and radius positive")
      var capsule = b2Capsule(
        center1: b2Vec2(x: -Float(halfLength), y: 0), center2: b2Vec2(x: Float(halfLength), y: 0),
        radius: Float(radius))
      _ = b2CreateCapsuleShape(body, &def, &capsule)  // Box2D makes a circle when halfLength is below slop
      return shape
    case .polygon(let points):
      precondition(points.count >= 3 && points.allSatisfy { isFinite($0) }, "RigidShape.polygon: needs ≥ 3 finite vertices")
      let hull = PolygonHull.reduce(PolygonHull.convexHull(points), to: Int(B2_MAX_POLYGON_VERTICES))
      var vertices: [b2Vec2] = hull.map { vec($0) }
      var b2hull = b2ComputeHull(&vertices, Int32(vertices.count))
      if b2hull.count > 0 {
        var polygon = b2MakePolygon(&b2hull, 0)
        _ = b2CreatePolygonShape(body, &def, &polygon)
        let n = Int(polygon.count)
        let built = withUnsafeBytes(of: polygon.vertices) { raw in
          (0..<n).map { vec(raw.load(fromByteOffset: $0 * MemoryLayout<b2Vec2>.stride, as: b2Vec2.self)) }
        }
        return .polygon(built)
      }
      // Box2D refused the hull (collinear, or vertices closer than its 0.5 mm slop): use a disc of equal area,
      // centred on the body origin because `RigidShape.circle` is defined there (an off-centre disc would
      // make `shape(_:)` — and every collider or sprite built from it — disagree with what Box2D simulates).
      let radius = max((RigidShape.polygon(hull).area / Double.pi).squareRoot(), 1e-4)
      var circle = b2Circle(center: b2Vec2(x: 0, y: 0), radius: Float(radius))
      _ = b2CreateCircleShape(body, &def, &circle)
      return .circle(radius: radius)
    }
  }

  private static func bodyType(_ kind: RigidBodyKind) -> b2BodyType {
    switch kind {
    case .dynamic: return b2_dynamicBody
    case .kinematic: return b2_kinematicBody
    case .fixed: return b2_staticBody
    }
  }

  /// Exact rotation. Box2D's own b2MakeRot uses Bhaskara's cosine approximation (≈ 1.6 mrad error measured
  /// by testKinematicTargetTracking before this was added).
  private static func rot(_ angle: Double) -> b2Rot { b2Rot(c: Float(cos(angle)), s: Float(sin(angle))) }
  private static func vec(_ v: SIMD2<Double>) -> b2Vec2 { b2Vec2(x: Float(v.x), y: Float(v.y)) }
  private static func vec(_ v: b2Vec2) -> SIMD2<Double> { SIMD2(Double(v.x), Double(v.y)) }
  private static func isFinite(_ v: SIMD2<Double>) -> Bool { v.x.isFinite && v.y.isFinite }
}

/// `RigidWorld` is deliberately not Sendable: Box2D worlds are single-threaded and Box2D's world table is
/// process-global. This makes any attempt to send one across isolation domains a compile-time error.
@available(*, unavailable)
extension RigidWorld: Sendable {}

/// Convex hull and vertex reduction for `RigidShape.polygon` (Box2D takes at most 8 vertices).
enum PolygonHull {
  /// Andrew's monotone chain: counter-clockwise, collinear points dropped.
  static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
    let p = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
    guard p.count >= 3 else { return p }
    func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [SIMD2<Double>] = []
    for q in p {
      while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
      lower.append(q)
    }
    var upper: [SIMD2<Double>] = []
    for q in p.reversed() {
      while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
      upper.append(q)
    }
    return Array(lower.dropLast() + upper.dropLast())
  }

  /// Removes, one at a time, the vertex whose corner triangle has the least area, until `maxCount` remain.
  static func reduce(_ hull: [SIMD2<Double>], to maxCount: Int) -> [SIMD2<Double>] {
    var v = hull
    while v.count > maxCount {
      var weakest = 0
      var least = Double.infinity
      for i in v.indices {
        let a = v[(i + v.count - 1) % v.count], b = v[i], c = v[(i + 1) % v.count]
        let area = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        if area < least { least = area; weakest = i }
      }
      v.remove(at: weakest)
    }
    return v
  }
}
