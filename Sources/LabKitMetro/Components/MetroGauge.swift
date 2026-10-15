#if os(iOS)
  import LabKitCore
  import LabKitFeedback
  import SwiftUI

  /// What a primary object's readout says (spec §8): the hero value, its unit, a short human meaning and optional phase
  /// metadata, with the complete spoken form.
  public struct MetroGaugeReadout: Sendable, Hashable {
    public var value: String
    public var unit: String
    public var meaning: String?
    public var phase: String?
    public var phaseActive: Bool
    public var spokenLabel: String
    public var spokenValue: String?

    public init(
      value: String, unit: String, meaning: String? = nil, phase: String? = nil, phaseActive: Bool = false,
      spokenLabel: String, spokenValue: String? = nil
    ) {
      self.value = value
      self.unit = unit
      self.meaning = meaning
      self.phase = phase
      self.phaseActive = phaseActive
      self.spokenLabel = spokenLabel
      self.spokenValue = spokenValue
    }
  }

  /// The direct-manipulation contract of a primary object (spec §8): rim scrubbing outside 0.30 D, incremental across
  /// the ±π seam, Schmitt-quantised, plus the non-gesture alternatives (VoiceOver adjustable, named coarse actions).
  public struct MetroGaugeInteraction {
    /// Rim travel per whole step.
    public var degreesPerStep: Double
    public var hint: String
    /// Words under the readout while scrubbing (hidden at accessibility sizes).
    public var idleWord: String
    public var increaseWord: String
    public var decreaseWord: String
    /// Named VoiceOver actions for a coarse move ("Increase by ten", 10).
    public var coarse: (increase: String, decrease: String, steps: Int)?
    /// Applies a proposed whole-step change and returns the change actually applied (0 at a limit).
    public var apply: (Int) -> Int
    public var onBegan: () -> Void
    public var onEnded: () -> Void

    public init(
      degreesPerStep: Double, hint: String, idleWord: String = "SCRUB", increaseWord: String = "INCREASE",
      decreaseWord: String = "DECREASE", coarse: (increase: String, decrease: String, steps: Int)? = nil,
      onBegan: @escaping () -> Void = {}, onEnded: @escaping () -> Void = {}, apply: @escaping (Int) -> Int
    ) {
      self.degreesPerStep = degreesPerStep
      self.hint = hint
      self.idleWord = idleWord
      self.increaseWord = increaseWord
      self.decreaseWord = decreaseWord
      self.coarse = coarse
      self.apply = apply
      self.onBegan = onBegan
      self.onEnded = onEnded
    }
  }

  /// The calibration of a primary object's scale (spec §8): a 300° sweep from 120° (lower left) clockwise, `ticks`
  /// divisions with major and middle marks, one label per major mark, and an optional spectral band lit up to the index.
  public struct MetroGaugeScale: Sendable, Hashable {
    public var ticks: Int
    public var majorEvery: Int
    public var middleEvery: Int
    /// One label per major mark, lowest first (`ticks / majorEvery + 1` of them).
    public var labels: [String]
    public var spectralBand: Bool
    public static let startDegrees = 120.0
    public static let sweepDegrees = 300.0

    public init(ticks: Int = 70, majorEvery: Int = 10, middleEvery: Int = 5, labels: [String] = [], spectralBand: Bool = true) {
      self.ticks = max(1, ticks)
      self.majorEvery = max(1, majorEvery)
      self.middleEvery = max(1, middleEvery)
      self.labels = labels
      self.spectralBand = spectralBand
    }

    /// The screen angle (degrees, clockwise from +x) of a 0…1 position along the scale.
    public static func angle(fraction: Double) -> Double {
      startDegrees + (fraction.isFinite ? min(1, max(0, fraction)) : 0) * sweepDegrees
    }
  }

  /// The primary instrument (spec §6–§8; Metro Station `GaugeView`, generalised): opaque metal housing, a calibrated
  /// spectral scale with an amber index, the host's domain `mechanism`, both seen through the isolated glass lens
  /// (`MetroLensSurface`), the unfiltered `MetroLargeReadout` at fixed coordinates, and a fixed circular interaction
  /// region (rim scrubbing, VoiceOver adjustable and named actions) that owns its touches. Tilt moves only the metal's
  /// light, the optics and the rim reflection, never the readout or the touch region.
  public struct MetroGauge<Mechanism: View>: View {
    private let diameter: CGFloat
    private let fraction: Double
    private let scale: MetroGaugeScale
    private let readout: MetroGaugeReadout
    private let tilt: SIMD2<Double>
    private let motionActive: Bool
    private let radiusScale: Double
    private let interaction: MetroGaugeInteraction?
    private let identifier: String
    private let mechanism: Mechanism

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.metroHaptics) private var haptics
    @ScaledMetric(relativeTo: .caption2) private var metadataSize = Metro.Typography.heroUnit.size
    @State private var scrub = MetroRimScrub(degreesPerStep: 10)
    @State private var scrubDirection = 0

    /// - Parameters:
    ///   - fraction: the index position along the scale, 0…1.
    ///   - tilt: the host's filtered screen-space tilt (`MetroTilt.vector`).
    ///   - radiusScale: the lens radius scale from the host's clock (`MetroLensPulse`), 1 at rest.
    public init(
      diameter: CGFloat, fraction: Double, scale: MetroGaugeScale = MetroGaugeScale(), readout: MetroGaugeReadout,
      tilt: SIMD2<Double> = .zero, motionActive: Bool = false, radiusScale: Double = 1,
      interaction: MetroGaugeInteraction? = nil, identifier: String = "metro-gauge",
      @ViewBuilder mechanism: () -> Mechanism
    ) {
      self.diameter = diameter.isFinite ? max(1, diameter) : 1
      self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
      self.scale = scale
      self.readout = readout
      self.tilt = tilt
      self.motionActive = motionActive
      self.radiusScale = radiusScale
      self.interaction = interaction
      self.identifier = identifier
      self.mechanism = mechanism()
    }

    private var light: SIMD2<Double> { reduceMotion || !motionActive ? .zero : tilt }

    public var body: some View {
      let d = diameter
      ZStack {
        MetroInstrumentHousing(diameter: d, light: light)
        MetroLensSurface(diameter: d, radiusScale: radiusScale, filteredTilt: tilt, motionActive: motionActive) {
          ZStack {
            MetroGaugeDial(
              diameter: d, fraction: fraction, scale: scale, light: light,
              showsLabels: !dynamicType.isAccessibilitySize)
            mechanism.frame(width: d, height: d)
          }
        } readout: {
          MetroLargeReadout(
            diameter: d, value: readout.value, unit: readout.unit, meaning: readout.meaning, phase: readout.phase,
            phaseActive: readout.phaseActive, spokenLabel: readout.spokenLabel, spokenValue: readout.spokenValue)
        }
        if let interaction, scrub.isActive, !dynamicType.isAccessibilitySize {
          VStack {
            Spacer()
            HStack(spacing: 5) {
              Image(systemName: scrubDirection >= 0 ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.system(size: metadataSize - 1, weight: .medium))
              Text(
                scrubDirection == 0
                  ? interaction.idleWord : scrubDirection > 0 ? interaction.increaseWord : interaction.decreaseWord
              )
              .font(.system(size: metadataSize, weight: .medium, design: .monospaced))
              .tracking(1.15)
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.bottom, d * 0.054)
          }
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .frame(width: d, height: d)
      .contentShape(Circle())
      .gesture(scrubGesture, isEnabled: interaction != nil)
      .onDisappear { endScrub() }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { endScrub() }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier(identifier)
      .accessibilityLabel(readout.spokenLabel)
      .accessibilityValue(spokenValue)
      .accessibilityHint(interaction?.hint ?? "")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: accessibleStep(1)
        case .decrement: accessibleStep(-1)
        @unknown default: break
        }
      }
      .accessibilityActions {
        if let coarse = interaction?.coarse {
          Button(coarse.increase) { accessibleStep(coarse.steps) }
          Button(coarse.decrease) { accessibleStep(-coarse.steps) }
        }
      }
      .metroControlOwnsTouches(identifier: identifier)
    }

    private var spokenValue: String {
      readout.spokenValue
        ?? [readout.value, LabFormat.spoken(readout.unit), readout.meaning ?? ""].filter { !$0.isEmpty }
        .joined(separator: ", ")
    }

    private var scrubGesture: some Gesture {
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          guard let interaction else { return }
          if !scrub.isActive {
            // The large central readout stays calm; the rim is the manipulation target.
            guard MetroRimScrub.beginsOnRim(value.startLocation, diameter: diameter) else { return }
            scrub = MetroRimScrub(degreesPerStep: interaction.degreesPerStep)
            scrub.begin(at: value.startLocation, diameter: diameter)
            scrubDirection = 0
            interaction.onBegan()
          }
          let applied = scrub.update(at: value.location, diameter: diameter, accept: interaction.apply)
          if applied != 0 {
            scrubDirection = applied > 0 ? 1 : -1
            haptics?.play(MetroDetentRole.fine.tap(direction: applied))
          }
        }
        .onEnded { _ in endScrub() }
    }

    private func accessibleStep(_ steps: Int) {
      guard let interaction else { return }
      let applied = interaction.apply(steps)
      if applied != 0 { haptics?.play(MetroDetentRole.fine.tap(direction: applied)) }
    }

    private func endScrub() {
      guard scrub.isActive else { return }
      scrub.end()
      scrubDirection = 0
      interaction?.onEnded()
    }
  }

  extension MetroGauge where Mechanism == EmptyView {
    /// A primary object without a domain mechanism (the scale and index alone).
    public init(
      diameter: CGFloat, fraction: Double, scale: MetroGaugeScale = MetroGaugeScale(), readout: MetroGaugeReadout,
      tilt: SIMD2<Double> = .zero, motionActive: Bool = false, radiusScale: Double = 1,
      interaction: MetroGaugeInteraction? = nil, identifier: String = "metro-gauge"
    ) {
      self.init(
        diameter: diameter, fraction: fraction, scale: scale, readout: readout, tilt: tilt, motionActive: motionActive,
        radiusScale: radiusScale, interaction: interaction, identifier: identifier
      ) { EmptyView() }
    }
  }

  /// The decorative calibrated face (drawn inside the lens's optical filter): the recessed sweep, the spectral band lit
  /// up to the index, major/middle/minor marks, major labels, the amber index (triangle and needle) and three faint
  /// caustic arcs that move with the light.
  public struct MetroGaugeDial: View {
    private let diameter: CGFloat
    private let fraction: Double
    private let scale: MetroGaugeScale
    private let light: SIMD2<Double>
    private let showsLabels: Bool

    public init(diameter: CGFloat, fraction: Double, scale: MetroGaugeScale, light: SIMD2<Double>, showsLabels: Bool) {
      self.diameter = diameter.isFinite ? max(1, diameter) : 1
      self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
      self.scale = scale
      self.light = SIMD2(
        light.x.isFinite ? min(1, max(-1, light.x)) : 0, light.y.isFinite ? min(1, max(-1, light.y)) : 0)
      self.showsLabels = showsLabels
    }

    public var body: some View {
      Canvas { context, size in draw(&context, diameter: min(size.width, size.height)) }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func point(_ angle: Double, _ radius: CGFloat, _ center: CGPoint) -> CGPoint {
      let radians = angle * .pi / 180
      return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    private func draw(_ context: inout GraphicsContext, diameter: CGFloat) {
      let center = CGPoint(x: diameter / 2, y: diameter / 2)
      let radius = diameter * Metro.Gauge.calibrationRadiusRatio
      let start = MetroGaugeScale.startDegrees
      let sweep = MetroGaugeScale.sweepDegrees
      let index = MetroGaugeScale.angle(fraction: fraction)
      let track = Path { path in
        path.addArc(
          center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
      }
      context.stroke(track, with: .color(.white.opacity(0.075)), style: StrokeStyle(lineWidth: 4, lineCap: .round))

      if scale.spectralBand {
        // A thin spectral scale, separate from the bright amber index.
        for segment in 0..<120 {
          let angle = start + Double(segment) * 2.5
          let arc = Path { path in
            path.addArc(
              center: center, radius: radius, startAngle: .degrees(angle), endAngle: .degrees(angle + 2.1), clockwise: false)
          }
          let hue = 0.49 + Double(segment) / 120 * 0.37
          let lit = angle <= index
          context.stroke(
            arc,
            with: .color(Color(hue: hue, saturation: 0.70, brightness: lit ? 0.92 : 0.33).opacity(lit ? 0.85 : 0.40)),
            style: StrokeStyle(lineWidth: lit ? 2.5 : 1.2, lineCap: .butt))
        }
      }

      for tick in 0...scale.ticks {
        let angle = start + Double(tick) / Double(scale.ticks) * sweep
        let major = tick.isMultiple(of: scale.majorEvery)
        let middle = tick.isMultiple(of: scale.middleEvery)
        let outer = radius - 10
        let inner = outer - (major ? 12 : middle ? 8 : 4)
        var mark = Path()
        mark.move(to: point(angle, inner, center))
        mark.addLine(to: point(angle, outer, center))
        context.stroke(
          mark, with: .color(.white.opacity(major ? 0.64 : middle ? 0.38 : 0.19)), lineWidth: major ? 1.3 : 0.8)
        let labelIndex = tick / scale.majorEvery
        if major, showsLabels, labelIndex < scale.labels.count {
          let label = Text(scale.labels[labelIndex])
            .font(.system(size: diameter * 0.027, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.54))
          context.draw(label, at: point(angle, inner - 9, center))
        }
      }

      let amber = MetroPalette.instrumentAmber
      var triangle = Path()
      triangle.move(to: point(index, radius + 6, center))
      triangle.addLine(to: point(index - 1.8, radius + 12, center))
      triangle.addLine(to: point(index + 1.8, radius + 12, center))
      triangle.closeSubpath()
      context.fill(triangle, with: .color(amber))
      var needle = Path()
      needle.move(to: point(index, radius - 2, center))
      needle.addLine(to: point(index, radius - 20, center))
      context.stroke(needle, with: .color(amber), style: StrokeStyle(lineWidth: 2.1, lineCap: .round))

      // Different depths and slightly split highlights respond to the light independently.
      let reflection = -120 + light.x * 32 + light.y * 20
      for layer in 0..<3 {
        let layerRadius = diameter * (0.485 - Double(layer) * 0.008)
        let offset = Double(layer) * 1.1
        let caustic = Path { path in
          path.addArc(
            center: CGPoint(x: center.x + light.x * offset, y: center.y + light.y * offset), radius: layerRadius,
            startAngle: .degrees(reflection - 27), endAngle: .degrees(reflection + 22), clockwise: false)
        }
        let colour: Color =
          layer == 0 ? .white : layer == 1 ? MetroPalette.instrumentCyan : Color(red: 0.61, green: 0.54, blue: 0.97)
        context.stroke(
          caustic, with: .color(colour.opacity(layer == 0 ? 0.30 : 0.12)),
          style: StrokeStyle(lineWidth: layer == 0 ? 1 : 0.6, lineCap: .round))
      }
    }
  }

  // MARK: - ParamSpec bridge

  /// A primary object over one LabKit parameter: the index at `spec.position(of:)`, the hero value and unit from
  /// `MetroFormat.heroParts`, the meaning from the labelled detent band (or `meaning`), major labels from the spec,
  /// rim scrubbing in fine steps (300° across the sweep), VoiceOver adjustable in fine steps and named semantic actions.
  public struct MetroParamGauge<Mechanism: View>: View {
    private let store: ParamStore
    private let id: ParamID
    private let diameter: CGFloat
    private let meaning: String?
    private let phase: String?
    private let phaseActive: Bool
    private let tilt: SIMD2<Double>
    private let motionActive: Bool
    private let radiusScale: Double
    private let onInteraction: (Bool) -> Void
    private let mechanism: Mechanism

    /// - Parameters:
    ///   - meaning: the human meaning under the value; the labelled detent band ("Allegro") when nil.
    ///   - phase: optional phase metadata ("BEAT 1 / 4"); `phaseActive` lights its status dot amber.
    public init(
      store: ParamStore, id: ParamID, diameter: CGFloat, meaning: String? = nil, phase: String? = nil,
      phaseActive: Bool = false, tilt: SIMD2<Double> = .zero, motionActive: Bool = false, radiusScale: Double = 1,
      onInteraction: @escaping (Bool) -> Void = { _ in }, @ViewBuilder mechanism: () -> Mechanism
    ) {
      self.store = store
      self.id = id
      self.diameter = diameter
      self.meaning = meaning
      self.phase = phase
      self.phaseActive = phaseActive
      self.tilt = tilt
      self.motionActive = motionActive
      self.radiusScale = radiusScale
      self.onInteraction = onInteraction
      self.mechanism = mechanism()
    }

    public var body: some View {
      let spec = store.spec(id)
      let value = store[id]
      let parts = MetroFormat.heroParts(spec, value)
      let band = MetroParamStepping.band(spec, at: value)?.label
      MetroGauge(
        diameter: diameter, fraction: spec.position(of: value),
        scale: MetroGaugeScale(labels: MetroParamGaugeLabels.labels(spec, majors: 8)),
        readout: MetroGaugeReadout(
          value: parts.value, unit: LabFormat.uppercasedLatin(parts.unit), meaning: meaning ?? band, phase: phase,
          phaseActive: phaseActive, spokenLabel: spec.accessibilityLabel, spokenValue: MetroFormat.spoken(spec, value)),
        tilt: tilt, motionActive: motionActive, radiusScale: radiusScale,
        interaction: MetroGaugeInteraction(
          degreesPerStep: MetroParamStepping.rimDegreesPerStep(spec), hint: spec.hint,
          onBegan: { onInteraction(true) }, onEnded: { onInteraction(false) },
          apply: { steps in store.metroApplyFine(id, steps: steps) }),
        identifier: "metro-gauge-\(id.rawValue)"
      ) { mechanism }
      .accessibilityActions {
        Button("Next \(spec.title.lowercased()) stop") { semantic(1) }
        Button("Previous \(spec.title.lowercased()) stop") { semantic(-1) }
      }
    }

    @Environment(\.metroHaptics) private var haptics

    private func semantic(_ direction: Int) {
      guard store.metroStep(id, direction: direction, role: .semantic) != nil else { return }
      haptics?.play(MetroDetentRole.semantic.tap(direction: direction))
    }
  }

  extension MetroParamGauge where Mechanism == EmptyView {
    public init(
      store: ParamStore, id: ParamID, diameter: CGFloat, meaning: String? = nil, phase: String? = nil,
      phaseActive: Bool = false, tilt: SIMD2<Double> = .zero, motionActive: Bool = false, radiusScale: Double = 1,
      onInteraction: @escaping (Bool) -> Void = { _ in }
    ) {
      self.init(
        store: store, id: id, diameter: diameter, meaning: meaning, phase: phase, phaseActive: phaseActive, tilt: tilt,
        motionActive: motionActive, radiusScale: radiusScale, onInteraction: onInteraction
      ) { EmptyView() }
    }
  }
#endif
