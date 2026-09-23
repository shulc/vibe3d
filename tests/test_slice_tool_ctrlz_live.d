// test_slice_tool_ctrlz_live.d — task 7111 (S1-R), item 24 (the Slice tool,
// Shift+C): the first Ctrl+Z during a live cut cancels that cut. The line is
// the session's first (and only) gesture, so the same press also ends the tool
// (owner decision 2026-09-23, after the reference capture, replacing the plan's
// "tool stays active"). History: exactly the length after activation — Shift+C
// records the tool's activation (measured), the cancel consumes and adds
// nothing. Mesh/history first, the tool-off negation second, each with its
// own message; a tool-id probe before Ctrl+Z is the negation's control.
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
    const recordedHistoryLen = slSliceActivateAndDraw();
    const cut = slMesh();
    assert(cut.faces > 4, format("slice floor: no cut before Ctrl+Z (subpatch %s): %s",
                                 tag, cut.toString));
    // Positive control for the tool-off negation below: the id the Slice
    // tool publishes while its cut is live.
    assert(slTool() == "slice", "slice floor: tool id probe before Ctrl+Z: '" ~ slTool() ~ "'");
    const ok = slKeyTolerant(SL_SDLK_z, SL_KMOD_LCTRL, "Ctrl+Z");
    assert(ok && slAlive(), format("editor died on slice ctrl+z (subpatch %s)", tag));
    const after = slMesh();
    const labels = slHistoryLabels();
    assert(after.canon == base.canon && labels.length == recordedHistoryLen,
           format("slice ctrl+z did not cancel the live cut (subpatch %s): mesh %s (expected %s), "
                  ~ "history %s (%d records, %d after activation)",
                  tag, after.toString, base.toString, labels, labels.length, recordedHistoryLen));
    const tool = slTool();
    assert(tool != "slice",
           format("slice ctrl+z did not turn the tool off (subpatch %s): tool '%s'", tag, tool));
}

// Block A — subpatch OFF: the red cell on HEAD.
unittest {
    ctrlzBlock(false);
}

// Block B — subpatch ON: same form.
unittest {
    ctrlzBlock(true);
}
