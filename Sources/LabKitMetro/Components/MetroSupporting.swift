#if os(iOS)
  import LabKitCore
  import SwiftUI

  // Supporting components (spec §12): telemetry, event tiles and the floating action group.

  // MARK: Telemetry

  /// A telemetry row (spec §12): equal columns of label (caption2 mono, tracking 1.2), value (title3 mono, monospaced
  /// digits) and unit (caption2 mono, first-baseline aligned), separated by 1 × 30 pt white 0.10 dividers. Each metric
  /// is one accessibility element with its complete spoken value. At accessibility sizes the columns stack.
  public struct MetroTelemetryRow: View {
    private let metrics: [MetroMetric]
    private let identifier: String
    @Environment(\.dynamicTypeSize) private var dynamicType

    public init(_ metrics: [MetroMetric], identifier: String = "metro-telemetry") {
      self.metrics = metrics
      self.identifier = identifier
    }

    public var body: some View {
      Group {
        if dynamicType.isAccessibilitySize {
          VStack(spacing: 10) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
              if index > 0 { Rectangle().fill(.white.opacity(Metro.Opacity.divider)).frame(height: 1) }
              cell(metric)
            }
          }
        } else {
          HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
              if index > 0 {
                Rectangle().fill(.white.opacity(Metro.Opacity.divider))
                  .frame(width: Metro.Layout.telemetryDividerWidth, height: Metro.Layout.telemetryDividerHeight)
                  .accessibilityHidden(true)
              }
              cell(metric)
            }
          }
          .padding(.vertical, 2)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(identifier)
    }

    private func cell(_ metric: MetroMetric) -> some View {
      VStack(spacing: 5) {
        Text(metric.label)
          .font(MetroFont.telemetryLabel)
          .tracking(Metro.Typography.telemetryLabelTracking)
          .foregroundStyle(MetroPalette.secondaryInk)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text(metric.value).font(MetroFont.telemetryValue).lineLimit(1).minimumScaleFactor(0.6)
          if !metric.unit.isEmpty { Text(metric.unit).font(MetroFont.telemetryUnit) }
        }
        .foregroundStyle(Color(metro: metric.colour))
      }
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(metric.label.capitalized)
      .accessibilityValue(metric.spokenValue)
    }
  }

  // MARK: Event tiles

  /// A row of discrete event tiles (spec §12; Metro Station's beat grid): 37 pt tiles, radius 8, 7 pt apart. The
  /// active tile fills action cyan 0.08 with a cyan 0.35 border (the first position is amber when `emphasisFirst`); idle
  /// tiles fill white 0.025 with a white 0.06 border. Each tile shows its number (selected state is clear by number and
  /// position as well as colour) and optional 2 pt subdivision capsules. One accessibility element for the row.
  public struct MetroEventTiles: View {
    private let title: String
    private let status: String
    private let count: Int
    private let active: Int?
    private let subdivisions: Int
    private let activeSubdivision: Int?
    private let emphasisFirst: Bool
    private let labels: [String]?
    private let accessibilityValueText: String
    private let identifier: String
    @ScaledMetric(relativeTo: .caption2) private var numberSize = 12.0

    /// - Parameters:
    ///   - active: the index of the active tile, or nil when idle.
    ///   - labels: per-tile labels; `1…count` when nil.
    public init(
      title: String, status: String, count: Int, active: Int?, subdivisions: Int = 1, activeSubdivision: Int? = nil,
      emphasisFirst: Bool = true, labels: [String]? = nil, accessibilityValue: String,
      identifier: String = "metro-event-tiles"
    ) {
      self.title = title
      self.status = status
      self.count = max(1, count)
      self.active = active
      self.subdivisions = max(1, subdivisions)
      self.activeSubdivision = activeSubdivision
      self.emphasisFirst = emphasisFirst
      self.labels = labels
      self.accessibilityValueText = accessibilityValue
      self.identifier = identifier
    }

    public var body: some View {
      VStack(spacing: 8) {
        HStack {
          Text(title).tracking(1.7)
          Spacer(minLength: 8)
          Text(status).monospacedDigit()
        }
        .font(MetroFont.caption)
        .foregroundStyle(MetroPalette.secondaryInk)
        .lineLimit(1)
        HStack(spacing: Metro.Layout.eventTileRowGap) {
          ForEach(0..<count, id: \.self) { index in tile(index) }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title.capitalized)
      .accessibilityValue(accessibilityValueText)
      .accessibilityIdentifier(identifier)
    }

    private func tile(_ index: Int) -> some View {
      let isActive = active == index
      let accent = emphasisFirst && index == 0 ? MetroPalette.actionAmber : MetroPalette.actionCyan
      let label = labels.flatMap { index < $0.count ? $0[index] : nil } ?? "\(index + 1)"
      return VStack(spacing: 3) {
        Text(label).font(.system(size: numberSize, weight: .medium, design: .monospaced)).lineLimit(1)
          .minimumScaleFactor(0.7)
        if subdivisions > 1 {
          HStack(spacing: 3) {
            ForEach(0..<subdivisions, id: \.self) { pulse in
              Capsule().fill(isActive && activeSubdivision == pulse ? accent : .white.opacity(0.16)).frame(height: 2)
            }
          }
          .padding(.horizontal, 4)
        }
      }
      .foregroundStyle(isActive ? accent : MetroPalette.secondaryInk)
      .frame(maxWidth: .infinity, minHeight: Metro.Layout.eventTileHeight)
      .background(
        isActive ? MetroPalette.actionCyan.opacity(0.08) : .white.opacity(0.025),
        in: .rect(cornerRadius: Metro.Radius.beatTile)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Metro.Radius.beatTile)
          .stroke(isActive ? MetroPalette.actionCyan.opacity(0.35) : .white.opacity(0.06))
      )
    }
  }

  // MARK: Floating action group

  /// A secondary action beside the primary one: an SF Symbol and an optional short caption.
  public struct MetroSideAction {
    public let symbol: String
    public let caption: String?
    public let accessibilityLabel: String
    public let hint: String?
    public let identifier: String
    public let action: () -> Void

    public init(
      symbol: String, caption: String? = nil, accessibilityLabel: String, hint: String? = nil, identifier: String,
      action: @escaping () -> Void
    ) {
      self.symbol = symbol
      self.caption = caption
      self.accessibilityLabel = accessibilityLabel
      self.hint = hint
      self.identifier = identifier
      self.action = action
    }
  }

  /// The floating action group (spec §12 "Floating action group"): native glass over the page with no black backing
  /// strip, one prominent primary action (action cyan when idle, action amber while running) between optional
  /// secondary actions. Label frames: leading 62 × 58, primary flexible with minimum height 58, trailing 54 × 58; row
  /// spacing 12; glass container spacing 14. Native style padding enlarges the rendered glass; reserve the real
  /// footprint (`Metro.Layout.bottomContentReserve` is the source's 98 pt) so the last row stays reachable.
  public struct MetroFloatingActionGroup: View {
    private let title: String
    private let symbol: String
    private let isRunning: Bool
    private let primaryIdentifier: String
    private let primaryAction: () -> Void
    private let leading: MetroSideAction?
    private let trailing: MetroSideAction?
    private let status: String?

    /// - Parameter status: a constant-position line above the row (an error or an "applying" note); keep the text
    ///   explicit, never colour alone.
    public init(
      title: String, symbol: String, isRunning: Bool, primaryIdentifier: String = "action-primary",
      leading: MetroSideAction? = nil, trailing: MetroSideAction? = nil, status: String? = nil,
      primaryAction: @escaping () -> Void
    ) {
      self.title = title
      self.symbol = symbol
      self.isRunning = isRunning
      self.primaryIdentifier = primaryIdentifier
      self.primaryAction = primaryAction
      self.leading = leading
      self.trailing = trailing
      self.status = status
    }

    public var body: some View {
      VStack(spacing: 8) {
        if let status {
          Text(status).font(.caption).foregroundStyle(MetroPalette.actionAmber).multilineTextAlignment(.center)
            .accessibilityIdentifier("\(primaryIdentifier)-status")
        }
        GlassEffectContainer(spacing: Metro.Layout.transportGlassSpacing) {
          HStack(spacing: Metro.Layout.transportRowSpacing) {
            if let leading { side(leading, width: Metro.Layout.transportLeadingWidth) }
            Button(action: primaryAction) {
              HStack(spacing: 10) {
                Image(systemName: symbol)
                Text(title).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1)
                  .minimumScaleFactor(0.8)
              }
              .frame(maxWidth: .infinity, minHeight: Metro.Layout.transportLabelMinHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(isRunning ? MetroPalette.actionAmber : MetroPalette.actionCyan)
            .accessibilityIdentifier(primaryIdentifier)
            if let trailing { side(trailing, width: Metro.Layout.transportTrailingWidth) }
          }
        }
      }
    }

    private func side(_ item: MetroSideAction, width: CGFloat) -> some View {
      Button(action: item.action) {
        VStack(spacing: 3) {
          Image(systemName: item.symbol).font(.system(size: item.caption == nil ? 20 : 18))
          if let caption = item.caption {
            Text(caption).font(.system(.caption2, design: .monospaced)).tracking(1).lineLimit(1).minimumScaleFactor(0.7)
          }
        }
        .frame(width: width, height: Metro.Layout.transportLabelMinHeight)
      }
      .buttonStyle(.glass)
      .accessibilityLabel(item.accessibilityLabel)
      .accessibilityHint(item.hint ?? "")
      .accessibilityIdentifier(item.identifier)
    }
  }

  extension View {
    /// Floats `group` over the bottom of this (scrolling) view with Metro's transport insets (horizontal 22, top 10,
    /// bottom 12). The content should reserve the group's real footprint at its end.
    public func metroFloatingActions(_ group: MetroFloatingActionGroup) -> some View {
      overlay(alignment: .bottom) {
        group
          .padding(.horizontal, Metro.Spacing.transportInset)
          .padding(.top, Metro.Spacing.transportTop)
          .padding(.bottom, Metro.Spacing.transportBottom)
      }
    }
  }
#endif
