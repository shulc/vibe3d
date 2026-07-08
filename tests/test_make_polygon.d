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

// Count how many faces in a /api/model response use the (undirected) edge
// (a,b) as a consecutive corner pair. Used to assert manifold-safety
// (an edge must never be used by more than 2 faces).
int edgeUseCount(JSONValue model, int a, int b) {
    int count = 0;
    foreach (f; model["faces"].array) {
        auto corners = f.array;
        foreach (i; 0 .. corners.length) {
            int va = cast(int)corners[i].integer;
            int vb = cast(int)corners[(i + 1) % corners.length].integer;
            if ((va == a && vb == b) || (va == b && vb == a)) { ++count; break; }
        }
    }
    return count;
}

unittest { // manifold-safety guard: reusing an already-saturated edge must
           // reject, not push the edge to 3 faces (task 0316).
    // Default cube: face 0 = [0,3,2,1], face 5 = [0,1,5,4] — both already
    // share edge (0,1). Vertex 6 is the far corner of the top face.
    resetCube();
    postSelect("vertices", [0, 1, 6]);
    auto m0 = getModel();
    long fc0 = m0["faceCount"].integer;
    long ec0 = m0["edgeCount"].integer;
    assert(edgeUseCount(m0, 0, 1) == 2, "sanity: edge (0,1) starts at 2 faces");

    postCommandRaw(`{"id":"mesh.makePolygon","params":{"flip":false}}`);

    auto m1 = getModel();
    assert(m1["faceCount"].integer == fc0,
        "reusing a saturated edge must reject (no new face), got " ~
        m1["faceCount"].integer.to!string ~ " vs " ~ fc0.to!string);
    assert(m1["edgeCount"].integer == ec0,
        "reusing a saturated edge must reject (no new edges)");
    assert(edgeUseCount(m1, 0, 1) == 2,
        "edge (0,1) must remain manifold (exactly 2 faces) after the rejected makePolygon");
}

unittest { // manifold-safety guard: same repro on the other saturated edge
           // documented in the bug report ([2,3,5]).
    resetCube();
    postSelect("vertices", [2, 3, 5]);
    auto m0 = getModel();
    long fc0 = m0["faceCount"].integer;

    postCommandRaw(`{"id":"mesh.makePolygon","params":{"flip":false}}`);

    auto m1 = getModel();
    assert(m1["faceCount"].integer == fc0,
        "reusing a saturated edge must reject, got " ~
        m1["faceCount"].integer.to!string ~ " vs " ~ fc0.to!string);
}

unittest { // legitimate makePolygon on OPEN boundary edges must still succeed:
           // load a cube missing its top face (open boundary quad [4,5,6,7],
           // each of whose 4 edges is currently used by exactly 1 face) and
           // confirm makePolygon closes it back into a manifold cube.
    postLoadMesh(`{"vertices":[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],` ~
                  `[-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]],` ~
                  `"faces":[[0,3,2,1],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4]]}`);
    auto m0 = getModel();
    assert(m0["faceCount"].integer == 5, "fixture must start with 5 faces (open cube)");
    assert(edgeUseCount(m0, 4, 5) == 1, "sanity: top-face edges start open (1 face)");
    assert(edgeUseCount(m0, 6, 7) == 1, "sanity: top-face edges start open (1 face)");

    postSelect("vertices", [4, 5, 6, 7]);
    postCommand(`{"id":"mesh.makePolygon","params":{"flip":false}}`);

    auto m1 = getModel();
    assert(m1["faceCount"].integer == 6,
        "closing the open boundary must succeed, got " ~
        m1["faceCount"].integer.to!string ~ " faces");
    assert(m1["edgeCount"].integer == 12,
        "closing an open boundary reuses all 4 existing edges, expected 12 total, got " ~
        m1["edgeCount"].integer.to!string);
    assert(edgeUseCount(m1, 4, 5) == 2, "top-face edges must now be manifold-closed (2 faces)");
    assert(edgeUseCount(m1, 6, 7) == 2, "top-face edges must now be manifold-closed (2 faces)");
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
