import Foundation
import Metal
import LabKitMPMTypes

/// LabKitMPM's Metal library (the package's `default.metallib`, loaded from `Bundle.module`) and compute pipelines.
final class MPMPipelines {
  let library: MTLLibrary
  let g2p2g: MTLComputePipelineState
  let resetBins, bukkitCount, bukkitAllocate, bukkitInsert: MTLComputePipelineState
  let inject, injectCommit, clearParticles, emit, stats, snapshot, gridMass: MTLComputePipelineState
  /// True when the fused pass reduces body impulses with SIMD-group functions; false = threadgroup-atomic fallback.
  let usesSIMDGroupReduction: Bool
  /// What the runtime probe found (nil if it was not run because the path was forced).
  let simdProbePassed: Bool?

  static func library(device: MTLDevice) throws -> MTLLibrary {
    do { return try device.makeDefaultLibrary(bundle: .module) } catch {
      throw MPMError.metal("cannot load LabKitMPM's default.metallib from Bundle.module: \(error)")
    }
  }

  init(device: MTLDevice, queue: MTLCommandQueue, forceSIMD: Bool?) throws {
    let lib = try Self.library(device: device)
    library = lib
    func pipeline(_ name: String, simd: Bool = false) throws -> MTLComputePipelineState {
      let values = MTLFunctionConstantValues()
      var flag = simd
      values.setConstantValue(&flag, type: .bool, index: 0)
      do {
        let fn = try lib.makeFunction(name: name, constantValues: values)
        return try device.makeComputePipelineState(function: fn)
      } catch {
        throw MPMError.metal("pipeline \(name): \(error)")
      }
    }
    try Self.checkLayout(device: device, queue: queue, probe: pipeline("pbLayoutProbe"))

    var probePassed: Bool? = nil
    let useSimd: Bool
    if let forced = forceSIMD {
      useSimd = forced
    } else {
      let ok = (try? Self.probeSIMDGroup(device: device, queue: queue, pipeline: pipeline("pbSimdProbe"))) ?? false
      probePassed = ok
      useSimd = ok
    }
    usesSIMDGroupReduction = useSimd
    simdProbePassed = probePassed
    g2p2g = try pipeline("pbG2P2G", simd: useSimd)
    resetBins = try pipeline("pbResetBins")
    bukkitCount = try pipeline("pbBukkitCount")
    bukkitAllocate = try pipeline("pbBukkitAllocate")
    bukkitInsert = try pipeline("pbBukkitInsert")
    inject = try pipeline("pbInject")
    injectCommit = try pipeline("pbInjectCommit")
    clearParticles = try pipeline("pbClearParticles")
    emit = try pipeline("pbEmit")
    stats = try pipeline("pbStats")
    snapshot = try pipeline("pbSnapshot")
    gridMass = try pipeline("pbGridMass")
    if g2p2g.maxTotalThreadsPerThreadgroup < Int(PB_TILE_NODES) {
      throw MPMError.metal("pbG2P2G allows only \(g2p2g.maxTotalThreadsPerThreadgroup) threads per group; needs \(PB_TILE_NODES)")
    }
  }

  /// Compares MSL `sizeof`/`offsetof` with the Swift (C) view of MPMShared.h. Runs once at init.
  private static func checkLayout(device: MTLDevice, queue: MTLCommandQueue, probe: MTLComputePipelineState) throws {
    guard let out = device.makeBuffer(length: 256, options: .storageModeShared),
          let cmd = queue.makeCommandBuffer(), let e = cmd.makeComputeCommandEncoder() else {
      throw MPMError.metal("cannot create the layout probe")
    }
    e.setComputePipelineState(probe)
    e.setBuffer(out, offset: 0, index: 0)
    e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    let v = out.contents().bindMemory(to: UInt32.self, capacity: 64)
    let msl = (0..<20).map { Int(v[$0]) }
    let swift = [
      MemoryLayout<PBParticle>.stride, MemoryLayout<PBSimConstants>.stride, MemoryLayout<PBShape>.stride,
      MemoryLayout<PBMaterial>.stride, MemoryLayout<PBCounters>.stride, MemoryLayout<PBBukkitDispatch>.stride,
      MemoryLayout<PBStats>.stride, MemoryLayout<PBBukkitThreadData>.stride, Int(PB_TILE_NODES), Int(PB_BUKKIT_SIZE),
      MemoryLayout<PBParticle>.offset(of: \.elastic)!, MemoryLayout<PBParticle>.offset(of: \.liquidDensity)!,
      MemoryLayout<PBParticle>.offset(of: \.tag)!, MemoryLayout<PBSimConstants>.offset(of: \.field)!,
      MemoryLayout<PBSimConstants>.offset(of: \.ambientTemperature)!, MemoryLayout<PBSimConstants>.offset(of: \.injectCount)!,
      MemoryLayout<PBMaterial>.offset(of: \.dst)!, MemoryLayout<PBMaterial>.offset(of: \.restMelt)!,
      MemoryLayout<PBCounters>.offset(of: \.drawArgs)!, MemoryLayout<PBStats>.offset(of: \.gridMass)!,
    ]
    if msl != swift { throw MPMError.layout("MSL \(msl) vs Swift \(swift)") }
  }

  /// Runs the SIMD-group probe (simd_sum, simd_broadcast_first, simd_max, simd_any, simd_is_first) on one 64-thread
  /// group and checks every lane. The iOS simulator reports only the Apple2/Common1 families, so these functions are
  /// tested rather than assumed (mpm-metal.md §7).
  static func probeSIMDGroup(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState) throws -> Bool {
    let n = 64
    let width = pipeline.threadExecutionWidth
    guard width > 0, n % width == 0, pipeline.maxTotalThreadsPerThreadgroup >= n,
          let out = device.makeBuffer(length: n * 16, options: .storageModeShared),
          let cmd = queue.makeCommandBuffer(), let e = cmd.makeComputeCommandEncoder() else { return false }
    memset(out.contents(), 0xFF, n * 16)
    e.setComputePipelineState(pipeline)
    e.setBuffer(out, offset: 0, index: 0)
    e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: n, height: 1, depth: 1))
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    if cmd.status != .completed { return false }
    let v = out.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: n)
    for t in 0..<n {
      let first = (t / width) * width
      let last = first + width - 1
      let sumTids = (first + last) * width / 2
      let r = v[t]
      let anyFive = (5 >= first && 5 <= last) ? 1 : 0
      let isFirst = t == first ? 2 : 0
      let expected = SIMD4<UInt32>(UInt32(width), UInt32(first), UInt32(last), UInt32(anyFive + isFirst + (sumTids << 8)))
      if r != expected { return false }
    }
    return true
  }
}
