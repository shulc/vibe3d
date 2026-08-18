// Task 1130 -- our make-polygon has four refusal gates; the reference has
// none of them. Frozen as a KNOWN DIVERGENCE, ledger row 7.
//
//   three_collinear_points        zero-area triangle -- built there
//   two_points_only               a 2-point polygon -- built there
//   bowtie_click_order            a self-intersecting ring -- built as given
//   duplicate_over_existing_face  a DUPLICATE face on an existing ring:
//                                 2 faces -> 3, and the edge count does not
//                                 grow at all
//
// The click ORDER is the independent variable in the bow-tie cell, so the
// selection is keyed on an ORDERED coordinate list -- the same four points in
// ring order build a clean quad, and that is a different case entirely.
//
// This fixture takes no position on which engine is right. Three of these four
// gates protect invariants our mesh kernel genuinely relies on; what the
// fixture pins is that the disagreement exists and has not silently moved. If
// a gate is ever removed to match, this reddens on the case that changed, and
// that case is then retired into a parity fixture.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/make_polygon_gates.json");
    runCommandDivergenceSuite(json);
}
