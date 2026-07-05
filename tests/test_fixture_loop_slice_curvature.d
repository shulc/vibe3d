// Loop Slice "Preserve Curvature" option (task 0254). When OFF (default) each new
// loop vertex sits at the linear midpoint on the rail chord; when ON it is placed
// on a uniform Catmull-Rom spline through the rail's cage-neighbour continuation
// points, so a cut across a CURVED cage keeps the surface's rounded profile
// (bulges off the chord) instead of flattening. Analytic self-golden on a curved
// open strip (3 quads, column heights h=[0,1,1,0]), seed = the middle quad's top
// long edge: OFF places the two new verts on the flat chord (y=1.0); ON bulges
// them to y=1.125 (measurably off the chord, x/z unchanged). Topology is identical
// either way (10 verts / 13 edges / 4 faces) — curvature only relocates the new
// verts. The flat_cage case proves ON is a no-op on a locally-straight cage. The
// exact spline value + the byte-for-byte-linear-when-off invariant also live in
// the source/mesh.d kernel unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_curvature.json");
    runTopologyDiffSuite(json);
}
