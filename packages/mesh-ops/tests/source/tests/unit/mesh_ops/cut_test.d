// Module unittests for `mesh_ops.cut`, moved verbatim out of source/mesh_ops/cut.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.cut_test;

import mesh;
import math;
import std.math : abs;
import mesh_ops.cut;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, MeshOpEntry;
import http_json : meshPlanesJson;   // task 1903 L2: the plane-cut round-trip

// Task 1903 Stage E3: every entry point of this family is a free function over
// `ref MeshEditBatch` now, so a test cannot call one on a bare `Mesh` — that is
// a COMPILE error, and it is the enforcement, not an inconvenience. One helper
// for all five kernels, so there is ONE place that says why the batch is
// `unrecorded`: nothing in these blocks reads an op-log, and track 1 is the
// conversion axis only. The production callers open theirs the same way
// (`commands/mesh/axis_slice.d`, `commands/mesh/screen_slice.d` and the three
// sites in `tools/slice/slice_tool.d` — see mesh_ops/cut.d's header). The
// RECORDING block at the bottom of this file is the one deliberate exception,
// and it is the only block that looks at what the delta says.
//
// `auto ref` is load-bearing: `cutByPlaneEx` takes `out PlaneCutLoops result`
// and `cutByPlaneSplitGap` takes `out bool separated`, so the argument must
// reach the kernel as an lvalue for the `out` to land back on the caller's
// variable.
private size_t cutOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kCutEditScope);
    const n = kernel(ed, args);
    ed.close();
    return n;
}

unittest { // cutByPlane: single quad split at x=0.5 — T-junction (index-share) + attr carry-over
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    // Set non-default material on face 0 and enable subpatch.
    m.surfaces ~= Surface("TestMat", Vec3(1,0,0));
    m.faceMaterial[0] = 1;
    m.setSubpatch(0, true);

    // Cut at x=0.5 (normal along X).
    size_t nSplit = cutOnce!cutByPlane(m, Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

    assert(nSplit == 1, "single quad should produce 1 split");
    assert(m.faces.length == 2, "2 sub-faces after cut");
    // Edge (0,1): d[0]=-0.5, d[1]=0.5 → new vert v4 at (0.5,0,0)
    // Edge (3,2): d[3]=-0.5, d[2]=0.5 → new vert v5 at (0.5,1,0)
    assert(m.vertices.length == 6, "4 original + 2 crossing verts");

    // T-junction check: both sub-faces must share the SAME vertex index at
    // each cut point (same index = same addVertex call, no T-junction).
    uint[] f0 = m.faces[0];
    uint[] f1 = m.faces[1];
    // Find vertex indices at x=0.5 in each face.
    uint[] cuts0, cuts1;
    foreach (vi; f0) if (m.vertices[vi].x > 0.49f && m.vertices[vi].x < 0.51f) cuts0 ~= vi;
    foreach (vi; f1) if (m.vertices[vi].x > 0.49f && m.vertices[vi].x < 0.51f) cuts1 ~= vi;
    assert(cuts0.length == 2, "f0 must have 2 cut verts");
    assert(cuts1.length == 2, "f1 must have 2 cut verts");
    import std.algorithm : canFind;
    foreach (vi; cuts0)
        assert(cuts1.canFind(vi), "cut vert index must be shared between both sub-faces (T-junction check)");

    // Per-face attr carry-over (OBJ2): both sub-faces inherit material 1 and subpatch.
    assert(m.faceMaterial.length >= 2, "faceMaterial must cover both sub-faces");
    assert(m.faceMaterial[0] == 1, "f0 must inherit parent material 1");
    assert(m.faceMaterial[1] == 1, "f1 must inherit parent material 1");
    assert(m.isFaceSubpatch(0), "f0 must inherit subpatch bit");
    assert(m.isFaceSubpatch(1), "f1 must inherit subpatch bit");

    // Topology sanity.
    assert(m.edges.length > 0, "edges must be rebuilt");
    assert(m.loops.length == m.faces[0].length + m.faces[1].length, "loops must match arity sum");
}

unittest { // cutByPlane: adjacent-hit guard — plane at y=0.5 on cube (on-vertex row, no degenerate 2-gons)
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();

    // Plane at y=0.5 snaps top-row verts on-plane; side faces have adjacent hits → no splits.
    size_t nSplit = cutOnce!cutByPlane(m, Vec3(0, 0.5f, 0), Vec3(0, 1, 0));

    assert(nSplit == 0, "plane at top-vertex row must produce 0 splits (adjacent-hit guard)");
    assert(m.faces.length == 6, "face count must stay 6 (cube)");
    assert(m.vertices.length == 8, "vertex count must stay 8 (no new verts)");
    // No 2-vertex faces.
    foreach (fi, face; m.faces)
        assert(face.length >= 3, "no degenerate 2-vertex faces must exist");
}

unittest { // cutByPlane: cube mid-plane cut — correct face/vert counts and 0 orphans
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();

    // Cut at y=0 through the cube middle; 4 side faces straddle, 2 caps don't.
    size_t nSplit = cutOnce!cutByPlane(m, Vec3(0, 0, 0), Vec3(0, 1, 0));

    assert(nSplit == 4, "4 side faces split by mid-plane cut");
    assert(m.faces.length == 10, "6 faces → 4 split (×2) + 2 unchanged = 10");
    assert(m.vertices.length == 12, "8 original + 4 crossing verts = 12");
    // No orphan vertices.
    import std.conv : to;
    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "vertex " ~ i.to!string ~ " is orphaned after cut");
    // No degenerate faces.
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate sub-faces");
}

unittest { // cutByPlaneRestricted (task 0279): cut confined to the selected faces
    import std.math : abs;
    // The Slice tool cuts ONLY the selected polygons. An x=0 plane (normal +X)
    // crosses the cube's 4 X-spanning faces; restricting to the two Z-facing
    // faces (front z=-0.5, back z=+0.5) must split ONLY those two — 12v/8f — with
    // the two unselected crossed neighbours (top/bottom) absorbing their shared
    // crossing vertex as a watertight n-gon. Reference-captured: 12v/8f (task
    // 0279).
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    uint[] restrict;
    foreach (fi; 0 .. m.faces.length) {
        bool allFront = true, allBack = true;
        foreach (vi; m.faces[fi]) {
            if (m.vertices[vi].z > -0.49f) allFront = false;
            if (m.vertices[vi].z <  0.49f) allBack  = false;
        }
        if (allFront || allBack) restrict ~= cast(uint)fi;
    }
    assert(restrict.length == 2, "cube has exactly two Z-facing faces");
    size_t nSplit = cutOnce!cutByPlaneRestricted(m, Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);
    assert(nSplit == 2, "only the 2 selected faces split");
    assert(m.faces.length == 8, "6 → 8 (each selected face → 2; neighbours stay whole)");
    assert(m.vertices.length == 12, "4 crossing verts at the selected faces' spanning edges");
    // Watertight: no orphan verts, no degenerate faces.
    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (r; refd) assert(r, "no orphan vertex after a restricted cut");
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate sub-face");
}

unittest { // cutByPlaneRestricted: 1 selected face → only it splits (10v/7f)
    import std.math : abs;
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    uint[] restrict;
    foreach (fi; 0 .. m.faces.length) {
        bool allFront = true;
        foreach (vi; m.faces[fi]) if (m.vertices[vi].z > -0.49f) allFront = false;
        if (allFront) restrict ~= cast(uint)fi;
    }
    assert(restrict.length == 1, "exactly one front (z=-0.5) face");
    size_t nSplit = cutOnce!cutByPlaneRestricted(m, Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);
    assert(nSplit == 1, "only the front face splits");
    assert(m.faces.length == 7, "6 → 7");
    assert(m.vertices.length == 10, "only 2 crossing verts on the front face's spanning edges");
    // The whole-cut-only crossing verts on the UNSELECTED back face (0, ±0.5, +0.5)
    // must be ABSENT — proof the cut stopped at the selection.
    foreach (v; m.vertices)
        assert(!(abs(v.x) < 1e-4f && abs(v.z - 0.5f) < 1e-4f),
               "no crossing vertex may land on the unselected back face");
}

unittest { // cutByPlaneRestricted: empty/null set == whole cut, byte-for-byte
    auto a = makeCube(); a.buildLoops(); a.resetSelection();
    auto b = makeCube(); b.buildLoops(); b.resetSelection();
    size_t na = cutOnce!cutByPlaneRestricted(a, Vec3(0, 0, 0), Vec3(1, 0, 0), null);
    size_t nb = cutOnce!cutByPlane(b, Vec3(0, 0, 0), Vec3(1, 0, 0));
    assert(na == nb, "empty restrict set cuts identically to the whole cut");
    assert(a.faces.length == b.faces.length && a.faces.length == 10);
    assert(a.vertices.length == b.vertices.length && a.vertices.length == 12);
}

unittest { // cutByPlaneClipped: a full-span segment agrees with cutByPlane (infinite)
    // The cube's cross-section fits within the drawn line (Z from -1 to 1, cube
    // spans ±0.5), so the clip is a no-op — every crossing is in-band and the
    // clipped cut reproduces the whole-belt topology exactly (12v/10f).
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    // Plane x=0 (normal X); segment along Z spanning the cube.
    size_t nSplit = cutOnce!cutByPlaneClipped(m, Vec3(0, 0, 0), Vec3(1, 0, 0),
                                                 Vec3(0, 0, -1), Vec3(0, 0, 1));
    assert(nSplit == 4, "full-span clip == infinite: 4 side faces split");
    assert(m.faces.length == 10, "full-span clip: 6 → 10 faces");
    assert(m.vertices.length == 12, "full-span clip: 8 + 4 crossing verts");
}

unittest { // cutByPlaneClipped: a short segment cuts ONLY the spanned faces
    // Two disjoint co-planar quad strips (left x∈[-3,-1], right x∈[1,3]) in the
    // y=0 plane, each 2 quads. The plane z=0 (normal Z) straddles all 4 quads;
    // the drawn segment [(-4,0,0)→(0,0,0)] spans ONLY the left strip (its x∈
    // [-3,-1] crossings are in-band; the right strip's x∈[1,3] are out-of-band).
    static Mesh twoStrips() {
        Mesh m;
        m.vertices = [
            // left strip: bottom row z=-0.5, top row z=+0.5
            Vec3(-3, 0, -0.5f), Vec3(-2, 0, -0.5f), Vec3(-1, 0, -0.5f),
            Vec3(-3, 0,  0.5f), Vec3(-2, 0,  0.5f), Vec3(-1, 0,  0.5f),
            // right strip
            Vec3( 1, 0, -0.5f), Vec3( 2, 0, -0.5f), Vec3( 3, 0, -0.5f),
            Vec3( 1, 0,  0.5f), Vec3( 2, 0,  0.5f), Vec3( 3, 0,  0.5f),
        ];
        m.addFace([0u, 1u, 4u, 3u]);   m.addFace([1u, 2u, 5u, 4u]);   // left
        m.addFace([6u, 7u, 10u, 9u]);  m.addFace([7u, 8u, 11u, 10u]); // right
        m.buildLoops();
        m.resetSelection();
        return m;
    }

    // infinite plane (cutByPlane) cuts ALL 4 quads: +6 crossing verts, 4 → 8 faces.
    Mesh inf = twoStrips();
    size_t nInf = cutOnce!cutByPlane(inf, Vec3(0, 0, 0), Vec3(0, 0, 1));
    assert(nInf == 4, "infinite: all 4 quads split");
    assert(inf.vertices.length == 18 && inf.faces.length == 8,
           "infinite: 12+6 verts / 4→8 faces");

    // clipped to the left strip: only the 2 left quads split (+3 verts, 4 → 6).
    Mesh clip = twoStrips();
    size_t nClip = cutOnce!cutByPlaneClipped(clip, Vec3(0, 0, 0), Vec3(0, 0, 1),
                                                   Vec3(-4, 0, 0), Vec3(0, 0, 0));
    assert(nClip == 2, "clipped: only the 2 in-band (left) quads split");
    assert(clip.vertices.length == 15, "clipped: 12 + 3 left crossing verts");
    assert(clip.faces.length == 6, "clipped: 2 split (×2) + 2 whole = 6");
    // The right strip is untouched — no crossing vertex at x>0, z≈0.
    foreach (v; clip.vertices)
        assert(!(v.x > 0.5f && v.z > -0.4f && v.z < 0.4f),
               "clipped: right strip must have no z≈0 crossing vertex");
}

unittest { // cutByPlaneClipped: segment terminating INSIDE a face — interior
    // vertex + slit edge to the entry boundary (task 0289, reference-captured).
    //
    // Plane y=0 (normal +Y); drawn segment (-0.9,0,0)→(0,0,0) enters the back
    // (z=-0.5) and front (z=+0.5) faces through their x=-0.5 edge but STOPS at
    // x=0 (interior). The reference (captured single-interior-point case):
    //   • the LEFT face (both crossings in band) splits cleanly along its chord;
    //   • back & front get a KEYHOLE — an interior terminus vertex at the clip
    //     point (0,0,∓0.5), connected by a slit edge back to the entry crossing
    //     (-0.5,0,∓0.5), spliced as [.., B, T, B, ..] in ONE unsplit face.
    // Result: 8+4 verts, 6+1 faces (only the left clean split adds a face).
    import std.math : abs;
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    assert(m.vertices.length == 8 && m.faces.length == 6);

    size_t nSplit = cutOnce!cutByPlaneClipped(m, Vec3(0, 0, 0), Vec3(0, 1, 0),
                                                 Vec3(-0.9f, 0, 0), Vec3(0, 0, 0));
    assert(nSplit >= 1, "the in-band left face must still split cleanly");

    int findVert(float x, float y, float z) {
        foreach (i, v; m.vertices)
            if (abs(v.x - x) < 1e-4f && abs(v.y - y) < 1e-4f && abs(v.z - z) < 1e-4f)
                return cast(int) i;
        return -1;
    }
    int tBack  = findVert(0, 0, -0.5f);   // interior terminus (segment-end clip)
    int tFront = findVert(0, 0,  0.5f);
    int bBack  = findVert(-0.5f, 0, -0.5f); // entry crossing on the x=-0.5 edge
    int bFront = findVert(-0.5f, 0,  0.5f);
    assert(tBack  >= 0 && tFront >= 0, "interior terminus vertices missing");
    assert(bBack  >= 0 && bFront >= 0, "entry boundary crossings missing");

    bool hasEdge(int a, int b) {
        foreach (e; m.edges)
            if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) return true;
        return false;
    }
    assert(hasEdge(tBack, bBack),   "slit edge interior→boundary (back) missing");
    assert(hasEdge(tFront, bFront), "slit edge interior→boundary (front) missing");

    // Keyhole: the terminus is flanked on BOTH sides by its entry crossing in a
    // SINGLE (unsplit) face — never split into two along a degenerate B..B chord.
    bool keyhole(int t, int b) {
        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == t) {
                    uint prev = f[(k + f.length - 1) % f.length];
                    uint next = f[(k + 1) % f.length];
                    if (prev == b && next == b) return true;
                }
        }
        return false;
    }
    assert(keyhole(tBack, bBack),   "back keyhole winding [..,B,T,B,..] missing");
    assert(keyhole(tFront, bFront), "front keyhole winding [..,B,T,B,..] missing");

    assert(m.vertices.length == 12, "8 + 2 entry + 2 terminus verts");
    assert(m.faces.length == 7, "only the left clean split adds a face (6 → 7)");
}

unittest { // cutByPlaneEx: Slice `split` (S7) — the plane-cut loop reuses the
    // Loop Slice lo/hi seam-pair split model. A cube mid-plane cut (x=0) with
    // split OFF is the connected cut (byte-for-byte cutByPlane: closed shell, 0
    // boundary edges, 1 component); with split ON each of the 4 crossing verts is
    // DUPLICATED into a coincident lo/hi pair, so the single loop becomes TWO
    // boundary loops → +4 verts, +4 edges, SAME faces, 8 boundary edges, 2
    // disconnected shells — the identical topological signature as the Loop Slice
    // split guard (see the insertEdgeLoopsMulti Split unittest).
    import std.math : abs;
    static size_t boundaryEdgeCount(ref Mesh m) {
        size_t n = 0;
        foreach (ei; 0 .. m.edges.length) {
            size_t nf = 0;
            foreach (fi; m.facesAroundEdge(cast(uint)ei)) ++nf;
            if (nf == 1) ++n;
        }
        return n;
    }
    static size_t componentCount(ref Mesh m) {
        auto nf = m.faces.length;
        if (nf == 0) return 0;
        auto parent = new size_t[](nf);
        foreach (i; 0 .. nf) parent[i] = i;
        size_t find(size_t x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void uni(size_t a, size_t b) { parent[find(a)] = find(b); }
        uint[][uint] vFaces;
        foreach (fi, f; m.faces) foreach (v; f) vFaces[v] ~= cast(uint)fi;
        foreach (v, fs; vFaces) foreach (k; 1 .. fs.length) uni(fs[0], fs[k]);
        bool[size_t] roots;
        foreach (i; 0 .. nf) roots[find(i)] = true;
        return roots.length;
    }

    // Split OFF — connected cut, closed manifold cube (byte-for-byte cutByPlane).
    Mesh off = makeCube();
    off.buildLoops();
    off.resetSelection();
    PlaneCutLoops offR;
    size_t nOff = cutOnce!cutByPlaneEx(off, Vec3(0, 0, 0), Vec3(1, 0, 0),
                                            /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                                            /*split*/false, /*caps*/false, offR);
    assert(nOff == 4, "split off: 4 side faces split by the mid-plane cut");
    immutable offV = off.vertices.length, offE = off.edges.length, offF = off.faces.length;
    assert(offV == 12 && offF == 10, "split off: 12v/10f connected cut");
    assert(boundaryEdgeCount(off) == 0, "split off: closed cube, no boundary edges");
    assert(componentCount(off) == 1, "split off: one connected shell");
    assert(offR.seamPairs.length == 0, "split off: no seam pairs");
    // The ordered loop is the 4 crossing verts as one closed ring.
    assert(offR.loops.length == 1 && offR.loops[0].length == 4,
           "split off: one 4-vertex crossing ring");

    // Split ON — each crossing vert duplicated → two disconnected boundary loops.
    Mesh on = makeCube();
    on.buildLoops();
    on.resetSelection();
    PlaneCutLoops onR;
    size_t nOn = cutOnce!cutByPlaneEx(on, Vec3(0, 0, 0), Vec3(1, 0, 0),
                                          /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                                          /*split*/true, /*caps*/false, onR);
    assert(nOn == 4, "split on: same 4 side faces split");
    assert(on.vertices.length == offV + 4, "split on: 4 crossing verts duplicated");
    assert(on.edges.length    == offE + 4, "split on: 4 loop edges doubled into boundaries");
    assert(on.faces.length    == offF,     "split on: splitting duplicates verts, not faces");
    assert(boundaryEdgeCount(on) == 8, "split on: two 4-edge boundary loops (8 boundary edges)");
    assert(componentCount(on) == 2, "split on: two disconnected shells");
    // Seam pairs: one coincident [lo,hi] per crossing vert (same shape as Loop Slice).
    assert(onR.seamPairs.length == 4, "split on: 4 seam pairs (one per crossing vert)");
    foreach (pr; onR.seamPairs) {
        assert(pr[0] != pr[1], "seam lo/hi must be distinct verts");
        Vec3 a = on.vertices[pr[0]], b = on.vertices[pr[1]];
        assert(abs(a.x - b.x) < 1e-6f && abs(a.y - b.y) < 1e-6f && abs(a.z - b.z) < 1e-6f,
               "seam lo/hi coincide (zero gap — Gap/S9 moves them apart later)");
    }
    // No orphan vertices after the split.
    import std.conv : to;
    bool[] refd = new bool[](on.vertices.length);
    foreach (face; on.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "split on: vertex " ~ i.to!string ~ " orphaned");

    // Split ON + Cap Sections ON (S8, task 0274) — each of the two boundary loops
    // is sealed by ONE cap polygon (the shared capShellCycles geometry, same as
    // Loop Slice Cap Sections). +2 faces, NO new verts, NO new edges (each cap
    // edge reuses an existing shell boundary edge); both loops close (0 boundary
    // edges) yet the two shells stay DISCONNECTED (each cap seals its own shell).
    Mesh cap = makeCube();
    cap.buildLoops();
    cap.resetSelection();
    PlaneCutLoops capR;
    size_t nCap = cutOnce!cutByPlaneEx(cap, Vec3(0, 0, 0), Vec3(1, 0, 0),
                                            /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                                            /*split*/true, /*caps*/true, capR);
    assert(nCap == 4, "split+caps: same 4 side faces split");
    assert(cap.vertices.length == on.vertices.length, "caps add no verts");
    assert(cap.edges.length    == on.edges.length,    "caps add no edges (reuse boundary edges)");
    assert(cap.faces.length    == on.faces.length + 2, "caps add exactly 2 faces (one per shell)");
    assert(boundaryEdgeCount(cap) == 0, "split+caps: both boundary loops sealed");
    assert(componentCount(cap) == 2, "split+caps: two shells stay disconnected");
    assert(capR.seamPairs.length == 4, "split+caps: still 4 seam pairs for Gap (S9)");
}

unittest { // cutByPlaneEx: Slice `gap` + `gapSide` (S9, task 0275) — the two
    // split shells separate ALONG THE PLANE NORMAL by exactly `gap`, offset per
    // gapSide. Mid-plane cut of a cube with n = +X through X=0: lo (originals) is
    // the +n (x>0) shell, hi (dups) the −n (x<0) shell.
    import std.math : abs;
    enum float G = 0.4f;
    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);

    // gap=0 baseline: 4 coincident pairs (byte-for-byte S7/S8) — proven above.

    // center (0): symmetric — lo at x=+G/2, hi at x=−G/2, separation = G.
    Mesh c = makeCube(); c.buildLoops(); c.resetSelection();
    PlaneCutLoops cR;
    cutOnce!cutByPlaneEx(c, P, N, false, P, P, /*split*/true, /*caps*/true, cR,
                            1e-5f, null, /*gap*/G, /*gapSide*/0);
    assert(cR.seamPairs.length == 4);
    foreach (pr; cR.seamPairs) {
        Vec3 lo = c.vertices[pr[0]], hi = c.vertices[pr[1]];
        assert(abs(lo.x - (+G * 0.5f)) < 1e-6f, "center: lo shell at +gap/2");
        assert(abs(hi.x - (-G * 0.5f)) < 1e-6f, "center: hi shell at −gap/2");
        assert(abs((lo.x - hi.x) - G) < 1e-6f, "center: shells separated by exactly gap");
        assert(abs(lo.y - hi.y) < 1e-6f && abs(lo.z - hi.z) < 1e-6f,
               "gap displaces ONLY along the plane normal");
    }

    // positive (1): +n shell (lo) takes the full gap along +n; hi stays on plane.
    Mesh pMesh = makeCube(); pMesh.buildLoops(); pMesh.resetSelection();
    PlaneCutLoops pR;
    cutOnce!cutByPlaneEx(pMesh, P, N, false, P, P, true, true, pR, 1e-5f, null, G, 1);
    foreach (pr; pR.seamPairs) {
        assert(abs(pMesh.vertices[pr[0]].x - G)    < 1e-6f, "positive: lo at +gap");
        assert(abs(pMesh.vertices[pr[1]].x - 0.0f) < 1e-6f, "positive: hi stays on plane");
    }

    // negative (2): −n shell (hi) takes the full gap along −n; lo stays on plane.
    Mesh nMesh = makeCube(); nMesh.buildLoops(); nMesh.resetSelection();
    PlaneCutLoops nR;
    cutOnce!cutByPlaneEx(nMesh, P, N, false, P, P, true, true, nR, 1e-5f, null, G, 2);
    foreach (pr; nR.seamPairs) {
        assert(abs(nMesh.vertices[pr[0]].x - 0.0f) < 1e-6f, "negative: lo stays on plane");
        assert(abs(nMesh.vertices[pr[1]].x - (-G)) < 1e-6f, "negative: hi at −gap");
    }
}

unittest { // cutByPlaneEx: Slice `gap` on a SHEARED cube — split edges stay
    // COLLINEAR (task 0290). On an OBLIQUE cut the crossed edge is NOT parallel to
    // the plane normal, so pushing the [lo,hi] pair along the normal would BEND the
    // split edge (the pre-0290 bug). The reference separates each pair ALONG THE
    // ORIGINAL EDGE, so both halves stay on the edge's line. Assert exactly that:
    // every seam pair is collinear with one original crossed edge, separated by the
    // gap measured along the edge.
    //
    // NOTE (task 0291, DQ5 — KEEP option): this direct `cutByPlaneEx` call still
    // produces the pre-0291 along-edge SLIDE — that is CORRECT here, because the
    // UNRESTRICTED Slice split+caps+gap tool path no longer reaches this code at
    // all (it routes through `cutByPlaneSplitGap`'s two REAL parallel cuts, whose
    // seam sits at edge∩offset-plane instead). The slide survives only for (a)
    // the restricted split-gap branch, (b) the partial-cut fallback in
    // `slice_tool.sliceSplitGap`, and (c) this direct kernel call — same input,
    // two valid answers depending on the code path that reaches it.
    import std.math : abs, sqrt;
    // Sheared cube: top face displaced +X (repro from the task file).
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,     -0.5f, -0.5f), Vec3( 0.5f,     -0.5f, -0.5f),
        Vec3( 1.146581f,  0.5f, -0.5f), Vec3( 0.146581f, 0.5f, -0.5f),
        Vec3(-0.5f,     -0.5f,  0.5f), Vec3( 0.5f,     -0.5f,  0.5f),
        Vec3( 1.146581f,  0.5f,  0.5f), Vec3( 0.146581f, 0.5f,  0.5f),
    ];
    m.addFace([0u,3u,2u,1u]); m.addFace([4u,5u,6u,7u]);
    m.addFace([0u,4u,7u,3u]); m.addFace([1u,2u,6u,5u]);
    m.addFace([3u,7u,6u,2u]); m.addFace([0u,1u,5u,4u]);
    m.buildLoops(); m.resetSelection();

    // Slice line in xy extruded along Z (axis=z): n = normalize(cross(end-start, +Z)).
    Vec3 s = Vec3(-0.285f, -0.168f, 0.0f), e = Vec3(0.969f, 0.225f, 0.0f);
    Vec3 N = normalize(cross(e - s, Vec3(0, 0, 1)));  // ≈ (0.2991, -0.9542, 0)
    Vec3 P = s;
    enum float G = 0.175f;

    // Original crossed edges (top/bottom face edges the vertical plane cuts).
    static immutable uint[2][4] crossed = [[0,3],[1,2],[5,6],[4,7]];

    PlaneCutLoops R;
    // infinite (clipped=false) so the whole cross-section is cut (owner's 16v result).
    size_t nS = cutOnce!cutByPlaneEx(m, P, N, /*clipped*/false, P, P,
                                        /*split*/true, /*caps*/true, R, 1e-5f, null,
                                        /*gap*/G, /*gapSide*/0);
    assert(nS > 0, "sheared cube: the oblique plane must cut faces");
    assert(R.seamPairs.length == 4, "sheared cube: 4 crossing verts duplicated");

    foreach (pr; R.seamPairs) {
        Vec3 lo = m.vertices[pr[0]], hi = m.vertices[pr[1]];
        // Find the original edge this pair sits on (the one both endpoints are
        // collinear with) and assert perpendicular offset ≈ 0 for BOTH.
        bool matched = false;
        foreach (ce; crossed) {
            Vec3 A = m.vertices[ce[0]], B = m.vertices[ce[1]];
            Vec3 dir = B - A;
            float len = dir.length;
            float perpLo = cross(lo - A, dir).length / len;
            float perpHi = cross(hi - A, dir).length / len;
            if (perpLo < 1e-4f && perpHi < 1e-4f) {
                matched = true;
                // Separation measured along the edge == gap (both halves on the line).
                float sep = sqrt((lo.x-hi.x)*(lo.x-hi.x) + (lo.y-hi.y)*(lo.y-hi.y)
                               + (lo.z-hi.z)*(lo.z-hi.z));
                assert(abs(sep - G) < 1e-4f,
                       "sheared: split-edge pair separated by exactly gap along the edge");
                break;
            }
        }
        assert(matched, "sheared: both halves of every split edge stay COLLINEAR "
                        ~ "with the original edge (not bent along the plane normal)");
    }
}

unittest { // cutByPlane: selected parent → BOTH split halves stay selected
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    m.selectFace(0);

    size_t nSplit = cutOnce!cutByPlane(m, Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

    assert(nSplit == 1, "single quad should produce 1 split");
    assert(m.faces.length == 2, "2 sub-faces after cut");
    assert(m.isFaceSelected(0) && m.isFaceSelected(1),
           "both halves of a selected parent must stay selected");
}

unittest { // cutByPlane: unselected parent → BOTH split halves stay unselected (control)
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    // Deliberately no selectFace() call.

    size_t nSplit = cutOnce!cutByPlane(m, Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

    assert(nSplit == 1, "single quad should produce 1 split");
    assert(m.faces.length == 2, "2 sub-faces after cut");
    assert(!m.isFaceSelected(0) && !m.isFaceSelected(1),
           "an unselected parent's split halves must stay unselected");
}

unittest { // cutByPlaneRestricted: only the selected+masked parents' halves stay selected
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    uint[] restrict;
    foreach (fi; 0 .. m.faces.length) {
        bool allFront = true, allBack = true;
        foreach (vi; m.faces[fi]) {
            if (m.vertices[vi].z > -0.49f) allFront = false;
            if (m.vertices[vi].z <  0.49f) allBack  = false;
        }
        if (allFront || allBack) {
            restrict ~= cast(uint)fi;
            m.selectFace(cast(int)fi); // select both Z-facing faces before the cut
        }
    }
    assert(restrict.length == 2, "cube has exactly two Z-facing faces");

    size_t nSplit = cutOnce!cutByPlaneRestricted(m, Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);

    assert(nSplit == 2, "only the 2 selected faces split");
    assert(m.faces.length == 8, "6 → 8 (each selected face → 2; neighbours stay whole)");

    import std.math : abs;
    int nSel = 0;
    foreach (fi; 0 .. m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        nSel++;
        // A selected split half is one of the front/back halves: every vertex
        // shares the SAME z (±0.5) — the top/bottom n-gons that merely
        // absorbed a shared crossing vertex are copied whole and unselected.
        float z0 = m.vertices[m.faces[fi][0]].z;
        foreach (vi; m.faces[fi])
            assert(abs(m.vertices[vi].z - z0) < 1e-4f,
                   "a selected face after a restricted cut must be a front/back half");
    }
    assert(nSel == 4, "exactly 4 selected faces: both halves of each of the 2 selected parents");
}

unittest { // cutByPlane: nothing selected before ⇒ nothing selected after (nothing-in ⇒ nothing-out)
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();

    size_t nSplit = cutOnce!cutByPlane(m, Vec3(0, 0, 0), Vec3(0, 1, 0));

    assert(nSplit == 4, "4 side faces split by mid-plane cut");
    assert(m.faces.length == 10, "6 faces → 4 split (×2) + 2 unchanged = 10");
    assert(m.countSelectedFaces() == 0,
           "nothing selected before the cut ⇒ nothing selected after");
}

// ===========================================================================
// THE DEFERRAL CELL (task 1903 Stage E3, added in the E3 review round).
//
// WHAT THE SUITE CANNOT SEE, AND WHY THIS IS HERE. `tests/test_axis_slice.d`
// asserts that a 4-cut ladder makes ZERO unbatched geometry commits. That cell
// is a SCALE check — the zero has to survive the ladder growing — and it does
// NOT separate "one batch spanning the ladder" from "one batch opened per
// cut". MEASURED in the E3 review: moving the batch INSIDE
// `foreach (k; 0 .. count_)` in `commands/mesh/axis_slice.d` leaves every
// counter at `/api/changes` byte-identical, because
// `unbatchedGeometryCommits` ticks only OUTSIDE any batch (a per-cut batch
// reads 0 exactly like a per-ladder one) and change-bus delivery coalesces per
// frame either way. The observable that DOES separate them is
// `mutationVersion`, and that is not on the wire at all — so the discriminating
// cell has to live in the unit lane, here.
//
// The block is a DIFFERENTIAL and not a single number for the second reason
// too: deferring N commits into one is only legal if nothing in these kernels
// reads back a version, a derived plane or a rebuilt loop table BETWEEN cuts.
// The full-state compare below is what says so, and the E3 review measured the
// same equality over 24 cells (8 stands x 3 axes) outside the gate.
//
// The one mechanism that COULD have made deferral observable — a per-element
// derive (Hide, Select) that a later cut then reads back — is closed by
// construction rather than by this test: `source/mesh_ops/cut.d` reads no
// derived Hide or Select bit at all (grep for `isFaceHidden` / `isFaceSelected`
// and their vertex/edge twins across the file: ZERO hits), so a derive deferred
// to `close()` has nothing in this family to feed back into.
// ===========================================================================

/// Every plane the plane cut can touch, one line each, for a bit-exact compare.
///
/// Coordinates go out as `%a` — the exact hex form. `%g` would round two
/// genuinely different floats onto one string, and it prints `-0.0` and `0.0`
/// alike; this family has zero-amplitude arithmetic in its Gap arm
/// (`v + dir*0` flips `-0.0`), which is exactly the difference a lossy compare
/// hides. The half-edge tables are included deliberately: they are DERIVED, so
/// they are where a deferred `buildLoops()` would show up if deferral changed
/// anything.
private string[] cutStateLines(ref Mesh m) {
    import std.format    : format;
    import std.algorithm : sort;
    string[] a;
    a ~= format("counts V=%d F=%d E=%d", m.vertices.length, m.faces.length, m.edges.length);
    foreach (i, v; m.vertices) a ~= format("V[%d]=%a,%a,%a", i, v.x, v.y, v.z);
    foreach (fi; 0 .. m.faces.length) a ~= format("F[%d]=%(%d,%)", fi, m.faces[fi]);
    foreach (ei; 0 .. m.edges.length) a ~= format("E[%d]=%d,%d", ei, m.edges[ei][0], m.edges[ei][1]);
    a ~= format("loops=%d faceLoop=%d vertLoop=%d loopEdge=%d",
                m.loops.length, m.faceLoop.length, m.vertLoop.length, m.loopEdge.length);
    foreach (i, L; m.loops)    a ~= format("L[%d]=v%d,f%d,n%d,p%d,t%d", i, L.vert, L.face, L.next, L.prev, L.twin);
    foreach (i, w; m.faceLoop) a ~= format("fL[%d]=%d", i, w);
    foreach (i, w; m.vertLoop) a ~= format("vL[%d]=%d", i, w);
    foreach (i, w; m.loopEdge) a ~= format("lE[%d]=%d", i, w);
    foreach (i, w; m.vertexMarks) a ~= format("vM[%d]=%d", i, w);
    foreach (i, w; m.edgeMarks)   a ~= format("eM[%d]=%d", i, w);
    foreach (i, w; m.faceMarks)   a ~= format("fM[%d]=%d", i, w);
    foreach (i, w; m.vertexSelectionOrder) a ~= format("vSO[%d]=%d", i, w);
    foreach (i, w; m.edgeSelectionOrder)   a ~= format("eSO[%d]=%d", i, w);
    foreach (i, w; m.faceSelectionOrder)   a ~= format("fSO[%d]=%d", i, w);
    a ~= format("selOrdCounters=%d,%d,%d", m.vertexSelectionOrderCounter,
                m.edgeSelectionOrderCounter, m.faceSelectionOrderCounter);
    foreach (i, w; m.faceMaterial)  a ~= format("fMat[%d]=%d", i, w);
    foreach (i, w; m.facePart)      a ~= format("fPart[%d]=%d", i, w);
    foreach (i, w; m.faceSetMask)   a ~= format("fSet[%d]=%d", i, w);
    foreach (i, w; m.vertexSetMask) a ~= format("vSet[%d]=%d", i, w);
    ulong[] eks;                                   // the edge set mask is an AA
    foreach (k, v; m.edgeSetMask) eks ~= k;
    eks.sort();
    foreach (k; eks) a ~= format("eSet[%d]=%d", k, m.edgeSetMask[k]);
    return a;
}

unittest { // ONE batch over a ladder DEFERS what a batch-per-cut stamps, and lands on the same mesh
    import std.format : format;

    // `recCutStand` (declared below, with the RECORDING block it was written
    // for): a grid with every mark plane non-empty. Load-bearing here too —
    // the state compare's Marks half is zero-against-zero on a clean stand.
    immutable float[4] offs = [-0.37f, -0.11f, 0.13f, 0.41f];
    immutable Vec3 n = Vec3(1, 0, 0);

    // (a) A BATCH PER CUT — what `commands/mesh/axis_slice.d` would do with its
    // `MeshEditBatch` moved inside the ladder loop. This arm IS the mutation
    // the suite cell cannot see; keeping it in the test is what makes the
    // comparison below a differential rather than a pinned constant.
    Mesh perCut = recCutStand();
    immutable ulong basePerCut = perCut.mutationVersion;
    string retPerCut;
    foreach (k; 0 .. 4) {
        auto ed = MeshEditBatch.unrecorded(perCut, kCutEditScope);
        retPerCut ~= format("%d;", ed.cutByPlane(n * offs[k], n));
        ed.close();
    }
    immutable ulong dPerCut = perCut.mutationVersion - basePerCut;

    // (b) ONE batch spanning the whole ladder — what it does today.
    Mesh ladder = recCutStand();
    immutable ulong baseLadder = ladder.mutationVersion;
    string retLadder;
    {
        auto ed = MeshEditBatch.unrecorded(ladder, kCutEditScope);
        foreach (k; 0 .. 4) retLadder ~= format("%d;", ed.cutByPlane(n * offs[k], n));
        ed.close();
    }
    immutable ulong dLadder = ladder.mutationVersion - baseLadder;

    // ANTI-VACUITY, and it is not decoration: `cutByPlane` returns 0 the moment
    // a plane misses, two refusals produce two identical untouched meshes, and
    // every assertion below would then hold for free.
    assert(retPerCut == "3;3;3;3;" && retLadder == "3;3;3;3;",
        format("the ladder split %s (per-cut) / %s (one batch), expected "
             ~ "3;3;3;3; each — the four planes at x = -0.37/-0.11/0.13/0.41 "
             ~ "each cross one column of the [-1,1] grid. On a refusal both "
             ~ "meshes stay untouched and every assertion below is vacuous.",
               retPerCut, retLadder));
    assert(ladder.vertices.length == 32 && ladder.faces.length == 21,
        format("the ladder left V=%d F=%d, expected V=32 F=21 (16 + 4x4 verts, "
             ~ "9 + 4x3 faces)", ladder.vertices.length, ladder.faces.length));

    // THE DISCRIMINATOR. Both arms make the same commits; the batch decides how
    // many of them reach `mutationVersion`. Measured on this stand: ONE batch
    // stamps +1, four batches stamp +4. Asserted as a RELATION, not as the pair
    // — the numbers are what a coalescing rule chose, the relation is the law
    // ("a batch that spans the ladder stamps fewer times than one per cut"),
    // and it is the relation that reddens when the batch moves inside the loop:
    // both arms then read +4 and `<` fails.
    assert(dLadder < dPerCut,
        format("the ladder-wide batch bumped mutationVersion by %d and the "
             ~ "batch-per-cut ladder by %d, expected strictly fewer (measured "
             ~ "at Stage E3: +1 against +4). Equal deltas mean the batch is no "
             ~ "longer deferring — either a caller opens one per cut, or "
             ~ "`MeshEditBatch` stopped coalescing its commits into `close()`. "
             ~ "This is the ONLY cell in the tree that separates those two "
             ~ "worlds: every counter at /api/changes reads identically under "
             ~ "both (task 1903 Stage E3, plan section 3.2 L2).",
               dLadder, dPerCut));
    assert(dLadder > 0,
        format("the ladder-wide batch bumped mutationVersion by %d — a cut that "
             ~ "stamps NOTHING is a missing publisher, not a better batch "
             ~ "(changeBus.missedPublishers is the suite-side twin)", dLadder));

    // DEFERRAL EQUIVALENCE. Deferring the commits must not change one bit of
    // the result: same coordinates, same windings, same edge order, same marks,
    // same derived half-edge tables.
    auto sPerCut = cutStateLines(perCut), sLadder = cutStateLines(ladder);
    size_t nDiff; string firstDiff;
    foreach (i; 0 .. (sPerCut.length < sLadder.length ? sPerCut.length : sLadder.length))
        if (sPerCut[i] != sLadder[i]) {
            if (nDiff == 0)
                firstDiff = format("line %d: per-cut `%s` vs one-batch `%s`",
                                   i, sPerCut[i], sLadder[i]);
            ++nDiff;
        }
    assert(sPerCut.length == sLadder.length && nDiff == 0,
        format("batching the ladder CHANGED the mesh: %d of %d/%d state lines "
             ~ "differ. %s. Deferring N commits into one is only legal because "
             ~ "nothing in these kernels reads back a version or a derived "
             ~ "plane between cuts; a difference here means something does "
             ~ "(task 1903 Stage E3).",
               nDiff, sPerCut.length, sLadder.length,
               firstDiff.length ? firstDiff : "lengths differ"));
    assert(sLadder.length > 600,
        format("the state compare walked only %d lines — on this stand it is "
             ~ "634, and a comparison of two empty dumps is two zeros "
             ~ "(the equality above would hold for free)", sLadder.length));
}

// ===========================================================================
// THE RECORDING BLOCK (task 1903 Stage E3).
//
// Every block above opens an UNRECORDED batch, which is what track 1 is about:
// the conversion axis, not the undo axis. This one opens the RECORDING
// constructor, because it is the only thing in the tree that looks at what this
// family's op-log actually SAYS — and on this family that turns out to be the
// stage's sharpest finding, invisible to every behavioural test there is.
// ===========================================================================

/// The op-log's KIND SEQUENCE, as text — never the LENGTH (task 1903 §L2.7's
/// W-2-SHAPE: a length is satisfied by a log with an entry interposed).
private string kindsOf(in MeshEditDelta d) {
    import std.conv : to;
    string r;
    foreach (i, ref e; d.log) r ~= (i ? " " : "") ~ e.kind.to!string;
    return r;
}

private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
    size_t n;
    foreach (ref e; d.log) if (e.kind == k) ++n;
    return n;
}

/// The scope this family declares, written out from the enum INDEPENDENTLY of
/// `kCutEditScope`.
///
/// `d.scope_` IS `kCutEditScope` fed through `MeshEditTracker.declare`, so
/// `d.scope_ == kCutEditScope` is the measurement judging itself: set the
/// constant to 0 and that equality stays true. Measured at Stage D2 on the
/// reduce family, where exactly that draft stayed green under
/// `enum uint kReduceEditScope = 0;`. So the expectation here is written from
/// what the kernels DO — they splice crossing vertices in (Points), rewrite the
/// whole face array and delete the band component (Polygons), carry the mark
/// words onto both halves and resize every plane (Marks), and the Gap option
/// MOVES existing seam vertices (Position) — and the equality against the
/// constant is asserted separately, AFTER it, where it can only see a broken
/// `declare`/`close` path.
private enum uint kExpectedCutScope = MeshEditScope.Position
                                    | MeshEditScope.Points
                                    | MeshEditScope.Polygons
                                    | MeshEditScope.Marks;

private void assertDeclaredScope(string what, ref MeshEditDelta d) {
    import std.format : format;
    assert(cast(uint)d.scope_ == kExpectedCutScope,
        format("%s: a recording plane cut declared scope 0x%x, expected 0x%x "
             ~ "(Position|Points|Polygons|Marks). Missing: 0x%x. Unexpected: "
             ~ "0x%x. `MeshEditDelta.finalize` reads scope_ back on a revert to "
             ~ "decide what to bump and rebuild, so a wrong constant is a wrong "
             ~ "invalidation, not a cosmetic mismatch (task 1903 Stage E3)",
               what, cast(uint)d.scope_, kExpectedCutScope,
               kExpectedCutScope & ~cast(uint)d.scope_,
               cast(uint)d.scope_ & ~kExpectedCutScope));
    assert(cast(uint)d.scope_ == kCutEditScope,
        format("%s: the delta's scope_ (0x%x) is not the kCutEditScope the "
             ~ "batch was opened with (0x%x) — the declared scope is not "
             ~ "reaching MeshEditDelta.scope_ at all",
               what, cast(uint)d.scope_, kCutEditScope));
}

/// A stand with every plane the cut touches non-empty and non-uniform, and it
/// SELECTS — which is load-bearing, not decoration. The delta declares
/// `MeshEditScope.Marks`; on a stand where every mark plane is empty or zero,
/// "the marks were carried" and "there were no marks" are the same measurement
/// (Stage E2 review, BLOCKER B1, on exactly this shape). A GRID, not a cube:
/// the cut must leave faces it never touches, so a carried plane on a SURVIVING
/// face is something the assertions below can actually be wrong about.
private Mesh recCutStand() {
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) m.faceMaterial[fi] = cast(uint)(fi % 2);
    m.setSubpatch(1, true);
    m.buildLoops();
    // `syncSelection` SIZES the mark planes — they are lazily grown and stay
    // `[]` until something asks for them, so without it `selectFace` has
    // nothing to write into.
    m.syncSelection();
    m.selectFace(4);
    m.selectVertex(1);
    m.faceSelectionOrder[2] = 11;
    return m;
}

unittest { // the plane-cut op-log NAMES ITS FACE CHANGE, and its revert WORKS
    import std.format : format;
    import std.conv   : to;

    Mesh m = recCutStand();
    // STAND CANARY. Asserts the stand, not the code under test, so it can only
    // fire when `recCutStand` is edited: with nothing selected and every mark
    // word zero, the "declared Marks, recorded none" law below would be zero
    // compared with zero.
    assert(m.isFaceSelected(4) && m.isVertexSelected(1) && m.isFaceSubpatch(1)
           && m.faceSelectionOrder[2] == 11,
        "recCutStand selected/tagged nothing — the Marks half of the law below "
      ~ "would be vacuous (task 1903 Stage E3, and Stage E2 review BLOCKER B1 "
      ~ "for the shape)");
    immutable size_t preV = m.vertices.length, preF = m.faces.length;

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kCutEditScope);   // RECORDING
        n = ed.cutByPlane(Vec3(0.13f, 0, 0), Vec3(1, 0, 0));
        d = ed.close();
    }

    // Anti-vacuity: this kernel returns 0 the moment the plane misses, and a
    // 0-return satisfies every assertion below for free.
    assert(n == 3 && m.vertices.length == preV + 4 && m.faces.length == preF + 3,
        format("the stand split %d face(s) (V %d -> %d, F %d -> %d), expected 3 "
             ~ "(V +4, F +3) — every assertion below would be vacuous on a "
             ~ "refusal", n, preV, m.vertices.length, preF, m.faces.length));

    assertDeclaredScope("cutByPlane", d);

    // THE FINDING, MEASURED — and stage L2 turned it over.
    //
    // WHAT IT SAID AT STAGE E3 (2026-08-25). Three faces became six, nine face
    // slots became twelve, and the op-log was ONE entry, `[AddVerts]`:
    // `Mesh.rebuildFacesWithChordSplits` built a whole new face array and
    // installed it with `faces._store = newFacesArr;`, a DIRECT store reaching
    // no mutation hook, and `Mesh.insertEdgePoint` spliced the crossing corner
    // into every incident winding with a raw `face = face[0 .. k+1] ~ …`. So
    // the delta named the four crossing vertices and NOTHING about the faces,
    // and `revert()` un-added those vertices while twelve rebuilt faces still
    // referenced them: `ArrayIndexError: index [16] is out of bounds for array
    // of length 16` out of `finalize`→`buildLoops`, leaving the mesh HALF
    // REVERTED at V=16 with F=12.
    //
    // WHAT CHANGED (2026-08-28, task 1903 Stage L2-c and L2-d), and the block's
    // own instruction was to become this comparison once it did. BOTH of those
    // sites got a publisher, and both landed in stage L2 rather than L4 because
    // L2's own commands reach them: `insertEdgePoint` now installs its splices
    // through `Mesh.setFaceWindings` (for `mesh.addPoint` / `mesh.split_edge`)
    // and `rebuildFacesWithChordSplits` now installs its result through
    // `mesh_planes.rewriteFaces` under an explicit `faceReindexScope()` (for
    // `mesh.splitFace`). §5.5's L4 note lists "record the Pass-1 winding splice
    // as well" and "route the chord rebuild through the primitive" as L4's own
    // open choices #1 and #2; L4 now arrives with both MADE AND MEASURED HERE.
    //
    // So this block is now a full pre/post comparison across a real `revert()`,
    // and what it measures is that the plane cut ROUND-TRIPS.
    immutable string preDump = meshPlanesJson(m);
    immutable size_t addV = countKind(d, MeshOpEntry.Kind.AddVerts);
    assert(kindsOf(d) == "AddVerts ReshapeFaces AddVerts ReshapeFaces AddVerts "
                       ~ "ReshapeFaces AddVerts ReshapeFaces FaceReindex",
        format("the plane cut's op-log is [%s].\n"
             ~ "  ONE entry, `[AddVerts]`, is the pre-L2 state: the four "
             ~ "crossing vertices named and the faces not, in which `revert()` "
             ~ "THROWS out of finalize->buildLoops and half-reverts the mesh.\n"
             ~ "  Expected is four `[AddVerts, ReshapeFaces]` pairs — one per "
             ~ "straddling edge, `insertEdgePoint`'s vertex and its winding "
             ~ "splices — followed by ONE `FaceReindex` for the chord rebuild. "
             ~ "There is no `MeshMapDelta` beside any of them because "
             ~ "`recCutStand` carries no per-corner map; a stand that did would "
             ~ "show the payload paired with each face entry.\n"
             ~ "  The SEQUENCE and not the length: since Stage J the "
             ~ "`[MeshMapDelta, <face entry>]` adjacency is contractual "
             ~ "(`CornerCarry.payloadForCount`), so an interposed entry zeroes "
             ~ "a UV map silently while the geometry round-trips.",
               kindsOf(d)));
    assert(addV == 4,
        format("the op-log names %d AddVerts entr(ies), expected the 4 "
             ~ "straddling edges' crossing vertices", addV));

    // NO POSITION WRITE on the plain cut — the behavioural twin of the §5.7
    // census row, from the other side. `cutByPlane` moves no existing vertex;
    // only the Gap option does, and the block below is where that shows up.
    assert(countKind(d, MeshOpEntry.Kind.SetPos) == 0,
        format("cutByPlane recorded %d Kind.SetPos entr(ies), expected 0 — a "
             ~ "plain plane cut now moves an EXISTING vertex, which no caller "
             ~ "asked for (task 1903 §5.7)",
               countKind(d, MeshOpEntry.Kind.SetPos)));

    // …and NOTHING about the marks either, though the delta DECLARES them.
    //
    // STAGE L4 DID NOT FLIP THIS, AND THAT IS THE RULING RATHER THAN A
    // DEFERRAL. This line used to read "STAGE L4 FLIPS THIS", on the reading
    // that a declared `Marks` scope with no `Kind.SelectionDelta` entry was a
    // gap the migrating stage owed a publisher for. L4 measured it instead of
    // building it, and the gap is not one:
    //
    //   * `Kind.FaceReindex` carries ALL FIVE face planes by construction —
    //     `faceSelectionOrder`, `faceMaterial`, `facePart`, `faceSetMask` and
    //     the marks word (Select + Subpatch + Hide together). That is exactly
    //     why stage L2-d routed the chord rebuild through `rewriteFaces` under
    //     an arming rather than emitting `recordAddFaces` + `recordReshapeFaces`.
    //   * The revert BELOW is the proof, not this count: it compares the WHOLE
    //     plane dump and the only difference is the one recorded normalisation.
    //   * A `SelectionDelta` publisher here would be a SECOND writer over a
    //     plane `FaceReindex` already owns, which is the shape a restore ORDER
    //     exists to prevent (`selection_undo.d`'s header makes the same
    //     argument for the loop-slice family, where the answer came out the
    //     same way).
    //
    // So the equality STAYS, and it now pins a decision instead of a gap: a
    // `SelectionDelta` appearing on this path means someone added that second
    // writer, and this line is where they should argue for it.
    assert(countKind(d, MeshOpEntry.Kind.SelectionDelta) == 0,
        format("the plane cut's op-log carries %d SelectionDelta entr(ies), "
             ~ "expected 0. `Kind.FaceReindex` already carries every face "
             ~ "plane the chord rebuild reinstalls — including the marks word "
             ~ "— so a SelectionDelta here is a SECOND writer over the same "
             ~ "plane, and the revert comparison below is what says the first "
             ~ "one is sufficient (task 1903 Stage L4: measured, not "
             ~ "deferred).",
               countKind(d, MeshOpEntry.Kind.SelectionDelta)));

    // `revert()` IS CALLED NOW, AND CALLING IT IS THE CHECK. Until stage L2 it
    // was deliberately not called because it aborted the module; a block that
    // still declined to call it would not have tested the fix.
    assert(d.revert(m), "the plane cut's revert refused the delta outright");
    assert(m.vertices.length == preV && m.faces.length == preF,
        format("the revert left V=%d F=%d, expected the pre-cut %d/%d — a "
             ~ "HALF-reverted mesh (V back, F not) is the pre-L2 shape",
               m.vertices.length, m.faces.length, preV, preF));

    // THE WHOLE PLANE DUMP, and the ONE named exception.
    //
    // `faceSelectionOrder[2]` is the stand's synthetic stamp 11 on a face that
    // is NOT selected. `MeshSnapshot.restore` copied the array whole and put it
    // back; the delta path re-derives the Select layer and re-zeroes the stamp
    // of every unselected element, which is `SelectionSnapshot.restore`'s own
    // rule (task 0613 S3, against resurrecting a stale rank). The delta is
    // CORRECTER here, so this is a recorded NORMALISATION and not a loss — the
    // same ruling `undo_parity_l3_test.d` takes on the same plane.
    //
    // IT IS A PIN AND NOT A SKIP: the SHAPE is still asserted, so both a new
    // regression on this plane and a FIX of the divergence redden — the second
    // telling whoever fixed it to retire this exception.
    immutable string post = meshPlanesJson(m);
    if (post != preDump) {
        foreach (fi; 0 .. m.faces.length) {
            if (m.isFaceSelected(cast(uint) fi)) continue;
            assert(m.faceSelectionOrder[fi] == 0,
                format("the plane cut's revert left selection-order stamp %d "
                     ~ "on UNSELECTED face %d. The standing exception on this "
                     ~ "plane says the delta path re-zeroes such a stamp; a "
                     ~ "nonzero one is a different divergence and needs its own "
                     ~ "reading", m.faceSelectionOrder[fi], fi));
        }
        // …and nothing ELSE may differ. Re-dump with the exception neutralised
        // on BOTH sides: if the two still disagree, the difference is real.
        Mesh probe = recCutStand();
        probe.faceSelectionOrder[2] = 0;
        assert(meshPlanesJson(probe) == post,
            format("the plane cut's revert differs from the pre-cut state in "
                 ~ "more than the ONE recorded normalisation "
                 ~ "(faceSelectionOrder on unselected faces).\n  pre : %s\n"
                 ~ "  post: %s", meshPlanesJson(probe), post));
    } else {
        assert(false,
            "the plane cut's revert now reproduces the pre-cut dump EXACTLY, "
          ~ "including the synthetic selection-order stamp on unselected face "
          ~ "2. That divergence was recorded as a deliberate normalisation "
          ~ "(the delta path re-zeroes a stamp whose element is not selected, "
          ~ "task 0613 S3). If it is gone, either the normalisation was "
          ~ "reverted — which resurrects the stale-rank corruption that review "
          ~ "removed — or the stand stopped setting the stamp. RETIRE THIS "
          ~ "EXCEPTION in the same commit that closed it.");
    }
}

unittest { // the Gap option's seam separation IS recorded — Kind.SetPos, once
    import std.format : format;

    // The behavioural twin of cut.d's §5.7 census row, and the POSITIVE half of
    // it: the census says "no raw write is left in the file", this says "the
    // write that replaced them reaches the op-log". Neither alone is enough —
    // the census is satisfied by deleting the write, this is satisfied by a
    // write that records but moves the wrong vertices, and the byte-identity
    // differential is what covers that third case.
    Mesh m = recCutStand();
    immutable size_t preV = m.vertices.length;
    auto prePos = m.vertices.dup;   // task 1903 L2: the Gap's SetPos must return

    MeshEditDelta d;
    size_t n;
    PlaneCutLoops r;
    {
        auto ed = MeshEditBatch(m, kCutEditScope);   // RECORDING
        n = ed.cutByPlaneEx(Vec3(0.13f, 0, 0), Vec3(1, 0, 0), /*clipped*/false,
                            Vec3(0, 0, 0), Vec3(0, 0, 0),
                            /*split*/true, /*caps*/true, r,
                            1e-5f, null, /*gap*/0.3f, /*gapSide*/0);
        d = ed.close();
    }

    // Anti-vacuity, twice over: the cut must have happened AND it must have
    // duplicated a seam, because `setVertexPositions` is only reached from
    // inside `if (seamPairs.length)`.
    assert(n == 3 && r.seamPairs.length == 4,
        format("the stand split %d face(s) and produced %d seam pair(s), "
             ~ "expected 3 and 4 — with no seam pair the Gap block never runs "
             ~ "and the SetPos assertion below is vacuous",
               n, r.seamPairs.length));
    assert(m.vertices.length == preV + 8,
        format("V %d -> %d, expected +8 (4 crossing verts + 4 duplicates)",
               preV, m.vertices.length));

    assertDeclaredScope("cutByPlaneEx split+gap", d);

    // ONE entry for the whole seam, not one per vertex: `setVertexPositions` is
    // the bulk form precisely so a kernel that moves N vertices declares once.
    immutable size_t setPos = countKind(d, MeshOpEntry.Kind.SetPos);
    assert(setPos == 1,
        format("the Gap option recorded %d Kind.SetPos entr(ies), expected "
             ~ "exactly 1. Until Stage E3 this separation was two raw "
             ~ "`vertices[pr[0]] = …` writes, which record NOTHING inside a "
             ~ "recording batch — and §5.7's predicate could not even see them, "
             ~ "because it refused to match a nested index expression. If this "
             ~ "is 0 the raw write is back; if it is 8 the bulk form was "
             ~ "replaced by a per-vertex `setVertexPos` loop, which is a "
             ~ "different (and noisier) declaration (task 1903 §2.5, §5.7).",
               setPos));

    // The face side IS here now — task 1903 stage L2-c/L2-d, same mechanism as
    // the block above. Asserted as a KIND SEQUENCE rather than a length: the
    // per-straddling-edge `[AddVerts, ReshapeFaces]` pairs, the chord rebuild's
    // `FaceReindex`, and the Gap's own `SetPos` on the seam.
    assert(countKind(d, MeshOpEntry.Kind.FaceReindex) == 1
        && countKind(d, MeshOpEntry.Kind.ReshapeFaces) > 0,
        format("the split+gap op-log is [%s]. Two entries — AddVerts and "
             ~ "SetPos, and nothing about the faces — is the pre-L2 state, in "
             ~ "which `revert()` throws out of finalize->buildLoops. Expected "
             ~ "is the crossing-vertex splices as `ReshapeFaces` plus ONE "
             ~ "`FaceReindex` for the chord rebuild. See the `cutByPlane` block "
             ~ "above for the full round-trip.", kindsOf(d)));

    // `revert()` IS CALLED, and this cell adds what the block above cannot: the
    // Gap's `SetPos` has to come back too, which is a POSITION claim on top of
    // a topology one. Asserted by index against the pre-op positions.
    assert(d.revert(m),
        "the split+gap revert refused the delta outright");
    assert(m.vertices.length == preV,
        format("the split+gap revert left V=%d, expected the pre-cut %d",
               m.vertices.length, preV));
    foreach (i; 0 .. preV)
        assert(m.vertices[i] == prePos[i],
            format("the split+gap revert left vertex %d at (%g, %g, %g), "
                 ~ "expected its pre-cut (%g, %g, %g) — the topology came back "
                 ~ "and the seam separation did not", i, m.vertices[i].x,
                   m.vertices[i].y, m.vertices[i].z, prePos[i].x, prePos[i].y,
                   prePos[i].z));
}
