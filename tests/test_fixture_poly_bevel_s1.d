// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — GROUP x
// SEGMENTS interaction, task 0458 Phase 1 (+S1). See
// tests/fixtures/poly_bevel_S1_group_segs2.json for the full derivation
// note: pins both the segment ring-lerp law across a group-shared corner
// AND the vertex-count/topology fix (the shared corner's intermediate ring
// vertex is now shared across both faces, not duplicated per face).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_S1_group_segs2.json");
    runTopologyDiffSuite(json);
}
