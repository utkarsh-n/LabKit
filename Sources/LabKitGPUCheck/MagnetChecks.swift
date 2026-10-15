import CoreGraphics
import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPM

// MR fluid over the virtual magnet under the floor (Rheo's set-up: 4 mm under the glass floor, field B at 1 cm).

/// Development entry (`labkit-gpucheck mrdev`): env MR_DEPTH (mm), MR_MT (mT at 1 cm), MR_CAP (m/s², negative = soft),
/// MR_YIELDFRAC (field-yield clamp as a fraction of G), MR_T (s), MR_PNG.
func mrDev(_ device: MTLDevice, _ report: Report) throws {
  let env = ProcessInfo.processInfo.environment
  let depth = (env["MR_DEPTH"].flatMap(Double.init) ?? 15) * 1e-3
  let tesla = (env["MR_MT"].flatMap(Double.init) ?? 207) * 1e-3
  let seconds = env["MR_T"].flatMap(Double.init) ?? 3
  var mr = ContinuumPresets.mrFluid
  if let y = env["MR_YIELDFRAC"].flatMap(Double.init) { mr.field?.clampFractionOfG = y }
  var v = MPMVerificationOptions()
  if env["MR_UPSTREAM"] == "1" { v.twoSidedVolumeCorrection = false; v.wallMirrorVolume = false }
  if let n = env["MR_SUB"].flatMap(Int.init) { v.fixedSubsteps = n }
  if env["MR_NOSCALE"] == "1" { v.kelvinYieldScaling = false }
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1), verification: v, materials: [mr])
  let W = rig.solver.domain.size.x
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: depth), material: 0, temperature: 293.15)
  rig.run(120)
  let fr = (0...24).map { (Double($0) + 0.5) / 25 }
  let before = rig.surface(at: fr)
  var input = MPMFrameInput()
  input.magnet = (SIMD2(W / 2, -0.004), tesla / MPMConstants.vacuumPermeability)
  input.probe = SIMD2(W / 2, 0.004)
  var last = MPMStats()
  var subs: [Int] = []
  rig.run(Int(seconds * 120), input: input) { _, s in last = s; subs.append(s.substeps) }
  let after = rig.surface(at: fr)
  func heap(_ s: [Double]) -> Double { s[12] - (s[2] + s[22]) / 2 }
  let ps = rig.particles
  let near = ps.filter { simd_length($0.position - SIMD2(W / 2, -0.004)) < 0.02 }
  let jNear = near.map(\.volumeRatio).reduce(0, +) / Double(max(near.count, 1))
  print("MR depth \(fmt(depth * 1000, 0)) mm, \(fmt(tesla * 1000, 0)) mT: heap \(fmt(heap(before) * 1000, 2)) → \(fmt(heap(after) * 1000, 2)) mm; centre \(fmt(after[12] * 1000, 1)) mm, sides \(fmt(after[2] * 1000, 1)) / \(fmt(after[22] * 1000, 1)) mm; J near magnet \(fmt(jNear, 3)), mean J \(fmt(last.volumeRatio, 3)); probe solid \(fmt(last.probe.solidFraction, 2)), τ̄ \(fmt(last.probe.stress, 0)) Pa; v \(fmt(last.maxSpeed, 4)) m/s; substeps \(subs.max() ?? 0)")
  print("  before mm:  " + before.map { fmt($0 * 1000, 1) }.joined(separator: " "))
  print("  profile mm: " + after.map { fmt($0 * 1000, 1) }.joined(separator: " "))
  if let png = env["MR_PNG"] { writeParticlePNG(rig, path: png) }
  let g = SIMD2(0.0, -9.81) * rig.solver.lastSubstepLength   // stored velocity holds the next gravity kick
  let fast = ps.sorted { simd_length($0.velocity - g) > simd_length($1.velocity - g) }.prefix(5)
  print("  fastest: " + fast.map { "(\(fmt($0.position.x * 1000, 1)), \(fmt($0.position.y * 1000, 1))) mm \(fmt(simd_length($0.velocity - g), 4)) m/s" }.joined(separator: "; "))
  _ = report
}

/// Rheo's stiffening probe: an 8 mm finger pressed down 25 mm at 3 cm/s, 15 mm off the magnet, in a `depth` pool after
/// 2 s of field; returns the largest upward fluid force on it (N, for the 10 mm gap).
func mrFingerForce(_ device: MTLDevice, material: ContinuumMaterial, depth: Double, tesla: Double, offset: Double = 0.015,
                   press: Double = 0.010, verification: MPMVerificationOptions = MPMVerificationOptions()) throws -> Double {
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1), verification: verification,
                    materials: [material])
  let W = rig.solver.domain.size.x
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: depth), material: 0, temperature: 293.15)
  var input = MPMFrameInput()
  if tesla > 0 { input.magnet = (SIMD2(W / 2, -0.004), tesla / MPMConstants.vacuumPermeability) }
  rig.run(240, input: input)
  var y = depth + 0.015, maxF = 0.0
  let x = W / 2 + offset
  while y > depth - press {
    var i = input
    i.colliders = [MPMCollider(shape: .circle(radius: 0.008), position: SIMD2(x, y), velocity: SIMD2(0, -0.03), bodyIndex: 0)]
    let s = rig.frame(i)
    y -= 0.03 * s.simulatedTime
    maxF = max(maxF, s.bodyImpulses[0].y / max(s.simulatedTime, 1e-9))
  }
  return maxF
}

func mrFingerDev(_ device: MTLDevice) throws {
  let env = ProcessInfo.processInfo.environment
  var mr = ContinuumPresets.mrFluid
  if let y = env["MR_YIELDFRAC"].flatMap(Double.init) { mr.field?.clampFractionOfG = y }
  var v = MPMVerificationOptions()
  if env["MR_NOSCALE"] == "1" { v.kelvinYieldScaling = false }
  let depth = (env["MR_DEPTH"].flatMap(Double.init) ?? 45) * 1e-3
  let offset = (env["MR_OFF"].flatMap(Double.init) ?? 15) * 1e-3
  let press = (env["MR_PRESS"].flatMap(Double.init) ?? 10) * 1e-3
  let off = try mrFingerForce(device, material: mr, depth: depth, tesla: 0, offset: offset, press: press, verification: v)
  let on = try mrFingerForce(device, material: mr, depth: depth, tesla: (env["MR_MT"].flatMap(Double.init) ?? 207) * 1e-3,
                             offset: offset, press: press, verification: v)
  print("MR finger (depth \(fmt(depth * 1000, 0)) mm): off \(fmt(off, 4)) N, on \(fmt(on, 4)) N, ratio \(fmt(on / max(off, 1e-9), 1))")
}

/// A `depth` pool of MR fluid with the virtual magnet 4 mm under the floor at the tank centre (Rheo's set-up), `seconds`
/// of field: heap = surface over the magnet − mean of the surface at 10 % and 90 % of the width.
func mrHeap(_ device: MTLDevice, depth: Double, tesla: Double, seconds: Double = 3,
            verification: MPMVerificationOptions = MPMVerificationOptions()) throws -> (heap: Double, centre: Double, jNear: Double) {
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1), verification: verification,
                    materials: [ContinuumPresets.mrFluid])
  let W = rig.solver.domain.size.x
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: depth), material: 0, temperature: 293.15)
  rig.run(120)
  var input = MPMFrameInput()
  input.magnet = (SIMD2(W / 2, -0.004), tesla / MPMConstants.vacuumPermeability)
  rig.run(Int(seconds * 120), input: input)
  let s = rig.surface(at: (0...24).map { (Double($0) + 0.5) / 25 })
  let near = rig.particles.filter { simd_length($0.position - SIMD2(W / 2, -0.004)) < 0.02 }
  return (s[12] - (s[2] + s[22]) / 2, s[12], near.map(\.volumeRatio).reduce(0, +) / Double(max(near.count, 1)))
}

/// M5 (`labkit-gpucheck magnet`): MR fluid over the virtual magnet (207 mT at 1 cm, 4 mm under the floor). Judged: a
/// shallow pool (8 and 12 mm) heaps over the magnet by ≥ 1.5 mm within 3 s, and the fluid stiffens: a finger pressed in
/// 15 mm off the magnet in a 45 mm pool (Rheo's test) meets ≥ 3 × the force it meets with the magnet off. Recorded: a
/// finger over the magnet in a 12 mm pool, the same runs with the field yield blind to the Kelvin cap (before LK-FIX),
/// and a 30 mm pool.
func checkMagnet(_ device: MTLDevice, _ report: Report) throws {
  print("\n== M5 MR fluid over the virtual magnet (207 mT at 1 cm, 4 mm under the floor; Δx 2 mm, gap 10 mm) ==")
  var before = MPMVerificationOptions()
  before.kelvinYieldScaling = false
  print("| pool depth | heap after 3 s (mm) | surface over the magnet (mm) | mean J within 2 cm of the magnet | before LK-FIX: heap (mm) |")
  print("|---|---|---|---|---|")
  var heaps: [Double: Double] = [:], olds: [Double: Double] = [:]
  for depth in [0.008, 0.012, 0.030] {
    let now = try mrHeap(device, depth: depth, tesla: 0.207)
    let old = try mrHeap(device, depth: depth, tesla: 0.207, verification: before)
    heaps[depth] = now.heap; olds[depth] = old.heap
    print("| \(fmt(depth * 1000, 0)) mm | \(fmt(now.heap * 1000, 2)) | \(fmt(now.centre * 1000, 1)) | \(fmt(now.jNear, 3)) | \(fmt(old.heap * 1000, 2)) |")
  }
  let mr = ContinuumPresets.mrFluid
  print("| finger | magnet off (N) | on (N) | ratio | before LK-FIX: ratio |")
  print("|---|---|---|---|---|")
  var ratios: [String: Double] = [:]
  for (label, depth, offset, press) in [("over the magnet, 12 mm pool", 0.012, 0.0, 0.008), ("15 mm off, 45 mm pool", 0.045, 0.015, 0.010)] {
    let off = try mrFingerForce(device, material: mr, depth: depth, tesla: 0, offset: offset, press: press)
    let on = try mrFingerForce(device, material: mr, depth: depth, tesla: 0.207, offset: offset, press: press)
    let onOld = try mrFingerForce(device, material: mr, depth: depth, tesla: 0.207, offset: offset, press: press, verification: before)
    ratios[label] = on / max(off, 1e-9)
    print("| \(label) | \(fmt(off, 3)) | \(fmt(on, 3)) | \(fmt(on / max(off, 1e-9), 1)) | \(fmt(onOld / max(off, 1e-9), 1)) |")
  }
  let shallow = [0.008, 0.012].map { heaps[$0] ?? 0 }
  report.add("M5a", "MR fluid heaps over the magnet (8 and 12 mm pools, ≥ 1.5 mm)", pass: shallow.allSatisfy { $0 >= 0.0015 },
             "8 mm: \(fmt(shallow[0] * 1000, 2)) mm, 12 mm: \(fmt(shallow[1] * 1000, 2)) mm (before LK-FIX \(fmt((olds[0.008] ?? 0) * 1000, 2)) / \(fmt((olds[0.012] ?? 0) * 1000, 2)) mm); 30 mm pool \(fmt((heaps[0.03] ?? 0) * 1000, 2)) mm (recorded)")
  let rheo = ratios["15 mm off, 45 mm pool"] ?? 0, over = ratios["over the magnet, 12 mm pool"] ?? 0
  report.add("M5b", "MR fluid stiffens near the magnet (Rheo's finger 15 mm off: force ≥ 3 × off)", pass: rheo >= 3,
             "15 mm off, 45 mm pool ×\(fmt(rheo, 1)); over the magnet, 12 mm pool ×\(fmt(over, 1)) (recorded)")
}

/// Development entry (`labkit-gpucheck mrabove`): LabKitMPMTests' magnet-above scene (20 mm MR pool, 1.5e5 A/m at 1 cm,
/// 1 cm above the surface, probe 5 mm below the surface) over MR_T (3) s: surface under the magnet, probe solid fraction
/// and stress every 0.25 s. MR_NOSCALE=1: field yield blind to the Kelvin cap.
func mrAboveDev(_ device: MTLDevice) throws {
  let env = ProcessInfo.processInfo.environment
  var v = MPMVerificationOptions()
  if env["MR_NOSCALE"] == "1" { v.kelvinYieldScaling = false }
  if env["MR_UPSTREAM"] == "1" { v.twoSidedVolumeCorrection = false; v.wallMirrorVolume = false }
  if env["MR_ONESIDED"] == "1" { v.twoSidedVolumeCorrection = false }
  if let mirror = env["MR_MIRROR"] { v.wallMirrorVolume = mirror == "1" }
  if let t = env["MR_TOL"].flatMap(Double.init) { v.underfillTolerance = t }
  if let n = env["MR_SUB"].flatMap(Int.init) { v.fixedSubsteps = n }
  let seconds = env["MR_T"].flatMap(Double.init) ?? 3
  let strength = env["MR_H"].flatMap(Double.init) ?? 1.5e5
  let material = env["MR_MAT"].flatMap { ContinuumPresets.named($0) } ?? ContinuumPresets.mrFluid
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1), verification: v,
                    materials: [material])
  let W = rig.solver.domain.size.x
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.02), material: 0, temperature: 293.15)
  rig.run(60)
  let magnet = SIMD2(W / 2, 0.03)
  var input = MPMFrameInput()
  input.magnet = (magnet, strength)
  input.probe = SIMD2(W / 2, 0.015)
  var rows: [String] = []
  for k in 1...Int(seconds * 4) {
    let s = rig.run(30, input: input)
    let top = rig.particles.filter { abs($0.position.x - magnet.x) < 0.01 }.map(\.position.y).max() ?? 0
    rows.append("t \(fmt(Double(k) * 0.25, 2)) s (substeps \(s.substeps)): top \(fmt(top * 1000, 1)) mm, probe solid \(fmt(s.probe.solidFraction, 2)), τ̄ \(fmt(s.probe.stress, 0)) Pa, γ̇ \(fmt(s.probe.shearRate, 2)) 1/s, v \(fmt(s.maxSpeed, 3))")
  }
  print("MR magnet above (\(fmt(strength, 0)) A/m at 1 cm), scaling \(v.kelvinYieldScaling ? "on" : "off"):")
  for r in rows { print("  " + r) }
  if let png = env["MR_PNG"] { writeParticlePNG(rig, path: png) }
}
