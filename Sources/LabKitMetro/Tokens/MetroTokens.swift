import CoreGraphics
import LabKitCore

// Metro Station design tokens, edition 1.0 (Metro Station build 14, 12 October 2026): every value of the skill's
// `assets/design-tokens.json`, typed, behind one namespace. RGB doubles are canonical (the manifest's hex strings are
// nearest-8-bit approximations); points describe layout, not millimetres. `LabKitMetroTests` loads a frozen copy of the
// manifest and checks that every number and colour here equals it exactly, and that nothing in it is missing here.
//
// `nonisolated`: LabKitMetro defaults to the main actor (SE-0466) and these are plain values that renderers, shaders and
// tests read from anywhere. SwiftUI adapters (`MetroPalette`, `MetroFont`) live in Components/MetroTheme.swift.

/// The Metro Station design system's tokens (spec §2–§15). Apps adapt the instruments to their own domain; these values
/// are the shared material and interaction vocabulary.
nonisolated public enum Metro {
  /// Edition of the token manifest these values reproduce.
  public static let edition = "1.0"
  /// Metro Station app build the edition was extracted from.
  public static let sourceBuild = 14
  /// The manifest's `schemaVersion`.
  public static let manifestSchemaVersion = 1

  // MARK: Colour

  /// One manifest colour: its manifest name ("surface.canvas"), canonical sRGB doubles and role.
  public struct NamedColour: Sendable, Hashable {
    public let name: String
    public let colour: LabColor
    public let hexApprox: String
    public let role: String
  }

  /// `colors` (spec §3). Cyan = continuous signal and active control, amber = events and emphasis, violet/magenta = a
  /// second, independent signal family. Pair colour with position, text or shape.
  public enum Colour {
    // Surfaces and text
    /// `surface.canvas` #060B0F: the full-screen environment.
    public static let canvas = LabColor(0.025, 0.042, 0.058)
    /// `surface.content` #0B1216: content panels.
    public static let content = LabColor(0.045, 0.07, 0.087)
    /// `surface.gaugeHousing` #070A0E: the opaque primary-object body.
    public static let gaugeHousing = LabColor(0.027, 0.041, 0.055)
    /// `surface.metalLight` #0E1317: upper illuminated metal.
    public static let metalLight = LabColor(0.055, 0.073, 0.09)
    /// `surface.metalDark` #05080B: recessed metal depth.
    public static let metalDark = LabColor(0.021, 0.032, 0.042)
    /// `surface.pillLight` #0E1218: leading stop of a pill enclosure.
    public static let pillLight = LabColor(0.055, 0.069, 0.095)
    /// `surface.pillDark` #040609: trailing stop of a pill enclosure.
    public static let pillDark = LabColor(0.014, 0.022, 0.037)
    /// `surface.plot` #06090C: a large plot inset.
    public static let plot = LabColor(0.022, 0.036, 0.047)
    /// `text.display` #E8F2F7: primary numeric ink.
    public static let displayInk = LabColor(0.91, 0.95, 0.97)
    /// `text.secondary` #99B0BA: labels, supporting values and context.
    public static let secondaryInk = LabColor(0.6, 0.69, 0.73)

    // Accents
    /// `accent.actionCyan` #57EDF5: general actions, selection, the main Stepper value.
    public static let actionCyan = LabColor(0.34, 0.93, 0.96)
    /// `accent.actionAmber` #FFBD5E: running primary action and emphasised events.
    public static let actionAmber = LabColor(1, 0.74, 0.37)
    /// `accent.instrumentCyan` #52E8F5: dial, crown and large waveform ink.
    public static let instrumentCyan = LabColor(0.32, 0.91, 0.96)
    /// `accent.instrumentAmber` #FFB84F: dial index, crown and large carrier ink.
    public static let instrumentAmber = LabColor(1, 0.72, 0.31)

    // Signal families
    /// `signal.wavePrimary` #4FDBFF: compact waveform trace.
    public static let wavePrimary = LabColor(0.31, 0.86, 1)
    /// `signal.waveSecondary` #3666FF: waveform depth.
    public static let waveSecondary = LabColor(0.21, 0.4, 1)
    /// `signal.spectrumPrimary` #C291FF: compact spectrum trace.
    public static let spectrumPrimary = LabColor(0.76, 0.57, 1)
    /// `signal.spectrumSecondary` #F55CD6: spectrum depth.
    public static let spectrumSecondary = LabColor(0.96, 0.36, 0.84)
    /// `signal.carrier` #FFBA57: compact carrier marker.
    public static let carrier = LabColor(1, 0.73, 0.34)

    // Crown metal
    /// `metal.crownBase` #1F262B.
    public static let crownBase = LabColor(0.12, 0.15, 0.17)
    /// `metal.crownRimLight` #7D919C.
    public static let crownRimLight = LabColor(0.49, 0.57, 0.61)
    /// `metal.crownRimDark` #1A2126.
    public static let crownRimDark = LabColor(0.1, 0.13, 0.15)
    /// `metal.crownRimMid` #52636E.
    public static let crownRimMid = LabColor(0.32, 0.39, 0.43)
    /// `metal.crownFaceLight` #45545E.
    public static let crownFaceLight = LabColor(0.27, 0.33, 0.37)
    /// `metal.crownFaceDark` #141C21.
    public static let crownFaceDark = LabColor(0.08, 0.11, 0.13)

    /// Every manifest colour in manifest order, keyed by its manifest name.
    public static let all: [NamedColour] = [
      NamedColour(name: "surface.canvas", colour: canvas, hexApprox: "#060B0F", role: "App environment"),
      NamedColour(name: "surface.content", colour: content, hexApprox: "#0B1216", role: "Content panel"),
      NamedColour(name: "surface.gaugeHousing", colour: gaugeHousing, hexApprox: "#070A0E", role: "Opaque gauge housing"),
      NamedColour(name: "surface.metalLight", colour: metalLight, hexApprox: "#0E1317", role: "Upper dial metal"),
      NamedColour(name: "surface.metalDark", colour: metalDark, hexApprox: "#05080B", role: "Lower dial metal"),
      NamedColour(name: "surface.pillLight", colour: pillLight, hexApprox: "#0E1218", role: "Leading enclosure gradient stop"),
      NamedColour(name: "surface.pillDark", colour: pillDark, hexApprox: "#040609", role: "Trailing enclosure gradient stop"),
      NamedColour(name: "surface.plot", colour: plot, hexApprox: "#06090C", role: "Large plot inset"),
      NamedColour(name: "accent.actionCyan", colour: actionCyan, hexApprox: "#57EDF5", role: "General actions and selection"),
      NamedColour(name: "accent.actionAmber", colour: actionAmber, hexApprox: "#FFBD5E", role: "Running primary action and emphasis"),
      NamedColour(name: "accent.instrumentCyan", colour: instrumentCyan, hexApprox: "#52E8F5", role: "Dial, crown and large waveform ink"),
      NamedColour(name: "accent.instrumentAmber", colour: instrumentAmber, hexApprox: "#FFB84F", role: "Dial, crown and large carrier ink"),
      NamedColour(name: "text.display", colour: displayInk, hexApprox: "#E8F2F7", role: "Primary numeric ink"),
      NamedColour(name: "text.secondary", colour: secondaryInk, hexApprox: "#99B0BA", role: "Secondary engineering text"),
      NamedColour(name: "signal.wavePrimary", colour: wavePrimary, hexApprox: "#4FDBFF", role: "Compact waveform ink"),
      NamedColour(name: "signal.waveSecondary", colour: waveSecondary, hexApprox: "#3666FF", role: "Compact waveform depth"),
      NamedColour(name: "signal.spectrumPrimary", colour: spectrumPrimary, hexApprox: "#C291FF", role: "Compact spectrum ink"),
      NamedColour(name: "signal.spectrumSecondary", colour: spectrumSecondary, hexApprox: "#F55CD6", role: "Compact spectrum depth"),
      NamedColour(name: "signal.carrier", colour: carrier, hexApprox: "#FFBA57", role: "Compact carrier marker"),
      NamedColour(name: "metal.crownBase", colour: crownBase, hexApprox: "#1F262B", role: "Crown metal base"),
      NamedColour(name: "metal.crownRimLight", colour: crownRimLight, hexApprox: "#7D919C", role: "Upper crown rim"),
      NamedColour(name: "metal.crownRimDark", colour: crownRimDark, hexApprox: "#1A2126", role: "Lower crown rim"),
      NamedColour(name: "metal.crownRimMid", colour: crownRimMid, hexApprox: "#52636E", role: "Crown rim midpoint"),
      NamedColour(name: "metal.crownFaceLight", colour: crownFaceLight, hexApprox: "#45545E", role: "Crown face upper"),
      NamedColour(name: "metal.crownFaceDark", colour: crownFaceDark, hexApprox: "#141C21", role: "Crown face lower"),
    ]

    /// The colour with this manifest name ("accent.actionCyan"), or nil.
    public static func named(_ name: String) -> LabColor? { all.first { $0.name == name }?.colour }
  }

  // MARK: Spacing, radii, strokes, opacity

  /// `recommendedSpacing` (the 4-point family for new layout work) and `componentSpacing` (build 14), pt.
  public enum Spacing {
    /// The recommended family: 4, 8, 12, 16, 24, 32 (spec §5).
    public static let recommended: [CGFloat] = [4, 8, 12, 16, 24, 32]
    /// In-component literals of build 14. Keep them inside their component recipes, not as global tokens.
    public static let micro: [CGFloat] = [3, 5, 6, 7, 10]
    public static let screenInset: CGFloat = 12
    public static let headerInset: CGFloat = 24
    public static let panelInset: CGFloat = 16
    public static let mainStack: CGFloat = 12
    public static let landscapeColumns: CGFloat = 24
    public static let transportInset: CGFloat = 22
    public static let transportBottom: CGFloat = 12
    // Spec §5 values the manifest does not list.
    /// Subsidiary rows add this to the screen inset.
    public static let subsidiaryInset: CGFloat = 10
    public static let headerTop: CGFloat = 10
    public static let headerBottom: CGFloat = 12
    public static let transportTop: CGFloat = 10
  }

  /// `radii`, pt. Pills are capsules; controls are circles or capsules.
  public enum Radius {
    public static let contentPanel: CGFloat = 22
    public static let plot: CGFloat = 10
    public static let beatTile: CGFloat = 8
  }

  /// `strokes`, pt.
  public enum Stroke {
    public static let panel: CGFloat = 1
    public static let plot: CGFloat = 0.6
    public static let grid: CGFloat = 0.5
    public static let pill: CGFloat = 0.8
    public static let housingRim: CGFloat = 1.4
    public static let glassRimLight: CGFloat = 0.9
  }

  /// `opacity`, plus the white-ink opacities spec §3 and §6 name.
  public enum Opacity {
    public static let panelFill = 0.85
    public static let panelBorder = 0.09
    public static let grid = 0.025
    public static let environmentWash = 0.085
    /// The isolated lens's constant composite opacity (contract 2).
    public static let lensComposite = 0.48
    /// Reduce Transparency restores the full native lens material.
    public static let lensCompositeReduceTransparency = 1.0
    public static let rimLightPeak = 0.085
    public static let crownGlassTint = 0.08
    public static let pillPrimaryBorder = 0.36
    public static let pillPrimaryBorderIncreasedContrast = 0.7
    public static let pillSecondaryBorder = 0.38
    // Spec values the manifest does not list.
    /// The starter's adoption improvement: a stronger panel border under Increased Contrast.
    public static let panelBorderIncreasedContrast = 0.20
    /// Plot inset border, white (spec §6).
    public static let plotBorder = 0.075
    /// Dial metadata ink (units, phase), white (spec §3).
    public static let dialMetadata = 0.68
    /// Supporting axes and captions, white (spec §3: 0.74–0.75).
    public static let supportingInk = 0.74
    /// The pill enclosure's middle border stop, white (spec §11).
    public static let pillMiddleBorder = 0.10
    /// Telemetry dividers, white (spec §12).
    public static let divider = 0.10
    /// Stepper capsule border, action cyan (spec §9).
    public static let stepperBorder = 0.14
  }

  // MARK: Typography

  /// A system font weight named as the manifest names it.
  public enum Weight: String, Sendable, CaseIterable { case regular, light, medium, semibold }
  /// A system font design named as the manifest names it.
  public enum Design: String, Sendable, CaseIterable { case `default`, rounded, monospaced, serif }
  /// A Dynamic Type style a `@ScaledMetric` size is relative to.
  public enum TextStyle: String, Sendable, CaseIterable {
    case largeTitle, title, title3, body, callout, subheadline, caption, caption2
  }

  /// One type role. `size` is the base point size; `relativeTo` (when set) scales it with Dynamic Type.
  public struct TypeRole: Sendable, Hashable {
    public let size: CGFloat
    public let weight: Weight
    public let design: Design
    public let tracking: CGFloat
    public let relativeTo: TextStyle?
    public let minimumScale: CGFloat?
    public let monospacedDigits: Bool
    public let italic: Bool

    public init(
      size: CGFloat, weight: Weight, design: Design, tracking: CGFloat = 0, relativeTo: TextStyle? = nil,
      minimumScale: CGFloat? = nil, monospacedDigits: Bool = false, italic: Bool = false
    ) {
      self.size = size
      self.weight = weight
      self.design = design
      self.tracking = tracking
      self.relativeTo = relativeTo
      self.minimumScale = minimumScale
      self.monospacedDigits = monospacedDigits
      self.italic = italic
    }
  }

  /// `typography` (spec §4). Three designs with distinct jobs: rounded numerals for the live value, monospaced labels for
  /// units and engineering context, an occasional serif italic for human meaning.
  public enum Typography {
    /// 27 pt semibold rounded, one line, minimum scale 0.75.
    public static let appTitle = TypeRole(size: 27, weight: .semibold, design: .rounded, minimumScale: 0.75)
    /// 9 pt medium mono, tracking 2.6 (build 14). Prefer `appSubtitleScalable` when it carries content.
    public static let appSubtitle = TypeRole(size: 9, weight: .medium, design: .monospaced, tracking: 2.6)
    /// The spec's recommendation: a scalable 11 pt subtitle.
    public static let appSubtitleScalable = TypeRole(
      size: 11, weight: .medium, design: .monospaced, tracking: 2.6, relativeTo: .caption2)
    /// The hero numeral is `heroValueRatio` × the primary object's diameter.
    public static let heroValueRatio: CGFloat = 0.23
    public static let heroValue = TypeRole(
      size: 0, weight: .light, design: .rounded, minimumScale: 0.7, monospacedDigits: true)
    public static let heroUnit = TypeRole(
      size: 11, weight: .medium, design: .monospaced, tracking: 2.2, relativeTo: .caption2)
    /// System subheadline, medium serif italic, instrument cyan.
    public static let humanMeaning = TypeRole(
      size: 15, weight: .medium, design: .serif, relativeTo: .subheadline, italic: true)
    /// Phase or state metadata under the hero (spec §4).
    public static let phaseMetadata = TypeRole(
      size: 11, weight: .regular, design: .monospaced, relativeTo: .caption2, monospacedDigits: true)
    public static let stepperValue = TypeRole(
      size: 18, weight: .medium, design: .rounded, relativeTo: .body, monospacedDigits: true)
    /// 10 pt (build 14); the starter scales an 11 pt base (`stepperLabelScalable`).
    public static let stepperLabel = TypeRole(size: 10, weight: .medium, design: .monospaced, tracking: 1.5)
    public static let stepperLabelScalable = TypeRole(
      size: 11, weight: .medium, design: .monospaced, tracking: 1.5, relativeTo: .caption2)
    public static let pillTitle = TypeRole(size: 10, weight: .semibold, design: .monospaced, relativeTo: .caption2)
    public static let pillAxis = TypeRole(size: 9, weight: .medium, design: .monospaced, relativeTo: .caption2)
    /// Recommended minimum for reusable captions; smaller calibration stays supplementary.
    public static let captionMinimum = TypeRole(size: 11, weight: .regular, design: .default, relativeTo: .caption2)
    /// Telemetry label: caption2 mono, tracking 1.2. Value: title3 mono. Unit: caption2 mono.
    public static let telemetryLabelTracking: CGFloat = 1.2
    /// Crown captions reserve a scaled 14 pt row (spec §10).
    public static let crownCaptionRowHeight: CGFloat = 14
  }

  // MARK: Layout

  /// `layout` (build 14), pt.
  public enum Layout {
    public static let portraitContentMax: CGFloat = 540
    public static let clusterMax: CGFloat = 490
    public static let gaugeMax: CGFloat = 360
    public static let pillWidthCompact: CGFloat = 30
    public static let pillWidthRegular: CGFloat = 36
    public static let pillWidthBreakpoint: CGFloat = 350
    public static let clusterGap: CGFloat = 6
    public static let pillHeightMax: CGFloat = 218
    public static let pillHeightRatio: CGFloat = 0.66
    public static let controlRowMax: CGFloat = 380
    public static let stepperMinHeight: CGFloat = 48
    public static let secondaryTargetMin: CGFloat = 44
    public static let crownDiameter: CGFloat = 62
    public static let transportLabelMinHeight: CGFloat = 58
    public static let bottomContentReserve: CGFloat = 98
    public static let landscapeInstrumentWidthRatio: CGFloat = 0.47
    // Spec §5, §9, §12 values the manifest does not list.
    public static let stepperHorizontalPadding: CGFloat = 14
    public static let eventTileHeight: CGFloat = 37
    public static let eventTileRowGap: CGFloat = 7
    public static let telemetryDividerWidth: CGFloat = 1
    public static let telemetryDividerHeight: CGFloat = 30
    public static let scopeHeight: CGFloat = 140
    /// Floating action label frames: Tap 62 × 58, settings 54 × 58; row spacing 12, glass container spacing 14.
    public static let transportLeadingWidth: CGFloat = 62
    public static let transportTrailingWidth: CGFloat = 54
    public static let transportRowSpacing: CGFloat = 12
    public static let transportGlassSpacing: CGFloat = 14
    /// The environment grid pitch.
    public static let gridSpacing: CGFloat = 28
  }

  // MARK: The primary object

  /// `gauge`: proportional geometry inside the primary object, as fractions of its diameter D.
  public enum Gauge {
    public static let calibrationRadiusRatio: CGFloat = 0.445
    public static let metalInsetRatio: CGFloat = 0.038
    public static let lensDiameterRatio: CGFloat = 0.76
    public static let readoutYRatio: CGFloat = 0.52
    public static let unitsYRatio: CGFloat = 0.665
    public static let meaningYRatio: CGFloat = 0.745
    public static let meaningYAccessibilityRatio: CGFloat = 0.79
    public static let phaseYRatio: CGFloat = 0.835
    public static let readoutWidthRatio: CGFloat = 0.64
    public static let tickerPivotYRatio: CGFloat = 0.38
    public static let tickerLengthRatio: CGFloat = 0.235
    public static let tickerAmplitudeDegrees = 26.0
    public static let tickerCycleBeats = 2.0
    /// Rim scrubbing begins outside 0.30 D; the centre stays calm (spec §8).
    public static let scrubInnerRadiusRatio: CGFloat = 0.30
    /// The lens radius is 0.38 D (half of `lensDiameterRatio`) × the bounded radius scale.
    public static var lensRadiusRatio: CGFloat { lensDiameterRatio / 2 }
    /// The housing's drop shadow: black 0.8, radius 22, y 16 (spec §6).
    public static let housingShadowOpacity = 0.8
    public static let housingShadowRadius: CGFloat = 22
    public static let housingShadowY: CGFloat = 16
  }

  // MARK: Motion and sensors

  /// `motion`: timeline cadence (requested, not guaranteed), the gravity baseline and detent tuning (spec §10, §13).
  public enum Motion {
    public static let gaugeHz = 60.0
    public static let telemetryHz = 30.0
    public static let reduceMotionHz = 10.0
    public static let gravitySampleHz = 30.0
    public static let gravityGain = 1.7
    public static let gravityLowPassAlpha = 0.18
    /// At most 20 accepted detents a second.
    public static let detentMaxHz = 20.0
    public static let fineDetentDegrees = 8.0
    public static let coarseDetentDegrees = 20.0
    /// Reversal needs 18 % of the detent spacing of extra travel.
    public static let reversalHysteresisRatio = 0.18
    /// Touches within 7 pt of a crown's centre discard angular history (spec §10).
    public static let crownCentreExclusion: CGFloat = 7
    /// A queued notch is cleared when the finger moves back by more than this (degrees).
    public static let pendingReversalDegrees = 0.5
  }

  // MARK: Optics

  /// `optics`: the bounded refraction and chromatic cue under the isolated lens (spec §14). An artistic cue, not a
  /// calibrated optical model.
  public enum Optics {
    public static let shiftDiameterRatio = 0.025
    public static let shiftCapPt = 9.5
    public static let achromaticRimStart = 0.82
    public static let curvature = 0.32
    public static let totalChannelSplitAt322Pt = 1.0
    public static let totalChannelSplitCapPt = 1.2
    public static let channelOffsetFractionOfTotal = 0.5
    public static let chromaticInnerStart = 0.52
    public static let chromaticPeakRadius = 0.82
    public static let rimRadiusRatio = 0.985
    public static let rimArcDegrees = 76.0
    /// The reflection's centre angle is −90° + 70° × tilt.x + 20° × tilt.y.
    public static let rimAngleBaseDegrees = -90.0
    public static let rimAngleTiltXDegrees = 70.0
    public static let rimAngleTiltYDegrees = 20.0
    public static let rimOpacityConstant = true
    public static let faceHighlightFill = false
    /// The reference gauge diameter at which the total channel split is 1 pt.
    public static let referenceDiameter = 322.0
    /// The lens radius scale is clamped to 0.92…1.09; the centre never moves.
    public static let radiusScaleRange: ClosedRange<Double> = 0.92...1.09
  }

  // MARK: Feedback

  /// One Core Haptics transient: intensity and sharpness, 0…1.
  public struct HapticDetent: Sendable, Hashable {
    public let intensity: Double
    public let sharpness: Double
    public init(intensity: Double, sharpness: Double) {
      self.intensity = intensity
      self.sharpness = sharpness
    }
  }

  /// `hapticDetents` (spec §15): fine, semantic and directional adjustments feel distinct.
  public enum HapticDetents {
    public static let fineUp = HapticDetent(intensity: 0.78, sharpness: 0.95)
    public static let fineDown = HapticDetent(intensity: 0.82, sharpness: 0.2)
    public static let semanticUp = HapticDetent(intensity: 1, sharpness: 0.6)
    public static let semanticDown = HapticDetent(intensity: 1, sharpness: 0.05)
  }

  // MARK: Contracts and portability

  /// `contract`: the behavioural rules every adopting screen keeps (spec §1). LabKitMetro's components honour them.
  public enum Contract {
    public static let readoutTransforms = false
    public static let controlTransformsFromSensor = false
    public static let pillOutlineBeatAnimation = false
    public static let globalBeatOpacityAnimation = false
    public static let controlTouchOwnsWholeSequence = true
    public static let nativeHoldRepeat = true
    public static let wholeIntegerValuesRenderWithoutDecimals = true
  }

  /// `portability`.
  public enum Portability {
    public static let starterMinimumIOS = 26
    public static let sourceTargetIOS = 27
  }
}
