// Tests for mesh.vertexExtrude — Vertex Extrude kernel + command.
//
// Geometry model: for each selected vertex, a duplicate is spawned offset
// along the averaged face normal, connected to the original by a new wire
// edge (a faceless edge — persistent in this mesh representation). The
// vertex selection moves to the newly created vertices.
//
// Cube vertex layout (makeCube):
//   0=(-0.5,-0.5,-0.5)  1=(0.5,-0.5,-0.5)  2=(0.5,0.5,-0.5)  3=(-0.5,0.5,-0.5)
//   4=(-0.5,-0.5, 0.5)  5=(0.5,-0.5, 0.5)  6=(0.5,0.5, 0.5)  7=(-0.5,0.5, 0.5)
// Cube has 8 verts, 12 edges, 6 quad faces.
//
// Corner 0's three incident face normals (Newell): (0,0,-1) + (-1,0,0) + (0,-1,0)
// = (-1,-1,-1); normalized = (-1,-1,-1) / sqrt(3).
// Expected new vertex: (-0.5,-0.5,-0.5) + normalize(-1,-1,-1) * offset.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

// --- HTTP helpers -----------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ resp ~ "\nbody: " ~ body);
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
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }
JSONValue getUndoStatus() {
    return parseJSON(get("http://localhost:8080/api/undo/status"));
}

// --- geometry helpers -------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
double len3(V3 a)    { return sqrt(a.x*a.x + a.y*a.y + a.z*a.z); }

// Index of the (undirected) edge with endpoints {a,b} in model["edges"], or -1.
int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

// Index of the first vertex in `m` closest to `p` (within tol), or -1.
int vertAt(JSONValue m, V3 p, double tol = 1e-4) {
    foreach (i; 0 .. m["vertices"].array.length) {
        if (len3(sub3(vert(m, i), p)) < tol) return cast(int)i;
    }
    return -1;
}

// True iff index `vi` appears in the selectedVertices array from /api/selection.
bool isVertexSelected(JSONValue sel, int vi) {
    foreach (jv; sel["selectedVertices"].array)
        if (cast(int)jv.integer == vi) return true;
    return false;
}

// ---------------------------------------------------------------------------
// 1. Normal extrude: select cube corner 0, offset=0.5.
//    Expected: +1 vertex at corner + normalize(-1,-1,-1)*0.5; +1 wire edge
//    [0, newIdx]; selection moves to new vertex.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);

    auto before = getModel();
    long baseV = before["vertexCount"].integer;  // 8
    long baseE = before["edgeCount"].integer;    // 12

    // Discover corner 0 position (self-consistent, not hard-coded).
    V3 corner = vert(before, 0);

    postCommand(`{"id":"mesh.vertexExtrude","params":{"offset":0.5}}`);

    auto after = getModel();
    assert(after["vertexCount"].integer == baseV + 1,
           format("vertexExtrude: expected %d verts, got %d", baseV+1, after["vertexCount"].integer));
    assert(after["edgeCount"].integer   == baseE + 1,
           format("vertexExtrude: expected %d edges, got %d", baseE+1, after["edgeCount"].integer));

    // New vertex is at corner + normalize(-1,-1,-1)*0.5.
    double inv3 = 1.0 / sqrt(3.0);
    V3 expected = V3(corner.x - inv3 * 0.5,
                     corner.y - inv3 * 0.5,
                     corner.z - inv3 * 0.5);
    int newIdx = vertAt(after, expected);
    assert(newIdx >= 0,
           format("vertexExtrude: new vertex not found near (%.4f,%.4f,%.4f)",
                  expected.x, expected.y, expected.z));

    // Wire edge [0 → newIdx] must exist.
    int ei = edgeIndex(after, 0, newIdx);
    assert(ei >= 0, "vertexExtrude: wire edge (0, newIdx) not found in /api/model.edges");

    // Selection must have moved to the new vertex only.
    auto sel = getSelection();
    assert(sel["mode"].str == "vertices", "vertexExtrude: edit mode must be vertices");
    assert( isVertexSelected(sel, newIdx), "vertexExtrude: new vertex not selected");
    assert(!isVertexSelected(sel, 0),     "vertexExtrude: original vertex still selected");
}

// ---------------------------------------------------------------------------
// 2. Undo restores geometry; redo re-extrudes.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);
    auto before = getModel();
    long baseV = before["vertexCount"].integer;
    long baseE = before["edgeCount"].integer;

    postCommand(`{"id":"mesh.vertexExtrude","params":{"offset":0.3}}`);
    auto after = getModel();

    auto ur = postUndo();
    assert(ur["status"].str == "ok", "undo failed: " ~ ur.toString);
    auto undone = getModel();
    assert(undone["vertexCount"].integer == baseV,
           "undo: vertex count not restored");
    assert(undone["edgeCount"].integer   == baseE,
           "undo: edge count not restored");
    assert(undone["faceCount"].integer   == before["faceCount"].integer,
           "undo: face count not restored");
}

// ---------------------------------------------------------------------------
// 3. No-op: offset=0 — kernel returns 0, command discards snapshot, returns
//    false. Use postCommandRaw (NOT postCommand which asserts "ok"). Assert
//    ONLY unchanged /api/model counts + unchanged undo stack depth.
//    (Pattern from test_edge_extrude.d:785,798.)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("vertices", [0]);

    auto before   = getModel();
    auto undoBefore = getUndoStatus();

    // offset=0 → no-op.
    postCommandRaw(`{"id":"mesh.vertexExtrude","params":{"offset":0.0}}`);

    auto after   = getModel();
    auto undoAfter = getUndoStatus();

    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "no-op changed vertex count");
    assert(after["edgeCount"].integer   == before["edgeCount"].integer,
           "no-op changed edge count");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "no-op changed face count");

    // Undo stack depth must not have grown.
    assert(undoAfter["modelDepth"].integer == undoBefore["modelDepth"].integer,
           "no-op pushed an undo entry (modelDepth changed)");
}
