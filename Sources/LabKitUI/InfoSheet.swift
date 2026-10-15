#if os(iOS)
import LabKitCore
import LabKitFeedback
import SwiftUI
import UIKit

// The "How <App> works" sheet (labkit-from-orbitals-spectra.md §3.9): Gyre's presentation (medium and
// large detents, the stage live and touchable above the half sheet) holding Orbitals' numbered panels,
// in a fixed section order: 01 What you're looking at · 02 Touch · 03 What you're seeing · 04 Knobs ·
// 05 Experiments · 06 What's real and what's illustrative · 07 Sensors in play · 08 Sound & feel ·
// 09 Sources & licences.

/// A `ScrollView` of `InstrumentPanel`s on the ground's background, with an inline title, a drag
/// indicator and a "Done" button tinted `signatureDeep` (iOS 27 draws it as a filled circle with a
/// white checkmark). Opens at `.medium` with background interaction, so the simulation stays live.
public struct LabInfoSheet<Content: View>: View {
  let title: String
  let content: Content
  @State private var detent: PresentationDetent
  @Environment(\.dismiss) private var dismiss
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics

  public init(title: String, startLarge: Bool = false, @ViewBuilder content: () -> Content) {
    self.title = title
    self._detent = State(initialValue: startLarge ? .large : .medium)
    self.content = content()
  }

  public var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) { content }
          .font(LabFont.body)
          .foregroundStyle(.white.opacity(LabSemantic.bodyAlpha))
          .padding(16)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.visible)
      .background(Color(palette.ground.background).ignoresSafeArea())
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") {
            haptics?.play(.tap)
            dismiss()
          }
          .tint(Color(palette.signatureDeep))
          .accessibilityIdentifier("info-done")
        }
      }
      .accessibilityIdentifier("info-scroll")
    }
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    .presentationDragIndicator(.visible)
    .presentationBackground(Color(palette.ground.background))
  }
}

/// Field note (Orbitals TelemetryView.swift:184-189): the title in the signature, an optional
/// provenance badge, then the paragraph. One combined element. Pattern: what you do → what happens →
/// why, in one sentence of physics → the caveat.
public struct FieldNote: View {
  let title: String
  let text: String
  let provenance: Provenance?
  @Environment(\.labPalette) private var palette

  public init(_ title: String, _ text: String, provenance: Provenance? = nil) {
    self.title = title
    self.text = text
    self.provenance = provenance
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      FlowLayout(spacing: 8, lineSpacing: 4) {
        Text(title).foregroundStyle(Color(palette.signature)).fontWeight(.medium)
        if let provenance { ProvenanceBadge(provenance) }
      }
      Text(text)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Icon, bold title and a secondary paragraph (Gyre `info(symbol, title, body)`, InfoSheet.swift:97-106).
public struct InfoRow: View {
  let icon: String
  let title: String
  let text: String
  @Environment(\.labPalette) private var palette
  public init(_ icon: String, _ title: String, _ text: String) {
    self.icon = icon
    self.title = title
    self.text = text
  }
  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(Color(palette.signature))
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        Text(text).font(LabFont.body).foregroundStyle(.white.opacity(LabSemantic.secondaryAlpha))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// A colour legend row: a serif-italic glyph in the **same encoded token** the renderer converts to
/// linear (so legend and scene agree; Gyre's legend used linear numbers and drew darker swatches).
public struct LegendRow: View {
  let colour: LabColor
  let glyph: String
  let text: String
  public init(_ colour: LabColor, glyph: String, _ text: String) {
    self.colour = colour
    self.glyph = glyph
    self.text = text
  }
  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(glyph).font(LabFont.legendGlyph).foregroundStyle(Color(colour)).frame(width: 22).accessibilityHidden(true)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A live sensor row for panel 07, its value coloured by provenance (simulated values in orange).
public struct SensorRow: View {
  let icon: String
  let name: String
  let value: String
  let provenance: Provenance
  @Environment(\.labPalette) private var palette
  public init(_ icon: String, _ name: String, _ value: String, provenance: Provenance = .live) {
    self.icon = icon
    self.name = name
    self.value = value
    self.provenance = provenance
  }
  public init(_ row: TelemetryRow) { self.init(row.icon, row.title, row.value, provenance: row.provenance) }
  public var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline) {
        Label(name, systemImage: icon).foregroundStyle(.white)
        Spacer(minLength: 8)
        reading
      }
      VStack(alignment: .leading, spacing: 4) {
        Label(name, systemImage: icon).foregroundStyle(.white)
        reading
      }
    }
    .frame(minHeight: LabMetrics.minHit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(name)
    .accessibilityValue("\(LabFormat.spoken(value)), \(provenance.badge)")
  }
  private var reading: some View {
    HStack(spacing: 8) {
      Text(value)
        .font(.system(.subheadline, design: .monospaced).monospacedDigit())
        .foregroundStyle(Color(provenance == .simulated ? LabSemantic.simulated : LabSemantic.value))
      ProvenanceBadge(provenance)
    }
  }
}

/// Panel 04 "Knobs", generated from the specs (Gyre InfoSheet.swift:47-59): icon and title in the
/// knob's hue, glyph, provenance badge, the detail paragraph and the labelled detents.
public struct KnobDetailRows: View {
  let groups: [(title: String?, specs: [ParamSpec])]
  @Environment(\.labPalette) private var palette

  public init(_ specs: [ParamSpec]) { self.groups = [(nil, specs)] }

  /// Grouped by console page, with "Fluid page" sub-headers named from the live page titles.
  public init(pages: [ConsolePage], store: ParamStore) {
    self.groups = pages.map { p in ("\(p.title) page", p.knobs.compactMap { store.specs[$0] }) }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        if let title = group.title {
          Text(LabFormat.uppercasedLatin(title))
            .font(LabFont.readoutLabel)
            .tracking(1)
            .foregroundStyle(Color(palette.ground.muted))
            .accessibilityAddTraits(.isHeader)
        }
        ForEach(group.specs) { spec in row(spec) }
      }
    }
  }

  private func row(_ spec: ParamSpec) -> some View {
    let hue = Color(spec.tint ?? palette.hue(for: spec.id))
    return VStack(alignment: .leading, spacing: 5) {
      FlowLayout(spacing: 8, lineSpacing: 4) {
        Label(spec.title, systemImage: spec.icon).font(.headline).foregroundStyle(hue)
        if let glyph = spec.glyph, !glyph.isEmpty {
          QuantitySymbol(glyph, font: LabFont.legendGlyph).foregroundStyle(hue)
        }
        ProvenanceBadge(spec.provenance)
      }
      if !spec.detail.isEmpty || !spec.hint.isEmpty {
        Text(spec.detail.isEmpty ? spec.hint : spec.detail)
          .font(LabFont.body)
          .foregroundStyle(.white.opacity(LabSemantic.bodyAlpha))
          .fixedSize(horizontal: false, vertical: true)
      }
      if !spec.isSwitch, !spec.detents.isEmpty {
        // "Earth 1.00 g", but "Off", not "Off Off", when the format already says the label.
        Text(spec.detents.map { detentLine($0, spec) }.joined(separator: LabFormat.separator))
          .font(LabFont.readoutDetail)
          .foregroundStyle(Color(palette.ground.dim))
          .fixedSize(horizontal: false, vertical: true)
      } else if case .labels(let names) = spec.format {
        Text(names.joined(separator: LabFormat.separator))
          .font(LabFont.readoutDetail)
          .foregroundStyle(Color(palette.ground.dim))
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func detentLine(_ d: Detent, _ spec: ParamSpec) -> String {
    let shown = spec.format.string(d.value)
    return shown == d.label ? d.label : "\(d.label) \(shown)"
  }
}

/// A source the user can open: "Publisher · Title", an optional licence line, and ↗ (Tether
/// MethodologyView.swift:85-98). Opens in Safari.
public struct SourceLink: View {
  let citation: Citation
  @Environment(\.labPalette) private var palette
  public init(_ citation: Citation) { self.citation = citation }
  public var body: some View {
    Link(destination: citation.url) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(citation.label).font(.subheadline).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          let meta = [citation.licence.isEmpty ? nil : "Licence: \(citation.licence)", "Checked \(citation.checked)"]
            .compactMap { $0 }.joined(separator: LabFormat.separator)
          Text(meta).font(.caption).foregroundStyle(Color(palette.ground.muted))
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right").font(.caption).accessibilityHidden(true)
      }
      .frame(minHeight: LabMetrics.minHit)
      .contentShape(.rect)
    }
    .tint(Color(palette.signature))
    .accessibilityHint("Opens in Safari")
  }
}

/// Panel 09's body: the source links, then the method footnote and the privacy sentence.
public struct SourceList: View {
  let citations: [Citation]
  let method: String?
  let privacy: String?
  @Environment(\.labPalette) private var palette
  public init(_ citations: [Citation], method: String? = nil, privacy: String? = nil) {
    self.citations = citations
    self.method = method
    self.privacy = privacy
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(citations) { SourceLink($0) }
      ForEach([method, privacy].compactMap { $0 }, id: \.self) { line in
        Text(line)
          .font(.footnote)
          .foregroundStyle(Color(palette.ground.muted))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
      }
    }
  }
}

// MARK: - Settings

/// Panel 08 "Sound & feel" (§3.9, §5.2): Haptics, Strength (0.2…1, step 0.05; release plays a detent
/// at the new strength), "Feel a detent", the continuous Feel switch and Sound. Strength and Feel are
/// disabled while haptics are off. Wire the bindings to the engine (or use `init(engine:…)`).
public struct FeedbackSettings: View {
  @Binding var haptics: Bool
  @Binding var strength: Double
  let feel: Binding<Bool>?
  @Binding var sound: Bool
  let feelTitle: String
  let feelExplanation: String
  let soundExplanation: String
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var engine

  public init(
    haptics: Binding<Bool>, strength: Binding<Double>, feel: Binding<Bool>? = nil, sound: Binding<Bool>,
    feelTitle: String = "Feel the simulation", feelExplanation: String = "", soundExplanation: String
  ) {
    self._haptics = haptics
    self._strength = strength
    self.feel = feel
    self._sound = sound
    self.feelTitle = feelTitle
    self.feelExplanation = feelExplanation
    self.soundExplanation = soundExplanation
  }

  /// Binds Haptics, Strength and Feel straight to the engine (which persists them itself).
  public init(
    engine: HapticEngine, sound: Binding<Bool>, feelTitle: String = "Feel the simulation", feelExplanation: String,
    soundExplanation: String
  ) {
    self.init(
      haptics: Binding(get: { engine.enabled }, set: { engine.enabled = $0 }),
      strength: Binding(get: { Double(engine.strength) }, set: { engine.strength = Float($0) }),
      feel: Binding(get: { engine.humEnabled }, set: { engine.humEnabled = $0 }),
      sound: sound, feelTitle: feelTitle, feelExplanation: feelExplanation, soundExplanation: soundExplanation)
  }

  /// Binds every control to the app's `LabFeedback` (haptics settings and the persisted Sound toggle).
  public init(
    feedback: LabFeedback, feelTitle: String = "Feel the simulation", feelExplanation: String,
    soundExplanation: String
  ) {
    self.init(
      engine: feedback.haptics, sound: Binding(get: { feedback.sound }, set: { feedback.sound = $0 }),
      feelTitle: feelTitle, feelExplanation: feelExplanation, soundExplanation: soundExplanation)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      GlassToggle(
        "Haptics", isOn: $haptics, icon: "hand.tap.fill",
        note: "Taps, knob detents and end stops. Haptics need supported hardware and follow device settings.")
      .accessibilityIdentifier("settings-haptics")
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Label("Strength", systemImage: "dial.medium").symbolRenderingMode(.hierarchical)
          Spacer()
          Text(LabFormat.fixed(strength, precision: 2))
            .font(.system(.subheadline, design: .monospaced).monospacedDigit())
            .foregroundStyle(Color(LabSemantic.value))
            .accessibilityHidden(true)
        }
        Slider(value: $strength, in: 0.2...1, step: 0.05) { editing in
          if !editing {
            engine?.strength = Float(strength)
            engine?.play(.detent)
          }
        }
        .tint(Color(palette.signature))
        .frame(minHeight: LabMetrics.minHit)
        .accessibilityLabel("Haptic strength")
        .accessibilityValue("\(Int((strength * 100).rounded())) percent")
        .accessibilityIdentifier("settings-strength")
      }
      .disabled(!haptics)
      .opacity(haptics ? 1 : 0.5)
      Button {
        engine?.play(.boundary)
      } label: {
        Label("Feel a detent", systemImage: "hand.tap").font(LabFont.button).foregroundStyle(.white)
      }
      .buttonStyle(.glass)
      .frame(minHeight: LabMetrics.minHit)
      .disabled(!haptics)
      .accessibilityIdentifier("settings-feel-detent")
      if let feel {
        GlassToggle(feelTitle, isOn: feel, icon: "waveform.path", note: feelExplanation.isEmpty ? nil : feelExplanation)
          .disabled(!haptics)
          .accessibilityIdentifier("settings-feel")
      }
      GlassToggle("Sound", isOn: $sound, icon: "speaker.wave.2.fill", note: soundExplanation)
        .accessibilityIdentifier("settings-sound")
    }
  }
}

/// A sensor the user refused, or that this device lacks: says so, says what keeps working, and offers
/// Settings (Orbitals OrbitARScreen). "Rheo can't hear the room. Allow the microphone in Settings to let
/// sound shake the fluid. Everything else keeps working."
public struct PermissionGate: View {
  let title: String
  let icon: String
  let message: String
  let canOpenSettings: Bool
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics

  public init(_ title: String, icon: String, message: String, canOpenSettings: Bool) {
    self.title = title
    self.icon = icon
    self.message = message
    self.canOpenSettings = canOpenSettings
  }

  public var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: icon)
    } description: {
      Text(message)
    } actions: {
      if canOpenSettings {
        Button {
          haptics?.play(.tap)
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
          Text("Open Settings").font(LabFont.button).foregroundStyle(Color(palette.onSignature))
        }
        .buttonStyle(.glassProminent)
        .tint(Color(palette.signature))
        .accessibilityIdentifier("permission-open-settings")
      }
    }
  }
}
#endif
