// Task 1130 / 1180 -- what a band loop slice leaves selected. Measured as a
// divergence (ledger row 3) and then PORTED.
//
// The reference leaves the new loop's EDGES and VERTICES selected ALONGSIDE
// the sliced polygons; we used to leave the polygons only. Task 1180 ported
// the law: the Loop Slice tool now adds the loop through
// selection_product.addNewLoop -- additively, because the slice's product
// spans two dimensions at once and both halves are held.
//
// Measured on a 3-segment unit cube where the two engines' slice GEOMETRY
// agrees exactly, so the divergence was isolated to the selection. On this
// base the selected POLYGON sets agree exactly and always did -- the ledger's
// "six of fourteen polygons differ" was seen on the pilot's patch, is NOT
// reproduced here, and was never this cell's target. It freezes the
// edge/vertex half and deliberately claims nothing about the polygon half.
//
// Every measured dimension is now declared a CONTROL, so the closed gap is
// asserted exactly as strictly as the open one was: delete the addNewLoop call
// in the tool and this file reddens on the 10 missing vertices.
//
// One rule, two callers: the one-shot mesh.addLoop / mesh.loopSlice commands
// call the same helper (they used to carry their own edges-only copy from task
// 0476, whose single-layer capture could not see the vertex leg this row's
// three-layer capture shows).
//
// NOT a parity test -- see runCommandDivergenceSuite.
import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_post_selection.json");
    runCommandDivergenceSuite(json);
}
