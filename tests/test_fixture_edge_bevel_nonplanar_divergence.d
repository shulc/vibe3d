// Task 1140 -- edge bevel on non-planar geometry. Ledger rows 29, 30 and 31.
//
// Three cells of one tool, each with its own frozen numbers:
//   width_mode_on_folded_base   0.079188 at width 0.08  (~100%)   -- OPEN
//   round_level_two_arc         0.016540 at bevel 0.08  (21%)     -- OPEN
//                               and only at the FOLDED end of the edge; the
//                               arc at the flat end is identical on both sides
//   whole_star_of_interior_vert was 0.007414 at bevel 0.06 (12%)  -- CLOSED
//                               by task 1170; its gap is now declared EMPTY
//
// THE GROUPING WAS AN ATTRIBUTION, AND THE PORT SPLIT IT. These three were
// filed together on a SUSPECTED shared root -- which plane the offset corner
// is placed in on a bent face -- explicitly not asserted as one proven law.
// That root has since been measured (53 cells, 117 mitred corners,
// tests/fixtures/edge_bevel_offset_law.json) and ported
// (`math.bevelMiterPoint`), and the result separates the three: cell (c)
// closed to parity in both the vertex and the face channel, while (a) and (b)
// did not move by a single coordinate.
//
// The reason is visible in the cells themselves and is worth keeping, because
// it is what stops (a) and (b) being read as "the same bug, still open": a
// mitre exists only where ONE face carries BOTH of its ring edges bevelled.
// (c) is the whole star of an interior vertex, so every incident face does.
// (a) and (b) bevel a SINGLE edge, so no face does, and every vertex they
// create is a pure SLIDE along an unbevelled edge -- a rule we already
// matched. (a) and (b) therefore each pose their own separate, still
// UNMEASURED question: how a perpendicular width converts to a corner slide,
// and where the interior points of a round-level arc go. Neither is answered
// by the offset law, and neither should be closed by appeal to it.
//
// (c) is kept here rather than deleted. It is an INDEPENDENT confirmation of
// the offset law -- different geometry, a different rig, and not one of the
// 53 cells the law was fitted on -- so its reference golden is worth keeping
// in the tree, and `runKnownDivergenceSuite` asserts its now-empty gap
// exactly as strictly as it asserts (a)'s and (b)'s full ones.
//
// This is NOT a parity test for (a) and (b). A green run means three things
// at once: our output still matches its recorded output, the reference golden
// is still what it was measured to be, and the gap between them is EXACTLY
// the declared delta. If a gap narrows OR widens this suite goes red -- and
// closing one entirely is a red run too, which is the prompt to re-measure
// and convert that case, as (c) has been.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/edge_bevel_nonplanar_divergence.json");
    runKnownDivergenceSuite(json);
}
