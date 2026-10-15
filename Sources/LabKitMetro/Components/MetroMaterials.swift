#if os(iOS)
  import LabKitCore
  import SwiftUI

  // Metro's material roles (spec §6): environment, quiet content panels, precise opaque metal and native Liquid Glass,
  // each with one job. Native glass stays on controls and the isolated lens; supporting content stays calm.

  /// The environment (spec §6 "Environment recipe"): solid canvas, a localised action-cyan wash (0.085, top-trailing,
  /// radii 5–620 pt) and a faint 28 pt technical grid (white 0.025, 0.5 pt). Ignores safe areas, hidden from
  /// accessibility, owns no touches. Reduce Transparency drops the wash (the starter's adoption improvement).
  public struct MetroBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
      ZStack {
        MetroPalette.canvas
        if !reduceTransparency {
          RadialGradient(
            colors: [MetroPalette.actionCyan.opacity(Metro.Opacity.environmentWash), .clear],
            center: .topTrailing, startRadius: 5, endRadius: 620)
        }
        Canvas { context, size in
          var grid = Path()
          let pitch = Metro.Layout.gridSpacing
          for x in stride(from: 0.0, through: size.width, by: pitch) {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
          }
          for y in stride(from: 0.0, through: size.height, by: pitch) {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
          }
          context.stroke(grid, with: .color(.white.opacity(Metro.Opacity.grid)), lineWidth: Metro.Stroke.grid)
        }
      }
      .ignoresSafeArea()
      .accessibilityHidden(true)
      .allowsHitTesting(false)
    }
  }

  /// A quiet content panel (spec §6): content colour at 0.85, radius 22, white 0.09 border at 1 pt, 16 pt padding.
  /// Opaque under Reduce Transparency; a stronger border (0.20) under Increased Contrast.
  public struct MetroContentPanel<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = Metro.Spacing.panelInset, @ViewBuilder content: () -> Content) {
      self.padding = padding
      self.content = content()
    }

    public var body: some View { content.modifier(MetroPanelModifier(padding: padding)) }
  }

  struct MetroPanelModifier: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
      content
        .padding(padding)
        .background(
          MetroPalette.content.opacity(reduceTransparency ? 1 : Metro.Opacity.panelFill),
          in: .rect(cornerRadius: Metro.Radius.contentPanel)
        )
        .overlay {
          RoundedRectangle(cornerRadius: Metro.Radius.contentPanel)
            .strokeBorder(
              .white.opacity(
                contrast == .increased ? Metro.Opacity.panelBorderIncreasedContrast : Metro.Opacity.panelBorder),
              lineWidth: Metro.Stroke.panel
            )
            .allowsHitTesting(false)
        }
    }
  }

  /// A quiet plot inset inside a panel (spec §6): plot colour, radius 10, white 0.075 border at 0.6 pt.
  struct MetroPlotInsetModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
      content
        .background(MetroPalette.plot, in: .rect(cornerRadius: Metro.Radius.plot))
        .overlay {
          RoundedRectangle(cornerRadius: Metro.Radius.plot)
            .strokeBorder(
              .white.opacity(contrast == .increased ? 0.2 : Metro.Opacity.plotBorder), lineWidth: Metro.Stroke.plot
            )
            .allowsHitTesting(false)
        }
    }
  }

  extension View {
    /// Places the view in a Metro content panel.
    public func metroPanel(padding: CGFloat = Metro.Spacing.panelInset) -> some View {
      modifier(MetroPanelModifier(padding: padding))
    }

    /// Places the view on a Metro plot inset.
    public func metroPlotInset() -> some View { modifier(MetroPlotInsetModifier()) }

    /// Native Liquid Glass for a small control (spec §10, §18): regular, interactive, tinted with `accent` at 0.08,
    /// in a circle. Size the actual label first (44 × 44 at least), then apply this.
    public func metroGlassControl(accent: Color = MetroPalette.actionCyan, in shape: some Shape = Circle()) -> some View
    {
      glassEffect(.regular.tint(accent.opacity(Metro.Opacity.crownGlassTint)).interactive(), in: shape)
    }
  }

  /// The opaque metal housing of a primary object (spec §6 "Metal recipe"): gauge-housing body with the black 0.8
  /// shadow (radius 22, y 16), a 1.4 pt rim through white 0.36, white 0.025, black and white 0.15, and a recessed face
  /// inset 0.038 D in a metal-light → metal-dark gradient with a white 0.07 hairline. `light` (a bounded screen-space
  /// tilt, zero under Reduce Motion) moves a faint directional sheen; it never moves the housing itself.
  public struct MetroInstrumentHousing: View {
    private let diameter: CGFloat
    private let light: SIMD2<Double>
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(diameter: CGFloat, light: SIMD2<Double> = .zero) {
      self.diameter = diameter.isFinite ? max(1, diameter) : 1
      self.light = SIMD2(
        light.x.isFinite ? min(1, max(-1, light.x)) : 0, light.y.isFinite ? min(1, max(-1, light.y)) : 0)
    }

    public var body: some View {
      let lx = reduceMotion ? 0 : light.x
      let ly = reduceMotion ? 0 : light.y
      ZStack {
        Circle()
          .fill(MetroPalette.gaugeHousing)
          .shadow(
            color: .black.opacity(Metro.Gauge.housingShadowOpacity), radius: Metro.Gauge.housingShadowRadius,
            y: Metro.Gauge.housingShadowY)
          .overlay {
            Circle().strokeBorder(
              LinearGradient(
                colors: [.white.opacity(0.36), .white.opacity(0.025), .black, .white.opacity(0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
              lineWidth: Metro.Stroke.housingRim)
          }
        Circle()
          .inset(by: diameter * Metro.Gauge.metalInsetRatio)
          .fill(
            LinearGradient(
              colors: [MetroPalette.metalLight, MetroPalette.metalDark], startPoint: .topLeading,
              endPoint: .bottomTrailing)
          )
          .overlay {
            Circle().inset(by: diameter * Metro.Gauge.metalInsetRatio)
              .strokeBorder(.white.opacity(0.07), lineWidth: 0.6)
          }
        if !reduceTransparency {
          Circle()
            .fill(
              RadialGradient(
                colors: [.white.opacity(0.085), MetroPalette.instrumentCyan.opacity(0.018), .clear],
                center: UnitPoint(x: 0.28 + lx * 0.25, y: 0.10 + ly * 0.25), startRadius: 0,
                endRadius: diameter * 0.85))
          Circle()
            .inset(by: diameter * 0.05)
            .stroke(
              LinearGradient(
                colors: [.clear, MetroPalette.instrumentCyan.opacity(0.13), .clear],
                startPoint: UnitPoint(x: 0.1 + lx * 0.12, y: 0.25 + ly * 0.14), endPoint: .bottomTrailing),
              lineWidth: 5
            )
            .blur(radius: 6)
        }
      }
      .frame(width: diameter, height: diameter)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  /// A small native-glass icon button: a 44 × 44 label sized before the glass, tinted 0.08, owning its touches.
  public struct MetroGlassIconButton: View {
    private let symbol: String
    private let label: String
    private let accent: Color
    private let identifier: String
    private let action: () -> Void

    public init(
      _ symbol: String, label: String, accent: Color = MetroPalette.actionCyan, identifier: String = "metroIconButton",
      action: @escaping () -> Void
    ) {
      self.symbol = symbol
      self.label = label
      self.accent = accent
      self.identifier = identifier
      self.action = action
    }

    public var body: some View {
      Button(action: action) {
        Image(systemName: symbol)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(accent)
          .frame(width: Metro.Layout.secondaryTargetMin, height: Metro.Layout.secondaryTargetMin)
          .metroGlassControl(accent: accent)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .accessibilityIdentifier(identifier)
      .metroControlOwnsTouches(identifier: identifier)
    }
  }
#endif
