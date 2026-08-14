// Module unittests for `mesh_ops.loop_slice`, moved verbatim out of source/mesh_ops/loop_slice.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.loop_slice_test;

import mesh;
import math;
import mesh_ops.loop_slice;

unittest {
    import std.math : abs;

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

    // ------------------------------------------------------------------
    // A) Closed ring on the default cube — seed edge 0-1.
    // Cube: v0=(-0.5,-0.5,-0.5) v1=(0.5,-0.5,-0.5)  edge 0-1 = bottom-front.
    // ------------------------------------------------------------------
    {
        Mesh m = makeCube();
        m.buildLoops();

        uint eiSeed = m.edgeIndex(0, 1);
        assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");

        bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
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

        bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
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
    assert(m.insertEdgeLoops(eiSeed, [0.5f]), "insertEdgeLoops must succeed");
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

        bool ok = m.insertEdgeLoops(seed, [0.234f]);
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

        bool ok = cube.insertEdgeLoops(eiSeed, [0.234f]);
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
    bool ok = m.insertEdgeLoops(eiSeed, [0.5f], newFaceIndices);
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
    bool ok2 = m2.insertEdgeLoops(eiSeed2, [0.5f]);
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
    bool okDup = dup.insertEdgeLoopsMulti([eiDup], [0.5f, 0.5f], nfDup);
    assert(okDup, "duplicate cut positions must still succeed (clean single cut)");

    Mesh clean = makeCube();
    uint eiClean = clean.edgeIndex(0, 1);
    uint[] nfClean;
    bool okClean = clean.insertEdgeLoopsMulti([eiClean], [0.5f], nfClean);
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
    bool okTriple = triple.insertEdgeLoopsMulti([eiTriple], [0.5f, 0.5f, 0.5f], nfTriple);
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
    assert(whole.insertEdgeLoopsMulti([eiW], [0.5f], nfW),
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
    assert(restr.insertEdgeLoopsMulti([eiR], [0.5f], nfR, [0u, 5u]),
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
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, /*keepQuads*/false),
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
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, /*keepQuads*/true),
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
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, false, /*ngon*/false),
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
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, false, /*ngon*/true),
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
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, false, false, /*split*/false),
           "split-off insert must succeed");
    immutable offV = off.vertices.length, offE = off.edges.length, offF = off.faces.length;
    assert(boundaryEdgeCount(off) == 0, "split off: closed cube, no boundary edges");
    assert(componentCount(off) == 1, "split off: one connected shell");

    // Split ON — each rail midpoint duplicated → two disconnected boundary loops.
    Mesh on = makeCube();
    uint eiOn = on.edgeIndex(0, 1);
    uint[] nfOn;
    uint[2][] pairs;
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, false, false, /*split*/true, /*caps*/false, &pairs),
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
    off2.insertEdgeLoopsMulti([off2.edgeIndex(0, 1)], [0.5f], nf2, null, false, false, false, /*caps*/false, &pairs2);
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
    assert(open.insertEdgeLoopsMulti([eiO], [0.5f], nfOpen, null, false, false, /*split*/true, /*caps*/false),
           "split-on caps-off insert must succeed");
    immutable openV = open.vertices.length, openE = open.edges.length, openF = open.faces.length;
    assert(boundaryEdgeCount(open) == 8, "caps off: two 4-edge boundary loops (8 boundary edges)");
    assert(componentCount(open) == 2, "caps off: two disconnected shells");

    // Split ON, caps ON — cap ring closes both boundary loops.
    Mesh capped = makeCube();
    uint eiC = capped.edgeIndex(0, 1);
    uint[] nfCap;
    assert(capped.insertEdgeLoopsMulti([eiC], [0.5f], nfCap, null, false, false, /*split*/true, /*caps*/true),
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
    assert(nosplit.insertEdgeLoopsMulti([nosplit.edgeIndex(0, 1)], [0.5f], nfNo, null, false, false, /*split*/false, /*caps*/true),
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
    assert(z.insertEdgeLoopsMulti([eiZ], [0.5f], nfZ, null, false, false,
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
    assert(g.insertEdgeLoopsMulti([eiG], [0.5f], nfG, null, false, false,
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
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, false, false,
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
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, false, false,
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
    assert(half.insertEdgeLoopsMulti([eiHalf], [0.5f], nfHalf, null, false, false,
                                     false, false, null, 0.0f, /*curvature*/true,
                                     /*curveTension*/0.5f),
           "curvature-on tension=0.5 insert must succeed");
    assert(hasV(half, Vec3(1.5f, 1.0517767f, 0)), "tension=0.5: rail (2,4) midpoint at the half bulge (y=1.0517767)");
    assert(hasV(half, Vec3(1.5f, 1.0517767f, 1)), "tension=0.5: rail (3,5) midpoint at the half bulge (y=1.0517767)");

    Mesh zero = makeArcStrip(1.0f, 1.0f);
    uint eiZero = zero.edgeIndex(2, 4);
    uint[] nfZero;
    assert(zero.insertEdgeLoopsMulti([eiZero], [0.5f], nfZero, null, false, false,
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
    assert(flat.insertEdgeLoopsMulti([eiFlat], [0.5f], nfFlat, null, false, false,
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
    assert(flat.insertEdgeLoopsMulti([eiF], posV, nfF, null, false, false,
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
    assert(vee.insertEdgeLoopsMulti([eiV], posV, nfV, null, false, false,
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
    assert(d0.insertEdgeLoopsMulti([eiD], posV, nfD, null, false, false,
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
    bool okGrid = grid.insertEdgeLoopsMulti([eiHoriz, eiVert], [0.3f, 0.7f], gridNewFaces);
    assert(okGrid, "grid insertEdgeLoopsMulti must succeed on the cube");

    // --- Sequential path: ring A alone, then re-find ring B's seed (the
    //     vertical edges are never touched by ring A's rails — see the
    //     kernel doc comment — so edgeIndex(0,4) is still valid post-cut).
    Mesh seq = makeCube();
    uint eiHoriz2 = seq.edgeIndex(0, 1);
    bool okA = seq.insertEdgeLoops(eiHoriz2, [0.3f, 0.7f]);
    assert(okA, "sequential ring-A insert must succeed");
    uint eiVert2 = seq.edgeIndex(0, 4);
    assert(eiVert2 != ~0u, "vertical seed edge 0-4 must survive ring-A's cut");
    bool okB = seq.insertEdgeLoops(eiVert2, [0.3f, 0.7f]);
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
    bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
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
        assert(m.insetFacesByMask(allOne, 0.1f) == 1, "must process 1 face");
        assert(m.faces.length == 5, "expected 1 inner + 4 ring quads");
        foreach (fi; 0 .. m.faces.length)
            assert(m.isFaceSubpatch(fi),
                   "every face (inner + ring) must be Subpatch when the source was");
    }

    // Source left plain ⇒ inner AND ring quads all stay non-subpatch.
    {
        Mesh m = makeFlatQuad();
        m.resetSelection();
        assert(m.insetFacesByMask(allOne, 0.1f) == 1, "must process 1 face");
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
    bool ok = m.insertEdgeLoopsMulti([eiValid, eiDegenerate], [0.5f], newFaceIndices);
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
    bool okAll = m2.insertEdgeLoopsMulti([eiDeg2], [0.5f], unused);
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

    // collectEdgeRing must return empty: the triangle makes the seed non-manifold-safe.
    bool closed;
    auto ring = m.collectEdgeRing(eiSeed, closed);
    assert(ring.length == 0,
           "collectEdgeRing must return [] when a non-quad is incident on the seed");

    // insertEdgeLoops must propagate the no-op.
    uint vBefore = cast(uint)m.vertices.length;
    uint eBefore = cast(uint)m.edges.length;
    uint fBefore = cast(uint)m.faces.length;

    bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
    assert(!ok, "insertEdgeLoops must return false for a triangle-adjacent seed");
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
    assert(m.insertEdgeLoopsMulti([ei], [0.5f], nf, null, false, false,
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
    assert(m.insertEdgeLoopsMulti([ei], [0.5f], nf, null, false, false,
                                   /*split*/true, /*caps*/true),
        "split-on caps-on insert must succeed");

    assert(nf.length >= 2, "expected at least the 2 cap faces among the new faces");
    immutable uint cap0 = nf[$ - 2], cap1 = nf[$ - 1];
    assert(m.isFaceHidden(cap0) && m.isFaceHidden(cap1),
        "S5 companion: section caps must be HIDDEN when ALL FOUR ring source "
        ~ "faces were");
}
