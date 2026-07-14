// Edge Bevel golden parity — closed 4-edge loop (a cube face's own
// perimeter): every corner is a K==2 "loop turn" (2 selected edges meeting
// at a vertex, no bare ends, no N-way junction). Task 0391 Phase 1 target —
// see tests/fixtures/edge_bevel_loop.json for the full derivation note.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/edge_bevel_loop.json");
    runTopologyDiffSuite(json);
}
