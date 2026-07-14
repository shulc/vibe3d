// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — 3-face
// corner junction with the shared-corner GROUP accumulator (task 0391
// Phase 4). See tests/fixtures/poly_bevel_corner.json for the full
// derivation note (a genuine contrast with edge_bevel_corner.json's
// triangle+3-quad edge-junction cap: poly's shared corner collapses to
// ONE apex + 3 bridging quads, no extra fill polygon).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_corner.json");
    runTopologyDiffSuite(json);
}
