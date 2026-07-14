// Edge Bevel (mesh.bevel, edit-mode Edges) golden parity — single isolated
// interior edge (both endpoints bare) on a unit cube. Baseline regression
// lock for task 0391 (see tests/fixtures/edge_bevel_single.json for the
// full derivation note); this is the case vibe3d's bevelEdgesByMask already
// reproduced pre-0391, kept here as the anchor fixture for the harder cap
// cases in test_fixture_edge_bevel_{loop,corner,open_end}.d.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/edge_bevel_single.json");
    runTopologyDiffSuite(json);
}
