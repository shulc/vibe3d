// Slice tool "Gap" DIRECTION on a SHEARED cube (mesh.sliceTool, task 0290). On an
// axis-aligned cube the crossed edges are parallel to the cut-plane normal, so the
// pre-0290 normal-direction gap and the corrected along-edge gap coincide (the
// slice_gap golden stays byte-for-byte). This golden exercises the case where they
// DIVERGE: a sheared cube whose top face is displaced +X, so the plane-crossed edges
// are OBLIQUE to the normal. Gap must separate each [lo,hi] seam pair ALONG THE
// ORIGINAL CROSSED EDGE, keeping both halves of every split edge COLLINEAR with the
// original edge (the reference behavior — the split edge does not bend). The frozen
// post-op vertices pin the exact along-edge geometry; the collinearity + exact
// along-edge separation proof lives in the source/mesh.d cutByPlaneEx unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_gap_sheared.json");
    runTopologyDiffSuite(json);
}
