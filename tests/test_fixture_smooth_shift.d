// Reference-parity: Smooth Shift + Thicken (mesh.smoothShiftTool, task 0358).
// A topology-CHANGING interactive tool (adds cap/skin verts+faces), so it is
// verified with the topology-diff suite (count deltas + bidirectional
// position match), not the rigid-cluster before/after-pair verifier. No
// reference engine runs at test time — the golden geometry in
// fixtures/smooth_shift.json was transcribed once from a frozen reference
// capture and cross-checked analytically (see the smoothShiftFacesByMask
// doc comment in source/mesh.d for the derived law).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/smooth_shift.json");
    runTopologyDiffSuite(json);
}
