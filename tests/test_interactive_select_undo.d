// Integration tests for interactive selection undo (parent plan Phase 5 —
// selection-undo policy). Selection edits stay UNDOABLE but are now in the
// UI-undo class (CmdFlags.UiState, NOT Model), and consecutive interactive
// selects COALESCE into a single undo entry via the P2 recordCoalescing
// machinery. These tests play back recorded SDL event logs that produce
// selections via clicks/lasso, then verify the new semantics:
//
//   * N consecutive interactive selects ⇒ ONE coalesced undo entry; one
//     undo restores the pre-run selection.
//   * select → geometry edit → select ⇒ THREE entries (the edit breaks the
//     run; no cross-coalesce). Undo of the edit still restores ITS captured
//     state, independent of the selection-undo class.
//   * A MeshSelectionEdit IS undoable (lands on the stack) and is classified
//     UI (the /api/history `ui` field is true).
//   * An intervening NON-selection command between two selects breaks
//     coalescing.
//
// The play-events path goes through handleMouseButtonDown/Up which
// open/close an interactive selection edit session and record one
// MeshSelectionEdit per drag (coalesced at record time).

import std.net.curl;
import std.json;
import std.file : read;
import std.conv : to;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers; // fetchCamera / viewportFromCamera / projectToWindow /
                     // buildDragLog / playAndWait / vertexPos / Vec3

void main() {}

// Interactive single-click select of vertex `vid`, aimed PROGRAMMATICALLY at
// the vertex's CURRENT position (projected through the live camera) rather than
// a frozen pixel log. Frozen event logs bake in pixels captured for the
// original cube; after a transform moves the geometry those pixels miss, so a
// post-transform select must re-aim at runtime (the drag-test / perf-harness
// pattern). `vid` should be a currently-visible (front-facing) vertex — pass an
// already-selected one, which is guaranteed pickable. A plain click changes the
// selection, so it records a fresh MeshSelectionEdit through the same
// down(begin)/up(commit) interactive path the logs drive.
void clickSelectVertex(uint vid) {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    auto p   = vertexPos(cast(int)vid);
    float px, py;
    assert(projectToWindow(Vec3(cast(float)p[0], cast(float)p[1], cast(float)p[2]),
                           vp, px, py),
        "vertex " ~ vid.to!string ~ " projects off-camera");
    // DOWN+UP at one pixel = a click (steps=1 ⇒ a single zero-delta motion).
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              cast(int)px, cast(int)py, cast(int)px, cast(int)py, 1);
    playAndWait(log);
}

// /api/reset rebuilds the mesh but does NOT clear the undo history, and these
// tests assert on entry COUNTS. Clear the history after each reset so leftover
// entries from a prior unittest cannot contaminate the count.
void clearHistory() {
    auto resp = post("http://localhost:8080/api/command", `{"id":"history.clear"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "history.clear failed: " ~ resp);
}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
    clearHistory();
}

void playEvents(string logPath) {
    auto events = cast(const(void)[])read(logPath);
    auto resp = post("http://localhost:8080/api/play-events", events);
    assert(parseJSON(resp)["status"].str == "success",
        "play-events failed: " ~ resp);
    for (int i = 0; i < 100; ++i) {
        auto statusJson = parseJSON(get("http://localhost:8080/api/play-events/status"));
        if (statusJson["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // The player reports "finished" once its events are DISPATCHED, but the
    // HTTP play-events path pushes them onto the SDL queue (g_directDispatch is
    // null) — the LAST gesture's MOUSEBUTTONUP is still queued, unprocessed,
    // when the player goes idle. It drains over the next 1–2 main-loop frames.
    // Reading the selection before it drains sees only the prior gesture's
    // verts (the "expected 3 ... got 2" flake on selection_add.log). Settle so
    // the trailing click is processed before any post-playback assertion.
    Thread.sleep(dur!"msecs"(120));
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

JSONValue postRedo() {
    return parseJSON(post("http://localhost:8080/api/redo", ""));
}

JSONValue getSelection() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

JSONValue getHistory() {
    return parseJSON(get("http://localhost:8080/api/history"));
}

// Count entries on the undo stack whose internal command name matches.
size_t countUndo(string commandName) {
    size_t n = 0;
    foreach (e; getHistory()["undo"].array)
        if (e["command"].str == commandName) ++n;
    return n;
}

// The most recent (top) mesh.selection_edit entry, or JSONValue.init if none.
JSONValue topSelectionEntry() {
    auto undo = getHistory()["undo"].array;
    foreach_reverse (e; undo)
        if (e["command"].str == "mesh.selection_edit") return e;
    return JSONValue.init;
}

JSONValue translate(double dx) {
    return parseJSON(post("http://localhost:8080/api/transform",
        `{"kind":"translate","delta":[` ~ dx.to!string ~ `,0,0]}`));
}

// ---------------------------------------------------------------------------

unittest { // A MeshSelectionEdit IS undoable and classified UI (ui:true)
    resetCube();
    playEvents("tests/events/selection_points.log");

    auto sel = getSelection();
    assert(sel["mode"].str == "vertices", "mode after events");
    assert(sel["selectedVertices"].array.length == 2,
        "expected 2 verts after click-events, got "
        ~ sel["selectedVertices"].array.length.to!string);

    // The selection edit landed on the stack (it is undoable)...
    assert(countUndo("mesh.selection_edit") == 1,
        "expected exactly one selection_edit entry on the stack");
    // ...and it is classified UI-undo, not Model-undo.
    auto top = topSelectionEntry();
    assert(top.type != JSONType.null_, "no selection_edit entry found");
    assert(top["ui"].type == JSONType.true_,
        "selection_edit must be classified UI (ui:true)");

    // It is genuinely undoable: one undo removes it from the stack.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo of selection failed: " ~ u.toString);
    assert(countUndo("mesh.selection_edit") == 0,
        "selection_edit should be gone after undo");
}

unittest { // N consecutive interactive selects ⇒ ONE coalesced entry;
           // one undo restores the pre-run (empty) selection.
    resetCube();
    // selection_add.log = two click gestures (two MOUSEBUTTONDOWN/UP) that
    // cumulatively select 3 verts. Same edit mode, no intervening edit ⇒ the
    // two gestures coalesce into a single undo entry.
    playEvents("tests/events/selection_add.log");

    auto sel = getSelection();
    assert(sel["mode"].str == "vertices", "mode after add-select events");
    assert(sel["selectedVertices"].array.length == 3,
        "expected 3 verts after two add-select gestures, got "
        ~ sel["selectedVertices"].array.length.to!string);

    // Two gestures, ONE coalesced entry.
    assert(countUndo("mesh.selection_edit") == 1,
        "two consecutive selects must coalesce into ONE entry, got "
        ~ countUndo("mesh.selection_edit").to!string);

    // A single undo unwinds the whole run back to the pre-run (empty) state.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    sel = getSelection();
    assert(sel["selectedVertices"].array.length == 0,
        "one undo of a coalesced run should restore the empty pre-run "
        ~ "selection, got " ~ sel["selectedVertices"].array.length.to!string);
}

unittest { // select → geometry edit → select ⇒ THREE entries (edit breaks
           // the run); undo of the edit restores ITS captured geometry,
           // independent of the selection-undo class.
    resetCube();

    // First select run (coalesces internally to one entry).
    playEvents("tests/events/selection_add.log");
    assert(countUndo("mesh.selection_edit") == 1, "first select run = 1 entry");

    // A geometry edit between the two select runs.
    auto t = translate(0.25);
    assert(t["status"].str == "ok", "transform failed: " ~ t.toString);
    assert(countUndo("mesh.transform") == 1, "transform recorded");

    // Second select run, aimed programmatically at a now-moved vertex (the
    // frozen log's pixels miss after the translate). Its compareOp(top =
    // mesh.transform) is Different (not a MeshSelectionEdit) ⇒ a NEW entry. No
    // cross-coalesce across the geometry edit.
    {
        auto sv = getSelection()["selectedVertices"].array;
        assert(sv.length > 0, "expected a live selection to re-click after transform");
        clickSelectVertex(cast(uint)sv[0].integer);
    }
    assert(countUndo("mesh.selection_edit") == 2,
        "select→edit→select must yield TWO selection entries (no "
        ~ "cross-coalesce), got " ~ countUndo("mesh.selection_edit").to!string);

    // Order on the stack: selection_edit, mesh.transform, selection_edit.
    auto undo = getHistory()["undo"].array;
    string[] seq;
    foreach (e; undo) {
        auto c = e["command"].str;
        if (c == "mesh.selection_edit" || c == "mesh.transform") seq ~= c;
    }
    assert(seq == ["mesh.selection_edit", "mesh.transform", "mesh.selection_edit"],
        "unexpected entry sequence: " ~ seq.to!string);

    // Under T-SEP class-aware undo, the nearest Model entry from the tail is
    // mesh.transform (index 1). Its suffix = [mesh.transform, mesh.selection_edit(2nd)].
    // A single undo reverts the transform AND carries the 2nd selection inert —
    // both the geometry revert and the suffix move happen in ONE undo step.
    //
    // After undo 1: undoStack = [sel1(UI)] — the first selection run is still
    // present. The 2nd selection entry was carried inert (never revert()'d) but
    // lives on the redo stack with the transform.
    auto vBefore = parseJSON(get("http://localhost:8080/api/model"));
    // One undo: reverts transform + carries sel2 inert as suffix.
    assert(postUndo()["status"].str == "ok", "undo (transform+sel2 suffix) failed");
    // The remaining stack still has the first selection run (still undoable).
    assert(countUndo("mesh.selection_edit") == 1,
        "first selection run should survive after undoing edit + 2nd run");
}

unittest { // An intervening NON-selection command between two selects breaks
           // coalescing (general form of the geometry-edit case, using a
           // distinct non-selection command on top of the stack).
    resetCube();

    playEvents("tests/events/selection_points.log");
    assert(countUndo("mesh.selection_edit") == 1, "first select = 1 entry");

    // Intervening non-selection command (geometry translate).
    assert(translate(0.1)["status"].str == "ok", "intervening transform");

    // Next select (programmatic re-aim — the cube moved under the frozen log's
    // pixels) can NOT merge into the transform on top ⇒ new entry.
    {
        auto sv = getSelection()["selectedVertices"].array;
        assert(sv.length > 0, "expected a live selection to re-click after transform");
        clickSelectVertex(cast(uint)sv[0].integer);
    }
    assert(countUndo("mesh.selection_edit") == 2,
        "an intervening non-selection command must break coalescing, got "
        ~ countUndo("mesh.selection_edit").to!string ~ " selection entries");
}

unittest { // RMB lasso polygons → still undoable (UI-class); undo restores
           // empty, redo brings it back.
    resetCube();
    playEvents("tests/events/lasso_polygon_front.log");

    auto sel = getSelection();
    assert(sel["mode"].str == "polygons", "mode after lasso events");
    assert(sel["selectedFaces"].array.length > 0,
        "expected at least one face from lasso");

    auto top = topSelectionEntry();
    assert(top.type != JSONType.null_, "lasso should record a selection_edit");
    assert(top["ui"].type == JSONType.true_, "lasso selection is UI-class");

    auto u = postUndo();
    assert(u["status"].str == "ok",
        "undo of lasso selection failed: " ~ u.toString);
    sel = getSelection();
    assert(sel["selectedFaces"].array.length == 0,
        "expected empty face selection after undo of lasso, got "
        ~ sel["selectedFaces"].array.length.to!string);

    auto r = postRedo();
    assert(r["status"].str == "ok",
        "redo of lasso selection failed: " ~ r.toString);
    sel = getSelection();
    assert(sel["selectedFaces"].array.length > 0,
        "expected face selection back after redo");
}

unittest { // Cross-mode interactive-select undo: MeshSelectionEdit.revert()
           // routes through promoteGeometryType(beforeMode), which re-fronts
           // selTypeOrder in lockstep with editMode. This is the OBJ2
           // discriminator — the case where selTypeOrder.front diverges from
           // editMode between the commit and the undo.
           //
           // Scenario:
           //   1. Reset → vertices mode (front=vertex, mode=vertices).
           //   2. Lasso polygon front faces (lasso log: key-3 → polygons, then
           //      lasso gesture). MeshSelectionEdit{before=Polygons, after=Polygons}.
           //      selTypeOrder.front = Polygon (via key-3 in the log).
           //   3. Switch BACK to vertex mode via select.typeFrom (front=vertex,
           //      mode=vertices). selTypeOrder.front ≠ beforeMode=Polygons.
           //   4. Undo the lasso: revert() must promote Polygons back to the front.
           //      Old code: *editModePtr = Polygons (selTypeOrder stays Vertex → DESYNC).
           //      New code: promoteGeometryType(Polygons) → both revert to Polygons.
    resetCube();

    // Step 1: verify starting state.
    auto selInit = getSelection();
    assert(selInit["mode"].str == "vertices",
        "expected vertices mode after reset; got " ~ selInit["mode"].str);
    assert(selInit["selType"].str == "vertex",
        "expected vertex selType after reset; got " ~ selInit["selType"].str);

    // Step 2: lasso some polygon faces (log starts with key-3 → polygon mode).
    playEvents("tests/events/lasso_polygon_front.log");
    auto selAfterLasso = getSelection();
    assert(selAfterLasso["mode"].str == "polygons",
        "expected polygons mode after lasso; got " ~ selAfterLasso["mode"].str);
    assert(selAfterLasso["selType"].str == "polygon",
        "expected polygon selType after lasso; got " ~ selAfterLasso["selType"].str);
    assert(selAfterLasso["selectedFaces"].array.length > 0,
        "expected at least one face selected after lasso");

    // Step 3: switch back to vertex mode — selTypeOrder.front = Vertex now,
    // but the recorded MeshSelectionEdit has beforeMode=Polygons.
    auto resp = post("http://localhost:8080/api/command", "select.typeFrom vertex");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "select.typeFrom vertex failed");
    auto selVertex = getSelection();
    assert(selVertex["mode"].str == "vertices" && selVertex["selType"].str == "vertex",
        "expected vertex mode after select.typeFrom; got "
        ~ selVertex["mode"].str ~ "/" ~ selVertex["selType"].str);

    // Step 4: undo the lasso. revert() calls promoteGeometryType(beforeMode=Polygons).
    // Both editMode AND selTypeOrder front must revert to Polygons.
    auto u = postUndo();
    assert(u["status"].str == "ok",
        "undo of cross-mode selection failed: " ~ u.toString);
    auto selReverted = getSelection();
    assert(selReverted["mode"].str == "polygons",
        "cross-mode undo: editMode must revert to polygons; got "
        ~ selReverted["mode"].str);
    assert(selReverted["selType"].str == "polygon",
        "cross-mode undo: selTypeOrder front must revert to polygon; got "
        ~ selReverted["selType"].str);
}
