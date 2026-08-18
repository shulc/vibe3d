// Task 1150 -- divergence-ledger row 48: polygon inset moves every corner of
// the new ring by exactly the inset distance in BOTH engines, and the two
// engines disagree only about the DIRECTION.
//
// The reference follows the corner's angle bisector: at a right angle its
// offset is (0.084853, 0, 0.084853), which is 0.12/sqrt(2) and nothing else.
// We head for the face CENTROID. On a convex ring that is a modest error --
// 16.9 degrees at the rectangle's corners. On a NON-CONVEX ring it is not
// modest: the dart's reflex corner is sent -0.12 where the reference sends it
// +0.12, exactly 180 degrees the wrong way, so our inset ring bulges out of
// the polygon at that corner instead of into it.
//
// This is NOT a parity test. It freezes our own output, the reference golden,
// the exact vertex-level gap, AND -- because a vertex-set diff records "three
// vertices differ" and loses the actual finding -- each engine's per-corner
// displacement VECTOR. The runner re-derives both offsets (the reference's
// from the frozen golden, ours from the live run) and asserts three separate
// things about them: the magnitudes still agree, each corner's direction gap
// is still the angle that was measured, and the vertex sets differ by exactly
// the declared set. Any of the three moving means the divergence changed.
//
// When the direction law is ported, the angles go to zero and the extra/
// missing sets empty out -- and this suite reddens on all three counts, which
// is the prompt to retire it into a parity fixture.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/inset_corner_direction_divergence.json");
    runKnownDivergenceSuite(json);
}
