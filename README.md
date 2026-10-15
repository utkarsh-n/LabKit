# LabKit

LabKit is the shared Swift package for Utkarsh's iOS 27 toy apps. It was lifted from Gyre, Orbitals, Tether and spectra-lab, and Rheo (the Non-Newtonian Toy, `../Rheo`) is its first and so far only adopter; the older apps have not been moved onto it. It gives every toy the same look ("glass over phosphor"), the same feel (knobs, haptics, sound) and the same physics plumbing (parameters, sensors with simulator fakes, a Metal render host, rigid bodies and a 2D continuum engine).

- **Platforms:** iOS 27 (iPhone, portrait) for apps; macOS 27 for the Mac harnesses and the UI-free modules' tests.
- **Language:** Swift 6.4 tools, Swift 6 language mode with strict concurrency, 0 warnings. Tests use XCTest.
- **Contract:** `Rheo/Documentation/ARCHITECTURE.md` is binding. The design rules come from `Rheo/Documentation/research/labkit-from-orbitals-spectra.md` and `labkit-from-gyre.md`.
- **Spelling:** British in everything a person reads. Public APIs take SI units.

Status words used below: **built** (compiled), **run** (executed and checked), **written** (code exists but was not exercised).

**Current status (QA pass, 9 October 2026, mirror `labkit-qa`, M1 Max at load 600–900).** Every check below was re-run on
the final sources: `labkit-physcheck` (all) 73 PASS, 0 FAIL (18 core + 55 MPM, V1–V12); `labkit-gpucheck all` 27 PASS,
0 FAIL, 4 recorded; `swift test --no-parallel` 180 tests, 0 failures (LabKitCoreTests 84, LabKitRigidTests 22,
LabKitRenderTests 9, LabKitMPMTests 24, LabKitMPMReferenceTests 41); `LabKit-Package` for the iOS Simulator and for
device: BUILD SUCCEEDED, 0 warnings. Rheo's own suites run against it (`../Rheo/VERIFICATION.md`). The sections further
down keep each package's original verification record; where a count there is older, this paragraph is current.

---

## Module map

| Product | What it holds | Isolation | Runs on |
|---|---|---|---|
| `LabKitCore` | Parameters (`ParamID`, `ParamSpec`, `ParamFormat`, `ParamStore`, `ParamValues`, `Detent`, `ConsolePage`, `KnobFocus`); colour and palettes (`LabColor`, `LabGround`, `LabSemantic`, `DataHue`, `LabPalette`); `LabFormat`; plot maths (`PlotAxis`, `PlotSeries`, `PlotGuide`); `Provenance`, `Citation`, `Experiment`, `ExperimentEffects`; `LabDisplay` (millimetres per point); `CopyLint`. Also the runtime maths: time, integrators, modulation, environment, DSP and the pure halves of the haptics/sound policy (see [Runtime](#runtime-core-sensors-feedback-render)). `ContinuumMaterial` and `ContinuumPresets` for the MPM engines. | nonisolated (`ParamStore` is `@MainActor @Observable`) | iOS, macOS |
| `LabKitSensors` | `MotionSource`, `MicListener`, `ThermalSource`, `LaunchOptions` | main actor, `@Sendable` handlers | iOS |
| `LabKitFeedback` | `HapticEngine`, `HapticTap`, `SynthHost`, `SynthKernel`, `SonicCue`, `LabFeedback`, `AudioRoute` | main actor, `@Sendable` handlers | iOS |
| `LabKitUI` | The design system and every component (below) | `defaultIsolation(MainActor)` | iOS |
| `LabKitMetro` | The Metro Station design system (edition 1.0): exact manifest tokens, type, materials, instrument components, the touch boundary, the lens shader in its own bundle, the `ParamSpec` bridge ([below](#labkitmetro-the-metro-station-design-system)) | `defaultIsolation(MainActor)`; tokens and logic `nonisolated` | iOS (logic and tests also macOS) |
| `LabKitRender` + `LabKitShaderTypes` | `LabRenderHost`, `LabRenderScene` (two-phase with a mipmapped `behind` copy for refraction), `PostChain` bloom/EDR, `LineBatch`, `LayoutCamera`, `MeshBuilder`; the shared C header | main actor | iOS (offscreen on macOS) |
| `LabKitRigid` | Box2D v3.1.1 behind an SI Swift API (`RigidWorld`) | confined to its owner | iOS, macOS |
| `LabKitMPM` + `LabKitMPMTypes` | GPU 2D MPM solver (PB-MPM port) and the fluid surface renderer | confined to its owner | iOS, macOS (Metal) |
| `LabKitMPMReference` | CPU `Double` MLS-MPM oracle with the same constitutive model | nonisolated | iOS, macOS |
| `labkit-physcheck`, `labkit-gpucheck` | Mac harnesses that print PASS/FAIL tables | — | macOS |

Dependencies point one way: Core ← Feedback ← Sensors; Core + Feedback ← UI, Metro; Core + ShaderTypes ← Render; Core ← Rigid, MPM, MPMReference. `CBox2D` is never a product.

---

## LabKitUI: the design system

Three layers, three materials (`labkit-from-orbitals-spectra.md` §2.1):

| Layer | What lives there | Material | Type |
|---|---|---|---|
| **Stage** | the Metal canvas (a fluid tank, a gyroscope) | opaque, full-bleed, `ground.stage` | `LabCanvasLabel` only |
| **Instrument surfaces** | `InstrumentPanel`, `Readout`, `LabPlot`, field notes | **opaque** `panel` / `plot`, white hairline 0.07 | `design: .monospaced` |
| **Chrome** | knobs, console, buttons, chips, top bar, telemetry card, banners | **Liquid Glass** | SF Pro, `.monospacedDigit()` |

Colour rules: the **signature** marks primary and selected only; a **parameter hue** says which knob (`palette.hue(for: id)`); a **data hue** says which thing (a fluid, a channel); **semantic** colours are fixed in every app (`live` phosphor, `value` amber, `forecast` cyan, `warning` coral, `simulated` orange). Every number carries a **provenance** word: measured, modelled, live, simulated or illustrative.

### Tokens

| Token | Where | Notes |
|---|---|---|
| `LabPalette.rheo`, `.gyre`, `.orbitals`, `.tether`, `.spectra` | Core | ground, signature, parameter hues, data hues; `onSignature` and `signatureDeep` are computed for contrast |
| `LabPalette.sharedHues` | Core | Gravity amber, Time violet, Magnet green, Listen, Drives, Gain, Scope, Air keep one hue in every app |
| `LabFont` | UI | type roles (eyebrow, panel header, readout label/value, knob title/value, quantity symbol, …) |
| `LabMetrics` | UI | radii, spacing, 44 pt hit areas, knob geometry, console layout, `stageChromeTypeCap = .accessibility1`, `millimetresPerPoint` |
| `LabMotion` | UI | named animations; `gated(_:reduceMotion:)`, `.labAnimation(_:value:)`, `withLabAnimation` return no animation under Reduce Motion |
| `Color(_ c: LabColor, opacity:)` | UI | tokens are gamma-encoded sRGB; renderers use `linearSRGB` / `linearDisplayP3` |

### Components

| Component | Purpose |
|---|---|
| `.labChrome(_ palette:)`, `.labPalette(_:)`, `.labHaptics(_:)` | App root: palette, dark scheme, signature tint, stage background, hidden status bar; inject the `HapticEngine` |
| `InstrumentPanel(_ number:, _ title:, caption:, accessory:, content:)` | Numbered opaque phosphor card |
| `Readout`, `ReadoutGrid(columns:)`, `ProvenanceBadge`, `ProvenanceLegend`, `FlowLayout`, `Eyebrow`, `ClockReadout`, `QuantitySymbol` | Instrument readouts; one accessibility element each, spoken values |
| `GlassKnob(spec:value:style:onActive:onPrecision:)` | The rotary control, `.compact` (console) or `.card` (sheets). Drag (230 pt per sweep in position space), labelled detents, rotary switch when `step ≥ 1` with a `.labels` format (a whole-number knob with a unit, such as Heat in °C, stays a knob with detents), double-tap reset, long-press precision, keyboard arrows (Shift = coarse), VoiceOver adjustable + "Reset to default" + "Fine control", haptics only on real changes |
| `KnobArc`, `KnobReadout`, `KnobPrecisionTray`, `PrecisionSlider` | Knob parts; the readout and tray float above the console. `onPrecision` is optional: without it a knob offers no long press and no "Fine control" action (a `.card` knob already shows its slider); `KnobGrid` always passes one |
| `KnobConsole(pages:page:store:focus:open:uniformHeight:pickerMaxWidth:dimmed:controls:)` | `.tabs` page picker, one `KnobGrid` per page, controls row; `open: nil` = no fold; `uniformHeight` keeps the console a constant height |
| `KnobGrid`, `LevelMeter`, `ProminentGlassButton`, `CircleGlassButton`, `ResetPageButton` | Console parts |
| `GlassToggle`, `ChoiceChips`, `GlassTile`, `GlassTileShelf` | Choosing things (chips or tiles, never a menu that hides the choice) |
| `LabTopBar(card:actions:)`, `ToolbarGlyph`, `TelemetryCard`, `TelemetryRow`, `TelemetryHeadline`, `StatusBanner`, `StatusBannerHost`, `.statusBanner(_:)` | Glass chrome over the stage, capped at `.accessibility1`; the top bar reflows at accessibility sizes |
| `LabInfoSheet(title:startLarge:content:)`, `FieldNote`, `InfoRow`, `LegendRow`, `SensorRow`, `KnobDetailRows`, `SourceLink`, `SourceList` | The "How *App* works" sheet in the fixed panel order 01–09 |
| `FeedbackSettings(feedback:…)` / `(engine:sound:…)` / `(haptics:strength:feel:sound:…)`, `PermissionGate` | Panel 08 "Sound & feel"; a denied or missing sensor |
| `ExperimentMenu(_:current:apply:)` + `Experiment` (Core) | Presets as data with a derived current experiment and a generated effects sentence |
| `LabPlot(title:x:y:series:guides:cursor:summary:identifier:)` | Canvas plot: linear or log10 axes (a major tick at every decade, labels thinned to fit; an axis narrower than a decade labels 1-2-5 values), glowing lines, hollow measured markers, dashed guides with collision-culled labels, a live cursor, an `AXChartDescriptor` for Audio Graphs |
| `CanvasRegion(label:value:hint:actions:identifier:adjust:onKey:onFrame:onTouch:onTwoFinger:)` | The stage's transparent multi-touch and accessibility surface; reports its global frame for the camera |
| `LabCanvasLabel(_:colour:backing:)` | Stage tags; `backing: true` for any tag that can land on the fluid |

Accessibility is built in: every control has a label, value, hint, identifier (`knob-<id>`, `console-pages`, `action-primary`, `topbar-info`, `stage-canvas`, …), a VoiceOver route and a keyboard route; chrome over the stage stops growing at `.accessibility1` and offers the Large Content Viewer; Reduce Motion removes animations and symbol effects; Increase Contrast raises hairlines and glass tints; Differentiate Without Colour dashes plot series and checks selected chips.

---

## LabKitMetro: the Metro Station design system

`LabKitMetro` is the Metro Station design system (edition 1.0, Metro Station build 14), promoted from the skill
(`AI Stuff/Metro Station/Skills/metro-station-design-system`) and the Metro Station app into one shared module, so
every toy adopts the user's default design system from one place instead of copying the starter. It sits beside
`LabKitUI` (the older "glass over phosphor" look); an app picks one of the two for its chrome. Dependencies: `LabKitCore`
and `LabKitFeedback` only. Isolation: `defaultIsolation(MainActor)`; tokens and logic are `nonisolated` values, so they
run anywhere (and are tested on the Mac); the SwiftUI layer is `#if os(iOS)`.

The skill's spec stays the authority on *why*; this module is the *how*. Every Metro contract is built in, not left to
the app:

| Contract (spec §16) | Where it lives |
|---|---|
| **Fixed foreground**: values, units, labels and controls never move with sensors | `MetroLargeReadout` and every control sit outside the optical filter; tilt reaches only `light`/`enhancedTilt` inputs (metal sheen, caustics, lens optics, rim arc). `Metro.Contract` records the rule as data |
| **Touch ownership**: a control owns a touch that begins on it; off-control contact still scrolls | `.metroControlOwnsTouches(identifier:)` (the starter's `InstrumentControlTouchBoundary`, rebuilt on the pure `MetroTouchOwnership` + `MetroTouchSequence`); applied by the crown, stepper, gauge and glass buttons |
| **Accessible alternatives**: native +/− and spoken values for every gesture | crowns have glass −/+ buttons and are VoiceOver adjustable; the gauge is adjustable with named coarse actions; Reduce Motion stops custom motion, Reduce Transparency makes panels opaque and the lens full material, Increased Contrast strengthens outlines |
| **One feedback per accepted change**, none at a limit; stale input discarded | `MetroCrownDetentTracker` (8° fine / 20° semantic, 18 % hysteresis, at most one step per update, ±180° seam, 7 pt centre exclusion) → `MetroDetentGate` (≤ 20 Hz, no catch-up burst, pending notch cleared on reversal) → `canStep` → one write → one `HapticTap` via `.metroHaptics(_:)` |
| **Whole-number formatting** | `MetroFormat` (whole digits, U+2212, "—" when not finite, unit joining), `MetroFormat.formatted(spec, value)` shows a whole-stepped `ParamSpec` with whole digits whatever its format's precision |
| **Static signal enclosures** | `MetroSignalPill`: the capsule outline, title and endpoints are constant; only the interior reacts through `energy` |
| **Authoritative motion** | components never run their own clocks: hosts sample `MetroPulseEnvelope` / `MetroLensPulse` from their own event clock (a `TimelineView` that only redraws the instrument) |

### Tokens, type and materials

| API | What it is |
|---|---|
| `Metro` | every value of `assets/design-tokens.json`, typed: `Metro.Colour` (25 colours, exact RGB doubles as `LabColor`, plus `Metro.Colour.all` with manifest names, hex approximations and roles), `Spacing`, `Radius`, `Stroke`, `Opacity`, `Typography` (`TypeRole`s), `Layout`, `Gauge`, `Motion`, `Optics`, `HapticDetents`, `Contract`, `Portability`; `edition`, `sourceBuild` |
| `MetroPalette`, `Color(metro:opacity:)` | the colours as SwiftUI `Color`s |
| `MetroFont`, `MetroFont.font(_ role:size:)` | type roles (hero numeral, units, serif-italic meaning, telemetry, captions, explanation title, equations) |
| `.metroChrome(environment:)` | app root: dark scheme, `MetroBackground` (canvas, localised cyan wash, 28 pt technical grid; no wash under Reduce Transparency) |
| `MetroContentPanel` / `.metroPanel()`, `.metroPlotInset()` | content material: panel 0.85, radius 22, white 0.09 border, 16 pt inset; plot inset radius 10 |
| `MetroInstrumentHousing(diameter:light:)` | the metal recipe: gauge-housing body, black 0.8 shadow (22 / y 16), four-stop rim, recessed metal face; `light` moves only a faint sheen |
| `.metroGlassControl(accent:in:)`, `MetroGlassIconButton` | native Liquid Glass for controls (`.glassEffect(.regular.tint(accent 0.08).interactive())`, 44 × 44 labels sized before the glass) |
| `.metroHaptics(_ engine: HapticEngine?)` | injects LabKitFeedback's engine; components play `Metro.HapticDetents` (fine/semantic × up/down) through it |

### Components

| Component | Metro source | Notes |
|---|---|---|
| `MetroGauge(diameter:fraction:scale:readout:tilt:motionActive:radiusScale:interaction:identifier:mechanism:)` | `GaugeView` | primary instrument shell: housing, `MetroGaugeDial` (300° sweep from 120°, 70 ticks, spectral band, amber index, caustics), the host's `mechanism` slot, the lens, the fixed readout, rim scrubbing outside 0.30 D (`MetroRimScrub`), VoiceOver adjustable + named coarse actions |
| `MetroParamGauge(store:id:diameter:…)` | — | the gauge over one `ParamSpec`: index at `spec.position(of:)`, hero value/unit from `MetroFormat.heroParts`, meaning from the labelled detent band, major labels from the spec, rim scrub in fine steps (300° across the sweep), "Next/Previous *x* stop" actions |
| `MetroIntegerStepper(_:value:in:unit:…)` | `InstrumentParameterStepper` | native integer Stepper in a dark capsule; writes once, one fine detent, then `onAcceptedChange`; nothing at a limit |
| `MetroParamStepper(store:id:…)` | — | native Stepper over a `ParamSpec` (one fine step per press) |
| `MetroCrown(role:caption:footer:glyph:light:…canStep:onStep:)`, `MetroCrownFace` | `TempoCrownControl` | tactile crown: 62 pt knurled metal face (40 knurls, rotating pointer, fixed datum), glass −/+ buttons, steady captions, detent tracker + rate gate |
| `MetroParamCrown(store:id:role:…)`, `MetroParamCrownPair(store:id:…)` | — | **fine** = one fine step; **semantic** = next labelled detent (Zero-g → Moon → Mars → Earth), one switch position, or a coarse quarter sweep; captions and "Mars ⇆ Jupiter" footers from `MetroParamCrownWords` |
| `MetroSignalPill(title:kind:family:upperLabel:lowerLabel:reference:response:energy:marker:…)` | `MetroStationPillView` | vertical channel (`.wave` or `.distribution`; `.wave`/`.spectrum` families), constant 0.8 pt outline, quiet reference trace, interior ribbon driven by `energy` |
| `MetroTelemetryRow([MetroMetric])` | instrument telemetry strip | equal columns, 1 × 30 pt dividers, one accessibility element per metric, stacks at accessibility sizes |
| `MetroEventTiles(title:status:count:active:subdivisions:…)` | beat grid | 37 pt tiles, number + position + colour, subdivision capsules, one element for the row |
| `MetroFloatingActionGroup` + `MetroSideAction`, `.metroFloatingActions(_:)` | transport | native glass, no backing strip; primary cyan when idle, amber while running; reserve `Metro.Layout.bottomContentReserve` (98 pt) |
| `MetroLensSurface(diameter:radiusScale:filteredTilt:motionActive:face:readout:)` | `InstrumentLensSurface` | face (decorative, filtered) → native clear glass 0.76 D at a constant 0.48 opacity → rim arc → unfiltered readout; optics only while motion is active and Reduce Motion/Transparency are off and the scene is active (`MetroLensState`) |
| `MetroLargeReadout(diameter:value:unit:meaning:phase:…)` | `InstrumentLargeReadout` | hero numeral 0.23 D, units, serif meaning, phase metadata at fixed coordinates |
| `MetroTilt` (+ `MetroTiltFilter`) | `MotionLighting` | sensor baseline: the host feeds gravity (CoreMotion, `MotionSource` or a simulator pose) and owns permission and lifecycle; generation-stamped samples; `vector` is bounded −1…1 |
| `MetroPulseEnvelope`, `MetroLensPulse`, `MetroClusterLayout`, `MetroReadoutLayout` | `PillTickResponse`, `GlassDialMotion`, gauge layout | pure helpers sampled from the host's clock and width |

### The lens shader in a package

The starter's `ShaderLibrary.instrumentLensOptics` resolves in the **app's** default library, which a Swift package
never populates. `Shaders/MetroLensOptics.metal` is a processed resource of the `LabKitMetro` target, so SwiftPM and
Xcode compile it into `default.metallib` inside `LabKit_LabKitMetro.bundle`, and every lookup is explicit:
`MetroShaders.library` is `ShaderLibrary.bundle(Bundle.module)`, `MetroShaders.lensOptics(diameter:radius:enhancedTilt:)`
builds the `Shader`, and `MetroShaders.verify()` loads the library with Metal and checks `metroLensOptics` exists.
Verified on the Mac (`MetroOpticsTests`), in the gallery on the simulator in Debug and Release (`shader ok=true
metroLensOptics found in LabKit_LabKitMetro.bundle`), and the metallib is embedded in the device build. The Swift twin of
the shader maths, `MetroLensRefraction` (bounded shift, rim feather, diagonal chromatic split, sampling bound), is
unit-tested against the same constants.

### ParamSpec bridge

A `ParamStore` drives Metro controls directly, with no parallel model: `MetroParamStepping` maps a `ParamSpec` onto the
two roles (fine: one `step` for a stepped parameter of at most 200 steps, else 1 % of the sweep in position space,
stopping on a labelled detent it would cross; semantic: next labelled detent, switch position, or a coarse quarter
sweep) and returns nil at a limit. `store.metroStep(id, direction:role:)` and `store.metroApplyFine(id, steps:)` write
**once** per accepted change and return nil / 0 at a limit, so the views emit no event and no feedback for a clamped
no-op.

```swift
import LabKitCore
import LabKitFeedback
import LabKitMetro

struct InstrumentScreen: View {
  @State private var model = Model()          // owns a ParamStore and a MetroTilt
  @State private var haptics = HapticEngine()

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        TimelineView(.animation(minimumInterval: 1 / Metro.Motion.gaugeHz)) { context in
          MetroParamGauge(store: model.params, id: "tempo", diameter: 300,
                          tilt: model.tilt.vector, motionActive: model.tilt.isActive,
                          radiusScale: model.lensPulse(at: context.date)) { Mechanism(model, context.date) }
        }
        MetroTelemetryRow(model.metrics).metroPanel()
        MetroParamCrownPair(store: model.params, id: "gravity", light: model.tilt.vector).metroPanel()
        MetroParamStepper(store: model.params, id: "heat")       // outside the TimelineView: native repeat survives
      }
      .padding(.horizontal, Metro.Spacing.screenInset)
    }
    .metroFloatingActions(MetroFloatingActionGroup(title: "Start", symbol: "play.fill", isRunning: false) { model.start() })
    .metroHaptics(haptics)
    .metroChrome()
  }
}
```

### Gallery and verification

The gallery app lives outside LabKit and outside iCloud at `~/Developer/labkit-metro-gallery` (XcodeGen, bundle
`com.utkarsh.labkitmetrogallery`). `Tools/build.sh sim|release|device` mirrors LabKit and the gallery side by side under
`$TMPDIR/lkmetro-gallery` and builds. It shows every component on one scrolling screen (primary instrument flanked by
pills, telemetry and event tiles, crowns and steppers, the isolated lens over a calibration face, the three material
families, all 25 colour tokens) with the floating action group over the page. Arguments: `-section
instrument|signals|controls|lens|materials|tokens`, `-tilt x,y` (a held pose; the simulator has no motion), `-frozenAge s`,
`-stopped`, and `-tour [-tourOnly prefix]`, which steps through every configuration in-process and writes
`tmp/metro-gallery-<step>.png` into its container (on a loaded host SpringBoard may never bring the app forward, and
`simctl io screenshot` then returns the home screen). Screenshots: `Documentation/metro-gallery-*.png`.

Checks (`Tools/lk.sh lkmetro env TOOLCHAINS=metal swift test --filter LabKitMetroTests`):

| Suite | What it proves |
|---|---|
| `MetroTokenManifestTests` | every colour, number and type role in `Metro` equals a frozen copy of `design-tokens.json` exactly, and nothing in the manifest is missing |
| `MetroFormatTests` | whole digits, U+2212, no "−0", unit joining, whole-stepped `ParamSpec`s, hero parts, spoken values |
| `MetroDetentTests` | detent spacing, hysteresis on reversal, one step per update, the ±180° seam, large jumps, rate gate (20 Hz, no burst, reversal clears pending, refused steps cost nothing) |
| `MetroTouchBoundaryTests` | ownership (edges inside, hidden/transparent/detached markers own nothing), the scroll-pan pairing, multi-touch sequence states |
| `MetroOpticsTests` | `MetroLensRefraction` bounds and feathering, `MetroLensState` accessibility rules, pulse envelope, tilt filter, and the package shader lookup (`MetroShaders.verify()`) |
| `MetroGeometryTests` | cluster and readout layout, rim-scrub begin region and quantisation |
| `MetroParamBridgeTests` | fine/semantic stepping, detent landing, limits return nil (no write), crown words, gauge labels |

### Migrating an app from the starter (Toothpaste Toy, Gyre, Spectra)

Toothpaste Toy currently carries its own copy of the starter in `ToothpasteToy/Design/Metro/` (its UI agent adapted it in
parallel with this module). Moving it, or any app, onto LabKitMetro is a later, separate step:

1. Add `LabKitMetro` to the app target's LabKit products in `project.yml`.
2. Delete the app's copies: `MetroTokens.swift` (its `enum Metro` would shadow the module's), `InstrumentDesignSystem.swift`,
   `InstrumentControlTouchBoundary.swift`, `LensRefraction.swift`, `InstrumentLensOptics.metal`, `UsageExample.swift`.
3. Rename: `InstrumentPalette` → `MetroPalette`; `InstrumentMetrics` → `Metro.Spacing` / `Metro.Layout` / `Metro.Radius`;
   `InstrumentDesignBackground` → `MetroBackground` (or `.metroChrome()`); `InstrumentContentPanel` → `MetroContentPanel`
   / `.metroPanel()`; `InstrumentGlassIconButton` → `MetroGlassIconButton`; `InstrumentMetricReadout` → `MetroMetric` in a
   `MetroTelemetryRow`; `InstrumentParameterStepper` → `MetroIntegerStepper` (or `MetroParamStepper`);
   `InstrumentLargeReadout` → `MetroLargeReadout`; `InstrumentLensSurface` → `MetroLensSurface`; `LensRefraction` →
   `MetroLensRefraction`; `.instrumentControlOwnsTouches(identifier:)` → `.metroControlOwnsTouches(identifier:)`;
   `ShaderLibrary.instrumentLensOptics(…)` → `MetroShaders.lensOptics(diameter:radius:enhancedTilt:)`.
4. App-specific `Metro.*` values the app added to its own namespace move into an app extension (`extension Metro { enum
   Toothpaste { … } }`), never into LabKitMetro.
5. Toothpaste Toy's own components in `ToothpasteToy/UI/Metro*.swift` map onto the module's: `CrownDetentTracker` /
   `DetentGate` → `MetroCrownDetentTracker` / `MetroDetentGate`; `InstrumentCrown`, `GravityCrown`, `HeatCrown` →
   `MetroCrown` or `MetroParamCrown(Pair)` over the app's `ParamStore`; `SignalPill` / `LivePills` → `MetroSignalPill`
   (feed it `energy` from the app's event clock); `TelemetryStrip` → `MetroTelemetryRow`; `EventTiles` →
   `MetroEventTiles`; `FloatingActions` → `MetroFloatingActionGroup`. Keep app-only pieces (`SqueezeCrown`,
   `SqueezeHoldButton`, `SignalRack`) in the app, built from the module's parts. None of these names collide with the
   module's (all of its public types are `Metro`-prefixed); the only clash is the app's own `enum Metro`, which step 2
   removes.
6. Toothpaste Toy's own Metal hologram may keep reading the same numbers through `MetroLensRefraction` and `Metro.Optics`.
7. Re-run the app's UI tests (identifiers change from the starter's to `metro-*`), and look at the result on a simulator.

---

## Adopting LabKit in an app

1. **Add the package.** In the app's XcodeGen `project.yml`, point at a mirror outside iCloud (see [Building](#building-and-testing)), then depend on the products you use:
   ```yaml
   packages:
     LabKit: { path: ../LabKit }        # Rheo/Tools/build.sh mirrors LabKit and the app side by side
   targets:
     Rheo:
       dependencies:
         - { package: LabKit, product: LabKitCore }
         - { package: LabKit, product: LabKitUI }
         - { package: LabKit, product: LabKitFeedback }
         - { package: LabKit, product: LabKitSensors }
         - { package: LabKit, product: LabKitRender }
   ```
   Set `SWIFT_VERSION: 6.0` and `SWIFT_STRICT_CONCURRENCY: complete`. Add the signature as the `AccentColor` asset and the ground's `background` as `LaunchBackground` (widgets read assets, not Swift constants).

2. **Declare parameters.** One `ParamSpec` per knob, SI or display units in the format, copy in British English:
   ```swift
   extension ParamID { static let gravity: ParamID = "gravity" }
   ParamSpec(.gravity, title: "Gravity", icon: "arrow.down.to.line", range: -1...3, defaultValue: 1, origin: 0,
             detents: Gravity.detents, step: 0.01, hint: "Strength of gravity in the tank.", glyph: "g",
             provenance: .live, format: .number(precision: 2, unit: "g"))
   ```
   Values quantise from the lower bound; a re-registered spec clamps its stored value into the new range (`store.register(specs)`, or `adoptDefaults: true` to restore defaults). The engine reads `store.snapshot()` once per frame. Observation is per parameter: a view that reads `store[.time]` redraws when Time changes, not when any other knob turns, so keep `snapshot()` (which reads every value) out of view bodies that should stay still.

3. **Build the screen** from the components. Rheo's skeleton (`labkit-from-orbitals-spectra.md` §9.10):
   ```swift
   VStack(spacing: 0) {
     CanvasRegion(label: model.canvasLabel, value: model.canvasValue, hint: "Drag to poke and stir.",
                  actions: model.canvasActions, onFrame: model.setTankRegion, onTouch: model.touch,
                  onTwoFinger: model.twoFinger)
       .overlay(alignment: .top) {
         VStack(spacing: 8) {
           LabTopBar { TelemetryCard(expanded: $open, rows: rows, simulatedNote: note) {
                         TelemetryHeadline(icon: "drop.fill", spins: running, activity: .breathe,
                                           headline: "η 12.4 Pa·s", subline: "γ̇ 3.20 s⁻¹ · σ 39.7 Pa") } }
           actions: { /* ToolbarGlyph buttons, ExperimentMenu, a Layers Menu, Info */ }
           StatusBannerHost($banner)
         }
         .padding(.horizontal, 16).padding(.top, 6)
       }
     KnobConsole(pages: pages, page: $page, store: model.params, focus: $focus) {   // open: nil → no fold
       ProminentGlassButton("Refill", icon: "drop.triangle.fill") { model.refill() }
       CircleGlassButton("Freeze time", icon: "pause.fill") { model.paused.toggle() }
       Spacer(minLength: 0)
       ResetPageButton(page: currentPage, store: model.params)
     }
     .padding(.horizontal, 12).padding(.bottom, 4)
   }
   .background { LabRenderHost(scene: model).ignoresSafeArea() }
   .labChrome(.rheo)
   .labHaptics(model.feedback.haptics)
   ```

4. **Lifecycle.** On `scenePhase` changes call `feedback.setActive(phase == .active)` (haptics stop whenever the app is not active) and pause the simulation clock. Push `accessibilityReduceMotion` into the model so the renderer honours it too.

5. **Write the info sheet** in the fixed order: 01 What you're looking at · 02 Touch · 03 What you're seeing · 04 Knobs (`KnobDetailRows(pages:store:)`) · 05 Experiments · 06 What's real and what's illustrative (`ProvenanceLegend`) · 07 Sensors in play · 08 Sound & feel (`FeedbackSettings(feedback:…)`) · 09 Sources & licences (`SourceList`). Run `CopyLint` over its strings in a unit test.

6. **Draw life-size** with `LabMetrics.millimetresPerPoint` (model-identifier table; `iPhone16,2` → 0.16565 mm/pt). It is `nil` on an unknown model: hide the "LIFE-SIZE" tag and fit the scene instead.

---

## Launch arguments

Simulator and test stand-ins live in `LabKitSensors.LaunchOptions`. A fake is honoured in DEBUG builds, or whenever the real hardware is missing.

| Argument | Effect |
|---|---|
| `-simSway` | Sway the simulated phone (yaw, pitch and roll on slow sines) |
| `-fakeMic` | A synthetic room (a hummed chord plus a clap every 1.6 s) through the real ring and analyser |
| `-startMic` | Turn the microphone on at launch |
| `-fakeMagnet` | A magnet that approaches and retreats every 6 s (up to 2 mT) |
| `-fakeShake` | Periodic shakes (0.4 s of 12 Hz at ±1.2 g every 3 s) |
| `-fakeThermal 0\|1\|2\|3\|cycle` | Pretend thermal state (DEBUG only) |
| `-fakeLowPower` | Pretend Low Power Mode: 60 fps cap, no hum, no sound bed (DEBUG only) |
| `-ui-testing` | Apps: defaults, paused, deterministic fakes (house convention; read by the app) |
| `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL` | System argument: launch at the largest accessibility text size (layout checks) |

Example: `xcrun simctl launch booted com.utkarsh.rheo -simSway -fakeMic -startMic -fakeMagnet -fakeShake`.

---

## Building and testing

**Never build inside iCloud** (`AI Stuff` is iCloud-synced; xcodebuild and SwiftPM hang or misbehave there). `Tools/lk.sh <work-name> <command…>` mirrors LabKit to `$TMPDIR/labkit-<work-name>/LabKit` and runs the command in the mirror. Use a unique work name per parallel job.

| Task | Command (from `LabKit/`) |
|---|---|
| Build one target on the Mac | `Tools/lk.sh me swift build --target LabKitCore` |
| Metal targets on the Mac | `Tools/lk.sh me env TOOLCHAINS=metal swift build --target LabKitMPM` (the default toolchain's `metal` is a stub) |
| Unit tests on the Mac | `Tools/lk.sh me env TOOLCHAINS=metal swift test --filter LabKitCoreTests` (add `--no-parallel` for `LabKitRigidTests`) |
| Core harness | `Tools/lk.sh me swift run -c release labkit-physcheck core` (`mpm` or `all` for the MPM checks) |
| GPU harness | `Tools/lk.sh me env TOOLCHAINS=metal swift run -c release labkit-gpucheck` |
| iOS Simulator build | `Tools/lk.sh me xcodebuild -scheme LabKitUI -destination 'generic/platform=iOS Simulator' -derivedDataPath ../dd build` |
| Whole package | `-scheme LabKit-Package` (scheme names are target names) |
| Device build | `-destination 'generic/platform=iOS'` |

Rheo builds through `Rheo/Tools/build.sh sim|device`, which mirrors LabKit and Rheo side by side.

**Component gallery.** A throwaway XcodeGen app that renders every LabKitUI component and a Rheo-like screen lives outside the repo (`$SCRATCH/wpc1v2/gallery`, the complete copy with its `project.yml` and `RheoData.swift`; the older `$SCRATCH/wpc1-gallery` has lost both; bundle `com.utkarsh.labkit.gallery.wpc1`). Its arguments: `-components [-section n]`; or the Rheo screen with `-page <fluid|world|touch|signals|view>`, `-shelf`, `-rheometer [-large]`, `-info [-infoFrom n]`, `-held <knob>`, `-precision <knob>`, `-expanded`, `-banner`, `-time <x>`, `-fold`. It writes `FRAME name x y w h` lines to `tmp/frames.txt` in its container. On a loaded host, where SpringBoard can take minutes to bring an app forward and `simctl io screenshot` returns the home screen, launch it once with `-tour` (optionally `-tourOnly <prefix>`): it steps through every configuration in-process and writes `tour-<name>.png` window captures to its `tmp/`; `-snapshot` captures a single launch; `-ax` applies Accessibility XXXL to the stage (sheets need the system `-UIPreferredContentSizeCategoryName` argument).

---

## Verification (LabKitUI and the parameter model, 4 October 2026)

| Claim | Status | Evidence |
|---|---|---|
| LabKitUI (with Core and Feedback) builds for iOS Simulator and for device with 0 warnings | **built** | `xcodebuild -scheme LabKitUI -destination 'generic/platform=iOS Simulator'` and `'generic/platform=iOS'` |
| `LabKitCoreTests` pass on macOS (parameters, palette contrast and hue rules, formats, plot axes, experiments, life-size table, copy lint, plus WP-C2's runtime tests) | **run** | `swift test --filter LabKitCoreTests`: 84 tests, 0 failures (second verification pass, 8 October 2026) |
| `labkit-physcheck core` | **run** | 18 checks PASS (integrators, substeps, knob mapping and nudges, drives, envelope, spectrum, gravity, spoken values, life-size table, Rheo's signature contrast) |
| Components render and lay out on an iPhone 15 Pro Max simulator (iOS 27): tank 430 × 612.3 pt (y 59–671.3), console 226.7 pt, top bar 398 × 55.3 pt, Rheometer strip top at y 668.9 | **run** | gallery screenshots and frame logs |
| At Accessibility XXXL the top bar stacks (131.3 pt), knob rows go 4 → 2, the console grows to 409.7 pt, Refill goes icon-only | **run** | gallery, `-UIPreferredContentSizeCategoryName …AccessibilityXXXL` |
| Haptic feel, VoiceOver flows, keyboard focus, Large Content Viewer, Increase Contrast and Differentiate Without Colour branches | **written** | compile only; the simulator has no haptics and these were not driven |
| `millimetresPerPoint` = 0.16565 on the 15 Pro Max | **run** (table lookup) | unit test; the physical scale on hardware is not measured |

An independent verification pass re-ran every build, test and harness above from its own mirror (same results; 0 compiler warnings) and fixed: a crash in `LevelMeter` when the level is NaN (`clamped` passes NaN through and `Int(NaN)` traps on render); `ParamValues.choice` trapping on a NaN or huge modulated value; NaN defaults and infinite steps leaking into `ParamSpec`; a held knob that disappears (page change by another finger, fold) leaving its readout floating; a "Fine control" VoiceOver action and long press that did nothing on knobs without a precision handler; Audio Graph data points that a log axis can't place; the fold button's missing Large Content Viewer.

Visual defects found in the gallery screenshots and fixed in LabKitUI: the knob readout and precision tray drew over the console; a detent label repeated the value ("Off Off"); secondary glass controls took the pink tint; the last x-axis label and the x caption ran into the plot frame; guide labels sat on their own lines; the time chip widened the telemetry card so the top bar jumped to its stacked layout; neighbouring controls-row buttons blended into pinched glass; readouts without a symbol sat 2 pt higher; card knobs without a descriptor were shorter than their neighbours; `FlowLayout` wrapped a badge onto a line its height didn't include; floating glass cards turned pale over light fluid.

A second verification pass (8 October 2026, mirror `wpc1-verify2`) rebuilt LabKitUI for iOS Simulator and device (0 warnings), re-ran `LabKitCoreTests` (84 tests, 0 failures) and `labkit-physcheck core` (18 PASS), and fixed:

- **Whole-number knobs became rotary switches.** `isSwitch` was `step ≥ 1`, so Rheo's Heat (0–90 °C) and Magnet (0–500 mT, both step 1, as Rheo's `Knobs.swift` declares them) were switches: by the code, they would draw a dot per degree or millitesla, skip their labelled detents, lose the precision tray and slider, drop the detent from VoiceOver, and move 1 mT per VoiceOver swipe (500 swipes end to end). A switch now also needs `format: .labels(...)` (§3.5); test `testWholeNumberKnobsWithUnitsAreNotSwitches`.
- **One knob redrew every parameter reader.** `ParamStore` kept all values in one observed dictionary, so turning any knob invalidated every knob on the page, the top bar's derived experiment label and any app body that read a parameter. Each value now lives in its own observable cell (`testObservationIsPerParameter`); `snapshot(_ ids:)` reads only the ids given, `matchingExperiment` uses it, and the console's floating readout is its own view.
- **Shear rates got a wrong SI prefix.** `LabFormat.engineering(0.32, unit: "s⁻¹")` gave "320 ms⁻¹", which reads as 320 per millisecond (a million times too fast), and VoiceOver said "per millisecond"; Rheo's top bar and Rheometer format the shear rate this way. A unit whose first factor is a reciprocal now takes no prefix ("0.320 s⁻¹"; scientific outside 10⁻³…10⁶); test `testEngineeringNeverPrefixesAReciprocalUnit`.
- **Info sheet detents said "Off Off".** `KnobDetailRows` printed the label and the formatted value even when the format already says the label (Magnet, Stir, Listen, Glow).
- **`FlowLayout` never wrapped a subview wider than the line.** In the uncapped info sheet at accessibility sizes a long field-note or knob title ran off the panel; such a subview is now offered the line's width and wraps.
- **Log axes dropped the grid line of every unlabelled decade** (§3.12 asks for a major tick at every decade), and an axis narrower than a decade had no labels at all; both fixed in `PlotAxis.ticks` and tested.
- **The material shelf grew with Dynamic Type.** `GlassTileShelf` is stage chrome: it is now capped at `.accessibility1`, and each `GlassTile` shows its name in the Large Content Viewer.

Seen, not just built: the gallery ran on the `C1V 15 Pro Max` simulator (iOS 27) and was inspected through in-process window captures (`-tour`; the host was too loaded for `simctl io screenshot` to show the app): the fluid and World pages (held Magnet, Heat precision tray), the Rheometer strip and large detent, the held readout with expanded telemetry and time chip, the precision tray with banner, the fold, info panels 01–09, component sections 1–8, and the Signals page, material shelf and info sheet at Accessibility XXXL. Frames were unchanged (tank 430 × 612.3 pt, console 226.7 pt at y 671.3, top bar 398 × 55.3 pt, Refill 94.3 × 50 pt). The same captures from the pre-fix package showed Heat and Magnet ringed with 91 and 501 dots and a field-note title running off its panel at Accessibility XXXL; neither remains. Haptics, VoiceOver, keyboard focus and the Large Content Viewer were still not driven (compile only).

---

<!-- Sections below belong to the packages named in their headings. Append or replace your own section only. -->

## Runtime: Core, Sensors, Feedback, Render

*Owned by WP-C2 (written 4 October 2026; merged here from [`Documentation/README-Runtime.md`](Documentation/README-Runtime.md), which stays as the source).* The non-UI half of LabKit: maths, time, integrators, the modulation ("Drives") router, sensors with simulator fakes, the haptics and sound policy, and the Metal render host with bloom and EDR.

| Module | Platforms | What it holds |
|---|---|---|
| `LabKitCore` (runtime part) | iOS, macOS | `V2/V3/F2/F3/F4` maths, `XorShift32`; `approach`, `AttackRelease`, `Throttle`, `FrameClock`, `SimClock`, `FixedStep`; `RK4`, `substepCount`, `symplecticEuler`, `DampedSpring`, `RingBuffer`; `MotionSample`, `LabEnvironment`, `TouchSample`, `SourceConditioner`; `MicSnapshot`, `OnsetAnalyser`, `EnvelopeFollower`, `ScopeData`, `Spectrum`, `EMFMeter`; `ModSourceID`, `ModRoute`, `ModulationRouter`, `LFO`; the pure halves of feedback (`HumGovernor`, `HumPolicy`, `StressFeel`, `FeelEventDetector`, `FeelCauses`, `SoundPolicy`, `logPitch`); `DeviceConditions`, `FramePacing`; `PhysCheck` |
| `LabKitSensors` | iOS | `MotionSource` (pulled once per frame), `MicListener` (iOS 27 `installAudioTap`), `ThermalSource`, `LaunchOptions` |
| `LabKitFeedback` | iOS | `HapticEngine`, `HapticTap`, `SynthHost` + `SynthKernel` + `SynthControls`, `RotorHumKernel`, `SilentKernel`, `SonicCue`, `LabFeedback` (the policy object apps hold), `AudioRoute` |
| `LabKitShaderTypes` | C | `LabFrameUniforms`, `LabLineInstance`, `LabMeshVertex`, `LabQuadInstance`, buffer-index enums (one header for Swift and MSL) |
| `LabKitRender` | iOS (+ macOS for offscreen use) | `LabRenderHost`, `LabRenderer`, `LabRenderScene`, `LabFrameEncoder`, `LabFrameContext`, `RenderTargets`, `PostChain`, `PipelineFactory`, `DepthStates`, `LayoutCamera` (perspective, orthographic, orthographic world rect), `LineBatch`/`LineRenderer`, `QuadRenderer`, `MeshBuilder`/`GPUMesh`, `LabShaders`; `Shaders/LabKit.metal` + header-only `LabKitShaderLib.h` |

Core is Foundation + simd + Accelerate only, so the Mac harness (`labkit-physcheck`) and XCTest run it without a simulator.

### The frame loop

The render loop owns time: `LabRenderer.draw(in:)` calls `scene.advance(dt:)` once per drawn frame (first frame 1/120 s, then at most 1/15 s). There are no timers.

```swift
@MainActor @Observable final class ToyModel: LabRenderScene {
  @ObservationIgnored let motion = MotionSource()
  @ObservationIgnored let mic = MicListener()
  @ObservationIgnored let thermal = ThermalSource()
  @ObservationIgnored let feedback = LabFeedback(appName: "Rheo", kernel: GloopKernel())   // persists "Rheo.haptics" etc.
  @ObservationIgnored var conditioner = SourceConditioner()
  @ObservationIgnored var router = ModulationRouter([/* ModRoute(...) */])
  @ObservationIgnored var canvasRegion = CGRect.zero          // from CanvasRegion(onFrame:)
  var isRunning = false; var reduceMotion = false
  var projection: LabProjection { .orthographicRect(CGRect(x: 0, y: 0, width: 0.0712, height: 0.1014)) }  // metres, y up
  var wantsBehindCopy: Bool { true }                          // refraction: encodeScene may sample context.targets.behind

  func advance(dt: Double) {
    let s = motion.sample(dt: dt)
    var p = store.snapshot()
    let src = conditioner.step(motion: s, mic: mic.isLive ? mic.snapshot(dt: dt) : nil, micGain: 1,
                               pressureKPa: nil, thermal: thermal.sample(dt: dt), touch: touch, dt: dt)
    let out = router.apply(src, to: &p, specs: store.specs, dt: dt, holding: heldKnobs)
    let env = LabEnvironment.from(s, gravityScale: p["gravity"])   // env.screenGravity: in-plane g for a 2D tank
    // … physics …
    if FeelCauses().isLive(src, listen: p["listen"], fingerDown: touch.down) { feedback.noteCause() }
    feedback.updateHum(stressFeel.step(stress: σ, solidFraction: sf, fingerSpeed: v, dt: dt))
    feedback.micLive = mic.isLive; feedback.updateBed(activity: a, dt: dt)
  }
  func encodeCompute(_ cmd: MTLCommandBuffer, context: LabFrameContext) { /* MPM substeps, fluid prepass */ }
  func encodeBehind(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext) { /* back wall */ }
  func encodeScene(_ enc: MTLRenderCommandEncoder, uniforms: inout LabFrameUniforms, context: LabFrameContext) { /* fluid, glass */ }
  func buildLines(_ batch: inout LineBatch, context: LabFrameContext) { /* overlays */ }
}
// View: LabRenderHost(scene: model).ignoresSafeArea()
// scenePhase: feedback.setActive(phase == .active); motion.start()/stop(); thermal.start()
// Wire the self-trigger guard: feedback.onSelfSound = { [mic] in mic.ignoreOnsets(for: $0) }
// Interruptions: AudioRoute.observeInterruptions(inactive: { mic.suspend() }, resume: { Task { await mic.resume() } })
```

Read `store.snapshot()` in `advance(dt:)`, never inside a SwiftUI body: the store's observation is per parameter, and the engine should not subscribe to any of it.

Frame order inside the renderer: `advance` → `buildLines` → `fillUniforms` → `encodeCompute` → pass 1 (backdrop, `encodeBehind`) → if `wantsBehindCopy`: blit to the mipmapped `behind` texture + `generateMipmaps` → pass 2 (load) → `encodeScene` → lines (additive) → bloom ½ + ¼ → composite (aberration, scanlines, EDR soft-clip at min(headroom, 3), knee 0.8). Scene colour `rgba16Float`, depth `depth32Float`.

- **Frame budget.** At most 2 command buffers in flight. The renderer tries the in-flight semaphore with `wait(timeout: .now())`; when both slots are busy it skips the display frame (no advance, no encode; counted in `renderer.stats.skippedFrames`) instead of blocking the main thread. Every 0.5 s it asks for 60 fps under Low Power Mode or thermal state ≥ serious, 120 fps otherwise (`FramePacing`). `stats.gpuMilliseconds` is the smoothed GPU time from completion handlers. On iPhone, 120 fps also needs `CADisableMinimumFrameDurationOnPhone: true` in the app's Info.plist.
- **Allocation-free encode (LK-FIX).** `LabFrameEncoder` and `PostChain` keep their render pass descriptors and re-point them at each frame's textures (the composite pass drops its reference to the drawable as soon as the encoder exists). `LabRenderer` gives `behind` `RenderTargets.liveBehindMipLevels` = 8 levels (lod ≤ 7; the fluid shade samples ≤ 6) through the new `RenderTargets(device:size:wantsBehind:behindMipLevels:)`; the old initialiser still makes the full chain. `LabColor.linearDisplayP3` uses a static matrix. Main-thread heap allocations per `encode` (libmalloc `malloc_logger`, no-op scene at 1290 × 2796, M1 Max): 190 → 112 with the behind copy, 52 → 19 without, and 1 → 0 per `linearDisplayP3` call. What is left is inside Apple's driver: about 10 per mip level in `generateMipmapsForTexture:` and about 2 per encoder.
- **Orthographic tank.** `.orthographicRect(world, fit:)` maps a world rectangle (x right, y up, any units) onto the eased canvas region; with `.stretch` the world's corners land on the region's corners. `LayoutCamera.orthographicMatrix(world:regionPx:drawablePx:fit:)` is the same matrix as a pure function. Checked on screen in the WP-C2 smoke app (life-size 71.2 × 101.4 mm tank, lines, a refraction pane sampling `behind`, bloom).
- **Shaders.** Xcode compiles `Shaders/LabKit.metal` into `LabKit_LabKitRender.bundle/default.metallib`; `LabShaders.library(device:)` loads it. App shaders reuse the helpers with `MTL_HEADER_SEARCH_PATHS: "$(SRCROOT)/../LabKit/Sources/LabKitRender/Shaders $(SRCROOT)/../LabKit/Sources/LabKitShaderTypes/include"` and `#include "LabKitShaderLib.h"`. `PipelineFactory.make(vertex:fragment:vertexLibrary:fragmentLibrary:…)` mixes LabKit and app functions; it never sets a nil label (that asserts under Metal validation).

### Feedback policy (haptics and sound)

- **Two haptic channels.** Transients answer something the user did (`HapticTap` vocabulary: `.tap .grab .tick .detent .switchClick .release .boundary .reset .soft .select .place .poke .ripple`, plus `selection()`, `success()`, `ramp()`, `crackle()`; Gyre's names `knobGrab` etc. remain as deprecated aliases). The hum ("Feel") follows `HumPolicy.causal(maxIdle: 8)`: it plays only within 8 s of `noteCause()`, with a 0.25 s lag, stopping below 0.02, at ≤ 40 parameter sends a second.
- **Strength** 0.2…1 (default 0.85) scales both channels; under VoiceOver the hum plays at × 0.6.
- **Stop rules.** Everything stops on `stop()` / `setActive(false)` and on `didEnterBackground`. The hum stops while paused, in Low Power Mode and at thermal state ≥ serious; the sound bed stops while paused and in Low Power Mode (not on thermal state, per the sound policy); transients and cues stay.
- **Rheo's map** (`StressFeel`): intensity = clamp(0.15·log₁₀(1 + σ̃/0.1 Pa)), sharpness = clamp(0.15 + 0.7·s_f + 0.15·min(1, v/0.5 m/s)); `FeelEventDetector` emits yield / jam / unjam / grain events with hysteresis.
- **Sound.** One bed voice per app (`SynthKernel`, set through atomic `SynthControls` slots) plus `SonicCue`s, each paired with a haptic twin (`.tick .detent .threshold .resonance .action`). Sound is on by default, persisted as `"<App>.sound"`, and follows the ring/silent switch (`.ambient`). With the mic live the session is `.playAndRecord` (which ignores the switch), so the bed ducks to × 0.3, cue partials within ± 1 octave of `micBand` are dropped, and every self-made cue or poke opens a 0.2 s onset-ignore window. Echo-cancelled input is opt-in (`AudioRoute.prefersEchoCancellation`) and checked at runtime (`echoCancellationAvailable`, `echoCancelledInputActive`).
- **Media-services reset (LK-FIX).** `SynthHost` observes `AVAudioSession.mediaServicesWereResetNotification` itself. `rebuildAfterMediaReset()` (public, safe to call twice) drops the dead engine, node and configuration observer, builds a fresh `AVAudioEngine` (the node is rebuilt on the next `start()`), makes `AudioRoute` re-apply the session category, and restarts if the app wanted sound. `rebuilds` counts the rebuilds. An app's own reset handler that calls `stop()` and then `start()` (Rheo's RheoFeel) works in either observer order.
- **Swift 6.** Every audio render block, tap, Core Haptics handler and notification closure is built in a `nonisolated static` factory or written `{ @Sendable … }`.

The launch arguments these modules read are in [Launch arguments](#launch-arguments) above (`-fakeThermal` with no value means 2, serious; `cycle` steps every 8 s; `-fakeTouch` is not read by LabKit: Rheo parses it itself).

### Runtime build and test commands

```zsh
Tools/lk.sh me xcodebuild -scheme LabKit-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath ../dd build
Tools/lk.sh me xcodebuild -scheme LabKit-Package -destination 'generic/platform=iOS' -derivedDataPath ../dd build
Tools/lk.sh me xcodebuild test -scheme LabKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath ../dd -only-testing:LabKitCoreTests -only-testing:LabKitRenderTests
Tools/lk.sh me swift run -c release labkit-physcheck core          # Mac, no Metal
Tools/lk.sh me env TOOLCHAINS=metal swift build --target LabKitRender   # SwiftPM needs the Metal toolchain
```

### Runtime verification (WP-C2, 4 October 2026)

| Claim | Status |
|---|---|
| Core, Sensors, Feedback, ShaderTypes, Render build for iOS Simulator and device (clean build incl. `LabKit.metal`), 0 warnings | built |
| `LabKitCoreTests` (78 at the time: router, conditioner, integrators, clocks, feel, sound policy, pacing, plus the UI-model tests) and `LabKitRenderTests` 8/8 (metallib loads, pipelines build, shared layouts, `behind` is mipmapped, orthographic matrix maps tank corners to the canvas region, fit modes, the two-phase pass feeds `behind` to pass 2, single pass without the copy) on an iPhone 15 Pro Max simulator, and again on the Mac (`TOOLCHAINS=metal swift test`) | run, pass |
| `labkit-physcheck core`: the 11 runtime checks PASS (RK4 energy, substep rule, knob maths, gravity and kick drives, envelope, spectrum band, screen gravity) | run, pass |
| Smoke app (Swift 6 strict, XcodeGen) renders the orthographic tank, lines, the behind-copy refraction pane and bloom; `-fakeThermal 2` drops it to 60 fps | run in the simulator, screenshots inspected |
| Haptic feel, hum levels, Strength, echo cancellation, speaker audibility of low cues, real mic tap sizes | written, not testable in the simulator (`supportsHaptics == false`); needs the iPhone 15 Pro Max |

## LabKitRigid (Box2D)

*Owned by WP-R (written 3 October 2026; merged here from [`Documentation/README-Rigid.md`](Documentation/README-Rigid.md), which stays as the source).* Rigid props for LabKit toys: **Box2D v3.1.1** (MIT, vendored unmodified in `Sources/CBox2D`) behind a small Swift API in SI units. Apps `import LabKitRigid` and never see the C API (`internal import CBox2D`; `CBox2D` is not a product). Provenance: `Sources/CBox2D/UPSTREAM.md` / `UPSTREAM.json`; licence: `THIRD_PARTY_NOTICES.md` (bundle it and credit Box2D in the info sheet).

### Units and frame

- Metres, kilograms, seconds, radians, newtons. `Double` everywhere in the API (Box2D stores `Float`).
- Tank frame: origin bottom-left, y up, the same frame as LabKitMPM's colliders.
- **Densities are areal (kg/m²).** For a prop of density ρ (kg/m³) in a tank of depth d (m), pass ρ·d. Steel in a 1 cm tank: 7850 × 0.01 = 78.5 kg/m².
- Box2D's tolerances are scaled once per process with `b2SetLengthUnitsPerMeter(0.1)` (first `RigidWorld` or `RigidUnits.configure` wins): slop 0.5 mm, restitution and hit thresholds 0.1 m/s, sleep 5 mm/s, maximum speed 40 m/s. That is what makes 2–30 mm props bounce and settle properly.

### API (as shipped)

```swift
public struct RigidBodyID: Hashable, Comparable, Sendable { public let rawValue: Int }   // never reused in a world
public enum RigidShape: Sendable, Equatable {
  case circle(radius: Double), box(halfWidth: Double, halfHeight: Double)
  case capsule(halfLength: Double, radius: Double)        // segment along the body x axis
  case polygon([SIMD2<Double>])                           // convex hull, ≤ 8 vertices after reduction
  var area: Double; var boundingRadius: Double
}
public enum RigidBodyKind: Sendable { case dynamic, kinematic, fixed }
public struct RigidBodySpec: Sendable, Equatable {
  init(kind: = .dynamic, shape:, position:, angle: = 0, density: = 10, friction: = 0.6, restitution: = 0,
       linearDamping: = 0, angularDamping: = 0, enableSleep: = false, userTag: = 0,
       velocity: = .zero, angularVelocity: = 0, reportsHits: = true)
}
public struct RigidPose: Sendable, Equatable {            // all about the body origin
  var position, velocity: SIMD2<Double>; var angle, angularVelocity: Double
  func velocity(at point:) -> SIMD2<Double>; func toWorld(_ local:) -> SIMD2<Double>; static let zero
}
public struct RigidHit: Sendable, Equatable {             // one impact in the last step
  var bodyA, bodyB: RigidBodyID?   /* nil = tank wall */; var tagA, tagB: Int?
  var point, normal: SIMD2<Double>; var approachSpeed: Double   // m/s
  func involves(_:) -> Bool; var involvesWall: Bool
}
public enum RigidUnits {
  static let defaultLengthUnitsPerMetre = 0.1
  static func configure(lengthUnitsPerMetre: Double = 0.1) -> Double   // first call wins
  static var lengthUnitsPerMetre: Double? { get }; static var box2DVersion: String { get }   // "3.1.1"
  static var liveWorldCount: Int { get }
}
public final class RigidWorld {                            // not Sendable (explicitly unavailable)
  init(gravity: SIMD2<Double>, lengthUnitsPerMetre: Double = 0.1)
  let lengthUnitsPerMetre: Double
  var gravity: SIMD2<Double>                               // setting it wakes dynamic bodies; NaN/∞ refused
  var hitSpeedThreshold: Double; var restitutionThreshold: Double   // m/s, default 0.1
  // bodies
  @discardableResult func add(_ spec: RigidBodySpec) -> RigidBodyID
  func remove(_ id:); func removeAll()                     // removeAll keeps the walls
  var bodies: [RigidBodyID] { get }                        // insertion order, walls excluded
  func contains(_:) -> Bool; func spec(_:) -> RigidBodySpec?; func kind(_:) -> RigidBodyKind?; func userTag(_:) -> Int?
  func shape(_:) -> RigidShape                             // what Box2D actually built
  func mass(_:) -> Double                                  // kg; 0 for kinematic/fixed
  func rotationalInertia(_:) -> Double; func centreOfMass(_:) -> SIMD2<Double>
  func pose(_:) -> RigidPose
  func setTransform(_:position:angle:); func setVelocity(_:linear:angular:)
  // tank
  func addWalls(width:height:thickness:top: = true, friction: = 0.6, restitution: = 0); func removeWalls(); var hasWalls: Bool
  // driving
  func setTarget(_:position:angle:dt:)                     // kinematic tools (b2Body_SetTargetTransform)
  func applyImpulse(_:linear:angular:)                     // N·s at the COM, N·m·s about it
  func applyImpulse(_:linear:at:)                          // N·s at a point
  func applyForce(_:_:); func applyTorque(_:_:)            // for the next step only
  func explode(at:radius:falloff: = 0, impulsePerLength:)  // punch
  @discardableResult func beginDrag(_:at:maxForce: = nil, stiffness: = 15, dampingRatio: = 0.9) -> Bool
  func updateDrag(to:); func endDrag(); var draggedBody: RigidBodyID? { get }
  // time and events
  func step(dt: Double, subSteps: Int = 4)
  var hits: [RigidHit] { get }                             // from the last step
  func drainHits() -> [RigidHit]                           // since the last drain, ≤ 64 (weakest dropped)
  var rejectedInputCount: Int { get }                      // NaN/∞ forces, impulses, targets, gravity refused
  func query(point: SIMD2<Double>, radius: Double = 0) -> RigidBodyID?   // dynamic > kinematic > fixed, then nearest
}
```

Unknown or removed ids never crash: queries return neutral values (`RigidPose.zero`, mass 0, a zero-radius circle) and commands do nothing. Programmer errors (non-finite or non-positive sizes, a dynamic body with density 0, non-finite spec values) are preconditions.

### Using it in a toy (Rheo sketch)

```swift
let rigid = RigidWorld(gravity: SIMD2(0, -9.81))
rigid.addWalls(width: 0.0712, height: 0.1014, thickness: 0.01)            // life-size tank, closed top
let ball = rigid.add(RigidBodySpec(shape: .circle(radius: 0.004), position: SIMD2(0.0356, 0.09),
                                   density: 7850 * gap, restitution: 0.4, userTag: Prop.steelBall.rawValue))
let finger = rigid.add(RigidBodySpec(kind: .kinematic, shape: .circle(radius: 0.004), position: start))

// Once per fixed quantum h (1/120 s × time scale), on the main actor:
for (index, id) in coupled.enumerated() {                                  // fluid → body, one frame late
  let j = mpmStats.bodyImpulses[index]                                     // (Jx, Jy, angular) N·s
  rigid.applyImpulse(id, linear: SIMD2(j.x, j.y), angular: j.z)
}
rigid.gravity = screenGravity * gravityKnob
rigid.setTarget(finger, position: fingerPoint, angle: 0, dt: h)
rigid.step(dt: h)                                                          // 4 substeps
// Per display frame: impacts → haptics/sound
for hit in rigid.drainHits() where hit.approachSpeed > 0.15 { haptics.tap(strength: min(1, hit.approachSpeed / 0.8)) }

// Body → fluid: each prop becomes an MPMCollider (LabKitMPM), velocities about the body origin.
func collider(_ id: RigidBodyID, index: Int) -> MPMCollider? {
  let p = rigid.pose(id)
  let shape: MPMCollider.Shape
  switch rigid.shape(id) {
  case .circle(let r): shape = .circle(radius: r)
  case .box(let hw, let hh): shape = .box(halfSize: SIMD2(hw, hh))
  case .capsule(let hl, let r): shape = .capsule(halfLength: hl, radius: r)   // check LabKitMPM's capsule axis
  case .polygon: return nil                                                 // no MPM polygon collider
  }
  return MPMCollider(shape: shape, position: p.position, angle: p.angle, velocity: p.velocity,
                     angularVelocity: p.angularVelocity, friction: rigid.spec(id)?.friction ?? 0.5, bodyIndex: index)
}
```

(The `MPMCollider` initialiser is WP-G's; adapt to what LabKitMPM ships. `haptics.tap(strength:)` stands for the app's own impact cue, for example `HapticEngine.transient(intensity:sharpness:minGap:)`.) For circle, box and capsule props the body origin is the centre of mass, so the angular impulse LabKitMPM reports about the collider position is the one `applyImpulse` expects.

Coupling advice from the research notes (not yet tested against the real solver): the one-frame impulse lag can pump energy into light props in dense fluids. If it does, clamp |Δv| per quantum to about 2·g·h + 0.5·|v_rel| and give coupled props a little linear damping. Do **not** model fluid drag with `linearDamping`: Box2D damps only the carried velocity (v ← h·a + v/(1 + h·c)), so the terminal speed can never fall below g·h ≈ 20 mm/s at 480 substeps/s.

### Threading and global state

`RigidWorld` belongs to one isolation domain (the main actor in Rheo). Box2D's world table (128 slots) and length scale are process-global; `RigidUnits` puts world creation and destruction behind one `Mutex` and fixes the scale before the first world. No Box2D callbacks run during a step (`workerCount = 1`); events are read after it.

### Checks (LabKitRigidTests, one serialised XCTestCase)

Run: `Tools/lk.sh <work-name> env TOOLCHAINS=metal swift test --no-parallel --filter LabKitRigidTests`. Twenty-two tests. Measured on the M1 Max host, 3 October 2026 (WP-R), re-run 4 October 2026 by the WP-R verifier with identical numbers in Debug and Release:

| Check | Pass condition | Measured |
|---|---|---|
| Free fall, 1 s at 120 Hz × 4 substeps | drop within 0.5 % of ½gt² | +0.209 % (4.9152 m vs 4.9050 m; theory for semi-implicit Euler with N = 480 substeps: +1/N = +0.208 %) |
| Resting 1 cm box | centre within 0.5 mm of 5 mm | 4.914 mm (−0.086 mm) |
| Restitution e = 0.8, 4 mm bead, 26 mm drop | apex within 5 % of e²h | 16.53 mm vs 16.64 mm |
| Kinematic tracking, circular path 2 cm at 1 Hz | position < 10 µm, angle < 0.1 mrad; stops dead when the target stops | 3.8 nm, 3.0 µrad; velocity exactly 0 after stopping |
| Impulse → Δv = J/m, Δω = L/I | relative 1e-5 | agree to Float precision (~6e-8) |
| Force balance with `applyForce` | weight-cancelling force: no drift; half weight: ¼gt² within 0.5 % | drift 0.0 m; 2.4576 m vs 2.4525 m (+0.21 %, same discretisation bias) |
| Point query | inside, outside, fingertip radius, walls never picked, dynamic beats fixed | pass |
| Hit events, 4 mm bead, 2 cm drop | exactly one hit, wall + bead + tag, approach within g·dt of √(2gh) | 0.654 vs 0.626 m/s; no hits at rest; none above a 1 m/s threshold |
| Determinism | two identical 20-body runs bitwise equal | pass |
| Sleep | sleep-disabled bead sinking at 3 mm/s keeps sinking; sleep-enabled one freezes | 5.14 mm (model 5.10 mm) vs 0.80 mm in 2 s |
| Drag | bead within 2 mm of the finger after 1 s | 1.10 mm (spring sag g/ω² = 1.1 mm at 15 Hz) |
| Walls and tilt | rests at x = width − r under sideways gravity; closed top holds it upside down | pass |
| Polygon | 12-gon reduced to ≤ 8 vertices; mass = density × built area; a degenerate polygon becomes a disc centred on the body origin | Box2D built 7 vertices (it welds near-collinear points) |
| Point impulse, torque, teleport, wall removal | Δω = (p − c) × J / I and τ·dt/I to 1e-5/1e-4; `setTransform` exact to Float; bead falls out once walls are removed | pass |
| Non-finite gravity | NaN/∞ gravity refused (counted in `rejectedInputCount`), bodies stay finite; a `setTarget` dt that is 0 in Float is refused | pass |
| Lifecycle | worlds destroyed with the wrapper; 300 sequential worlds fit in Box2D's 128 slots | pass |
| Benchmark (informational) | 500 awake balls, 4 substeps | 0.13–0.15 ms per step (Debug Swift, C at -O2) |

iOS: `xcodebuild -scheme LabKitRigid` for `generic/platform=iOS Simulator` and `generic/platform=iOS` both build with 0 warnings. Not yet run on a phone.

### Box2D quirks handled by the wrapper

- `b2MakeRot` uses Bhaskara's cosine approximation (≈ 1.6 mrad error): rotations are built from exact `cos`/`sin`, and poses report `atan2` of the stored rotation.
- `b2Body_SetTargetTransform` ignores "sleepy" targets (below 5 mm/s), which would leave a stopped tool drifting: `setTarget` writes the velocities itself.
- Box2D's hull drops vertices within 1 mm of their neighbours' chord and takes at most 8: `shape(_:)` reports what was built; degenerate polygons fall back to a disc of equal area centred on the body origin (where `RigidShape.circle` is defined).
- Hit approach speeds are read at the start of the step that resolves the contact, so they are within ± g·dt of the true impact speed.

## LabKitMPM (GPU continuum engine)

*Owned by WP-G.* A 2D continuum engine on the GPU: PB-MPM's fused `g2p2g` tile solver (EA SEED, BSD-3, ported to Metal; credit EA SEED in the info sheet, never "powered by EA") running the unified elasto-viscoplastic model of `rheology-models.md` §4 as a compliant constraint, plus a 2.5D fluid surface renderer. Full numbers: [`Documentation/VERIFICATION-GPU.md`](Documentation/VERIFICATION-GPU.md).

**Units and frame.** SI `Double` in every public type; the tank frame has its origin bottom-left, y up (the same frame as LabKitRigid). Materials are `ContinuumMaterial` values (`ContinuumPresets.honey` …), index = particle material id (≤ 16). The thin tank is 2D plus a Hele-Shaw gap (`MPMDomain.heleShawGap`, default 10 mm): masses, energies and `bodyImpulses` are for the whole gap, so they apply directly to LabKitRigid bodies with areal density ρ·gap.

```swift
let solver = try MPMSolver(device: device, domain: MPMDomain(), quality: .standard, capacity: 40_000)
solver.materials = ContinuumPresets.all.map(\.material)
solver.fill(rect: CGRect(x: 0, y: 0, width: 0.0712, height: 0.04), material: 1, temperature: 293.15)   // honey
let surface = try MPMSurfaceRenderer(device: device)        // looks: FluidLook.all, same order as the presets

// encodeCompute (every frame):
var input = MPMFrameInput(dt: 1.0 / 120, gravity: tankGravity)
input.colliders = [MPMCollider(shape: .capsule(halfLength: 0, radius: 0.005), position: finger, velocity: fingerVelocity, bodyIndex: 0)]
solver.encode(into: cmd, input: input)                      // every substep of the frame; never waits
surface.encodePrepass(cmd, solver: solver, tankToClip: tankToClip, drawableSize: sceneSize, options: options)
// encodeScene (wantsBehindCopy = true):
surface.encodeShade(enc, behind: context.targets.behind!, tankToClip: tankToClip, time: t, options: options)
// next frame: solver.stats (1–2 frames old): bodyImpulses → RigidWorld.applyImpulse, probe → rheometer and haptics
```

| Quality | Δx | substep cap | dam break, 1/120 s frame, M1 Max GPU (run) | use |
|---|---|---|---|---|
| `.standard` | 2.0 mm (36 × 51 cells) | 20 | ≈ 1.1 ms, 11 substeps | 120 Hz default |
| `.high` | 1.6 mm | 32 | ≈ 1.5 ms, 14 substeps | 60 Hz quality mode |
| `.bench` | 1.1 mm | 64 | ≈ 3.3 ms, 19 substeps | Mac benchmarks and verification |

The renderer adds about 0.3–0.8 ms (prepass) + 0.4–1.3 ms (shade) at 1290 × 2796 on the M1 Max. **On the iPhone 15 Pro Max** (Rheo's device run 1, 9 October 2026, Release, `.standard`, about 3,300 particles, before LK-FIX's solver changes): the GPU time of a whole Rheo frame (solver substeps and every render pass in one command buffer) was 5.2–7.7 ms for water, honey, ketchup, mayonnaise, toothpaste and slime, and 8.2–10.1 ms for oobleck, whose stiff jammed branch drives the elastic substep rule to 15–16 substeps (`../Rheo/Documentation/DEVICE-RUN-1.md`). The 8.3 ms budget at 120 Hz holds for everything but oobleck; repeat the run on the final sources (`../Rheo/Documentation/DEVICE-RUN.md`) before choosing the default.

Things to know:

- **Substeps** follow `MPMSubstepRule` (hydrostatic Π ≤ 0.07, ≤ 1 cell per substep, ≥ 8 per vibration period, elastic wave rule). Above `maxSubsteps`, simulated time slows and `stats.lagging` is true.
- **Stats** come from a pool of shared readback buffers polled without waiting, so they are 1–2 frames old. `debugValidation` (DEBUG default) prints when NaN resets or fixed-point overflows appear.
- **Colliders** are kinematic shapes (≤ 32) extrapolated through the frame from their frame-start pose and velocity; `bodyIndex` 0..<16 sums the fluid's impulse on them (Jx, Jy, angular about the frame-start position). Grid nodes within `colliderSkin` (1 cell) outside a shape already feel it, which makes buoyancy right (within 6 % of ρgA at every quality) but leaves a one-cell gap between fluid and prop: draw props that much larger or shrink their colliders.
- **`setQuality`** resamples the fluid on the CPU when a copy-back completes (no GPU wait), costing about 20–30 ms of main-thread time once (measured in release on the M1 Max).
- **`encodeShade`** draws a premultiplied quad over the tank with no depth test and leaves its own pipeline and depth state on the encoder: set yours again afterwards.
- **iOS simulator.** The simulator GPU reports only the Apple2/Common1 families, so SIMD-group functions are probed at init (`simdProbePassed`); a threadgroup-atomic fallback is selected if the probe fails (bitwise the same particle state; tested). All 24 `LabKitMPMTests` pass in the iOS 27 simulator.
- **Volume after landing (LK-FIX, wave 3).** The grid-volume J correction is two-sided: an under-filled particle away from colliders gives up compression beyond `underfillTolerance` (3) gravity kicks, and the tank walls and floor mirror the grid fill. Before, a particle that landed compressed (J ≈ 0.85–0.95) among gaps kept its pressure and held the gaps open: poured honey stood as a particle foam (Rheo's cold-honey pour: foam index 1.42, surface 73.1 mm for 52.4 mm of honey; now 0.99 and 50.3 mm). Water still splashes. Switches for comparisons: `MPMVerificationOptions.twoSidedVolumeCorrection`, `.underfillTolerance`, `.wallMirrorVolume`. **Known limitation:** a yield-stress pool (ketchup, toothpaste) that settled at 1 g sits 3–4 mm above the floor at 0 g (upstream: 0.3 mm). It needs both the two-sided correction and the mirror, and the mechanism is not pinned down; without the mirror the floor rows compact instead and Rheo's toothpaste demonstration fails its lean limit.
- **Virtual magnet (LK-FIX).** The Kelvin force is still capped at 3 g per particle. The magnet's |H| is radial, so the capped force is still the gradient of a potential (Φ = μ₀χH²/2ρ outside the radius where it reaches the cap, linear inside). Where the cap bites, the field-induced yield is scaled by the same factor (`MPMVerificationOptions.kelvinYieldScaling`, default on), so drive and yield keep their physical ratio. With 207 mT at 1 cm, MR fluid heaps over the magnet in shallow pools (8 mm: +4.1 mm, 12 mm: +2.3 mm; before: −1.3 / −0.5 mm dips) and stiffens (a finger meets 7.9× the force over the magnet, 10.7× 15 mm off). A 30 mm or deeper pool does not heap (−0.7 mm). Its surface lies outside the capped zone (about 25 mm at 207 mT), where the Kelvin pressure difference along the surface is about 50 Pa against a field yield of about 1.2 kPa. That is the model's honest answer: it has no magnetic surface traction, so it cannot form Rosensweig spikes. The substep rule counts the capped magnetic potential as extra head (`MPMConstants.kelvinHead`).
- **Temperature band per material (LK-FIX).** `ContinuumMaterial.temperatureBandBelow` (nil = the global 40 K) widens the cold side of the band the flow law sees. Lava uses 230 K, so it stiffens from the 1170 °C eruption down to 900 °C (τ̄ at 1 s⁻¹: 533 Pa → 11.9 kPa, GPU = oracle within 5e-6, V14e). Real basalt stiffens far more as it crystallises; this extrapolates the two-point Arrhenius fit.
- **Verification harness:** `Tools/lk.sh me env TOOLCHAINS=metal swift run -c release labkit-gpucheck [dam pi mass buoyancy materials oobleck pour magnet v13 v14 render] [--png sheet.png]` (≈ 3 minutes; V14 checks parity with `LabKitMPMReference`). Development entries outside `all`: `foamdev`, `mrdev`, `mrfinger`, `mrabove`, `monstersdev`, `gravitydev` (env-driven, see their source).

## LabKitMPMReference (CPU oracle)

*Owned by WP-O.* A CPU, `Double`, explicit 2D MLS-MPM solver (quadratic B-splines, 2×2 particles per cell, SI units) running the same unified elasto-viscoplastic material update as the GPU engine. It is the physics oracle: the V-suite checks it against closed-form solutions, and WP-G's V14 checks the GPU against it. Spec: `Rheo/Documentation/research/rheology-models.md` §4, §6, §7 and Appendix B.

| API | What it does |
|---|---|
| `ContinuumPresets` (in **LabKitCore**) | the 13 Rheo materials as `ContinuumMaterial` values (`waterLike` … `lava`, `all` with display names in shelf order) plus `extras` (rheopectic cream, ferrofluid, blood, shampoo, glycerol) and `named(_:)`; values from §6 revision 2 with provenance comments |
| `EVPState`, `EVP.update(_:velocityGradient:dt:material:fieldMagnitude:)` | one particle's constitutive step: b̄ₑ, J, structure λ, contact fraction f, T, γ̇ₚ in; Kirchhoff (τ11, τ12, τ22) out. `diagnostics:` overload reports τ̄_tr, τ̄, γ̇, γ̇ₚ, jam blend, a_T, τ_field, guard hits. C convention: c11 = ∂vₓ/∂x = `C[0][0]`, c12 = ∂vₓ/∂y = `C[1][0]` |
| `ReferenceScene`, `ReferenceSolver2D` | periodic or walled (sticky, moving, slip, open) domains, body force a(x, t) with ramp and vibration helpers, Hele-Shaw drag (fixed, Newtonian, gap-averaged power law), kinematic boxes with reaction forces, MR field lag and Kelvin force, temperature relaxation, optional grid-volume J correction; `step(dt:)`, `advance(by:dt:)`, `suggestedTimeStep()`, `particles`, `gridVelocity(atRow:)`, `profile(…)`, guard `counters` |
| `ReferenceLaws` | the closed forms of V1–V12 (hydrostatics, HB Couette/Poiseuille/film, Kolmogorov, Maxwell, Moore, bifurcation, Hele-Shaw, Han front ratio, Carlson, Cheng, honey) |

The solver is single-threaded and not `Sendable` (confine it to one thread); it is for Mac harnesses and tests, not for the app's frame loop.

| Claim | Status | Evidence |
|---|---|---|
| `labkit-physcheck mpm` (V1–V10 and V12, the required set) | **run** | 55 PASS, 0 FAIL, exit 0; about 135 s of CPU in release. `mpm V3 V4` runs single cases, `mpm full` adds V11 |
| `LabKitMPMReferenceTests` | **run** | 35 tests, 0 failures (macOS, debug) at the time; 41 since LK-FIX (QA pass, 9 October 2026) |
| iOS Simulator and device builds of `LabKitMPMReference` | **built** | 0 warnings |
| V11 oobleck jamming front | **run, exploratory** | front 3.3–4.3 × the plate speed against Han's 6.96: hypothesis not met (info rows only) |

Numbers, set-ups and known limits (sticky-wall row artefact, coarse-gap shear thinning, finite-Wi deficit): [`Documentation/VERIFICATION-MPM.md`](Documentation/VERIFICATION-MPM.md).

## Wave 3 changes (LK-FIX, 9 October 2026)

Every API change is additive and source-compatible. Numbers and before/after tables: [`Documentation/VERIFICATION-GPU.md`](Documentation/VERIFICATION-GPU.md#lk-fix-wave-3-9-october-2026) and [`Documentation/VERIFICATION-MPM.md`](Documentation/VERIFICATION-MPM.md).

| Where | Added | Default behaviour change |
|---|---|---|
| LabKitMPM | `MPMVerificationOptions.twoSidedVolumeCorrection`, `.underfillTolerance`, `.wallMirrorVolume`, `.kelvinYieldScaling`; `MPMConstants.kelvinAccelerationCap`, `MPMConstants.kelvinHead(…)` | **yes, for every material:** two-sided grid-volume J correction and mirrored wall fill (no particle foam after a pour or splash; a resting pool keeps 96–100 % of its volume), the field yield scaled where the Kelvin cap bites (MR fluid heaps in shallow pools), extra substeps for the magnet's potential. Apps should re-run their physics tests |
| LabKitMPM GPU table | `PBMaterial` grew 192 → 208 B (`bandBelow`, `bandAbove`, two pads) | none outside LabKitMPM (no app reads it) |
| LabKitCore | `ContinuumMaterial.temperatureBandBelow` (and the init parameter); `ContinuumPresets.lava` sets 230 K | lava stiffens down to 900 °C |
| LabKitMPMReference | `EVP.bandBelow(_:)`, `ReferenceScene.gridVolumeUnderfillTolerance`, `ReferenceSolver2D.fieldScaled(_:_:)` | the oracle scales the field yield where the Kelvin force is capped, as the GPU does |
| LabKitRender | `RenderTargets(device:size:wantsBehind:behindMipLevels:)`, `RenderTargets.liveBehindMipLevels`; `PostChain.pass(_:clear:alpha:)` takes an optional texture | `LabRenderer`'s `behind` has 8 mip levels instead of the full chain; no per-frame pass descriptors |
| LabKitCore | — | `LabColor.linearDisplayP3` no longer allocates |
| LabKitFeedback | `SynthHost.rebuildAfterMediaReset()`, `SynthHost.rebuilds` | a media-services reset now rebuilds the engine and node |
| labkit-gpucheck | sections `pour` (F1–F4) and `magnet` (M5) in `all`, V14e in `v14`; dev entries `foamdev`, `mrdev`, `mrfinger`, `mrabove`, `monstersdev`, `gravitydev` | — |
| LabKitMPMTests | `testMagnetPullsMRFluidAndStiffensIt` rewritten: a magnet held above now pulls ferrofluid and MR fluid up to it (the old 0.3 mm bulge came from upstream volume handling holding the pool down) | — |


## Public snapshot

See [PUBLICATION.md](PUBLICATION.md) for publication exclusions and setup requirements.
