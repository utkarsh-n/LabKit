import CoreGraphics
import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPM

// labkit-gpucheck support: a waiting frame loop around MPMSolver, measurements and the PASS/FAIL report.

/// One line of the final table. `pass == nil` = recorded, not judged.
struct CheckResult {
  let id: String
  let title: String
  let pass: Bool?
  let detail: String
}

final class Report {
  private(set) var results: [CheckResult] = []
  func add(_ id: String, _ title: String, pass: Bool?, _ detail: String) {
    results.append(CheckResult(id: id, title: title, pass: pass, detail: detail))
    let tag = pass.map { $0 ? "PASS" : "FAIL" } ?? "INFO"
    print("  [\(tag)] \(id) \(title): \(detail)")
  }
  var failures: Int { results.filter { $0.pass == false }.count }
  func printSummary() {
    print("\n== Summary ==")
    print("| ID | Check | Result | Measured |")
    print("|---|---|---|---|")
    for r in results {
      print("| \(r.id) | \(r.title) | \(r.pass.map { $0 ? "PASS" : "FAIL" } ?? "info") | \(r.detail) |")
    }
    print("\n\(results.filter { $0.pass == true }.count) passed, \(failures) failed, \(results.filter { $0.pass == nil }.count) recorded")
  }
}

func fmt(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }
func sci(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)e", x) }

/// A solver with its own queue; every frame is committed and waited on (the harness measures, the app never waits).
final class Rig {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let solver: MPMSolver
  private(set) var gpuTimes: [Double] = []

  init(device: MTLDevice, domain: MPMDomain = MPMDomain(), quality: MPMQuality = .standard, capacity: Int = 40_000,
       verification: MPMVerificationOptions = MPMVerificationOptions(), materials: [ContinuumMaterial]) throws {
    self.device = device
    queue = device.makeCommandQueue()!
    solver = try MPMSolver(device: device, domain: domain, quality: quality, capacity: capacity, verification: verification)
    solver.materials = materials
    solver.debugValidation = false
  }

  @discardableResult
  func frame(_ input: MPMFrameInput = MPMFrameInput()) -> MPMStats {
    let cmd = queue.makeCommandBuffer()!
    solver.encode(into: cmd, input: input)
    cmd.commit()
    cmd.waitUntilCompleted()
    if cmd.status != .completed { print("  command buffer failed: \(String(describing: cmd.error))") }
    let s = solver.stats
    gpuTimes.append(s.gpuMilliseconds)
    return s
  }

  @discardableResult
  func run(_ frames: Int, input: MPMFrameInput = MPMFrameInput(), each: ((Int, MPMStats) -> Void)? = nil) -> MPMStats {
    var last = MPMStats()
    for f in 0..<frames {
      last = frame(input)
      each?(f, last)
    }
    return last
  }

  func resetTimes() { gpuTimes.removeAll() }
  /// Median and 90th percentile of the per-frame GPU times recorded since the last reset, ms.
  var timing: (median: Double, p90: Double) {
    let t = gpuTimes.sorted()
    guard !t.isEmpty else { return (0, 0) }
    return (t[t.count / 2], t[min(t.count - 1, Int(Double(t.count) * 0.9))])
  }

  var particles: [MPMParticleSnapshot] { solver.debugParticles().filter(\.enabled) }

  /// Cells holding at least one particle divided by the initial particle count / 4 (mpm-metal.md §12.2 "occupancy").
  func occupancy(initialParticles: Int) -> Double {
    let dx = solver.cellSize
    var cells = Set<SIMD2<Int>>()
    for p in particles { cells.insert(SIMD2(Int((p.position.x / dx).rounded(.down)), Int((p.position.y / dx).rounded(.down)))) }
    return Double(cells.count) / (Double(initialParticles) / 4)
  }

  /// Free-surface height (m) at fractions of the tank width: the highest particle within 1.5 cells of each station.
  func surface(at fractions: [Double]) -> [Double] {
    let W = solver.domain.size.x, dx = solver.cellSize
    let ps = particles
    return fractions.map { f in
      let x = f * W
      return (ps.filter { abs($0.position.x - x) < 1.5 * dx }.map(\.position.y).max() ?? 0) + 0.25 * dx
    }
  }
}

/// Mean and standard deviation.
func meanStd(_ xs: [Double]) -> (mean: Double, std: Double) {
  guard !xs.isEmpty else { return (0, 0) }
  let m = xs.reduce(0, +) / Double(xs.count)
  let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
  return (m, v.squareRoot())
}

/// Least-squares slope of y against x.
func slope(_ x: [Double], _ y: [Double]) -> Double {
  let n = Double(x.count)
  let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
  var sxy = 0.0, sxx = 0.0
  for i in x.indices { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
  return sxy / sxx
}
