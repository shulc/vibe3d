// Task 1054 Phase 3 -- Loop Slice "Slice Selected" as a BAND WALK, PARITY
// subset (F1, doc/loop_slice_corner_plan.md §5 Phase 3 / §6). 47 of the
// 54-case reference corpus (base = a 3x1x3 segmented unit box): chains over
// the selected polygons in SELECTION order, a per-polygon entry/exit side
// pair, one cut per polygon in its own ring frame -- turning at a corner
// cell instead of two clipped rings crossing there. The other 7 corpus cases
// are the reference's own non-manifold neighbour-frame anomaly, deliberately
// NOT reproduced -- see test_fixture_loop_slice_band_divergence.d.
//
// Every expected number (V/E/F, full post-op vertex set, face-degree
// multiset) is reference-sourced, generated from the corpus + raw dumps by
// tools/local/fixture_gen/loop_slice_band/gen_band_fixtures.py -- never read
// off vibe3d's own output.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_band.json");
    runTopologyDiffSuite(json);
}
