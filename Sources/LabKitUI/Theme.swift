#if os(iOS)
import LabKitCore
import LabKitFeedback
import SwiftUI

// Tokens for "glass over phosphor" (labkit-from-orbitals-spectra.md §2): colour adapters and the
// environment, type roles, metrics and motion. Colour values live in LabKitCore (`LabPalette`,
// `LabGround`, `LabSemantic`); this file only adapts them to SwiftUI.
// `nonisolated` on the token enums: LabKitUI defaults to MainActor, and shapes/renderers read them.

extension Color {
  /// Tokens are gamma-encoded sRGB, exactly as the apps write `Color(red:green:blue:)`.
  nonisolated public init(_ c: LabColor, opacity: Double = 1) {
    self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
  }
}

extension LabColor {
  /// `Color(self)`.
  nonisolated public var color: Color { Color(self) }
}

extension EnvironmentValues {
  /// The app's palette. Set once at the root with `.labChrome(.rheo)` or `.labPalette(.rheo)`.
  @Entry public var labPalette: LabPalette = .orbitals
  /// The app's haptic engine; LabKit controls play their vocabulary through it. `nil` = silent.
  @Entry public var labHaptics: HapticEngine? = nil
}

extension View {
  /// Installs the palette, forces the dark scheme and applies the signature as the global tint
  /// (OrbitalsApp `.preferredColorScheme(.dark).tint(phosphor)`).
  public func labPalette(_ palette: LabPalette) -> some View {
    environment(\.labPalette, palette)
      .preferredColorScheme(.dark)
      .tint(Color(palette.signature))
  }

  /// The root of every LabKit app (§1.3 #11): palette + dark scheme + signature tint, the ground's
  /// stage colour behind everything, status bar hidden and the home indicator auto-hidden.
  public func labChrome(_ palette: LabPalette) -> some View {
    self
      .labPalette(palette)
      .background(Color(palette.ground.stage).ignoresSafeArea())
      .statusBarHidden()
      .persistentSystemOverlays(.hidden)
  }

  /// Injects the haptic engine every LabKit control plays through.
  public func labHaptics(_ engine: HapticEngine?) -> some View { environment(\.labHaptics, engine) }

  /// `.animation(_:value:)` that becomes no animation under Reduce Motion (§2.7).
  public func labAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
    modifier(LabAnimationModifier(animation: animation, value: value))
  }
}

private struct LabAnimationModifier<V: Equatable>: ViewModifier {
  let animation: Animation
  let value: V
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}

// MARK: - Type (§2.5)

/// Type roles. Every role is a Dynamic Type text style. **The surface decides the design**: opaque
/// instrument surfaces use `design: .monospaced`; glass chrome uses SF Pro with `.monospacedDigit()`.
nonisolated public enum LabFont {
  /// "LABKIT · GLASS OVER PHOSPHOR": uppercased, tracking 2, muted, after a 5 pt signature dot.
  public static let eyebrow = Font.system(.caption2, design: .monospaced)
  /// Panel header: number in signature, title uppercased with tracking 2, muted.
  public static let panelHeader = Font.system(.caption, design: .monospaced).weight(.medium)
  public static let panelHeaderTracking: CGFloat = 2
  /// Readout label: the word uppercased, the quantity symbol kept as typed.
  public static let readoutLabel = Font.system(.caption2, design: .monospaced)
  public static let readoutValue = Font.system(.callout, design: .monospaced).weight(.medium).monospacedDigit()
  public static let readoutDetail = Font.system(.caption2, design: .monospaced)
  /// Compact knob title: uppercased, tracking 0.6, white × 0.62 (Gyre GlassKnob.swift:24-28).
  public static let knobTitle = Font.caption2.weight(.semibold)
  public static let knobTitleTracking: CGFloat = 0.6
  /// Compact knob value (glass chrome: SF Pro digits).
  public static let knobValue = Font.caption.weight(.medium).monospacedDigit()
  /// Card knob title, in the parameter hue (Orbitals GlassControls.swift:35-37).
  public static let cardTitle = Font.subheadline.weight(.semibold)
  /// Serif italic quantity symbol (ISO 80000-1): η, γ̇, σ, g, B. Never case-transformed.
  public static let quantitySymbol = Font.system(.title3, design: .serif).weight(.semibold).italic()
  public static let dialReading = Font.system(.title3, design: .monospaced).weight(.semibold)
  public static let telemetryHeadline = Font.subheadline.weight(.semibold).monospacedDigit()
  public static let telemetrySubline = Font.caption.monospacedDigit()
  public static let timeChip = Font.caption2.weight(.bold)
  public static let button = Font.subheadline.weight(.semibold)
  public static let toolbarIcon = Font.body.weight(.semibold)
  /// Legend glyph, 22 pt wide (Gyre InfoSheet.swift:111-113).
  public static let legendGlyph = Font.system(.headline, design: .serif).italic()
  /// Info-sheet reading text; field-note bodies use `.subheadline`.
  public static let body = Font.callout
  public static let caption = Font.caption
  /// Knob readout hint and footers.
  public static let hint = Font.footnote
  public static let readoutCardTitle = Font.headline
  public static let readoutCardValue = Font.headline.monospacedDigit()
  public static let banner = Font.footnote.weight(.medium)
}

// MARK: - Shape, spacing, size (§2.6)

nonisolated public enum LabMetrics {
  public static let visualizationRadius: CGFloat = 28
  public static let panelRadius: CGFloat = 26
  public static let glassCardRadius: CGFloat = 22
  public static let knobCardRadius: CGFloat = 20
  public static let canvasRadius: CGFloat = 20
  public static let tileRadius: CGFloat = 18
  public static let chipRadius: CGFloat = 14

  public static let gutter: CGFloat = 16
  public static let gutterWide: CGFloat = 26
  public static let wideBreakpoint: CGFloat = 850
  public static let sectionSpacing: CGFloat = 22
  public static let columnSpacing: CGFloat = 18
  public static let panelPadding: CGFloat = 20
  public static let panelSpacing: CGFloat = 18
  /// Every control's minimum hit area (Orbitals; Gyre used 36).
  public static let minHit: CGFloat = 44
  /// Glass circle glyph frame inside the 44 pt hit area (renders 50 pt in glass, measured).
  public static let glyphFrame: CGFloat = 36
  public static let toolbarIcon = CGSize(width: 42, height: 44)
  /// Chrome floating over the stage stops growing here and offers the Large Content Viewer instead.
  /// Sheets and panels are never capped (§4.3, measured at AX XXXL).
  public static let stageChromeTypeCap = DynamicTypeSize.accessibility1
  /// Stage-coloured tint under glass cards that float over the fluid (knob readout, precision tray,
  /// banners). Measured: over light oobleck, plain `.regular` glass turned pale and the white title and
  /// secondary hint lost their contrast.
  public static let floatingCardScrim = 0.6

  /// Gyre's top-bar and console placement (labkit-from-gyre.md §4.3).
  public enum Screen {
    public static let topBarHorizontal: CGFloat = 16
    public static let topBarTop: CGFloat = 6
    public static let consoleHorizontal: CGFloat = 12
    public static let consoleBottom: CGFloat = 4
    public static let bannerTop: CGFloat = 8
  }

  /// Console layout (Gyre Console.swift; measured row 119.7 pt, controls row 50 pt).
  public enum Console {
    public static let stack: CGFloat = 12
    public static let page: CGFloat = 10
    public static let gridH: CGFloat = 2
    public static let gridV: CGFloat = 10
    public static let controls: CGFloat = 10
    public static let pickerMaxWidth: CGFloat = 320
    /// The knob page's `GlassEffectContainer` (Gyre's 18; pucks sit 40 pt apart, so they never blend).
    public static let glassSpacing: CGFloat = 18
    /// The controls row's container. Gyre's 18 blended neighbouring 50 pt circles, whose glass sits
    /// about 7 pt apart, into pinched bulges at rest (measured on the 15 Pro Max simulator); 4 keeps
    /// them separate.
    public static let controlsGlassSpacing: CGFloat = 4
    public static let readoutLift: CGFloat = -78
    public static let trayLift: CGFloat = -128
    /// The knob page scrolls inside this height at accessibility sizes.
    public static let accessibilityPageMaxHeight: CGFloat = 320
  }

  /// Knob geometry (Gyre GlassKnob.swift; Orbitals GlassControls.swift for the card).
  public enum Knob {
    public static let sweep = 270.0
    /// Points of (dx − dy) drag for the full range, in position space (Gyre GlassKnob.swift:108).
    public static let travel = 230.0
    public static let ticksPerSweep = 24
    /// Position-space radius in which a labelled detent captures the drag.
    public static let capture = 0.02
    public static let compactFrame: CGFloat = 84
    public static let compactPuck: CGFloat = 60
    public static let cardDial: CGFloat = 104
    public static let cardArc: CGFloat = 84
    public static let cardPuck: CGFloat = 70
    public static let stroke: CGFloat = 3
    public static let arcInset: CGFloat = 2
    public static let dot: CGFloat = 3
    public static let idleTint = 0.10
    public static let heldTint = 0.32
    public static let cardTint = 0.22
    public static let heldScale: CGFloat = 1.07
    public static let dimmedOpacity = 0.55
  }

  /// Millimetres per point on this device, from the model-identifier table (`LabDisplay`), or nil
  /// on an unknown device (hide "LIFE-SIZE" and fit instead). iPhone 15 Pro Max: 0.16565.
  public static var millimetresPerPoint: Double? { LabDisplay.currentMillimetresPerPoint }
}

// MARK: - Motion (§2.7)

/// Motion tokens. Every animation goes through `gated(_:reduceMotion:)` or `.labAnimation(_:value:)`,
/// which return no animation under Reduce Motion.
nonisolated public enum LabMotion {
  public static let select = Animation.smooth(duration: 0.25)
  public static let action = Animation.smooth(duration: 0.2)
  public static let grabCard = Animation.smooth(duration: 0.14)
  public static let grab = Animation.spring(duration: 0.25, bounce: 0.4)
  public static let page = Animation.spring(duration: 0.35, bounce: 0.2)
  public static let readout = Animation.spring(duration: 0.3, bounce: 0.25)
  public static let expand = Animation.spring(duration: 0.4, bounce: 0.25)
  public static let fold = Animation.spring(duration: 0.45, bounce: 0.2)
  public static let tile = Animation.spring(duration: 0.35, bounce: 0.25)
  public static let reset = Animation.smooth(duration: 0.5)
  public static let experiment = Animation.smooth(duration: 0.6)
  public static let readoutValue = Animation.smooth(duration: 0.15)
  public static let meter = Animation.linear(duration: 0.1)

  public static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : animation }

  /// Page change: blur-replace, or a cross-fade under Reduce Motion.
  @MainActor public static func pageTransition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : AnyTransition(.blurReplace)
  }
  /// The console deck appearing: blur-replace + scale 0.9 from the bottom.
  @MainActor public static func deckTransition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : AnyTransition(.blurReplace.combined(with: .scale(0.9, anchor: .bottom)))
  }
  /// The floating knob readout: fade + scale 0.92 from the bottom.
  @MainActor public static func readoutTransition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom))
  }
}

/// Runs `body` inside `withAnimation(animation)` unless Reduce Motion is on.
@MainActor public func withLabAnimation<R>(_ animation: Animation, reduceMotion: Bool, _ body: () throws -> R) rethrows -> R {
  if reduceMotion { return try body() }
  return try withAnimation(animation, body)
}

// MARK: - Canvas labels

/// Monospaced UPPERCASE stage tag that follows Dynamic Type (`@ScaledMetric` 9, capped at 14), e.g.
/// "THIN TANK · OOBLECK". With `backing`, a 0.6-alpha stage capsule sits behind it, for labels that
/// can land on the fluid (§3.13).
public struct LabCanvasLabel: View {
  let text: String
  let colour: Color?
  let backing: Bool
  @Environment(\.labPalette) private var palette
  @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 9

  public init(_ text: String, colour: Color? = nil, backing: Bool = false) {
    self.text = text
    self.colour = colour
    self.backing = backing
  }

  public var body: some View {
    Text(LabFormat.uppercasedLatin(text))
      .font(.system(size: min(size, 14), weight: .medium, design: .monospaced))
      .tracking(0.6)
      .foregroundStyle(colour ?? Color(LabSemantic.live, opacity: 0.8))
      .padding(.horizontal, backing ? 6 : 0)
      .padding(.vertical, backing ? 2 : 0)
      .background {
        if backing { Capsule().fill(Color(palette.ground.stage, opacity: 0.6)) }
      }
      .accessibilityLabel(text)
  }
}
#endif
