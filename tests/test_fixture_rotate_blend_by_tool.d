// The cells that SEPARATE the rotation-blend law from its rival (task 2990).
//
// The law (doc/measured_laws.md §4): rotation under a falloff has two blends
// and the TOOL selects between them. The soft-rotate preset family scales the
// ANGLE by the per-vertex weight — R(w·θ), every radius preserved — while the
// unified transform lerps the MATRIX toward identity, (1-w)I + w·R, which
// shrinks radii to a minimum of cos(θ/2).
//
// The rival: the blend is selected by AXIS COUNT — single-axis rotations arc,
// multi-axis ones lerp.
//
// Why this fixture exists. Every rotate cell frozen before it is green under
// BOTH readings: softrotate / swirl / twist / vortex are single-axis AND arc,
// falloff_rot_multi / falloff_trs_multi are multi-axis AND lerp. That is
// exactly the rival's partition, so the corpus could not tell the two apart —
// audit 2980 rewrote the fold-mode selection to the rival and the whole
// rotation set still passed, 8 of 8.
//
// Every case here is SINGLE-axis and yet takes the MATRIX-LERP arm, which the
// rival cannot produce. Minimum radius ratio r₁/r₀ about the rotation axis,
// in exact terms — the minimum is cos(θ/2), attained at the vertices whose
// weight is exactly ½ (a seg-4 cube's face centres sit at distance 0.5 from a
// unit-size falloff centre):
//
//     rot_xform_single_30   unified, RY  30   →  cos 15°  = 0.965926
//     rot_xform_single_90   unified, RY  90   →  cos 45°  = 0.707107
//     edge_xform_180        unified, RY 180   →  0          (collapses)
//
// The arc twin is softrotate.json's `rot_lin_90`: the same 90° rotation under
// the same radial linear falloff on the same seg-4 cube, through the
// soft-rotate preset instead, preserving every radius (ratio exactly 1). Same
// axis count, opposite arm, only the tool differs — that pair is the
// separation. It is referenced rather than copied so one measurement keeps
// one home.
//
// The losing model misses the frozen positions here by 1.8e-2 (RY 30) up to
// 5.1e-1 (RY 180) against this suite's 1e-4 tolerance, so a wrong fold-mode
// choice cannot squeak through on tolerance.
//
// Replayed via falloff_transform against a live vibe3d; no external engine at
// runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/rotate_blend_by_tool.json");
    runParitySuite(json);
}
