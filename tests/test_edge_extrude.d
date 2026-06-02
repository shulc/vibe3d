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
//   - BOUNDARY edges (one neighbor face F) emit a width-only CHAMFER and IGNORE
//     extrude (no ridge, no lift, no bridge, no cap): each endpoint dissolves
//     into a top inset (+width along F's in-plane inward dir) and an anti-normal
//     inset (−width·faceNormal(F)). F keeps the top-inset edge (stays a quad);
//     each other incident face absorbs both insets (quad → 5-gon). The chamfer
//     edge lies on the open boundary. This matches the reference (test 3).
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
// 2. Grid interior edge (3,4): boundary endpoint v3 (on the open grid edge → no
//    cap) and the valence-4 plane center v4 (dissolved into two perpendicular
//    insets + an along-edge inset, closed by two triangle caps). Different
//    valence than the cube, so a different — but still hole-free, orphan-free —
//    topology; counts stay 14v/8f, fv-dist {4:4,5:2,3:2}.
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
// 3. Boundary edge (1 adjacent face) → width-only CHAMFER (reference parity).
//
//    The reference treats a boundary edge entirely differently from an interior
//    one: it IGNORES the extrude amount (no outward lift, no ridge, no bridge)
//    and emits a width-only chamfer. Each endpoint is DISSOLVED into TWO insets:
//      topInset        = endpoint + width · (in-plane inward dir of the sole
//                        neighbour face F, perpendicular to the edge)
//      antiNormalInset = endpoint − width · faceNormal(F)
//    F keeps the topInset edge (stays a quad); every OTHER face incident to the
//    endpoint absorbs BOTH insets in winding order (quad → 5-gon). The chamfer
//    edge topInset–antiNormalInset lies on the OPEN boundary. NO ridge vert, NO
//    lift past the original face plane, NO triangle cap.
//
//    Fixture = the reference parity case: a cube with its +Z front face deleted
//    (so the top-front edge becomes a boundary edge whose sole neighbour is the
//    +Y top face), then that edge extruded. Reference target: 10 verts, 5 faces,
//    fv-dist {4:3, 5:2}.
// ---------------------------------------------------------------------------

unittest {
    resetCube();

    // Delete the +Z front face (addFace index 1 = [4,5,6,7]) → its 4 perimeter
    // edges become boundary edges (one adjacent face).
    postSelect("polygons", [1]);
    postCommand(`{"id":"mesh.delete"}`);

    auto before = getModel();
    assert(before["vertexCount"].integer == 8, "boundary: open cube should keep 8 verts");
    assert(before["faceCount"].integer == 5, "boundary: open cube should have 5 faces");

    immutable V3 vaPos = V3(-0.5, 0.5, 0.5);   // top-front-left  endpoint
    immutable V3 vbPos = V3( 0.5, 0.5, 0.5);   // top-front-right endpoint
    int va = vertAt(before, vaPos);
    int vb = vertAt(before, vbPos);
    assert(va >= 0 && vb >= 0, "boundary: top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "boundary: top-front edge not found");
    // Sole neighbour of this edge is the +Y top face → its normal is +Y.
    immutable V3 faceN = V3(0, 1, 0);
    postSelect("edges", [ei]);

    enum extrude = 0.2, width = 0.1;
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // Exact reference counts: chamfer adds 2 insets per endpoint (4 new) and
    // dissolves both endpoints (2 dropped) ⇒ 8 − 2 + 4 = 10 verts; the face count
    // is unchanged (F stays a quad, two side faces grow to 5-gons) ⇒ 5 faces.
    assert(m["vertexCount"].integer == 10,
        "boundary: expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 5,
        "boundary: expected 5 faces, got " ~ m["faceCount"].integer.to!string);
    auto fv = fvDist(m);
    assert(fv == [4: 3, 5: 2],
        "boundary: expected fv-dist {4:3,5:2}, got " ~ fv.to!string);

    // The chamfer ignores extrude: NO ridge vertex and NO lift past the original
    // top-face plane — nothing rises above y = 0.5.
    foreach (i; 0 .. m["vertices"].array.length)
        assert(vert(m, i).y <= 0.5 + 1e-4,
            "boundary: chamfer must not lift any vertex above y=0.5 (extrude ignored)");

    // NO triangle caps (chamfer emits none).
    assert(fv.get(3, 0) == 0, "boundary: chamfer must emit no triangle caps");

    // Both original endpoints are DISSOLVED (no surviving vertex sits at them).
    assert(vertAt(m, vaPos) < 0, "boundary: endpoint va must be dissolved");
    assert(vertAt(m, vbPos) < 0, "boundary: endpoint vb must be dissolved");

    // Per endpoint: a top inset at +width along the in-plane inward dir of F
    // (perpendicular to the edge; the edge runs along ±X, F extends in −Z from
    // it, so inward = −Z) and an anti-normal inset at −width·faceNormal(F) (−Y).
    immutable V3 inward = V3(0, 0, -1);
    foreach (immutable ep; [vaPos, vbPos]) {
        auto topInset  = add3(ep, V3(inward.x*width, inward.y*width, inward.z*width));
        auto antiInset = sub3(ep, V3(faceN.x*width, faceN.y*width, faceN.z*width));
        assert(countAt(m, topInset) == 1,
            "boundary: top inset missing/duplicated at " ~
            to!string([topInset.x, topInset.y, topInset.z]));
        assert(countAt(m, antiInset) == 1,
            "boundary: anti-normal inset missing/duplicated at " ~
            to!string([antiInset.x, antiInset.y, antiInset.z]));
    }

    // F (the +Y top neighbour) stays a QUAD: exactly the 3 quads are F + the back
    // and bottom faces; the two side faces (+X / −X) are the 5-gons. Verify the
    // quad that contains BOTH top insets (that is F) and that it has 4 corners.
    auto topA = add3(vaPos, V3(inward.x*width, inward.y*width, inward.z*width));
    auto topB = add3(vbPos, V3(inward.x*width, inward.y*width, inward.z*width));
    int fFaces = 0;
    foreach (f; m["faces"].array) {
        bool hasA = false, hasB = false;
        foreach (c; f.array) {
            auto p = vert(m, cast(size_t)c.integer);
            if (len3(sub3(p, topA)) < 1e-4) hasA = true;
            if (len3(sub3(p, topB)) < 1e-4) hasB = true;
        }
        if (hasA && hasB) { ++fFaces; assert(f.array.length == 4,
            "boundary: neighbour face F must stay a quad, got " ~
            f.array.length.to!string ~ "-gon"); }
    }
    assert(fFaces == 1, "boundary: expected exactly one face (F) spanning both top insets");

    // Hole-free / no orphans (open boundary edges allowed).
    assert(orphanVerts(m).length == 0, "boundary: orphan verts: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "boundary: result has a hole / non-manifold edge");
    assert(noCoincidentVerts(m), "boundary: coincident duplicate vertices present");
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
    // v1 and v7 are the two outer free ends, but BOTH sit on the open mesh
    // boundary (top/bottom grid edges): a boundary free end is not ringed by
    // faces, so the reference (and now this kernel) caps it with NO triangle —
    // the ridge bridge already closes the corner against the open boundary.
    // Hence the chain has ZERO triangle caps (was 2 before the boundary-cap
    // rule landed for the coplanar interior free-end fix). No orphans, hole-free.
    assert(orphanVerts(m).length == 0, "chain: orphan verts: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "chain: result not hole-free");
    auto fv = fvDist(m);
    assert(fv.get(3, 0) == 0,
        "chain: expected no triangle caps (outer free ends are on the open " ~
        "boundary), got " ~ fv.get(3, 0).to!string ~ " (fv-dist " ~ fv.to!string ~ ")");

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
// 5. Corner / fan — two BOUNDARY edges sharing a single quad and a vertex.
//
//    f0 = [0,1,4,3]. Edges (0,1) and (0,3) both border f0 (one adjacent face →
//    both boundary) and share v0. A SHARED corner on boundary edges is OUT OF
//    SCOPE for exact reference parity (the in-scope chamfer case is a single
//    boundary edge with free-end corners). This test only pins the best-effort
//    contract: the op must NOT crash and must leave a clean, hole-free, orphan-
//    free, duplicate-free mesh. (Both endpoints' single selected edge is a
//    boundary edge, so extrude is ignored and no ridge lift is produced — the
//    pre-chamfer ridge-vert assertion no longer applies.)
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();
    int e01 = edgeIndex(before, 0, 1);
    int e03 = edgeIndex(before, 0, 3);
    assert(e01 >= 0 && e03 >= 0, "fan edges not found");
    postSelect("edges", [e01, e03]);

    auto raw = postCommandRaw(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    assert(parseJSON(raw)["status"].str == "ok", "fan extrude failed: " ~ raw);
    auto m = getModel();

    // Every face must remain a clean polygon: no repeated corner index, ≥ 3
    // corners.
    foreach (f; m["faces"].array) {
        auto idx = f.array;
        assert(idx.length >= 3, "fan: a face collapsed to < 3 corners");
        foreach (i; 0 .. idx.length)
            foreach (j; i + 1 .. idx.length)
                assert(idx[i].integer != idx[j].integer,
                    "fan: a face has a duplicated corner");
    }

    // Best-effort invariants for the out-of-scope shared boundary corner: the
    // result is hole-free, has no orphan verts, and no coincident duplicates.
    assert(orphanVerts(m).length == 0, "fan: orphan verts: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "fan: result not hole-free");
    assert(noCoincidentVerts(m), "fan: coincident duplicate vertices present");

    // The shared corner v0 is dissolved (replaced by its welded inset), so no
    // surviving vertex sits at the original corner position.
    assert(vertAt(m, vert(before, 0)) < 0,
        "fan: shared corner v0 should be dissolved into its inset, not kept");
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
// 7. No-op: (near-)zero width is a whole-operation no-op, regardless of extrude.
//    width<eps leaves the inset coincident with the original endpoints, so the
//    reference modeler emits no topology change at all. extrude is irrelevant.
// ---------------------------------------------------------------------------

unittest {
    // 7a. width=0 AND extrude=0 — total identity no-op.
    resetGrid(2);
    auto before = getModel();
    int ei = edgeIndex(before, 3, 4);
    postSelect("edges", [ei]);

    postCommandRaw(`{"id":"mesh.edge_extrude","params":{"extrude":0.0,"width":0.0}}`);
    auto m = getModel();
    assert(m["faceCount"].integer   == before["faceCount"].integer,   "no-op changed face count");
    assert(m["vertexCount"].integer == before["vertexCount"].integer, "no-op changed vertex count");
    assert(m["edgeCount"].integer   == before["edgeCount"].integer,   "no-op changed edge count");

    // 7b. width=0 with a NONZERO extrude — STILL a no-op (no shrink room for the
    //     bridge faces ⇒ the reference no-ops; we must not emit degenerate faces).
    resetGrid(2);
    auto before2 = getModel();
    int ei2 = edgeIndex(before2, 3, 4);
    postSelect("edges", [ei2]);

    postCommandRaw(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.0}}`);
    auto m2 = getModel();
    assert(m2["faceCount"].integer   == before2["faceCount"].integer,   "width=0/extrude=0.2 changed face count");
    assert(m2["vertexCount"].integer == before2["vertexCount"].integer, "width=0/extrude=0.2 changed vertex count");
    assert(m2["edgeCount"].integer   == before2["edgeCount"].integer,   "width=0/extrude=0.2 changed edge count");
}

// 7c. extrude=0 with width>0 — pure inset MUST still produce topology change
//     (this is NOT subsumed by the width guard; only width drives the no-op).
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();
    int ei = edgeIndex(before, 3, 4);
    postSelect("edges", [ei]);

    postCommandRaw(`{"id":"mesh.edge_extrude","params":{"extrude":0.0,"width":0.1}}`);
    auto m = getModel();
    bool changed =
        m["faceCount"].integer   != before["faceCount"].integer   ||
        m["vertexCount"].integer != before["vertexCount"].integer ||
        m["edgeCount"].integer   != before["edgeCount"].integer;
    assert(changed, "pure inset (extrude=0, width=0.1) must change topology, not no-op");
}

// ---------------------------------------------------------------------------
// 10. Coplanar interior FREE END (valence>3, planar). Extruding one interior
//     edge of a flat plane such that one endpoint is the valence-4 plane CENTER
//     (ringed by 4 coplanar faces — 2 extruded neighbour faces + 2 back faces)
//     and the other is on the open boundary.
//
//     The center is the case the cube valence-3 path does NOT cover: its two
//     perpendicular insets leave a gap that the back-fan rim edge cuts through.
//     The reference dissolves the center into THREE points — the two
//     perpendicular insets PLUS an along-edge inset at center + width·t̂ (t̂ = unit
//     edge tangent pointing AWAY from the edge into the back fan) — turns each
//     back face into a 5-gon using the along-edge point + one perpendicular
//     inset, and closes the corner with TWO triangles up to the ridge.
//
//     The boundary endpoint sits on the open mesh edge → ringed by no full fan →
//     NO triangle cap (the ridge bridge closes it against the boundary).
//
//     Uses makeGridPlane(2) (the same flat valence-4-center topology as the
//     reference 2×2 plane case, just on the [-1,1] extent): edge (3,4) runs from
//     the boundary mid v3=(-1,0,0) to the center v4=(0,0,0). With t̂ pointing from
//     the center AWAY from v3, i.e. +X, the along-edge inset lands at (0.1,0,0).
// ---------------------------------------------------------------------------

unittest {
    resetGrid(2);
    auto before = getModel();
    assert(before["vertexCount"].integer == 9 && before["faceCount"].integer == 4);

    immutable centerPos   = V3( 0.0, 0.0, 0.0);   // v4 — valence-4 plane center
    immutable boundaryPos = V3(-1.0, 0.0, 0.0);   // v3 — open-boundary endpoint
    int va = vertAt(before, boundaryPos);
    int vb = vertAt(before, centerPos);
    assert(va >= 0 && vb >= 0, "coplanar: endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "coplanar: interior edge (3,4) not found");
    postSelect("edges", [ei]);

    enum extrude = 0.2, width = 0.1;
    postCommand(`{"id":"mesh.edge_extrude","params":{"extrude":0.2,"width":0.1}}`);
    auto m = getModel();

    // Counts mirror the reference 2×2-plane target (14v / 8f): the two extruded
    // neighbour faces (quads) + two back 5-gons + two ridge bridges + two corner
    // triangles at the center; the original center and the boundary mid are both
    // dissolved.
    assert(m["vertexCount"].integer == 14,
        "coplanar: expected 14 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "coplanar: expected 8 faces, got " ~ m["faceCount"].integer.to!string);
    auto fv = fvDist(m);
    assert(fv == [4: 4, 5: 2, 3: 2],
        "coplanar: expected fv-dist {4:4,5:2,3:2}, got " ~ fv.to!string);

    // The valence-4 center vertex is DISSOLVED (no surviving vertex sits at it).
    assert(vertAt(m, centerPos) < 0,
        "coplanar: center vertex (0,0,0) must be dissolved, not kept");

    // The along-edge inset exists at center + width·t̂. The tangent points from
    // the center AWAY from the boundary endpoint v3=(-1,0,0), i.e. +X.
    auto t   = norm3(sub3(centerPos, boundaryPos));        // (+1,0,0)
    auto along = add3(centerPos, V3(t.x*width, t.y*width, t.z*width)); // (0.1,0,0)
    assert(countAt(m, along) == 1,
        "coplanar: along-edge inset at center+width·t̂ missing/duplicated");

    // Both perpendicular center insets exist (±width perpendicular to the edge,
    // in the plane). The edge is along ±X so the perpendiculars are along ±Z.
    assert(countAt(m, V3(0.0, 0.0, -width)) == 1 || countAt(m, V3(0.0, 0.0, width)) == 1,
        "coplanar: perpendicular center insets missing");

    assert(orphanVerts(m).length == 0,
        "coplanar: orphan verts: " ~ orphanVerts(m).to!string);
    assert(isHoleFree(m), "coplanar: result is not hole-free");
    assert(noCoincidentVerts(m), "coplanar: coincident duplicate vertices present");

    // Exactly two triangle caps, BOTH at the interior center end (the boundary
    // end gets none). Each cap's normal runs along the edge axis (the corner
    // faces along ±t̂, not along the extrude direction).
    int tris = 0;
    foreach (fi; 0 .. m["faces"].array.length) {
        auto f = m["faces"].array[fi];
        if (f.array.length != 3) continue;
        ++tris;
        // Every cap must touch the along-edge inset and the center ridge vert.
        bool touchesAlong = false;
        foreach (c; f.array)
            if (len3(sub3(vert(m, cast(size_t)c.integer), along)) < 1e-4) touchesAlong = true;
        assert(touchesAlong,
            "coplanar: triangle cap does not touch the along-edge inset");
    }
    assert(tris == 2, "coplanar: expected exactly 2 triangle caps, got " ~ tris.to!string);
}
