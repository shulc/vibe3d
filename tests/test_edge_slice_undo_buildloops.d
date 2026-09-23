// test_edge_slice_undo_buildloops.d — task 7111 (S1-R), item 23: the same
// undo walk as test_edge_slice_undo_delete_revert.d, over the prologue variant
// whose Delete record fails inside the delta replay's loop rebuild rather than
// in the face-mark check.
//
// The variant was chosen from the slice's grid (at most eight: delete faces or
// vertices x chain below or above the deleted index x two or three points),
// as the first that reproduced that stack: delete the VERTEX at corner
// (-0.5,-0.5,-0.5) (7 verts, 6 faces: three quads and three triangles), three
// points on the front/right verticals. The grid's results are in the task card.
// Crashes the editor on HEAD: gated alone, like the item-21 file.

import slice_leak_helpers;

void main() {}

unittest {
    slUndoLawWitness("vertices", &slBackLeftBottomCorner, 7, 6,
                     [[323, 302], [507, 326], [606, 271]]);
}
