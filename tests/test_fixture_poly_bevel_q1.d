// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — SQUARE
// CORNER, task 0458 Phase 3, finding Q1 (single face, no group). See
// tests/fixtures/poly_bevel_Q1_single_square.json for the full derivation
// note: pins the Square-Corner topology rewrite (retained original corner +
// 2 splits + quad cap per boundary-contour corner, edge-panel quads,
// unselected side faces absorbing splits into hexagons) on a single
// standalone face with no group interaction.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_Q1_single_square.json");
    runTopologyDiffSuite(json);
}
