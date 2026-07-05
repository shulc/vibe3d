// Loop Slice Reverse Inset (task 0258: reversey). reversey flips the SIGN of the
// profile's normal-direction inset/displacement (height := -height in kernelFeed),
// so the profile presses OUT of the surface instead of into it. Analytic
// self-golden on the 0256 flat strip (3 quads, normal -Y): with the symmetric Vee
// profile + Inset depth=2, reversey OFF INSETS into the surface (apex y=-2) and
// reversey ON BULGES out of it (apex y=+2) — same topology (14 verts / 19 edges /
// 6 faces), the displacement sign flipped. The OFF case is byte-for-byte the
// un-reversed Vee profile cut (the 0256 mechanism, reverseY_ identity).
//
// SCOPE/HONESTY: reversey is a live-captured reference option (default false,
// greyed until a Profile loads); the mapping (height := -height) is DERIVED — the
// loop-slice gesture is human-VNC-only and the profile preset library is closed
// source, so the Vee curve is a vibe3d-defined stand-in and the exact reversey
// geometry was not live-recaptured. Flagged in the fixture `source`.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_reversey.json");
    runTopologyDiffSuite(json);
}
