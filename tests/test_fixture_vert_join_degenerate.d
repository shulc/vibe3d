// Task 1130 -- what survives a join that consumes everything. Frozen as a
// KNOWN DIVERGENCE, ledger row 21.
//
//   collapse_everything   collapse a whole open plate to one point. The
//                         reference keeps ONE FREE VERTEX; we keep an empty
//                         mesh.
//   keep_flag_on_a_pole   with the keep flag on, the reference honours it and
//                         preserves the two-point remnants (8 faces); our
//                         kernel discards them (6). Our own source says the
//                         flag "is recognized but not yet honored" -- this is
//                         that sentence turned into a number, and into a test
//                         that reddens the day the sentence stops being true.
//
// Degenerate remnants are the object of study, so the face and edge counts
// carry the finding and are asserted on both sides. Both bases are open.
//
// NOT a parity test: green means the measured gap is unchanged. When the keep
// flag is implemented, the second case reddens with the delta it now sees --
// re-measure, and if it closed, retire the case into a parity fixture.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/vert_join_degenerate.json");
    runCommandDivergenceSuite(json);
}
