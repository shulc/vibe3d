// Tests for mesh.addLoop and mesh.loopSlice commands.
//
// Both commands walk a quad ring from the first selected edge and split each
// crossed quad with new mid-edge vertices connected by new rung edges.
// mesh.addLoop inserts one loop at a parametric position (default 0.5).
// mesh.loopSlice inserts N evenly-spaced loops (default count=3).
//
// Connectivity is asserted by:
//   - vertex / edge / face counts + Euler characteristic (V-E+F)
//   - all faces are quads after the operation
//   - specific rung edges exist (looked up by endpoint pair via edgeIdx)
//   - specific sub-quads exist (looked up by vertex set via faceWithVerts)
//   - midpoint position via vertNear
//
// Counts + Euler alone cannot catch a twisted loop (Risk 2 in the plan).
// Edge indices are looked up by endpoint pair — they shift after rebuildEdges.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ----- HTTP helpers ----------------------------------------------------------

void postReset() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post("http://localhost:8080/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/load-mesh failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    import std.array : appender;
    auto s = appender!string("[");
    foreach (i, v; indices) { if (i > 0) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ s.data ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/select failed: " ~ resp);
}

/// Post command with params JSON (e.g. `{"count":3}`).  Asserts ok.
void postCommandParams(string id, string paramsJson) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
           id ~ " failed: " ~ resp);
}

JSONValue postCommandRaw(string id) {
    return parseJSON(post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`));
}

void postCommand(string id) {
    auto r = postCommandRaw(id);
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

// ----- Connectivity helpers --------------------------------------------------

/// Index of the undirected edge {a,b} in model["edges"], or -1.
int edgeIdx(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

/// True if any face in model["faces"] has exactly the vertex set {vs}.
bool faceWithVerts(JSONValue m, int[] vs) {
    outer: foreach (f; m["faces"].array) {
        if (f.array.length != vs.length) continue;
        bool[int] fset;
        foreach (v; f.array) fset[cast(int)v.integer] = true;
        foreach (v; vs) if (v !in fset) continue outer;
        return true;
    }
    return false;
}

/// Vertex index whose position is within eps of (x,y,z), or -1.
int vertNear(JSONValue m, float x, float y, float z, float eps = 1e-3f) {
    import std.math : abs;
    foreach (i, v; m["vertices"].array) {
        float vx = cast(float)v.array[0].floating;
        float vy = cast(float)v.array[1].floating;
        float vz = cast(float)v.array[2].floating;
        if (abs(vx - x) < eps && abs(vy - y) < eps && abs(vz - z) < eps)
            return cast(int)i;
    }
    return -1;
}

/// True when every face in the model is a quad.
bool allQuads(JSONValue m) {
    foreach (f; m["faces"].array)
        if (f.array.length != 4) return false;
    return true;
}

// ----- Default cube in edge mode  -------------------------------------------
// The default cube has 8 vertices and 12 edges.  We select a belt edge
// (any edge shared by two non-cap quad faces) to trigger a closed-ring walk.
// Belt edges connect the cap planes; on the default cube they are 0-1, 0-3,
// 1-2, 2-3 (bottom cap) and their counterparts.  We use edgeIdx to look up
// index by endpoint pair — indices shift after rebuildEdges so we never
// hard-code them.

// ---------------------------------------------------------------------------
// Case 1 — mesh.addLoop on default cube (closed ring).
//   Seed = belt edge 0-1.  One loop at default position 0.5.
//   Expected: V=12, E=20, F=10, Euler=2, all quads.
//   Connectivity: rung edges mA–mB–mC–mD–mA, sub-quad {0,mA,mB,3} or
//   {mA,1,2,mB}, midpoint of 0-1 at x=0.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["edgeCount"].integer   == 12);
    assert(before["faceCount"].integer   == 6);

    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0, "belt edge 0-1 must exist on default cube");
    postSelect("edges", [eiSeed]);

    postCommand("mesh.addLoop");

    auto after = getModel();
    assert(after["vertexCount"].integer == 12, "V must be 12 after addLoop");
    assert(after["edgeCount"].integer   == 20, "E must be 20 after addLoop");
    assert(after["faceCount"].integer   == 10, "F must be 10 after addLoop");
    assert(cast(int)after["vertexCount"].integer
           - cast(int)after["edgeCount"].integer
           + cast(int)after["faceCount"].integer == 2, "Euler must be 2");
    assert(allQuads(after), "all faces must be quads after addLoop");

    // Midpoint of edge 0-1: cube vertices 0=(-0.5,-0.5,-0.5), 1=(0.5,-0.5,-0.5)
    // → midpoint at (0,-0.5,-0.5).
    int mA = vertNear(after,  0.0f, -0.5f, -0.5f);
    int mB = vertNear(after,  0.0f,  0.5f, -0.5f);
    int mC = vertNear(after,  0.0f,  0.5f,  0.5f);
    int mD = vertNear(after,  0.0f, -0.5f,  0.5f);
    assert(mA >= 0, "midpoint of belt edge at (0,-0.5,-0.5) must exist");
    assert(mB >= 0, "midpoint of belt edge at (0,0.5,-0.5) must exist");
    assert(mC >= 0, "midpoint of belt edge at (0,0.5,0.5) must exist");
    assert(mD >= 0, "midpoint of belt edge at (0,-0.5,0.5) must exist");

    // Rung edges — closed belt.
    assert(edgeIdx(after, mA, mB) >= 0, "rung edge mA-mB must exist");
    assert(edgeIdx(after, mB, mC) >= 0, "rung edge mB-mC must exist");
    assert(edgeIdx(after, mC, mD) >= 0, "rung edge mC-mD must exist");
    assert(edgeIdx(after, mD, mA) >= 0, "rung edge mD-mA must exist (ring closure)");

    // One sub-quad by vertex set — catches orientation bugs that counts miss.
    // Face F0=[0,3,2,1] is split; one of its two sub-quads must appear.
    bool subOk = faceWithVerts(after, [0, mA, mB, 3]) ||
                 faceWithVerts(after, [mA, 1, 2, mB]);
    assert(subOk, "at least one sub-quad of the F0 split must exist");
}

// ---------------------------------------------------------------------------
// Case 2 — mesh.loopSlice count=3 on default cube (closed ring).
//   Seed = belt edge 0-1.  Three evenly-spaced loops (t=0.25, 0.5, 0.75).
//   Expected: V=20, E=36, F=18, Euler=2, all quads.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    auto before = getModel();

    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0, "belt edge 0-1 must exist");
    postSelect("edges", [eiSeed]);

    postCommandParams("mesh.loopSlice", `{"count":3}`);

    auto after = getModel();
    assert(after["vertexCount"].integer == 20, "V must be 20 after loopSlice count=3");
    assert(after["edgeCount"].integer   == 36, "E must be 36 after loopSlice count=3");
    assert(after["faceCount"].integer   == 18, "F must be 18 after loopSlice count=3");
    assert(cast(int)after["vertexCount"].integer
           - cast(int)after["edgeCount"].integer
           + cast(int)after["faceCount"].integer == 2, "Euler must be 2");
    assert(allQuads(after), "all faces must be quads after loopSlice");
}

// ---------------------------------------------------------------------------
// Case 3 — Undo restores original cube after mesh.addLoop.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    auto before = getModel();

    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0);
    postSelect("edges", [eiSeed]);
    postCommand("mesh.addLoop");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);

    auto restored = getModel();
    assert(restored["vertexCount"].integer == 8,  "V must be restored to 8 on undo");
    assert(restored["edgeCount"].integer   == 12, "E must be restored to 12 on undo");
    assert(restored["faceCount"].integer   == 6,  "F must be restored to 6 on undo");
    // Original belt edge must be back.
    assert(edgeIdx(restored, 0, 1) >= 0, "edge 0-1 must be restored after undo");
}

// ---------------------------------------------------------------------------
// Case 4 — Open ring: 1×3 quad strip, seed = interior edge 1-5.
//   Ring terminates at both strip boundaries.
//   Expected: V=12, E=17, F=6, Euler=1 (disk), all quads.
//   Rung edge at midpoint of 1-5 must exist on BOTH sides.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    // Strip: v0-v3 bottom, v4-v7 top.
    //   F0=[0,1,5,4], F1=[1,2,6,5], F2=[2,3,7,6]
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[2,0,0],[3,0,0],` ~
                     `[0,0,1],[1,0,1],[2,0,1],[3,0,1]],` ~
        ` "faces":[[0,1,5,4],[1,2,6,5],[2,3,7,6]]}`);
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["edgeCount"].integer   == 10);
    assert(before["faceCount"].integer   == 3);

    int eiSeed = edgeIdx(before, 1, 5);
    assert(eiSeed >= 0, "interior edge 1-5 must exist in strip");
    postSelect("edges", [eiSeed]);

    postCommand("mesh.addLoop");

    auto after = getModel();
    assert(after["vertexCount"].integer == 12, "V must be 12 after open-ring addLoop");
    assert(after["edgeCount"].integer   == 17, "E must be 17 after open-ring addLoop");
    assert(after["faceCount"].integer   ==  6, "F must be 6 after open-ring addLoop");
    assert(cast(int)after["vertexCount"].integer
           - cast(int)after["edgeCount"].integer
           + cast(int)after["faceCount"].integer == 1, "Euler must be 1 (disk)");
    assert(allQuads(after), "all strip faces must be quads after open-ring addLoop");

    // Midpoint of seed edge 1-5 is at (1, 0, 0.5).
    // It connects via a rung to the midpoint of 0-4 on the left (0, 0, 0.5)
    // and the midpoint of 2-6 on the right (2, 0, 0.5).
    int mSeed  = vertNear(after, 1.0f, 0.0f, 0.5f);
    int mLeft  = vertNear(after, 0.0f, 0.0f, 0.5f);
    int mRight = vertNear(after, 2.0f, 0.0f, 0.5f);
    assert(mSeed  >= 0, "midpoint of seed edge 1-5 must exist at (1,0,0.5)");
    assert(mLeft  >= 0, "midpoint of boundary edge 0-4 must exist at (0,0,0.5)");
    assert(mRight >= 0, "midpoint of interior edge 2-6 must exist at (2,0,0.5)");

    assert(edgeIdx(after, mSeed, mLeft)  >= 0, "rung edge mSeed-mLeft must exist");
    assert(edgeIdx(after, mSeed, mRight) >= 0, "rung edge mSeed-mRight must exist");
    assert(edgeIdx(after, mLeft, mRight) <  0,
           "mLeft and mRight must NOT be directly connected (open ring)");
}

// ---------------------------------------------------------------------------
// Case 5 — No-op: mesh.addLoop with no edges selected.
//   Command must return a non-ok status; mesh must be unchanged.
//   Uses postCommandRaw (NOT postCommand) because evaluate() returns false.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    auto before = getModel();

    // Explicitly leave no edges selected — postReset already clears selection.
    auto r = postCommandRaw("mesh.addLoop");
    // Status must NOT be "ok" (evaluate() guards require a selected edge).
    assert(r["status"].str != "ok",
           "mesh.addLoop with no selection must not return ok");

    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "vertex count must not change on no-op");
    assert(after["edgeCount"].integer   == before["edgeCount"].integer,
           "edge count must not change on no-op");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "face count must not change on no-op");
}

// ---------------------------------------------------------------------------
// Case 6 — Triangle-adjacent seed: mesh.addLoop must no-op (non-manifold guard).
//   Mesh: quad [0,1,2,3] and triangle [2,1,4] share edge 1-2.
//   collectEdgeRing detects a non-quad incident face on the seed edge and
//   returns empty → evaluate() returns false → non-ok status, mesh unchanged.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],[0.5,2,0]],` ~
        ` "faces":[[0,1,2,3],[2,1,4]]}`);
    auto before = getModel();
    assert(before["vertexCount"].integer == 5);
    assert(before["faceCount"].integer   == 2);

    // Select edge 1-2 — the shared edge between the quad and the triangle.
    int eiSeed = edgeIdx(before, 1, 2);
    assert(eiSeed >= 0, "edge 1-2 must exist in the mixed-valence mesh");
    postSelect("edges", [eiSeed]);

    auto r = postCommandRaw("mesh.addLoop");
    assert(r["status"].str != "ok",
           "mesh.addLoop on a triangle-adjacent seed must not return ok");

    // Mesh must be completely unchanged.
    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "vertex count must not change when triangle is incident on seed");
    assert(after["edgeCount"].integer   == before["edgeCount"].integer,
           "edge count must not change when triangle is incident on seed");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "face count must not change when triangle is incident on seed");
}
