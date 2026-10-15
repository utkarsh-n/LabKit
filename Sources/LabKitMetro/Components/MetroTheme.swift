#if os(iOS)
  import LabKitCore
  import LabKitFeedback
  import SwiftUI

  // SwiftUI adapters for the Metro tokens: colours, type roles, the haptic vocabulary and the root modifiers.

  extension Color {
    /// A Metro token as a SwiftUI colour: gamma-encoded sRGB, exactly as Metro Station writes `Color(red:green:blue:)`.
    /// (A distinct label, so an app that also imports LabKitUI, which adds `Color(_: LabColor)`, stays unambiguous.)
    nonisolated public init(metro colour: LabColor, opacity: Double = 1) {
      self.init(.sRGB, red: colour.r, green: colour.g, blue: colour.b, opacity: opacity)
    }
  }

  /// The Metro colours as SwiftUI `Color`s (spec §3). Values come from `Metro.Colour`.
  nonisolated public enum MetroPalette {
    public static let canvas = Color(metro: Metro.Colour.canvas)
    public static let content = Color(metro: Metro.Colour.content)
    public static let gaugeHousing = Color(metro: Metro.Colour.gaugeHousing)
    public static let metalLight = Color(metro: Metro.Colour.metalLight)
    public static let metalDark = Color(metro: Metro.Colour.metalDark)
    public static let pillLight = Color(metro: Metro.Colour.pillLight)
    public static let pillDark = Color(metro: Metro.Colour.pillDark)
    public static let plot = Color(metro: Metro.Colour.plot)
    public static let displayInk = Color(metro: Metro.Colour.displayInk)
    public static let secondaryInk = Color(metro: Metro.Colour.secondaryInk)
    public static let actionCyan = Color(metro: Metro.Colour.actionCyan)
    public static let actionAmber = Color(metro: Metro.Colour.actionAmber)
    public static let instrumentCyan = Color(metro: Metro.Colour.instrumentCyan)
    public static let instrumentAmber = Color(metro: Metro.Colour.instrumentAmber)
    public static let wavePrimary = Color(metro: Metro.Colour.wavePrimary)
    public static let waveSecondary = Color(metro: Metro.Colour.waveSecondary)
    public static let spectrumPrimary = Color(metro: Metro.Colour.spectrumPrimary)
    public static let spectrumSecondary = Color(metro: Metro.Colour.spectrumSecondary)
    public static let carrier = Color(metro: Metro.Colour.carrier)
    public static let crownBase = Color(metro: Metro.Colour.crownBase)
    public static let crownRimLight = Color(metro: Metro.Colour.crownRimLight)
    public static let crownRimDark = Color(metro: Metro.Colour.crownRimDark)
    public static let crownRimMid = Color(metro: Metro.Colour.crownRimMid)
    public static let crownFaceLight = Color(metro: Metro.Colour.crownFaceLight)
    public static let crownFaceDark = Color(metro: Metro.Colour.crownFaceDark)
  }

  extension Metro.Weight {
    nonisolated public var swiftUI: Font.Weight {
      switch self {
      case .regular: .regular
      case .light: .light
      case .medium: .medium
      case .semibold: .semibold
      }
    }
  }

  extension Metro.Design {
    nonisolated public var swiftUI: Font.Design {
      switch self {
      case .default: .default
      case .rounded: .rounded
      case .monospaced: .monospaced
      case .serif: .serif
      }
    }
  }

  extension Metro.TextStyle {
    nonisolated public var swiftUI: Font.TextStyle {
      switch self {
      case .largeTitle: .largeTitle
      case .title: .title
      case .title3: .title3
      case .body: .body
      case .callout: .callout
      case .subheadline: .subheadline
      case .caption: .caption
      case .caption2: .caption2
      }
    }
  }

  /// Metro type (spec §4). Roles with a fixed recipe are fonts here; roles that scale take their base size through a
  /// `@ScaledMetric` in the component and call `font(_:size:)`.
  nonisolated public enum MetroFont {
    /// A role at `size` (its base size when nil), with its weight, design, monospaced digits and italic.
    public static func font(_ role: Metro.TypeRole, size: CGFloat? = nil) -> Font {
      var font = Font.system(size: size ?? role.size, weight: role.weight.swiftUI, design: role.design.swiftUI)
      if role.monospacedDigits { font = font.monospacedDigit() }
      if role.italic { font = font.italic() }
      return font
    }

    /// Human meaning: system subheadline, medium serif italic (Dynamic Type).
    public static let meaning = Font.system(.subheadline, design: .serif, weight: .medium).italic()
    /// Telemetry: caption2 mono label (tracking 1.2), title3 mono value, caption2 mono unit.
    public static let telemetryLabel = Font.system(.caption2, design: .monospaced)
    public static let telemetryValue = Font.system(.title3, design: .monospaced).monospacedDigit()
    public static let telemetryUnit = Font.system(.caption2, design: .monospaced)
    /// Short engineering captions (crown captions, strip headers): caption2 mono, medium.
    public static let caption = Font.system(.caption2, design: .monospaced, weight: .medium)
    /// An explanation surface's title: large title, rounded, semibold.
    public static let explanationTitle = Font.system(.largeTitle, design: .rounded, weight: .semibold)
    /// Equations: callout mono, with units and assumptions nearby.
    public static let equation = Font.system(.callout, design: .monospaced)
  }

  // MARK: Feedback

  extension Metro.HapticDetent {
    /// As a LabKit `HapticTap`. The 0.05 s gap bounds detent density at Metro's 20 a second through the engine's one
    /// admission clock, so a burst coalesces instead of queueing (spec §15).
    nonisolated public var tap: HapticTap {
      HapticTap(Float(intensity), Float(sharpness), minGap: 1 / Metro.Motion.detentMaxHz)
    }
  }

  extension MetroDetentRole {
    /// The detent a role plays for one accepted step in `direction`.
    nonisolated public func tap(direction: Int) -> HapticTap { haptic(direction: direction).tap }
  }

  extension EnvironmentValues {
    /// The haptic engine Metro controls play their accepted-change detents through (one per accepted change; none for a
    /// clamped no-op). `nil` = silent. Set it with `.metroHaptics(_:)`; it is LabKit's `HapticEngine`, so an app that also
    /// uses LabKitUI passes the same engine to `.labHaptics(_:)`.
    @Entry public var metroHaptics: HapticEngine? = nil
  }

  extension View {
    /// Injects the haptic engine every Metro control plays its detents through.
    public func metroHaptics(_ engine: HapticEngine?) -> some View { environment(\.metroHaptics, engine) }

    /// The root of a Metro screen: the dark appearance Metro specifies (a light theme needs its own palette and
    /// validation), action cyan as the tint, and the Metro environment (canvas, cyan wash, grid) behind everything.
    public func metroChrome(environment: Bool = true) -> some View {
      self
        .preferredColorScheme(.dark)
        .tint(MetroPalette.actionCyan)
        .background {
          if environment { MetroBackground() } else { MetroPalette.canvas.ignoresSafeArea() }
        }
    }
  }
#endif
