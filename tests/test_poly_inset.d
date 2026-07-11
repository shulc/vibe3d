// Tests for mesh.poly_inset (Polygon Inset kernel + command).
//
// Geometry model (task 0359, reference-parity rewrite): for each selected
// face of N verts, one inset vertex is added per corner, moved TOWARD the
// polygon centroid by an ABSOLUTE distance of `inset` world units (see
// mesh.insetFacesByMask / insetCornerCentroid) — NOT a per-edge perpendicular/
// miter offset. The original face slot is replaced by the inner face (same
// slot → selection mark preserved), and N ring quads bridge original
// boundary to inner boundary. `inset == 0` is NOT a no-op — the split always
// happens (reference-matched), landing a degenerate zero-width ring.
//
// Cube vertex layout (from makeCube):
//   0:(-0.5,-0.5,-0.5)  1:(0.5,-0.5,-0.5)  2:(0.5,0.5,-0.5)  3:(-0.5,0.5,-0.5)
//   4:(-0.5,-0.5, 0.5)  5:(0.5,-0.5, 0.5)  6:(0.5,0.5, 0.5)  7:(-0.5,0.5, 0.5)
// Cube faces (addFace order):
//   0:[0,3,2,1]  1:[4,5,6,7]  2:[0,4,7,3]  3:[1,2,6,5]  4:[3,7,6,2]  5:[0,1,5,4]
// Top face  (+Y, y= 0.5): face 4, centroid (0, 0.5, 0)
// Right face (+X, x= 0.5): face 3, centroid (0.5, 0, 0)
//
// Every cube face corner sits at the SAME distance from its face centroid
// (a square), so "move by a constant absolute distance" displaces each
// in-plane axis component by inset/sqrt(2) (the diagonal toward/away from
// centroid) — e.g. inset=0.1 → inner corners at ±(0.5 - 0.1/sqrt(2)) ≈
// ±0.42929 (NOT ±0.4, which was the old per-edge-miter law's prediction).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// Per-axis in-plane displacement for a cube-face corner (every corner is
// equidistant from its face centroid, so inset=0.1's constant-distance move
// splits evenly across both in-plane axes: 0.1/sqrt(2)).
immutable double SQRT2_ = sqrt(2.0);
immutable double D1 = 0.1 / SQRT2_;

// --- HTTP helpers ------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ body ~ " → " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(cast(string)post("http://localhost:8080/api/command", body));
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
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }

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

// Map face-vertex-count → frequency, e.g. {4:10}.
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
// Test A — single face inset: cube top (+Y) face → 12 verts, 10 quads
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["faceCount"].integer   == 6);

    // Find the top face (+Y, centroid at (0, 0.5, 0)).
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "top face (+Y centroid) not found in cube");
    postSelect("polygons", [topFi]);

    postCommand(`{"id":"mesh.poly_inset","params":{"inset":0.1}}`);
    auto m = getModel();

    // Topology counts.
    assert(m["vertexCount"].integer == 12,
        "A: expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 10,
        "A: expected 10 faces, got " ~ m["faceCount"].integer.to!string);

    // All-quads result.
    auto fv = fvDist(m);
    assert(fv == [4: 10],
        "A: expected all-quad fv-dist {4:10}, got " ~ fv.to!string);

    // Inner corners at (±(0.5-0.1/sqrt(2)), 0.5, ±(0.5-0.1/sqrt(2))) — one
    // vertex each (no coincidents). The SHRUNK magnitude confirms inset
    // direction (outset would grow past ±0.5).
    double c = 0.5 - D1;
    foreach (x; [-c, c])
        foreach (z; [-c, c]) {
            int n = countAt(m, V3(x, 0.5, z));
            assert(n == 1,
                "A: expected 1 inner corner at ("~x.to!string~",0.5,"~z.to!string~
                "), found "~n.to!string);
        }

    assert(orphanVerts(m).length == 0, "A: orphan verts after inset");
    assert(isHoleFree(m),              "A: result is not hole-free");
    assert(noCoincidentVerts(m),       "A: coincident verts found");

    // The inner face (same slot) stays selected.
    auto sel = getSelection();
    assert(sel["selectedFaces"].array.length == 1,
        "A: expected inner face still selected, got " ~
        sel["selectedFaces"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// Test B — undo/redo: restore to 8v/6f, then back to 12v/10f
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "B: top face not found");
    postSelect("polygons", [topFi]);
    postCommand(`{"id":"mesh.poly_inset","params":{"inset":0.1}}`);

    // Undo → original cube.
    postUndo();
    auto mUndo = getModel();
    assert(mUndo["vertexCount"].integer == 8,
        "B undo: expected 8 verts, got " ~ mUndo["vertexCount"].integer.to!string);
    assert(mUndo["faceCount"].integer == 6,
        "B undo: expected 6 faces, got " ~ mUndo["faceCount"].integer.to!string);

    // Redo → inset result.
    postRedo();
    auto mRedo = getModel();
    assert(mRedo["vertexCount"].integer == 12,
        "B redo: expected 12 verts, got " ~ mRedo["vertexCount"].integer.to!string);
    assert(mRedo["faceCount"].integer == 10,
        "B redo: expected 10 faces, got " ~ mRedo["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Test C — inset=0 is NOT a no-op (task 0359, reference-matched): the split
// still happens, landing a degenerate zero-width ring (4 new verts exactly
// coincident with the 4 original top-face corners).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int topFi = faceWithCentroid(before, V3(0, 0.5, 0));
    assert(topFi >= 0, "C: top face not found");
    postSelect("polygons", [topFi]);

    postCommand(`{"id":"mesh.poly_inset","params":{"inset":0.0}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 12,
        "C: expected 12 verts after inset=0 split, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 10,
        "C: expected 10 faces after inset=0 split, got " ~ m["faceCount"].integer.to!string);

    // Still all-quads.
    auto fv = fvDist(m);
    assert(fv == [4: 10],
        "C: expected all-quad fv-dist {4:10}, got " ~ fv.to!string);

    // The degenerate ring: 2 verts at each of the 4 original top-face corner
    // positions (original + coincident new inner corner).
    foreach (x; [-0.5, 0.5])
        foreach (z; [-0.5, 0.5]) {
            int n = countAt(m, V3(x, 0.5, z));
            assert(n == 2,
                "C: expected 2 coincident verts at ("~x.to!string~",0.5,"~z.to!string~
                "), found "~n.to!string);
        }

    // Topologically still hole-free and orphan-free (the ring quads are
    // degenerate/zero-area, not missing).
    assert(isHoleFree(m),              "C: result is not hole-free");
    assert(orphanVerts(m).length == 0, "C: orphan verts after inset=0 split");
}

// ---------------------------------------------------------------------------
// Test D — multi-face per-face: top (+Y) + right (+X) → 16v, 14f, 8 distinct
//          inset verts (per-face independence; shared original edge reused).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();

    // Find the top face (+Y, y=0.5) and right face (+X, x=0.5).
    int topFi   = faceWithCentroid(before, V3(0,   0.5, 0));
    int rightFi = faceWithCentroid(before, V3(0.5, 0,   0));
    assert(topFi   >= 0, "D: top face not found");
    assert(rightFi >= 0, "D: right face not found");
    postSelect("polygons", [topFi, rightFi]);

    postCommand(`{"id":"mesh.poly_inset","params":{"inset":0.1}}`);
    auto m = getModel();

    // Per-face inset: each face adds 4 verts + 4 ring quads + 1 inner face.
    // 2 faces selected → 8 new verts (16 total), 8 ring quads + 2 inner faces
    //   (replacing 2 original slots), so 6 - 2 + 2 + 8 = 14 faces total.
    assert(m["vertexCount"].integer == 16,
        "D: expected 16 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 14,
        "D: expected 14 faces, got " ~ m["faceCount"].integer.to!string);

    assert(isHoleFree(m),        "D: result is not hole-free");
    assert(noCoincidentVerts(m), "D: coincident verts found");
    assert(orphanVerts(m).length == 0, "D: orphan verts found");

    // 8 distinct inset verts: top-face insets at
    // (±(0.5-0.1/sqrt(2)), 0.5, ±(0.5-0.1/sqrt(2))), right-face insets at
    // (0.5, ±(0.5-0.1/sqrt(2)), ±(0.5-0.1/sqrt(2))). Per-face independence
    // means the two faces' inset verts are fully separate — no shared inner
    // verts.
    double c = 0.5 - D1;
    foreach (x; [-c, c])
        foreach (z; [-c, c])
            assert(countAt(m, V3(x, 0.5, z)) == 1,
                "D: top inset corner missing at ("~x.to!string~",0.5,"~z.to!string~")");

    foreach (y; [-c, c])
        foreach (z; [-c, c])
            assert(countAt(m, V3(0.5, y, z)) == 1,
                "D: right inset corner missing at (0.5,"~y.to!string~","~z.to!string~")");
}

// ---------------------------------------------------------------------------
// Test E — sign law: negative inset GROWS the duplicate outward (task 0359
// toolcard `behavior.sign_law`, captured parity single_face_neg02). Same +X
// face as Test D's right face, inset=-0.2: displacement magnitude is
// |inset| (0.2) toward centroid, i.e. AWAY from it for a negative inset, so
// each in-plane axis component grows by 0.2/sqrt(2).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int rightFi = faceWithCentroid(before, V3(0.5, 0, 0));
    assert(rightFi >= 0, "E: right face not found");
    postSelect("polygons", [rightFi]);

    postCommand(`{"id":"mesh.poly_inset","params":{"inset":-0.2}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 12,
        "E: expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 10,
        "E: expected 10 faces, got " ~ m["faceCount"].integer.to!string);

    // Outer (grown) corners at (0.5, ±(0.5+0.2/sqrt(2)), ±(0.5+0.2/sqrt(2))).
    double g = 0.5 + 0.2 / SQRT2_;
    foreach (y; [-g, g])
        foreach (z; [-g, g])
            assert(countAt(m, V3(0.5, y, z)) == 1,
                "E: grown corner missing at (0.5,"~y.to!string~","~z.to!string~")");

    assert(isHoleFree(m),        "E: result is not hole-free");
    assert(noCoincidentVerts(m), "E: coincident verts found");
    assert(orphanVerts(m).length == 0, "E: orphan verts found");
}

// ---------------------------------------------------------------------------
// Test F — interactive tool (mesh.polyInsetTool, task 0359): headless
// tool.set/tool.attr/tool.doApply drives the SAME kernel as the one-shot
// command, and undo after tool.set off restores the pre-activation mesh
// exactly — the same undo-after-deactivation shape test_edge_extend_tool.d
// and its siblings pin for their own tools (redo is deliberately NOT
// asserted here: ToolDoApplyCommand.apply() re-fires via
// toolHost.getActiveTool(), which is null once the tool has been switched
// off, a pre-existing characteristic of the tool.doApply redo path shared by
// every interactive tool, not specific to Polygon Inset). Geometry itself is
// pinned by tests/test_fixture_inset.d against the frozen reference.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int rightFi = faceWithCentroid(before, V3(0.5, 0, 0));
    assert(rightFi >= 0, "F: right face not found");
    postSelect("polygons", [rightFi]);

    postCommand("tool.set mesh.polyInsetTool on");
    postCommand("tool.attr mesh.polyInsetTool inset 0.2");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.polyInsetTool off");

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "F: expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 10,
        "F: expected 10 faces, got " ~ m["faceCount"].integer.to!string);

    auto u = postUndo();
    assert(u["status"].str == "ok", "F: undo failed: " ~ u.toString);
    auto mUndo = getModel();
    assert(mUndo["vertexCount"].integer == before["vertexCount"].integer,
        "F undo: expected " ~ before["vertexCount"].integer.to!string ~
        " verts, got " ~ mUndo["vertexCount"].integer.to!string);
    assert(mUndo["faceCount"].integer == before["faceCount"].integer,
        "F undo: expected " ~ before["faceCount"].integer.to!string ~
        " faces, got " ~ mUndo["faceCount"].integer.to!string);
}
