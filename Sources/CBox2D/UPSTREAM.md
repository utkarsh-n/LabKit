# Box2D (vendored)

This target builds **Box2D v3.1.1**, commit `8c661469c9507d3ad6fbd2fea3f1aa71669c2fe3` (lightweight tag, committed 2025-06-03), as an unmodified C17 static library for LabKit. Swift reaches it only through the `LabKitRigid` wrapper, which uses `internal import CBox2D`; `CBox2D` is never a package product. Source provenance and checksums are also recorded in `UPSTREAM.json`.

The upstream source is from https://github.com/erincatto/box2d and is covered by the MIT License in `LICENSE`, copyright (c) 2022 Erin Catto. Source files keep their `SPDX-License-Identifier: MIT` headers. The full notice is reproduced in `LabKit/THIRD_PARTY_NOTICES.md`, which apps must bundle and credit in their info sheet (the MIT notice must ship inside every `.app`).

## Provenance

| Item | Value |
|---|---|
| Tag | `v3.1.1` (lightweight: no tag object) |
| Commit | `8c661469c9507d3ad6fbd2fea3f1aa71669c2fe3` |
| Tree | `f411f5197e73db138a249525ad3f1315816a956b` |
| Archive | https://github.com/erincatto/box2d/archive/refs/tags/v3.1.1.tar.gz, 780,115 bytes, SHA-256 `fb6ef914b50f4312d7d921a600eabc12318bb3c55a0b8c0b90608fa4488ef2e4` (GitHub archives are usually but not contractually stable; the commit is the authority) |
| `LICENSE` SHA-256 | `68a3e676d7e94093b102d5cba0d4e04af812040d6f230c3db67a6664574e43d2` |
| Vendored tree manifest | `47441ae45a0a354fef117e0684bc768b236faffc1ce9e3c273a99bad5b30f2eb` (every file under `include/box2d`, `src`, plus `LICENSE`) |
| Compiled-set manifest | `5f8e10b1017e90701e9cba7c639169cd4277844db244de0d4a89b0f15943d479` (`*.c`, `*.h`, `LICENSE`; matches the value in `oss-integration-lessons.md` §3.1) |

Verified on 3 October 2026 (WP-R): `diff -r` of `src/`, `include/box2d/` and `LICENSE` against a clone of the tag **and** against the extracted tarball found no differences; `git get-tar-commit-id` on the tarball prints the commit above; the 57 files in `src/*.c` + `src/*.h` are exactly upstream's `BOX2D_SOURCE_FILES` and the six headers exactly `BOX2D_API_FILES` (`src/CMakeLists.txt`). Re-check with:

```zsh
cd LabKit/Sources/CBox2D
find include/box2d src LICENSE -type f | sort | xargs shasum -a 256 | shasum -a 256          # 47441ae4…
find include/box2d src LICENSE -type f \( -name '*.c' -o -name '*.h' -o -name LICENSE \) \
  | sort | xargs shasum -a 256 | shasum -a 256                                               # 5f8e10b1…
```

## Preserved behaviour (all upstream; no modifications)

- Every file under `src/`, `include/box2d/` and `LICENSE` is byte-identical to the tag. `modifiedUpstreamFiles` is empty.
- Soft-step solver, sub-stepping, continuous collision, hit/contact/sensor events, joints, explosions, `b2Body_SetTargetTransform`, cross-platform determinism (with `-ffp-contract=off`, as upstream's CMake sets on Apple).
- SIMD path chosen by `src/core.h` from the target: NEON on arm64 device and simulator, SSE2 on the x86_64 simulator. No defines needed.

## LabKit additions

- `include/module.modulemap` (hand-written): `module CBox2D { header "box2d/box2d.h" export * }`. `box2d.h` includes the other five public headers. The explicit map avoids SwiftPM's umbrella-header guessing (an umbrella header next to `include/box2d/` is rejected as an invalid layout, and case-insensitive APFS makes `Box2D/Box2D.h` "exist").
- `UPSTREAM.md` and `UPSTREAM.json` (this provenance). Both are in the target's `exclude:` list.

## Vendored but not compiled

`src/CMakeLists.txt` (kept so the source list can be re-checked) and `src/box2d.natvis` (a Visual Studio debugger visualiser). Both are in `exclude:`; `exclude:` entries must exist on disk, so delete them only together with the manifest entries.

Not vendored at all: `samples`, `test`, `benchmark`, `shared`, `extern`, `docs`, the top-level `CMakeLists.txt` and build scripts.

## Build settings (`Package.swift`, target `CBox2D`)

- `cLanguageStandard: .c17` (package-wide). Upstream uses C17 with extensions; both `-std=c17` and `-std=gnu17` compile with 0 warnings.
- `.define("NDEBUG", .when(configuration: .release))`: SwiftPM never defines `NDEBUG`, so without this Release builds keep `B2_ASSERT` on. Debug builds keep the asserts (they catch misuse such as a zero-initialised definition).
- `.unsafeFlags(["-ffp-contract=off", "-O2"])`: upstream determinism flag, and `-O2` in every configuration because SwiftPM's Debug `-O0` makes a Box2D step 10–21× slower. Clang honours the last `-O`, so `-O2` overrides SwiftPM's `-O0`/`-Os` (checked in the response files: Debug `-O0 … -O2`, Release `-Os -DNDEBUG … -O2`). `unsafeFlags` restricts LabKit to being consumed by local `path:`, which is how the apps use it.
- Never set `BOX2D_VALIDATE` (heavy internal validation) or `BOX2D_DISABLE_SIMD`. Never pass global `OTHER_CFLAGS` with `-Wconversion`: upstream produces ~875 conversion warnings under it.

## Global state and threading

Box2D v3.1.1 keeps three things per process, not per world:

1. **The world table** `b2_worlds[128]` (`src/world.c`), scanned by `b2CreateWorld` without a lock. `LabKitRigid` serialises world creation and destruction behind one `Mutex` (`RigidUnits`).
2. **`b2_lengthUnitsPerMeter`** (`src/core.c`), which scales every tolerance in `src/constants.h` and the defaults in `src/types.c`. Changing it while worlds exist changes their behaviour mid-flight.
3. **The assert hook and the allocator.** LabKit leaves both at their defaults.

A world is locked during `b2World_Step`; never call back into it from a callback. `LabKitRigid` uses no callbacks during a step (`workerCount = 1`, no task system, no pre-solve) and reads events after the step. `RigidWorld` is not `Sendable`: one isolation domain (the main actor in Rheo) owns it.

**Tests:** all Box2D tests live in one XCTestCase (`Tests/LabKitRigidTests`) and the package runs `swift test --no-parallel`. Parallel suites that toggled the global units were flaky (3 failures in 5 runs, `oss-integration-lessons.md` §3.5).

## Tolerances and units

LabKit calls `b2SetLengthUnitsPerMeter(0.1)` once per process, before the first world (first caller wins; later requests for another value are ignored and reported by `RigidWorld.lengthUnitsPerMetre`). Positions stay in metres; the call only rescales the tolerances, which upstream tunes for 0.1–10 m bodies:

| Tolerance | Default (1.0) | LabKit (0.1) |
|---|---|---|
| Linear slop | 5 mm | 0.5 mm |
| Speculative distance (4 × slop) | 20 mm | 2 mm |
| Restitution threshold | 1 m/s | 0.1 m/s |
| Hit-event threshold | 1 m/s | 0.1 m/s |
| Body sleep threshold | 5 cm/s | 5 mm/s |
| Maximum contact push speed | 3 m/s | 0.3 m/s |
| Maximum linear speed | 400 m/s | 40 m/s |

With the defaults a 4 mm bead dropped 26 mm does not bounce and a bead sinking at ~3 cm/s falls asleep mid-fluid; at 0.1 it bounces to e²h (measured 16.53 mm against 16.64 mm) and a fluid-coupled body with `enableSleep = false` never freezes.

## Upstream quirks the wrapper compensates for

Measured by `LabKitRigidTests` (3 October 2026):

- `b2MakeRot` uses Bhaskara's cosine approximation (about 1.6 mrad error on a kinematic paddle). `LabKitRigid` builds rotations from exact `cos`/`sin`.
- `b2Body_SetTargetTransform` returns without writing the velocity when the requested motion is below the body's sleep threshold, so a kinematic tool whose finger stops would keep drifting at its last speed. `LabKitRigid.setTarget` writes the velocities itself after the call.
- Body damping is applied to the carried velocity only (`v ← h·a + v/(1 + h·c)`), so the terminal speed under damping is a/c + a·h: it can never fall below g·h ≈ 20 mm/s at 480 substeps/s. Fluid drag must come from the MPM impulses, not from damping.
- `b2ComputeHull` drops vertices within 2 × slop (1 mm at 0.1) of their neighbours' chord. `RigidWorld.shape(_:)` reports the polygon Box2D actually built.
- Hit-event approach speeds are taken at the start of the step that resolves the contact, so they read within ± g·dt of the true impact speed (measured 0.654 m/s against √(2gh) = 0.626 m/s for a 2 cm drop at 120 Hz).

## Build and checks

```zsh
# from LabKit/ (never inside iCloud: Tools/lk.sh mirrors to $TMPDIR/labkit-<work-name>)
# TOOLCHAINS=metal because `swift test` builds every test target, including the Metal ones.
Tools/lk.sh <work-name> env TOOLCHAINS=metal swift test --no-parallel --filter LabKitRigidTests
Tools/lk.sh <work-name> xcodebuild -scheme LabKitRigid -destination 'generic/platform=iOS Simulator' -derivedDataPath ../dd build
Tools/lk.sh <work-name> xcodebuild -scheme LabKitRigid -destination 'generic/platform=iOS' -derivedDataPath ../dd build CODE_SIGNING_ALLOWED=NO
```

When sandboxed, point `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` at a writable directory (`lk.sh` does this).

## Upgrading

Box2D `main` is 3.2.0-dev (untagged as of 3 October 2026): it adds snapshots/replay and a scheduler, moves `world.c` to `physics_world.c`, and replaces the mouse joint with a mover joint. Every API that 3.2 changes is used only in `Sources/LabKitRigid/RigidWorld.swift` (mouse joint, overlap queries) and `Sources/LabKitRigid/RigidUnits.swift` (world definition, `b2CreateWorld`, which becomes a macro under double precision). To upgrade: copy the new tag's `src/*.c`, `src/*.h`, `include/box2d/*.h`, `LICENSE` (plus `src/CMakeLists.txt` for the source list), keep `include/module.modulemap`, update the `exclude:` list for any new non-source files, recompute both manifest hashes and the archive hash into `UPSTREAM.json`, update `THIRD_PARTY_NOTICES.md`, and re-run the checks above.
