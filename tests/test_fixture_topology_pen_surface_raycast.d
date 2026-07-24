// Topology Pen P0/P2 (doc/topopen_p0_plan.md, doc/topopen_p2_plan.md) —
// golden-fixture Tier B: the CONS stage's background-surface constraint,
// probed end-to-end through GET /api/surface-raycast (no GL, no active
// tool — pure pipeline-evaluate + BvhPick / constraint.closestPointOnMeshes).
// See tests/fixtures/topo_pen_surface_raycast.json for the 14 cases (11
// Screen-mode camera-ray cases from P0, relabeled from their original
// `geometry point` argstring once P2 fixed Point mode to mean nearest-foot
// instead of always-camera-ray; 3 new Point-mode nearest-foot cases) and
// the fixture's provenance/authoring notes (the camera "focus-point trick"
// that lets every expected hit point be nailed exactly, modulo a small
// sub-pixel-sampling tolerance).
//
// Run via: ./run_test.d topology_pen_surface_raycast

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/topo_pen_surface_raycast.json");
    runSurfaceRaycastSuite(json);
}
