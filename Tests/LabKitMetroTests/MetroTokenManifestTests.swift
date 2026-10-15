import Foundation
import LabKitCore
import XCTest

@testable import LabKitMetro

/// Every value in the Metro Station token manifest (edition 1.0, `Resources/design-tokens.json`, a frozen copy of the
/// skill's `assets/design-tokens.json`, SHA-256 82334c29…0d20) equals the typed token exactly, and every numeric leaf of
/// the manifest is covered: a new manifest value fails `testEveryNumericLeafIsCovered` until LabKitMetro adopts it.
final class MetroTokenManifestTests: XCTestCase {
  private static func manifest() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "design-tokens", withExtension: "json"))
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// Every numeric manifest path → the Swift token. Doubles from JSON and from Swift literals are both the nearest
  /// binary64 to the decimal text, so equality is exact, not approximate.
  private static let numericTokens: [String: Double] = [
    "schemaVersion": Double(Metro.manifestSchemaVersion),
    "baseline.appBuild": Double(Metro.sourceBuild),
    "recommendedSpacing.values[0]": Double(Metro.Spacing.recommended[0]),
    "recommendedSpacing.values[1]": Double(Metro.Spacing.recommended[1]),
    "recommendedSpacing.values[2]": Double(Metro.Spacing.recommended[2]),
    "recommendedSpacing.values[3]": Double(Metro.Spacing.recommended[3]),
    "recommendedSpacing.values[4]": Double(Metro.Spacing.recommended[4]),
    "recommendedSpacing.values[5]": Double(Metro.Spacing.recommended[5]),
    "componentSpacing.micro[0]": Double(Metro.Spacing.micro[0]),
    "componentSpacing.micro[1]": Double(Metro.Spacing.micro[1]),
    "componentSpacing.micro[2]": Double(Metro.Spacing.micro[2]),
    "componentSpacing.micro[3]": Double(Metro.Spacing.micro[3]),
    "componentSpacing.micro[4]": Double(Metro.Spacing.micro[4]),
    "componentSpacing.screenInset": Double(Metro.Spacing.screenInset),
    "componentSpacing.headerInset": Double(Metro.Spacing.headerInset),
    "componentSpacing.panelInset": Double(Metro.Spacing.panelInset),
    "componentSpacing.mainStack": Double(Metro.Spacing.mainStack),
    "componentSpacing.landscapeColumns": Double(Metro.Spacing.landscapeColumns),
    "componentSpacing.transportInset": Double(Metro.Spacing.transportInset),
    "componentSpacing.transportBottom": Double(Metro.Spacing.transportBottom),
    "radii.contentPanel": Double(Metro.Radius.contentPanel),
    "radii.plot": Double(Metro.Radius.plot),
    "radii.beatTile": Double(Metro.Radius.beatTile),
    "strokes.panel": Double(Metro.Stroke.panel),
    "strokes.plot": Double(Metro.Stroke.plot),
    "strokes.grid": Double(Metro.Stroke.grid),
    "strokes.pill": Double(Metro.Stroke.pill),
    "strokes.housingRim": Double(Metro.Stroke.housingRim),
    "strokes.glassRimLight": Double(Metro.Stroke.glassRimLight),
    "opacity.panelFill": Metro.Opacity.panelFill,
    "opacity.panelBorder": Metro.Opacity.panelBorder,
    "opacity.grid": Metro.Opacity.grid,
    "opacity.environmentWash": Metro.Opacity.environmentWash,
    "opacity.lensComposite": Metro.Opacity.lensComposite,
    "opacity.lensCompositeReduceTransparency": Metro.Opacity.lensCompositeReduceTransparency,
    "opacity.rimLightPeak": Metro.Opacity.rimLightPeak,
    "opacity.crownGlassTint": Metro.Opacity.crownGlassTint,
    "opacity.pillPrimaryBorder": Metro.Opacity.pillPrimaryBorder,
    "opacity.pillPrimaryBorderIncreasedContrast": Metro.Opacity.pillPrimaryBorderIncreasedContrast,
    "opacity.pillSecondaryBorder": Metro.Opacity.pillSecondaryBorder,
    "typography.appTitle.sizePt": Double(Metro.Typography.appTitle.size),
    "typography.appTitle.minScale": Double(Metro.Typography.appTitle.minimumScale ?? -1),
    "typography.appSubtitle.sizePt": Double(Metro.Typography.appSubtitle.size),
    "typography.appSubtitle.trackingPt": Double(Metro.Typography.appSubtitle.tracking),
    "typography.heroValue.minScale": Double(Metro.Typography.heroValue.minimumScale ?? -1),
    "typography.heroUnit.baseSizePt": Double(Metro.Typography.heroUnit.size),
    "typography.heroUnit.trackingPt": Double(Metro.Typography.heroUnit.tracking),
    "typography.stepperValue.sizePt": Double(Metro.Typography.stepperValue.size),
    "typography.stepperLabel.sizePt": Double(Metro.Typography.stepperLabel.size),
    "typography.stepperLabel.trackingPt": Double(Metro.Typography.stepperLabel.tracking),
    "typography.pillTitle.baseSizePt": Double(Metro.Typography.pillTitle.size),
    "typography.pillAxis.baseSizePt": Double(Metro.Typography.pillAxis.size),
    "typography.reuseCaptionMinimum.baseSizePt": Double(Metro.Typography.captionMinimum.size),
    "layout.portraitContentMax": Double(Metro.Layout.portraitContentMax),
    "layout.clusterMax": Double(Metro.Layout.clusterMax),
    "layout.gaugeMax": Double(Metro.Layout.gaugeMax),
    "layout.pillWidthCompact": Double(Metro.Layout.pillWidthCompact),
    "layout.pillWidthRegular": Double(Metro.Layout.pillWidthRegular),
    "layout.pillWidthBreakpoint": Double(Metro.Layout.pillWidthBreakpoint),
    "layout.clusterGap": Double(Metro.Layout.clusterGap),
    "layout.pillHeightMax": Double(Metro.Layout.pillHeightMax),
    "layout.pillHeightRatio": Double(Metro.Layout.pillHeightRatio),
    "layout.controlRowMax": Double(Metro.Layout.controlRowMax),
    "layout.stepperMinHeight": Double(Metro.Layout.stepperMinHeight),
    "layout.secondaryTargetMin": Double(Metro.Layout.secondaryTargetMin),
    "layout.crownDiameter": Double(Metro.Layout.crownDiameter),
    "layout.transportLabelMinHeight": Double(Metro.Layout.transportLabelMinHeight),
    "layout.bottomContentReserve": Double(Metro.Layout.bottomContentReserve),
    "layout.landscapeInstrumentWidthRatio": Double(Metro.Layout.landscapeInstrumentWidthRatio),
    "gauge.calibrationRadiusRatio": Double(Metro.Gauge.calibrationRadiusRatio),
    "gauge.metalInsetRatio": Double(Metro.Gauge.metalInsetRatio),
    "gauge.lensDiameterRatio": Double(Metro.Gauge.lensDiameterRatio),
    "gauge.readoutYRatio": Double(Metro.Gauge.readoutYRatio),
    "gauge.unitsYRatio": Double(Metro.Gauge.unitsYRatio),
    "gauge.meaningYRatio": Double(Metro.Gauge.meaningYRatio),
    "gauge.meaningYAccessibilityRatio": Double(Metro.Gauge.meaningYAccessibilityRatio),
    "gauge.phaseYRatio": Double(Metro.Gauge.phaseYRatio),
    "gauge.readoutWidthRatio": Double(Metro.Gauge.readoutWidthRatio),
    "gauge.tickerPivotYRatio": Double(Metro.Gauge.tickerPivotYRatio),
    "gauge.tickerLengthRatio": Double(Metro.Gauge.tickerLengthRatio),
    "gauge.tickerAmplitudeDegrees": Metro.Gauge.tickerAmplitudeDegrees,
    "gauge.tickerCycleBeats": Metro.Gauge.tickerCycleBeats,
    "motion.gaugeHz": Metro.Motion.gaugeHz,
    "motion.telemetryHz": Metro.Motion.telemetryHz,
    "motion.reduceMotionHz": Metro.Motion.reduceMotionHz,
    "motion.gravitySampleHz": Metro.Motion.gravitySampleHz,
    "motion.gravityGain": Metro.Motion.gravityGain,
    "motion.gravityLowPassAlpha": Metro.Motion.gravityLowPassAlpha,
    "motion.detentMaxHz": Metro.Motion.detentMaxHz,
    "motion.fineDetentDegrees": Metro.Motion.fineDetentDegrees,
    "motion.coarseDetentDegrees": Metro.Motion.coarseDetentDegrees,
    "motion.reversalHysteresisRatio": Metro.Motion.reversalHysteresisRatio,
    "optics.shiftDiameterRatio": Metro.Optics.shiftDiameterRatio,
    "optics.shiftCapPt": Metro.Optics.shiftCapPt,
    "optics.achromaticRimStart": Metro.Optics.achromaticRimStart,
    "optics.curvature": Metro.Optics.curvature,
    "optics.totalChannelSplitAt322Pt": Metro.Optics.totalChannelSplitAt322Pt,
    "optics.totalChannelSplitCapPt": Metro.Optics.totalChannelSplitCapPt,
    "optics.channelOffsetFractionOfTotal": Metro.Optics.channelOffsetFractionOfTotal,
    "optics.chromaticInnerStart": Metro.Optics.chromaticInnerStart,
    "optics.chromaticPeakRadius": Metro.Optics.chromaticPeakRadius,
    "optics.rimRadiusRatio": Metro.Optics.rimRadiusRatio,
    "optics.rimArcDegrees": Metro.Optics.rimArcDegrees,
    "hapticDetents.fineUp.intensity": Metro.HapticDetents.fineUp.intensity,
    "hapticDetents.fineUp.sharpness": Metro.HapticDetents.fineUp.sharpness,
    "hapticDetents.fineDown.intensity": Metro.HapticDetents.fineDown.intensity,
    "hapticDetents.fineDown.sharpness": Metro.HapticDetents.fineDown.sharpness,
    "hapticDetents.semanticUp.intensity": Metro.HapticDetents.semanticUp.intensity,
    "hapticDetents.semanticUp.sharpness": Metro.HapticDetents.semanticUp.sharpness,
    "hapticDetents.semanticDown.intensity": Metro.HapticDetents.semanticDown.intensity,
    "hapticDetents.semanticDown.sharpness": Metro.HapticDetents.semanticDown.sharpness,
    "portability.starterMinimumIOS": Double(Metro.Portability.starterMinimumIOS),
    "portability.sourceTargetIOS": Double(Metro.Portability.sourceTargetIOS),
  ]

  private static let booleanTokens: [String: Bool] = [
    "optics.rimOpacityConstant": Metro.Optics.rimOpacityConstant,
    "optics.faceHighlightFill": Metro.Optics.faceHighlightFill,
    "typography.heroValue.monospacedDigits": Metro.Typography.heroValue.monospacedDigits,
    "typography.humanMeaning.italic": Metro.Typography.humanMeaning.italic,
    "typography.stepperValue.monospacedDigits": Metro.Typography.stepperValue.monospacedDigits,
    "contract.readoutTransforms": Metro.Contract.readoutTransforms,
    "contract.controlTransformsFromSensor": Metro.Contract.controlTransformsFromSensor,
    "contract.pillOutlineBeatAnimation": Metro.Contract.pillOutlineBeatAnimation,
    "contract.globalBeatOpacityAnimation": Metro.Contract.globalBeatOpacityAnimation,
    "contract.controlTouchOwnsWholeSequence": Metro.Contract.controlTouchOwnsWholeSequence,
    "contract.nativeHoldRepeat": Metro.Contract.nativeHoldRepeat,
    "contract.wholeIntegerValuesRenderWithoutDecimals": Metro.Contract.wholeIntegerValuesRenderWithoutDecimals,
  ]

  /// Typography roles' weight and design words.
  private static let typeRoles: [String: Metro.TypeRole] = [
    "appTitle": Metro.Typography.appTitle,
    "appSubtitle": Metro.Typography.appSubtitle,
    "heroValue": Metro.Typography.heroValue,
    "heroUnit": Metro.Typography.heroUnit,
    "humanMeaning": Metro.Typography.humanMeaning,
    "stepperValue": Metro.Typography.stepperValue,
    "stepperLabel": Metro.Typography.stepperLabel,
    "pillTitle": Metro.Typography.pillTitle,
    "pillAxis": Metro.Typography.pillAxis,
  ]

  // MARK: Walking the manifest

  /// Every leaf of the manifest as "dotted.path[index]" → value. Colours are checked separately (they are RGB triples).
  private static func leaves(_ value: Any, path: String, into out: inout [String: Any]) {
    if let dict = value as? [String: Any] {
      for (key, child) in dict { leaves(child, path: path.isEmpty ? key : "\(path).\(key)", into: &out) }
    } else if let array = value as? [Any] {
      for (index, child) in array.enumerated() { leaves(child, path: "\(path)[\(index)]", into: &out) }
    } else {
      out[path] = value
    }
  }

  private static func isBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  func testColoursMatchTheManifestExactly() throws {
    let colours = try XCTUnwrap(Self.manifest()["colors"] as? [String: Any])
    XCTAssertEqual(colours.count, Metro.Colour.all.count, "colour count")
    XCTAssertEqual(Set(colours.keys), Set(Metro.Colour.all.map(\.name)), "colour names")
    for token in Metro.Colour.all {
      let entry = try XCTUnwrap(colours[token.name] as? [String: Any], token.name)
      let rgb = try XCTUnwrap(entry["rgb"] as? [Double], token.name)
      XCTAssertEqual(rgb.count, 3, token.name)
      XCTAssertEqual(rgb[0], token.colour.r, "\(token.name).r")
      XCTAssertEqual(rgb[1], token.colour.g, "\(token.name).g")
      XCTAssertEqual(rgb[2], token.colour.b, "\(token.name).b")
      XCTAssertEqual(entry["hexApprox"] as? String, token.hexApprox, "\(token.name) hex")
      XCTAssertEqual(entry["role"] as? String, token.role, "\(token.name) role")
      XCTAssertEqual(entry["colorSpace"] as? String, "sRGB", "\(token.name) colour space")
      XCTAssertEqual(Metro.Colour.named(token.name), token.colour)
    }
  }

  /// The manifest's own claim: each hex is the nearest 8-bit sRGB value of its RGB doubles (LabColor.hex rounds).
  func testHexApproximationsAreNearestEightBit() {
    for token in Metro.Colour.all {
      XCTAssertEqual(token.colour.hex, token.hexApprox, token.name)
    }
  }

  func testNumericTokensMatchTheManifestExactly() throws {
    var leaves: [String: Any] = [:]
    Self.leaves(try Self.manifest(), path: "", into: &leaves)
    for (path, expected) in Self.numericTokens {
      let raw = try XCTUnwrap(leaves[path], "manifest has no \(path)")
      XCTAssertFalse(Self.isBoolean(raw), path)
      let value = try XCTUnwrap((raw as? NSNumber)?.doubleValue, path)
      XCTAssertEqual(value, expected, path)
    }
    for (path, expected) in Self.booleanTokens {
      let raw = try XCTUnwrap(leaves[path], "manifest has no \(path)")
      XCTAssertTrue(Self.isBoolean(raw), path)
      XCTAssertEqual((raw as? NSNumber)?.boolValue, expected, path)
    }
  }

  func testEveryNumericLeafIsCovered() throws {
    var leaves: [String: Any] = [:]
    Self.leaves(try Self.manifest(), path: "", into: &leaves)
    for (path, value) in leaves where !path.hasPrefix("colors.") {
      if Self.isBoolean(value) {
        XCTAssertNotNil(Self.booleanTokens[path], "manifest boolean \(path) has no Metro token")
      } else if value is NSNumber {
        XCTAssertNotNil(Self.numericTokens[path], "manifest number \(path) has no Metro token")
      }
    }
  }

  func testTypographyWeightsAndDesigns() throws {
    let typography = try XCTUnwrap(Self.manifest()["typography"] as? [String: Any])
    for (name, role) in Self.typeRoles {
      let entry = try XCTUnwrap(typography[name] as? [String: Any], name)
      XCTAssertEqual(entry["weight"] as? String, role.weight.rawValue, "\(name).weight")
      XCTAssertEqual(entry["design"] as? String, role.design.rawValue, "\(name).design")
      if let scaled = entry["scaledRelativeTo"] as? String {
        XCTAssertEqual(scaled, role.relativeTo?.rawValue, "\(name).scaledRelativeTo")
      }
      if let textStyle = entry["textStyle"] as? String {
        XCTAssertEqual(textStyle, role.relativeTo?.rawValue, "\(name).textStyle")
      }
      if let mono = entry["monospacedDigits"] as? Bool { XCTAssertEqual(mono, role.monospacedDigits, "\(name).digits") }
      if let italic = entry["italic"] as? Bool { XCTAssertEqual(italic, role.italic, "\(name).italic") }
    }
    XCTAssertEqual(typography["heroValue"].flatMap { ($0 as? [String: Any])?["size"] as? String }, "0.23 * gaugeDiameterPt")
    XCTAssertEqual(Metro.Typography.heroValueRatio, 0.23)
  }

  func testEditionAndRadiiWords() throws {
    let manifest = try Self.manifest()
    XCTAssertEqual(manifest["edition"] as? String, Metro.edition)
    let radii = try XCTUnwrap(manifest["radii"] as? [String: Any])
    XCTAssertEqual(radii["pill"] as? String, "capsule")
    let optics = try XCTUnwrap(manifest["optics"] as? [String: Any])
    XCTAssertEqual(optics["rimAngleDegrees"] as? String, "-90 + 70*enhancedTilt.x + 20*enhancedTilt.y")
    XCTAssertEqual(Metro.Optics.rimAngleBaseDegrees, -90)
    XCTAssertEqual(Metro.Optics.rimAngleTiltXDegrees, 70)
    XCTAssertEqual(Metro.Optics.rimAngleTiltYDegrees, 20)
    let motion = try XCTUnwrap(manifest["motion"] as? [String: Any])
    XCTAssertEqual(motion["enhance"] as? String, "2g/(1+|g|^2) after radial unit-disk clamp")
  }
}
