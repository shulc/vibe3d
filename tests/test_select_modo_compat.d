// Tests for phase 4.5: MODO-compat select.* shim commands.
//
// Cube layout (from /api/model):
//   verts: 0:(-,-,-)  1:(+,-,-)  2:(+,+,-)  3:(-,+,-)
//          4:(-,-,+)  5:(+,-,+)  6:(+,+,+)  7:(-,+,+)
//   edges (addEdge order):
//     0:[0,3]  1:[3,2]  2:[2,1]  3:[1,0]   (back face perimeter)
//     4:[4,5]  5:[5,6]  6:[6,7]  7:[7,4]   (front face perimeter)
//     8:[0,4]  9:[7,3]  10:[2,6] 11:[5,1]  (cross edges)
//   faces:
//     0:back [0,3,2,1]   1:front [4,5,6,7]
//     2:left [0,4,7,3]   3:right [1,2,6,5]
//     4:top  [3,7,6,2]   5:bot   [0,1,5,4]

import std.net.curl;
import std.json;
import std.algorithm : sort, equal, canFind;
import std.array     : array;
import std.conv      : to;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

string postCommandRaw(string body) {
    return cast(string) post("http://localhost:8080/api/command", body);
}

string postScript(string script) {
    return cast(string) post("http://localhost:8080/api/script", script);
}

JSONValue getSelection() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

// buildJsonArray in app.d emits an index array (not bool array):
// e.g. [0,5] means indices 0 and 5 are selected.
int[] selectedFaces() {
    int[] r;
    foreach (n; getSelection()["selectedFaces"].array)
        r ~= cast(int)n.integer;
    return r;
}

int[] selectedEdges() {
    int[] r;
    foreach (n; getSelection()["selectedEdges"].array)
        r ~= cast(int)n.integer;
    return r;
}

int[] selectedVerts() {
    int[] r;
    foreach (n; getSelection()["selectedVertices"].array)
        r ~= cast(int)n.integer;
    return r;
}

string editMode() {
    return getSelection()["mode"].str;
}

void assertSet(T)(T[] actual, T[] expected, string label) {
    auto a = actual.dup; a.sort();
    auto e = expected.dup; e.sort();
    assert(a.equal(e),
        label ~ ": expected " ~ expected.to!string ~ ", got " ~ actual.to!string);
}

// ---------------------------------------------------------------------------
// 1. select.typeFrom — switches EditMode without touching selection
// ---------------------------------------------------------------------------

unittest { // typeFrom polygon via JSON
    resetCube();
    postSelect("vertices", [0, 1]);   // set some vert selection first
    postCommand(`{"id":"select.typeFrom","params":{"_positional":["polygon"]}}`);
    assert(editMode() == "polygons",
        "typeFrom polygon: expected mode=polygons, got " ~ editMode());
    // vert selection must be untouched
    assertSet(selectedVerts(), [0, 1], "typeFrom: vert selection unchanged");
}

unittest { // typeFrom edge via argstring
    resetCube();
    postSelect("polygons", [0, 1]);
    postCommand("select.typeFrom edge");
    assert(editMode() == "edges",
        "typeFrom edge: expected mode=edges, got " ~ editMode());
    // face selection must be untouched
    assertSet(selectedFaces(), [0, 1], "typeFrom: face selection unchanged");
}

unittest { // typeFrom vertex
    resetCube();
    postCommand("select.typeFrom vertex");
    assert(editMode() == "vertices",
        "typeFrom vertex: expected mode=vertices, got " ~ editMode());
}

unittest { // typeFrom unknown type returns error
    resetCube();
    auto resp = postCommandRaw(`{"id":"select.typeFrom","params":{"_positional":["bogus"]}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "typeFrom bogus: expected error, got: " ~ resp);
}

// ---------------------------------------------------------------------------
// 2. select.drop — clears selection in given mode, keeps EditMode
// ---------------------------------------------------------------------------

unittest { // drop polygon clears face selection, keeps edge/vert selections
    resetCube();
    postSelect("polygons", [0, 2, 4]);
    postSelect("vertices", [1, 3]);    // also set some vert selection
    postCommand("select.drop polygon");
    assertSet(selectedFaces(), [], "drop polygon: faces should be empty");
    // Mode should still be whatever /api/select set last (vertices)
    // The important thing is that the face selection is cleared.
    assertSet(selectedVerts(), [1, 3], "drop polygon: vert selection preserved");
}

unittest { // drop vertex clears vertex selection
    resetCube();
    postSelect("vertices", [0, 1, 2]);
    postCommand("select.drop vertex");
    assertSet(selectedVerts(), [], "drop vertex: vert selection should be empty");
}

unittest { // drop edge clears edge selection
    resetCube();
    postSelect("edges", [0, 1, 2]);
    postCommand("select.drop edge");
    assertSet(selectedEdges(), [], "drop edge: edge selection should be empty");
}

unittest { // drop on already-empty selection is a no-op (no error)
    resetCube();
    postCommand("select.drop polygon");   // should not throw
    assertSet(selectedFaces(), [], "drop empty: still empty");
}

// ---------------------------------------------------------------------------
// 3. select.element — set / add / remove
// ---------------------------------------------------------------------------

unittest { // element polygon set: selects exactly the named faces
    resetCube();
    postSelect("polygons", [3, 4, 5]);      // prime with different selection
    postCommand("select.element polygon set 0 5");
    assertSet(selectedFaces(), [0, 5], "element set 0 5");
}

unittest { // element polygon add: adds to current selection
    resetCube();
    postSelect("polygons", [0]);
    postCommand("select.element polygon add 5");
    assertSet(selectedFaces(), [0, 5], "element add 5 to {0}");
}

unittest { // element polygon remove: deselects named faces
    resetCube();
    postSelect("polygons", [0, 5]);
    postCommand("select.element polygon remove 0");
    assertSet(selectedFaces(), [5], "element remove 0 from {0,5}");
}

unittest { // element edge set
    resetCube();
    postSelect("edges", [0, 1, 2, 3]);
    postCommand("select.element edge set 4 5");
    assertSet(selectedEdges(), [4, 5], "element edge set 4 5");
}

unittest { // element vertex add
    resetCube();
    postSelect("vertices", [0]);
    postCommand("select.element vertex add 3 7");
    assertSet(selectedVerts(), [0, 3, 7], "element vertex add 3 7");
}

unittest { // element polygon remove on index not in selection is harmless
    resetCube();
    postSelect("polygons", [0, 1]);
    postCommand("select.element polygon remove 5");   // 5 not selected — no-op
    assertSet(selectedFaces(), [0, 1], "element remove non-selected is harmless");
}

unittest { // element polygon set with zero indices clears selection
    resetCube();
    postSelect("polygons", [0, 1, 2]);
    postCommand(`{"id":"select.element","params":{"_positional":["polygon","set"]}}`);
    assertSet(selectedFaces(), [], "element set with no indices clears selection");
}

unittest { // element out-of-range index returns error
    resetCube();
    auto resp = postCommandRaw("select.element polygon set 99");
    assert(parseJSON(resp)["status"].str == "error",
        "element out-of-range: expected error, got: " ~ resp);
}

// ---------------------------------------------------------------------------
// 4. select.convert
// ---------------------------------------------------------------------------

// vertex → edge: edge between v0 and v1 (edge 3 = [1,0] in the cube)
unittest { // convert vertex→edge selects edges where both endpoints selected
    resetCube();
    postSelect("vertices", [0, 1]);
    postCommand("select.convert edge");
    assert(editMode() == "edges",
        "convert vert→edge: mode should be edges, got " ~ editMode());
    auto edges = selectedEdges();
    // Edge 3 = [1, 0] connects v1 and v0, so it should be selected.
    assert(edges.canFind(3),
        "convert vert→edge: expected edge 3 ([1,0]), got " ~ edges.to!string);
    // Vertex selection should be cleared.
    assertSet(selectedVerts(), [], "convert vert→edge: vert selection cleared");
}

// vertex → polygon: back face [0,3,2,1] — needs all 4 verts selected
unittest { // convert vertex→polygon: selects face only if all verts selected
    resetCube();
    // back face = [0, 3, 2, 1] — select all 4 verts
    postSelect("vertices", [0, 1, 2, 3]);
    postCommand("select.convert polygon");
    assert(editMode() == "polygons",
        "convert vert→poly: mode should be polygons, got " ~ editMode());
    // Face 0 (back: [0,3,2,1]) has all verts selected → should appear.
    // Face 4 (top: [3,7,6,2]) has v3 and v2 selected but not v6, v7 → NOT selected.
    auto faces = selectedFaces();
    assert(faces.canFind(0),
        "convert vert→poly: back face should be selected, got " ~ faces.to!string);
    assert(!faces.canFind(1),
        "convert vert→poly: front face (verts 4-7) should NOT be selected");
    assertSet(selectedVerts(), [], "convert vert→poly: vert selection cleared");
}

// edge → vertex: endpoints of edge 3 ([1,0]) → v1 and v0
unittest { // convert edge→vertex selects both endpoints
    resetCube();
    postSelect("edges", [3]);     // edge 3 = [1, 0]
    postCommand("select.convert vertex");
    assert(editMode() == "vertices",
        "convert edge→vert: mode should be vertices, got " ~ editMode());
    auto verts = selectedVerts();
    assert(verts.canFind(0) && verts.canFind(1),
        "convert edge→vert: expected v0 and v1, got " ~ verts.to!string);
    assertSet(selectedEdges(), [], "convert edge→vert: edge selection cleared");
}

// edge → polygon (MODO ALL rule): face is selected only when every one of
// its edges is in the current edge selection.
unittest { // convert edge→poly with ALL edges of f0 → f0 selected (round-trip)
    resetCube();
    // f0 = [0, 3, 2, 1] — its 4 edges are 0:[0,3], 1:[3,2], 2:[2,1], 3:[1,0]
    postSelect("edges", [0, 1, 2, 3]);
    postCommand("select.convert polygon");
    assert(editMode() == "polygons",
        "convert edge→poly: mode should be polygons, got " ~ editMode());
    assertSet(selectedFaces(), [0],
        "convert edge→poly with all f0 edges: only f0 should be selected");
    assertSet(selectedEdges(), [], "convert edge→poly: edge selection cleared");
}

unittest { // convert edge→poly with ONLY ONE edge → no face selected (ALL rule)
    resetCube();
    postSelect("edges", [0]);   // edge 0 alone is not enough for any face
    postCommand("select.convert polygon");
    assertSet(selectedFaces(), [],
        "convert edge→poly with single edge: no face should be selected under MODO ALL rule");
}

unittest { // poly → edge → poly round-trip preserves the original face
    resetCube();
    postSelect("polygons", [0]);
    postCommand("select.convert edge");      // f0 → its 4 edges
    postCommand("select.convert polygon");   // those 4 edges → f0 only
    assertSet(selectedFaces(), [0],
        "poly→edge→poly round-trip: should land on the original face only");
}

// polygon → vertex: face 0 = back [0,3,2,1]
unittest { // convert polygon→vertex selects all face vertices
    resetCube();
    postSelect("polygons", [0]);    // back face: [0, 3, 2, 1]
    postCommand("select.convert vertex");
    assert(editMode() == "vertices",
        "convert poly→vert: mode should be vertices, got " ~ editMode());
    assertSet(selectedVerts(), [0, 1, 2, 3],
        "convert poly→vert: back face verts");
    assertSet(selectedFaces(), [], "convert poly→vert: face selection cleared");
}

// polygon → edge: face 0 = back [0,3,2,1] has 4 edges: 0,1,2,3
unittest { // convert polygon→edge selects all face edges
    resetCube();
    postSelect("polygons", [0]);    // back face has edges 0,1,2,3
    postCommand("select.convert edge");
    assert(editMode() == "edges",
        "convert poly→edge: mode should be edges, got " ~ editMode());
    auto edges = selectedEdges();
    // All 4 perimeter edges of the back face.
    foreach (e; [0, 1, 2, 3])
        assert(edges.canFind(e),
            "convert poly→edge: expected edge " ~ e.to!string ~
            " in selection, got " ~ edges.to!string);
    assertSet(selectedFaces(), [], "convert poly→edge: face selection cleared");
}

// ---------------------------------------------------------------------------
// 5. select.delete and select.remove aliases
// ---------------------------------------------------------------------------

unittest { // select.delete alias: deletes selected polygon (same as mesh.delete)
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"select.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5,
        "select.delete: expected 5 faces, got " ~ m["faceCount"].integer.to!string);
}

unittest { // select.remove alias: removes selected polygon
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"select.remove"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5,
        "select.remove: expected 5 faces, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 6. End-to-end MODO-style script
// ---------------------------------------------------------------------------

unittest { // MODO bevel script: typeFrom + drop + element + tool.set/attr/doApply
    resetCube();
    string script =
        "select.typeFrom polygon\n" ~
        "select.drop polygon\n" ~
        "select.element polygon set 0\n" ~
        "tool.set bevel\n" ~
        "tool.attr bevel insert 0.25\n" ~
        "tool.attr bevel shift 0.2\n" ~
        "tool.doApply\n" ~
        "tool.set bevel off";
    auto resp = postScript(script);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
        "MODO bevel script failed: " ~ resp);
    auto results = j["results"].array;
    assert(results.length == 8,
        "expected 8 executed lines, got " ~ results.length.to!string);
    foreach (i, r; results)
        assert(r["status"].str == "ok",
            "line " ~ (i+1).to!string ~ " failed: " ~ r.toString);
    // Bevel adds vertices; a bevelled cube face has more verts than 8.
    auto m = getModel();
    assert(m["vertexCount"].integer > 8,
        "bevel script: expected more than 8 verts, got " ~
        m["vertexCount"].integer.to!string);
}

unittest { // convert→delete: poly→vert convert then re-select and delete
    resetCube();
    // Select the back face, convert to edges, then delete via select.delete.
    postSelect("polygons", [0]);   // back face, edges 0..3
    postCommand("select.convert edge");
    // Now 4 edges are selected; select.delete in edge mode dissolves them.
    postCommand(`{"id":"select.delete"}`);
    auto m = getModel();
    // Deleting 4 boundary edges of the back face should dissolve into fewer faces.
    assert(m["faceCount"].integer < 6,
        "convert+delete: expected fewer than 6 faces, got " ~
        m["faceCount"].integer.to!string);
}
