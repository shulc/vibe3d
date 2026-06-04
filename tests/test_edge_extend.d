// Tests for mesh.edge_extend (Edge Extend kernel + command), HTTP-driven.
//
// Topology model (golden-fixture; frozen coordinates, no engine at runtime).
// Edge Extend is ADDITIVE and non-manifold: per selected edge (with ≥1 adjacent
// face) it spawns 2 ridge verts + 1 bridge quad WITHOUT modifying the source
// mesh (the source edge becomes 3-face). Vertices shared by 2+ selected edges
// WELD to ONE new vert (chains / loops / star junctions). Each new vert =
//   (k/segments)·offset + insetShiftDelta(v) + scale(rotate(E_src(v) about origin))
// with rotate then scale about the WORLD ORIGIN, world-frame inset/shift drop
// from the original geometry. `shift` is INERT on interior edges (no-op, not a
// bug). Bridge winding is [srcA, newA, newB, srcB] where srcA→srcB is the source
// edge's directed traversal order within an adjacent face.
//
// The canonical fixture is the CUBE interior top-front edge:
//   va=(-0.5,0.5,0.5), vb=(0.5,0.5,0.5); inset=0.1, shift=0.2 → 10v / 7f, new
//   verts at (±0.4,0.4,0.4), bridge tuple [6,8,9,7] (vibe3d's makeCube indexes
//   corner (0.5,0.5,0.5)=6, (-0.5,0.5,0.5)=7, matching the reference layout).
//
// Golden new-vert numbers (cube interior edge, inset=0.1, shift=0.2):
//   identity                  : (0.4,0.4,0.4)        / (-0.4,0.4,0.4)
//   offset=(0,0.3,0)          : (0.4,0.7,0.4)        / (-0.4,0.7,0.4)
//   rotZ=30                   : (0.083013,0.583013,0.4) / (-0.583013,0.083013,0.4)
//   sclX=2                    : (0.9,0.4,0.4)        / (-0.9,0.4,0.4)
//   offY0.3+rotZ30+sclX2      : (0.266025,0.883013,0.4) / (-1.266025,0.383013,0.4)

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;
import std.algorithm : sort, canFind;

void main() {}

// --- HTTP helpers (same shapes as tests/test_edge_extrude.d) ---------------

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

double dot3(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 add3(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }
V3 sub3(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
double len3(V3 a) { return sqrt(dot3(a, a)); }

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
int vertAt(JSONValue m, V3 p, double tol = 1e-4) {
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) return cast(int)i;
    return -1;
}

// Count vertices coincident with position p (within tol).
int countAt(JSONValue m, V3 p, double tol = 1e-4) {
    int n = 0;
    foreach (i; 0 .. m["vertices"].array.length)
        if (len3(sub3(vert(m, i), p)) < tol) ++n;
    return n;
}

// Map face-vertex-count → frequency.
int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

// Indices not referenced by any face.
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

// The face whose vertex SET equals `want` (order-independent), as a uint[] of its
// directed corner indices; null if none.
uint[] faceByVerts(JSONValue m, int[] want) {
    auto ws = want.dup; ws.sort();
    foreach (f; m["faces"].array) {
        if (f.array.length != want.length) continue;
        int[] fs;
        foreach (c; f.array) fs ~= cast(int)c.integer;
        auto fss = fs.dup; fss.sort();
        if (fss == ws) {
            uint[] dir;
            foreach (c; f.array) dir ~= cast(uint)c.integer;
            return dir;
        }
    }
    return null;
}

// True iff directed `face` matches `tuple` up to a cyclic rotation in the SAME
// orientation (a flipped bridge fails).
bool tupleMatchesWound(uint[] face, uint[] tuple) {
    if (face.length != tuple.length) return false;
    size_t n = face.length;
    foreach (off; 0 .. n) {
        bool ok = true;
        foreach (j; 0 .. n) if (face[(off + j) % n] != tuple[j]) { ok = false; break; }
        if (ok) return true;
    }
    return false;
}

// Select the cube's top-front interior edge (va=(-0.5,.5,.5), vb=(.5,.5,.5)) and
// return (va, vb) vertex indices for downstream tuple resolution.
int[2] selectCubeTopFront(JSONValue before) {
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));
    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "cube top-front edge not found");
    postSelect("edges", [ei]);
    return [va, vb];
}

// ---------------------------------------------------------------------------
// 1. CUBE interior edge — identity (inset=0.1, shift=0.2) → 10v/7f, new verts
//    (±0.4,0.4,0.4), bridge tuple [6,8,9,7] (winding asserted).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8);
    assert(before["faceCount"].integer == 6);

    auto ends = selectCubeTopFront(before);
    int va = ends[0], vb = ends[1];   // vb=(0.5,...)=6, va=(-0.5,...)=7

    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 10,
        "interior: expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "interior: expected 7 faces, got " ~ m["faceCount"].integer.to!string);

    // 8 cube corners unchanged (source mesh never modified).
    foreach (i; 0 .. 8)
        assert(len3(sub3(vert(m, i), vert(before, i))) < 1e-5,
            "interior: cube corner " ~ i.to!string ~ " moved");

    // New ridge verts at (±0.4, 0.4, 0.4).
    int nPos = vertAt(m, V3( 0.4, 0.4, 0.4));
    int nNeg = vertAt(m, V3(-0.4, 0.4, 0.4));
    assert(nPos >= 0, "interior: new vert (0.4,0.4,0.4) missing");
    assert(nNeg >= 0, "interior: new vert (-0.4,0.4,0.4) missing");
    // vb=(0.5,..) → +0.4 ; va=(-0.5,..) → -0.4.
    assert(nPos >= 8 && nNeg >= 8, "interior: new verts must be appended (idx>=8)");

    // Bridge tuple [vb, nVb, nVa, va] wound: srcVb→srcVa directed order within an
    // adjacent face. Reference golden tuple is [6,8,9,7] = [vb, n(vb), n(va), va].
    auto bf = faceByVerts(m, [vb, nPos, nNeg, va]);
    assert(bf !is null, "interior: bridge face {vb,n+,n-,va} not found");
    assert(tupleMatchesWound(bf, [cast(uint)vb, cast(uint)nPos, cast(uint)nNeg, cast(uint)va]),
        "interior: bridge winding [6,8,9,7] wrong, got " ~ bf.to!string);

    // The new ridge edge is selected on exit (mirrors extrude).
    auto sel = getSelection();
    assert(sel["selectedEdges"].array.length >= 1,
        "interior: expected the new ridge edge selected");

    assert(orphanVerts(m).length == 0, "interior: orphan verts");
}

// ---------------------------------------------------------------------------
// 2. Offset (0,0.3,0) → new verts (±0.4, 0.7, 0.4).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2,"offsetY":0.3}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 10);
    assert(vertAt(m, V3( 0.4, 0.7, 0.4)) >= 0, "offset: ( 0.4,0.7,0.4) missing");
    assert(vertAt(m, V3(-0.4, 0.7, 0.4)) >= 0, "offset: (-0.4,0.7,0.4) missing");
}

// ---------------------------------------------------------------------------
// 3. Rotate Z=30° about the WORLD ORIGIN →
//    (0.083013,0.583013,0.4) / (-0.583013,0.083013,0.4).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2,"rotateZ":30.0}}`);
    auto m = getModel();
    assert(vertAt(m, V3( 0.083013,  0.583013, 0.4), 2e-5) >= 0,
        "rotate: ( 0.083013, 0.583013,0.4) missing");
    assert(vertAt(m, V3(-0.583013,  0.083013, 0.4), 2e-5) >= 0,
        "rotate: (-0.583013, 0.083013,0.4) missing");
}

// ---------------------------------------------------------------------------
// 4. Scale X=2 about the WORLD ORIGIN → (±0.9, 0.4, 0.4).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2,"scaleX":2.0}}`);
    auto m = getModel();
    assert(vertAt(m, V3( 0.9, 0.4, 0.4)) >= 0, "scale: ( 0.9,0.4,0.4) missing");
    assert(vertAt(m, V3(-0.9, 0.4, 0.4)) >= 0, "scale: (-0.9,0.4,0.4) missing");
}

// ---------------------------------------------------------------------------
// 5. Combined offY0.3 + rotZ30 + sclX2 (law-ordering: R then S about origin,
//    world inset, Offset last) → (0.266025,0.883013,0.4)/(-1.266025,0.383013,0.4).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":` ~
        `{"inset":0.1,"shift":0.2,"offsetY":0.3,"rotateZ":30.0,"scaleX":2.0}}`);
    auto m = getModel();
    assert(vertAt(m, V3( 0.266025,  0.883013, 0.4), 3e-5) >= 0,
        "combined: ( 0.266025, 0.883013,0.4) missing");
    assert(vertAt(m, V3(-1.266025,  0.383013, 0.4), 3e-5) >= 0,
        "combined: (-1.266025, 0.383013,0.4) missing");
}

// ---------------------------------------------------------------------------
// 6. chain2 weld — top-front + top-right edges share corner (0.5,0.5,0.5).
//    11v/8f; the shared corner welds to ONE new vert at (0.4,0.4,0.4) reused by
//    both bridges.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    // Edge A = top-front: (-0.5,0.5,0.5)-(0.5,0.5,0.5)
    // Edge B = top-right: (0.5,0.5,0.5)-(0.5,0.5,-0.5)
    int c   = vertAt(before, V3( 0.5, 0.5,  0.5));   // shared corner
    int a1  = vertAt(before, V3(-0.5, 0.5,  0.5));
    int b1  = vertAt(before, V3( 0.5, 0.5, -0.5));
    assert(c >= 0 && a1 >= 0 && b1 >= 0, "chain2: endpoints not found");
    int eA = edgeIndex(before, c, a1);
    int eB = edgeIndex(before, c, b1);
    assert(eA >= 0 && eB >= 0, "chain2: edges not found");
    postSelect("edges", [eA, eB]);

    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.0}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 11,
        "chain2: expected 11 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "chain2: expected 8 faces, got " ~ m["faceCount"].integer.to!string);

    // Shared corner welds to ONE new vert at (0.4,0.4,0.4).
    assert(countAt(m, V3(0.4, 0.4, 0.4)) == 1,
        "chain2: welded corner (0.4,0.4,0.4) missing/duplicated");
    int welded = vertAt(m, V3(0.4, 0.4, 0.4));
    // Free ends: a1 → (-0.4,0.4,0.4); b1 → (0.4,0.4,-0.4).
    assert(vertAt(m, V3(-0.4, 0.4,  0.4)) >= 0, "chain2: free end (-0.4,0.4,0.4) missing");
    assert(vertAt(m, V3( 0.4, 0.4, -0.4)) >= 0, "chain2: free end (0.4,0.4,-0.4) missing");

    // Both bridge quads reuse the welded vert.
    int bridgesWithWeld = 0;
    foreach (f; m["faces"].array) {
        if (f.array.length != 4) continue;
        int newCount = 0; bool hasWeld = false;
        foreach (cc; f.array) {
            int vid = cast(int)cc.integer;
            if (vid >= 8) ++newCount;
            if (vid == welded) hasWeld = true;
        }
        if (hasWeld && newCount == 2) ++bridgesWithWeld;
    }
    assert(bridgesWithWeld == 2, "chain2: expected two bridges sharing the welded vert");
    assert(orphanVerts(m).length == 0, "chain2: orphan verts");

    // Exact DIRECTED bridge tuples (winding). vibe3d makeCube: corner=6,
    // a1=(-0.5,0.5,0.5)=7 → free7(-0.4,0.4,0.4); b1=(0.5,0.5,-0.5)=2 →
    // free2(0.4,0.4,-0.4).
    int f7 = vertAt(m, V3(-0.4, 0.4,  0.4));
    int f2 = vertAt(m, V3( 0.4, 0.4, -0.4));
    assert(f7 >= 0 && f2 >= 0, "chain2: free ends not found");
    //   -X edge {corner,a1}: srcA=corner srcB=a1 → [corner, weld, free7, a1]
    //   -Z edge {corner,b1}: srcA=b1 srcB=corner → [b1, free2, weld, corner]
    auto bX = faceByVerts(m, [c, welded, f7, a1]);
    auto bZ = faceByVerts(m, [b1, f2, welded, c]);
    assert(bX !is null &&
           tupleMatchesWound(bX, [cast(uint)c, cast(uint)welded, cast(uint)f7, cast(uint)a1]),
        "chain2: -X bridge winding [corner,weld,free7,a1] wrong, got " ~ bX.to!string);
    assert(bZ !is null &&
           tupleMatchesWound(bZ, [cast(uint)b1, cast(uint)f2, cast(uint)welded, cast(uint)c]),
        "chain2: -Z bridge winding [b1,free2,weld,corner] wrong, got " ~ bZ.to!string);
}

// ---------------------------------------------------------------------------
// 7. star3 — three cube edges meeting at corner (0.5,0.5,0.5). 12v/9f; the corner
//    welds to ONE vert (0.4,0.4,0.4) reused by all three bridges (NOT split/refused).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    int c  = vertAt(before, V3( 0.5,  0.5,  0.5));
    int e1 = vertAt(before, V3(-0.5,  0.5,  0.5));   // -X
    int e2 = vertAt(before, V3( 0.5,  0.5, -0.5));   // -Z
    int e3 = vertAt(before, V3( 0.5, -0.5,  0.5));   // -Y
    assert(c >= 0 && e1 >= 0 && e2 >= 0 && e3 >= 0, "star3: endpoints not found");
    int eA = edgeIndex(before, c, e1);
    int eB = edgeIndex(before, c, e2);
    int eC = edgeIndex(before, c, e3);
    assert(eA >= 0 && eB >= 0 && eC >= 0, "star3: edges not found");
    postSelect("edges", [eA, eB, eC]);

    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.0}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 12,
        "star3: expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 9,
        "star3: expected 9 faces, got " ~ m["faceCount"].integer.to!string);

    // ONE welded corner reused by 3 bridges.
    assert(countAt(m, V3(0.4, 0.4, 0.4)) == 1,
        "star3: welded corner (0.4,0.4,0.4) missing/duplicated");
    int welded = vertAt(m, V3(0.4, 0.4, 0.4));
    int bridgesWithWeld = 0;
    foreach (f; m["faces"].array) {
        if (f.array.length != 4) continue;
        foreach (cc; f.array) if (cast(int)cc.integer == welded) { ++bridgesWithWeld; break; }
    }
    assert(bridgesWithWeld == 3, "star3: expected three bridges reusing the welded corner");
    assert(orphanVerts(m).length == 0, "star3: orphan verts");

    // Exact DIRECTED bridge tuples (winding). The -Y bridge is the one a naive
    // lower-index-by-array rule got backwards; the normal-comparator orienting
    // rule reproduces the reference orientation for all three.
    //   e1=(-0.5,0.5,0.5) → free7(-0.4,0.4,0.4); e2=(0.5,0.5,-0.5) → free2(0.4,0.4,-0.4);
    //   e3=(0.5,-0.5,0.5) → free5(0.4,-0.4,0.4).
    int f7 = vertAt(m, V3(-0.4, 0.4,  0.4));
    int f2 = vertAt(m, V3( 0.4, 0.4, -0.4));
    int f5 = vertAt(m, V3( 0.4, -0.4, 0.4));
    assert(f7 >= 0 && f2 >= 0 && f5 >= 0, "star3: free ends not found");
    //   -X {c,e1}: srcA=c srcB=e1 → [c, weld, free7, e1]
    //   -Z {c,e2}: srcA=e2 srcB=c → [e2, free2, weld, c]
    //   -Y {c,e3}: srcA=c srcB=e3 → [c, weld, free5, e3]
    auto bX = faceByVerts(m, [c, welded, f7, e1]);
    auto bZ = faceByVerts(m, [e2, f2, welded, c]);
    auto bY = faceByVerts(m, [c, welded, f5, e3]);
    assert(bX !is null &&
           tupleMatchesWound(bX, [cast(uint)c, cast(uint)welded, cast(uint)f7, cast(uint)e1]),
        "star3: -X bridge winding [c,weld,free7,e1] wrong, got " ~ bX.to!string);
    assert(bZ !is null &&
           tupleMatchesWound(bZ, [cast(uint)e2, cast(uint)f2, cast(uint)welded, cast(uint)c]),
        "star3: -Z bridge winding [e2,free2,weld,c] wrong, got " ~ bZ.to!string);
    assert(bY !is null &&
           tupleMatchesWound(bY, [cast(uint)c, cast(uint)welded, cast(uint)f5, cast(uint)e3]),
        "star3: -Y bridge winding [c,weld,free5,e3] wrong, got " ~ bY.to!string);
}

// ---------------------------------------------------------------------------
// 8. shift-inert — on an interior edge, shift=0.4 with inset=0 leaves the new
//    verts exactly on the source endpoints (bridge still created). Asserts the
//    shift no-op (do NOT "fix" it).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.0,"shift":0.4}}`);
    auto m = getModel();
    assert(m["faceCount"].integer == 7, "shift-inert: bridge still created");
    // New verts coincide with the source endpoints (shift inert on interior).
    assert(vertAt(m, V3( 0.5, 0.5, 0.5), 1e-5) >= 0 && countAt(m, V3( 0.5, 0.5, 0.5), 1e-5) == 2,
        "shift-inert: new vert must coincide with source endpoint (0.5,0.5,0.5)");
    assert(vertAt(m, V3(-0.5, 0.5, 0.5), 1e-5) >= 0 && countAt(m, V3(-0.5, 0.5, 0.5), 1e-5) == 2,
        "shift-inert: new vert must coincide with source endpoint (-0.5,0.5,0.5)");
}

// ---------------------------------------------------------------------------
// 8b. Boundary edge — delete the cube's +Z front face (polygon index 1) so the
//     top-front edge becomes a boundary edge whose sole adjacent face is the +Y
//     top face. Extend it with inset=0.1, shift=0.2 and assert the single-face
//     law: each new vert = src + (−inset·meet over incident faces) +
//     (shift·in-plane outward perp off the open boundary), with the bridge wound
//     from the sole adjacent face. The shift slides the new verts off the open
//     +Z boundary (z 0.5 → 0.7); inset drops them to the (±0.4,0.4) corner.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    // Delete the +Z front face (addFace index 1 = [4,5,6,7]) → the top-front edge
    // {(-0.5,0.5,0.5),(0.5,0.5,0.5)} becomes a boundary edge; its sole neighbour
    // is the +Y top face.
    postSelect("polygons", [1]);
    postCommand(`{"id":"mesh.delete"}`);

    auto before = getModel();
    assert(before["vertexCount"].integer == 8, "boundary: open cube keeps 8 verts");
    assert(before["faceCount"].integer == 5, "boundary: open cube has 5 faces");

    int vb = vertAt(before, V3( 0.5, 0.5, 0.5));   // top-front-right
    int va = vertAt(before, V3(-0.5, 0.5, 0.5));   // top-front-left
    assert(va >= 0 && vb >= 0, "boundary: top-front endpoints not found");
    int ei = edgeIndex(before, va, vb);
    assert(ei >= 0, "boundary: top-front edge not found");
    postSelect("edges", [ei]);

    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2}}`);
    auto m = getModel();

    // Pure add: 8 + 2 = 10 verts; 5 source + 1 bridge = 6 faces.
    assert(m["vertexCount"].integer == 10,
        "boundary: expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "boundary: expected 6 faces, got " ~ m["faceCount"].integer.to!string);

    // Single-face law: inset drops each endpoint to its (±0.4,0.4) corner; shift
    // slides both off the open +Z boundary by 0.2 (z 0.5 → 0.7). No axial term.
    immutable V3 newVbPos = V3( 0.4, 0.4, 0.7);   // from vb=(0.5,0.5,0.5)
    immutable V3 newVaPos = V3(-0.4, 0.4, 0.7);   // from va=(-0.5,0.5,0.5)
    int nVb = vertAt(m, newVbPos);
    int nVa = vertAt(m, newVaPos);
    assert(nVb >= 0, "boundary: new vert (0.4,0.4,0.7) missing");
    assert(nVa >= 0, "boundary: new vert (-0.4,0.4,0.7) missing");
    assert(nVb >= 8 && nVa >= 8, "boundary: new verts must be appended (idx>=8)");

    // Bridge wound from the sole adjacent (+Y top) face. The top face traverses
    // the edge va→vb, so srcA=va, srcB=vb → bridge [va, nVa, nVb, vb].
    auto bf = faceByVerts(m, [va, nVa, nVb, vb]);
    assert(bf !is null, "boundary: bridge face {va,nVa,nVb,vb} not found");
    assert(tupleMatchesWound(bf, [cast(uint)va, cast(uint)nVa, cast(uint)nVb, cast(uint)vb]),
        "boundary: bridge winding [va,nVa,nVb,vb] (from sole top face) wrong, got " ~ bf.to!string);

    assert(orphanVerts(m).length == 0, "boundary: orphan verts");
}

// ---------------------------------------------------------------------------
// 9. Undo / redo restores counts (cube interior edge).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2}}`);
    auto after = getModel();
    assert(after["vertexCount"].integer == 10);
    assert(after["faceCount"].integer == 7);

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["faceCount"].integer   == before["faceCount"].integer,   "faces not restored on undo");
    assert(m["vertexCount"].integer == before["vertexCount"].integer, "verts not restored on undo");
    assert(m["edgeCount"].integer   == before["edgeCount"].integer,   "edges not restored on undo");
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
        "undo: original 8v/6f cube restored");

    auto r = postRedo();
    assert(r["status"].str == "ok", "redo failed: " ~ r.toString);
    auto m2 = getModel();
    assert(m2["faceCount"].integer   == after["faceCount"].integer,   "faces not redone");
    assert(m2["vertexCount"].integer == after["vertexCount"].integer, "verts not redone");
    assert(m2["vertexCount"].integer == 10 && m2["faceCount"].integer == 7,
        "redo: extended 10v/7f restored");
}

// ---------------------------------------------------------------------------
// 10. No-op — empty edge selection that resolves to no edge with an adjacent
//     face. On the cube, an empty edge selection means "whole mesh" (every edge
//     extended), which is NOT a no-op — so to exercise the true 0-result no-op
//     we select a non-existent / wire-edge situation. The reference rule mirrors
//     extrude: a 0-result is a no-op (command returns status:error, mesh
//     unchanged). We drive it by selecting NOTHING in a NON-edge mode so the
//     command's editMode guard rejects it (editMode != Edges ⇒ false ⇒ no-op).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    // Switch to Vertices mode (key 1) via /api/select mode=vertices select; then
    // the command's `editMode != Edges` guard makes evaluate() return false ⇒
    // dispatcher reports status:error, mesh unchanged. Mirrors extrude's
    // editMode-guard no-op.
    postSelect("vertices", []);
    auto raw = postCommandRaw(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2}}`);
    auto j = parseJSON(raw);
    assert(j["status"].str != "ok", "no-op (non-Edges mode) must not apply: " ~ raw);
    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer, "no-op changed vertex count");
    assert(m["faceCount"].integer   == before["faceCount"].integer,   "no-op changed face count");
    assert(m["edgeCount"].integer   == before["edgeCount"].integer,   "no-op changed edge count");
}

// ---------------------------------------------------------------------------
// 11. SEGMENTS (Phase 3). segs=N stacks N ring levels + N stacked bridge quads
//     per edge. Ring k (k=1..N) = (k/N)·offset + insetShiftDelta(FULL) +
//     Scale_k(Rotate_k(E_src)); Rotate_k=(k/N)·angle, Scale_k=1+(k/N)·(scale−1),
//     inset FULL on every ring. The OUTERMOST ring (k=N) is selected on exit.
// ---------------------------------------------------------------------------

// 11a. segs=3 + offY=0.3 — cube interior edge → 14v/9f, ring Y = 0.4 + k/3·0.3
//      (0.5/0.6/0.7), X/Z held at the full-inset ±0.4/0.4. Asserts counts, all
//      three ring positions, and the FIRST stacked bridge tuple (src→ring1).
unittest {
    resetCube();
    auto before = getModel();
    auto ends = selectCubeTopFront(before);
    int va = ends[0], vb = ends[1];   // vb=(0.5,..)=6, va=(-0.5,..)=7

    postCommand(`{"id":"mesh.edge_extend","params":` ~
        `{"inset":0.1,"shift":0.0,"offsetY":0.3,"segments":3}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 14,
        "seg3 offY: expected 14 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 9,
        "seg3 offY: expected 9 faces, got " ~ m["faceCount"].integer.to!string);

    // Ring positions: +x ring welds vb=6, −x ring welds va=7. Y = 0.4 + k/3·0.3.
    double[3] ringY = [0.5, 0.6, 0.7];
    foreach (k; 0 .. 3) {
        assert(vertAt(m, V3( 0.4, ringY[k], 0.4)) >= 0,
            "seg3 offY: +x ring " ~ k.to!string ~ " (0.4," ~ ringY[k].to!string ~ ",0.4) missing");
        assert(vertAt(m, V3(-0.4, ringY[k], 0.4)) >= 0,
            "seg3 offY: -x ring " ~ k.to!string ~ " (-0.4," ~ ringY[k].to!string ~ ",0.4) missing");
    }

    // FIRST stacked bridge tuple [vb, ring1+x, ring1−x, va] (src→ring1), wound
    // like the N=1 bridge ([6,8,9,7]). ring1 +x = (0.4,0.5,0.4), −x = (-0.4,0.5,0.4).
    int r1p = vertAt(m, V3( 0.4, 0.5, 0.4));
    int r1m = vertAt(m, V3(-0.4, 0.5, 0.4));
    assert(r1p >= 0 && r1m >= 0, "seg3 offY: ring1 verts not found");
    auto b1 = faceByVerts(m, [vb, r1p, r1m, va]);
    assert(b1 !is null, "seg3 offY: first stacked bridge {vb,r1+,r1-,va} not found");
    assert(tupleMatchesWound(b1, [cast(uint)vb, cast(uint)r1p, cast(uint)r1m, cast(uint)va]),
        "seg3 offY: first stacked bridge winding [vb,r1+,r1-,va] wrong, got " ~ b1.to!string);

    // The OUTERMOST ring (Y=0.7) edge is selected on exit. selectedEdges is a
    // list of EDGE INDICES; resolve the index against the model's edge list.
    auto sel = getSelection();
    assert(sel["selectedEdges"].array.length == 1,
        "seg3 offY: exactly the outermost ridge edge selected");
    int selEi = cast(int)sel["selectedEdges"].array[0].integer;
    auto se = m["edges"].array[selEi];
    int sa = cast(int)se.array[0].integer, sbi = cast(int)se.array[1].integer;
    auto pa = vert(m, sa), pb = vert(m, sbi);
    bool outer = (len3(sub3(pa, V3( 0.4, 0.7, 0.4))) < 1e-4 && len3(sub3(pb, V3(-0.4, 0.7, 0.4))) < 1e-4) ||
                 (len3(sub3(pa, V3(-0.4, 0.7, 0.4))) < 1e-4 && len3(sub3(pb, V3( 0.4, 0.7, 0.4))) < 1e-4);
    assert(outer, "seg3 offY: selected edge must be the OUTERMOST ring (Y=0.7)");

    assert(orphanVerts(m).length == 0, "seg3 offY: orphan verts");
}

// 11b. segs=2 + offY=0.3 + rotZ=30 — combined per-ring TRS. 12v/8f. Golden ring
//      positions (verbatim h_seg2_trs equivalent): ring1/ring2 +x and −x.
unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":` ~
        `{"inset":0.1,"shift":0.0,"offsetY":0.3,"rotateZ":30.0,"segments":2}}`);
    auto m = getModel();

    assert(m["vertexCount"].integer == 12,
        "seg2 TRS: expected 12 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "seg2 TRS: expected 8 faces, got " ~ m["faceCount"].integer.to!string);

    // Golden ring verts (h_seg2_trs.json): +x then −x per ring.
    assert(vertAt(m, V3( 0.253553, 0.662372, 0.4), 2e-5) >= 0, "seg2 TRS: ring1 +x missing");
    assert(vertAt(m, V3(-0.512372, 0.403553, 0.4), 2e-5) >= 0, "seg2 TRS: ring1 -x missing");
    assert(vertAt(m, V3( 0.083013, 0.883013, 0.4), 2e-5) >= 0, "seg2 TRS: ring2 +x missing");
    assert(vertAt(m, V3(-0.583013, 0.383013, 0.4), 2e-5) >= 0, "seg2 TRS: ring2 -x missing");

    assert(orphanVerts(m).length == 0, "seg2 TRS: orphan verts");
}

// 11c. Undo / redo round-trip with segs=3 (snapshot path must restore 8v/6f).
unittest {
    resetCube();
    auto before = getModel();
    selectCubeTopFront(before);
    postCommand(`{"id":"mesh.edge_extend","params":{"inset":0.1,"shift":0.2,"segments":3}}`);
    auto after = getModel();
    assert(after["vertexCount"].integer == 14, "seg3 undo: extended to 14v");
    assert(after["faceCount"].integer   == 9,  "seg3 undo: extended to 9f");

    auto u = postUndo();
    assert(u["status"].str == "ok", "seg3 undo failed: " ~ u.toString);
    auto m = getModel();
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
        "seg3 undo: original 8v/6f cube restored");
    assert(m["edgeCount"].integer == before["edgeCount"].integer,
        "seg3 undo: edges restored");

    auto r = postRedo();
    assert(r["status"].str == "ok", "seg3 redo failed: " ~ r.toString);
    auto m2 = getModel();
    assert(m2["vertexCount"].integer == 14 && m2["faceCount"].integer == 9,
        "seg3 redo: extended 14v/9f restored");
}
