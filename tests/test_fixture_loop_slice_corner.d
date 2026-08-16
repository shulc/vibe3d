// Loop Slice `Slice Selected` over an L-SHAPED selection — a corner turn.
//
// PARITY as of task 1054 Phase 3 (the selection-band walk, doc/
// loop_slice_corner_plan.md): the cut turns at the corner cell, entering
// through one edge and leaving through a PERPENDICULAR one, matching the
// reference exactly (38 verts / 71 edges / 35 faces, including the corner
// TRIANGLE the turn produces). Until task 1054 this was a KNOWN DIVERGENCE
// (task 1053, risk R1 of the dogfood audit): the old kernel clipped both
// rings to the selection independently, so they crossed inside the corner
// cell and emitted three extra vertices the reference does not.
//
// Why it exists at all: the only Slice Selected fixture we had before task
// 1053 (test_fixture_loop_slice_slice_selected.d) selects two ADJACENT
// faces — a straight run — so it cannot see corner behaviour, and chapter 5
// cuts around corners repeatedly (the groin band, the palm, the shirt's
// neckline). This exact case (corpus case `L`) is also reproduced inside
// the 47-case parity fixture `loop_slice_band.json`
// (test_fixture_loop_slice_band.d) — this file is kept anyway as the task's
// own named deliverable and its provenance block records the original 1053
// capture.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_corner.json");
    runTopologyDiffSuite(json);
}
