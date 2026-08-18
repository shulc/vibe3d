// Task 1140 -- KNOWN DIVERGENCE: polygon inset on a non-planar ring.
// Ledger row 24.
//
// On a folded quad the reference's inset-ring corners follow the bend; ours
// do not. The two engines agree to 2.7e-4 in the two in-plane axes and part
// by up to 4.230e-3 along the fold axis, at inset 0.12 -- 3.5% of the inset.
// Every corner of the inset ring is affected, in both cases.
//
// WHY they differ -- a per-corner offset plane on their side versus a single
// approximating plane on ours -- is an INFERENCE consistent with these two
// cells, not something this capture settled. What is frozen here is the two
// sets of coordinates and the gap between them.
//
// This is NOT a parity test. A green run means three things at once: our
// output still matches its recorded output, the reference golden is still
// what it was measured to be, and the gap between them is EXACTLY the
// declared delta. If the gap narrows OR widens this suite goes red -- and
// closing it entirely is a red run too, which is the point: whoever closes
// it deletes the case and adds a parity one in its place.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_inset_nonplanar_divergence.json");
    runKnownDivergenceSuite(json);
}
