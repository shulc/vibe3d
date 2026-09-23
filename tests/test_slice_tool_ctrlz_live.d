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
// real SDL events. Block A is subpatch OFF: before task 7112 the Slice tool
// implemented none of the live-edit hooks, so Ctrl+Z went to the history
// instead; the liveness read comes first so a crash names itself. Block C
// (task 7112) witnesses the tool's `resyncSession`.

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

// Block C (task 7112, F) — the resync witness. A raw history step taken under
// a live Slice with NO cut on the mesh must re-take the session baseline, or
// the next preview restores the stale one over the undo. Two selection rows
// sit above the activation row (a selection does not drop the tool), and
// Ctrl+Z undoes the newer; the baseline taken at activation holds the
// selection from BEFORE both, the resynced one the selection after the
// first. The Slice cut keeps original vertex indices, so after the line and
// W the committed mesh still says which baseline the preview restored.
unittest {
    import std.algorithm : canFind;
    import http_client : getJson;
    slPrologue(false, "polygons", &slBackAndLeft, false);
    const base = slMesh();
    assert(base.verts == 8 && base.faces == 4,
           "slice floor: the prologue is not the 8v/4f open box: " ~ base.toString);
    slKey(SL_SDLK_c, SL_KMOD_LSHIFT, "Shift+C (Slice)");
    assert(slTool() == "slice", "slice resync floor: Shift+C did not activate the Slice tool");
    const activated = slHistoryLen();
    long[] selVerts() {
        long[] r;
        foreach (v; getJson("/api/selection")["selectedVertices"].array) r ~= v.integer;
        return r;
    }
    assert(!selVerts().canFind(0L),
           format("slice resync floor: vertex 0 is selected before the rows: %s", selVerts()));
    slCmd("mesh.select", `{"mode":"vertices","indices":[0]}`);
    slCmd("mesh.select", `{"mode":"vertices","indices":[0,1]}`);
    assert(slTool() == "slice" && slHistoryLen() == activated + 2,
           format("slice resync floor: two selection rows above the activation with Slice live "
                  ~ "(tool '%s', history %d, activation at %d): %s",
                  slTool(), slHistoryLen(), activated, slHistoryLabels()));
    slKey(SL_SDLK_z, SL_KMOD_LCTRL, "Ctrl+Z (raw step, no live cut)");
    assert(slTool() == "slice" && slHistoryLen() == activated + 1 && selVerts() == [0L],
           format("slice resync floor: Ctrl+Z did not undo exactly the newer selection row "
                  ~ "with Slice still live (tool '%s', history %d, selection %s)",
                  slTool(), slHistoryLen(), selVerts()));
    slSliceDrawLine();
    assert(slMesh().faces > 4, "slice resync floor: the line did not cut: " ~ slMesh().toString);
    slKey(SL_SDLK_w, 0, "W (commit the cut)");
    assert(slHistoryLabels().canFind("Slice"),
           format("slice resync floor: W left no Slice row: %s", slHistoryLabels()));
    assert(selVerts().canFind(0L),
           format("slice resync: stale baseline restored over undo: selection after W %s, "
                  ~ "expected vertex 0 (the state the Ctrl+Z left)", selVerts()));
}
