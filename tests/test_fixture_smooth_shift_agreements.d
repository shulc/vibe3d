// Smooth-shift parity on dirty geometry, frozen from the reference
// (task 1160).
//
// The existing smooth-shift fixture is a capture on a stock cube. On a cube
// every face is planar and every incident normal agrees, so the averaged
// direction a shifted face travels is not actually being tested there. These
// cells are the complement: non-planar rings, poles of valence 3 to 8, reflex
// rings, slivers, a collinear corner and a spike, plus the inward direction
// and the single-face-of-many selection.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/smooth_shift_dirty_parity.json"));
}
