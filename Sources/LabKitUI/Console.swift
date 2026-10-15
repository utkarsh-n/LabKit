#if os(iOS)
import LabKitCore
import LabKitFeedback
import SwiftUI

// The bottom console (labkit-from-orbitals-spectra.md §3.7; Gyre Console.swift:13-74 with §1.3 #14-#17).

extension ParamStore {
  /// A SwiftUI binding to one parameter (writes clamp through the store).
  public func binding(_ id: ParamID) -> Binding<Double> {
    Binding(get: { self[id] }, set: { self[id] = $0 })
  }
}

/// The console: an iOS 27 `.tabs` page picker (hidden for one page), a page of glass knobs, an
/// always-visible controls row, and the readout or precision tray floating above while a knob is held.
///
/// - `open: nil` means no fold button (Rheo: the tank floor is the console's top edge and must not move).
/// - `uniformHeight` reserves the tallest page's rows on every page, so switching pages never moves
///   anything above the console.
/// - The page and the controls row sit in **separate** `GlassEffectContainer`s: measured at AX XXXL, pucks
///   scrolled under one shared container fused with the buttons' glass.
/// - Chrome over the stage: capped at `.accessibility1`; at accessibility sizes knob rows go from 4 to 2
///   and the page scrolls inside 320 pt.
public struct KnobConsole<Page: View, Controls: View>: View {
  let pages: [ConsolePage]
  @Binding var page: String
  let store: ParamStore
  @Binding var focus: KnobFocus
  let open: Binding<Bool>?
  let uniformHeight: Bool
  let pickerMaxWidth: CGFloat
  let content: (ConsolePage) -> Page
  let controls: () -> Controls

  @Environment(\.labHaptics) private var haptics
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var contentHeight: CGFloat = 0

  public init(
    pages: [ConsolePage], page: Binding<String>, store: ParamStore, focus: Binding<KnobFocus>,
    open: Binding<Bool>? = nil, uniformHeight: Bool = true, pickerMaxWidth: CGFloat = LabMetrics.Console.pickerMaxWidth,
    @ViewBuilder content: @escaping (ConsolePage) -> Page,
    @ViewBuilder controls: @escaping () -> Controls
  ) {
    self.pages = pages
    self._page = page
    self.store = store
    self._focus = focus
    self.open = open
    self.uniformHeight = uniformHeight
    self.pickerMaxWidth = pickerMaxWidth
    self.content = content
    self.controls = controls
  }

  private typealias C = LabMetrics.Console
  private var isOpen: Bool { open?.wrappedValue ?? true }
  private var perRow: Int { typeSize.isAccessibilitySize ? 2 : 4 }
  private var current: ConsolePage? { pages.first { $0.id == page } ?? pages.first }
  private var maxRows: Int {
    pages.map { ($0.knobs.count + perRow - 1) / perRow }.max() ?? 0
  }

  public var body: some View {
    VStack(spacing: C.stack) {
      if isOpen {
        GlassEffectContainer(spacing: C.glassSpacing) {
          VStack(spacing: C.page) {
            if pages.count > 1 { picker }
            pageArea
          }
        }
        .transition(LabMotion.deckTransition(reduceMotion: reduceMotion))
      }
      GlassEffectContainer(spacing: C.controlsGlassSpacing) {
        HStack(spacing: C.controls) {
          controls()
          if let open { foldButton(open) }
        }
      }
    }
    .overlay(alignment: .top) {
      // A zero-height anchor on the console's top edge; the readout or tray hangs above it with its
      // bottom 12 pt clear of the console, whatever its height (measured: an alignment-guide version
      // drew the readout over the page picker).
      Color.clear
        .frame(height: 0)
        .overlay(alignment: .bottom) {
          focusOverlay
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
        }
    }
    .labAnimation(LabMotion.readout, value: focus)
    .dynamicTypeSize(...LabMetrics.stageChromeTypeCap)
  }

  private var picker: some View {
    Picker("Knobs", selection: $page.animation(LabMotion.gated(LabMotion.page, reduceMotion: reduceMotion))) {
      ForEach(pages) { Text($0.title).tag($0.id) }
    }
    .pickerStyle(.tabs)
    .frame(maxWidth: pickerMaxWidth)
    .onChange(of: page) { _, _ in
      haptics?.selection()
      if focus != .none { focus = .none }
    }
    .accessibilityIdentifier("console-pages")
  }

  @ViewBuilder private var pageArea: some View {
    if let current {
      let stack = ZStack(alignment: .top) {
        if uniformHeight { KnobRowsSizer(rows: maxRows) }
        content(current)
          .id(current.id)
          .transition(LabMotion.pageTransition(reduceMotion: reduceMotion))
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("console-page-\(current.id)")
      if typeSize.isAccessibilitySize {
        ScrollView {
          stack
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollClipDisabled(false)
        .contentMargins(.bottom, 8, for: .scrollContent)
        .frame(height: min(max(contentHeight, 1), C.accessibilityPageMaxHeight))
      } else {
        stack
      }
    }
  }

  /// The readout (or tray) that hangs above the console's top edge. Its own view, so a held knob's
  /// value changes redraw only the readout, not the whole console and the app's controls row.
  private var focusOverlay: some View {
    KnobFocusOverlay(focus: $focus, store: store, reduceMotion: reduceMotion)
  }

  private func foldButton(_ open: Binding<Bool>) -> some View {
    Button {
      haptics?.play(.soft)
      withLabAnimation(LabMotion.fold, reduceMotion: reduceMotion) { open.wrappedValue.toggle() }
    } label: {
      Label("Knobs", systemImage: open.wrappedValue ? "chevron.down" : "chevron.up")
        .labelStyle(.titleAndIcon)
        .font(LabFont.button)
        .foregroundStyle(.white)  // secondary chrome is white on glass; the signature marks primary only
        .lineLimit(1)
        .fixedSize()
        .frame(minHeight: LabMetrics.glyphFrame)
        .contentTransition(.symbolEffect(.replace))
        .symbolEffectsRemoved(reduceMotion)
    }
    .buttonStyle(.glass)
    .accessibilityLabel(open.wrappedValue ? "Hide knobs" : "Show knobs")
    .accessibilityShowsLargeContentViewer {
      Label(open.wrappedValue ? "Hide knobs" : "Show knobs", systemImage: open.wrappedValue ? "chevron.down" : "chevron.up")
    }
    .accessibilityIdentifier("console-fold")
  }
}

extension KnobConsole where Page == KnobGrid {
  /// The common case: every page is its knobs. `dimmed` knobs do nothing for the current state
  /// (Rheo's Packing on honey) and draw at 0.55 opacity.
  public init(
    pages: [ConsolePage], page: Binding<String>, store: ParamStore, focus: Binding<KnobFocus>,
    open: Binding<Bool>? = nil, uniformHeight: Bool = true, pickerMaxWidth: CGFloat = LabMetrics.Console.pickerMaxWidth,
    dimmed: Set<ParamID> = [],
    @ViewBuilder controls: @escaping () -> Controls
  ) {
    self.init(
      pages: pages, page: page, store: store, focus: focus, open: open, uniformHeight: uniformHeight,
      pickerMaxWidth: pickerMaxWidth,
      content: { KnobGrid($0.knobs, store: store, focus: focus, dimmed: dimmed) },
      controls: controls)
  }
}

/// Knobs in rows of `columns` (4; 2 at accessibility sizes), wired to the console's focus: grabbing
/// a knob shows its readout, a long press opens its precision tray. Apps never wire those by hand.
public struct KnobGrid: View {
  let ids: [ParamID]
  let store: ParamStore
  @Binding var focus: KnobFocus
  let columns: Int
  let dimmed: Set<ParamID>
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ ids: [ParamID], store: ParamStore, focus: Binding<KnobFocus>, columns: Int = 4, dimmed: Set<ParamID> = []) {
    self.ids = ids
    self.store = store
    self._focus = focus
    self.columns = max(1, columns)
    self.dimmed = dimmed
  }

  public var body: some View {
    let perRow = typeSize.isAccessibilitySize ? min(columns, 2) : columns
    let known = ids.filter { store.contains($0) }
    Grid(horizontalSpacing: LabMetrics.Console.gridH, verticalSpacing: LabMetrics.Console.gridV) {
      ForEach(Array(stride(from: 0, to: known.count, by: perRow)), id: \.self) { start in
        let row = known[start..<min(start + perRow, known.count)]
        GridRow {
          ForEach(row, id: \.self) { id in knob(id) }
          // Pad short rows so every page keeps the same columns.
          ForEach(0..<(perRow - row.count), id: \.self) { _ in
            Color.clear.frame(maxWidth: .infinity).gridCellUnsizedAxes(.vertical).accessibilityHidden(true)
          }
        }
      }
    }
  }

  private func knob(_ id: ParamID) -> some View {
    GlassKnob(
      spec: store.spec(id), value: store.binding(id),
      onActive: { active in
        if active {
          focus = .held(id)
        } else if focus == .held(id) {
          focus = .none
        }
      },
      onPrecision: { focus = .precision(id) }
    )
    .opacity(dimmed.contains(id) ? LabMetrics.Knob.dimmedOpacity : 1)
  }
}

/// The floating `KnobReadout` (held) or `KnobPrecisionTray` (long press) for the console's focus.
struct KnobFocusOverlay: View {
  @Binding var focus: KnobFocus
  let store: ParamStore
  let reduceMotion: Bool

  var body: some View {
    switch focus {
    case .held(let id):
      if let spec = store.specs[id] {
        KnobReadout(spec: spec, value: store[id])
          .transition(LabMotion.readoutTransition(reduceMotion: reduceMotion))
      }
    case .precision(let id):
      if let spec = store.specs[id] {
        KnobPrecisionTray(spec: spec, value: store.binding(id)) { focus = .none }
          .transition(.opacity)
      }
    case .none:
      EmptyView()
    }
  }
}

/// Reserves the height of `rows` compact-knob rows at the current Dynamic Type size, invisibly.
struct KnobRowsSizer: View {
  let rows: Int
  var body: some View {
    VStack(spacing: LabMetrics.Console.gridV) {
      ForEach(0..<max(0, rows), id: \.self) { _ in
        VStack(spacing: 4) {
          Color.clear.frame(width: LabMetrics.Knob.compactFrame, height: LabMetrics.Knob.compactFrame)
          Text("X").font(LabFont.knobTitle)
          Text("0").font(LabFont.knobValue)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .hidden()
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

/// A slim phosphor bar (Gyre Console.swift:296-317), in the live colour.
public struct LevelMeter: View {
  let level: Double
  let active: Bool
  let label: String
  @Environment(\.colorSchemeContrast) private var contrast

  public init(level: Double, active: Bool, label: String = "Sound level") {
    self.level = level
    self.active = active
    self.label = label
  }

  public var body: some View {
    let live = Color(LabSemantic.live)
    // `clamped` passes NaN through (Swift's max/min return the NaN operand), and `Int(NaN)` traps, so a
    // glitching level must be made finite before it is clamped or counted.
    let shown = clamped(level.isFinite ? level : 0, 0, 1)
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(contrast == .increased ? 0.22 : 0.1))
        Capsule()
          .fill(live.gradient)
          .frame(width: max(6, geo.size.width * shown))
          .shadow(color: live.opacity(0.8), radius: 4)
          .opacity(active ? 1 : 0)
      }
    }
    .frame(height: 6)
    .labAnimation(LabMotion.meter, value: shown)
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue(active ? "\(Int((shown * 100).rounded())) percent" : "Off")
  }
}

// MARK: - Controls-row buttons

/// The primary action (§3.7): `.glassProminent` in the signature with an `onSignature` label (white on
/// Rheo pink is 2.90:1), icon-only at accessibility sizes with the full label in the Large Content
/// Viewer, plays `.tap`, runs the action under `LabMotion.action`.
public struct ProminentGlassButton: View {
  let title: String
  let icon: String
  let iconOnly: Bool
  let action: () -> Void
  @Environment(\.labPalette) private var palette
  @Environment(\.labHaptics) private var haptics
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ title: String, icon: String, iconOnly: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.iconOnly = iconOnly
    self.action = action
  }

  public var body: some View {
    let compact = iconOnly || typeSize.isAccessibilitySize
    Button {
      haptics?.play(.tap)
      withLabAnimation(LabMotion.action, reduceMotion: reduceMotion) { action() }
    } label: {
      Group {
        if compact {
          Image(systemName: icon)
        } else {
          Label(title, systemImage: icon).labelStyle(.titleAndIcon)
        }
      }
      .font(LabFont.button)
      .foregroundStyle(Color(palette.onSignature))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, compact ? 0 : 4)
      .frame(minWidth: compact ? LabMetrics.glyphFrame : nil, minHeight: LabMetrics.glyphFrame)
      .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.glassProminent)
    .tint(Color(palette.signature))
    .symbolEffectsRemoved(reduceMotion)
    .transaction { if reduceMotion { $0.animation = nil } }
    .accessibilityLabel(title)
    .accessibilityShowsLargeContentViewer { Label(title, systemImage: icon) }
  }
}

/// A secondary action: a white glyph in a 36 pt frame on `.glass` circle (renders 50 pt), with a 44 pt
/// hit area and a configurable tap haptic (default `.soft`).
public struct CircleGlassButton: View {
  let label: String
  let icon: String
  let tap: HapticTap
  let action: () -> Void
  @Environment(\.labHaptics) private var haptics
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(_ label: String, icon: String, tap: HapticTap = .soft, action: @escaping () -> Void) {
    self.label = label
    self.icon = icon
    self.tap = tap
    self.action = action
  }

  public var body: some View {
    Button {
      haptics?.play(tap)
      action()
    } label: {
      Image(systemName: icon)
        .font(LabFont.toolbarIcon)
        .foregroundStyle(.white)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: LabMetrics.glyphFrame, height: LabMetrics.glyphFrame)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .frame(minWidth: LabMetrics.minHit, minHeight: LabMetrics.minHit)
    .contentShape(.circle)
    .symbolEffectsRemoved(reduceMotion)
    .transaction { if reduceMotion { $0.animation = nil } }
    .accessibilityLabel(label)
    .accessibilityShowsLargeContentViewer { Label(label, systemImage: icon) }
  }
}

/// "Reset fluid knobs": resets only the visible page's knobs, and says so (Orbitals' scoped-reset rule).
public struct ResetPageButton: View {
  let page: ConsolePage
  let store: ParamStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(page: ConsolePage, store: ParamStore) {
    self.page = page
    self.store = store
  }

  public var body: some View {
    CircleGlassButton("Reset \(page.title.lowercased()) knobs", icon: "arrow.counterclockwise", tap: .reset) {
      withLabAnimation(LabMotion.reset, reduceMotion: reduceMotion) { store.reset(page.knobs) }
    }
    .accessibilityIdentifier("action-reset-page")
  }
}
#endif
