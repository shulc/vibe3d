// Task 1140 -- KNOWN DIVERGENCE: bridge ring pairing, winding and segments.
// Ledger row 38.
//
// (a) two_faces_plain -- SAME vertices, SAME counts, SAME rings, and all four
//     bridge quads wound the OTHER WAY. This is why the face channel here
//     compares rings up to rotation only and never up to reflection: a
//     winding-blind comparison calls this cell parity outright.
//
// (b) two_faces_flipped -- the flip flag means two different things. The
//     reference's flip reverses the WINDING of the same four quads; ours
//     re-pairs the two rings one step round, producing a different set of
//     quads (ours joins (0,0,0)-(1,0,0) to (0,0,3)-(0,0,2); the reference
//     joins it to (1,0,2)-(0,0,2)).
//
// (c) three_segments -- a CAPABILITY GAP. The reference lays 12 quads on two
//     intermediate rings at 1/3 and 2/3 of the span; our bridge has no
//     segment count, so it lays the single span of (a). 16 vertices / 12
//     faces against our 8 / 4. Closing this means adding the control.
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
    enum string json = import("fixtures/bridge_ring_pairing_divergence.json");
    runKnownDivergenceSuite(json);
}
