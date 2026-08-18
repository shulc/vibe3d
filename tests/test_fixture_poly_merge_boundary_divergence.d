// Task 1140 -- KNOWN DIVERGENCE: which boundary a polygon merge walks.
// Ledger rows 8 and 33.
//
// (a) annulus_walks_into_the_hole -- 3x3 grid minus its centre face, all 8
//     faces merged. The reference walks INTO the hole and back out along the
//     same edge, giving one 18-corner ring on 16 vertices / 17 edges; two of
//     its ring entries are the same vertex twice. We produce the 12-corner
//     outer boundary, pave the hole over and delete the 4 vertices that
//     bounded it -- 12 vertices, 12 edges.
//
// (b) opposite_winding_pair_refused -- two quads sharing an edge, wound
//     against each other. The reference merges them into one hexagon; we
//     leave both quads and the shared edge alone. THE VERTEX SETS ARE
//     IDENTICAL in this cell, so it is the face channel, not the vertex
//     channel, that carries the whole divergence.
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
    enum string json = import("fixtures/poly_merge_boundary_divergence.json");
    runKnownDivergenceSuite(json);
}
