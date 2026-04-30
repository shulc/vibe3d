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

unittest { // MODO Delete-vertex DISSOLVES from incident faces (quad → tri)
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

unittest { // modo_cl edge-delete: dissolve edge + dissolve 2-valent endpoints
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

unittest { // delete with empty selection is a no-op (returns error from apply)
    resetCube();
    // Vertices mode, no selection.
    auto resp = postCommandRaw(`{"id":"mesh.delete"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error on empty-selection delete, got: " ~ resp);
    // Mesh unchanged.
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
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
// mesh.remove — MODO "Remove" semantics: same as delete except for edges
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

unittest { // remove edge: same modo_cl behavior as delete edge
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
    // modo_cl headless treats `cmd delete` and `cmd remove` the same way
    // for edge selections (both: dissolve + 2-valent cleanup). vibe3d
    // matches that behavior — Delete and Remove are kept as separate
    // commands only because MODO exposes them as separate menu items.
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
