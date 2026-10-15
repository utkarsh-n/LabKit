import Foundation

/// The bounded optics of Metro's isolated lens (spec §14; Metro Station `LensRefraction`, same maths): an achromatic
/// sampling shift that feathers to zero at the rim, and a subtle red/blue split confined to diagonal edge arcs. A visual
/// cue for decorative ink under the native clear glass, not a ray-traced or calibrated optical model. The Metal shader
/// `metroLensOptics` (Shaders/MetroLensOptics.metal) evaluates the same functions per pixel.
nonisolated public enum MetroLensRefraction {
  /// The outer 18 % of the lens radius smoothly releases the displacement.
  public static let rimStart = Metro.Optics.achromaticRimStart
  public static let curvature = Metro.Optics.curvature
  /// Chromatic detail begins outside the central readout region and peaks in diagonal arcs before releasing at the rim.
  public static let chromaticInnerStart = Metro.Optics.chromaticInnerStart
  public static let chromaticPeakRadius = Metro.Optics.chromaticPeakRadius

  /// Radially clamps a tilt vector to the unit disk, keeping its direction, then enhances moderate tilt with
  /// e = 2g / (1 + |g|²); the magnitude stays at most one. Disabled or non-finite input gives zero (Reduce Motion, a
  /// static presentation, motion off).
  public static func enhancedTilt(x: Double, y: Double, enabled: Bool = true) -> (x: Double, y: Double) {
    guard enabled, x.isFinite, y.isFinite else { return (0, 0) }
    let largest = max(abs(x), abs(y))
    guard largest > 0 else { return (0, 0) }
    // Scale before finding the magnitude so even hostile finite vectors cannot overflow.
    let scaledX = x / largest
    let scaledY = y / largest
    let scaledMagnitude = hypot(scaledX, scaledY)
    let boundedX: Double
    let boundedY: Double
    if largest > 1 / scaledMagnitude {
      boundedX = scaledX / scaledMagnitude
      boundedY = scaledY / scaledMagnitude
    } else {
      boundedX = x
      boundedY = y
    }
    let gain = 2 / (1 + boundedX * boundedX + boundedY * boundedY)
    return (boundedX * gain, boundedY * gain)
  }

  /// `enhancedTilt` as a SIMD vector.
  public static func enhancedTilt(_ tilt: SIMD2<Double>, enabled: Bool = true) -> SIMD2<Double> {
    let e = enhancedTilt(x: tilt.x, y: tilt.y, enabled: enabled)
    return SIMD2(e.x, e.y)
  }

  /// Maximum sampling shift in points for a primary object of `diameter` points: min(9.5, 0.025 D). 8.05 pt at 322 pt.
  public static func maximumShift(diameter: Double) -> Double {
    guard diameter.isFinite, diameter > 0 else { return 0 }
    return min(Metro.Optics.shiftCapPt, Metro.Optics.shiftDiameterRatio * diameter)
  }

  /// Achromatic weight at lens-local coordinates (relative to the centre, divided by the radius): the bow
  /// 1 − 0.32 r² inside, times a quintic feather from r = 0.82 to the rim with continuous first and second derivatives.
  /// Zero at and outside the rim and for malformed input.
  public static func weight(normalizedX: Double, normalizedY: Double) -> Double {
    guard normalizedX.isFinite, normalizedY.isFinite else { return 0 }
    let radius = hypot(normalizedX, normalizedY)
    guard radius < 1 else { return 0 }
    let bow = 1 - curvature * radius * radius
    guard radius > rimStart else { return bow }
    let progress = (radius - rimStart) / (1 - rimStart)
    let remaining = 1 - progress
    // Factored 1 − smootherstep keeps small values stable near the rim.
    let feather = remaining * remaining * remaining * (1 + 3 * progress + 6 * progress * progress)
    return bow * feather
  }

  /// The displacement in points at a lens-local position. A sampling shader subtracts it, so detail appears to move
  /// with positive tilt; the lens frame and everything over it stay put.
  public static func sampleOffset(
    normalizedX: Double, normalizedY: Double, tiltX: Double, tiltY: Double, diameter: Double, enabled: Bool = true
  ) -> (x: Double, y: Double) {
    let tilt = enhancedTilt(x: tiltX, y: tiltY, enabled: enabled)
    let amount = maximumShift(diameter: diameter) * weight(normalizedX: normalizedX, normalizedY: normalizedY)
    return (tilt.x * amount, tilt.y * amount)
  }

  /// Total red-to-blue separation in points before tilt and edge weighting: min(1.2, D / 322); 1 pt at 322 pt.
  public static func maximumChannelSplit(diameter: Double) -> Double {
    guard diameter.isFinite, diameter > 0 else { return 0 }
    return min(Metro.Optics.totalChannelSplitCapPt, diameter / Metro.Optics.referenceDiameter)
  }

  /// The diagonal chromatic window: a quintic rise from r = 0.52 to 0.82, a quintic fall to the rim, times
  /// sin²(2θ) = (2xy / r²)², so the centre, the axial arcs and the rim have no colour separation.
  public static func chromaticWeight(normalizedX: Double, normalizedY: Double) -> Double {
    guard normalizedX.isFinite, normalizedY.isFinite else { return 0 }
    let radius = hypot(normalizedX, normalizedY)
    guard radius > chromaticInnerStart, radius < 1 else { return 0 }
    let radial: Double
    if radius < chromaticPeakRadius {
      let p = (radius - chromaticInnerStart) / (chromaticPeakRadius - chromaticInnerStart)
      radial = p * p * p * (10 + p * (-15 + 6 * p))
    } else {
      let p = (radius - chromaticPeakRadius) / (1 - chromaticPeakRadius)
      let remaining = 1 - p
      radial = remaining * remaining * remaining * (1 + 3 * p + 6 * p * p)
    }
    let diagonal = 2 * (normalizedX / radius) * (normalizedY / radius)
    return min(1, max(0, radial * diagonal * diagonal))
  }

  /// One channel's offset from the achromatic sample, in points: red samples at base + offset, green at base, blue at
  /// base − offset, so the TOTAL red-to-blue split is bounded by `maximumChannelSplit`. Zero at neutral tilt.
  public static func chromaticOffset(
    normalizedX: Double, normalizedY: Double, tiltX: Double, tiltY: Double, diameter: Double, enabled: Bool = true
  ) -> (x: Double, y: Double) {
    let tilt = enhancedTilt(x: tiltX, y: tiltY, enabled: enabled)
    let amount =
      Metro.Optics.channelOffsetFractionOfTotal * maximumChannelSplit(diameter: diameter)
      * chromaticWeight(normalizedX: normalizedX, normalizedY: normalizedY)
    return (tilt.x * amount, tilt.y * amount)
  }

  /// The per-axis `maxSampleOffset` a `layerEffect` must declare: maximumShift + half the total split (8.55 pt at 322).
  public static func samplingBound(diameter: Double) -> Double {
    maximumShift(diameter: diameter) + Metro.Optics.channelOffsetFractionOfTotal * maximumChannelSplit(diameter: diameter)
  }

  /// The faint rim reflection's centre angle in degrees: −90° + 70° eₓ + 20° e_y for the enhanced tilt e.
  public static func rimAngleDegrees(enhancedTilt e: SIMD2<Double>) -> Double {
    Metro.Optics.rimAngleBaseDegrees + Metro.Optics.rimAngleTiltXDegrees * e.x + Metro.Optics.rimAngleTiltYDegrees * e.y
  }

  /// A host-supplied lens radius scale clamped to 0.92…1.09; 1 when not finite.
  public static func boundedRadiusScale(_ scale: Double) -> Double {
    guard scale.isFinite else { return 1 }
    return min(Metro.Optics.radiusScaleRange.upperBound, max(Metro.Optics.radiusScaleRange.lowerBound, scale))
  }
}
