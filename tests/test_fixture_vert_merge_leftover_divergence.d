// Task 1140 -- KNOWN DIVERGENCE: what survives a merge-by-distance.
// Ledger row 37.
//
// A quad plus a sliver triangle whose two far corners are 2e-3 apart, merged
// at radius 1e-2 with everything selected. Both engines collapse the sliver
// and keep the quad; the reference leaves the merged point behind as a LOOSE
// vertex at (1.9,0,0.501) and we discard it. 5 vertices against our 4, with
// the same 4 edges and the same single face ring on both sides -- so the
// entire gap is that one unreferenced vertex, and only the vertex channel
// can see it.
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
    enum string json = import("fixtures/vert_merge_leftover_divergence.json");
    runKnownDivergenceSuite(json);
}
