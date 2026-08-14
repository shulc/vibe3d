// Module unittests for `mesh_ops.cut`, moved verbatim out of source/mesh_ops/cut.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.cut_test;

import mesh;
import math;
import std.math : abs;
import mesh_ops.cut;

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
    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

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
    size_t nSplit = m.cutByPlane(Vec3(0, 0.5f, 0), Vec3(0, 1, 0));

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
    size_t nSplit = m.cutByPlane(Vec3(0, 0, 0), Vec3(0, 1, 0));

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
    size_t nSplit = m.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);
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
    size_t nSplit = m.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);
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
    size_t na = a.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), null);
    size_t nb = b.cutByPlane(Vec3(0, 0, 0), Vec3(1, 0, 0));
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
    size_t nSplit = m.cutByPlaneClipped(Vec3(0, 0, 0), Vec3(1, 0, 0),
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
    size_t nInf = inf.cutByPlane(Vec3(0, 0, 0), Vec3(0, 0, 1));
    assert(nInf == 4, "infinite: all 4 quads split");
    assert(inf.vertices.length == 18 && inf.faces.length == 8,
           "infinite: 12+6 verts / 4→8 faces");

    // clipped to the left strip: only the 2 left quads split (+3 verts, 4 → 6).
    Mesh clip = twoStrips();
    size_t nClip = clip.cutByPlaneClipped(Vec3(0, 0, 0), Vec3(0, 0, 1),
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

    size_t nSplit = m.cutByPlaneClipped(Vec3(0, 0, 0), Vec3(0, 1, 0),
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
    Mesh.PlaneCutLoops offR;
    size_t nOff = off.cutByPlaneEx(Vec3(0, 0, 0), Vec3(1, 0, 0),
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
    Mesh.PlaneCutLoops onR;
    size_t nOn = on.cutByPlaneEx(Vec3(0, 0, 0), Vec3(1, 0, 0),
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
    Mesh.PlaneCutLoops capR;
    size_t nCap = cap.cutByPlaneEx(Vec3(0, 0, 0), Vec3(1, 0, 0),
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
    Mesh.PlaneCutLoops cR;
    c.cutByPlaneEx(P, N, false, P, P, /*split*/true, /*caps*/true, cR,
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
    Mesh.PlaneCutLoops pR;
    pMesh.cutByPlaneEx(P, N, false, P, P, true, true, pR, 1e-5f, null, G, 1);
    foreach (pr; pR.seamPairs) {
        assert(abs(pMesh.vertices[pr[0]].x - G)    < 1e-6f, "positive: lo at +gap");
        assert(abs(pMesh.vertices[pr[1]].x - 0.0f) < 1e-6f, "positive: hi stays on plane");
    }

    // negative (2): −n shell (hi) takes the full gap along −n; lo stays on plane.
    Mesh nMesh = makeCube(); nMesh.buildLoops(); nMesh.resetSelection();
    Mesh.PlaneCutLoops nR;
    nMesh.cutByPlaneEx(P, N, false, P, P, true, true, nR, 1e-5f, null, G, 2);
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

    Mesh.PlaneCutLoops R;
    // infinite (clipped=false) so the whole cross-section is cut (owner's 16v result).
    size_t nS = m.cutByPlaneEx(P, N, /*clipped*/false, P, P,
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

    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

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

    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

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

    size_t nSplit = m.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);

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

    size_t nSplit = m.cutByPlane(Vec3(0, 0, 0), Vec3(0, 1, 0));

    assert(nSplit == 4, "4 side faces split by mid-plane cut");
    assert(m.faces.length == 10, "6 faces → 4 split (×2) + 2 unchanged = 10");
    assert(m.countSelectedFaces() == 0,
           "nothing selected before the cut ⇒ nothing selected after");
}
