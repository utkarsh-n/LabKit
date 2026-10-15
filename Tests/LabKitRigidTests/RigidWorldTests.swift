// LabKitRigid tests. Box2D keeps process-global state (world table, length units), so every Box2D test lives
// in this one XCTestCase (XCTest runs a case's methods one after another) and the package runs
// `swift test --no-parallel` (oss-integration-lessons.md §3.5: parallel suites failed 3 runs in 5).

import XCTest
import simd

@testable import LabKitRigid

final class RigidWorldTests: XCTestCase {
  private let g = 9.81
  private let dt = 1.0 / 120.0
  /// Rheo's tank: 71.2 × 101.4 mm (ARCHITECTURE.md §5.1).
  private let tank = SIMD2(0.0712, 0.1014)

  private func makeWorld(gravity: SIMD2<Double>? = nil, walls: Bool = false) -> RigidWorld {
    let world = RigidWorld(gravity: gravity ?? SIMD2(0, -g))
    if walls { world.addWalls(width: tank.x, height: tank.y, thickness: 0.01) }
    return world
  }

  private func run(_ world: RigidWorld, seconds: Double, each: (Int) -> Void = { _ in }) {
    let steps = Int((seconds / dt).rounded())
    for i in 0..<steps {
      each(i)
      world.step(dt: dt)
    }
  }

  // MARK: Provenance and global state

  func testBox2DVersionAndProcessWideUnits() {
    XCTAssertEqual(RigidUnits.box2DVersion, "3.1.1")
    let world = makeWorld()
    XCTAssertEqual(world.lengthUnitsPerMetre, 0.1)
    XCTAssertEqual(RigidUnits.lengthUnitsPerMetre, 0.1)
    // The scale is fixed for the process: a later, different request is ignored.
    let second = RigidWorld(gravity: .zero, lengthUnitsPerMetre: 1)
    XCTAssertEqual(second.lengthUnitsPerMetre, 0.1)
    XCTAssertEqual(RigidUnits.configure(lengthUnitsPerMetre: 2), 0.1)
    // Scaled tolerances: thresholds of 1 m/s × 0.1.
    XCTAssertEqual(world.restitutionThreshold, 0.1, accuracy: 1e-6)
    XCTAssertEqual(world.hitSpeedThreshold, 0.1, accuracy: 1e-6)
    // Keep both worlds alive past their last use (optimised builds may release them early).
    withExtendedLifetime((world, second)) {
      XCTAssertGreaterThanOrEqual(RigidUnits.liveWorldCount, 2)
    }
  }

  /// Worlds are destroyed with their wrapper (Box2D allows 128 per process).
  func testWorldIsDestroyedWithItsWrapper() {
    let before = RigidUnits.liveWorldCount
    do {
      let world = makeWorld(walls: true)
      _ = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.03, 0.03)))
      world.step(dt: dt)
      withExtendedLifetime(world) { XCTAssertEqual(RigidUnits.liveWorldCount, before + 1) }
    }
    XCTAssertEqual(RigidUnits.liveWorldCount, before)
    for _ in 0..<300 { _ = RigidWorld(gravity: .zero) }  // more than 128 in sequence: slots are recycled
    XCTAssertEqual(RigidUnits.liveWorldCount, before)
  }

  /// Informational, not a gate: the research note's scene (500 awake balls, 3 static walls, 4 substeps).
  func testBenchmark500Balls() {
    let world = RigidWorld(gravity: SIMD2(0, -g))
    world.addWalls(width: 1, height: 10, thickness: 0.1, top: false)
    for i in 0..<500 {
      let x: Double = 0.05 + Double(i % 20) * 0.045
      let y: Double = 0.05 + Double(i / 20) * 0.045
      world.add(RigidBodySpec(shape: .circle(radius: 0.02), position: SIMD2(x, y)))
    }
    for _ in 0..<60 { world.step(dt: dt) }
    let clock = ContinuousClock()
    let elapsed = clock.measure { for _ in 0..<600 { world.step(dt: dt) } }
    let ms = Double(elapsed.components.attoseconds) / 1e15 / 600 + Double(elapsed.components.seconds) * 1000 / 600
    print("WPR benchmark: 500 awake balls, \(ms) ms per step (C at -O2; informational)")
    XCTAssertTrue(world.bodies.allSatisfy { world.pose($0).position.y.isFinite })
  }

  // MARK: Required physics checks (ARCHITECTURE.md §4)

  /// 1 s of free fall at 120 Hz × 4 substeps: Box2D's semi-implicit Euler gives ½gt²(1 + 1/N), N = 480
  /// substeps, i.e. +0.21 %; the contract allows 0.5 %.
  func testFreeFallMatchesHalfGTSquared() {
    let world = makeWorld()
    let ball = world.add(RigidBodySpec(shape: .circle(radius: 0.005), position: SIMD2(0, 10)))
    run(world, seconds: 1)
    let pose = world.pose(ball)
    let t = 120 * Double(Float(dt))
    let expectedDrop = 0.5 * g * t * t
    let drop = 10 - pose.position.y
    let error = abs(drop - expectedDrop) / expectedDrop
    print("WPR free fall: drop \(drop) m vs ½gt² \(expectedDrop) m, error \(error * 100) %")
    XCTAssertLessThanOrEqual(error, 0.005)
    XCTAssertEqual(-pose.velocity.y, g * t, accuracy: g * t * 0.005)
    XCTAssertEqual(pose.position.x, 0, accuracy: 1e-9)
  }

  /// A 1 cm box dropped into the tank comes to rest with its centre at its half height above the floor.
  func testRestingBoxHeight() {
    let world = makeWorld(walls: true)
    let half = 0.005
    let box = world.add(
      RigidBodySpec(shape: .box(halfWidth: half, halfHeight: half), position: SIMD2(0.035, 0.03), density: 10))
    run(world, seconds: 2)
    let pose = world.pose(box)
    print("WPR resting box: centre y \(pose.position.y) m, expected \(half) m, offset \((pose.position.y - half) * 1000) mm")
    XCTAssertEqual(pose.position.y, half, accuracy: 0.0005)  // within Box2D's 0.5 mm slop
    XCTAssertEqual(pose.angle, 0, accuracy: 1e-3)
    XCTAssertLessThan(simd_length(pose.velocity), 1e-3)
  }

  /// A 4 mm bead with e = 0.8 falls 26 mm onto the floor and rebounds to e²·26 mm = 16.6 mm.
  /// (With Box2D's default 1 m/s restitution threshold it would not bounce at all; units 0.1 make it 0.1 m/s.)
  func testRestitutionBounceHeight() {
    let world = makeWorld(walls: true)
    let r = 0.004, fall = 0.026, e = 0.8
    let bead = world.add(
      RigidBodySpec(shape: .circle(radius: r), position: SIMD2(0.035, r + fall), restitution: e))
    var bounced = false
    var apex = 0.0
    for _ in 0..<240 {
      world.step(dt: dt)
      let pose = world.pose(bead)
      if !bounced && pose.velocity.y > 0 { bounced = true }
      if bounced {
        apex = max(apex, pose.position.y - r)
        if pose.velocity.y < 0 { break }
      }
    }
    let expected = e * e * fall
    print("WPR bounce: apex \(apex * 1000) mm vs e²h \(expected * 1000) mm")
    XCTAssertTrue(bounced)
    XCTAssertEqual(apex, expected, accuracy: expected * 0.05)
  }

  /// A kinematic paddle follows a circular path exactly, and stops dead when its target stops moving
  /// (Box2D 3.1.1's b2Body_SetTargetTransform alone would leave it drifting at its last speed).
  func testKinematicTargetTracking() {
    let world = makeWorld(walls: true)
    let centre = SIMD2(0.035, 0.05), radius = 0.02, omega = 2 * Double.pi
    let paddle = world.add(
      RigidBodySpec(kind: .kinematic, shape: .box(halfWidth: 0.01, halfHeight: 0.002), position: centre + SIMD2(radius, 0)))
    var worstPosition = 0.0, worstAngle = 0.0
    for i in 1...120 {
      let t = Double(i) * dt
      let target = centre + radius * SIMD2(cos(omega * t), sin(omega * t))
      let angle = remainder(omega * t, 2 * Double.pi)
      world.setTarget(paddle, position: target, angle: angle, dt: dt)
      world.step(dt: dt)
      let pose = world.pose(paddle)
      worstPosition = max(worstPosition, simd_distance(pose.position, target))
      worstAngle = max(worstAngle, abs(remainder(pose.angle - angle, 2 * Double.pi)))
    }
    print("WPR kinematic: worst position error \(worstPosition) m, worst angle error \(worstAngle) rad")
    XCTAssertLessThan(worstPosition, 1e-5)
    XCTAssertLessThan(worstAngle, 1e-4)  // b2MakeRot's approximation alone would give ≈ 1.6e-3

    // Stop: target = where it is now. Box2D skips "sleepy" targets; the wrapper must zero the velocity.
    let held = world.pose(paddle)
    for _ in 0..<60 {
      world.setTarget(paddle, position: held.position, angle: held.angle, dt: dt)
      world.step(dt: dt)
    }
    let after = world.pose(paddle)
    XCTAssertLessThan(simd_distance(after.position, held.position), 1e-6)
    XCTAssertEqual(simd_length(after.velocity), 0, accuracy: 1e-9)
    XCTAssertEqual(after.angularVelocity, 0, accuracy: 1e-9)
    XCTAssertEqual(world.mass(paddle), 0)  // kinematic: infinite mass
  }

  /// Δv = J/m and Δω = L/I, immediately, for the fluid → body coupling.
  func testImpulseChangesVelocityByJOverM() {
    let world = makeWorld(gravity: .zero)
    let density = 12.5
    let body = world.add(
      RigidBodySpec(shape: .box(halfWidth: 0.005, halfHeight: 0.003), position: SIMD2(0.03, 0.04), density: density))
    let m = world.mass(body)
    XCTAssertEqual(m, density * 4 * 0.005 * 0.003, accuracy: m * 1e-5)
    let inertia = world.rotationalInertia(body)
    XCTAssertEqual(inertia, m * (0.01 * 0.01 + 0.006 * 0.006) / 12, accuracy: inertia * 1e-4)

    let before = world.pose(body)
    let j = SIMD2(2e-4, -1e-4), l = 3e-8
    world.applyImpulse(body, linear: j, angular: l)
    let after = world.pose(body)
    let dv = after.velocity - before.velocity
    print("WPR impulse: Δv \(dv) vs J/m \(j / m); Δω \(after.angularVelocity) vs L/I \(l / inertia)")
    XCTAssertEqual(dv.x, j.x / m, accuracy: abs(j.x / m) * 1e-5)
    XCTAssertEqual(dv.y, j.y / m, accuracy: abs(j.y / m) * 1e-5)
    XCTAssertEqual(after.angularVelocity, l / inertia, accuracy: (l / inertia) * 1e-5)

    // The new velocity carries the body: one step moves it by v·dt.
    world.step(dt: dt)
    let moved = world.pose(body).position - before.position
    XCTAssertEqual(moved.x, j.x / m * dt, accuracy: abs(j.x / m * dt) * 1e-4)
  }

  /// Buoyancy-style balance: a force equal to the weight holds a body still; half of it halves the
  /// acceleration; and a force lasts one step only.
  func testForceBalanceWithApplyForce() {
    let world = makeWorld()
    let spec = RigidBodySpec(shape: .circle(radius: 0.004), position: SIMD2(0, 1), density: 78.5)  // steel, 1 cm deep
    let floating = world.add(spec)
    var halfSpec = spec
    halfSpec.position = SIMD2(0.1, 1)
    let sinking = world.add(halfSpec)
    let m = world.mass(floating)
    run(world, seconds: 1) { _ in
      world.applyForce(floating, SIMD2(0, m * self.g))
      world.applyForce(sinking, SIMD2(0, 0.5 * m * self.g))
    }
    let still = world.pose(floating)
    XCTAssertEqual(still.position.y, 1, accuracy: 1e-6)
    XCTAssertEqual(simd_length(still.velocity), 0, accuracy: 1e-6)

    let t = 120 * Double(Float(dt))
    let expectedDrop = 0.25 * g * t * t
    let drop = 1 - world.pose(sinking).position.y
    print("WPR force balance: hover drift \(still.position.y - 1) m; half-weight drop \(drop) m vs ¼gt² \(expectedDrop) m")
    XCTAssertEqual(drop, expectedDrop, accuracy: expectedDrop * 0.005)

    // A single force acts for one step only (Box2D clears forces after each step).
    let world2 = makeWorld(gravity: .zero)
    let puck = world2.add(RigidBodySpec(shape: .circle(radius: 0.004), position: .zero))
    let f = SIMD2(1e-3, 0)
    world2.applyForce(puck, f)
    world2.step(dt: dt)
    let v1 = world2.pose(puck).velocity.x
    world2.step(dt: dt)
    XCTAssertEqual(v1, f.x / world2.mass(puck) * dt, accuracy: v1 * 1e-4)
    XCTAssertEqual(world2.pose(puck).velocity.x, v1, accuracy: 1e-12)
  }

  func testPointQuery() {
    let world = makeWorld(gravity: .zero, walls: true)
    let ball = world.add(RigidBodySpec(shape: .circle(radius: 0.005), position: SIMD2(0.02, 0.02)))
    let paddle = world.add(
      RigidBodySpec(kind: .kinematic, shape: .box(halfWidth: 0.005, halfHeight: 0.005), position: SIMD2(0.05, 0.05)))
    XCTAssertEqual(world.query(point: SIMD2(0.022, 0.021)), ball)
    XCTAssertEqual(world.query(point: SIMD2(0.054, 0.046)), paddle)
    XCTAssertNil(world.query(point: SIMD2(0.035, 0.08)))
    XCTAssertNil(world.query(point: SIMD2(-0.005, 0.05)))  // inside the left wall: walls are never picked
    // Fingertip tolerance: 2 mm outside the ball.
    XCTAssertNil(world.query(point: SIMD2(0.027, 0.02), radius: 0.001))
    XCTAssertEqual(world.query(point: SIMD2(0.027, 0.02), radius: 0.003), ball)
    // Overlap: a dynamic body wins over a fixed one under the same point.
    let shelf = world.add(
      RigidBodySpec(kind: .fixed, shape: .box(halfWidth: 0.01, halfHeight: 0.002), position: SIMD2(0.035, 0.07)))
    XCTAssertEqual(world.query(point: SIMD2(0.035, 0.07)), shelf)
    let bead = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.035, 0.071)))
    XCTAssertEqual(world.query(point: SIMD2(0.035, 0.07)), bead)
  }

  /// A bead dropped 2 cm reports one impact with the floor at ≈ √(2gh); a resting bead reports none.
  func testHitEventsReportImpactSpeed() {
    let world = makeWorld(walls: true)
    let r = 0.004, h = 0.02
    let bead = world.add(RigidBodySpec(shape: .circle(radius: r), position: SIMD2(0.035, r + h), userTag: 7))
    var impacts: [RigidHit] = []
    run(world, seconds: 0.5) { _ in impacts += world.hits }
    let expected = (2 * g * h).squareRoot()
    XCTAssertEqual(impacts.count, 1, "\(impacts)")
    guard let hit = impacts.first else { return }
    print("WPR hit: approach \(hit.approachSpeed) m/s vs √(2gh) \(expected) m/s at \(hit.point)")
    XCTAssertTrue(hit.involves(bead))
    XCTAssertTrue(hit.involvesWall)
    XCTAssertEqual(hit.bodyA == bead ? hit.tagA : hit.tagB, 7)
    // Box2D reads the approach speed at the start of the step that resolves the contact. A speculative contact
    // reads it before the bead has finished accelerating (up to g·dt low); continuous collision stops a fast
    // bead at the floor but keeps its end-of-step speed (up to g·dt high). Measured: 0.654 vs 0.626 m/s.
    XCTAssertEqual(hit.approachSpeed, expected, accuracy: g * dt + 0.01)
    XCTAssertEqual(hit.point.y, 0, accuracy: 0.002)
    XCTAssertEqual(abs(hit.normal.y), 1, accuracy: 1e-3)

    // drainHits keeps everything since the last drain, then empties.
    XCTAssertEqual(world.drainHits().count, 1)
    XCTAssertTrue(world.drainHits().isEmpty)

    // Resting: no hits.
    run(world, seconds: 1) { _ in XCTAssertTrue(world.hits.isEmpty) }

    // Above the threshold only.
    let quiet = makeWorld(walls: true)
    quiet.hitSpeedThreshold = 1
    _ = quiet.add(RigidBodySpec(shape: .circle(radius: r), position: SIMD2(0.035, r + h)))
    run(quiet, seconds: 0.5)
    XCTAssertTrue(quiet.drainHits().isEmpty)
  }

  // MARK: Behaviour the app relies on

  func testIdenticalRunsAreBitwiseEqual() {
    func simulate() -> [RigidPose] {
      let world = makeWorld(walls: true)
      var ids: [RigidBodyID] = []
      for i in 0..<20 {
        let shape: RigidShape = i % 2 == 0 ? .circle(radius: 0.003) : .box(halfWidth: 0.003, halfHeight: 0.002)
        let x: Double = 0.01 + Double(i % 5) * 0.012
        let y: Double = 0.03 + Double(i / 5) * 0.012
        ids.append(world.add(RigidBodySpec(shape: shape, position: SIMD2(x, y), angle: Double(i) * 0.3, restitution: 0.3)))
      }
      run(world, seconds: 2.5)
      return ids.map { world.pose($0) }
    }
    let a = simulate(), b = simulate()
    XCTAssertEqual(a, b)
    XCTAssertTrue(a.allSatisfy { simd_length($0.velocity) < 0.01 }, "beads should have settled")
  }

  func testRemoveAndIdsAreNeverReused() {
    let world = makeWorld(walls: true)
    let a = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.01, 0.05)))
    let b = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.02, 0.05)))
    let c = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.03, 0.05)))
    XCTAssertEqual(world.bodies, [a, b, c])
    world.remove(b)
    XCTAssertEqual(world.bodies, [a, c])
    XCTAssertFalse(world.contains(b))
    XCTAssertEqual(world.pose(b), .zero)
    XCTAssertEqual(world.mass(b), 0)
    world.applyImpulse(b, linear: SIMD2(1, 1), angular: 0)  // ignored, no crash
    world.removeAll()
    XCTAssertTrue(world.bodies.isEmpty)
    XCTAssertTrue(world.hasWalls)  // walls survive removeAll
    let d = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.03, 0.05)))
    XCTAssertGreaterThan(d, c)
    run(world, seconds: 1)
    XCTAssertEqual(world.pose(d).position.y, 0.003, accuracy: 0.0005)  // walls still catch it
  }

  /// The tank walls' inner faces sit exactly on the rectangle: tilt gravity sideways and a bead rests
  /// against the right wall at x = width − r. Changing gravity also wakes a sleeping body.
  func testWallsAndGravityTilt() {
    let world = makeWorld(walls: true)
    let r = 0.004
    let bead = world.add(
      RigidBodySpec(shape: .circle(radius: r), position: SIMD2(0.03, 0.02), enableSleep: true))
    run(world, seconds: 2)  // settles and falls asleep on the floor
    world.gravity = SIMD2(g, 0)
    run(world, seconds: 2)
    let pose = world.pose(bead)
    XCTAssertEqual(pose.position.x, tank.x - r, accuracy: 0.0005)
    world.gravity = SIMD2(0, g)  // upside down: the closed top holds it
    run(world, seconds: 2)
    XCTAssertEqual(world.pose(bead).position.y, tank.y - r, accuracy: 0.0005)
  }

  /// Why `enableSleep` defaults to false: a nearly neutrally buoyant bead sinking at 3 mm/s (below Box2D's
  /// 5 mm/s sleep threshold at units 0.1) keeps sinking only when sleep is off.
  ///
  /// Box2D damps only the carried velocity, v ← h·a + v/(1 + h·c), so the terminal speed is a/c + a·h: with
  /// full gravity it can never drop below g·h ≈ 20 mm/s at 480 substeps/s. Hence the weak effective gravity
  /// here (gravity minus buoyancy), as a fluid-coupled bead would feel.
  func testSlowSinkingBeadStaysAwake() {
    let a = 0.01, c = 10.0 / 3.0  // terminal speed a/c = 3 mm/s
    let world = makeWorld(gravity: SIMD2(0, -a))
    let awake = world.add(
      RigidBodySpec(shape: .circle(radius: 0.002), position: SIMD2(0, 1), linearDamping: c))
    let sleepy = world.add(
      RigidBodySpec(shape: .circle(radius: 0.002), position: SIMD2(0.1, 1), linearDamping: c, enableSleep: true))
    run(world, seconds: 2)
    let awakeDrop = 1 - world.pose(awake).position.y
    let sleepyDrop = 1 - world.pose(sleepy).position.y
    let terminal = a / c, expected = terminal * (2 - (1 - exp(-2 * c)) / c)
    print("WPR sleep: awake bead sank \(awakeDrop * 1000) mm (model \(expected * 1000) mm), sleep-enabled bead \(sleepyDrop * 1000) mm in 2 s")
    XCTAssertEqual(awakeDrop, expected, accuracy: expected * 0.05)
    XCTAssertLessThan(sleepyDrop, 0.0015)  // asleep after 0.5 s, frozen mid-fluid
  }

  func testDragPullsBodyToFinger() {
    let world = makeWorld(walls: true)
    let r = 0.004
    let bead = world.add(RigidBodySpec(shape: .circle(radius: r), position: SIMD2(0.02, r)))
    let paddle = world.add(
      RigidBodySpec(kind: .kinematic, shape: .circle(radius: 0.003), position: SIMD2(0.06, 0.09)))
    XCTAssertFalse(world.beginDrag(paddle, at: SIMD2(0.06, 0.09)))
    run(world, seconds: 0.5)
    XCTAssertTrue(world.beginDrag(bead, at: world.pose(bead).position))
    XCTAssertEqual(world.draggedBody, bead)
    let finger = SIMD2(0.04, 0.06)
    run(world, seconds: 1) { _ in world.updateDrag(to: finger) }
    let gap = simd_distance(world.pose(bead).position, finger)
    print("WPR drag: bead \(gap * 1000) mm from the finger after 1 s (spring sag g/ω² = 1.1 mm)")
    XCTAssertLessThan(gap, 0.002)
    world.endDrag()
    XCTAssertNil(world.draggedBody)
    run(world, seconds: 1)
    XCTAssertEqual(world.pose(bead).position.y, r, accuracy: 0.0005)  // released, it falls back
  }

  func testPolygonIsReducedToEightVertices() {
    let world = makeWorld(gravity: .zero)
    let ring = (0..<12).map { i -> SIMD2<Double> in
      let a = Double(i) * 2 * Double.pi / 12
      return 0.005 * SIMD2(cos(a), sin(a))
    }
    let density = 10.0
    let gem = world.add(RigidBodySpec(shape: .polygon(ring), position: SIMD2(0.03, 0.03), density: density))
    guard case .polygon(let built) = world.shape(gem) else { return XCTFail("expected a polygon") }
    // The wrapper reduces 12 → 8; Box2D's hull then drops vertices within 2 × slop (1 mm) of their
    // neighbours' chord, so `shape(_:)` reports what Box2D really built (7 here).
    print("WPR polygon: 12-gon built as \(built.count) vertices")
    XCTAssertLessThanOrEqual(built.count, 8)
    XCTAssertGreaterThanOrEqual(built.count, 6)
    let area = world.shape(gem).area
    XCTAssertLessThan(area, RigidShape.polygon(ring).area)
    XCTAssertGreaterThan(area, 0.85 * RigidShape.polygon(ring).area)
    XCTAssertEqual(world.mass(gem), density * area, accuracy: density * area * 1e-4)

    // Collinear points: Box2D refuses the hull; the wrapper falls back to a disc. `RigidShape.circle` is centred
    // on the body origin, so the disc Box2D simulates must be too (its centre of mass is the body origin).
    let sliver = world.add(
      RigidBodySpec(shape: .polygon([SIMD2(0, 0), SIMD2(0.001, 0), SIMD2(0.002, 0)]), position: SIMD2(0.01, 0.01)))
    guard case .circle(let radius) = world.shape(sliver) else { return XCTFail("expected a disc fallback") }
    XCTAssertEqual(simd_distance(world.centreOfMass(sliver), world.pose(sliver).position), 0, accuracy: 1e-9)
    XCTAssertEqual(world.mass(sliver), 10 * Double.pi * radius * radius, accuracy: world.mass(sliver) * 1e-4)
  }

  /// Off-centre impulses, torques and teleports, which the app uses for pokes, spins and resets.
  func testPointImpulseTorqueTeleportAndWallRemoval() {
    let world = makeWorld(gravity: .zero)
    let body = world.add(
      RigidBodySpec(shape: .box(halfWidth: 0.006, halfHeight: 0.004), position: SIMD2(0.03, 0.04), density: 20))
    let m = world.mass(body), inertia = world.rotationalInertia(body)

    // Impulse J at a point p: Δv = J/m and Δω = (p − c) × J / I.
    let j = SIMD2(0.0, 1e-4), p = SIMD2(0.036, 0.04)
    world.applyImpulse(body, linear: j, at: p)
    let r = p - world.centreOfMass(body)
    let expectedOmega = (r.x * j.y - r.y * j.x) / inertia
    var pose = world.pose(body)
    XCTAssertEqual(pose.velocity.y, j.y / m, accuracy: abs(j.y / m) * 1e-5)
    XCTAssertEqual(pose.angularVelocity, expectedOmega, accuracy: abs(expectedOmega) * 1e-5)

    // Torque τ for one step: Δω = τ·dt/I, then no more (Box2D clears torques after each step).
    world.setVelocity(body, linear: .zero, angular: 0)
    let tau = 2e-7
    world.applyTorque(body, tau)
    world.step(dt: dt)
    let omega1 = world.pose(body).angularVelocity
    XCTAssertEqual(omega1, tau * Double(Float(dt)) / inertia, accuracy: abs(omega1) * 1e-4)
    world.step(dt: dt)
    XCTAssertEqual(world.pose(body).angularVelocity, omega1, accuracy: 1e-12)

    // Teleport: position and angle are set exactly (to Float precision); velocity is kept.
    world.setTransform(body, position: SIMD2(0.05, 0.02), angle: 0.7)
    pose = world.pose(body)
    XCTAssertEqual(pose.position.x, 0.05, accuracy: 1e-8)
    XCTAssertEqual(pose.position.y, 0.02, accuracy: 1e-8)
    XCTAssertEqual(pose.angle, 0.7, accuracy: 1e-6)
    XCTAssertEqual(pose.angularVelocity, omega1, accuracy: 1e-12)

    // Removing the walls lets a bead fall out of the tank.
    let tank = makeWorld(walls: true)
    let bead = tank.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.03, 0.02)))
    run(tank, seconds: 0.5)
    XCTAssertEqual(tank.pose(bead).position.y, 0.003, accuracy: 0.0005)
    tank.removeWalls()
    XCTAssertFalse(tank.hasWalls)
    run(tank, seconds: 0.5)
    XCTAssertLessThan(tank.pose(bead).position.y, -0.5)
  }

  /// A NaN or infinite gravity (a bad sensor sample) is refused instead of poisoning every body.
  func testNonFiniteGravityIsRefused() {
    let world = makeWorld()
    let bead = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0, 1)))
    world.gravity = SIMD2(.nan, -g)
    world.gravity = SIMD2(0, -.infinity)
    XCTAssertEqual(world.gravity, SIMD2(0, -g))
    XCTAssertEqual(world.rejectedInputCount, 2)
    run(world, seconds: 1)
    let pose = world.pose(bead)
    XCTAssertTrue(pose.position.x.isFinite && pose.position.y.isFinite)
    XCTAssertEqual(-pose.velocity.y, g * 120 * Double(Float(dt)), accuracy: 1e-3)
    // A positive dt that is zero in Float would give an infinite target velocity: refused too.
    let tool = world.add(RigidBodySpec(kind: .kinematic, shape: .circle(radius: 0.003), position: .zero))
    world.setTarget(tool, position: SIMD2(0.01, 0), angle: 0, dt: 1e-60)
    XCTAssertEqual(world.rejectedInputCount, 3)
    XCTAssertEqual(world.pose(tool).velocity, .zero)
  }

  func testNonFiniteInputIsRefused() {
    let world = makeWorld(gravity: .zero)
    let bead = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.03, 0.03)))
    world.applyImpulse(bead, linear: SIMD2(.nan, 0), angular: 0)
    world.applyForce(bead, SIMD2(0, .infinity))
    world.setTarget(bead, position: SIMD2(.nan, 0), angle: 0, dt: dt)
    world.step(dt: dt)
    XCTAssertEqual(world.rejectedInputCount, 3)
    let start = SIMD2(Double(Float(0.03)), Double(Float(0.03)))  // Box2D stores Float
    XCTAssertEqual(world.pose(bead).position, start)
    world.step(dt: .nan)  // ignored
    XCTAssertEqual(world.pose(bead).position, start)
  }

  func testExplosionPushesBodiesAway() {
    let world = makeWorld(gravity: .zero)
    let near = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.01, 0)))
    let far = world.add(RigidBodySpec(shape: .circle(radius: 0.003), position: SIMD2(0.2, 0)))
    world.explode(at: .zero, radius: 0.02, falloff: 0.01, impulsePerLength: 0.01)
    world.step(dt: dt)
    XCTAssertGreaterThan(world.pose(near).velocity.x, 0)
    XCTAssertEqual(simd_length(world.pose(far).velocity), 0)
  }

  func testInitialVelocityIsTheBodyOriginVelocity() {
    let world = makeWorld(gravity: .zero)
    // An off-centre triangle: centre of mass ≠ body origin.
    let tri = world.add(
      RigidBodySpec(
        shape: .polygon([SIMD2(0, 0), SIMD2(0.01, 0), SIMD2(0, 0.01)]), position: SIMD2(0.03, 0.03),
        velocity: SIMD2(0.1, 0), angularVelocity: 2))
    let pose = world.pose(tri)
    XCTAssertEqual(pose.velocity.x, 0.1, accuracy: 1e-6)
    XCTAssertEqual(pose.velocity.y, 0, accuracy: 1e-6)
    XCTAssertEqual(pose.angularVelocity, 2, accuracy: 1e-6)
    let com = world.centreOfMass(tri)
    XCTAssertEqual(com.x, 0.03 + 0.01 / 3, accuracy: 1e-6)
    // RigidPose.velocity(at:) gives the rigid velocity field.
    let vCom = pose.velocity(at: com)
    XCTAssertEqual(vCom.x, 0.1 - 2 * (com.y - 0.03), accuracy: 1e-7)  // Box2D stores Float
  }
}
