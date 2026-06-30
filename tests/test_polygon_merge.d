// Tests for mesh.mergeFaces command.
//
// Kernel: adjacent selected faces are merged into one n-gon per connected
// group by dissolving their shared interior edges (accept-all, no coplanarity
// criterion). Differs from mesh.detriangulate: works on selection only (no
// whole-mesh fallback), accepts non-coplanar faces, and is a no-op when the
// selection is empty or contains no adjacent faces.
//
// Fixtures:
//   A — two coplanar quads → 1 merged hexagon (6 corners: collinear midpoints survive)
//   B — non-adjacent / empty selection → no-op (postCommandRaw, status != ok)
//   C — non-coplanar adjacent cube faces DO merge (distinguishes from detriangulate)
//   D — undo / redo round-trip
//   E — two disjoint adjacent-pairs → 2 merged n-gons (not 1)

import std.net.curl;
import std.json;
import std.algorithm : sort, map;
import std.array     : array;
import std.conv      : to;
import std.math      : fabs, sqrt;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

void postReset() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post("http://localhost:8080/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/load-mesh failed: " ~ resp);
}

/// Select face indices (mode = element type: "polygons", "edges", "vertices").
/// /api/select always REPLACES the current selection with the given indices.
void postSelect(string elementType, int[] indices) {
    import std.array : appender;
    auto s = appender!string("[");
    foreach (i, v; indices) { if (i > 0) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ elementType ~ `","indices":` ~ s.data ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/select failed: " ~ resp);
}

/// Run a command that is expected to succeed (asserts status == "ok").
void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
                     `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           id ~ " failed: " ~ resp);
}

/// Run a command WITHOUT asserting success — returns the parsed response.
/// Use this for no-op cases where evaluate() returns false.
JSONValue postCommandRaw(string id) {
    auto resp = post("http://localhost:8080/api/command",
                     `{"id":"` ~ id ~ `"}`);
    return parseJSON(cast(string)resp);
}

void undoCmd() {
    auto resp = post("http://localhost:8080/api/command", `{"id":"history.undo"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok", "undo failed: " ~ resp);
}

void redoCmd() {
    auto resp = post("http://localhost:8080/api/command", `{"id":"history.redo"}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok", "redo failed: " ~ resp);
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

JSONValue getSel() {
    return parseJSON(get("http://localhost:8080/api/selection"));
}

void setPolyMode() {
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
}

void resetCube() {
    postReset();
    setPolyMode();
}

// Newell normal of face fi from /api/model JSON. Returns unit normal.
double[3] faceNormalFrom(JSONValue m, size_t fi) {
    auto verts = m["vertices"].array;
    auto face  = m["faces"].array[fi].array;
    double nx = 0, ny = 0, nz = 0;
    foreach (i; 0 .. face.length) {
        auto a = verts[cast(size_t)face[i].integer].array;
        auto b = verts[cast(size_t)face[(i+1) % face.length].integer].array;
        nx += (a[1].floating - b[1].floating) * (a[2].floating + b[2].floating);
        ny += (a[2].floating - b[2].floating) * (a[0].floating + b[0].floating);
        nz += (a[0].floating - b[0].floating) * (a[1].floating + b[1].floating);
    }
    double len = sqrt(nx*nx + ny*ny + nz*nz);
    if (len < 1e-9) return [0.0, 1.0, 0.0];
    return [nx/len, ny/len, nz/len];
}

/// Check that two cyclic sequences are equal up to rotation and optional
/// reversal (direction may differ since boundary-walk direction is implementation-
/// defined). Returns true if they match.
bool cyclicEqual(int[] a, int[] b) {
    if (a.length != b.length) return false;
    size_t n = a.length;
    // Try forward rotations.
    foreach (start; 0 .. n) {
        bool ok = true;
        foreach (k; 0 .. n)
            if (a[k] != b[(start + k) % n]) { ok = false; break; }
        if (ok) return true;
    }
    // Try reversed b.
    int[] br = b.dup;
    foreach (i; 0 .. n / 2) {
        int t = br[i]; br[i] = br[n-1-i]; br[n-1-i] = t;
    }
    foreach (start; 0 .. n) {
        bool ok = true;
        foreach (k; 0 .. n)
            if (a[k] != br[(start + k) % n]) { ok = false; break; }
        if (ok) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Fixture A — coplanar 2-quad grid merges to one 6-corner n-gon
// ---------------------------------------------------------------------------
//
// Mesh (flat 2×1 grid, Y=0):
//   verts: 0=(0,0,0) 1=(1,0,0) 2=(2,0,0)
//          3=(0,0,1) 4=(1,0,1) 5=(2,0,1)
//   face 0 = [0,1,4,3], face 1 = [1,2,5,4]  (shared edge 1–4)
//
// After merge: 1 face, 6 corners {0,1,2,3,4,5} incl. collinear midpoints 1+4.
// Boundary walk: 0→1→2→5→4→3 (or reverse / rotated).

unittest {
    postReset();
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[2,0,0],[0,0,1],[1,0,1],[2,0,1]],` ~
        ` "faces":[[0,1,4,3],[1,2,5,4]]}`);
    setPolyMode();

    // Select both faces.
    postSelect("polygons", [0, 1]);

    runCmd("mesh.mergeFaces");

    auto m = getModel();
    assert(m["faceCount"].integer == 1,
           "A: expected 1 face after merge, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 6,
           "A: vertex count must stay 6 (no orphans), got " ~ m["vertexCount"].integer.to!string);

    // The merged face must have exactly 6 corners.
    auto faceCorners = m["faces"].array[0].array;
    assert(faceCorners.length == 6,
           "A: merged face must have 6 corners (collinear midpoints survive), got "
           ~ faceCorners.length.to!string);

    // Corner index SET must be exactly {0,1,2,3,4,5}.
    int[] got = faceCorners.map!(v => cast(int)v.integer).array;
    int[] sorted = got.dup; sort(sorted);
    assert(sorted == [0,1,2,3,4,5],
           "A: merged face corners must span all 6 verts, got " ~ sorted.to!string);

    // Cyclic order must match expected boundary 0→1→2→5→4→3 (or rotation/reversal).
    int[] expected = [0,1,2,5,4,3];
    assert(cyclicEqual(got, expected),
           "A: merged face corner order is not a rotation/reversal of 0-1-2-5-4-3, got "
           ~ got.to!string);

    // Newell normal must be ±Y (planar, winding consistent).
    auto n = faceNormalFrom(m, 0);
    assert(fabs(n[1]) > 0.99,
           "A: merged face Newell normal must be ±Y, got [" ~
           n[0].to!string ~ "," ~ n[1].to!string ~ "," ~ n[2].to!string ~ "]");
}

// ---------------------------------------------------------------------------
// Fixture B — no-op cases: non-adjacent selection and empty selection
// ---------------------------------------------------------------------------

unittest {
    // B1: two opposite cube faces (no shared edge) → no-op.
    // Cube layout: face 0=[0,3,2,1] (Z=-0.5 front), face 1=[4,5,6,7] (Z=+0.5 back).
    // These share no vertices so they cannot share an edge.
    resetCube();
    postSelect("polygons", [0, 1]);

    auto r = postCommandRaw("mesh.mergeFaces");
    assert(r["status"].str != "ok",
           "B1: non-adjacent selection must return non-ok, got " ~ r["status"].str);

    auto m = getModel();
    assert(m["faceCount"].integer == 6,
           "B1: face count must not change on no-op, got " ~ m["faceCount"].integer.to!string);

    // Selection must NOT have been cleared (conditional resetSelection divergence).
    auto sel = getSel();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length >= 1,
           "B1: selection must survive a no-op (conditional resetSelection)");
}

unittest {
    // B2: empty selection → no-op (the whole-mesh fallback is NOT applied).
    resetCube();
    // No select call — selection is empty after reset.

    auto r = postCommandRaw("mesh.mergeFaces");
    assert(r["status"].str != "ok",
           "B2: empty selection must return non-ok, got " ~ r["status"].str);

    auto m = getModel();
    assert(m["faceCount"].integer == 6,
           "B2: face count must not change on empty-selection no-op");
}

// ---------------------------------------------------------------------------
// Fixture C — non-coplanar adjacent cube faces DO merge (distinguishes from
//             mesh.detriangulate which would leave them at 6 faces)
// ---------------------------------------------------------------------------

unittest {
    // Cube layout:
    //   face 0 = [0,3,2,1] (Z=-0.5 front),  normal ≈ -Z
    //   face 2 = [0,4,7,3] (X=-0.5 left),   normal ≈ -X
    //   Shared edge: 0–3 (adjacent, 90° apart — non-coplanar).
    resetCube();
    postSelect("polygons", [0, 2]);

    runCmd("mesh.mergeFaces");

    auto m = getModel();
    assert(m["faceCount"].integer == 5,
           "C: non-coplanar adjacent faces must merge → 5 faces, got "
           ~ m["faceCount"].integer.to!string);

    // The merged face must have 6 corners (two quads sharing one edge → hexagon).
    auto faceCorners = m["faces"].array;
    bool found6 = false;
    foreach (f; faceCorners)
        if (f.array.length == 6) { found6 = true; break; }
    assert(found6, "C: merged non-coplanar face must have 6 corners");

    // Cross-check: detriangulate on same selection leaves 6 faces (dot(n0,n2) ≈ 0 < 0.999).
    resetCube();
    postSelect("polygons", [0, 2]);
    runCmd("mesh.detriangulate");
    auto m2 = getModel();
    assert(m2["faceCount"].integer == 6,
           "C: detriangulate on non-coplanar pair must leave 6 faces (contrast check)");
}

// ---------------------------------------------------------------------------
// Fixture D — undo / redo round-trip
// ---------------------------------------------------------------------------

unittest {
    postReset();
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[2,0,0],[0,0,1],[1,0,1],[2,0,1]],` ~
        ` "faces":[[0,1,4,3],[1,2,5,4]]}`);
    setPolyMode();
    postSelect("polygons", [0, 1]);
    runCmd("mesh.mergeFaces");

    auto mMerged = getModel();
    assert(mMerged["faceCount"].integer == 1, "D: merged state must have 1 face");

    // Undo → back to 2 quads.
    undoCmd();
    auto mUndo = getModel();
    assert(mUndo["faceCount"].integer == 2,
           "D: after undo expected 2 faces, got " ~ mUndo["faceCount"].integer.to!string);
    // Both faces must be 4-corner quads.
    foreach (f; mUndo["faces"].array)
        assert(f.array.length == 4, "D: undo must restore original quads");

    // Redo → merged again.
    redoCmd();
    auto mRedo = getModel();
    assert(mRedo["faceCount"].integer == 1,
           "D: after redo expected 1 face, got " ~ mRedo["faceCount"].integer.to!string);
    assert(mRedo["faces"].array[0].array.length == 6,
           "D: redo face must have 6 corners");
}

// ---------------------------------------------------------------------------
// Fixture E — two disjoint adjacent-pairs → 2 independent merged n-gons
// ---------------------------------------------------------------------------
//
// Mesh: two separate 2-quad strips (islands) with NO shared verts/edges.
//   Island 1: verts 0-5, face 0=[0,1,4,3], face 1=[1,2,5,4] (share edge 1-4)
//   Island 2: verts 6-11, face 2=[6,7,10,9], face 3=[7,8,11,10] (share edge 7-10)
//
// Selecting all 4 faces: union-find produces two components {0,1} and {2,3}.
// Each component merges to its own boundary n-gon → 2 hexagons, not 1.

unittest {
    postReset();
    postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[2,0,0],[0,0,1],[1,0,1],[2,0,1],` ~
                    `[10,0,0],[11,0,0],[12,0,0],[10,0,1],[11,0,1],[12,0,1]],` ~
        ` "faces":[[0,1,4,3],[1,2,5,4],[6,7,10,9],[7,8,11,10]]}`);
    setPolyMode();

    // Select all 4 faces — two disjoint adjacent pairs.
    postSelect("polygons", [0, 1, 2, 3]);

    runCmd("mesh.mergeFaces");

    auto m = getModel();
    assert(m["faceCount"].integer == 2,
           "E: two disjoint adjacent-pairs must each merge independently → 2 faces, got "
           ~ m["faceCount"].integer.to!string);

    // Both merged faces must be hexagons (collinear midpoints survive).
    foreach (f; m["faces"].array)
        assert(f.array.length == 6,
               "E: both merged faces must have 6 corners, got " ~ f.array.length.to!string);
}
