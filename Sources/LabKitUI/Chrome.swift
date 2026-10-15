#if os(iOS)
import LabKitCore
import LabKitFeedback
import SwiftUI

// Glass chrome over the stage (labkit-from-orbitals-spectra.md §3.8): top bar, toolbar glyphs,
// telemetry card and banners. All of it is capped at `.accessibility1` and offers the Large Content Viewer.

/// Telemetry card on the left, one glass capsule of glyphs and menus on the right (Gyre TopBar.swift:5-41).
/// When both don't fit (accessibility sizes) the icon group moves above the card (`ViewThatFits`).
/// The fit is judged on the card's collapsed width: an expanded `TelemetryCard` grows downwards in
/// the space left of the group, so tapping it never moves the group (measured: judging the expanded
/// width threw the group above the card on every tap).
/// Put `.padding(.horizontal, 16).padding(.top, 6)` around it (`LabMetrics.Screen`).
public struct LabTopBar<Card: View, Actions: View>: View {
  let card: Card
  let actions: Actions
  public init(@ViewBuilder card: () -> Card, @ViewBuilder actions: () -> Actions) {
    self.card = card()
    self.actions = actions()
  }

  public var body: some View {
    GlassEffectContainer(spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 10) {
          card.frame(maxWidth: .infinity, alignment: .leading)
          group
        }
        VStack(alignment: .trailing, spacing: 8) {
          group
          card.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .dynamicTypeSize(...LabMetrics.stageChromeTypeCap)
  }

  private var group: some View {
    HStack(spacing: 0) { actions }
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .glassEffect(.regular.interactive(), in: .capsule)
      .fixedSize()
  }
}

/// A 42 × 44 toolbar glyph for buttons and `Menu` labels in `LabTopBar`. `title` feeds the Large
/// Content Viewer (capped chrome); give the enclosing button or menu the same accessibility label.
/// `tint` colours the glyph (Rheo's Material glyph wears the current material's data hue).
public struct ToolbarGlyph: View {
  let icon: String
  let title: String
  let tint: LabColor?
  public init(_ icon: String, title: String, tint: LabColor? = nil) {
    self.icon = icon
    self.title = title
    self.tint = tint
  }
  public var body: some View {
    Image(systemName: icon)
      .font(LabFont.toolbarIcon)
      .foregroundStyle(tint.map { Color($0) } ?? .white)
      .frame(width: LabMetrics.toolbarIcon.width, height: LabMetrics.toolbarIcon.height)
      .contentShape(.rect)
      .contentTransition(.symbolEffect(.replace))
      .accessibilityShowsLargeContentViewer { Label(title, systemImage: icon) }
  }
}

/// One row of the expanded telemetry card, with its provenance (simulated values draw in orange).
nonisolated public struct TelemetryRow: Identifiable, Sendable, Hashable {
  public var id: String { title }
  public var title: String
  public var icon: String
  public var value: String
  public var provenance: Provenance
  public init(_ title: String, icon: String, value: String, provenance: Provenance) {
    self.title = title
    self.icon = icon
    self.value = value
    self.provenance = provenance
  }
}

/// Collapsed: the headline (usually `TelemetryHeadline`). Tap: a grid of `TelemetryRow`s, simulated
/// values in the simulated orange, and an orange note saying how to drive the stand-in (Gyre TopBar.swift:97-184).
/// Rows come from a 10 Hz telemetry struct, never per-frame state.
public struct TelemetryCard<Headline: View>: View {
  @Binding var expanded: Bool
  let rows: [TelemetryRow]
  let simulatedNote: String?
  let headline: Headline
  @Environment(\.labHaptics) private var haptics
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityDifferentiateWithoutColor) private var noColourOnly

  public init(
    expanded: Binding<Bool>, rows: [TelemetryRow], simulatedNote: String? = nil, @ViewBuilder headline: () -> Headline
  ) {
    self._expanded = expanded
    self.rows = rows
    self.simulatedNote = simulatedNote
    self.headline = headline()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      headline
      if expanded {
        // No ideal width of its own: the rows take the width the card is given instead of widening it,
        // so `LabTopBar` lays out by the collapsed card.
        ZeroIdealWidth {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
          ForEach(rows) { r in
            GridRow {
              Label(r.title, systemImage: r.icon).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
              Text(r.provenance == .simulated && noColourOnly ? "\(r.value) (simulated)" : r.value)
                .foregroundStyle(r.provenance == .simulated ? Color(LabSemantic.simulated) : .primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
          }
          if let simulatedNote, rows.contains(where: { $0.provenance == .simulated }) {
            Text(simulatedNote)
              .font(.caption2)
              .foregroundStyle(Color(LabSemantic.simulated))
              .fixedSize(horizontal: false, vertical: true)
              .gridCellColumns(2)
          }
        }
        .font(.caption.monospacedDigit())
        }
        .transition(LabMotion.pageTransition(reduceMotion: reduceMotion))
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: LabMetrics.glassCardRadius))
    .contentShape(.rect(cornerRadius: LabMetrics.glassCardRadius))
    .onTapGesture { toggle() }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(expanded ? "Hides sensor readings" : "Shows sensor readings")
    .accessibilityAction { toggle() }
    .accessibilityIdentifier("telemetry-card")
  }

  private func toggle() {
    withLabAnimation(LabMotion.expand, reduceMotion: reduceMotion) { expanded.toggle() }
    haptics?.play(.soft)
  }
}

/// Reports zero width when asked for its ideal or maximum size (`ViewThatFits` measures with an
/// unspecified or infinite width), and lays its content out normally inside any finite width. Height is
/// then measured at a typical 200 pt.
nonisolated struct ZeroIdealWidth: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let s = subviews.first else { return .zero }
    guard let width = proposal.width, width.isFinite else {
      return CGSize(width: 0, height: s.sizeThatFits(ProposedViewSize(width: 200, height: proposal.height)).height)
    }
    return s.sizeThatFits(proposal)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

/// The standard collapsed telemetry: an icon in the signature (spinning while the simulation runs,
/// unless Reduce Motion), the hero quantity, a subline with two secondary quantities joined by " · ",
/// and an optional time chip ("×0.25") in the Time hue × 0.35 (§3.8).
public struct TelemetryHeadline: View {
  /// How the icon shows that the simulation is running. `.rotate` suits a rotor (Gyre's gyroscope);
  /// a symbol with a natural "up", such as Rheo's drop, reads better with `.breathe` (measured: a
  /// rotating `drop.fill` lies on its side for half of every turn).
  public enum Activity: Sendable, Hashable { case rotate, breathe, pulse }

  let icon: String
  let spins: Bool
  let activity: Activity
  let headline: String
  let subline: String
  let chip: String?
  @Environment(\.labPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `spins`: the simulation is running (the effect plays unless Reduce Motion is on).
  public init(
    icon: String, spins: Bool = false, activity: Activity = .rotate, headline: String, subline: String,
    chip: String? = nil
  ) {
    self.icon = icon
    self.spins = spins
    self.activity = activity
    self.headline = headline
    self.subline = subline
    self.chip = chip
  }

  public var body: some View {
    HStack(spacing: 10) {
      activityIcon
        .font(.title3)
        .foregroundStyle(Color(palette.signature))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        // The time chip rides on the headline row, which is shorter than the subline, so a chip never
        // widens the card (measured: on the subline it pushed Rheo's card to 233 pt, past the 212 pt
        // beside the icon group, and the top bar jumped to its stacked layout whenever time ≠ 1).
        HStack(spacing: 6) {
          Text(headline)
            .font(LabFont.telemetryHeadline)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(LabFormat.spoken(headline))
          if let chip {
            Text(chip)
              .font(LabFont.timeChip)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color(palette.hue(for: "time"), opacity: 0.35), in: .capsule)
              .lineLimit(1)
              .fixedSize()
              .accessibilityLabel("Time \(LabFormat.spoken(chip))")
          }
        }
        Text(subline)
          .font(LabFont.telemetrySubline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .accessibilityLabel(LabFormat.spoken(subline))
      }
    }
  }

  @ViewBuilder private var activityIcon: some View {
    let active = spins && !reduceMotion
    switch activity {
    case .rotate: Image(systemName: icon).symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: active)
    case .breathe: Image(systemName: icon).symbolEffect(.breathe, options: .repeat(.continuous), isActive: active)
    case .pulse: Image(systemName: icon).symbolEffect(.pulse, options: .repeat(.continuous), isActive: active)
    }
  }
}

/// A glass capsule with one human sentence (Gyre ARBanner; spectra-lab toast): sensor status,
/// post-experiment notes, coaching. Posts the text to VoiceOver when it appears or changes.
public struct StatusBanner: View {
  let text: String
  let icon: String
  @Environment(\.labPalette) private var palette
  public init(_ text: String, icon: String = "info.circle") {
    self.text = text
    self.icon = icon
  }
  public var body: some View {
    Label(text, systemImage: icon)
      .font(LabFont.banner)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .glassEffect(.regular.tint(Color(palette.ground.stage, opacity: LabMetrics.floatingCardScrim)), in: .capsule)
      .contentTransition(.opacity)
      .allowsHitTesting(false)
      .dynamicTypeSize(...LabMetrics.stageChromeTypeCap)
      .accessibilityAddTraits(.updatesFrequently)
      .onAppear { AccessibilityNotification.Announcement(text).post() }
      .onChange(of: text) { _, t in AccessibilityNotification.Announcement(t).post() }
  }
}

/// A slot for a timed `StatusBanner`: shows `message` for `duration` seconds (spectra-lab's 6.5 s toast),
/// then clears it; a new message restarts the timer. Place it where the banner belongs, usually under
/// the top bar (and the shelf) in the stage overlay, so it never covers the chrome it follows.
public struct StatusBannerHost: View {
  @Binding var message: String?
  let icon: String
  let duration: TimeInterval
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(_ message: Binding<String?>, icon: String = "info.circle", duration: TimeInterval = 6.5) {
    self._message = message
    self.icon = icon
    self.duration = duration
  }

  public var body: some View {
    ZStack {
      if let message {
        StatusBanner(message, icon: icon)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
      }
    }
    .labAnimation(LabMotion.action, value: message)
    .task(id: message) {
      guard message != nil else { return }
      try? await Task.sleep(for: .seconds(duration))
      if !Task.isCancelled { message = nil }
    }
  }
}

extension View {
  /// Overlays a `StatusBannerHost` at the top, `topInset` below this view's top edge. Over a stage with
  /// a top bar, pass the bar's height plus 8 (or place a `StatusBannerHost` under the bar yourself).
  public func statusBanner(
    _ message: Binding<String?>, icon: String = "info.circle", duration: TimeInterval = 6.5,
    topInset: CGFloat = LabMetrics.Screen.bannerTop
  ) -> some View {
    overlay(alignment: .top) {
      StatusBannerHost(message, icon: icon, duration: duration)
        .padding(.horizontal, LabMetrics.gutter)
        .padding(.top, topInset)
    }
  }
}
#endif
