// select.set.{store,apply,edit,rename,delete} — the cases the frozen golden
// (tests/fixtures/selection_sets.json) cannot express: thrown errors (the
// suite has no way to assert one), multi-layer apply (it reads only the
// primary's model), and a save/load round trip (the suite has no dynamic
// file-path primitive). See doc/selection_sets_plan.md Stage 3/4/6 and the
// task card doc/tasks/work/1060-selection-sets.md.
import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.format : format;
import std.file    : exists, remove;

void main() {}

alias BASE = testBaseUrl;

/// Fire a command (argstring form) that must SUCCEED.
private JSONValue cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

/// Fire a command that must be REFUSED; hand back the message.
private string cmdRefused(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "error",
        "cmd `" ~ argstring ~ "` reported ok, expected a refusal");
    return j["message"].str;
}

private void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

private JSONValue selection() { return getJson("/api/selection"); }
private JSONValue model(int layer = -1) {
    return layer < 0 ? getJson("/api/model") : getJson(format("/api/model?layer=%d", layer));
}

private void selectFaceIdx(int[] idx) {
    string j = "[";
    foreach (k, v; idx) { if (k) j ~= ","; j ~= format("%d", v); }
    j ~= "]";
    auto r = postJson("/api/command", commandBody("mesh.select", format(`{"mode":"polygons","indices":%s}`, j)));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
}

private void selectNone(string mode) {
    auto r = postJson("/api/command", commandBody("mesh.select", format(`{"mode":"%s","indices":[]}`, mode)));
    assert(r["status"].str == "ok", "select-none failed: " ~ r.toString);
}

private size_t selCount(string kind) { return selection()["selected" ~ kind].array.length; }

/// Read-only existence check via `/api/model`'s `selectionSets` block — does
/// NOT mutate the live selection, so it is safe to call between an undo and
/// a redo (unlike `select.set.apply`, whose own success would push a new
/// history entry and truncate the redo branch it is being used to verify).
private bool ownsSetName(string domain, string name) {
    auto sets = model()["selectionSets"][domain].array;
    foreach (s; sets) if (s["name"].str == name) return true;
    return false;
}

// ---------------------------------------------------------------------------
// The current-type gate (SelType.Item — no geometry domain, throw + no-op)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom polygon");
    selectFaceIdx([1]);
    cmd("select.set.store name:M");
    assert(selCount("Faces") == 1, "setup: M holds one face");

    // Switch the CURRENT TYPE to Item (layer selection) — every select.set.*
    // verb must refuse, and must not disturb the prior polygon selection.
    cmd("select.typeFrom item");
    auto msg = cmdRefused("select.set.apply name:M mode:select");
    assert(msg.length > 0, "the refusal must carry a reason");

    cmd("select.typeFrom polygon");
    assert(selCount("Faces") == 1,
        "the refused apply under Item must have changed NOTHING — "
      ~ "the prior polygon selection must survive untouched");
}

unittest {
    resetCube();
    cmd("select.typeFrom item");
    cmdRefused("select.set.store name:X");
    cmdRefused("select.set.edit name:X mode:add");
    cmdRefused("select.set.rename from:X to:Y");
    cmdRefused("select.set.delete name:X");
}

// ---------------------------------------------------------------------------
// Unknown-name errors — apply / rename / delete look up an EXISTING name;
// `edit` on a missing name CREATES instead (tested in the golden fixture).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom polygon");
    cmdRefused("select.set.apply name:Nope mode:select");
    cmdRefused("select.set.rename from:Nope to:Y");
    cmdRefused("select.set.delete name:Nope");
}

// ---------------------------------------------------------------------------
// Empty-selection scoping (task 1060 plan §Q4 correction) — a no-op ONLY for
// the two verbs whose new state comes FROM the live selection.
// ---------------------------------------------------------------------------

unittest { // store / edit on an empty selection: no-op, no history entry
    resetCube();
    cmd("select.typeFrom polygon");
    selectNone("polygons");
    auto r1 = postJson("/api/command", "select.set.store name:M");
    // `apply()` returning false surfaces as a "did not apply" error at the
    // HTTP layer, same as every other no-op command (mesh.setMaterial etc).
    assert(r1["status"].str == "error", "store on empty selection must not apply: " ~ r1.toString);
    auto r2 = postJson("/api/command", "select.set.edit name:M mode:add");
    assert(r2["status"].str == "error", "edit on empty selection must not apply: " ~ r2.toString);

    // No history entry: undo must have nothing to undo (still nothing named M).
    cmdRefused("select.set.apply name:M mode:select");
}

unittest { // apply / rename / delete act on their NAME ARGUMENT unconditionally
    resetCube();
    cmd("select.typeFrom polygon");
    selectFaceIdx([0]);
    cmd("select.set.store name:M");

    selectNone("polygons");   // Escape, in effect — the selection is now empty
    assert(selCount("Faces") == 0);

    // apply: the feature's primary path (open a file, select nothing, apply).
    cmd("select.set.apply name:M mode:select");
    assert(selCount("Faces") == 1, "apply must work with an empty live selection");

    selectNone("polygons");
    cmd("select.set.rename from:M to:R");   // must succeed with nothing selected
    cmd("select.set.apply name:R mode:select");
    assert(selCount("Faces") == 1, "rename must have kept R's membership");

    selectNone("polygons");
    cmd("select.set.delete name:R");        // must succeed with nothing selected
    cmdRefused("select.set.apply name:R mode:select");
}

// ---------------------------------------------------------------------------
// Multi-layer apply (task 1060 §Q6) — searches every FOREGROUND layer,
// selects only inside the owner(s); write verbs are primary-only (Stage 0 C2).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom polygon");
    selectFaceIdx([1]);            // one specific face on layer A (index 0)
    cmd("select.set.store name:M"); // M created on A ONLY — write verbs are primary-only
    selectNone("polygons");         // clear A's live selection WHILE A is still
                                     // primary, so the later apply is the only
                                     // thing that can put a face back — the
                                     // pre-existing selection would otherwise
                                     // make the assertion pass by coincidence.
    assert(selCount("Faces") == 0, "setup: A's selection must be clear");

    cmd("layer.add name:B");        // B becomes the new primary + sole selected layer
    selectNone("polygons");         // defensive: whatever B starts with, clear it
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
      ~ "segmentsX:1 segmentsY:1 segmentsZ:1 radius:0");   // give B real geometry
    cmd("select.typeFrom polygon");
    selectNone("polygons");         // clear whatever prim.cube may have selected
    // Re-add A to the FOREGROUND set without changing which layer is primary
    // (mirrors tests/test_change_bus.d's own `layer.select mode:add` idiom —
    // "A still the target"/here, B stays primary): this is the exact
    // "owner selected while NOT primary" cell the plan's multi-layer law was
    // measured against (cap/fin3.json f3_set_scope_primary).
    cmd("layer.select index:0 mode:add");
    // `layer.select` is an ITEM-selection command — it promotes the CURRENT
    // TYPE to `SelType.Item` (the item door every layer.* command routes
    // through), so it must be switched back to Polygon before the next
    // select.set.* verb reads `currentType()`, or the mode gate refuses.
    cmd("select.typeFrom polygon");

    // B does not own "M" at all; A does, and A is foreground-but-not-primary.
    cmd("select.set.apply name:M mode:select");

    cmd("layer.select index:0");    // make A primary so /api/selection reads it
    assert(selCount("Faces") == 1, "apply must have selected M's member on A");

    cmd("layer.select index:1");    // make B primary
    assert(selCount("Faces") == 0, "B never owned M — it must be untouched");
}

unittest { // no foreground layer owns the name -> throw, nothing changes
    resetCube();
    cmd("select.typeFrom polygon");
    cmdRefused("select.set.apply name:Ghost mode:select");
}

// ---------------------------------------------------------------------------
// Undo / redo of every verb
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom polygon");
    selectFaceIdx([2]);
    cmd("select.set.store name:M");
    assert(selection()["selectedFaces"].array.length == 1);

    cmd(`{"id":"history.undo"}`);
    // store's undo is a MeshSnapshot restore — the set must be gone again.
    // No selection-mutating call between undo and the redo below (that
    // would truncate the redo branch) — a REFUSED command does not push a
    // history entry, so this check alone is safe to make in between.
    cmdRefused("select.set.apply name:M mode:select");

    cmd(`{"id":"history.redo"}`);
    cmd("select.set.apply name:M mode:select");
    assert(selCount("Faces") == 1, "redo must recreate M");
}

unittest { // undo/redo of apply (selection-only)
    resetCube();
    cmd("select.typeFrom polygon");
    selectFaceIdx([0]);
    cmd("select.set.store name:M");
    selectFaceIdx([3]);
    assert(selCount("Faces") == 1);

    cmd("select.set.apply name:M mode:select");   // unions face 0 in
    assert(selCount("Faces") == 2);

    cmd(`{"id":"history.undo"}`);
    assert(selCount("Faces") == 1, "undo must restore the pre-apply selection");

    cmd(`{"id":"history.redo"}`);
    assert(selCount("Faces") == 2, "redo must reproduce the apply");
}

unittest { // undo/redo of rename and delete
    // Verified via `ownsSetName` (a read-only /api/model lookup) throughout —
    // `select.set.apply` between an undo and its redo would itself push a
    // new history entry and truncate the very redo branch under test.
    resetCube();
    cmd("select.typeFrom polygon");
    selectFaceIdx([4]);
    cmd("select.set.store name:M");

    cmd("select.set.rename from:M to:R");
    assert(!ownsSetName("polygon", "M") && ownsSetName("polygon", "R"));
    cmd(`{"id":"history.undo"}`);
    assert(ownsSetName("polygon", "M") && !ownsSetName("polygon", "R"),
        "undo of rename must restore the old name");
    cmd(`{"id":"history.redo"}`);
    assert(!ownsSetName("polygon", "M") && ownsSetName("polygon", "R"),
        "redo of rename must reproduce it");

    cmd("select.set.delete name:R");
    assert(!ownsSetName("polygon", "R"));
    cmd(`{"id":"history.undo"}`);
    assert(ownsSetName("polygon", "R"), "undo of delete must restore R");
    cmd(`{"id":"history.redo"}`);
    assert(!ownsSetName("polygon", "R"), "redo of delete must remove R again");
}

// ---------------------------------------------------------------------------
// `.v3d` round trip — the measured asymmetry this feature exists for: the
// SET returns, the live selection does not (g56_measured.json
// roundtrip_cell.after_reload_live_selection = 0/0/0).
// ---------------------------------------------------------------------------

unittest {
    enum string path = "/tmp/vibe3d-test-selection-sets.v3d";
    if (exists(path)) remove(path);

    resetCube();
    cmd("select.typeFrom polygon");
    selectFaceIdx([0]);            // +X face -> RIGHT, centroid (0.5,0,0)
    cmd("select.set.store name:PS");

    cmd("select.typeFrom vertex");
    // the four x=+0.5 vertices
    int[] rightVerts;
    auto verts = model()["vertices"].array;
    foreach (i, v; verts) if (v.array[0].floating > 0.4) rightVerts ~= cast(int) i;
    assert(rightVerts.length == 4, "setup: cube must have 4 vertices at x=+0.5");
    auto rsel = postJson("/api/command", commandBody("mesh.select", format(`{"mode":"vertices","indices":%s}`, rightVerts)));
    assert(rsel["status"].str == "ok");
    cmd("select.set.store name:VS");

    cmd("select.typeFrom edge");
    // the four +X edges (both endpoints at x=+0.5)
    int[] rightEdges;
    auto edges = model()["edges"].array;
    bool atRight(long vi) { return verts[cast(size_t) vi].array[0].floating > 0.4; }
    foreach (i, e; edges)
        if (atRight(e.array[0].integer) && atRight(e.array[1].integer)) rightEdges ~= cast(int) i;
    assert(rightEdges.length == 4, "setup: cube must have 4 edges wholly at x=+0.5");
    auto esel = postJson("/api/command", commandBody("mesh.select", format(`{"mode":"edges","indices":%s}`, rightEdges)));
    assert(esel["status"].str == "ok");
    cmd("select.set.store name:ES");

    cmd(format(`{"id":"file.save","params":{"path":"%s"}}`, path));
    assert(exists(path));

    resetCube();   // wipe the live scene so the reload is the only source of state
    cmd(format(`{"id":"file.load","params":{"path":"%s"}}`, path));

    // The measured contrast: the live selection is EMPTY right after reload.
    auto sel = selection();
    assert(sel["selectedVertices"].array.length == 0);
    assert(sel["selectedEdges"].array.length    == 0);
    assert(sel["selectedFaces"].array.length    == 0);

    // ...but every set survived and re-selects correctly.
    cmd("select.typeFrom polygon");
    cmd("select.set.apply name:PS mode:replace");
    assert(selCount("Faces") == 1, "polygon set must survive the round trip");

    cmd("select.typeFrom vertex");
    cmd("select.set.apply name:VS mode:replace");
    assert(selCount("Vertices") == 4, "vertex set must survive the round trip");

    cmd("select.typeFrom edge");
    cmd("select.set.apply name:ES mode:replace");
    assert(selCount("Edges") == 4, "edge set must survive the round trip");

    // The raw JSON shape assertion (Stage 4 mutation: persisting edge
    // members by INDEX instead of vertex PAIR must redden this immediately).
    import std.file : readText;
    auto raw = parseJSON(readText(path));
    auto layerSets = raw["layers"].array[0]["mesh"]["selectionSets"];
    auto esMembers = layerSets["edge"].array[0]["members"].array;
    assert(esMembers.length == 4);
    foreach (m; esMembers)
        assert(m.array.length == 2,
            "edge-set members must be written as [a,b] vertex-index PAIRS, "
          ~ "not a bare edge index — got " ~ m.toString);

    if (exists(path)) remove(path);
}
