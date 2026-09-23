// test_slice_tool_switch_records.d — task 7111 (S1-R), item 24 (the Slice
// tool, Shift+C): switching tools with a live cut must leave that cut in
// history as ONE Slice record, with the mesh unchanged across the switch.
//
// Prologue (tests/slice_leak_helpers.d): cube, top face lifted by a Move-gizmo
// drag, back and left faces deleted (8v/4f); block B adds Tab (subpatch ON).
// Shift+C and the line are real SDL events; W switches to the transform tool.
// Block A (subpatch OFF) stays green; block B is the red cell on HEAD: the
// tool's armed key went stale under the live subpatch preview, so the switch
// drops the cut without a record.

import slice_leak_helpers;
import std.algorithm : count;
import std.format : format;
import std.stdio : writeln;

void main() {}

void switchBlock(bool subpatchOn) {
    const tag = subpatchOn ? "ON" : "OFF";
    slPrologue(subpatchOn, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    const recordedHistoryLen = slSliceActivateAndDraw();
    const cut = slMesh();
    assert(cut.faces > 4, format("slice floor: no cut before the switch (subpatch %s): %s",
                                 tag, cut.toString));
    slKey(SL_SDLK_w, 0, "W (tool switch)");
    assert(slTool() != "slice", "slice floor: W did not switch away from Slice");
    const added = slHistoryLabels()[cast(size_t)recordedHistoryLen .. $];
    const after = slMesh();
    writeln("subpatch ", tag, ": records added by the line and the switch: ", added);
    assert(added.count("Slice") == 1 && after.canon == cut.canon,
           format("slice leak: tool switch left no history entry (subpatch %s): added %s, "
                  ~ "mesh before W %s, after W %s", tag, added, cut.toString, after.toString));
}

// Block A — subpatch OFF: green on R and F.
unittest {
    switchBlock(false);
}

// Block B — subpatch ON: predicted red on HEAD at the switch assert.
unittest {
    switchBlock(true);
}
