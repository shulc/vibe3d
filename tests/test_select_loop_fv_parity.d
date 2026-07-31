// select.loop (polygon/vertex modes) reference parity (task 0390). 26 frozen
// capture cases — the face/vertex counterpart of test_select_loop_parity.d
// (edge, task 0457): regular strips/rings, boundary expansions (seed on an
// open boundary chains the whole boundary loop), n-gon/triangle encounters,
// pole valences, and degenerate single seeds (a single vertex clears the
// selection; a single polygon expands to a reference-chosen strip). Golden
// `expected` is each case's frozen postLoop.selected verbatim — never
// vibe3d's own output. See toolcards/select.loop/ (private) for captures and
// findings.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/select_loop_fv_parity.json");
    runSelectLoopFvSuite(json);
}
