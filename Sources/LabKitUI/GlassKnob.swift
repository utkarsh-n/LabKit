#if os(iOS)
import LabKitCore
import LabKitFeedback
import SwiftUI

/// The LabKit rotary control (labkit-from-orbitals-spectra.md §3.4). Gyre mechanics: a Liquid Glass
/// puck, an arc lit from the spec's origin, labelled detents that capture within 0.02 of the sweep,
/// 24 ticks per sweep, rotary switches that click into each position, and double-tap reset. Orbitals
/// access: keyboard arrows with focus (Shift = coarse), a VoiceOver adjustable action plus "Reset to
/// default" and "Fine control", feedback only on real value changes, and a linear precision control
/// (under the dial on `.card`; a long-press tray on `.compact`, opened through `onPrecision`).
///
/// Drag up or right to turn it up: 230 pt of (dx − dy) is the full sweep, in position space, so a log
/// knob gives every decade equal travel. The tint is `spec.tint` or the palette's hue for `spec.id`.
public struct GlassKnob: View {
  public enum Style: Sendable { case compact, card }

  let spec: ParamSpec
  @Binding var value: Double
  let style: Style
  let onActive: (Bool) -> Void
  let onPrecision: (() -> Void)?

  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.isEnabled) private var isEnabled
  @GestureState private var dragging = false
  @State private var startPosition: Double?
  @State private var lastTick = 0
  @State private var lastDetent: String?
  @State private var atLimit = false
  @State private var bump = 0
  @FocusState private var focused: Bool
  @ScaledMetric(relativeTo: .caption) private var descriptorHeight: CGFloat = 36

  /// - Parameters:
  ///   - onActive: true on grab, false on release (drives the console's floating `KnobReadout`). A knob
  ///     that disappears while held (page change, fold) also reports false, so no readout is left behind.
  ///   - onPrecision: long press or the "Fine control" action (the console opens the precision tray).
  ///     `nil` (the default) offers neither: a `.card` knob carries its slider already, and a VoiceOver
  ///     action that does nothing is worse than none.
  public init(
    spec: ParamSpec, value: Binding<Double>, style: Style = .compact,
    onActive: @escaping (Bool) -> Void = { _ in }, onPrecision: (() -> Void)? = nil
  ) {
    self.spec = spec
    self._value = value
    self.style = style
    self.onActive = onActive
    self.onPrecision = onPrecision
  }

  private typealias K = LabMetrics.Knob
  private var hue: LabColor { spec.tint ?? palette.hue(for: spec.id) }
  private var tint: Color { Color(hue) }
  private var position: Double { spec.position(of: value) }
  private var held: Bool { startPosition != nil }
  private var glassBoost: Double { contrast == .increased ? 0.1 : 0 }

  public var body: some View {
    switch style {
    case .compact: compact
    case .card: card
    }
  }

  // MARK: Layouts

  /// Gyre console knob: 84 pt dial, 60 pt puck, uppercase title and value underneath.
  private var compact: some View {
    VStack(spacing: 4) {
      dial(frame: K.compactFrame, arc: K.compactFrame, puck: K.compactPuck)
      Text(LabFormat.uppercasedLatin(spec.title))
        .font(LabFont.knobTitle)
        .tracking(LabFont.knobTitleTracking)
        .foregroundStyle(.white.opacity(LabSemantic.tertiaryAlpha))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
      Text(spec.format.string(value))
        .font(LabFont.knobValue)
        .foregroundStyle(.white)
        .contentTransition(.numericText(value: value))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity)
    .opacity(isEnabled ? 1 : K.dimmedOpacity)
    .accessibilityShowsLargeContentViewer {
      Label("\(spec.title) \(spec.format.string(value))", systemImage: spec.icon)
    }
  }

  /// Orbitals dial card: glyph + title, descriptor, a 104 pt dial with a 31-tick scale, the reading,
  /// and a linear precision slider (not for switches).
  private var card: some View {
    VStack(spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if let glyph = spec.glyph, !glyph.isEmpty { QuantitySymbol(glyph) }
        Text(spec.title).font(LabFont.cardTitle)
      }
      .foregroundStyle(tint)
      .accessibilityHidden(true)
      // The descriptor slot is always reserved, so cards side by side keep their dials level
      // (measured: a card without a descriptor sat 36 pt shorter than its neighbour).
      Text(spec.descriptor)
        .font(LabFont.caption)
        .foregroundStyle(.white.opacity(LabSemantic.secondaryAlpha))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: descriptorHeight, alignment: .top)
        .accessibilityHidden(true)
      ZStack {
        tickScale.frame(width: K.cardDial, height: K.cardDial)
        dial(frame: K.cardDial, arc: K.cardArc, puck: K.cardPuck)
      }
      Text(spec.format.string(value))
        .font(LabFont.dialReading)
        .foregroundStyle(tint)
        .contentTransition(.numericText(value: value))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityHidden(true)
      if !spec.isSwitch {
        PrecisionSlider(spec: spec, value: $value)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 8)
    .padding(.vertical, 14)
    .background(tint.opacity(0.055), in: .rect(cornerRadius: LabMetrics.knobCardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: LabMetrics.knobCardRadius)
        .strokeBorder(tint.opacity(held ? 0.58 : 0.22), lineWidth: 1)
        .labAnimation(LabMotion.grabCard, value: held)
        .allowsHitTesting(false)
    }
    .opacity(isEnabled ? 1 : K.dimmedOpacity)
  }

  // MARK: Dial

  private func dial(frame: CGFloat, arc: CGFloat, puck: CGFloat) -> some View {
    let lo = min(spec.originPosition, position)
    let hi = max(spec.originPosition, position)
    let here = position
    return ZStack {
      KnobArc(from: 0, to: 1, sweep: K.sweep)
        .stroke(.white.opacity(contrast == .increased ? 0.22 : 0.1), style: StrokeStyle(lineWidth: K.stroke, lineCap: .round))
        .frame(width: arc, height: arc)
      KnobArc(from: lo, to: hi, sweep: K.sweep)
        .stroke(tint, style: StrokeStyle(lineWidth: K.stroke, lineCap: .round))
        .shadow(color: tint.opacity(0.8), radius: 4)
        .frame(width: arc, height: arc)
      ForEach(Array(detentDots.enumerated()), id: \.offset) { _, p in
        let on = abs(p - here) < 0.004  // the dot the value sits on lights up
        Circle()
          .fill(.white.opacity(on ? 1 : 0.45))
          .frame(width: K.dot, height: K.dot)
          .offset(y: -(arc / 2 - 1))
          .rotationEffect(.degrees(-K.sweep / 2 + K.sweep * p))
      }
      ZStack {
        Image(systemName: spec.icon)
          .font(.system(size: puck * 0.27, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .symbolEffect(.bounce, value: bump)
          .symbolEffectsRemoved(reduceMotion)
        Capsule()
          .fill(tint)
          .frame(width: 3.5, height: puck / 6)
          .shadow(color: tint, radius: 3)
          .offset(y: -(puck / 2 - puck / 7.5))
          .rotationEffect(.degrees(-K.sweep / 2 + K.sweep * position))
      }
      .frame(width: puck, height: puck)
      .glassEffect(
        .regular.tint(tint.opacity((held ? K.heldTint : (style == .card ? K.cardTint : K.idleTint)) + glassBoost)).interactive(),
        in: .circle)
      .scaleEffect(held && !reduceMotion ? K.heldScale : 1)
      .labAnimation(LabMotion.grab, value: held)
    }
    .frame(width: frame, height: frame)
    .contentShape(Circle())
    .gesture(turn)
    .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.4, maximumDistance: 4).onEnded { _ in
        guard !spec.isSwitch, let onPrecision else { return }
        haptics?.play(.grab)
        onPrecision()
      })
    .onChange(of: dragging) { _, isDragging in if !isDragging { finish() } }
    .onDisappear {
      // Removed mid-drag (a page change by another finger, a fold): the gesture never ends here, so
      // release now, or the console keeps showing this knob's readout.
      if startPosition != nil {
        startPosition = nil
        onActive(false)
      }
    }
    .focusable()
    .focused($focused)
    .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
      let up = press.key == .upArrow || press.key == .rightArrow
      nudge(up ? 1 : -1, coarse: press.modifiers.contains(.shift), fromKeyboard: true)
      return .handled
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spec.accessibilityLabel)
    .accessibilityValue(spec.accessibilityValue(value))
    .accessibilityHint(spec.hint.isEmpty ? "Swipe up or down to adjust." : "\(spec.hint) Swipe up or down to adjust.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: nudge(1)
      case .decrement: nudge(-1)
      @unknown default: break
      }
    }
    .accessibilityAction(named: "Reset to default") { reset() }
    .modifier(FineControlAction(action: spec.isSwitch ? nil : onPrecision))
    .accessibilityIdentifier("knob-\(spec.id)")
  }

  /// Positions of the dots: every labelled detent, and every position of a rotary switch.
  private var detentDots: [Double] {
    if spec.isSwitch, spec.switchCount > 1 {
      return (0..<spec.switchCount).map { spec.position(of: spec.range.lowerBound + Double($0) * spec.step) }
    }
    return spec.detents.map { spec.position(of: $0.value) }
  }

  /// Orbitals' 31-tick scale (GlassControls.swift:129-144): every 5th major, lit up to the value.
  private var tickScale: some View {
    let p = position
    let c = tint
    return Canvas { context, size in
      let centre = CGPoint(x: size.width / 2, y: size.height / 2)
      for index in 0...30 {
        let angle = (-135 + Double(index) * 9) * .pi / 180
        let major = index.isMultiple(of: 5)
        let outer = size.width / 2 - 2
        let inner = outer - (major ? 7 : 3)
        var path = Path()
        path.move(to: CGPoint(x: centre.x + sin(angle) * inner, y: centre.y - cos(angle) * inner))
        path.addLine(to: CGPoint(x: centre.x + sin(angle) * outer, y: centre.y - cos(angle) * outer))
        context.stroke(path, with: .color(c.opacity(Double(index) / 30 <= p + 1e-9 ? 0.8 : 0.22)), lineWidth: major ? 1.6 : 1)
      }
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }

  // MARK: Interaction

  private var turn: some Gesture {
    DragGesture(minimumDistance: 2)
      .updating($dragging) { _, state, _ in state = true }
      .onChanged { g in
        if startPosition == nil {
          startPosition = position
          lastTick = tick(position)
          lastDetent = spec.detent(at: value)?.label
          atLimit = false
          focused = true
          onActive(true)
          haptics?.play(.grab)
        }
        let raw = (startPosition ?? position) + Double(g.translation.width - g.translation.height) / K.travel
        let p = clamped(raw, 0, 1)
        // End stop: one boundary pulse when the drag first runs into a limit.
        let limited = raw < 0 || raw > 1
        if limited && !atLimit { haptics?.play(.boundary) }
        atLimit = limited
        if spec.isSwitch {
          let next = spec.value(at: p)
          if next != value {
            value = next
            if voiceOver { haptics?.selection() } else { haptics?.play(.switchClick) }
            bump += 1
          }
          return
        }
        if let d = spec.capture(near: p, radius: K.capture) {
          if lastDetent != d.label {
            lastDetent = d.label
            haptics?.play(.detent)
            bump += 1
          }
          if value != d.value { value = d.value }
          return
        }
        lastDetent = nil
        let next = spec.value(at: p)
        guard next != value else { return }  // feedback only for real changes (Orbitals setValue)
        value = next
        let t = tick(p)
        if t != lastTick {
          lastTick = t
          if voiceOver { haptics?.selection() } else { haptics?.play(.tick) }
        }
      }
  }

  private func tick(_ p: Double) -> Int { Int((p * Double(K.ticksPerSweep)).rounded(.down)) }

  /// Releases even when a scroll view or system gesture cancels the drag (Orbitals GlassControls.swift:120-123).
  private func finish() {
    guard startPosition != nil else { return }
    startPosition = nil
    haptics?.play(.release)
    onActive(false)
  }

  private func nudge(_ direction: Int, coarse: Bool = false, fromKeyboard: Bool = false) {
    let next = spec.nudged(value, by: direction, coarse: coarse)
    guard next != value else {
      haptics?.play(.boundary)
      return
    }
    value = next
    if spec.isSwitch || spec.detent(at: next) == nil {
      if fromKeyboard && !voiceOver { haptics?.play(spec.isSwitch ? .switchClick : .tick) } else { haptics?.selection() }
    } else {
      haptics?.play(.detent)
    }
    bump += 1
  }

  private func reset() {
    withLabAnimation(LabMotion.reset, reduceMotion: reduceMotion) { value = spec.defaultValue }
    haptics?.play(.reset)
    bump += 1
  }
}

/// Adds the "Fine control" named action only to knobs that have a precision control to open.
private struct FineControlAction: ViewModifier {
  let action: (() -> Void)?
  func body(content: Content) -> some View {
    if let action {
      content.accessibilityAction(named: "Fine control", action)
    } else {
      content
    }
  }
}

/// A native slider for exact values (§3.4), over **position space** so log knobs give each decade
/// equal travel; quantised through the spec; feedback only on real changes.
public struct PrecisionSlider: View {
  let spec: ParamSpec
  @Binding var value: Double
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @State private var lastTick = 0

  public init(spec: ParamSpec, value: Binding<Double>) {
    self.spec = spec
    self._value = value
  }

  public var body: some View {
    Slider(
      value: Binding(
        get: { spec.position(of: value) },
        set: { p in
          let next = spec.value(at: p)
          guard next != value else { return }
          value = next
          let t = Int((spec.position(of: next) * Double(LabMetrics.Knob.ticksPerSweep)).rounded(.down))
          if voiceOver {
            haptics?.selection()
          } else if t != lastTick {
            lastTick = t
            haptics?.play(.tick)
          }
        }),
      in: 0...1
    ) { editing in
      haptics?.play(editing ? .grab : .release)
    }
    .tint(Color(spec.tint ?? palette.hue(for: spec.id)))
    .frame(minHeight: LabMetrics.minHit)
    .accessibilityLabel("\(spec.title), linear control")
    .accessibilityValue(spec.accessibilityValue(value))
    .accessibilityIdentifier("knob-\(spec.id)-slider")
  }
}

/// An arc clockwise from the knob's lowest point, by fractions of its sweep (Gyre GlassKnob.swift:160-188).
/// `nonisolated`: LabKitUI defaults to MainActor, and Shape's requirements are nonisolated.
nonisolated public struct KnobArc: Shape {
  public var from: Double
  public var to: Double
  public var sweep: Double

  public init(from: Double, to: Double, sweep: Double = LabMetrics.Knob.sweep) {
    self.from = from
    self.to = to
    self.sweep = sweep
  }

  public var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(from, to) }
    set {
      from = newValue.first
      to = newValue.second
    }
  }

  public func path(in rect: CGRect) -> Path {
    var path = Path()
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let r = min(rect.width, rect.height) / 2 - LabMetrics.Knob.arcInset
    let start = -sweep / 2 + sweep * from
    let end = -sweep / 2 + sweep * to
    let n = max(2, Int(abs(end - start) / 4))
    for i in 0...n {
      let deg = start + (end - start) * Double(i) / Double(n)
      let a = deg * .pi / 180
      let p = CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r)
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    return path
  }
}

/// The floating glass card naming what you're turning and what it does (Gyre Console.swift:319-353).
/// Glass chrome, so SF Pro digits. Hidden from VoiceOver: the knob already speaks.
public struct KnobReadout: View {
  let spec: ParamSpec
  let value: Double
  @Environment(\.labPalette) private var palette

  public init(spec: ParamSpec, value: Double) {
    self.spec = spec
    self.value = value
  }

  public var body: some View {
    let tint = Color(spec.tint ?? palette.hue(for: spec.id))
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: spec.icon).foregroundStyle(tint)
        if let glyph = spec.glyph, !glyph.isEmpty {
          QuantitySymbol(glyph, font: LabFont.legendGlyph).foregroundStyle(tint)
        }
        Text(spec.title).font(LabFont.readoutCardTitle).lineLimit(1)
        Spacer(minLength: 8)
        if let d = shownDetent(spec, value) {
          Text(d.label).font(.caption.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
        }
        Text(spec.format.string(value))
          .font(LabFont.readoutCardValue)
          .contentTransition(.numericText(value: value))
          .lineLimit(1)
      }
      if !spec.hint.isEmpty {
        Text(spec.hint)
          .font(LabFont.hint)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 420)
    .glassEffect(.regular.tint(Color(palette.ground.stage, opacity: LabMetrics.floatingCardScrim)), in: .rect(cornerRadius: LabMetrics.glassCardRadius))
    .padding(.horizontal, 4)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Precision for a compact knob (long press): the readout card made interactive, with a slider in
/// position space, ± steps that nudge (stopping on detents), the hint and a Done button.
public struct KnobPrecisionTray: View {
  let spec: ParamSpec
  @Binding var value: Double
  let onDone: () -> Void
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics

  public init(spec: ParamSpec, value: Binding<Double>, onDone: @escaping () -> Void) {
    self.spec = spec
    self._value = value
    self.onDone = onDone
  }

  public var body: some View {
    let tint = Color(spec.tint ?? palette.hue(for: spec.id))
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(spec.title, systemImage: spec.icon).font(LabFont.readoutCardTitle).foregroundStyle(tint)
        Spacer(minLength: 8)
        if let d = shownDetent(spec, value) {
          Text(d.label).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
        Text(spec.format.string(value))
          .font(LabFont.readoutCardValue)
          .contentTransition(.numericText(value: value))
      }
      .accessibilityElement(children: .combine)
      HStack(spacing: 10) {
        step(-1)
        PrecisionSlider(spec: spec, value: $value)
        step(1)
      }
      HStack(alignment: .firstTextBaseline) {
        Text(spec.hint)
          .font(LabFont.hint)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button {
          haptics?.play(.tap)
          onDone()
        } label: {
          Text("Done").foregroundStyle(.white)
        }
        .buttonStyle(.glass)
        .font(LabFont.button)
        .accessibilityIdentifier("knob-\(spec.id)-precision-done")
      }
    }
    .padding(14)
    .frame(maxWidth: 460)
    .glassEffect(.regular.tint(Color(palette.ground.stage, opacity: LabMetrics.floatingCardScrim)).interactive(), in: .rect(cornerRadius: LabMetrics.glassCardRadius))
    .padding(.horizontal, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knob-\(spec.id)-precision")
  }

  private func step(_ d: Int) -> some View {
    Button {
      let next = spec.nudged(value, by: d)
      if next == value {
        haptics?.play(.boundary)
      } else {
        value = next
        if spec.detent(at: next) != nil { haptics?.play(.detent) } else { haptics?.play(.tick) }
      }
    } label: {
      Image(systemName: d < 0 ? "minus" : "plus")
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .frame(minWidth: LabMetrics.minHit, minHeight: LabMetrics.minHit)
    .accessibilityLabel(d < 0 ? "Decrease \(spec.title)" : "Increase \(spec.title)")
  }
}
/// The labelled detent the value sits on, unless its label just repeats the value ("Off" · "Off").
func shownDetent(_ spec: ParamSpec, _ value: Double) -> Detent? {
  guard !spec.isSwitch, let d = spec.detent(at: value), d.label != spec.format.string(value) else { return nil }
  return d
}
#endif
