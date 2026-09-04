// Tests for mesh.makePolygon (Make Polygon command).
//
// Fixture: 4 free coplanar vertices with no faces, loaded via /api/load-mesh.
// All cases use the standard raw-HTTP helpers.
//
// TASK 1200 REVERSED FOUR OF THESE. This command used to refuse a zero-area
// ring, a two-corner ring, a duplicate face and a face on a saturated edge; the
// reference editor refuses none of them (ledger row 7), the owner's call
// (2026-08-18) was to match it, and the four cases below now assert that each
// one is BUILT. They are asserted by shape and by count, not merely by "the
// command returned ok", because "ok" is what a command that silently did
// nothing would also return.
//
// The KERNEL still has all four refusals — `Mesh.MakePolyGates`, default `all`,
// pinned per-flag in tests/unit/mesh_test.d. Only this command asks for `none`.
// The Topology Pen goes through the same kernel with the default and relies on
// the zero-area refusal, which is why the flag exists instead of a deletion.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post(testBaseUrl() ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post(testBaseUrl() ~ "/api/command", commandBody("scene.loadMesh", body));
    assert(parseJSON(resp)["status"].str == "ok", "/api/load-mesh failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(testBaseUrl() ~ "/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`));
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post(testBaseUrl() ~ "/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

string postCommandRaw(string body) {
    return cast(string)post(testBaseUrl() ~ "/api/command", body);
}

JSONValue getModel() { return parseJSON(get(testBaseUrl() ~ "/api/model")); }
JSONValue postUndo()  { return parseJSON(post(testBaseUrl() ~ "/api/undo", "")); }

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

unittest { // TWO verts selected → a 2-point polygon (task 1200, ledger row 7)
    loadFreeQuadVerts();
    postSelect("vertices", [0, 1]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1,
        "two selected verts must BUILD a face, got " ~
        m["faceCount"].integer.to!string);
    auto corners = m["faces"].array[0].array;
    assert(corners.length == 2,
        "and it must keep BOTH corners, not be padded to a triangle, got " ~
        corners.length.to!string);
    assert(corners[0].integer == 0 && corners[1].integer == 1,
        "the ring follows the selection order");
    assert(m["edgeCount"].integer == 1,
        "a 2-corner ring has ONE edge, not two: its two darts share a key");
    assert(m["vertexCount"].integer == 4, "no vertex is created or lost");
}

unittest { // ...and ONE vert is still refused. The floor is not a gate.
    loadFreeQuadVerts();
    postSelect("vertices", [0]);
    auto m0 = getModel();
    postCommandRaw(`{"id":"mesh.makePolygon"}`);
    auto m1 = getModel();
    assert(m1["faceCount"].integer == m0["faceCount"].integer,
        "a single vertex must not produce a face — a one-corner polygon is a "
        ~ "shape nobody has measured on either engine");
    assert(m1["edgeCount"].integer == m0["edgeCount"].integer,
        "and must not produce an edge either");
}

unittest { // collinear selection → a zero-area triangle (task 1200, row 7)
    loadCollinearPlusFree();
    // Select the 3 collinear points (indices 0,1,2 on the x-axis)
    postSelect("vertices", [0, 1, 2]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1,
        "three collinear verts must BUILD the triangle, got " ~
        m["faceCount"].integer.to!string);
    auto corners = m["faces"].array[0].array;
    assert(corners.length == 3, "a triangle, with all three corners kept");
    assert(corners[0].integer == 0 && corners[1].integer == 1 &&
           corners[2].integer == 2, "ring follows the selection order");
    assert(m["edgeCount"].integer == 3,
        "and it carries three edges — including the long one, 0-2, that the "
        ~ "other two lie on");
}

unittest { // bow-tie click order → a self-intersecting quad (task 1200, row 7)
    // The same four points in ring order build a clean quad; the ORDER is the
    // independent variable. What refused this before was the ZERO-AREA gate:
    // a bow-tie over a square has a Newell normal of exactly zero, the two
    // lobes being equal and opposite.
    loadFreeQuadVerts();
    postSelect("vertices", [0, 2, 1, 3]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 1, "the bow-tie must be built as given");
    auto corners = m["faces"].array[0].array;
    assert(corners.length == 4, "four corners");
    assert(corners[0].integer == 0 && corners[1].integer == 2 &&
           corners[2].integer == 1 && corners[3].integer == 3,
        "the ring is the CLICK order, crossing and all — not re-sorted into a "
        ~ "simple polygon");
    assert(m["edgeCount"].integer == 4,
        "four edges, two of which cross in space");
}

unittest { // duplicate face → a SECOND face on the same ring (task 1200, row 7)
    loadFreeQuadVerts();
    postSelect("vertices", [0, 1, 2, 3]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m0 = getModel();
    assert(m0["faceCount"].integer == 1, "first make: expected 1 face");
    assert(m0["edgeCount"].integer == 4, "first make: expected 4 edges");
    // Re-select the same verts (same unordered set, different order)
    postSelect("vertices", [2, 3, 0, 1]);
    postCommand(`{"id":"mesh.makePolygon"}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 2,
        "the duplicate vertex set must produce a SECOND face, got " ~
        m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 4,
        "and it must add no edge at all — every one of its edges already "
        ~ "existed, which is the half of ledger row 7 a face count cannot see");
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

unittest { // task 0316's manifold-safety guard, REVERSED by task 1200: reusing
           // an already-saturated edge now BUILDS, and the edge goes to 3 faces.
    // Default cube: face 0 = [0,3,2,1], face 5 = [0,1,5,4] — both already
    // share edge (0,1). Vertex 6 is the far corner of the top face.
    //
    // The guard came off because the reference has none: its Make Polygon
    // builds a duplicate face on the ring of an existing one (ledger row 7,
    // `duplicate_over_existing_face`), and there the shared edge of the two
    // plate quads is already saturated too — the duplicate gate and this one
    // both had to go for that single cell to converge.
    //
    // The mesh this leaves is non-manifold, and that is measured here rather
    // than assumed: `edgeUseCount` reads 3. `Mesh.buildLoops` survives it
    // (Treatment A leaves all three darts of such an edge twinless), which is
    // why the state is degraded rather than corrupt. The readers that ARE
    // degraded by it are listed in doc/tasks/work/1200-ref-refusals.md.
    resetCube();
    postSelect("vertices", [0, 1, 6]);
    auto m0 = getModel();
    long fc0 = m0["faceCount"].integer;
    long ec0 = m0["edgeCount"].integer;
    assert(edgeUseCount(m0, 0, 1) == 2, "sanity: edge (0,1) starts at 2 faces");

    postCommand(`{"id":"mesh.makePolygon","params":{"flip":false}}`);

    auto m1 = getModel();
    assert(m1["faceCount"].integer == fc0 + 1,
        "reusing a saturated edge must now BUILD one new face, got " ~
        m1["faceCount"].integer.to!string ~ " vs " ~ fc0.to!string);
    assert(m1["edgeCount"].integer == ec0 + 2,
        "the triangle [0,1,6] reuses edge (0,1) and adds the two new ones, "
        ~ "expected " ~ (ec0 + 2).to!string ~ " got " ~
        m1["edgeCount"].integer.to!string);
    assert(edgeUseCount(m1, 0, 1) == 3,
        "edge (0,1) now carries THREE faces — the non-manifold result the "
        ~ "owner chose to allow");
}

unittest { // same repro on the other saturated edge documented in the 0316 bug
           // report ([2,3,5]) — also builds now.
    resetCube();
    postSelect("vertices", [2, 3, 5]);
    auto m0 = getModel();
    long fc0 = m0["faceCount"].integer;

    postCommand(`{"id":"mesh.makePolygon","params":{"flip":false}}`);

    auto m1 = getModel();
    assert(m1["faceCount"].integer == fc0 + 1,
        "reusing a saturated edge must now build, got " ~
        m1["faceCount"].integer.to!string ~ " vs " ~ fc0.to!string);
    assert(edgeUseCount(m1, 2, 3) == 3,
        "edge (2,3) now carries three faces");
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
