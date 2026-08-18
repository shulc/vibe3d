// Ledger row 24 — polygon inset on a NON-PLANAR ring. Measured by task 1140
// as a KNOWN DIVERGENCE; CLOSED by task 1190, and kept here with an EMPTY
// declared gap.
//
// On a folded quad the reference's inset-ring corners follow the bend. Ours
// did not: heading for the face CENTROID put all four on one approximating
// plane (out-of-plane 4.24e-3 four times over, against the reference's
// 2.1e-5 / 8.443e-3 / 2.1e-5 / 9.1557e-2). The two engines agreed to 2.7e-4
// in the two in-plane axes and parted by up to 4.230e-3 along the fold axis
// at inset 0.12 — 3.5% of the inset, at every corner of both cells.
//
// This closed for free with ledger row 48. `insetCornerBisector` builds the
// direction from the two adjacent EDGES (rotated into the ring plane), and an
// edge of a bent ring is on the bend — so the corner lands on the surface by
// construction rather than by a separate out-of-plane rule. Worst residual is
// now 2.12e-5, two hundred times smaller and at the reference's own
// six-decimal print precision; the 1140 note that the mechanism was "an
// INFERENCE consistent with these two cells" turned out to be the right
// inference.
//
// It is NOT bit-exact and this fixture does not claim it is: 2.12e-5 is below
// the 1e-4 tolerance, not zero. Two of the four corners do land exactly.
//
// An EMPTY divergence is the strict reading of this schema: the runner
// recomputes `extra_in_vibe3d` / `missing_in_vibe3d` live against the frozen
// reference and asserts they are empty, so restoring the flat approximation
// reddens this at 4.230e-3.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_inset_nonplanar_divergence.json");
    runKnownDivergenceSuite(json);
}
