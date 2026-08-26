// Module unittests for `mesh_ops.loop_slice`, moved verbatim out of source/mesh_ops/loop_slice.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.loop_slice_test;

import mesh;
import math;
import mesh_ops.loop_slice;

// Task 1903 Stage F2: the three polygon-bevel entries (`insetFacesByMask`,
// `bevelFacesByMask`, `spikeFacesByMask`) are free functions over
// `ref MeshEditBatch` in `source/mesh_ops/poly_bevel.d`, so a test that drives
// a kernel DIRECTLY opens the batch itself. ONE helper per file, so there is a
// single place that says why it is `unrecorded`: nothing in these blocks reads
// an op-log, and a recording batch would build one for no reader. GENERIC IN
// THE RETURN TYPE — all three kernels answer `size_t`. `auto ref Args` because
// callers pass array literals.
private auto polyBevelOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kPolyBevelEditScope);
    auto n = kernel(ed, args);
    ed.close();
    return n;
}
import mesh_edit_delta : MeshEditDelta, MeshEditScope, MeshOpEntry;

// Task 1903 Stage F1: every MUTATING entry point of this family is a free
// function over `ref MeshEditBatch` now, so a test cannot call one on a bare
// `Mesh` — that is a COMPILE error, and it is the enforcement, not an
// inconvenience. One helper for both entries, so there is ONE place that says
// why the batch is `unrecorded`: nothing in these blocks reads an op-log, and
// track 1 is the conversion axis only. The production callers open theirs the
// same way (`commands/mesh/loop_slice.d` ×2, `tools/slice/loop_slice_tool.d`
// ×2 — commit and per-frame preview — and `tools/edit/topology_pen/tool.d`'s
// Add Loop). The RECORDING block at the bottom of this file is the one
// deliberate exception, and it is the only block that looks at what the delta
// says.
//
// `auto ref` is load-bearing: the 3-arg `insertEdgeLoops` and
// `insertEdgeLoopsMulti` take `out uint[] newFaceIndices`, so the argument
// must reach the kernel as an lvalue for the `out` to land back on the
// caller's variable.
//
// The READ-ONLY entries need no helper: `collectEdgeRing` and
// `loopSliceRingEdges` take `ref const(Mesh)`, so `m.collectEdgeRing(seed, c)`
// keeps compiling verbatim on a `Mesh` lvalue (plan §4.1's whole point about
// the const receiver).
private bool sliceOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kLoopSliceEditScope);
    const ok = kernel(ed, args);
    ed.close();
    return ok;
}

unittest {
    import std.math : abs;
    import std.conv : to;

    // Helper: true if any face in m has exactly the vertices in vs (order-independent).
    static bool hasFace(const Mesh m, uint[] vs) {
        outer: foreach (const f; m.faces) {
            if (f.length != vs.length) continue;
            foreach (v; vs) {
                bool found = false;
                foreach (fv; f) if (fv == v) { found = true; break; }
                if (!found) continue outer;
            }
            return true;
        }
        return false;
    }

    // Helper: find a vertex near the given position; returns ~0u if none within eps.
    static uint findVertNear(const Mesh m, float x, float y, float z,
                             float eps = 1e-4f) {
        foreach (uint i; 0 .. cast(uint)m.vertices.length) {
            auto v = m.vertices[i];
            if (abs(v.x - x) < eps && abs(v.y - y) < eps && abs(v.z - z) < eps)
                return i;
        }
        return ~0u;
    }

    // Helper: like `hasFace` but returns the actual ring ARRAY (in its
    // stored order) rather than a bool -- `hasFace` only checks vertex-SET
    // membership, which is blind to ring ROTATION (task 1054 review, "Also
    // worth strengthening": a band-mode leak into this whole-ring path
    // reddened only a fraction of the existing whole-ring suites, precisely
    // because most of them -- this one included, until the assert below --
    // never inspect a face's ring array, only its vertex set/counts).
    static uint[] findFaceRingByVertexSet(const Mesh m, uint[] vs) {
        outer: foreach (const f; m.faces) {
            if (f.length != vs.length) continue;
            foreach (v; vs) {
                bool found = false;
                foreach (fv; f) if (fv == v) { found = true; break; }
                if (!found) continue outer;
            }
            return f.dup;
        }
        return [];
    }

    // ------------------------------------------------------------------
    // A) Closed ring on the default cube — seed edge 0-1.
    // Cube: v0=(-0.5,-0.5,-0.5) v1=(0.5,-0.5,-0.5)  edge 0-1 = bottom-front.
    // ------------------------------------------------------------------
    {
        Mesh m = makeCube();
        m.buildLoops();

        uint eiSeed = m.edgeIndex(0, 1);
        assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");

        bool ok = sliceOnce!insertEdgeLoops(m, eiSeed, [0.5f]);
        assert(ok, "insertEdgeLoops must succeed on cube");

        // Counts + Euler (V-E+F=2 for closed manifold).
        assert(m.vertices.length == 12, "V must be 12 after one loop on cube");
        assert(m.edges.length    == 20, "E must be 20 after one loop on cube");
        assert(m.faces.length    == 10, "F must be 10 after one loop on cube");
        assert(cast(int)m.vertices.length - cast(int)m.edges.length
               + cast(int)m.faces.length == 2, "Euler must be 2 (closed manifold)");

        // All faces must still be quads.
        foreach (const f; m.faces)
            assert(f.length == 4, "all faces must be quads after loop insert");

        // Midpoint position: new vertex on edge 0-1 must be at x=0 (midpoint
        // of v0.x=-0.5 and v1.x=0.5), y=-0.5, z=-0.5.
        // The walk processes faces in fi order; fi=0 is F0=[0,3,2,1] which
        // contains edge 0-1, so the first new vertex (index 8) is the midpoint
        // of the edge traversed a→b in F0, which equals lerp(v1,v0,0.5) or
        // lerp(v0,v1,0.5) — either way, x=0, y=-0.5, z=-0.5.
        uint mA = findVertNear(m, 0.0f, -0.5f, -0.5f);
        assert(mA != ~0u, "midpoint of edge 0-1 must exist at (0,-0.5,-0.5)");

        // Corresponding midpoints on the three other belt edges.
        uint mB = findVertNear(m,  0.0f,  0.5f, -0.5f); // midpoint of edge 2-3
        uint mC = findVertNear(m,  0.0f,  0.5f,  0.5f); // midpoint of edge 6-7
        uint mD = findVertNear(m,  0.0f, -0.5f,  0.5f); // midpoint of edge 4-5
        assert(mB != ~0u, "midpoint of edge 2-3 must exist at (0,0.5,-0.5)");
        assert(mC != ~0u, "midpoint of edge 6-7 must exist at (0,0.5,0.5)");
        assert(mD != ~0u, "midpoint of edge 4-5 must exist at (0,-0.5,0.5)");

        // Rung edges — these are the new loop edges connecting the midpoints.
        // They form a closed belt: mA–mB–mC–mD–mA.
        assert(m.edgeIndex(mA, mB) != ~0u, "rung edge mA-mB must exist");
        assert(m.edgeIndex(mB, mC) != ~0u, "rung edge mB-mC must exist");
        assert(m.edgeIndex(mC, mD) != ~0u, "rung edge mC-mD must exist");
        assert(m.edgeIndex(mD, mA) != ~0u, "rung edge mD-mA must exist (closure)");

        // One sub-quad by vertex set — orientation sanity.
        // F0=[0,3,2,1] is split into [0,mA,mB,3] (or permutation) and [mA,1,2,mB].
        // We accept either sub-quad of F0 to allow for orientation variants.
        bool subQuadOk = hasFace(m, [0u, mA, mB, 3u]) || hasFace(m, [mA, 1u, 2u, mB]);
        assert(subQuadOk, "at least one sub-quad of the F0 split must exist by vertex set");

        // Task 1054 review ("Also worth strengthening"): the vertex-set
        // checks above (and every other assertion in this test) are blind to
        // ring ORDER. `select = off` (this whole-ring path, `bandFaces ==
        // null`) must stay byte-for-byte on `emitSingleRingSplit`'s own
        // dispatch/construction: its FIRST cap is built literally as
        // `newFaces ~= [a, pLo[0], qLo[0], d];` (loop_slice.d) -- ORIGINAL,
        // new, new, ORIGINAL (`oNNo`) -- never band mode's chord-start
        // rotation (`emitNgonRingSplit`'s `[qLo0] ~ s2 ~ [pLo0]`, R9's
        // `NooN`). Confirmed empirically (a fresh cube's only cut): F0's
        // "toward-a/d" cap is the sub-quad with vertex set {1, mA, mB, 2}
        // (F0=[0,3,2,1], seed edge 0-1 is F0's own wrap-around edge 1->0)
        // and its EXACT stored ring is `[1, mA, mB, 2]` -- not merely "some
        // rotation of that set", which is what the earlier `hasFace`-only
        // checks in this test could not tell apart from a rotated one.
        uint[] cap1 = findFaceRingByVertexSet(m, [1u, mA, mB, 2u]);
        assert(cap1.length == 4, "F0's toward-a/d sub-quad must exist by vertex set");
        assert(cap1 == [1u, mA, mB, 2u],
            "select=off whole-ring split must keep emitSingleRingSplit's "
            ~ "[a, pLo0, qLo0, d] (oNNo) construction EXACTLY -- a band-mode "
            ~ "chord-start rotation (NooN) must never leak into this path -- "
            ~ "got ring " ~ cap1.to!string);
    }

    // ------------------------------------------------------------------
    // B) Open ring: 1×3 quad strip — seed = interior edge 1-5.
    // Strip: F0=[0,1,5,4], F1=[1,2,6,5], F2=[2,3,7,6]
    // Ring from seed 1-5: both sides stop at strip boundaries.
    // ------------------------------------------------------------------
    {
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0), Vec3(3,0,0),
            Vec3(0,0,1), Vec3(1,0,1), Vec3(2,0,1), Vec3(3,0,1),
        ];
        m.addFace([0u, 1u, 5u, 4u]);  // F0
        m.addFace([1u, 2u, 6u, 5u]);  // F1
        m.addFace([2u, 3u, 7u, 6u]);  // F2
        m.buildLoops();

        uint eiSeed = m.edgeIndex(1, 5);
        assert(eiSeed != ~0u, "seed edge 1-5 must exist in strip");

        bool ok = sliceOnce!insertEdgeLoops(m, eiSeed, [0.5f]);
        assert(ok, "insertEdgeLoops must succeed on open strip");

        // V=12, E=17, F=6, Euler=1 (disk topology).
        assert(m.vertices.length == 12, "V must be 12 after open-ring loop");
        assert(m.edges.length    == 17, "E must be 17 after open-ring loop");
        assert(m.faces.length    ==  6, "F must be 6 after open-ring loop");
        assert(cast(int)m.vertices.length - cast(int)m.edges.length
               + cast(int)m.faces.length == 1, "Euler must be 1 (disk topology)");

        // All faces must still be quads.
        foreach (const f; m.faces)
            assert(f.length == 4, "all strip faces must be quads after loop insert");

        // Midpoint on the seed edge 1-5.
        uint mSeed = findVertNear(m, 1.0f, 0.0f, 0.5f);
        assert(mSeed != ~0u, "midpoint of edge 1-5 must exist at (1,0,0.5)");

        // The midpoint is shared between F0 and F1 ring entries, so it must
        // appear as a vertex in a rung edge on EACH side of the seed.
        // Left side (F0): rung connects mSeed to midpoint of 0-4.
        // Right side (F1): rung connects mSeed to midpoint of 2-6.
        uint mLeft  = findVertNear(m, 0.0f, 0.0f, 0.5f); // midpoint of 0-4
        uint mRight = findVertNear(m, 2.0f, 0.0f, 0.5f); // midpoint of 2-6
        assert(mLeft  != ~0u, "midpoint of edge 0-4 must exist at (0,0,0.5)");
        assert(mRight != ~0u, "midpoint of edge 2-6 must exist at (2,0,0.5)");

        assert(m.edgeIndex(mSeed, mLeft)  != ~0u,
               "rung edge mSeed-mLeft must exist (F0 rung)");
        assert(m.edgeIndex(mSeed, mRight) != ~0u,
               "rung edge mSeed-mRight must exist (F1 rung)");

        // mLeft and mRight must NOT be directly connected (open ring — not a closed loop).
        assert(m.edgeIndex(mLeft, mRight) == ~0u,
               "mLeft and mRight must NOT be directly connected (open ring)");
    }
}

// ---------------------------------------------------------------------------
// insertEdgeLoops — task 0678 M1 regression: `faces = newFaces` renumbers
// every face (a split ring face emits several sub-faces, shifting everything
// after it), so the discrete polygon tags (`faceMaterial`/`facePart`) must be
// rebuilt in the same lock-step pass as `faceMarks`.  Before the fix the old
// arrays were kept as-is (resetSelection only fixed their LENGTH), scrambling
// every tag after one belt slice.  Fixture: cube with a DISTINCT material and
// part per face — cube faces are axis-aligned, so every post-slice face's
// source is recoverable from the one coordinate constant across its verts.
unittest {
    import std.math : abs;

    static int planeKeyOf(ref Mesh mm, const(uint)[] f) {
        foreach (axis; 0 .. 3) {
            float coordOf(uint vi) {
                auto v = mm.vertices[vi];
                return axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
            }
            immutable float c0 = coordOf(f[0]);
            bool constant = true;
            foreach (v; f)
                if (abs(coordOf(v) - c0) > 1e-5f) { constant = false; break; }
            if (constant) return axis * 2 + (c0 > 0.0f ? 1 : 0);
        }
        return -1;
    }

    Mesh m = makeCube();
    m.buildLoops();

    // Distinct material + part per face, keyed by the face's plane.
    uint[int] wantMat, wantPart;
    m.faceMaterial.length = m.faces.length;
    m.facePart.length     = m.faces.length;
    foreach (uint fi; 0 .. cast(uint)m.faces.length) {
        immutable int key = planeKeyOf(m, m.faces[fi]);
        assert(key >= 0, "cube faces must be axis-aligned");
        m.faceMaterial[fi] = 10 + fi;
        m.facePart[fi]     = 20 + fi;
        wantMat[key]  = 10 + fi;
        wantPart[key] = 20 + fi;
    }

    uint eiSeed = m.edgeIndex(0, 1);
    assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");
    assert(sliceOnce!insertEdgeLoops(m, eiSeed, [0.5f]), "insertEdgeLoops must succeed");
    assert(m.faces.length == 10, "one belt loop on the cube must yield 10 faces");
    assert(m.faceMaterial.length == m.faces.length,
           "faceMaterial must be rebuilt to the new face count");
    assert(m.facePart.length == m.faces.length,
           "facePart must be rebuilt to the new face count");

    // Every post-slice face still lies in one of the six original planes;
    // its tags must match that plane's original face.
    foreach (uint fi; 0 .. cast(uint)m.faces.length) {
        immutable int key = planeKeyOf(m, m.faces[fi]);
        assert(key >= 0, "sliced cube faces must stay axis-aligned");
        assert(m.faceMaterial[fi] == wantMat[key],
               "faceMaterial must follow its source face through the slice");
        assert(m.facePart[fi] == wantPart[key],
               "facePart must follow its source face through the slice");
    }
}

// insertEdgeLoops — task 0398 regression: OPEN-ring loop slice must land
// every ring vertex on a CONSISTENT (planar) cut, even on the side-B-
// exclusive rails of a two-sided open walk.
//
// Root cause: `collectEdgeRing` walks an OPEN ring from BOTH faces incident
// to the seed edge (`sideA` from `incFaces[0]`, `sideB` from `incFaces[1]`).
// The seed edge carries opposite darts in its two incident faces (a basic
// manifold invariant), so every rail `getMids` creates FRESH from a side-B
// entry lands at fraction `1-t` instead of `t` relative to side A's
// convention — one ring vertex ends up off-plane (owner repro: v19 landed at
// Y=0.4415 while the other three sat at Y=0.3085). The fix (`EdgeRingEntry.
// mirror` + `getMids`'s `mirror` param) mirrors a FRESH side-B rail's
// fraction so it lands in side A's convention. This test uses an asymmetric
// t (0.234, NOT 0.5 — 0.5 is a mirror fixed point and can't distinguish a
// mirrored result from a correct one) and checks planarity + winding
// directly, rather than depending on the owner's specific coordinates.
//
// Cage: a belt of 3 quads (LEFT, BACK, FRONT) around Y=[0.25,0.5] with the
// RIGHT quad DELETED — a quad belt sliced out of a cuboid with one side face
// missing, exactly the construction (and asymmetry) the validated repro
// used. Seeding from the INTERIOR rail (2,3), shared by LEFT and BACK, forces
// `collectEdgeRing` down the two-sided walk: side A = {LEFT, FRONT}
// (terminates at the deleted RIGHT via FRONT's own boundary rail), side B =
// {BACK} (also terminates at the deleted RIGHT via BACK's own boundary rail)
// — BACK's own rail is created FRESH exclusively by side B, exactly the
// failure mode task 0398 fixed.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    // Winding-consistency scan: a well-formed manifold quad mesh has each
    // interior undirected edge covered by at most ONE dart per direction; a
    // repeated same-direction dart across two faces means one is inverted.
    static int repeatedDirectionDarts(const Mesh m) {
        int[ulong] fwd;
        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];
            foreach (k; 0 .. f.length) {
                uint a = f[k], b = f[(k + 1) % f.length];
                ulong dkey = (cast(ulong)a << 32) | b;
                fwd[dkey] = (dkey in fwd ? fwd[dkey] : 0) + 1;
            }
        }
        int sameDir = 0;
        foreach (k, cnt; fwd) if (cnt > 1) ++sameDir;
        return sameDir;
    }

    // ------------------------------------------------------------------
    // A) OPEN ring, two-sided walk — the bug's exact failure mode.
    // ------------------------------------------------------------------
    {
        Mesh m;
        m.vertices = [
            Vec3(-0.5f, 0.25f,  0.5f),  // 0 L0 bottom-front
            Vec3(-0.5f, 0.5f,   0.5f),  // 1 L1 top-front
            Vec3(-0.5f, 0.5f,  -0.5f),  // 2 L2 top-back
            Vec3(-0.5f, 0.25f, -0.5f),  // 3 L3 bottom-back
            Vec3( 0.5f, 0.25f,  0.5f),  // 4 R0 bottom-front
            Vec3( 0.5f, 0.5f,   0.5f),  // 5 R1 top-front
            Vec3( 0.5f, 0.5f,  -0.5f),  // 6 R2 top-back
            Vec3( 0.5f, 0.25f, -0.5f),  // 7 R3 bottom-back
        ];
        m.addFace([0u, 1u, 2u, 3u]);   // LEFT
        m.addFace([3u, 2u, 6u, 7u]);   // BACK
        m.addFace([0u, 4u, 5u, 1u]);   // FRONT
        // RIGHT [4,7,6,5] intentionally OMITTED — the ring is OPEN.
        m.rebuildEdges();
        m.buildLoops();

        uint seed = m.edgeIndex(2, 3);   // interior rail shared by LEFT/BACK
        assert(seed != ~0u, "seed rail (2,3) must exist");

        bool closed;
        auto ring = m.collectEdgeRing(seed, closed);
        assert(!closed, "sanity: this belt's ring must be OPEN");
        assert(ring.length == 3, "sanity: ring crosses LEFT+FRONT (side A) + BACK (side B)");

        bool ok = sliceOnce!insertEdgeLoops(m, seed, [0.234f]);
        assert(ok, "open-ring insertEdgeLoops must succeed");
        assert(m.vertices.length == 12, "4 distinct rails (seed + 3 exit rails) get one midpoint each");

        float ymin = 1e9f, ymax = -1e9f;
        foreach (vi; 8 .. m.vertices.length) {
            float y = m.vertices[vi].y;
            if (y < ymin) ymin = y;
            if (y > ymax) ymax = y;
        }
        assert(ymax - ymin < 1e-4f,
               "task 0398: all 4 ring vertices must be coplanar (one loop, one height)");
        assert(repeatedDirectionDarts(m) == 0,
               "task 0398 fix must not invert any face's winding");
    }

    // ------------------------------------------------------------------
    // B) CLOSED ring sanity — the mirror flag must NEVER fire here.
    // `walkRingSide` returns via `closedA` before side B is ever walked
    // (mesh.d, `collectEdgeRing`), so this must stay byte-for-byte with the
    // pre-0398 behaviour. Uses an ASYMMETRIC t (0.5 is a mirror fixed point
    // and can't tell a mirrored result from a correct one). Seed edge (0,1)
    // on `makeCube()` is the X-aligned belt seed the existing closed-ring
    // unittest (A, above) uses at t=0.5 — every one of the 4 belt rails
    // (0-1, 2-3, 6-7, 4-5) runs along X, so a CONSISTENT fraction must land
    // all 4 new vertices at the SAME X (not Y — this belt varies in Y/Z as
    // it goes around, only X is the cut-fraction axis).
    // ------------------------------------------------------------------
    {
        Mesh cube = makeCube();
        cube.buildLoops();
        uint eiSeed = cube.edgeIndex(0, 1);
        assert(eiSeed != ~0u, "cube seed edge 0-1 must exist");

        bool closed;
        auto ring = cube.collectEdgeRing(eiSeed, closed);
        assert(closed, "sanity: cube's equatorial ring must be CLOSED");

        bool ok = sliceOnce!insertEdgeLoops(cube, eiSeed, [0.234f]);
        assert(ok, "closed-ring insertEdgeLoops must succeed");
        assert(cube.vertices.length == 12, "closed ring: 8 + 4 belt midpoints");

        float xmin = 1e9f, xmax = -1e9f;
        foreach (vi; 8 .. cube.vertices.length) {
            float x = cube.vertices[vi].x;
            if (x < xmin) xmin = x;
            if (x > xmax) xmax = x;
        }
        assert(xmax - xmin < 1e-4f,
               "closed-ring belt vertices must share one X (mirror flag never fires)");
        // Exact value (task 0398 fix must not touch this — closed rings
        // never mirror): the walk visits F0=[0,3,2,1] first, whose local
        // frame for edge (0,1) is the dart 1->0 (a=1,b=0), so the vertex
        // sits at v1 + (v0-v1)*t = 0.5 + (-1.0)*0.234 = 0.266. A mirrored
        // (1-t) result would instead land at -0.266.
        assert(abs(cube.vertices[8].x - 0.266f) < 1e-3f,
               "closed-ring belt X must be the UNMIRRORED t=0.234 fraction (byte-for-byte pre-0398)");
        assert(repeatedDirectionDarts(cube) == 0,
               "closed-ring cut must not invert any face winding");
    }
}

// ---------------------------------------------------------------------------
// insertEdgeLoops (3-arg, Select-New-Polygons affordance) — the returned
// `newFaceIndices` must name exactly the sub-quads this call created, and
// nothing else. On the cube fixture above the closed ring crosses 4
// equatorial quad faces (ringLen=4); one loop (count=1) replaces each ring
// face with exactly 2 sub-quads (first+last, no middle sub-quad) → the
// returned set must have length 2*ringLen == 8, and every referenced face
// index must still be a quad.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.buildLoops();

    uint eiSeed = m.edgeIndex(0, 1);
    assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");

    uint[] newFaceIndices;
    bool ok = sliceOnce!insertEdgeLoops(m, eiSeed, [0.5f], newFaceIndices);
    assert(ok, "insertEdgeLoops(3-arg) must succeed on cube");

    enum ringLen = 4;   // the equatorial ring crosses 4 quad faces
    assert(newFaceIndices.length == 2 * ringLen,
           "count=1 must report 2 sub-quads per ring face (first+last, no middle)");

    // No duplicate indices, and every returned index names a real quad face.
    bool[uint] seen;
    foreach (fi; newFaceIndices) {
        assert(fi !in seen, "newFaceIndices must not repeat an index");
        seen[fi] = true;
        assert(fi < m.faces.length, "newFaceIndices must index into the rebuilt faces array");
        assert(m.faces[fi].length == 4, "every reported new face must be a quad");
    }

    // The 2-arg forwarder must be byte-identical to the 3-arg call (ignoring
    // the out-param) — same V/E/F on an independent mesh.
    Mesh m2 = makeCube();
    m2.buildLoops();
    uint eiSeed2 = m2.edgeIndex(0, 1);
    bool ok2 = sliceOnce!insertEdgeLoops(m2, eiSeed2, [0.5f]);
    assert(ok2, "2-arg forwarder must still succeed");
    assert(m2.vertices.length == m.vertices.length
           && m2.edges.length == m.edges.length
           && m2.faces.length == m.faces.length,
           "2-arg forwarder must produce the same geometry as the 3-arg overload");
}

// insertEdgeLoopsMulti — duplicate CUT POSITION dedup (task 0308, fuzz-found).
//
// Definitive repro: select edge 0, tool.set mesh.loopSliceTool, mode Free,
// position 0.5, then insertAt 0.5 — Free mode does not enforce distinct
// slice fractions, so `positions_` ends up `[0.5, 0.5]` (two IDENTICAL cut
// fractions on the same seed ring) and reached the kernel unchanged.
// `getMids` independently `addVertex`'d once PER entry in `positions`, so
// each of the ring's 4 rails grew TWO coincident vertices (same world
// position, distinct indices) instead of one, and the sub-quad chain built
// a zero-area quad between each coincident pair — 16v/28e/14f instead of a
// clean single cut's 12v/20e/10f (4 exact-coincident vertex pairs + 4
// zero-area faces). This is a DIFFERENT failure mode than the 0303
// `edgeSliceEx` atomicity bug (that one was a Pass-1/Pass-2 rollback gap on
// a legitimate no-split outcome; this one is a degenerate INPUT — duplicate
// cut fractions — that the kernel must dedup before creating any vertex).
unittest {
    Mesh dup = makeCube();
    uint eiDup = dup.edgeIndex(0, 1);
    assert(eiDup != ~0u, "seed edge 0-1 must exist on cube");
    uint[] nfDup;
    bool okDup = sliceOnce!insertEdgeLoopsMulti(dup, [eiDup], [0.5f, 0.5f], nfDup);
    assert(okDup, "duplicate cut positions must still succeed (clean single cut)");

    Mesh clean = makeCube();
    uint eiClean = clean.edgeIndex(0, 1);
    uint[] nfClean;
    bool okClean = sliceOnce!insertEdgeLoopsMulti(clean, [eiClean], [0.5f], nfClean);
    assert(okClean, "single-position reference insert must succeed");

    assert(dup.vertices.length == clean.vertices.length,
           "a duplicate cut position must NOT add extra (coincident) vertices");
    assert(dup.faces.length == clean.faces.length,
           "a duplicate cut position must NOT add extra (zero-area) faces");
    assert(dup.edges.length == clean.edges.length,
           "a duplicate cut position must NOT add extra edges");
    assert(nfDup.length == nfClean.length,
           "newFaceIndices must report the same sub-quad count as the deduped single cut");

    // No two vertices may be exactly coincident (the concrete symptom: 4
    // coincident vertex PAIRS at the 4 rail midpoints).
    foreach (i; 0 .. dup.vertices.length)
        foreach (j; i + 1 .. dup.vertices.length)
            assert((dup.vertices[i] - dup.vertices[j]).length() > 1e-5f,
                   "no two vertices may sit at the exact same world position");

    // No zero-area faces (the concrete symptom: 4 degenerate quads spliced
    // between each coincident vertex pair).
    import std.conv : to;
    foreach (fi, f; dup.faces) {
        Vec3 centroid = Vec3(0, 0, 0);
        foreach (vi; f) centroid = centroid + dup.vertices[vi];
        centroid = centroid * (1.0f / f.length);
        float area = 0.0f;
        foreach (k; 0 .. f.length) {
            Vec3 a = dup.vertices[f[k]] - centroid;
            Vec3 b = dup.vertices[f[(k + 1) % f.length]] - centroid;
            area += cross(a, b).length();
        }
        area *= 0.5f;
        assert(area > 1e-6f, "face " ~ fi.to!string ~ " must not be zero-area");
    }

    // Euler characteristic must stay 2 (a closed watertight solid).
    assert(cast(long)dup.vertices.length - cast(long)dup.edges.length
           + cast(long)dup.faces.length == 2,
           "Euler characteristic must stay 2 after a deduped single cut");

    // count=N under Free mode: 3 slots defaulting to 0.5 (the mode-law
    // no-op path noted in the task) must collapse the SAME way as an
    // explicit [0.5, 0.5, 0.5].
    Mesh triple = makeCube();
    uint eiTriple = triple.edgeIndex(0, 1);
    uint[] nfTriple;
    bool okTriple = sliceOnce!insertEdgeLoopsMulti(triple, [eiTriple], [0.5f, 0.5f, 0.5f], nfTriple);
    assert(okTriple, "triple-duplicate cut positions must still succeed");
    assert(triple.vertices.length == clean.vertices.length
           && triple.faces.length == clean.faces.length
           && triple.edges.length == clean.edges.length,
           "N-way duplicate cut positions must collapse to the SAME clean single cut");
}

// insertEdgeLoopsMulti — Slice Selected restriction (task 0248). Seed edge
// (0,1) crosses the belt ring {front(0), top(4), back(1), bottom(5)} of the
// default cube. Restricting the cut to faces {0,5} (front + bottom) must slice
// ONLY those two, absorbing the terminating midpoints into their unsliced belt
// neighbours (top, back) as n-gons — a watertight partial cut.
unittest {
    import std.math : abs;
    static bool hasVertNear(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x - p.x) < eps && abs(v.y - p.y) < eps && abs(v.z - p.z) < eps)
                return true;
        return false;
    }

    // Whole-ring baseline (restrictFaces = null) — 4 belt faces sliced.
    Mesh whole = makeCube();
    uint eiW = whole.edgeIndex(0, 1);
    uint[] nfW;
    assert(sliceOnce!insertEdgeLoopsMulti(whole, [eiW], [0.5f], nfW),
           "whole-ring insert must succeed");
    assert(whole.vertices.length == 12,
           "whole ring: 8 + 4 belt midpoints = 12 verts");
    assert(whole.faces.length == 10,
           "whole ring: 4 sliced belt faces (×2) + 2 caps = 10 faces");

    // Restricted to {front=0, bottom=5}: only those two are sliced; top+back
    // absorb the boundary midpoints → 3 new verts, 8 faces.
    Mesh restr = makeCube();
    uint eiR = restr.edgeIndex(0, 1);
    uint[] nfR;
    assert(sliceOnce!insertEdgeLoopsMulti(restr, [eiR], [0.5f], nfR, [0u, 5u]),
           "restricted insert must succeed");
    assert(restr.vertices.length == 11,
           "restricted: 8 + 3 (two boundary + one shared seed) midpoints = 11 verts");
    assert(restr.faces.length == 8,
           "restricted: front+bottom sliced (4 quads) + top/back n-gons + left/right = 8");

    // The three midpoints that MUST exist (seed + two selection-border rails).
    assert(hasVertNear(restr, Vec3( 0.0f, -0.5f, -0.5f)), "seed midpoint present");
    assert(hasVertNear(restr, Vec3( 0.0f,  0.5f, -0.5f)), "front→top border midpoint present");
    assert(hasVertNear(restr, Vec3( 0.0f, -0.5f,  0.5f)), "bottom→back border midpoint present");
    // The whole-ring-only midpoint on the top-back edge must be ABSENT — the
    // cut never reached that edge because neither incident face was selected.
    assert(!hasVertNear(restr, Vec3(0.0f, 0.5f, 0.5f)),
           "top-back midpoint must NOT appear under Slice Selected");

    // newFaceIndices reports only the CREATED sub-quads (front+bottom = 4),
    // not the absorbed n-gon neighbours (modified originals).
    assert(nfR.length == 4,
           "restricted newFaceIndices = 4 sliced sub-quads (2 faces × 2 each)");
}

// insertEdgeLoopsMulti — Keep Quads is a NO-OP under watertight-by-default. A
// planar strip of two quads Q0=[0,1,4,3], Q1=[1,2,5,4] capped by a triangle
// T=[2,6,5]. The seed edge (1,4) makes the quad ring walk {Q0,Q1} and TERMINATE
// at the non-quad T — an OPEN ring. Since the default now absorbs the terminating
// midpoint at that non-quad neighbour, BOTH Keep Quads OFF and ON produce the
// SAME watertight all-quad result (10 verts / 5 faces / 14 edges; T absorbs the
// midpoint → the quad [2,6,5,mid]; the full edge (2,5) is gone). This matches the
// reference (Keep Quads on == off). `quad` is retained only for panel parity.
unittest {
    static Mesh makeStrip() {
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),      // v0 v1 v2
            Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),      // v3 v4 v5
            Vec3(3,0.5f,0),                             // v6 triangle apex
        ];
        m.addFace([0u,1u,4u,3u]);   // Q0
        m.addFace([1u,2u,5u,4u]);   // Q1
        m.addFace([2u,6u,5u]);      // T (triangle)
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }

    // Keep Quads OFF (default) — the open ring absorbs the terminating midpoint
    // by default → T becomes the quad [2,6,5,mid], watertight, no T-junction.
    Mesh off = makeStrip();
    uint eiOff = off.edgeIndex(1, 4);
    assert(eiOff != ~0u, "seed edge (1,4) must exist");
    uint[] nfOff;
    assert(sliceOnce!insertEdgeLoopsMulti(off, [eiOff], [0.5f], nfOff, null, /*keepQuads*/false),
           "keep-quads-off insert must succeed");
    assert(off.vertices.length == 10, "off: 7 + 3 midpoints = 10 verts");
    assert(off.faces.length == 5,     "off: Q0×2 + Q1×2 + T(now quad) = 5 faces");
    assert(off.edges.length == 14,    "off: 14 edges (default absorbs the midpoint — watertight)");
    // The full seed-exit edge (v2..v5) is GONE — T absorbed the midpoint by default.
    assert(off.edgeIndex(2, 5) == ~0u,
           "off: full exit edge (2,5) removed (non-quad T absorbed the midpoint by default)");

    // Keep Quads ON — geometric no-op: identical watertight result.
    Mesh on = makeStrip();
    uint eiOn = on.edgeIndex(1, 4);
    uint[] nfOn;
    assert(sliceOnce!insertEdgeLoopsMulti(on, [eiOn], [0.5f], nfOn, null, /*keepQuads*/true),
           "keep-quads-on insert must succeed");
    assert(on.vertices.length == 10, "on: identical vertex set (10 verts)");
    assert(on.faces.length == 5,     "on: same 5 faces (T is a quad)");
    assert(on.edges.length == 14,    "on: 14 edges (no-op — same as OFF)");
    // The full exit edge (2,5) is GONE — T references (2,mid) and (mid,5).
    assert(on.edgeIndex(2, 5) == ~0u,
           "on: full exit edge (2,5) removed (identical to OFF)");
    // Both created only the 4 sub-quads of Q0+Q1; the absorbed T is excluded.
    assert(nfOn.length == 4,  "on: newFaceIndices = 4 created sub-quads (T excluded)");
    assert(nfOff.length == 4, "off: newFaceIndices = 4 created sub-quads (T excluded)");
}

// insertEdgeLoopsMulti — Slice N-gon guard (task 0250). A planar horizontal
// strip Q0=[0,1,6,5], Q1=[1,2,7,6], a HEXAGON H=[2,10,3,8,11,7] (top+bottom
// split at x=2.5), Q2=[3,4,9,8]. Seed = the vertical edge (1,6) between the two
// left quads. The quad ring walks left to the boundary (via Q0) and right into
// H. With ngon OFF (default) the ring TERMINATES at the hexagon → only {Q0,Q1}
// are sliced (H, Q2 untouched; the exit rail leaves a T-junction against H).
// With ngon ON the ring CROSSES the hexagon (chord between its two vertical-edge
// midpoints) and reaches Q2 → {Q0,Q1,H,Q2} all sliced. Countable proof: OFF =
// 15 verts / 20 edges / 6 faces (watertight-by-default: the terminating midpoint
// is absorbed into the hexagon → 7-gon, no T-junction); ON = 17 verts / 24 edges
// / 8 faces.
unittest {
    import std.math : abs;
    static bool hasV(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x-p.x) < eps && abs(v.y-p.y) < eps && abs(v.z-p.z) < eps)
                return true;
        return false;
    }
    static Mesh makeStrip() {
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0), Vec3(3,0,0), Vec3(4,0,0), // v0..v4
            Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0), Vec3(3,1,0), Vec3(4,1,0), // v5..v9
            Vec3(2.5f,0,0), Vec3(2.5f,1,0),                                  // v10 BM, v11 TM
        ];
        m.addFace([0u,1u,6u,5u]);         // Q0
        m.addFace([1u,2u,7u,6u]);         // Q1
        m.addFace([2u,10u,3u,8u,11u,7u]); // H (hexagon)
        m.addFace([3u,4u,9u,8u]);         // Q2
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }

    // ngon OFF (default) — ring terminates at the hexagon; only Q0,Q1 sliced, but
    // the hexagon ABSORBS the terminating midpoint by default (7-gon, watertight).
    Mesh off = makeStrip();
    uint eiOff = off.edgeIndex(1, 6);
    assert(eiOff != ~0u, "seed edge (1,6) must exist");
    uint[] nfOff;
    assert(sliceOnce!insertEdgeLoopsMulti(off, [eiOff], [0.5f], nfOff, null, false, /*ngon*/false),
           "ngon-off insert must succeed");
    assert(off.vertices.length == 15, "off: 12 + 3 midpoints = 15 verts");
    assert(off.edges.length    == 20, "off: 20 edges (hexagon absorbs the terminating midpoint — watertight)");
    assert(off.faces.length    == 6,  "off: Q0×2 + Q1×2 + H(7-gon) + Q2 = 6 faces");
    // The hexagon + Q2 rails were never traversed — no midpoints there.
    assert(!hasV(off, Vec3(3,0.5f,0)), "off: hexagon exit rail NOT cut");
    assert(!hasV(off, Vec3(4,0.5f,0)), "off: Q2 rail NOT cut (ring stopped at hexagon)");
    // The exit edge into the hexagon is GONE — the hexagon absorbed the midpoint
    // (its boundary edge (2,7) split into (2,mid),(mid,7)), so the cut is watertight.
    assert(off.edgeIndex(2, 7) == ~0u, "off: full edge (2,7) removed (hexagon absorbed the midpoint)");
    assert(nfOff.length == 4, "off: 4 created sub-quads (Q0+Q1); absorbed hexagon excluded");

    // ngon ON — ring crosses the hexagon and reaches Q2; all four faces sliced.
    Mesh on = makeStrip();
    uint eiOn = on.edgeIndex(1, 6);
    uint[] nfOn;
    assert(sliceOnce!insertEdgeLoopsMulti(on, [eiOn], [0.5f], nfOn, null, false, /*ngon*/true),
           "ngon-on insert must succeed");
    assert(on.vertices.length == 17, "on: 12 + 5 midpoints = 17 verts");
    assert(on.edges.length    == 24, "on: 24 edges (watertight crossing, no T-junction)");
    assert(on.faces.length    == 8,  "on: Q0×2 + Q1×2 + H×2 + Q2×2 = 8 faces");
    // The hexagon was traversed: its two vertical-edge midpoints now exist and
    // the exit-into-hexagon edge is gone (replaced by the two half-edges).
    assert(hasV(on, Vec3(3,0.5f,0)), "on: hexagon exit rail midpoint present");
    assert(hasV(on, Vec3(4,0.5f,0)), "on: Q2 rail cut (ring reached past hexagon)");
    assert(on.edgeIndex(2, 7) == ~0u, "on: full edge (2,7) gone (hexagon sliced)");
    assert(on.edgeIndex(3, 8) == ~0u, "on: full edge (3,8) gone (hexagon+Q2 sliced)");
    // Hexagon chord split emits 2 sub-faces; Q0,Q1,Q2 emit 2 each = 8 total.
    assert(nfOn.length == 8, "on: 8 created sub-faces across the 4 ring faces");
}

// insertEdgeLoopsMulti — Split guard (task 0251). A unit cube, seed = the
// equatorial belt edge (0,1); the ring cuts a horizontal loop around the 4 side
// faces (4 rails → 4 midpoints). Split OFF keeps ONE connected loop (watertight
// closed cube: 0 boundary edges, 1 component). Split ON DUPLICATES each rail
// midpoint (+4 verts, +4 edges, SAME face count) so the single loop becomes TWO
// boundary edge-loops → 8 boundary edges + 2 disconnected shells. The seam pairs
// (splitPairsOut) list each coincident [lo,hi] duplicate for Cap/Gap (0252/0253).
unittest {
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
    // Connected-component count over faces joined by any shared vertex.
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

    // Split OFF (default) — one connected loop, closed manifold cube.
    Mesh off = makeCube();
    uint eiOff = off.edgeIndex(0, 1);
    assert(eiOff != ~0u, "cube seed edge (0,1) must exist");
    uint[] nfOff;
    assert(sliceOnce!insertEdgeLoopsMulti(off, [eiOff], [0.5f], nfOff, null, false, false, /*split*/false),
           "split-off insert must succeed");
    immutable offV = off.vertices.length, offE = off.edges.length, offF = off.faces.length;
    assert(boundaryEdgeCount(off) == 0, "split off: closed cube, no boundary edges");
    assert(componentCount(off) == 1, "split off: one connected shell");

    // Split ON — each rail midpoint duplicated → two disconnected boundary loops.
    Mesh on = makeCube();
    uint eiOn = on.edgeIndex(0, 1);
    uint[] nfOn;
    uint[2][] pairs;
    assert(sliceOnce!insertEdgeLoopsMulti(on, [eiOn], [0.5f], nfOn, null, false, false, /*split*/true, /*caps*/false, &pairs),
           "split-on insert must succeed");
    assert(on.vertices.length == offV + 4, "split on: 4 rail midpoints duplicated");
    assert(on.edges.length    == offE + 4, "split on: 4 loop edges doubled into boundaries");
    assert(on.faces.length    == offF,     "split on: splitting duplicates verts, not faces");
    assert(boundaryEdgeCount(on) == 8, "split on: two 4-edge boundary loops (8 boundary edges)");
    assert(componentCount(on) == 2, "split on: two disconnected shells");
    assert(nfOn.length == nfOff.length, "split on: same created sub-face count as off");

    // Seam pairs: one [lo,hi] per duplicated rail midpoint, coincident + distinct.
    assert(pairs.length == 4, "split on: 4 seam pairs (one per rail midpoint)");
    foreach (pr; pairs) {
        assert(pr[0] != pr[1], "seam lo/hi must be distinct verts");
        Vec3 a = on.vertices[pr[0]], b = on.vertices[pr[1]];
        assert(abs(a.x-b.x) < 1e-6f && abs(a.y-b.y) < 1e-6f && abs(a.z-b.z) < 1e-6f,
               "seam lo/hi coincide (zero gap — Gap/0253 moves them apart later)");
    }

    // Split OFF emits no seam pairs even when a splitPairsOut sink is given.
    Mesh off2 = makeCube();
    uint[] nf2;
    uint[2][] pairs2;
    sliceOnce!insertEdgeLoopsMulti(off2, [off2.edgeIndex(0, 1)], [0.5f], nf2, null, false, false, false, /*caps*/false, &pairs2);
    assert(pairs2.length == 0, "split off: no seam pairs emitted");
}

// insertEdgeLoopsMulti — Cap Sections guard (task 0252, geometry corrected by the
// LIVE reference capture in task 0261). Same unit cube + equatorial seed (0,1); the
// ring cuts a belt around the 4 side faces (4 rails → 4 duplicated lo/hi pairs under
// Split). Split ON + caps OFF is exactly 0251's result: 8 boundary edges, 2
// disconnected shells. Split ON + caps ON seals EACH shell's boundary loop with ONE
// cap polygon (the reference-captured behaviour: the cube belt yields +2 faces, one
// per shell — NOT the pre-0261 ring of 4 bridging quads). Each cap closes its loop
// (boundary edges 8→0) but the two shells stay DISCONNECTED (each becomes an
// independent closed solid): +2 faces, NO new edges (cap edges reuse the shell
// boundary edges), NO new verts. caps is a no-op when Split is off (byte-for-byte).
unittest {
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

    // Split ON, caps OFF — open sections (0251's split-on topology).
    Mesh open = makeCube();
    uint eiO = open.edgeIndex(0, 1);
    assert(eiO != ~0u, "cube seed edge (0,1) must exist");
    uint[] nfOpen;
    assert(sliceOnce!insertEdgeLoopsMulti(open, [eiO], [0.5f], nfOpen, null, false, false, /*split*/true, /*caps*/false),
           "split-on caps-off insert must succeed");
    immutable openV = open.vertices.length, openE = open.edges.length, openF = open.faces.length;
    assert(boundaryEdgeCount(open) == 8, "caps off: two 4-edge boundary loops (8 boundary edges)");
    assert(componentCount(open) == 2, "caps off: two disconnected shells");

    // Split ON, caps ON — cap ring closes both boundary loops.
    Mesh capped = makeCube();
    uint eiC = capped.edgeIndex(0, 1);
    uint[] nfCap;
    assert(sliceOnce!insertEdgeLoopsMulti(capped, [eiC], [0.5f], nfCap, null, false, false, /*split*/true, /*caps*/true),
           "split-on caps-on insert must succeed");
    assert(capped.vertices.length == openV,     "caps on: adds NO new vertices");
    assert(capped.faces.length    == openF + 2, "caps on: +2 cap polys (one per shell loop)");
    assert(capped.edges.length    == openE,     "caps on: cap edges reuse the boundary edges (no new edges)");
    assert(boundaryEdgeCount(capped) == 0, "caps on: both boundary loops closed (0 boundary edges)");
    assert(componentCount(capped) == 2, "caps on: caps seal each shell — two shells stay disconnected");
    // Two closed genus-0 shells → V-E+F = 2 per shell = 4 total.
    assert(cast(long)capped.vertices.length - cast(long)capped.edges.length
           + cast(long)capped.faces.length == 4, "caps on: two closed manifolds, V-E+F = 4");
    // The 2 cap polys are reported as new polys (Select-New selects them).
    assert(nfCap.length == nfOpen.length + 2, "caps on: 2 extra new faces vs caps-off");

    // caps is a no-op when Split is off (byte-for-byte the connected loop).
    Mesh nosplit = makeCube();
    uint[] nfNo;
    assert(sliceOnce!insertEdgeLoopsMulti(nosplit, [nosplit.edgeIndex(0, 1)], [0.5f], nfNo, null, false, false, /*split*/false, /*caps*/true),
           "caps-on split-off insert must succeed");
    assert(boundaryEdgeCount(nosplit) == 0 && componentCount(nosplit) == 1,
           "caps no-op with Split off: still the closed connected cube");
    assert(nosplit.faces.length == openF, "caps no-op with Split off: no cap faces added");
}

// insertEdgeLoopsMulti — Gap guard (task 0253; direction confirmed by the LIVE
// reference capture in task 0261). Same unit cube + equatorial seed (0,1); Split ON
// duplicates each rail midpoint into a coincident lo/hi pair and Caps ON seals each
// shell's loop with one cap polygon. Gap pushes each seam pair apart by `gap`
// (±gap/2, symmetric) ALONG THE RAIL — the reference does exactly this: the two
// shells separate along the loop rail (±Y on the cube), opening a real visible band
// between the two caps. gap=0 leaves the pairs COINCIDENT (byte-for-byte 0251/0252);
// gap=G separates every [lo,hi] pair by EXACTLY G and pulls the two caps G apart.
// Topology is identical to the gap=0 caps-on case either way (Gap only moves verts).
unittest {
    import std.math : abs, sqrt;
    static Vec3 faceCentroid(ref Mesh m, uint fi) {
        auto f = m.faces[fi];
        Vec3 c = Vec3(0, 0, 0);
        foreach (vi; f) c = c + m.vertices[vi];
        return c * (1.0f / cast(float)f.length);
    }

    enum float G = 0.2f;

    // gap=0 baseline (== the caps-on result): 4 seam pairs still coincident.
    Mesh z = makeCube();
    uint eiZ = z.edgeIndex(0, 1);
    assert(eiZ != ~0u, "cube seed edge (0,1) must exist");
    uint[] nfZ; uint[2][] prZ;
    assert(sliceOnce!insertEdgeLoopsMulti(z, [eiZ], [0.5f], nfZ, null, false, false,
                                  /*split*/true, /*caps*/true, &prZ, /*gap*/0.0f),
           "split+caps, gap=0 insert must succeed");
    immutable zV = z.vertices.length, zE = z.edges.length, zF = z.faces.length;
    assert(prZ.length == 4, "gap=0: 4 seam pairs");
    foreach (pr; prZ) {
        Vec3 a = z.vertices[pr[0]], b = z.vertices[pr[1]];
        assert(abs(a.x-b.x) < 1e-6f && abs(a.y-b.y) < 1e-6f && abs(a.z-b.z) < 1e-6f,
               "gap=0: seam lo/hi still coincide");
    }

    // gap=G opens the pairs: same topology, each pair separated by EXACTLY G.
    Mesh g = makeCube();
    uint eiG = g.edgeIndex(0, 1);
    uint[] nfG; uint[2][] prG;
    assert(sliceOnce!insertEdgeLoopsMulti(g, [eiG], [0.5f], nfG, null, false, false,
                                  /*split*/true, /*caps*/true, &prG, /*gap*/G),
           "split+caps, gap>0 insert must succeed");
    // Topology unchanged by Gap (positions only).
    assert(g.vertices.length == zV && g.edges.length == zE && g.faces.length == zF,
           "gap>0: topology identical to gap=0 (Gap relocates verts only)");
    assert(prG.length == 4, "gap>0: 4 seam pairs");
    foreach (pr; prG) {
        Vec3 a = g.vertices[pr[0]], b = g.vertices[pr[1]];
        float d = sqrt((a.x-b.x)*(a.x-b.x) + (a.y-b.y)*(a.y-b.y) + (a.z-b.z)*(a.z-b.z));
        assert(abs(d - G) < 1e-5f, "gap>0: seam lo/hi separated by exactly G");
    }
    // The two cap polys (the last 2 created faces) are full-area quads in the
    // loop's plane in BOTH cases (unlike the pre-0261 zero-area bridging quads).
    // At gap=0 the two caps are COINCIDENT (same centroid); at gap=G they are pulled
    // exactly G apart along the rail — the real visible band the reference opens.
    assert(nfG.length >= 2, "gap>0: cap faces reported as new polys");
    uint capA = nfG[$ - 2], capB = nfG[$ - 1];
    Vec3 zc0 = faceCentroid(z, capA), zc1 = faceCentroid(z, capB);
    float dZero = (zc0 - zc1).length;
    assert(dZero < 1e-6f, "gap=0: the two shell caps are coincident");
    Vec3 gc0 = faceCentroid(g, capA), gc1 = faceCentroid(g, capB);
    float dGap = (gc0 - gc1).length;
    assert(abs(dGap - G) < 1e-5f, "gap>0: the two shell caps pulled exactly G apart");
}

// insertEdgeLoopsMulti — Preserve Curvature guard (task 0254). A CURVED open strip
// of 3 quads whose column heights arc h=[0,1,1,0]; seed = the middle quad's top
// long edge (2,4), giving a 1-face open ring that cuts Q1's two long rails (both at
// y=1, but curved — their cage neighbours drop to y=0 on each side). With curvature
// OFF (default) each new loop vert is the LINEAR chord midpoint (y=1.0 exactly).
// With curvature ON it is placed on the chord-weighted Catmull-Rom spline through the
// four cage points P0=(0,0,*),va,vb,P3=(3,0,*): at t=0.5 the spline bulges the flat
// chord UP to y=1+(√2−1)/4=1.1035534 (LIVE-corrected, task 0263; x/z unchanged) —
// measurably off the chord. Topology is identical
// either way (Curvature relocates the new verts only). A FLAT strip (heights all 0)
// proves ON is a no-op there: the four spline points are collinear ⇒ spline == chord.
unittest {
    import std.math : abs;
    static bool hasV(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x-p.x) < eps && abs(v.y-p.y) < eps && abs(v.z-p.z) < eps)
                return true;
        return false;
    }
    static Mesh makeArcStrip(float h1, float h2) {
        // Columns at x=0..3, rows z=0/1, column heights [0, h1, h2, 0].
        Mesh m;
        m.vertices = [
            Vec3(0,0,0),  Vec3(0,0,1),
            Vec3(1,h1,0), Vec3(1,h1,1),
            Vec3(2,h2,0), Vec3(2,h2,1),
            Vec3(3,0,0),  Vec3(3,0,1),
        ];
        m.addFace([0u,2u,3u,1u]);   // Q0 (cols 0-1)
        m.addFace([2u,4u,5u,3u]);   // Q1 (cols 1-2) — the cut face
        m.addFace([4u,6u,7u,5u]);   // Q2 (cols 2-3)
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }

    // curvature OFF (default) — linear chord midpoints at y=1.0.
    Mesh off = makeArcStrip(1.0f, 1.0f);
    uint eiOff = off.edgeIndex(2, 4);
    assert(eiOff != ~0u, "seed edge (2,4) must exist");
    uint[] nfOff;
    assert(sliceOnce!insertEdgeLoopsMulti(off, [eiOff], [0.5f], nfOff, null, false, false,
                                    false, false, null, 0.0f, /*curvature*/false),
           "curvature-off insert must succeed");
    assert(off.vertices.length == 10, "off: 8 + 2 midpoints = 10 verts");
    assert(off.edges.length    == 13, "off: 13 edges");
    assert(off.faces.length    == 4,  "off: Q0 + Q1×2 + Q2 = 4 faces");
    assert(hasV(off, Vec3(1.5f, 1.0f, 0)), "off: rail (2,4) midpoint on the flat chord (y=1)");
    assert(hasV(off, Vec3(1.5f, 1.0f, 1)), "off: rail (3,5) midpoint on the flat chord (y=1)");
    assert(!hasV(off, Vec3(1.5f, 1.1035534f, 0)), "off: no bulged vert (linear placement)");

    // curvature ON — chord-weighted Catmull-Rom spline bulges the midpoints to
    // y=1+(√2−1)/4=1.1035534 (LIVE-captured reference value, task 0263).
    Mesh on = makeArcStrip(1.0f, 1.0f);
    uint eiOn = on.edgeIndex(2, 4);
    uint[] nfOn;
    assert(sliceOnce!insertEdgeLoopsMulti(on, [eiOn], [0.5f], nfOn, null, false, false,
                                   false, false, null, 0.0f, /*curvature*/true),
           "curvature-on insert must succeed");
    // Topology IDENTICAL to the off case (curvature relocates verts only).
    assert(on.vertices.length == 10 && on.edges.length == 13 && on.faces.length == 4,
           "on: topology identical to curvature-off (positions only)");
    assert(hasV(on, Vec3(1.5f, 1.1035534f, 0)), "on: rail (2,4) midpoint bulged off the chord to y=1.1035534");
    assert(hasV(on, Vec3(1.5f, 1.1035534f, 1)), "on: rail (3,5) midpoint bulged off the chord to y=1.1035534");
    assert(!hasV(on, Vec3(1.5f, 1.0f, 0)), "on: chord midpoint replaced by the bulged spline point");

    // Tension (task 0255) scales the bulge: result = lerp + tension·(spline − lerp).
    // At tension=1.0 the bulge is the full 1.1035534 (above); at tension=0.5 it is
    // halfway between the flat chord (1.0) and the full spline ⇒ y=1.0517767; at
    // tension=0.0 it collapses to the linear chord (y=1.0) — byte-for-byte the
    // curvature-OFF placement even though `curvature` is ON.
    Mesh half = makeArcStrip(1.0f, 1.0f);
    uint eiHalf = half.edgeIndex(2, 4);
    uint[] nfHalf;
    assert(sliceOnce!insertEdgeLoopsMulti(half, [eiHalf], [0.5f], nfHalf, null, false, false,
                                     false, false, null, 0.0f, /*curvature*/true,
                                     /*curveTension*/0.5f),
           "curvature-on tension=0.5 insert must succeed");
    assert(hasV(half, Vec3(1.5f, 1.0517767f, 0)), "tension=0.5: rail (2,4) midpoint at the half bulge (y=1.0517767)");
    assert(hasV(half, Vec3(1.5f, 1.0517767f, 1)), "tension=0.5: rail (3,5) midpoint at the half bulge (y=1.0517767)");

    Mesh zero = makeArcStrip(1.0f, 1.0f);
    uint eiZero = zero.edgeIndex(2, 4);
    uint[] nfZero;
    assert(sliceOnce!insertEdgeLoopsMulti(zero, [eiZero], [0.5f], nfZero, null, false, false,
                                     false, false, null, 0.0f, /*curvature*/true,
                                     /*curveTension*/0.0f),
           "curvature-on tension=0.0 insert must succeed");
    assert(hasV(zero, Vec3(1.5f, 1.0f, 0)) && hasV(zero, Vec3(1.5f, 1.0f, 1)),
           "tension=0.0: curvature ON collapses to the linear chord (y=1.0)");
    assert(!hasV(zero, Vec3(1.5f, 1.1035534f, 0)), "tension=0.0: no bulge");

    // curvature ON on a FLAT cage (all heights 0) — the four spline points are
    // collinear, so the spline equals the linear chord: no-op vs off.
    Mesh flat = makeArcStrip(0.0f, 0.0f);
    uint eiFlat = flat.edgeIndex(2, 4);
    uint[] nfFlat;
    assert(sliceOnce!insertEdgeLoopsMulti(flat, [eiFlat], [0.5f], nfFlat, null, false, false,
                                     false, false, null, 0.0f, /*curvature*/true),
           "curvature-on flat-cage insert must succeed");
    assert(hasV(flat, Vec3(1.5f, 0, 0)) && hasV(flat, Vec3(1.5f, 0, 1)),
           "flat cage: curvature ON leaves the midpoints on the (straight) chord");
}

// insertEdgeLoopsMulti — 1D profile cutter (task 0256). A FLAT strip of 3 quads
// in the XZ plane (all normal +Y); seed = the middle quad's rail edge (2,4).
// Feeding a Vee profile (3 loops at along-cut fractions t=[0.25,0.5,0.75] with
// normalized heights h=[0.5,1.0,0.5]) and Inset depth D presses a V into the
// surface: each rail midpoint at fraction t is lifted along +Y by h·D. With
// profileHeights=null (flat, default) the same 3 positions stay ON the surface
// (byte-for-byte the multi-loop flat cut). With depth=0 a non-flat profile is
// ALSO a no-op (loops stay on the surface). Topology is identical in every case
// (3 loops ⇒ same vert/edge/face counts) — profile relocates verts only.
unittest {
    import std.math : abs;
    static bool hasV(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x-p.x) < eps && abs(v.y-p.y) < eps && abs(v.z-p.z) < eps)
                return true;
        return false;
    }
    static Mesh makeFlatStrip() {
        // Columns x=0..3, rows z=0/1, all y=0 (planar, normal +Y).
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(0,0,1),
            Vec3(1,0,0), Vec3(1,0,1),
            Vec3(2,0,0), Vec3(2,0,1),
            Vec3(3,0,0), Vec3(3,0,1),
        ];
        m.addFace([0u,2u,3u,1u]);   // Q0
        m.addFace([2u,4u,5u,3u]);   // Q1 — the cut face
        m.addFace([4u,6u,7u,5u]);   // Q2
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }
    immutable float[] posV = [0.25f, 0.5f, 0.75f];   // along-cut sample fractions
    immutable float[] hV   = [0.5f, 1.0f, 0.5f];     // Vee heights (normalized)

    // Baseline: same 3 loops, NO profile (flat) — every loop on the surface (y=0).
    Mesh flat = makeFlatStrip();
    uint eiF = flat.edgeIndex(2, 4);
    assert(eiF != ~0u, "seed edge (2,4) must exist");
    uint[] nfF;
    assert(sliceOnce!insertEdgeLoopsMulti(flat, [eiF], posV, nfF, null, false, false,
                                     false, false, null, 0.0f, false, 1.0f,
                                     /*profileHeights*/null, /*depth*/0.0f),
           "flat profile (null heights) insert must succeed");
    immutable fV = flat.vertices.length, fE = flat.edges.length, fF = flat.faces.length;
    // Q1's rail (2,4) runs x=1→2 at z=0; three loops at x=1.25/1.5/1.75, all y=0.
    assert(hasV(flat, Vec3(1.25f, 0, 0)) && hasV(flat, Vec3(1.5f, 0, 0)) && hasV(flat, Vec3(1.75f, 0, 0)),
           "flat: 3 loops sit on the surface (y=0)");

    // Vee profile, depth D=2. Q1's geometric normal is -Y (the strip is wound so
    // faceNormal([2,4,5,3]) = (0,-1,0)), so heights [0.5,1,0.5]·D press the loops
    // DOWN by y = [-1,-2,-1] along that surface normal. The MECHANISM uses the true
    // per-rail normal — the sign follows the winding, not an assumed "up".
    Mesh vee = makeFlatStrip();
    uint eiV = vee.edgeIndex(2, 4);
    uint[] nfV;
    assert(sliceOnce!insertEdgeLoopsMulti(vee, [eiV], posV, nfV, null, false, false,
                                    false, false, null, 0.0f, false, 1.0f,
                                    /*profileHeights*/hV, /*depth*/2.0f),
           "vee profile insert must succeed");
    // Topology IDENTICAL to the flat baseline (profile relocates verts only).
    assert(vee.vertices.length == fV && vee.edges.length == fE && vee.faces.length == fF,
           "vee: topology identical to the flat baseline (positions only)");
    // Rail (2,4) at z=0: x=1.25→y=-1, x=1.5→y=-2 (the vee apex), x=1.75→y=-1.
    assert(hasV(vee, Vec3(1.25f, -1.0f, 0)), "vee: t=0.25 loop inset h·D = 0.5·2 = 1 (along -Y normal)");
    assert(hasV(vee, Vec3(1.5f,  -2.0f, 0)), "vee: t=0.50 apex inset h·D = 1.0·2 = 2");
    assert(hasV(vee, Vec3(1.75f, -1.0f, 0)), "vee: t=0.75 loop inset h·D = 0.5·2 = 1");
    assert(hasV(vee, Vec3(1.25f, -1.0f, 1)), "vee: the z=1 rail (3,5) insets identically");
    assert(!hasV(vee, Vec3(1.5f, 0, 0)), "vee: the apex loop is no longer on the surface");

    // depth=0 with a non-flat profile is a no-op (loops stay on the surface).
    Mesh d0 = makeFlatStrip();
    uint eiD = d0.edgeIndex(2, 4);
    uint[] nfD;
    assert(sliceOnce!insertEdgeLoopsMulti(d0, [eiD], posV, nfD, null, false, false,
                                   false, false, null, 0.0f, false, 1.0f,
                                   /*profileHeights*/hV, /*depth*/0.0f),
           "depth=0 profile insert must succeed");
    assert(hasV(d0, Vec3(1.5f, 0, 0)) && !hasV(d0, Vec3(1.5f, -2.0f, 0)),
           "depth=0: non-flat profile leaves every loop on the surface");
}

// (d) Grid equivalence oracle (task 0239 owner objection #2): a plain unit
// cube has exactly 2 perpendicular closed rings crossing at 2 shared faces —
// seed edge (0,1) (the horizontal "equatorial" belt, established above) and
// seed edge (0,4) (the vertical belt) share faces F4=[3,7,6,2] (Top) and
// F5=[0,1,5,4] (Bottom). insertEdgeLoopsMulti must GRID-split those two
// shared faces. The oracle: compare against applying the SAME two single-
// ring inserts SEQUENTIALLY (ring A via insertEdgeLoops, then re-finding the
// vertical seed on the mutated mesh and inserting ring B) — this is a
// stronger check than a count-only comparison because a winding/corner-
// reconciliation flip could preserve counts while producing the WRONG
// sub-quad shapes; comparing actual VERTEX POSITIONS (order-independent)
// catches that.
unittest {
    import std.math : abs;

    static bool hasVertNear(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x - p.x) < eps && abs(v.y - p.y) < eps && abs(v.z - p.z) < eps)
                return true;
        return false;
    }

    // --- Grid path: one insertEdgeLoopsMulti call, both seeds together.
    Mesh grid = makeCube();
    uint eiHoriz = grid.edgeIndex(0, 1);
    uint eiVert  = grid.edgeIndex(0, 4);
    assert(eiHoriz != ~0u && eiVert != ~0u, "both cube seeds must exist");
    uint[] gridNewFaces;
    bool okGrid = sliceOnce!insertEdgeLoopsMulti(grid, [eiHoriz, eiVert], [0.3f, 0.7f], gridNewFaces);
    assert(okGrid, "grid insertEdgeLoopsMulti must succeed on the cube");

    // --- Sequential path: ring A alone, then re-find ring B's seed (the
    //     vertical edges are never touched by ring A's rails — see the
    //     kernel doc comment — so edgeIndex(0,4) is still valid post-cut).
    Mesh seq = makeCube();
    uint eiHoriz2 = seq.edgeIndex(0, 1);
    bool okA = sliceOnce!insertEdgeLoops(seq, eiHoriz2, [0.3f, 0.7f]);
    assert(okA, "sequential ring-A insert must succeed");
    uint eiVert2 = seq.edgeIndex(0, 4);
    assert(eiVert2 != ~0u, "vertical seed edge 0-4 must survive ring-A's cut");
    bool okB = sliceOnce!insertEdgeLoops(seq, eiVert2, [0.3f, 0.7f]);
    assert(okB, "sequential ring-B insert must succeed");

    // Equivalence: identical V/E/F counts...
    assert(grid.vertices.length == seq.vertices.length,
           "grid vs sequential: vertex counts differ");
    assert(grid.edges.length == seq.edges.length,
           "grid vs sequential: edge counts differ");
    assert(grid.faces.length == seq.faces.length,
           "grid vs sequential: face counts differ");

    // ...and every vertex position in the grid result has a coincident
    // match in the sequential result (order-independent) — proves the grid
    // split lands vertices at EXACTLY the same points a sequential two-pass
    // insert would, catching a winding/reconciliation flip that a count-only
    // check would miss.
    foreach (v; grid.vertices)
        assert(hasVertNear(seq, v),
               "grid vertex has no coincident match in the sequential result");

    // No degenerate sub-quad: every face must be a quad with 4 DISTINCT
    // vertex indices, and the mesh must still be a closed manifold (Euler
    // V-E+F=2) — `rebuildEdges`/`buildLoops` would otherwise have silently
    // produced a non-manifold mess.
    foreach (const f; grid.faces) {
        assert(f.length == 4, "grid split must only ever produce quads");
        assert(f[0] != f[1] && f[1] != f[2] && f[2] != f[3] && f[3] != f[0]
               && f[0] != f[2] && f[1] != f[3],
               "grid split must not produce a degenerate (repeated-vertex) sub-quad");
    }
    assert(cast(int)grid.vertices.length - cast(int)grid.edges.length
           + cast(int)grid.faces.length == 2,
           "grid-split result must still satisfy Euler's formula (closed manifold)");
}

// Task 0389: insertEdgeLoopsMulti (loop_slice's kernel) must not drop the
// per-face Subpatch bit — neither on faces it dups untouched nor on the new
// sub-quads a ring split emits. Uses the SAME closed-ring cube fixture as
// unittest (A) above (seed edge 0-1), but this time with ONE ring face
// marked Subpatch and its immediate ring neighbour left plain, so the test
// proves per-source INHERITANCE (not just a blanket true/false leak).
unittest {
    import std.math : abs;

    static bool hasFace(const Mesh m, uint[] vs) {
        outer: foreach (const f; m.faces) {
            if (f.length != vs.length) continue;
            foreach (v; vs) {
                bool found = false;
                foreach (fv; f) if (fv == v) { found = true; break; }
                if (!found) continue outer;
            }
            return true;
        }
        return false;
    }
    static uint findFaceIndexBySet(const Mesh m, uint[] vs) {
        outer: foreach (fi, const f; m.faces) {
            if (f.length != vs.length) continue;
            foreach (v; vs) {
                bool found = false;
                foreach (fv; f) if (fv == v) { found = true; break; }
                if (!found) continue outer;
            }
            return cast(uint)fi;
        }
        return ~0u;
    }
    static uint findVertNear(const Mesh m, float x, float y, float z,
                             float eps = 1e-4f) {
        foreach (uint i; 0 .. cast(uint)m.vertices.length) {
            auto v = m.vertices[i];
            if (abs(v.x - x) < eps && abs(v.y - y) < eps && abs(v.z - z) < eps)
                return i;
        }
        return ~0u;
    }

    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();   // size faceMarks — makeCube/addFace leave it empty

    // F0 = faces[0] = [0,3,2,1] (bottom) marked Subpatch; every other face
    // (including its ring neighbour F5 = faces[5] = [0,1,5,4], sharing the
    // seed edge 0-1) is left plain.
    m.setFaceSubpatch(0, true);
    assert(m.isFaceSubpatch(0), "F0 must be marked Subpatch before the cut");
    assert(!m.isFaceSubpatch(5), "F5 must start plain");

    uint eiSeed = m.edgeIndex(0, 1);
    assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");
    bool ok = sliceOnce!insertEdgeLoops(m, eiSeed, [0.5f]);
    assert(ok, "insertEdgeLoops must succeed on cube");
    assert(m.faces.length == 10, "cube ring cut must still produce 10 faces");

    // Untouched cap faces F2=[0,4,7,3] and F3=[1,2,6,5] (outside the ring,
    // dup'd as-is) must keep their own (unset) bit.
    uint f2i = findFaceIndexBySet(m, [0u, 4u, 7u, 3u]);
    uint f3i = findFaceIndexBySet(m, [1u, 2u, 6u, 5u]);
    assert(f2i != ~0u && f3i != ~0u, "cap faces F2/F3 must survive the cut unchanged");
    assert(!m.isFaceSubpatch(f2i), "untouched cap face F2 must stay non-subpatch");
    assert(!m.isFaceSubpatch(f3i), "untouched cap face F3 must stay non-subpatch");

    // Rail midpoints — same geometry as unittest (A) above.
    uint mA = findVertNear(m, 0.0f, -0.5f, -0.5f); // mid of edge 0-1 (shared F0/F5 rail)
    uint mB = findVertNear(m, 0.0f,  0.5f, -0.5f); // mid of edge 2-3 (F0's other rail)
    uint mD = findVertNear(m, 0.0f, -0.5f,  0.5f); // mid of edge 4-5 (F5's other rail)
    assert(mA != ~0u && mB != ~0u && mD != ~0u, "rail midpoints must exist");

    // F0's two sub-quads must BOTH inherit F0's Subpatch=true.
    assert(hasFace(m, [0u, mA, mB, 3u]) && hasFace(m, [mA, 1u, 2u, mB]),
           "F0 must split into its two expected sub-quads");
    uint f0aI = findFaceIndexBySet(m, [0u, mA, mB, 3u]);
    uint f0bI = findFaceIndexBySet(m, [mA, 1u, 2u, mB]);
    assert(m.isFaceSubpatch(f0aI) && m.isFaceSubpatch(f0bI),
           "both of F0's new sub-quads must inherit Subpatch=true from F0");

    // F5's two sub-quads (its neighbour across the shared rail, plain) must
    // BOTH stay Subpatch=false — proves inheritance is per-SOURCE-face, not
    // a blanket flip from the one marked ring face.
    assert(hasFace(m, [0u, mA, mD, 4u]) && hasFace(m, [mA, 1u, 5u, mD]),
           "F5 must split into its two expected sub-quads");
    uint f5aI = findFaceIndexBySet(m, [0u, mA, mD, 4u]);
    uint f5bI = findFaceIndexBySet(m, [mA, 1u, 5u, mD]);
    assert(!m.isFaceSubpatch(f5aI) && !m.isFaceSubpatch(f5bI),
           "both of F5's new sub-quads must stay Subpatch=false (F5 was plain)");
}

// Task 0389: bevelEdgesByMask — the chamfer quad inherits Subpatch via OR
// of the TWO faces adjacent to the beveled edge. Same cube-edge (6,7)
// fixture as the bevelEdgesByMask cube-edge unittest elsewhere in this file:
// edge (6,7) is shared by faces[1]=[4,5,6,7] (+Z) and faces[4]=[3,7,6,2] (+Y).
unittest {
    static int findEdge(ref Mesh m, uint va, uint vb) {
        foreach (i; 0 .. m.edges.length) {
            uint a = m.edges[i][0], b = m.edges[i][1];
            if ((a == va && b == vb) || (a == vb && b == va)) return cast(int)i;
        }
        return -1;
    }
    static uint firstSelectedFace(ref Mesh m) {
        foreach (fi; 0 .. m.faces.length) if (m.isFaceSelected(fi)) return cast(uint)fi;
        return uint.max;
    }

    // Neither adjacent face marked ⇒ the chamfer must stay non-subpatch.
    {
        Mesh m = makeCube();
        m.buildLoops();
        m.resetSelection();
        int ei = findEdge(m, 6, 7);
        assert(ei >= 0, "edge (6,7) must exist");
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");
        uint chamferFi = firstSelectedFace(m);
        assert(chamferFi != uint.max, "chamfer face must be selected after bevel");
        assert(!m.isFaceSubpatch(chamferFi),
               "chamfer must stay non-subpatch when neither neighbour was marked");
    }

    // Exactly ONE adjacent face marked (faces[1] = [4,5,6,7], the +Z
    // neighbour) ⇒ OR still produces a Subpatch chamfer, proving inheritance
    // is per-source (not requiring both sides marked).
    {
        Mesh m = makeCube();
        m.buildLoops();
        m.resetSelection();
        m.setFaceSubpatch(1, true);   // faces[1] = [4,5,6,7], the +Z neighbour
        assert(!m.isFaceSubpatch(4), "faces[4] (+Y neighbour) must start plain");
        int ei = findEdge(m, 6, 7);
        assert(ei >= 0, "edge (6,7) must exist");
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");
        uint chamferFi = firstSelectedFace(m);
        assert(chamferFi != uint.max, "chamfer face must be selected after bevel");
        assert(m.isFaceSubpatch(chamferFi),
               "chamfer must inherit Subpatch via OR when only ONE neighbour was marked");
    }
}

// Task 0389: insetFacesByMask — the inner face already kept its bit
// in-place (faces[fi] reassigned, not the marks word); the new ring quads
// must ALSO inherit Subpatch from the inset source face, in both directions
// (not a blanket true/false leak).
unittest {
    static Mesh makeFlatQuad() {
        Mesh m;
        m.vertices = [
            Vec3(-0.5f, 0f, -0.5f), Vec3(0.5f, 0f, -0.5f),
            Vec3(0.5f, 0f,  0.5f),  Vec3(-0.5f, 0f, 0.5f),
        ];
        m.addFace([0, 1, 2, 3]);
        m.buildLoops();
        return m;
    }
    bool[] allOne = [true];

    // Source marked Subpatch=true ⇒ inner AND all 4 ring quads inherit true.
    {
        Mesh m = makeFlatQuad();
        m.resetSelection();
        m.setFaceSubpatch(0, true);
        assert(polyBevelOnce!insetFacesByMask(m, allOne, 0.1f) == 1, "must process 1 face");
        assert(m.faces.length == 5, "expected 1 inner + 4 ring quads");
        foreach (fi; 0 .. m.faces.length)
            assert(m.isFaceSubpatch(fi),
                   "every face (inner + ring) must be Subpatch when the source was");
    }

    // Source left plain ⇒ inner AND ring quads all stay non-subpatch.
    {
        Mesh m = makeFlatQuad();
        m.resetSelection();
        assert(polyBevelOnce!insetFacesByMask(m, allOne, 0.1f) == 1, "must process 1 face");
        assert(m.faces.length == 5, "expected 1 inner + 4 ring quads");
        foreach (fi; 0 .. m.faces.length)
            assert(!m.isFaceSubpatch(fi),
                   "no face should be Subpatch when the source was plain");
    }
}

// Task 0389: extrudeFacesByMask — the cap already inherited (pre-existing);
// the 4 side walls must ALSO inherit Subpatch from the extruded source face.
// Same single-face-extrude fixture as the extrudeFacesByMask unittest
// elsewhere in this file (cube face 0, distance 0.5 → 5 orig + 1 cap + 4
// walls = 10 faces).
unittest {
    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();
    m.setFaceSubpatch(0, true);
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
    size_t n = m.extrudeFacesByMask(mask, 0.5f);
    assert(n > 0, "extrudeFacesByMask must succeed");
    assert(m.faces.length == 10, "expected 10 faces after single-face extrude");

    size_t subCount = 0, plainCount = 0;
    foreach (fi; 0 .. m.faces.length) {
        if (m.isFaceSubpatch(fi)) ++subCount; else ++plainCount;
    }
    // 5 non-selected originals stay plain; cap + 4 walls (all derived from
    // the ONE Subpatch-marked source face) all become Subpatch.
    assert(subCount == 5, "cap + 4 walls (5 faces) must all inherit Subpatch");
    assert(plainCount == 5, "the 5 untouched original faces must stay plain");
}

// (e) Degenerate seed among valid ones: a seed whose collectEdgeRing is
// empty (non-quad-adjacent) must be silently skipped, WITHOUT blocking the
// other valid seed's ring from being cut; if EVERY seed is degenerate, the
// call is a no-op (false, no mutation).
unittest {
    // One valid cube seed + one triangle-adjacent (non-quad) seed sharing
    // NO faces with the cube — the mixed-valence fixture from the
    // `collectEdgeRing` non-quad-guard unittest just below, merged with a
    // disjoint cube.
    Mesh m = makeCube();
    // Triangulate F2=[0,4,7,3] (Left face — NOT part of the (0,1) BeltX
    // ring) by hand: split it into two triangles sharing diagonal 0-7.
    uint[][] withTri = m.faces.dup;
    withTri[2] = [0u, 4u, 7u];          // shrink F2 to a triangle
    withTri ~= [0u, 7u, 3u];            // the other half as a 2nd triangle
    m.faces = withTri;
    m.rebuildEdges();
    m.buildLoops();

    uint eiValid = m.edgeIndex(0, 1);          // still a valid BeltX seed
    uint eiDegenerate = m.edgeIndex(0, 7);     // now triangle-adjacent
    assert(eiValid != ~0u, "valid seed edge must exist");
    assert(eiDegenerate != ~0u, "degenerate seed edge must exist");

    bool closedDegenerate;
    assert(m.collectEdgeRing(eiDegenerate, closedDegenerate).length == 0,
           "sanity: the degenerate seed's ring must indeed be empty");

    uint[] newFaceIndices;
    bool ok = sliceOnce!insertEdgeLoopsMulti(m, [eiValid, eiDegenerate], [0.5f], newFaceIndices);
    assert(ok, "one valid + one degenerate seed must still succeed (valid seed's ring cut)");
    assert(m.vertices.length == 12, "valid seed's ring must still be cut (V=12, as single-seed)");
    // F=11: the base cube's single-seed cut gives F=10 (see the closed-ring
    // unittest above); triangulating F2 into 2 triangles (replacing 1 quad)
    // adds exactly 1 extra face on top of that, and F2/its 2 triangles sit
    // OUTSIDE the BeltX ring so they pass through untouched.
    assert(m.faces.length == 11, "valid seed's ring must still be cut (F=11 = 10 + 1 extra tri)");

    // All-degenerate: no-op.
    Mesh m2 = makeCube();
    uint[][] withTri2 = m2.faces.dup;
    withTri2[2] = [0u, 4u, 7u];
    withTri2 ~= [0u, 7u, 3u];
    m2.faces = withTri2;
    m2.rebuildEdges();
    m2.buildLoops();
    uint eiDeg2 = m2.edgeIndex(0, 7);
    assert(eiDeg2 != ~0u);
    uint vBefore = cast(uint)m2.vertices.length;
    uint eBefore = cast(uint)m2.edges.length;
    uint fBefore = cast(uint)m2.faces.length;
    uint[] unused;
    bool okAll = sliceOnce!insertEdgeLoopsMulti(m2, [eiDeg2], [0.5f], unused);
    assert(!okAll, "all-degenerate seed set must return false");
    assert(m2.vertices.length == vBefore && m2.edges.length == eBefore
           && m2.faces.length == fBefore, "all-degenerate call must not mutate the mesh");
}

unittest {
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0), Vec3(0.5f,2,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);   // quad
    m.addFace([2u, 1u, 4u]);       // triangle — shares edge 1-2 with the quad
    m.buildLoops();

    uint eiSeed = m.edgeIndex(1, 2);
    assert(eiSeed != ~0u, "edge 1-2 must exist in the mixed-valence mesh");

    // TASK 1240 REVERSED THIS BLOCK (ledger rows 27/53). It used to require
    // `collectEdgeRing` to return [] here, because a non-quad on the seed edge
    // would leave a T-junction. The absorb pass has answered that since the
    // watertight-by-default change — it already spliced the terminating
    // midpoint into whatever non-quad the walk stopped at MID-ring — so the
    // seed was the last place still refusing, and the reference cuts here.
    // The ring is now collected from the QUAD side only: one entry, open.
    bool closed;
    auto ring = m.collectEdgeRing(eiSeed, closed);
    assert(ring.length == 1,
           "collectEdgeRing must collect the quad side of a quad+triangle seed");
    assert(!closed, "a ring that starts beside a non-quad is always open");
    assert(m.faces[ring[0].fi].length == 4,
           "the collected ring entry must be the QUAD, never the triangle");

    // insertEdgeLoops cuts the quad and the triangle absorbs the midpoint.
    bool ok = sliceOnce!insertEdgeLoops(m, eiSeed, [0.5f]);
    assert(ok, "insertEdgeLoops must now cut a triangle-adjacent seed");
    assert(m.vertices.length == 7, "expected 7 verts after the cut");
    assert(m.edges.length    == 9, "expected 9 edges after the cut");
    assert(m.faces.length    == 3, "expected 3 faces after the cut");
    // Watertight: the triangle took the seed midpoint into its own ring, so
    // nothing is left at arity 3.
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 4,
               "every face must be a quad after the absorb — a surviving "
               ~ "triangle would mean a T-junction on the seed edge");
}

// Task 1240 — the refusal that SURVIVED: no quad on EITHER side of the seed.
// There is no quad frame to take the p/q rails from, and nothing measured says
// what should happen, so this stays a no-op. Without this block the relaxation
// above would read as "any seed cuts", which is not what was implemented.
unittest {
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]);
    m.buildLoops();

    uint eiSeed = m.edgeIndex(0, 2);       // shared by the two triangles
    assert(eiSeed != ~0u, "edge 0-2 must exist");

    bool closed;
    assert(m.collectEdgeRing(eiSeed, closed).length == 0,
           "collectEdgeRing must still return [] when NO quad borders the seed");

    uint vBefore = cast(uint)m.vertices.length;
    uint eBefore = cast(uint)m.edges.length;
    uint fBefore = cast(uint)m.faces.length;
    assert(!sliceOnce!insertEdgeLoops(m, eiSeed, [0.5f]),
           "insertEdgeLoops must return false with no quad on the seed");
    assert(m.vertices.length == vBefore, "vertex count must not change");
    assert(m.edges.length    == eBefore, "edge count must not change");
    assert(m.faces.length    == fBefore, "face count must not change");
}

// S4/S5 code review (task 0613 §4.2): the section cap's multi-source Hide
// combine is ALL-source AND (Mesh.combineFaceMarksWords), not the ANY-source
// OR that Subpatch still (correctly) uses. Fixture: makeCube(), seed edge
// (0,1) with Split+Caps on (same seed as the byte-identical "Split ON, caps
// ON" fixture above). Empirically confirmed (by inspecting the split-only,
// caps-off result) that this seed's ring is the FOUR faces
// {0:[0,3,2,1](-Z), 1:[4,5,6,7](+Z), 4:[3,7,6,2](+Y), 5:[0,1,5,4](-Y)} —
// each split into two fragments — while {2:[0,4,7,3](-X), 3:[1,2,6,5](+X)}
// stay whole (not ring faces, one per shell). Both new caps fold their word
// from the SAME `perFaceRings` set, so this fixture drives both caps at once.
unittest { // S4/S5 — ONE ring face hidden, three visible: caps must be VISIBLE.
    // Discriminator: an ANY-source OR would read both caps as hidden (one
    // ring face was); the correct ALL-source AND reads them as visible (not
    // every ring face was) — the same law §1.2 uses to derive a vertex's
    // hidden state from its incident faces.
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.setFaceHidden(0, true);   // ring face -Z only
    assert(!m.isFaceHidden(1) && !m.isFaceHidden(4) && !m.isFaceHidden(5),
        "the other three ring faces must stay visible");

    uint ei = m.edgeIndex(0, 1);
    uint[] nf;
    assert(sliceOnce!insertEdgeLoopsMulti(m, [ei], [0.5f], nf, null, false, false,
                                   /*split*/true, /*caps*/true),
        "split-on caps-on insert must succeed");

    // The 2 cap faces are the newly-appended tail entries (Select-New's own
    // convention, confirmed by the byte-identical fixture above:
    // "caps on: 2 extra new faces vs caps-off").
    assert(nf.length >= 2, "expected at least the 2 cap faces among the new faces");
    immutable uint cap0 = nf[$ - 2], cap1 = nf[$ - 1];
    assert(!m.isFaceHidden(cap0) && !m.isFaceHidden(cap1),
        "S5: section caps must be VISIBLE when only ONE of the ring's four "
        ~ "source faces was hidden (ALL-source AND, not ANY-source OR)");
}

unittest { // S4/S5 companion — ALL FOUR ring faces hidden: caps must still
    // be HIDDEN. Proves the AND rule actually ANDs instead of degenerating
    // to "never hidden" (which would pass the row above but fail this one).
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.setFaceHidden(0, true);
    m.setFaceHidden(1, true);
    m.setFaceHidden(4, true);
    m.setFaceHidden(5, true);

    uint ei = m.edgeIndex(0, 1);
    uint[] nf;
    assert(sliceOnce!insertEdgeLoopsMulti(m, [ei], [0.5f], nf, null, false, false,
                                   /*split*/true, /*caps*/true),
        "split-on caps-on insert must succeed");

    assert(nf.length >= 2, "expected at least the 2 cap faces among the new faces");
    immutable uint cap0 = nf[$ - 2], cap1 = nf[$ - 1];
    assert(m.isFaceHidden(cap0) && m.isFaceHidden(cap1),
        "S5 companion: section caps must be HIDDEN when ALL FOUR ring source "
        ~ "faces were");
}

// ---------------------------------------------------------------------------
// Task 1054 U2/U3 — the selection-band walk (Phase 2, doc/
// loop_slice_corner_plan.md §1/§3.1/§3.2/§6). `bandWalk` is a PURE function
// (no `Mesh` coupling, not yet wired into any kernel — Phase 3), so these
// drive it directly with a literal face-ring table instead of building a
// full `Mesh`: `tests/unit/` cannot string-import `tests/fixtures/`
// (`dub.json` `stringImportPaths` is `assets/icon`/`assets/fonts` only), so
// this embeds a compact ~8-case table lifted from the 54-case corpus
// (`tools/local/fixture_gen/loop_slice_band/loop_slice_slice_selected_band.json`,
// private) rather than the whole thing — the full 54 run in the HTTP lane
// once the walk is wired in (Phase 3, F1/F2).
//
// `bandTestBasePolys` is NOT our own `prim.cube`'s output -- it is the
// reference's own base-mesh dump for the same primitive parameters
// (`prim.cube segmentsX:3 segmentsY:1 segmentsZ:3 sizeX:1 sizeY:1 sizeZ:1
// sharp:true radius:0`, same argstring as
// `tests/fixtures/loop_slice_corner.json:24-27`), embedded here as ring
// topology only (vertex-index adjacency) since U2/U3 test chains and
// ring-edge-index side pairs, not the cut geometry (§1 step 4, which stays
// unwired) — so no vertex coordinates are needed either.
//
// CHECKED (task 1054 review), and the numbering does NOT correspond:
// vibe3d's own `prim.cube` with the identical argstring also lands on
// 32 V / 60 E / 30 F, but its face table is a different numbering
// entirely -- e.g. this file's faces 21/24/27/28/29 (the corpus's own "L"
// selection, see the `L` case below) are the reference's top-face L; the
// same five indices against vibe3d's own `prim.cube` output land on one
// top cell plus four side faces at y = 0. **Nothing in this file
// establishes an index correspondence between the two meshes.** Phase 3,
// when it wires `bandWalk` into a live kernel, must therefore key its own
// fixtures on GEOMETRY (vertex positions / face-set membership), exactly
// as `tests/fixtures/loop_slice_corner.json` already does, never on a
// face-index literal carried over from this table.
//
// Expected chains/side-pairs/edge-counts below were computed by re-running
// the plan's own predictor (its chain-ordering routine, plus the
// side-derivation half of its cut-point routine with the position-dependent
// cut math removed) against this same reference base mesh and selection --
// the same predictor independently verified to reproduce the full 54-case
// corpus 54/54 during planning (task 1054 reading). Not re-derived by hand.
private immutable(uint[])[] bandTestBasePolys = [
    [0, 1, 12, 11], [11, 12, 13, 10], [10, 13, 8, 9], [1, 2, 14, 12],
    [12, 14, 15, 13], [13, 15, 7, 8], [2, 3, 4, 14], [14, 4, 5, 15],
    [15, 5, 6, 7], [16, 17, 1, 0], [17, 18, 2, 1], [18, 19, 3, 2],
    [19, 20, 4, 3], [20, 21, 5, 4], [21, 22, 6, 5], [22, 23, 7, 6],
    [23, 24, 8, 7], [24, 25, 9, 8], [25, 26, 10, 9], [26, 27, 11, 10],
    [27, 16, 0, 11], [16, 27, 28, 17], [27, 26, 29, 28], [26, 25, 24, 29],
    [17, 28, 30, 18], [28, 29, 31, 30], [29, 24, 23, 31], [18, 30, 20, 19],
    [30, 31, 21, 20], [31, 23, 22, 21],
];

/// Canonical (unordered) vertex-pair key for face `fi`'s ring-edge `side`
/// (edge k = ring[k] -> ring[(k+1)%n]) — test-local mirror of the "shared
/// rail" identity check §3.2 describes, using `mesh.edgeKey` so it agrees
/// with the kernel's own canonicalisation.
private ulong bandCellEdgeKey(const(uint[])[] polys, uint fi, uint side) {
    auto ring = polys[fi];
    auto n = ring.length;
    return edgeKey(ring[side], ring[(side + 1) % n]);
}

unittest { // U2 — chains and (A,B) side pairs, ~8 cases spanning straight /
    // turn / closed / multi-chain / single-cell / backward-gate-used /
    // backward-gate-blocked / start-rule-fallback-runs (§2's own branch-
    // coverage table names each of these by corpus case).
    import mesh_ops.loop_slice : bandWalk, BandCell;
    import std.format : format;

    // straight cell run (A,B opposite) — corpus `row3`.
    {
        auto got = bandWalk(bandTestBasePolys, [21u, 24u, 27u]);
        assert(got == [[BandCell(21, 0, 2), BandCell(24, 0, 2), BandCell(27, 0, 2)]],
            format("row3: got %s", got));
    }

    // the turn cell (A,B adjacent) — corpus `L`, the frozen corner fixture's
    // own selection.
    {
        auto got = bandWalk(bandTestBasePolys, [21u, 24u, 27u, 28u, 29u]);
        assert(got == [[BandCell(21, 0, 2), BandCell(24, 0, 2), BandCell(27, 0, 1),
                         BandCell(28, 3, 1), BandCell(29, 3, 1)]],
            format("L: got %s", got));
    }

    // closed chain — corpus `b2x2` (a 2x2 block; every cell turns).
    {
        auto got = bandWalk(bandTestBasePolys, [21u, 24u, 22u, 25u]);
        assert(got == [[BandCell(21, 1, 2), BandCell(24, 0, 1),
                         BandCell(25, 3, 0), BandCell(22, 2, 3)]],
            format("b2x2: got %s", got));
    }

    // multi-chain — corpus `tee` (a T shape: a 3-cell stem plus one arm cell
    // that the list-order walk cannot fold into the same chain).
    {
        auto got = bandWalk(bandTestBasePolys, [22u, 25u, 28u, 24u]);
        assert(got == [[BandCell(22, 0, 2), BandCell(25, 0, 2), BandCell(28, 0, 2)],
                        [BandCell(24, 2, 0)]],
            format("tee: got %s", got));
    }

    // single-polygon chain — corpus `one_00` (both sides derived: B=0, A=n/2).
    {
        auto got = bandWalk(bandTestBasePolys, [25u]);
        assert(got == [[BandCell(25, 2, 0)]], format("one_00: got %s", got));
    }

    // backward extension USED — corpus `L_cornerfirst` (corner cell clicked
    // first; forward growth alone can't reach the whole L, so the backward
    // gate — forward chain >= 3 and not closed — fires).
    {
        auto got = bandWalk(bandTestBasePolys, [27u, 21u, 24u, 28u, 29u]);
        assert(got == [[BandCell(29, 1, 3), BandCell(28, 1, 3), BandCell(27, 1, 0),
                         BandCell(24, 2, 0), BandCell(21, 2, 0)]],
            format("L_cornerfirst: got %s", got));
    }

    // backward gate BLOCKED — corpus `L_p3_midfirst` (mid-row cell clicked
    // first; the forward-only chain never reaches 3 polygons before the
    // corner splits it into two chains, so backward extension never fires).
    {
        auto got = bandWalk(bandTestBasePolys, [24u, 29u, 21u, 28u, 27u]);
        assert(got == [[BandCell(24, 2, 0), BandCell(21, 2, 0)],
                        [BandCell(29, 1, 3), BandCell(28, 1, 3), BandCell(27, 1, 3)]],
            format("L_p3_midfirst: got %s", got));
    }

    // backward gate BLOCKED by `closed` specifically (task 1054 review
    // finding: this case did not exist before the review — none of the 8
    // cases above, nor the 54-case corpus, force `closed` to do anything;
    // replacing its computation with a constant `false` left every one of
    // them green). Selection [22,21,23,24,25]: the forward walk from seed
    // 22 closes a 4-cell ring (22,21,24,25) before cell 23 is ever
    // reached, so the "not closed" gate blocks 23 from being absorbed
    // backward into that ring -- 23 starts its own one-cell chain
    // instead. Verified by mutation: constant-`false`-ing `closed` merges
    // both into a single 5-cell chain `[23,22,21,24,25]`.
    {
        auto got = bandWalk(bandTestBasePolys, [22u, 21u, 23u, 24u, 25u]);
        assert(got == [
            [BandCell(22, 2, 3), BandCell(21, 1, 2), BandCell(24, 0, 1), BandCell(25, 3, 0)],
            [BandCell(23, 2, 0)],
        ], format("closed_gate_discriminator: got %s", got));
    }

    // start-rule fallback RUNS (§1.1(a)) — corpus `w3_all9scr`: all 9 cells
    // of the 3x3 block selected in a scrambled order; the first chain
    // consumes 8 of them as a closed ring, and the restart for the 9th
    // reaches the "no nb<2 candidate" fallback with a single remaining
    // candidate (so this pins that the branch RUNS and produces the right
    // chain, not which of two candidates it would prefer with a choice —
    // see the plan's §1.1(a)/R5 and this file's own doc comment on
    // `bandReorderByConnectivity`).
    {
        auto got = bandWalk(bandTestBasePolys,
            [25u, 27u, 23u, 26u, 28u, 21u, 29u, 22u, 24u]);
        assert(got == [
            [BandCell(27, 0, 1), BandCell(28, 3, 0), BandCell(25, 2, 1),
             BandCell(26, 3, 0), BandCell(23, 2, 3), BandCell(22, 1, 3),
             BandCell(21, 1, 2), BandCell(24, 0, 2)],
            [BandCell(29, 2, 0)],
        ], format("w3_all9scr: got %s", got));
    }

    // Mutations (per plan §5 Phase 2 validation; both actually run against
    // this file, see `bandChains`'s doc comment for the same split):
    //  - dropping the >= 3 backward-extension threshold (raised so it never
    //    fires) changes `L_cornerfirst`'s chain shape from one 5-cell chain
    //    to two split chains -- reddens the assert above.
    //  - constant-`false`-ing `closed` merges the discriminator case above
    //    (`[22,21,23,24,25]`) from two chains into one 5-cell chain --
    //    reddens that assert. This is the ONLY case in this file (or the
    //    54-case corpus) that discriminates it at all.
}

unittest { // U3 — shared-rail identity (§3.2) + open/closed cut-point count.
    // Cell i's entry edge B_i and cell i+1's exit edge A_{i+1} (within the
    // SAME chain) must resolve to the identical physical (undirected) edge
    // -- the manifold-winding invariant §3.2 names -- and a k-cell chain
    // must expose exactly k+1 distinct physical cut edges when open, k when
    // closed (watertight-by-construction, per §3.2's own count).
    //
    // STRUCTURAL, not discriminating (task 1054 review): every case here is
    // a STRICT SUBSET of U2's own selections, driven back through the same
    // `bandWalk`, so U3 cannot fail in a way U2's exact-chain asserts
    // wouldn't already catch first -- it re-derives the shared-rail
    // identity from `bandSideOf`'s own side derivation, so agreeing with
    // itself is close to a tautology for that half. What it adds beyond U2
    // is the DISTINCT-EDGE-COUNT invariant (open k -> k+1, closed k -> k),
    // which U2's per-cell literal asserts do not check directly.
    import mesh_ops.loop_slice : bandWalk, BandCell;
    import std.format : format;

    static void checkChain(BandCell[] chain, size_t expectDistinct, string tag) {
        // Shared-rail identity: consecutive cells' facing sides are the
        // SAME edge. Guarded against an empty chain (`bandWalk` cannot
        // hand one to a caller today, but `chain.length - 1` on `size_t`
        // underflows to `size_t.max` if it ever does, turning this into an
        // effectively-unbounded loop over an empty array instead of a
        // clean no-op).
        if (chain.length == 0) return;
        foreach (i; 0 .. chain.length - 1) {
            auto lhs = bandCellEdgeKey(bandTestBasePolys, chain[i].fi, chain[i].B);
            auto rhs = bandCellEdgeKey(bandTestBasePolys, chain[i + 1].fi, chain[i + 1].A);
            assert(lhs == rhs,
                format("%s: chain[%d]'s B-edge must equal chain[%d]'s A-edge",
                       tag, i, i + 1));
        }
        bool[ulong] distinct;
        foreach (c; chain) {
            distinct[bandCellEdgeKey(bandTestBasePolys, c.fi, c.A)] = true;
            distinct[bandCellEdgeKey(bandTestBasePolys, c.fi, c.B)] = true;
        }
        assert(distinct.length == expectDistinct,
            format("%s: expected %d distinct cut edges (k=%d), got %d",
                   tag, expectDistinct, chain.length, distinct.length));
    }

    // row3 -- open, k=3 -> 4 distinct edges.
    checkChain(bandWalk(bandTestBasePolys, [21u, 24u, 27u])[0], 4, "row3");
    // L -- open, k=5 -> 6.
    checkChain(bandWalk(bandTestBasePolys, [21u, 24u, 27u, 28u, 29u])[0], 6, "L");
    // b2x2 -- CLOSED, k=4 -> 4 (not 5): the wraparound edge is shared, not new.
    checkChain(bandWalk(bandTestBasePolys, [21u, 24u, 22u, 25u])[0], 4, "b2x2");
    // one_00 -- single-cell (both sides derived), k=1 -> 2.
    checkChain(bandWalk(bandTestBasePolys, [25u])[0], 2, "one_00");
    // w3_all9scr's first chain -- CLOSED, k=8 -> 8 (the 3x3 block's outer
    // ring; every cut edge is shared with the chain's other end).
    checkChain(bandWalk(bandTestBasePolys,
        [25u, 27u, 23u, 26u, 28u, 21u, 29u, 22u, 24u])[0], 8, "w3_all9scr chain0");

    // Mutation (plan §5 Phase 3 validation, applies once wired): deleting
    // the rail pre-pass or corrupting the entry/exit convention would break
    // the shared-rail identity above for any turn cell (L_cornerfirst,
    // b2x2) -- U3 pins the INVARIANT the pre-pass depends on existing.
}

unittest { // Phase-2-review hang guard (NOT the plan's U4 — that name is
    // reused below by Phase 3's own §6 U4, determinism under a permuted
    // face-array order; this test predates that numbering) — a repeated
    // index in `sel` must not hang `bandWalk` forever (task 1054 review,
    // BLOCKER). `bandReorderByConnectivity`'s
    // `seenCount` counts DISTINCT visits while `S = sel.length` counts raw
    // entries -- a duplicate index (e.g. `[21, 21]`) marks the same slot
    // `seen` twice, so `seenCount` saturates below `S`; both the nb<2 scan
    // and its "first unvisited" fallback then find nothing left, `start`
    // stays -1, and without a `start < 0` escape the outer
    // `while (seenCount < S)` spins with no progress. Reproduced pre-fix:
    // `bandWalk(bandTestBasePolys, [21u, 21u])` killed at an external 8 s
    // timeout.
    //
    // Bounded with an in-process watchdog (a daemon thread + a timed
    // semaphore wait), per plan/review guidance ("bound it so a regression
    // fails fast rather than wedging the suite"): a plain direct call would
    // itself hang the whole test binary if this ever regresses, defeating
    // the point of a regression test. The daemon thread means a genuine
    // regression still leaves one thread spinning in the background, but
    // the test PROCESS does not block on it -- this assert fails within
    // the watchdog window instead.
    //
    // Mutation: reverting the `if (start < 0) break;` fix (i.e. dropping
    // it) reproduces the pre-fix hang -- verified by running this exact
    // assert against the reverted source, which timed out instead of
    // passing.
    import mesh_ops.loop_slice : bandWalk;
    import core.thread : Thread;
    import core.time : dur;
    import core.sync.semaphore : Semaphore;

    auto done = new Semaphore();
    auto worker = new Thread({
        cast(void) bandWalk(bandTestBasePolys, [21u, 21u]);
        done.notify();
    });
    worker.isDaemon = true;
    worker.start();
    assert(done.wait(dur!"seconds"(5)),
        "bandWalk(bandTestBasePolys, [21, 21]) (a repeated selection index) "
        ~ "did not return within the 5s watchdog -- regressed to the "
        ~ "pre-fix infinite loop in bandReorderByConnectivity's restart scan");
}

unittest { // Phase-2-review bounds guard (NOT the plan's U5 — that name is
    // reused below by Phase 3's own §6 U5, the measured ring-start law; this
    // test predates that numbering) — an out-of-range selection index must
    // not crash `bandWalk` (task 1054 review). `bandNb`/`bandSideOf` index `polys[pi]` raw with
    // no bounds guard of their own; `bandWalk` now filters `sel` to
    // `p < polys.length` once, before any of them run. Reproduced pre-fix:
    // `bandWalk(bandTestBasePolys, [21u, 999u])` threw `ArrayIndexError`
    // (`bandTestBasePolys.length` is 30, so 999 is well out of range).
    //
    // Mutation: removing the `valid`/filter block in `bandWalk` reproduces
    // the pre-fix crash -- verified by running this exact call against the
    // reverted source, which threw instead of returning.
    import mesh_ops.loop_slice : bandWalk, BandCell;
    import std.format : format;

    auto got = bandWalk(bandTestBasePolys, [21u, 999u]);
    // The out-of-range entry is dropped, not silently kept -- what
    // survives is exactly the single-cell walk over face 21 alone.
    assert(got == [[BandCell(21, 2, 0)]],
        format("out-of-range index must be filtered out, not crash or "
               ~ "silently retained: got %s", got));
}

// ---------------------------------------------------------------------------
// Task 1054 Phase 3 — U5: the MEASURED ring-start law (R9, plan §3.2/§6),
// pinned on a REAL kernel run rather than the pure `bandWalk` above. Unlike
// U2/U3 (which drive `bandWalk` directly against `bandTestBasePolys`'
// reference-index topology, since the walk was not yet wired), U5 needs the
// actual EMITTED face rings `insertEdgeLoopsMulti` produces, so it builds a
// real `Mesh` via `prim.cube`'s own generator (`buildCuboidParametric`) and
// selects faces by GEOMETRY (vertex-coordinate SET, mirroring tests/
// fixture_helpers.d's `resolveCoords`) — never by a face-index literal, per
// the SAME "our numbering does not correspond to the reference's" rule
// `bandTestBasePolys`' own doc comment states (and CLAUDE.md's Picking
// Strategy note: never key a geometry assertion to index correspondence).
//
// Classification needs no cross-engine correspondence either: a vertex index
// at or above the PRE-CUT vertex count is a vertex THIS CALL created ('N');
// below it, it is original ('o') — `insertEdgeLoopsMulti` only ever APPENDS
// (`addVertex`), so this partition is exact. The resulting pattern STRING
// (letters in the face's own stored ring order) is then a direct,
// reference-independent read of the ring-start law: a face carrying the
// chord at both ends of its OWN stored array (`flags[0] && flags[$-1]`) is
// "created"; one with a non-new position 0 is "absorb-only" (per §6's own
// classifier).
//
// The CREATED-class multisets below are the reference's, lifted verbatim
// from the plan's §6 table (`ring_start_law.py`'s per-case output — 470
// created / 133 absorb-only / 0 violations across all 54 cases): a created
// face's exact pattern is fully determined by the cut's OWN construction
// (§3.2's `capA`/`capB`), so its letter-for-letter shape is portable across
// engines regardless of which mesh generator built the base cube — verified
// empirically (this test's created-class asserts reproduce the reference's
// strings exactly, unmodified from the plan's table). An ABSORB-only face's
// pattern additionally encodes WHICH local ring-edge index the absorbed
// mid(s) land at, which is an accident of THAT face's own vertex ordering —
// vibe3d's `prim.cube` generator does not match the reference's index/
// winding convention (`bandTestBasePolys`' own doc comment) — so absorb-only
// faces are checked STRUCTURALLY (`assertAbsorbShape`, below) rather than by
// exact string: face count, midpoints-absorbed-per-face, and `!flags[0]`
// (never rotated) — the count/shape claims the reference dump also supports
// on these four cases, and the portable half of the law either way.
private struct BandRunResult { string[] created; string[] absorbOnly; }

private BandRunResult runBandAndClassify(Vec3[][] sel, float pos) {
    import mesh_ops.box_geom : BoxParams, buildCuboidParametric;
    import std.algorithm : canFind;

    Mesh m;
    BoxParams p;
    p.segmentsX = 3; p.segmentsY = 1; p.segmentsZ = 3;
    p.sizeX = 1; p.sizeY = 1; p.sizeZ = 1;
    p.radius = 0; p.sharp = true;
    buildCuboidParametric(&m, p);
    m.buildLoops();
    m.resetSelection();   // size the selection/order arrays before selectFace
    immutable uint origCount = cast(uint) m.vertices.length;

    static bool near(Vec3 a, Vec3 b) { return (a - b).length() < 1e-4f; }

    // Resolve one polygon by its corner-coordinate SET (any order) — the
    // in-process mirror of fixture_helpers.resolveCoords's polygon mode.
    static uint resolveFace(ref Mesh mm, Vec3[] want) {
        outer: foreach (fi, f; mm.faces) {
            if (f.length != want.length) continue;
            auto used = new bool[](f.length);
            foreach (w; want) {
                bool found = false;
                foreach (k, vi; f) {
                    if (used[k]) continue;
                    if (near(mm.vertices[vi], w)) { used[k] = true; found = true; break; }
                }
                if (!found) continue outer;
            }
            return cast(uint) fi;
        }
        assert(false, "resolveFace: no matching polygon in the built cube");
    }

    uint[] faceIdx;
    foreach (spec; sel) faceIdx ~= resolveFace(m, spec);
    foreach (fi; faceIdx) m.selectFace(cast(int) fi);
    uint[] bandFaces = m.selectedFaceIndicesInSelectionOrder();

    uint[] newFaceIndices;
    bool ok = sliceOnce!insertEdgeLoopsMulti(m, null, [pos], newFaceIndices, bandFaces);
    assert(ok, "band cut must succeed");

    BandRunResult res;
    foreach (f; m.faces) {
        char[] s;
        foreach (v; f) s ~= (v >= origCount) ? 'N' : 'o';
        if (!s.canFind('N')) continue;   // untouched face — outside the classifier's domain
        // This partitions on `s[0]=='N' && s[$-1]=='N'` -- the very property
        // under test (does the ring START ON the chord) -- so it is worth
        // recording, not just asserting, WHY that is discriminating rather
        // than circular (task 1054 review NIT): verified over this corpus
        // that exactly ONE cyclic rotation of any given face's ring has the
        // marker at BOTH ends (a chord is exactly 2 adjacent new vertices;
        // no other rotation of the same ring puts both at index 0 and $-1
        // simultaneously unless the whole ring is new, which never happens
        // here), so the stored order the kernel actually emitted -- not an
        // independent re-derivation -- is what this reads. Confirmed by
        // mutation: dropping the rotation (forcing every face's stored start
        // back to index 0 regardless of content) moves faces between the
        // `created`/`absorbOnly` classes and reddens BOTH consumers below --
        // U5's created-class multiset assert AND the absorb-only regression
        // guard -- rather than leaving either silently unaffected.
        if (s[0] == 'N' && s[$ - 1] == 'N') res.created    ~= s.idup;
        else                                res.absorbOnly ~= s.idup;
    }
    return res;
}

private void assertMultiset(string what, string[] got, string[] want) {
    import std.algorithm : sort;
    import std.format : format;
    auto g = got.dup;  auto w = want.dup;
    sort(g); sort(w);
    assert(g == w, format("%s: pattern multiset expected %s, got %s", what, w, g));
}

// Absorb-only faces are checked STRUCTURALLY (count of absorbing faces, and
// how many midpoints each absorbed), not by exact pattern STRING: unlike a
// created face's pattern (fully determined by the cut's OWN construction,
// hence portable letter-for-letter across engines — the created-class
// asserts above reproduce the reference's exact strings), an absorbing
// face's pattern also encodes WHICH local ring-edge index the absorbed
// mid(s) land at, which is an accident of THAT face's own vertex ordering —
// a property of the mesh GENERATOR (ours differs from the reference's, per
// `bandTestBasePolys`' own doc comment), not of the cut law. `!flags[0]`
// (never rotate an absorbing face) is the portable, LAW-level invariant —
// checked directly below, and again by the dedicated regression-guard
// unittest after this one.
private void assertAbsorbShape(string what, string[] got, size_t expectedCount,
                                size_t expectedNPerFace) {
    import std.algorithm : count;
    import std.format : format;
    assert(got.length == expectedCount,
        format("%s: expected %d absorb-only face(s), got %d (%s)",
               what, expectedCount, got.length, got));
    foreach (pat; got) {
        assert(pat[0] != 'N',
            format("%s: absorb-only face rotated onto a new vertex: %s", what, pat));
        auto n = pat.count('N');
        assert(n == expectedNPerFace,
            format("%s: expected %d absorbed midpoint(s), got %d in %s",
                   what, expectedNPerFace, n, pat));
    }
}

unittest { // U5 — created-class law: the chord sits on the ring's CLOSING
    // edge (`flags[0] && flags[$-1]`), on the four corpus cases the plan's
    // §6 table freezes (row3/L/b2x2/one_00), all on the top face (y=0.5) of
    // the 3x1x3 segmented box, all at pos 0.5 (rotation is pos-independent).
    Vec3 v(float x, float y, float z) { return Vec3(x, y, z); }
    enum float e = 0.166667f, h = 0.5f;

    Vec3[][] row3Sel = [
        [v(-h,h,-h), v(-h,h,-e), v(-e,h,-e), v(-e,h,-h)],
        [v(-e,h,-h), v(-e,h,-e), v(e,h,-e),  v(e,h,-h)],
        [v(e,h,-h),  v(e,h,-e),  v(h,h,-e),  v(h,h,-h)],
    ];
    auto r3 = runBandAndClassify(row3Sel, 0.5f);
    assertMultiset("row3 created", r3.created,
        ["NooN", "NooN", "NooN", "NooN", "NooN", "NooN"]);
    assertAbsorbShape("row3 absorb-only", r3.absorbOnly, 2, 1);

    Vec3[][] LSel = row3Sel ~ [
        [v(e,h,-e), v(e,h,e), v(h,h,e), v(h,h,-e)],
        [v(e,h,e),  v(e,h,h), v(h,h,h), v(h,h,e)],
    ];
    auto L = runBandAndClassify(LSel, 0.5f);
    assertMultiset("L created", L.created,
        ["NooN", "NooN", "NooN", "NooN", "NooN", "NooN", "NooN", "NooN", "NoN", "NoooN"]);
    assertAbsorbShape("L absorb-only", L.absorbOnly, 2, 1);

    Vec3[][] b2x2Sel = [
        [v(-h,h,-h), v(-h,h,-e), v(-e,h,-e), v(-e,h,-h)],
        [v(-e,h,-h), v(-e,h,-e), v(e,h,-e),  v(e,h,-h)],
        [v(-h,h,-e), v(-h,h,e),  v(-e,h,e),  v(-e,h,-e)],
        [v(-e,h,-e), v(-e,h,e),  v(e,h,e),   v(e,h,-e)],
    ];
    auto b22 = runBandAndClassify(b2x2Sel, 0.5f);
    assertMultiset("b2x2 created", b22.created,
        ["NoN", "NoN", "NoN", "NoN", "NoooN", "NoooN", "NoooN", "NoooN"]);
    assert(b22.absorbOnly.length == 0,
        "b2x2: a closed loop of turn cells has NO terminal — nothing absorbs");

    Vec3[][] one00Sel = [
        [v(-e,h,-e), v(-e,h,e), v(e,h,e), v(e,h,-e)],
    ];
    auto one00 = runBandAndClassify(one00Sel, 0.5f);
    assertMultiset("one_00 created", one00.created, ["NooN", "NooN"]);
    assertAbsorbShape("one_00 absorb-only", one00.absorbOnly, 2, 1);
}

unittest { // U5 — absorb-only class is a REGRESSION GUARD (§3.2 consequence
    // 3): a face that only absorbs a foreign terminating midpoint must KEEP
    // its ORIGINAL start (`!flags[0]`) — the pass-2 absorber already
    // guarantees `nf[0] == f[0]` (it walks `f` from `k=0`, inserting mids
    // AFTER each original vertex), so this is pinned as a standing
    // regression check on the same row3 run rather than new machinery.
    Vec3 v(float x, float y, float z) { return Vec3(x, y, z); }
    enum float e = 0.166667f, h = 0.5f;
    Vec3[][] row3Sel = [
        [v(-h,h,-h), v(-h,h,-e), v(-e,h,-e), v(-e,h,-h)],
        [v(-e,h,-h), v(-e,h,-e), v(e,h,-e),  v(e,h,-h)],
        [v(e,h,-h),  v(e,h,-e),  v(h,h,-e),  v(h,h,-h)],
    ];
    auto r3 = runBandAndClassify(row3Sel, 0.5f);
    foreach (pat; r3.absorbOnly)
        assert(pat[0] != 'N',
            "absorb-only face must keep its ORIGINAL ring start: " ~ pat);
}

// ---------------------------------------------------------------------------
// Task 1054 review (SHOULD-FIX 2) — the rail pre-pass must skip a
// DEGENERATE band cell (`cell.A == cell.B`, only reachable via a
// 3-polygon edge — `bandSides`'s own doc comment) instead of creating a
// rail for a cell that the entry-population loop then skips anyway. In
// the ALL-degenerate limit this must be decided a no-op BEFORE any vertex
// is appended, matching the standing rule (this file's coincident-
// position dedup, and `mesh_ops.edge_slice`'s "no-op must not corrupt the
// mesh" contract) that a no-op is decided before the first geometry
// mutation.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;

    // Three triangles all sharing ONE edge (0,1) — a genuine non-manifold
    // "book" (same construction as tests/unit/mesh_test.d's "non-manifold
    // book: spine edge (3 faces)" fixture). Selecting all three makes
    // EVERY chain cell degenerate: `bandChains`' own "closed" rule treats
    // three polygons mutually adjacent via a SINGLE physical edge as a
    // closed 3-cycle, so each cell's derived predecessor-side and
    // successor-side resolve to the SAME ring-edge index — that polygon's
    // only shared (non-boundary) edge — giving `cell.A == cell.B` for all
    // three cells, with no live cell anywhere in the chain.
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),      // 0 — spine endpoint A
        Vec3(1, 0, 0),      // 1 — spine endpoint B
        Vec3(0.5f,  1, 0),  // 2 — page 0 tip
        Vec3(0.5f, -1, 0),  // 3 — page 1 tip
        Vec3(-0.5f, 0, 1),  // 4 — page 2 tip
    ];
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 1u, 3u]);
    m.addFace([0u, 1u, 4u]);
    m.buildLoops();
    m.resetSelection();
    m.selectFace(0);
    m.selectFace(1);
    m.selectFace(2);
    uint[] bandFaces = m.selectedFaceIndicesInSelectionOrder();
    assert(bandFaces.length == 3, "setup: all three book pages must be selected");

    immutable size_t vertsBefore = m.vertices.length;
    immutable size_t edgesBefore = m.edges.length;
    immutable size_t facesBefore = m.faces.length;

    uint[] newFaceIndices;
    bool ok = sliceOnce!insertEdgeLoopsMulti(m, null, [0.5f], newFaceIndices, bandFaces);

    assert(!ok, "an all-degenerate band selection must report a no-op");
    // The load-bearing assert: before the fix, the pre-pass's `getMids`
    // calls ran over every cell (degenerate or not) and appended a rail
    // vertex on the book's shared edge BEFORE the all-degenerate bail at
    // the end of the band-mode block ever ran — a no-op that still
    // mutated the mesh. Reverting the fix (removing the `anyLiveCell` gate
    // and its early `return false`, restoring the pre-pass to run
    // unconditionally) reproduces exactly that: `ok` stays `false` but
    // `m.vertices.length` grows by 1 — verified by running this assert
    // against the reverted source, where it failed with "expected 5, got 6".
    assert(m.vertices.length == vertsBefore,
        "a no-op band cut must NOT append any vertex — got "
        ~ m.vertices.length.to!string ~ ", expected " ~ vertsBefore.to!string);
    assert(m.edges.length == edgesBefore,
        "a no-op band cut must NOT touch the edge count");
    assert(m.faces.length == facesBefore,
        "a no-op band cut must NOT touch the face count");
    assert(newFaceIndices.length == 0,
        "a no-op band cut must report no new faces");
}

// ===========================================================================
// Task 1903 Stage F1 — the batch cells and the recording block.
// ===========================================================================

/// A stand that carries EVERY plane a revert would have to bring back: a
/// selected vertex / edge / face with their orders and counters, per-face
/// material and part, all three set masks, one HIDDEN face, one SUBPATCH face
/// and a PolyVertex UV map. Audited plane by plane rather than by name — the
/// Stage E2 review's BLOCKER B1 was a recording stand carrying one `faceMarks`
/// bit and no selection, which made "the revert is complete" hold for free.
private Mesh recSliceStand() {
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    m.selectVertex(1);
    m.selectEdge(3);
    m.selectFace(4);
    m.faceMaterial.length = m.faces.length;
    m.facePart.length     = m.faces.length;
    foreach (i; 0 .. m.faces.length) {
        m.faceMaterial[i] = cast(uint)(i % 3);
        m.facePart[i]     = cast(uint)(i % 2);
    }
    m.vertexSetMask.length = m.vertices.length;
    m.faceSetMask.length   = m.faces.length;
    m.vertexSetMask[2] = 1UL;
    m.faceSetMask[1]   = 2UL;
    m.edgeSetMask[m.edgeKeyOf(0)] = 4UL;
    m.edgeSetMask[m.edgeKeyOf(5)] = 8UL;
    m.setFaceHidden(0, true);
    m.setFaceSubpatch(2, true);
    auto mp = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    foreach (fi; 0 .. m.faces.length)
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t slot = (m.faceLoop[fi] + c) * 2;
            auto p = m.vertices[m.faces[fi][c]];
            mp.data[slot]     = p.x + 0.25f;
            mp.data[slot + 1] = p.y + 0.5f;
        }
    return m;
}

private string kindsOf(ref MeshEditDelta d) {
    import std.conv : to;
    string s = "[";
    foreach (i, ref e; d.log) { if (i) s ~= " "; s ~= e.kind.to!string; }
    return s ~ "]";
}

private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
    size_t n; foreach (ref e; d.log) if (e.kind == k) ++n; return n;
}

unittest { // ONE stamp, however many loops the cut inserts — and it SCALES
    import std.format : format;
    // A SCALE check, not a location check. Measured on this stand with the
    // deferral disabled (M-F1-BATCH: `if (false) if (auto f =
    // currentBatchFrame(&this))` in Mesh.commitChange): ONE position costs 6
    // stamps, THREE cost 14. The batch holds both at 1, and the amplitude
    // grows with the position count — the half a single-position cell cannot
    // see, and the half no wire counter can see at all (E3 memo 11: at suite
    // level a batch per cut and a batch over the ladder read identically on
    // every /api/changes counter, so `mutationVersion` in the unit lane is the
    // only discriminator).
    static immutable ulong[2] kUnbatched = [6, 14];
    foreach (i, positions; [[0.5f], [0.25f, 0.5f, 0.75f]]) {
        Mesh m = recSliceStand();
        immutable uint seed = m.edgeIndex(0, 1);
        assert(seed != ~0u, "recSliceStand must carry the cube belt seed edge");

        immutable ulong base = m.mutationVersion;
        uint[] nfi;
        bool ok;
        {
            auto ed = MeshEditBatch.unrecorded(m, kLoopSliceEditScope);
            ok = ed.insertEdgeLoopsMulti([seed], positions, nfi);
            ed.close();
        }
        immutable ulong d = m.mutationVersion - base;

        // ANTI-VACUITY: a refusal returns false and makes no commits, so
        // `d == 1` would fail on one — but pin the work anyway, because a
        // future refusal that stamped once would sail through.
        assert(ok && nfi.length == 4 * (positions.length + 1),
            format("the stand cut %s and reported %d new face(s), expected "
                 ~ "true and %d (a four-face belt ring, %d sub-quads each) — "
                 ~ "the assertion below would be measuring a refusal "
                 ~ "(task 1903 Stage F1)",
                   ok, nfi.length, 4 * (positions.length + 1),
                   positions.length + 1));
        assert(d == 1,
            format("a %d-position loop slice bumped mutationVersion by %d, "
                 ~ "expected exactly 1. The `MeshEditBatch` its caller opens — "
                 ~ "the two commands in commands/mesh/loop_slice.d, the tool's "
                 ~ "commit and per-frame preview in "
                 ~ "tools/slice/loop_slice_tool.d, the topology pen's Add Loop "
                 ~ "— is what defers every internal commit to one close(). "
                 ~ "Without it this reads %d on this stand, and the figure "
                 ~ "grows with the position count (6 for one, 14 for three) "
                 ~ "(task 1903 Stage F1).",
                   positions.length, d, kUnbatched[i]));
    }
}

/// The scope this family declares, written out from the enum INDEPENDENTLY of
/// `kLoopSliceEditScope` — `d.scope_` IS that constant fed through
/// `MeshEditTracker.declare`, so comparing them proves nothing on its own (a
/// draft of exactly that shape stayed green under `enum uint kReduceEditScope
/// = 0;` at Stage D2). Written from what the kernel DOES: it appends a rail
/// vertex per crossed rail per position and, under Split, a duplicate for each
/// (Points); it replaces the whole face array with the ring split and appends
/// Cap Sections polygons (Polygons); it rewrites the mark words through
/// `setFaceMarksFrom` and clears every selection through `resetSelection`
/// (Marks); and the Gap and Profile options MOVE vertices through
/// `setVertexPositions` (Position). The fourth bit is the one that separates
/// this family from the two bevels, which declare `Geometry|Marks` and move
/// nothing.
private enum uint kExpectedSliceScope = MeshEditScope.Points
                                      | MeshEditScope.Polygons
                                      | MeshEditScope.Marks
                                      | MeshEditScope.Position;

unittest { // the loop slice's op-log NAMES NO FACE CHANGE, and its revert FAULTS
    import std.format : format;
    Mesh m = recSliceStand();

    // STAND CANARY — asserts the stand, not the code under test.
    assert(m.isFaceSelected(4) && m.isVertexSelected(1) && m.isEdgeSelected(3)
           && m.isFaceHidden(0) && m.isFaceSubpatch(2)
           && m.meshMap(kUvMapName) !is null && m.edgeSetMask.length == 2,
        "recSliceStand selected/tagged nothing — the Marks half of the law "
      ~ "below would be vacuous (task 1903 Stage F1, and Stage E2 review "
      ~ "BLOCKER B1 for the shape)");

    immutable size_t preV = m.vertices.length, preF = m.faces.length;
    immutable uint seed = m.edgeIndex(0, 1);

    MeshEditDelta d;
    bool ok;
    uint[] nfi;
    {
        auto ed = MeshEditBatch(m, kLoopSliceEditScope);   // RECORDING
        ok = ed.insertEdgeLoopsMulti([seed], [0.5f], nfi);
        d = ed.close();
    }

    assert(ok && m.vertices.length == preV + 4 && m.faces.length == preF + 4,
        format("the stand cut %s (V %d -> %d, F %d -> %d), expected true, "
             ~ "V +4 (one rail midpoint per belt rail) and F +4 (each of the "
             ~ "four belt faces splits in two) — every assertion below would "
             ~ "be vacuous on a refusal",
               ok, preV, m.vertices.length, preF, m.faces.length));

    assert(cast(uint)d.scope_ == kExpectedSliceScope,
        format("a recording loop slice declared scope 0x%x, expected 0x%x "
             ~ "(Points|Polygons|Marks|Position). Missing: 0x%x. Unexpected: "
             ~ "0x%x. `MeshEditDelta.finalize` reads scope_ back on a revert "
             ~ "to decide what to bump and rebuild (task 1903 Stage F1)",
               cast(uint)d.scope_, kExpectedSliceScope,
               kExpectedSliceScope & ~cast(uint)d.scope_,
               cast(uint)d.scope_ & ~kExpectedSliceScope));
    assert(cast(uint)d.scope_ == kLoopSliceEditScope,
        format("the delta's scope_ (0x%x) is not the kLoopSliceEditScope the "
             ~ "batch was opened with (0x%x) — the declared scope is not "
             ~ "reaching MeshEditDelta.scope_ at all",
               cast(uint)d.scope_, kLoopSliceEditScope));

    // THE FINDING, MEASURED (2026-08-26).
    //
    // Six faces became ten, every one of the four belt faces was replaced,
    // and the op-log is ONE entry:
    //
    //     entries=1 kinds=[AddVerts]
    //
    // — the four rail midpoints and nothing else. The whole face array was
    // installed through `mesh_planes.rewriteFaces(ed, …, &rw, vertBlend)`,
    // whose `Kind.FaceReindex` publisher is merely DISARMED
    // (`MeshEditTracker.wantsFaceReindex` is false). That is the shape Stage
    // K's per-rewrite arming scope reaches, and plan §5.3's audit row for this
    // kernel already says "yes, after Stage J" — CONFIRMED here by arming and
    // measuring, which is the only way a disarmed publisher can be told from
    // an absent one (E3 memo 12). With the flag armed at its declaration the
    // log becomes `[AddVerts FaceReindex]` and `revert()` STOPS throwing — it
    // answers `true`. The potency of that mutation was checked on a FOREIGN
    // family: the same armed build reddens
    // `tests/unit/mesh_ops/cleanup_test.d(785)` ("revert restored V=4 F=3,
    // expected V=4 F=2"), so an unchanged log here would have meant something.
    //
    // ARMING IS NOT THE FIX, AND THAT IS MEASURED TOO — the same shape the
    // vertex chamfer showed at Stage E4. With the flag armed, `revert()`
    // answers `true`, V/F/E and every winding come back, `faceMaterial`,
    // `facePart`, `faceSetMask` and `edgeSetMask` come back, the `Hide` and
    // `Subpatch` bits of `faceMarks` come back — and these do NOT:
    //
    // NINE ROWS, and the count is written out here because it was carried as
    // six / seven / eight in three different artefacts before the F1 review
    // (2026-08-26). This enumeration is the canonical one; the plan's §5.3 K
    // row and the card quote it verbatim.
    //
    //     1. vertexMarks[1] Select      1 -> 0
    //     2. edgeMarks[3]   Select      1 -> 0
    //     3. faceMarks[4]   Select      1 -> 0
    //     4. vertexSelectionOrder[1]    1 -> 0
    //     5. edgeSelectionOrder[3]      1 -> 0
    //     6. faceSelectionOrder[4]      1 -> 0
    //     7. all three selection-order counters   1,1,1 -> 0,0,0
    //     8. vertexSetMask  — VALUES correct, LENGTH left grown (8 -> 12)
    //     9. meshMaps["uv"].data — 48 floats, ALL ZEROED (36 were non-zero)
    //
    // THE ATTRIBUTION IS THREE-WAY, NOT ONE-WAY, and each third was measured
    // by VARIANT on the armed build rather than reasoned from the code:
    //
    //   * SEVEN of the nine (1, 2, 4, 5, 6, 7, 8) are the tail
    //     `resetSelection()`. Deleting that one call restores every one of
    //     them: `vertexMarks[1]`/`edgeMarks[3]` come back true, all three
    //     order slots read 1 again, the counters read 1,1,1 and
    //     `vertexSetMask.length` stays 8. No `FaceReindex` could have carried
    //     the vertex or edge half.
    //   * ROW 3 IS NOT `resetSelection`'s, and this is where the pre-review
    //     text was self-contradictory. `faceMarks[4]` Select is cleared by
    //     `ed.setFaceMarksFrom(newWord, ~ed.Marks.Select)` (the tail of `insertEdgeLoopsMulti`),
    //     BEFORE the tail ever runs. Measured: with `resetSelection()` deleted
    //     the face Select bit is ALREADY false post-op, and `FaceReindex`'s
    //     reverse faithfully restores a surviving old face from the live
    //     post-op word — which has Select off. So it stays lost.
    //   * ROW 9 IS NEITHER. `resetSelection()` deleted, the map is STILL
    //     zeroed at 48. Its cause is `MeshEditDelta.finalize`'s tail
    //     `m.resizeAllMeshMaps()` (mesh_edit_delta.d:2032) reaching
    //     `resizeMeshMapData`, whose documented rule is "topology rewritten
    //     WITHOUT a relocate … ZERO the whole map at the new length"
    //     (`resizeMeshMapData`'s own doc comment). The log is `[AddVerts FaceReindex]` — no
    //     `Kind.MeshMapDelta`, whose only publisher is
    //     `Mesh.recordPolyVertexPayload`, never called on this path.
    //
    // TWO DIFFERENCES FROM E4's vertex chamfer, and they matter to whoever
    // owns the remedy: here `faceSelectionOrder` IS lost (there it survived),
    // and here the FORWARD op CARRIES the PolyVertex UV map rather than
    // zeroing it (measured: 48 floats / 36 non-zero -> 80 / 60, with and
    // without Split+Gap), so this family IS inside the 0682/0830 corner-carry
    // census.
    //
    // THE FORWARD CARRY DOES NOT MAKE UNDO SAFE, AND THE PRE-REVIEW TEXT SAID
    // IT DID. That inference was measurably false and it is the sentence L9
    // would have acted on. The forward carry is a `rewriteFaces` property; the
    // REVERSE is the half undo needs, and on the armed build — exactly the L9
    // state — `revert()` restores the map's LENGTH (80 -> 48) and ZEROES all
    // 48 floats, 36 of which were non-zero:
    //
    //     pre  [0..12] = -0.25 0 -0.25 1 0.75 1 0.75 0 -0.25 0 0.75 0
    //     post-revert  =  0    0  0    0 0    0 0    0  0    0 0    0
    //
    // What L9 owes, therefore, is THREE publishers and not one: a MARKS
    // publisher (plan L0's first production publishers) for all three domains
    // plus the set-mask resize (rows 1, 2, 4-8); publishing
    // `setFaceMarksFrom` (row 3), which the Marks publisher does NOT cover;
    // and a `MeshMapDelta` publisher on this path (row 9), which neither
    // covers. Any of the three left undone is a stated `MeshSnapshot` refusal,
    // not a silent gap. None of it is a reorder.
    //
    // `revert()` IS NOT CALLED IN THIS BLOCK, and that is a MEASUREMENT, not
    // caution: on the shipped (disarmed) build it THROWS
    // `index [8] is out of bounds for array of length 8` and leaves the mesh
    // half-reverted at V=8 F=10 E=20 with 16 dangling face corners (max
    // corner index 11 against 8 vertices). The observable that flips when
    // this is fixed is the KIND LIST below.
    //
    // STAGE K/L9 FLIPS THIS.
    assert(d.log.length == 1,
        format("the loop slice recorded %d op-log entr(ies) %s, expected "
             ~ "exactly 1. If a face entry has appeared, K/J has armed the "
             ~ "rewrite — good news, and this block's whole comment plus plan "
             ~ "§5.3's row move with it, including the NINE rows the armed "
             ~ "revert was measured to lose — seven selection planes, the "
             ~ "set-mask resize, and the PolyVertex UV map zeroed at its "
             ~ "restored length (task 1903 Stage F1).",
               d.log.length, kindsOf(d)));
    assert(countKind(d, MeshOpEntry.Kind.AddVerts) == 1,
        format("the loop slice's op-log is %s, expected exactly one AddVerts "
             ~ "(task 1903 Stage F1).", kindsOf(d)));
    assert(countKind(d, MeshOpEntry.Kind.FaceReindex)  == 0
        && countKind(d, MeshOpEntry.Kind.AddFaces)     == 0
        && countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 0
        && countKind(d, MeshOpEntry.Kind.RemoveFaces)  == 0,
        format("the loop slice's op-log now names a face change (%s) — see the "
             ~ "comment above: the rewrite's publisher was DISARMED, and if it "
             ~ "is armed now the NINE-row loss measured under arming has to "
             ~ "be re-checked before this is called fixed "
             ~ "(task 1903 Stage F1, plan §5.3).", kindsOf(d)));
}

unittest { // the Gap and the Profile writes are RECORDED, one SetPos entry each
    import std.format : format;
    // The half of Stage F1 that only a recording batch can see. Before F1 both
    // blocks were raw `vertices[pr[0]] = …` / `vertices[r.midsVa[i]] = …`
    // writes: a recording batch around a split-gap or profiled cut produced an
    // op-log that named the added vertices and said NOTHING about the
    // coordinates it had just moved. `Kind.SetPos` had a complete
    // forward+reverse apply and no publisher on this path at all.
    //
    // The two blocks are counted SEPARATELY, and the third cell is why: a
    // single `== 1` row would be satisfied by either block alone, and a cut
    // that runs both must produce TWO entries — one per `setVertexPositions`
    // call. Measured: plain `[AddVerts]`; +Gap `[AddVerts SetPos]`; +Profile
    // `[AddVerts SetPos]`; both `[AddVerts SetPos SetPos]`.
    static struct Cell { string name; bool split; float gap; float[] heights; float depth; size_t setPos; }
    static immutable Cell[] cells = [
        Cell("plain",          false, 0.0f, null,                 0.0f, 0),
        Cell("split, no gap",  true,  0.0f, null,                 0.0f, 0),
        Cell("split+gap",      true,  0.2f, null,                 0.0f, 1),
        Cell("profile",        false, 0.0f, [0.0f, 1.0f, 0.0f],   0.4f, 1),
        Cell("split+gap+profile", true, 0.1f, [0.0f, 1.0f, 0.0f], 0.4f, 2),
    ];
    foreach (c; cells) {
        Mesh m = recSliceStand();
        immutable uint seed = m.edgeIndex(0, 1);
        float[] pos = (c.heights.length > 0) ? [0.25f, 0.5f, 0.75f] : [0.5f];
        MeshEditDelta d;
        bool ok;
        uint[] nfi;
        {
            auto ed = MeshEditBatch(m, kLoopSliceEditScope);   // RECORDING
            ok = ed.insertEdgeLoopsMulti([seed], pos, nfi, null, false, false,
                                         c.split, false, null, c.gap,
                                         false, 1.0f, c.heights.dup, c.depth);
            d = ed.close();
        }
        assert(ok, c.name ~ ": the stand refused the cut — every count below "
                          ~ "would be vacuous (task 1903 Stage F1)");
        assert(countKind(d, MeshOpEntry.Kind.SetPos) == c.setPos,
            format("%s: the loop slice recorded %d `SetPos` entr(ies) %s, "
                 ~ "expected %d. Stage F1 migrated FOUR raw coordinate writes "
                 ~ "to two `ed.setVertexPositions` calls — the Gap block's "
                 ~ "seam pair and the Profile block's rail mids — and a raw "
                 ~ "write inside a recording batch produces NO entry at all: "
                 ~ "a delta undo would restore the topology and leave every "
                 ~ "seam half and every profiled rail at its displaced "
                 ~ "coordinate (task 1903 §2.5, §5.7).",
                   c.name, countKind(d, MeshOpEntry.Kind.SetPos), kindsOf(d),
                   c.setPos));
    }
}
