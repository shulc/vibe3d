// Tests for mesh.makePolygon (Make Polygon command).
//
// Fixture: 4 free coplanar vertices with no faces, loaded via /api/load-mesh.
// All cases use the standard raw-HTTP helpers.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post("http://localhost:8080/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/load-mesh failed: " ~ resp);
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

string postCommandRaw(string body) {
    return cast(string)post("http://localhost:8080/api/command", body);
}

JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue postUndo()  { return parseJSON(post("http://localhost:8080/api/undo", "")); }

// Load a 4-vertex coplanar no-face mesh onto the XY plane
void loadFreeQuadVerts() {
    postLoadMesh(`{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],"faces":[]}`);
}

// Load 3 collinear vertices on the X axis + a 4th off-axis vertex
void loadCollinearPlusFree() {
    postLoadMesh(`{"vertices":[[0,0,0],[1,0,0],[2,0,0],[1,1,0]],"faces":[]}`);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest { // happy path: 4 free verts → quad, winding = [0,1,2,3]
    loadFreeQuadVerts();
    postSelect("vertices", [0, 1, 2, 3]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1,
        "expected 1 face, got " ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 4,
        "expected 4 edges, got " ~ m["edgeCount"].integer.to!string);
    assert(m["vertexCount"].integer == 4,
        "expected 4 verts, got " ~ m["vertexCount"].integer.to!string);
    // Verify winding matches selection order [0,1,2,3]
    auto corners = m["faces"].array[0].array;
    assert(corners.length == 4, "expected quad");
    assert(corners[0].integer == 0 && corners[1].integer == 1 &&
           corners[2].integer == 2 && corners[3].integer == 3,
        "winding mismatch: expected [0,1,2,3]");
}

unittest { // winding follows selection order (non-ascending: [0,3,2,1])
    loadFreeQuadVerts();
    // Select in reverse order: 0 → 3 → 2 → 1
    postSelect("vertices", [0, 3, 2, 1]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1, "expected 1 face");
    auto corners = m["faces"].array[0].array;
    assert(corners.length == 4, "expected quad");
    // Must reflect the exact click order, not sorted ascending
    assert(corners[0].integer == 0 && corners[1].integer == 3 &&
           corners[2].integer == 2 && corners[3].integer == 1,
        "winding must equal click order [0,3,2,1]");
}

unittest { // flip param reverses winding
    loadFreeQuadVerts();
    postSelect("vertices", [0, 1, 2, 3]);
    postCommand(`{"id":"mesh.makePolygon","params":{"flip":true}}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1, "expected 1 face");
    auto corners = m["faces"].array[0].array;
    assert(corners.length == 4, "expected quad");
    // flip reverses [0,1,2,3] → [3,2,1,0]
    assert(corners[0].integer == 3 && corners[1].integer == 2 &&
           corners[2].integer == 1 && corners[3].integer == 0,
        "flip winding mismatch: expected [3,2,1,0]");
}

unittest { // <3 verts selected → no-op (geometry unchanged)
    loadFreeQuadVerts();
    postSelect("vertices", [0, 1]);
    auto m0 = getModel();
    long fc0 = m0["faceCount"].integer;
    long ec0 = m0["edgeCount"].integer;
    // The command is a no-op; the HTTP layer may return error or ok depending
    // on whether the evaluate returns false; check geometry unchanged.
    postCommandRaw(`{"id":"mesh.makePolygon"}`);
    auto m1 = getModel();
    assert(m1["faceCount"].integer == fc0,
        "faceCount must not change on <3 vert reject");
    assert(m1["edgeCount"].integer == ec0,
        "edgeCount must not change on <3 vert reject");
}

unittest { // collinear selection → no-op
    loadCollinearPlusFree();
    // Select the 3 collinear points (indices 0,1,2 on the x-axis)
    postSelect("vertices", [0, 1, 2]);
    auto m0 = getModel();
    postCommandRaw(`{"id":"mesh.makePolygon"}`);
    auto m1 = getModel();
    assert(m1["faceCount"].integer == m0["faceCount"].integer,
        "collinear verts must not produce a face");
}

unittest { // duplicate face → no-op (faceCount stays 1)
    loadFreeQuadVerts();
    postSelect("vertices", [0, 1, 2, 3]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    assert(getModel()["faceCount"].integer == 1, "first make: expected 1 face");
    // Re-select same verts (same unordered set, different order)
    postSelect("vertices", [2, 3, 0, 1]);
    postCommandRaw(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1,
        "duplicate vertex set must not produce a second face");
}

unittest { // edge dedup: shared edge with existing face → only 2 new edges added
    loadFreeQuadVerts();
    // Build first triangle [0,1,2] → 3 edges
    postSelect("vertices", [0, 1, 2]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m1 = getModel();
    assert(m1["faceCount"].integer == 1, "first triangle created");
    long ec1 = m1["edgeCount"].integer;
    assert(ec1 == 3, "triangle should have 3 edges, got " ~ ec1.to!string);
    // Build second triangle [1,3,2] — shares edge 1-2 with first triangle
    postSelect("vertices", [1, 3, 2]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m2 = getModel();
    assert(m2["faceCount"].integer == 2, "second triangle created");
    long ec2 = m2["edgeCount"].integer;
    assert(ec2 == ec1 + 2,
        "expected exactly 2 new edges (shared edge reused), got " ~
        (ec2 - ec1).to!string ~ " new");
}

unittest { // non-convex (concave) click order is accepted as-is
    // 5-vertex concave polygon: v3=(2,1,0) is a reflex vertex.  Selecting
    // vertices in order [0,1,2,3,4] produces a concave face and the command
    // MUST NOT silently reorder to the convex-hull order [0,1,2,4,3].
    postLoadMesh(`{"vertices":[[0,0,0],[4,0,0],[4,4,0],[2,1,0],[0,4,0]],"faces":[]}`);
    postSelect("vertices", [0, 1, 2, 3, 4]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1, "non-convex order must produce exactly 1 face");
    auto corners = m["faces"].array[0].array;
    assert(corners.length == 5, "expected pentagon (5 corners)");
    assert(corners[0].integer == 0 && corners[1].integer == 1 &&
           corners[2].integer == 2 && corners[3].integer == 3 &&
           corners[4].integer == 4,
        "concave click order must not be reordered to convex hull");
}

unittest { // undo restores original empty mesh
    loadFreeQuadVerts();
    postSelect("vertices", [0, 1, 2, 3]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    assert(getModel()["faceCount"].integer == 1, "face created");
    postUndo();
    auto m = getModel();
    assert(m["faceCount"].integer == 0, "undo must remove the face");
    assert(m["edgeCount"].integer == 0, "undo must restore 0 edges");
    assert(m["vertexCount"].integer == 4, "undo must keep the 4 verts");
}
