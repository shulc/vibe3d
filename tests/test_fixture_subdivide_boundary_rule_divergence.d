// Task 1140 -- KNOWN DIVERGENCE: Catmull-Clark at an open boundary.
// Ledger row 34.
//
// The reference applies the cubic B-spline boundary rule
//     v' = 1/8 * prev + 3/4 * v + 1/8 * next        (along the boundary)
// and we apply nothing -- our boundary vertices do not move. This is not an
// attribution: the rule was CHECKED against the frozen reference output on
// all 10 boundary corners of the two cases and reproduces every one of them
// exactly, including the reflex corner (2,0,1) -> (2,0,1.75).
//
// Counts agree (11 / 15 / 5 on both sides): edge midpoints and the face
// point are identical, and the entire gap is the 5 corners, up to 0.910014
// apart on a face 4 units across.
//
// The two cases are the same pentagon with the ring started at a different
// corner, so the gap is shown not to be a ring-start artefact.
//
// Closing this means implementing a boundary rule, and the fixture already
// names the one to implement.
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
    enum string json = import("fixtures/subdivide_boundary_rule_divergence.json");
    runKnownDivergenceSuite(json);
}
