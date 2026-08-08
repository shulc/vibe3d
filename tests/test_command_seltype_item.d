// Task 0621 — a command asks the CURRENT selection type, never the derived
// `editMode`.
//
// ---------------------------------------------------------------------------
// THE STATE UNDER TEST, and why an item-mode test is worthless without it
// ---------------------------------------------------------------------------
// `editMode` is a materialized VIEW of the geometry part of the selection type
// (source/seltype.d). Under `SelType.Item` it deliberately RETAINS the most
// recent geometry type instead of clearing, so picking and drawing always have
// a defined mode. The consequence, which is what these rows pin: with an item
// selected the user sees NO geometry selection, but the geometry selection
// from before the switch is STILL IN THE MESH and `editMode` STILL reads
// `polygons` — so a command that branches on `editMode` silently scopes itself
// to faces the user cannot see selected.
//
// Every row below therefore builds a STALE selection on purpose:
//
//     select.typeFrom polygon        -> Polygon becomes the current type
//     /api/select polygons [0]       -> face 0 selected
//     layer.select index:0           -> Item becomes current; face 0 STAYS
//
// and `assertStaleFixture()` asserts all three halves of that state before any
// row measures anything. An item-mode test that skips this and enters item
// mode with NOTHING previously selected cannot tell the fixed code from the
// broken code — both find no selection and both hide/toggle everything. The
// stale selection IS the experiment; the fixture assert is what stops the file
// from quietly degrading into that vacuous version if `layer.select` ever
// starts clearing the geometry selection.
//
// Measured on the real command surface: no state is reached by any back door.
//
// ---------------------------------------------------------------------------
// THE CONTROL ROWS
// ---------------------------------------------------------------------------
// Each command is driven TWICE: once in item mode (stale selection ignored,
// whole model) and once in polygon mode (selection honored, scoped). Both
// directions are needed, because the item rows alone are satisfied by a
// degenerate implementation that ignores the face selection ALWAYS. The
// polygon control fails that implementation loudly, so the pair pins
// "type-aware", not merely "whole-model".

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string p)            { return parseJSON(cast(string) get(baseUrl ~ p)); }
JSONValue postJson(string p, string b) { return parseJSON(cast(string) post(baseUrl ~ p, b)); }

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd(`{"id":"history.clear"}`);
}

JSONValue model() { return getJson("/api/model"); }

bool[] faceHidden() {
    bool[] r;
    foreach (b; model()["faceHidden"].array) r ~= b.type == JSONType.true_;
    return r;
}

bool[] subpatchFlags() {
    bool[] r;
    foreach (b; model()["isSubpatch"].array) r ~= b.type == JSONType.true_;
    return r;
}

void selectFaces(int[] idx) {
    cmd("select.typeFrom polygon");
    string j = "[";
    foreach (i, v; idx) { if (i) j ~= ","; j ~= v.to!string; }
    j ~= "]";
    auto r = postJson("/api/select", `{"mode":"polygons","indices":` ~ j ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

// Build the trap state: a POLYGON selection made first, then an item select on
// top of it. Asserts every half of the premise — see the file header.
void enterItemModeWithStaleFaceSelection(int[] stale) {
    resetCube();
    selectFaces(stale);
    cmd("layer.select index:0");        // promotes SelType.Item to current
    assertStaleFixture(stale);
}

void assertStaleFixture(int[] stale) {
    auto sel = getJson("/api/selection");
    // (a) Item really is the CURRENT type.
    assert(sel["selType"].str == "item",
        "fixture: layer.select must make Item current, got "
        ~ sel["selType"].str);
    // (b) `editMode` still reads polygons — the retained view. This is the
    // half that makes the bug reachable; if it ever cleared to something else
    // the rows below would stop discriminating and this assert says so.
    assert(sel["mode"].str == "polygons",
        "fixture: editMode must RETAIN polygons under Item (that retention is "
        ~ "what a command reading editMode would trip over), got "
        ~ sel["mode"].str);
    // (c) the geometry selection genuinely survived the switch, by identity.
    int[] got;
    foreach (v; sel["selectedFaces"].array) got ~= cast(int) v.integer;
    assert(got == stale,
        "fixture: the pre-switch face selection must SURVIVE into item mode — "
        ~ "without it this file cannot tell a fixed command from a broken one "
        ~ "(both would find nothing). expected " ~ stale.to!string
        ~ ", got " ~ got.to!string);
}

// ---------------------------------------------------------------------------
// mesh.hide
// ---------------------------------------------------------------------------
// WRONG IMPLEMENTATION this row rejects: `hideSelectedTargets(mesh, editMode)`
// — the pre-0621 code. Under Item it reads editMode==Polygons, finds the stale
// face 0 still selected, and hides exactly that one face.
//   broken: faceHidden == [true,false,false,false,false,false]  (1 hidden)
//   fixed : faceHidden == [true x6]                             (6 hidden)
unittest {
    enterItemModeWithStaleFaceSelection([0]);
    cmd(`{"id":"mesh.hide"}`);
    assert(faceHidden() == [true, true, true, true, true, true],
        "under Item no geometry type is current, so there is no current "
        ~ "geometry selection and the empty-selection convention hides the "
        ~ "whole model. A command reading the retained editMode instead hides "
        ~ "only the stale face 0. got " ~ faceHidden().to!string);
}

// CONTROL: the same command in POLYGON mode still honors the selection. Fails
// any implementation that reached the row above by ignoring the face selection
// unconditionally.
unittest {
    resetCube();
    selectFaces([0]);
    auto sel = getJson("/api/selection");
    assert(sel["selType"].str == "polygon", "control: Polygon must be current");
    cmd(`{"id":"mesh.hide"}`);
    assert(faceHidden() == [true, false, false, false, false, false],
        "control: in Polygon mode the face selection IS current and scopes the "
        ~ "hide to face 0 only. got " ~ faceHidden().to!string);
}

// ---------------------------------------------------------------------------
// mesh.hideUnselected (isolate)
// ---------------------------------------------------------------------------
// WRONG IMPLEMENTATION this row rejects: `keepVisibleTargets(mesh, editMode)`.
// Under Item it keeps the stale face 0 visible and hides the other five.
//   broken: faceHidden == [false,true,true,true,true,true]  (5 hidden)
//   fixed : faceHidden == [true x6]                         (6 hidden)
// Note the broken value here (5) differs from mesh.hide's broken value (1),
// so the two rows are independently discriminating even though their FIXED
// values coincide at 6.
unittest {
    enterItemModeWithStaleFaceSelection([0]);
    cmd(`{"id":"mesh.hideUnselected"}`);
    assert(faceHidden() == [true, true, true, true, true, true],
        "under Item the keep set is empty (no current geometry selection), so "
        ~ "the isolate hides everything. A command reading the retained "
        ~ "editMode instead keeps the stale face 0 visible. got "
        ~ faceHidden().to!string);
}

// CONTROL: isolate in POLYGON mode keeps exactly the selected face.
unittest {
    resetCube();
    selectFaces([0]);
    cmd(`{"id":"mesh.hideUnselected"}`);
    assert(faceHidden() == [false, true, true, true, true, true],
        "control: in Polygon mode the isolate keeps exactly the selected face "
        ~ "0 visible. got " ~ faceHidden().to!string);
}

// ---------------------------------------------------------------------------
// mesh.subpatch_toggle
// ---------------------------------------------------------------------------
// WRONG IMPLEMENTATION this row rejects: `editMode == EditMode.Polygons &&
// mesh.hasAnySelectedFaces()`. Under Item that reads true and scopes the
// toggle to the stale face 0.
//   broken: isSubpatch == [true,false,false,false,false,false]  (1 subpatch)
//   fixed : isSubpatch == [true x6]                             (6 subpatch)
//
// This row also pins the command against app.d's Tab-key handler, which has
// always asked `currentSelType(selTypeOrder) == SelType.Polygon` — the two
// spellings of one toggle must answer identically, item mode included.
unittest {
    enterItemModeWithStaleFaceSelection([0]);
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    assert(subpatchFlags() == [true, true, true, true, true, true],
        "under Item the face selection is not current, so the toggle applies "
        ~ "to the WHOLE model — the same answer app.d's Tab handler gives. A "
        ~ "command reading the retained editMode instead toggles only the "
        ~ "stale face 0. got " ~ subpatchFlags().to!string);
}

// CONTROL: toggle in POLYGON mode scopes to the selected face.
unittest {
    resetCube();
    selectFaces([0]);
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    assert(subpatchFlags() == [true, false, false, false, false, false],
        "control: in Polygon mode the toggle is scoped to the selected face 0. "
        ~ "got " ~ subpatchFlags().to!string);
}
