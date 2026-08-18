// Task 1130 -- what an edge bevel leaves selected. Frozen as a KNOWN
// DIVERGENCE, ledger row 2.
//
// The reference leaves the NEW BAND selected: its 10 edges and the 8 vertices
// they span. We leave 3 POLYGONS selected -- while still reporting edge mode,
// which is its own small oddity and is pinned here rather than described.
//
// The cell is a 3-segment unit cube with its three top-front rim edges
// bevelled by 0.1, and the choice of base is the point of the file. The ledger
// found this on the pilot's book patch, where the finding could only be
// recorded as COUNTS (17 verts / 22 edges) -- that patch's step-14 mesh was
// never dumped and several of the amounts leading to it are substituted, so
// there is nothing there to freeze. On this base both engines produce
// 60 verts / 115 edges / 57 faces and the SAME vertex, edge and face sets, so
// the geometry is declared a CONTROL and the divergence is isolated to exactly
// one thing: the selection the command leaves behind.
//
// That isolation is what makes the row actionable. "Our bevel selects
// differently" and "our bevel cuts differently" are different bugs with
// different fixes, and until this fixture existed the row could not tell them
// apart. If the geometry ever parts company here, the control reddens FIRST
// and says so -- which is a finding about the bevel, not about the selection.
//
// Same law as ledger row 12 (test_fixture_cmd_selection_product.d): the
// reference re-points the selection at the command's PRODUCT. This is that law
// reaching a tool the thin-command capture never touched.
//
// NOT a parity test -- see runCommandDivergenceSuite.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/edge_bevel_post_selection.json");
    runCommandDivergenceSuite(json);
}
