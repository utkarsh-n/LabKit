#if os(iOS)
import LabKitCore
import SwiftUI
import UIKit

// The stage's touch and accessibility surface (labkit-from-gyre.md §3.4, labkit-from-orbitals-spectra.md
// §3.13). It is transparent: the Metal view draws behind it. Its global frame places the Metal camera.

/// One finger on the canvas, in region-local points (origin top-left, y down).
nonisolated public struct CanvasTouch: Identifiable, Sendable, Hashable {
  public enum Phase: Sendable, Hashable { case began, moved, stationary, ended, cancelled }
  /// Stable for the life of the finger; small integers, reused after lift.
  public let id: Int
  public var location: CGPoint
  /// Where this finger came down.
  public var start: CGPoint
  public var phase: Phase
  /// Seconds since boot (`UITouch.timestamp`), for finger-speed estimates.
  public var timestamp: TimeInterval
  public var isActive: Bool { phase != .ended && phase != .cancelled }
}

/// Every finger on the canvas at one moment: those still down, plus any that just lifted.
nonisolated public struct CanvasTouches: Sendable {
  public var touches: [CanvasTouch]
  /// The region's size, so callers can normalise.
  public var size: CGSize
  public var active: [CanvasTouch] { touches.filter(\.isActive) }
  /// True when no finger remains down (the last event of a gesture).
  public var isEnd: Bool { active.isEmpty }
  /// Centroid of the fingers still down.
  public var centroid: CGPoint? {
    let a = active
    guard !a.isEmpty else { return nil }
    let s = a.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.location.x, y: $0.y + $1.location.y) }
    return CGPoint(x: s.x / CGFloat(a.count), y: s.y / CGFloat(a.count))
  }
}

/// A two-finger gesture: pan of the centroid and pinch scale, both relative to when the second
/// finger landed. Rheo: two-finger drag = simulated tilt (Simulator), pinch = zoom.
nonisolated public struct CanvasTwoFinger: Sendable {
  public enum Phase: Sendable { case began, changed, ended }
  public var phase: Phase
  /// Centroid travel since the gesture began (points).
  public var translation: CGSize
  /// Centroid travel since the previous event (points).
  public var delta: CGSize
  /// Finger spread relative to the start (1 = unchanged).
  public var scale: Double
  /// Current centroid, region-local.
  public var anchor: CGPoint
}

/// The space between the bars: a transparent, multi-touch surface over the Metal stage, and one
/// accessibility element with a live value and named actions (Gyre ContentView.swift:66-98).
///
/// - `onFrame`: its global frame, for the render host's camera (the tank region).
/// - `onTouch`: every touch change, all fingers (poke, stir, punch).
/// - `onTwoFinger`: two-finger pan and pinch, derived from the same touches.
/// - `adjust`: the VoiceOver adjustable action for the main continuous gesture (Rheo: stir speed), +1/−1.
/// - `onKey`: hardware keys while focused (arrows tilt, space pokes, +/− zoom); return true if handled.
/// - Identifier `stage-canvas` by default.
public struct CanvasRegion: View {
  public struct Action: Identifiable {
    public let id: String
    public let run: () -> Void
    public init(_ name: String, _ run: @escaping () -> Void) {
      self.id = name
      self.run = run
    }
  }

  let label: String
  let value: String
  let hint: String
  let actions: [Action]
  let identifier: String
  let adjust: ((Int) -> Void)?
  let onKey: ((KeyPress) -> Bool)?
  let onFrame: (CGRect) -> Void
  let onTouch: (CanvasTouches) -> Void
  let onTwoFinger: ((CanvasTwoFinger) -> Void)?

  public init(
    label: String, value: String, hint: String, actions: [Action] = [], identifier: String = "stage-canvas",
    adjust: ((Int) -> Void)? = nil, onKey: ((KeyPress) -> Bool)? = nil,
    onFrame: @escaping (CGRect) -> Void,
    onTouch: @escaping (CanvasTouches) -> Void,
    onTwoFinger: ((CanvasTwoFinger) -> Void)? = nil
  ) {
    self.label = label
    self.value = value
    self.hint = hint
    self.actions = actions
    self.identifier = identifier
    self.adjust = adjust
    self.onKey = onKey
    self.onFrame = onFrame
    self.onTouch = onTouch
    self.onTwoFinger = onTwoFinger
  }

  /// The prototype's single-finger form: `onTouch(location, size, ended)` for the first finger, and
  /// `onMagnify(scale, ended)` for a pinch.
  public init(
    label: String, value: String, hint: String, actions: [Action] = [],
    onFrame: @escaping (CGRect) -> Void,
    onTouch: @escaping (_ location: CGPoint, _ size: CGSize, _ ended: Bool) -> Void,
    onMagnify: ((CGFloat, Bool) -> Void)? = nil
  ) {
    self.init(
      label: label, value: value, hint: hint, actions: actions, onFrame: onFrame,
      onTouch: { t in
        guard let first = t.touches.first else { return }
        onTouch(first.location, t.size, t.isEnd)
      },
      onTwoFinger: onMagnify.map { magnify in
        { (g: CanvasTwoFinger) in magnify(CGFloat(g.scale), g.phase == .ended) }
      })
  }

  public var body: some View {
    TouchSurface(onTouch: onTouch, onTwoFinger: onTwoFinger)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
      .focusable(onKey != nil)
      .onKeyPress { press in (onKey?(press) ?? false) ? .handled : .ignored }
      .accessibilityElement()
      .accessibilityLabel(label)
      .accessibilityValue(value)
      .accessibilityHint(hint)
      .modifier(AdjustableAction(adjust: adjust))
      .accessibilityActions {
        ForEach(actions) { a in Button(a.id, action: a.run) }
      }
      .accessibilityIdentifier(identifier)
      .accessibilityIgnoresInvertColors()
  }
}

private struct AdjustableAction: ViewModifier {
  let adjust: ((Int) -> Void)?
  func body(content: Content) -> some View {
    if let adjust {
      content.accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: adjust(1)
        case .decrement: adjust(-1)
        @unknown default: break
        }
      }
    } else {
      content
    }
  }
}

/// A UIKit view that reports raw multi-touch: SwiftUI gestures don't give stable per-finger tracks
/// together with a pinch on one surface.
private struct TouchSurface: UIViewRepresentable {
  let onTouch: (CanvasTouches) -> Void
  let onTwoFinger: ((CanvasTwoFinger) -> Void)?

  func makeUIView(context: Context) -> TouchSurfaceView {
    let v = TouchSurfaceView()
    v.onTouch = onTouch
    v.onTwoFinger = onTwoFinger
    return v
  }

  func updateUIView(_ v: TouchSurfaceView, context: Context) {
    v.onTouch = onTouch
    v.onTwoFinger = onTwoFinger
  }
}

final class TouchSurfaceView: UIView {
  var onTouch: ((CanvasTouches) -> Void)?
  var onTwoFinger: ((CanvasTwoFinger) -> Void)?

  private var ids: [ObjectIdentifier: Int] = [:]
  private var starts: [ObjectIdentifier: CGPoint] = [:]
  private var live: [ObjectIdentifier: UITouch] = [:]
  private var pair: (a: ObjectIdentifier, b: ObjectIdentifier, centroid: CGPoint, spread: CGFloat, last: CGPoint)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    isExclusiveTouch = false
    backgroundColor = .clear
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches {
      let key = ObjectIdentifier(t)
      ids[key] = nextID()
      starts[key] = t.location(in: self)
      live[key] = t
    }
    report(changed: touches, phase: .began)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(changed: touches, phase: .moved) }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, phase: .ended) }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, phase: .cancelled) }

  private func nextID() -> Int {
    var i = 0
    let used = Set(ids.values)
    while used.contains(i) { i += 1 }
    return i
  }

  private func finish(_ touches: Set<UITouch>, phase: CanvasTouch.Phase) {
    report(changed: touches, phase: phase)
    for t in touches {
      let key = ObjectIdentifier(t)
      ids[key] = nil
      starts[key] = nil
      live[key] = nil
    }
  }

  private func report(changed: Set<UITouch>, phase: CanvasTouch.Phase) {
    let changedKeys = Set(changed.map(ObjectIdentifier.init))
    var list: [CanvasTouch] = []
    for (key, t) in live {
      guard let id = ids[key] else { continue }
      let p = t.location(in: self)
      list.append(
        CanvasTouch(
          id: id, location: p, start: starts[key] ?? p, phase: changedKeys.contains(key) ? phase : .stationary,
          timestamp: t.timestamp))
    }
    list.sort { $0.id < $1.id }
    onTouch?(CanvasTouches(touches: list, size: bounds.size))
    updatePair(phase: phase, changed: changedKeys)
  }

  /// Two-finger pan and pinch from the first two fingers down.
  private func updatePair(phase: CanvasTouch.Phase, changed: Set<ObjectIdentifier>) {
    guard let onTwoFinger else { return }
    let down = live.keys.filter { key in
      !(changed.contains(key) && (phase == .ended || phase == .cancelled))
    }.sorted { (ids[$0] ?? 0) < (ids[$1] ?? 0) }
    func point(_ k: ObjectIdentifier) -> CGPoint { live[k]?.location(in: self) ?? .zero }
    if var p = pair {
      let stillDown = down.contains(p.a) && down.contains(p.b)
      let a = point(p.a), b = point(p.b)
      let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
      let spread = max(1, hypot(a.x - b.x, a.y - b.y))
      let g = CanvasTwoFinger(
        phase: stillDown ? .changed : .ended,
        translation: CGSize(width: c.x - p.centroid.x, height: c.y - p.centroid.y),
        delta: CGSize(width: c.x - p.last.x, height: c.y - p.last.y),
        scale: Double(spread / p.spread), anchor: c)
      onTwoFinger(g)
      if stillDown {
        p.last = c
        pair = p
      } else {
        pair = nil
      }
    } else if down.count >= 2 {
      let a = point(down[0]), b = point(down[1])
      let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
      pair = (down[0], down[1], c, max(1, hypot(a.x - b.x, a.y - b.y)), c)
      onTwoFinger(CanvasTwoFinger(phase: .began, translation: .zero, delta: .zero, scale: 1, anchor: c))
    }
  }
}
#endif
