import Foundation
import Metal
import simd
import LabKitCore
import LabKitMPMTypes

/// Verification only (labkit-gpucheck V14, tests): runs the GPU's single-point EVP update (`rheoUpdate` in
/// MPMSolver.metal, float32) on homogeneous material points under prescribed velocity gradients, for parity with
/// LabKitMPMReference's `EVP.update` (Double). Waits for the GPU; never use it in a frame loop.
public final class MPMConstitutiveProbe {
  /// One material point's EVP state (the same fields as LabKitMPMReference's `EVPState`).
  public struct Point: Sendable, Equatable {
    public var b11, b12, b22, J, structure, contact, temperature, plasticRate: Double
    public init(b11: Double = 1, b12: Double = 0, b22: Double = 1, J: Double = 1, structure: Double = 1, contact: Double = 0,
                temperature: Double = 293.15, plasticRate: Double = 0) {
      self.b11 = b11; self.b12 = b12; self.b22 = b22; self.J = J; self.structure = structure; self.contact = contact
      self.temperature = temperature; self.plasticRate = plasticRate
    }
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState

  public init(device: MTLDevice) throws {
    self.device = device
    guard let q = device.makeCommandQueue() else { throw MPMError.metal("command queue") }
    queue = q
    let lib = try MPMPipelines.library(device: device)
    guard let fn = lib.makeFunction(name: "pbConstitutive") else { throw MPMError.metal("pbConstitutive missing") }
    pipeline = try device.makeComputePipelineState(function: fn)
  }

  /// Advances every point `steps` times (each with its own material and velocity gradient C, c12 = ∂vx/∂y = C[1][0])
  /// and returns the Kirchhoff stress (τ11, τ12, τ22) after the last update.
  public func run(materials: [ContinuumMaterial], points: inout [Point], materialIndex: [Int], velocityGradient: [simd_double2x2],
                  dt: Double, steps: Int, fieldMagnitude: Double = 0) -> [SIMD3<Double>] {
    let n = points.count
    precondition(materialIndex.count == n && velocityGradient.count == n && !materials.isEmpty)
    var table = (0..<Int(PB_MAX_MATERIALS)).map { PBMaterial.make(materials[min($0, materials.count - 1)]) }
    var ps = points.map { q -> PBParticle in
      var p = PBParticle()
      p.elastic = SIMD4(Float(q.b11), Float(q.b12), Float(q.b22), Float(q.plasticRate))
      p.liquidDensity = Float(q.J); p.structure = Float(q.structure); p.contact = Float(q.contact)
      p.temperature = Float(q.temperature)
      return p
    }
    var jobs = (0..<n).map { i -> PBConstitutiveJob in
      let c = velocityGradient[i]
      return PBConstitutiveJob(gradient: SIMD4(Float(c[0][0]), Float(c[1][0]), Float(c[0][1]), Float(c[1][1])),
                               dt: Float(dt), steps: UInt32(max(steps, 0)), material: UInt32(materialIndex[i]),
                               fieldMagnitude: Float(fieldMagnitude))
    }
    guard let mb = device.makeBuffer(bytes: &table, length: table.count * MemoryLayout<PBMaterial>.stride, options: .storageModeShared),
          let pb = device.makeBuffer(bytes: &ps, length: max(n, 1) * MemoryLayout<PBParticle>.stride, options: .storageModeShared),
          let jb = device.makeBuffer(bytes: &jobs, length: max(n, 1) * MemoryLayout<PBConstitutiveJob>.stride, options: .storageModeShared),
          let ob = device.makeBuffer(length: max(n, 1) * 16, options: .storageModeShared),
          let cmd = queue.makeCommandBuffer(), let e = cmd.makeComputeCommandEncoder() else { return [] }
    var count = UInt32(n)
    e.setComputePipelineState(pipeline)
    e.setBuffer(mb, offset: 0, index: 0); e.setBuffer(pb, offset: 0, index: 1); e.setBuffer(jb, offset: 0, index: 2)
    e.setBuffer(ob, offset: 0, index: 3); e.setBytes(&count, length: 4, index: 4)
    e.dispatchThreads(MTLSize(width: max(n, 1), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    let rp = pb.contents().bindMemory(to: PBParticle.self, capacity: n)
    let ro = ob.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
    var out: [SIMD3<Double>] = []
    for i in 0..<n {
      let p = rp[i]
      points[i] = Point(b11: Double(p.elastic.x), b12: Double(p.elastic.y), b22: Double(p.elastic.z), J: Double(p.liquidDensity),
                        structure: Double(p.structure), contact: Double(p.contact), temperature: Double(p.temperature),
                        plasticRate: Double(p.elastic.w))
      out.append(SIMD3(Double(ro[i].x), Double(ro[i].y), Double(ro[i].z)))
    }
    return out
  }
}
