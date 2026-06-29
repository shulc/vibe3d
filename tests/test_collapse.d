// Tests for mesh.collapse (Vertices / Edges / Polygons scope).
//
// Cube layout (from makeCube):
//   v0=(-0.5,-0.5,-0.5)  v1=(+0.5,-0.5,-0.5)
//   v2=(+0.5,+0.5,-0.5)  v3=(-0.5,+0.5,-0.5)
//   v4=(-0.5,-0.5,+0.5)  v5=(+0.5,-0.5,+0.5)
//   v6=(+0.5,+0.5,+0.5)  v7=(-0.5,+0.5,+0.5)
//
// Faces (addFace order):
//   0=[0,3,2,1] back     1=[4,5,6,7] front
//   2=[0,4,7,3] left     3=[1,2,6,5] right
//   4=[3,7,6,2] top      5=[0,1,5,4] bottom
//
// Edges (addEdge insertion order, deduped):
//   0=[0,3]  1=[3,2]  2=[2,1]  3=[1,0]
//   4=[4,5]  5=[5,6]  6=[6,7]  7=[7,4]
//   8=[0,4]  9=[7,3]  10=[2,6] 11=[5,1]

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
    assert(parseJSON(resp)["status"].str == "ok");
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// ---------------------------------------------------------------------------
// Vertex scope
// ---------------------------------------------------------------------------

unittest { // vertex collapse: 4 front-face corners → centroid (0, 0, 0.5)
    // Identical topology to vert.join average:true on the same selection,
    // but issued as the distinct mesh.collapse command.
    resetCube();
    // v4, v5, v6, v7 are the front face corners. centroid = (0, 0, 0.5).
    postSelect("vertices", [4, 5, 6, 7]);
    postCommand(`{"id":"mesh.collapse"}`);
    auto m = getModel();
    // 4 verts collapse to 1; 8 - 4 + 1 = 5.
    assert(m["vertexCount"].integer == 5,
        "expected 5 verts, got " ~ m["vertexCount"].integer.to!string);
    // Front face fully collapses (dropped). 4 side faces → tris. Back → quad.
    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        if      (f.array.length == 3) ++tris;
        else if (f.array.length == 4) ++quads;
    }
    assert(quads == 1 && tris == 4,
        "expected 1 quad + 4 tris, got " ~ quads.to!string ~ "q/" ~ tris.to!string ~ "t");
    // Centroid at (0, 0, 0.5) must be present.
    bool foundCenter = false;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, 0.0)
         && approxEqual(a[1].floating, 0.0)
         && approxEqual(a[2].floating, 0.5)) { foundCenter = true; break; }
    }
    assert(foundCenter, "centroid (0,0,0.5) not found after vertex collapse");
}

unittest { // vertex collapse with a single vert selected → no-op error
    resetCube();
    postSelect("vertices", [0]);
    auto resp = postCommandRaw(`{"id":"mesh.collapse"}`);
    assert(parseJSON(resp)["status"].str == "error",
        "single-vert collapse should error, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 8, "mesh must be unchanged");
}

// ---------------------------------------------------------------------------
// Edge scope
// ---------------------------------------------------------------------------

unittest { // edge collapse: single edge 0 ([v0,v3]) → midpoint (-0.5, 0, -0.5)
    resetCube();
    // Edge 0 = [v0,v3]: v0=(-0.5,-0.5,-0.5), v3=(-0.5,+0.5,-0.5).
    // Midpoint = (-0.5, 0, -0.5).
    // back and left faces each lose a corner → triangles; 4 others stay quads.
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.collapse"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 7,
        "expected 7 verts after edge collapse, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "expected 6 faces, got " ~ m["faceCount"].integer.to!string);
    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        if      (f.array.length == 3) ++tris;
        else if (f.array.length == 4) ++quads;
    }
    assert(tris == 2 && quads == 4,
        "expected 2 tris + 4 quads, got " ~ tris.to!string ~ "t/" ~ quads.to!string ~ "q");
    // Midpoint (-0.5, 0, -0.5) must be present.
    bool foundMid = false;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, -0.5)
         && approxEqual(a[1].floating,  0.0)
         && approxEqual(a[2].floating, -0.5)) { foundMid = true; break; }
    }
    assert(foundMid, "midpoint (-0.5,0,-0.5) not found after edge collapse");
}

unittest { // edge collapse disjoint: edges 0 ([v0,v3]) and 6 ([v6,v7]) — no shared vert
    // Per-island behavior: each edge collapses to its OWN midpoint.
    // If only one island collapsed, vertexCount would be 7 (not 6).
    // m03 = (-0.5, 0, -0.5),  m67 = (0, 0.5, 0.5).
    resetCube();
    postSelect("edges", [0, 6]);
    postCommand(`{"id":"mesh.collapse"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 6,
        "both disjoint edges must collapse: expected 6 verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "expected 6 faces, got " ~ m["faceCount"].integer.to!string);
    // Both midpoints must be present.
    bool foundM03 = false, foundM67 = false;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, -0.5)
         && approxEqual(a[1].floating,  0.0)
         && approxEqual(a[2].floating, -0.5)) foundM03 = true;
        if (approxEqual(a[0].floating,  0.0)
         && approxEqual(a[1].floating,  0.5)
         && approxEqual(a[2].floating,  0.5)) foundM67 = true;
    }
    assert(foundM03, "midpoint m03=(-0.5,0,-0.5) not found");
    assert(foundM67, "midpoint m67=(0,0.5,0.5) not found");
}

// ---------------------------------------------------------------------------
// Polygon scope
// ---------------------------------------------------------------------------

unittest { // polygon collapse: front face (fi=1) → centroid (0, 0, 0.5)
    // Same result as vertex collapse on the same 4 corners, reached via
    // face selection rather than vertex selection.
    resetCube();
    // Face 1 = front [4,5,6,7]. centroid = (0, 0, 0.5).
    postSelect("polygons", [1]);
    postCommand(`{"id":"mesh.collapse"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 5,
        "expected 5 verts after poly collapse, got " ~ m["vertexCount"].integer.to!string);
    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        if      (f.array.length == 3) ++tris;
        else if (f.array.length == 4) ++quads;
    }
    assert(quads == 1 && tris == 4,
        "expected 1 quad + 4 tris, got " ~ quads.to!string ~ "q/" ~ tris.to!string ~ "t");
    bool foundCenter = false;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, 0.0)
         && approxEqual(a[1].floating, 0.0)
         && approxEqual(a[2].floating, 0.5)) { foundCenter = true; break; }
    }
    assert(foundCenter, "centroid (0,0,0.5) not found after polygon collapse");
}

unittest { // polygon collapse disjoint: back (fi=0) + front (fi=1) — no shared vert
    // Per-island behavior: back → (0,0,-0.5), front → (0,0,0.5).
    // Every intermediate cube face has 2 verts from each island, so they
    // all degenerate to 2-corner segments and are dropped → empty mesh.
    // If only one island collapsed, we would get 5 verts / 5 faces instead.
    resetCube();
    postSelect("polygons", [0, 1]);
    postCommand(`{"id":"mesh.collapse"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 0,
        "both disjoint poly islands must collapse: expected 0 verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 0,
        "expected 0 faces after disjoint poly collapse, got "
        ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Undo
// ---------------------------------------------------------------------------

unittest { // undo vertex collapse restores the cube
    resetCube();
    postSelect("vertices", [4, 5, 6, 7]);
    postCommand(`{"id":"mesh.collapse"}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8, "undo should restore 8 verts");
    assert(m["faceCount"].integer == 6,   "undo should restore 6 faces");
    foreach (f; m["faces"].array)
        assert(f.array.length == 4, "all faces should be quads after undo");
}

unittest { // undo edge collapse restores the cube
    resetCube();
    postSelect("edges", [0]);
    postCommand(`{"id":"mesh.collapse"}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8,  "undo edge: expected 8 verts");
    assert(m["edgeCount"].integer   == 12, "undo edge: expected 12 edges");
    assert(m["faceCount"].integer   == 6,  "undo edge: expected 6 faces");
}

unittest { // undo polygon collapse restores the cube
    resetCube();
    postSelect("polygons", [1]);
    postCommand(`{"id":"mesh.collapse"}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8, "undo poly: expected 8 verts");
    assert(m["faceCount"].integer   == 6, "undo poly: expected 6 faces");
    foreach (f; m["faces"].array)
        assert(f.array.length == 4, "all faces should be quads after undo");
}
