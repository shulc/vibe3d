// Slice tool "Split" option (mesh.sliceTool, task 0273 S7). By default the
// plane cut is a single connected loop and the cut stays watertight (the
// crossing verts are shared between the two sides). When ON, each crossing
// vert is DUPLICATED into two coincident verts, so the single connected cut
// loop becomes TWO distinct boundary edge-loops and the two sides of the cut
// are topologically disconnected along it — reusing the Loop Slice lo/hi
// seam-pair split machinery (Mesh.cutByPlaneEx -> splitAlongCutLoop) fed the
// plane-cut loop instead of an edge-ring loop. Analytic self-golden on a cube,
// line along Z through the origin (plane normal ||X, X=0, == S0 slice.json
// midX): OFF 12 verts / 20 edges / 10 faces (one closed shell); ON 16 verts /
// 24 edges / 10 faces (the 4 crossing verts doubled -> verts 12-15 coincide
// with 8-11, the 4 interior loop edges become 8 boundary edges -> two
// disconnected sections). Faces stay 10 because splitting duplicates verts, not
// faces. The stronger topological proof (boundary-edge count, component count,
// coincident seam pairs) lives in the source/mesh.d cutByPlaneEx kernel unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_split.json");
    runTopologyDiffSuite(json);
}
