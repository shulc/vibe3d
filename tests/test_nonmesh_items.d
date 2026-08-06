// Task 0615 Stages 6/7 — non-mesh item types: the layer lifecycle commands
// and the layer list panel behave correctly WHEN a non-mesh ("empty") item
// is present in the document, and a live MIXED document survives every
// layer.*/mesh.* command (+ undo/redo), scene.reset, and the per-frame draw
// loop without a missed-publisher warning.
//
// Stage 6 was deliberately re-scoped: the `.v3d` format cannot yet persist a
// non-mesh item (that work moved to task 0616), so THIS SLICE ships the
// machinery WITHOUT any button/menu/command-argument a user could reach to
// CREATE one — see doc/nonmesh_item_types_plan.md §Stage 6. The ONLY source
// of a non-mesh item here is the test-only injector POST /api/test/layer
// (source/http_server.d + source/http_providers.d), which bypasses the
// Command/undo system entirely (it is scaffolding, not a document edit).
//
// Spec cases (plan §Stage 6 validation + §Stage 7):
//   - the injected layer shows up in /api/layers, deselected, non-primary.
//   - selecting it moves item FOCUS, never the mesh PRIMARY (§L2): the
//     selected set becomes exactly {target} ∪ {primary-after}, and the mesh
//     primary is never reclassified background.
//   - a mesh.* command still edits the mesh primary while the non-mesh item
//     is focused.
//   - /api/model?layer=N on the non-mesh layer reports an explicit error,
//     not a silent empty mesh.
//   - deleting the LAST layer that can be the mesh edit target is refused,
//     even when the document has more than one layer left (§L1).
//   - deleting the non-mesh layer succeeds; undo restores it (kind included,
//     verified BEHAVIORALLY — no `"type"` field is reported in this slice).
//   - cross-command ordering the unit tests cannot reach: delete the primary
//     while the non-mesh item is focused; reorder it above the primary then
//     delete the primary; hide the primary when the only other selected
//     layer is non-mesh (must not promote to it).
//   - scene.reset on a mixed document collapses to exactly one mesh layer.
//   - no missed-publisher warning across a mixed-document sequence.

import std.net.curl;
import std.json;
import std.conv    : to;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers (mirrors tests/test_layers.d)
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

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/undo", "")); }
JSONValue postRedo() { return parseJSON(cast(string)post(baseUrl ~ "/api/redo", "")); }

void undoOk(string why) {
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
}

void redoOk(string why) {
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo (" ~ why ~ ") failed: " ~ r.toString);
}

JSONValue getLayers()    { return getJson("/api/layers"); }
JSONValue getSelection() { return getJson("/api/selection"); }
JSONValue getChanges()   { return getJson("/api/changes"); }

size_t layerCount()  { return getLayers()["layers"].array.length; }
size_t activeLayer() { return cast(size_t)getLayers()["active"].integer; }

bool approx(double a, double b) {
    auto d = a - b;
    return (d < 0 ? -d : d) < 1e-4;
}

// ---------------------------------------------------------------------------
// The ONLY source of a non-mesh item in this slice: POST /api/test/layer.
// Bypasses the Command/undo system on purpose (test scaffolding, not a
// document edit) — see the module doc comment above.
// ---------------------------------------------------------------------------
void injectEmpty(string name, int index = -1) {
    string body_ = index >= 0
        ? `{"kind":"empty","name":"` ~ name ~ `","index":` ~ index.to!string ~ `}`
        : `{"kind":"empty","name":"` ~ name ~ `"}`;
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer", body_));
    assert(j["status"].str == "ok", "inject-layer failed: " ~ j.toString);
}

// Build [MeshA(primary,selected), Empty("E"), MeshB]. A primary. History
// cleared.
void mixedDoc() {
    resetCube();                       // 1 layer: MeshA (cube, 8v)
    cmd("layer.add name:B");           // layer 1 active, empty(0v)
    cmd("prim.cube");                  // B = cube (8v)
    cmd("layer.select index:0");       // A primary + selected again
    injectEmpty("E", 1);               // [A, E, B]
    clearHistory();
}

// ---------------------------------------------------------------------------
// Stage 6 — basic shape: the injected item is visible in /api/layers,
// deselected, non-primary.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();
    assert(layerCount() == 3, "mixedDoc must produce 3 layers");
    auto ls = getLayers()["layers"].array;
    assert(ls[1]["name"].str == "E", "the injected layer sits at index 1");
    assert(ls[1]["selected"].type == JSONType.false_, "injected layer starts deselected");
    assert(ls[1]["primary"].type == JSONType.false_, "injected layer starts non-primary");
    assert(ls[0]["primary"].type == JSONType.true_, "A is still primary");
}

unittest {
    // Hostile-input: an unknown kind token is rejected cleanly (the
    // `kindFromToken` reject-on-unknown chokepoint), not a crash / silent
    // ItemKind.Mesh fallback.
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer", `{"kind":"bogus"}`));
    assert(j["status"].str != "ok", "an unknown kind token must be rejected");
}

// ---------------------------------------------------------------------------
// Stage 6 — §L2: selecting the non-mesh item moves FOCUS, never PRIMARY. The
// selected set becomes exactly {target} ∪ {primary-after}; the mesh primary
// is never reclassified background. A mesh.* command still hits the mesh
// edit target while the non-mesh item is focused. /api/model on the
// non-mesh layer reports an explicit error, not a silent empty mesh.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                                    // [A, E, B]
    cmd("layer.select index:1 mode:set");          // exclusive-select E

    auto ls = getLayers()["layers"].array;
    assert(ls[0]["primary"].type == JSONType.true_,    "§L2: A stays primary");
    assert(ls[0]["selected"].type == JSONType.true_,   "§L2: A stays selected");
    assert(ls[0]["background"].type == JSONType.false_,
        "§L2: A must never be reclassified background by selecting a non-mesh item");
    assert(ls[1]["selected"].type == JSONType.true_,   "§L2: E becomes selected");
    assert(ls[1]["primary"].type == JSONType.false_,   "§L2: E never becomes primary");
    size_t selCount = 0;
    foreach (l; ls) if (l["selected"].type == JSONType.true_) ++selCount;
    assert(selCount == 2, "§L2: selected set == {target} ∪ {primary-after}, size 2");

    // selType promotes to "item" (SelType.Item is kind-agnostic).
    assert(getSelection()["selType"].str == "item",
        "selecting a layer (of any kind) promotes SelType.Item");

    // A mesh.* command still edits the mesh PRIMARY (A), unaffected by a
    // non-mesh item holding focus.
    cmdJson(`{"id":"mesh.move_vertex","params":{"from":[0.5,-0.5,-0.5],"to":[3.0,-0.5,-0.5]}}`);
    bool moved = false;
    foreach (v; getJson("/api/model?layer=0")["vertices"].array)
        if (approx(v.array[0].floating, 3.0)) moved = true;
    assert(moved, "mesh.* still edits the mesh primary A while E is focused");

    // /api/model?layer=1 (the non-mesh layer) reports an explicit error, not
    // a silent empty mesh (task 0615 Stage 7 crash-prevention guard).
    auto e = getJson("/api/model?layer=1");
    assert("error" in e,
        "a non-mesh layer's /api/model reports an explicit error, not a silent empty mesh");
}

// ---------------------------------------------------------------------------
// Stage 6 — §L1: deleting the LAST layer that can be the mesh edit target is
// refused, even when the document has more than one layer left. Deleting the
// non-mesh layer always succeeds.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                        // [A, E, B]
    clearHistory();

    cmd("layer.delete index:2");       // delete B (non-primary mesh) — OK
    assert(layerCount() == 2, "deleting a non-primary mesh layer succeeds");   // [A, E]

    auto r = cmdMayFail("layer.delete index:0");   // A is now the ONLY mesh layer
    assert(r["status"].str != "ok",
        "§L1: deleting the last layer that can be primary must be refused");
    assert(layerCount() == 2, "refused delete leaves the document untouched");
    assert(getLayers()["layers"].array[0]["primary"].type == JSONType.true_,
        "refused delete leaves primary untouched");

    cmd("layer.delete index:1");       // delete E (non-mesh) — always OK
    assert(layerCount() == 1, "deleting the non-mesh layer succeeds");
}

// ---------------------------------------------------------------------------
// Stage 6 — undo/redo of a delete restores the kind. No `"type"` field is
// reported over HTTP in this slice (Stage 9 is out of scope), so this is
// verified BEHAVIORALLY: the restored layer still refuses to become primary,
// and /api/model on it still reports "no mesh".
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                        // [A, E, B]
    clearHistory();

    cmd("layer.delete index:1");       // delete E
    assert(layerCount() == 2, "E deleted");         // [A, B]

    undoOk("restore the deleted non-mesh layer");
    assert(layerCount() == 3, "undo restores the deleted layer");
    assert(getLayers()["layers"].array[1]["name"].str == "E",
        "the restored layer is E, back at its original slot");

    // Redo BEFORE dispatching any other command — a fresh command clears the
    // redo stack, so the redo check must come first.
    redoOk("redo the delete of E");
    assert(layerCount() == 2, "redo removes E again");

    // Undo once more, then verify the restored layer's KIND survived
    // BEHAVIORALLY: it still refuses to become primary, and /api/model on
    // it still reports "no mesh". Dispatching `layer.select` here is fine —
    // this test is done exercising undo/redo of the delete entry itself.
    undoOk("restore E again for the kind-survival check");
    assert(layerCount() == 3);

    auto primaryBefore = activeLayer();
    cmd("layer.select index:1 mode:set");   // try to make the restored E primary
    assert(activeLayer() == primaryBefore,
        "the restored layer is still non-mesh: selecting it never moves primary");
    auto e = getJson("/api/model?layer=1");
    assert("error" in e, "the restored layer still reports no mesh — kind survived undo");
}

// ---------------------------------------------------------------------------
// Stage 7 — order-of-operations cases that cross multiple commands.
// ---------------------------------------------------------------------------

unittest { // delete the primary while the non-mesh item is focused
    mixedDoc();                             // [A, E, B]
    cmd("layer.select index:1 mode:set");   // E focused; A still primary
    clearHistory();

    cmd("layer.delete index:0");            // delete A (the primary)
    assert(layerCount() == 2, "A deleted");           // [E, B]
    auto ls = getLayers()["layers"].array;
    assert(ls[1]["primary"].type == JSONType.true_,
        "§L1: primary rehomes to the surviving MESH layer B");
    assert(ls[0]["primary"].type == JSONType.false_,
        "§L1: the non-mesh layer E never becomes primary");
}

unittest { // reorder the non-mesh item above the primary, then delete the primary
    mixedDoc();                             // [A, E, B]
    clearHistory();

    cmd("layer.reorder from:1 to:0");       // [E, A, B]; A follows by identity
    assert(activeLayer() == 1, "A's index followed the reorder (now 1)");

    cmd("layer.delete index:1");            // delete A at its new slot
    assert(layerCount() == 2, "A deleted");           // [E, B]
    auto ls = getLayers()["layers"].array;
    assert(ls[1]["primary"].type == JSONType.true_,
        "primary rehomes to B, never to the reordered E");
}

unittest { // hide the primary when the only other selected layer is non-mesh
    mixedDoc();                             // [A, E, B]; A primary+selected
    cmd("layer.select index:1 mode:add");   // A, E selected; A stays primary (E can't be)
    clearHistory();

    cmd("layer.setVisible index:0 value:false");   // hide A (the primary)
    auto ls = getLayers()["layers"].array;
    // Pre-existing (deliberately softened) semantics: hiding the ONLY
    // promotable layer still succeeds — it just cannot PROMOTE to a
    // non-mesh alternative. The load-bearing assertion here is the second
    // one: primary must never become the non-mesh E.
    assert(ls[0]["visible"].type == JSONType.false_, "the hide itself still applies");
    assert(ls[0]["primary"].type == JSONType.true_,
        "promoteAwayFromHiddenPrimary must never promote to the non-mesh E (§Q2)");
}

// ---------------------------------------------------------------------------
// Stage 7 — scene.reset on a mixed document collapses to exactly one MESH
// layer (R4), same invariant every existing test already depends on.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();
    assert(layerCount() == 3);
    resetCube();
    assert(layerCount() == 1, "reset collapses to exactly ONE layer");
    assert(getLayers()["layers"].array[0]["primary"].type == JSONType.true_,
        "the surviving layer is the mesh primary");
}

// ---------------------------------------------------------------------------
// Stage 7 — no missed-publisher warning across a mixed-document sequence
// (change_bus.missedPublishers, task 0462's counter). A non-mesh layer must
// never get a lastSeenMutVer entry (app.d's per-layer flush loops), so
// nothing about its presence should ever trip this.
// ---------------------------------------------------------------------------

unittest {
    auto before = getChanges()["missedPublishers"].integer;
    mixedDoc();
    cmd("layer.select index:1 mode:set");
    cmdJson(`{"id":"mesh.move_vertex","params":{"from":[0.5,-0.5,-0.5],"to":[2.0,-0.5,-0.5]}}`);
    cmd("layer.delete index:1");
    undoOk("restore E");
    cmd("layer.reorder from:1 to:0");
    resetCube();
    auto after = getChanges()["missedPublishers"].integer;
    assert(after == before,
        "no missed-publisher warnings across a mixed-document sequence (got "
        ~ before.to!string ~ " -> " ~ after.to!string ~ ")");
}

// ---------------------------------------------------------------------------
// Stage 6/7 — the layer list panel itself must not crash rendering a mixed
// document (kind badge, primary/focus/selected marker, delete-guard). The
// panel is hidden by default in --test (same convention as Tool Properties,
// see [[imgui_ini_test_determinism]]) — show it explicitly and let real
// frames render. A crash here would take down the whole app; a subsequent
// successful HTTP call is proof the process survived.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                             // [A, E, B] — length > 1, so the
                                             // bg-draw + snap-source loops
                                             // (ui/panels.d) are live too.
    cmd("layer.select index:1 mode:set");   // E focused, A still primary —
                                             // exercises the "@" focus marker.

    cmd("ui.layerList show");
    Thread.sleep(300.msecs);                // let several real frames draw
    cmd("ui.layerList hide");

    // The process is still alive and the document is exactly as left.
    assert(layerCount() == 3, "app survived rendering the mixed-document panel");
    assert(getLayers()["layers"].array[0]["primary"].type == JSONType.true_);
}
