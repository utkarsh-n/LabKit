import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPM
import LabKitMPMReference

/// V14e (`labkit-gpucheck v14`): lava's cooling band (LK-FIX). The flow law follows the temperature from the 1170 °C
/// eruption down to 900 °C (T_ref − 230 K) instead of stopping at T_ref − 40 K = 1090 °C. GPU float32 `rheoUpdate` vs the
/// oracle's `EVP.update` at 1 s⁻¹ simple shear from rest for 0.5 s (Δt = 1/1440 s, the same temperature held), at
/// 1170 … 850 °C. Judged: τ̄ within 1e-5 of the oracle at every temperature, and τ̄ rises monotonically down to 900 °C
/// and is flat below it. Recorded: τ̄ with the old 40 K band.
func checkLavaBand(_ device: MTLDevice, _ report: Report) throws {
  print("\n== V14e Lava cooling band: GPU vs oracle, 1 1/s simple shear for 0.5 s at a held temperature ==")
  let probe = try MPMConstitutiveProbe(device: device)
  let lava = ContinuumPresets.lava
  var narrow = lava
  narrow.temperatureBandBelow = nil
  let celsius: [Double] = [1170, 1130, 1090, 1050, 1000, 950, 900, 850]
  let dt = 1.0 / 1440, steps = 720
  func gpuStress(_ m: ContinuumMaterial) -> [Double] {
    var points = celsius.map { MPMConstitutiveProbe.Point(structure: 1, temperature: $0 + 273.15) }
    let out = probe.run(materials: [m], points: &points, materialIndex: Array(repeating: 0, count: celsius.count),
                        velocityGradient: Array(repeating: EVP.simpleShear(1), count: celsius.count), dt: dt, steps: steps)
    return out.map { EVP.equivalentShearStress($0) }
  }
  func cpuStress(_ m: ContinuumMaterial) -> [Double] {
    celsius.map { c in
      var s = EVPState.rested(m)
      s.temperature = c + 273.15
      var tau = SIMD3<Double>.zero
      for _ in 0..<steps { tau = EVP.update(&s, velocityGradient: EVP.simpleShear(1), dt: dt, material: m, fieldMagnitude: 0) }
      return EVP.equivalentShearStress(tau)
    }
  }
  let g = gpuStress(lava), c = cpuStress(lava), old = cpuStress(narrow)
  print("| T (°C) | GPU τ̄ (Pa) | oracle τ̄ (Pa) | |Δτ̄|/τ̄ | before LK-FIX (40 K band) τ̄ (Pa) |")
  print("|---|---|---|---|---|")
  var worst = 0.0
  for i in celsius.indices {
    let rel = abs(g[i] - c[i]) / max(c[i], 1e-9)
    worst = max(worst, rel)
    print("| \(fmt(celsius[i], 0)) | \(fmt(g[i], 2)) | \(fmt(c[i], 2)) | \(sci(rel)) | \(fmt(old[i], 2)) |")
  }
  let i900 = celsius.firstIndex(of: 900)!
  var monotone = true
  for i in 1...i900 where c[i] <= c[i - 1] { monotone = false }
  let flatBelow = abs(c[i900 + 1] - c[i900]) <= 1e-9 * c[i900]
  report.add("V14e", "lava stiffens from 1170 to 900 °C, GPU = oracle within 1e-5", pass: worst <= 1e-5 && monotone && flatBelow,
             "τ̄ at 1 1/s: \(fmt(c[0], 1)) Pa at 1170 °C → \(fmt(c[i900], 1)) Pa at 900 °C (×\(fmt(c[i900] / c[0], 1)); 40 K band stopped at \(fmt(old[i900], 1)) Pa), worst GPU/oracle \(sci(worst))")
}
