// Mirror / flip / triple parity on dirty geometry, frozen from the reference
// (task 1160). None of these three commands had a measured fixture before.
//
// `poly_flip_triple_dirty_parity`'s flip cells are the only place in this
// delivery where a direction-sensitive face ring is the ENTIRE assertion: a
// flip moves no vertex, changes no count, and rewrites nothing but winding
// order. If `expected_faces` were compared winding-blind, those cases would
// pass with the command removed.
//
// Triangulation is frozen only on the subset where the two engines picked the
// same diagonal. On reflex and non-planar rings they largely do not, and those
// cells belong to the divergence lane -- freezing "we happen to agree here"
// alongside "we are known to disagree there" is the distinction this file
// keeps.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/mirror_dirty_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/poly_flip_triple_dirty_parity.json"));
}
