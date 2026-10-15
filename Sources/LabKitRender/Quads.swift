import CoreGraphics
import LabKitCore
import LabKitShaderTypes
import Metal
import simd

extension LabQuadInstance {
  /// A quad covering `rect` (scene units, y up) in a linear colour (rgb × intensity, alpha).
  public init(rect: CGRect, color: F4, z: Float = 0, rotation: Float = 0, cornerRadius: Float = 0, app: Float = 0) {
    self.init(
      rect: F4(Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY)), color: color,
      params: F4(z, rotation, cornerRadius, app))
  }
}

/// Instanced flat quads with LabKit's `labQuadVertex` and any fragment function: LabKit's
/// `labQuadFragment` (flat rounded rectangle, premultiplied) or an app fragment that takes
/// `LabQuadOut` (e.g. one that samples `context.targets.behind` for refraction).
public final class QuadRenderer {
  public let pipeline: MTLRenderPipelineState
  private let device: MTLDevice
  /// `setVertexBytes` takes up to 4 KB, i.e. 85 quads; larger batches get a one-off buffer.
  public static let inlineLimit = 4096 / MemoryLayout<LabQuadInstance>.stride

  public init(
    device: MTLDevice, factory: PipelineFactory, fragment: String = "labQuadFragment", fragmentLibrary: MTLLibrary? = nil,
    blend: LabBlend = .premultiplied, format: MTLPixelFormat = LabFormats.scene, label: String? = nil
  ) throws {
    self.device = device
    pipeline = try factory.make(
      vertex: "labQuadVertex", fragment: fragment, fragmentLibrary: fragmentLibrary, format: format, blend: blend,
      depth: true, label: label)
  }

  /// Draws `quads` with this renderer's pipeline. Bind any extra fragment textures/buffers first
  /// (the frame uniforms are bound at vertex buffer 1 here; fragment buffer 0 is bound by the host).
  /// Safe to call several times per frame: the instances are copied at encode time.
  public func draw(
    _ enc: MTLRenderCommandEncoder, quads: [LabQuadInstance], uniforms: inout LabFrameUniforms,
    depth: MTLDepthStencilState? = nil
  ) {
    guard !quads.isEmpty else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setCullMode(.none)
    if let depth { enc.setDepthStencilState(depth) }
    enc.setVertexBytes(&uniforms, length: MemoryLayout<LabFrameUniforms>.stride, index: Int(LabBufferFrame.rawValue))
    let length = quads.count * MemoryLayout<LabQuadInstance>.stride
    if quads.count <= Self.inlineLimit {
      quads.withUnsafeBytes { raw in
        if let base = raw.baseAddress { enc.setVertexBytes(base, length: length, index: Int(LabBufferInstances.rawValue)) }
      }
    } else {
      guard let buffer = quads.withUnsafeBytes({ raw in
        raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: length, options: .storageModeShared) }
      }) else { return }
      enc.setVertexBuffer(buffer, offset: 0, index: Int(LabBufferInstances.rawValue))
    }
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
  }
}
