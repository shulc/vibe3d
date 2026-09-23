// test_loop_slice_subpatch_session_key.d — task 7111 (S1-R), the Loop Slice
// witness for mutation M3: an armed and scrubbed loop cut must survive a live
// subpatch preview and be recorded as ONE Loop Slice record when the tool is
// switched (W), with the mesh unchanged across the switch.
//
// Prologue (tests/slice_leak_helpers.d): cube, top face lifted by a Move-gizmo
// drag, back and left faces deleted (8v/4f); block B adds Tab. The seed edge
// is the front-bottom edge, selected by position; Loop Slice arms on an LMB
// press over the viewport (selection-seeded, no hover needed), the scrub is
// held motions + release, W switches — all real SDL events. Block A (OFF)
// stays green; block B is the red cell if Loop Slice leaks on HEAD.

import slice_leak_helpers;
import http_client : getJson;
import std.json : JSONType;
import std.algorithm : count;
import std.format : format;
import std.stdio : writeln;

void main() {}

void loopBlock(bool subpatchOn) {
    const tag = subpatchOn ? "ON" : "OFF";
    slPrologue(subpatchOn, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    auto m = getJson("/api/model");
    const a = slCornerVert(m, -0.5, false, 0.5), b = slCornerVert(m, 0.5, false, 0.5);
    const e = slEdgeOf(m, a, b);
    assert(e >= 0, "slice rig: the front-bottom edge was not found");
    slCmd("mesh.select", format(`{"mode":"edges","indices":[%d]}`, e));
    slLine("tool.set mesh.loopSliceTool on");
    assert(slTool() == "loopSlice", "slice floor: Loop Slice did not activate: " ~ slTool());
    const recordedHistoryLen = slHistoryLen();

    slClickDown(475, 300, "the arming press");
    auto st = getJson("/api/tool/state");
    assert(st["armed"].type == JSONType.true_ && slMesh().faces > 4,
           format("slice floor: the press did not arm a loop cut (subpatch %s): %s",
                  tag, st.toString));
    slDragUp(475, 300, 6, 0, 4, "the scrub");
    const cut = slMesh();
    assert(cut.faces > 4, format("slice floor: no cut before the switch (subpatch %s): %s",
                                 tag, cut.toString));
    slKey(SL_SDLK_w, 0, "W (tool switch)");
    assert(slTool() != "loopSlice", "slice floor: W did not switch away from Loop Slice");
    const added = slHistoryLabels()[cast(size_t)recordedHistoryLen .. $];
    const after = slMesh();
    writeln("subpatch ", tag, ": records added by the arm, scrub and switch: ", added);
    assert(added.count("Loop Slice") == 1 && after.canon == cut.canon,
           format("loop slice leak: tool switch left no history entry (subpatch %s): added %s, "
                  ~ "mesh before W %s, after W %s", tag, added, cut.toString, after.toString));
}

// Block A — subpatch OFF: green on R and F.
unittest {
    loopBlock(false);
}

// Block B — subpatch ON.
unittest {
    loopBlock(true);
}
