// test_bridge.d — smoke tests for the mesh.bridge command.
//
// Two-cap fixture (loaded via /api/load-mesh): two coaxial unit squares.
//   Vertices (8):
//     Cap A (z=0): 0(0,0,0) 1(1,0,0) 2(1,1,0) 3(0,1,0)
//     Cap B (z=1): 4(0,0,1) 5(1,0,1) 6(1,1,1) 7(0,1,1)
//   Faces (2): 0 = cap A [0,1,2,3], 1 = cap B [4,5,6,7]
//
//   Edge-mode bridge (select both rim loops): bridges then DELETES both caps
//   (each rim loop exactly bounds one cap face), leaving the 4 quad rungs → 4
//   faces, 8 verts (open tube). Matches the reference editor's edge.bridge and
//   vibe3d's mesh.bridgeTool (task 0467 — was 6 faces before the edge-branch
//   learned to remove the bounding caps like the Polygon branch already did).
//   Polygon-mode bridge (select both faces): bridges then DELETES both caps,
//   leaving the 4 quad rungs → 4 faces, 8 verts (open tube).

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

JSONValue postCmd(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

// Load the two-cap fixture: 8 verts, 2 quad faces (one per cap).
void loadCaps() {
    auto r = postCmd("/api/load-mesh", `{
        "vertices": [
            [0,0,0],[1,0,0],[1,1,0],[0,1,0],
            [0,0,1],[1,0,1],[1,1,1],[0,1,1]
        ],
        "faces": [
            [0,1,2,3],
            [4,5,6,7]
        ]
    }`);
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

void setSelection(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices)
        idxJson ~= (i > 0 ? "," : "") ~ v.to!string;
    idxJson ~= "]";
    auto r = postCmd("/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

void runCmd(string id) {
    auto r = postCmd("/api/command", `{"id":"` ~ id ~ `"}`);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command " ~ id ~ " failed: " ~ r.toString);
}

JSONValue model() {
    return parseJSON(cast(string)get(BASE ~ "/api/model"));
}

size_t faceCount() {
    return model()["faces"].array.length;
}

long vertCount() {
    return model()["vertexCount"].integer;
}

// face-vertex-count histogram, e.g. {4: 6}.
int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

// vertex indices not referenced by any face.
int[] orphanVerts(JSONValue m) {
    bool[] refd;
    refd.length = cast(size_t)m["vertexCount"].integer;
    foreach (f; m["faces"].array)
        foreach (c; f.array) {
            auto vi = cast(size_t)c.integer;
            if (vi < refd.length) refd[vi] = true;
        }
    int[] orph;
    foreach (i; 0 .. refd.length) if (!refd[i]) orph ~= cast(int)i;
    return orph;
}

// edge indices whose both endpoints fall in cap A (verts 0-3).
int[] capAEdges(JSONValue m) {
    int[] res;
    foreach (i, e; m["edges"].array) {
        int a = cast(int)e.array[0].integer;
        int b = cast(int)e.array[1].integer;
        if (a < 4 && b < 4) res ~= cast(int)i;
    }
    return res;
}

// edge indices whose both endpoints fall in cap B (verts 4-7).
int[] capBEdges(JSONValue m) {
    int[] res;
    foreach (i, e; m["edges"].array) {
        int a = cast(int)e.array[0].integer;
        int b = cast(int)e.array[1].integer;
        if (a >= 4 && b >= 4) res ~= cast(int)i;
    }
    return res;
}

// Count of bridge quads whose computed normal points outward from the tube axis
// at (axX, axY).  Vertex positions are taken from the standard 8-vertex fixture
// (verts 0-7 at the positions declared in loadCaps / the opposite-handed variant).
// Caller must ensure all faces in m are quads and all vertex indices are 0-7.
int outwardNormals(JSONValue m, float axX = 0.5f, float axY = 0.5f) {
    static immutable float[3][8] kV = [
        [0,0,0],[1,0,0],[1,1,0],[0,1,0],
        [0,0,1],[1,0,1],[1,1,1],[0,1,1]
    ];
    int ok = 0;
    foreach (f; m["faces"].array) {
        auto vi = f.array;
        int a = cast(int)vi[0].integer, b = cast(int)vi[1].integer;
        int c = cast(int)vi[2].integer, d = cast(int)vi[3].integer;
        // normal = cross(B-A, D-A)
        float e1x = kV[b][0]-kV[a][0], e1y = kV[b][1]-kV[a][1], e1z = kV[b][2]-kV[a][2];
        float e2x = kV[d][0]-kV[a][0], e2y = kV[d][1]-kV[a][1], e2z = kV[d][2]-kV[a][2];
        float nx = e1y*e2z - e1z*e2y;
        float ny = e1z*e2x - e1x*e2z;
        // centroid xy
        float cx = (kV[a][0]+kV[b][0]+kV[c][0]+kV[d][0]) * 0.25f;
        float cy = (kV[a][1]+kV[b][1]+kV[c][1]+kV[d][1]) * 0.25f;
        if (nx*(cx-axX) + ny*(cy-axY) > 0.0f) ok++;
    }
    return ok;
}

// ---------------------------------------------------------------------------
// edge-mode bridge: 2 rim loops → 4 quad rungs, caps DELETED (4 faces)
// ---------------------------------------------------------------------------

unittest { // edge-mode bridge: 2 closed 4-cycles → 4 faces, 8 verts, all quads.
           // Each rim loop exactly bounds one cap face, so the mesh.bridge
           // COMMAND removes both caps just like its Polygon branch, the
           // mesh.bridgeTool, and the reference editor's edge.bridge — captured
           // ground truth: two-cap edge.bridge → 8v/4f (task 0467). Was 8v/6f
           // (caps kept) before the edge-branch fix.
    loadCaps();
    setSelection("edges", []);  // switch to edge mode

    auto m0 = model();
    assert(m0["faces"].array.length == 2, "fixture starts with 2 caps");
    assert(m0["vertexCount"].integer == 8, "fixture has 8 verts");

    auto ea = capAEdges(m0);
    auto eb = capBEdges(m0);
    assert(ea.length == 4, "cap A has 4 rim edges");
    assert(eb.length == 4, "cap B has 4 rim edges");
    setSelection("edges", ea ~ eb);

    runCmd("mesh.bridge");

    auto m1 = model();
    assert(m1["faces"].array.length == 4,
        "expected 4 faces after edge bridge (caps removed), got " ~
        m1["faces"].array.length.to!string);
    assert(m1["vertexCount"].integer == 8, "no new verts after edge bridge");
    assert(fvDist(m1).get(4, 0) == 4, "all 4 faces must be quads");
    assert(orphanVerts(m1).length == 0, "no orphan vertices");

    runCmd("history.undo");
    auto m2 = model();
    assert(m2["faces"].array.length == 2, "undo restores 2 cap faces");
    assert(m2["vertexCount"].integer == 8, "undo restores 8 verts");
}

// ---------------------------------------------------------------------------
// polygon-mode bridge: 2 selected caps → 4 quad rungs, caps deleted (4 faces)
// ---------------------------------------------------------------------------

unittest { // polygon-mode bridge: caps gone, 4 quads remain
    loadCaps();
    setSelection("polygons", [0, 1]);

    runCmd("mesh.bridge");

    auto m1 = model();
    assert(m1["faces"].array.length == 4,
        "expected 4 faces after polygon bridge, got " ~
        m1["faces"].array.length.to!string);
    assert(m1["vertexCount"].integer == 8, "no new verts after polygon bridge");
    assert(fvDist(m1).get(4, 0) == 4, "all 4 faces must be quads");
    assert(orphanVerts(m1).length == 0, "no orphan vertices");

    runCmd("history.undo");
    auto m2 = model();
    assert(m2["faces"].array.length == 2, "undo restores 2 cap faces");
    assert(m2["vertexCount"].integer == 8, "undo restores 8 verts");
}

// ---------------------------------------------------------------------------
// flip parameter: accepted, still produces a valid bridge
// ---------------------------------------------------------------------------

unittest { // flip=true accepted and still bridges (caps removed → 4 faces).
           // flip only reverses the bridge pairing direction; the two rim
           // loops still each bound a cap, so both caps are removed (task 0467).
    loadCaps();
    setSelection("edges", []);
    auto m0 = model();
    setSelection("edges", capAEdges(m0) ~ capBEdges(m0));

    auto r = postCmd("/api/command", `{"id":"mesh.bridge","flip":true}`);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "mesh.bridge with flip=true failed: " ~ r.toString);
    auto m1 = model();
    assert(m1["faces"].array.length == 4,
        "expected 4 faces with flip (caps removed), got " ~ m1["faces"].array.length.to!string);
    assert(m1["vertexCount"].integer == 8, "no new verts with flip");
}

// ---------------------------------------------------------------------------
// single-loop rejection: only one edge cycle → clean no-op
// ---------------------------------------------------------------------------

unittest { // selecting only one cap's rim is not bridgeable
    loadCaps();
    setSelection("edges", []);
    auto m0 = model();
    setSelection("edges", capAEdges(m0));  // one cycle only

    // Must not crash; mesh stays unchanged.
    postCmd("/api/command", `{"id":"mesh.bridge"}`);
    auto m1 = model();
    assert(m1["faces"].array.length == 2, "single-loop selection is a no-op");
    assert(m1["vertexCount"].integer == 8, "vertex count unchanged");
}

// ---------------------------------------------------------------------------
// task 0395: mesh.bridge COMMAND accepts OPEN edge rows (owner repro) +
// single-open-chain no-op. See tests/fixtures/bridge_open_rows.json for the
// same contract driven through mesh.bridgeTool; this exercises the
// PRE-EXISTING one-shot mesh.bridge command entry point, which reported the
// original bug (:9000, 2026-07-14): the edge-mode branch used to require
// exactly 2 CLOSED edge cycles and silently no-op'd on open rows.
// ---------------------------------------------------------------------------

// find the edge index whose endpoints are the unordered vertex-index pair (a,b).
int findEdgeIdx(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int ea = cast(int)e.array[0].integer, eb = cast(int)e.array[1].integer;
        if ((ea == a && eb == b) || (ea == b && eb == a)) return cast(int)i;
    }
    return -1;
}

// cube minus 2 adjacent faces (right x=+0.5, back y=+0.5): 8v/4f/11e.
void loadOpenHoleCube() {
    auto r = postCmd("/api/load-mesh", `{
        "vertices": [
            [-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
            [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]
        ],
        "faces": [
            [0,3,2,1],
            [4,5,6,7],
            [0,4,7,3],
            [0,1,5,4]
        ]
    }`);
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

unittest { // owner repro: two 2-edge open arcs -> mesh.bridge reconstructs
           // the 2 deleted faces on EXISTING verts (8v/4f -> 8v/6f).
    loadOpenHoleCube();
    auto m0 = model();
    assert(m0["faces"].array.length == 4, "owner repro fixture starts with 4 faces");
    assert(m0["vertexCount"].integer == 8, "owner repro fixture has 8 verts");

    int e32 = findEdgeIdx(m0, 3, 2), e21 = findEdgeIdx(m0, 2, 1);
    int e56 = findEdgeIdx(m0, 5, 6), e67 = findEdgeIdx(m0, 6, 7);
    assert(e32 >= 0 && e21 >= 0 && e56 >= 0 && e67 >= 0,
        "owner repro: all 4 boundary edges must exist");

    setSelection("edges", []);  // switch to edge mode
    setSelection("edges", [e32, e21, e56, e67]);

    runCmd("mesh.bridge");

    auto m1 = model();
    assert(m1["faces"].array.length == 6,
        "owner repro: expected 6 faces (8v/4f -> 8v/6f), got " ~
        m1["faces"].array.length.to!string);
    assert(m1["vertexCount"].integer == 8, "owner repro: no new verts");
    assert(fvDist(m1).get(4, 0) == 6, "owner repro: all 6 faces must be quads");
    assert(orphanVerts(m1).length == 0, "owner repro: no orphan vertices");

    runCmd("history.undo");
    auto m2 = model();
    assert(m2["faces"].array.length == 4, "owner repro: undo restores 4 faces");
    assert(m2["vertexCount"].integer == 8, "owner repro: undo restores 8 verts");
}

unittest { // single open chain, nothing else selected -> mesh.bridge command is a no-op
    loadOpenHoleCube();
    auto m0 = model();
    int e32 = findEdgeIdx(m0, 3, 2), e21 = findEdgeIdx(m0, 2, 1);
    assert(e32 >= 0 && e21 >= 0, "single-chain no-op: boundary edges must exist");

    setSelection("edges", []);
    setSelection("edges", [e32, e21]);  // one open chain only, no second group

    postCmd("/api/command", `{"id":"mesh.bridge"}`);
    auto m1 = model();
    assert(m1["faces"].array.length == 4, "single open chain: mesh.bridge must be a no-op");
    assert(m1["vertexCount"].integer == 8, "single open chain: vertex count unchanged");
}

// ---------------------------------------------------------------------------
// opposite-handed winding: auto-heuristic produces consistent outward normals
// ---------------------------------------------------------------------------
//
// The common real-world case when bridging two open holes of a closed solid is
// that the two boundary loops face in OPPOSITE directions (top-cap normal +z,
// bottom-cap normal −z).  This exercises the min-paired-distance heuristic and
// confirms that flip=false (the default) is the correct choice: the heuristic
// picks the reverse-direction pairing, which gives geometrically consistent
// outward-facing quads.  flip=true would force the forward (mismatched)
// direction and produce twisted quads — it is NOT needed for this case.

unittest { // opposite-handed polygon bridge: auto-heuristic produces consistent outward normals
    // loopA [0,1,2,3] at z=0: CCW from +z → normal = +z.
    // loopB [4,7,6,5] at z=1: CW from +z  → normal = −z (opposite to loopA).
    // Same 8 vertex positions as loadCaps; only the winding of cap B is reversed.
    auto r = postCmd("/api/load-mesh", `{
        "vertices": [
            [0,0,0],[1,0,0],[1,1,0],[0,1,0],
            [0,0,1],[1,0,1],[1,1,1],[0,1,1]
        ],
        "faces": [
            [0,1,2,3],
            [4,7,6,5]
        ]
    }`);
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);

    // Polygon-mode bridge: both faces selected; caps are deleted, 4 lateral
    // quads remain.
    setSelection("polygons", [0, 1]);
    runCmd("mesh.bridge");

    auto m1 = model();
    assert(m1["faces"].array.length == 4,
        "expected 4 lateral quads after opposite-handed polygon bridge, got " ~
        m1["faces"].array.length.to!string);
    assert(m1["vertexCount"].integer == 8, "no new verts after opposite-handed bridge");
    assert(fvDist(m1).get(4, 0) == 4, "all 4 faces must be quads");
    assert(orphanVerts(m1).length == 0, "no orphan verts");

    // All 4 quad normals must point outward from the tube axis (x=0.5, y=0.5).
    // The auto min-paired-distance heuristic correctly handles the opposite-
    // handed case without needing flip=true.
    int ok = outwardNormals(m1);
    assert(ok == 4,
        "auto-heuristic: expected 4/4 outward normals for opposite-handed loops, got " ~
        ok.to!string ~ "/4");

    runCmd("history.undo");
    auto m2 = model();
    assert(m2["faces"].array.length == 2, "undo restores 2 cap faces");
    assert(m2["vertexCount"].integer == 8, "undo restores 8 verts");
}
