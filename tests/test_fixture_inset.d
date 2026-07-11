// Golden parity fixture for Polygon Inset (mesh.polyInsetTool, task 0359
// promotion of the one-shot mesh.poly_inset command). Verifier: topology-diff
// (vert/face count deltas + per-vertex bidirectional nearest-match against a
// frozen golden). The primary case (single_face_pos02) is a bit-exact frozen
// reference capture (see tests/fixtures/inset.json "source" for provenance);
// the default (inset=0, split-not-skipped) and negative (sign-law, grows
// outward) cases replay the SAME reference-confirmed per-vertex law
// analytically. No external reference engine at test time.
//
// Drives the INTERACTIVE tool headlessly (tool.set mesh.polyInsetTool on;
// tool.attr inset <v>; tool.doApply) via fixture_helpers' "poly_inset" step
// — this is the tool task 0359 promotes mesh.poly_inset into, so the fixture
// exercises the new PolyInsetTool.applyHeadless() path, not the one-shot
// command directly. tests/test_poly_inset.d keeps covering the underlying
// one-shot mesh.poly_inset command (same shared kernel, mesh.insetFacesByMask).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/inset.json");
    runTopologyDiffSuite(json);
}
