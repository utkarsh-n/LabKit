// swift-tools-version: 6.4
// `.iOS(.v27)` / `.macOS(.v27)` need tools-version 6.4 (PackageDescription marks v27 `@available(_PackageDescription 6.4)`).
// `.macOS(.v27)` is load-bearing: without it the Metal targets compile for an old macOS and `swift test` fails.
//
// Ownership: this manifest belongs to the integrator (see Rheo/Documentation/ARCHITECTURE.md §2).
// Work packages may edit only their own target's settings block; new targets go through the integrator.
import PackageDescription

let package = Package(
  name: "LabKit",
  platforms: [.iOS(.v27), .macOS(.v27)],
  products: [
    .library(name: "LabKitCore", targets: ["LabKitCore"]),
    .library(name: "LabKitSensors", targets: ["LabKitSensors"]),
    .library(name: "LabKitFeedback", targets: ["LabKitFeedback"]),
    .library(name: "LabKitUI", targets: ["LabKitUI"]),
    .library(name: "LabKitMetro", targets: ["LabKitMetro"]),
    .library(name: "LabKitRender", targets: ["LabKitRender"]),
    .library(name: "LabKitShaderTypes", targets: ["LabKitShaderTypes"]),
    .library(name: "LabKitRigid", targets: ["LabKitRigid"]),
    .library(name: "LabKitMPM", targets: ["LabKitMPM"]),
    .library(name: "LabKitMPMTypes", targets: ["LabKitMPMTypes"]),
    .library(name: "LabKitMPMReference", targets: ["LabKitMPMReference"]),
    .library(name: "Wave", targets: ["Wave"]),
    .executable(name: "labkit-physcheck", targets: ["LabKitPhyscheck"]),
    .executable(name: "labkit-gpucheck", targets: ["LabKitGPUCheck"]),
  ],
  targets: [
    // Pure Swift + simd + Accelerate. Nonisolated by default so solvers and the Mac harness can use it anywhere.
    .target(name: "LabKitCore"),
    .target(name: "LabKitSensors", dependencies: ["LabKitCore", "LabKitFeedback"]),
    .target(name: "LabKitFeedback", dependencies: ["LabKitCore"]),
    // SwiftUI chrome: MainActor by default (SE-0466). Shapes and token enums must be `nonisolated`.
    .target(
      name: "LabKitUI", dependencies: ["LabKitCore", "LabKitFeedback"],
      swiftSettings: [.defaultIsolation(MainActor.self)]),
    // Metro Station design system (edition 1.0, the user's default for new iPhone apps): tokens, materials, components,
    // the touch boundary and the lens shader, compiled into this target's own bundle (looked up via Bundle.module).
    .target(
      name: "LabKitMetro", dependencies: ["LabKitCore", "LabKitFeedback"],
      resources: [.process("Shaders")],
      swiftSettings: [.defaultIsolation(MainActor.self)]),
    // C header shared by Swift and MSL (frame uniforms, line instances, mesh vertices).
    .target(name: "LabKitShaderTypes"),
    .target(
      name: "LabKitRender", dependencies: ["LabKitCore", "LabKitShaderTypes"],
      resources: [.process("Shaders")]),

    // Box2D v3.1.1 (MIT), vendored verbatim. Never a product: apps go through LabKitRigid.
    // SwiftPM defines neither NDEBUG nor an optimisation level for C in Debug; Box2D at -O0 is 10–15× slower.
    .target(
      name: "CBox2D",
      exclude: ["LICENSE", "UPSTREAM.md", "UPSTREAM.json", "src/CMakeLists.txt", "src/box2d.natvis"],
      sources: ["src"],
      publicHeadersPath: "include",
      cSettings: [
        .define("NDEBUG", .when(configuration: .release)),
        .unsafeFlags(["-ffp-contract=off", "-O2"]),
      ]),
    .target(name: "LabKitRigid", dependencies: ["LabKitCore", "CBox2D"]),

    // 2D MPM continuum engine: PB-MPM GPU infrastructure (EA SEED, BSD-3, ported to Metal) + the EVP material model.
    .target(name: "LabKitMPMTypes"),
    .target(
      name: "LabKitMPM", dependencies: ["LabKitCore", "LabKitMPMTypes"],
      resources: [.process("Shaders")]),
    // CPU (Double) explicit MLS-MPM oracle with the same constitutive model. Foundation + simd only.
    .target(name: "LabKitMPMReference", dependencies: ["LabKitCore"]),

    // Wave 0.3.4 by Janum Trivedi (MIT), vendored verbatim: spring-based, interruptible interface animation.
    // Swift 5 language mode because upstream predates Swift 6 strict concurrency.
    .target(
      name: "Wave", exclude: ["LICENSE.md", "UPSTREAM.md", "UPSTREAM.json"],
      // Upstream calls UIScreen.main (deprecated in iOS 26); the source stays verbatim, so silence this target only.
      swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-suppress-warnings"])]),

    // Mac harnesses. physcheck: `swift run -c release labkit-physcheck` (no Metal needed).
    // gpucheck: `TOOLCHAINS=metal swift run -c release labkit-gpucheck` (GPU vs CPU parity on the Mac GPU).
    .executableTarget(name: "LabKitPhyscheck", dependencies: ["LabKitCore", "LabKitMPMReference"]),
    .executableTarget(name: "LabKitGPUCheck", dependencies: ["LabKitCore", "LabKitMPM", "LabKitMPMReference"]),

    .testTarget(name: "LabKitCoreTests", dependencies: ["LabKitCore"]),
    .testTarget(name: "LabKitRenderTests", dependencies: ["LabKitRender"]),
    .testTarget(name: "LabKitRigidTests", dependencies: ["LabKitRigid"]),
    .testTarget(name: "LabKitMPMTests", dependencies: ["LabKitMPM", "LabKitMPMReference"]),
    .testTarget(name: "LabKitMPMReferenceTests", dependencies: ["LabKitMPMReference"]),
    .testTarget(name: "WaveTests", dependencies: ["Wave"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "LabKitMetroTests", dependencies: ["LabKitMetro", "LabKitCore"],
      resources: [.copy("Resources/design-tokens.json")]),
  ],
  swiftLanguageModes: [.v6],
  cLanguageStandard: .c17
)
