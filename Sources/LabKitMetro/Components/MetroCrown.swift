#if os(iOS)
  import LabKitCore
  import LabKitFeedback
  import SwiftUI

  /// A tactile crown (spec §10; Metro Station `TempoCrownControl`): a knurled metal face (62 × 62) between native
  /// glass minus/plus buttons (44 × 44 labels, 13 pt semibold, tint 0.08), a steady caption row above and below (a
  /// scaled 14 pt base each).
  ///
  /// Rotating the face moves in relative angular detents (`MetroCrownDetentTracker`: 8° fine or 20° semantic, 18 %
  /// reversal hysteresis, at most one step per update, the ±180° seam handled, a 7 pt centre exclusion) through a rate
  /// gate (`MetroDetentGate`: at most 20 a second, no queued catch-up burst, a pending notch cleared on reversal). Every
  /// **accepted** step, from the face, a button or VoiceOver, calls `onStep(direction)` once and plays the role's
  /// directional detent once through `.metroHaptics(_:)`. A step `canStep` refuses (a domain limit) does neither.
  ///
  /// The control owns touches that begin on it; tilt only moves the metal's light, never the control or its captions.
  public struct MetroCrown: View {
    private let role: MetroDetentRole
    private let accent: Color
    private let caption: String
    private let footer: MetroCrownFooter
    private let glyph: MetroCrownGlyph
    private let light: SIMD2<Double>
    private let accessibilityName: String
    private let accessibilityValueText: String
    private let accessibilityHintText: String
    private let increaseLabel: String
    private let decreaseLabel: String
    private let identifier: String
    private let canStep: (Int) -> Bool
    private let onStep: (Int) -> Void
    private let onInteraction: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.metroHaptics) private var haptics
    @ScaledMetric(relativeTo: .caption2) private var captionRowHeight = Metro.Typography.crownCaptionRowHeight
    @State private var tracker = MetroCrownDetentTracker(role: .fine)
    @State private var gate = MetroDetentGate()
    @State private var isDragging = false
    @State private var previousVisualAngle: Double?
    @State private var rotation = 0.0

    /// - Parameters:
    ///   - role: fine (8° detents, a numeric increment) or semantic (20° detents, a named state).
    ///   - accent: instrument cyan for fine and instrument amber for semantic by default.
    ///   - caption: the steady top caption ("FINE", "TEMPO · ALLEGRO").
    ///   - light: a bounded screen-space tilt for the metal's light (zero under Reduce Motion).
    ///   - canStep: whether a step in a direction would change the domain value.
    ///   - onStep: called once per accepted step, after `canStep` agreed.
    ///   - onInteraction: true when a gesture or button press begins, false when it ends.
    public init(
      role: MetroDetentRole, accent: Color? = nil, caption: String, footer: MetroCrownFooter,
      glyph: MetroCrownGlyph, light: SIMD2<Double> = .zero, accessibilityLabel: String, accessibilityValue: String,
      accessibilityHint: String, increaseLabel: String, decreaseLabel: String, identifier: String,
      canStep: @escaping (Int) -> Bool, onStep: @escaping (Int) -> Void,
      onInteraction: @escaping (Bool) -> Void = { _ in }
    ) {
      self.role = role
      self.accent = accent ?? (role == .fine ? MetroPalette.instrumentCyan : MetroPalette.instrumentAmber)
      self.caption = caption
      self.footer = footer
      self.glyph = glyph
      self.light = light
      self.accessibilityName = accessibilityLabel
      self.accessibilityValueText = accessibilityValue
      self.accessibilityHintText = accessibilityHint
      self.increaseLabel = increaseLabel
      self.decreaseLabel = decreaseLabel
      self.identifier = identifier
      self.canStep = canStep
      self.onStep = onStep
      self.onInteraction = onInteraction
    }

    public var body: some View {
      VStack(spacing: 5) {
        Text(caption)
          .font(MetroFont.caption)
          .foregroundStyle(accent)
          .lineLimit(1)
          .minimumScaleFactor(0.9)
          .frame(height: captionRowHeight)

        GlassEffectContainer(spacing: 6) {
          HStack(spacing: 0) {
            stepButton(-1)
            face
            stepButton(1)
          }
          .frame(maxWidth: .infinity)
        }

        footerRow
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.white.opacity(0.75))
          .frame(height: captionRowHeight)
      }
      .frame(maxWidth: .infinity)
      .metroControlOwnsTouches(identifier: identifier)
      .onDisappear { finishGesture() }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { finishGesture() }
      }
    }

    @ViewBuilder private var footerRow: some View {
      switch footer {
      case .text(let text):
        Text(text).lineLimit(1)
      case .neighbours(let previous, let next, let fallback):
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 3) {
            Text(previous).lineLimit(1)
            Image(systemName: "arrow.left.arrow.right")
            Text(next).lineLimit(1)
          }
          .fixedSize(horizontal: true, vertical: false)
          Text(fallback).lineLimit(1)
        }
        .accessibilityHidden(true)
      }
    }

    private var face: some View {
      let crown = Metro.Layout.crownDiameter
      return MetroCrownFace(
        accent: accent, rotation: reduceMotion ? 0 : rotation, light: reduceMotion ? .zero : light,
        isPressed: isDragging, glyph: glyph
      )
      .frame(width: crown, height: crown)
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in drag(to: value.location, diameter: crown) }
          .onEnded { _ in finishGesture() }
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityName)
      .accessibilityValue(accessibilityValueText)
      .accessibilityHint(accessibilityHintText)
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: tapStep(1)
        case .decrement: tapStep(-1)
        @unknown default: break
        }
      }
      .accessibilityIdentifier(identifier)
    }

    private func drag(to location: CGPoint, diameter: CGFloat) {
      let dx = Double(location.x - diameter / 2)
      let dy = Double(location.y - diameter / 2)
      guard hypot(dx, dy) >= Double(Metro.Motion.crownCentreExclusion) else {
        // Crossing the bearing discards only angular history; emerging on the other side cannot make a large step.
        tracker.reset()
        previousVisualAngle = nil
        gate.clearPending()
        return
      }
      let angle = atan2(dy, dx) * 180 / .pi
      if !isDragging {
        isDragging = true
        tracker = MetroCrownDetentTracker(role: role)
        tracker.begin(angleDegrees: angle)
        previousVisualAngle = angle
        gate.begin()
        onInteraction(true)
        return
      }
      var visualDelta: Double?
      if let previousVisualAngle {
        let delta = MetroCrownDetentTracker.wrap(angle - previousVisualAngle)
        visualDelta = delta
        rotation += delta
      }
      previousVisualAngle = angle
      let detent = tracker.update(angleDegrees: angle)
      let accepted = gate.update(
        visualDelta: visualDelta, detent: detent, now: ProcessInfo.processInfo.systemUptime, canStep: canStep)
      if accepted != 0 { accept(accepted) }
    }

    private func stepButton(_ direction: Int) -> some View {
      Button {
        tapStep(direction)
      } label: {
        Image(systemName: direction > 0 ? "plus" : "minus")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(accent)
          .frame(width: Metro.Layout.secondaryTargetMin, height: Metro.Layout.secondaryTargetMin)
          .metroGlassControl(accent: accent)
      }
      .buttonStyle(.plain)
      .disabled(!canStep(direction))
      .accessibilityLabel(direction > 0 ? increaseLabel : decreaseLabel)
      .accessibilityIdentifier("\(identifier)-\(direction > 0 ? "plus" : "minus")")
    }

    private func tapStep(_ direction: Int) {
      guard canStep(direction) else { return }
      onInteraction(true)
      accept(direction)
      onInteraction(false)
    }

    private func accept(_ direction: Int) {
      onStep(direction)
      haptics?.play(role.tap(direction: direction))
    }

    private func finishGesture() {
      guard isDragging else { return }
      isDragging = false
      tracker.reset()
      previousVisualAngle = nil
      gate.clearPending()
      onInteraction(false)
    }
  }

  /// The crown's metal (spec §6 "Metal recipe", §10): crown-base body with a black 0.75 shadow (resting radius 6 / y 5,
  /// pressed 3 / y 2), a rim gradient through rim-light, rim-dark and rim-mid, 40 knurls, a face gradient, concentric
  /// grooves, an accent pointer that turns with the drag and a fixed accent datum at the top. Decorative: hidden from
  /// accessibility (the crown control speaks for it).
  public struct MetroCrownFace: View {
    private let accent: Color
    private let rotation: Double
    private let light: SIMD2<Double>
    private let isPressed: Bool
    private let glyph: MetroCrownGlyph

    public init(accent: Color, rotation: Double, light: SIMD2<Double> = .zero, isPressed: Bool, glyph: MetroCrownGlyph)
    {
      self.accent = accent
      self.rotation = rotation.isFinite ? rotation : 0
      self.light = SIMD2(
        light.x.isFinite ? min(1, max(-1, light.x)) : 0, light.y.isFinite ? min(1, max(-1, light.y)) : 0)
      self.isPressed = isPressed
      self.glyph = glyph
    }

    public var body: some View {
      ZStack {
        Circle()
          .fill(MetroPalette.crownBase)
          .shadow(color: .black.opacity(0.75), radius: isPressed ? 3 : 6, y: isPressed ? 2 : 5)
        Canvas { context, size in draw(&context, diameter: min(size.width, size.height)) }
        switch glyph {
        case .text(let text):
          Text(text).font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
        case .symbol(let name):
          Image(systemName: name).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        }
      }
      .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, diameter: CGFloat) {
      let lx = light.x
      let ly = light.y
      let center = CGPoint(x: diameter / 2, y: diameter / 2)
      let rim = CGRect(x: 1.5, y: 1.5, width: diameter - 3, height: diameter - 3)
      context.fill(
        Path(ellipseIn: rim),
        with: .linearGradient(
          Gradient(colors: [MetroPalette.crownRimLight, MetroPalette.crownRimDark, MetroPalette.crownRimMid]),
          startPoint: CGPoint(x: 9 + lx * 8, y: ly * 6), endPoint: CGPoint(x: diameter - 8, y: diameter)))
      for index in 0..<40 {
        let radians = (Double(index) * 9 + rotation) * .pi / 180
        var groove = Path()
        groove.move(to: CGPoint(x: center.x + cos(radians) * diameter * 0.40, y: center.y + sin(radians) * diameter * 0.40))
        groove.addLine(
          to: CGPoint(x: center.x + cos(radians) * diameter * 0.475, y: center.y + sin(radians) * diameter * 0.475))
        context.stroke(groove, with: .color(.black.opacity(0.65)), lineWidth: 1.5)
        context.stroke(groove, with: .color(.white.opacity(0.20)), lineWidth: 0.45)
      }
      let face = CGRect(x: 8, y: 8, width: diameter - 16, height: diameter - 16)
      context.fill(
        Path(ellipseIn: face),
        with: .linearGradient(
          Gradient(colors: [MetroPalette.crownFaceLight, MetroPalette.crownFaceDark]),
          startPoint: CGPoint(x: center.x - 12 + lx * 9, y: 3 + ly * 8), endPoint: CGPoint(x: diameter - 7, y: diameter)))
      context.stroke(Path(ellipseIn: face), with: .color(.white.opacity(0.31)), lineWidth: 0.7)
      for inset in stride(from: 11.0, through: 16.0, by: 1.5) {
        context.stroke(
          Path(ellipseIn: CGRect(x: inset, y: inset, width: diameter - inset * 2, height: diameter - inset * 2)),
          with: .color(.white.opacity(0.045)), lineWidth: 0.4)
      }
      let pointerAngle = (-90 + rotation) * .pi / 180
      var pointer = Path()
      pointer.move(to: CGPoint(x: center.x + cos(pointerAngle) * 16, y: center.y + sin(pointerAngle) * 16))
      pointer.addLine(to: CGPoint(x: center.x + cos(pointerAngle) * 21, y: center.y + sin(pointerAngle) * 21))
      context.stroke(pointer, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      var datum = Path()
      datum.move(to: CGPoint(x: center.x - 2.5, y: 0.5))
      datum.addLine(to: CGPoint(x: center.x + 2.5, y: 0.5))
      datum.addLine(to: CGPoint(x: center.x, y: 4))
      datum.closeSubpath()
      context.fill(datum, with: .color(accent))
    }
  }

  // MARK: - ParamSpec bridge

  /// A crown over one LabKit parameter: **fine** moves one fine step (`MetroParamStepping.fine`), **semantic** moves to
  /// the next labelled detent (Zero-g → Moon → Mars → Earth; a rotary switch moves one position; a parameter without
  /// detents moves a coarse quarter of its sweep). Each accepted step writes `store[id]` once.
  public struct MetroParamCrown: View {
    private let store: ParamStore
    private let id: ParamID
    private let role: MetroDetentRole
    private let light: SIMD2<Double>
    private let glyph: MetroCrownGlyph?
    private let onInteraction: (Bool) -> Void
    private let onAcceptedChange: (Double) -> Void

    public init(
      store: ParamStore, id: ParamID, role: MetroDetentRole, light: SIMD2<Double> = .zero, glyph: MetroCrownGlyph? = nil,
      onInteraction: @escaping (Bool) -> Void = { _ in }, onAcceptedChange: @escaping (Double) -> Void = { _ in }
    ) {
      self.store = store
      self.id = id
      self.role = role
      self.light = light
      self.glyph = glyph
      self.onInteraction = onInteraction
      self.onAcceptedChange = onAcceptedChange
    }

    public var body: some View {
      let spec = store.spec(id)
      let value = store[id]
      let words = MetroParamCrownWords(spec: spec, value: value, role: role)
      MetroCrown(
        role: role, caption: words.caption, footer: words.footer,
        glyph: glyph ?? (role == .fine ? .text("1") : .symbol(spec.icon)), light: light,
        accessibilityLabel: words.accessibilityLabel, accessibilityValue: MetroFormat.spoken(spec, value),
        accessibilityHint: words.hint, increaseLabel: words.increaseLabel, decreaseLabel: words.decreaseLabel,
        identifier: "metro-crown-\(role.rawValue)-\(id.rawValue)",
        canStep: { direction in MetroParamStepping.canStep(spec, from: store[id], direction: direction, role: role) },
        onStep: { direction in
          // `canStep` already agreed; the store is written once.
          if let accepted = store.metroStep(id, direction: direction, role: role) { onAcceptedChange(accepted) }
        },
        onInteraction: onInteraction)
    }
  }

  /// A fine and a semantic crown for one parameter, side by side (stacked at accessibility sizes), at most 380 pt wide.
  public struct MetroParamCrownPair: View {
    private let store: ParamStore
    private let id: ParamID
    private let light: SIMD2<Double>
    private let onInteraction: (Bool) -> Void
    private let onAcceptedChange: (Double) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var activeInteractions = 0

    public init(
      store: ParamStore, id: ParamID, light: SIMD2<Double> = .zero, onInteraction: @escaping (Bool) -> Void = { _ in },
      onAcceptedChange: @escaping (Double) -> Void = { _ in }
    ) {
      self.store = store
      self.id = id
      self.light = light
      self.onInteraction = onInteraction
      self.onAcceptedChange = onAcceptedChange
    }

    public var body: some View {
      Group {
        if dynamicType.isAccessibilitySize {
          VStack(spacing: 18) {
            crown(.fine)
            crown(.semantic)
          }
        } else {
          HStack(alignment: .top, spacing: 12) {
            crown(.fine)
            crown(.semantic)
          }
        }
      }
      .frame(maxWidth: Metro.Layout.controlRowMax)
    }

    private func crown(_ role: MetroDetentRole) -> some View {
      MetroParamCrown(
        store: store, id: id, role: role, light: light, onInteraction: interaction, onAcceptedChange: onAcceptedChange)
    }

    /// One begin/end pair for the host however many crowns are touched at once.
    private func interaction(_ began: Bool) {
      if began {
        if activeInteractions == 0 { onInteraction(true) }
        activeInteractions += 1
      } else {
        guard activeInteractions > 0 else { return }
        activeInteractions -= 1
        if activeInteractions == 0 { onInteraction(false) }
      }
    }
  }

#endif
