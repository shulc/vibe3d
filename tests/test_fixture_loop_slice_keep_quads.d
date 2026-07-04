// Loop Slice "Keep Quads" option (task 0249). The quad ring only ever splits
// quads (every new sub-face is a quad regardless), so the toggle's realized
// effect is the TERMINATION at a non-quad face: OFF (default, whole-ring
// behaviour byte-for-byte) leaves the non-quad uncut (a T-junction on the
// terminating rail); ON makes the non-quad neighbour ABSORB the terminating
// midpoint (n-gon), so the cut stays watertight AND all-quad. Analytic
// self-golden on a custom mesh (two quads capped by a triangle): identical
// vertex set both ways; the edge count (15 OFF vs 14 ON) is the countable
// proof the non-quad absorbed the midpoint. Composes with `select` (both use
// the same absorb pass).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_keep_quads.json");
    runTopologyDiffSuite(json);
}
