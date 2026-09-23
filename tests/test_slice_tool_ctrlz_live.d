// test_slice_tool_ctrlz_live.d — task 7111 (S1-R), item 24 (the Slice tool,
// Shift+C): the first Ctrl+Z during a live cut cancels that cut. The line is
// the session's first (and only) gesture, so the same press also ends the tool
// (owner decision 2026-09-23, after the reference capture, replacing the plan's
// "tool stays active"); the prologue's records stay and none is added. Whether
// the tool's own activation record is popped with it is left to the slice's
// amendment, so the history bound below admits both.
//
// Prologue (tests/slice_leak_helpers.d): cube, top face lifted by a Move-gizmo
// drag, back and left faces deleted (8v/4f). Shift+C, one line, Ctrl+Z — all
// real SDL events. Block A is subpatch OFF: the Slice tool implements none of
// the live-edit hooks on HEAD, so Ctrl+Z goes to the history instead. Listed
// among the slice's editor-killing files and gated alone; the liveness read
// comes first so a crash names itself.

import slice_leak_helpers;
import std.format : format;

void main() {}

void ctrlzBlock(bool subpatchOn) {
    const tag = subpatchOn ? "ON" : "OFF";
    slPrologue(subpatchOn, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    const prologueLabels = slHistoryLabels();
    const recordedHistoryLen = slSliceActivateAndDraw();
    const cut = slMesh();
    assert(cut.faces > 4, format("slice floor: no cut before Ctrl+Z (subpatch %s): %s",
                                 tag, cut.toString));
    const ok = slKeyTolerant(SL_SDLK_z, SL_KMOD_LCTRL, "Ctrl+Z");
    assert(ok && slAlive(), format("editor died on slice ctrl+z (subpatch %s)", tag));
    const after = slMesh();
    const len = slHistoryLen();
    const tool = slTool();
    const labels = slHistoryLabels();
    const prologueKept = labels.length >= prologueLabels.length
        && labels[0 .. prologueLabels.length] == prologueLabels;
    assert(after.canon == base.canon && prologueKept && len <= recordedHistoryLen
           && tool != "slice",
           format("slice ctrl+z did not cancel the live cut (subpatch %s): mesh %s (expected %s), "
                  ~ "history %s (prologue %s, %d after activation), tool '%s'",
                  tag, after.toString, base.toString, labels, prologueLabels,
                  recordedHistoryLen, tool));
}

// Block A — subpatch OFF: the red cell on HEAD.
unittest {
    ctrlzBlock(false);
}

// Block B — subpatch ON: same form.
unittest {
    ctrlzBlock(true);
}
