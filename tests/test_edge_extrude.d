// Tests for mesh.edge_extrude (Edge Extrude kernel + command).
//
// Topology model (matches the reference edge-extrude). For each selected edge with two
// neighbor faces T/F:
//   - one ridge vertex per endpoint (welded across edges that share an endpoint)
//   - one inset vertex per (endpoint, neighbor-face); shared corners average
//   - the two neighbor faces keep their degree (edge replaced by the inset edge)
//   - two ridge-bridge quads (one per neighbor side) + the ridge edge
//   - FREE ENDS (endpoints touched by exactly one selected edge that is
//     interior): the endpoint is DISSOLVED — every non-neighbor "side" face has
//     its corner replaced by the endpoint's two insets (quad → 5-gon), and a
//     triangle cap [insetF, insetT, ridge] closes the corner. Dissolved
//     endpoints are dropped by compaction (no orphans).
//   - SHARED endpoints (chain joints, ≥2 selected edges) stay welded: one ridge
//     vertex, NO cap.
//   - BOUNDARY edges (one neighbor face) close with an inset-gap quad + a
//     ridge-bridge quad; their free ends keep their other faces intact (only one
//     inset, no split, no cap). Boundary parity vs the reference is out of scope, but the
//     result must be hole-free.
//
// The canonical reference-parity fixture is the CUBE interior edge (test 1); the grid
// cases (tests 2-5) exercise welding / boundary / fan / chain on a small open
// mesh. n=2 grid (resetGrid(2)): side = 3, 9 verts on the y=0 plane, 4 quads,
// row-major index(i,j)=i*3+j.
//
//        z=+1   6  7  8
//        z= 0   3  4  5
//        z=-1   0  1  2
//             x=-1  0 +1
//
// Faces (addFace order): f0=[0,1,4,3] f1=[1,2,5,4] f2=[3,4,7,6] f3=[4,5,8,7].
// Edge indices are derived from faces in a deterministic order; each test
// discovers the index it needs by endpoint pair from /api/model's "edges" array.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;

void main() {}

// --- HTTP helpers (same shapes as tests/test_delete.d) ---------------------

void resetGrid(int n) {
    auto resp = post("http://localhost:8080/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset grid failed: " ~ resp);
}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
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
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }

// --- small geometry helpers ------------------------------------------------

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

// Index of the (undirected) edge with endpoints {a,b} in model["edges"], or -1.
int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

// Index of the first vertex coincident with position p (within tol), or -1.
int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        if (len3(sub3(vert(m, i), p)) < 1e-4) return cast(int)i;
    }
    return -1;
}

// Newell normal of a face (array of vertex indices) given current verts.
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

double dot3(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 add3(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }
V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
double len3(V3 a) { return sqrt(dot3(a, a)); }
V3 norm3(V3 a) { auto l = len3(a); return l < 1e-9 ? V3(0,0,0) : V3(a.x/l, a.y/l, a.z/l); }

// Map face-vertex-count → frequency, e.g. {4:6, 5:2, 3:2}.
int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

// Indices not referenced by any face — must be empty (no orphans).
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

// True if the surface is hole-free: no undirected edge is shared by >2 faces and
// no directed half-edge is used more than once (a fold / coincident winding).
// Open boundaries (undirected edge used once) are allowed for the grid cases.
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
    foreach (_, c; undirected) if (c > 2) return false;     // non-manifold
    foreach (_, c; directed)   if (c > 1) return false;     // folded faces
    return true;
}

// Count vertices coincident with position p (within tol).
int countAt(JSONValue m, V3 p) {
    int n = 0;
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < 1e-4) ++n;
    return n;
}

// True if NO two distinct vertices in the model share a position (within tol).
// A welded result must have zero coincident duplicate verts.
bool noCoincidentVerts(JSONValue m) {
    auto n = m["vertices"].array.length;
    foreach (i; 0 .. n)
        foreach (j; i + 1 .. n)
            if (len3(sub3(vert(m, i), vert(m, j))) < 1e-4) return false;
    return true;
}

V3 avgNeighborNormal(JSONValue before, int a, int b) {
    V3 sum = V3(0, 0, 0);
    foreach (face; before["faces"].array) {
        auto idx = face.array;
        bool adj = false;
        foreach (k; 0 .. idx.length) {
            long u = idx[k].integer, w = idx[(k + 1) % idx.length].integer;
            if ((u == a && w == b) || (u == b && w == a)) { adj = true; break; }
        }
        if (adj) sum = add3(sum, faceNormal(before, face));
    }
    return norm3(sum);
}

// ---------------------------------------------------------------------------
// 1. CUBE interior edge — the reference-parity topology (12 verts, 10 faces).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["faceCount"].integer == 6);

    // Top-front edge: va=(-0.5,0.5,0.5), vb=(0.5,0.5,0.5); neighbor faces are the
    // +Y top and +Z front. Both endpoints are interior free ends → dissolved,
    // each closed with a 5-gon side face + a triangle cap. reference target:
    //   12 verts, 10 faces, fv-dist {4:6, 5:2, 3:2}.
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "cube top-front edge not found");
    postSelect("edges", [ei]);

    enum extrude = 0.2, width = 0.1;
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // Exact reference counts.
    assert(m["vertexCount"].integer == 12,
        "cube: expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 10,
        "cube: expected 10 faces, got " ~ m["faceCount"].integer.to!string);
    auto fv = fvDist(m);
    assert(fv == [4: 6, 5: 2, 3: 2],
        "cube: expected fv-dist {4:6,5:2,3:2}, got " ~ fv.to!string);

    // The two dissolved endpoints leave NO orphan vertices (compaction ran).
    assert(orphanVerts(m).length == 0,
        "cube: orphan verts after compaction: " ~ orphanVerts(m).to!string);

    // Hole-free, orientable: no non-manifold / folded edges.
    assert(isHoleFree(m), "cube: result is not hole-free / has folded faces");

    // Ridge verts = original endpoints displaced by extrude along the averaged
    // neighbor normal. Both must be present.
    V3 ne = avgNeighborNormal(before, va, vb);
    auto expA = add3(vert(before, va), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    auto expB = add3(vert(before, vb), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    assert(vertAt(m, expA) >= 0, "cube: ridge vert for va missing");
    assert(vertAt(m, expB) >= 0, "cube: ridge vert for vb missing");

    // The two triangle caps must be oriented outward — their normal points away
    // from the span centroid (the mesh center is ~origin; cap centroids sit at
    // the ±X free ends, so cap normal · (capCentroid - origin) > 0).
    int tris = 0;
    foreach (fi; 0 .. m["faces"].array.length) {
        auto f = m["faces"].array[fi];
        if (f.array.length != 3) continue;
        ++tris;
        auto c = faceCentroid(m, f);
        auto n = faceNormal(m, f);
        assert(dot3(n, c) > 0.0,
            "cube: triangle cap " ~ fi.to!string ~ " not oriented outward (dot=" ~
            dot3(n, c).to!string ~ ")");
    }
    assert(tris == 2, "cube: expected exactly 2 triangle caps, got " ~ tris.to!string);

    // The single ridge edge (connecting the two ridge verts) is selected.
    auto sel = getSelection();
    assert(sel["selectedEdges"].array.length == 1,
        "cube: expected 1 ridge edge selected, got " ~
        sel["selectedEdges"].array.length.to!string);
}

// ---------------------------------------------------------------------------
// 1b. CUBE interior edge, NEGATIVE (inward) extrude — same topology as test 1
//     (12 verts, 10 faces) but the ridge is pushed INWARD. The free-end triangle
//     caps must stay consistently wound with the bridge faces: when the ridge
//     flips from outward (extrude>0) to inward (extrude<0) the cap's geometric
//     normal flips too, so the cap winding must flip to match. Concretely, the
//     positive case asserts cap normal · capCentroid > 0 (points away from the
//     origin); for a negative extrude the same caps must point the opposite way,
//     i.e. cap normal · capCentroid < 0. This mirrors test 1's cap-orientation
//     check with extrude < 0 and guards the sign-aware cap reference.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["faceCount"].integer == 6);

    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube(neg) top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "cube(neg) top-front edge not found");
    postSelect("edges", [ei]);

    enum extrude = -0.2, width = 0.1;
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":-0.2,"width":0.1}}`);
    auto m = getModel();

    // Same topology as the positive case — only the ridge moved inward.
    assert(m["vertexCount"].integer == 12,
        "cube(neg): expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 10,
        "cube(neg): expected 10 faces, got " ~ m["faceCount"].integer.to!string);
    auto fv = fvDist(m);
    assert(fv == [4: 6, 5: 2, 3: 2],
        "cube(neg): expected fv-dist {4:6,5:2,3:2}, got " ~ fv.to!string);
    assert(orphanVerts(m).length == 0,
        "cube(neg): orphan verts after compaction: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "cube(neg): result is not hole-free / has folded faces");

    // Ridge verts = endpoints displaced INWARD (extrude<0) along the averaged
    // neighbor normal; both must be present (positions carry the sign).
    V3 ne = avgNeighborNormal(before, va, vb);
    auto expA = add3(vert(before, va), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    auto expB = add3(vert(before, vb), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    assert(vertAt(m, expA) >= 0, "cube(neg): ridge vert for va missing");
    assert(vertAt(m, expB) >= 0, "cube(neg): ridge vert for vb missing");

    // Sign-aware cap orientation: for a negative extrude the two triangle caps
    // wind the OPPOSITE way vs the positive case, so cap normal · capCentroid < 0
    // (they point back toward the origin, consistent with the inward bridges).
    int tris = 0;
    foreach (fi; 0 .. m["faces"].array.length) {
        auto f = m["faces"].array[fi];
        if (f.array.length != 3) continue;
        ++tris;
        auto c = faceCentroid(m, f);
        auto n = faceNormal(m, f);
        assert(dot3(n, c) < 0.0,
            "cube(neg): triangle cap " ~ fi.to!string ~
            " not oriented consistently with inward extrude (dot=" ~
            dot3(n, c).to!string ~ ")");
    }
    assert(tris == 2, "cube(neg): expected exactly 2 triangle caps, got " ~ tris.to!string);
}

// ---------------------------------------------------------------------------
// 2. Grid interior edge (3,4): boundary endpoint v3 (dissolved + capped) and
//    center endpoint v4 (insets into its two side faces). Different valence than
//    the cube, so a different — but still hole-free, orphan-free — topology.
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();
    assert(before["faceCount"].integer == 4);
    assert(before["vertexCount"].integer == 9);

    int ei = edgeIndex(before, 3, 4);
    assert(ei >= 0, "interior edge (3,4) not found");
    postSelect("edges", [ei]);

    enum extrude = 0.2, width = 0.1;
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // New topology: 14 verts, 8 faces, fv-dist {4:4, 5:2, 3:2}. v3 (a boundary
    // endpoint with only its two neighbor faces) is dissolved + capped; v4 (the
    // valence-4 center) has its two side faces grown to 5-gons.
    assert(m["vertexCount"].integer == 14,
        "grid interior: expected 14 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "grid interior: expected 8 faces, got " ~ m["faceCount"].integer.to!string);
    auto fv = fvDist(m);
    assert(fv == [4: 4, 5: 2, 3: 2],
        "grid interior: expected fv-dist {4:4,5:2,3:2}, got " ~ fv.to!string);

    assert(orphanVerts(m).length == 0,
        "grid interior: orphan verts: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "grid interior: result is not hole-free");

    // Ridge displacement check on both endpoints.
    V3 ne = avgNeighborNormal(before, 3, 4);
    assert(len3(ne) > 0.5, "averaged neighbor normal degenerate");
    auto exp3 = add3(vert(before, 3), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    auto exp4 = add3(vert(before, 4), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    assert(vertAt(m, exp3) >= 0, "grid interior: ridge vert for v3 missing");
    assert(vertAt(m, exp4) >= 0, "grid interior: ridge vert for v4 missing");

    // The two ridge-bridge quads' normals point outward (positive dot with ne).
    int bridges = 0;
    foreach (fi; 0 .. m["faces"].array.length) {
        auto f = m["faces"].array[fi];
        if (f.array.length != 4) continue;
        // Bridge quads are the ones containing a ridge vert.
        bool hasRidge = false;
        foreach (c; f.array) {
            auto p = vert(m, cast(size_t)c.integer);
            if (len3(sub3(p, exp3)) < 1e-4 || len3(sub3(p, exp4)) < 1e-4) hasRidge = true;
        }
        if (!hasRidge) continue;
        ++bridges;
        assert(dot3(faceNormal(m, f), ne) > 0.0,
            "grid interior: bridge quad " ~ fi.to!string ~ " inverted");
    }
    assert(bridges == 2, "grid interior: expected 2 ridge-bridge quads, got " ~
        bridges.to!string);
}

// ---------------------------------------------------------------------------
// 3. Boundary edge (1 adjacent face): hole-free, +4 verts / +2 faces.
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();

    int ei = edgeIndex(before, 0, 1);
    assert(ei >= 0, "boundary edge (0,1) not found");
    postSelect("edges", [ei]);

    enum extrude = 0.2;
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // Boundary branch: 4 new verts (ridge×2 + inset×2), 2 new quads (inset-gap +
    // ridge-bridge). Boundary free ends keep their other faces (no split / cap),
    // so all faces stay quads and v0/v1 survive (no compaction removal).
    assert(m["vertexCount"].integer == before["vertexCount"].integer + 4,
        "boundary: expected +4 verts, got " ~
        to!string(m["vertexCount"].integer - before["vertexCount"].integer));
    assert(m["faceCount"].integer == before["faceCount"].integer + 2,
        "boundary: expected +2 faces, got " ~
        to!string(m["faceCount"].integer - before["faceCount"].integer));
    assert(orphanVerts(m).length == 0, "boundary: unexpected orphan verts");
    assert(isHoleFree(m), "boundary: result has a hole / non-manifold edge");

    // Ridge moves along the single face normal by extrude.
    V3 ne = avgNeighborNormal(before, 0, 1);
    assert(len3(ne) > 0.5, "boundary neighbor normal degenerate");
    auto exp0 = add3(vert(before, 0), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    auto exp1 = add3(vert(before, 1), V3(ne.x*extrude, ne.y*extrude, ne.z*extrude));
    assert(vertAt(m, exp0) >= 0, "boundary: ridge vert for v0 missing");
    assert(vertAt(m, exp1) >= 0, "boundary: ridge vert for v1 missing");
}

// ---------------------------------------------------------------------------
// 4. 2-edge collinear chain sharing a vertex → 1 welded ridge, 2 outer caps.
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();

    // Interior edges (1,4) [f0,f1] and (4,7) [f2,f3] are collinear along x=0,
    // sharing the center vertex v4 but living in different face pairs.
    int e14 = edgeIndex(before, 1, 4);
    int e47 = edgeIndex(before, 4, 7);
    assert(e14 >= 0 && e47 >= 0, "chain edges not found");
    postSelect("edges", [e14, e47]);

    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // v4 is shared (≥2 selected edges) → ONE welded ridge vert, NO cap there.
    // v1 and v7 are the two outer free ends → each dissolved + capped, so
    // fv-dist has exactly 2 triangles. No orphans, hole-free.
    assert(orphanVerts(m).length == 0, "chain: orphan verts: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "chain: result not hole-free");
    auto fv = fvDist(m);
    assert(fv.get(3, 0) == 2,
        "chain: expected exactly 2 triangle caps (outer free ends), got " ~
        fv.get(3, 0).to!string ~ " (fv-dist " ~ fv.to!string ~ ")");

    // Welded center: exactly ONE ridge vert sits at v4 + extrude·ne. A non-welded
    // result would place two coincident ridge verts there.
    V3 ne4 = avgNeighborNormal(before, 1, 4);   // same averaged dir for collinear edges
    auto exp4 = add3(vert(before, 4), V3(ne4.x*0.2, ne4.y*0.2, ne4.z*0.2));
    int atCenter = 0;
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), exp4)) < 1e-4) ++atCenter;
    assert(atCenter == 1,
        "chain: expected ONE welded ridge vert at the shared corner, got " ~
        atCenter.to!string);

    // No two output vertices may be coincident (welds must collapse, never
    // duplicate).
    assert(noCoincidentVerts(m), "chain: coincident duplicate vertices present");
}

// ---------------------------------------------------------------------------
// 5. Corner / fan — two boundary edges sharing a single quad and a vertex.
// ---------------------------------------------------------------------------

unittest {
    // f0 = [0,1,4,3]. Edges (0,1) and (0,3) both border f0 and share v0. Both are
    // perimeter (boundary) edges. Face-centric rewrite must produce ONE inset
    // vert for v0 in f0 and ONE welded ridge vert for v0 — no duplicated corner.
    resetGrid(2);
    auto before = getModel();
    int e01 = edgeIndex(before, 0, 1);
    int e03 = edgeIndex(before, 0, 3);
    assert(e01 >= 0 && e03 >= 0, "fan edges not found");
    postSelect("edges", [e01, e03]);

    auto raw = postCommandRaw(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    assert(parseJSON(raw)["status"].str == "ok", "fan extrude failed: " ~ raw);
    auto m = getModel();

    // The rewritten neighbor quad f0 must remain a clean polygon: no repeated
    // corner index, ≥ 3 corners.
    auto f0 = m["faces"].array[0].array;
    assert(f0.length >= 3, "fan: f0 collapsed to < 3 corners");
    foreach (i; 0 .. f0.length)
        foreach (j; i + 1 .. f0.length)
            assert(f0[i].integer != f0[j].integer,
                "fan: f0 has a duplicated corner");

    // Both edges are boundary, sharing v0; v0 welds to ONE ridge vert. Outer free
    // ends are boundary (one neighbor face) → no caps. Hole-free, no orphans.
    assert(orphanVerts(m).length == 0, "fan: orphan verts: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "fan: result not hole-free");

    // v0's welded ridge vert: exactly ONE vertex at v0 + extrude·ne0 (averaged
    // over the two incident edges' neighbor normals — here both border f0).
    V3 n0 = avgNeighborNormal(before, 0, 1);    // f0 normal
    auto exp0 = add3(vert(before, 0), V3(n0.x*0.2, n0.y*0.2, n0.z*0.2));
    int atCorner = 0;
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), exp0)) < 1e-4) ++atCorner;
    assert(atCorner == 1,
        "fan: expected ONE welded ridge vert at the shared corner, got " ~
        atCorner.to!string);

    // No two output vertices may be coincident.
    assert(noCoincidentVerts(m), "fan: coincident duplicate vertices present");
}

// ---------------------------------------------------------------------------
// 8. CUBE corner fan — two top edges sharing the +X/+Y/+Z corner. Pins the
//    distinct-face-normal ridge average AND the no-coincident-vert weld at a
//    shared corner whose two edges border one common neighbor face (+Y).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();

    // Edge A = top edge along X on the +Y/+Z faces: (0.5,0.5,0.5)-(-0.5,0.5,0.5).
    // Edge B = top-right edge along Z on the +X/+Y faces: (0.5,0.5,0.5)-(0.5,0.5,-0.5).
    // They share corner C=(0.5,0.5,0.5); their neighbor faces are {+Y,+Z} and
    // {+X,+Y} — +Y is shared by BOTH edges.
    int c   = vertAt(before, V3(0.5, 0.5, 0.5));
    int a1  = vertAt(before, V3(-0.5, 0.5, 0.5));
    int b1  = vertAt(before, V3(0.5, 0.5, -0.5));
    assert(c >= 0 && a1 >= 0 && b1 >= 0, "fan-weld endpoints not found");
    int eA = edgeIndex(before, c, a1);
    int eB = edgeIndex(before, c, b1);
    assert(eA >= 0 && eB >= 0, "fan-weld edges not found");
    postSelect("edges", [eA, eB]);

    enum extrude = 0.2;
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // Reference target: 14 verts, 12 faces, fv-dist {4:8, 5:2, 3:2}.
    assert(m["vertexCount"].integer == 14,
        "fan-weld: expected 14 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "fan-weld: expected 12 faces, got " ~ m["faceCount"].integer.to!string);
    auto fv = fvDist(m);
    assert(fv == [4: 8, 5: 2, 3: 2],
        "fan-weld: expected fv-dist {4:8,5:2,3:2}, got " ~ fv.to!string);

    assert(orphanVerts(m).length == 0, "fan-weld: orphan verts");
    assert(isHoleFree(m), "fan-weld: not hole-free");
    assert(noCoincidentVerts(m), "fan-weld: coincident duplicate vertices present");

    // Distinct-face-normal ridge average at the shared corner C. The reference
    // displaces C along normalize(sum of the DISTINCT neighbor-face normals over
    // both incident edges) = {+X,+Y,+Z} → (1,1,1)/√3 — NOT the per-edge-averaged
    // normal sum (which double-counts the shared +Y face and skews the direction).
    V3 dirDistinct = norm3(V3(1, 1, 1));
    auto ridgeExp = add3(vert(before, c),
        V3(dirDistinct.x*extrude, dirDistinct.y*extrude, dirDistinct.z*extrude));
    assert(countAt(m, ridgeExp) == 1,
        "fan-weld: shared-corner ridge not at distinct-face-normal average " ~
        "(expected one vert at " ~
        to!string([ridgeExp.x, ridgeExp.y, ridgeExp.z]) ~ ")");

    // The two-edge-averaged sum (each edge's normalize(nT+nF)) would land here —
    // it MUST NOT, proving the dedupe of the shared +Y face.
    V3 nA = avgNeighborNormal(before, c, a1);   // normalize(+Y + +Z)
    V3 nB = avgNeighborNormal(before, c, b1);   // normalize(+X + +Y)
    V3 dirPerEdge = norm3(add3(nA, nB));
    auto ridgeWrong = add3(vert(before, c),
        V3(dirPerEdge.x*extrude, dirPerEdge.y*extrude, dirPerEdge.z*extrude));
    assert(len3(sub3(ridgeWrong, ridgeExp)) > 1e-3,
        "fan-weld: test precondition — the two ridge formulas must differ");
    assert(countAt(m, ridgeWrong) == 0,
        "fan-weld: shared-corner ridge used per-edge-sum (double-counted +Y face)");
}

// ---------------------------------------------------------------------------
// 9. CUBE top loop — the 4 edges of the +Y face form a CLOSED loop (every
//    endpoint shared, no free ends). The reference unifies it into one inset
//    ring with NO caps and NO duplicate verts: 16 verts, 14 faces, all quads.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();

    int v00 = vertAt(before, V3(-0.5, 0.5, 0.5));
    int v10 = vertAt(before, V3( 0.5, 0.5, 0.5));
    int v11 = vertAt(before, V3( 0.5, 0.5, -0.5));
    int v01 = vertAt(before, V3(-0.5, 0.5, -0.5));
    assert(v00 >= 0 && v10 >= 0 && v11 >= 0 && v01 >= 0, "top-loop corners not found");
    int e0 = edgeIndex(before, v00, v10);
    int e1 = edgeIndex(before, v10, v11);
    int e2 = edgeIndex(before, v11, v01);
    int e3 = edgeIndex(before, v01, v00);
    assert(e0 >= 0 && e1 >= 0 && e2 >= 0 && e3 >= 0, "top-loop edges not found");
    postSelect("edges", [e0, e1, e2, e3]);

    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // Closed loop: 16 verts, 14 faces, ALL quads (no caps).
    assert(m["vertexCount"].integer == 16,
        "top-loop: expected 16 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 14,
        "top-loop: expected 14 faces, got " ~ m["faceCount"].integer.to!string);
    auto fv = fvDist(m);
    assert(fv == [4: 14],
        "top-loop: expected all-quad fv-dist {4:14}, got " ~ fv.to!string);
    assert(fv.get(3, 0) == 0, "top-loop: closed loop must have NO triangle caps");

    assert(orphanVerts(m).length == 0, "top-loop: orphan verts");
    assert(isHoleFree(m), "top-loop: not hole-free");
    // The crux of the multi-edge weld fix: no coincident duplicate verts. The
    // two side faces flanking each vertical corner edge both inset that corner
    // straight down — those insets MUST weld to one vert, not duplicate.
    assert(noCoincidentVerts(m), "top-loop: coincident duplicate vertices present");

    // The inner inset ring stays in the +Y plane (y == 0.5) inset by width along
    // BOTH in-plane directions (offsets ADD, not average-renormalize): the +X/+Z
    // corner insets to (0.4,0.5,0.4).
    assert(countAt(m, V3(0.4, 0.5, 0.4)) == 1,
        "top-loop: top-plane inset ring vert (0.4,0.5,0.4) missing/duplicated");
}

// ---------------------------------------------------------------------------
// 6. Undo / redo restores counts (cube interior edge).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    int ei = edgeIndex(before, va, vb);
    postSelect("edges", [ei]);
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto after = getModel();
    assert(after["vertexCount"].integer == 12);
    assert(after["faceCount"].integer == 10);

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["faceCount"].integer   == before["faceCount"].integer,   "faces not restored on undo");
    assert(m["vertexCount"].integer == before["vertexCount"].integer, "verts not restored on undo");
    assert(m["edgeCount"].integer   == before["edgeCount"].integer,   "edges not restored on undo");

    auto r = postRedo();
    assert(r["status"].str == "ok", "redo failed: " ~ r.toString);
    auto m2 = getModel();
    assert(m2["faceCount"].integer   == after["faceCount"].integer,   "faces not redone");
    assert(m2["vertexCount"].integer == after["vertexCount"].integer, "verts not redone");
}

// ---------------------------------------------------------------------------
// 7. No-op: extrude=0, width=0 leaves geometry unchanged.
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();
    int ei = edgeIndex(before, 3, 4);
    postSelect("edges", [ei]);

    auto raw = postCommandRaw(`{"id":"mesh.edge_extrude","params":{"extrude":0.0,"width":0.0}}`);
    auto m = getModel();
    assert(m["faceCount"].integer   == before["faceCount"].integer,   "no-op changed face count");
    assert(m["vertexCount"].integer == before["vertexCount"].integer, "no-op changed vertex count");
    assert(m["edgeCount"].integer   == before["edgeCount"].integer,   "no-op changed edge count");
}
