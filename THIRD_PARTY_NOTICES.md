# Third-party notices

LabKit includes the software below. Each section gives the copyright, where the code came from, how LabKit uses it and the full licence text. Source notices and licence files also remain next to the vendored or ported code. Apps that link LabKit must bundle this file (for example as a `buildPhase: resources` source in `project.yml`) and credit each entry in their info sheet.

## Box2D 3.1.1

Copyright (c) 2022 Erin Catto. MIT License. The unmodified upstream C sources are compiled into LabKit's `CBox2D` target and reached only through the `LabKitRigid` Swift wrapper. LabKit adds only a Clang module map; no upstream file is changed.

- Repository: https://github.com/erincatto/box2d
- Release: `v3.1.1` (lightweight tag, no tag object) · commit `8c661469c9507d3ad6fbd2fea3f1aa71669c2fe3`
- Source archive SHA-256: `fb6ef914b50f4312d7d921a600eabc12318bb3c55a0b8c0b90608fa4488ef2e4`
- `LICENSE` SHA-256: `68a3e676d7e94093b102d5cba0d4e04af812040d6f230c3db67a6664574e43d2`
- Source and notices: [vendored tree](Sources/CBox2D/), [LICENSE](Sources/CBox2D/LICENSE), [provenance](Sources/CBox2D/UPSTREAM.md), [machine-readable provenance](Sources/CBox2D/UPSTREAM.json)

```text
MIT License

Copyright (c) 2022 Erin Catto

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## PB-MPM (Position Based MPM), Electronic Arts SEED

Copyright (c) 2024 Electronic Arts Inc. BSD 3-Clause License. LabKit's GPU continuum solver is a Metal port of PB-MPM's WGSL compute shaders (fused `g2p2g` with bukkit tiling, binning, grid update, emission and the particle/constant layouts), modified for LabKit: SI units, the unified elasto-viscoplastic material model as a compliant constraint, moving colliders with exact rigid-body impulse sums and a collider skin, merged binning with exact grid clearing, 2²⁴ round-to-nearest fixed point, periodic verification domains and Apple GPU threadgroup sizes. The derived files keep EA's notice in their headers: `Sources/LabKitMPM/Shaders/MPMSolver.metal` and `Sources/LabKitMPMTypes/include/MPMShared.h`. The fluid surface renderer (`MPMRender.metal`, `MPMRender.h`) and the Swift host are new code and not derived from PB-MPM. Credit EA SEED in the app's info sheet; the licence forbids using EA's name to endorse or promote LabKit or the apps (no "powered by EA").

- Repository: https://github.com/electronicarts/pbmpm
- Ported from: `main` commit `61749b6c2d2631ed243f86882752ba43196f2de7` (17 October 2024; fused `g2p2g`, bukkits), with pass semantics checked against `siggraph2024` commit `5a2f438b7115741c41ed429a2a0360d0e5f4b5a9`
- `LICENSE.md` SHA-256: `7bb46d23e3920a130d94a23a5a134a870ba6087b76802e91a9fd61ee673fd5f3`
- Licence copies: [Sources/LabKitMPM/Shaders/LICENSE-PBMPM.md](Sources/LabKitMPM/Shaders/LICENSE-PBMPM.md) (bundled with the shaders), [Sources/LabKitMPMTypes/LICENSE-PBMPM.md](Sources/LabKitMPMTypes/LICENSE-PBMPM.md)

```text
Copyright (c) 2024 Electronic Arts Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
following conditions are met:

1.  Redistributions of source code must retain the above copyright notice, this list of conditions and the following
    disclaimer.
2.  Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
    disclaimer in the documentation and/or other materials provided with the distribution.
3.  Neither the name of Electronic Arts, Inc. ("EA") nor the names of its contributors may be used to endorse or promote
    products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Colour maps: viridis, magma, inferno, plasma

By Nathaniel J. Smith and Stéfan van der Walt (viridis also by Eric Firing). Released under the CC0 1.0 public domain dedication; no licence obligations, credited here as a courtesy. `Sources/LabKitMPM/MPMColourMaps.swift` embeds 256 samples of each map, generated with matplotlib 3.10.9 (`matplotlib.colormaps[name](i / 255)`, rounded to 8-bit sRGB), for the fluid renderer's diagnostic views.

- Source: https://github.com/BIDS/colormap (CC0) and matplotlib's `_cm_listed.py`

## Wave 0.3.4

- Upstream: https://github.com/jtrivedi/Wave (tag 0.3.4, commit 72f4688be3cfd3b56fcc76f51bf2a59dfece017e)
- Location: `Sources/Wave`, `Tests/WaveTests` (verbatim)
- Licence: MIT

```
Copyright (c) 2022 Janum Trivedi

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

```
