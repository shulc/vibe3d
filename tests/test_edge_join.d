// Tests for mesh.edgeJoin — join two edges sharing a degree-2 vertex.
//
// Custom quad fixture (load-mesh):
//   v0=(-1,0,0)  v1=(0,0,0)  v2=(1,0,0)  v3=(0,1,0)
//   face [0,1,2,3] → edges built from face adjacency:
//     0=[0,1]  1=[1,2]  2=[2,3]  3=[3,0]
//   Edges 0 and 1 share vertex 1 (m=(0,0,0)), which has degree 2.
//
// Cube layout (from makeCube):
//   v0=(-0.5,-0.5,-0.5)  v1=(+0.5,-0.5,-0.5)
//   v2=(+0.5,+0.5,-0.5)  v3=(-0.5,+0.5,-0.5)
//   v4=(-0.5,-0.5,+0.5)  v5=(+0.5,-0.5,+0.5)
//   v6=(+0.5,+0.5,+0.5)  v7=(-0.5,+0.5,+0.5)
//
// Cube edges (addEdge insertion order, deduped):
//   0=[0,3]  1=[3,2]  2=[2,1]  3=[1,0]
//   4=[4,5]  5=[5,6]  6=[6,7]  7=[7,4]
//   8=[0,4]  9=[7,3]  10=[2,6] 11=[5,1]
//
// Vertex 3 appears in cube edges 0, 1, and 9 → degree 3 (cube-corner guard test).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok");
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ cast(string)resp);
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
    assert(parseJSON(resp)["status"].str == "ok");
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// Load a single quad: a(-1,0,0) — m(0,0,0) — b(1,0,0) — c(0,1,0).
// Edges built from face [0,1,2,3]: 0=[0,1], 1=[1,2], 2=[2,3], 3=[3,0].
// Vertex 1 (m) is incident to edges 0 and 1 only → degree 2.
void loadQuadStrip() {
    auto resp = post("http://localhost:8080/api/load-mesh",
        `{"vertices":[[-1,0,0],[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2,3]]}`);
    assert(parseJSON(resp)["status"].str == "ok",
           "load-mesh failed: " ~ cast(string)resp);
}

// ---------------------------------------------------------------------------
// Mode 0: plain join — endpoints preserved, middle vertex dissolved
// ---------------------------------------------------------------------------

unittest { // mode 0: join edges 0+1 on quad strip, middle vertex removed
    resetCube();
    loadQuadStrip();
    // Select edges 0=[0,1] and 1=[1,2]; both incident to v1=(0,0,0), degree 2.
    postSelect("edges", [0, 1]);
    postCommand(`{"id":"mesh.edgeJoin"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 3,
        "expected 3 verts after join, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1,
        "expected 1 face after join, got " ~ m["faceCount"].integer.to!string);
    // Result is a triangle.
    assert(m["faces"].array[0].array.length == 3,
        "resulting face should be a triangle");
    // Middle vertex (0,0,0) must be gone; far endpoints and c preserved.
    bool foundM = false, foundA = false, foundB = false, foundC = false;
    foreach (v; m["vertices"].array) {
        auto c = v.array;
        double x = c[0].floating, y = c[1].floating, z = c[2].floating;
        if (approxEqual(x, 0) && approxEqual(y, 0) && approxEqual(z, 0)) foundM = true;
        if (approxEqual(x,-1) && approxEqual(y, 0) && approxEqual(z, 0)) foundA = true;
        if (approxEqual(x, 1) && approxEqual(y, 0) && approxEqual(z, 0)) foundB = true;
        if (approxEqual(x, 0) && approxEqual(y, 1) && approxEqual(z, 0)) foundC = true;
    }
    assert(!foundM, "middle vertex (0,0,0) must be absent after join");
    assert(foundA && foundB && foundC, "all three endpoints must be preserved");
}

// ---------------------------------------------------------------------------
// Mode 0: inverse-of-split round trip
// ---------------------------------------------------------------------------

unittest { // split cube edge 0, then join the two sub-edges → cube restored
    resetCube();
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.split_edge"}`);
    auto afterSplit = getModel();
    assert(afterSplit["vertexCount"].integer == 9,
        "expected 9 verts after split, got " ~
        afterSplit["vertexCount"].integer.to!string);

    // Find the newly inserted midpoint vertex index.
    // Midpoint of v0=(-0.5,-0.5,-0.5) and v3=(-0.5,+0.5,-0.5) = (-0.5, 0, -0.5).
    int midIdx = -1;
    foreach (i, v; afterSplit["vertices"].array) {
        auto c = v.array;
        if (approxEqual(c[0].floating, -0.5) &&
            approxEqual(c[1].floating,  0.0) &&
            approxEqual(c[2].floating, -0.5)) {
            midIdx = cast(int)i;
            break;
        }
    }
    assert(midIdx >= 0, "midpoint vertex (-0.5,0,-0.5) not found after split");

    // Find the two edges incident to the midpoint vertex.
    int[] subEdges;
    foreach (i, e; afterSplit["edges"].array) {
        auto ep = e.array;
        if (ep[0].integer == midIdx || ep[1].integer == midIdx)
            subEdges ~= cast(int)i;
    }
    assert(subEdges.length == 2,
        "midpoint vertex should have exactly 2 incident edges, got " ~
        subEdges.length.to!string);

    // Join the two sub-edges → cube geometry restored.
    postSelect("edges", subEdges);
    postCommand(`{"id":"mesh.edgeJoin"}`);
    auto afterJoin = getModel();
    assert(afterJoin["vertexCount"].integer == 8,
        "expected 8 verts after join, got " ~
        afterJoin["vertexCount"].integer.to!string);
    assert(afterJoin["edgeCount"].integer == 12,
        "expected 12 edges after join, got " ~
        afterJoin["edgeCount"].integer.to!string);
    assert(afterJoin["faceCount"].integer == 6,
        "expected 6 faces after join, got " ~
        afterJoin["faceCount"].integer.to!string);
    // All faces must be quads (the two 5-gons introduced by split_edge collapse back).
    foreach (f; afterJoin["faces"].array)
        assert(f.array.length == 4,
            "all faces should be quads after round-trip, got arity " ~
            f.array.length.to!string);
}

// ---------------------------------------------------------------------------
// Mode 1: averaged — each endpoint moves to midpoint of its sub-edge
// ---------------------------------------------------------------------------

unittest { // mode 1 (averaged): endpoints at ±0.5 on symmetric strip
    resetCube();
    loadQuadStrip();
    // a=(-1,0,0), m=(0,0,0), b=(1,0,0) — symmetric strip.
    // Candidate A: a → midpoint(a,m) = (-0.5,0,0); b → midpoint(b,m) = (0.5,0,0).
    postSelect("edges", [0, 1]);
    postCommand(`{"id":"mesh.edgeJoin","params":{"mode":1}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 3,
        "expected 3 verts after averaged join, got " ~
        m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1,
        "expected 1 face after averaged join, got " ~
        m["faceCount"].integer.to!string);
    assert(m["faces"].array[0].array.length == 3,
        "averaged result should be a triangle");
    // Averaged endpoints at (-0.5,0,0) and (0.5,0,0); c=(0,1,0) unchanged.
    bool foundA = false, foundB = false, foundC = false;
    foreach (v; m["vertices"].array) {
        auto c = v.array;
        double x = c[0].floating, y = c[1].floating, z = c[2].floating;
        if (approxEqual(x,-0.5) && approxEqual(y, 0) && approxEqual(z, 0)) foundA = true;
        if (approxEqual(x, 0.5) && approxEqual(y, 0) && approxEqual(z, 0)) foundB = true;
        if (approxEqual(x, 0.0) && approxEqual(y, 1) && approxEqual(z, 0)) foundC = true;
    }
    assert(foundA, "averaged endpoint (-0.5,0,0) not found");
    assert(foundB, "averaged endpoint (0.5,0,0) not found");
    assert(foundC, "apex vertex (0,1,0) must be unchanged");
}

// ---------------------------------------------------------------------------
// Undo
// ---------------------------------------------------------------------------

unittest { // undo mode-0 join restores the quad
    resetCube();
    loadQuadStrip();
    postSelect("edges", [0, 1]);
    postCommand(`{"id":"mesh.edgeJoin"}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 4, "undo should restore 4 verts");
    assert(m["faceCount"].integer == 1,   "undo should restore 1 face");
    assert(m["faces"].array[0].array.length == 4,
        "restored face should be a quad");
    // Middle vertex (0,0,0) restored.
    bool foundM = false;
    foreach (v; m["vertices"].array) {
        auto c = v.array;
        if (approxEqual(c[0].floating, 0) &&
            approxEqual(c[1].floating, 0) &&
            approxEqual(c[2].floating, 0)) { foundM = true; break; }
    }
    assert(foundM, "middle vertex (0,0,0) must be restored after undo");
}

// ---------------------------------------------------------------------------
// Negatives — all must return status:error and leave mesh unchanged
// ---------------------------------------------------------------------------

unittest { // only 1 edge selected → error
    resetCube();
    loadQuadStrip();
    postSelect("edges", [0]);
    auto resp = postCommandRaw(`{"id":"mesh.edgeJoin"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "single edge: expected error, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 4, "mesh must be unchanged");
}

unittest { // disjoint edges (no shared vertex) → error
    // Edge 0=[0,1] and edge 2=[2,3]: no common endpoint.
    resetCube();
    loadQuadStrip();
    postSelect("edges", [0, 2]);
    auto resp = postCommandRaw(`{"id":"mesh.edgeJoin"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "disjoint edges: expected error, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 4, "mesh must be unchanged");
}

unittest { // cube-corner vertex (degree 3) → error
    // Cube edges 0=[0,3] and 1=[3,2]: shared vertex is 3, incident to 3 edges.
    resetCube();
    postSelect("edges", [0, 1]);
    auto resp = postCommandRaw(`{"id":"mesh.edgeJoin"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "degree-3 vertex: expected error, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 8, "cube must be unchanged");
}

unittest { // wrong edit mode (Vertices) → error
    resetCube();
    loadQuadStrip();
    postSelect("vertices", [0]);  // switches to Vertices mode
    auto resp = postCommandRaw(`{"id":"mesh.edgeJoin"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "vertices mode: expected error, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 4, "mesh must be unchanged");
}
