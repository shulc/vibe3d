// Topology Pen P1 (doc/topopen_p1_plan.md) — golden-fixture Tier B: the
// constraint layer's `resolveHoverTarget` (source/constraint.d), probed
// end-to-end through GET /api/surface-raycast's `targetKind`/`targetVert`/
// `targetEdge` fields (no GL, no active tool — pure pipeline-evaluate +
// BvhPick + resolveHoverTarget). See
// tests/fixtures/topo_pen_hover_target.json for the 10 cases and the
// fixture's provenance/authoring notes (including the REV-C independently
// hand-derived pixel distances backing the threshold-flip cases). P2
// (doc/topopen_p2_plan.md): all 10 cases relabeled `geometry point` ->
// `geometry screen` — they drive a real camera-ray hit (same "focus-point
// trick" as topo_pen_surface_raycast.json), which P2's mode fix now means
// Screen, not Point (nearest-foot-from-work-plane-seed); values unchanged.
//
// Run via: ./run_test.d topology_pen_hover_target

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/topo_pen_hover_target.json");
    runHoverTargetSuite(json);
}
