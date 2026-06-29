// test_thicken.d — HTTP tests for the mesh.thicken command.
//
// Fixtures:
//   grid2x2   — 9 verts, 4 quads (2×2), z=0, 1 boundary loop (8 verts).
//   grid3x3h  — 16 verts, 8 quads (3×3 minus center), 2 boundary loops.
//   closedCube — 8 verts, 6 quads, closed (no boundary).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// ---------------------------------------------------------------------------
// Infrastructure
// ---------------------------------------------------------------------------

enum BASE = "http://localhost:8080";

JSONValue postCmd(string path, string body_) {
    auto resp = cast(string)post(BASE ~ path, body_);
    return parseJSON(resp);
}

JSONValue getModel() {
    return parseJSON(cast(string)get(BASE ~ "/api/model"));
}

void loadMesh(string json) {
    auto r = postCmd("/api/load-mesh", json);
    assert(r["status"].str == "ok", "/api/load-mesh failed: " ~ r.toString);
}

// Run a command; extra is an optional JSON params object like {"thickness":0.2}
// sent as the nested "params" field: {"id":"<id>","params":{...}}.
void runCmd(string id, string extra = "") {
    string body_ = extra.length == 0
        ? `{"id":"` ~ id ~ `"}`
        : `{"id":"` ~ id ~ `","params":` ~ extra ~ `}`;
    auto r = postCmd("/api/command", body_);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command " ~ id ~ " failed: " ~ r.toString);
}

// Like runCmd but ignores the status (for intentional no-op tests).
void runCmdLax(string id, string extra = "") {
    string body_ = extra.length == 0
        ? `{"id":"` ~ id ~ `"}`
        : `{"id":"` ~ id ~ `","params":` ~ extra ~ `}`;
    postCmd("/api/command", body_);
}

long vertCount(JSONValue m) { return m["vertexCount"].integer; }
long faceCount(JSONValue m) { return m["faces"].array.length; }

// Count undirected edges incident to exactly one face (open boundary edges).
long boundaryEdgeCount(JSONValue m) {
    int[string] cnt;
    foreach (f; m["faces"].array) {
        auto vs = f.array;
        const size_t N = vs.length;
        foreach (k; 0 .. N) {
            long a = vs[k].integer, b = vs[(k+1)%N].integer;
            string key = a < b ? a.to!string ~ ":" ~ b.to!string
                               : b.to!string ~ ":" ~ a.to!string;
            cnt[key] = cnt.get(key, 0) + 1;
        }
    }
    long open = 0;
    foreach (_, v; cnt) if (v == 1) open++;
    return open;
}

long orphanVertCount(JSONValue m) {
    bool[] refd;
    refd.length = cast(size_t)m["vertexCount"].integer;
    foreach (f; m["faces"].array)
        foreach (vi; f.array) {
            auto idx = cast(size_t)vi.integer;
            if (idx < refd.length) refd[idx] = true;
        }
    long cnt = 0;
    foreach (r; refd) if (!r) cnt++;
    return cnt;
}

float[3] faceCentroid(JSONValue m, size_t fi) {
    auto vs  = m["faces"].array[fi].array;
    auto pos = m["vertices"].array;
    float[3] c = [0,0,0];
    foreach (vi; vs) {
        auto p = pos[cast(size_t)vi.integer].array;
        c[0] += cast(float)p[0].floating;
        c[1] += cast(float)p[1].floating;
        c[2] += cast(float)p[2].floating;
    }
    float n = cast(float)vs.length;
    c[0] /= n; c[1] /= n; c[2] /= n;
    return c;
}

float[3] faceNorm(JSONValue m, size_t fi) {
    auto vs  = m["faces"].array[fi].array;
    auto pos = m["vertices"].array;
    const size_t N = vs.length;
    float nx = 0, ny = 0, nz = 0;
    foreach (k; 0 .. N) {
        auto pa = pos[cast(size_t)vs[k      ].integer].array;
        auto pb = pos[cast(size_t)vs[(k+1)%N].integer].array;
        float ax = cast(float)pa[0].floating, ay = cast(float)pa[1].floating, az = cast(float)pa[2].floating;
        float bx = cast(float)pb[0].floating, by = cast(float)pb[1].floating, bz = cast(float)pb[2].floating;
        nx += (ay - by) * (az + bz);
        ny += (az - bz) * (ax + bx);
        nz += (ax - bx) * (ay + by);
    }
    float len = sqrt(nx*nx + ny*ny + nz*nz);
    return len < 1e-7f ? [0f, 1f, 0f] : [nx/len, ny/len, nz/len];
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// 2×2 grid: 9 verts (row-major, 3×3 positions at z=0), 4 quads (CCW from +z).
string GRID2x2 = `{
    "vertices": [
        [0,0,0],[1,0,0],[2,0,0],
        [0,1,0],[1,1,0],[2,1,0],
        [0,2,0],[1,2,0],[2,2,0]
    ],
    "faces": [
        [0,1,4,3],[1,2,5,4],
        [3,4,7,6],[4,5,8,7]
    ]
}`;

// 3×3 grid (4×4 verts, 16) with center quad [5,6,10,9] removed → 8 quads.
// Face row-major: [0,1,5,4],[1,2,6,5],[2,3,7,6],[4,5,9,8],SKIP,[6,7,11,10],
//                 [8,9,13,12],[9,10,14,13],[10,11,15,14]
string GRID3x3H = `{
    "vertices": [
        [0,0,0],[1,0,0],[2,0,0],[3,0,0],
        [0,1,0],[1,1,0],[2,1,0],[3,1,0],
        [0,2,0],[1,2,0],[2,2,0],[3,2,0],
        [0,3,0],[1,3,0],[2,3,0],[3,3,0]
    ],
    "faces": [
        [0,1,5,4],[1,2,6,5],[2,3,7,6],
        [4,5,9,8],
        [6,7,11,10],
        [8,9,13,12],[9,10,14,13],[10,11,15,14]
    ]
}`;

string CLOSED_CUBE = `{
    "vertices": [
        [0,0,0],[1,0,0],[1,1,0],[0,1,0],
        [0,0,1],[1,0,1],[1,1,1],[0,1,1]
    ],
    "faces": [
        [0,3,2,1],[4,5,6,7],
        [0,1,5,4],[1,2,6,5],
        [2,3,7,6],[3,0,4,7]
    ]
}`;

// ---------------------------------------------------------------------------
// Test 1: one-sided thicken → closed shell, counts
// ---------------------------------------------------------------------------

unittest { // 2×2 grid → 18 verts, 16 faces, watertight
    loadMesh(GRID2x2);
    runCmd("mesh.thicken", `{"thickness":0.2}`);
    auto m = getModel();
    assert(vertCount(m) == 18,
        "thicken 2×2: verts " ~ vertCount(m).to!string ~ " (expected 18)");
    assert(faceCount(m) == 16,
        "thicken 2×2: faces " ~ faceCount(m).to!string ~ " (expected 16)");
    assert(boundaryEdgeCount(m) == 0,
        "thicken 2×2: open edges " ~ boundaryEdgeCount(m).to!string ~ " (expected 0)");
    assert(orphanVertCount(m) == 0, "thicken 2×2: orphan verts");
}

// ---------------------------------------------------------------------------
// Test 2: winding — outer +z, inner −z, rim outward
// ---------------------------------------------------------------------------

unittest { // 2×2 grid thicken: outer +z, inner -z, rim normals outward
    loadMesh(GRID2x2);
    runCmd("mesh.thicken", `{"thickness":0.2}`);
    auto m = getModel();
    const size_t nf = cast(size_t)faceCount(m);

    int outerOk = 0, innerOk = 0, rimOk = 0;
    int outerCnt = 0, innerCnt = 0, rimCnt = 0;
    foreach (fi; 0 .. nf) {
        auto c = faceCentroid(m, fi);
        auto n = faceNorm(m, fi);
        if (abs(c[2]) < 0.01f) {
            outerCnt++;
            if (n[2] > 0.5f) outerOk++;
        } else if (abs(c[2] + 0.2f) < 0.01f) {
            innerCnt++;
            if (n[2] < -0.5f) innerOk++;
        } else {
            rimCnt++;
            // Rim normal should point away from grid centroid (1,1).
            float dx = c[0] - 1.0f, dy = c[1] - 1.0f;
            if (n[0]*dx + n[1]*dy > 0.0f) rimOk++;
        }
    }
    assert(outerCnt == 4 && outerOk == 4, "thicken winding: outer +z failed");
    assert(innerCnt == 4 && innerOk == 4, "thicken winding: inner -z failed");
    assert(rimCnt   == 8 && rimOk   == 8, "thicken winding: rim outward failed");
}

// ---------------------------------------------------------------------------
// Test 3: multi-loop (3×3 holed) → watertight, 28 faces
// ---------------------------------------------------------------------------

unittest { // 3×3 holed grid → 32 verts, 28 faces, watertight
    loadMesh(GRID3x3H);
    runCmd("mesh.thicken", `{"thickness":0.2}`);
    auto m = getModel();
    assert(vertCount(m) == 32,
        "thicken holed: verts " ~ vertCount(m).to!string ~ " (expected 32)");
    assert(faceCount(m) == 32,
        "thicken holed: faces " ~ faceCount(m).to!string ~ " (expected 32)");
    assert(boundaryEdgeCount(m) == 0,
        "thicken holed: open edges " ~ boundaryEdgeCount(m).to!string ~ " (expected 0)");
    assert(orphanVertCount(m) == 0, "thicken holed: orphan verts");
}

// ---------------------------------------------------------------------------
// Test 4: 3×3 holed — rim normals outward on BOTH loops independently
// ---------------------------------------------------------------------------

unittest { // 3×3 holed thicken: outward rim normals on outer AND inner-hole rim
    loadMesh(GRID3x3H);
    runCmd("mesh.thicken", `{"thickness":0.2}`);
    auto m = getModel();
    const size_t nf = cast(size_t)faceCount(m);

    // Inner hole verts (original indices and their offsets +16).
    bool isHoleVert(long vi) {
        if (vi >= 16) vi -= 16;
        return vi == 5 || vi == 6 || vi == 9 || vi == 10;
    }

    int outerRimOk = 0, outerRimCnt = 0;
    int innerRimOk = 0, innerRimCnt = 0;
    const float ax = 1.5f, ay = 1.5f;

    foreach (fi; 0 .. nf) {
        auto c = faceCentroid(m, fi);
        if (abs(c[2]) < 0.01f || abs(c[2] + 0.2f) < 0.01f) continue; // cap
        auto vs = m["faces"].array[fi].array;
        bool anyHole = false;
        foreach (vi; vs) if (isHoleVert(vi.integer)) { anyHole = true; break; }
        auto n = faceNorm(m, fi);
        float dx = c[0] - ax, dy = c[1] - ay;
        bool out_ = (n[0]*dx + n[1]*dy > 0.0f);
        if (anyHole) { innerRimCnt++; if (out_) innerRimOk++; }
        else         { outerRimCnt++; if (out_) outerRimOk++; }
    }
    assert(outerRimCnt > 0, "thicken holed: no outer rim faces found");
    assert(innerRimCnt > 0, "thicken holed: no inner hole rim faces found");
    assert(outerRimOk == outerRimCnt,
        "thicken holed: outer rim outward " ~ outerRimOk.to!string ~ "/" ~ outerRimCnt.to!string);
    assert(innerRimOk == innerRimCnt,
        "thicken holed: inner hole rim outward " ~ innerRimOk.to!string ~ "/" ~ innerRimCnt.to!string);
}

// ---------------------------------------------------------------------------
// Test 5: symmetric mode — verts split ±t/2
// ---------------------------------------------------------------------------

unittest { // 2×2 grid symmetric thicken: outer at z=+0.1, inner at z=-0.1
    loadMesh(GRID2x2);
    runCmd("mesh.thicken", `{"thickness":0.2,"symmetric":true}`);
    auto m = getModel();
    assert(vertCount(m) == 18, "thicken symmetric: 18 verts");
    assert(faceCount(m) == 16, "thicken symmetric: 16 faces");
    assert(boundaryEdgeCount(m) == 0, "thicken symmetric: watertight");
    auto pos = m["vertices"].array;
    foreach (i; 0 .. 9)
        assert(abs(cast(float)pos[i].array[2].floating - 0.1f) < 1e-4f,
            "thicken symmetric: outer vert " ~ i.to!string ~ " z != +0.1");
    foreach (i; 9 .. 18)
        assert(abs(cast(float)pos[i].array[2].floating + 0.1f) < 1e-4f,
            "thicken symmetric: inner vert " ~ i.to!string ~ " z != -0.1");
}

// ---------------------------------------------------------------------------
// Test 6: undo restores original surface
// ---------------------------------------------------------------------------

unittest { // thicken then undo → original 9 verts / 4 faces / open boundary
    loadMesh(GRID2x2);
    runCmd("mesh.thicken", `{"thickness":0.2}`);
    assert(faceCount(getModel()) == 16, "before undo: 16 faces");
    runCmd("history.undo");
    auto m = getModel();
    assert(vertCount(m) == 9, "after undo: 9 verts");
    assert(faceCount(m) == 4, "after undo: 4 faces");
    assert(boundaryEdgeCount(m) == 8, "after undo: 8 open boundary edges");
}

// ---------------------------------------------------------------------------
// Test 7: closed input → no-op, no phantom undo entry
// ---------------------------------------------------------------------------

unittest { // thicken closed mesh → no-op; subsequent undo pops a prior entry
    loadMesh(CLOSED_CUBE);
    // Perform a real mutation so undo stack is non-empty.
    runCmd("mesh.subdivide");
    auto mSub = getModel();
    long vcSub = vertCount(mSub), fcSub = faceCount(mSub);

    // Thicken the (still-closed) subdivided cube — must be a no-op.
    runCmdLax("mesh.thicken");
    auto m1 = getModel();
    assert(vertCount(m1) == vcSub, "thicken closed: vertex count unchanged");
    assert(faceCount(m1) == fcSub, "thicken closed: face count unchanged");

    // Undo must pop the subdivide, not a phantom thicken entry.
    runCmd("history.undo");
    auto m2 = getModel();
    assert(faceCount(m2) == 6, "thicken closed: undo reverts to pre-subdivide cube");
}

// ---------------------------------------------------------------------------
// Test 8: zero thickness → no-op
// ---------------------------------------------------------------------------

unittest { // zero thickness leaves mesh unchanged
    loadMesh(GRID2x2);
    runCmdLax("mesh.thicken", `{"thickness":0}`);
    auto m = getModel();
    assert(vertCount(m) == 9, "zero thickness: vertex count unchanged");
    assert(faceCount(m) == 4, "zero thickness: face count unchanged");
}
