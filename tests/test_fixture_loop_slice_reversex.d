// Loop Slice Reverse Direction (task 0257: reversex). reversex mirrors the 1D
// profile ALONG THE CUT (t := 1-t, then re-sort the samples by t), so an
// ASYMMETRIC profile (Step: flat near half, raised far half) cuts in the
// mirrored orientation. Analytic self-golden on the 0256 flat strip (3 quads,
// normal -Y): with the Step profile + Inset depth=2, reversex OFF displaces the
// FAR half (y=[...,-2,-2]) and reversex ON displaces the NEAR half
// (y=[-2,-2,...]) — same topology (16 verts / 22 edges / 7 faces), the height
// pattern mirrored along t. The OFF case is byte-for-byte the un-reversed Step
// profile cut (the 0256 mechanism, reverseX_ identity).
//
// SCOPE/HONESTY: reversex is a live-captured reference option (default false,
// greyed until a Profile loads); the mapping (t := 1-t, re-sort) is DERIVED —
// the loop-slice gesture is human-VNC-only and the profile preset library is
// closed source, so the Step curve is a vibe3d-defined stand-in and the exact
// reversex geometry was not live-recaptured. Flagged in the fixture `source`.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_reversex.json");
    runTopologyDiffSuite(json);
}
