// select.byStat.{vertex,edge,polygon} reference parity (task 1061) — the
// Statistics tree's rows, frozen from a headless reference command capture.
//
// What is NOT here (see source/commands/select/by_stat.d's module unittests
// and doc/behavior_gap_registry.md instead): the non-manifold 3rd-polygon
// edge case (needs a coincident-duplicate polygon the fixture step
// vocabulary cannot build), the select.boundary cross-law discriminator
// (needs two commands run in sequence on the same mesh state), the polygon
// `less` anomaly (measured as behaving like `more` in the reference; we
// ship strictly-less and do not reproduce it), the multi-foreground-layer
// scope divergence (we evaluate the primary layer only), and the deferred
// coplanar/UV boundary kinds. Every case below is single-layer, manifold
// geometry where our answer matches the reference's — a green run here says
// "we match the reference on ordinary geometry", not "we picked every rule
// right" (the 1050 precedent, `tests/test_fixture_select_boundary.d`).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/select_by_stat.json");
    runSelectionSuite(json);
}
