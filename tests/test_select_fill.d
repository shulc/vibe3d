// Tests for task 0387 "Selection Fill" — select.fill.holes and
// select.fill.insideLoop, invoked via /api/command against a grid mesh
// built by /api/reset?type=grid&n=N (== mesh.makeGridPlane(n), same
// row-major vertex/face layout its own unittests use):
//
//   side = n + 1 verts per row/column; vertex(i,j) = i*side + j.
//   face(i,j), i,j in [0,n): one quad per grid cell, addFace order == i*n+j.
//
// No event-log replay — selections are set directly via /api/select
// (mesh.select), matching tests/test_select_topology.d's style.

import std.net.curl;
import std.json;
import std.algorithm : sort, equal, canFind;
import std.array     : array;
import std.conv      : to;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers (same shapes as tests/test_select_topology.d / test_edge_extrude.d)
// ---------------------------------------------------------------------------

void resetGrid(int n) {
    auto resp = post("http://localhost:8080/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset grid failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue postRedo() { return parseJSON(post("http://localhost:8080/api/redo", "")); }

JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }
JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }

int[] selectedFaces() {
    int[] r;
    foreach (n; getSelection()["selectedFaces"].array) r ~= cast(int)n.integer;
    return r;
}

int[] selectedEdges() {
    int[] r;
    foreach (n; getSelection()["selectedEdges"].array) r ~= cast(int)n.integer;
    return r;
}

string editMode() { return getSelection()["mode"].str; }

void assertSet(T)(T[] actual, T[] expected, string label) {
    auto a = actual.dup; a.sort();
    auto e = expected.dup; e.sort();
    assert(a.equal(e), label ~ ": expected " ~ expected.to!string ~ ", got " ~ actual.to!string);
}

// Index of the (undirected) edge with endpoints {a,b} in model["edges"], or -1.
int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Grid geometry helpers
// ---------------------------------------------------------------------------

int vidx(int i, int j, int side) { return i * side + j; }

// Perimeter edges (vertex-index pairs) enclosing the face block
// [r0,r1) x [c0,c1) of an n×n grid (side = n+1 verts/row).
int[2][] perimeterEdges(int r0, int r1, int c0, int c1, int side) {
    int[2][] e;
    foreach (j; c0 .. c1) e ~= [vidx(r0, j, side),     vidx(r0, j + 1, side)];     // top
    foreach (j; c0 .. c1) e ~= [vidx(r1, j, side),     vidx(r1, j + 1, side)];     // bottom
    foreach (i; r0 .. r1) e ~= [vidx(i, c0, side),     vidx(i + 1, c0, side)];     // left
    foreach (i; r0 .. r1) e ~= [vidx(i, c1, side),     vidx(i + 1, c1, side)];     // right
    return e;
}

int[] blockFaces(int r0, int r1, int c0, int c1, int n) {
    int[] f;
    foreach (i; r0 .. r1) foreach (j; c0 .. c1) f ~= i * n + j;
    return f;
}

// ---------------------------------------------------------------------------
// select.fill.insideLoop
// ---------------------------------------------------------------------------

unittest { // insideLoop: a closed edge loop enclosing a 2x2 face block
           // selects exactly those faces and switches to Polygons mode.
    resetGrid(6);
    immutable n = 6, side = 7;
    immutable r0 = 2, r1 = 4, c0 = 2, c1 = 4;   // strictly interior: faces {14,15,20,21}

    auto m = getModel();
    int[] edgeIdxs;
    foreach (pr; perimeterEdges(r0, r1, c0, c1, side)) {
        int ei = edgeIndex(m, pr[0], pr[1]);
        assert(ei >= 0, "perimeter edge (" ~ pr[0].to!string ~ "," ~ pr[1].to!string ~ ") not found");
        edgeIdxs ~= ei;
    }
    assert(edgeIdxs.length == 8, "fixture: expected 8 perimeter edges, got " ~ edgeIdxs.length.to!string);

    postSelect("edges", edgeIdxs);
    assert(editMode() == "edges", "fixture: expected mode=edges before fill");

    postCommand("select.fill.insideLoop");
    assert(editMode() == "polygons",
        "insideLoop: expected mode=polygons, got " ~ editMode());

    auto expectedFaces = blockFaces(r0, r1, c0, c1, n);
    assertSet(selectedFaces(), expectedFaces, "insideLoop: interior faces");
    assertSet(selectedEdges(), [], "insideLoop: edge selection cleared");

    // Undo restores the prior EDGE selection (and mode); redo re-applies the fill.
    postUndo();
    assert(editMode() == "edges", "insideLoop undo: expected mode=edges, got " ~ editMode());
    assertSet(selectedEdges(), edgeIdxs, "insideLoop undo: edge selection restored");
    assertSet(selectedFaces(), [], "insideLoop undo: face selection restored");

    postRedo();
    assert(editMode() == "polygons", "insideLoop redo: expected mode=polygons, got " ~ editMode());
    assertSet(selectedFaces(), expectedFaces, "insideLoop redo: interior faces re-selected");
}

unittest { // insideLoop: an OPEN polyline (does not enclose anything) is a no-op —
           // selection and edit mode are left exactly as they were.
    resetGrid(6);
    immutable side = 7;
    auto m = getModel();

    // A straight run of 3 edges along one grid line — never closes a loop.
    int[] edgeIdxs;
    foreach (pr; [[vidx(2, 2, side), vidx(2, 3, side)],
                  [vidx(2, 3, side), vidx(2, 4, side)],
                  [vidx(2, 4, side), vidx(2, 5, side)]]) {
        int ei = edgeIndex(m, pr[0], pr[1]);
        assert(ei >= 0, "fixture: open-polyline edge not found");
        edgeIdxs ~= ei;
    }

    postSelect("edges", edgeIdxs);
    postCommand("select.fill.insideLoop");

    assert(editMode() == "edges",
        "insideLoop open polyline: mode must be left unchanged, got " ~ editMode());
    assertSet(selectedEdges(), edgeIdxs, "insideLoop open polyline: edge selection left unchanged");
    assertSet(selectedFaces(), [], "insideLoop open polyline: no face selection created");
}

// ---------------------------------------------------------------------------
// select.fill.holes
// ---------------------------------------------------------------------------

unittest { // fill.holes: a 4x4 block missing one interior face gets it filled back in.
    resetGrid(6);
    immutable n = 6;

    int[] sel;
    foreach (i; 1 .. 5) foreach (j; 1 .. 5)
        if (!(i == 2 && j == 3)) sel ~= i * n + j;
    assert(sel.length == 15, "fixture: expected 15 preselected faces, got " ~ sel.length.to!string);

    postSelect("polygons", sel);
    postCommand("select.fill.holes");

    auto after = selectedFaces();
    assert(after.length == 16,
        "fill.holes: expected 16 faces after fill, got " ~ after.length.to!string);
    assert(after.canFind(2 * n + 3),
        "fill.holes: the missing interior face (2,3) should now be selected");

    // Undo restores the pre-fill 15-face selection; redo re-fills.
    postUndo();
    assertSet(selectedFaces(), sel, "fill.holes undo: 15-face selection restored");
    postRedo();
    auto redone = selectedFaces();
    assert(redone.length == 16,
        "fill.holes redo: expected 16 faces again, got " ~ redone.length.to!string);
}

unittest { // fill.holes: two disjoint 2x2 blocks must NOT be merged.
    resetGrid(10);
    immutable n = 10;

    int[] sel = blockFaces(1, 3, 1, 3, n) ~ blockFaces(6, 8, 6, 8, n); // block A + block B
    assert(sel.length == 8, "fixture: expected 8 preselected faces, got " ~ sel.length.to!string);

    postSelect("polygons", sel);
    postCommand("select.fill.holes");

    assertSet(selectedFaces(), sel, "fill.holes: two disjoint blocks must be left unchanged");
}
