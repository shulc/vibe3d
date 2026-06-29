// Tests for mesh.delete (Tier 1.1). Dispatches by edit mode:
//   Vertices: delete every face incident to a selected vert
//   Edges:    delete every face incident to a selected edge
//   Polygons: delete the selected faces directly
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)
// Faces (in addFace insertion order):
//   f0=back [0,3,2,1]   f1=front [4,5,6,7]
//   f2=left [0,4,7,3]   f3=right [1,2,6,5]
//   f4=top  [3,7,6,2]   f5=bottom [0,1,5,4]

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void resetGrid(int n) {
    auto resp = post("http://localhost:8080/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset grid failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

string postCommandRaw(string body) {
    return cast(string)post("http://localhost:8080/api/command", body);
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

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue postRedo() { return parseJSON(post("http://localhost:8080/api/redo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// ---------------------------------------------------------------------------
// Polygons mode
// ---------------------------------------------------------------------------

unittest { // delete one face — verts shared with other faces survive
    resetCube();
    postSelect("polygons", [0]);  // back face — verts 0,1,2,3
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    // Cube has 6 faces; one delete removes 1 face. Verts 0..3 are still
    // referenced by left/right/top/bottom faces, so all 8 stay.
    assert(m["faceCount"].integer == 5,
        "expected 5 faces after deleting back, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "expected 8 verts (none orphaned), got " ~ m["vertexCount"].integer.to!string);
}

unittest { // delete two opposite faces — verts still survive
    resetCube();
    postSelect("polygons", [0, 1]);   // back + front
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 4,
        "expected 4 faces after delete, got " ~ m["faceCount"].integer.to!string);
    // All 8 verts still on left/right/top/bottom.
    assert(m["vertexCount"].integer == 8,
        "expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // undo a face delete restores the cube
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.delete"}`);
    assert(getModel()["faceCount"].integer == 5);

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["faceCount"].integer == 6, "face delete not undone");
    assert(m["vertexCount"].integer == 8);
    assert(m["edgeCount"].integer == 12, "edges not restored on undo");

    auto r = postRedo();
    assert(r["status"].str == "ok");
    assert(getModel()["faceCount"].integer == 5, "face delete not redone");
}

// ---------------------------------------------------------------------------
// Vertices mode
// ---------------------------------------------------------------------------

unittest { // Delete-vertex DISSOLVES from incident faces (quad → tri)
    resetCube();
    postSelect("vertices", [0]);   // corner — touches back/left/bottom (3 quads)
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    // Vert 0 was shared by 3 quad faces. Each loses v0 and shrinks to a
    // triangle. Other 3 faces (front/right/top) keep all 4 verts.
    // → 6 faces total: 3 triangles + 3 quads.
    assert(m["faceCount"].integer == 6,
        "expected 6 faces (dissolve, not kill), got " ~ m["faceCount"].integer.to!string);
    // v0 is dissolved out; 7 verts remain.
    assert(m["vertexCount"].integer == 7,
        "expected 7 verts (v0 dissolved), got " ~ m["vertexCount"].integer.to!string);

    // Verify the face shape distribution: 3 triangles + 3 quads.
    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        if (f.array.length == 3) ++tris;
        else if (f.array.length == 4) ++quads;
    }
    assert(tris == 3 && quads == 3,
        "expected 3 tris + 3 quads, got " ~ tris.to!string ~ "/" ~ quads.to!string);
}

unittest { // undo a vertex dissolve restores everything
    resetCube();
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.delete"}`);
    assert(getModel()["faceCount"].integer == 6);

    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["faceCount"].integer == 6);
    assert(m["vertexCount"].integer == 8, "verts not restored");
    assert(m["edgeCount"].integer == 12, "edges not restored");
    // All faces back to quads.
    foreach (f; m["faces"].array)
        assert(f.array.length == 4, "non-quad after undo");
}

// ---------------------------------------------------------------------------
// Edges mode
// ---------------------------------------------------------------------------

unittest { // edge-delete: dissolve edge + dissolve 2-valent endpoints
    resetCube();
    // Edge 0 = [0, 3] (back-left vertical). Shared by back f0 and left f2.
    // After dissolve: back+left merge into a hex; v0 and v3 become 2-valent
    // and get dissolved too — quad merge → 3 quads + 2 tris (5 faces, 6 verts).
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5,
        "expected 5 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 6,
        "expected 6 verts (v0, v3 dissolved), got " ~ m["vertexCount"].integer.to!string);

    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        if (f.array.length == 3) ++tris;
        else if (f.array.length == 4) ++quads;
    }
    assert(tris == 2 && quads == 3,
        "expected 2 tris + 3 quads, got " ~ tris.to!string ~ "/" ~ quads.to!string);
}

unittest { // undo an edge delete restores cube
    resetCube();
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.delete"}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["faceCount"].integer == 6);
    assert(m["vertexCount"].integer == 8);
    assert(m["edgeCount"].integer == 12);
}

// ---------------------------------------------------------------------------
// Errors / no-op
// ---------------------------------------------------------------------------

unittest { // delete with empty selection ⇒ everything is selected (whole mesh)
    resetCube();
    // Vertices mode, no selection: by the "empty selection = everything"
    // convention (mesh.nothingSelected), delete operates on all verts and
    // leaves an empty mesh.
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 0,
        "expected empty mesh after empty-selection delete, got "
        ~ m["vertexCount"].integer.to!string ~ " verts");
    assert(m["faceCount"].integer == 0);
    assert(m["edgeCount"].integer == 0);
}

unittest { // delete every face leaves an empty mesh
    resetCube();
    postSelect("polygons", [0, 1, 2, 3, 4, 5]);
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 0,
        "expected 0 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 0,
        "expected 0 verts (all orphaned), got " ~ m["vertexCount"].integer.to!string);
    assert(m["edgeCount"].integer == 0);
}

// ---------------------------------------------------------------------------
// mesh.remove — "Remove" semantics: same as delete except for edges
// ---------------------------------------------------------------------------

unittest { // remove face = delete face (same behavior)
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.remove"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5);
    assert(m["vertexCount"].integer == 8);
}

unittest { // remove vertex = delete vertex (both dissolve)
    resetCube();
    postSelect("vertices", [0]);
    postCommand(`{"id":"mesh.remove"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 6, "remove vertex should dissolve, not kill faces");
    assert(m["vertexCount"].integer == 7);
}

unittest { // remove edge: same behavior as delete edge
    resetCube();
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.remove"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5);
    assert(m["vertexCount"].integer == 6);
    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        if (f.array.length == 3) ++tris;
        else if (f.array.length == 4) ++quads;
    }
    assert(tris == 2 && quads == 3,
        "expected 2 tris + 3 quads, got " ~ tris.to!string ~ "/" ~ quads.to!string);
}

unittest { // undo remove edge restores cube
    resetCube();
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.remove"}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["faceCount"].integer == 6);
    assert(m["vertexCount"].integer == 8);
    assert(m["edgeCount"].integer == 12);
    foreach (f; m["faces"].array)
        assert(f.array.length == 4, "non-quad face after undo");
}

unittest { // delete vs remove on a single edge produce IDENTICAL output
    // `cmd delete` and `cmd remove` produce the same output for edge
    // selections (both: dissolve + 2-valent cleanup). Delete and Remove
    // are kept as separate commands only because they appear as separate
    // menu items.
    resetCube();
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.delete"}`);
    auto deleted = getModel();

    resetCube();
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.remove"}`);
    auto removed = getModel();

    assert(deleted["faceCount"].integer == removed["faceCount"].integer,
        "delete/remove edge should give the same face count");
    assert(deleted["vertexCount"].integer == removed["vertexCount"].integer,
        "delete/remove edge should give the same vertex count");
}

unittest { // Pin the boundary-survival fix: delete ALL edges on an OPEN grid.
    // Regression for removeEdgesByMask dropping half-edges by "merely
    // selected" instead of "actually dissolved". On an open mesh a selected
    // *boundary* edge is NOT dissolved (only one adjacent face), so its
    // half-edge must SURVIVE on the merged boundary. The old code dropped it,
    // emptied the boundary walk, skipped the component, and left the mesh
    // unchanged (n=2 grid stayed 4 faces / 9 verts).
    //
    // With the fix the four interior-merged quads collapse to the 8-vertex
    // perimeter loop; every perimeter vertex is then 2-valent, so the
    // follow-up dissolveDegree2Verts reduces the whole open patch to nothing.
    // The load-bearing assertion is that the counts CHANGE (faceCount < 4),
    // i.e. the component is no longer skipped.
    resetGrid(2);
    postSelect("edges", []);   // empty selection ⇒ whole mesh (all edges)
    auto before = getModel();
    assert(before["faceCount"].integer == 4,
        "n=2 grid should start with 4 faces, got " ~ before["faceCount"].integer.to!string);
    assert(before["vertexCount"].integer == 9,
        "n=2 grid should start with 9 verts, got " ~ before["vertexCount"].integer.to!string);

    postCommand(`{"id":"mesh.delete"}`);
    auto after = getModel();
    // Pre-fix bug: faceCount stayed at 4 (component skipped). Post-fix it drops.
    assert(after["faceCount"].integer < before["faceCount"].integer,
        "delete-all-edges must change the mesh (boundary-survival fix); faceCount stayed "
        ~ after["faceCount"].integer.to!string);
    // Observed post-fix result on the n=2 open grid: full collapse.
    assert(after["faceCount"].integer == 0,
        "expected 0 faces after whole-grid edge delete, got " ~ after["faceCount"].integer.to!string);
    assert(after["vertexCount"].integer == 0,
        "expected 0 verts after whole-grid edge delete, got " ~ after["vertexCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Cross-mode redirect — task 0110 regression tests
//
// Scenario: a selection that lives in one element type is present while the
// active edit mode is a DIFFERENT element type. The pre-fix code keyed the
// "empty selection ⇒ whole mesh" check on the active mode alone and wiped the
// mesh even though a face (or edge/vert) selection existed in another mode.
// The fix redirects to the type that actually holds a selection.
// ---------------------------------------------------------------------------

unittest { // cross-mode: face selected, vertices mode active → delete ONLY that face
    // Pre-fix: nothingSelected(Vertices)=true → dissolveVerticesByMask(allTrue) → 0 faces.
    // Post-fix: effectiveDeleteMode → Polygons → deleteFacesByMask([face 0]) → 5 faces.
    resetCube();
    postSelect("polygons", [0]);   // face 0 selected; mode = polygons
    postSelect("vertices", []);    // mode flips to vertices; face 0 mark survives
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5,
        "cross-mode delete (vertices active, face 0 selected) expected 5 faces, got "
        ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "expected 8 verts (none orphaned), got " ~ m["vertexCount"].integer.to!string);
}

unittest { // cross-mode undo: undo restores the cube + redo re-deletes the face
    resetCube();
    postSelect("polygons", [0]);
    postSelect("vertices", []);
    postCommand(`{"id":"mesh.delete"}`);
    assert(getModel()["faceCount"].integer == 5, "pre-undo: expected 5 faces");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["faceCount"].integer == 6, "undo should restore 6 faces");
    assert(m["vertexCount"].integer == 8, "undo should restore 8 verts");

    auto r = postRedo();
    assert(r["status"].str == "ok", "redo failed: " ~ r.toString);
    assert(getModel()["faceCount"].integer == 5, "redo should re-delete face → 5 faces");
}

unittest { // cross-mode: face selected, edges mode active → delete ONLY that face
    // Pre-fix on a closed cube: nothingSelected(Edges)=true → removeEdgesByMask(allTrue)
    // + dissolveDegree2Verts → net no-op (cube stayed 6 faces — silently wrong).
    // Post-fix: effectiveDeleteMode → Polygons → deleteFacesByMask([face 0]) → 5 faces.
    resetCube();
    postSelect("polygons", [0]);   // face 0 selected
    postSelect("edges", []);       // mode flips to edges; face 0 mark survives
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5,
        "cross-mode delete (edges active, face 0 selected) expected 5 faces, got "
        ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // cross-mode mesh.remove parity: same redirect applies to mesh.remove
    resetCube();
    postSelect("polygons", [0]);
    postSelect("vertices", []);
    postCommand(`{"id":"mesh.remove"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 5,
        "mesh.remove cross-mode: expected 5 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // multi-face cross-mode: 2 faces selected, vertices active → 4 faces remain
    resetCube();
    postSelect("polygons", [0, 1]);  // back + front selected
    postSelect("vertices", []);      // mode flips to vertices; face marks survive
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 4,
        "cross-mode multi-face delete expected 4 faces, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 8,
        "expected 8 verts, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // no-regression: truly-empty selection still wipes whole mesh (convention preserved)
    // effectiveDeleteMode returns current when nothing is selected anywhere,
    // so nothingSelected(current)=true fires and the whole-mesh all-true mask
    // wipes the mesh. This is the intended behaviour pinned by the original test.
    resetCube();
    // No select call — default state: vertices mode, nothing selected anywhere.
    postCommand(`{"id":"mesh.delete"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 0,
        "truly-empty delete must still wipe whole mesh, got "
        ~ m["faceCount"].integer.to!string ~ " faces");
    assert(m["vertexCount"].integer == 0);
    assert(m["edgeCount"].integer == 0);
}
