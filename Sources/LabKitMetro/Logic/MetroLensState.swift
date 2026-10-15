import Foundation

/// Everything the isolated lens derives from its inputs and the accessibility settings (spec §6, §14, §17), as one pure
/// value so `MetroLensSurface` stays a thin renderer and the rules are tested:
///
/// - custom optics (refraction, chromatic split, rim glide) only while motion is active and neither Reduce Motion nor
///   Reduce Transparency is on and the scene is active; otherwise zero displacement;
/// - the radius scale is clamped to 0.92…1.09 and rests at 1 under Reduce Motion or an inactive scene; the centre never
///   moves;
/// - the native lens opacity is a constant 0.48, or the full material (1) under Reduce Transparency;
/// - the rim arc's centre angle follows the enhanced tilt; its opacity is constant.
nonisolated public struct MetroLensState: Sendable, Equatable {
  public let diameter: Double
  public let opticsEnabled: Bool
  /// The lens radius scale actually drawn.
  public let scale: Double
  /// The enhanced, bounded tilt the shader and rim use (zero when optics are off).
  public let enhancedTilt: SIMD2<Double>
  public let lensOpacity: Double

  public init(
    diameter: Double, radiusScale: Double, tilt: SIMD2<Double>, motionActive: Bool, reduceMotion: Bool,
    reduceTransparency: Bool, sceneActive: Bool
  ) {
    let d = diameter.isFinite ? max(1, diameter) : 1
    self.diameter = d
    opticsEnabled = motionActive && !reduceMotion && !reduceTransparency && sceneActive
    scale = reduceMotion || !sceneActive ? 1 : MetroLensRefraction.boundedRadiusScale(radiusScale)
    enhancedTilt = MetroLensRefraction.enhancedTilt(tilt, enabled: opticsEnabled)
    lensOpacity = reduceTransparency ? Metro.Opacity.lensCompositeReduceTransparency : Metro.Opacity.lensComposite
  }

  /// The lens radius in points: 0.38 D × scale.
  public var radius: Double { diameter * Double(Metro.Gauge.lensRadiusRatio) * scale }

  /// The rim reflection's centre angle, degrees.
  public var rimAngleDegrees: Double { MetroLensRefraction.rimAngleDegrees(enhancedTilt: enhancedTilt) }
}
