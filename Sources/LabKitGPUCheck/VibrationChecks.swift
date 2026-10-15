import CoreGraphics
import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPM

/// Development entry (`labkit-gpucheck monstersdev`, not in `all`): Merkt et al. 2004's vibrated oobleck layer in a
/// narrow slice. A 5 mm oobleck layer on a floor shaken at VIB_HZ (120) with peak acceleration VIB_G (10) g; after
/// 0.3 s a 4 mm finger indents it to 1 mm above the floor and leaves (Merkt: a hole forms only after an indentation
/// deeper than half the layer); then VIB_T (1.5) s more. Prints the layer's surface profile and the deepest dip over
/// time. env: VIB_DX (mm, default 0.5), VIB_G, VIB_HZ, VIB_T, VIB_W (slice width mm, 30), VIB_PNG.
func monstersDev(_ device: MTLDevice) throws {
  let env = ProcessInfo.processInfo.environment
  let dx = (env["VIB_DX"].flatMap(Double.init) ?? 0.5) * 1e-3
  let gees = env["VIB_G"].flatMap(Double.init) ?? 10
  let hz = env["VIB_HZ"].flatMap(Double.init) ?? 120
  let seconds = env["VIB_T"].flatMap(Double.init) ?? 1.5
  let width = (env["VIB_W"].flatMap(Double.init) ?? 30) * 1e-3
  let layer = 0.005
  let quality = MPMQuality(cellSize: dx, maxSubsteps: 400, iterations: 3)
  let domain = MPMDomain(size: SIMD2(width, 0.02), cellSize: dx, heleShawGap: 0.01, heleShawMinTime: 0.1)
  let rig = try Rig(device: device, domain: domain, quality: quality, materials: [ContinuumPresets.oobleck])
  let W = rig.solver.domain.size.x, h = rig.solver.cellSize
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: layer), material: 0, temperature: 293.15)
  rig.run(36)
  var shake = MPMFrameInput()
  shake.vibration = (gees * 9.81, hz)
  let stations = (0..<40).map { (Double($0) + 0.5) / 40 }
  var t = 0.0, frames = 0
  var log: [String] = []
  var substeps: [Int] = []
  let finger = 0.002, start = 0.3, press = 0.1
  while t < start + press * 2 + seconds {
    var input = shake
    let tf = t - start
    if tf >= 0 && tf < 2 * press {
      // Down to 1 mm above the floor over 0.1 s, then back up over 0.1 s.
      let top = layer + finger + 0.002, bottom = 0.001 + finger
      let y = tf < press ? top - (top - bottom) * tf / press : bottom + (top - bottom) * (tf - press) / press
      let vy = (tf < press ? -1.0 : 1.0) * (top - bottom) / press
      input.colliders = [MPMCollider(shape: .circle(radius: finger), position: SIMD2(W / 2, y), velocity: SIMD2(0, vy))]
    }
    let s = rig.frame(input)
    substeps.append(s.substeps)
    t += s.simulatedTime
    frames += 1
    if frames % 12 == 0 {
      let surf = rig.surface(at: stations)
      let mid = surf[14...25]
      log.append("t \(fmt(t, 2)) s: min \(fmt((mid.min() ?? 0) * 1000, 1)) mm, mean \(fmt(surf.reduce(0, +) / Double(surf.count) * 1000, 1)) mm, jam \(fmt(s.jammedFraction, 2)), v \(fmt(s.maxSpeed, 3))")
    }
  }
  let surf = rig.surface(at: stations)
  print("monsters Δx \(fmt(h * 1000, 2)) mm, \(fmt(gees, 0)) g at \(fmt(hz, 0)) Hz (displacement amplitude \(fmt(gees * 9.81 / pow(2 * Double.pi * hz, 2) * 1000, 3)) mm), \(rig.particles.count) particles, substeps \(substeps.min() ?? 0)–\(substeps.max() ?? 0), \(fmt(t, 2)) s simulated")
  for l in log { print("  " + l) }
  print("  final profile mm: " + surf.map { fmt($0 * 1000, 1) }.joined(separator: " "))
  if let png = env["VIB_PNG"] { writeParticlePNG(rig, path: png) }
}

/// Development entry (`labkit-gpucheck gravitydev`): Rheo's Gravity knob runs −1…3 g. A 30 mm pool (GRAV_MAT, default
/// water-like) settles 1 s at 1 g, then 3 s at 0 g, then 2 s at −1 g. Prints the lowest and highest particle and mean J
/// at the end of each phase. GRAV_UPSTREAM=1: upstream volume handling.
func gravityDev(_ device: MTLDevice) throws {
  let env = ProcessInfo.processInfo.environment
  let name = env["GRAV_MAT"] ?? "water-like"
  guard let m = ContinuumPresets.named(name) else { print("unknown material \(name)"); return }
  var v = MPMVerificationOptions()
  if env["GRAV_UPSTREAM"] == "1" { v.twoSidedVolumeCorrection = false; v.wallMirrorVolume = false }
  if env["GRAV_ONESIDED"] == "1" { v.twoSidedVolumeCorrection = false }
  if let mirror = env["GRAV_MIRROR"] { v.wallMirrorVolume = mirror == "1" }
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1), verification: v, materials: [m])
  let W = rig.solver.domain.size.x
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: 0.03), material: 0, temperature: 293.15)
  var out: [String] = []
  let ramp = env["GRAV_RAMP"].flatMap(Double.init) ?? 0      // s: change gravity linearly over this long
  var g0 = 1.0
  for (g, seconds) in [(1.0, 1.0), (0.0, 3.0), (-1.0, 2.0)] {
    let frames = Int(seconds * 120)
    var s = MPMStats()
    for f in 0..<frames {
      let k = ramp > 0 ? min(Double(f) / (ramp * 120), 1) : 1
      s = rig.frame(MPMFrameInput(gravity: SIMD2(0, -9.81 * (g0 + (g - g0) * k))))
    }
    g0 = g
    let ys = rig.particles.map(\.position.y)
    out.append("\(fmt(g, 0)) g for \(fmt(seconds, 0)) s: lowest \(fmt((ys.min() ?? 0) * 1000, 1)) mm, highest \(fmt((ys.max() ?? 0) * 1000, 1)) mm, J \(fmt(s.volumeRatio, 3)), v \(fmt(s.maxSpeed, 3))")
  }
  print("gravity \(name) (two-sided \(v.twoSidedVolumeCorrection), mirror \(v.wallMirrorVolume)): " + out.joined(separator: " | "))
}
