#if os(iOS)
import LabKitCore
import LabKitFeedback
import SwiftUI

// Choosing things (labkit-from-orbitals-spectra.md §3.5–§3.6): a mode of the instrument is a rotary
// switch; a *thing* (a material, a sample) is chips or tiles, never a menu that hides the active choice.

/// A native switch whose **whole row** is the hit target (Blockdown's lesson; Orbitals
/// GlassControls.swift:289-313). The system switch stays as the visual, tinted `signatureDeep` so its
/// white thumb reads. Plays `selection()` on a real change.
public struct GlassToggle: View {
  let title: String
  @Binding var isOn: Bool
  let icon: String
  let note: String?
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics
  @Environment(\.isEnabled) private var isEnabled

  public init(_ title: String, isOn: Binding<Bool>, icon: String, note: String? = nil) {
    self.title = title
    self._isOn = isOn
    self.icon = icon
    self.note = note
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: $isOn) {
        Label(title, systemImage: icon).symbolRenderingMode(.hierarchical)
      }
      .tint(Color(palette.signatureDeep))
      .allowsHitTesting(false)
      if let note {
        Text(note)
          .font(.caption)
          .foregroundStyle(Color(palette.ground.muted))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(minHeight: LabMetrics.minHit)
    .contentShape(.rect)
    .onTapGesture { flip() }
    .opacity(isEnabled ? 1 : 0.5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityHint(note ?? "")
    .accessibilityAddTraits([.isToggle, .isButton])
    .accessibilityAction { flip() }
  }

  private func flip() {
    guard isEnabled else { return }
    isOn.toggle()
    haptics?.selection()
  }
}

/// Explicit choice chips with a live explanation line (Orbitals MotionControls.swift:130; spectra-lab
/// `kindNote`). Selected chips fill with the item's hue and use a contrast-safe `onFill` label; under
/// Differentiate Without Colour they also gain a checkmark.
public struct ChoiceChips<ID: Hashable & Sendable>: View {
  nonisolated public struct Item: Identifiable, Sendable {
    public var id: ID
    public var title: String
    public var icon: String?
    public var hue: LabColor?
    public init(_ id: ID, _ title: String, icon: String? = nil, hue: LabColor? = nil) {
      self.id = id
      self.title = title
      self.icon = icon
      self.hue = hue
    }
  }

  let items: [Item]
  @Binding var selection: ID
  let columns: Int
  let identifierPrefix: String
  let explanation: (ID) -> String
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityDifferentiateWithoutColor) private var noColourOnly
  @Environment(\.colorSchemeContrast) private var contrast

  /// `explanation` returns the line shown under the grid for the selected id ("" for none).
  public init(
    _ items: [Item], selection: Binding<ID>, columns: Int = 3, identifierPrefix: String,
    explanation: @escaping (ID) -> String = { _ in "" }
  ) {
    self.items = items
    self._selection = selection
    self.columns = max(1, columns)
    self.identifierPrefix = identifierPrefix
    self.explanation = explanation
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 1 : columns),
        spacing: 7
      ) {
        ForEach(items) { chip($0) }
      }
      let note = explanation(selection)
      if !note.isEmpty {
        Text(note)
          .font(.caption)
          .foregroundStyle(Color(palette.ground.muted))
          .fixedSize(horizontal: false, vertical: true)
          .contentTransition(.opacity)
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
  }

  private func chip(_ item: Item) -> some View {
    let hue = item.hue ?? palette.signature
    let selected = item.id == selection
    let label = LabPalette.onFill(hue, ground: palette.ground)
    return Button {
      guard !selected else { return }
      selection = item.id
      haptics?.selection()
    } label: {
      HStack(spacing: 6) {
        if noColourOnly && selected { Image(systemName: "checkmark").accessibilityHidden(true) }
        if let icon = item.icon { Image(systemName: icon).accessibilityHidden(true) }
        Text(item.title).lineLimit(1).minimumScaleFactor(0.8)
      }
      .font(.subheadline.weight(selected ? .semibold : .medium))
      .foregroundStyle(selected ? Color(label) : .white.opacity(LabSemantic.bodyAlpha))
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: LabMetrics.minHit)
      .background(selected ? Color(hue) : .white.opacity(0.07), in: .rect(cornerRadius: LabMetrics.chipRadius))
      .overlay {
        RoundedRectangle(cornerRadius: LabMetrics.chipRadius)
          .strokeBorder(Color(hue, opacity: selected ? 0.8 : (contrast == .increased ? 0.4 : 0.18)))
      }
      .contentShape(.rect(cornerRadius: LabMetrics.chipRadius))
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(Color(hue, opacity: 0.12)).interactive(), in: .rect(cornerRadius: LabMetrics.chipRadius))
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("\(identifierPrefix)-\(item.id)")
  }
}

/// A selectable glass tile (Gyre ObjectTile, Console.swift:264-293), tinted by the item's **data hue**:
/// icon over title; the subtitle is the accessibility hint. The icon is the hue when unselected, white
/// when selected; the selected tint is the hue at 0.45, or 0.30 for light hues (luminance > 0.5),
/// measured: oobleck white at 0.45 left the white label at 4.25:1, at 0.30 it reads 6.7:1. Plays `.select`.
public struct GlassTile: View {
  let title: String
  let icon: String
  let subtitle: String
  let selected: Bool
  let hue: LabColor
  let action: () -> Void
  @Environment(\.labHaptics) private var haptics
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  public init(title: String, icon: String, subtitle: String, selected: Bool, hue: LabColor, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.subtitle = subtitle
    self.selected = selected
    self.hue = hue
    self.action = action
  }

  public var body: some View {
    let tint = (hue.luminance > 0.5 ? 0.30 : 0.45) + (contrast == .increased ? 0.1 : 0)
    Button {
      haptics?.play(.select)
      action()
    } label: {
      VStack(spacing: 5) {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(selected ? Color.white : Color(hue))
          .symbolEffect(.bounce, value: selected)
          .symbolEffectsRemoved(reduceMotion)
          .frame(height: 26)
        Text(title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(selected ? .white : .white.opacity(LabSemantic.secondaryAlpha))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .padding(.horizontal, 4)
      .frame(minWidth: 76, maxWidth: .infinity, minHeight: 62)
      .contentShape(.rect(cornerRadius: LabMetrics.tileRadius))
    }
    .buttonStyle(.plain)
    .glassEffect(
      selected ? .regular.tint(Color(hue, opacity: tint)).interactive() : .regular.interactive(),
      in: .rect(cornerRadius: LabMetrics.tileRadius))
    .accessibilityLabel(title)
    .accessibilityHint(subtitle)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityShowsLargeContentViewer { Label(title, systemImage: icon) }
  }
}

/// A horizontally scrolling shelf of `GlassTile`s (§3.6, §9.4): 76 × 62 pt tiles, spacing 8, in one
/// `GlassEffectContainer(spacing: 4)`; scrolls the selection to the centre on appear and on change.
/// At 398 pt wide it shows 4.8 tiles, so the cut-off fifth tells the user it scrolls.
public struct GlassTileShelf<ID: Hashable & Sendable>: View {
  nonisolated public struct Item: Identifiable, Sendable {
    public var id: ID
    public var title: String
    public var icon: String
    public var subtitle: String
    public var hue: LabColor
    public init(_ id: ID, title: String, icon: String, subtitle: String, hue: LabColor) {
      self.id = id
      self.title = title
      self.icon = icon
      self.subtitle = subtitle
      self.hue = hue
    }
  }

  let items: [Item]
  @Binding var selection: ID
  let identifierPrefix: String
  let onSelect: (ID) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    _ items: [Item], selection: Binding<ID>, identifierPrefix: String = "material",
    onSelect: @escaping (ID) -> Void = { _ in }
  ) {
    self.items = items
    self._selection = selection
    self.identifierPrefix = identifierPrefix
    self.onSelect = onSelect
  }

  public var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        GlassEffectContainer(spacing: 4) {
          HStack(spacing: 8) {
            ForEach(items) { item in
              GlassTile(
                title: item.title, icon: item.icon, subtitle: item.subtitle, selected: item.id == selection,
                hue: item.hue
              ) {
                selection = item.id
                onSelect(item.id)
              }
              .frame(width: 76)
              .id(item.id)
              .accessibilityIdentifier("\(identifierPrefix)-\(item.id)")
            }
          }
          .padding(.vertical, 2)
        }
      }
      .scrollIndicators(.hidden)
      .onAppear { proxy.scrollTo(selection, anchor: .center) }
      .onChange(of: selection) { _, id in
        withLabAnimation(LabMotion.select, reduceMotion: reduceMotion) { proxy.scrollTo(id, anchor: .center) }
      }
    }
    // Stage chrome (Rheo's shelf floats over the headspace): capped at `.accessibility1` like the top
    // bar (§4.3), with each tile's full name in the Large Content Viewer, since 76 pt tiles can't grow.
    .dynamicTypeSize(...LabMetrics.stageChromeTypeCap)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("\(identifierPrefix)-shelf")
  }
}
#endif
