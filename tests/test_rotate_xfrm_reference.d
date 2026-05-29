// MS-7 of doc/rotate_single_source_plan.md — cross-engine pin for the unified
// xfrm.transform rotate apply (`applyTRS`).
//
// The frozen reference golden (a REAL rotate-ring handle capture, recovered by
// Kabsch) already lives in tests/fixtures/rotate_drag.json, but that suite
// replays it via the `rotate_about` /api/transform primitive — which is NOT the
// path this refactor touched, so it gives zero coverage of the new
// gesture→applyTRS code (round-3 S4).
//
// This test closes S4: it reuses the SAME reference after-positions (top face,
// +Y axis, 60°) but applies them through the xfrm.transform Euler path
// (`tool.set rotate` / `tool.attr rotate RY` / `tool.doApply` → `applyTRS`).
// So it validates `applyTRS == reference engine` for a clean basis-axis case.
// Combined with test_rotate_drag_parity (drag == numeric == applyTRS), this
// gives drag == reference transitively, without needing pixel-perfect drag
// tuning to hit the reference angle.
//
// Why only the Y-axis case is reproducible this way: a rotation about +Y is
// invariant to the pivot's Y component, so ACEN.Auto (the top-face centroid
// 0,0.5,0 used by the `rotate` step) yields the same geometry as the captured
// origin pivot. The captured X/Z/arbitrary-axis cases would need a forced
// pivot and are left to the rotate_about suite.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/rotate_xfrm_reference.json");
    runParityFixture(json);
}
