// Tests for poly.extrude (Face Extrude kernel + command).
//
// Topology model (region-based):
//   - selected faces lifted by distance along averaged region normal
//   - one cap face per selected face (cloned, offset by distance)
//   - one wall quad per BOUNDARY edge (edge shared by exactly one selected face)
//   - internal edges (shared by two selected faces) get NO wall
//   - original selected faces dropped; their boundary verts kept by walls
//
// Cube single-face: 6→10 faces, 8→12 verts (5 orig + 1 cap + 4 walls; +4 verts).
// Grid 2-face region: 4→10 faces, 9→15 verts (2 remaining + 2 caps + 6 walls;
//   shared edge (1,4) has no wall).
// Closed island (all 6 cube faces): no boundary → no-op → 6 faces, 8 verts.
// distance==0 → no-op.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void resetGrid(int n) {
    auto resp = post("http://localhost:8080/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset grid failed: " ~ resp);
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
// Geometry helpers
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

V3 faceNormal(JSONValue m, JSONValue faceArr) {
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

// Indices of faces with exactly `n` corners.
int[] facesOfDeg(JSONValue m, int n) {
    int[] result;
    foreach (i, f; m["faces"].array) if (cast(int)f.array.length == n) result ~= cast(int)i;
    return result;
}

// True if the surface has no edge shared by more than 2 faces and no directed
// half-edge used more than once (no flipped / duplicated windings).
bool isHoleFree(JSONValue m) {
    int[ulong] undirected;
    int[ulong] directed;
    foreach (f; m["faces"].array) {
        auto idx = f.array;
        auto n = idx.length;
        foreach (k; 0 .. n) {
            ulong a = cast(ulong)idx[k].integer;
            ulong b = cast(ulong)idx[(k + 1) % n].integer;
            ulong lo = a < b ? a : b, hi = a < b ? b : a;
            undirected[(lo << 32) | hi] += 1;
            directed[(a << 32) | b] += 1;
        }
    }
    foreach (v; undirected) if (v > 2) return false;
    foreach (v; directed)   if (v > 1) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// TEST 1: Single-face extrude on a cube.
// Select face 0 in polygon mode, extrude by 0.5.
// Expected: 10 faces, 12 verts.  Cap centroid ≈ orig centroid + 0.5 * orig normal.
// Undo restores 6 faces, 8 verts.
unittest { // SingleFaceExtrude
    resetCube();

    auto before = getModel();
    assert(before["faces"].array.length == 6,
        "BEFORE: expected 6 cube faces");
    assert(before["vertices"].array.length == 8,
        "BEFORE: expected 8 cube verts");

    // Record face 0 geometry for later cap check.
    V3 origC = faceCentroid(before, before["faces"].array[0]);
    V3 origN = faceNormal(before, before["faces"].array[0]);

    // Select face 0 (switches to Polygons mode).
    postSelect("polygons", [0]);
    // Run extrude command.
    postCommand(`{"id":"poly.extrude","params":{"distance":0.5}}`);

    auto after = getModel();
    assert(after["faces"].array.length == 10,
        "testSingleFaceExtrude: expected 10 faces, got " ~
        after["faces"].array.length.to!string);
    assert(after["vertices"].array.length == 12,
        "testSingleFaceExtrude: expected 12 verts, got " ~
        after["vertices"].array.length.to!string);

    // Surface must be hole-free (orientability rule).
    assert(isHoleFree(after), "testSingleFaceExtrude: surface has winding errors");

    // Exactly 5 quad faces (5 orig) + 1 quad cap + 4 quad walls = 10 quads.
    assert(facesOfDeg(after, 4).length == 10,
        "testSingleFaceExtrude: all 10 faces should be quads");

    // Find the cap face: the one whose centroid is closest to origC + 0.5*origN.
    V3 expCap = V3(origC.x + 0.5 * origN.x,
                   origC.y + 0.5 * origN.y,
                   origC.z + 0.5 * origN.z);
    double bestDist = double.max;
    foreach (f; after["faces"].array) {
        V3 c = faceCentroid(after, f);
        double d = len3(sub3(c, expCap));
        if (d < bestDist) bestDist = d;
    }
    assert(bestDist < 1e-3,
        "testSingleFaceExtrude: no cap face centroid within 1e-3 of expected offset");

    // Undo must restore the original 6/8 topology.
    postUndo();
    auto undone = getModel();
    assert(undone["faces"].array.length == 6,
        "testSingleFaceExtrude: after undo expected 6 faces, got " ~
        undone["faces"].array.length.to!string);
    assert(undone["vertices"].array.length == 8,
        "testSingleFaceExtrude: after undo expected 8 verts, got " ~
        undone["vertices"].array.length.to!string);
}

// TEST 2: Multi-face region extrude on a 2×1 quad grid.
// Grid (n=2): 4 quads, 9 verts. Select f0 and f1 (adjacent, sharing edge (1,4)).
// Region boundary has 6 edges (3 from f0 + 3 from f1; shared internal edge excluded).
// Expected: 10 faces (2 orig + 2 caps + 6 walls), 15 verts (9 + 6 clones).
unittest { // MultiFaceRegion
    resetGrid(2);

    auto before = getModel();
    assert(before["faces"].array.length == 4, "BEFORE: expected 4 grid faces");
    assert(before["vertices"].array.length == 9, "BEFORE: expected 9 grid verts");

    postSelect("polygons", [0, 1]);
    postCommand(`{"id":"poly.extrude","params":{"distance":0.3}}`);

    auto after = getModel();
    assert(after["faces"].array.length == 10,
        "testMultiFaceRegion: expected 10 faces, got " ~
        after["faces"].array.length.to!string);
    assert(after["vertices"].array.length == 15,
        "testMultiFaceRegion: expected 15 verts, got " ~
        after["vertices"].array.length.to!string);

    // Surface must be hole-free.
    assert(isHoleFree(after), "testMultiFaceRegion: surface has winding errors");

    // Undo restores 4/9.
    postUndo();
    auto undone = getModel();
    assert(undone["faces"].array.length == 4,
        "testMultiFaceRegion: after undo expected 4 faces");
    assert(undone["vertices"].array.length == 9,
        "testMultiFaceRegion: after undo expected 9 verts");
}

// TEST 3: Closed island (all 6 cube faces) — no boundary edges → no-op.
// Nothing should change; the command must not extrude or translate anything.
unittest { // ClosedIslandNoOp
    resetCube();

    // Select all 6 faces.
    postSelect("polygons", [0, 1, 2, 3, 4, 5]);
    string raw = postCommandRaw(`{"id":"poly.extrude","params":{"distance":0.5}}`);
    // The command returns false (kernel returns 0); the API may still respond ok
    // or not-ok depending on how the command bus handles it.  The key invariant
    // is topology is UNCHANGED.
    auto m = getModel();
    assert(m["faces"].array.length == 6,
        "testClosedIslandNoOp: closed island must not change face count");
    assert(m["vertices"].array.length == 8,
        "testClosedIslandNoOp: closed island must not change vert count");
}

// TEST 4: distance==0 → no-op (snapshot discarded, topology unchanged).
unittest { // DistanceZeroNoOp
    resetCube();
    postSelect("polygons", [0]);
    string raw = postCommandRaw(`{"id":"poly.extrude","params":{"distance":0.0}}`);
    auto m = getModel();
    assert(m["faces"].array.length == 6,
        "testDistanceZeroNoOp: distance==0 must not change face count");
    assert(m["vertices"].array.length == 8,
        "testDistanceZeroNoOp: distance==0 must not change vert count");
}

// TEST 5: Undo+redo round-trip.
unittest { // UndoRedo
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"poly.extrude","params":{"distance":0.5}}`);
    assert(getModel()["faces"].array.length == 10, "testUndoRedo: after extrude");

    postUndo();
    assert(getModel()["faces"].array.length == 6, "testUndoRedo: after undo");

    postRedo();
    assert(getModel()["faces"].array.length == 10, "testUndoRedo: after redo");
}

// TEST 6 (task 0312, fuzz-found): diagonal/checkerboard face pair — faces 1
// and 2 on a 2x2 grid touch ONLY at the shared center vertex (no shared
// edge), so they are two DISJOINT islands. Before the fix, the inset kernel
// keyed its clone-vertex map by vertex id alone, so the shared corner got
// ONE merged clone whose cap-side vertical edge was then walled by BOTH
// islands at once — a non-manifold edge used by 4 faces. Each island must
// get its own clone at that corner.
//
// Grid n=2: 4 quads, 9 verts. Faces 1 ({1,2,5,4}) and 2 ({3,4,7,6}) share
// only vertex 4. Each face is its own single-face island (no internal edge
// between them), so each contributes a cap (1) + 4 walls (all 4 edges are
// boundary, since the two selected faces share no edge). 2 unselected
// originals remain. Expected: 12 faces; 9 orig + 8 clones (vertex 4 cloned
// ONCE PER ISLAND) = 17 verts — 16 would mean the corner was wrongly merged
// into a single shared clone (the regression).
unittest { // DiagonalPairIslands
    resetGrid(2);

    auto before = getModel();
    assert(before["faces"].array.length == 4, "BEFORE: expected 4 grid faces");
    assert(before["vertices"].array.length == 9, "BEFORE: expected 9 grid verts");

    postSelect("polygons", [1, 2]);
    postCommand(`{"id":"poly.extrude","params":{"distance":0.4}}`);

    auto after = getModel();
    assert(after["faces"].array.length == 12,
        "testDiagonalPairIslands: expected 12 faces, got " ~
        after["faces"].array.length.to!string);
    assert(after["vertices"].array.length == 17,
        "testDiagonalPairIslands: expected 17 verts (9 orig + 8 clones — " ~
        "the shared corner must be cloned ONCE PER ISLAND), got " ~
        after["vertices"].array.length.to!string ~
        " (16 would mean the corner was wrongly merged into one shared clone)");

    // The core regression: the result must be edge-manifold. Before the fix
    // this failed — the corner's vertical edge was shared by 4 wall quads
    // (2 from each island) instead of ≤2.
    assert(isHoleFree(after),
        "testDiagonalPairIslands: non-manifold edge at the shared corner " ~
        "(task 0312 regression — diagonal islands merged their inset vertex)");

    // Undo restores 4/9.
    postUndo();
    auto undone = getModel();
    assert(undone["faces"].array.length == 4,
        "testDiagonalPairIslands: after undo expected 4 faces");
    assert(undone["vertices"].array.length == 9,
        "testDiagonalPairIslands: after undo expected 9 verts");
}
