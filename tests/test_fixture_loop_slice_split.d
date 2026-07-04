// Loop Slice "Split" option (task 0251). By default the inserted loop is a
// single connected edge loop and the cut stays watertight (the rail midpoints
// are shared between the two sides). When ON, each rail midpoint is DUPLICATED
// into two coincident verts, so the single connected loop becomes TWO distinct
// boundary edge-loops and the two sides of the cut are topologically
// disconnected along it. Analytic self-golden on a unit cube, seed = a vertical
// edge, ring = a horizontal belt of 4 side quads (4 rails): OFF 12 verts / 20
// edges / 10 faces (one closed shell); ON 16 verts / 24 edges / 10 faces (the 4
// midpoints doubled → verts 12-15 coincide with 8-11, the 4 interior loop edges
// become 8 boundary edges → two disconnected cap shells). Faces stay 10 because
// splitting duplicates verts, not faces. Foundation for Cap Sections (0252) +
// Gap (0253). The stronger topological proof (boundary-edge count, component
// count, seam pairs) lives in the source/mesh.d kernel unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_split.json");
    runTopologyDiffSuite(json);
}
