// Task 1140 -- KNOWN DIVERGENCE: triangulation diagonals on a reflex ring.
// Ledger row 25.
//
// BOTH CELLS HAVE IDENTICAL VERTEX SETS AND IDENTICAL COUNTS. Nothing moves,
// nothing is created; the whole divergence is which vertices make a triangle.
// A check that compared vertices alone would report parity here, which is
// exactly why this fixture carries the face channel.
//
// The concrete defect on our side is visible in the frozen data: our fan
// starts at ring vertex 0 and emits a triangle that CONTAINS the reflex
// corner -- (0,0,0)-(4,0,0)-(4,0,4) contains (2,0,1) in the pentagon, and
// (0,0,0)-(3,0,0)-(3,0,3) contains (2,0,1) in the hexagon -- so our
// triangulation overlaps itself. The reference's does not.
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
    enum string json = import("fixtures/poly_triple_reflex_divergence.json");
    runKnownDivergenceSuite(json);
}
