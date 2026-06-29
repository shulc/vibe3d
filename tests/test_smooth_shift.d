// Tests for mesh.smooth_shift (Smooth Shift command).
//
// Smooth Shift extrudes the selected polygon region where each cap vertex is
// offset along the normalized average of its incident selected-face normals
// ("per-vertex smooth normal").  The key behavioural difference from the rigid
// Face Extrude (poly.extrude) is that outer/ridge vertices move in DIFFERENT
// directions depending on their local curvature.
//
// Tent mesh (6 verts / 2 quads, shared ridge v2-v3):
//   v0=(-1,0,0)  v1=(-1,0,1)  v2=(0,1,0)  v3=(0,1,1)  v4=(1,0,0)  v5=(1,0,1)
//   face 0: [0,1,3,2]   face 1: [2,3,5,4]
//   n0=(-1/√2, 1/√2, 0)   n1=(1/√2, 1/√2, 0)   regionNormal=(0,1,0)
//
// Smooth result (shift=0.5):
//   outer-left  clones: x ≈ -1-0.5/√2 ≈ -1.354  (moved along n0, NOT along (0,1,0))
//   outer-right clones: x ≈  1+0.5/√2 ≈  1.354  (moved along n1)
//   ridge clones:       x ≈  0,  y ≈ 1.5         (averaged n0+n1 = (0,1,0))
//
// Rigid result (poly.extrude, shift=0.5):
//   all clones: dy=+0.5 (along regionNormal=(0,1,0)), x/z unchanged
//
// "localhost:8080" is rewritten to the per-worker port by run_test.d when
// running in parallel; keep the literal so that rewrite still matches.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers (mirrors test_face_extrude.d)
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

string loadMesh(string body) {
    return cast(string)post("http://localhost:8080/api/load-mesh", body);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
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
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue postRedo() { return parseJSON(post("http://localhost:8080/api/redo", "")); }
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// ---------------------------------------------------------------------------
// Geometry helpers (shared with test_face_extrude.d — kept local)
// ---------------------------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

double dot3(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 add3(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }
V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
double len3(V3 a) { return sqrt(dot3(a, a)); }
V3 scale3(V3 a, double s) { return V3(a.x*s, a.y*s, a.z*s); }

V3 faceNormalH(JSONValue m, JSONValue faceArr) {
    double nx = 0, ny = 0, nz = 0;
    auto idx = faceArr.array;
    foreach (k; 0 .. idx.length) {
        auto a = vert(m, cast(size_t)idx[k].integer);
        auto b = vert(m, cast(size_t)idx[(k + 1) % idx.length].integer);
        nx += (a.y - b.y) * (a.z + b.z);
        ny += (a.z - b.z) * (a.x + b.x);
        nz += (a.x - b.x) * (a.y + b.y);
    }
    double len = sqrt(nx*nx + ny*ny + nz*nz);
    if (len < 1e-9) return V3(0, 1, 0);
    return V3(nx/len, ny/len, nz/len);
}

V3 faceCentroid(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    V3 c = V3(0, 0, 0);
    foreach (k; 0 .. idx.length) c = add3(c, vert(m, cast(size_t)idx[k].integer));
    return V3(c.x / idx.length, c.y / idx.length, c.z / idx.length);
}

// The tent mesh JSON: 6 verts, 2 quads sharing ridge v2-v3.
// Face normals: n0=(-1/√2,1/√2,0)  n1=(1/√2,1/√2,0)  regionNormal=(0,1,0)
enum string kTentMesh =
    `{"vertices":[[-1,0,0],[-1,0,1],[0,1,0],[0,1,1],[1,0,0],[1,0,1]],` ~
    `"faces":[[0,1,3,2],[2,3,5,4]]}`;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// TEST 1: Smooth shift on the tent — outer cap verts move along their own
// face normal, NOT the shared region normal.
// Smooth outer-left x ≈ -1-0.5/√2 ≈ -1.354  (rigid would give x == -1.0).
// Rigid outer-left  x == -1.0                (along regionNormal=(0,1,0)).
// This is the weighting-invariant discriminator: the tent is symmetric so
// uniform/area/angle weighting all produce the same result.
unittest { // SmoothDistinctFromRigid
    // --- smooth shift ---
    loadMesh(kTentMesh);
    postSelect("polygons", [0, 1]);
    postCommand(`{"id":"mesh.smooth_shift","params":{"shift":0.5}}`);
    auto smoothM = getModel();

    assert(smoothM["faces"].array.length == 8,
        "testSmoothDistinctFromRigid: smooth expected 8 faces (2 caps + 6 walls), got " ~
        smoothM["faces"].array.length.to!string);

    // Find a cap vert with x < -1.0 (outer-left, smooth moves it along n0).
    // Rigid would give x == -1.0 exactly; smooth gives x ≈ -1.354.
    bool foundSmoothOuterLeft = false;
    foreach (arr; smoothM["vertices"].array) {
        double x = arr.array[0].floating;
        double y = arr.array[1].floating;
        if (x < -1.01 && y > 0.0) { foundSmoothOuterLeft = true; break; }
    }
    assert(foundSmoothOuterLeft,
        "testSmoothDistinctFromRigid: no outer-left cap vert with x < -1.01 " ~
        "(smooth must move outer verts along face normal, not region normal)");

    // Symmetrically: outer-right vert should have x > 1.01.
    bool foundSmoothOuterRight = false;
    foreach (arr; smoothM["vertices"].array) {
        double x = arr.array[0].floating;
        double y = arr.array[1].floating;
        if (x > 1.01 && y > 0.0) { foundSmoothOuterRight = true; break; }
    }
    assert(foundSmoothOuterRight,
        "testSmoothDistinctFromRigid: no outer-right cap vert with x > 1.01");

    // --- rigid extrude on the SAME tent for comparison ---
    loadMesh(kTentMesh);
    postSelect("polygons", [0, 1]);
    postCommand(`{"id":"poly.extrude","params":{"distance":0.5}}`);
    auto rigidM = getModel();

    // Rigid: all original outer-left verts (x==-1) should have clones at x==-1
    // (they move in pure +Y along regionNormal).
    bool rigidHasNegativeSplitX = false;
    foreach (arr; rigidM["vertices"].array) {
        double x = arr.array[0].floating;
        double y = arr.array[1].floating;
        if (x < -1.01 && y > 0.0) { rigidHasNegativeSplitX = true; break; }
    }
    assert(!rigidHasNegativeSplitX,
        "testSmoothDistinctFromRigid: rigid extrude unexpectedly has x < -1.01 " ~
        "(it should move along regionNormal=(0,1,0), keeping x==-1.0)");

    // Undo the rigid extrude.
    postUndo();
}

// TEST 2: Smooth shift on a single flat cube face == rigid Face Extrude.
// With exactly one selected face, the per-vertex smooth normal = that face's
// normal = the regionNormal, so both modes give the same cap position.
unittest { // SmoothPlanarEqualsRigid
    resetCube();

    auto before = getModel();
    V3 origC = faceCentroid(before, before["faces"].array[0]);
    V3 origN = faceNormalH(before, before["faces"].array[0]);

    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.smooth_shift","params":{"shift":0.5}}`);
    auto after = getModel();

    assert(after["faces"].array.length == 10,
        "testSmoothPlanarEqualsRigid: expected 10 faces, got " ~
        after["faces"].array.length.to!string);
    assert(after["vertices"].array.length == 12,
        "testSmoothPlanarEqualsRigid: expected 12 verts, got " ~
        after["vertices"].array.length.to!string);

    // Cap centroid should be at origC + 0.5*origN (same as rigid).
    V3 exp = add3(origC, scale3(origN, 0.5));
    double bestDist = double.max;
    foreach (f; after["faces"].array) {
        V3 c = faceCentroid(after, f);
        double d = len3(sub3(c, exp));
        if (d < bestDist) bestDist = d;
    }
    assert(bestDist < 1e-3,
        "testSmoothPlanarEqualsRigid: planar smooth cap centroid too far from rigid result");
}

// TEST 3: shift==0 → no-op (snapshot discarded, topology unchanged).
unittest { // ShiftZeroNoOp
    resetCube();
    postSelect("polygons", [0]);
    postCommandRaw(`{"id":"mesh.smooth_shift","params":{"shift":0.0}}`);
    auto m = getModel();
    assert(m["faces"].array.length == 6,
        "testShiftZeroNoOp: shift==0 must not change face count");
    assert(m["vertices"].array.length == 8,
        "testShiftZeroNoOp: shift==0 must not change vert count");
}

// TEST 4: Closed island (all 6 cube faces) → no boundary edges → no-op.
unittest { // ClosedIslandNoOp
    resetCube();
    postSelect("polygons", [0, 1, 2, 3, 4, 5]);
    postCommandRaw(`{"id":"mesh.smooth_shift","params":{"shift":0.5}}`);
    auto m = getModel();
    assert(m["faces"].array.length == 6,
        "testClosedIslandNoOp: closed island must not change face count");
    assert(m["vertices"].array.length == 8,
        "testClosedIslandNoOp: closed island must not change vert count");
}

// TEST 5: Undo + redo round-trip on the tent.
unittest { // UndoRedo
    loadMesh(kTentMesh);
    postSelect("polygons", [0, 1]);
    postCommand(`{"id":"mesh.smooth_shift","params":{"shift":0.5}}`);
    assert(getModel()["faces"].array.length == 8,
        "testUndoRedo: expected 8 faces after smooth shift");

    postUndo();
    auto undone = getModel();
    assert(undone["faces"].array.length == 2,
        "testUndoRedo: after undo expected 2 faces (tent restored), got " ~
        undone["faces"].array.length.to!string);
    assert(undone["vertices"].array.length == 6,
        "testUndoRedo: after undo expected 6 verts, got " ~
        undone["vertices"].array.length.to!string);

    postRedo();
    assert(getModel()["faces"].array.length == 8,
        "testUndoRedo: after redo expected 8 faces");
}
