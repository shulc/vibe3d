// mesh.setPosition `axis` + `value` reference parity (task 1052).
//
// The counts in expected_after are load-bearing, not decoration: the
// partial-ring case lands two vertices on the SAME point, and the vertex
// golden is matched bidirectionally by position — which cannot tell one
// vertex from two at that point. Only the count says "the reference did not
// weld, and neither did we".

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/set_position_axis.json");
    runTopologyDiffSuite(json);
}
