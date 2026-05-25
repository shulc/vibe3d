// Reference-parity: translate a connected face patch on a Catmull-Clark
// subdivided cube. The patch (4 sub-faces of the +Y face) shares an interior
// vertex (the face center) with the other 8 verts on the selection border —
// connected-patch coverage on SDS geometry, groundwork for future
// selection-border tests.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/move_sds_patch.json");
    runParitySuite(json);
}
