// Tests for mesh.addPoint command.
//
// mesh.addPoint inserts a single vertex on the first selected edge at a
// caller-given parameter t (default 0.5), splitting the edge and every incident
// face so the new vertex is index-shared (no T-junction).
//
// Unlike mesh.addLoop (ring-walk, quad-only), addPoint has no quad/ring
// restriction — it works on triangle edges too (Case C).
//
// Connectivity assertions:
//   - vertex / edge / face counts + Euler V−E+F = 2
//   - new vertex at analytic position (orientation-robust for t≠0.5, Case B)
//   - index-shared: no face retains a bare 0→1 or 1→0 adjacency after split
//   - both former incident faces now contain the new vertex index
//   - undo restores the original mesh exactly

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

/// Post command with params JSON.  Asserts status == "ok".
void postCommandParams(string id, string paramsJson) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
           id ~ " failed: " ~ resp);
}

/// Post command with params JSON.  Returns raw JSON (no assertion).
JSONValue postCommandParamsRaw(string id, string paramsJson) {
    return parseJSON(post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`));
}

/// Post command without params.  Returns raw JSON (no assertion).
JSONValue postCommandRaw(string id) {
    return parseJSON(post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`));
}

/// Post command without params.  Asserts status == "ok".
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

/// Index of undirected edge {a,b} in model["edges"], or -1.
int edgeIdx(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

/// True if any face has exactly the vertex set {vs}.
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

/// Vertex index within eps of (x,y,z), or -1.
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

// ---------------------------------------------------------------------------
// Case A — default t=0.5 on a cube edge.
//
// Split edge {0,1} at its midpoint.
// Expected: V 8→9, F 6→6 (two incident quads become pentagons), E 12→13.
// Euler V−E+F = 9−13+6 = 2.
// New vertex at (0,−0.5,−0.5) — orientation-independent midpoint.
// Index-shared: both former incident faces contain the new vertex; no face
// retains a bare 0→1 or 1→0 consecutive adjacency.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["edgeCount"].integer   == 12);
    assert(before["faceCount"].integer   == 6);

    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0, "edge {0,1} must exist on default cube");
    postSelect("edges", [eiSeed]);

    postCommand("mesh.addPoint");

    auto after = getModel();
    assert(after["vertexCount"].integer == 9,  "V must be 9 after addPoint");
    assert(after["edgeCount"].integer   == 13, "E must be 13 after addPoint");
    assert(after["faceCount"].integer   == 6,  "F must be 6 after addPoint");
    assert(cast(int)after["vertexCount"].integer
           - cast(int)after["edgeCount"].integer
           + cast(int)after["faceCount"].integer == 2, "Euler must be 2");

    // Midpoint of {0,1}: verts 0=(−0.5,−0.5,−0.5) and 1=(0.5,−0.5,−0.5)
    // → midpoint at (0,−0.5,−0.5). Orientation-independent.
    int vm = vertNear(after, 0.0f, -0.5f, -0.5f);
    assert(vm >= 0, "new vertex at midpoint (0,−0.5,−0.5) must exist");

    // Index-shared: no face may retain a bare 0→1 or 1→0 consecutive adjacency.
    foreach (f; after["faces"].array) {
        auto fa = f.array;
        for (size_t k = 0; k < fa.length; k++) {
            int a = cast(int)fa[k].integer;
            int b = cast(int)fa[(k + 1) % fa.length].integer;
            assert(!((a == 0 && b == 1) || (a == 1 && b == 0)),
                   "no face may retain bare 0→1 adjacency after addPoint");
        }
    }

    // Both former incident faces must now contain vm (no T-junction).
    int facesWithVm = 0;
    foreach (f; after["faces"].array)
        foreach (v; f.array)
            if (cast(int)v.integer == vm) { facesWithVm++; break; }
    assert(facesWithVm == 2, "exactly 2 faces must contain the new vertex");
}

// ---------------------------------------------------------------------------
// Case B — positional t=0.3 (orientation-robust headline assertion).
//
// The stored edge winding is first-insertion order (addFace/addEdge), not the
// endpoint-pair order we use to look up the edge.  For the default cube, edge
// {0,1} is stored as [1,0] (from face [0,3,2,1], winding step 1→0), so
// insertEdgePoint lerps vm = a + t*(b−a) = vert[1] + 0.3*(vert[0]−vert[1])
// → x = 0.5 + 0.3*(−1.0) = +0.2, NOT −0.2.
//
// Strategy: read the ACTUAL stored endpoints from the before-model and compute
// expected = ea_pos + t*(eb_pos − ea_pos) from those values.  This stays valid
// regardless of future makeCube winding changes.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    auto before = getModel();

    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0, "edge {0,1} must exist on default cube");

    // Resolve the stored endpoint indices for this edge.
    auto storedEdge = before["edges"].array[eiSeed];
    int ea = cast(int)storedEdge.array[0].integer;
    int eb = cast(int)storedEdge.array[1].integer;

    // Read vertex positions of stored endpoints.
    float ax = cast(float)before["vertices"].array[ea].array[0].floating;
    float ay = cast(float)before["vertices"].array[ea].array[1].floating;
    float az = cast(float)before["vertices"].array[ea].array[2].floating;
    float bx = cast(float)before["vertices"].array[eb].array[0].floating;
    float by = cast(float)before["vertices"].array[eb].array[1].floating;
    float bz = cast(float)before["vertices"].array[eb].array[2].floating;

    // Expected position: ea + 0.3*(eb − ea) from actual stored winding.
    float ex = ax + 0.3f * (bx - ax);
    float ey = ay + 0.3f * (by - ay);
    float ez = az + 0.3f * (bz - az);

    postSelect("edges", [eiSeed]);
    postCommandParams("mesh.addPoint", `{"t":0.3}`);

    auto after = getModel();
    assert(after["vertexCount"].integer == 9, "V must be 9 after t=0.3 addPoint");

    int vm = vertNear(after, ex, ey, ez);
    assert(vm >= 0, "new vertex must lie at t=0.3 along the stored edge endpoints");
}

// ---------------------------------------------------------------------------
// Case C — triangle edge (no quad/ring restriction).
//
// Load a single triangle face [0,1,2].  Split edge {0,1} at t=0.5.
// Expected: V 3→4, F 1→1 (now a quad), new vertex at (0.5,0,0).
// This confirms addPoint works on non-quad faces, unlike mesh.addLoop.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    postLoadMesh(`{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}`);

    auto before = getModel();
    assert(before["vertexCount"].integer == 3, "triangle must have 3 verts");
    assert(before["faceCount"].integer   == 1, "triangle must have 1 face");

    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0, "edge {0,1} must exist on triangle");
    postSelect("edges", [eiSeed]);

    postCommand("mesh.addPoint");

    auto after = getModel();
    assert(after["vertexCount"].integer == 4, "V must be 4 after triangle-edge addPoint");
    assert(after["faceCount"].integer   == 1, "F must stay 1 (now a quad)");
    assert(after["faces"].array[0].array.length == 4,
           "the face must now have 4 vertices (quad)");

    // Midpoint of {0,1}: (0,0,0) and (1,0,0) → (0.5,0,0). Orientation-independent.
    int vm = vertNear(after, 0.5f, 0.0f, 0.0f);
    assert(vm >= 0, "new vertex at (0.5,0,0) must exist");
}

// ---------------------------------------------------------------------------
// Case D — undo restores the original cube exactly.
// ---------------------------------------------------------------------------
unittest {
    postReset();
    auto before = getModel();

    int eiSeed = edgeIdx(before, 0, 1);
    assert(eiSeed >= 0);
    postSelect("edges", [eiSeed]);
    postCommand("mesh.addPoint");

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);

    auto restored = getModel();
    assert(restored["vertexCount"].integer == 8,  "V must be restored to 8 after undo");
    assert(restored["edgeCount"].integer   == 12, "E must be restored to 12 after undo");
    assert(restored["faceCount"].integer   == 6,  "F must be restored to 6 after undo");
    assert(edgeIdx(restored, 0, 1) >= 0, "edge {0,1} must be restored after undo");
}

// ---------------------------------------------------------------------------
// Case E — no-op guards.
//
// E1: no edge selected → command must fail (non-ok status), mesh unchanged.
// E2: t=1.0 (open-interval boundary) → command guard rejects.
//     HTTP injection does NOT clamp t to the .max(0.999f) hint
//     (injectParamsInto Float writes *p.fptr = value with no clamp), so t=1.0
//     reaches t_ verbatim and only the command's own guard stops it.
// ---------------------------------------------------------------------------
unittest {
    postReset();

    // E1: no selection.
    auto r1 = postCommandRaw("mesh.addPoint");
    assert(r1["status"].str != "ok", "mesh.addPoint with no selection must fail");
    auto m1 = getModel();
    assert(m1["vertexCount"].integer == 8, "V must be unchanged after no-selection no-op");

    // E2: t=1.0 (endpoint boundary).
    int eiSeed = edgeIdx(m1, 0, 1);
    assert(eiSeed >= 0);
    postSelect("edges", [eiSeed]);

    auto r2 = postCommandParamsRaw("mesh.addPoint", `{"t":1.0}`);
    assert(r2["status"].str != "ok", "mesh.addPoint with t=1.0 must fail");
    auto m2 = getModel();
    assert(m2["vertexCount"].integer == 8, "V must be unchanged after t=1.0 no-op");
}
