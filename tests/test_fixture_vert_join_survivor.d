// Tasks 1130 (measured) + 1210 (ported) -- which vertex survives a join with
// averaging OFF. Ledger row 11.
//
// THE LAW: the survivor is the LAST-SELECTED vertex. We used to keep the one
// with the LOWEST INDEX -- two rules that agree on half of all inputs, which
// is why the fixture carries the cell that separates them AND the cell that
// does not:
//
//   forward_order_diverges          select the low corner, then the high one.
//                                   Last-selected and lowest-index name
//                                   different vertices, so this cell is what
//                                   the port had to move.
//   reversed_order_is_the_control   the SAME pair, opposite order. There the
//                                   two rules pick the same vertex and the
//                                   survivors agreed even BEFORE the port.
//                                   This is the cell that rules out "highest
//                                   index" as the law; without it the forward
//                                   cell alone cannot tell the two apart, and
//                                   a port that guessed "highest index" would
//                                   have gone green on the forward cell and
//                                   red here.
//   three_vertices_confirm          three vertices on a valence-6 pole: the
//                                   same rule, not a two-vertex quirk.
//
// Selection ORDER is therefore load-bearing, and the fixture keys each
// selection on an ORDERED coordinate list. `Mesh.selectedVerticesBySelectionOrder`
// is where that order is read; every user-reachable selection path (click,
// RMB lasso, every select.* command) stamps it.
//
// The cell NAMES are kept as they were: "diverges" and "is_the_control"
// describe what each cell is FOR, which does not change when a gap closes.
//
// ALL THREE CASES NOW DECLARE AN EMPTY GAP -- including the post-command
// selection, which the reference leaves empty and which we used to leave
// holding the survivor. The cases are not deleted: every measured dimension is
// declared a CONTROL, so the empty gap is asserted per dimension.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/vert_join_survivor.json");
    runCommandDivergenceSuite(json);
}
