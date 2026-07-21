// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — SQUARE
// CORNER + SEGMENTS, task 0458 Phase 3, finding Q3. See
// tests/fixtures/poly_bevel_Q3_square_segs2.json for the full derivation
// note: pins that square is NOT rejected when combined with segments — it
// wraps only the OUTERMOST ring (original boundary → the first segment
// ring), at that ring's own inset (inset/segs); deeper segment rings stay
// plain, unmodified quads.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_Q3_square_segs2.json");
    runTopologyDiffSuite(json);
}
