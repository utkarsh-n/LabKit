// LabKitCore checks (owned by WP-C). Moved out of main.swift so WP-O can add the MPM oracle checks alongside.
import Foundation
import LabKitCore
import simd

func runCoreChecks(_ pc: inout PhysCheck) {

  // 1. RK4 on a harmonic oscillator conserves energy over 100 periods.
  do {
    struct SHO: IntegrableState {
      var x: Double, v: Double
      static func + (a: SHO, b: SHO) -> SHO { SHO(x: a.x + b.x, v: a.v + b.v) }
      static func * (k: Double, a: SHO) -> SHO { SHO(x: k * a.x, v: k * a.v) }
    }
    let w = 2 * Double.pi
    var s = SHO(x: 1, v: 0)
    let h = 1.0 / 120
    for _ in 0..<(120 * 100) { s = RK4.step(s, h: h) { SHO(x: $0.v, v: -w * w * $0.x) } }
    let e = 0.5 * s.v * s.v + 0.5 * w * w * s.x * s.x
    pc.near("RK4 energy (SHO, 100 periods)", measured: e, theory: 0.5 * w * w, tolerance: 1e-4)
  }

  // 2. Substep rule matches GyroSim at 12,000 rpm.
  do {
    let n = substepCount(dt: 1.0 / 120, fastestRate: 12_000 * 2 * .pi / 60 * 2)
    pc.check("substep rule", n == 210, "n = \(n) for ω = 2513 rad/s at 120 Hz (⌈20.94 rad / 0.1⌉)")
  }

  // 3. Param mapping: log knob round-trips; detents capture; lower-bound quantisation; nudges stop at detents.
  do {
    let time = ParamSpec(
      "time", title: "Time", icon: "hourglass", range: 0.05...2, defaultValue: 1, scale: .logarithmic,
      detents: [Detent(0.25, "Slow motion"), Detent(1, "Real time")], hint: "", provenance: .illustrative,
      format: .multiplier(precision: 2))
    let p = time.position(of: 1)
    let back = time.value(at: p)
    pc.check("log knob round-trip", abs(back - 1) < 1e-12, String(format: "pos(1) = %.4f → %.12f", p, back))
    pc.check("detent lookup", time.detent(at: 0.2501)?.label == "Slow motion", "0.2501 → \(time.detent(at: 0.2501)?.label ?? "nil")")
    let gain = ParamSpec("g", title: "G", icon: "dial.medium", range: 0.25...3, defaultValue: 1, step: 0.1, hint: "",
      format: .number(precision: 2, unit: ""))
    pc.check("quantise from the lower bound", gain.value(at: 0) == 0.25 && gain.value(at: 1) == 3 && gain.quantised(0.33) == 0.35,
      "0.25…3 step 0.1: ends \(gain.value(at: 0)), \(gain.value(at: 1)); 0.33 → \(gain.quantised(0.33))")
    let gravity = ParamSpec("gravity", title: "Gravity", icon: "arrow.down.to.line", range: -1...3, defaultValue: 1,
      origin: 0, detents: Gravity.detents, step: 0.01, hint: "", format: .number(precision: 2, unit: "g"))
    let n = gravity.nudged(0.9, by: 1)
    pc.check("nudge stops at a detent", abs(n - 1) < 1e-12, "0.9 + one nudge → \(n) (Earth)")
  }

  // 4. Modulation: Gyre's Gravity drive adds depth·m·2; the gate disables the others.
  do {
    let specs: [ParamID: ParamSpec] = [
      "gravity": ParamSpec("gravity", title: "Gravity", icon: "arrow.down.to.line", range: -1...3, defaultValue: 1,
        hint: "", format: .number(precision: 2, unit: "g")),
      "air": ParamSpec("air", title: "Air", icon: "wind", range: 0...3, defaultValue: 1, hint: "",
        format: .number(precision: 2, unit: "")),
    ]
    var router = ModulationRouter([
      ModRoute("gravity", source: .micEnvelope, target: "gravity", depthParam: "listen", gate: ModGate("drives", 0), mode: .add(2)),
      ModRoute("air", source: .micEnvelope, target: "air", depthParam: "listen", gate: ModGate("drives", 1), mode: .multiply(3)),
      ModRoute("kick", source: .micOnset, target: "kick", depthParam: "listen", gate: ModGate("drives", 3),
        curve: .normalize(5), mode: .trigger(threshold: 0)),
    ])
    var params = ParamValues(["gravity": 1, "air": 1, "listen": 0.6, "drives": 0])
    var src = ModSources()
    src[.micEnvelope] = 0.5
    _ = router.apply(src, to: &params, specs: specs, dt: 1.0 / 120)
    pc.check("gravity drive", abs(params["gravity"] - 1.6) < 1e-12 && params["air"] == 1, "g = \(params["gravity"]), air = \(params["air"])")
    params = ParamValues(["gravity": 1, "air": 1, "listen": 0.6, "drives": 3])
    src[.micOnset] = 7
    let out = router.apply(src, to: &params, specs: specs, dt: 1.0 / 120)
    pc.check("kick trigger", abs((out.fired("kick")?.strength ?? 0) - 0.6) < 1e-12, "strength \(out.fired("kick")?.strength ?? 0)")
  }

  // 5. Envelope: a steady tone fades to ~0 above its own floor; a clap jumps.
  do {
    var env = EnvelopeFollower()
    var peak = 0.0
    for _ in 0..<(120 * 60) { env.step(level: 0.05, gain: 1, dt: 1.0 / 120) }
    let steady = env.value
    for _ in 0..<6 { peak = max(peak, env.step(level: 0.8, gain: 1, dt: 1.0 / 120)) }
    pc.check("envelope ignores steady hum", steady < 0.05, String(format: "steady %.3f, clap peak %.3f", steady, peak))
  }

  // 6. Spectrum finds a 1 kHz tone in the right band.
  do {
    let sp = Spectrum()
    let tone = (0..<4096).map { Float(0.3 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
    for _ in 0..<10 { sp.update(tone, gain: 1, dt: 1.0 / 60) }
    let best = sp.bands.indices.max { sp.bands[$0] < sp.bands[$1] }!
    let lo = 45 * pow(15_000.0 / 45, Double(best) / 48), hi = 45 * pow(15_000.0 / 45, Double(best + 1) / 48)
    pc.check("spectrum band of 1 kHz", lo <= 1000 * 1.06 && hi >= 1000 * 0.94, String(format: "band %d = %.0f–%.0f Hz", best, lo, hi))
  }

  // 7. Environment: gravity in the phone frame for the resting pose (pitch 60°).
  do {
    let e = LabEnvironment.from(.resting, gravityScale: 1)
    let g = e.screenGravity
    pc.check("screen gravity at rest", abs(g.y + Gravity.g0 * sin(60 * .pi / 180)) < 1e-9 && abs(g.x) < 1e-9,
      String(format: "in-plane g = (%.3f, %.3f) m/s²", g.x, g.y))
  }

  // 8. Parameter formats and spoken values (labkit-from-orbitals-spectra.md §3.3, §4.2).
  do {
    let consistency = ParamSpec(
      "consistency", title: "Consistency", icon: "drop.fill", range: 0.001...1000, defaultValue: 0.0136,
      scale: .logarithmic, detents: [Detent(0.001, "Water"), Detent(1.414, "Glycerol")], hint: "",
      format: .si(unit: "Pa·sⁿ"))
    let ratio = consistency.nudged(10, by: 1) / 10  // no detent between 10 and 20
    pc.near("log nudge is a constant ratio", measured: ratio, theory: pow(10, 6.0 / 20), tolerance: 1e-9)
    let gravity = ParamSpec("gravity", title: "Gravity", icon: "arrow.down.to.line", range: -1...3, defaultValue: 1,
      origin: 0, detents: Gravity.detents, step: 0.01, hint: "", format: .number(precision: 2, unit: "g"))
    let spoken = gravity.accessibilityValue(1)
    pc.check("detent announced with the value", spoken.hasSuffix(", Earth"), "accessibilityValue(1) = \"\(spoken)\"")
    pc.check("negative values use U+2212", gravity.formatted(-0.5) == "\u{2212}0.50 g", "−0.5 → \"\(gravity.formatted(-0.5))\"")
  }

  // 9. Design tokens: the life-size table and Rheo's contrast-derived colours (§2.3, §9.2).
  do {
    let mm = LabDisplay.millimetresPerPoint(modelIdentifier: LabDisplay.referenceModel) ?? 0
    pc.near("mm per point, iPhone 15 Pro Max", measured: mm, theory: 0.16565, tolerance: 1e-4, unit: " mm")
    pc.check("unknown model has no physical scale", LabDisplay.millimetresPerPoint(modelIdentifier: "iPhone99,9") == nil,
      "iPhone99,9 → nil (hide LIFE-SIZE, fit instead)")
    let p = LabPalette.rheo
    let onSig = p.onSignature.contrast(against: p.signature)
    let deep = LabColor.white.contrast(against: p.signatureDeep)
    let white = LabColor.white.contrast(against: p.signature)
    pc.check("label on Rheo's signature fill ≥ 4.5:1", onSig >= 4.5,
      String(format: "onSignature %.2f:1 (white would be %.2f:1)", onSig, white))
    pc.check("white on Rheo's signatureDeep ≥ 4.49:1", deep >= 4.49, String(format: "%.2f:1", deep))
  }
}
