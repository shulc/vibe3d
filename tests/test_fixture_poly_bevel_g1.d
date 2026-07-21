// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — GROUP
// shared-corner accumulator, half-shared branch (internalCnt==1), on
// deliberately asymmetric (non-90°, unequal-edge-length) geometry — task
// 0458 Phase 1. See tests/fixtures/poly_bevel_G1_halfshared_tent.json for
// the full derivation note: this is the discriminating oracle that a
// naive-normal-sum accumulator FAILS (bit-exact only on axis-aligned cube
// corners like poly_bevel_corner.json's sibling case), while the
// reference-recovered AVE_N=k·N/|N|² law passes it exactly.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_G1_halfshared_tent.json");
    runTopologyDiffSuite(json);
}
