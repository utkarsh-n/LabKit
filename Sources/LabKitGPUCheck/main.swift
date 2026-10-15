// labkit-gpucheck — GPU continuum engine checks on the Mac GPU (WP-G; ARCHITECTURE.md §5.2, rheology-models.md §7).
//
//   Tools/lk.sh <name> env TOOLCHAINS=metal swift run -c release labkit-gpucheck [sections…] [--png <path>]
//
// Sections (default: all): dam pi mass buoyancy materials oobleck pour magnet v13 v14 render; development entries
// (not in all): foamdev mrdev mrfinger mrabove monstersdev gravitydev (FoamChecks / MagnetChecks / VibrationChecks.swift). Prints markdown tables and a
// PASS/FAIL summary; exits 1 if a judged check fails. Numbers go into LabKit/Documentation/VERIFICATION-GPU.md.
import Foundation
import Metal
import LabKitCore
import LabKitMPM

let arguments = Array(CommandLine.arguments.dropFirst())
var pngPath: String?
var sections: [String] = []
var i = 0
while i < arguments.count {
  if arguments[i] == "--png", i + 1 < arguments.count { pngPath = arguments[i + 1]; i += 2; continue }
  sections.append(arguments[i].lowercased())
  i += 1
}
let all = ["dam", "pi", "mass", "buoyancy", "materials", "oobleck", "pour", "magnet", "v13", "v14", "render"]
if sections.isEmpty || sections.contains("all") { sections = all }

guard let device = MTLCreateSystemDefaultDevice() else {
  print("labkit-gpucheck: no Metal device")
  exit(2)
}
let report = Report()
print("labkit-gpucheck on \(device.name), \(ProcessInfo.processInfo.operatingSystemVersionString)")
do {
  let probe = try MPMSolver(device: device, domain: MPMDomain(), quality: .standard, capacity: 64)
  report.add("S1", "SIMD-group probe → impulse reduction path", pass: nil,
             "probe \(probe.simdProbePassed == true ? "passed" : "failed") → \(probe.usesSIMDGroupReduction ? "SIMD-group" : "threadgroup-atomic fallback")")
  let start = Date()
  for s in sections {
    switch s {
    case "dam": try checkDamBreak(device, report)
    case "pi": try checkPiTable(device, report)
    case "mass": try checkMass(device, report)
    case "buoyancy": try checkBuoyancy(device, report)
    case "materials": try checkMaterials(device, report)
    case "oobleck": try checkOobleck(device, report)
    case "v13": try checkV13(device, report)
    case "v14":
      try checkV14Constitutive(device, report)
      try checkV14Spatial(device, report)
      try checkLavaBand(device, report)
    case "pour": try checkPours(device, report)
    case "foamdev": try foamDev(device, report)
    case "magnet": try checkMagnet(device, report)
    case "mrdev": try mrDev(device, report)
    case "mrfinger": try mrFingerDev(device)
    case "mrabove": try mrAboveDev(device)
    case "monstersdev": try monstersDev(device)
    case "gravitydev": try gravityDev(device)
    case "render":
      try checkRenderTiming(device, report)
      try writeContactSheet(device, path: pngPath ?? FileManager.default.temporaryDirectory.appendingPathComponent("labkit-fluid-looks.png").path, report)
    default: print("unknown section \(s); known: \(all.joined(separator: " "))")
    }
  }
  print(String(format: "\n(%.0f s)", Date().timeIntervalSince(start)))
} catch {
  print("labkit-gpucheck: \(error)")
  exit(2)
}
report.printSummary()
exit(report.failures == 0 ? 0 : 1)
