// `+` AND `-` AGAINST THE LIVE APP (task 1100 Stage 3.2).
//
// The arguments fired here are the rows' OWN — read back out of `/api/stats`,
// which publishes what the frame drew — and they go through `POST /api/command`,
// the same dispatch the panel's click takes. Nothing in this file re-derives an
// argument, because a test that built its own arguments would pass while the
// panel dispatched something else.
//
// What is measured here rather than assumed: the hidden-element interaction
// (risk 8), whose answer is recorded in the behaviour-gap registry rather than
// predicted.

import std.net.curl;
import std.json;
import std.exception : enforce;
import std.algorithm : canFind, filter, map;
import std.array : array;
import std.conv : to;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue gj(string p) { return parseJSON(cast(string)get(baseUrl ~ p)); }

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

string rawCmd(string line) { return httpPost("/api/command", line); }

void cmd(string line) {
    string resp = rawCmd(line);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command `" ~ line ~ "` failed: " ~ resp);
}

void settle() { Thread.sleep(400.msecs); }
void resetApp() { httpPost("/api/reset", "{}"); settle(); }

// The panel is a floating window and `/api/reset` does not close it: a block
// that leaves it open hands every later test on this worker a viewport with a
// window over it (measured 2026-08-26: after this file + reset, 92 frames / 92
// stat rebuilds in 400 ms; test_discard_census then reddened on CI twice). Every
// block that opens it closes it on exit.
void closePanel() { cmd("ui.statistics hide"); settle(); }

void openPanelWith(string[] targets) {
    cmd("ui.statistics show");
    // JSON, not an argstring: a category key contains a SPACE ("Vertices/By
    // Edge") and the argstring parser splits positionals on whitespace.
    foreach (t; targets)
        cmd(`{"id":"ui.statistics.expand","_positional":["` ~ t ~ `","open"]}`);
    settle();
}

/// Address a row by its PATH, not by its bare label: "3" is a row of
/// `Vertices → By Edge` and of `Polygons → By Vertex` both, and a lookup that
/// took the first match would silently assert about the wrong one.
JSONValue rowAt(JSONValue[] rs, string section, string category, string label) {
    string curSec, curCat;
    foreach (r; rs) {
        immutable string lvl = r["level"].str;
        if (lvl == "section")  { curSec = r["label"].str; curCat = ""; continue; }
        if (lvl == "category") { curCat = r["label"].str; continue; }
        if (curSec == section && curCat == category && r["label"].str == label)
            return r;
    }
    assert(false, "no drawn row: " ~ section ~ "/" ~ category ~ "/" ~ label);
}

JSONValue[] rows() { return gj("/api/stats")["rows"].array; }

JSONValue rowOf(string level, string label) {
    foreach (r; rows())
        if (r["level"].str == level && r["label"].str == label) return r;
    assert(false, "no drawn row: " ~ level ~ " " ~ label);
}

/// Fire a row's own action, with its argument object passed VERBATIM.
///
/// The NESTED `params` form, not the flat one, and that is not a style choice:
/// `select.byTag` has a parameter literally called `id`, and the flat form puts
/// the command id under the same key — the row's `{"type":"part","id":0,…}`
/// would overwrite the command name with the tag number. Any command with an
/// `id` parameter has this collision; the nested form is what it is for.
string fireRaw(string id, string args) {
    enforce(args.length >= 2 && args[0] == '{', "not an argument object: " ~ args);
    return rawCmd(`{"id":"` ~ id ~ `","params":` ~ args ~ `}`);
}

void fire(string id, string args) {
    auto resp = fireRaw(id, args);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "row action `" ~ id ~ " " ~ args ~ "` failed: " ~ resp);
    settle();
}

size_t[] selectedFaces() {
    auto sel = gj("/api/selection");
    size_t[] outp;
    foreach (v; sel["selectedFaces"].array) outp ~= cast(size_t) v.integer;
    return outp;
}

size_t selectedItems() {
    size_t n = 0;
    foreach (l; gj("/api/layers")["layers"].array)
        if (l["selected"].boolean) ++n;
    return n;
}

// --------------------------------------------------------------------------

unittest { // `+` UNIONS with a selection it does not cover; `-` SUBTRACTS
    scope(exit) closePanel();   // see closePanel: a leaked window is the next test's red
    resetApp();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    openPanelWith(["Polygons", "Polygons/By Vertex", "Polygons/By Type"]);

    // A pre-existing selection the row does not cover would be visible if `+`
    // were a replace. On a cube every face is a quad, so the disjoint operand
    // has to come from another category — Subdivs, which counts zero faces
    // here, is not it; use an explicit face selection instead.
    cmd(`{"id":"select.byStat.polygon","test":"vertexCount","compare":"more","value":4,"mode":"add"}`);
    assert(selectedFaces().length == 0, "setup: no face has more than 4 vertices");

    auto quad = rowAt(rows(), "Polygons", "By Vertex", "4");
    fire(quad["addCommand"].str, quad["addArgs"].str);
    assert(selectedFaces().length == 6, "`+` selects the row's own six quads");

    // `-` subtracts.
    fire(quad["addCommand"].str, quad["removeArgs"].str);
    assert(selectedFaces().length == 0, "`-` subtracts the row's elements");

    // `-` on a row DISJOINT from the selection is a no-op, never a replace.
    cmd(`{"id":"select.byStat.polygon","test":"vertexCount","compare":"equal","value":4,"mode":"add"}`);
    auto before = selectedFaces();
    auto tri = rowAt(rows(), "Polygons", "By Vertex", "3");
    fire(tri["addCommand"].str, tri["removeArgs"].str);
    assert(selectedFaces() == before,
        "subtracting a disjoint row changes nothing, got "
        ~ selectedFaces().to!string);
}

unittest { // the INERT category is inert — paired with a LIVE neighbour, so
    scope(exit) closePanel();   // see closePanel: a leaked window is the next test's red
           // the test can fail
    resetApp();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    openPanelWith(["Polygons", "Polygons/Layer", "Polygons/By Vertex"]);

    auto fg = rowAt(rows(), "Polygons", "Layer", "Foreground");
    assert(!fg["actionsEnabled"].boolean,
        "the Layer rows' buttons are drawn disabled (ours) over measured "
        ~ "inertness");
    assert(fg["addCommand"].str.length == 0,
        "…and there is no command behind them at all");

    // THE PAIR. "Assert nothing changed" alone passes when the whole panel is
    // broken; the live neighbour is what proves this test can fail.
    auto before = selectedFaces();
    auto quad = rowAt(rows(), "Polygons", "By Vertex", "4");
    fire(quad["addCommand"].str, quad["addArgs"].str);
    assert(selectedFaces().length > before.length,
        "the live neighbour must change the selection — otherwise the inert "
        ~ "check below proves nothing");
}

unittest { // a Material row fired in the WRONG MODE refuses and changes nothing
    scope(exit) closePanel();   // see closePanel: a leaked window is the next test's red
    resetApp();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    openPanelWith(["Polygons", "Polygons/Material"]);
    auto matl = rowAt(rows(), "Polygons", "Material", "Material 0");
    assert(matl["addCommand"].str == "select.byTag", matl["addCommand"].str);

    cmd("select.typeFrom vertex");
    settle();
    auto before = selectedFaces();
    auto resp = fireRaw(matl["addCommand"].str, matl["addArgs"].str);
    // A refusal still reads as an error over HTTP — `applyOrRefire` synthesises
    // an exception from the refusal reason for scripted callers. What Stage 0b
    // changed is that a BUTTON's click no longer unwinds; the wire is the same.
    auto r = parseJSON(resp);
    assert("status" in r && r["status"].str == "error",
        "the wrong mode must be refused: " ~ resp);
    assert(r["message"].str.canFind("Polygons"), r["message"].str);
    settle();
    assert(selectedFaces() == before, "…and nothing may change");
}

unittest { // HIDDEN ELEMENTS — MEASURED here, not assumed (risk 8). The answer
    scope(exit) closePanel();   // see closePanel: a leaked window is the next test's red
           // is frozen below and carried into the behaviour-gap registry.
    resetApp();
    // A stand with BOTH triangles and quads, so a SUBSET can be hidden and the
    // row that covers it still has something to count.
    httpPost("/api/load-mesh", `{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],`
        ~ `[2,0,0],[3,0,0],[3,1,0],[2,2,0],[4,0,0]],`
        ~ `"faces":[[0,1,2,3],[4,5,6],[6,7,8]]}`);
    settle();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    openPanelWith(["Polygons", "Polygons/By Vertex"]);

    auto tri = rowAt(rows(), "Polygons", "By Vertex", "3");
    assert(tri["num"].str == "2", "setup: two triangles, got " ~ tri["num"].str);

    // Hide exactly the triangles.
    fire(tri["addCommand"].str, tri["addArgs"].str);
    cmd("mesh.hide");
    settle();
    cmd("select.typeFrom polygon");
    cmd("select.drop polygon");
    settle();

    auto hidden = rowAt(rows(), "Polygons", "By Vertex", "3");
    // MEASURED: `Num` counts GEOMETRY and is blind to the hide flag.
    assert(hidden["num"].str == "2",
        "Num counts geometry whether or not it is hidden, got "
        ~ hidden["num"].str);

    // …and pressing `+` on a row whose elements are all hidden selects NONE of
    // them: the mesh's own `Select ∧ Hide = ∅` invariant is what enforces it,
    // so the row honestly reads Sel < Num afterwards. THIS IS THE MEASUREMENT;
    // the registry row records it.
    fire(hidden["addCommand"].str, hidden["addArgs"].str);
    auto after = rowAt(rows(), "Polygons", "By Vertex", "3");
    assert(after["num"].str == "2", after["num"].str);
    assert(after["sel"].str == "0",
        "a `+` on a hidden row selects nothing — Num stays 2 and Sel stays 0, "
        ~ "got Sel=" ~ after["sel"].str);
    assert(selectedFaces().length == 0,
        "…and the mesh agrees: nothing hidden became selected");
}

unittest { // THE ITEMS ROUND TRIP — one click, one undo entry, and the app
    scope(exit) closePanel();   // see closePanel: a leaked window is the next test's red
           // survives the state that click produces
    resetApp();
    openPanelWith(["Items", "Items/By Type"]);

    auto mesh = rowAt(rows(), "Items", "By Type", "Mesh");
    assert(mesh["addCommand"].str == "layer.select", mesh["addCommand"].str);

    // `-` on the Mesh row empties the item selection. This is the state the
    // panel then has to draw in, on the very next frame.
    fire(mesh["addCommand"].str, mesh["removeArgs"].str);

    assert(selectedItems() == 0,
        "the whole mesh kind was deselected by ONE click, got "
        ~ selectedItems().to!string);

    // The process survives it — the panel is open and drawing in that state,
    // and an unguarded `primary` read here is a segfault rather than a wrong
    // number. These reads are the assertion.
    settle();
    auto model = gj("/api/model");
    assert(model.type == JSONType.object, "the app still answers /api/model");
    auto rs = rows();
    assert(rs.length > 0, "…and the panel is still drawing rows");

    // ONE undo entry for that click. Asserted as a PROPERTY rather than by
    // reading a depth counter: the first undo restores the selection, and a
    // SECOND one leaves it exactly where the first put it — which is only true
    // if the click made one entry rather than one per item.
    cmd("history.undo");
    settle();
    immutable size_t afterUndo = selectedItems();
    assert(afterUndo > 0, "one undo restores the item selection, got "
        ~ afterUndo.to!string);

    cmd("history.undo");
    settle();
    assert(selectedItems() == afterUndo,
        "a SECOND undo must not restore more of the same click — that would "
        ~ "mean the click made an entry per item, got "
        ~ selectedItems().to!string ~ " vs " ~ afterUndo.to!string);
}
