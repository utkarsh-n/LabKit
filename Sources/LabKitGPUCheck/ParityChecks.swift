import CoreGraphics
import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPM
import LabKitMPMReference

// V13 (PB-MPM viscosity regression) and V14 (GPU–CPU parity against LabKitMPMReference), rheology-models.md §7.

// MARK: V13

/// Shear wave u = u₀ sin(k y) on a periodic 4 × 64-cell strip, Δx 1.5 mm, Δt 1/240 s (one substep per frame), N = 3.
/// Returns the measured amplitude history (t, A).
func shearWave(_ device: MTLDevice, material: ContinuumMaterial, native: Double?, seconds: Double) throws -> [(Double, Double)] {
  var v = MPMVerificationOptions()
  v.periodicX = true; v.periodicY = true
  v.fixedSubsteps = 1
  if let mu = native { v.nativeViscosity = [0: mu] }
  let dx = 0.0015
  let q = MPMQuality(cellSize: dx, maxSubsteps: 1, iterations: 3)
  let rig = try Rig(device: device, domain: MPMDomain(size: SIMD2(4 * dx, 64 * dx), cellSize: dx, heleShawGap: 0), quality: q,
                    capacity: 2000, verification: v, materials: [material])
  rig.solver.fill(rect: CGRect(x: 0, y: 0, width: 4 * dx, height: 64 * dx), material: 0, temperature: 293.15)
  var input = MPMFrameInput(dt: 0, gravity: .zero)
  rig.frame(input)                                                   // inject only
  let dt = 1.0 / 240, u0 = 0.01, L = 64 * dx, k = 2 * Double.pi / L
  rig.solver.debugSetVelocity(substep: dt, velocity: { x in SIMD2(u0 * sin(k * x.y), 0) },
                              gradient: { x in simd_double2x2(columns: (SIMD2(0, 0), SIMD2(u0 * k * cos(k * x.y), 0))) })
  input.dt = dt
  func amplitude() -> Double {
    let ps = rig.particles
    return 2 * ps.reduce(0) { $0 + $1.velocity.x * sin(k * $1.position.y) } / Double(ps.count)
  }
  var series = [(0.0, amplitude())]
  for f in 1...Int(seconds * 240) {
    rig.frame(input)
    series.append((Double(f) * dt, amplitude()))
  }
  return series
}

func checkV13(_ device: MTLDevice, _ report: Report) throws {
  print("\n== V13 PB-MPM viscosity regression: periodic shear wave, 4 × 64 cells, Δx 1.5 mm, Δt 1/240 s, N = 3 ==")
  let dx = 0.0015, dt = 1.0 / 240, k = 2 * Double.pi / (64 * dx), kIt = 3.0
  print("| model | ν set (m²/s) | r = 8νΔt/(NΔx²) | ν measured (m²/s) | ratio |")
  print("|---|---|---|---|---|")
  var nativeRatios: [Double] = [], evpRatios: [Double] = []
  for r in [0.1, 0.5] {
    let nu = r * kIt * dx * dx / (8 * dt)
    var water = ContinuumPresets.waterLike
    water.density = 1000
    let series = try shearWave(device, material: water, native: nu * 1000, seconds: 1)
    let pts = series.filter { $0.0 > 0.02 && $0.1 > 0 }
    let decay = -slope(pts.map(\.0), pts.map { log($0.1) })
    let measured = decay / (k * k)
    nativeRatios.append(measured / nu)
    print("| native relaxation | \(sci(nu)) | \(fmt(r, 2)) | \(sci(measured)) | \(fmt(measured / nu)) |")
  }
  for eta in [0.05, 0.3] {
    // Newtonian EVP (Maxwell with λ = η/G ≪ Δt), XPBD warm start ω = 1, β = 1; Π = κ·2G·θ ≤ 4N by construction.
    let m = ContinuumMaterial(density: 1000, shearModulus: 1e4, bulkModulus: 5e4, fluidity: 1 / eta)
    let series = try shearWave(device, material: m, native: nil, seconds: 1)
    let pts = series.filter { $0.0 > 0.02 && $0.1 > 0 }
    let measured = -slope(pts.map(\.0), pts.map { log($0.1) }) / (k * k)
    evpRatios.append(measured / (eta / 1000))
    print("| XPBD-EVP Newtonian η = \(fmt(eta, 2)) Pa·s | \(sci(eta / 1000)) | – | \(sci(measured)) | \(fmt(measured / (eta / 1000))) |")
  }
  // Elastic wave: G = 100 Pa (Π = κ·2G = 6.2 ≤ 4N), u(t) = u₀ cos(ωt), ω = √(G/ρ)·k.
  let G = 100.0
  let elastic = ContinuumMaterial(density: 1000, shearModulus: G, bulkModulus: 5e4)
  let series = try shearWave(device, material: elastic, native: nil, seconds: 0.5)
  var crossings: [Double] = []
  for i in 1..<series.count where (series[i - 1].1 > 0) != (series[i].1 > 0) {
    let (t0, a0) = series[i - 1], (t1, a1) = series[i]
    crossings.append(t0 + (t1 - t0) * a0 / (a0 - a1))
  }
  let omegaExact = (G / 1000).squareRoot() * k
  let omega = crossings.count >= 2 ? Double.pi / (crossings[1] - crossings[0]) : 0
  print("| XPBD-EVP elastic G = 100 Pa | ω exact \(fmt(omegaExact, 3)) rad/s | – | ω \(fmt(omega, 3)) rad/s | \(fmt(omega / omegaExact, 4)) |")
  report.add("V13a", "native viscosity within −2 % / +20 %", pass: nativeRatios.allSatisfy { $0 >= 0.98 && $0 <= 1.2 },
             nativeRatios.map { fmt($0) }.joined(separator: ", "))
  report.add("V13b", "XPBD-EVP viscosity within 2 %", pass: evpRatios.allSatisfy { abs($0 - 1) <= 0.02 },
             evpRatios.map { fmt($0) }.joined(separator: ", "))
  report.add("V13c", "XPBD-EVP elastic ω within 0.5 %", pass: abs(omega / omegaExact - 1) <= 0.005,
             "ω/ω_exact = \(fmt(omega / omegaExact, 4))")
}

// MARK: V14 constitutive level

func checkV14Constitutive(_ device: MTLDevice, _ report: Report) throws {
  print("\n== V14a Constitutive parity: GPU float32 rheoUpdate vs LabKitMPMReference EVP.update (Double) ==")
  let probe = try MPMConstitutiveProbe(device: device)
  let presets = ContinuumPresets.all
  let materials = presets.map(\.material)
  let rates = [0.1, 1, 10, 100]
  /// Simple shear from rest for `seconds` at each rate; returns the worst relative τ̄ difference and its case.
  func sweep(dt: Double, seconds: Double, printRows: Bool) -> (Double, String) {
    var worst = 0.0, worstCase = ""
    let steps = Int((seconds / dt).rounded())
    for (mi, entry) in presets.enumerated() {
      var points = rates.map { _ -> MPMConstitutiveProbe.Point in
        let st = EVPState.rested(entry.material)
        return MPMConstitutiveProbe.Point(structure: st.structure, temperature: st.temperature)
      }
      let gpu = probe.run(materials: materials, points: &points, materialIndex: Array(repeating: mi, count: rates.count),
                          velocityGradient: rates.map { EVP.simpleShear($0) }, dt: dt, steps: steps)
      var line: [String] = []
      var caseWorst = 0.0
      for (i, r) in rates.enumerated() {
        var s = EVPState.rested(entry.material)
        var tau = SIMD3<Double>.zero
        for _ in 0..<steps { tau = EVP.update(&s, velocityGradient: EVP.simpleShear(r), dt: dt, material: entry.material, fieldMagnitude: 0) }
        let cpu = EVP.equivalentShearStress(tau), g = EVP.equivalentShearStress(gpu[i])
        let rel = abs(g - cpu) / max(cpu, 1e-6)
        caseWorst = max(caseWorst, rel)
        if rel > worst && entry.name != "Oobleck" { worst = rel; worstCase = "\(entry.name) at \(r) 1/s" }
        line.append(fmt(g, 3))
      }
      if printRows { print("| \(entry.name) | \(line.joined(separator: " / ")) | \(sci(caseWorst)) |") }
    }
    return (worst, worstCase)
  }
  // Step-wise: every GPU update starts from the oracle's state (all 52 cases batched), 0.5 s at Δt = 1/1440 s.
  var stepWorst = 0.0, stepCase = "", oobWorst = 0.0
  do {
    let dt = 1.0 / 1440
    var cpu: [EVPState] = [], mat: [Int] = [], grad: [simd_double2x2] = [], peak: [Double] = []
    for (mi, entry) in presets.enumerated() {
      for r in rates { cpu.append(EVPState.rested(entry.material)); mat.append(mi); grad.append(EVP.simpleShear(r)); peak.append(0) }
    }
    for _ in 0..<720 {
      var pts = cpu.map { MPMConstitutiveProbe.Point(b11: $0.b11, b12: $0.b12, b22: $0.b22, J: $0.J, structure: $0.structure,
                                                     contact: $0.contact, temperature: $0.temperature, plasticRate: $0.plasticRate) }
      let g = probe.run(materials: materials, points: &pts, materialIndex: mat, velocityGradient: grad, dt: dt, steps: 1)
      for k in cpu.indices {
        let c = EVP.equivalentShearStress(EVP.update(&cpu[k], velocityGradient: grad[k], dt: dt, material: materials[mat[k]], fieldMagnitude: 0))
        peak[k] = max(peak[k], c)
        let rel = abs(EVP.equivalentShearStress(g[k]) - c) / max(c, 1e-3 * peak[k], 1e-9)
        if presets[mat[k]].name == "Oobleck" { oobWorst = max(oobWorst, rel); continue }
        if rel > stepWorst { stepWorst = rel; stepCase = "\(presets[mat[k]].name) at \(grad[k][1][0]) 1/s" }
      }
    }
  }
  print("Step-wise (each GPU update from the oracle's state), 13 presets × 4 rates × 720 updates at Δt 1/1440 s: worst |Δτ̄|/τ̄ \(sci(stepWorst)) (\(stepCase)); oobleck \(sci(oobWorst))")
  // Oobleck's jam blend divides by the small packing gap 1 − φ/φ_J (w_jam = 0.02), which amplifies float32 rounding of f
  // about 50×: its bound is 1e-4.
  report.add("V14a", "constitutive update, step-wise, 13 presets × 4 rates: τ̄ within 1e-5 (oobleck 1e-4)",
             pass: stepWorst <= 1e-5 && oobWorst <= 1e-4,
             "max |Δτ̄|/τ̄ = \(sci(stepWorst)) (\(stepCase)); oobleck \(sci(oobWorst))")

  print("Free-running simple shear from rest for 0.5 s at the app's substep (Δt = 1/1440 s):")
  print("| preset | γ̇ = 0.1 / 1 / 10 / 100 1/s: GPU τ̄ (Pa) | max relative difference |")
  print("|---|---|---|")
  let app = sweep(dt: 1.0 / 1440, seconds: 0.5, printRows: true)
  let fine = sweep(dt: 1e-4, seconds: 0.5, printRows: false)
  print("Same at Δt = 1e-4 s (5,000 updates; increments γ̇Δt down to 1e-5 approach float32's 1.2e-7 ulp of b̄ₑ ≈ I): worst \(sci(fine.0)) (\(fine.1))")
  report.add("V14a2", "free-running shear, 12 presets × 4 rates (oobleck excluded: stick-slip), Δt 1/1440 s", pass: nil,
             "max |Δτ̄|/τ̄ = \(sci(app.0)) (\(app.1)); at Δt 1e-4 s: \(sci(fine.0)) (\(fine.1))")

  // Oobleck impact (200 1/s for 10 ms), then hold (C = 0) for 0.35 s at Δt = 1e-4 s. Step-wise parity: each GPU update
  // starts from the oracle's state, so this compares the update itself. Free-running, the impact is a jam–fail–unjam
  // stick-slip cycle of a few steps' period whose phase drifts with rounding, so the two trajectories part (reported).
  let oob = ContinuumPresets.oobleck
  let dt = 1e-4
  var cs = EVPState.rested(oob)
  var free = [MPMConstitutiveProbe.Point(structure: 1, temperature: oob.referenceTemperature)]
  var maxRel = 0.0, maxDf = 0.0, peak = 0.0, freeRel = 0.0, freeDf = 0.0
  for step in 0..<3600 {
    let C = EVP.simpleShear(step < 100 ? 200 : 0)
    var gp = [MPMConstitutiveProbe.Point(b11: cs.b11, b12: cs.b12, b22: cs.b22, J: cs.J, structure: cs.structure, contact: cs.contact,
                                         temperature: cs.temperature, plasticRate: cs.plasticRate)]
    let g = probe.run(materials: [oob], points: &gp, materialIndex: [0], velocityGradient: [C], dt: dt, steps: 1)
    let gf = probe.run(materials: [oob], points: &free, materialIndex: [0], velocityGradient: [C], dt: dt, steps: 1)
    let c = EVP.equivalentShearStress(EVP.update(&cs, velocityGradient: C, dt: dt, material: oob, fieldMagnitude: 0))
    peak = max(peak, c)
    maxRel = max(maxRel, abs(EVP.equivalentShearStress(g[0]) - c) / max(peak, 1))
    maxDf = max(maxDf, abs(gp[0].contact - cs.contact))
    freeRel = max(freeRel, abs(EVP.equivalentShearStress(gf[0]) - c) / max(peak, 1))
    freeDf = max(freeDf, abs(free[0].contact - cs.contact))
  }
  print("oobleck impact-hold (3,600 updates): step-wise max |Δτ̄|/peak \(sci(maxRel)), max |Δf| \(sci(maxDf)); free-running max |Δτ̄|/peak \(fmt(freeRel)), |Δf| \(fmt(freeDf)) (peak τ̄ \(fmt(peak, 0)) Pa)")
  report.add("V14b", "oobleck impact-hold, step-wise: τ̄ within 1e-5 of peak, f within 0.05", pass: maxRel <= 1e-5 && maxDf <= 0.05,
             "|Δτ̄|/peak \(sci(maxRel)), |Δf| \(sci(maxDf)); free-running trajectories part (stick-slip): |Δτ̄|/peak \(fmt(freeRel)), |Δf| \(fmt(freeDf))")
}

// MARK: V14 spatial

/// Builds the same particles on the GPU (explicit parity mode, periodic) and in ReferenceSolver2D. The GPU's grid nodes sit
/// at cell centres, the oracle's at cell corners: the oracle copy is shifted by −Δx/2 on both axes (and the forcing phase
/// with it), which makes the two node lattices coincide.
final class ParityPair {
  let rig: Rig
  let oracle: ReferenceSolver2D
  let dx: Double
  let size: SIMD2<Double>

  init(_ device: MTLDevice, cells: SIMD2<Int>, dx: Double, materials: [ContinuumMaterial],
       layout: (SIMD2<Double>) -> Int, forcing: (amplitude: Double, wavelength: Double)?,
       velocity: ((SIMD2<Double>) -> SIMD2<Double>)?, dt: Double, prestrain: Double = 0) throws {
    self.dx = dx
    size = SIMD2(Double(cells.x), Double(cells.y)) * dx
    var v = MPMVerificationOptions()
    v.periodicX = true; v.periodicY = true; v.explicitParity = true; v.fixedSubsteps = 1
    if let f = forcing { v.shearForcingAmplitude = f.amplitude; v.shearForcingWavelength = f.wavelength }
    rig = try Rig(device: device, domain: MPMDomain(size: size, cellSize: dx, heleShawGap: 0),
                  quality: MPMQuality(cellSize: dx, maxSubsteps: 1, iterations: 1), capacity: cells.x * cells.y * 4 + 16,
                  verification: v, materials: materials)
    // Seed every lattice site, material chosen by position (2 × 2 per cell, small jitter from fill()).
    for j in 0..<cells.y {
      for i in 0..<cells.x {
        let c = SIMD2(Double(i) + 0.5, Double(j) + 0.5) * dx
        rig.solver.fill(rect: CGRect(x: Double(i) * dx, y: Double(j) * dx, width: dx, height: dx), material: layout(c),
                        temperature: materials[layout(c)].referenceTemperature)
      }
    }
    rig.frame(MPMFrameInput(dt: 0, gravity: .zero))                   // inject only
    if prestrain != 0 {
      rig.solver.debugModifyParticles { p in p.elastic = SIMD4(Float(1 + prestrain * prestrain), Float(prestrain), 1, 0) }
    }
    if let vel = velocity { rig.solver.debugSetVelocity(substep: dt, velocity: vel) }
    // The oracle copy.
    var scene = ReferenceScene(size: size, cellSize: dx, periodicX: true, periodicY: true)
    if let f = forcing {
      let kf = 2 * Double.pi / f.wavelength, a = f.amplitude, h = 0.5 * dx
      scene.bodyAcceleration = { x, _ in SIMD2(a * sin(kf * (x.y + h)), 0) }
    }
    let gpuParticles = rig.particles
    let L = size, h = dx
    scene.particles = gpuParticles.map { p in
      var x = p.position - SIMD2(repeating: 0.5 * h)
      x.x -= L.x * (x.x / L.x).rounded(.down); x.y -= L.y * (x.y / L.y).rounded(.down)
      let m = materials[p.material]
      var st = EVPState.rested(m)
      st.temperature = p.temperature
      if prestrain != 0 { st.setElasticSimpleShear(prestrain) }
      let v0 = velocity.map { $0(p.position) } ?? .zero
      return ReferenceParticle(position: x, velocity: v0, material: p.material, mass: m.density * h * h / 4,
                               volume: h * h / 4, state: st)
    }
    oracle = ReferenceSolver2D(scene: scene, materials: materials)
  }

  func step(_ n: Int, dt: Double) {
    for _ in 0..<n {
      rig.frame(MPMFrameInput(dt: dt, gravity: .zero))
      oracle.step(dt: dt)
    }
  }

  /// Position RMS difference (cells), velocity RMS difference / max speed, τ̄ RMS difference / max τ̄, max |Δf|.
  func compare() -> (positionCells: Double, velocity: Double, stress: Double, contact: Double, maxSpeed: Double, maxStress: Double) {
    let g = rig.particles, c = oracle.particles
    precondition(g.count == c.count)
    var dp = 0.0, dv = 0.0, ds = 0.0, df = 0.0, vmax = 0.0, smax = 0.0
    for i in g.indices {
      var d = (g[i].position - SIMD2(repeating: 0.5 * dx)) - c[i].position
      d.x -= size.x * (d.x / size.x).rounded(); d.y -= size.y * (d.y / size.y).rounded()
      dp += simd_length_squared(d / dx)
      dv += simd_length_squared(g[i].velocity - c[i].velocity)
      let cs = EVP.equivalentShearStress(c[i].stress)
      ds += (g[i].stress - cs) * (g[i].stress - cs)
      df = max(df, abs(g[i].contact - c[i].state.contact))
      vmax = max(vmax, simd_length(c[i].velocity))
      smax = max(smax, cs)
    }
    let n = Double(g.count)
    return ((dp / n).squareRoot(), (dv / n).squareRoot() / max(vmax, 1e-12), (ds / n).squareRoot() / max(smax, 1e-12), df, vmax, smax)
  }
}

func checkV14Spatial(_ device: MTLDevice, _ report: Report) throws {
  print("\n== V14b–d Spatial parity: GPU explicit mode (k = 1, ω = 0, β = 1) vs ReferenceSolver2D, periodic domains ==")
  print("| scene | particles | steps | Δt (s) | position RMS (cells) | velocity RMS / max | τ̄ RMS / max | max |Δf| | max speed (m/s) | max τ̄ (Pa) |")
  print("|---|---|---|---|---|---|---|---|---|---|")
  func row(_ name: String, _ pair: ParityPair, steps: Int, dt: Double) -> (Double, Double, Double, Double) {
    let r = pair.compare()
    print("| \(name) | \(pair.oracle.particles.count) | \(steps) | \(sci(dt)) | \(sci(r.positionCells)) | \(sci(r.velocity)) | \(sci(r.stress)) | \(fmt(r.contact, 4)) | \(sci(r.maxSpeed)) | \(fmt(r.maxStress, 2)) |")
    return (r.positionCells, r.velocity, r.stress, r.contact)
  }
  var results: [(String, Double, Double, Double, Double)] = []

  // V6: Maxwell relaxation of a pre-strained periodic 8 × 8 block (γ₀ = 0.01, G 10 kPa), λ/Δt = 100, 10, 1.
  var v6worst = 0.0
  for lamOverDt in [100.0, 10, 1] {
    let dt = 5e-5, G = 1e4, lam = lamOverDt * dt, g0 = 0.01                     // Δt below the elastic CFL (7e-5 s)
    let m = ContinuumMaterial(density: 1000, shearModulus: G, bulkModulus: 2e4, fluidity: 1 / (G * lam))
    let pair = try ParityPair(device, cells: SIMD2(8, 8), dx: 0.001, materials: [m], layout: { _ in 0 }, forcing: nil,
                              velocity: nil, dt: dt, prestrain: g0)
    let n = Int(3 * lamOverDt.rounded(.up))
    pair.step(n, dt: dt)
    let be = G * g0 * pow(1 + dt / lam, -Double(n))
    // GPU and oracle τ̄ against the backward-Euler discrete solution (for the small-strain Maxwell law).
    let gpuMean = pair.rig.particles.map(\.stress).reduce(0, +) / Double(pair.rig.particles.count)
    let cpuMean = pair.oracle.particles.map { EVP.equivalentShearStress($0.stress) }.reduce(0, +) / Double(pair.oracle.particles.count)
    v6worst = max(v6worst, abs(gpuMean - cpuMean) / (G * g0))
    print("V6 λ/Δt = \(Int(lamOverDt)): GPU τ̄ \(fmt(gpuMean, 4)) Pa, oracle \(fmt(cpuMean, 4)) Pa, backward Euler \(fmt(be, 4)) Pa after \(n) steps")
  }
  report.add("V14c", "V6 Maxwell block: |τ̄_GPU − τ̄_oracle| ≤ 1e-4·Gγ₀", pass: v6worst <= 1e-4, "max \(sci(v6worst))·Gγ₀")

  // V4: Kolmogorov flow, Newtonian μ 1 Pa·s, G 5 kPa, K 20 kPa, F 2e4 N/m³, L_y 1 cm in 32 rows, L_x = 4Δx.
  let dxK = 0.01 / 32
  let newt = ContinuumMaterial(density: 1000, shearModulus: 5000, bulkModulus: 20_000, fluidity: 1)
  let dtK = 0.4 * dxK / ((25_000.0 / 1000).squareRoot())
  for steps in [100, 1000] {
    let pair = try ParityPair(device, cells: SIMD2(4, 32), dx: dxK, materials: [newt], layout: { _ in 0 },
                              forcing: (20, 0.01), velocity: nil, dt: dtK)
    pair.step(steps, dt: dtK)
    let r = row("V4 Kolmogorov (Newtonian)", pair, steps: steps, dt: dtK)
    results.append(("V4 \(steps) steps", r.0, r.1, r.2, r.3))
  }

  // Mixed scene: 32 × 16 cells (2,048 particles) at Δx 1 mm, bands of ketchup, oobleck and slime, an initial shear wave
  // u = 5 cm/s · sin(2πy/L) and Kolmogorov forcing 20 m/s². Δt from the oracle's CFL (C = 0.4).
  let mixed = [ContinuumPresets.ketchup, ContinuumPresets.oobleck, ContinuumPresets.slime]
  let L = 0.016
  let cp = mixed.map { (($0.bulkModulus + $0.shearModulus) / $0.density).squareRoot() }.max()!
  let dtM = 0.4 * 0.001 / (cp + 0.05)
  let pair = try ParityPair(device, cells: SIMD2(32, 16), dx: 0.001, materials: mixed,
                            layout: { x in min(2, Int(x.y / L * 3)) }, forcing: (20, L),
                            velocity: { x in SIMD2(0.05 * sin(2 * Double.pi * x.y / L), 0) }, dt: dtM)
  pair.step(100, dt: dtM)
  let r = row("mixed ketchup/oobleck/slime", pair, steps: 100, dt: dtM)
  results.append(("mixed 100 steps", r.0, r.1, r.2, r.3))

  let ok = results.allSatisfy { $0.1 < 0.05 && $0.4 <= 0.05 }
  report.add("V14d", "spatial parity: positions RMS < 0.05 cell, f within 0.05", pass: ok,
             results.map { "\($0.0): pos \(sci($0.1)) cell, v \(sci($0.2)), τ̄ \(sci($0.3)), Δf \(fmt($0.4, 3))" }.joined(separator: "; "))
}
