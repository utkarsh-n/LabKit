// MPM oracle checks V1–V12 (owned by WP-O). See Rheo/Documentation/research/rheology-models.md §7.
//
//   swift run -c release labkit-physcheck mpm              the required cases V1–V10 and V12
//   swift run -c release labkit-physcheck mpm full         V1–V12 (V11 is exploratory: info rows, not counted)
//   swift run -c release labkit-physcheck mpm V3 V4        selected cases
//
// Every line prints measured against theory. Tolerances are the "Tolerance" column of §7 (resolution-aware for V3
// and V5). Synthetic test fluids use ρ 1000, G 5 kPa, K 20 kPa and no tension cap unless a case says otherwise.
import Foundation
import LabKitCore
import LabKitMPMReference
import simd

private let g0 = 9.80665

private struct MPMRow {
  let id: String, name: String, measured: String, target: String, ok: Bool?
}

private struct MPMSuite {
  var rows: [MPMRow] = []
  var timings: [(String, Double)] = []

  mutating func check(_ pc: inout PhysCheck, _ id: String, _ name: String, ok: Bool, measured: String, target: String) {
    pc.check("\(id) \(name)", ok, "measured \(measured); required \(target)")
    rows.append(MPMRow(id: id, name: name, measured: measured, target: target, ok: ok))
  }

  /// Not counted as pass/fail (regression values, hypotheses, resolution studies).
  mutating func info(_ id: String, _ name: String, measured: String, target: String) {
    print("INFO  \(id) \(name) — measured \(measured); reference \(target)")
    rows.append(MPMRow(id: id, name: name, measured: measured, target: target, ok: nil))
  }
}

private func fmt(_ x: Double, _ digits: Int = 4) -> String { String(format: "%.\(digits)g", x) }
private func pct(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f %%", 100 * x) }

/// A synthetic Herschel–Bulkley test fluid (no thixotropy, no tension cap).
private func fluid(rho: Double = 1000, G: Double = 5e3, K: Double = 2e4, ty: Double = 0, k: Double = 1, n: Double = 1)
  -> ContinuumMaterial
{
  ContinuumMaterial(density: rho, shearModulus: G, bulkModulus: K, tensionLimit: .infinity,
                    yieldBroken: ty, consistency: k, flowIndex: n)
}

/// Explicit time step 0.3·Δx/c_p (the numpy prototype's choice; §4.9 allows 0.4).
private func explicitDt(_ m: ContinuumMaterial, h: Double, courant: Double = 0.3, vmax: Double = 0) -> Double {
  courant * h / (((m.bulkModulus + m.shearModulus) / m.density).squareRoot() + vmax)
}

/// Runs to `end` and returns each particle's velocity averaged over the steps that end at t ≥ `averageFrom`.
private func runAveraging(_ s: ReferenceSolver2D, until end: Double, dt: Double, averageFrom: Double) -> [SIMD2<Double>] {
  var acc = Array(repeating: SIMD2<Double>.zero, count: s.particles.count)
  var n = 0
  while s.time < end - 1e-12 {
    s.step(dt: min(dt, end - s.time))
    if s.time >= averageFrom {
      let ps = s.particles
      for i in ps.indices { acc[i] += ps[i].velocity }
      n += 1
    }
  }
  return n > 0 ? acc.map { $0 / Double(n) } : s.particles.map(\.velocity)
}

private func percentile(_ xs: [Double], _ q: Double) -> Double {
  guard !xs.isEmpty else { return 0 }
  let s = xs.sorted()
  let r = q / 100 * Double(s.count - 1)
  let i = Int(r.rounded(.down)), f = r - Double(i)
  return i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[i]
}

private func guardSummary(_ s: ReferenceSolver2D) -> String {
  let c = s.counters
  return "guards det \(c.determinantGuards), speed \(c.speedClamps), bounds \(c.outOfBounds), NaN \(c.nonFinite)"
}

// MARK: - Entry point

func runMPMChecks(_ pc: inout PhysCheck, arguments: [String]) {
  let all = ["V1", "V2", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "V10", "V11", "V12"]
  let words = arguments.map { $0.uppercased() }
  let requested = words.filter { all.contains($0) }
  let selected = words.contains("FULL") ? all : (requested.isEmpty ? all.filter { $0 != "V11" } : requested)
  print("\n=== LabKitMPMReference oracle: verification suite (\(selected.joined(separator: " "))) ===")
  var suite = MPMSuite()
  let t0 = Date()
  for id in selected {
    let start = Date()
    print("\n--- \(id) ---")
    switch id {
    case "V1": v1Hydrostatic(&pc, &suite)
    case "V2": v2Couette(&pc, &suite)
    case "V3": v3Poiseuille(&pc, &suite)
    case "V4": v4Kolmogorov(&pc, &suite)
    case "V5": v5Incline(&pc, &suite)
    case "V6": v6MaxwellRelaxation(&pc, &suite)
    case "V7": v7MaxwellStartup(&pc, &suite)
    case "V8": v8Thixotropy(&pc, &suite)
    case "V9": v9Bifurcation(&pc, &suite)
    case "V10": v10HeleShaw(&pc, &suite)
    case "V11": v11JammingFront(&pc, &suite)
    case "V12": v12Laws(&pc, &suite)
    default: break
    }
    let dtWall = Date().timeIntervalSince(start)
    suite.timings.append((id, dtWall))
    print(String(format: "    (%@ took %.1f s)", id, dtWall))
  }

  print("\n=== MPM oracle summary ===")
  print("ID    Result  Case | measured | required")
  for r in suite.rows {
    let res = r.ok.map { $0 ? "PASS  " : "FAIL  " } ?? "info  "
    print("\(r.id.padding(toLength: 5, withPad: " ", startingAt: 0)) \(res)  \(r.name) | \(r.measured) | \(r.target)")
  }
  print(suite.timings.map { String(format: "%@ %.1f s", $0.0, $0.1) }.joined(separator: ", ")
        + String(format: "; total %.1f s", Date().timeIntervalSince(t0)))
}

// MARK: - V1 hydrostatic column

private func v1Hydrostatic(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let rho = 1000.0, bulk = 2.5e4, h0 = 0.02
  for rows in [32, 64] {
    let h = h0 / Double(rows)
    let m = fluid(rho: rho, G: 5e3, K: bulk, k: 0.05)
    var sc = ReferenceScene(size: SIMD2(4 * h, h0 + 8 * h), cellSize: h, periodicX: true,
                            walls: ReferenceWalls(bottom: .fixed, top: .open),
                            bodyAcceleration: ReferenceScene.ramped(SIMD2(0, -g0), over: 0.05))
    sc.heleShaw = .fixedTime(0.02)
    sc.fill(lower: .zero, upper: SIMD2(4 * h, h0), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    s.advance(by: 0.4, dt: explicitDt(m, h: h))
    let scale = rho * g0 * h0
    // Bin by Lagrangian cell row (as the prototype t9b). Interior = cell rows outside the floor's B-spline reach
    // (cells 0 and 1 hold particles within 1.5Δx of the sticky floor nodes) and more than 2 cells below the surface.
    // Particle rows inside one cell alternate about the cell mean; their spread is reported separately.
    var rowP = Array(repeating: 0.0, count: rows), rowZ = Array(repeating: 0.0, count: rows)
    var rowN = Array(repeating: 0, count: rows)
    var prP = Array(repeating: 0.0, count: 2 * rows), prZ = Array(repeating: 0.0, count: 2 * rows)
    var prN = Array(repeating: 0, count: 2 * rows)
    var jErr = 0.0, pSum = 0.0, maxShear = 0.0
    for p in s.particles {
      let z = h0 - p.initialPosition.y
      let r = min(Int(p.initialPosition.y / h), rows - 1)
      rowP[r] += p.pressure; rowZ[r] += z; rowN[r] += 1
      let q = min(Int(p.initialPosition.y / (0.5 * h)), 2 * rows - 1)
      prP[q] += p.pressure; prZ[q] += z; prN[q] += 1
      jErr = max(jErr, abs(p.state.J - ReferenceLaws.hydrostaticVolumeRatio(depth: z, density: rho, gravity: g0, bulk: bulk)))
      pSum += p.pressure
      maxShear = max(maxShear, abs(p.cauchyStress.y))
    }
    var interior = 0.0, particleRows = 0.0
    for r in 2..<(rows - 2) {
      interior = max(interior, abs(rowP[r] - rho * g0 * rowZ[r]) / Double(rowN[r]) / scale)
      for q in [2 * r, 2 * r + 1] { particleRows = max(particleRows, abs(prP[q] - rho * g0 * prZ[q]) / Double(prN[q]) / scale) }
    }
    let rowRel = (0..<4).map { (prP[$0] / Double(prN[$0])) / (rho * g0 * prZ[$0] / Double(prN[$0])) - 1 }
    let cellRel = (0..<2).map { (rowP[$0] / Double(rowN[$0])) / (rho * g0 * rowZ[$0] / Double(rowN[$0])) - 1 }
    let meanRatio = pSum / Double(s.particles.count) / (scale / 2)
    suite.check(&pc, "V1", "hydrostatic p, interior cell rows (\(rows) rows)", ok: interior <= 0.005,
                measured: "max |p − ρ₀gZ|/(ρ₀gH₀) = \(pct(interior, 3))", target: "≤ 0.5 %")
    suite.check(&pc, "V1", "hydrostatic J (\(rows) rows)", ok: jErr <= 2e-3,
                measured: "max |J − J_ex| = \(fmt(jErr, 3))", target: "≤ 2 × 10⁻³")
    suite.info("V1", "floor row and mean pressure (\(rows) rows)",
               measured: "floor cell rows p/p_ex − 1 = \(pct(cellRel[0], 1)), \(pct(cellRel[1], 1)) (particle rows \(rowRel.map { pct($0, 1) }.joined(separator: ", "))); interior single particle rows \(pct(particleRows, 2)) of ρ₀gH₀; mean p/(ρ₀gH₀/2) = \(fmt(meanRatio, 5)); max |σ_xy|/(ρ₀gH₀) = \(fmt(maxShear / scale, 2)); \(guardSummary(s))",
               target: "prototype: floor row +9 % (sticky-wall artefact, excluded), mean 1.003–1.005")
  }
}

// MARK: - V2 plane Couette

private func v2Couette(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let gap = 5e-3, u = 0.05, rows = 20
  let h = gap / Double(rows)
  for (name, ty, k, n) in [("Bingham τ_y 10, k 1", 10.0, 1.0, 1.0), ("HB τ_y 10, k 2, n 0.4", 10.0, 2.0, 0.4),
                           ("Newtonian η 1", 0.0, 1.0, 1.0)] {
    let m = fluid(ty: ty, k: k, n: n)
    var sc = ReferenceScene(size: SIMD2(4 * h, gap), cellSize: h, periodicX: true,
                            walls: ReferenceWalls(bottom: .fixed, top: .sticky(velocity: SIMD2(u, 0))))
    sc.fill(lower: .zero, upper: SIMD2(4 * h, gap), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let vavg = runAveraging(s, until: 0.15, dt: explicitDt(m, h: h), averageFrom: 0.12)
    let exact = ReferenceLaws.herschelBulkley(rate: u / gap, yield: ty, consistency: k, index: n)
    let taus = s.particles.map { $0.cauchyStress.y }
    let mean = taus.reduce(0, +) / Double(taus.count)
    let sd = (taus.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(taus.count)).squareRoot()
    var prof = 0.0
    for (i, p) in s.particles.enumerated() { prof = max(prof, abs(vavg[i].x - u * p.position.y / gap) / u) }
    let rel = (mean - exact) / exact
    suite.check(&pc, "V2", "Couette mean τ, \(name)", ok: abs(rel) <= 0.015,
                measured: "τ_xy \(fmt(mean, 6)) Pa vs \(fmt(exact, 6)) (\(pct(rel)), scatter \(pct(sd / exact, 1)))",
                target: "±1.5 %")
    suite.check(&pc, "V2", "Couette profile, \(name)", ok: prof <= 0.02,
                measured: "max |u − Uy/h|/U = \(pct(prof))", target: "≤ 2 %")
  }
}

// MARK: - V3 walled plane Poiseuille

private struct PoiseuilleResult { var error: Double; var center: Double; var plug: Double?; var slope: Double; var cell: Double }

private func poiseuille(ty: Double, k: Double, n: Double, gp: Double, rows: Int, duration: Double) -> PoiseuilleResult {
  let hh = 5e-3, rho = 1000.0
  let h = 2 * hh / Double(rows)
  let m = fluid(rho: rho, ty: ty, k: k, n: n)
  var sc = ReferenceScene(size: SIMD2(4 * h, 2 * hh), cellSize: h, periodicX: true,
                          walls: ReferenceWalls(bottom: .fixed, top: .fixed),
                          bodyAcceleration: ReferenceScene.uniform(SIMD2(gp / rho, 0)))
  sc.fill(lower: .zero, upper: SIMD2(4 * h, 2 * hh), material: 0, m)
  let s = ReferenceSolver2D(scene: sc, materials: [m])
  let vavg = runAveraging(s, until: duration, dt: explicitDt(m, h: h), averageFrom: 0.9 * duration)
  let uc = ReferenceLaws.poiseuilleVelocity(y: 0, halfWidth: hh, gradient: gp, yield: ty, consistency: k, index: n)
  var err = 0.0, centre = 0.0, best = Double.infinity
  var unyielded: [Double] = []
  var sxy = 0.0, syy = 0.0, sy = 0.0, st = 0.0
  for (i, p) in s.particles.enumerated() {
    let y = p.position.y - hh
    let ue = ReferenceLaws.poiseuilleVelocity(y: y, halfWidth: hh, gradient: gp, yield: ty, consistency: k, index: n)
    err = max(err, abs(vavg[i].x - ue) / uc)
    if abs(y) < best { best = abs(y); centre = vavg[i].x }
    if ty > 0 && p.state.plasticRate <= 0 { unyielded.append(abs(y)) }
    let tau = p.cauchyStress.y
    sxy += y * tau; syy += y * y; sy += y; st += tau
  }
  let np = Double(s.particles.count)
  let slope = (sxy - sy * st / np) / (syy - sy * sy / np)
  return PoiseuilleResult(error: err, center: centre / uc, plug: ty > 0 ? percentile(unyielded, 98) : nil, slope: slope, cell: h)
}

private func v3Poiseuille(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  // Newtonian and Bingham at 24 rows.
  let newt = poiseuille(ty: 0, k: 1, n: 1, gp: 4000, rows: 24, duration: 0.25)
  suite.check(&pc, "V3", "Poiseuille Newtonian (24 rows)", ok: newt.error <= 0.015,
              measured: "max |u − u_ex|/u_c = \(pct(newt.error)), u_c ratio \(fmt(newt.center, 5))", target: "≤ 1.5 %")
  let bing = poiseuille(ty: 10, k: 1, n: 1, gp: 4000, rows: 24, duration: 0.6)
  suite.check(&pc, "V3", "Poiseuille Bingham τ_y 10 (24 rows)", ok: bing.error <= 0.05,
              measured: "max |u − u_ex|/u_c = \(pct(bing.error)), u_c ratio \(fmt(bing.center, 5))", target: "≤ 5 %")
  let y0 = 10.0 / 4000
  let plugErr = abs((bing.plug ?? 0) - y0) / bing.cell
  suite.check(&pc, "V3", "Poiseuille Bingham plug half-width (24 rows)", ok: plugErr <= 1,
              measured: "\(fmt((bing.plug ?? 0) * 1e3, 4)) mm vs \(fmt(y0 * 1e3, 4)) mm (\(fmt(plugErr, 2)) cell)",
              target: "±1 cell")
  // Shear-thinning n = 0.5: resolution study 12 / 24 / 48 rows.
  for (name, ty, gp) in [("power law k 1, n 0.5", 0.0, 1000.0), ("HB τ_y 10, k 1, n 0.5", 10.0, 4000.0)] {
    var errs: [Double] = []
    var slopes: [Double] = []
    for rows in [12, 24, 48] {
      let r = poiseuille(ty: ty, k: 1, n: 0.5, gp: gp, rows: rows, duration: 0.6)
      errs.append(r.error); slopes.append(r.slope)
    }
    suite.info("V3", "Poiseuille \(name), 12 rows (phone-resolution regression value)",
               measured: "max |u − u_ex|/u_c = \(pct(errs[0], 1))",
               target: ty > 0 ? "prototype 62 %" : "prototype 34 %")
    suite.check(&pc, "V3", "Poiseuille \(name), 48 rows", ok: errs[2] <= 0.12,
                measured: "max |u − u_ex|/u_c = \(pct(errs[2], 1)) (24 rows \(pct(errs[1], 1)))", target: "≤ 12 %")
    let ratio = errs[1] / errs[2]
    suite.check(&pc, "V3", "Poiseuille \(name), convergence 24 → 48 rows", ok: ratio >= 2.5,
                measured: "error falls \(fmt(ratio, 3))× (12 → 24: \(fmt(errs[0] / errs[1], 3))×); dτ/dy \(slopes.map { fmt($0, 5) }.joined(separator: " / ")) vs \(fmt(-gp, 5))",
                target: "≥ 2.5× per halving, checked on 24 → 48 (12 → 24 reported only: the prototype's HB 12 → 24 is itself 2.0×)")
  }
}

// MARK: - V4 wall-free periodic shear (Kolmogorov flow)

private func v4Kolmogorov(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let ly = 0.01, rho = 1000.0
  let cases: [(String, Double, Double, Double, Double, Int, Double)] = [
    ("Newtonian η 1", 0, 1, 1, 2e4, 32, 0.005),
    ("Newtonian η 1", 0, 1, 1, 2e4, 64, -1),
    ("Bingham τ_y 20, η 1", 20, 1, 1, 2e4, 64, 0.02),
    ("power law k 1, n 0.5", 0, 1, 0.5, 6e3, 64, 0.02),
  ]
  for (name, ty, k, n, f, rows, tol) in cases {
    let h = ly / Double(rows)
    let m = fluid(rho: rho, ty: ty, k: k, n: n)
    let kap = 2 * Double.pi / ly
    var sc = ReferenceScene(size: SIMD2(4 * h, ly), cellSize: h, periodicX: true, periodicY: true,
                            bodyAcceleration: { x, _ in SIMD2(f / rho * sin(kap * x.y), 0) })
    sc.fill(lower: .zero, upper: SIMD2(4 * h, ly), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let vavg = runAveraging(s, until: 0.6, dt: explicitDt(m, h: h), averageFrom: 0.85 * 0.6)
    let ex = ReferenceLaws.KolmogorovProfile(force: f, period: ly, yield: ty, consistency: k, index: n)
    let umax = ex.maximumSpeed
    var err = 0.0
    var unyielded: [Double] = []
    for (i, p) in s.particles.enumerated() {
      err = max(err, abs(vavg[i].x - ex.velocity(at: p.position.y)) / umax)
      if ty > 0 && p.state.plasticRate <= 0 {
        var yc = (p.position.y - ly / 4).truncatingRemainder(dividingBy: ly / 2)
        if yc < 0 { yc += ly / 2 }
        unyielded.append(min(yc, ly / 2 - yc))
      }
    }
    if tol > 0 {
      suite.check(&pc, "V4", "Kolmogorov \(name) (\(rows) rows)", ok: err <= tol,
                  measured: "max |u − u_ex|/u_max = \(pct(err, 3)) (u_max \(fmt(umax, 4)) m/s)", target: "≤ \(pct(tol, 1))")
    } else {
      suite.info("V4", "Kolmogorov \(name) (\(rows) rows)", measured: "max |u − u_ex|/u_max = \(pct(err, 3))",
                 target: "prototype 0.28 %")
    }
    if ty > 0 {
      let y0 = ReferenceLaws.kolmogorovPlugHalfWidth(force: f, period: ly, yield: ty)
      let w = percentile(unyielded, 98)
      suite.check(&pc, "V4", "Kolmogorov Bingham plug half-width (\(rows) rows)", ok: abs(w - y0) <= h,
                  measured: "\(fmt(w * 1e3, 4)) mm vs \(fmt(y0 * 1e3, 4)) mm (\(fmt(abs(w - y0) / h, 2)) cell)",
                  target: "±1 cell")
    }
  }
}

// MARK: - V5 incline stoppage and film

private func v5Incline(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let rho = 1100.0, ty = 15.0, k = 8.0, n = 0.3, theta = 30.0 * Double.pi / 180
  let hc = ReferenceLaws.stoppageDepth(yield: ty, density: rho, gravity: g0, angle: theta)
  let m = fluid(rho: rho, G: 2e3, K: 2e4, ty: ty, k: k, n: n)
  let gvec = SIMD2(g0 * sin(theta), -g0 * cos(theta))
  for frac in [0.85, 1.15, 1.5, 2.5] {
    let depth = frac * hc, rows = 16
    let h = depth / Double(rows)
    var sc = ReferenceScene(size: SIMD2(4 * h, depth + 8 * h), cellSize: h, periodicX: true,
                            walls: ReferenceWalls(bottom: .fixed, top: .open),
                            bodyAcceleration: ReferenceScene.ramped(gvec, over: 0.1))
    sc.fill(lower: .zero, upper: SIMD2(4 * h, depth), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let dt = explicitDt(m, h: h)
    var lateYield = 0.0
    var acc = Array(repeating: 0.0, count: s.particles.count), na = 0
    while s.time < 0.6 - 1e-12 {
      s.step(dt: min(dt, 0.6 - s.time))
      // §7 V5: "no plastic rate after the ramp" (gravity is ramped over 0.1 s).
      if s.time > 0.1 { lateYield = max(lateYield, s.particles.map(\.state.plasticRate).max() ?? 0) }
      if s.time >= 0.45 { for (i, p) in s.particles.enumerated() { acc[i] += p.velocity.x }; na += 1 }
    }
    let yTop = s.particles.map(\.initialPosition.y).max() ?? 0
    var us = 0.0, cnt = 0
    for (i, p) in s.particles.enumerated() where p.initialPosition.y > yTop - h { us += acc[i] / Double(na); cnt += 1 }
    us /= Double(max(cnt, 1))
    let endYield = s.particles.map(\.state.plasticRate).max() ?? 0
    let ex = ReferenceLaws.filmSurfaceSpeed(depth: depth, yield: ty, consistency: k, index: n, density: rho, gravity: g0,
                                            angle: theta)
    let label = "h = \(fmt(frac, 3)) h_c (\(fmt(depth * 1e3, 4)) mm)"
    switch frac {
    case 0.85:
      suite.check(&pc, "V5", "incline static, \(label)", ok: abs(us) <= 1e-6 && lateYield == 0 && endYield == 0,
                  measured: "u_s = \(fmt(us, 3)) m/s, γ̇ₚ max after the ramp (t > 0.1 s) \(fmt(lateYield, 3)) /s, at end \(fmt(endYield, 3)) /s",
                  target: "|u_s| ≤ 10⁻⁶ m/s, no plastic rate after the ramp")
    case 1.15:
      suite.check(&pc, "V5", "incline flowing, \(label)", ok: us > 1e-6 && endYield > 0,
                  measured: "u_s = \(fmt(us, 3)) m/s (exact \(fmt(ex, 3))), γ̇ₚ max \(fmt(endYield, 3)) /s",
                  target: "flowing (u_s > 10⁻⁶ m/s, γ̇ₚ > 0)")
    case 2.5:
      let rel = (us - ex) / ex
      suite.check(&pc, "V5", "incline surface speed, \(label)", ok: abs(rel) <= 0.03,
                  measured: "u_s = \(fmt(us, 5)) vs \(fmt(ex, 5)) m/s (\(pct(rel)))", target: "±3 %")
    default:
      suite.info("V5", "incline surface speed, \(label)", measured: "u_s = \(fmt(us, 4)) vs \(fmt(ex, 4)) m/s (\(pct((us - ex) / ex, 0)))",
                 target: "prototype +78 % (sticky-wall artefact: effective h_c ≈ 7 % low)")
    }
  }
  suite.info("V5", "stoppage depth", measured: "h_c = \(fmt(hc * 1e3, 4)) mm", target: "τ_y/(ρg sin θ) = 2.781 mm")
}

// MARK: - V6 Maxwell stress relaxation (MPM, periodic block)

private func v6MaxwellRelaxation(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let h = 1e-3, g = 1e4, gamma0 = 0.01
  for ratio in [100.0, 10.0, 1.0] {
    var m = fluid(G: g, K: 2e4, k: 1)
    let dt = explicitDt(m, h: h)
    let eta = ratio * dt * g
    m.consistency = eta
    let lam = eta / g
    var sc = ReferenceScene(size: SIMD2(8 * h, 8 * h), cellSize: h, periodicX: true, periodicY: true)
    sc.fill(lower: .zero, upper: SIMD2(8 * h, 8 * h), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    s.modifyParticles { $0.state.setElasticSimpleShear(gamma0) }
    let steps = Int((3 * lam / dt).rounded())
    var maxBE = 0.0, maxExact = 0.0
    for i in 1...steps {
      s.step(dt: dt)
      let tau = s.particles.reduce(0) { $0 + $1.stress.y } / Double(s.particles.count)
      let be = ReferenceLaws.maxwellRelaxationBackwardEuler(steps: i, dt: dt, initial: g * gamma0, relaxationTime: lam)
      maxBE = max(maxBE, abs(tau - be) / (g * gamma0))
      maxExact = max(maxExact, abs(tau - ReferenceLaws.maxwellRelaxation(time: s.time, initial: g * gamma0, relaxationTime: lam)) / (g * gamma0))
    }
    suite.check(&pc, "V6", "Maxwell relaxation λ/Δt = \(fmt(ratio, 3)) (MPM block)", ok: maxBE <= 1e-4,
                measured: "max |τ − τ_BE|/(Gγ₀) = \(fmt(maxBE, 3)); vs exponential \(fmt(maxExact, 3))",
                target: "≤ 10⁻⁴ (vs exponential: the BE error, prototype 1.8e-3 / 1.8e-2 / 0.13)")
  }
}

// MARK: - V7 Maxwell start-up and N₁ (constitutive)

private func v7MaxwellStartup(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let g = 1e3, eta = 10.0, lam = eta / g
  let m = fluid(G: g, K: 2.5e4, k: eta)
  let regression: [Double: (Double, Double)] = [0.5: (0.7417, 0.5945), 1.0: (0.5231, 0.3229)]
  for wi in [0.01, 0.1, 0.5, 1.0] {
    let rate = wi / lam, dt = lam / 200
    var st = EVPState()
    var err = 0.0
    var tau = SIMD3<Double>.zero
    for i in 1...2000 {
      tau = EVP.update(&st, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0)
      let t = Double(i) * dt
      if t < 3 * lam { err = max(err, abs(tau.y - ReferenceLaws.maxwellStartup(time: t, viscosity: eta, rate: rate, relaxationTime: lam)) / (eta * rate)) }
    }
    let steady = tau.y / (eta * rate)
    let n1 = (tau.x - tau.z) / ReferenceLaws.ucmFirstNormalStress(viscosity: eta, relaxationTime: lam, rate: rate)
    if wi <= 0.1 {
      suite.check(&pc, "V7", "Maxwell start-up Wi \(fmt(wi, 2))", ok: err <= 0.02,
                  measured: "max start-up error \(pct(err, 3)); steady τ/(ηγ̇) \(fmt(steady, 5))", target: "≤ 2 %")
      suite.check(&pc, "V7", "Maxwell N₁ Wi \(fmt(wi, 2))", ok: abs(n1 - 1) <= 0.05,
                  measured: "N₁/N₁,UCM = \(fmt(n1, 5))", target: "within 5 %")
    } else if let reg = regression[wi] {
      let ok = abs(steady - reg.0) <= 2e-3 && abs(n1 - reg.1) <= 2e-3
      suite.check(&pc, "V7", "Maxwell regression Wi \(fmt(wi, 2)) (model property, §4.6)", ok: ok,
                  measured: "τ/(ηγ̇) \(fmt(steady, 4)), N₁/N₁,UCM \(fmt(n1, 4))",
                  target: "prototype \(reg.0) / \(reg.1) ± 0.002")
    }
  }
}

// MARK: - V8 thixotropic structure

private func v8Thixotropy(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let a0 = 0.05, b1 = 0.5, rate = 2.0
  // Constitutive level: w_vib = 1 drives λ with exactly the prescribed total rate.
  var m = fluid(G: 5e3, K: 2e4, k: 1)
  m.buildRate = a0; m.breakShear = b1; m.vibrationWeight = 1
  for dt in [1e-3, 1e-2] {
    var st = EVPState()
    let nSteps = Int((30 / dt).rounded())
    var errD = 0.0, errE = 0.0
    for i in 1...nSteps {
      EVP.update(&st, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0)
      errD = max(errD, abs(st.structure - ReferenceLaws.structureDiscrete(steps: i, dt: dt, initial: 1, build: a0, breakdown: b1 * rate)))
      errE = max(errE, abs(st.structure - ReferenceLaws.structure(time: Double(i) * dt, initial: 1, build: a0, breakdown: b1 * rate)))
    }
    let bound = 0.2 * (a0 + b1 * rate) * dt
    suite.check(&pc, "V8", "structure breakdown, Δt \(fmt(dt, 2)) s (constitutive)", ok: errD <= 1e-9 && errE <= bound,
                measured: "vs discrete \(fmt(errD, 2)), vs exact \(fmt(errE, 3))", target: "≤ 10⁻⁹; ≤ 0.2(A+B)Δt = \(fmt(bound, 3))")
    // Recovery at rest from λ_ss.
    var rest = EVPState(structure: a0 / (a0 + b1 * rate))
    let l0 = rest.structure
    var errR = 0.0
    for i in 1...Int((20 / dt).rounded()) {
      EVP.update(&rest, velocityGradient: simd_double2x2(0), dt: dt, material: m, fieldMagnitude: 0)
      errR = max(errR, abs(rest.structure - ReferenceLaws.structureDiscrete(steps: i, dt: dt, initial: l0, build: a0, breakdown: 0)))
    }
    suite.check(&pc, "V8", "structure recovery at rest, Δt \(fmt(dt, 2)) s (constitutive)", ok: errR <= 1e-9,
                measured: "vs discrete \(fmt(errR, 2)); λ(20 s) = \(fmt(rest.structure, 5)) vs exact \(fmt(ReferenceLaws.structure(time: 20, initial: l0, build: a0, breakdown: 0), 5))",
                target: "≤ 10⁻⁹")
  }

  // MPM level: Couette with a Bingham fluid, plastic-rate driven (w_vib = 0), then stop the wall.
  var bm = fluid(G: 5e3, K: 2e4, ty: 10, k: 1)
  bm.buildRate = a0; bm.breakShear = b1
  let gap = 5e-3, rows = 10
  let h = gap / Double(rows)
  var sc = ReferenceScene(size: SIMD2(4 * h, gap), cellSize: h, periodicX: true,
                          walls: ReferenceWalls(bottom: .fixed, top: .sticky(velocity: SIMD2(rate * gap, 0))))
  sc.fill(lower: .zero, upper: SIMD2(4 * h, gap), material: 0, bm)
  let s = ReferenceSolver2D(scene: sc, materials: [bm])
  let dt = explicitDt(bm, h: h)
  // Bulk = particles outside the walls' B-spline reach (1.5Δx); the sticky-wall rows shear faster (§9 item 4).
  let bulk = { (p: ReferenceParticle) in p.initialPosition.y >= 1.5 * h && p.initialPosition.y <= gap - 1.5 * h }
  var rateSum = 0.0, rateN = 0
  while s.time < 3 - 1e-12 {
    s.step(dt: min(dt, 3 - s.time))
    if s.stepCount % 10 == 0 {
      let b = s.particles.filter(bulk)
      rateSum += b.reduce(0) { $0 + $1.state.plasticRate } / Double(b.count); rateN += 1
    }
  }
  let bulkRate = rateSum / Double(rateN)
  let bulkP = s.particles.filter(bulk)
  let lam3 = bulkP.reduce(0) { $0 + $1.state.structure } / Double(bulkP.count)
  let all3 = s.particles.reduce(0) { $0 + $1.state.structure } / Double(s.particles.count)
  let ex3 = ReferenceLaws.structure(time: 3, initial: 1, build: a0, breakdown: b1 * bulkRate)
  let exU = ReferenceLaws.structure(time: 3, initial: 1, build: a0, breakdown: b1 * rate)
  suite.check(&pc, "V8", "structure breakdown in Couette, bulk (MPM, 3 s)", ok: abs(lam3 - ex3) <= 0.002,
              measured: "bulk λ \(fmt(lam3, 5)) vs \(fmt(ex3, 5)) at the bulk's mean γ̇ₚ \(fmt(bulkRate, 4)) /s",
              target: "±0.002")
  suite.info("V8", "structure breakdown vs U/h (\(rows) rows)",
             measured: "bulk γ̇ₚ/(U/h) = \(fmt(bulkRate / rate, 4)); all-particle λ \(fmt(all3, 4)) vs \(fmt(exU, 4)) at γ̇ₚ = U/h",
             target: "sticky-wall rows take extra shear at 10 rows (§9 item 4)")
  let lam3all = all3
  s.walls.top = .fixed
  s.advance(by: 4, dt: dt)
  let lam7 = s.particles.reduce(0) { $0 + $1.state.structure } / Double(s.particles.count)
  let ex7 = ReferenceLaws.structure(time: 4, initial: lam3all, build: a0, breakdown: 0)
  suite.check(&pc, "V8", "structure recovery after the wall stops (MPM, 4 s)", ok: abs(lam7 - ex7) <= 0.005,
              measured: "mean λ \(fmt(lam7, 5)) vs \(fmt(ex7, 5)); \(guardSummary(s))", target: "±0.005")
}

// MARK: - V9 viscosity bifurcation (stress-controlled, homogeneous)

/// One stress-controlled simple-shear step: finds γ̇ ≥ 0 such that the updated Kirchhoff τ_xy equals `target`.
private func stressControlledStep(_ st: inout EVPState, material m: ContinuumMaterial, target: Double, dt: Double) -> Double {
  func trial(_ rate: Double) -> Double {
    var copy = st
    return EVP.update(&copy, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0).y
  }
  var lo = 0.0, hi = 1.0
  if trial(0) >= target { EVP.update(&st, velocityGradient: EVP.simpleShear(0), dt: dt, material: m, fieldMagnitude: 0); return 0 }
  while trial(hi) < target && hi < 1e9 { lo = hi; hi *= 4 }
  for _ in 0..<200 {
    let mid = 0.5 * (lo + hi)
    if trial(mid) < target { lo = mid } else { hi = mid }
    if hi - lo <= 1e-13 * hi { break }
  }
  let rate = 0.5 * (lo + hi)
  EVP.update(&st, velocityGradient: EVP.simpleShear(rate), dt: dt, material: m, fieldMagnitude: 0)
  return rate
}

private func v9Bifurcation(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let k0 = 0.05, beta = 2e4, mm = 3.0, a0 = 0.1, b1 = 1.0
  guard let ext = ReferenceLaws.bifurcationExtrema(k0: k0, beta: beta, m: mm, a0: a0, b1: b1) else {
    suite.check(&pc, "V9", "bifurcation curve extrema", ok: false, measured: "none found", target: "max and min")
    return
  }
  // The note's rates come from a 400-point log grid (4 % spacing): the refined minimum sits at 3.268 /s, not 3.2.
  let okExt = abs(ext.maxStress / 14.8 - 1) < 0.005 && abs(ext.maxRate / 0.050 - 1) < 0.05
    && abs(ext.minStress / 0.25 - 1) < 0.01 && abs(ext.minRate / 3.2 - 1) < 0.05
  suite.check(&pc, "V9", "steady curve extrema", ok: okExt,
              measured: "max \(fmt(ext.maxStress, 4)) Pa at \(fmt(ext.maxRate, 4)) /s; min \(fmt(ext.minStress, 4)) Pa at \(fmt(ext.minRate, 4)) /s",
              target: "14.8 Pa at 0.050 /s; 0.25 Pa at 3.2 /s (stresses ±0.5–1 %, rates ±5 %: the note's 400-point grid)")
  var m = ContinuumMaterial(density: 2000, shearModulus: 5000, bulkModulus: 1e5, tensionLimit: .infinity,
                            consistency: k0, flowIndex: 1, consistencyStructure: beta)
  m.structureExponent = mm; m.buildRate = a0; m.breakShear = b1
  // Adaptive Δt keeps γ̇Δt ≤ 2 × 10⁻³ (the b̄ₑ kinematics are finite-strain: §4.6 needs γ̇Δt ≤ 10⁻²); the run stops at
  // 5/A₀ or once the rate has been steady to 10⁻⁷ for 2000 steps.
  for target in [10.0, 20.0] {
    var st = EVPState()
    var rate = 0.0, t = 0.0, steadySteps = 0
    while t < 5 / a0 && steadySteps < 2000 {
      let dt = min(1e-3, 2e-3 / max(rate, 1e-9))
      let r = stressControlledStep(&st, material: m, target: target, dt: dt)
      steadySteps = abs(r - rate) <= 1e-7 * r ? steadySteps + 1 : 0
      rate = r; t += dt
    }
    let roots = ReferenceLaws.bifurcationRoots(stress: target, k0: k0, beta: beta, m: mm, a0: a0, b1: b1)
    if target < ext.maxStress {
      let left = roots.first ?? .nan
      let ok = rate < ext.maxRate && abs(rate / left - 1) < 0.02
      suite.check(&pc, "V9", "stress step \(fmt(target, 3)) Pa from rest: stays on the viscous branch", ok: ok,
                  measured: "γ̇ = \(fmt(rate, 4)) /s at t = \(fmt(t, 3)) s, λ \(fmt(st.structure, 4)) (steady left root \(fmt(left, 4)) /s)",
                  target: "γ̇ < \(fmt(ext.maxRate, 3)) /s and = left root ± 2 %")
    } else {
      let right = roots.last ?? .nan
      let ok = rate > ext.minRate && abs(rate / right - 1) < 0.02
      suite.check(&pc, "V9", "stress step \(fmt(target, 3)) Pa from rest: avalanches", ok: ok,
                  measured: "γ̇ = \(fmt(rate, 4)) /s at t = \(fmt(t, 3)) s, λ \(fmt(st.structure, 3)) (steady right root \(fmt(right, 4)) /s)",
                  target: "γ̇ > \(fmt(ext.minRate, 3)) /s and = right root ± 2 %")
    }
  }
}

// MARK: - V10 Hele-Shaw drag decay

private func v10HeleShaw(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let h = 1e-3, rho = 1000.0, gap = 5e-3
  // Newtonian: v(t) = v₀(1 + Δt/t_HS)^(−n).
  do {
    let eta = 0.01
    let m = fluid(rho: rho, G: 100, K: 2e4, k: eta)
    var sc = ReferenceScene(size: SIMD2(8 * h, 8 * h), cellSize: h, periodicX: true, periodicY: true)
    sc.heleShaw = .gapAveraged(gap: gap, minimumTime: 0)
    sc.fill(lower: .zero, upper: SIMD2(8 * h, 8 * h), material: 0, m, velocity: SIMD2(0.1, 0))
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    let dt = explicitDt(m, h: h)
    let tHS = ReferenceLaws.heleShawTime(density: rho, gap: gap, viscosity: eta)
    let steps = Int((0.3 / dt).rounded())
    var maxRel = 0.0
    for i in 1...steps {
      s.step(dt: dt)
      let v = s.particles.reduce(0) { $0 + $1.velocity.x } / Double(s.particles.count)
      let be = 0.1 * pow(1 + dt / tHS, -Double(i))
      maxRel = max(maxRel, abs(v - be) / be)
    }
    suite.check(&pc, "V10", "Hele-Shaw Newtonian η 0.01, b 5 mm (t_HS \(fmt(tHS, 4)) s)", ok: maxRel <= 1e-12,
                measured: "max |v − v_BE|/v_BE = \(fmt(maxRel, 2)) over 0.3 s", target: "≤ 10⁻¹²")
  }
  // Power law: finite stop.
  do {
    let k = 1.0, n = 0.5, u0 = 0.05
    let m = fluid(rho: rho, G: 100, K: 2e4, k: k, n: n)
    let c = ReferenceLaws.powerLawDragCoefficient(consistency: k, index: n, density: rho, gap: gap)
    let tStop = ReferenceLaws.powerLawStopTime(initial: u0, coefficient: c, index: n)
    for frac in [0.5, 0.9, 1.2] {
      var sc = ReferenceScene(size: SIMD2(8 * h, 8 * h), cellSize: h, periodicX: true, periodicY: true)
      sc.heleShaw = .gapAveraged(gap: gap, minimumTime: 0)
      sc.fill(lower: .zero, upper: SIMD2(8 * h, 8 * h), material: 0, m, velocity: SIMD2(u0, 0))
      let s = ReferenceSolver2D(scene: sc, materials: [m])
      let dt = explicitDt(m, h: h)
      let steps = Int((frac * tStop / dt).rounded(.up))
      for _ in 0..<steps { s.step(dt: dt) }
      let v = s.particles.reduce(0) { $0 + $1.velocity.x } / Double(s.particles.count)
      let ex = ReferenceLaws.powerLawDragSpeed(time: s.time, initial: u0, coefficient: c, index: n)
      let err = abs(v - ex) / u0
      if frac < 1 {
        suite.check(&pc, "V10", "Hele-Shaw power law k 1, n 0.5 at \(fmt(s.time / tStop, 3)) t_stop", ok: err <= 0.005,
                    measured: "Ū \(fmt(v, 5)) vs \(fmt(ex, 5)) m/s (\(pct(err, 3)) of Ū₀)", target: "≤ 0.5 % of Ū₀")
      } else {
        suite.check(&pc, "V10", "Hele-Shaw power law stops (t_stop \(fmt(tStop * 1e3, 4)) ms)", ok: abs(v) <= 1e-9 * u0,
                    measured: "Ū(\(fmt(s.time / tStop, 3)) t_stop) = \(fmt(v, 3)) m/s", target: "0 after t_stop")
      }
    }
  }
}

// MARK: - V11 oobleck jamming front (exploratory: info rows, not counted)

/// Least-squares speed of the front while it is between 25 % and 75 % of the layer depth.
private func frontSpeed(_ samples: [(t: Double, front: Double)], depth: Double) -> (speed: Double, count: Int) {
  let win = samples.filter { $0.front >= 0.25 * depth && $0.front <= 0.75 * depth }
  guard win.count >= 3 else { return (.nan, win.count) }
  let n = Double(win.count)
  let st = win.reduce(0) { $0 + $1.t }, sf = win.reduce(0) { $0 + $1.front }
  let stt = win.reduce(0) { $0 + $1.t * $1.t }, stf = win.reduce(0) { $0 + $1.t * $1.front }
  return ((stf - st * sf / n) / (stt - st * st / n), win.count)
}

private func v11JammingFront(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  let preset = ContinuumPresets.oobleck
  let h = 1e-3, width = 0.07, depth = 0.04
  let half = SIMD2(5e-3, 2.5e-3)                               // a 1 cm plate, 5 mm thick
  let theory = ReferenceLaws.jammingFrontRatio(phi: preset.dst?.phi ?? 0.52)
  var stiff = preset                                           // sensitivity: 4× the toy shear modulus
  stiff.shearModulus = 8e4
  stiff.bulkModulus = ContinuumPresets.oracleBulkModulus(density: stiff.density, shearModulus: stiff.shearModulus)

  /// A 4 cm layer settled under gravity (ramped over 0.02 s, 0.08 s in all) and its surface height under the plate.
  func settledLayer(_ m: ContinuumMaterial) -> (solver: ReferenceSolver2D, surface: Double) {
    var sc = ReferenceScene(size: SIMD2(width, depth + 0.02), cellSize: h, walls: .tank,
                            bodyAcceleration: ReferenceScene.ramped(SIMD2(0, -g0), over: 0.02))
    sc.fill(lower: .zero, upper: SIMD2(width, depth), material: 0, m)
    let s = ReferenceSolver2D(scene: sc, materials: [m])
    s.advance(by: 0.08, dt: explicitDt(m, h: h, courant: 0.3, vmax: 1))
    let top = s.particles.filter { abs($0.position.x - width / 2) <= half.x }.map(\.position.y).max() ?? depth
    return (s, top + 0.25 * h)
  }
  /// The settled layer with a kinematic plate resting on its surface, moving down at `u0`.
  func plateRun(_ base: (solver: ReferenceSolver2D, surface: Double), _ m: ContinuumMaterial, speed u0: Double,
                sticky: Bool) -> ReferenceSolver2D {
    let s = ReferenceSolver2D(scene: base.solver.scene, materials: [m])
    s.setParticles(base.solver.particles)
    s.bodyAcceleration = ReferenceScene.uniform(SIMD2(0, -g0))
    s.boxes = [ReferenceBox(center: SIMD2(width / 2, base.surface + half.y), halfSize: half, velocity: SIMD2(0, -u0),
                            sticky: sticky)]
    return s
  }

  // Front speed: the deepest jammed particle (s > 0.5) in the plate's column, below the undisturbed surface.
  var bases: [Double: (solver: ReferenceSolver2D, surface: Double)] = [:]
  for (label, m, u0) in [("toy G 20 kPa", preset, 1.0), ("toy G 20 kPa", preset, 0.3), ("G 80 kPa", stiff, 0.3)] {
    let base = bases[m.shearModulus] ?? settledLayer(m)
    bases[m.shearModulus] = base
    let s = plateRun(base, m, speed: u0, sticky: true)
    let dt = explicitDt(m, h: h, courant: 0.3, vmax: 1.5 * u0 * theory)
    var samples: [(t: Double, front: Double)] = []
    while s.time < 0.05 {
      s.step(dt: dt)
      let jammed = s.particles.filter { abs($0.position.x - width / 2) <= half.x && $0.jam > 0.5 }.map(\.position.y)
      samples.append((s.time, base.surface - (jammed.min() ?? base.surface)))
      if samples[samples.count - 1].front > 0.9 * depth || u0 * s.time > 0.02 { break }
    }
    let (speed, count) = frontSpeed(samples, depth: depth)
    let ratio = speed / u0
    let cs = (m.shearModulus / m.density).squareRoot()
    let last = samples.last.map { "front \(fmt($0.front * 1e3, 3)) mm deep when the plate was \(fmt(u0 * $0.t * 1e3, 3)) mm in" } ?? "no samples"
    let within = ratio.isFinite && abs(ratio / theory - 1) <= 0.3
    suite.info("V11", "jamming front, sticky plate at \(fmt(u0, 2)) m/s, \(label) (hypothesis ±30 %: \(within ? "met" : "not met"))",
               measured: "U_f/U₀ = \(fmt(ratio, 3)) (U_f = \(fmt(speed, 3)) m/s = \(fmt(speed / cs, 3)) c_s; \(count) samples; \(last)); \(guardSummary(s))",
               target: "1/γ_∞ = \(fmt(theory, 3)) (Han et al. 2018)")
  }

  // Slow push (0.02 m/s for 0.25 s = 5 mm) must not jam. Jammed particles are counted ahead of (below) the plate face,
  // inside the plate's footprint (particles a grid-node collider has swallowed at its corners) and elsewhere, for a
  // sticky and a frictionless plate.
  for sticky in [true, false] {
    let base = bases[preset.shearModulus] ?? settledLayer(preset)
    let s = plateRun(base, preset, speed: 0.02, sticky: sticky)
    let dt = explicitDt(preset, h: h, courant: 0.3, vmax: 0.5)
    var maxAhead = 0, maxInside = 0, maxElsewhere = 0, maxJam = 0.0
    var first = ""
    while s.time < 0.25 - 1e-12 {
      s.step(dt: min(dt, 0.25 - s.time))
      guard s.stepCount % 20 == 0 else { continue }
      let plate = s.boxes[0]
      let bottom = plate.center.y - plate.halfSize.y
      var ahead = 0, inside = 0, elsewhere = 0
      for p in s.particles where p.jam > 0.5 {
        if plate.contains(p.position) { inside += 1 } else if p.position.y < bottom
          && abs(p.position.x - plate.center.x) <= plate.halfSize.x + h { ahead += 1 } else { elsewhere += 1 }
        if first.isEmpty {
          first = String(format: "; first at x − x_plate = %+.1f mm, %+.1f mm from the plate face, t = %.3f s",
                         (p.position.x - plate.center.x) * 1e3, (p.position.y - bottom) * 1e3, s.time)
        }
      }
      maxAhead = max(maxAhead, ahead); maxInside = max(maxInside, inside); maxElsewhere = max(maxElsewhere, elsewhere)
      maxJam = max(maxJam, s.particles.map(\.jam).max() ?? 0)
    }
    let verdict = maxAhead + maxInside + maxElsewhere == 0 ? "met"
      : (maxAhead + maxElsewhere == 0 ? "met in the fluid; corner particles inside the collider jam" : "not met")
    suite.info("V11", "slow push, \(sticky ? "sticky" : "frictionless") plate at 0.02 m/s for 5 mm (hypothesis 'does not jam': \(verdict))",
               measured: "max jammed particles (s > 0.5): \(maxAhead) ahead of the plate, \(maxInside) inside its footprint, \(maxElsewhere) elsewhere\(first); max jam blend \(fmt(maxJam, 3)); \(guardSummary(s))",
               target: "none (§7 V11)")
  }
}

// MARK: - V12 field and temperature laws

/// |calc − table| within half a unit of the table's last printed digit (plus 10⁻⁴ relative slack).
private func matchesTable(_ calc: Double, _ table: Double, decimals: Int) -> Bool {
  abs(calc - table) <= 0.5 * pow(10, -Double(decimals)) + 1e-4 * abs(table)
}

private func v12Laws(_ pc: inout PhysCheck, _ suite: inout MPMSuite) {
  // MR yield (Carlson, unclamped) and B–H against the §3.8 table.
  let hs: [Double] = [40, 400, 1000, 4000, 10_000, 20_000, 50_000, 100_000, 200_000, 300_000]
  let tauTable: [(Double, Int)] = [(11.8, 1), (118, 0), (296, 0), (1183, 0), (2954, 0), (5884, 0), (14314, 0), (26172, 0),
                                   (39844, 0), (44678, 0)]
  let bTable: [(Double, Int)] = [(0.33, 2), (3.3, 1), (8.3, 1), (32.7, 1), (79, 0), (149, 0), (320, 0), (512, 0), (735, 0), (885, 0)]
  var unclamped = ContinuumPresets.mrFluid
  unclamped.field?.clampFractionOfG = 1e9
  var worstTau = "", okTau = true, okB = true, worstB = ""
  for (i, hv) in hs.enumerated() {
    let t = EVP.fieldYield(fieldMagnitude: hv, material: unclamped)
    if !matchesTable(t, tauTable[i].0, decimals: tauTable[i].1) { okTau = false; worstTau += " H=\(fmt(hv, 6)): \(fmt(t, 6)) vs \(tauTable[i].0);" }
    let b = ReferenceLaws.carlsonFluxDensity(field: hv) * 1e3
    if !matchesTable(b, bTable[i].0, decimals: bTable[i].1) { okB = false; worstB += " H=\(fmt(hv, 6)): \(fmt(b, 4)) vs \(bTable[i].0);" }
  }
  suite.check(&pc, "V12", "MR yield τ_field(H), 10 table points (unclamped preset)", ok: okTau,
              measured: okTau ? "all within table rounding (e.g. H 10⁵: \(fmt(EVP.fieldYield(fieldMagnitude: 1e5, material: unclamped), 6)) Pa)" : worstTau,
              target: "§3.8 table to its printed digits")
  suite.check(&pc, "V12", "MR flux density B(H), 10 table points", ok: okB,
              measured: okB ? "all within table rounding" : worstB, target: "§3.8 table")
  let clamped = EVP.fieldYield(fieldMagnitude: 8000, material: ContinuumPresets.mrFluid)
  suite.check(&pc, "V12", "MR toy clamp 0.05·G", ok: abs(clamped - 1500) <= 1e-9,
              measured: "τ_field(8 kA/m) = \(fmt(clamped, 6)) Pa (unclamped \(fmt(ReferenceLaws.carlsonYield(field: 8000), 5)))",
              target: "1500 Pa")

  // Honey: a_T·η(20 °C) against the §3.1 table, through the shift factor and through the full update.
  let honeyTable: [(Double, Double, Int)] = [(10, 52.7, 1), (15, 28.2, 1), (20, 15.4, 1), (25, 8.57, 2), (30, 4.87, 2),
                                             (40, 1.66, 2), (50, 0.604, 3), (60, 0.234, 3)]
  let eta20 = ReferenceLaws.honeyViscosity(kelvin: 293.15)
  var okHoney = true, okPipe = true, detail = "", worstPipe = 0.0
  for (c, table, dec) in honeyTable {
    let tk = 273.15 + c
    let aT = EVP.shiftFactor(activationEnergy: 85_000, temperature: tk, reference: 293.15)
    if !matchesTable(aT * eta20, table, decimals: dec) { okHoney = false; detail += " \(c) °C: \(fmt(aT * eta20, 4)) vs \(table);" }
    // Pipeline: honey preset, steady simple shear at Wi ≤ 10⁻³.
    var st = EVPState.rested(ContinuumPresets.honey)
    st.temperature = tk
    let eta = ContinuumPresets.honey.consistency * aT
    let rate = 1e-3 * ContinuumPresets.honey.shearModulus / eta
    var tau = SIMD3<Double>.zero
    let dt = 0.02 * eta / ContinuumPresets.honey.shearModulus
    for _ in 0..<2000 { tau = EVP.update(&st, velocityGradient: EVP.simpleShear(rate), dt: dt, material: ContinuumPresets.honey, fieldMagnitude: 0) }
    let rel = abs(tau.y / rate / eta - 1)
    worstPipe = max(worstPipe, rel)
    if rel > 1e-4 { okPipe = false }
  }
  suite.check(&pc, "V12", "honey Arrhenius a_T·η(20 °C), 10–60 °C", ok: okHoney,
              measured: okHoney ? "8/8 table values reproduced (η(20 °C) = \(fmt(eta20, 5)) Pa·s)" : detail,
              target: "§3.1 table to its printed digits")
  suite.check(&pc, "V12", "honey preset steady viscosity through EVP.update, 10–60 °C", ok: okPipe,
              measured: "max |τ/(γ̇·a_T·k) − 1| = \(fmt(worstPipe, 2)) at Wi 10⁻³", target: "≤ 10⁻⁴ (2Wi² = 2 × 10⁻⁶)")

  // Cheng water and glycerol tables, effective E_a 15–25 °C, glycerol VFT.
  let temps: [Double] = [0, 10, 20, 25, 30, 40, 60, 80, 100]
  let water: [(Double, Int)] = [(1.790, 3), (1.310, 3), (1.005, 3), (0.893, 3), (0.800, 3), (0.655, 3), (0.468, 3), (0.356, 3), (0.283, 3)]
  let glyc: [(Double, Int)] = [(12.10, 2), (3.817, 3), (1.414, 3), (0.906, 3), (0.598, 3), (0.282, 3), (0.0822, 4), (0.0315, 4), (0.0148, 4)]
  var okW = true, okG = true, vftErr = 0.0
  for (i, c) in temps.enumerated() {
    if !matchesTable(ReferenceLaws.chengWaterViscosity(celsius: c) * 1e3, water[i].0, decimals: water[i].1) { okW = false }
    if !matchesTable(ReferenceLaws.chengGlycerolViscosity(celsius: c), glyc[i].0, decimals: glyc[i].1) { okG = false }
  }
  for c in stride(from: 0.0, through: 100.0, by: 1.0) {
    vftErr = max(vftErr, abs(ReferenceLaws.glycerolVFT(kelvin: 273.15 + c) / ReferenceLaws.chengGlycerolViscosity(celsius: c) - 1))
  }
  suite.check(&pc, "V12", "Cheng 2008 water and glycerol tables", ok: okW && okG,
              measured: "water \(okW ? "9/9" : "mismatch"), glycerol \(okG ? "9/9" : "mismatch")", target: "§3.1 table")
  let eaW = ReferenceLaws.effectiveActivationEnergy(eta1: ReferenceLaws.chengWaterViscosity(celsius: 15), t1: 288.15,
                                                    eta2: ReferenceLaws.chengWaterViscosity(celsius: 25), t2: 298.15)
  let eaG = ReferenceLaws.effectiveActivationEnergy(eta1: ReferenceLaws.chengGlycerolViscosity(celsius: 15), t1: 288.15,
                                                    eta2: ReferenceLaws.chengGlycerolViscosity(celsius: 25), t2: 298.15)
  suite.check(&pc, "V12", "effective E_a 15–25 °C", ok: abs(eaW / 17_500 - 1) < 0.003 && abs(eaG / 66_000 - 1) < 0.003,
              measured: "water \(fmt(eaW / 1e3, 4)), glycerol \(fmt(eaG / 1e3, 4)) kJ/mol", target: "17.5 and 66.0 kJ/mol")
  suite.check(&pc, "V12", "glycerol VFT fit vs Cheng, 0–100 °C", ok: abs(vftErr - 0.024) < 0.0015,
              measured: "max error \(pct(vftErr, 2))", target: "2.4 % (§3.1)")
  // Water-like preset a_T ratio between 15 and 25 °C vs Cheng.
  let wl = ContinuumPresets.waterLike
  let ratioModel = EVP.shiftFactor(activationEnergy: wl.activationEnergy, temperature: 288.15, reference: wl.referenceTemperature)
    / EVP.shiftFactor(activationEnergy: wl.activationEnergy, temperature: 298.15, reference: wl.referenceTemperature)
  let ratioCheng = ReferenceLaws.chengWaterViscosity(celsius: 15) / ReferenceLaws.chengWaterViscosity(celsius: 25)
  suite.check(&pc, "V12", "water-like preset η(15 °C)/η(25 °C)", ok: abs(ratioModel / ratioCheng - 1) < 0.005,
              measured: "\(fmt(ratioModel, 5)) vs Cheng \(fmt(ratioCheng, 5))", target: "±0.5 %")
}
