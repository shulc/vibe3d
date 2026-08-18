// Face-split parity, frozen from the reference (task 1160).
//
// Until this landed, `mesh.splitFace` had no reference-captured oracle at all
// -- every expectation about it in this suite was hand-written. Both fixtures
// here are measured AGREEMENTS from the 1121/1123 sweeps: the reference and
// vibe3d were handed byte-identical geometry, the same selection resolved by
// COORDINATE on each side, and answered the same.
//
// What makes the cases worth their bytes is that none of them is a cube. A
// closed solid cannot ask which of two faces containing both endpoints gets
// cut, cannot carry a chord that leaves a non-convex ring, and cannot put a
// reflex corner at ring index 0 rather than index 3 -- and that last pair is
// the control that separates a ring-start-dependent law from one that is not.
//
// The cells where BOTH engines DECLINE to split live in
// test_fixture_shared_refusals.d, deliberately apart: a refusal frozen here
// would still pass with the command deleted.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/poly_split_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/poly_split_dirty_parity.json"));
}
