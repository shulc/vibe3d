// Polygon bevel and polygon inset parity on dirty geometry, frozen from the
// reference (task 1160).
//
// The existing bevel fixtures are dump-oracles for single flags on clean
// cages. These cross the flag space with the geometry: inset only, shift only,
// both, grouped and ungrouped, two segments, square corners, a negative inset,
// a doubled application and a star selection -- over non-planar, oblique,
// reflex, poled, degenerate and counter-wound bases.
//
// `nogroup` is the separating flag. With grouping off each selected face
// bevels alone, so the shared edges of a multi-face base come apart, and the
// two answers differ in vertex COUNT as well as position.
//
// Inset is frozen for the opposite reason to bevel: it diverges on roughly
// three quarters of the dirty bases, so the surviving agreements are a thin
// ledge, and a regression that moved the ledge would show here first.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/poly_bevel_dirty_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/poly_inset_dirty_parity.json"));
}
