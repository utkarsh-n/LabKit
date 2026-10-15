import CoreGraphics
import Foundation
import Metal

#if canImport(SwiftUI)
  import SwiftUI
#endif

/// LabKitMetro's compiled shaders and the **explicit** library lookup that package use needs.
///
/// The Metro starter calls `ShaderLibrary.instrumentLensOptics`, which resolves in the *app's* default library; from a
/// Swift package that lookup finds nothing (the skill warns about exactly this). Here `MetroLensOptics.metal` is a
/// processed resource of the LabKitMetro target, so SwiftPM and Xcode compile it into `default.metallib` inside the
/// target's own resource bundle, and every lookup goes through `ShaderLibrary.bundle(MetroShaders.bundle)`.
/// `verify()` proves the bundle, library and function exist (LabKitMetroTests on the Mac; the gallery on the simulator
/// and device, in Debug and Release).
public enum MetroShaders {
  /// The stitchable lens function's name in the package library.
  public static let lensOpticsFunction = "metroLensOptics"

  /// LabKitMetro's resource bundle, which holds the compiled `default.metallib`.
  public static var bundle: Bundle { Bundle.module }

  /// The outcome of `verify()`.
  public struct Verification: Sendable, Equatable {
    public let bundlePath: String
    public let libraryLoaded: Bool
    public let functionFound: Bool
    public let message: String
    public var ok: Bool { libraryLoaded && functionFound }
  }

  /// Loads the package's default library with Metal and looks for `metroLensOptics`.
  public static func verify(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) -> Verification {
    let path = bundle.bundlePath
    guard let device else {
      return Verification(bundlePath: path, libraryLoaded: false, functionFound: false, message: "No Metal device")
    }
    do {
      let library = try device.makeDefaultLibrary(bundle: bundle)
      let found = library.functionNames.contains(lensOpticsFunction)
      return Verification(
        bundlePath: path, libraryLoaded: true, functionFound: found,
        message: found
          ? "\(lensOpticsFunction) found in \(bundle.bundleURL.lastPathComponent)"
          : "\(lensOpticsFunction) missing; library has \(library.functionNames.sorted())")
    } catch {
      return Verification(
        bundlePath: path, libraryLoaded: false, functionFound: false,
        message: "No default.metallib in \(bundle.bundleURL.lastPathComponent): \(error.localizedDescription)")
    }
  }

  #if canImport(SwiftUI)
    /// The package's shader library (never the app's default library).
    public static var library: ShaderLibrary { .bundle(bundle) }

    /// The lens optics shader for a primary object of `diameter` points whose lens currently has `radius` points,
    /// with an already enhanced tilt (`MetroLensRefraction.enhancedTilt`). Apply it with
    /// `.layerEffect(_, maxSampleOffset: MetroLensRefraction.samplingBound(diameter:))` to decorative drawing only.
    public static func lensOptics(diameter: CGFloat, radius: CGFloat, enhancedTilt: SIMD2<Double>) -> Shader {
      let d = Double(diameter)
      let function = ShaderFunction(library: library, name: lensOpticsFunction)
      return Shader(
        function: function,
        arguments: [
          .float2(Float(diameter / 2), Float(diameter / 2)),
          .float(Float(radius)),
          .float2(Float(enhancedTilt.x), Float(enhancedTilt.y)),
          .float(Float(MetroLensRefraction.maximumShift(diameter: d))),
          .float(Float(MetroLensRefraction.rimStart)),
          .float(Float(MetroLensRefraction.curvature)),
          .float(Float(MetroLensRefraction.maximumChannelSplit(diameter: d))),
          .float(Float(MetroLensRefraction.chromaticInnerStart)),
          .float(Float(MetroLensRefraction.chromaticPeakRadius)),
        ])
    }
  #endif
}
