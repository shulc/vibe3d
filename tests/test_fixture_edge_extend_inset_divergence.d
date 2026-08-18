// Task 1140 -- KNOWN DIVERGENCE: edge extend by local inset.
// Ledger row 36.
//
// Counts agree exactly on both bases and every new vertex lands somewhere
// else: 7.063e-3 at inset 0.1 on the folded pair (6 of 6 new vertices),
// 1.703e-2 on the saddle (12 of 12). The direction the inset pushes the new
// row is what differs.
//
// The sweep this came from also drove the same family with the inset at
// zero -- a pure world offset -- and 64 of 71 of THOSE cells agree, which is
// what locates the gap in the inset direction rather than in the extend.
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
    enum string json = import("fixtures/edge_extend_inset_divergence.json");
    runKnownDivergenceSuite(json);
}
