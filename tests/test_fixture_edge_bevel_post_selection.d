// Task 1130 / 1180 -- what an edge bevel leaves selected. Measured as a
// divergence (ledger row 2) and then PORTED.
//
// The reference leaves the NEW BAND selected: its 10 edges and the 8 vertices
// they span, and NONE of the band's 3 faces. We used to leave those 3 POLYGONS
// selected -- while still reporting edge mode, which was its own small oddity
// and was pinned here rather than described. Task 1180 ported the law: our
// kernel still selects the band's faces (that is how the product is NAMED
// without a second pass) and commands/mesh/bevel.d re-points one dimension
// down from them, through selection_product.repointToFaceBorder.
//
// The cell is a 3-segment unit cube with its three top-front rim edges
// bevelled by 0.1, and the choice of base is the point of the file. The ledger
// found this on the pilot's book patch, where the finding could only be
// recorded as COUNTS (17 verts / 22 edges) -- that patch's step-14 mesh was
// never dumped and several of the amounts leading to it are substituted, so
// there is nothing there to freeze. On this base both engines produce
// 60 verts / 115 edges / 57 faces and the SAME vertex, edge and face sets, and
// now the same selection too; every measured dimension is declared a CONTROL,
// so the closed gap is asserted exactly as strictly as the open one was.
//
// That isolation is what made the row actionable. "Our bevel selects
// differently" and "our bevel cuts differently" are different bugs with
// different fixes, and until this fixture existed the row could not tell them
// apart. If the geometry ever parts company here, the geometry control reddens
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
