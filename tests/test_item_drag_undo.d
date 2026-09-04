// Task 0614 Phase 4 — item-transform undo, driven by REAL gizmo drags.
//
// Deliberately NOT `tool.attr` + `tool.doApply`: that headless path is
// backed by ToolDoApplyCommand (commands/tool/do_apply.d), which records
// its OWN undo entry via a whole-`MeshSnapshot` capture/restore — a
// mechanism that never reads or writes `Layer.xform`, so its revert() never
// touches the item's transform. This is NOT a silent no-op, though (S3,
// 0614 review): ToolDoApplyCommand.apply() still records a real undo entry
// (applyHeadless() returns true for an item-mode edit), so a later
// undo/redo still POPS/PUSHES that entry — it just restores nothing on the
// document, desyncing the undo stack from what's actually on screen. That
// command is not reachable from the UI (its only references are its own
// name and its registration; the panel's import of it is unused) but IS
// reachable from HTTP, scripts, macros and script replay — a real, named
// follow-up (doc/tasks/work/0614-item-mode-transform.md), not fixed here.
// It never calls beginEdit()/commitEdit() at all. This file's whole job is
// proving the tool's OWN per-gesture undo path (beginEdit/commitEdit ->
// LayerXformEdit -> RunMergeable -> CommandHistory.consolidate), which is
// reachable only through the interactive drag lifecycle (begin*DragSession
// / commitGesture / commitEdit) — so every case here drives a real
// mouse-down/motion/up sequence via drag_helpers.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math  : fabs;
import std.conv  : to;
import std.format: format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

JSONValue history() { return parseJSON(cast(string)get(BASE ~ "/api/history")); }

JSONValue layerXform(int layer = 0) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/layers"));
    return j["layers"].array[layer]["xform"];
}

double xformX(JSONValue x)    { return x["pos"].array[0].floating; }
double xformRotY(JSONValue x) { return x["rot"].array[1].floating; }

// Raw `/api/undo`/`/api/redo` POST directly to `history.undo()`/`.redo()` —
// fine for a POST-boundary undo (no tool active), but it does NOT call
// resyncSession() on a still-active tool (that only happens via
// EditSession.navigate(), which the raw HTTP undo endpoint bypasses
// entirely — confirmed against source/http_providers.d's
// `setUndoHandler(() { return history.undo(); })`, a bare call with no
// navigate()/resync in between). A genuine Ctrl+Z keypress routes through
// app.d's shortcuts.yaml -> navHistory(true) -> EditSession.navigate(),
// which DOES call resyncSession() — the mechanism R13 depends on. Mirrors
// the proven recipe in test_undo_resync_golden.d. Used for test 3 below
// (mid-run, tool still active); tests 1/2 use the raw endpoint since no
// tool is active at their undo point (post tool.set off), where the two
// are equivalent.
enum int SDLK_z     = 122;
enum int KMOD_LCTRL = 0x0040;

void playCtrlZ(Viewport vp) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
      ~ `{"t":60.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}`,
        vp.x, vp.y, vp.width, vp.height, SDLK_z, KMOD_LCTRL, SDLK_z, KMOD_LCTRL);
    playAndWait(log);
}

void doUndo() {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("history.undo")));
    assert(r["status"].str == "ok", "/api/undo failed: " ~ r.toString);
}
void doRedo() {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/redo", ""));
    assert(r["status"].str == "ok", "/api/redo failed: " ~ r.toString);
}

// One X-arrow drag on the item's world pivot (origin, for a fresh cube).
void dragMoveX(Viewport vp, int pixels = 40) {
    Vec3 pivot = Vec3(0, 0, 0);
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    int x1 = gx + cast(int)(pixels * ux);
    int y1 = gy + cast(int)(pixels * uy);
    auto log = buildDragLog(vp.x, vp.y, vp.width, vp.height, gx, gy, x1, y1);
    playAndWait(log);
}

// -----------------------------------------------------------------------
// 1. One drag = one undo entry (after the tool-drop boundary), not
//    in-session; undo restores the exact prior xform; redo restores it back.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.select index:0");

    auto before = layerXform(0);
    long undoCountBefore = history()["undo"].array.length;

    post(BASE ~ "/api/script", "tool.set move");
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    dragMoveX(vp);
    post(BASE ~ "/api/script", "tool.set move off");   // tool drop = run boundary

    auto after = layerXform(0);
    assert(!approx(xformX(after), xformX(before)),
        "sanity: the drag must have moved pos.x");

    auto h = history();
    long undoCountAfter = h["undo"].array.length;
    assert(undoCountAfter == undoCountBefore + 2,
        format("one arm plus one drag must surface exactly TWO undo rows, before=%d after=%d",
               undoCountBefore, undoCountAfter));
    auto topEntry = h["undo"].array[$ - 1];
    assert(topEntry["inSession"].type == JSONType.FALSE,
        "the surviving entry must NOT be flagged inSession after the boundary — "
        ~ topEntry.toString);

    doUndo();
    auto reverted = layerXform(0);
    assert(approx(xformX(reverted), xformX(before), 1e-6),
        "undo must restore the EXACT prior pos.x — expected " ~ before["pos"].toString
        ~ " got " ~ reverted["pos"].toString);

    doRedo();
    auto redone = layerXform(0);
    assert(approx(xformX(redone), xformX(after), 1e-6),
        "redo must restore the exact post-drag pos.x");
}

// -----------------------------------------------------------------------
// 2. Two consecutive drags in ONE activation = ONE surviving entry after
//    the boundary; its undo restores the PRE-FIRST-DRAG pose.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.select index:0");

    auto before = layerXform(0);
    long undoCountBefore = history()["undo"].array.length;

    post(BASE ~ "/api/script", "tool.set move");
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    dragMoveX(vp, 30);
    auto afterDrag1 = layerXform(0);
    dragMoveX(vp, 30);   // second gesture, SAME activation (no tool.set off yet)
    auto afterDrag2 = layerXform(0);
    post(BASE ~ "/api/script", "tool.set move off");   // boundary: consolidate

    assert(!approx(xformX(afterDrag1), xformX(before)), "sanity: drag 1 moved pos.x");
    assert(!approx(xformX(afterDrag2), xformX(afterDrag1)), "sanity: drag 2 moved pos.x further");

    auto h = history();
    long undoCountAfter = h["undo"].array.length;
    assert(undoCountAfter == undoCountBefore + 2,
        format("two consecutive drags in one activation must surface the arm plus "
             ~ "ONE consolidated edit, before=%d after=%d", undoCountBefore, undoCountAfter));

    doUndo();
    auto reverted = layerXform(0);
    assert(approx(xformX(reverted), xformX(before), 1e-6),
        "the ONE consolidated entry's undo must restore the PRE-FIRST-DRAG pose — "
        ~ "expected " ~ before["pos"].toString ~ " got " ~ reverted["pos"].toString);
}

// -----------------------------------------------------------------------
// 3. A mid-run undo (before the tool-drop boundary) steps exactly ONE
//    gesture, and the following drag in the SAME activation starts from
//    the reverted pose (R13 — the resyncSession()/resetRun() rebake).
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.select index:0");

    auto initial = layerXform(0);
    long undoCountBefore = history()["undo"].array.length;

    post(BASE ~ "/api/script", "tool.set move");
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    dragMoveX(vp, 25);                      // gesture 1
    auto afterDrag1 = layerXform(0);
    dragMoveX(vp, 25);                      // gesture 2, same activation
    auto afterDrag2 = layerXform(0);
    assert(!approx(xformX(afterDrag2), xformX(afterDrag1)),
        "sanity: gesture 2 moved pos.x further than gesture 1");

    // Two tagged in-session entries exist now (no boundary yet).
    long undoCountMidRun = history()["undo"].array.length;
    assert(undoCountMidRun == undoCountBefore + 3,
        format("mid-run: expected one arm plus 2 tagged in-session entries, got %d new",
               undoCountMidRun - undoCountBefore));

    playCtrlZ(vp);   // mid-run undo, tool STILL ACTIVE — steps exactly gesture 2
                     // AND resyncs the tool's baseline (R13); a raw /api/undo
                     // would revert the xform but leave the tool's cached run
                     // baseline stale (see doUndo()'s doc comment above).
    auto afterMidRunUndo = layerXform(0);
    assert(approx(xformX(afterMidRunUndo), xformX(afterDrag1), 1e-6),
        "a mid-run undo must step exactly ONE gesture, landing back at gesture "
        ~ "1's end state — expected " ~ afterDrag1["pos"].toString
        ~ " got " ~ afterMidRunUndo["pos"].toString);

    // gesture 3, SAME activation, SAME pixel motion as gesture 1 — if the
    // tool correctly re-baselined off the reverted state (R13), this
    // reproduces gesture 1's OWN delta a second time, landing at
    // gesture1-end + (gesture1-end - initial). If R13 were broken (a stale
    // run baseline / un-reset run-absolute total surviving the undo), this
    // would instead compose on top of the DISCARDED gesture-2 state and
    // land far past that.
    dragMoveX(vp, 25);                      // gesture 3
    auto afterDrag3 = layerXform(0);
    post(BASE ~ "/api/script", "tool.set move off");

    double gesture1Delta = xformX(afterDrag1) - xformX(initial);
    double expectedX     = xformX(afterMidRunUndo) + gesture1Delta;
    assert(approx(xformX(afterDrag3), expectedX, 5e-2),
        format("gesture 3 must start from the REVERTED pose (R13) — expected "
             ~ "~%.4f (afterMidRunUndo + gesture1's own delta), got %.4f "
             ~ "(afterDrag1=%.4f afterDrag2=%.4f)",
               expectedX, xformX(afterDrag3), xformX(afterDrag1), xformX(afterDrag2)));
    // The discriminating wrong answer: continuing from the discarded
    // gesture-2 baseline would land near afterDrag2 + gesture1Delta, a
    // clearly different (larger) number than expectedX.
    assert(!approx(xformX(afterDrag3), xformX(afterDrag2) + gesture1Delta, 5e-2),
        "gesture 3 must NOT have composed onto the discarded gesture-2 state");
}

// -----------------------------------------------------------------------
// 4. BLOCKER (0614 review) — a PANEL rotate edit in item mode (NOT a gizmo
//    drag) must still create exactly ONE undo entry at the tool-drop
//    boundary, and undo must restore the exact prior rotation.
//
//    `tool.beginSession` (test-only, commands/tool/begin_session.d) +
//    bare `tool.attr` simulates a panel value edit: production reaches the
//    identical reEvaluate() seam from the forms-engine transform panel on
//    every RX/RY/RZ/SX/SY/SZ keystroke (xfrm_transform.d — the form "OWNS
//    ALL the TRS value rows ... drives them through the reEvaluate() seam"
//    comment above XfrmTransformTool.drawProperties). Deliberately NOT
//    `tool.doApply`: that goes through ToolDoApplyCommand, a completely
//    different (and, per S3 in the task log, item-blind) undo path — this
//    test is specifically about the TOOL's own per-gesture commit, reached
//    only via an open live session, which is exactly what the blocker
//    broke for Rotate/Scale.
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.select index:0");

    auto before = layerXform(0);
    long undoCountBefore = history()["undo"].array.length;

    cmd("tool.set rotate on");
    cmd("tool.beginSession");      // test-only live-session primer
    cmd("tool.attr rotate RY 40"); // panel-style edit — the blocker's exact seam
    cmd("tool.set rotate off");    // tool drop = commit boundary

    auto after = layerXform(0);
    assert(!approx(xformRotY(after), xformRotY(before)),
        "sanity: the panel rotate must have changed rot.y");

    auto h = history();
    long undoCountAfter = h["undo"].array.length;
    assert(undoCountAfter == undoCountBefore + 2,
        format("a panel rotate edit must surface one arm plus exactly ONE edit "
             ~ "(the blocker regression added no edit) — before=%d after=%d",
               undoCountBefore, undoCountAfter));

    doUndo();
    auto reverted = layerXform(0);
    assert(approx(xformRotY(reverted), xformRotY(before), 1e-4),
        "undo must restore the exact pre-edit rot.y — expected "
        ~ before["rot"].toString ~ " got " ~ reverted["rot"].toString);
}

// -----------------------------------------------------------------------
// 5. S2 (0614 review) — an in-session Ctrl+Z DURING an open item panel
//    session (before the tool-drop boundary) must cancel the edit IN
//    PLACE on the FIRST undo — restoring rot.y immediately, recording
//    nothing new — not the second (the phantom-mutation-bump symptom the
//    review measured: a broken cancel left the item edit applied, and the
//    NEXT update() tick silently committed it instead of reverting it).
// -----------------------------------------------------------------------

unittest {
    resetCube();
    cmd("layer.select index:0");

    auto before = layerXform(0);
    long undoCountBefore = history()["undo"].array.length;

    cmd("tool.set rotate on");
    cmd("tool.beginSession");
    cmd("tool.attr rotate RY 40");

    auto midEdit = layerXform(0);
    assert(!approx(xformRotY(midEdit), xformRotY(before)),
        "sanity: the panel rotate must have changed rot.y before cancel");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    playCtrlZ(vp);   // in-session cancel, tool STILL ACTIVE — must hit
                     // cancelUncommittedEdit(), not history.undo()

    auto afterFirstUndo = layerXform(0);
    assert(approx(xformRotY(afterFirstUndo), xformRotY(before), 1e-4),
        "S2: the FIRST Ctrl+Z during an open item panel session must "
        ~ "restore rot.y immediately — expected " ~ before["rot"].toString
        ~ " got " ~ afterFirstUndo["rot"].toString);

    // The discriminating wrong answer (the S2 bug): the first Ctrl+Z leaves
    // rot.y at the EDITED value (cancel silently failed to revert the
    // item), and a phantom mutation-version bump makes the NEXT update()
    // tick commit the pending edit instead — so a SECOND undo would be the
    // one that actually reverts. Assert it plainly wrong here rather than
    // only asserting the right answer above.
    assert(!approx(xformRotY(afterFirstUndo), xformRotY(midEdit), 1e-4),
        "the first Ctrl+Z must NOT leave rot.y at the edited value");

    // An in-session cancel must record NOTHING on the undo stack.
    long undoCountAfterCancel = history()["undo"].array.length;
    assert(undoCountAfterCancel == undoCountBefore + 1,
        format("an in-session cancel must record no edit and leave only the surfaced arm — before=%d after=%d",
               undoCountBefore, undoCountAfterCancel));

    cmd("tool.set rotate off");
    long undoCountAfterDrop = history()["undo"].array.length;
    assert(undoCountAfterDrop == undoCountBefore + 1,
        "dropping the tool after a fully-cancelled session must leave only "
        ~ "the surfaced arm row");
}
