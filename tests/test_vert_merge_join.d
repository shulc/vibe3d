// Tests for Tier 1.2: vert.merge and vert.join (matching MODO command
// names and argument schema).
//
// Cube layout:
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)

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

// Helper: move v0 to v1's position so they're coincident
void coincidev0v1() {
    postCommand(`{"id":"mesh.move_vertex","params":{"from":[-0.5,-0.5,-0.5],"to":[0.5,-0.5,-0.5]}}`);
}

// ---------------------------------------------------------------------------
// vert.merge
// ---------------------------------------------------------------------------

unittest { // vert.merge range:auto on coincident verts welds them
    resetCube();
    coincidev0v1();   // v0 and v1 now share the same coords
    postSelect("vertices", [0, 1]);
    postCommand(`{"id":"vert.merge","params":{"range":"auto"}}`);
    auto m = getModel();
    // Cube was 8/12/6; v0 and v1 weld → 7 verts. Faces using both v0 and
    // v1 (back, bottom) collapse one edge so they go quad → triangle.
    assert(m["vertexCount"].integer == 7,
        "expected 7 verts after weld, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // vert.merge range:fixed honors dist parameter
    resetCube();
    // Move v0 close to v1 (distance 0.1 in x).
    postCommand(`{"id":"mesh.move_vertex","params":{"from":[-0.5,-0.5,-0.5],"to":[0.4,-0.5,-0.5]}}`);
    postSelect("vertices", [0, 1]);

    // dist=0.05 won't weld → command returns error (no work done).
    auto resp = postCommandRaw(`{"id":"vert.merge","params":{"range":"fixed","dist":0.05}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error when no verts within dist, got: " ~ resp);
    assert(getModel()["vertexCount"].integer == 8, "no-op merge should leave 8 verts");

    // dist=0.2 covers the 0.1 gap → welds.
    postCommand(`{"id":"vert.merge","params":{"range":"fixed","dist":0.2}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 7,
        "dist=0.2 should weld, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // vert.merge with nothing close enough is a no-op error
    resetCube();
    postSelect("vertices", [0, 6]);   // opposite corners — distance ≈ 1.7
    auto resp = postCommandRaw(`{"id":"vert.merge","params":{"range":"fixed","dist":0.1}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "non-coincident merge should error, got: " ~ resp);
    // Mesh unchanged.
    assert(getModel()["vertexCount"].integer == 8);
}

unittest { // undo a vert.merge restores the cube
    resetCube();
    coincidev0v1();
    postSelect("vertices", [0, 1]);
    postCommand(`{"id":"vert.merge","params":{"range":"auto"}}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    // Undoing weld restores 8 verts AND undoes the move (because revert
    // restores from the snap captured at vert.merge apply time, AFTER
    // the move). So we get 8 verts but v0 still at v1's coords.
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
}

// ---------------------------------------------------------------------------
// vert.join
// ---------------------------------------------------------------------------

unittest { // vert.join average:true collapses 4 face verts to centroid
    resetCube();
    // Select front face's 4 corners: v4, v5, v6, v7. Centroid = (0, 0, 0.5).
    postSelect("vertices", [4, 5, 6, 7]);
    postCommand(`{"id":"vert.join","params":{"average":true}}`);
    auto m = getModel();
    // 4 verts → 1 collapsed vert. Plus the 4 originals dropped, replaced
    // by the centroid: 8 - 4 + 1 = 5 verts.
    assert(m["vertexCount"].integer == 5,
        "expected 5 verts, got " ~ m["vertexCount"].integer.to!string);

    // Front face fully collapses (all 4 corners same point) → dropped.
    // Adjacent faces (right/top/left/bottom) each lose 2 of their 4 verts
    // to the centroid → become triangles. Back face untouched (no front
    // verts) → stays a quad.
    int tris = 0, quads = 0;
    foreach (f; m["faces"].array) {
        if (f.array.length == 3) ++tris;
        else if (f.array.length == 4) ++quads;
    }
    assert(quads == 1 && tris == 4,
        "expected 1 quad + 4 tris, got " ~ quads.to!string ~ "q/" ~ tris.to!string ~ "t");

    // Verify the centroid landed at (0, 0, 0.5) — the front face center.
    bool foundCenter = false;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, 0.0)
         && approxEqual(a[1].floating, 0.0)
         && approxEqual(a[2].floating, 0.5)) {
            foundCenter = true;
            break;
        }
    }
    assert(foundCenter, "expected a vert at centroid (0,0,0.5)");
}

unittest { // vert.join average:false uses first selected vert's position
    resetCube();
    // Select v4, v5, v6, v7 (front face). With average=false the target is
    // the first selected = v4 = (-0.5, -0.5, 0.5).
    postSelect("vertices", [4, 5, 6, 7]);
    postCommand(`{"id":"vert.join","params":{"average":false}}`);
    auto m = getModel();
    bool foundCorner = false;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        if (approxEqual(a[0].floating, -0.5)
         && approxEqual(a[1].floating, -0.5)
         && approxEqual(a[2].floating,  0.5)) {
            foundCorner = true;
            break;
        }
    }
    assert(foundCorner, "expected a vert at v4 corner (-0.5,-0.5,0.5)");
}

unittest { // vert.join with single vert is a no-op error
    resetCube();
    postSelect("vertices", [0]);
    auto resp = postCommandRaw(`{"id":"vert.join","params":{"average":true}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "single-vert join should error, got: " ~ resp);
}

unittest { // undo a vert.join restores the cube
    resetCube();
    postSelect("vertices", [4, 5, 6, 7]);
    postCommand(`{"id":"vert.join","params":{"average":true}}`);
    assert(postUndo()["status"].str == "ok");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    foreach (f; m["faces"].array)
        assert(f.array.length == 4, "non-quad after undo");
}
