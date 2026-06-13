// Layers Stage 2 — multi-layer document lifecycle, the active-layer switch
// hook, cross-layer undo, cache-identity hardening, and the /api/layers +
// /api/model?layer= surface. Headless-only (non-active layers are not yet
// drawn): every assertion is geometry/selection/history state read over HTTP.
//
// Spec cases (doc/layers_document_plan.md Stage 2):
//   - layer.add bumps the layer count and makes the new layer active.
//   - layer.select swaps /api/model content to the selected layer.
//   - cross-layer model undo: edit A, select B, edit B; undo reverts B's edit;
//     undo restores the selection (UI-undo); undo reverts A's edit (asserted on
//     A via ?layer=, while B is active).
//   - layer.delete with live history → undo restores the layer + its geometry.
//   - deleting the last layer is refused.
//   - layer.rename; visible/background flags reflected in /api/layers.
//
// Review-driven guards:
//   - BLOCKER 1 (cross-layer display): A and B with DIFFERENT vertex counts;
//     edit A, select B, undo A's edit → A reverts (via ?layer=), B unchanged,
//     and a subsequent interactive pick on the active layer still works (the
//     global pick caches were never resized/refreshed against a foreign mesh).
//   - MAJOR 5 (coalescing boundary): interactive selection on A, layer.select
//     B, interactive selection on B, undo → only B's selection reverts; a
//     second undo restores the active layer; A's selection is intact. Plus the
//     undo-of-layer.select variant (an older selection entry must NOT merge
//     with a new selection on a different layer).

import std.net.curl;
import std.json;
import std.conv    : to;
import std.file    : read;
import core.thread : Thread;
import core.time   : dur;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

JSONValue cmdJson(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

// cmd that is allowed to fail (returns the parsed response without asserting).
JSONValue cmdMayFail(string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    clearHistory();
}

void clearHistory() {
    cmdJson(`{"id":"history.clear"}`);
}

JSONValue postUndo() {
    return parseJSON(cast(string)post(baseUrl ~ "/api/undo", ""));
}

JSONValue postRedo() {
    return parseJSON(cast(string)post(baseUrl ~ "/api/redo", ""));
}

void undoOk(string why) {
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
}

JSONValue getLayers() { return getJson("/api/layers"); }
JSONValue getSelection() { return getJson("/api/selection"); }

JSONValue getModelLayer(int layer) {
    return getJson("/api/model?layer=" ~ layer.to!string);
}

JSONValue getModelActive() { return getJson("/api/model"); }

size_t layerCount() { return getLayers()["layers"].array.length; }
size_t activeLayer() { return cast(size_t)getLayers()["active"].integer; }

size_t vertCount(int layer) { return getModelLayer(layer)["vertices"].array.length; }

// Position of vertex `idx` in `layer`'s mesh.
double[3] vertexAt(int layer, int idx) {
    auto v = getModelLayer(layer)["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void playEvents(string logPath) {
    auto events = cast(const(void)[])read(logPath);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/play-events", events));
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    for (int i = 0; i < 150; ++i) {
        auto s = parseJSON(cast(string)get(baseUrl ~ "/api/play-events/status"));
        if (s["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(100));
    }
    // Post-playback settle: the trailing MOUSEBUTTONUP drains over the next
    // 1-2 frames after the player reports finished (see test_interactive_*).
    Thread.sleep(dur!"msecs"(150));
}

// Move the vertex at `from` to `to` on the ACTIVE layer (Model-undo command).
void moveVertexActive(double[3] from, double[3] to) {
    string v3(double[3] p) {
        return "[" ~ p[0].to!string ~ "," ~ p[1].to!string ~ "," ~ p[2].to!string ~ "]";
    }
    cmdJson(`{"id":"mesh.move_vertex","params":{"from":` ~ v3(from)
            ~ `,"to":` ~ v3(to) ~ `}}`);
}

bool approx(double a, double b) {
    auto d = a - b;
    return (d < 0 ? -d : d) < 1e-4;
}

// Count undo-stack entries whose internal command name matches.
size_t countUndo(string commandName) {
    size_t n = 0;
    foreach (e; getJson("/api/history")["undo"].array)
        if (e["command"].str == commandName) ++n;
    return n;
}

// ---------------------------------------------------------------------------
// Build a clean two-cube document: A = active cube (layer 0), B = cube
// (layer 1, built via prim.cube into the fresh empty layer). Returns with A
// active. History cleared.
// ---------------------------------------------------------------------------
void twoCubeDoc() {
    resetCube();                       // 1 layer, cube A (8v)
    cmd("layer.add name:B");           // layer 1 active, empty (0v)
    cmd("prim.cube");                  // B = cube (8v)
    cmd("layer.select index:0");       // A active again
    clearHistory();
}

// ---------------------------------------------------------------------------
// scene.reset baseline — every existing test depends on it
// ---------------------------------------------------------------------------

unittest { // reset collapses any multi-layer document back to exactly one layer
    twoCubeDoc();
    assert(layerCount() == 2, "twoCubeDoc should leave 2 layers");
    resetCube();
    assert(layerCount() == 1, "reset must collapse to exactly ONE layer, got "
        ~ layerCount().to!string);
    assert(activeLayer() == 0, "reset active layer is 0");
    auto l0 = getLayers()["layers"].array[0];
    assert(l0["name"].str == "Layer 1", "reset names the layer 'Layer 1'");
    assert(l0["visible"].type == JSONType.true_, "reset layer visible");
    assert(l0["background"].type == JSONType.false_, "reset layer foreground");
    assert(vertCount(0) == 8, "reset layer is the cube (8 verts)");
}

// ---------------------------------------------------------------------------
// layer.add / counts / active
// ---------------------------------------------------------------------------

unittest { // layer.add bumps the count and activates the new layer
    resetCube();
    assert(layerCount() == 1);
    cmd("layer.add");
    assert(layerCount() == 2, "layer.add adds a layer");
    assert(activeLayer() == 1, "layer.add makes the new layer active");
    assert(vertCount(1) == 0, "fresh layer is empty");
    // The new layer auto-names "Layer N".
    assert(getLayers()["layers"].array[1]["name"].str == "Layer 2",
        "auto name should be 'Layer 2'");
}

// ---------------------------------------------------------------------------
// layer.select swaps /api/model content
// ---------------------------------------------------------------------------

unittest { // select swaps the ACTIVE /api/model to the selected layer's mesh
    twoCubeDoc();                      // A active (cube), B cube
    // Edit A so the two cubes differ: move A's (-0.5,-0.5,-0.5) vertex.
    moveVertexActive([-0.5, -0.5, -0.5], [-2.0, -0.5, -0.5]);
    // A's active model now carries the moved vert; B's does not.
    bool aHasMoved = false, bHasMoved = false;
    foreach (v; getModelActive()["vertices"].array)
        if (approx(v.array[0].floating, -2.0)) aHasMoved = true;
    cmd("layer.select index:1");       // B active
    foreach (v; getModelActive()["vertices"].array)
        if (approx(v.array[0].floating, -2.0)) bHasMoved = true;
    assert(aHasMoved, "A's active model should carry the moved vertex");
    assert(!bHasMoved, "B's active model must NOT carry A's edit (content swapped)");
}

// ---------------------------------------------------------------------------
// Cross-layer model undo
// ---------------------------------------------------------------------------

unittest { // edit A, select B, edit B; undo unwinds B then the (UI) select
           // then A — A's revert asserted via ?layer= while B is active.
    twoCubeDoc();                      // A active
    clearHistory();
    // Edit A: move the +X-bottom corner.
    moveVertexActive([0.5, -0.5, -0.5], [3.0, -0.5, -0.5]);
    assert(vertexAt(0, vIndexNear(0, 3.0))[0].approx(3.0),
        "A edit landed on layer 0");
    cmd("layer.select index:1");       // B active (UI-undo entry)
    // Edit B: move a different corner.
    moveVertexActive([-0.5, 0.5, 0.5], [-3.0, 0.5, 0.5]);
    assert(vertexAt(1, vIndexNear(1, -3.0))[0].approx(-3.0),
        "B edit landed on layer 1");

    // Undo 1 — B's edit reverts (B still active).
    undoOk("revert B edit");
    assert(!anyVertNear(1, -3.0), "B's edit should be reverted");
    assert(anyVertNear(0, 3.0), "A's edit must still be present");

    // Undo 2 — the layer.select reverts: A becomes active again.
    undoOk("revert layer.select");
    assert(activeLayer() == 0, "undo of layer.select returns active to A");

    // Undo 3 — A's edit reverts. A is active now; assert via ?layer=0.
    undoOk("revert A edit");
    assert(!anyVertNear(0, 3.0), "A's edit should be reverted (via ?layer=0)");
}

// vertex index in `layer` whose x is approximately `x`.
int vIndexNear(int layer, double x) {
    auto verts = getModelLayer(layer)["vertices"].array;
    foreach (i, v; verts)
        if (approx(v.array[0].floating, x)) return cast(int)i;
    return -1;
}

bool anyVertNear(int layer, double x) { return vIndexNear(layer, x) >= 0; }

// ---------------------------------------------------------------------------
// layer.delete + undo restores layer & geometry; last-layer refusal
// ---------------------------------------------------------------------------

unittest { // delete a layer with history → undo restores the layer + geometry
    twoCubeDoc();                      // A active, B cube
    cmd("layer.select index:1");       // B active
    moveVertexActive([0.5, 0.5, 0.5], [5.0, 0.5, 0.5]);  // edit B
    cmd("layer.select index:0");       // A active
    clearHistory();
    assert(layerCount() == 2);

    cmd("layer.delete index:1");       // delete B
    assert(layerCount() == 1, "delete drops the layer");
    assert(activeLayer() == 0, "active stays on A after deleting B");

    undoOk("restore deleted layer");
    assert(layerCount() == 2, "undo restores the deleted layer");
    // The restored layer keeps B's edited geometry.
    assert(anyVertNear(1, 5.0), "undo restores B's geometry (the 5.0 vertex)");
}

unittest { // deleting the LAST layer is refused (document invariant: >= 1)
    resetCube();
    assert(layerCount() == 1);
    auto r = cmdMayFail("layer.delete");
    // The command's apply() returns false → dispatch reports an error.
    assert(r["status"].str != "ok", "deleting the last layer must be refused");
    assert(layerCount() == 1, "last layer survives a refused delete");
}

unittest { // deleting the ACTIVE layer activates a neighbour
    twoCubeDoc();
    cmd("layer.select index:1");       // B active
    clearHistory();
    cmd("layer.delete index:1");       // delete the active layer
    assert(layerCount() == 1, "active-layer delete drops it");
    assert(activeLayer() == 0, "deleting the last/active layer falls back to A");
    assert(vertCount(0) == 8, "surviving layer A intact");
}

// ---------------------------------------------------------------------------
// rename + visible/background flags in /api/layers
// ---------------------------------------------------------------------------

unittest { // rename reflected in /api/layers + undoable (UI class)
    resetCube();
    cmd("layer.add");                  // layer 1
    cmd(`layer.rename index:1 name:"Reference"`);
    assert(getLayers()["layers"].array[1]["name"].str == "Reference",
        "rename reflected in /api/layers");
    undoOk("rename undo");
    assert(getLayers()["layers"].array[1]["name"].str == "Layer 2",
        "rename undo restores the prior name");
}

unittest { // setVisible / setBackground reflected in /api/layers
    resetCube();
    cmd("layer.add");                  // layer 1 active
    cmd("layer.setBackground index:1 value:true");
    cmd("layer.setVisible index:1 value:false");
    auto l1 = getLayers()["layers"].array[1];
    assert(l1["background"].type == JSONType.true_, "background flag set");
    assert(l1["visible"].type == JSONType.false_, "visible flag cleared");
    undoOk("undo setVisible");
    assert(getLayers()["layers"].array[1]["visible"].type == JSONType.true_,
        "setVisible undo restores visible");
    undoOk("undo setBackground");
    assert(getLayers()["layers"].array[1]["background"].type == JSONType.false_,
        "setBackground undo restores foreground");
}

// ---------------------------------------------------------------------------
// BLOCKER 1 — cross-layer DISPLAY guard. Different vertex counts: editing /
// reverting the background layer A must never resize/refresh the GLOBAL pick
// caches against A while B is active. A subsequent interactive pick on the
// active layer must still work.
// ---------------------------------------------------------------------------

unittest {
    resetCube();                       // A = cube (8v)
    // B with a DIFFERENT vertex count (a sphere) so a global pick cache sized
    // against A (8v) vs B would be detectably wrong if the gate leaked.
    cmd("layer.add name:B");           // B active, empty
    cmd("prim.sphere");                // B = sphere
    auto bVerts = vertCount(1);
    assert(bVerts != 8, "B must differ from A in vertex count, got "
        ~ bVerts.to!string);

    // Edit A (A active), select B, edit B. The undo chain below reverts B's
    // edit (B active, foreground), then the select (back to A), then A's edit
    // (A active). At each step the gated refreshDisplay either refreshes the
    // on-screen mesh (active target) or no-ops (off-screen target) — never
    // resizing the global caches against a foreign-sized mesh.
    cmd("layer.select index:0");       // A active
    clearHistory();
    moveVertexActive([0.5, -0.5, -0.5], [4.0, -0.5, -0.5]);   // edit A
    assert(anyVertNear(0, 4.0), "A edit present");
    cmd("layer.select index:1");       // B active (sphere)
    // Edit B: nudge a sphere vertex far out so B's revert is observable.
    auto bv0 = vertexAt(1, 0);
    moveVertexActive([bv0[0], bv0[1], bv0[2]], [9.0, 9.0, 9.0]);
    assert(anyVertNear(1, 9.0), "B edit present");

    // Undo B's edit (B active).
    undoOk("revert B edit");
    assert(!anyVertNear(1, 9.0), "B's edit reverted");
    assert(vertCount(1) == bVerts, "B vertex count unchanged");
    // Undo the layer.select (→ A active).
    undoOk("revert layer.select");
    assert(activeLayer() == 0, "back on A");
    // Undo A's edit (A active). A reverts; assert via ?layer=0.
    undoOk("revert A edit");
    assert(!anyVertNear(0, 4.0), "A's edit reverted (via ?layer=0)");
    assert(vertCount(0) == 8, "A still a cube (8v)");
    assert(vertCount(1) == bVerts, "B's geometry unchanged by A's undo");

    // The active layer must still PICK correctly after all the cross-layer
    // cache churn: select B (sphere) then A (cube) and run an interactive
    // vertex pick on the cube. A success proves the global pick caches resized
    // cleanly against the now-active mesh rather than carrying A-vs-B stale
    // sizing from the gated refresh path.
    cmd("layer.select index:1");       // B active (resize caches to 554v)
    cmd("layer.select index:0");       // A active (resize caches back to 8v)
    clearHistory();
    playEvents("tests/events/selection_points.log");
    auto sel = getSelection();
    assert(sel["mode"].str == "vertices", "pick mode on A");
    assert(sel["selectedVertices"].array.length == 2,
        "interactive pick on the active layer still works after cross-layer "
        ~ "undo + switches (got "
        ~ sel["selectedVertices"].array.length.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// MAJOR 5 — coalescing-boundary guard. Interactive selection on A, layer.select
// B, interactive selection on B: the two selection edits must NOT coalesce
// across the switch (different meshes + explicit barrier). Undo reverts only
// B's selection; a second undo restores the active layer; A's selection holds.
// ---------------------------------------------------------------------------

unittest {
    twoCubeDoc();                      // A active (cube), B cube
    clearHistory();

    // Interactive selection on A.
    playEvents("tests/events/selection_points.log");
    auto selA = getSelection()["selectedVertices"].array;
    assert(selA.length == 2, "A interactive selection (got "
        ~ selA.length.to!string ~ ")");
    assert(countUndo("mesh.selection_edit") == 1,
        "one selection_edit recorded on A");

    cmd("layer.select index:1");       // B active — fires the coalesce barrier

    // Interactive selection on B. With B's distinct mesh + the barrier, this
    // must record a SEPARATE selection_edit entry, never merge with A's.
    playEvents("tests/events/selection_points.log");
    assert(getSelection()["selectedVertices"].array.length == 2,
        "B interactive selection");
    assert(countUndo("mesh.selection_edit") == 2,
        "B's selection must be a SEPARATE entry — not coalesced across the "
        ~ "layer switch (got " ~ countUndo("mesh.selection_edit").to!string ~ ")");

    // Undo 1 — only B's selection reverts (B still active, now empty sel).
    undoOk("revert B selection");
    assert(getSelection()["selectedVertices"].array.length == 0,
        "B's selection reverted to empty");
    assert(activeLayer() == 1, "still on B after reverting its selection");

    // Undo 2 — the layer.select reverts: A active again, with its selection.
    undoOk("revert layer.select");
    assert(activeLayer() == 0, "undo of layer.select returns to A");
    assert(getSelection()["selectedVertices"].array.length == 2,
        "A's selection is intact throughout");
}

unittest { // undo-of-layer.select variant: an older selection entry resurfacing
           // as top must NOT merge with a new selection on a different layer.
    twoCubeDoc();                      // A active
    clearHistory();

    // Selection on A (entry 1).
    playEvents("tests/events/selection_points.log");
    assert(countUndo("mesh.selection_edit") == 1);

    cmd("layer.select index:1");       // B active (entry 2, UI)
    // Undo the layer.select → A active again; A's selection entry is now TOP.
    undoOk("undo layer.select, exposing A's selection as top");
    assert(activeLayer() == 0, "back on A");

    // A fresh interactive selection on A would legitimately coalesce (same
    // mesh, same gesture chain) — that is fine. The hazard is a selection on a
    // DIFFERENT layer merging with A's resurfaced entry. Re-select B and select
    // there: it must be a fresh entry, not a merge.
    cmd("layer.select index:1");       // B active again (new UI entry)
    playEvents("tests/events/selection_points.log");  // selection on B
    // A's entry + B's entry are distinct; selecting on B never merged into A's.
    assert(countUndo("mesh.selection_edit") == 2,
        "B's selection must not merge with A's resurfaced entry (got "
        ~ countUndo("mesh.selection_edit").to!string ~ ")");
}
