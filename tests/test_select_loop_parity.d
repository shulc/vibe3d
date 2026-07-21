// select.loop (edge) reference parity (task 0457). 11 frozen capture cases
// exercising the recovered algorithm: the regular quad edge-strip walk
// (rules 1/2/3/8, already correct via Mesh.walkEdgeLoop) plus four extra
// branches recovered from the reference — an n-gon or a valence pole
// immediately across the seed (both directions dead-end, fall back to the
// seed's own largest-vertex-count incident face), a triangle immediately
// across the seed (succeeds exactly one hop further, no fallback), and a
// seed edge that is itself on an open boundary (chains the whole boundary
// loop). See toolcards/select.loop/findings.md (private) for the full
// algorithm and per-rule provenance, and doc/select_loop_parity_plan.md for
// scope. Golden `expected_edges` is each case's frozen `postLoop.selectedEdges`
// verbatim — never vibe3d's own output.
//
// This is a SEPARATE suite from tests/test_select_topology.d's cube edge-0
// `select.loop` unittest (~line 153-211), which stays byte-identical (the
// 7-edge union — rules 1/2/3/8 on a plain cube).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/select_loop_parity.json");
    runSelectLoopSuite(json);
}
