// Task 0615 Stages 6/7/9 — non-mesh item types: the layer lifecycle commands
// and the layer list panel behave correctly WHEN a non-mesh ("empty") item
// is present in the document, a live MIXED document survives every
// layer.*/mesh.* command (+ undo/redo), scene.reset, and the per-frame draw
// loop without a missed-publisher warning, and the HTTP surface (Stage 9)
// reports the kind and the focus/primary distinction directly instead of
// forcing every caller to infer them behaviorally.
//
// Stage 6 was deliberately re-scoped: the `.v3d` format cannot yet persist a
// non-mesh item (that work moved to task 0616), so THIS SLICE ships the
// machinery WITHOUT any button/menu/command-argument a user could reach to
// CREATE one — see doc/nonmesh_item_types_plan.md §Stage 6. The ONLY source
// of a non-mesh item here is the test-only injector POST /api/test/layer
// (source/http_server.d + source/http_providers.d), which bypasses the
// Command/undo system entirely (it is scaffolding, not a document edit).
//
// Spec cases (plan §Stage 6 validation + §Stage 7 + §Stage 9):
//   - the injected layer shows up in /api/layers, deselected, non-primary,
//     reporting "type":"empty" with null vertexCount/faceCount/mutationVersion
//     (not 0 — 0 is a legal empty MESH and the two must stay distinguishable).
//   - selecting it moves item FOCUS, never the mesh PRIMARY (§L2): the
//     selected set becomes exactly {target} ∪ {primary-after}, the mesh
//     primary is never reclassified background, and /api/layers +
//     /api/selection both report "focused" distinctly from "primary".
//   - a mesh.* command still edits the mesh primary while the non-mesh item
//     is focused.
//   - /api/model?layer=N on the non-mesh layer reports an explicit error
//     naming the kind, not a silent empty mesh.
//   - deleting the LAST layer that can be the mesh edit target is refused,
//     even when the document has more than one layer left (§L1).
//   - deleting the non-mesh layer succeeds; undo restores it, kind included —
//     directly asserted via "type" on /api/layers (Stage 9), plus the
//     original Stage 6/7 behavioral checks (still-refuses-primary, still-no-mesh).
//   - cross-command ordering the unit tests cannot reach: delete the primary
//     while the non-mesh item is focused; reorder it above the primary then
//     delete the primary; hide the primary when the only other selected
//     layer is non-mesh (must not promote to it).
//   - scene.reset on a mixed document collapses to exactly one mesh layer.
//   - no missed-publisher warning across a mixed-document sequence.

import std.net.curl;
import std.json;
import std.conv       : to;
import std.algorithm  : canFind;
import core.thread    : Thread;
import core.time      : msecs;

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

    // Stage 9: /api/layers reports the kind directly, and the three mesh
    // counters are JSON null (not 0) for a non-mesh layer — 0 is a legal
    // empty mesh, so the two must stay distinguishable to an HTTP-only caller.
    assert(ls[0]["type"].str == "mesh", "A reports type:\"mesh\"");
    assert(ls[1]["type"].str == "empty", "E reports type:\"empty\"");
    assert(ls[2]["type"].str == "mesh", "B reports type:\"mesh\"");
    assert(ls[1]["vertexCount"].type == JSONType.null_,
        "a non-mesh layer's vertexCount is null, not 0");
    assert(ls[1]["faceCount"].type == JSONType.null_,
        "a non-mesh layer's faceCount is null, not 0");
    assert(ls[1]["mutationVersion"].type == JSONType.null_,
        "a non-mesh layer's mutationVersion is null, not 0");
    assert(ls[0]["vertexCount"].integer == 8, "A (a cube) reports a real vertexCount");
}

unittest {
    // Hostile-input: an unknown kind token is rejected cleanly (the
    // `kindFromToken` reject-on-unknown chokepoint), not a crash / silent
    // ItemKind.Mesh fallback.
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer", `{"kind":"bogus"}`));
    assert(j["status"].str != "ok", "an unknown kind token must be rejected");
}

// ---------------------------------------------------------------------------
// Stage 6 §L2, AS AMENDED BY TASK 0668: an EXCLUSIVE select of the non-mesh
// item takes the mesh edit target with it.
//
// This case used to assert the opposite — "A stays primary, A stays selected,
// A is never reclassified background, the selected set is {target} ∪
// {primary-after}, size 2". That was not a design preference: the pre-0654
// invariants demanded a non-null, selected, visible primary, so sparing the
// mesh was the only representable answer. 0654 made an absent primary legal
// and 0668 spends it, so `mode:set` now means set.
//
// The rows are inverted rather than deleted, and the COUNT is the load-bearing
// one: "E becomes selected" passed under the old law too. THREE layers exist
// here, so `1` also separates "cleared all others" from "cleared exactly one".
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                                    // [A, E, B]
    cmd("layer.select index:1 mode:set");          // exclusive-select E

    auto ls = getLayers()["layers"].array;
    assert(ls[0]["primary"].type == JSONType.false_,
        "§L2/0668: A is no longer the edit target — nothing selected can be");
    assert(ls[0]["selected"].type == JSONType.false_,
        "§L2/0668: and A is no longer selected. `true` here is the pre-0668 "
        ~ "sparing, which is the whole defect this task closed");
    assert(ls[0]["background"].type == JSONType.true_,
        "§L2/0668: so A derives as BACKGROUND — dimmed and read-only, which "
        ~ "is what an item that is no longer the edit target must look like");
    assert(ls[1]["selected"].type == JSONType.true_,   "§L2: E becomes selected");
    assert(ls[1]["primary"].type == JSONType.false_,   "§L2: E never becomes primary");
    size_t selCount = 0;
    foreach (l; ls) if (l["selected"].type == JSONType.true_) ++selCount;
    assert(selCount == 1,
        "§L2/0668: the selected set is exactly {target}, size 1 — read "
        ~ to!string(selCount));
    assert(getLayers()["active"].integer == -1,
        "…and `active` reports the absence rather than substituting a layer");

    // Stage 9: /api/layers reports "focused" distinctly from "primary" — and
    // 0668 makes them disagree in a new way: E holds the focus and NOTHING
    // holds the primary.
    assert(ls[0]["focused"].type == JSONType.false_,  "§L2: A holds no focus");
    assert(ls[1]["focused"].type == JSONType.true_,   "§L2: E holds focus but not primary");

    // selType promotes to "item" (SelType.Item is kind-agnostic).
    assert(getSelection()["selType"].str == "item",
        "selecting a layer (of any kind) promotes SelType.Item");

    // Stage 9: /api/selection's items array carries the same "type"/"focused"
    // pair as /api/layers, independently derived — the two surfaces must agree.
    auto selItems = getSelection()["items"].array;
    assert(selItems[0]["type"].str == "mesh" && selItems[1]["type"].str == "empty",
        "/api/selection reports type per item, same as /api/layers");
    assert(selItems[0]["focused"].type == JSONType.false_
        && selItems[1]["focused"].type == JSONType.true_,
        "/api/selection reports focused per item, same as /api/layers");

    // A mesh.* command now REFUSES, by name — the 0654 refusal, reached
    // through the 0668 state instead of through an empty selection.
    auto r = cmdMayFail(
        `{"id":"mesh.move_vertex","params":{"from":[0.5,-0.5,-0.5],"to":[3.0,-0.5,-0.5]}}`);
    assert(r["status"].str != "ok",
        "§L2/0668: with no edit target a mesh command refuses: " ~ r.toString);
    assert(r["message"].str.canFind("mesh edit target"),
        "…and names the reason rather than refusing anonymously — read `"
        ~ r["message"].str ~ "`");
    foreach (v; getJson("/api/model?layer=0")["vertices"].array)
        assert(!approx(v.array[0].floating, 3.0),
            "…and A really was not written — read through an explicit "
            ~ "`?layer=0`, the one reading a silent substitution could not fake");

    // /api/model?layer=1 (the non-mesh layer) reports an explicit error
    // naming the kind, not a silent empty mesh. The error string itself
    // (`"... has no mesh (kind " ~ tokenOf(lyr.kind) ~ ")"`) is Stage 7's
    // crash-prevention guard, unchanged by Stage 9 — this assertion is a
    // regression PIN for that pre-existing body, not new Stage-9 coverage
    // (review round: the earlier comment here overstated it as a Stage 9
    // requirement, but it is green with this diff reverted).
    auto e = getJson("/api/model?layer=1");
    assert("error" in e,
        "a non-mesh layer's /api/model reports an explicit error, not a silent empty mesh");
    assert(e["error"].str.canFind("empty"),
        "the error body names the kind (\"empty\"), not just \"no mesh\"");
}

// ---------------------------------------------------------------------------
// The other half of §L2, and the one 0668 did NOT change: ctrl-ADDING the
// non-mesh item moves the focus and SPARES the primary, so a mesh command
// still lands on the mesh while a non-mesh item is focused.
//
// This is the pair that stops the 0668 fix being written as "a non-mesh
// selection never has an edit target", which would break ctrl-click — where
// the user is adding to a selection, not replacing it. The `mesh.move_vertex`
// row that used to live in the case above lives here now, unchanged, because
// this is the state it was really about.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                                    // [A, E, B]
    cmd("layer.select index:0 mode:set");          // the mesh alone
    cmd("layer.select index:1 mode:add");          // ctrl-add E

    auto ls = getLayers()["layers"].array;
    assert(ls[0]["primary"].type == JSONType.true_,  "§L2: Add spares the primary");
    assert(ls[0]["selected"].type == JSONType.true_, "§L2: A stays selected under Add");
    assert(ls[0]["background"].type == JSONType.false_,
        "§L2: and is still foreground, not reclassified background");
    assert(ls[1]["selected"].type == JSONType.true_ && ls[1]["focused"].type == JSONType.true_,
        "§L2: E joins the set and takes the focus");
    size_t selCount = 0;
    foreach (l; ls) if (l["selected"].type == JSONType.true_) ++selCount;
    assert(selCount == 2,
        "§L2: Add GREW the set to {A, E}, size 2 — read " ~ to!string(selCount));

    cmdJson(`{"id":"mesh.move_vertex","params":{"from":[0.5,-0.5,-0.5],"to":[3.0,-0.5,-0.5]}}`);
    bool moved = false;
    foreach (v; getJson("/api/model?layer=0")["vertices"].array)
        if (approx(v.array[0].floating, 3.0)) moved = true;
    assert(moved, "mesh.* still edits the mesh primary A while E is focused");
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
// Stage 6/9 — undo/redo of a delete restores the kind. Stage 9 added a
// `"type"` field to /api/layers, so this is now asserted DIRECTLY rather
// than only behaviorally; the original behavioral checks (still-refuses-
// primary, /api/model still reports "no mesh") are kept as an independent
// second proof that the two surfaces agree.
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
    assert(getLayers()["layers"].array[1]["type"].str == "empty",
        "the restored layer's kind survived undo, asserted directly via \"type\"");

    // Redo BEFORE dispatching any other command — a fresh command clears the
    // redo stack, so the redo check must come first.
    redoOk("redo the delete of E");
    assert(layerCount() == 2, "redo removes E again");

    // Undo once more, then verify the restored layer's KIND survived both
    // DIRECTLY ("type") and BEHAVIORALLY: it still refuses to become
    // primary, and /api/model on it still reports "no mesh". Dispatching
    // `layer.select` here is fine — this test is done exercising undo/redo
    // of the delete entry itself.
    undoOk("restore E again for the kind-survival check");
    assert(layerCount() == 3);
    assert(getLayers()["layers"].array[1]["type"].str == "empty",
        "kind survived a second undo round-trip");

    // Try to make the restored E primary. TASK 0668: the reading changed from
    // "the primary stays where it was" to "there is no primary" — an
    // exclusive select of a kind that cannot be primary clears the edit
    // target. Either way the point stands: the restored layer never BECOMES
    // the primary, which is the kind-survival evidence this row is after.
    cmd("layer.select index:1 mode:set");
    // `activeLayer()` casts to `size_t`, which cannot carry the -1 sentinel —
    // read the raw field.
    immutable long activeAfter = getLayers()["active"].integer;
    assert(activeAfter == -1,
        "the restored layer is still non-mesh: selecting it exclusively "
        ~ "leaves NO edit target rather than making it one — read "
        ~ to!string(activeAfter));
    assert(getLayers()["layers"].array[1]["primary"].type == JSONType.false_,
        "…and specifically it did not become the primary itself");
    auto e = getJson("/api/model?layer=1");
    assert("error" in e, "the restored layer still reports no mesh — kind survived undo");
}

// ---------------------------------------------------------------------------
// Stage 9 review finding — accepted pre-existing gap, pinned rather than
// fixed: undoing the deletion of a FOCUSED non-mesh item does not restore
// focus to it. `LayerDelete` (source/commands/layer/commands.d) only
// snapshots `prevPrimary` (the mesh edit target), never `focusedItem`; its
// `revert()` re-lands on the primary via `doc.setPrimary`/`doc.setActive`,
// both of which unconditionally write `focusedItem` as part of their
// contract (document.d). This predates task 0615 — `LayerDelete` never
// tracked focus — but Stage 9's "focused" field is what makes it observable
// over HTTP, and the undo/redo test above only pins "type" surviving, not
// "focused". Pinned here so a future change to this behaviour is a
// deliberate, reviewed decision, not an accidental drift.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                             // [A, E, B]; A primary+focus
    // TASK 0668: the fixture is `add`, not `set`. The gap this case pins lives
    // in the `prevPrimary !is null` arm of `LayerDelete.revert` — `setPrimary`
    // homes the focus onto the primary — so it needs a document that HAS a
    // primary. An exclusive select of E now leaves none, which takes a
    // different arm entirely (pinned by the case just below).
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");   // E becomes focus; A stays primary
    assert(getLayers()["layers"].array[1]["focused"].type == JSONType.true_,
        "E holds focus before the delete");
    clearHistory();

    cmd("layer.delete index:1");            // delete the FOCUSED item E
    assert(layerCount() == 2, "E deleted");           // [A, B]

    undoOk("restore the deleted, previously-focused non-mesh layer");
    assert(layerCount() == 3, "undo restores E");
    auto ls = getLayers()["layers"].array;
    assert(ls[1]["name"].str == "E", "E is back at its original slot");
    assert(ls[0]["focused"].type == JSONType.true_,
        "ACCEPTED GAP: focus lands back on the mesh primary A, not on the restored E");
    assert(ls[1]["focused"].type == JSONType.false_,
        "ACCEPTED GAP: the restored E does not recover the focus it held before the delete");
}

// ---------------------------------------------------------------------------
// TASK 0668 — undoing the delete of an EXCLUSIVELY selected non-mesh item.
//
// This shape did not exist before 0668: an exclusive select of E now leaves
// the document with no edit target, so `LayerDelete.revert` takes its
// `prevPrimary is null` arm — which until this task called
// `setActive(prevActiveIndex)`. With no primary, `prevActiveIndex` IS the
// absent-sentinel `layers.length`, and `setActive` CLAMPS an out-of-range
// index into a real layer. The undo would then exclusively select the LAST
// layer, throwing away the set the revert had just restored.
//
// The wrong implementation and its reading:
//   * the `setActive(prevActiveIndex)` clamp  ->  `selected [2]` (B, an item
//     the user never touched) with `active 2`, where the answer is `[1]` and
//     `active -1`.
// ---------------------------------------------------------------------------

unittest {
    mixedDoc();                             // [A, E, B]
    cmd("layer.select index:1 mode:set");   // E alone; no edit target
    assert(getLayers()["active"].integer == -1,
        "fixture: an exclusive select of E leaves no edit target");
    clearHistory();

    cmd("layer.delete index:1");
    assert(layerCount() == 2, "E deleted");

    undoOk("restore the exclusively-selected non-mesh layer");
    assert(layerCount() == 3, "undo restores E");
    auto ls = getLayers()["layers"].array;
    assert(ls[1]["name"].str == "E", "E is back at its original slot");

    int[] sel;
    foreach (i, l; ls) if (l["selected"].type == JSONType.true_) sel ~= cast(int) i;
    assert(sel == [1],
        "the undo restored the prior set — E alone. `[2]` is the clamp "
        ~ "selecting the last layer; `[0]` is a rehome to the first mesh. "
        ~ "Read " ~ to!string(sel));
    assert(getLayers()["active"].integer == -1,
        "…and the absent edit target came back absent, read "
        ~ to!string(getLayers()["active"].integer));
    assert(ls[1]["focused"].type == JSONType.true_,
        "…with the focus on the one item that is selected");
}

// ---------------------------------------------------------------------------
// Stage 7 — order-of-operations cases that cross multiple commands.
// ---------------------------------------------------------------------------

unittest { // delete the primary while the non-mesh item is focused
    mixedDoc();                             // [A, E, B]
    // TASK 0668: `add`, not `set`. This case is about deleting the PRIMARY
    // while a non-mesh item holds the focus, and an exclusive select of E now
    // leaves no primary to delete.
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");   // E focused; A still primary
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
    // TASK 0668: `add`, not `set` — the sequence needs a live mesh edit target
    // for the `mesh.move_vertex` below, and an exclusive select of E now
    // removes it (the refusal is asserted in its own case above; this case is
    // about the missed-publisher counter, not about the selection law).
    cmd("layer.select index:1 mode:add");
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
    // TASK 0668: `add`, so BOTH markers are on screen — an exclusive select
    // of E would leave no primary and the primary marker would not be drawn
    // at all, which is the opposite of what this case wants to render.
    cmd("layer.select index:1 mode:add");   // E focused, A still primary —
                                             // exercises the "@" focus marker.

    cmd("ui.layerList show");
    Thread.sleep(300.msecs);                // let several real frames draw
    cmd("ui.layerList hide");

    // The process is still alive and the document is exactly as left.
    assert(layerCount() == 3, "app survived rendering the mixed-document panel");
    assert(getLayers()["layers"].array[0]["primary"].type == JSONType.true_);
}
