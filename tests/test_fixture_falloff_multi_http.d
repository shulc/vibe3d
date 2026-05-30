// MS-4.3 production-fold parity: drive the MULTI-AXIS rotate-under-falloff
// reference fixtures through vibe3d's LIVE applyTRS path (HTTP rotate tool +
// falloff + doApply) and assert the output lands on the frozen reference
// `after`. This proves the production apply now COMPOSES the per-axis rotations
// into one matrix blended once per vertex (the MS-4.3 fold) — before the fold,
// the per-pass sequential blend diverged 0.02-0.03 from the reference
// (quantified in the pure-D tests/test_fixture_falloff_multi.d).
//
// Only the rotate fixture is driven here: its op is representable through
// vibe3d's RX/RY/RZ Euler attrs. The combined T+R+S fixture's captured scale is
// not axis-aligned (not expressible as SX/SY/SZ), so its fold correctness is
// pinned at the kernel level in test_fixture_falloff_multi.d instead.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/falloff_rot_multi.json");
    runParitySuite(json);
}
