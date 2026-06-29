// Tests for mesh.spinEdge (Spin Edge kernel + command).
//
// Spin reconnects the shared edge of two adjacent triangle faces to the other
// diagonal of the merged quad boundary.  Vertex count never changes; only
// connectivity changes.  These tests therefore assert /api/model "edges" and
// "faces" (connectivity), NOT vertex positions.
//
// Mesh geometry is injected via /api/load-mesh so the tests are independent of
// the default cube primitive.  Edge indices are looked up by endpoint pair from
// the model JSON, never hard-coded (they shift after each operation per Risk 5).
//
// Phase-0 note: quad-quad spin direction is capture-gated and deferred.  The
// quad no-op test (case 4) confirms the guard fires cleanly.

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

JSONValue postCommandRaw(string id) {
    return parseJSON(post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`));
}

void postCommand(string id) {
    auto r = postCommandRaw(id);
    assert(r["status"].str == "ok", "/" ~ id ~ " failed: " ~ r.toString);
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

/// Return true if any face in model["faces"] has exactly the vertex set {vs}.
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

// ----- Two-triangle mesh builder ---------------------------------------------

// Unit quad split into two triangles along diagonal 0–2.
//   v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1)
//   face 0 = [0,1,2],  face 1 = [0,2,3]
//   shared edge: 0–2
// After spin: new edge 1–3; face sets become {0,1,3} and {1,2,3}.
enum string TWOTRI_MESH =
    `{"vertices":[[0,0,0],[1,0,0],[1,0,1],[0,0,1]],` ~
    ` "faces":[[0,1,2],[0,2,3]]}`;

// ---------------------------------------------------------------------------
// Case 1 — Edge scope: two-triangle mesh, select shared edge, spin.
//          Asserts new diagonal present, old diagonal absent, counts stable.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    postLoadMesh(TWOTRI_MESH);
    auto before = getModel();
    assert(before["vertexCount"].integer == 4);
    assert(before["edgeCount"].integer   == 5);
    assert(before["faceCount"].integer   == 2);

    // Select the shared edge 0–2 by its current index.
    int ei02 = edgeIdx(before, 0, 2);
    assert(ei02 >= 0, "edge 0-2 must exist before spin");
    postSelect("edges", [ei02]);

    postCommand("mesh.spinEdge");

    auto after = getModel();

    // Counts unchanged (spin changes connectivity, not element counts).
    assert(after["vertexCount"].integer == 4, "vertex count must not change");
    assert(after["edgeCount"].integer   == 5, "edge count must not change");
    assert(after["faceCount"].integer   == 2, "face count must not change");

    // Old diagonal 0–2 absent; new diagonal 1–3 present.
    assert(edgeIdx(after, 0, 2) < 0, "edge 0-2 must be gone after spin");
    assert(edgeIdx(after, 1, 3) >= 0, "edge 1-3 must exist after spin");

    // New face vertex sets.
    assert(faceWithVerts(after, [0, 1, 3]), "face {0,1,3} must exist after spin");
    assert(faceWithVerts(after, [1, 2, 3]), "face {1,2,3} must exist after spin");
}

// ---------------------------------------------------------------------------
// Case 2 — Boundary-edge no-op: single triangle, all edges are boundary edges.
//          Command must return ok but must not mutate the mesh.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[0.5,0,1]],` ~
        ` "faces":[[0,1,2]]}`);
    auto before = getModel();

    // Select any edge (edge 0 = first edge in the list).
    postSelect("edges", [0]);

    // Command must NOT crash and must report a result (status ok or no-change).
    auto r = postCommandRaw("mesh.spinEdge");
    // We accept either "ok" (graceful no-op) or a failure status as long as the
    // mesh is not mutated.  The important invariant is the mesh is unchanged.
    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "vertex count must not change on boundary no-op");
    assert(after["edgeCount"].integer   == before["edgeCount"].integer,
           "edge count must not change on boundary no-op");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "face count must not change on boundary no-op");
    assert(faceWithVerts(after, [0, 1, 2]),
           "original face must survive boundary no-op");
}

// ---------------------------------------------------------------------------
// Case 3 — Undo: after a successful spin, undo restores original connectivity.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    postLoadMesh(TWOTRI_MESH);
    auto before = getModel();

    int ei02 = edgeIdx(before, 0, 2);
    assert(ei02 >= 0);
    postSelect("edges", [ei02]);
    postCommand("mesh.spinEdge");

    // Undo.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);

    auto restored = getModel();
    assert(restored["vertexCount"].integer == 4, "verts restored on undo");
    assert(restored["edgeCount"].integer   == 5, "edges restored on undo");
    assert(restored["faceCount"].integer   == 2, "faces restored on undo");

    // Original diagonal 0–2 must be back; new diagonal 1–3 must be gone.
    assert(edgeIdx(restored, 0, 2) >= 0,
           "edge 0-2 must be restored after undo");
    assert(edgeIdx(restored, 1, 3) < 0,
           "edge 1-3 must be absent after undo");
    assert(faceWithVerts(restored, [0, 1, 2]),
           "face {0,1,2} must be restored after undo");
    assert(faceWithVerts(restored, [0, 2, 3]),
           "face {0,2,3} must be restored after undo");
}

// ---------------------------------------------------------------------------
// Case 4 — Quad-pair no-op (Phase-0 capture-gated): two quads sharing an edge.
//          Spin must be a clean no-op until the reference direction is captured.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    // Six vertices; two quads sharing edge 1–2.
    //   v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1) v4=(2,0,0) v5=(2,0,1)
    //   face 0 = [0,1,2,3],  face 1 = [1,4,5,2]   shared edge: 1–2
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[1,0,1],[0,0,1],[2,0,0],[2,0,1]],` ~
        ` "faces":[[0,1,2,3],[1,4,5,2]]}`);
    auto before = getModel();

    int eiShared = edgeIdx(before, 1, 2);
    assert(eiShared >= 0, "shared quad edge 1-2 must exist");
    postSelect("edges", [eiShared]);

    // Command returns a result — what matters is the mesh is unchanged.
    postCommandRaw("mesh.spinEdge");

    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
           "vertex count must not change on quad no-op");
    assert(after["edgeCount"].integer   == before["edgeCount"].integer,
           "edge count must not change on quad no-op");
    assert(after["faceCount"].integer   == before["faceCount"].integer,
           "face count must not change on quad no-op");
    assert(edgeIdx(after, 1, 2) >= 0,
           "shared edge 1-2 must still exist after quad no-op");
}

// ---------------------------------------------------------------------------
// Case 5 — Fold-over guard: prospective new diagonal already exists.
//          Mesh [0,1,2] + [0,2,3] + [1,2,3]: spinning edge 0–2 would want 1–3
//          which already appears in face [1,2,3] → no-op.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[0.5,0,1],[0.5,0.5,0.5]],` ~
        ` "faces":[[0,1,2],[0,2,3],[1,2,3]]}`);
    auto before = getModel();

    int ei02 = edgeIdx(before, 0, 2);
    assert(ei02 >= 0, "edge 0-2 must exist");
    assert(edgeIdx(before, 1, 3) >= 0, "edge 1-3 must already exist (fold-over setup)");

    postSelect("edges", [ei02]);
    postCommandRaw("mesh.spinEdge");  // must not crash

    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer);
    assert(after["edgeCount"].integer   == before["edgeCount"].integer);
    assert(after["faceCount"].integer   == before["faceCount"].integer);
    assert(edgeIdx(after, 0, 2) >= 0,
           "edge 0-2 must still exist (fold-over blocked spin)");
    assert(edgeIdx(after, 1, 3) >= 0,
           "edge 1-3 must still exist after fold-over guard");
}

// ---------------------------------------------------------------------------
// Case 6 — Polygon scope: both faces selected, shared interior edge is spun.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    postLoadMesh(TWOTRI_MESH);
    auto before = getModel();

    // Select both faces (polygon mode switches edit mode to Polygons).
    postSelect("polygons", [0, 1]);

    postCommand("mesh.spinEdge");

    auto after = getModel();

    assert(after["vertexCount"].integer == 4, "vertex count unchanged (poly scope)");
    assert(after["edgeCount"].integer   == 5, "edge count unchanged (poly scope)");
    assert(after["faceCount"].integer   == 2, "face count unchanged (poly scope)");

    assert(edgeIdx(after, 0, 2) < 0,  "edge 0-2 must be gone (poly scope spin)");
    assert(edgeIdx(after, 1, 3) >= 0, "edge 1-3 must exist (poly scope spin)");
    assert(faceWithVerts(after, [0, 1, 3]), "face {0,1,3} must exist (poly scope)");
    assert(faceWithVerts(after, [1, 2, 3]), "face {1,2,3} must exist (poly scope)");
}

// ---------------------------------------------------------------------------
// Case 7 — Polygon scope partial: 3-triangle strip, select only first 2.
//          Only the shared interior edge between the two selected faces spins;
//          the edge between selected face 1 and unselected face 2 is untouched.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    // Three triangles in a strip:
    //   v0=(0,0,0) v1=(1,0,0) v2=(0.5,0,1) v3=(1.5,0,0) v4=(1,0,1)
    //   f0=[0,1,2]  f1=[1,3,2]  f2=[3,4,2]  (f0+f1 share edge 1-2; f1+f2 share edge 3-2)
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[0.5,0,1],[1.5,0,0],[1,0,1]],` ~
        ` "faces":[[0,1,2],[1,3,2],[3,4,2]]}`);
    auto before = getModel();

    // Confirm setup: edge 1-2 shared by f0+f1; edge 2-3 shared by f1+f2.
    assert(edgeIdx(before, 1, 2) >= 0, "edge 1-2 must exist");
    assert(edgeIdx(before, 2, 3) >= 0, "edge 2-3 must exist");

    // Select only faces 0 and 1 (not face 2).
    postSelect("polygons", [0, 1]);

    postCommand("mesh.spinEdge");

    auto after = getModel();

    // Counts unchanged.
    assert(after["vertexCount"].integer == before["vertexCount"].integer);
    assert(after["edgeCount"].integer   == before["edgeCount"].integer);
    assert(after["faceCount"].integer   == before["faceCount"].integer);

    // Edge 1-2 (interior to selected pair) must be gone; edge between face 1+2
    // (i.e. edge 2-3) must still exist because face 2 was not selected.
    assert(edgeIdx(after, 1, 2) < 0,
           "edge 1-2 (interior to selection) must be spun away");
    assert(edgeIdx(after, 2, 3) >= 0,
           "edge 2-3 (between selected and unselected) must survive");

    // The new diagonal of the spun pair is 0-3 (opposite vertices of f0+f1).
    assert(edgeIdx(after, 0, 3) >= 0,
           "new diagonal 0-3 must exist after poly-scope spin of f0+f1");
}
