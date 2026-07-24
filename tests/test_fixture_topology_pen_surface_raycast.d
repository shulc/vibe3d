// Topology Pen — golden-fixture Tier B: the CONS stage's background-surface
// constraint, probed end-to-end through GET /api/surface-raycast (no GL, no
// active tool — pure pipeline-evaluate + BvhPick / constraint.
// closestPointOnMeshes). See tests/fixtures/topo_pen_surface_raycast.json
// for the 14 cases (11 Screen-mode camera-ray cases from P0; 3
// `geometry point` cases proving Point mode's placement — now the SAME
// camera-ray hit, per a live cross-engine differential against the reference editor,
// superseding P2's brief work-plane-cursor nearest-foot derivation — agrees
// with Screen mode for an identical camera) and the fixture's
// provenance/authoring notes (the camera "focus-point trick" that lets
// every expected hit point be nailed exactly, modulo a small
// sub-pixel-sampling tolerance).
//
// Run via: ./run_test.d topology_pen_surface_raycast

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/topo_pen_surface_raycast.json");
    runSurfaceRaycastSuite(json);
}
