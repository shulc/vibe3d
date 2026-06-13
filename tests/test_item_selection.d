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

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

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
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
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

unittest { // mode:add accumulates selection + promotes primary (multi-foreground).
    threeLayers();
    cmd("layer.select index:1 mode:add");
    cmd("layer.select index:2 mode:add");
    auto s = selState();
    assert(s.selectedCount == 3, "add accumulates: A,B,C all selected");
    assert(s.primaryIndex == 2, "newest add (C) is primary");
    assert(isSelected(0) && isSelected(1) && isSelected(2));
}

unittest { // mode:remove of the primary moves primary to a remaining member.
    threeLayers();
    cmd("layer.select index:1 mode:add");   // A,B selected; B primary
    cmd("layer.select index:2 mode:add");   // A,B,C selected; C primary
    cmd("layer.select index:2 mode:remove");// remove primary C
    auto s = selState();
    assert(s.selectedCount == 2, "C removed → two selected");
    assert(!isSelected(2), "C deselected");
    assert(s.primaryIndex == 0 || s.primaryIndex == 1,
        "primary promoted to a remaining selected member");
    assert(isPrimary(s.primaryIndex) && isSelected(s.primaryIndex),
        "promoted primary is selected");
}

unittest { // mode:remove of the LAST selected is a no-op (>=1 invariant).
    threeLayers();                           // only A selected, A primary
    cmd("layer.select index:0 mode:remove"); // try to remove the sole selected
    auto s = selState();
    assert(s.selectedCount == 1, "cannot deselect the last selected layer");
    assert(s.primaryIndex == 0, "primary unchanged on last-selected remove");
    assert(isSelected(0));
}

unittest { // mode:toggle flips selection on/off.
    threeLayers();
    cmd("layer.select index:1 mode:toggle"); // B off→on (add)
    assert(isSelected(1) && isPrimary(1), "toggle-on selects + promotes B");
    assert(selState().selectedCount == 2, "A,B selected");
    cmd("layer.select index:1 mode:toggle"); // B on→off (remove)
    assert(!isSelected(1), "toggle-off deselects B");
    assert(selState().selectedCount == 1, "back to A only");
    assert(isPrimary(0), "primary fell back to A");
}

unittest { // hide-primary promotes the primary to another selected+visible layer.
    threeLayers();
    cmd("layer.select index:1 mode:add");    // A,B selected; B primary
    // B is primary + selected + visible; hide it.
    cmd("layer.setVisible index:1 value:false");
    auto s = selState();
    assert(layers()["layers"].array[1]["visible"].type == JSONType.false_,
        "B is hidden");
    assert(s.primaryIndex == 0, "primary promoted to the visible selected A");
    assert(isPrimary(0) && isSelected(0));
    assert(layers()["layers"].array[s.primaryIndex]["visible"].type == JSONType.true_,
        "promoted primary is visible");
}

unittest { // hide-primary with NO promotion target is allowed (hidden primary).
    // The plan's literal "refuse" fallback is softened to "allow" to keep the
    // pre-#4 single-layer setVisible behaviour neutral (see d-code-writer
    // report's ambiguity flag). When there is no other selected+visible layer,
    // hiding the sole primary leaves a hidden primary; it stays the edit target.
    threeLayers();                            // only A selected+visible, primary
    cmd("layer.setVisible index:0 value:false");
    assert(layers()["layers"].array[0]["visible"].type == JSONType.false_,
        "hiding the sole selected primary is allowed (hidden primary)");
    assert(isPrimary(0) && isSelected(0),
        "A remains the selected primary even while hidden (no promotion target)");
}

unittest { // an item select makes SelType.Item the current type.
    threeLayers();
    cmd("layer.select index:1 mode:add");   // any item select promotes Item
    auto sel = selection();
    assert(sel["selType"].str == "item",
        "item select promotes SelType.Item to current, got " ~ sel["selType"].str);
}

unittest { // undo of an item select (UI-undo) restores the prior set + primary.
    threeLayers();
    cmd("layer.select index:1 mode:add");    // A,B selected; B primary
    cmd("layer.select index:2 mode:add");    // A,B,C selected; C primary
    // Before undo: 3 selected, C primary.
    assert(selState().selectedCount == 3 && isPrimary(2));
    undoOk("undo C add");
    auto s1 = selState();
    assert(s1.selectedCount == 2, "undo restores the two-member set");
    assert(!isSelected(2), "C deselected by undo");
    assert(s1.primaryIndex == 1, "primary restored to B");
    undoOk("undo B add");
    auto s2 = selState();
    assert(s2.selectedCount == 1, "undo restores the SET-of-one");
    assert(s2.primaryIndex == 0, "primary restored to A");
    assert(isSelected(0) && !isSelected(1) && !isSelected(2));
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
