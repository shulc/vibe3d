// Task 1140 -- KNOWN DIVERGENCE: the loop-slice ring walk.
// Ledger rows 27 and 28.
//
// (a) ring_stops_at_triangle -- a CAPABILITY GAP. The reference cuts the quad
//     half of a quad+triangle base and absorbs the new vertex into the
//     triangle's ring (5 verts -> 7, 2 faces -> 3). Our walk stops at the
//     triangle, the command is rejected and nothing is cut. Closing this half
//     means teaching the walk to terminate into a non-quad -- implementing,
//     not tuning.
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
// This is NOT a parity test. A green run means three things at once: our
// output still matches its recorded output, the reference golden is still
// what it was measured to be, and the gap between them is EXACTLY the
// declared delta. If the gap narrows OR widens this suite goes red -- and
// closing it entirely is a red run too, which is the point: whoever closes
// it deletes the case and adds a parity one in its place.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_ring_walk_divergence.json");
    runKnownDivergenceSuite(json);
}
