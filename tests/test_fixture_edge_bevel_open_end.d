// Edge Bevel (mesh.bevel, edit-mode Edges) golden parity — a BOUNDARY edge
// of an OPEN mesh (the open-mesh rim end-cap case). Both endpoints of the
// selected edge are single-incident-face corners, so the reference bevels
// it WITHOUT a bridge quad and splits the two endpoints ASYMMETRICALLY: the
// endpoint that comes SECOND in the bordering face's own winding-order
// traversal of the edge gains 2 new vertices, the other only 1 (net +1
// vertex, vs. +2 for a closed isolated edge). See
// tests/fixtures/edge_bevel_open_end.json for the full derivation note.
//
// vibe3d had no boundary-edge bevel path (its per-vertex fan pass declines a
// vertex with fewer than two incident faces), so this fixture establishes the
// brand-new target geometry — including the 1-vs-2 asymmetry — that the
// single-incident-face rim-corner slide in bevelEdgesByMask reproduces.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/edge_bevel_open_end.json");
    runTopologyDiffSuite(json);
}
