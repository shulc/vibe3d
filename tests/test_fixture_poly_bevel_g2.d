// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — GROUP
// shared-corner accumulator, fully-enclosed-apex branch (internalCnt>=2 &&
// !anyBoundary), on asymmetric non-planar/non-orthogonal geometry — task
// 0458 Phase 1. See tests/fixtures/poly_bevel_G2_apex_v3.json for the full
// derivation note: pins the apex vertex bit-exact (orig + shift·AVE_N) and
// the topology (13v/9f); the same dump's ring vertices carry a known,
// documented residual not asserted here (see bevelFacesByMask's doc
// comment in source/mesh.d).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_G2_apex_v3.json");
    runTopologyDiffSuite(json);
}
