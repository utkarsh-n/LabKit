# LabKit runtime: Core, Sensors, Feedback, Render

The non-UI half of LabKit: maths, time, integrators, the modulation ("Drives") router, sensors with simulator fakes, the haptics and sound policy, and the Metal render host with bloom and EDR. LabKitUI (chrome, knobs, palette) is documented separately.

*Written by WP-C2 on 4 October 2026, to be merged into `LabKit/README.md`.*

## Module map

| Module | Platforms | What it holds |
|---|---|---|
| `LabKitCore` | iOS, macOS | `V2/V3/F2/F3/F4` maths, `XorShift32`; `approach`, `AttackRelease`, `Throttle`, `FrameClock`, `SimClock`, `FixedStep`; `RK4`, `substepCount`, `symplecticEuler`, `DampedSpring`, `RingBuffer`; `MotionSample`, `LabEnvironment`, `TouchSample`, `SourceConditioner`; `MicSnapshot`, `OnsetAnalyser`, `EnvelopeFollower`, `ScopeData`, `Spectrum`, `EMFMeter`; `ModSourceID`, `ModRoute`, `ModulationRouter`, `LFO`; the pure halves of feedback (`HumGovernor`, `HumPolicy`, `StressFeel`, `FeelEventDetector`, `FeelCauses`, `SoundPolicy`, `logPitch`); `DeviceConditions`, `FramePacing`; `PhysCheck`. (Params, palette, formats and plot maths in Core belong to the UI work.) |
| `LabKitSensors` | iOS | `MotionSource` (pulled once per frame), `MicListener` (iOS 27 `installAudioTap`), `ThermalSource`, `LaunchOptions` |
| `LabKitFeedback` | iOS | `HapticEngine`, `HapticTap`, `SynthHost` + `SynthKernel` + `SynthControls`, `RotorHumKernel`, `SilentKernel`, `SonicCue`, `LabFeedback` (the policy object apps hold), `AudioRoute` |
| `LabKitShaderTypes` | C | `LabFrameUniforms`, `LabLineInstance`, `LabMeshVertex`, `LabQuadInstance`, buffer-index enums (one header for Swift and MSL) |
| `LabKitRender` | iOS (+ macOS for offscreen use) | `LabRenderHost`, `LabRenderer`, `LabRenderScene`, `LabFrameEncoder`, `LabFrameContext`, `RenderTargets`, `PostChain`, `PipelineFactory`, `DepthStates`, `LayoutCamera` (perspective, orthographic, orthographic world rect), `LineBatch`/`LineRenderer`, `QuadRenderer`, `MeshBuilder`/`GPUMesh`, `LabShaders`; `Shaders/LabKit.metal` + header-only `LabKitShaderLib.h` |

Core is Foundation + simd + Accelerate only, so the Mac harness (`labkit-physcheck`) and XCTest run it without a simulator.

## How an app adopts it (the frame loop)

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

Frame order inside the renderer: `advance` → `buildLines` → `fillUniforms` → `encodeCompute` → pass 1 (backdrop, `encodeBehind`) → if `wantsBehindCopy`: blit to the mipmapped `behind` texture + `generateMipmaps` → pass 2 (load) → `encodeScene` → lines (additive) → bloom ½ + ¼ → composite (aberration, scanlines, EDR soft-clip at min(headroom, 3), knee 0.8). Scene colour `rgba16Float`, depth `depth32Float`.

**Frame budget.** At most 2 command buffers in flight. The renderer tries the in-flight semaphore with `wait(timeout: .now())`; when both slots are busy it skips the display frame (no advance, no encode; counted in `renderer.stats.skippedFrames`) instead of blocking the main thread. Every 0.5 s it asks for 60 fps under Low Power Mode or thermal state ≥ serious, 120 fps otherwise (`FramePacing`). `stats.gpuMilliseconds` is the smoothed GPU time from completion handlers. On iPhone, 120 fps also needs `CADisableMinimumFrameDurationOnPhone: true` in the app's Info.plist.

**Orthographic tank.** `.orthographicRect(world, fit:)` maps a world rectangle (x right, y up, any units) onto the eased canvas region; with `.stretch` the world's corners land on the region's corners. `LayoutCamera.orthographicMatrix(world:regionPx:drawablePx:fit:)` is the same matrix as a pure function. Checked on screen in the WP-C2 smoke app (life-size 71.2 × 101.4 mm tank, lines, a refraction pane sampling `behind`, bloom).

**Shaders.** Xcode compiles `Shaders/LabKit.metal` into `LabKit_LabKitRender.bundle/default.metallib`; `LabShaders.library(device:)` loads it. App shaders reuse the helpers with `MTL_HEADER_SEARCH_PATHS: "$(SRCROOT)/../LabKit/Sources/LabKitRender/Shaders $(SRCROOT)/../LabKit/Sources/LabKitShaderTypes/include"` and `#include "LabKitShaderLib.h"`. `PipelineFactory.make(vertex:fragment:vertexLibrary:fragmentLibrary:…)` mixes LabKit and app functions; it never sets a nil label (that asserts under Metal validation).

## Feedback policy (haptics and sound)

- **Two haptic channels.** Transients answer something the user did (`HapticTap` vocabulary: `.tap .grab .tick .detent .switchClick .release .boundary .reset .soft .select .place .poke .ripple`, plus `selection()`, `success()`, `ramp()`, `crackle()`; Gyre's names `knobGrab` etc. remain as deprecated aliases). The hum ("Feel") follows `HumPolicy.causal(maxIdle: 8)`: it plays only within 8 s of `noteCause()`, with a 0.25 s lag, stopping below 0.02, at ≤ 40 parameter sends a second.
- **Strength** 0.2…1 (default 0.85) scales both channels; under VoiceOver the hum plays at × 0.6.
- **Stop rules.** Everything stops on `stop()` / `setActive(false)` and on `didEnterBackground`. The hum stops while paused, in Low Power Mode and at thermal state ≥ serious; the sound bed stops while paused and in Low Power Mode (not on thermal state, per the sound policy); transients and cues stay.
- **Rheo's map** (`StressFeel`): intensity = clamp(0.15·log₁₀(1 + σ̃/0.1 Pa)), sharpness = clamp(0.15 + 0.7·s_f + 0.15·min(1, v/0.5 m/s)); `FeelEventDetector` emits yield / jam / unjam / grain events with hysteresis.
- **Sound.** One bed voice per app (`SynthKernel`, set through atomic `SynthControls` slots) plus `SonicCue`s, each paired with a haptic twin (`.tick .detent .threshold .resonance .action`). Sound is on by default, persisted as `"<App>.sound"`, and follows the ring/silent switch (`.ambient`). With the mic live the session is `.playAndRecord` (which ignores the switch), so the bed ducks to × 0.3, cue partials within ± 1 octave of `micBand` are dropped, and every self-made cue or poke opens a 0.2 s onset-ignore window. Echo-cancelled input is opt-in (`AudioRoute.prefersEchoCancellation`) and checked at runtime (`echoCancellationAvailable`, `echoCancelledInputActive`).
- **Swift 6.** Every audio render block, tap, Core Haptics handler and notification closure is built in a `nonisolated static` factory or written `{ @Sendable … }`.

## Launch arguments

Fakes are honoured in DEBUG builds, or in any build when the real hardware is missing (`LaunchOptions.fake(_:hardwareAvailable:)`).

| Flag | Effect |
|---|---|
| `-simSway` | the simulated phone sways (yaw ± 0.9, pitch ± 0.3, roll ± 0.25 rad) |
| `-fakeMic` | a synthetic room (hummed chord, a clap every 1.6 s) through the real ring and analyser; no permission prompt |
| `-startMic` | the app turns the mic on at its first `start()` (`LaunchOptions.startMicRequested`) |
| `-fakeMagnet` | a magnet swings past every 6 s (up to 2 mT), layered over live or simulated readings |
| `-fakeShake` | 0.4 s bursts of 12 Hz at ± 1.2 g every 3 s |
| `-fakeThermal 0…3` or `cycle` | pretend thermal state (cycle steps every 8 s; no value means 2, serious); drives the 60 fps cap and the hum stop rule |
| `-fakeLowPower` | pretend Low Power Mode |
| `-fakeTouch` | reserved (not read by LabKit yet) |

Example: `xcrun simctl launch booted com.utkarsh.rheo -simSway -fakeMic -startMic -fakeMagnet -fakeShake`.

## Build and test

Never build inside iCloud: `Tools/lk.sh <work-name> <command…>` mirrors the package to `$TMPDIR/labkit-<work-name>/LabKit` first.

```zsh
Tools/lk.sh me xcodebuild -scheme LabKit-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath ../dd build
Tools/lk.sh me xcodebuild -scheme LabKit-Package -destination 'generic/platform=iOS' -derivedDataPath ../dd build
Tools/lk.sh me xcodebuild test -scheme LabKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath ../dd -only-testing:LabKitCoreTests -only-testing:LabKitRenderTests
Tools/lk.sh me swift run -c release labkit-physcheck core          # Mac, no Metal
Tools/lk.sh me env TOOLCHAINS=metal swift build --target LabKitRender   # SwiftPM needs the Metal toolchain
```

## Verification (4 October 2026)

| Claim | Status |
|---|---|
| Core, Sensors, Feedback, ShaderTypes, Render build for iOS Simulator and device (clean build incl. `LabKit.metal`), 0 warnings | built |
| `LabKitCoreTests` 78/78 (router, conditioner, integrators, clocks, feel, sound policy, pacing, plus the UI-model tests) and `LabKitRenderTests` 8/8 (metallib loads, pipelines build, shared layouts, `behind` is mipmapped, orthographic matrix maps tank corners to the canvas region, fit modes, the two-phase pass feeds `behind` to pass 2, single pass without the copy) on an iPhone 15 Pro Max simulator, and again on the Mac (`TOOLCHAINS=metal swift test`) | run, pass |
| `labkit-physcheck core`: 11/11 PASS (RK4 energy, substep rule, knob maths, gravity and kick drives, envelope, spectrum band, screen gravity) | run, pass |
| Smoke app (Swift 6 strict, XcodeGen) renders the orthographic tank, lines, the behind-copy refraction pane and bloom; `-fakeThermal 2` drops it to 60 fps | run in the simulator, screenshots inspected |
| Haptic feel, hum levels, Strength, echo cancellation, speaker audibility of low cues, real mic tap sizes | written, not testable in the simulator (`supportsHaptics == false`); needs the iPhone 15 Pro Max |
