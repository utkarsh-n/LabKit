import CoreGraphics
import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPM

// Solver checks on the Mac GPU: dam break timings, Π–volume table, mass, buoyancy, material runs.

let qualities: [(name: String, q: MPMQuality)] = [("2.0 mm", .standard), ("1.6 mm", .high), ("1.1 mm", .bench)]

/// Water column 35 × 90 mm at the left wall of the life-size tank (71.2 × 101.4 mm); settles to a ≈ 44 mm pool.
func damBreakRig(_ device: MTLDevice, quality: MPMQuality, verification: MPMVerificationOptions = MPMVerificationOptions(),
                 material: ContinuumMaterial = ContinuumPresets.waterLike, width: Double = 0.035, height: Double = 0.09,
                 gap: Double = 0) throws -> (Rig, Int) {
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: gap), quality: quality, verification: verification,
                    materials: [material])
  let n = rig.solver.fill(rect: CGRect(x: 0, y: 0, width: width, height: height), material: 0, temperature: 293.15)
  return (rig, n)
}

func checkDamBreak(_ device: MTLDevice, _ report: Report) throws {
  print("\n== G1 Dam break, 3 s, substep rule Π ≤ 0.07 (water column 35 × 90 mm, no thin-tank drag) ==")
  print("| Δx | cells | particles | substeps (median, max) | Π at 44 mm | occupancy | mean J | peak v (m/s) | v at 3 s | clamps | overflow | NaN | GPU ms/frame median (p90) |")
  print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
  for (name, q) in qualities {
    let (rig, n) = try damBreakRig(device, quality: q)
    var peak = 0.0
    var subs: [Int] = []
    rig.run(10)
    rig.resetTimes()
    let st = rig.run(350) { _, s in peak = max(peak, s.maxSpeed); subs.append(s.substeps) }
    let occ = rig.occupancy(initialParticles: n)
    let sorted = subs.sorted()
    let S = sorted[sorted.count / 2]
    let dt = 1.0 / 120 / Double(S)
    let dx = rig.solver.cellSize
    let pi = 9.81 * dt * dt * 0.044 / (dx * dx)
    let t = rig.timing
    let cells = rig.solver.interiorCells
    print("| \(name) | \(cells.x) × \(cells.y) | \(n) | \(S), \(sorted.last ?? 0) | \(fmt(pi)) | \(fmt(occ)) | \(fmt(st.volumeRatio)) | \(fmt(peak, 2)) | \(fmt(st.maxSpeed, 3)) | \(st.clampedDisplacements) | \(st.overflowCount) | \(st.nanCount) | \(fmt(t.median, 2)) (\(fmt(t.p90, 2))) |")
    // No thin-tank drag here, so the pool keeps sloshing (PB liquids are lightly damped, mpm-metal.md §9.3): "settled"
    // means below 10 % of the peak speed.
    let ok = st.nanCount == 0 && st.overflowCount == 0 && st.maxSpeed < 0.1 * peak && occ > 0.95 && st.volumeRatio > 0.94
      && st.liveParticles == n
    report.add("G1-\(name)", "dam break \(name)", pass: ok,
               "occupancy \(fmt(occ)), J \(fmt(st.volumeRatio)), v(3 s) \(fmt(st.maxSpeed, 3)) m/s, S \(S), GPU \(fmt(t.median, 2)) ms/frame, NaN \(st.nanCount), overflow \(st.overflowCount)")
  }
}

func checkPiTable(_ device: MTLDevice, _ report: Report) throws {
  print("\n== G2 Π–volume table (fixed substeps, N = 3, same dam break, 3 s) ==")
  print("| Δx | S × N per 1/120 s | Π at 44 mm | occupancy | mean J | v at 3 s (m/s) | clamps | GPU ms/frame |")
  print("|---|---|---|---|---|---|---|---|")
  var rows: [(q: String, pi: Double, occ: Double, j: Double)] = []
  for (name, q, list) in [("2.0 mm", MPMQuality.standard, [4, 8, 12, 16, 24]), ("1.1 mm", MPMQuality.bench, [8, 16, 24, 32])] {
    for S in list {
      var v = MPMVerificationOptions()
      v.fixedSubsteps = S
      let (rig, n) = try damBreakRig(device, quality: q, verification: v)
      rig.run(10)
      rig.resetTimes()
      let st = rig.run(350)
      let occ = rig.occupancy(initialParticles: n)
      let dt = 1.0 / 120 / Double(S), dx = rig.solver.cellSize
      let pi = 9.81 * dt * dt * 0.044 / (dx * dx)
      rows.append((name, pi, occ, st.volumeRatio))
      print("| \(name) | \(S) × 3 | \(fmt(pi)) | \(fmt(occ)) | \(fmt(st.volumeRatio)) | \(fmt(st.maxSpeed, 3)) | \(st.clampedDisplacements) | \(fmt(rig.timing.median, 2)) |")
    }
  }
  // Π collapses resolutions: at Π ≤ 0.085 the mean J stays ≥ 0.95 and occupancy ≥ 0.95 on both grids.
  let low = rows.filter { $0.pi <= 0.085 }
  let ok = !low.isEmpty && low.allSatisfy { $0.occ >= 0.95 && $0.j >= 0.95 }
  report.add("G2", "Π ≤ 0.085 keeps ≥ 95 % of the volume (mean J and occupancy)", pass: ok,
             low.map { "\($0.q) Π \(fmt($0.pi)): J \(fmt($0.j)), occupancy \(fmt($0.occ))" }.joined(separator: "; "))
}

func checkMass(_ device: MTLDevice, _ report: Report) throws {
  print("\n== G3 Mass conservation (exact grid mass of the frame's last P2G vs particle mass) ==")
  var v = MPMVerificationOptions()
  v.sampleGridMass = true
  let (rig, n) = try damBreakRig(device, quality: .standard, verification: v)
  let expected = Double(n) * 0.25 * 1000 * pow(rig.solver.cellSize, 2)
  var worst = 0.0
  rig.run(240) { f, s in
    guard f % 10 == 9, let g = s.gridMass else { return }
    worst = max(worst, abs(g - expected) / expected, abs(s.particleMass - expected) / expected)
  }
  report.add("G3", "grid mass = particle mass", pass: worst < 1e-6, "worst relative error \(sci(worst)) over 2 s")
}

/// Mean vertical fluid force on a static body in a 70 mm pool, / (ρ g A gap).
func buoyancyRatio(_ device: MTLDevice, quality: MPMQuality, disc: Bool, shift: Double, skin: Double) throws -> Double {
  var water = ContinuumPresets.waterLike
  water.consistency = 0.05
  let gap = 0.005
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: gap, heleShawMinTime: 0), quality: quality, materials: [water])
  rig.solver.colliderSkin = skin
  let W = rig.solver.domain.size.x, dx = rig.solver.cellSize
  let half = disc ? SIMD2(0.007, 0.007) : SIMD2(0.011, 0.0055)
  let centre = SIMD2(W / 2, 0.035) + shift * dx
  if disc {
    let outline = (0...64).map { i in centre + half.x * SIMD2(-cos(Double(i) * .pi / 32), sin(Double(i) * .pi / 32)) }
    rig.solver.fill(polygon: [SIMD2(0, centre.y), SIMD2(0, 0), SIMD2(W, 0), SIMD2(W, 0.07), SIMD2(0, 0.07), SIMD2(0, centre.y)] + outline,
                    material: 0, temperature: 293.15)
  } else {
    let lo = centre - half, hi = centre + half
    for r in [CGRect(x: 0, y: 0, width: W, height: lo.y), CGRect(x: 0, y: hi.y, width: W, height: 0.07 - hi.y),
              CGRect(x: 0, y: lo.y, width: lo.x, height: hi.y - lo.y), CGRect(x: hi.x, y: lo.y, width: W - hi.x, height: hi.y - lo.y)] {
      rig.solver.fill(rect: r, material: 0, temperature: 293.15)
    }
  }
  var input = MPMFrameInput()
  input.colliders = [MPMCollider(shape: disc ? .circle(radius: half.x) : .box(halfSize: half), position: centre, friction: 0, bodyIndex: 0)]
  var jy = 0.0, t = 0.0
  rig.run(480, input: input) { f, s in
    guard f >= 240 else { return }
    jy += s.bodyImpulses[0].y; t += s.simulatedTime
  }
  let area = disc ? Double.pi * half.x * half.x : 4 * half.x * half.y
  return jy / t / (1000 * 9.81 * area * gap)
}

func checkBuoyancy(_ device: MTLDevice, _ report: Report) throws {
  print("\n== G4 Buoyancy from bodyImpulses: F_y / (ρ g A gap), mean over t = 2–4 s, static body in a 70 mm water pool ==")
  print("| body | Δx | skin 0: shift 0 | skin 1 (default): shift 0 / ¼ / ½ cell |")
  print("|---|---|---|---|")
  var all: [Double] = [], bench: [Double] = []
  for disc in [false, true] {
    for (name, q) in qualities {
      let r0 = try buoyancyRatio(device, quality: q, disc: disc, shift: 0, skin: 0)
      let r1 = try [0.0, 0.25, 0.5].map { try buoyancyRatio(device, quality: q, disc: disc, shift: $0, skin: 1) }
      all += r1
      if q == .bench { bench += r1 }
      print("| \(disc ? "disc r 7 mm" : "box 22 × 11 mm") | \(name) | \(fmt(r0)) | \(r1.map { fmt($0) }.joined(separator: " / ")) |")
    }
  }
  report.add("G4a", "buoyancy at Δx 1.1 mm within 5 %", pass: bench.allSatisfy { abs($0 - 1) <= 0.05 },
             "\(bench.map { fmt($0) }.joined(separator: ", "))")
  report.add("G4b", "buoyancy at Δx 1.1–2 mm within 15 %", pass: all.allSatisfy { abs($0 - 1) <= 0.15 },
             "range \(fmt(all.min() ?? 0))–\(fmt(all.max() ?? 0))")
}

// MARK: Materials

/// Dam break of a 44 × 66 mm column (mpm-metal.md §11.5) with the production thin-tank drag (gap 10 mm, t_HS ≥ 0.1 s).
func materialDamBreak(_ device: MTLDevice, _ m: ContinuumMaterial, seconds: Double) throws
  -> (rig: Rig, peak: Double, end: MPMStats, surface: [Double], residual: Double, yielding: Double) {
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1), quality: .standard, materials: [m])
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: 0.044, height: 0.066), material: 0, temperature: m.referenceTemperature)
  var peak = 0.0
  let end = rig.run(Int(seconds * 120)) { _, s in peak = max(peak, s.maxSpeed) }
  let ps = rig.particles
  let residual = ps.map(\.stress).max() ?? 0
  let yielding = Double(ps.filter { $0.plasticRate > 1e-3 }.count) / Double(max(ps.count, 1))
  return (rig, peak, end, rig.surface(at: [0.1, 0.3, 0.5, 0.7, 0.9]), residual, yielding)
}

func checkMaterials(_ device: MTLDevice, _ report: Report) throws {
  print("\n== M1–M3 Material dam breaks (44 × 66 mm column, Δx 2 mm, thin-tank gap 10 mm) ==")
  print("| preset | τ_y (Pa) | peak v (m/s) | v at end (m/s) | KE at end (J) | surface at 10/30/50/70/90 % (mm) | max residual τ̄ (Pa) | still yielding |")
  print("|---|---|---|---|---|---|---|---|")
  for (name, m, seconds) in [("Honey", ContinuumPresets.honey, 4.0), ("Toothpaste", ContinuumPresets.toothpaste, 3.0),
                             ("Ketchup", ContinuumPresets.ketchup, 3.0), ("Mayonnaise", ContinuumPresets.mayonnaise, 3.0)] {
    let r = try materialDamBreak(device, m, seconds: seconds)
    let ty = m.yieldBroken + m.yieldStructure
    let surf = r.surface.map { fmt($0 * 1000, 1) }.joined(separator: " / ")
    print("| \(name) | \(fmt(ty, 0)) | \(fmt(r.peak, 3)) | \(fmt(r.end.maxSpeed, 4)) | \(sci(r.end.kineticEnergy)) | \(surf) | \(fmt(r.residual, 1)) | \(fmt(100 * r.yielding, 0)) % |")
    let spread = (r.surface.max() ?? 0) - (r.surface.min() ?? 0)
    switch name {
    case "Honey":
      report.add("M1", "honey levels", pass: spread < 0.004 && r.end.nanCount == 0,
                 "surface spread \(fmt(spread * 1000, 1)) mm after \(fmt(seconds, 0)) s, v \(fmt(r.end.maxSpeed, 4)) m/s")
    default:
      // Stopped (v below 5 mm/s), stress left near the yield stress (0.7–2 τ_y), and not levelled.
      let ratio = r.residual / ty
      let ok = r.end.maxSpeed < 0.005 && ratio > 0.7 && ratio < 2.0 && spread > 0.003 && r.end.nanCount == 0
      report.add(name == "Toothpaste" ? "M2" : (name == "Ketchup" ? "M3" : "M3b"), "\(name.lowercased()) stops near τ_y", pass: ok,
                 "v \(fmt(r.end.maxSpeed, 4)) m/s, residual τ̄ max / τ_y = \(fmt(ratio, 2)), surface spread \(fmt(spread * 1000, 1)) mm")
    }
  }
}

/// A plate (24 × 4 mm box) pushed straight down into a 40 mm oobleck pool at `speed` for 12 mm: mean resistive stress
/// over the push, F_y / (plate width × gap), and the largest jammed fraction seen.
func oobleckPlate(_ device: MTLDevice, speed: Double) throws -> (stress: Double, jammed: Double, depth: Double, nan: Int) {
  let gap = 0.01
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: gap, heleShawMinTime: 0.1), quality: .standard,
                    materials: [ContinuumPresets.oobleck])
  let W = rig.solver.domain.size.x
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.04), material: 0, temperature: 293.15)
  rig.run(120)                                                      // settle 1 s
  let half = SIMD2(0.012, 0.002)
  var y = 0.04 + half.y + 0.5 * rig.solver.cellSize                 // just above the surface
  let travel = 0.012
  var impulse = 0.0, time = 0.0, jam = 0.0
  var nan = 0
  while travel > 0.04 + half.y + 0.5 * rig.solver.cellSize - y {
    var input = MPMFrameInput()
    input.colliders = [MPMCollider(shape: .box(halfSize: half), position: SIMD2(W / 2, y), velocity: SIMD2(0, -speed), friction: 0.5, bodyIndex: 0)]
    let s = rig.frame(input)
    y -= speed * s.simulatedTime
    impulse += s.bodyImpulses[0].y
    time += s.simulatedTime
    jam = max(jam, s.jammedFraction)
    nan = s.nanCount
  }
  // Fluid force on the body is upward (resisting the push): impulse > 0.
  return (impulse / time / (2 * half.x * gap), jam, 0.04 + half.y - y, nan)
}

func checkOobleck(_ device: MTLDevice, _ report: Report) throws {
  print("\n== M4 Oobleck: plate pushed into a 40 mm pool at 0.5 m/s (punch) and 0.01 m/s (slow), 12 mm stroke ==")
  let fast = try oobleckPlate(device, speed: 0.5)
  let slow = try oobleckPlate(device, speed: 0.01)
  print("| speed | mean resistive stress (Pa) | max jammed fraction | NaN |")
  print("|---|---|---|---|")
  print("| 0.5 m/s | \(fmt(fast.stress, 1)) | \(fmt(fast.jammed, 3)) | \(fast.nan) |")
  print("| 0.01 m/s | \(fmt(slow.stress, 1)) | \(fmt(slow.jammed, 3)) | \(slow.nan) |")
  let ok = fast.jammed > 0.01 && slow.jammed < 0.5 * fast.jammed && fast.stress > 10 * slow.stress && fast.nan == 0 && slow.nan == 0
  report.add("M4", "oobleck: fast plate jams, slow plate sinks", pass: ok,
             "stress fast \(fmt(fast.stress, 0)) Pa vs slow \(fmt(slow.stress, 1)) Pa (×\(fmt(fast.stress / max(slow.stress, 1e-9), 0))), jammed \(fmt(fast.jammed, 3)) vs \(fmt(slow.jammed, 3))")
}
