// Item (layer) selection — selection-types #4 Stage 2a.
//
// Exercises the multi-select mutators surfaced through `layer.select`'s uniform
// `mode` arg ({set,add,remove,toggle}), the SET + PRIMARY invariants, the
// hide-primary promotion, the `SelType.Item`-becomes-current wiring, and the
// UI-undo restoration of the full selection set + primary.
//
// All assertions are read over HTTP — `/api/layers` now reports per-layer
// `selected` + which is `primary`, `/api/selection` reports the current
// `selType`. Stage 2a is behaviour-neutral on snap/draw (the stored background
// bool is still authoritative), so this test only inspects the new DATA state.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

JSONValue cmdMayFail(string argstring) {
    return parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
}

JSONValue cmdJson(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmdJson(`{"id":"history.clear"}`);
}

JSONValue postUndo() { return parseJSON(cast(string)post(baseUrl ~ "/api/undo", "")); }
void undoOk(string why) {
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo (" ~ why ~ ") failed: " ~ u.toString);
}

JSONValue layers() { return getJson("/api/layers"); }
JSONValue selection() { return getJson("/api/selection"); }

// Count selected layers + return the primary's index (-1 if none).
struct SelState { int selectedCount; int primaryIndex; }
SelState selState() {
    SelState s; s.primaryIndex = -1;
    foreach (i, l; layers()["layers"].array) {
        if (l["selected"].type == JSONType.true_) s.selectedCount++;
        if (l["primary"].type  == JSONType.true_) s.primaryIndex = cast(int)i;
    }
    return s;
}

bool isSelected(int idx) {
    return layers()["layers"].array[idx]["selected"].type == JSONType.true_;
}
bool isPrimary(int idx) {
    return layers()["layers"].array[idx]["primary"].type == JSONType.true_;
}

// Build a clean three-layer document A/B/C, A primary+selected (SET-of-one).
void threeLayers() {
    resetCube();                  // A (index 0) = cube, primary+selected
    cmd("layer.add name:B");      // B (index 1) active+selected (exclusive)
    cmd("layer.add name:C");      // C (index 2) active+selected
    cmd("layer.select index:0");  // back to A primary (mode defaults to set)
    cmdJson(`{"id":"history.clear"}`);
    // Sanity: SET-of-one, A primary.
    auto s = selState();
    assert(s.selectedCount == 1 && s.primaryIndex == 0,
        "threeLayers baseline: SET-of-one with A primary");
}

unittest { // mode:set is the today-equivalent exclusive select.
    threeLayers();
    cmd("layer.select index:1");          // mode defaults to set
    auto s = selState();
    assert(s.selectedCount == 1, "set is exclusive (one selected)");
    assert(s.primaryIndex == 1, "set makes the target primary");
    assert(isSelected(1) && !isSelected(0) && !isSelected(2));
}

unittest { // mode:add accumulates selection; the target stays on the HEAD.
    // TASK 0671 — INTENT CHANGE. This used to assert "newest add (C) is
    // primary". The current item selection is an ordered QUEUE and the edit
    // target is its head, so an add appends and does not change who is being
    // edited (frozen: tests/fixtures/edit_target_legality.json, cell
    // `flush_is_per_item_kind` step 3, where `set B; add A` targets B).
    threeLayers();
    cmd("layer.select index:1 mode:add");
    cmd("layer.select index:2 mode:add");
    auto s = selState();
    assert(s.selectedCount == 3, "add accumulates: A,B,C all selected");
    assert(s.primaryIndex == 0,
        "the target is the queue HEAD (A, selected first), not the newest add");
    assert(isSelected(0) && isSelected(1) && isSelected(2));
}

unittest { // mode:add in REVERSE layer order — seat order, not `layers` order.
    // The discriminating rig: select C first, then add A. A `layers`-order walk
    // answers A; the selection queue answers C. Every ascending rig above
    // cannot tell the two apart.
    threeLayers();
    cmd("layer.select index:2");            // set C
    cmd("layer.select index:0 mode:add");   // add A
    auto s = selState();
    assert(s.selectedCount == 2, "A and C selected");
    assert(s.primaryIndex == 2,
        "the target is the EARLIEST-SELECTED (C), not the lowest-indexed (A)");
}

unittest { // mode:remove of the target: CURRENT outranks HISTORY.
    // TASK 0671 — the removed item keeps a non-zero selection state (it moves
    // into its kind's recently-deselected cache) and keeps its queue seat, so a
    // walk that merged the two lists by seat would leave the target on the
    // layer just deselected. It does not: current is walked to exhaustion
    // first.
    threeLayers();
    cmd("layer.select index:1 mode:add");   // A,B selected; A is the head
    cmd("layer.select index:2 mode:add");   // A,B,C selected; A is the head
    cmd("layer.select index:0 mode:remove");// remove the TARGET, A
    auto s = selState();
    assert(s.selectedCount == 2, "A removed → two selected");
    assert(!isSelected(0), "A deselected");
    assert(s.primaryIndex == 1,
        "the target promoted to the first remaining CURRENT item (B), even "
        ~ "though the deselected A holds an earlier seat");
    assert(isPrimary(s.primaryIndex) && isSelected(s.primaryIndex),
        "the promoted target is selected");
}

unittest { // mode:remove of the LAST selected EMPTIES the selection (task 0654).
    //
    // INTENT CHANGE, not a repaired test. This case asserted the opposite —
    // "cannot deselect the last selected layer" — because the ≥1-selected
    // invariant made the empty set unrepresentable. Task 0653 measured the
    // reference emptying on exactly this action and the owner decided we follow
    // it, so 0654 retired the invariant; the old assertion pinned behaviour
    // that was deliberately removed.
    threeLayers();                           // only A selected, A primary
    cmd("layer.select index:0 mode:remove"); // remove the sole selected
    auto s = selState();
    assert(s.selectedCount == 0,
        "removing the last selected layer empties the item selection (0654)");
    // TASK 0671 — the second half of that line was never measured. 0653
    // measured the SELECTION emptying; "and drops the primary with it" was
    // forced by the model of the day. Deselecting moves the item into its
    // kind's recently-deselected cache and the target is the head of a walk
    // over [current ++ cache], so it is still A.
    assert(s.primaryIndex == 0,
        "…and the edit target stays LATCHED on A: an empty item selection with "
        ~ "a live edit target is a legal state (frozen: edit_target_legality, "
        ~ "cell target_set_nothing_selected)");
    assert(!isSelected(0));
}

unittest { // mode:clear empties the whole set in one step (task 0654).
    threeLayers();
    cmd("layer.select index:1 mode:add");    // A,B selected; B primary
    assert(selState().selectedCount == 2, "precondition: two selected");
    cmd("layer.select mode:clear");
    auto s = selState();
    assert(s.selectedCount == 0, "clear empties the set");
    assert(s.primaryIndex == 0,
        "…and leaves the target on the head of what was cleared (task 0671) — "
        ~ "A, which was selected first");
    // Selecting a mesh FLUSHES the mesh bucket, so the latch does not
    // accumulate: after this exactly one layer is foreground again.
    cmd("layer.select index:2 mode:set");
    assert(selState().selectedCount == 1 && selState().primaryIndex == 2,
        "a select out of the empty state moves the target to what was selected");
    assert(layers()["layers"].array[0]["foreground"].type == JSONType.false_,
        "…and A is no longer foreground: the mesh bucket was flushed, not "
        ~ "appended to");
}

unittest { // mode:toggle flips selection on/off.
    threeLayers();
    cmd("layer.select index:1 mode:toggle"); // B off→on (add)
    // TASK 0671: an add appends to the queue; the target is the head, A.
    assert(isSelected(1) && isPrimary(0), "toggle-on selects B, target stays A");
    assert(selState().selectedCount == 2, "A,B selected");
    cmd("layer.select index:1 mode:toggle"); // B on→off (remove)
    assert(!isSelected(1), "toggle-off deselects B");
    assert(selState().selectedCount == 1, "back to A only");
    assert(isPrimary(0), "the target was on A throughout");
}

unittest { // hiding the edit target does NOT hand it to anyone else.
    // ~~hide-primary promotes the primary to another selected+visible layer.~~
    // TASK 0671 — measured (edit_target_legality, cell
    // `hidden_mesh_keeps_the_target`): visibility and targethood are
    // independent. The promotion this used to assert was forced by
    // `foreground == visible && selected`, under which a hidden target was
    // neither foreground nor background and had to go somewhere.
    threeLayers();
    cmd("layer.select index:1 mode:add");    // A,B selected; A is the target
    cmd("layer.select index:0 mode:remove"); // …now only B is, and B is the target
    assert(isPrimary(1) && isSelected(1), "precondition: B holds the target");
    cmd("layer.setVisible index:1 value:false");
    assert(layers()["layers"].array[1]["visible"].type == JSONType.false_,
        "B is hidden");
    assert(isPrimary(1),
        "THE MEASUREMENT: the hidden layer is still the edit target — A does "
        ~ "not inherit it and the hide is not refused");
    assert(layers()["layers"].array[1]["foreground"].type == JSONType.true_,
        "…and it classifies FOREGROUND while hidden, which is what keeps it in "
        ~ "the walk");
    assert(layers()["layers"].array[1]["background"].type == JSONType.false_,
        "…and specifically NOT background: it must not become a dimmed snap "
        ~ "source while it is the thing being edited");
    // CONTROL: the target still moves normally, so the rows above are not a
    // frozen read.
    cmd("layer.select index:0 mode:set");
    assert(isPrimary(0), "CONTROL: selecting another mesh moves the target");
}

unittest { // hiding the sole selected layer is allowed and keeps the target.
    threeLayers();                            // only A selected+visible, target
    cmd("layer.setVisible index:0 value:false");
    assert(layers()["layers"].array[0]["visible"].type == JSONType.false_,
        "hiding the sole selected target is allowed (hidden target)");
    assert(isPrimary(0) && isSelected(0),
        "A remains the selected edit target even while hidden");
}

unittest { // an item select makes SelType.Item the current type.
    threeLayers();
    cmd("layer.select index:1 mode:add");   // any item select promotes Item
    auto sel = selection();
    assert(sel["selType"].str == "item",
        "item select promotes SelType.Item to current, got " ~ sel["selType"].str);
}

unittest { // undo of an item select (UI-undo) restores the prior SET.
    // TASK 0671 — the target sits on A throughout (an add appends; the target
    // is the queue head), so the SET is what these undos have to get right and
    // the target column is the constant. The rig is kept because the set is
    // still the discriminating column, and E5b in
    // tests/test_empty_item_selection.d is where the undo's restoration of the
    // deselect CACHE is asserted.
    threeLayers();
    cmd("layer.select index:1 mode:add");    // A,B selected; A is the target
    cmd("layer.select index:2 mode:add");    // A,B,C selected; A is the target
    assert(selState().selectedCount == 3 && isPrimary(0));
    undoOk("undo C add");
    auto s1 = selState();
    assert(s1.selectedCount == 2, "undo restores the two-member set");
    assert(!isSelected(2), "C deselected by undo");
    assert(s1.primaryIndex == 0, "the target is still A");
    undoOk("undo B add");
    auto s2 = selState();
    assert(s2.selectedCount == 1, "undo restores the SET-of-one");
    assert(s2.primaryIndex == 0, "the target is still A");
    assert(isSelected(0) && !isSelected(1) && !isSelected(2));
}

unittest { // Stage 4 /api/selection final shape: selTypeOrder + items view.
    threeLayers();
    cmd("layer.select index:1 mode:add");        // A,B selected; B primary
    auto sel = selection();
    // selTypeOrder is the full most-recent-first ordering; the front matches
    // selType (an item select made Item current).
    assert("selTypeOrder" in sel, "/api/selection carries selTypeOrder");
    auto order = sel["selTypeOrder"].array;
    assert(order.length == 4, "selTypeOrder lists all four types");
    assert(order[0].str == sel["selType"].str,
        "selTypeOrder front == current selType");
    assert(order[0].str == "item", "item select promotes item to the front");
    // items mirrors /api/layers' per-layer {selected,primary} in layer order.
    assert("items" in sel, "/api/selection carries an items view");
    auto items = sel["items"].array;
    assert(items.length == 3, "one items entry per layer");
    // TASK 0671: the target is the queue head, so A holds it and B does not.
    assert(items[0]["selected"].type == JSONType.true_  && items[0]["primary"].type == JSONType.true_,
        "A selected + primary (it was selected first)");
    assert(items[1]["selected"].type == JSONType.true_  && items[1]["primary"].type == JSONType.false_,
        "B selected, not primary");
    assert(items[2]["selected"].type == JSONType.false_ && items[2]["primary"].type == JSONType.false_,
        "C neither selected nor primary");
}

unittest { // /api/reset restores a clean SET-of-one (cross-test bleed guard).
    threeLayers();
    cmd("layer.select index:1 mode:add");
    cmd("layer.select index:2 mode:add");    // rich multi-select state
    assert(selState().selectedCount == 3);
    resetCube();                              // reset must collapse to one layer
    auto ls = layers()["layers"].array;
    assert(ls.length == 1, "reset collapses to one layer");
    auto s = selState();
    assert(s.selectedCount == 1 && s.primaryIndex == 0,
        "reset restores the SET-of-one with index 0 primary");
}
