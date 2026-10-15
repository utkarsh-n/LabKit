#if os(iOS)
import LabKitCore
import LabKitFeedback
import SwiftUI

/// The Experiments menu for `LabTopBar` (labkit-from-orbitals-spectra.md §3.11): a `flask.fill` glyph
/// whose section header promises only the effects every experiment shares ("Experiments · each refills
/// the tank and restarts the clock."), with two-line items (title + subtitle). The current experiment
/// is **derived** (pass `Experiment.matching(...)`), so editing any knob reverts the label.
///
/// `apply` is the app's: `store.apply(experiment)`, select the material, honour the effects, then
/// `haptics.success()`, a 6.5 s `statusBanner` with the note and a VoiceOver announcement
/// (`experiment.announcement`). Opening the menu plays `.tap`.
public struct ExperimentMenu: View {
  let experiments: [Experiment]
  let current: Experiment?
  let apply: (Experiment) -> Void
  @Environment(\.labHaptics) private var haptics

  public init(_ experiments: [Experiment], current: Experiment?, apply: @escaping (Experiment) -> Void) {
    self.experiments = experiments
    self.current = current
    self.apply = apply
  }

  public var body: some View {
    Menu {
      Section(Experiment.commonEffects(experiments).menuHeader) {
        ForEach(experiments) { e in
          Button {
            apply(e)
          } label: {
            Label(e.title, systemImage: e.id == current?.id ? "checkmark" : e.icon)
            Text(e.subtitle)
          }
          .accessibilityIdentifier("experiment-\(e.id)")
        }
      }
    } label: {
      ToolbarGlyph("flask.fill", title: current?.title ?? "Experiments")
    }
    .simultaneousGesture(TapGesture().onEnded { haptics?.play(.tap) })
    .accessibilityLabel("Experiments")
    .accessibilityValue(current?.title ?? "None")
    .accessibilityIdentifier("topbar-experiments")
  }
}

extension ParamStore {
  /// Writes an experiment's values with `LabMotion.experiment` (no animation under Reduce Motion).
  public func apply(_ experiment: Experiment, reduceMotion: Bool = false) {
    withLabAnimation(LabMotion.experiment, reduceMotion: reduceMotion) { apply(experiment.values) }
  }

  /// The experiment the store's values currently match, if any. Reads (and, in a view body, observes)
  /// only the parameters the experiments set, so the menu label doesn't redraw for unrelated knobs.
  public func matchingExperiment(_ all: [Experiment], material: String?) -> Experiment? {
    Experiment.matching(snapshot(Set(all.flatMap(\.values.keys))), material: material, in: all)
  }
}
#endif
