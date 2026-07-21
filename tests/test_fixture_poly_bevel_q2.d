// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — SQUARE
// CORNER, task 0458 Phase 3, finding Q2 (two NON-adjacent faces). See
// tests/fixtures/poly_bevel_Q2_nonadjacent_square.json for the full
// derivation note: pins Square Corner as a pure per-face op — group=true
// is inert when the selected faces share no edge, so the result is two
// independent Q1 patterns, and the 4 cube side faces (each bordering both
// squared faces) become octagons.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_Q2_nonadjacent_square.json");
    runTopologyDiffSuite(json);
}
