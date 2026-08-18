// Task 1140 -- KNOWN DIVERGENCE: the loop-slice ring walk.
// Ledger rows 27 and 28. Row 27 is CLOSED (task 1240); row 28 is not.
//
// (a) ring_stops_at_triangle -- was a CAPABILITY GAP, CLOSED BY
//     IMPLEMENTATION in task 1240. The reference cuts the quad half of a
//     quad+triangle base and absorbs the new vertex into the triangle's ring
//     (5 verts -> 7, 2 faces -> 3); our walk used to stop at the triangle and
//     the command was rejected.
//
//     WHAT THE STOP TURNED OUT TO BE. The walk itself was never the problem:
//     it propagates through quads and terminates at anything else, and when it
//     terminated MID-ring the neighbour already absorbed the terminating
//     midpoint (`insertEdgeLoopsMulti`'s two-pass path, the default for any
//     open ring since the watertight change). The refusal lived one level up,
//     in `collectEdgeRing`'s SEED guard, whose comment gave the reason: a
//     non-quad on the seed would keep its old ring while the seed edge gained
//     a midpoint, i.e. a T-junction. That reason had already been answered by
//     the absorb pass everywhere except at the seed. Task 1240 removed the
//     seed refusal only -- the walk still requires a quad to propagate, and a
//     seed with NO quad on either side is still a no-op, since there is no
//     quad frame to take the rails from. Non-termination is guarded where it
//     always was, by `walkRingSide`'s visited-face set: a face is marked the
//     moment its entry is recorded and re-entering one breaks the loop, so
//     the walk is bounded by the face count however odd the topology.
//
//     This case declares an EMPTY gap now, and an empty gap is not a weaker
//     assertion: the runner recomputes the difference between our live output
//     and the frozen reference and requires it to equal the declaration, so
//     our counts, our vertex set and our face rings WITH WINDING must all
//     equal the reference's. The case is converted, not deleted -- the
//     reference measurement is unchanged and is the half worth keeping.
//
// (b) three_cuts_rail_pairing -- THE TRAP. Both engines produce the SAME 28
//     vertices, the SAME 45 edges and the SAME 18 faces. A fixture that
//     compared vertices, or even counts, would report parity. 8 of the 18
//     face rings nevertheless differ: our cut order runs backwards along
//     alternate rails, so a quad joins parameter t on one rail to 1-t on the
//     next -- the four quads of a column overlap instead of tiling it. The
//     cut set {0.25, 0.5, 0.75} is palindromic, which is what hides the
//     reversal in the vertex channel.
//
// The face channel here compares rings up to ROTATION only: 6 of the 8 differ
// in which vertices they join, and 2 differ only in which way round they go.
// A winding-blind comparison would report the second pair as parity.
//
// This is NOT (only) a parity test. A green run means three things at once:
// our output still matches its recorded output, the reference golden is still
// what it was measured to be, and the gap between them is EXACTLY the
// declared delta. If the gap narrows OR widens this suite goes red -- which is
// how case (a) announced that it had closed, and what makes case (b)'s
// still-declared gap a live statement rather than a note.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_ring_walk_divergence.json");
    runKnownDivergenceSuite(json);
}
