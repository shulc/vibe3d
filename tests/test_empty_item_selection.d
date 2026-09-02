// Task 0654 — an EMPTY item selection is legal, and every consumer that needed
// an edit target REFUSES BY NAME instead of quietly picking one.
//
// ---------------------------------------------------------------------------
// The assertion that would be worth nothing here
// ---------------------------------------------------------------------------
// "the app does not crash with an empty selection" passes for the single worst
// implementation this task can produce: one that silently substitutes layer 0.
// That implementation is not merely tolerable-looking, it is ATTRACTIVE — every
// accessor keeps returning a mesh, every panel keeps drawing, the whole suite
// stays green, and the only symptom is that edits land on an item the user did
// not select. So not one row below reads "it survived". Every row reads a
// VALUE that layer 0 would answer differently:
//
//   * `/api/layers` `active` — -1, where the substitution answers 0.
//   * `/api/model` (default layer) — an `error` naming the reason, where the
//     substitution answers the cube's 8 vertices.
//   * a mesh command — refused WITH the reason in the message, where the
//     substitution answers `status: ok` and subdivides layer 0 to 26 vertices.
//   * `tool.set` — same.
//   * the cube's own geometry after the refusal — still 8 vertices / 6 faces,
//     read through an EXPLICIT `?layer=0`, which is the only reading the
//     substitution cannot fake.
//
// ---------------------------------------------------------------------------
// The wrong implementations each row catches
// ---------------------------------------------------------------------------
//   * a viewport miss in Items mode does nothing (the pre-0654 branch)
//       -> covered by tests/test_item_click_select.d U3, not here.
//
// ---------------------------------------------------------------------------
// TASK 0671 — HOW THE STATE IS REACHED CHANGED, AND THAT IS THE FINDING
// ---------------------------------------------------------------------------
// Every row below used to drive the state with `layer.select mode:clear`. That
// does not produce it any more. 0670 read the reference's mechanism: deselecting
// MOVES an item into a cache of recently deselected elements, bucketed by item
// kind, and the edit target is the head of a walk over [current selection ++
// that cache]. So dropping the whole item selection empties the SELECTION and
// leaves the target exactly where it was — measured, and frozen in
// `tests/fixtures/edit_target_legality.json`, cell `target_set_nothing_selected`.
//
// 0654 measured the first half of that (a viewport miss empties the selection)
// and INFERRED the second. Nothing here is retracted: the absent edit target is
// still a legal state, every refusal below is still owed, and none of the values
// asserted has moved. Only the RIG moved — the state is now reached the way the
// reference's own fixture reaches it, by taking the target away rather than by
// deselecting it (`noEditTarget()` below).
//
// E1 keeps the old rig too, as the discriminating row: it asserts that a clear
// does NOT produce this state. That is the one assertion in this file that a
// pre-0671 build fails.
//   * `Document.activeIndex` keeps answering 0 for an absent primary
//       -> E1 "`/api/layers` reports active 0".
//   * the set empties but `primary` stays latched (the forbidden third state)
//       -> E1 "layer 1 still reports primary:true".
//   * an Operator command runs on the empty stand-in instead of refusing
//       -> E2 "mesh.subdivide reported ok".
//   * it refuses, but anonymously ("did not apply" with no reason)
//       -> E2 "…the message does not name a reason".
//   * `/api/model`'s `layer<0` default clamps the absent-sentinel
//       -> E3 "`/api/model` answered 8 vertices".
//   * a tool is armed over the stand-in (a create tool would build a whole
//     primitive into a mesh nobody can see)
//       -> E4 "tool.set prim.cube reported ok".
//   * emptying is not undoable
//       -> E5 "undo did not bring the selection back".
//   * undo INTO the empty state re-selects a layer (the clamp again, arriving
//     through the undo stack)
//       -> E6 "undo left layer 0 selected".
//   * `.v3d` writes `primaryLayer: 0` for an empty selection, or the reader
//     repairs -1 back to 0
//       -> E7 "the reloaded document has active 0".
//   * `Document.activeIndex` answers 0 rather than the absent-sentinel, so
//     `index:-1` on a layer command resolves onto a real layer
//       -> E9 "its name went from 'Layer 1' to 'RENAMED-BY-DEFAULT'".
//   * the foreground pass skips the layer (no primary) and the background pass
//     skips it too (its `layers.length > 1` fast path), so a single-layer
//     document goes dark
//       -> E8 "0 of 240 pixels across the model's row differ from the
//          background".

import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.file    : tempDir, exists, remove;
import std.path    : buildPath;
import std.algorithm : canFind;

void main() {}

enum string BASE = "http://localhost:8080";

private JSONValue getJson(string p) { return parseJSON(cast(string) get(BASE ~ p)); }

/// Fire a command that must SUCCEED.
private JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

/// Fire a command that must be REFUSED, and hand back the message so the
/// caller can assert what the reason SAYS. A command that succeeds here is the
/// silent-substitution failure, so the assertion names it.
private string cmdRefused(string argstring, string what) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "error",
        format("%s: `%s` reported %s. With no item selected there is no mesh "
               ~ "edit target, so this must refuse — `ok` means it found one, "
               ~ "which can only be a layer the user did not select.",
               what, argstring, j["status"].str));
    return j["message"].str;
}

/// The one sentence every no-edit-target refusal must carry. Kept as a literal
/// here rather than read from the app: a test that echoed the app's own string
/// back at it would pass whatever the app said.
enum string kReason = "no mesh item is selected: there is no mesh edit target";

private void resetCube() {
    auto r = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd(`{"id":"history.clear"}`);
}

/// `/api/layers`'s `active` — the index of the mesh edit target, -1 for none.
private int activeIndex() {
    return cast(int) getJson("/api/layers")["active"].integer;
}

private int[] selectedItems() {
    int[] outp;
    foreach (i, l; getJson("/api/layers")["layers"].array)
        if (l["selected"].type == JSONType.true_) outp ~= cast(int) i;
    return outp;
}

private int[] primaryRows() {
    int[] outp;
    foreach (i, l; getJson("/api/layers")["layers"].array)
        if (l["primary"].type == JSONType.true_) outp ~= cast(int) i;
    return outp;
}

/// Vertex count of an EXPLICITLY named layer. Explicit on purpose: `?layer=-1`
/// is the accessor under test, so reading the geometry through it would make
/// "the mesh is intact" and "the default resolved somewhere" the same reading.
private size_t vertexCountOf(int layer) {
    auto j = getJson(format("/api/model?layer=%d", layer));
    assert("error" !in j, format("/api/model?layer=%d failed: %s", layer, j.toString));
    return j["vertices"].array.length;
}

private size_t faceCountOf(int layer) {
    auto j = getJson(format("/api/model?layer=%d", layer));
    assert("error" !in j, format("/api/model?layer=%d failed: %s", layer, j.toString));
    return j["faces"].array.length;
}

/// Empty the item selection through the command layer.
///
/// TASK 0671: this no longer produces an absent edit target — it produces the
/// LATCHED one. Kept, and used by the rows that are genuinely about the
/// selection (E5, E6, E7) and by E1's discriminating row.
private void clearSelection() {
    cmd(`{"id":"layer.select","mode":"clear"}`);
}

/// Reach the state with NO mesh edit target, and leave layer 0 holding the
/// original reset cube (8 verts / 6 faces) so every row below can read it.
///
/// THE CONSTRUCTION, and why it takes three steps rather than one:
///   1. duplicate layer 0. The duplicate's `setActive` is an exclusive select
///      of the CLONE, and selecting a mesh FLUSHES the mesh bucket — so the
///      original loses its selection state entirely rather than being latched.
///      This is `edit_target_legality`'s cell `flush_is_per_item_kind`, step 2.
///   2. delete the clone. The item holding the target leaves the document, and
///      the target is derived by enumerating `layers`, so it stops being an
///      answer. Nothing is promoted in its place.
///   3. what is left is one mesh layer, unselected, with no target — which is
///      `edit_target_legality`'s cell `selection_nonempty_no_target`, step 3.
///
/// A DUPLICATE and not `layer.add`: an added layer carries no geometry, and
/// two rows here read the surviving layer's vertex count.
private void noEditTarget() {
    resetCube();
    cmd(`{"id":"layer.duplicate"}`);
    assert(getJson("/api/layers")["layers"].array.length == 2,
        "rig: the duplicate landed");
    assert(activeIndex() == 1, "rig: the clone took the edit target");
    cmd(`{"id":"layer.delete","index":1}`);
    assert(getJson("/api/layers")["layers"].array.length == 1,
        "rig: the clone is gone");
    assert(selectedItems() == [] && activeIndex() == -1,
        format("rig: nothing selected and NO edit target — selected %s "
               ~ "active %d. If this fires, the rig itself is broken and every "
               ~ "row below would be asserting refusals against a document that "
               ~ "has a target.", selectedItems(), activeIndex()));
    cmd(`{"id":"history.clear"}`);
}

/// One step of undo, through `/api/undo`.
///
/// `layer.select` is UI-undo class and strict LIFO steps it when it is the tail.
/// Every row below clears history after its Model setup so the selection change
/// it means to undo is isolated from unrelated setup history.
private void undoOk(string why) {
    auto u = parseJSON(cast(string) post(BASE ~ "/api/undo", ""));
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
}

// ---------------------------------------------------------------------------
// E1 — the state itself. Empty means EMPTY: no selected row, no primary row,
//      and an `active` that names no layer.
//
//      All three are needed. `selected == []` alone is satisfied by the
//      forbidden third state (the set emptied, the primary still latched);
//      `primary == []` alone is satisfied by an implementation that dropped the
//      pointer but left the bits; and `active` is the one a substitution has to
//      lie about, because a substituted layer 0 is a perfectly ordinary answer
//      to every other question.
// ---------------------------------------------------------------------------
unittest {
    // --- the discriminating half (task 0671): a CLEAR does not get you here --
    resetCube();
    assert(selectedItems() == [0] && activeIndex() == 0,
        "precondition: the reset document has exactly layer 0 selected + primary");
    clearSelection();
    assert(selectedItems() == [],
        format("clearing empties the item SET — selected %s", selectedItems()));
    assert(activeIndex() == 0,
        format("…and does NOT drop the edit target — it reads %d, want 0. "
               ~ "Deselecting MOVES an item into its kind's recently-deselected "
               ~ "cache, and the target is the head of a walk over [current ++ "
               ~ "that cache], so an empty item selection with a live edit "
               ~ "target is a legal state (frozen: edit_target_legality, cell "
               ~ "target_set_nothing_selected). -1 here is the pre-0671 model, "
               ~ "which inferred this half instead of measuring it.",
               activeIndex()));
    assert(getJson("/api/layers")["layers"][0]["foreground"].type == JSONType.true_,
        "…and the latched layer is FOREGROUND, not a dimmed background layer "
        ~ "that the toolpipe is nevertheless writing to");

    // --- the state itself ---------------------------------------------------
    noEditTarget();

    assert(selectedItems() == [],
        format("no item is selected — selected %s", selectedItems()));
    assert(primaryRows() == [],
        format("…and no row reports primary:true — rows reporting it are %s. "
               ~ "A non-empty answer here is a target rehomed onto a layer "
               ~ "nobody selected, which the delete path used to do.",
               primaryRows()));
    assert(activeIndex() == -1,
        format("…and `active` names no layer — it reads %d. 0 is the silent "
               ~ "substitution (a real, unrelated layer answering 'the active "
               ~ "one'); 1 is the in-process absent-sentinel leaking to the "
               ~ "wire as a plausible index.", activeIndex()));
    // Every visible layer is BACKGROUND now — the derived rule, read back.
    foreach (i, l; getJson("/api/layers")["layers"].array) {
        assert(l["background"].type == JSONType.true_,
            format("layer %d must be background with no selection state "
                   ~ "anywhere", i));
        assert(l["foreground"].type == JSONType.false_,
            format("layer %d must not ALSO read foreground — the two are arms "
                   ~ "of one classifier, not a value and its negation", i));
    }
}

// ---------------------------------------------------------------------------
// E2 — a mesh-mutating command REFUSES, NAMES the reason, and leaves the
//      geometry alone.
//
//      `mesh.subdivide` because its effect is a number, not a flag: one
//      Catmull-Clark pass takes the cube from 8 vertices to 26. So "it was
//      refused" and "it ran on the wrong layer" are two different readings of
//      the same field, and the second cannot hide behind the first.
// ---------------------------------------------------------------------------
unittest {
    noEditTarget();
    immutable size_t v0 = vertexCountOf(0);
    immutable size_t f0 = faceCountOf(0);
    assert(v0 == 8 && f0 == 6,
        format("precondition: the surviving layer is the reset cube, 8 verts / "
               ~ "6 faces, got %d / %d", v0, f0));

    auto msg = cmdRefused(`{"id":"mesh.subdivide"}`, "E2");
    assert(msg.canFind(kReason),
        format("the refusal must NAME the reason — the message was '%s', which "
               ~ "does not contain '%s'. An anonymous 'did not apply' leaves a "
               ~ "caller unable to tell 'nothing is selected' from 'the "
               ~ "operation is not valid on this geometry'.", msg, kReason));

    assert(vertexCountOf(0) == v0 && faceCountOf(0) == f0,
        format("the refused command must not have touched layer 0 — it went "
               ~ "from %d verts / %d faces to %d / %d. 26 verts is one "
               ~ "Catmull-Clark pass, i.e. the command ran on a layer nobody "
               ~ "selected.", v0, f0, vertexCountOf(0), faceCountOf(0)));
}

// ---------------------------------------------------------------------------
// E3 — `/api/model` with no explicit layer refuses rather than answering with
//      somebody's geometry.
//
//      This is the READ side of the same rule, and it is the row that a
//      substitution passes most comfortably: returning layer 0's mesh under the
//      name "the active layer" looks like success from every angle. The reading
//      that separates them is that a refusal has NO `vertices` array at all.
// ---------------------------------------------------------------------------
unittest {
    noEditTarget();

    auto j = getJson("/api/model");
    assert("error" in j,
        format("`/api/model` with no item selected must refuse — it answered "
               ~ "%d vertices instead. That is layer 0's geometry returned "
               ~ "under the name 'the active layer'.",
               ("vertices" in j) ? j["vertices"].array.length : 0));
    assert(j["error"].str.canFind(kReason),
        format("…and name the reason — got '%s'", j["error"].str));

    // The explicit form still works: refusing the DEFAULT must not make the
    // layer unreadable, or the refusal would be an outage rather than an answer.
    assert(vertexCountOf(0) == 8,
        "an explicitly named layer stays readable with nothing selected");
}

// ---------------------------------------------------------------------------
// E4 — a tool cannot be ARMED without an edit target.
//
//      `tool.set prim.cube` specifically: a create tool is the case where "the tool
//      quietly wrote into a mesh nobody can see" produces a whole primitive
//      rather than a no-op, so it is the arming that must be stopped, not the
//      drag.
// ---------------------------------------------------------------------------
unittest {
    noEditTarget();

    auto msg = cmdRefused(`{"id":"tool.set","_positional":["prim.cube"]}`, "E4");
    assert(msg.canFind(kReason),
        format("arming a tool with nothing selected must refuse BY NAME — the "
               ~ "message was '%s'", msg));

    // Selecting again lets it arm: the refusal is about the state, not a
    // permanent disabling of the tool.
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    cmd(`{"id":"tool.set","_positional":["prim.cube"]}`);
    cmd(`{"id":"tool.set","_positional":["prim.cube","off"]}`);
}

// ---------------------------------------------------------------------------
// E5 — emptying is an OPERATION, so it rolls back.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    // Two selected, so the restored state is not reproducible by "select
    // something": an undo that guessed would have to guess a SET.
    cmd(`{"id":"layer.add"}`);
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    cmd(`{"id":"layer.select","index":1,"mode":"add"}`);
    // TASK 0671: `add` does not promote — the edit target is the head of the
    // selection queue, so it stays on the FIRST-selected layer 0.
    assert(selectedItems() == [0, 1] && activeIndex() == 0,
        format("precondition: both layers selected, 0 is the target — selected "
               ~ "%s active %d", selectedItems(), activeIndex()));
    // Drop the Model entry (`layer.add`) from the stack so the clear below is
    // an all-UI tail and the single undo therefore steps ON it — see undoOk.
    cmd(`{"id":"history.clear"}`);

    clearSelection();
    assert(selectedItems() == [], "precondition: the SELECTION emptied");

    undoOk("the clear");
    assert(selectedItems() == [0, 1],
        format("undo must bring the WHOLE prior set back — selected %s. [1] "
               ~ "alone is an undo that restored only the primary.",
               selectedItems()));
    assert(activeIndex() == 0,
        format("…including which member headed the queue — active %d",
               activeIndex()));
}

// ---------------------------------------------------------------------------
// E5b (task 0671) — the undo restores the DESELECT CACHE too, not only the
//      selected bits.
//
//      The rig makes the two halves disagree: layer 1 is the edit target and
//      layer 0 is not selected at all, so a `clear` latches ONLY layer 1. Undo
//      that clear, then clear again — if the revert had put back the bits and
//      left the cache alone, the second clear would find layer 0 already in the
//      bucket from an operation that has been undone, and the target would come
//      back as layer 0.
//
//      This is the row that says the snapshot is the whole state. An undo that
//      restores a DERIVED value (which item was the target) instead of the
//      state it is derived from passes E5 and fails here.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd(`{"id":"layer.add"}`);
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    cmd(`{"id":"layer.select","index":1,"mode":"set"}`);   // flushes layer 0 out
    assert(selectedItems() == [1] && activeIndex() == 1,
        format("precondition: only layer 1 is selected and it is the target — "
               ~ "selected %s active %d", selectedItems(), activeIndex()));
    cmd(`{"id":"history.clear"}`);

    clearSelection();
    assert(selectedItems() == [] && activeIndex() == 1,
        format("the clear latches layer 1 and only layer 1 — selected %s "
               ~ "active %d", selectedItems(), activeIndex()));

    undoOk("the clear");
    assert(selectedItems() == [1] && activeIndex() == 1,
        format("undo restores the selection — selected %s active %d",
               selectedItems(), activeIndex()));

    clearSelection();
    assert(activeIndex() == 1,
        format("…and re-clearing latches layer 1 AGAIN, reading %d. 0 here is "
               ~ "an undo that restored the selected bits and left the "
               ~ "deselect cache holding a layer the undone operation put "
               ~ "there.", activeIndex()));
}

// ---------------------------------------------------------------------------
// E6 — undo back INTO the empty state.
//
//      The mirror of E5, and the sharper half: the empty state is stored as a
//      null primary, and the obvious restore path (`setActive(prevIndex)`)
//      CLAMPS an out-of-range index into a real layer. So an undo written the
//      obvious way lands on a selected layer 0 — the substitution arriving
//      through the undo stack rather than through a click.
// ---------------------------------------------------------------------------
unittest {
    // TASK 0671 — TWO layers, so the undo has a value to get WRONG. With one
    // layer the state before and after the select agree on the edit target
    // (layer 0 either way) and only the selected set moves; here the target
    // moves too, from the latched layer 1 back to layer 0 and back again.
    resetCube();
    cmd(`{"id":"layer.duplicate"}`);                 // layer 1 selected + target
    clearSelection();
    assert(selectedItems() == [] && activeIndex() == 1,
        format("precondition: nothing selected, layer 1 LATCHED — selected %s "
               ~ "active %d", selectedItems(), activeIndex()));
    cmd(`{"id":"history.clear"}`);     // all-UI tail from here — see undoOk

    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    assert(selectedItems() == [0] && activeIndex() == 0,
        "precondition: selecting layer 0 flushes the bucket and takes the target");

    undoOk("the select out of the empty-selection state");
    assert(selectedItems() == [],
        format("undoing a select made FROM the empty selection must return to "
               ~ "it — selected %s", selectedItems()));
    assert(activeIndex() == 1,
        format("…with the LATCH back on layer 1 — active %d. 0 is an undo that "
               ~ "restored the bits and left the mesh bucket flushed by the "
               ~ "select it just reverted; -1 is one that forgot the latch "
               ~ "existed.", activeIndex()));
}

// ---------------------------------------------------------------------------
// E7 — the empty selection ROUND-TRIPS through `.v3d`.
//
//      A file cannot store "nothing selected" as an absence: every layer's
//      `selected` is already false in a document that merely lost its selection
//      to a malformed write, and a reader that repairs THAT by selecting layer
//      0 would silently undo a deliberate empty. So the file states it (-1) and
//      the reader obeys it.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    // Two layers, so "active 0" is not the only possible wrong answer. DUPLICATE
    // rather than `layer.add`: an added layer carries no geometry, and the
    // `.v3d` reader rejects a vertex-less mesh — an unrelated limitation that
    // would make this row fail for a reason that is not about the selection.
    cmd(`{"id":"layer.duplicate"}`);
    clearSelection();
    // TASK 0671 — what gets saved is now the state the two halves DISAGREE on:
    // nothing selected, and layer 1 still the edit target. That is what makes
    // this row a real round-trip test instead of a test that -1 survives -1.
    assert(selectedItems() == [] && activeIndex() == 1,
        format("precondition: nothing selected, layer 1 LATCHED — selected %s "
               ~ "active %d", selectedItems(), activeIndex()));

    immutable string path = buildPath(tempDir(), "vibe3d_0654_empty.v3d");
    if (exists(path)) remove(path);
    cmd(format(`{"id":"file.save","path":%s}`, JSONValue(path).toString));
    assert(exists(path), "precondition: the save produced a file");

    // Put a DIFFERENT state back so the load has something to overwrite —
    // otherwise "the load restored it" and "the load did nothing" are one
    // reading. Layer 0, selected: both columns differ from the saved state.
    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    assert(selectedItems() == [0] && activeIndex() == 0,
        "precondition: a DIFFERENT selection AND a different target before the load");

    cmd(format(`{"id":"file.load","path":%s}`, JSONValue(path).toString));
    assert(selectedItems() == [],
        format("a document saved with nothing selected must load that way — "
               ~ "selected %s. [1] is a reader that re-SELECTS the item "
               ~ "`primaryLayer` names, which round-trips the document into a "
               ~ "different one.", selectedItems()));
    assert(activeIndex() == 1,
        format("…and the LATCHED target comes back on layer 1 — active %d. 0 "
               ~ "is the load leaving the pre-load state standing; -1 is a "
               ~ "reader that treated an unselected `primaryLayer` as no "
               ~ "target at all.", activeIndex()));
    assert(getJson("/api/layers")["layers"][1]["foreground"].type == JSONType.true_,
        "…and it reads FOREGROUND, so the restored state is the same one that "
        ~ "was saved and not merely the same index");
    assert(getJson("/api/layers")["layers"].array.length == 2,
        "the layers themselves survived — this is about the selection only");
    remove(path);
}

// ---------------------------------------------------------------------------
// E7b (task 0671) — the file can also carry NO edit target at all, and the
//      reader must not repair that into one.
// ---------------------------------------------------------------------------
unittest {
    noEditTarget();
    immutable string path = buildPath(tempDir(), "vibe3d_0671_notarget.v3d");
    if (exists(path)) remove(path);
    cmd(format(`{"id":"file.save","path":%s}`, JSONValue(path).toString));
    assert(exists(path), "precondition: the save produced a file");

    cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
    assert(activeIndex() == 0, "precondition: a target exists before the load");

    cmd(format(`{"id":"file.load","path":%s}`, JSONValue(path).toString));
    assert(selectedItems() == [] && activeIndex() == -1,
        format("a document saved with NO edit target must load that way — "
               ~ "selected %s active %d. 0 is the reader clamping a negative "
               ~ "`primaryLayer` back into range, or re-homing onto the only "
               ~ "mesh because it assumes one is always needed.",
               selectedItems(), activeIndex()));
    remove(path);
}

// ---------------------------------------------------------------------------
// E9 — an INDEX-DEFAULTED layer command refuses instead of resolving to a
//      layer nobody selected.
//
//      `layer.*` commands take `index:-1` meaning "the active layer", and that
//      default resolves through `Document.activeIndex`. So this row is the one
//      that reads the ABSENT-SENTINEL: with `activeIndex` answering `0` for a
//      missing primary — the obvious, and previously correct, choice — the
//      default silently names layer 0 and the rename lands on it.
//
//      Written with `layer.rename` because its effect is a STRING, so
//      "refused" and "renamed the wrong layer" are two different readings of
//      one field rather than a presence/absence.
//
//      This is the row M1 exists for: /api/layers spells the empty primary as
//      -1 through `hasEditTarget`, never through the sentinel, so no other
//      assertion in this file can see the sentinel change.
// ---------------------------------------------------------------------------
unittest {
    noEditTarget();
    immutable string name0 = getJson("/api/layers")["layers"][0]["name"].str;
    assert(name0.length > 0, "precondition: layer 0 has a name to lose");

    auto msg = cmdRefused(`{"id":"layer.rename","name":"RENAMED-BY-DEFAULT"}`, "E9");
    assert(msg.canFind("`index:-1` names no layer"),
        format("an index-defaulted layer command must refuse BY NAME with "
               ~ "nothing selected — the message was '%s'", msg));
    assert(getJson("/api/layers")["layers"][0]["name"].str == name0,
        format("…and must not have renamed layer 0 — its name went from '%s' "
               ~ "to '%s'. That is `activeIndex` answering 0 for an absent "
               ~ "primary and the default resolving onto a real layer.",
               name0, getJson("/api/layers")["layers"][0]["name"].str));
}

// ---------------------------------------------------------------------------
// E8 — nothing selected does NOT mean nothing drawn.
//
//      The trap is that the background pass had a `layers.length > 1` fast
//      path: on a ONE-layer document with no edit target the foreground pass
//      skips the layer and the background pass never ran, so the model
//      disappeared. A single-layer document is the only one that can see this.
//
//      TASK 0671 — TWO rows now, because the two states this file distinguishes
//      draw through DIFFERENT passes and each has to be checked:
//        * clear the selection: the layer is LATCHED, therefore foreground,
//          therefore drawn by the foreground pass;
//        * take the target away entirely (`noEditTarget`): the layer is
//          background, therefore drawn by the background pass — the pass whose
//          fast path is the actual trap.
//      Checking only the first would leave that fast path unguarded again.
//
//      The reading is a COUNT of pixels across the model's row that differ from
//      the viewport background, before and after. "Went dark" is 0.
// ---------------------------------------------------------------------------
private struct Px { int r, g, b; bool valid; }

private Px[] probeRow(int y, int x0, int x1) {
    Px[] outp;
    for (int x = x0; x < x1; x += 60) {
        immutable int xe = (x + 60 > x1) ? x1 : x + 60;
        string q = "/api/viewport/probe?cell=0&points=";
        foreach (k; x .. xe) {
            if (k > x) q ~= ";";
            q ~= format("%d,%d", k, y);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        assert(j["renders"].type == JSONType.true_,
            "the probed cell is not rendered under --test; the reading is void");
        foreach (e; j["points"].array) {
            Px p;
            if ("error" in e) { outp ~= p; continue; }
            p.r = cast(int) e["r"].integer;
            p.g = cast(int) e["g"].integer;
            p.b = cast(int) e["b"].integer;
            p.valid = true;
            outp ~= p;
        }
    }
    return outp;
}

/// How many pixels on the row differ from the row's MODAL pixel.
///
/// The modal pixel across a full viewport row is the empty background — the
/// scene occupies a minority of it — so this counts "pixels the scene painted"
/// without the test needing to know the clear colour or the shading. Counting
/// rather than colour-matching is the point: a backdrop layer is drawn DIMMED,
/// so its pixels change value while keeping their number, and only a layer that
/// is not drawn at all loses them.
private size_t paintedCount(Px[] row) {
    size_t[string] tally;
    foreach (p; row) if (p.valid) tally[format("%d,%d,%d", p.r, p.g, p.b)]++;
    string mode; size_t best = 0;
    foreach (k, v; tally) if (v > best) { best = v; mode = k; }
    size_t n = 0;
    foreach (p; row)
        if (p.valid && format("%d,%d,%d", p.r, p.g, p.b) != mode) ++n;
    return n;
}

unittest {
    resetCube();
    assert(getJson("/api/layers")["layers"].array.length == 1,
        "precondition: ONE layer — the only document shape that can go dark");

    // The cell's own size — the FBO probed by `cell=0` is exactly this, with
    // its own (0,0) origin, so no window→cell conversion is needed.
    auto c = getJson("/api/camera");
    immutable int w = cast(int) c["width"].integer;
    immutable int h = cast(int) c["height"].integer;
    immutable int row = h / 2;

    immutable size_t before = paintedCount(probeRow(row, 0, w));
    assert(before > 0,
        format("precondition: the cube paints something across row %d — %d "
               ~ "pixels differ from the background, so this row cannot "
               ~ "measure anything", row, before));

    clearSelection();

    immutable size_t latched = paintedCount(probeRow(row, 0, w));
    assert(latched * 2 >= before,
        format("with the selection cleared the layer is LATCHED and therefore "
               ~ "foreground, so it must still draw — the row went from %d "
               ~ "painted pixels to %d out of %d probed", before, latched, w));

    // …and the harder half: no edit target at all, so it draws as BACKGROUND.
    noEditTarget();
    immutable size_t after = paintedCount(probeRow(row, 0, w));
    // A PROPORTION, not `> 0`. The viewport also carries the ground grid, whose
    // pixels survive whatever happens to the layer — so "some pixel is not the
    // background" is true even with the model gone, and `after > 0` measured
    // INERT against exactly the mutation this row exists for (the background
    // pass keeping its `layers.length > 1` fast path). A backdrop is drawn
    // dimmed, so the model's pixels change VALUE and keep their COUNT; losing
    // the model halves the row's painted pixels at least.
    assert(after * 2 >= before,
        format("with no edit target the single layer must still DRAW, as "
               ~ "background — the row went from %d painted pixels to %d out "
               ~ "of %d probed. A large drop is 'everything went dark': the "
               ~ "foreground pass skipped it (no primary) and the background "
               ~ "pass skipped it too (its layers.length > 1 fast path), "
               ~ "leaving only the grid.", before, after, w));
}
