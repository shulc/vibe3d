// Task 1140 -- KNOWN DIVERGENCE: what a mirror's weld is allowed to join.
// Ledger row 32.
//
// A base carrying a near-duplicate pair 7.071e-4 apart is mirrored through
// x = 0 with weld distance 1e-3. The reference keeps both images of that
// pair (10 vertices); we weld them into one (9 vertices), and the mirrored
// triangle's ring loses its own corner with them.
//
// THE LEDGER ROW THAT PROMPTED THIS FIXTURE IS WRONG ABOUT THE MECHANISM and
// the numbers here say so: it reads the cell as a strict-versus-non-strict
// comparison at exactly the threshold, but the pair is 7.071e-4 apart and
// the threshold is 1e-3 -- inside it either way. The cell measures SCOPE (do
// two freshly created mirror images of two distinct source vertices weld to
// each other), not the comparison at the boundary. That reading is in turn
// an inference from ONE cell; what is frozen is the two vertex sets.
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
    enum string json = import("fixtures/mirror_weld_scope_divergence.json");
    runKnownDivergenceSuite(json);
}
