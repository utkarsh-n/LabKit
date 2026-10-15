#if os(iOS)
  import LabKitCore
  import SwiftUI

  /// A compact vertical signal channel (spec §11; Metro Station `MetroStationPillView`, generalised): a short channel
  /// title, an upper endpoint, a vertical trace region and a lower endpoint inside a stable capsule.
  ///
  /// Contract: the capsule outline, title and endpoint positions never change (0.8 pt outline: primary 0.36 → white
  /// 0.10 → secondary 0.38, primary 0.70 under Increased Contrast); a quiet reference trace stays visible; only the
  /// **interior** reacts, through `energy` (0…1, typically a `MetroPulseEnvelope` value sampled from the event's real
  /// age): a ribbon, a brighter trace and thicker stroke with a clear attack and decay. Reduce Motion keeps the
  /// reference static. The host supplies honest semantics: units, direction, normalisation and provenance in
  /// `accessibilityValue`.
  public struct MetroSignalPill: View {
    /// How the trace reads.
    public enum Kind: Sendable, Hashable {
      /// A bipolar trace (−1…1) down a centre spine: time runs downward, amplitude horizontally.
      case wave
      /// A unipolar distribution (0…1) from the leading edge: the axis runs upward (frequency), magnitude horizontally.
      case distribution
    }

    /// The two-colour family of a channel.
    public struct Family: Sendable, Hashable {
      public var primary: LabColor
      public var secondary: LabColor
      public init(primary: LabColor, secondary: LabColor) {
        self.primary = primary
        self.secondary = secondary
      }
      /// Wave primary / wave depth (continuous signal).
      public static let wave = Family(primary: Metro.Colour.wavePrimary, secondary: Metro.Colour.waveSecondary)
      /// Spectrum primary / spectrum depth (a second, independent channel).
      public static let spectrum = Family(
        primary: Metro.Colour.spectrumPrimary, secondary: Metro.Colour.spectrumSecondary)
    }

    private let title: String
    private let kind: Kind
    private let family: Family
    private let upperLabel: String
    private let lowerLabel: String
    private let reference: [Double]
    private let response: [Double]
    private let energy: Double
    private let marker: Double?
    private let accessibilityLabelText: String
    private let accessibilityValueText: String
    private let identifier: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .caption2) private var scaledTitleSize = Metro.Typography.pillTitle.size
    @ScaledMetric(relativeTo: .caption2) private var scaledAxisSize = Metro.Typography.pillAxis.size

    /// The enclosure is a fixed 28…42 pt instrument (contract 5), so its words scale only as far as they still fit
    /// whole (4 monospaced characters across the interior); at accessibility sizes the complete channel name and
    /// values are in the spoken label and value instead of being truncated on the capsule.
    private var titleSize: CGFloat { min(scaledTitleSize, Metro.Typography.pillTitle.size * Self.maximumTextScale) }
    private var axisSize: CGFloat { min(scaledAxisSize, Metro.Typography.pillAxis.size * Self.maximumTextScale) }
    /// Row heights keep the source's 14 pt and 11 pt at the base size and grow with the capped text.
    private var titleHeight: CGFloat { titleSize * 14 / Metro.Typography.pillTitle.size }
    private var axisHeight: CGFloat { axisSize * 11 / Metro.Typography.pillAxis.size }
    /// How far the pill's own words grow with Dynamic Type.
    static let maximumTextScale: CGFloat = 1.3

    /// - Parameters:
    ///   - reference: the quiet reference trace, top to bottom for `.wave` (−1…1), bottom to top for `.distribution`
    ///     (0…1). Resample it to at most a few hundred points; it is drawn every frame.
    ///   - response: the shape the interior energy takes (normalised to a peak of 1); `reference` when nil.
    ///   - energy: 0…1 interior energy; 0 at rest.
    ///   - marker: an amber carrier marker at 0…1 along the axis (`.distribution` reads it from the bottom).
    public init(
      title: String, kind: Kind, family: Family, upperLabel: String, lowerLabel: String, reference: [Double],
      response: [Double]? = nil, energy: Double = 0, marker: Double? = nil, accessibilityLabel: String,
      accessibilityValue: String, identifier: String
    ) {
      self.title = title
      self.kind = kind
      self.family = family
      self.upperLabel = upperLabel
      self.lowerLabel = lowerLabel
      self.reference = reference.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
      self.response = (response ?? reference).map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
      self.energy = energy.isFinite ? min(1, max(0, energy)) : 0
      self.marker = marker.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
      self.accessibilityLabelText = accessibilityLabel
      self.accessibilityValueText = accessibilityValue
      self.identifier = identifier
    }

    private var primary: Color { Color(metro: family.primary) }
    private var secondary: Color { Color(metro: family.secondary) }
    private var liveEnergy: Double { reduceMotion ? 0 : energy }

    public var body: some View {
      VStack(spacing: 3) {
        Text(title)
          .font(.system(size: titleSize, weight: .semibold, design: .monospaced))
          .foregroundStyle(primary)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .allowsTightening(true)
          .frame(height: titleHeight)
        axisText(upperLabel)
        Canvas { context, size in
          let plot = CGRect(x: 2, y: 2, width: max(1, size.width - 4), height: max(1, size.height - 4))
          drawCalibration(&context, plot: plot)
          switch kind {
          case .wave: drawWave(&context, plot: plot)
          case .distribution: drawDistribution(&context, plot: plot)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        axisText(lowerLabel)
      }
      .padding(.horizontal, 5)
      .padding(.vertical, 10)
      .frame(minWidth: 28, idealWidth: 40, maxWidth: 42, minHeight: 140, idealHeight: 190, maxHeight: Metro.Layout.pillHeightMax)
      .background {
        Capsule().fill(
          LinearGradient(colors: [MetroPalette.pillLight, MetroPalette.pillDark], startPoint: .leading, endPoint: .trailing))
      }
      .overlay {
        // Constant: never animated by events (contract 5).
        Capsule().strokeBorder(
          LinearGradient(
            colors: [
              primary.opacity(
                contrast == .increased ? Metro.Opacity.pillPrimaryBorderIncreasedContrast : Metro.Opacity.pillPrimaryBorder),
              .white.opacity(Metro.Opacity.pillMiddleBorder), secondary.opacity(Metro.Opacity.pillSecondaryBorder),
            ], startPoint: .topLeading, endPoint: .bottomTrailing),
          lineWidth: Metro.Stroke.pill)
      }
      .clipShape(Capsule())
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier(identifier)
      .accessibilityLabel(accessibilityLabelText)
      .accessibilityValue(accessibilityValueText)
    }

    private func axisText(_ text: String) -> some View {
      Text(text)
        .font(.system(size: axisSize, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(Metro.Opacity.supportingInk))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .allowsTightening(true)
        .frame(height: axisHeight)
    }

    private func drawCalibration(_ context: inout GraphicsContext, plot: CGRect) {
      for index in 0...4 {
        let y = plot.minY + plot.height * Double(index) / 4
        var tick = Path()
        tick.move(to: CGPoint(x: plot.minX, y: y))
        tick.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(tick, with: .color(.white.opacity(index == 0 || index == 4 ? 0.17 : 0.07)), lineWidth: 0.5)
      }
      var spine = Path()
      let x = kind == .wave ? plot.midX : plot.minX
      spine.move(to: CGPoint(x: x, y: plot.minY))
      spine.addLine(to: CGPoint(x: x, y: plot.maxY))
      context.stroke(spine, with: .color(primary.opacity(0.22)), lineWidth: 0.6)
    }

    private func drawWave(_ context: inout GraphicsContext, plot: CGRect) {
      let samples = reference
      guard samples.count > 1 else { return }
      let last = Double(samples.count - 1)
      var path = Path()
      for (index, sample) in samples.enumerated() {
        let point = CGPoint(x: plot.midX + sample * plot.width / 2, y: plot.minY + plot.height * Double(index) / last)
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      context.stroke(
        path,
        with: .linearGradient(
          Gradient(colors: [primary.opacity(0.42), secondary.opacity(0.36)]),
          startPoint: CGPoint(x: plot.midX, y: plot.minY), endPoint: CGPoint(x: plot.midX, y: plot.maxY)),
        style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))

      let energy = liveEnergy
      let shape = response
      guard energy > 0, shape.count > 1 else { return }
      let shapeLast = Double(shape.count - 1)
      let halfWidth = max(0, plot.width / 2 - 1) * energy
      var ribbon = Path()
      var pulse = Path()
      for (index, sample) in shape.enumerated() {
        let y = plot.minY + plot.height * Double(index) / shapeLast
        let upper = CGPoint(x: plot.midX + abs(sample) * halfWidth, y: y)
        let point = CGPoint(x: plot.midX + sample * halfWidth, y: y)
        if index == 0 {
          ribbon.move(to: upper)
          pulse.move(to: point)
        } else {
          ribbon.addLine(to: upper)
          pulse.addLine(to: point)
        }
      }
      for index in shape.indices.reversed() {
        ribbon.addLine(
          to: CGPoint(x: plot.midX - abs(shape[index]) * halfWidth, y: plot.minY + plot.height * Double(index) / shapeLast))
      }
      ribbon.closeSubpath()
      context.fill(
        ribbon,
        with: .linearGradient(
          Gradient(colors: [primary.opacity(0.36), secondary.opacity(0.22)]),
          startPoint: CGPoint(x: plot.midX, y: plot.minY), endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
      context.stroke(pulse, with: .color(primary.opacity(0.92)), style: StrokeStyle(lineWidth: 1.8 * energy, lineJoin: .round))
    }

    private func drawDistribution(_ context: inout GraphicsContext, plot: CGRect) {
      let bins = reference
      if bins.count > 1 {
        let path = distributionPath(bins, plot: plot, width: plot.width, scale: 1)
        var fill = path
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
        fill.closeSubpath()
        context.fill(
          fill,
          with: .linearGradient(
            Gradient(colors: [secondary.opacity(0.07), primary.opacity(0.025)]),
            startPoint: CGPoint(x: plot.maxX, y: plot.maxY), endPoint: CGPoint(x: plot.minX, y: plot.minY)))
        context.stroke(
          path,
          with: .linearGradient(
            Gradient(colors: [secondary.opacity(0.38), primary.opacity(0.42)]),
            startPoint: CGPoint(x: plot.maxX, y: plot.maxY), endPoint: CGPoint(x: plot.minX, y: plot.minY)),
          style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
      }
      let energy = liveEnergy
      if energy > 0, response.count > 1 {
        let pulse = distributionPath(response, plot: plot, width: plot.width - 1, scale: energy)
        var body = pulse
        body.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
        body.closeSubpath()
        context.fill(
          body,
          with: .linearGradient(
            Gradient(colors: [secondary.opacity(0.42), primary.opacity(0.22)]),
            startPoint: CGPoint(x: plot.maxX, y: plot.maxY), endPoint: CGPoint(x: plot.minX, y: plot.minY)))
        context.stroke(
          pulse, with: .color(secondary.opacity(0.94)), style: StrokeStyle(lineWidth: 1.8 * energy, lineJoin: .round))
      }
      if let marker {
        let amber = MetroPalette.carrier
        let y = plot.maxY - plot.height * marker
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(amber), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
        context.fill(Path(ellipseIn: CGRect(x: plot.maxX - 2, y: y - 1.8, width: 3.6, height: 3.6)), with: .color(amber))
      }
    }

    private func distributionPath(_ bins: [Double], plot: CGRect, width: CGFloat, scale: Double) -> Path {
      let last = Double(bins.count - 1)
      var path = Path()
      path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
      for (index, bin) in bins.enumerated() {
        path.addLine(
          to: CGPoint(x: plot.minX + width * max(0, bin) * scale, y: plot.maxY - plot.height * Double(index) / last))
      }
      return path
    }
  }
#endif
