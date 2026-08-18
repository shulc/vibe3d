// Task 1130 -- which vertex survives a join with averaging OFF. Frozen as a
// KNOWN DIVERGENCE, ledger row 11.
//
// The reference keeps the LAST-SELECTED vertex; we keep the one with the
// LOWEST INDEX. Two rules that agree on half of all inputs, which is why the
// fixture carries the cell that separates them AND the cell that does not:
//
//   forward_order_diverges          select the low corner, then the high one.
//                                   Last-selected and lowest-index disagree,
//                                   and so do the engines.
//   reversed_order_is_the_control   the SAME pair, opposite order. Now the two
//                                   rules pick the same vertex and the
//                                   survivors agree -- declared a CONTROL over
//                                   the geometry dimensions. This is the cell
//                                   that rules out "highest index" as the
//                                   reference's law; without it the forward
//                                   cell alone cannot tell the two apart.
//   three_vertices_confirm          three vertices on a valence-6 pole: the
//                                   same disagreement, not a two-vertex quirk.
//
// Selection ORDER is therefore load-bearing here, and the fixture keys each
// selection on an ORDERED coordinate list.
//
// Note that even in the control the post-command SELECTION still differs --
// that is ledger row 12's law, pinned in its own fixture, and the control is
// deliberately scoped to the geometry so the two findings stay separable.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/vert_join_survivor.json");
    runCommandDivergenceSuite(json);
}
