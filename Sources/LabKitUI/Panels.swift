#if os(iOS)
import LabKitCore
import SwiftUI

// Instrument surfaces (labkit-from-orbitals-spectra.md §3.1–§3.2): opaque phosphor panels, never
// glass, with monospaced labels. Numbers keep a fixed contrast on them.

/// The numbered phosphor card (Orbitals OrbitTheme.swift:22-41): opaque `panel` fill, white hairline,
/// a monospaced header (number in the signature, title UPPERCASE), content, and an optional caption.
public struct InstrumentPanel<Content: View, Accessory: View>: View {
  let number: String
  let title: String
  let caption: String?
  let accessory: Accessory
  let content: Content
  @Environment(\.labPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast

  /// `number`: "01"…"09" for ordered sections, or a symbolic code for a quantity group ("σ·γ̇").
  public init(
    _ number: String, _ title: String, caption: String? = nil,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
    @ViewBuilder content: () -> Content
  ) {
    self.number = number
    self.title = title
    self.caption = caption
    self.accessory = accessory()
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: LabMetrics.panelSpacing) {
      HStack(spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(number).foregroundStyle(Color(palette.signature))
          Text(LabFormat.uppercasedLatin(title)).tracking(LabFont.panelHeaderTracking)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), panel \(number)")
        Spacer(minLength: 0)
        accessory
      }
      .font(LabFont.panelHeader)
      .foregroundStyle(Color(palette.ground.muted))
      content
      if let caption {
        Text(caption)
          .font(LabFont.caption)
          .foregroundStyle(Color(palette.ground.muted))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(LabMetrics.panelPadding)
    .background(Color(palette.ground.panel), in: .rect(cornerRadius: LabMetrics.panelRadius))
    .overlay {
      RoundedRectangle(cornerRadius: LabMetrics.panelRadius)
        .strokeBorder(.white.opacity(contrast == .increased ? 0.22 : palette.ground.hairlineAlpha))
        .allowsHitTesting(false)
    }
  }
}

/// A quantity symbol in serif italic, never case-transformed. One `_` marks a subscript: "τ_y" → τᵧ.
public struct QuantitySymbol: View {
  let glyph: String
  let font: Font
  public init(_ glyph: String, font: Font = LabFont.quantitySymbol) {
    self.glyph = glyph
    self.font = font
  }
  public var body: some View {
    let parts = glyph.split(separator: "_", maxSplits: 1).map(String.init)
    Group {
      if parts.count == 2 {
        Text("\(Text(parts[0]))\(Text(parts[1]).font(.caption2).baselineOffset(-3))")
      } else {
        Text(glyph)
      }
    }
    .font(font)
    .accessibilityHidden(true)
  }
}

/// Title over value (over an optional detail and provenance badge), one accessibility element
/// (§3.2). The quantity `symbol` is never case-transformed; only the word is uppercased.
public struct Readout: View {
  let title: String
  let symbol: String
  let value: String
  let detail: String?
  let colour: LabColor?
  let provenance: Provenance?
  let spokenValue: String?
  @Environment(\.labPalette) private var palette

  /// `spokenValue`: what VoiceOver says when the visible value has superscripts or symbols
  /// ("3.20 s⁻¹" → "3.2 per second"). Defaults to `LabFormat.spoken(value)`.
  public init(
    _ title: String, symbol: String = "", value: String, detail: String? = nil, colour: LabColor? = nil,
    provenance: Provenance? = nil, spokenValue: String? = nil
  ) {
    self.title = title
    self.symbol = symbol
    self.value = value
    self.detail = detail
    self.colour = colour
    self.provenance = provenance
    self.spokenValue = spokenValue
  }

  private static let symbolFont = Font.system(.caption, design: .serif).italic()

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: symbol.isEmpty ? 0 : 5) {
        // A hidden serif strut gives every label row the same height and baseline, symbol or not
        // (measured: "TILT" beside "η VISCOSITY" sat 2 pt higher, and so did its value).
        QuantitySymbol(symbol.isEmpty ? "η" : symbol, font: Self.symbolFont)
          .foregroundStyle(Color(palette.ground.muted))
          .frame(width: symbol.isEmpty ? 0 : nil)
          .opacity(symbol.isEmpty ? 0 : 1)
        Text(LabFormat.uppercasedLatin(title))
          .font(LabFont.readoutLabel)
          .foregroundStyle(Color(palette.ground.muted))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      Text(value)
        .font(LabFont.readoutValue)
        .foregroundStyle(Color(colour ?? LabSemantic.value))
        .contentTransition(.numericText())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      // The badge sits on its own line under the value: beside a title it wrapped into syllables (measured).
      if let provenance { ProvenanceBadge(provenance) }
      if let detail {
        Text(detail)
          .font(LabFont.readoutDetail)
          .foregroundStyle(Color(palette.ground.dim))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(
      [spokenValue ?? LabFormat.spoken(value), detail, provenance?.badge].compactMap { $0 }.joined(separator: ", "))
  }
}

/// Readouts in a grid: adaptive columns (minimum 132 pt, 220 at accessibility sizes), or a fixed
/// count. Cells align to the top so labels share a baseline when one readout carries a badge.
public struct ReadoutGrid<Content: View>: View {
  let columns: Int?
  let content: Content
  @Environment(\.dynamicTypeSize) private var typeSize

  /// `columns: nil` = adaptive.
  public init(columns: Int? = nil, @ViewBuilder content: () -> Content) {
    self.columns = columns
    self.content = content()
  }

  public var body: some View {
    let items: [GridItem] =
      if let columns {
        Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading), count: max(1, columns))
      } else {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 220 : 132), spacing: 10, alignment: .topLeading)]
      }
    LazyVGrid(columns: items, alignment: .leading, spacing: 12) { content }
  }
}

/// The provenance word in a hairline capsule (§3.2, §3.10). The word is always there; colour only
/// reinforces it; `illustrative` is dashed (solid at 0.8 under Increase Contrast).
public struct ProvenanceBadge: View {
  let provenance: Provenance
  @Environment(\.labPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast

  public init(_ provenance: Provenance) { self.provenance = provenance }

  public var body: some View {
    let tint = provenance.tint(on: palette.ground)
    let dashed = provenance == .illustrative && contrast != .increased
    Text(LabFormat.uppercasedLatin(provenance.badge))
      .font(.system(.caption2, design: .monospaced))
      .tracking(1)
      .foregroundStyle(Color(tint))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .overlay {
        Capsule().strokeBorder(
          Color(tint, opacity: provenance == .illustrative && !dashed ? 0.8 : 0.45),
          style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(provenance.badge)
      .accessibilityHint(provenance.explanation)
  }
}

/// All five provenance words with their meaning: the honesty legend (info-sheet panel 06).
public struct ProvenanceLegend: View {
  let cases: [Provenance]
  public init(_ cases: [Provenance] = Provenance.allCases) { self.cases = cases }
  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(cases, id: \.self) { p in
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProvenanceBadge(p).frame(minWidth: 104, alignment: .leading)
            Text(p.explanation).font(.subheadline).fixedSize(horizontal: false, vertical: true)
          }
          VStack(alignment: .leading, spacing: 4) {
            ProvenanceBadge(p)
            Text(p.explanation).font(.subheadline).fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// A row of badges, chips or tags that wraps instead of hyphenating (measured: five badges in one
/// `HStack` across a 366 pt panel broke "MEASURED" into "MEA-SURED").
nonisolated public struct FlowLayout: Layout {
  public var spacing: CGFloat
  public var lineSpacing: CGFloat
  public init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing
  }

  /// A subview's size on a line `width` wide, and the proposal to place it with: its ideal size, or,
  /// when that is wider than the whole line, what it takes when offered the line (a long title wraps
  /// instead of running off the panel; measured risk at accessibility sizes, where sheets are uncapped).
  private func measure(_ s: LayoutSubview, width: CGFloat) -> (size: CGSize, proposal: ProposedViewSize) {
    let ideal = s.sizeThatFits(.unspecified)
    guard width.isFinite, ideal.width > width + 0.5 else { return (ideal, ProposedViewSize(ideal)) }
    let fit = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
    let size = CGSize(width: min(fit.width, width), height: fit.height)
    return (size, ProposedViewSize(size))
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
    for s in subviews {
      let size = measure(s, width: width).size
      if x > 0, x + size.width > width + 0.5 {
        y += line + lineSpacing
        x = 0
        line = 0
      }
      x += size.width + spacing
      widest = max(widest, x - spacing)
      line = max(line, size.height)
    }
    return CGSize(width: min(widest, width), height: y + line)
  }

  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    // Break lines against the same width `sizeThatFits` used, with a pixel of slack: the bounds come
    // back pixel-rounded, and breaking on the rounded width wrapped the last badge onto a line the
    // reported height didn't include (measured: a MODELLED badge drawn over the next paragraph).
    let width = max(bounds.width, proposal.width ?? bounds.width)
    let limit = bounds.minX + width + 0.5
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for s in subviews {
      let (size, place) = measure(s, width: width)
      if x > bounds.minX, x + size.width > limit {
        y += line + lineSpacing
        x = bounds.minX
        line = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: place)
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}

/// Monospaced UPPERCASE line after a 5 pt signature dot (Orbitals DashboardView.swift:92-100).
public struct Eyebrow: View {
  let text: String
  @Environment(\.labPalette) private var palette
  public init(_ text: String) { self.text = text }
  public var body: some View {
    HStack(spacing: 8) {
      Circle().fill(Color(palette.signature)).frame(width: 5, height: 5).accessibilityHidden(true)
      Text(LabFormat.uppercasedLatin(text)).tracking(2)
    }
    .font(LabFont.eyebrow)
    .foregroundStyle(Color(palette.ground.muted))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
  }
}

/// "RUN" in live phosphor or "HOLD" in amber over the clock (Orbitals DashboardView.swift:239-250).
public struct ClockReadout: View {
  let running: Bool
  let time: String
  @Environment(\.labPalette) private var palette
  public init(running: Bool, time: String) {
    self.running = running
    self.time = time
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(running ? "RUN" : "HOLD")
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .tracking(1)
        .foregroundStyle(Color(running ? LabSemantic.live : LabSemantic.value))
      Text(time)
        .font(.system(.caption, design: .monospaced).monospacedDigit())
        .foregroundStyle(Color(LabSemantic.value))
        .contentTransition(.numericText())
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(running ? "Simulation running" : "Simulation paused")
    .accessibilityValue(LabFormat.spoken(time))
  }
}
#endif
