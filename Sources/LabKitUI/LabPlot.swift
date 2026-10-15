#if os(iOS)
import Accessibility
import LabKitCore
import SwiftUI

/// A phosphor plot on a SwiftUI `Canvas` (labkit-from-orbitals-spectra.md §3.12): linear or log10 axes
/// from `PlotAxis` (decade labels, crowded labels thinned), glowing lines (spectra-lab `glowLine`: a
/// 3.2× under-stroke at the series' glow alpha), hollow measured markers and filled live dots, dashed
/// guides whose labels are **culled on collision**, and the live cursor as a signature ring.
///
/// Redraw it at the 10 Hz telemetry rate, not per frame. Accessibility: one element (label = title,
/// value = `summary`, a sentence the app writes when the material changes) plus an `AXChartDescriptor`
/// with log10 scale on log axes, so VoiceOver's Audio Graph can play the curves. Under Differentiate
/// Without Colour, line series after the first get distinct dash patterns.
public struct LabPlot: View {
  let title: String
  let x: PlotAxis
  let y: PlotAxis
  let series: [PlotSeries]
  let guides: [PlotGuide]
  let cursor: SIMD2<Double>?
  let summary: String
  let identifier: String?
  @Environment(\.labPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityDifferentiateWithoutColor) private var noColourOnly
  @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 9.5

  public init(
    title: String, x: PlotAxis, y: PlotAxis, series: [PlotSeries], guides: [PlotGuide] = [],
    cursor: SIMD2<Double>? = nil, summary: String, identifier: String? = nil
  ) {
    self.title = title
    self.x = x
    self.y = y
    self.series = series
    self.guides = guides
    self.cursor = cursor
    self.summary = summary
    self.identifier = identifier
  }

  public var body: some View {
    let style = PlotStyle(
      ground: palette.ground, signature: palette.signature, increasedContrast: contrast == .increased,
      dashSeries: noColourOnly, labelSize: min(labelSize, 13))
    Canvas { context, size in
      PlotRenderer(x: x, y: y, series: series, guides: guides, cursor: cursor, style: style).draw(in: &context, size: size)
    }
    .clipShape(.rect(cornerRadius: LabMetrics.canvasRadius))
    .overlay {
      RoundedRectangle(cornerRadius: LabMetrics.canvasRadius)
        .strokeBorder(Color(LabSemantic.live, opacity: 0.2))
        .allowsHitTesting(false)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(summary)
    .accessibilityChartDescriptor(LabPlotDescriptor(title: title, summary: summary, x: x, y: y, series: series))
    .accessibilityIgnoresInvertColors()
    .accessibilityIdentifier(identifier.map { "plot-\($0)" } ?? "plot")
  }
}

struct PlotStyle {
  let ground: LabGround
  let signature: LabColor
  let increasedContrast: Bool
  let dashSeries: Bool
  let labelSize: CGFloat
}

/// The drawing, separated from the view so the layout rules read top to bottom.
struct PlotRenderer {
  let x: PlotAxis
  let y: PlotAxis
  let series: [PlotSeries]
  let guides: [PlotGuide]
  let cursor: SIMD2<Double>?
  let style: PlotStyle

  /// Insets: leading 44, bottom 33, top 10, trailing 12, scaled with the label size. §3.12 says bottom
  /// 30; measured, the x caption under the tick labels then touched the frame's rounded corner.
  func plotRect(_ size: CGSize) -> CGRect {
    let k = style.labelSize / 9.5
    let leading = 44 * k, bottom = 33 * k, top: CGFloat = 10, trailing: CGFloat = 12
    return CGRect(
      x: leading, y: top, width: max(1, size.width - leading - trailing), height: max(1, size.height - top - bottom))
  }

  func draw(in context: inout GraphicsContext, size: CGSize) {
    let rect = plotRect(size)
    let font = Font.system(size: style.labelSize, design: .monospaced)
    let muted = Color(style.ground.muted)
    func point(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height) }

    context.fill(Path(rect), with: .color(Color(style.ground.plot)))

    // Grid, ticks and tick labels. Labels that would collide with one already drawn are dropped.
    var placed: [CGRect] = []
    // Labels stay inside the canvas (measured: "1000" centred on the last x tick ran into the frame).
    let canvas = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 2)
    func label(_ text: String, at p: CGPoint, anchor: UnitPoint, colour: Color, in ctx: inout GraphicsContext) -> Bool {
      let resolved = ctx.resolve(Text(text).font(font).foregroundStyle(colour))
      let s = resolved.measure(in: CGSize(width: 400, height: 100))
      var r = CGRect(x: p.x - anchor.x * s.width, y: p.y - anchor.y * s.height, width: s.width, height: s.height)
      r.origin.x = min(max(r.minX, canvas.minX), canvas.maxX - r.width)
      r.origin.y = min(max(r.minY, canvas.minY), canvas.maxY - r.height)
      guard !placed.contains(where: { $0.insetBy(dx: -2, dy: -1).intersects(r) }) else { return false }
      placed.append(r)
      ctx.draw(resolved, in: r)
      return true
    }
    let grid = Color(LabSemantic.live, opacity: style.increasedContrast ? 0.16 : 0.06)
    let yTicks = y.ticks(length: Double(rect.height), minSpacing: 22 * Double(style.labelSize / 9.5))
    let xTicks = x.ticks(length: Double(rect.width), minSpacing: 40 * Double(style.labelSize / 9.5))
    for t in yTicks where t.position >= -1e-9 && t.position <= 1 + 1e-9 {
      let py = rect.maxY - t.position * rect.height
      var line = Path()
      line.move(to: CGPoint(x: rect.minX, y: py))
      line.addLine(to: CGPoint(x: rect.maxX, y: py))
      context.stroke(line, with: .color(grid), lineWidth: t.isMajor ? 1 : 0.5)
      if let text = t.label {
        _ = label(text, at: CGPoint(x: rect.minX - 5, y: py), anchor: .trailing, colour: muted, in: &context)
      }
    }
    for t in xTicks where t.position >= -1e-9 && t.position <= 1 + 1e-9 {
      let px = rect.minX + t.position * rect.width
      var line = Path()
      line.move(to: CGPoint(x: px, y: rect.minY))
      line.addLine(to: CGPoint(x: px, y: rect.maxY))
      context.stroke(line, with: .color(grid), lineWidth: t.isMajor ? 1 : 0.5)
      if let text = t.label {
        _ = label(text, at: CGPoint(x: px, y: rect.maxY + 4), anchor: .top, colour: muted, in: &context)
      }
    }
    var frame = Path()
    frame.move(to: CGPoint(x: rect.minX, y: rect.minY))
    frame.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    frame.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    context.stroke(frame, with: .color(Color(style.ground.muted, opacity: 0.35)), lineWidth: 1)
    // Axis captions: x at the bottom right under the labels, y inside the top-left corner.
    _ = label(x.caption(), at: CGPoint(x: rect.maxX - 2, y: rect.maxY + 4 + style.labelSize * 1.35), anchor: .topTrailing, colour: muted, in: &context)
    _ = label(y.caption(), at: CGPoint(x: rect.minX + 5, y: rect.minY + 3), anchor: .topLeading, colour: muted, in: &context)

    // Everything below is clipped to the plot rectangle.
    var plot = context
    plot.clip(to: Path(rect))

    // Guides: dashed dim lines; their labels avoid each other, the tick labels and the series' last 10 %.
    var avoid: [CGRect] = []
    for s in series {
      for run in s.runs(x: x, y: y) {
        let tail = run.suffix(max(2, run.count / 10)).map(point)
        if let first = tail.first {
          avoid.append(tail.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -4, dy: -4))
        }
      }
    }
    if let cursor, let px = x.position(cursor.x), let py = y.position(cursor.y) {
      let c = point(SIMD2(px, py))
      avoid.append(CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28))
    }
    let dim = Color(style.ground.dim)
    let guideLines = guides.map { $0.polyline(x: x, y: y).map(point) }
    // True when any guide line passes through `r` (segments are sampled every quarter; guides are
    // 48-point polylines, so samples sit about 2 pt apart in a 374 pt plot).
    func crossesGuide(_ r: CGRect) -> Bool {
      let box = r.insetBy(dx: -1.5, dy: -1.5)
      for pts in guideLines where pts.count >= 2 {
        for i in 0..<(pts.count - 1) {
          let a = pts[i], b = pts[i + 1]
          for k in 0...4 {
            let t = CGFloat(k) / 4
            if box.contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { return true }
          }
        }
      }
      return false
    }
    for pts in guideLines {
      guard pts.count >= 2 else { continue }
      var path = Path()
      path.addLines(pts)
      plot.stroke(path, with: .color(dim.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }
    for (guide, pts) in zip(guides, guideLines) where !guide.label.isEmpty {
      let resolved = plot.resolve(Text(guide.label).font(font).foregroundStyle(dim))
      let s = resolved.measure(in: CGSize(width: 400, height: 100))
      // Anchors: where the line leaves the plot, then 25 % and 50 % back along it. At each, try the
      // four sides of the point; a label may not cross any guide line, another label, a series' last
      // 10 % or the cursor. A guide whose label finds no room stays unlabelled (the summary names it).
      let visible = pts.filter { rect.insetBy(dx: -1, dy: -1).contains($0) }
      guard !visible.isEmpty else { continue }
      search: for back in [0.0, 0.25, 0.5] {
        let p = visible[max(0, Int(Double(visible.count - 1) * (1 - back)))]
        let candidates = [
          CGPoint(x: p.x - s.width - 3, y: p.y - s.height - 2), CGPoint(x: p.x + 3, y: p.y + 2),
          CGPoint(x: p.x - s.width - 3, y: p.y + 2), CGPoint(x: p.x + 3, y: p.y - s.height - 2),
        ]
        for o in candidates {
          var r = CGRect(origin: o, size: s)
          r.origin.x = min(max(r.minX, rect.minX + 3), rect.maxX - s.width - 3)
          r.origin.y = min(max(r.minY, rect.minY + 2), rect.maxY - s.height - 2)
          guard rect.contains(r), !crossesGuide(r),
            !placed.contains(where: { $0.insetBy(dx: -2, dy: -1).intersects(r) }),
            !avoid.contains(where: { $0.intersects(r) })
          else { continue }
          placed.append(r)
          plot.draw(resolved, in: r)
          break search
        }
      }
    }

    // Series.
    let patterns: [[CGFloat]] = [[], [6, 3], [2, 3], [8, 3, 2, 3]]
    for (index, s) in series.enumerated() {
      let colour = Color(s.colour, opacity: s.opacity)
      for run in s.runs(x: x, y: y) {
        let pts = run.map(point)
        switch s.style {
        case .line(let width, let glow, let dash):
          var path = Path()
          path.addLines(pts)
          let pattern = dash.isEmpty && style.dashSeries ? patterns[index % patterns.count] : dash.map { CGFloat($0) }
          if glow > 0 {
            plot.stroke(
              path, with: .color(Color(s.colour, opacity: glow * s.opacity)),
              style: StrokeStyle(lineWidth: width * 3.2, lineCap: .round, lineJoin: .round, dash: pattern))
          }
          plot.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: pattern))
        case .markers(let d, let hollow):
          for p in pts {
            let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            if hollow {
              plot.stroke(Path(ellipseIn: r), with: .color(colour), lineWidth: 1.5)
            } else {
              plot.fill(Path(ellipseIn: r.insetBy(dx: -d * 0.6, dy: -d * 0.6)), with: .color(Color(s.colour, opacity: 0.22 * s.opacity)))
              plot.fill(Path(ellipseIn: r), with: .color(colour))
            }
          }
        }
      }
    }

    // Cursor: a 14 pt signature ring with a 0.18 halo and a white core.
    if let cursor, let px = x.position(cursor.x), let py = y.position(cursor.y) {
      let c = point(SIMD2(px, py))
      let ring = CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)
      plot.fill(Path(ellipseIn: ring.insetBy(dx: -6, dy: -6)), with: .color(Color(style.signature, opacity: 0.18)))
      plot.stroke(Path(ellipseIn: ring), with: .color(Color(style.signature)), lineWidth: 2)
      plot.fill(Path(ellipseIn: ring.insetBy(dx: 4.5, dy: 4.5)), with: .color(.white))
    }
  }
}

/// The Audio Graph for VoiceOver: the same axes (log10 where the plot is logarithmic) and series.
nonisolated struct LabPlotDescriptor: AXChartDescriptorRepresentable {
  let title: String
  let summary: String
  let x: PlotAxis
  let y: PlotAxis
  let series: [PlotSeries]

  func makeChartDescriptor() -> AXChartDescriptor {
    func axis(_ a: PlotAxis) -> AXNumericDataAxisDescriptor {
      let unit = a.unit
      let d = AXNumericDataAxisDescriptor(
        title: a.caption(long: true), range: a.domain,
        gridlinePositions: a.ticks(length: 300).filter(\.isMajor).map(\.value),
        valueDescriptionProvider: { v in
          LabFormat.spoken(unit.isEmpty ? LabFormat.sig3(v) : LabFormat.engineering(v, unit: unit))
        })
      d.scaleType = a.scale == .log10 ? .log10 : .linear
      return d
    }
    let described = series.map { s in
      let continuous: Bool =
        switch s.style {
        case .line: true
        case .markers: false
        }
      // Only points the plot can draw: finite, and positive on a log axis (Audio Graph's log10 scale
      // has no place for 0 or a negative value either).
      return AXDataSeriesDescriptor(
        name: "\(s.label), \(s.provenance.badge)", isContinuous: continuous,
        dataPoints: s.points.filter { x.position($0.x) != nil && y.position($0.y) != nil }
          .map { AXDataPoint(x: $0.x, y: $0.y) })
    }
    return AXChartDescriptor(
      title: title, summary: summary, xAxis: axis(x), yAxis: axis(y), additionalAxes: [], series: described)
  }
}
#endif
