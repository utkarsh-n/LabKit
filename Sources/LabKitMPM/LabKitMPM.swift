// LabKitMPM — LabKit's 2D continuum engine (owned by WP-G):
//   MPMSolver           PB-MPM fused g2p2g infrastructure (EA SEED, BSD-3, ported to Metal) running the unified EVP
//                       material model (rheology-models.md §4) as an XPBD compliant constraint; SI in, SI out.
//   MPMSurfaceRenderer  the 2.5D fluid look (splat + blur prepass, refraction/absorption/GGX shade, diagnostics).
// Shaders: Shaders/MPMSolver.metal (BSD-3 derivative, see LICENSE-PBMPM.md) and Shaders/MPMRender.metal (new code).
