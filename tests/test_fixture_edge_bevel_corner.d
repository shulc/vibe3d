// Edge Bevel golden parity — 3-way junction (all 3 edges at one cube corner
// selected together): the K==3 N-way junction hub-fill case, PLUS 3
// independent bare-end pentagons at the far endpoints in the SAME case.
// Task 0391 Phase 2 (highest-risk phase) target — see
// tests/fixtures/edge_bevel_corner.json for the full derivation note.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/edge_bevel_corner.json");
    runTopologyDiffSuite(json);
}
