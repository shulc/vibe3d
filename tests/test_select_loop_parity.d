// select.loop (edge) reference parity (task 0457). 12 frozen capture cases
// exercising the recovered algorithm: the regular quad edge-strip walk
// (rules 1/2/3/8, already correct via Mesh.walkEdgeLoop) plus the extra
// branches recovered from the reference — an n-gon or a valence-odd (no
// floor — even a plain valence-3 cube corner qualifies) pivot immediately
// across the seed (both directions dead-end, fall back to the seed's own
// largest-vertex-count incident face), a triangle immediately across the
// seed (succeeds exactly one hop further, no fallback), and a seed edge
// that is itself on an open boundary (chains the whole boundary loop). The
// 12th case (`cube_corner_edge0`) is a plain closed/watertight cube — the
// first watertight mesh in the toolcard — added specifically to settle
// Gate 1's valence-3 behavior, which the other 11 (all open/boundary
// meshes) could not pin. See toolcards/select.loop/findings.md (private)
// for the full algorithm and per-rule provenance, and
// doc/select_loop_parity_plan.md for scope. Golden `expected_edges` is each
// case's frozen `postLoop.selectedEdges` verbatim — never vibe3d's own
// output.
//
// tests/test_select_topology.d's cube edge-0 `select.loop` unittest uses
// the SAME seed as `cube_corner_edge0` and now asserts the same
// reference-validated 4-edge result — the two are consistent (kept as
// separate suites, not merged).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/select_loop_parity.json");
    runSelectLoopSuite(json);
}
