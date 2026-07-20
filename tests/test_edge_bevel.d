// Tests for mesh.bevel (Edge Bevel: chamfer strip) in Edges mode.
//
// Cube vertex layout (from makeCube):
//   0:(-0.5,-0.5,-0.5)  1:(0.5,-0.5,-0.5)  2:(0.5,0.5,-0.5)  3:(-0.5,0.5,-0.5)
//   4:(-0.5,-0.5, 0.5)  5:(0.5,-0.5, 0.5)  6:(0.5,0.5, 0.5)  7:(-0.5,0.5, 0.5)
// Cube faces:
//   0:[0,3,2,1]  1:[4,5,6,7]  2:[0,4,7,3]  3:[1,2,6,5]  4:[3,7,6,2]  5:[0,1,5,4]
// Edge (6,7) = between face1(+Z) and face4(+Y), valence-3 endpoints.
// bevel width=0.1 → 10 verts (8+4-2), 7 faces, fv-dist {4:5,5:2}.
// Chamfer centroid (0,0.45,0.45), normal pointing outward in (+Y+Z) direction.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// --- HTTP helpers ------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(cast(string)post("http://localhost:8080/api/command", body));
}

void postCommand(string body) {
    auto r = postCommandRaw(body);
    assert(r["status"].str == "ok", "/api/command failed: " ~ body ~ " → " ~ r.toString);
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
V3 cross3(V3 a, V3 b) {
    return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
double dot3(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }

V3 faceCentroid(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    V3 c = V3(0, 0, 0);
    foreach (k; 0 .. idx.length) c = add3(c, vert(m, cast(size_t)idx[k].integer));
    return V3(c.x / idx.length, c.y / idx.length, c.z / idx.length);
}

// Newell face normal (not normalized).
V3 faceNormal(JSONValue m, JSONValue faceArr) {
    auto idx = faceArr.array;
    auto n   = idx.length;
    V3 nm = V3(0,0,0);
    foreach (k; 0 .. n) {
        auto vi = vert(m, cast(size_t)idx[k].integer);
        auto vj = vert(m, cast(size_t)idx[(k+1)%n].integer);
        nm.x += (vi.y - vj.y) * (vi.z + vj.z);
        nm.y += (vi.z - vj.z) * (vi.x + vj.x);
        nm.z += (vi.x - vj.x) * (vi.y + vj.y);
    }
    return nm;
}

int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

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

bool noCoincidentVerts(JSONValue m, double tol=1e-4) {
    auto n = m["vertices"].array.length;
    foreach (i; 0 .. n)
        foreach (j; i + 1 .. n)
            if (len3(sub3(vert(m, i), vert(m, j))) < tol) return false;
    return true;
}

double faceArea(JSONValue m, JSONValue faceArr) {
    return len3(faceNormal(m, faceArr)) * 0.5;
}

bool noDegenerateFaces(JSONValue m, double areaEps=1e-6) {
    foreach (f; m["faces"].array) {
        bool[long] distinct;
        foreach (c; f.array) distinct[c.integer] = true;
        if (distinct.length < 3) return false;
        if (faceArea(m, f) < areaEps) return false;
    }
    return true;
}

// Find edge index for endpoints (a,b) (order-independent), or -1.
int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x==a&&y==b)||(x==b&&y==a)) return cast(int)i;
    }
    return -1;
}

// Index of first vertex near p, or -1.
int vertAt(JSONValue m, V3 p, double tol=1e-4) {
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) return cast(int)i;
    return -1;
}

// ---------------------------------------------------------------------------
// Test A — cube edge (6,7) between +Y and +Z faces, width=0.1
//          → 10v/7f, fv-dist {4:5,5:2}, chamfer centroid (0,0.45,0.45),
//            chamfer normal points outward (+Y+Z), hole-free, no orphans.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();

    // Find vertices 6=(0.5,0.5,0.5) and 7=(-0.5,0.5,0.5).
    int v6 = vertAt(before, V3( 0.5, 0.5, 0.5));
    int v7 = vertAt(before, V3(-0.5, 0.5, 0.5));
    assert(v6 >= 0 && v7 >= 0, "A: verts 6 and 7 not found");
    int ei = edgeIndex(before, v6, v7);
    assert(ei >= 0, "A: edge (6,7) not found");

    // postSelect("edges",...) enters Edges mode automatically.
    postSelect("edges", [ei]);

    postCommand(`{"id":"mesh.bevel","params":{"width":0.1}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 10,
        "A: expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "A: expected 7 faces, got " ~ m["faceCount"].integer.to!string);

    auto fv = fvDist(m);
    assert(fv.get(4,0) == 5 && fv.get(5,0) == 2,
        "A: expected fv-dist {4:5,5:2}, got " ~ fv.to!string);

    // Chamfer face should be selected.
    auto sel = getSelection();
    assert(sel["selectedFaces"].array.length == 1,
        "A: expected 1 selected (chamfer) face, got " ~ sel["selectedFaces"].array.length.to!string);
    int chamferFi = cast(int)sel["selectedFaces"].array[0].integer;
    auto chamferFace = m["faces"].array[chamferFi];
    assert(chamferFace.array.length == 4, "A: chamfer should be a quad");

    // Chamfer centroid near (0, 0.45, 0.45).
    auto cen = faceCentroid(m, chamferFace);
    assert(abs(cen.x) < 1e-3 && abs(cen.y - 0.45) < 1e-3 && abs(cen.z - 0.45) < 1e-3,
        "A: chamfer centroid expected (0,0.45,0.45), got (" ~
        cen.x.to!string ~ "," ~ cen.y.to!string ~ "," ~ cen.z.to!string ~ ")");

    // Winding: chamfer normal must point outward (dot with (0,1,1)/sqrt(2) > 0.9).
    auto n = faceNormal(m, chamferFace);
    double nlen = len3(n);
    assert(nlen > 1e-6, "A: chamfer normal degenerate");
    double cosAngle = dot3(V3(0, n.y/nlen, n.z/nlen), V3(0, 1.0/sqrt(2.0), 1.0/sqrt(2.0)));
    assert(cosAngle > 0.9,
        "A: chamfer normal should point in (+Y+Z) direction, cosAngle=" ~ cosAngle.to!string);

    assert(orphanVerts(m).length == 0, "A: orphan verts");
    assert(isHoleFree(m),              "A: not hole-free");
    assert(noCoincidentVerts(m),       "A: coincident verts");
}

// ---------------------------------------------------------------------------
// Test B — undo restores 8v/6f; redo re-applies 10v/7f.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int v6 = vertAt(before, V3( 0.5, 0.5, 0.5));
    int v7 = vertAt(before, V3(-0.5, 0.5, 0.5));
    int ei = edgeIndex(before, v6, v7);
    assert(ei >= 0, "B: edge (6,7) not found");
    postSelect("edges", [ei]);
    // (postSelect "edges" enters Edges mode automatically)
    postCommand(`{"id":"mesh.bevel","params":{"width":0.1}}`);

    auto u = postUndo();
    assert(u["status"].str == "ok", "B: undo failed: " ~ u.toString);
    auto ma = getModel();
    assert(ma["vertexCount"].integer == 8, "B: undo verts expected 8");
    assert(ma["faceCount"].integer   == 6, "B: undo faces expected 6");

    auto r = postRedo();
    assert(r["status"].str == "ok", "B: redo failed: " ~ r.toString);
    auto mb = getModel();
    assert(mb["vertexCount"].integer == 10, "B: redo verts expected 10");
    assert(mb["faceCount"].integer   == 7,  "B: redo faces expected 7");
}

// ---------------------------------------------------------------------------
// Test C — width=0 → status:error, mesh unchanged.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int v6 = vertAt(before, V3( 0.5, 0.5, 0.5));
    int v7 = vertAt(before, V3(-0.5, 0.5, 0.5));
    int ei = edgeIndex(before, v6, v7);
    assert(ei >= 0, "C: edge (6,7) not found");
    postSelect("edges", [ei]);
    // (postSelect "edges" enters Edges mode automatically)

    auto r = postCommandRaw(`{"id":"mesh.bevel","params":{"width":0.0}}`);
    assert(r["status"].str == "error", "C: expected error for width=0, got " ~ r["status"].str);
    auto m = getModel();
    assert(m["vertexCount"].integer == 8, "C: mesh should be unchanged (8 verts)");
    assert(m["faceCount"].integer   == 6, "C: mesh should be unchanged (6 faces)");
}

// ---------------------------------------------------------------------------
// Test D — shared-face / fully-connected config (task 0391 Phase 1/2): select
// ALL 12 edges of the cube. Pre-0391, the old face-disjoint / endpoint-
// disjoint guards rejected any selection where 2 edges shared a face or
// endpoint, so this whole-cube selection was silently skipped. Task 0391
// LIFTS those guards specifically to support this "bevel every edge"
// gesture (a standard "chamfer box" operation): every one of the cube's 8
// corners is now a full K==valence(3) junction, so EVERY corner is replaced
// by 3 hub vertices + 1 triangle cap (exactly the edge_bevel_corner.json
// cap topology, applied at all 8 corners simultaneously) — 8*3=24 hub
// verts (0 originals survive — every corner is fully consumed), 6 original
// faces shrink to smaller quads (each of their 4 corners now a hub), + 12
// per-edge chamfer quads + 8 corner-hub triangles.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();

    // Select all edges (a cube has 12 edges).
    int numEdges = cast(int)before["edgeCount"].integer;
    int[] allEdgeIdx;
    foreach (i; 0 .. numEdges) allEdgeIdx ~= i;
    postSelect("edges", allEdgeIdx);
    // (postSelect "edges" enters Edges mode automatically)

    auto r = postCommandRaw(`{"id":"mesh.bevel","params":{"width":0.05}}`);
    assert(r["status"].str == "ok",
        "D: bevel-all-edges should now succeed (task 0391 lifts the face-disjoint guard), got " ~
        r["status"].str);

    auto m = getModel();
    assert(m["vertexCount"].integer == 24,
        "D: expected 24 hub verts (8 corners x 3 hubs, 0 originals survive), got " ~
        m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 26,
        "D: expected 26 faces (6 shrunk originals + 12 chamfers + 8 corner-hub caps), got " ~
        m["faceCount"].integer.to!string);
    auto fvd = fvDist(m);
    assert(fvd.get(4, 0) == 18, "D: expected 18 quads (6 shrunk originals + 12 chamfers)");
    assert(fvd.get(3, 0) == 8,  "D: expected 8 triangles (one hub cap per corner)");

    assert(isHoleFree(m),           "D: mesh not hole-free after the full-cube bevel");
    assert(noCoincidentVerts(m),    "D: no coincident vertices expected");
    assert(orphanVerts(m).length == 0, "D: no orphaned (unreferenced) vertices expected");
}

// ---------------------------------------------------------------------------
// Test E — overshoot guard (task 0304, re-measured task 0436): width == the
//          length of the adjacent (non-bevel) edge clamps the slide corner
//          per-direction (bit-exact) at that far vertex's position — but the
//          reference does NOT weld it into the pre-existing far vertex.
//          `toolcards/edge.bevel/clamp_findings.md` Case A: it leaves the
//          duplicate in place (10v stays 10v, not 9v) with a hole-free,
//          orphan-free mesh; the old assumption that this must come out
//          "clean" (no coincident verts) was never reference-verified, and
//          the reference's own capture shows the opposite.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int v6 = vertAt(before, V3( 0.5, 0.5, 0.5));
    int v7 = vertAt(before, V3(-0.5, 0.5, 0.5));
    assert(v6 >= 0 && v7 >= 0, "E: verts 6 and 7 not found");
    int ei = edgeIndex(before, v6, v7);
    assert(ei >= 0, "E: edge (6,7) not found");
    postSelect("edges", [ei]);

    // width == 1.0 == length of every adjacent (non-bevel) edge on a unit cube.
    auto r = postCommandRaw(`{"id":"mesh.bevel","params":{"width":1.0}}`);
    assert(r["status"].str == "ok", "E: width==adjacent edge length should still process (clamped)");
    auto m = getModel();
    assert(m["vertexCount"].integer == 10,
        "E: expected 10 vertex records (no weld against the original mesh), got " ~
        m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "E: expected 7 faces, got " ~ m["faceCount"].integer.to!string);
    assert(isHoleFree(m),              "E: not hole-free at width==adjacent edge length");
    assert(orphanVerts(m).length == 0, "E: orphan verts at width==adjacent edge length");
    // The reference leaves the clamp-saturated slide corner and the
    // pre-existing far vertex it lands on as two separate, coincident
    // records — asserting their ABSENCE would be the stale (unverified)
    // expectation this test used to make.
    assert(!noCoincidentVerts(m),
        "E: expected coincident verts at width==adjacent edge length (no weld against the original mesh)");

    // Sanity: a normal small width must be completely unaffected by the guard.
    resetCube();
    auto before2 = getModel();
    int v6b = vertAt(before2, V3( 0.5, 0.5, 0.5));
    int v7b = vertAt(before2, V3(-0.5, 0.5, 0.5));
    int eib = edgeIndex(before2, v6b, v7b);
    postSelect("edges", [eib]);
    postCommand(`{"id":"mesh.bevel","params":{"width":0.1}}`);
    auto m2 = getModel();
    assert(m2["vertexCount"].integer == 10, "E: normal width must be unaffected by the guard");
    assert(m2["faceCount"].integer   == 7,  "E: normal width must be unaffected by the guard");
    assert(noCoincidentVerts(m2), "E: normal width must have no coincident verts");
}
