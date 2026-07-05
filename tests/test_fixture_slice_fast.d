// Slice tool (mesh.sliceTool, task 0267 S1) `fast` preview-gate parity golden.
// Drives the SAME mid-plane cube cut through the HTTP command path twice — once
// with fast=false (live preview during the drag) and once with fast=true (cut
// deferred to mouse-up) — and asserts both commit the identical 12v/10f
// geometry. Verifies the S1 `fast` flag is a pure preview gate that never
// perturbs the committed result. Analytic self-golden (no external engine).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_fast.json");
    runTopologyDiffSuite(json);
}
