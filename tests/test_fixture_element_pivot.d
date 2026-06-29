// Regression guard for element-falloff geometry parity: element falloff
// attenuates by distance to the picked element's geometric centre
// (edge midpoint / face centroid). Four cases (edge / edge-center /
// polygon / edge-loops) on a 4x4x4 seg cube, all from frozen captures.
// AnchorRing verts move at weight=1; surrounding verts attenuate by
// distance to the element geometry (segment / face plane / loop polyline).
// The genuine pivot-fix discriminators are the HTTP pick tests
// (test_element_pick_edge_clickpoint.d / _face_clickpoint.d), which
// verify that actionCenter.center tracks the picked element, not the
// cursor position.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/element_pivot.json");
    runParitySuite(json);
}
