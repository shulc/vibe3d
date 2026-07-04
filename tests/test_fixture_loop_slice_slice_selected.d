// Loop Slice "Slice Selected" option (task 0248): when ON, the cut is
// restricted to the selected face region instead of the whole ring around the
// mesh, terminating watertight at the selection border (unselected boundary
// neighbours absorb the terminating midpoints as n-gons). When OFF (default)
// the whole ring is cut, byte-for-byte as before. Analytic self-golden on the
// default cube — two adjacent selected faces, restricted vs whole-ring.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_slice_selected.json");
    runTopologyDiffSuite(json);
}
