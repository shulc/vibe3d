// Loop Slice 1D profile cutter (task 0256: Profile + Inset/depth). A profile is a
// normalized 2D curve (along-cut fraction, height) sampled into MULTIPLE loops;
// each loop is inserted at its fraction and displaced along the surface normal by
// height*depth ("Inset"). Analytic self-golden on a FLAT strip (3 quads, normal
// -Y): the default (Flat) profile reduces to the byte-for-byte multi-loop flat
// cut (loops stay on the surface); the Vee profile with depth=2 presses a V into
// the surface (y=[-1,-2,-1], apex at the centre); the Vee profile with the
// reference default depth=0 is a no-op (loops stay flat). Topology is identical in
// every case (14 verts / 19 edges / 6 faces) — the profile relocates verts only.
//
// SCOPE/HONESTY: the sample->loop->normal-inset MECHANISM is reference-faithful,
// but the specific built-in profile curves (flat/round/vee/step) are vibe3d-
// defined stand-ins — the reference profile preset library is closed
// source and not headlessly capturable. Flagged in the fixture `source`. The Vee
// tent + the flat/depth-0 no-op invariants also live in the source/mesh.d kernel
// unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_profile.json");
    runTopologyDiffSuite(json);
}
