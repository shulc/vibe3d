// MS-4 per-cluster fold parity: ACEN.Local move along each cluster's normal under
// a linear falloff, driven through vibe3d's LIVE applyTRS path (actr.local +
// falloff + move + doApply) and asserted against the frozen reference `after`.
//
// The reference WEIGHTS per-cluster translate by the falloff (it is NOT exempt) —
// see the capture in tools/local/.../falloff_local_tripatch. The MS-4 per-cluster
// fold reproduces this; the pre-fold falloff-EXEMPT applyTranslatePerCluster does
// not (it would move every cluster vert by the full amount regardless of weight),
// so this fixture is also the regression gate for that bug fix.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/falloff_local.json");
    runParitySuite(json);
}
