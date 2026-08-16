// select.boundary reference parity (task 1050) — the border edges of the
// selected polygon set, frozen from a headless reference capture.
//
// What is NOT here: the cases that decided the RULE. They need an open mesh,
// a T-junction and a coincident-duplicate polygon, none of which the fixture
// step vocabulary can build; they live in `source/commands/select/boundary.d`
// as module unittests, with both directions of the T-junction asserted. Every
// case below is manifold, where the measured rule and the reference's own
// documented "odd number of selected polygons" wording agree — so a green run
// here says "we match the reference on ordinary geometry", not "we picked the
// right rule".

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/select_boundary.json");
    runSelectionSuite(json);
}
