// Review of slice M4 (BLOCKER): C-H1-es with a PREDECESSOR armed first.
// The Ctrl+Z that removes Edge Slice's first group pops its key-door row, and
// the row's undo restores the tool it replaced (C-M4-token-switch, gap 376);
// the redo re-arms Edge Slice with that gesture, released (§22, tasks
// 7112/7137) — whether or not the predecessor writes activation rows of its
// own (the redo scope is the pre-M4 one: kept unless the predecessor writes
// activation rows). The reviewer's differential (card M4, "Ревью"): with the
// redo scope keyed on "any predecessor", r1 left the predecessor armed and no
// point.
// Rig: the reviewer's (tests/slice_leak_helpers.d prologue, front-right chain).

import slice_leak_helpers;
import std.format : format;

void main() {}

void ctrlZ(string what)      { slKey(SL_SDLK_z, SL_KMOD_LCTRL, what); }
void ctrlShiftZ(string what) { slKey(SL_SDLK_z, SL_KMOD_LCTRL | SL_KMOD_LSHIFT, what); }
enum int[2][3] HINT_OFF = [[315, 303], [531, 355], [616, 270]];

void cell(string pred, string predTool, bool redoKept = true) {
    slPrologue(false, "polygons", &slBackAndLeft, true);
    if (pred.length) slLineUi("tool.set " ~ pred ~ " on");
    assert(slTool() == predTool, format("rig (%s): the predecessor is '%s'", pred, slTool()));
    slLineUi("tool.set mesh.edgeSliceTool on");
    const P = slFrontRightChain();
    const px = slEdgePixel(P[0][0], P[0][1], HINT_OFF[0], "p1");
    slClickDown(px[0], px[1], "c1");
    slDragUp(px[0], px[1], 0, 4, 3, "d1");
    assert(slChain().pairs.length == 1, format("rig (%s): the first gesture latched no point", pred));
    ctrlZ("z1");
    assert(slTool() == predTool, format("(%s) the first group's Ctrl+Z left tool '%s', expected the predecessor '%s'",
                                        pred, slTool(), predTool));
    ctrlShiftZ("r1");
    if (!redoKept) {
        // A predecessor that writes activation rows of its own: the row's undo
        // clears redo, as before M4 (its row, not this one, is the predecessor's
        // undo image) — the other half of the scope.
        assert(slTool() == predTool, format("(%s) the redo over a row-writing predecessor re-armed '%s' "
                                            ~ "(the scope keeps no redo there)", pred, slTool()));
        return;
    }
    assert(slTool() == "edgeSlice" && slChain().pairs.length == 1,
        format("(%s) the redo did not re-arm Edge Slice with its first gesture (§22): tool '%s', points %s",
               pred, slTool(), slTool() == "edgeSlice" ? slChain().pairs.length : 0));
    slLine("tool.set mesh.edgeSliceTool off");
}

unittest { cell("", ""); }                          // control: no predecessor
unittest { cell("edge.extrude", "edgeExtrude"); }   // writes no row: the redo stays
// Polygon Bevel writes its row since slice M3b (and applies at its arm, which
// would change the rig's mesh), so the row-writing half is pinned on the
// transform, whose arm touches no geometry.
unittest { cell("TransformMove", "xfrm", false); }
