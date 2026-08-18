// Task 1130 -- what a band loop slice leaves selected. Frozen as a KNOWN
// DIVERGENCE, ledger row 3.
//
// The reference leaves the whole PRODUCT selected: the sliced polygons AND the
// new loop's 9 edges and 10 vertices. We leave the polygons only. Same law as
// ledger rows 2 and 12 -- the reference re-points the selection at what the
// command made -- reaching a third tool.
//
// Two things about this cell are worth saying out loud, because both are
// limits on what it proves.
//
// FIRST, the base is not the one the ledger row was found on. That row came
// from the pilot's book patch, whose step-15 mesh was never dumped and whose
// preceding amounts are substituted, so there is nothing there to freeze. This
// cell re-measures the same command on a 3-segment unit cube -- one command
// per engine, fully reproducible -- and on that base the two engines produce
// 66 verts / 127 edges / 63 faces with the SAME vertex, edge and face sets. So
// the geometry is declared a CONTROL and the selection stands alone.
//
// SECOND, the row's other half does NOT reproduce here. On the pilot patch six
// of the fourteen selected polygons differed between the engines; on this base
// the selected polygon sets agree exactly, all eighteen of them. This fixture
// therefore freezes the edge/vertex half of the row and claims NOTHING about
// the polygon half -- which stays open in the ledger, on a base that would
// have to be dumped before it could be frozen. Do not read a green run here as
// "row 3 is fully pinned".
//
// NOT a parity test -- see runCommandDivergenceSuite.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_post_selection.json");
    runCommandDivergenceSuite(json);
}
