import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
import LabKitCore
import LabKitMPM

// Pour checks (LK-FIX, 8 October 2026): a stream of viscous material poured from a height must land as one coherent
// body, not as a loose particle foam, and water must still splash.

/// Geometry of a settled pour, measured from the particles.
struct PileMetrics {
  var particles = 0
  /// Occupied cells × 4 / particles (Rheo's "foam index"; 1 for a compact body, plus the surface row).
  var foamIndex = 0.0
  /// The same for a freshly filled block of the same particle count and footprint (the floor of the measure).
  var enclosedOverRest = 0.0
  /// Mean J and its 10th / 90th percentiles.
  var meanJ = 1.0, j10 = 1.0, j90 = 1.0
  /// Highest particle (m) and mean surface over the wetted width (m).
  var top = 0.0, meanSurface = 0.0
  /// Rest area of the particles / tank width (m): the mass-equivalent layer height.
  var massHeight = 0.0
  /// Fraction of particles whose grid fill ρ̃ < 0.8 (loose).
  var loose = 0.0
  var maxSpeed = 0.0
}

/// Grid fill ρ̃ at each particle (the solver's own measure: Σ_i w_ip Σ_q w_iq V_q with V = ¼ cell), cell units.
func gridFill(_ ps: [MPMParticleSnapshot]) -> [Double] {
  var node: [SIMD2<Int>: Double] = [:]
  func weights(_ x: Double) -> (Int, [Double]) {
    let down = x.rounded(.down)
    let o = x - down - 0.5
    return (Int(down) - 1, [0.5 * (0.5 - o) * (0.5 - o), 0.75 - o * o, 0.5 * (0.5 + o) * (0.5 + o)])
  }
  for p in ps {
    let (bx, wx) = weights(p.positionCells.x), (by, wy) = weights(p.positionCells.y)
    for i in 0..<3 { for j in 0..<3 { node[SIMD2(bx + i, by + j), default: 0] += wx[i] * wy[j] * 0.25 } }
  }
  return ps.map { p in
    let (bx, wx) = weights(p.positionCells.x), (by, wy) = weights(p.positionCells.y)
    var s = 0.0
    for i in 0..<3 { for j in 0..<3 { s += wx[i] * wy[j] * (node[SIMD2(bx + i, by + j)] ?? 0) } }
    return s
  }
}

func pileMetrics(_ rig: Rig, last: MPMStats) -> PileMetrics {
  let ps = rig.particles
  var m = PileMetrics()
  m.particles = ps.count
  guard !ps.isEmpty else { return m }
  let dx = rig.solver.cellSize, W = rig.solver.domain.size.x
  var cells = Set<SIMD2<Int>>()
  for p in ps { cells.insert(SIMD2(Int((p.position.x / dx).rounded(.down)), Int((p.position.y / dx).rounded(.down)))) }
  m.foamIndex = Double(cells.count) * 4 / Double(ps.count)
  // Enclosed area under the surface profile, column by column (each column of width Δx).
  let columns = Int((W / dx).rounded(.down))
  var area = 0.0, wetted = 0
  for c in 0..<columns {
    let inCol = ps.filter { Int(($0.position.x / dx).rounded(.down)) == c }
    guard let h = inCol.map(\.position.y).max() else { continue }
    area += (h + 0.25 * dx) * dx
    wetted += 1
  }
  let rest = Double(ps.count) * 0.25 * dx * dx
  m.enclosedOverRest = area / rest
  m.meanSurface = wetted > 0 ? area / (Double(wetted) * dx) : 0
  m.massHeight = rest / W
  let js = ps.map(\.volumeRatio).sorted()
  m.meanJ = js.reduce(0, +) / Double(js.count)
  m.j10 = js[js.count / 10]; m.j90 = js[min(js.count - 1, js.count * 9 / 10)]
  m.top = (ps.map(\.position.y).max() ?? 0) + 0.25 * dx
  m.loose = Double(gridFill(ps).filter { $0 < 0.8 }.count) / Double(ps.count)
  m.maxSpeed = last.maxSpeed
  return m
}

/// Particle picture (one 3 × 3 px dot per particle at 6 px per mm), coloured by J: blue < 0.97 < green < 1.0 < red.
func writeParticlePNG(_ rig: Rig, path: String) {
  let ps = rig.particles
  let size = rig.solver.domain.size
  let scale = 6000.0
  let w = Int(size.x * scale), h = Int(size.y * scale)
  var px = [UInt8](repeating: 16, count: w * h * 4)
  for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
  for p in ps {
    let x = Int(p.position.x * scale), y = h - 1 - Int(p.position.y * scale)
    let j = p.volumeRatio
    let c: (UInt8, UInt8, UInt8) = j < 0.97 ? (60, 120, 255) : (j < 1.0 ? (80, 230, 120) : (255, 90, 60))
    for dy in -1...1 { for dx in -1...1 {
      let xx = x + dx, yy = y + dy
      guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
      let o = (yy * w + xx) * 4
      px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
    } }
  }
  px.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dst, img, nil)
    _ = CGImageDestinationFinalize(dst)
  }
}

struct PourSpec {
  var material: ContinuumMaterial
  var name: String
  /// Rest area to pour, m² (particles × ¼ cell).
  var area: Double = 1.0e-3
  /// Emitter centre height above the floor, m.
  var height: Double = 0.03
  var radius: Double = 0.003
  var speed: Double = 0.15
  var settle: Double = 3.0
  /// Temperature of the pool, the stream and the air, K; nil = the material's T_ref.
  var temperature: Double? = nil
  /// Height of a layer of the same material filled before the pour, m (Rheo's honey experiment: 12 mm).
  var layer: Double = 0
  var quality: MPMQuality = .standard
  var verification = MPMVerificationOptions()
  var png: String? = nil
}

/// Pours `spec.area` of material from a 6 mm nozzle (Rheo's pour emitter: 0.15 m/s, rate = speed × diameter in
/// particle areas) at `spec.height`, then lets it settle. Returns the pile's metrics and the peak droplet height seen
/// while pouring (splash).
func pour(_ device: MTLDevice, _ spec: PourSpec) throws -> (PileMetrics, splash: Double, splashSpeed: Double) {
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1), quality: spec.quality,
                    verification: spec.verification, materials: [spec.material])
  let dx = rig.solver.cellSize, W = rig.solver.domain.size.x
  let T = spec.temperature ?? spec.material.referenceTemperature
  if spec.layer > 0 {
    rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: spec.layer), material: 0, temperature: T)
    rig.run(60, input: MPMFrameInput(ambientTemperature: T))
  }
  let target = Int((spec.area / (0.25 * dx * dx)).rounded())
  let rate = spec.speed * 2 * spec.radius / (dx * dx / 4)
  var input = MPMFrameInput()
  input.ambientTemperature = T
  input.emitters = [MPMEmitter(position: SIMD2(W / 2, spec.height), radius: spec.radius, velocity: SIMD2(0, -spec.speed),
                               material: 0, rate: rate, temperature: T)]
  var emitted = 0, frames = 0
  var splash = 0.0
  var splashSpeed = 0.0
  while emitted < target && frames < 120 * 20 {
    let s = rig.frame(input)
    emitted = s.emitted
    frames += 1
    if frames % 3 == 0 {
      // Splash: the fastest upward particle outside the falling stream's column (|x − x_nozzle| > 2 r).
      let g = SIMD2(0.0, -9.81) * rig.solver.lastSubstepLength
      for p in rig.particles where abs(p.position.x - W / 2) > 2 * spec.radius {
        splashSpeed = max(splashSpeed, (p.velocity - g).y)
      }
    }
  }
  let quiet = MPMFrameInput(ambientTemperature: T)
  // Splash: the highest particle above the landing zone's surface during the first 0.5 s after the pour stops.
  for f in 0..<Int(spec.settle * 120) {
    let s = rig.frame(quiet)
    if f % 12 == 0 && f < 60 {
      let ps = rig.particles
      let low = ps.filter { abs($0.position.x - W / 2) > 0.012 }.map(\.position.y).max() ?? 0
      splash = max(splash, low)
    }
    _ = s
  }
  let m = pileMetrics(rig, last: rig.frame(quiet))
  if let png = spec.png { writeParticlePNG(rig, path: png) }
  return (m, splash, splashSpeed)
}

func describe(_ name: String, _ m: PileMetrics) -> String {
  "\(name): N \(m.particles), foam \(fmt(m.foamIndex, 3)), enclosed/rest \(fmt(m.enclosedOverRest, 3)), mean surface \(fmt(m.meanSurface * 1000, 1)) mm vs mass-equivalent \(fmt(m.massHeight * 1000, 1)) mm, top \(fmt(m.top * 1000, 1)) mm, J mean \(fmt(m.meanJ, 3)) (p10 \(fmt(m.j10, 3)), p90 \(fmt(m.j90, 3))), loose \(fmt(m.loose * 100, 1)) %, v \(fmt(m.maxSpeed, 4)) m/s"
}

/// Development entry (`labkit-gpucheck foamdev`): env FOAM_MAT (honey|ketchup|water|…), FOAM_AREA (mm²), FOAM_H (mm),
/// FOAM_SETTLE (s), FOAM_PNG (path), FOAM_MIX (grid-volume mix).
func foamDev(_ device: MTLDevice, _ report: Report) throws {
  let env = ProcessInfo.processInfo.environment
  let name = env["FOAM_MAT"] ?? "honey"
  guard let material = ContinuumPresets.named(name) else { print("unknown material \(name)"); return }
  var spec = PourSpec(material: material, name: name)
  if let a = env["FOAM_AREA"].flatMap(Double.init) { spec.area = a * 1e-6 }
  if let h = env["FOAM_H"].flatMap(Double.init) { spec.height = h * 1e-3 }
  if let s = env["FOAM_SETTLE"].flatMap(Double.init) { spec.settle = s }
  if let t = env["FOAM_TC"].flatMap(Double.init) { spec.temperature = t + 273.15 }
  if let l = env["FOAM_LAYER"].flatMap(Double.init) { spec.layer = l * 1e-3 }
  if let mix = env["FOAM_MIX"].flatMap(Double.init) { spec.verification.gridVolumeMix = mix }
  if let v = env["FOAM_TOL"].flatMap(Double.init) { spec.verification.underfillTolerance = v }
  if let mirror = env["FOAM_MIRROR"] { spec.verification.wallMirrorVolume = mirror == "1" }
  if env["FOAM_ONESIDED"] == "1" { spec.verification.twoSidedVolumeCorrection = false }
  spec.png = env["FOAM_PNG"]
  let t0 = Date()
  let (m, splash, splashSpeed) = try pour(device, spec)
  print(describe(name, m) + ", splash top \(fmt(splash * 1000, 1)) mm, splash speed \(fmt(splashSpeed, 3)) m/s (\(fmt(Date().timeIntervalSince(t0), 0)) s)")
  // Reference: the same particle count filled as a block (no pour).
  let rig = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1),
                    verification: spec.verification, materials: [material])
  let W = rig.solver.domain.size.x
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: spec.area / W), material: 0, temperature: material.referenceTemperature)
  rig.run(Int(spec.settle * 120), input: MPMFrameInput(ambientTemperature: material.referenceTemperature))
  print(describe("\(name) filled", pileMetrics(rig, last: rig.frame(MPMFrameInput(ambientTemperature: material.referenceTemperature)))))
  if let series = env["FOAM_SERIES"] {
    // Filled block over time: enclosed/rest and mean J at the listed times (s).
    let r2 = try Rig(device: device, domain: MPMDomain(heleShawGap: 0.01, heleShawMinTime: 0.1),
                     verification: spec.verification, materials: [material])
    r2.solver.fill(rect: CGRect(x: 0, y: 0, width: W, height: spec.area / W), material: 0, temperature: material.referenceTemperature)
    var t = 0.0
    var out: [String] = []
    for target in series.split(separator: ",").compactMap({ Double($0) }) {
      let q = MPMFrameInput(ambientTemperature: material.referenceTemperature)
      let n = Int(((target - t) * 120).rounded())
      if n > 0 { r2.run(n, input: q) }
      t = target
      let m = pileMetrics(r2, last: r2.frame(q))
      let xs = r2.particles.map(\.position.x)
      out.append("t \(fmt(t, 0)) s: enclosed \(fmt(m.enclosedOverRest, 3)) J \(fmt(m.meanJ, 3)) v \(fmt(m.maxSpeed, 3)) x \(fmt((xs.min() ?? 0) * 1000, 2))–\(fmt((xs.max() ?? 0) * 1000, 2)) mm")
    }
    print("  series: " + out.joined(separator: " | "))
  }
  if env["FOAM_PROFILE"] == "1" {
    // Number density per particle-spacing band (rest = 1), and mean J and ρ̃ per band, from the floor up.
    let ps = rig.particles, sp = 0.5 * rig.solver.cellSize
    let fills = gridFill(ps)
    var rows: [String] = []
    for b in 0..<Int((spec.area / W / sp).rounded() + 3) {
      let idx = ps.indices.filter { Int((ps[$0].position.y / sp).rounded(.down)) == b }
      guard !idx.isEmpty else { continue }
      let n = Double(idx.count) / (W / sp)
      let j = idx.map { ps[$0].volumeRatio }.reduce(0, +) / Double(idx.count)
      let f = idx.map { fills[$0] }.reduce(0, +) / Double(idx.count)
      rows.append("\(b): n \(fmt(n, 2)) J \(fmt(j, 3)) ρ̃ \(fmt(f, 2))")
    }
    print("  profile (band = ½ Δx from the floor): " + rows.joined(separator: " | "))
  }
  _ = report
}

/// F1–F3 (`labkit-gpucheck pour`): 1,000 mm² of honey, ketchup and water poured from Rheo's 6 mm pour nozzle (0.15 m/s)
/// 30 mm above the floor, then 3 s to settle. Judged: the settled body is compact (occupied cells × 4 / particles ≤ 1.1)
/// and encloses its own volume (area under the surface profile within 20 % of the particles' rest area, i.e. the pile
/// within 20 % of the mass-equivalent height), and water still splashes (≥ 0.1 m/s upward outside the stream, ≥ 3 × the
/// honey's). The same pours with upstream PB-MPM's volume handling (one-sided J correction, no wall mirror) are recorded.
func checkPours(_ device: MTLDevice, _ report: Report) throws {
  print("\n== F1–F3 Pours: 1,000 mm² from a 6 mm nozzle at 0.15 m/s, 30 mm above the floor, 3 s to settle (Δx 2 mm, gap 10 mm) ==")
  print("| material | solver | particles | foam index | enclosed / rest area | mean surface vs mass-equivalent (mm) | top (mm) | mean J (p10) | loose (ρ̃ < 0.8) | splash speed (m/s) |")
  print("|---|---|---|---|---|---|---|---|---|---|")
  var upstream = MPMVerificationOptions()
  upstream.twoSidedVolumeCorrection = false
  upstream.wallMirrorVolume = false
  var results: [String: (PileMetrics, Double)] = [:]
  for (name, m) in [("Honey", ContinuumPresets.honey), ("Ketchup", ContinuumPresets.ketchup), ("Water-like", ContinuumPresets.waterLike)] {
    for (label, v) in [("LabKit", MPMVerificationOptions()), ("upstream", upstream)] {
      var spec = PourSpec(material: m, name: name)
      spec.verification = v
      let (pm, _, speed) = try pour(device, spec)
      print("| \(name) | \(label) | \(pm.particles) | \(fmt(pm.foamIndex, 3)) | \(fmt(pm.enclosedOverRest, 3)) | \(fmt(pm.meanSurface * 1000, 1)) vs \(fmt(pm.massHeight * 1000, 1)) | \(fmt(pm.top * 1000, 1)) | \(fmt(pm.meanJ, 3)) (\(fmt(pm.j10, 3))) | \(fmt(pm.loose * 100, 1)) % | \(fmt(speed, 3)) |")
      results["\(name)-\(label)"] = (pm, speed)
    }
  }
  for (id, name) in [("F1", "Honey"), ("F2", "Ketchup"), ("F3a", "Water-like")] {
    guard let (pm, _) = results["\(name)-LabKit"], let (up, _) = results["\(name)-upstream"] else { continue }
    let ok = pm.foamIndex <= 1.1 && abs(pm.enclosedOverRest - 1) <= 0.2 && pm.particles > 900
    report.add(id, "\(name.lowercased()) pour lands as one body", pass: ok,
               "foam \(fmt(pm.foamIndex, 3)) (upstream \(fmt(up.foamIndex, 3))), enclosed/rest \(fmt(pm.enclosedOverRest, 3)) (upstream \(fmt(up.enclosedOverRest, 3))), surface \(fmt(pm.meanSurface * 1000, 1)) mm vs \(fmt(pm.massHeight * 1000, 1)) mm mass-equivalent")
  }
  // F4: Rheo's "Honey, cold and warm" experiment: 4 °C honey poured for 3.2 s from 6 mm under the lid into a 12 mm
  // layer of the same honey (2,880 mm² poured), 3 s to settle. Before LK-FIX it stood as a foam 20 mm taller than its
  // volume (the PHYS report's 65–95 mm "fill").
  var cold = PourSpec(material: ContinuumPresets.honey, name: "Honey 4 °C")
  cold.area = 2880e-6; cold.height = MPMDomain.lifeSizeTank.y - 0.006; cold.layer = 0.0122; cold.temperature = 277.15
  let (pm, _, _) = try pour(device, cold)
  cold.verification = upstream
  let (up, _, _) = try pour(device, cold)
  for (label, m) in [("LabKit", pm), ("upstream", up)] {
    print("| Honey 4 °C into a 12 mm layer, from 95 mm | \(label) | \(m.particles) | \(fmt(m.foamIndex, 3)) | \(fmt(m.enclosedOverRest, 3)) | \(fmt(m.meanSurface * 1000, 1)) vs \(fmt(m.massHeight * 1000, 1)) | \(fmt(m.top * 1000, 1)) | \(fmt(m.meanJ, 3)) (\(fmt(m.j10, 3))) | \(fmt(m.loose * 100, 1)) % | – |")
  }
  report.add("F4", "Rheo's cold-honey experiment pour lands as one body",
             pass: pm.foamIndex <= 1.1 && abs(pm.enclosedOverRest - 1) <= 0.2,
             "foam \(fmt(pm.foamIndex, 3)) (upstream \(fmt(up.foamIndex, 3))), surface \(fmt(pm.meanSurface * 1000, 1)) mm (upstream \(fmt(up.meanSurface * 1000, 1)) mm) vs \(fmt(pm.massHeight * 1000, 1)) mm mass-equivalent")
  if let water = results["Water-like-LabKit"], let honey = results["Honey-LabKit"] {
    report.add("F3b", "water still splashes", pass: water.1 >= 0.1 && water.1 >= 3 * honey.1,
               "peak upward speed outside the stream: water \(fmt(water.1, 3)) m/s, honey \(fmt(honey.1, 3)) m/s")
  }
}
