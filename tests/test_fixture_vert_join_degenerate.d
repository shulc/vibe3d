// Tasks 1130 (measured) + 1210 (ported) -- what survives a join that consumes
// everything. Ledger row 21.
//
//   collapse_everything   collapse a whole open plate to one point: ONE FREE
//                         VERTEX is left where every face has just been
//                         dropped. We used to be left with an EMPTY mesh,
//                         because the weld's tail compaction removed the
//                         survivor as unreferenced.
//   keep_flag_on_a_pole   with the keep flag on, the two TWO-POINT remnants
//                         survive (8 faces); our kernel used to discard them
//                         (6), and our own source said the flag "is recognized
//                         but not yet honored". That sentence is now a number.
//
// THE PIN IS `vert.join`'S ALONE, and the same capture says why: it also CUTS
// every face of that plate and is left with ZERO vertices. So "a weld keeps
// its orphans" is NOT the law -- "a join leaves its joined vertex" is.
//
// Degenerate remnants are the object of study, so the face and edge counts
// carry the finding and are asserted on both sides. Both bases are open.
//
// These remnants are now real DOCUMENT state, and closing this gap meant
// making the rest of the editor able to hold them: the .v3d reader used to
// drop every face with fewer than 3 corners and to refuse outright to open a
// mesh with no polygons at all, so an 8-face fan saved and came back with 6,
// and the free-vertex document saved and would not open. Both are one-sided
// reader drops (the writer emitted both correctly all along) and both are
// fixed in `source/io/native.d`. Picking, undo/redo and the GPU upload needed
// no change -- a 2-corner polygon contributes no triangle and no ray hit,
// which is the right answer, not a fault.
//
// BOTH CASES NOW DECLARE AN EMPTY GAP and are kept, with every measured
// dimension declared a CONTROL.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/vert_join_degenerate.json");
    runCommandDivergenceSuite(json);
}
