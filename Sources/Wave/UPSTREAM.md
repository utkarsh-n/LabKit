# Wave (vendored)

Janum Trivedi's spring-based animation engine for iOS and macOS: fluid, interruptible, velocity-preserving springs
(`Spring`, `SpringAnimator<T>`, `Wave.animate(withSpring:)`, animatable UIView/CALayer properties).
Upstream: https://github.com/jtrivedi/Wave, tag **0.3.4**, commit `72f4688be3cfd3b56fcc76f51bf2a59dfece017e`, MIT licence
(`LICENSE.md`, copied verbatim). Source files and tests are vendored unmodified; see `UPSTREAM.json` for the manifest hash.

LabKit builds it as the `Wave` product in Swift 5 language mode, because upstream predates Swift 6 strict concurrency.
Use it for interface motion (the lens following a finger, crowns with inertia, chamber parallax, panel and sheet
transitions). It animates interface values; it does not change the fluid physics, which stays in LabKitMPM.

Build note: upstream calls `UIScreen.main`, deprecated in iOS 26 (2 warnings). The source stays verbatim and the `Wave`
target alone is compiled with `-suppress-warnings` (`Package.swift`). If Wave is ever patched, replace those calls with
the view's `window.windowScene.screen` and drop the flag.
