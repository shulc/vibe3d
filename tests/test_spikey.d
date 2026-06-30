// Tests for mesh.spikey (Spikey kernel + command).
//
// Geometry model: for each selected face of N verts, one apex vertex is added
// at the face centroid displaced along the face normal by amount*(perimeter/N)
// (D1-B: amount = percent-of-average-edge), the original face slot is replaced
// in-place with the first fan tri [v0,v1,apex], and N-1 additional fan tris
// [vi, vi+1, apex] (i=1..N-1) are appended.  The parent face's material and
// subpatch flag are carried to every fan tri.
//
// Cube vertex layout (from makeCube):
//   0:(-0.5,-0.5,-0.5)  1:(0.5,-0.5,-0.5)  2:(0.5,0.5,-0.5)  3:(-0.5,0.5,-0.5)
//   4:(-0.5,-0.5, 0.5)  5:(0.5,-0.5, 0.5)  6:(0.5,0.5, 0.5)  7:(-0.5,0.5, 0.5)
// Cube faces (addFace order):
//   0:[0,3,2,1]  1:[4,5,6,7]  2:[0,4,7,3]  3:[1,2,6,5]  4:[3,7,6,2]  5:[0,1,5,4]
// Top face  (+Y, y=0.5): face 4, centroid (0, 0.5, 0), normal +Y
// Right face (+X, x=0.5): face 3, centroid (0.5, 0, 0), normal +X
// Unit cube: each edge = 1, perimeter/N = 4/4 = 1 ⇒ disp = amount.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// --- HTTP helpers ------------------------------------------------------------

string BASE = "http://localhost:8080";

void resetCube() {
    auto resp = post(BASE ~ "/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void postCommand(string body_) {
    auto resp = post(BASE ~ "/api/command", body_);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ body_ ~ " → " ~ resp);
}

JSONValue postCommandRaw(string body_) {
    return parseJSON(cast(string)post(BASE ~ "/api/command", body_));
}

// Argstring format (e.g. "select.typeFrom vertex") — used for mode switches.
void cmdArg(string argstring) {
    auto resp = post(BASE ~ "/api/command", argstring);
    assert(parseJSON(resp)["status"].str == "ok",
           "cmdArg `" ~ argstring ~ "` failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(BASE ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post(BASE ~ "/api/undo", "")); }
JSONValue postRedo() { return parseJSON(post(BASE ~ "/api/redo", "")); }
JSONValue getModel() { return parseJSON(get(BASE ~ "/api/model")); }
JSONValue getSelection() { return parseJSON(get(BASE ~ "/api/selection")); }

void loadMesh(string json) {
    auto resp = post(BASE ~ "/api/load-mesh", json);
    assert(parseJSON(resp)["status"].str == "ok", "/api/load-mesh failed: " ~ resp);
}

// --- geometry helpers --------------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

double len3(V3 a) { return sqrt(a.x*a.x + a.y*a.y + a.z*a.z); }
V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
V3 add3(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }

// Index of the first vertex coincident with position p (within tol), or -1.
int vertAt(JSONValue m, V3 p, double tol=1e-4) {
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) return cast(int)i;
    return -1;
}

// Count vertices coincident with position p (within tol).
int countAt(JSONValue m, V3 p, double tol=1e-4) {
    int n = 0;
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) ++n;
    return n;
}

// Face centroid (average of all vertex positions).
V3 faceCentroid(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    V3 c = V3(0, 0, 0);
    foreach (k; 0 .. idx.length) c = add3(c, vert(m, cast(size_t)idx[k].integer));
    return V3(c.x / idx.length, c.y / idx.length, c.z / idx.length);
}

// Face index whose centroid is nearest to `target` within `tol`, or -1.
int faceWithCentroid(JSONValue m, V3 target, double tol=0.05) {
    foreach (fi; 0 .. m["faces"].array.length) {
        auto c = faceCentroid(m, m["faces"].array[fi]);
        if (len3(sub3(c, target)) < tol) return cast(int)fi;
    }
    return -1;
}

// Map face-vertex-count → frequency, e.g. {4:5, 3:4}.
int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

// Indices not referenced by any face (orphan vertices).
int[] orphanVerts(JSONValue m) {
    bool[] referenced;
    referenced.length = cast(size_t)m["vertexCount"].integer;
    foreach (f; m["faces"].array)
        foreach (c; f.array) {
            auto vi = cast(size_t)c.integer;
            if (vi < referenced.length) referenced[vi] = true;
        }
    int[] orph;
    foreach (i; 0 .. referenced.length) if (!referenced[i]) orph ~= cast(int)i;
    return orph;
}

// True if no undirected edge is shared by >2 faces and no directed half-edge
// is used more than once (non-manifold / folded faces guard).
bool isHoleFree(JSONValue m) {
    int[ulong] undirected;
    int[ulong] directed;
    foreach (f; m["faces"].array) {
        auto idx = f.array;
        auto n   = idx.length;
        foreach (k; 0 .. n) {
            ulong a = cast(ulong)idx[k].integer;
            ulong b = cast(ulong)idx[(k + 1) % n].integer;
            ulong lo = a < b ? a : b, hi = a < b ? b : a;
            undirected[(lo << 32) | hi] += 1;
            directed[(a << 32) | b] += 1;
        }
    }
    foreach (_, c; undirected) if (c > 2) return false;
    foreach (_, c; directed)   if (c > 1) return false;
    return true;
}

// True if no two distinct vertices share a position (within tol).
bool noCoincidentVerts(JSONValue m, double tol=1e-4) {
    auto n = m["vertices"].array.length;
    foreach (i; 0 .. n)
        foreach (j; i + 1 .. n)
            if (len3(sub3(vert(m, i), vert(m, j))) < tol) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Test A — single face: cube top (+Y) → 9 verts, 9 faces, apex at (0,1,0)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["faceCount"].integer   == 6);

    // Find the top face (+Y, centroid at (0, 0.5, 0)).
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "A: top face (+Y centroid) not found in cube");
    postSelect("polygons", [topFi]);

    postCommand(`{"id":"mesh.spikey","params":{"amount":0.5}}`);
    auto m = getModel();

    // Topology: 8 original verts + 1 apex, 6 faces − 1 top + 4 fan tris.
    assert(m["vertexCount"].integer == 9,
        "A: expected 9 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 9,
        "A: expected 9 faces, got " ~ m["faceCount"].integer.to!string);

    // Face-vert distribution: 5 untouched quads + 4 fan tris.
    auto fv = fvDist(m);
    assert(fv == [4: 5, 3: 4],
        "A: expected fv-dist {4:5, 3:4}, got " ~ fv.to!string);

    // Apex at (0, 0.5 + 0.5, 0) = (0, 1, 0).
    // Unit cube: edge=1, N=4, perimeter/N=1 ⇒ disp = amount * 1 = 0.5.
    // Top face normal is +Y, centroid is (0, 0.5, 0).
    int n = countAt(m, V3(0, 1, 0));
    assert(n == 1,
        "A: expected exactly 1 vertex at apex (0,1,0), found " ~ n.to!string);

    assert(orphanVerts(m).length == 0, "A: orphan verts after spikey");
    assert(isHoleFree(m),              "A: result is not hole-free");
    assert(noCoincidentVerts(m),       "A: coincident verts found");

    // D3: all fan tris selected (in-place slot + 3 appended).
    auto sel = getSelection();
    assert(sel["selectedFaces"].array.length == 4,
        "A: expected 4 fan tris selected (D3), got " ~
        sel["selectedFaces"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// Test B — undo/redo: restore to 8v/6f, then back to 9v/9f
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "B: top face not found");
    postSelect("polygons", [topFi]);
    postCommand(`{"id":"mesh.spikey","params":{"amount":0.5}}`);

    // Undo → original cube.
    postUndo();
    auto mUndo = getModel();
    assert(mUndo["vertexCount"].integer == 8,
        "B undo: expected 8 verts, got " ~ mUndo["vertexCount"].integer.to!string);
    assert(mUndo["faceCount"].integer == 6,
        "B undo: expected 6 faces, got " ~ mUndo["faceCount"].integer.to!string);

    // Redo → spikey result.
    postRedo();
    auto mRedo = getModel();
    assert(mRedo["vertexCount"].integer == 9,
        "B redo: expected 9 verts, got " ~ mRedo["vertexCount"].integer.to!string);
    assert(mRedo["faceCount"].integer == 9,
        "B redo: expected 9 faces, got " ~ mRedo["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Test C — no-op: Vertices mode → status:error, mesh unchanged
// (amount==0 is NOT the no-op case: it still fans; only wrong mode is a no-op)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "C: top face not found");
    postSelect("polygons", [topFi]);

    // Switch to Vertices mode — spikey requires Polygons mode.
    cmdArg("select.typeFrom vertex");

    auto raw = postCommandRaw(`{"id":"mesh.spikey","params":{"amount":0.5}}`);
    assert(raw["status"].str == "error",
        "C: expected status:error in Vertices mode, got " ~ raw["status"].str);

    // Mesh must be unchanged.
    auto after = getModel();
    assert(after["vertexCount"].integer == 8,
        "C: mesh modified on no-op (verts=" ~ after["vertexCount"].integer.to!string ~ ")");
    assert(after["faceCount"].integer == 6,
        "C: mesh modified on no-op (faces=" ~ after["faceCount"].integer.to!string ~ ")");

    // Restore Polygons mode for subsequent tests.
    cmdArg("select.typeFrom polygon");
}

// ---------------------------------------------------------------------------
// Test D — multi-face: top (+Y) + right (+X) → 10 verts, 12 faces, 2 apexes
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();

    int topFi   = faceWithCentroid(before, V3(0,   0.5, 0));
    int rightFi = faceWithCentroid(before, V3(0.5, 0,   0));
    assert(topFi   >= 0, "D: top face not found");
    assert(rightFi >= 0, "D: right face not found");
    postSelect("polygons", [topFi, rightFi]);

    postCommand(`{"id":"mesh.spikey","params":{"amount":0.5}}`);
    auto m = getModel();

    // 2 faces spiked: each quad→4 tris + 1 apex ⇒ 8+2=10 verts, 6-2+8=12 faces.
    assert(m["vertexCount"].integer == 10,
        "D: expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "D: expected 12 faces, got " ~ m["faceCount"].integer.to!string);

    // Apex for top face at (0, 0.5+0.5, 0) = (0, 1, 0).
    assert(countAt(m, V3(0,   1,   0)) == 1, "D: top apex (0,1,0) missing");
    // Apex for right face at (0.5+0.5, 0, 0) = (1, 0, 0).
    assert(countAt(m, V3(1,   0,   0)) == 1, "D: right apex (1,0,0) missing");

    assert(isHoleFree(m),        "D: result is not hole-free");
    assert(noCoincidentVerts(m), "D: coincident verts found");
    assert(orphanVerts(m).length == 0, "D: orphan verts found");
}

// ---------------------------------------------------------------------------
// Test E — D1-B lock-in (MANDATORY): non-unit-edge quad asserts
//          disp = amount * perimeter/N, NOT amount (absolute distance).
//
// Quad: 2×2 in XZ plane (y=0), winding (-1,0,-1),(-1,0,1),(1,0,1),(1,0,-1)
//   → Newell normal = +Y, centroid = (0,0,0).
//   Edge length = 2, perimeter = 8, N = 4, average edge = perimeter/N = 2.
//   With amount=0.5: D1-B disp = 0.5*2 = 1.0 → apex at (0, 1, 0).
//                    D1-A disp = 0.5 (absolute) → apex at (0, 0.5, 0).
//   Asserting apex y ≈ 1.0 distinguishes B from A.
// ---------------------------------------------------------------------------

unittest {
    // Load a 2×2 quad with +Y normal (winding chosen to give +Y via Newell).
    loadMesh(`{
        "vertices": [
            [-1,0,-1], [-1,0,1], [1,0,1], [1,0,-1]
        ],
        "faces": [ [0,1,2,3] ]
    }`);
    // Also switch to Polygons mode (load-mesh may leave prior mode).
    cmdArg("select.typeFrom polygon");

    auto before = getModel();
    assert(before["vertexCount"].integer == 4, "E: expected 4 verts after load");
    assert(before["faceCount"].integer   == 1, "E: expected 1 face after load");

    // Select the single face (it starts deselected after load).
    postSelect("polygons", [0]);

    postCommand(`{"id":"mesh.spikey","params":{"amount":0.5}}`);
    auto m = getModel();

    // 1 quad → 4 tris + 1 apex = 5 verts, 4 faces.
    assert(m["vertexCount"].integer == 5,
        "E: expected 5 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 4,
        "E: expected 4 faces, got " ~ m["faceCount"].integer.to!string);

    // D1-B: disp = 0.5 * (8/4) = 1.0 → apex at (0, 1, 0).
    // D1-A: disp = 0.5 (absolute)  → apex at (0, 0.5, 0).
    // Checking apex y ≈ 1.0 pins D1-B.
    int n = countAt(m, V3(0, 1, 0), 1e-4);
    assert(n == 1,
        "E: apex must be at (0,1,0) [D1-B: disp=amount*(perimeter/N)=0.5*2=1.0]"
        ~ " — found " ~ n.to!string ~ " vertex there."
        ~ " (If apex is at (0,0.5,0) the formula is absolute (D1-A), not D1-B.)");
    // Ensure apex is NOT at the D1-A position.
    assert(countAt(m, V3(0, 0.5, 0), 1e-4) == 0,
        "E: apex must NOT be at (0,0.5,0) [D1-A absolute position]");
}

// ---------------------------------------------------------------------------
// Test F — subpatch carry-over: toggle subpatch on selected face before
//          spikey, then assert all 4 fan tris have isSubpatch=true in /api/model.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "F: top face not found");

    // Ensure Polygons mode and select top face.
    cmdArg("select.typeFrom polygon");
    postSelect("polygons", [topFi]);

    // Toggle subpatch ON for the selected face.
    postCommand(`{"id":"mesh.subpatch_toggle"}`);

    // Verify the source face is now subpatch before spikey.
    auto mPre = getModel();
    assert(mPre["isSubpatch"].array[topFi].type == JSONType.true_,
        "F: top face must be subpatch before spikey");

    // Now spikey the selected face.
    postSelect("polygons", [topFi]);
    postCommand(`{"id":"mesh.spikey","params":{"amount":0.5}}`);
    auto m = getModel();

    assert(m["faceCount"].integer == 9,
        "F: expected 9 faces, got " ~ m["faceCount"].integer.to!string);

    // All 4 fan tris (the 4 tri-arity faces in the result) must have isSubpatch=true.
    // The 5 original untouched quads should remain false.
    int subTris = 0, nonSubQuads = 0;
    foreach (fi; 0 .. m["faceCount"].integer) {
        int arity = cast(int)m["faces"].array[fi].array.length;
        bool isSub = m["isSubpatch"].array[fi].type == JSONType.true_;
        if (arity == 3) {
            assert(isSub,
                "F: fan tri fi=" ~ fi.to!string ~ " must have isSubpatch=true");
            ++subTris;
        } else {
            assert(!isSub,
                "F: untouched quad fi=" ~ fi.to!string ~ " must have isSubpatch=false");
            ++nonSubQuads;
        }
    }
    assert(subTris == 4,
        "F: expected 4 subpatch fan tris, got " ~ subTris.to!string);
    assert(nonSubQuads == 5,
        "F: expected 5 non-subpatch quads, got " ~ nonSubQuads.to!string);
}
