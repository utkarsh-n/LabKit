#if os(iOS)
  import LabKitCore
  import SwiftUI

  /// The isolated glass lens (spec §6–§7, §14; the starter's `InstrumentLensSurface` with the package shader): a stack of
  /// independently owned layers, bottom to top:
  ///
  /// 1. `face`: pure SwiftUI decorative drawing (Canvas or Shapes: calibration and the domain mechanism), filtered by
  ///    one `layerEffect` (`MetroShaders.lensOptics`: bounded achromatic refraction plus a subtle diagonal red/blue
  ///    split, sampled with the declared `MetroLensRefraction.samplingBound`);
  /// 2. centred native **clear** Liquid Glass, 0.76 D, at a constant 0.48 composite opacity (1 under Reduce
  ///    Transparency); only its radius may change (`radiusScale`, clamped to 0.92…1.09), its centre never;
  /// 3. a faint rim arc (76°, 0.9 pt, white 0.085 peak) whose angular position follows tilt and whose opacity is
  ///    constant; no fill, bloom or moving patch on the face;
  /// 4. `readout`: unfiltered values, units and meaning at fixed coordinates.
  ///
  /// Custom optics are off (identity sampling, no rim glide) under Reduce Motion, Reduce Transparency, an inactive scene
  /// or `motionActive == false`; the radius rests at 1 under Reduce Motion or an inactive scene. The host owns the
  /// sensor (`MetroTilt`), its permission, orientation mapping and lifecycle, and supplies `radiusScale` from its own
  /// clock (`MetroLensPulse`), never a competing UI timer. The surface owns no gestures: put the interaction region
  /// beside it, outside the filter.
  public struct MetroLensSurface<Face: View, Readout: View>: View {
    private let diameter: CGFloat
    private let inputScale: Double
    private let filteredTilt: SIMD2<Double>
    private let motionActive: Bool
    private let face: Face
    private let readout: Readout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase

    public init(
      diameter: CGFloat, radiusScale: Double = 1, filteredTilt: SIMD2<Double> = .zero, motionActive: Bool = false,
      @ViewBuilder face: () -> Face, @ViewBuilder readout: () -> Readout
    ) {
      self.diameter = diameter.isFinite ? max(1, diameter) : 1
      self.inputScale = MetroLensRefraction.boundedRadiusScale(radiusScale)
      self.filteredTilt = filteredTilt
      self.motionActive = motionActive
      self.face = face()
      self.readout = readout()
    }

    private var state: MetroLensState {
      MetroLensState(
        diameter: Double(diameter), radiusScale: inputScale, tilt: filteredTilt, motionActive: motionActive,
        reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, sceneActive: scenePhase == .active)
    }

    public var body: some View {
      let state = state
      let bound = CGFloat(MetroLensRefraction.samplingBound(diameter: Double(diameter)))
      ZStack {
        face
          .frame(width: diameter, height: diameter)
          .layerEffect(
            MetroShaders.lensOptics(diameter: diameter, radius: CGFloat(state.radius), enhancedTilt: state.enhancedTilt),
            maxSampleOffset: CGSize(width: bound, height: bound), isEnabled: state.opticsEnabled
          )
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        Color.clear
          .frame(width: diameter * Metro.Gauge.lensDiameterRatio, height: diameter * Metro.Gauge.lensDiameterRatio)
          .glassEffect(.clear, in: .circle)
          .scaleEffect(state.scale, anchor: .center)
          .opacity(state.lensOpacity)
          .frame(width: diameter, height: diameter)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        if state.opticsEnabled { MetroLensRimLight(diameter: diameter, state: state) }
        readout.frame(width: diameter, height: diameter)
      }
      .frame(width: diameter, height: diameter)
      .transaction { $0.animation = nil }
    }
  }

  /// The faint rim reflection: a 76° arc at 0.985 R whose centre angle follows the enhanced tilt. Constant opacity.
  struct MetroLensRimLight: View {
    let diameter: CGFloat
    let state: MetroLensState

    var body: some View {
      Canvas { context, _ in
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let rim = state.radius * Metro.Optics.rimRadiusRatio
        let angle = state.rimAngleDegrees
        let half = Metro.Optics.rimArcDegrees / 2
        let start = angle - half
        let end = angle + half
        let arc = Path { path in
          path.addArc(center: center, radius: rim, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        }
        let a = CGPoint(x: center.x + rim * cos(start * .pi / 180), y: center.y + rim * sin(start * .pi / 180))
        let b = CGPoint(x: center.x + rim * cos(end * .pi / 180), y: center.y + rim * sin(end * .pi / 180))
        context.stroke(
          arc,
          with: .linearGradient(
            Gradient(stops: [
              .init(color: .clear, location: 0), .init(color: .white.opacity(Metro.Opacity.rimLightPeak), location: 0.5),
              .init(color: .clear, location: 1),
            ]), startPoint: a, endPoint: b),
          style: StrokeStyle(lineWidth: Metro.Stroke.glassRimLight, lineCap: .round))
      }
      .frame(width: diameter, height: diameter)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  /// The large readout of a primary object (spec §4, §8): the hero numeral (0.23 D, light rounded, monospaced digits,
  /// 0.64 D wide, minimum scale 0.7) at y 0.52 D; units (scaled 11 pt mono, tracking 2.2, white 0.68) at 0.665 D; the
  /// human meaning (subheadline serif italic, instrument cyan) at 0.745 D; optional phase metadata (scaled 11 pt mono,
  /// white 0.68, with a status dot) at 0.835 D. At accessibility sizes units and phase hide (the spoken value keeps
  /// them) and the meaning moves to 0.79 D. Never transformed by tilt or the lens radius; owns no touches.
  public struct MetroLargeReadout: View {
    private let diameter: CGFloat
    private let value: String
    private let unit: String
    private let meaning: String?
    private let phase: String?
    private let phaseActive: Bool
    private let spokenLabel: String
    private let spokenValue: String?
    @ScaledMetric(relativeTo: .caption2) private var metadataSize = Metro.Typography.heroUnit.size
    @Environment(\.dynamicTypeSize) private var dynamicType

    /// - Parameter spokenValue: the complete spoken value ("120 beats per minute, Allegro"); value, unit and meaning
    ///   joined when nil.
    public init(
      diameter: CGFloat, value: String, unit: String, meaning: String? = nil, phase: String? = nil,
      phaseActive: Bool = false, spokenLabel: String, spokenValue: String? = nil
    ) {
      self.diameter = diameter.isFinite ? max(1, diameter) : 1
      self.value = value
      self.unit = unit
      self.meaning = meaning
      self.phase = phase
      self.phaseActive = phaseActive
      self.spokenLabel = spokenLabel
      self.spokenValue = spokenValue
    }

    public var body: some View {
      let layout = MetroReadoutLayout(diameter: diameter, accessibilitySize: dynamicType.isAccessibilitySize)
      ZStack {
        Text(value)
          .font(MetroFont.font(Metro.Typography.heroValue, size: layout.valueFontSize))
          .foregroundStyle(MetroPalette.displayInk)
          .minimumScaleFactor(Metro.Typography.heroValue.minimumScale ?? 0.7)
          .lineLimit(1)
          .frame(width: layout.readoutWidth)
          .position(x: layout.centreX, y: layout.valueY)
        if layout.showsSupplementaryLines, !unit.isEmpty {
          Text(unit)
            .font(.system(size: metadataSize, weight: .medium, design: .monospaced))
            .tracking(Metro.Typography.heroUnit.tracking)
            .foregroundStyle(.white.opacity(Metro.Opacity.dialMetadata))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: layout.readoutWidth)
            .position(x: layout.centreX, y: layout.unitsY)
        }
        if let meaning {
          Text(meaning)
            .font(MetroFont.meaning)
            .foregroundStyle(MetroPalette.instrumentCyan)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .frame(width: layout.readoutWidth)
            .position(x: layout.centreX, y: layout.meaningY)
        }
        if layout.showsSupplementaryLines, let phase {
          HStack(spacing: 5) {
            Circle().fill(phaseActive ? MetroPalette.instrumentAmber : .white.opacity(0.28)).frame(width: 3, height: 3)
            Text(phase)
              .font(.system(size: metadataSize, weight: .regular, design: .monospaced))
              .monospacedDigit()
              .foregroundStyle(.white.opacity(Metro.Opacity.dialMetadata))
              .lineLimit(1)
          }
          .position(x: layout.centreX, y: layout.phaseY)
        }
      }
      .frame(width: diameter, height: diameter)
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spokenLabel)
      .accessibilityValue(
        spokenValue ?? [value, LabFormat.spoken(unit), meaning ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }
  }
#endif
