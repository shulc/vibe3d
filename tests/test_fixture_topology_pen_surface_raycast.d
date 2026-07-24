// Topology Pen P0 (doc/topopen_p0_plan.md) — golden-fixture Tier B: the
// CONS stage's background-surface raycast branch, probed end-to-end
// through GET /api/surface-raycast (no GL, no active tool — pure
// pipeline-evaluate + BvhPick). See tests/fixtures/topo_pen_surface_raycast.json
// for the 10 cases and the fixture's provenance/authoring notes (the
// camera "focus-point trick" that lets every expected hit point be nailed
// exactly, modulo a small sub-pixel-sampling tolerance).
//
// Run via: ./run_test.d topology_pen_surface_raycast

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/topo_pen_surface_raycast.json");
    runSurfaceRaycastSuite(json);
}
