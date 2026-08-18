// Vertex-split parity, GEOMETRY CHANNEL ONLY, frozen from the reference
// (task 1160).
//
// The capture recorded matching geometry and a DIFFERENT post-operation
// selection in every one of the twelve cells it ran. That selection difference
// is a recorded divergence in its own right, so this fixture freezes the
// geometry and says so -- it does not carry an `expected_selection`, and
// widening it to one would be asserting a match nobody measured.
//
// Counts are the whole assertion for several cases: splitting a vertex leaves
// its copies at the SAME position, so the frozen position set is identical
// before and after and only the vertex/edge counts (plus the re-wired face
// rings) can tell one vertex from six.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/vertex_split_geometry_parity.json"));
}
