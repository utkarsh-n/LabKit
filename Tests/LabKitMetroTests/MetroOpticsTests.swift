import Foundation
import Metal
import XCTest

@testable import LabKitMetro

/// The isolated lens (spec §13–§14): bounded refraction (Metro Station `LensRefractionTests`, ported), the chromatic
/// window, the lens state's accessibility rules, the optional radius pulse, the tilt baseline, the pill envelope, and
/// the package shader lookup.
final class MetroOpticsTests: XCTestCase {
  // MARK: Refraction (ported from Metro Station)

  func testModerateTiltIsEnhancedWithoutChangingDirectionOrExceedingUnitMagnitude() {
    let half = MetroLensRefraction.enhancedTilt(x: 0.3, y: 0.4)
    XCTAssertEqual(half.x, 0.48, accuracy: 1e-12)
    XCTAssertEqual(half.y, 0.64, accuracy: 1e-12)
    XCTAssertEqual(hypot(half.x, half.y), 0.8, accuracy: 1e-12)
    let opposite = MetroLensRefraction.enhancedTilt(x: -0.3, y: -0.4)
    XCTAssertEqual(opposite.x, -half.x)
    XCTAssertEqual(opposite.y, -half.y)

    var previousMagnitude = 0.0
    for index in 0...200 {
      let magnitude = Double(index) / 100
      let tilt = MetroLensRefraction.enhancedTilt(x: magnitude * 0.6, y: magnitude * 0.8)
      let enhanced = hypot(tilt.x, tilt.y)
      XCTAssertGreaterThanOrEqual(enhanced, previousMagnitude - 1e-12)
      XCTAssertLessThanOrEqual(enhanced, 1 + 1e-12)
      XCTAssertEqual(tilt.x * 0.8 - tilt.y * 0.6, 0, accuracy: 1e-12)
      previousMagnitude = enhanced
    }
    let largest = Double.greatestFiniteMagnitude
    let hostile = MetroLensRefraction.enhancedTilt(x: largest, y: -largest / 2)
    XCTAssertTrue(hostile.x.isFinite && hostile.y.isFinite)
    XCTAssertEqual(hypot(hostile.x, hostile.y), 1, accuracy: 1e-12)
    XCTAssertEqual(hostile.y / hostile.x, -0.5, accuracy: 1e-12)
    let epsilon = 1e-5
    let below = MetroLensRefraction.enhancedTilt(x: 1 - epsilon, y: 0)
    let above = MetroLensRefraction.enhancedTilt(x: 1 + epsilon, y: 0)
    XCTAssertLessThan(abs(above.x - below.x) / (2 * epsilon), 1e-5)
    let simd = MetroLensRefraction.enhancedTilt(SIMD2(0.3, 0.4))
    XCTAssertEqual(simd.x, half.x)
    XCTAssertEqual(simd.y, half.y)
  }

  func testBroadInteriorWarpReleasesWithContinuousVelocityAndCurvatureAtTheRim() {
    func weight(_ radius: Double) -> Double { MetroLensRefraction.weight(normalizedX: radius, normalizedY: 0) }
    XCTAssertEqual(weight(0), 1)
    XCTAssertEqual(weight(0.5), 0.92, accuracy: 1e-12)
    XCTAssertGreaterThan(weight(0.8), 0.79)
    XCTAssertGreaterThan(weight(0.9), 0.4)
    XCTAssertEqual(weight(1), 0)
    XCTAssertEqual(weight(1.01), 0)
    XCTAssertEqual(weight(0.5), MetroLensRefraction.weight(normalizedX: 0.3, normalizedY: 0.4), accuracy: 1e-12)
    let h = 1e-6
    for join in [MetroLensRefraction.rimStart, 1] {
      let leftVelocity = (weight(join) - weight(join - h)) / h
      let rightVelocity = (weight(join + h) - weight(join)) / h
      let leftCurvature = (weight(join) - 2 * weight(join - h) + weight(join - 2 * h)) / (h * h)
      let rightCurvature = (weight(join + 2 * h) - 2 * weight(join + h) + weight(join)) / (h * h)
      XCTAssertLessThan(abs(leftVelocity - rightVelocity), 1e-4)
      XCTAssertLessThan(abs(leftCurvature - rightCurvature), 0.012)
    }
    XCTAssertLessThan(abs(weight(1 - h)) / h, 1e-5)
    var previous = 1.0
    for index in 0...1000 {
      let value = weight(Double(index) / 1000)
      XCTAssertTrue((0...1).contains(value))
      XCTAssertLessThanOrEqual(value, previous + 1e-12)
      previous = value
    }
  }

  func testSamplingDisplacementIsBoundedInPointsAndStationaryAtTheRim() {
    XCTAssertEqual(MetroLensRefraction.maximumShift(diameter: 322), 8.05, accuracy: 1e-12)
    XCTAssertEqual(MetroLensRefraction.maximumShift(diameter: 500), 9.5)
    let centre = MetroLensRefraction.sampleOffset(normalizedX: 0, normalizedY: 0, tiltX: 0.5, tiltY: 0, diameter: 322)
    XCTAssertEqual(centre.x, 6.44, accuracy: 1e-12)
    XCTAssertEqual(centre.y, 0)
    for diameter in [1.0, 160, 322, 500, Double.greatestFiniteMagnitude] {
      for tilt in [(0.0, 0.0), (0.3, -0.4), (1.0, 0.0), (9.0, -12.0)] {
        for x in -10...10 {
          for y in -10...10 {
            let offset = MetroLensRefraction.sampleOffset(
              normalizedX: Double(x) / 10, normalizedY: Double(y) / 10, tiltX: tilt.0, tiltY: tilt.1, diameter: diameter)
            XCTAssertTrue(offset.x.isFinite && offset.y.isFinite)
            XCTAssertLessThanOrEqual(hypot(offset.x, offset.y), MetroLensRefraction.maximumShift(diameter: diameter) + 1e-12)
            if x * x + y * y >= 100 {
              XCTAssertEqual(offset.x, 0, accuracy: 1e-12)
              XCTAssertEqual(offset.y, 0, accuracy: 1e-12)
            }
          }
        }
      }
    }
  }

  func testStaticModeAndMalformedInputsGiveFiniteZeroDisplacement() {
    let disabled = MetroLensRefraction.sampleOffset(
      normalizedX: 0.5, normalizedY: 0, tiltX: 1, tiltY: 0.5, diameter: 322, enabled: false)
    XCTAssertEqual(disabled.x, 0)
    XCTAssertEqual(disabled.y, 0)
    for invalid in [Double.nan, .infinity, -.infinity] {
      let tilt = MetroLensRefraction.enhancedTilt(x: invalid, y: 0.5)
      XCTAssertEqual(tilt.x, 0)
      XCTAssertEqual(tilt.y, 0)
      XCTAssertEqual(MetroLensRefraction.weight(normalizedX: 0, normalizedY: invalid), 0)
      XCTAssertEqual(MetroLensRefraction.maximumShift(diameter: invalid), 0)
      XCTAssertEqual(MetroLensRefraction.maximumChannelSplit(diameter: invalid), 0)
      XCTAssertEqual(MetroLensRefraction.chromaticWeight(normalizedX: invalid, normalizedY: 0.5), 0)
      let offset = MetroLensRefraction.sampleOffset(normalizedX: invalid, normalizedY: 0, tiltX: 1, tiltY: 0, diameter: 322)
      XCTAssertEqual(offset.x, 0)
      XCTAssertEqual(offset.y, 0)
    }
    for diameter in [0.0, -1, -Double.greatestFiniteMagnitude] {
      XCTAssertEqual(MetroLensRefraction.maximumShift(diameter: diameter), 0)
    }
    XCTAssertEqual(MetroLensRefraction.weight(normalizedX: .greatestFiniteMagnitude, normalizedY: .greatestFiniteMagnitude), 0)
    let smallest = MetroLensRefraction.enhancedTilt(x: .leastNonzeroMagnitude, y: 0)
    XCTAssertTrue(smallest.x.isFinite && smallest.x > 0 && smallest.y == 0)
  }

  // MARK: Chromatic window

  func testChromaticSplitIsConfinedToDiagonalEdgeArcsAndBounded() {
    XCTAssertEqual(MetroLensRefraction.maximumChannelSplit(diameter: 322), 1, accuracy: 1e-15)
    XCTAssertEqual(MetroLensRefraction.maximumChannelSplit(diameter: 500), 1.2)
    XCTAssertEqual(MetroLensRefraction.samplingBound(diameter: 322), 8.55, accuracy: 1e-12)
    let diagonal = 0.82 / 2.0.squareRoot()
    XCTAssertEqual(MetroLensRefraction.chromaticWeight(normalizedX: diagonal, normalizedY: diagonal), 1, accuracy: 1e-12)
    // No colour at the centre, inside the readout region, on the axial arcs or at the rim.
    XCTAssertEqual(MetroLensRefraction.chromaticWeight(normalizedX: 0, normalizedY: 0), 0)
    XCTAssertEqual(MetroLensRefraction.chromaticWeight(normalizedX: 0.3, normalizedY: 0.3), 0)
    XCTAssertEqual(MetroLensRefraction.chromaticWeight(normalizedX: 0.82, normalizedY: 0), 0, accuracy: 1e-15)
    XCTAssertEqual(MetroLensRefraction.chromaticWeight(normalizedX: 0, normalizedY: -0.82), 0, accuracy: 1e-15)
    XCTAssertEqual(
      MetroLensRefraction.chromaticWeight(normalizedX: 1 / 2.0.squareRoot(), normalizedY: 1 / 2.0.squareRoot()), 0,
      accuracy: 1e-12)
    for diameter in [100.0, 322, 600] {
      let bound = 0.5 * MetroLensRefraction.maximumChannelSplit(diameter: diameter)
      for x in -20...20 {
        for y in -20...20 {
          let offset = MetroLensRefraction.chromaticOffset(
            normalizedX: Double(x) / 20, normalizedY: Double(y) / 20, tiltX: 0.9, tiltY: -0.7, diameter: diameter)
          XCTAssertLessThanOrEqual(hypot(offset.x, offset.y), bound + 1e-12)
        }
      }
      // The declared layer-effect bound covers every sample the shader can take.
      XCTAssertEqual(
        MetroLensRefraction.samplingBound(diameter: diameter),
        MetroLensRefraction.maximumShift(diameter: diameter) + bound, accuracy: 1e-12)
    }
    let neutral = MetroLensRefraction.chromaticOffset(
      normalizedX: diagonal, normalizedY: diagonal, tiltX: 0, tiltY: 0, diameter: 322)
    XCTAssertEqual(neutral.x, 0)
    XCTAssertEqual(neutral.y, 0)
  }

  func testRimAngleAndRadiusScale() {
    XCTAssertEqual(MetroLensRefraction.rimAngleDegrees(enhancedTilt: .zero), -90)
    XCTAssertEqual(MetroLensRefraction.rimAngleDegrees(enhancedTilt: SIMD2(1, 0)), -20)
    XCTAssertEqual(MetroLensRefraction.rimAngleDegrees(enhancedTilt: SIMD2(0, -1)), -110)
    XCTAssertEqual(MetroLensRefraction.boundedRadiusScale(1.5), 1.09)
    XCTAssertEqual(MetroLensRefraction.boundedRadiusScale(0.5), 0.92)
    XCTAssertEqual(MetroLensRefraction.boundedRadiusScale(1.03), 1.03)
    XCTAssertEqual(MetroLensRefraction.boundedRadiusScale(.nan), 1)
  }

  // MARK: Lens state (accessibility rules)

  private func lens(
    scale: Double = 1.5, tilt: SIMD2<Double> = SIMD2(0.3, 0.4), motion: Bool = true, reduceMotion: Bool = false,
    reduceTransparency: Bool = false, active: Bool = true
  ) -> MetroLensState {
    MetroLensState(
      diameter: 322, radiusScale: scale, tilt: tilt, motionActive: motion, reduceMotion: reduceMotion,
      reduceTransparency: reduceTransparency, sceneActive: active)
  }

  func testLensStateDefaultsAndBounds() {
    let state = lens()
    XCTAssertTrue(state.opticsEnabled)
    XCTAssertEqual(state.scale, 1.09)
    XCTAssertEqual(state.enhancedTilt.x, 0.48, accuracy: 1e-12)
    XCTAssertEqual(state.enhancedTilt.y, 0.64, accuracy: 1e-12)
    XCTAssertEqual(state.lensOpacity, 0.48)
    XCTAssertEqual(state.radius, 322 * 0.38 * 1.09, accuracy: 1e-9)
    XCTAssertEqual(state.rimAngleDegrees, -90 + 70 * 0.48 + 20 * 0.64, accuracy: 1e-9)
  }

  func testReduceMotionStopsOpticsAndRestsTheRadius() {
    let state = lens(reduceMotion: true)
    XCTAssertFalse(state.opticsEnabled)
    XCTAssertEqual(state.scale, 1)
    XCTAssertEqual(state.enhancedTilt, .zero)
    XCTAssertEqual(state.lensOpacity, 0.48, "opacity is constant")
    XCTAssertEqual(state.rimAngleDegrees, -90)
  }

  func testReduceTransparencyRestoresTheFullMaterialWithoutOptics() {
    let state = lens(reduceTransparency: true)
    XCTAssertFalse(state.opticsEnabled)
    XCTAssertEqual(state.lensOpacity, 1)
    XCTAssertEqual(state.enhancedTilt, .zero)
  }

  func testInactiveSceneOrMotionOffStopsOptics() {
    let inactive = lens(active: false)
    XCTAssertFalse(inactive.opticsEnabled)
    XCTAssertEqual(inactive.scale, 1)
    let still = lens(motion: false)
    XCTAssertFalse(still.opticsEnabled)
    XCTAssertEqual(still.scale, 1.09, "a domain pulse may still breathe the radius")
    XCTAssertEqual(still.enhancedTilt, .zero)
    let malformed = MetroLensState(
      diameter: .nan, radiusScale: .nan, tilt: SIMD2(.nan, 1), motionActive: true, reduceMotion: false,
      reduceTransparency: false, sceneActive: true)
    XCTAssertEqual(malformed.diameter, 1)
    XCTAssertEqual(malformed.scale, 1)
    XCTAssertEqual(malformed.enhancedTilt, .zero)
  }

  // MARK: Lens pulse

  func testLensPulseIsBoundedAndRestsOutsideItsWindow() {
    XCTAssertEqual(MetroLensPulse.radiusScale(age: 0, duration: 0.5), 1)
    XCTAssertEqual(MetroLensPulse.radiusScale(age: -0.1, duration: 0.5), 1)
    XCTAssertEqual(MetroLensPulse.radiusScale(age: 0.5, duration: 0.5), 1)
    XCTAssertEqual(MetroLensPulse.radiusScale(age: 0.1, duration: 0.5, reduceMotion: true), 1)
    XCTAssertEqual(MetroLensPulse.radiusScale(age: .nan, duration: 0.5), 1)
    XCTAssertEqual(MetroLensPulse.radiusScale(age: 0.1, duration: 0), 1)
    let peak = MetroLensPulse.radiusScale(age: MetroLensPulse.peakPhase * 0.5, duration: 0.5)
    XCTAssertEqual(peak, 1.09, accuracy: 1e-9)
    let half = MetroLensPulse.radiusScale(age: MetroLensPulse.peakPhase * 0.5, duration: 0.5, strength: 0.5)
    XCTAssertEqual(half, 1.045, accuracy: 1e-9)
    XCTAssertLessThan(MetroLensPulse.radiusScale(age: MetroLensPulse.compressionPhase * 0.5, duration: 0.5), 1)
    var maximum = 0.0
    for index in 0...2000 {
      let scale = MetroLensPulse.radiusScale(age: Double(index) / 2000 * 0.5, duration: 0.5)
      XCTAssertTrue(Metro.Optics.radiusScaleRange.contains(scale))
      maximum = max(maximum, scale)
    }
    XCTAssertEqual(maximum, 1.09, accuracy: 1e-4)
    // Continuous at both ends.
    XCTAssertEqual(MetroLensPulse.radiusScale(age: 1e-6, duration: 0.5), 1, accuracy: 1e-6)
    XCTAssertEqual(MetroLensPulse.radiusScale(age: 0.5 - 1e-6, duration: 0.5), 1, accuracy: 1e-6)
  }

  // MARK: Tilt baseline

  func testTiltFilterCapturesItsReferenceAndLowPasses() {
    var filter = MetroTiltFilter()
    XCTAssertEqual(filter.update(gravityX: 0.5, gravityZ: 0.5, generation: 0), .zero, "inactive filter ignores samples")
    let generation = filter.start()
    XCTAssertTrue(filter.isActive)
    XCTAssertEqual(filter.update(gravityX: 0.2, gravityZ: -0.7, generation: generation), .zero, "first sample = reference")
    let first = filter.update(gravityX: 0.3, gravityZ: -0.7, generation: generation)
    XCTAssertEqual(first.x, 0.17 * 0.18, accuracy: 1e-12)
    XCTAssertEqual(first.y, 0, accuracy: 1e-12)
    // A held tilt keeps its response (no rolling baseline): it converges on the target and stays.
    for _ in 0..<200 { filter.update(gravityX: 0.3, gravityZ: -0.7, generation: generation) }
    XCTAssertEqual(filter.vector.x, 0.17, accuracy: 1e-9)
    // Bounded.
    for _ in 0..<200 { filter.update(gravityX: 5, gravityZ: -9, generation: generation) }
    XCTAssertEqual(filter.vector.x, 1, accuracy: 1e-9)
    XCTAssertEqual(filter.vector.y, -1, accuracy: 1e-9)
  }

  func testStaleGenerationsAndStopsCannotMoveARestartedStream() {
    var filter = MetroTiltFilter()
    let old = filter.start()
    filter.update(gravityX: 0, gravityZ: 0, generation: old)
    filter.stop()
    XCTAssertEqual(filter.vector, .zero)
    XCTAssertFalse(filter.isActive)
    let current = filter.start()
    XCTAssertNotEqual(old, current)
    filter.update(gravityX: 0, gravityZ: 0, generation: current)
    XCTAssertEqual(filter.update(gravityX: 0.4, gravityZ: 0.4, generation: old), .zero, "stale callback ignored")
    XCTAssertEqual(filter.update(gravityX: .nan, gravityZ: 0.4, generation: current), .zero)
    let moved = filter.update(gravityX: 0.1, gravityZ: 0, generation: current)
    XCTAssertGreaterThan(moved.x, 0)
    filter.rebase()
    XCTAssertEqual(filter.update(gravityX: 0.9, gravityZ: 0.9, generation: current), moved, "the rebase sample is the new reference")
  }

  func testLowPassStepIsRateIndependent() {
    XCTAssertEqual(MetroTiltFilter.alpha(dt: nil), 0.18)
    XCTAssertEqual(MetroTiltFilter.alpha(dt: 1.0 / 30), 0.18)
    XCTAssertEqual(MetroTiltFilter.alpha(dt: 0), 0.18)
    XCTAssertEqual(MetroTiltFilter.alpha(dt: 10), 1)
    let half = MetroTiltFilter.alpha(dt: 1.0 / 60)
    XCTAssertEqual((1 - half) * (1 - half), 0.82, accuracy: 1e-12, "two 60 Hz steps equal one 30 Hz step")
  }

  // MARK: Pulse envelope

  func testPulseEnvelopeAttacksAndDecaysFromTheEventsRealAge() {
    let envelope = MetroPulseEnvelope.standard
    XCTAssertEqual(envelope.duration(), 0.2)
    XCTAssertEqual(envelope.duration(interval: 0.1), 0.08, accuracy: 1e-15)
    XCTAssertEqual(envelope.attack(), 0.02)
    XCTAssertEqual(envelope.attack(interval: 0.05), 0.01, accuracy: 1e-15)
    XCTAssertEqual(envelope.duration(interval: 0), 0)
    XCTAssertEqual(envelope.duration(interval: .nan), 0)
    XCTAssertEqual(envelope.value(elapsed: nil), 0)
    XCTAssertEqual(envelope.value(elapsed: 0), 0)
    XCTAssertEqual(envelope.value(elapsed: -0.01), 0)
    XCTAssertEqual(envelope.value(elapsed: 0.02), 1, accuracy: 1e-12)
    XCTAssertEqual(envelope.value(elapsed: 0.2), 0)
    XCTAssertEqual(envelope.value(elapsed: 0.5), 0)
    XCTAssertEqual(envelope.value(elapsed: .infinity), 0)
    var previous = 0.0
    for index in 1...20 {
      let value = envelope.value(elapsed: Double(index) * 0.001)
      XCTAssertGreaterThanOrEqual(value, previous)
      previous = value
    }
    for index in 21...199 {
      let value = envelope.value(elapsed: Double(index) * 0.001)
      XCTAssertLessThanOrEqual(value, previous + 1e-12)
      XCTAssertTrue((0...1).contains(value))
      previous = value
    }
    let malformed = MetroPulseEnvelope(maximumDuration: .nan, preferredAttack: -1)
    XCTAssertEqual(malformed.value(elapsed: 0.01), 0)
  }

  // MARK: Package shader

  /// The lens shader is compiled into LabKitMetro's own bundle and found through `Bundle.module`, never the host app's
  /// default library (the starter's lookup, which fails from a package). Needs the Metal toolchain (`TOOLCHAINS=metal`)
  /// and a Metal device.
  @MainActor
  func testLensShaderIsInThePackageBundle() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
    let verification = MetroShaders.verify(device: device)
    XCTAssertTrue(verification.libraryLoaded, verification.message)
    XCTAssertTrue(verification.functionFound, verification.message)
    XCTAssertTrue(verification.ok)
    XCTAssertNotEqual(MetroShaders.bundle.bundleURL, Bundle.main.bundleURL, "the package bundle, not the host's")
    XCTAssertEqual(MetroShaders.verify(device: nil).ok, false)
  }
}
