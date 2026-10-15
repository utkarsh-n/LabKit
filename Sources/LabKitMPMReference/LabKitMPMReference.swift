// LabKitMPMReference: the CPU physics oracle of LabKit's continuum engine. Owned by WP-O.
//
// - `EVP` / `EVPState` (EVP.swift): the unified elasto-viscoplastic single-particle update in Double
//   (rheology-models.md §4 and Appendix B). The GPU solver (LabKitMPM) runs the same update in float32 and must
//   match it (V14).
// - `ReferenceSolver2D` / `ReferenceScene` (ReferenceSolver2D.swift): explicit 2D MLS-MPM, quadratic B-splines,
//   2×2 particles per cell, SI units, sticky/slip/moving walls, body forces a(x, t), Hele-Shaw drag, kinematic boxes.
// - `ReferenceLaws` (ReferenceLaws.swift): closed-form laws and solutions used by the verification suite V1–V12.
//
// Materials come from `ContinuumMaterial` / `ContinuumPresets` in LabKitCore. Verification: labkit-physcheck mpm.
