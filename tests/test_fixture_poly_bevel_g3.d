// Polygon Bevel (mesh.bevel, edit-mode Polygons) golden parity — GROUP
// shared-corner accumulator, PARTIAL branch (internalCnt>=2 &&
// anyBoundary) — task 0458 Phase 1 (+ follow-up). See
// tests/fixtures/poly_bevel_G3_partial_fan.json for the full derivation
// note: pins the TOPOLOGY fix (the reference shares one vertex; the
// pre-0458 kernel split it into 3 separate per-face vertices) via
// vertex/face counts (17v/12f), AND the bit-exact positions of the shared
// apex P plus its two internalCnt==1 ring vertices via the recovered
// `bevGenInset` mitered-corner offset (findings.md §1/§5). The remaining
// standalone (single-face) vertices carry a separate, out-of-scope
// residual not asserted here.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_bevel_G3_partial_fan.json");
    runTopologyDiffSuite(json);
}
