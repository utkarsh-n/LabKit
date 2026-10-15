#if os(iOS)
  import SwiftUI
  import UIKit
  import UIKit.UIGestureRecognizerSubclass

  // InstrumentControlTouchBoundary (Metro Station `ScrollGestureBoundary`, the starter's production edition without
  // the DEBUG audit hooks). The decisions live in `MetroTouchOwnership` / `MetroTouchSequence` (pure, tested); this file
  // only attaches them to UIKit.

  extension View {
    /// Touches that **begin** inside this view belong to it for the complete touch sequence: the nearest containing
    /// `UIScrollView`'s pan waits for, and fails with, a boundary recogniser while such a touch is down, so a held
    /// Stepper, a crown drag or a rim scrub never turns into a page scroll. Touches that begin anywhere else scroll the
    /// page as usual (they never wait on the boundary). The boundary never cancels the control's own touches.
    ///
    /// Apply it to the actual framed control bounds (the full native button, including its top and bottom edges).
    /// Higher nested scroll views and a sheet's interactive dismissal need their own host checks; a fixed outer frame
    /// alone does not prove the native button owns every edge touch (spec §9).
    public func metroControlOwnsTouches(identifier: String = "control") -> some View {
      modifier(MetroTouchBoundaryModifier(identifier: identifier))
    }
  }

  private struct MetroTouchBoundaryModifier: ViewModifier {
    let identifier: String

    func body(content: Content) -> some View {
      content.background {
        MetroTouchMarker(identifier: identifier)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }

  private struct MetroTouchMarker: UIViewRepresentable {
    let identifier: String

    func makeCoordinator() -> MetroTouchCoordinator { MetroTouchCoordinator() }

    func makeUIView(context: Context) -> MetroTouchMarkerView {
      let view = MetroTouchMarkerView()
      view.backgroundColor = .clear
      view.isUserInteractionEnabled = false
      view.isAccessibilityElement = false
      view.coordinator = context.coordinator
      context.coordinator.identifier = identifier
      context.coordinator.marker = view
      return view
    }

    func updateUIView(_ view: MetroTouchMarkerView, context: Context) {
      view.coordinator = context.coordinator
      context.coordinator.identifier = identifier
      context.coordinator.marker = view
      context.coordinator.updateAttachment()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MetroTouchMarkerView, context: Context) -> CGSize? {
      guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
      return CGSize(width: max(0, width), height: max(0, height))
    }

    static func dismantleUIView(_ view: MetroTouchMarkerView, coordinator: MetroTouchCoordinator) {
      view.coordinator = nil
      coordinator.detach()
      coordinator.marker = nil
    }
  }

  /// The invisible marker that sits behind the control and defines the owned region.
  final class MetroTouchMarkerView: UIView {
    weak var coordinator: MetroTouchCoordinator?

    override func didMoveToSuperview() {
      super.didMoveToSuperview()
      coordinator?.updateAttachment()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      coordinator?.updateAttachment()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      coordinator?.updateAttachment()
    }
  }

  final class MetroTouchCoordinator: NSObject, UIGestureRecognizerDelegate {
    var identifier = "control"
    weak var marker: MetroTouchMarkerView?
    private weak var scrollView: UIScrollView?
    private var recogniser: MetroImmediateTouchRecogniser?

    /// Attaches one boundary recogniser to the nearest containing scroll view (or detaches when there is none).
    func updateAttachment() {
      guard let marker, marker.window != nil else {
        detach()
        return
      }
      var ancestor = marker.superview
      var containing: UIScrollView?
      while let view = ancestor {
        if let scroll = view as? UIScrollView {
          containing = scroll
          break
        }
        ancestor = view.superview
      }
      guard let containing else {
        detach()
        return
      }
      if scrollView === containing, recogniser?.view === containing { return }
      detach()
      let boundary = MetroImmediateTouchRecogniser(target: nil, action: nil)
      boundary.name = "metroControlOwnsTouches.\(identifier)"
      boundary.cancelsTouchesInView = false
      boundary.delaysTouchesBegan = false
      boundary.delaysTouchesEnded = false
      boundary.requiresExclusiveTouchType = false
      boundary.scrollPan = containing.panGestureRecognizer
      boundary.delegate = self
      scrollView = containing
      recogniser = boundary
      containing.addGestureRecognizer(boundary)
      // The delegate sets up the failure requirement lazily for each sequence, so reparenting never leaves a
      // permanent require(toFail:) link behind.
    }

    func detach() {
      guard let recogniser else {
        scrollView = nil
        return
      }
      recogniser.endAttachment()
      recogniser.delegate = nil
      recogniser.scrollPan = nil
      recogniser.view?.removeGestureRecognizer(recogniser)
      self.recogniser = nil
      scrollView = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard let marker, let scrollView else {
        recogniser?.rejectUnrelatedSequence()
        return false
      }
      let owns = MetroTouchOwnership.owns(
        location: touch.location(in: marker), markerBounds: marker.bounds, isHidden: marker.isHidden,
        alpha: Double(marker.alpha), sharesWindowWithScrollView: marker.window != nil && marker.window === scrollView.window)
      // An unrelated scroll touch must not wait on a merely possible recogniser whose delegate declined the touch.
      if !owns { recogniser?.rejectUnrelatedSequence() }
      return owns
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      MetroTouchOwnership.scrollPanMustWait(
        isBoundary: gestureRecognizer === recogniser,
        otherIsScrollPan: otherGestureRecognizer === scrollView?.panGestureRecognizer)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      MetroTouchOwnership.recognisesSimultaneously(
        otherIsScrollPan: otherGestureRecognizer === scrollView?.panGestureRecognizer)
    }
  }

  /// Begins on the first owned touch and ends with the last one, holding the scroll pan back in between.
  final class MetroImmediateTouchRecogniser: UIGestureRecognizer {
    weak var scrollPan: UIGestureRecognizer?
    private var sequence = MetroTouchSequence()

    private static func ids(_ touches: Set<UITouch>) -> [Int] { touches.map { Int(bitPattern: ObjectIdentifier($0)) } }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      sequence.touchesBegan(Self.ids(touches))
      sync()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
      sequence.touchesMoved()
      sync()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      sequence.touchesEnded(Self.ids(touches))
      sync()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      sequence.touchesCancelled()
      sync()
    }

    override func reset() {
      super.reset()
      sequence.reset()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
      MetroTouchOwnership.canPrevent(otherIsScrollPan: preventedGestureRecognizer === scrollPan)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func rejectUnrelatedSequence() {
      sequence.rejectUnrelated()
      sync()
    }

    func endAttachment() {
      sequence.detach()
      sync()
    }

    /// Mirrors the pure sequence onto UIKit's state (UIKit itself returns the recogniser to `.possible`).
    private func sync() {
      let next: UIGestureRecognizer.State
      switch sequence.phase {
      case .possible: return
      case .began: next = .began
      case .changed: next = .changed
      case .ended: next = .ended
      case .cancelled: next = .cancelled
      case .failed: next = .failed
      }
      if state != next { state = next }
    }
  }
#endif
