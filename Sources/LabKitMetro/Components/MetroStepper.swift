#if os(iOS)
  import LabKitCore
  import LabKitFeedback
  import SwiftUI

  /// The native integer Stepper (spec §9; the starter's `InstrumentParameterStepper`): a short engineering label, a
  /// rounded monospaced-digit value with its unit, and the native minus/plus control inside a dark capsule (minimum
  /// height 48, horizontal padding 14, panel 0.85, action-cyan 0.14 border at 1 pt).
  ///
  /// Contract:
  /// - Native press-and-hold repeat stays active while the instrument redraws; keep this view outside any
  ///   `TimelineView` and give it a stable identity.
  /// - An accepted increment or decrement writes the Binding **once**, then plays one fine detent through
  ///   `.metroHaptics(_:)` (if injected), then calls `onAcceptedChange` with the value the Binding already holds. That
  ///   callback is a post-write notification for dependent work: never write or publish the same change again from it.
  /// - At a domain limit nothing happens: no write, no feedback, no callback.
  /// - The whole native control (including its top and bottom edges) owns the touches that begin on it.
  ///
  /// It formats its stored integer directly with whole digits. A quantity stored as tenths or as a preset index needs
  /// `MetroParamStepper` (a `ParamSpec` with its own format) or a domain-formatted label instead.
  public struct MetroIntegerStepper: View {
    @Binding private var value: Int
    private let label: String
    private let unit: String
    private let range: ClosedRange<Int>
    private let spokenUnit: String?
    private let identifier: String
    private let onEditingChanged: (Bool) -> Void
    private let onAcceptedChange: (Int) -> Void
    @Environment(\.metroHaptics) private var haptics

    public init(
      _ label: String, value: Binding<Int>, in range: ClosedRange<Int>, unit: String, spokenUnit: String? = nil,
      identifier: String = "metroStepper", onEditingChanged: @escaping (Bool) -> Void = { _ in },
      onAcceptedChange: @escaping (Int) -> Void = { _ in }
    ) {
      self.label = label
      self._value = value
      self.range = range
      self.unit = unit
      self.spokenUnit = spokenUnit
      self.identifier = identifier
      self.onEditingChanged = onEditingChanged
      self.onAcceptedChange = onAcceptedChange
    }

    public var body: some View {
      MetroStepperShell(
        label: label, valueText: MetroFormat.quantity(value, unit: unit),
        spokenValue: MetroFormat.join(MetroFormat.whole(value), unit: spokenUnit ?? LabFormat.spoken(unit)),
        identifier: identifier, onIncrement: { adjust(1) }, onDecrement: { adjust(-1) },
        onEditingChanged: onEditingChanged)
    }

    private func adjust(_ direction: Int) {
      guard MetroStepperLogic.canStep(value, direction: direction, in: range) else { return }
      value += direction
      haptics?.play(MetroDetentRole.fine.tap(direction: direction))
      // Post-write notification: the Binding already owns the change.
      onAcceptedChange(value)
    }
  }

  /// A native Stepper over one LabKit parameter (the `ParamSpec` / `ParamStore` bridge). Each press moves one fine step
  /// (`MetroParamStepping.fine`: one `step` of a stepped parameter, 1 % of the sweep of a continuous one, stopping on a
  /// labelled detent it would cross), writes `store[id]` once, plays one fine detent and calls `onAcceptedChange`. The
  /// value is shown with `MetroFormat.formatted` (whole digits for a whole-stepped parameter) and spoken consistently.
  public struct MetroParamStepper: View {
    private let store: ParamStore
    private let id: ParamID
    private let label: String?
    private let onEditingChanged: (Bool) -> Void
    private let onAcceptedChange: (Double) -> Void
    @Environment(\.metroHaptics) private var haptics

    public init(
      store: ParamStore, id: ParamID, label: String? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in },
      onAcceptedChange: @escaping (Double) -> Void = { _ in }
    ) {
      self.store = store
      self.id = id
      self.label = label
      self.onEditingChanged = onEditingChanged
      self.onAcceptedChange = onAcceptedChange
    }

    public var body: some View {
      let spec = store.spec(id)
      let value = store[id]
      MetroStepperShell(
        label: label ?? LabFormat.uppercasedLatin(spec.title), valueText: MetroFormat.formatted(spec, value),
        spokenValue: MetroFormat.spoken(spec, value), identifier: "metro-stepper-\(id.rawValue)",
        onIncrement: { adjust(1) }, onDecrement: { adjust(-1) }, onEditingChanged: onEditingChanged)
    }

    private func adjust(_ direction: Int) {
      guard let accepted = store.metroStep(id, direction: direction, role: .fine) else { return }
      haptics?.play(MetroDetentRole.fine.tap(direction: direction))
      onAcceptedChange(accepted)
    }
  }

  /// The shared Stepper look: native Stepper, scalable caption and value, accessibility-size stacking.
  struct MetroStepperShell: View {
    let label: String
    let valueText: String
    let spokenValue: String
    let identifier: String
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onEditingChanged: (Bool) -> Void
    @ScaledMetric(relativeTo: .caption2) private var labelSize = Metro.Typography.stepperLabelScalable.size
    @ScaledMetric(relativeTo: .body) private var valueSize = Metro.Typography.stepperValue.size
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
      Stepper {
        Group {
          if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
              caption
              number
            }
          } else {
            HStack(spacing: 10) {
              caption
              number
            }
          }
        }
      } onIncrement: {
        onIncrement()
      } onDecrement: {
        onDecrement()
      } onEditingChanged: { editing in
        onEditingChanged(editing)
      }
      .frame(minHeight: Metro.Layout.stepperMinHeight)
      .padding(.horizontal, Metro.Layout.stepperHorizontalPadding)
      .background(MetroPalette.content.opacity(Metro.Opacity.panelFill), in: .capsule)
      .overlay {
        Capsule().strokeBorder(MetroPalette.actionCyan.opacity(Metro.Opacity.stepperBorder), lineWidth: Metro.Stroke.panel)
          .allowsHitTesting(false)
      }
      .metroControlOwnsTouches(identifier: identifier)
      // The native Stepper stays VoiceOver-adjustable (its increment/decrement run the same accepted-change path);
      // only its words are set here, so displayed and spoken precision agree.
      .accessibilityLabel(label.capitalized)
      .accessibilityValue(spokenValue)
      .accessibilityHint("Hold plus or minus for repeated adjustments.")
      .accessibilityIdentifier(identifier)
    }

    private var caption: some View {
      Text(label)
        .font(MetroFont.font(Metro.Typography.stepperLabelScalable, size: labelSize))
        .tracking(Metro.Typography.stepperLabel.tracking)
        .foregroundStyle(MetroPalette.secondaryInk)
        .lineLimit(1)
    }

    private var number: some View {
      Text(valueText)
        .font(MetroFont.font(Metro.Typography.stepperValue, size: valueSize))
        .foregroundStyle(MetroPalette.actionCyan)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }
#endif
