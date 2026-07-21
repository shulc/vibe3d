// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — SQUARE
// CORNER + GROUP, task 0458 Phase 3, finding Q4 (2-face group, a full
// topology rewrite). See tests/fixtures/poly_bevel_Q4_grouped_square.json
// for the full derivation note: pins that a group-shared "ridge" corner
// (the shared edge's own two endpoints) gets NEITHER a split NOR a cap —
// it stays at its original position, connected directly into the two
// edge-panels meeting there — while the 4 standalone corners (touching
// only one of the two selected faces) get the ordinary Q1-style
// split+cap treatment. Re-verified bit-exact against the pre-existing
// dump poly_bevel_two_faces_grouped_square1.json.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_Q4_grouped_square.json");
    runTopologyDiffSuite(json);
}
