// Task 1130 measured it, task 1200 CLOSED it — our make-polygon had four
// refusal gates and the reference has none of them. Ledger row 7.
//
//   three_collinear_points        zero-area triangle
//   two_points_only               a 2-point polygon
//   bowtie_click_order            a self-intersecting ring, built as given
//   duplicate_over_existing_face  a DUPLICATE face on an existing ring:
//                                 2 faces -> 3, and the edge count does not
//                                 grow at all
//
// All four now declare an EMPTY gap, and every dimension they were ever open
// in is declared a CONTROL. That is stronger than deleting them: an empty gap
// is re-asserted per-dimension on every run, so this file still fails if the
// counts, the rings, the winding, the selection, or the applied-flags drift —
// and it fails naming the dimension.
//
// Three of the four gates protected invariants the mesh kernel relies on; the
// owner's call (2026-08-18) was to match the reference anyway and make the
// results survivable instead. The gates are NOT deleted from the kernel —
// `Mesh.MakePolyGates` switches them, the default is still `all`, and the
// Topology Pen (which builds every face it makes through the same kernel and
// relies on the zero-area refusal) is untouched. Only `mesh.makePolygon` asks
// for `none`. What the removal cost, and what had to be fixed downstream to
// pay it, is in doc/tasks/work/1200-ref-refusals.md.
//
// The click ORDER is the independent variable in the bow-tie cell, so the
// selection is keyed on an ORDERED coordinate list — the same four points in
// ring order build a clean quad, and that is a different case entirely.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/make_polygon_gates.json");
    runCommandDivergenceSuite(json);
}
