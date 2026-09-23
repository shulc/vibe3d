// test_edge_slice_undo_delete_revert.d — task 7111 (S1-R), item 21: Ctrl+Z
// after an Edge Slice chain on a subpatch mesh must not undo old records over
// a mesh the slice left behind unrecorded.
//
// Prologue (tests/slice_leak_helpers.d): cube, top face lifted by a Move-gizmo
// drag, back and left faces deleted (8v/4f), edge selection mode, Tab
// (subpatch ON). Edge Slice, three click+drag points on the front/right
// verticals, all through /api/play-events. Before the first Ctrl+Z the state
// is printed (S0). Then K = 3 + recordedHistoryLen Ctrl+Z, each followed by a
// liveness read; only after a whole loop are the steps compared with our undo
// law. On HEAD this file kills the editor, so it is gated alone
// (`./run_test.d --exclude` in the full run, then run by itself); the
// liveness message is its red line, the editor log carries the stack.

import slice_leak_helpers;

void main() {}

unittest {
    slUndoLawWitness("polygons", &slBackAndLeft, 8, 4,
                     [[323, 302], [507, 326], [606, 271]]);
}
