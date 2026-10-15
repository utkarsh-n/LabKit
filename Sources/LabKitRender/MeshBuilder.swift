import LabKitCore
import LabKitShaderTypes
import Metal
import simd

public struct GPUMesh {
  public let vertices: MTLBuffer
  public let indices: MTLBuffer
  public let count: Int
}

/// Procedural solids built once in unit sizes and placed per frame (GyroMeshes.Builder,
/// GyroMeshes.swift:33-172), with each batch's winding self-checked against its normals.
public final class MeshBuilder {
  public var vertices: [LabMeshVertex] = []
  public var indices: [UInt32] = []
  public init() {}

  public func grid(rows: Int, cols: Int, _ at: (Int, Int) -> (F3, F3)) {
    let base = UInt32(vertices.count)
    for i in 0...rows {
      for j in 0...cols {
        let (p, n) = at(i, j)
        vertices.append(LabMeshVertex(position: F4(p, 1), normal: F4(n, 0)))
      }
    }
    var tris: [UInt32] = []
    let w = UInt32(cols + 1)
    for i in 0..<UInt32(rows) {
      for j in 0..<UInt32(cols) {
        let a = base + i * w + j
        let b = a + w
        tris += [a, b, a + 1, a + 1, b, b + 1]
      }
    }
    orient(&tris)
    indices += tris
  }

  public func cap(radius: Float, z: Float, up: Float, segments: Int) {
    let center = UInt32(vertices.count)
    let n = F3(0, 0, up)
    vertices.append(LabMeshVertex(position: F4(0, 0, z, 1), normal: F4(n, 0)))
    for k in 0...segments {
      let a = Float(k) / Float(segments) * 2 * .pi
      vertices.append(LabMeshVertex(position: F4(radius * cos(a), radius * sin(a), z, 1), normal: F4(n, 0)))
    }
    var tris: [UInt32] = []
    for k in 0..<UInt32(segments) { tris += [center, center + 1 + k, center + 2 + k] }
    orient(&tris)
    indices += tris
  }

  /// Flips the batch if its first proper triangle faces against its vertex normal.
  private func orient(_ tris: inout [UInt32]) {
    for t in stride(from: 0, to: tris.count, by: 3) {
      let a = vertices[Int(tris[t])], b = vertices[Int(tris[t + 1])], c = vertices[Int(tris[t + 2])]
      let pa = F3(a.position.x, a.position.y, a.position.z)
      let face = simd_cross(F3(b.position.x, b.position.y, b.position.z) - pa, F3(c.position.x, c.position.y, c.position.z) - pa)
      guard simd_length(face) > 1e-9 else { continue }
      if simd_dot(face, F3(a.normal.x, a.normal.y, a.normal.z)) < 0 {
        for k in stride(from: 0, to: tris.count, by: 3) { tris.swapAt(k + 1, k + 2) }
      }
      return
    }
  }

  /// A flat rectangle in the z = `z` plane, facing +z (or −z with `facing: -1`).
  public func quad(min lo: SIMD2<Float>, max hi: SIMD2<Float>, z: Float = 0, facing: Float = 1) {
    grid(rows: 1, cols: 1) { i, j in
      (F3(j == 0 ? lo.x : hi.x, i == 0 ? lo.y : hi.y, z), F3(0, 0, facing))
    }
  }

  public func torus(major: Float, minor: Float, z: Float = 0, segments: Int = 72, sides: Int = 18) {
    grid(rows: segments, cols: sides) { i, j in
      let t = Float(i) / Float(segments) * 2 * .pi
      let f = Float(j) / Float(sides) * 2 * .pi
      let n = F3(cos(f) * cos(t), cos(f) * sin(t), sin(f))
      return (F3(major * cos(t), major * sin(t), z) + minor * n, n)
    }
  }

  public func cylinder(radius: Float, z0: Float, z1: Float, segments: Int = 48, caps: Bool = true) {
    grid(rows: 1, cols: segments) { i, j in
      let a = Float(j) / Float(segments) * 2 * .pi
      let n = F3(cos(a), sin(a), 0)
      return (F3(radius * n.x, radius * n.y, i == 0 ? z0 : z1), n)
    }
    if caps {
      cap(radius: radius, z: z1, up: 1, segments: segments)
      cap(radius: radius, z: z0, up: -1, segments: segments)
    }
  }

  public func sphere(center: F3 = .zero, radius: Float, segments: Int = 24) {
    grid(rows: segments / 2, cols: segments) { i, j in
      let th = Float(i) / Float(segments / 2) * .pi
      let ph = Float(j) / Float(segments) * 2 * .pi
      let n = F3(sin(th) * cos(ph), sin(th) * sin(ph), cos(th))
      return (center + radius * n, n)
    }
  }

  /// Surface of revolution about +Z from (radius, z) points bottom to top.
  public func lathe(_ profile: [SIMD2<Float>], segments: Int = 72) {
    grid(rows: profile.count - 1, cols: segments) { i, j in
      let a = Float(j) / Float(segments) * 2 * .pi
      let p = profile[i]
      let prev = profile[max(i - 1, 0)]
      let next = profile[min(i + 1, profile.count - 1)]
      let t = next - prev
      let n2 = SIMD2(t.y, -t.x)
      let n = simd_length(n2) > 1e-6 ? n2 / simd_length(n2) : SIMD2<Float>(1, 0)
      return (F3(p.x * cos(a), p.x * sin(a), p.y), F3(n.x * cos(a), n.x * sin(a), n.y))
    }
  }

  public func annulus(inner: Float, outer: Float, segments: Int = 120) {
    for side: Float in [1, -1] {
      grid(rows: 1, cols: segments) { i, j in
        let a = Float(j) / Float(segments) * 2 * .pi
        let r = i == 0 ? inner : outer
        return (F3(r * cos(a), r * sin(a), 0), F3(0, 0, side))
      }
    }
  }

  /// Catmull–Rom subdivision of a lathe profile.
  public static func smooth(_ p: [SIMD2<Float>], steps: Int = 4) -> [SIMD2<Float>] {
    guard p.count > 2 else { return p }
    var out: [SIMD2<Float>] = []
    for i in 0..<(p.count - 1) {
      let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
      for k in 0..<steps {
        let t = Float(k) / Float(steps)
        let t2 = t * t, t3 = t2 * t
        var q = 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
        q.x = max(q.x, 0)
        out.append(q)
      }
    }
    out.append(p[p.count - 1])
    return out
  }

  public func upload(_ device: MTLDevice) -> GPUMesh? {
    guard
      let v = device.makeBuffer(bytes: vertices, length: MemoryLayout<LabMeshVertex>.stride * vertices.count),
      let i = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count)
    else { return nil }
    return GPUMesh(vertices: v, indices: i, count: indices.count)
  }
}
