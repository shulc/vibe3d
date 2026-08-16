// Loop Slice `Slice Selected` over an L-SHAPED selection — a KNOWN DIVERGENCE
// from the reference, frozen (task 1053, risk R1 of the dogfood audit).
//
// This is NOT a parity test and a green run here does NOT mean we match. The
// reference cuts one path that TURNS at the corner cell; we cut both rings
// clipped to the selection, so they CROSS there and we emit three vertices it
// does not. The fixture carries both measurements and the exact gap, and
// `runKnownDivergenceSuite` fails if EITHER side moves — including if someone
// closes the gap, which is the moment this file should be replaced by a
// parity case.
//
// Why it exists at all: the only Slice Selected fixture we had
// (test_fixture_loop_slice_slice_selected.d) selects two ADJACENT faces — a
// straight run — so it cannot see corner behaviour, and chapter 5 cuts around
// corners repeatedly (the groin band, the palm, the shirt's neckline).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_corner.json");
    runKnownDivergenceSuite(json);
}
