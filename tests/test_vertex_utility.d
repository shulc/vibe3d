// Tests for mesh.addVertex / mesh.centerVertices / mesh.setPosition.
//
// Default cube layout (±0.5 unit cube):
//   v0=(-0.5,-0.5,-0.5)  v1=(+0.5,-0.5,-0.5)  v2=(+0.5,+0.5,-0.5)  v3=(-0.5,+0.5,-0.5)
//   v4=(-0.5,-0.5,+0.5)  v5=(+0.5,-0.5,+0.5)  v6=(+0.5,+0.5,+0.5)  v7=(-0.5,+0.5,+0.5)
// Top face (y=+0.5): v3, v2, v6, v7  (verified in test_vert_merge_join.d as [4,5,6,7]
// refers to the +z face; use /api/model to confirm y coords before asserting).

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

// Find the index of a vertex matching [x,y,z] within eps.
int findVertex(JSONValue model, double x, double y, double z, double eps = 1e-4) {
    foreach (i, v; model["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, x, eps)
         && approxEqual(a[1].floating, y, eps)
         && approxEqual(a[2].floating, z, eps))
            return cast(int)i;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// mesh.addVertex
// ---------------------------------------------------------------------------

unittest { // addVertex adds a vertex at the specified position
    resetCube();
    postCommand(`{"id":"mesh.addVertex","params":{"pos":[1.0,2.0,3.0]}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 9,
        "expected 9 verts after addVertex, got " ~ m["vertexCount"].integer.to!string);
    // The new vertex must be at (1, 2, 3).
    assert(findVertex(m, 1.0, 2.0, 3.0) >= 0,
        "new vertex not found at (1,2,3)");
}

unittest { // addVertex auto-selects the new vertex
    resetCube();
    postCommand(`{"id":"mesh.addVertex","params":{"pos":[1.0,2.0,3.0]}}`);
    auto sel = parseJSON(get("http://localhost:8080/api/selection"));
    // selectedVertices is a JSON array of SELECTED INDICES (built by
    // buildJsonArray which emits only true positions as integer indices).
    auto indices = sel["selectedVertices"].array;
    assert(indices.length == 1,
        "expected 1 selected vertex, got " ~ indices.length.to!string);
    assert(indices[0].integer == 8,
        "expected selected index 8, got " ~ indices[0].integer.to!string);
}

unittest { // undo addVertex restores the original cube
    resetCube();
    postCommand(`{"id":"mesh.addVertex","params":{"pos":[1.0,2.0,3.0]}}`);
    assert(getModel()["vertexCount"].integer == 9);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "expected 8 verts after undo, got " ~ m["vertexCount"].integer.to!string);
    assert(findVertex(m, 1.0, 2.0, 3.0) < 0,
        "vertex (1,2,3) should be gone after undo");
}

unittest { // addVertex at origin adds v at (0,0,0) distinct from cube verts
    resetCube();
    postCommand(`{"id":"mesh.addVertex","params":{"pos":[0.0,0.0,0.0]}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 9);
    assert(findVertex(m, 0.0, 0.0, 0.0) >= 0,
        "vertex at origin not found");
}

// ---------------------------------------------------------------------------
// mesh.centerVertices — helpers
// ---------------------------------------------------------------------------

// Returns all vertex positions as an array of [x,y,z] triples.
double[3][] allVertices(JSONValue model) {
    double[3][] r;
    foreach (v; model["vertices"].array)
        r ~= [v.array[0].floating, v.array[1].floating, v.array[2].floating];
    return r;
}

// Collect the indices of vertices with the given y-coordinate (within eps).
int[] indicesWithY(JSONValue model, double y, double eps = 1e-4) {
    int[] r;
    foreach (i, v; model["vertices"].array)
        if (approxEqual(v.array[1].floating, y, eps)) r ~= cast(int)i;
    return r;
}

// ---------------------------------------------------------------------------
// mesh.centerVertices
// ---------------------------------------------------------------------------

unittest { // centerVertices axis:y zeros y component of selected verts
    resetCube();
    // Identify the 4 verts at y=+0.5 from the live model (safe for any index order).
    auto m0 = getModel();
    auto topIdx = indicesWithY(m0, 0.5);
    assert(topIdx.length == 4,
        "expected 4 verts at y=+0.5, got " ~ topIdx.length.to!string);

    postSelect("vertices", topIdx);
    postCommand(`{"id":"mesh.centerVertices","params":{"axis":"y"}}`);

    auto m = getModel();
    // Vertex count must be unchanged (no welding).
    assert(m["vertexCount"].integer == 8,
        "centerVertices must not weld — expected 8 verts, got "
        ~ m["vertexCount"].integer.to!string);
    // All four former top verts must now have y == 0; x/z must be unchanged.
    auto verts0 = allVertices(m0);
    auto verts1 = allVertices(m);
    foreach (idx; topIdx) {
        assert(approxEqual(verts1[idx][1], 0.0),
            "vert " ~ idx.to!string ~ " y expected 0, got " ~ verts1[idx][1].to!string);
        // x and z unchanged
        assert(approxEqual(verts1[idx][0], verts0[idx][0]),
            "vert " ~ idx.to!string ~ " x changed unexpectedly");
        assert(approxEqual(verts1[idx][2], verts0[idx][2]),
            "vert " ~ idx.to!string ~ " z changed unexpectedly");
    }
    // The 4 bottom verts (y=-0.5) must be untouched.
    auto botIdx = indicesWithY(m0, -0.5);
    foreach (idx; botIdx)
        assert(approxEqual(verts1[idx][1], -0.5),
            "bottom vert " ~ idx.to!string ~ " was modified");
}

unittest { // centerVertices proves zero-not-average (mean y=+0.5, not 0)
    // If the command were computing an average it would move top verts to the
    // centroid of the whole mesh (which is 0) — same result as zeroing.
    // Use a non-symmetric selection: select only the 4 top verts (mean y=+0.5).
    // A zero-to-origin op yields y=0; an average op also yields y=0 in this case.
    // To discriminate: shift one top vert to y=+1.0 first so the 4-vert mean
    // becomes (0.5+0.5+0.5+1.0)/4 = 0.625.  Zero-to-origin still yields y=0;
    // average would yield y=0.625.
    resetCube();
    auto m0 = getModel();
    auto topIdx = indicesWithY(m0, 0.5);
    // Move one top vert to y=1.0.
    postCommand(`{"id":"mesh.move_vertex","params":{"from":[-0.5,0.5,-0.5],"to":[-0.5,1.0,-0.5]}}`);

    postSelect("vertices", topIdx);
    postCommand(`{"id":"mesh.centerVertices","params":{"axis":"y"}}`);

    auto m = getModel();
    auto verts1 = allVertices(m);
    foreach (idx; topIdx)
        assert(approxEqual(verts1[idx][1], 0.0),
            "expected y=0 (zero-to-origin), got " ~ verts1[idx][1].to!string);
}

unittest { // centerVertices axis:x zeros x only
    resetCube();
    postSelect("vertices", [0, 1]);   // v0=(-0.5,-0.5,-0.5), v1=(+0.5,-0.5,-0.5)
    postCommand(`{"id":"mesh.centerVertices","params":{"axis":"x"}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    auto verts = allVertices(m);
    assert(approxEqual(verts[0][0], 0.0), "v0 x should be 0");
    assert(approxEqual(verts[1][0], 0.0), "v1 x should be 0");
    // y and z must be unchanged.
    assert(approxEqual(verts[0][1], -0.5), "v0 y changed");
    assert(approxEqual(verts[0][2], -0.5), "v0 z changed");
}

unittest { // centerVertices axis:all zeros all three components
    resetCube();
    postSelect("vertices", [0]);   // v0=(-0.5,-0.5,-0.5)
    postCommand(`{"id":"mesh.centerVertices","params":{"axis":"all"}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    auto verts = allVertices(m);
    assert(approxEqual(verts[0][0], 0.0), "v0 x should be 0");
    assert(approxEqual(verts[0][1], 0.0), "v0 y should be 0");
    assert(approxEqual(verts[0][2], 0.0), "v0 z should be 0");
}

unittest { // centerVertices no-op when nothing selected
    resetCube();
    // No postSelect — vertex selection is empty after reset.
    auto resp = postCommandRaw(`{"id":"mesh.centerVertices","params":{"axis":"y"}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error with empty selection, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 8);
}

unittest { // centerVertices unknown axis is a no-op error
    resetCube();
    postSelect("vertices", [0]);
    auto resp = postCommandRaw(`{"id":"mesh.centerVertices","params":{"axis":"w"}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error for unknown axis, got: " ~ resp);
}

unittest { // undo centerVertices restores original positions
    resetCube();
    auto m0 = getModel();
    auto topIdx = indicesWithY(m0, 0.5);
    postSelect("vertices", topIdx);
    postCommand(`{"id":"mesh.centerVertices","params":{"axis":"y"}}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    auto verts = allVertices(m);
    foreach (idx; topIdx)
        assert(approxEqual(verts[idx][1], 0.5),
            "vert " ~ idx.to!string ~ " y not restored after undo");
}

// ---------------------------------------------------------------------------
// mesh.setPosition
// ---------------------------------------------------------------------------

unittest { // setPosition moves a single selected vertex to the exact param
    resetCube();
    postSelect("vertices", [0]);   // v0=(-0.5,-0.5,-0.5)
    postCommand(`{"id":"mesh.setPosition","params":{"pos":[1.0,2.0,3.0]}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "setPosition must not weld — expected 8 verts");
    auto verts = allVertices(m);
    assert(approxEqual(verts[0][0], 1.0), "v0 x expected 1.0");
    assert(approxEqual(verts[0][1], 2.0), "v0 y expected 2.0");
    assert(approxEqual(verts[0][2], 3.0), "v0 z expected 3.0");
    // Other verts unchanged — v1=(+0.5,-0.5,-0.5)
    assert(approxEqual(verts[1][0], 0.5),  "v1 x should be unchanged");
    assert(approxEqual(verts[1][1], -0.5), "v1 y should be unchanged");
    assert(approxEqual(verts[1][2], -0.5), "v1 z should be unchanged");
}

unittest { // setPosition moves ALL selected vertices to the same point
    resetCube();
    // Select two verts that are far apart; both must land at the same target.
    postSelect("vertices", [0, 6]);   // v0=(-0.5,-0.5,-0.5), v6=(+0.5,+0.5,+0.5)
    postCommand(`{"id":"mesh.setPosition","params":{"pos":[0.0,0.0,0.0]}}`);
    auto m = getModel();
    // Both verts at origin but no weld — vertex count still 8.
    assert(m["vertexCount"].integer == 8,
        "setPosition must not weld even when verts coincide — expected 8, got "
        ~ m["vertexCount"].integer.to!string);
    auto verts = allVertices(m);
    assert(approxEqual(verts[0][0], 0.0) && approxEqual(verts[0][1], 0.0) && approxEqual(verts[0][2], 0.0),
        "v0 should be at origin");
    assert(approxEqual(verts[6][0], 0.0) && approxEqual(verts[6][1], 0.0) && approxEqual(verts[6][2], 0.0),
        "v6 should be at origin");
}

unittest { // setPosition no-op when nothing selected
    resetCube();
    auto resp = postCommandRaw(`{"id":"mesh.setPosition","params":{"pos":[1.0,2.0,3.0]}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error with empty selection, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 8);
}

unittest { // undo setPosition restores original positions
    resetCube();
    postSelect("vertices", [0, 6]);
    postCommand(`{"id":"mesh.setPosition","params":{"pos":[0.0,0.0,0.0]}}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    auto verts = allVertices(m);
    // v0 restored to (-0.5,-0.5,-0.5)
    assert(approxEqual(verts[0][0], -0.5), "v0 x not restored");
    assert(approxEqual(verts[0][1], -0.5), "v0 y not restored");
    assert(approxEqual(verts[0][2], -0.5), "v0 z not restored");
    // v6 restored to (+0.5,+0.5,+0.5)
    assert(approxEqual(verts[6][0], 0.5), "v6 x not restored");
    assert(approxEqual(verts[6][1], 0.5), "v6 y not restored");
    assert(approxEqual(verts[6][2], 0.5), "v6 z not restored");
}
