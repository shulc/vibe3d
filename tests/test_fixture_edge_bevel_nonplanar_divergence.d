// Task 1140 -- KNOWN DIVERGENCE: edge bevel on non-planar geometry.
// Ledger rows 29, 30 and 31.
//
// Three cells of one tool, each with its own frozen numbers:
//   width_mode_on_folded_base   0.079188 at width 0.08  (~100%)
//   round_level_two_arc         0.016540 at bevel 0.08  (21%), and only
//                               at the FOLDED end of the edge -- the arc at
//                               the flat end is identical on both sides
//   whole_star_of_interior_vert 0.007414 at bevel 0.06  (12%)
//
// Vertex and face COUNTS agree in all three; only positions move. They are
// grouped here because they are one tool on one class of geometry, NOT
// because one law has been shown to generate all three -- the shared root
// (which plane the offset corner is placed in on a bent face) is an
// attribution from the wider sweep, and this fixture does not assert it.
// If it is ever settled, these three cases are the cells to re-measure.
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
    enum string json = import("fixtures/edge_bevel_nonplanar_divergence.json");
    runKnownDivergenceSuite(json);
}
