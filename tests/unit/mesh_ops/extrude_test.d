// Module unittests for `mesh_ops.extrude`, moved verbatim out of source/mesh_ops/extrude.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.extrude_test;

import mesh;
import math;
import std.math : sqrt;
import std.algorithm : sort;
import mesh_ops.extrude;

// task 1903 Stage H: every kernel in this family now takes `ref MeshEditBatch`
// — this file calls all FIVE directly on a bare `Mesh`, so every call site
// needs a batch. ONE generic helper rather than five near-identical ones
// (F1's `sliceOnce` / F2's `bevelOnce` shape, generalised over the KERNEL
// itself via an `alias` template parameter, since this file is the one place
// that exercises every kernel in the family): open an UNRECORDED batch (these
// are geometry/topology fixtures, not op-log fixtures), call the kernel,
// close, return its count. `Args` forwards each kernel's own parameter list
// verbatim, so every call site below changes only its receiver spelling.
version (unittest) private size_t kernelOnce(alias fn, Args...)(ref Mesh m, Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kExtrudeEditScope);
    immutable n = fn(ed, args);
    ed.close();
    return n;
}

// Mesh-robustness batch (fuzz-found): a standalone open n-gon (single
// face, open boundary loop) whose corners are all SHARED (>=2 selected
// boundary edges per corner) run through an overshoot `width` at
// `extrude=0` used to mint a coincident duplicate vertex at each original
// corner position — the Pass-1 ridge vertex always minted a NEW vertex
// via addVertex(v + dir*extrude) even when extrude=0 (where dir*extrude
// is exactly the zero vector). Fixed: Pass 1 reuses the original vertex
// id at extrude≈0 instead. Confirmed by an HTTP-level before/after probe:
// a regular pentagon, all 5 boundary edges selected, extrude=0/width=0.3
// produced V=15 (5 coincident pairs) before the fix, V=10 (none) after.
unittest {
    import std.conv : to;

    // Regular pentagon: single open-boundary face, every corner shared
    // by exactly 2 boundary edges (a chain-joint corner, not a free end).
    Mesh m;
    import std.math : PI, cos, sin;
    uint[] pent;
    foreach (k; 0 .. 5) {
        double ang = 2 * PI * k / 5 - PI / 2;
        pent ~= m.addVertex(Vec3(cast(float)cos(ang), 0, cast(float)sin(ang)));
    }
    m.addFace(pent);

    bool[] mask; mask.length = m.edges.length; mask[] = true;
    size_t n = kernelOnce!extrudeEdgesByMask(m, mask, 0.0f, 0.3f);
    assert(n == 5, "pentagon shared-corner extrude=0: expected 5 edges extruded, got " ~ n.to!string);

    // No coincident duplicate vertices.
    foreach (i; 0 .. m.vertices.length) {
        foreach (j; i + 1 .. m.vertices.length) {
            Vec3 d = m.vertices[i] - m.vertices[j];
            float d2 = d.x*d.x + d.y*d.y + d.z*d.z;
            assert(d2 > 1e-8f,
                "pentagon shared-corner extrude=0: verts " ~ i.to!string ~
                " and " ~ j.to!string ~ " are coincident");
        }
    }

    // Edge-manifold: every undirected edge used by at most 2 faces.
    size_t[ulong] edgeUseCount;
    foreach (fi; 0 .. m.faces.length) {
        auto f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            ulong key = edgeKey(f[k], f[(k + 1) % f.length]);
            auto p = key in edgeUseCount;
            if (p is null) edgeUseCount[key] = 1;
            else           ++(*p);
        }
    }
    foreach (key, count; edgeUseCount)
        assert(count <= 2,
            "pentagon shared-corner extrude=0: non-manifold edge used by " ~
            count.to!string ~ " faces");
}

// Boundary-loop DROP-SHIFT rule (parity): the reference applies only `inset`
// to BOUNDARY edges (single adjacent face) and drops `shift` entirely —
// measured against the reference engine on a flat open-boundary rim loop:
// shift-only leaves the mesh unchanged, and shift+inset produces exactly the
// inset-only result (no lifted band). vibe3d already honours this for a
// single boundary edge (width-only chamfer); this locks in the SAME rule for
// a boundary LOOP whose corners are all shared, which previously lifted a
// spurious band along the face normal. INTERIOR edges keep their shift band
// (covered by the cube/coplanar reference cases), so this is scoped to the
// all-boundary loop.
unittest {
    import std.conv : to;
    import std.math : abs;

    // Flat open quad in the y=0 plane (+Y normal): its 4 edges are all
    // boundary edges and its 4 corners are each shared by 2 of them.
    Vec3[4] corners = [Vec3(-0.5f, 0, -0.5f), Vec3(0.5f, 0, -0.5f),
                       Vec3(0.5f, 0, 0.5f),   Vec3(-0.5f, 0, 0.5f)];
    Mesh mkQuad() {
        Mesh q;
        uint[] r;
        foreach (ref c; corners) r ~= q.addVertex(c);
        q.addFace(r);
        return q;
    }

    // shift+inset on the boundary loop: shift must be dropped → NO lift.
    Mesh mShiftInset = mkQuad();
    {
        bool[] mask; mask.length = mShiftInset.edges.length; mask[] = true;
        kernelOnce!extrudeEdgesByMask(mShiftInset, mask, 0.2f, 0.1f);
    }
    foreach (i; 0 .. mShiftInset.vertices.length)
        assert(abs(mShiftInset.vertices[i].y) < 1e-4f,
            "boundary-loop shift+inset: vertex " ~ i.to!string ~
            " lifted off the boundary plane to y=" ~
            mShiftInset.vertices[i].y.to!string ~ " (shift not dropped)");

    // inset-only: same rim loop, no shift. shift+inset must equal this.
    Mesh mInsetOnly = mkQuad();
    {
        bool[] mask; mask.length = mInsetOnly.edges.length; mask[] = true;
        kernelOnce!extrudeEdgesByMask(mInsetOnly, mask, 0.0f, 0.1f);
    }
    assert(mShiftInset.vertices.length == mInsetOnly.vertices.length,
        "boundary-loop shift+inset vs inset-only: vertex count differs (" ~
        mShiftInset.vertices.length.to!string ~ " vs " ~
        mInsetOnly.vertices.length.to!string ~ ")");
    assert(mShiftInset.faces.length == mInsetOnly.faces.length,
        "boundary-loop shift+inset vs inset-only: face count differs (" ~
        mShiftInset.faces.length.to!string ~ " vs " ~
        mInsetOnly.faces.length.to!string ~ ")");
    // Every shift+inset vertex has a coincident inset-only counterpart.
    foreach (i; 0 .. mShiftInset.vertices.length) {
        bool matched = false;
        foreach (j; 0 .. mInsetOnly.vertices.length) {
            Vec3 dd = mShiftInset.vertices[i] - mInsetOnly.vertices[j];
            if (dd.x*dd.x + dd.y*dd.y + dd.z*dd.z < 1e-8f) { matched = true; break; }
        }
        assert(matched,
            "boundary-loop shift+inset: vertex " ~ i.to!string ~
            " has no inset-only counterpart (shift changed the geometry)");
    }

    // shift-only on the boundary loop leaves the rim unchanged (no inset room,
    // shift dropped) — the mesh stays the original quad.
    Mesh mShiftOnly = mkQuad();
    {
        bool[] mask; mask.length = mShiftOnly.edges.length; mask[] = true;
        kernelOnce!extrudeEdgesByMask(mShiftOnly, mask, 0.2f, 0.0f);
    }
    assert(mShiftOnly.vertices.length == 4 && mShiftOnly.faces.length == 1,
        "boundary-loop shift-only: expected the original quad (4v/1f), got " ~
        mShiftOnly.vertices.length.to!string ~ "v/" ~
        mShiftOnly.faces.length.to!string ~ "f");
    foreach (i; 0 .. mShiftOnly.vertices.length)
        assert(abs(mShiftOnly.vertices[i].y) < 1e-4f,
            "boundary-loop shift-only: vertex " ~ i.to!string ~ " lifted");
}

// edge.extrude free-end ridge uses PER-CORNER normals on non-planar faces
// (parity-measured bit-exact vs the reference on cc1 + twisted 2-quad tents).
// A single interior edge shared by two TWISTED (non-planar) quads is
// extruded; its two free ends must lift along DIFFERENT directions — each
// the sum of its own faces' per-corner normals — NOT the shared whole-face
// Newell average (which would lift both ends identically and miss the
// reference by ~0.015). A PLANAR tent is the byte-identical control: there
// the per-corner normal equals the face normal, so both ends lift the same.
unittest {
    import std.conv : to;
    import std.math : abs, sqrt;

    // Build a tent: two quads sharing the interior edge P0-P1 (along Z).
    // `warp` twists each quad's far edge in Y, making the quads non-planar
    // by different amounts on the two sides (asymmetric).
    Mesh mkTent(float warp) {
        Mesh m;
        uint p0 = m.addVertex(Vec3(0, 0, -1));           // 0
        uint p1 = m.addVertex(Vec3(0, 0, 1));            // 1
        uint a1 = m.addVertex(Vec3(1, -0.3f + warp, 1)); // 2
        uint a0 = m.addVertex(Vec3(1, -0.3f, -1));       // 3
        uint b0 = m.addVertex(Vec3(-1, -0.3f, -1));      // 4
        uint b1 = m.addVertex(Vec3(-1, -0.3f - warp, 1));// 5
        m.addFace([p0, p1, a1, a0]);
        m.addFace([p1, p0, b0, b1]);
        return m;
    }
    // Mask selecting only the shared interior edge (endpoints {0,1}).
    bool[] edgeMask(ref Mesh m) {
        bool[] mask; mask.length = m.edges.length;
        foreach (i; 0 .. m.edges.length) {
            uint a = m.edges[i][0], b = m.edges[i][1];
            if ((a == 0 && b == 1) || (a == 1 && b == 0)) mask[i] = true;
        }
        return mask;
    }
    // Does the mesh contain a vertex at `p` (within tol)?
    bool hasVert(ref Mesh m, Vec3 p, float tol) {
        foreach (i; 0 .. m.vertices.length) {
            Vec3 d = m.vertices[i] - p;
            if (sqrt(d.x*d.x + d.y*d.y + d.z*d.z) < tol) return true;
        }
        return false;
    }

    // NON-planar (warp 0.2): the two free-end ridges land on distinct,
    // reference-matched positions — P0 straight down (its faces are locally
    // symmetric there), P1 tilted (its faces twist away). A whole-face Newell
    // average would place BOTH at (±0.0137, -0.149, ±1) — see the negative
    // assertions — so these pin the per-corner-normal behaviour.
    {
        Mesh m = mkTent(0.2f);
        auto mask = edgeMask(m);
        kernelOnce!extrudeEdgesByMask(m, mask, -0.15f, 0.1f);
        assert(hasVert(m, Vec3(0.0f, -0.15f, -1.0f), 1e-4f),
            "non-planar free-end ridge P0 not at per-corner position (0,-0.15,-1)");
        assert(hasVert(m, Vec3(0.027148f, -0.147523f, 1.0f), 1e-4f),
            "non-planar free-end ridge P1 not at per-corner position (0.0271,-0.1475,1)");
        // The old whole-face-Newell ridge for P1 was (~0.0137,-0.1494,1); the
        // fix must NOT leave a vertex there.
        assert(!hasVert(m, Vec3(0.0137f, -0.1494f, 1.0f), 1e-4f),
            "free-end ridge P1 still at the whole-face-Newell position (fix inactive)");
        // Each ridge is displaced by exactly |extrude| perpendicular to the
        // Z-aligned shared edge (z unchanged).
        assert(hasVert(m, Vec3(0.0f, -0.15f, -1.0f), 1e-4f), "P0 ridge z shifted");
    }

    // PLANAR control (warp 0): per-corner == face normal, so BOTH free ends
    // lift to the identical (x,y) — byte-identical to the pre-fix Newell path.
    {
        Mesh m = mkTent(0.0f);
        auto mask = edgeMask(m);
        kernelOnce!extrudeEdgesByMask(m, mask, -0.15f, 0.1f);
        // Symmetric flat tent: both ridges share the same (x,y), differing
        // only in z (the two edge endpoints). Find them and compare.
        Vec3[] ridges;
        foreach (i; 0 .. m.vertices.length) {
            // ridge verts sit ~|extrude| below the y=-0.15 line near x=0
            Vec3 p = m.vertices[i];
            if (abs(p.x) < 0.05f && p.y < -0.1f) ridges ~= p;
        }
        assert(ridges.length == 2,
            "planar tent: expected 2 free-end ridges, got " ~ ridges.length.to!string);
        assert(abs(ridges[0].x - ridges[1].x) < 1e-5f &&
               abs(ridges[0].y - ridges[1].y) < 1e-5f,
            "planar tent free-end ridges diverged in (x,y) — per-corner path " ~
            "must reduce to the face normal on planar faces");
    }
}

unittest {
    import std.math : abs;

    // Single-face extrude: cube face 0, distance 0.5.
    // Cube: 6 faces, 8 verts. After extruding one quad face:
    // 5 orig + 1 cap + 4 walls = 10 faces; 8 orig + 4 clones = 12 verts.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
        Vec3 origC = m.faceCentroid(0);
        Vec3 origN = m.faceNormal(0);
        size_t n = kernelOnce!extrudeFacesByMask(m, mask, 0.5f);
        assert(n > 0,
            "extrudeFacesByMask: returned 0 on valid single-face selection");
        assert(m.faces.length == 10,
            "extrudeFacesByMask: expected 10 faces after single-face extrude");
        assert(m.vertices.length == 12,
            "extrudeFacesByMask: expected 12 verts after single-face extrude");
        // Cap face is selected after the op; find it.
        int capFi = -1;
        foreach (fi; 0 .. m.faces.length)
            if (m.isFaceSelected(fi)) { capFi = cast(int)fi; break; }
        assert(capFi >= 0, "extrudeFacesByMask: no cap face selected after op");
        Vec3 capC = m.faceCentroid(cast(uint)capFi);
        Vec3 exp  = origC + origN * 0.5f;
        assert(abs(capC.x - exp.x) < 1e-4f &&
               abs(capC.y - exp.y) < 1e-4f &&
               abs(capC.z - exp.z) < 1e-4f,
            "extrudeFacesByMask: cap centroid not offset by 0.5 along face normal");
    }

    // distance == 0 → no-op (topology and vert count unchanged).
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
        size_t n = kernelOnce!extrudeFacesByMask(m, mask, 0.0f);
        assert(n == 0,
            "extrudeFacesByMask: distance==0 must return 0");
        assert(m.faces.length == 6,
            "extrudeFacesByMask: distance==0 changed face count");
        assert(m.vertices.length == 8,
            "extrudeFacesByMask: distance==0 changed vert count");
    }

    // Closed island (all 6 cube faces) → no boundary edges → no-op.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = true;
        size_t n = kernelOnce!extrudeFacesByMask(m, mask, 0.5f);
        assert(n == 0,
            "extrudeFacesByMask: closed island must return 0");
        assert(m.faces.length == 6,
            "extrudeFacesByMask: closed island changed face count");
        assert(m.vertices.length == 8,
            "extrudeFacesByMask: closed island changed vert count");
    }

    // ── Smooth-shift discriminator: symmetric two-quad tent ──────────────
    // Geometry:
    //   v0=(-1,0,0)  v1=(-1,0,1)   — outer left
    //   v2=( 0,1,0)  v3=( 0,1,1)   — ridge (shared by both faces)
    //   v4=( 1,0,0)  v5=( 1,0,1)   — outer right
    //   face 0: [0,1,3,2]   face 1: [2,3,5,4]
    //
    // Face normals (Newell):
    //   n0 = (-1/√2,  1/√2, 0)
    //   n1 = ( 1/√2,  1/√2, 0)
    //   regionNormal = (0, 1, 0)          (normalized n0+n1)
    //   smooth-ridge avg = normalize(n0+n1) = (0, 1, 0)  ← same as rigid
    //   smooth-outer-left  = n0            ← differs from rigid
    //   smooth-outer-right = n1            ← differs from rigid
    //
    // The RIDGE assertion is the ordering-bug discriminator: if the
    // vertOffset were accumulated inside the clone loop, the ridge vert
    // would be offset by only the FIRST face's normal (n0 or n1),
    // placing it at (~±0.354, ~1.354, *) instead of (0, 1.5, *).

    // Test A: smooth=true — verify ridge AND outer-vert positions.
    {
        import std.math : abs, sqrt;
        Mesh m;
        m.vertices = [
            Vec3(-1, 0, 0), Vec3(-1, 0, 1),   // 0,1 outer-left
            Vec3( 0, 1, 0), Vec3( 0, 1, 1),   // 2,3 ridge
            Vec3( 1, 0, 0), Vec3( 1, 0, 1),   // 4,5 outer-right
        ];
        m.addFace([0u, 1u, 3u, 2u]);  // left face
        m.addFace([2u, 3u, 5u, 4u]);  // right face
        m.buildLoops();

        bool[] mask; mask.length = 2; mask[] = true;
        size_t n = kernelOnce!extrudeFacesByMask(m, mask, 0.5f, true);
        assert(n > 0, "smooth tent: returned 0");

        // Ridge cap verts: v2=(0,1,0) and v3=(0,1,1) offset by (0,1,0)*0.5
        //   → clone at (0, 1.5, 0) and (0, 1.5, 1).
        // If ordering-bug present: ridge offset by n0 only → (≈-0.354, ≈1.354, *)
        bool ridgeFront = false, ridgeBack = false;
        // Outer-left cap: v0=(-1,0,0) offset by n0*0.5 → x ≈ -1-0.5/√2 ≈ -1.354
        bool outerLeft = false;
        // Outer-right cap: v4=(1,0,0) offset by n1*0.5 → x ≈ 1+0.5/√2 ≈ 1.354
        bool outerRight = false;
        immutable float halfOverSqrt2 = 0.5f / sqrt(2.0f);
        foreach (v; m.vertices) {
            // Ridge front clone
            if (abs(v.x) < 1e-4f && abs(v.y - 1.5f) < 1e-4f &&
                abs(v.z) < 1e-4f)
                ridgeFront = true;
            // Ridge back clone
            if (abs(v.x) < 1e-4f && abs(v.y - 1.5f) < 1e-4f &&
                abs(v.z - 1.0f) < 1e-4f)
                ridgeBack = true;
            // Outer-left clone (x < -1, y ≈ halfOverSqrt2)
            if (abs(v.x - (-1.0f - halfOverSqrt2)) < 1e-4f &&
                abs(v.y - halfOverSqrt2) < 1e-4f)
                outerLeft = true;
            // Outer-right clone (x > 1, y ≈ halfOverSqrt2)
            if (abs(v.x - (1.0f + halfOverSqrt2)) < 1e-4f &&
                abs(v.y - halfOverSqrt2) < 1e-4f)
                outerRight = true;
        }
        assert(ridgeFront,
            "smooth tent: ridge front clone not at (0,1.5,0) — " ~
            "ordering bug? (in-loop accum offsets ridge by first-face normal only)");
        assert(ridgeBack,
            "smooth tent: ridge back clone not at (0,1.5,1)");
        assert(outerLeft,
            "smooth tent: outer-left clone not offset along face-0 normal");
        assert(outerRight,
            "smooth tent: outer-right clone not offset along face-1 normal");
    }

    // Test B: smooth=true on a single flat face == smooth=false (rigid).
    // With one selected face, faceNormal IS the regionNormal, so every
    // cap vertex gets the same offset regardless of mode.
    {
        import std.math : abs;
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        mask[0] = true;
        Vec3 origC = m.faceCentroid(0);
        Vec3 origN = m.faceNormal(0);
        size_t n = kernelOnce!extrudeFacesByMask(m, mask, 0.5f, true);
        assert(n > 0, "smooth flat single-face: returned 0");
        // Find cap face (selected after the op).
        int capFi = -1;
        foreach (fi; 0 .. m.faces.length)
            if (m.isFaceSelected(fi)) { capFi = cast(int)fi; break; }
        assert(capFi >= 0, "smooth flat single-face: no cap selected");
        Vec3 capC = m.faceCentroid(cast(uint)capFi);
        Vec3 exp  = origC + origN * 0.5f;
        assert(abs(capC.x - exp.x) < 1e-4f &&
               abs(capC.y - exp.y) < 1e-4f &&
               abs(capC.z - exp.z) < 1e-4f,
            "smooth flat single-face: cap centroid differs from rigid extrude");
    }
}

// Task 0312 (fuzz-found): a diagonal/checkerboard face pair that shares
// only a single vertex (no shared edge) must extrude as TWO independent
// islands, each with its own inset vertex at the shared corner. Before
// the fix, a single merged clone at that corner had its cap-side
// vertical edge walled by both islands at once — an edge used by 4
// faces. Assert the post-extrude mesh is edge-manifold (every undirected
// edge used by ≤2 faces), matching the HTTP repro:
//   /api/reset?type=grid&n=2; select polygons [1,2]; poly.extrude 1.0
unittest {
    import std.conv : to;

    auto m = makeGridPlane(2);
    // 2x2 grid: faces 1 and 2 (row0/col1 and row1/col0) touch only at
    // the shared center vertex — the diagonal/checkerboard pair.
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[1] = true;
    mask[2] = true;
    size_t n = kernelOnce!extrudeFacesByMask(m, mask, 1.0f);
    assert(n == 2, "diagonal pair: expected 2 faces extruded");

    // Recount every undirected edge across ALL faces directly (NOT via
    // buildEdgeFaces — its 2-slot [int;2] silently drops a 3rd/4th
    // incident face instead of flagging it, so it can't witness this
    // bug). A count > 2 anywhere means a non-manifold edge.
    size_t[ulong] edgeUseCount;
    foreach (fi; 0 .. m.faces.length) {
        auto f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            ulong key = edgeKey(f[k], f[(k + 1) % f.length]);
            auto p = key in edgeUseCount;
            if (p is null) edgeUseCount[key] = 1;
            else           ++(*p);
        }
    }
    foreach (key, count; edgeUseCount)
        assert(count <= 2,
            "diagonal pair extrude: non-manifold edge used by " ~
            count.to!string ~ " faces (task 0312 regression)");
}

// Mesh-robustness batch (fuzz-found): a "book" edge — one undirected edge
// shared by 3 faces (non-manifold input) — must reject the whole extrude
// as a clean no-op, not attempt to extrude into the already-invalid
// neighborhood. A normal disjoint 2-face pair (no book edge) must still
// extrude as before (no over-reject).
unittest {
    import std.conv : to;
    // Book mesh: 3 quad "pages" all hinged on the shared edge (v0,v1).
    //   page A: v0,v1,v2,v3   (in the XY... here XZ-ish plane, x>0)
    //   page B: v0,v1,v4,v5   (rotated: z>0)
    //   page C: v0,v1,v6,v7   (rotated: x<0)
    // Undirected edge (0,1) is used by all 3 pages => incidence count 3.
    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(0, 1, 0));
    uint v2 = m.addVertex(Vec3(1, 1, 0));
    uint v3 = m.addVertex(Vec3(1, 0, 0));
    uint v4 = m.addVertex(Vec3(0, 1, 1));
    uint v5 = m.addVertex(Vec3(0, 0, 1));
    uint v6 = m.addVertex(Vec3(-1, 1, 0));
    uint v7 = m.addVertex(Vec3(-1, 0, 0));
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v0, v1, v4, v5]);
    m.addFace([v0, v1, v6, v7]);

    size_t vertsBefore = m.vertices.length;
    size_t facesBefore = m.faces.length;
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[0] = true; // select page A, which touches the book edge (0,1)
    size_t n = kernelOnce!extrudeFacesByMask(m, mask, 1.0f);
    assert(n == 0, "book-edge extrude: expected reject (0), got " ~ n.to!string);
    assert(m.vertices.length == vertsBefore,
        "book-edge extrude: reject must not add verts");
    assert(m.faces.length == facesBefore,
        "book-edge extrude: reject must not add faces");

    // A normal disjoint 2-face pair (not touching the book edge) must
    // still extrude normally — the guard must not over-reject.
    Mesh gm = makeGridPlane(2);
    bool[] gmask; gmask.length = gm.faces.length; gmask[] = false;
    gmask[0] = true; gmask[1] = true; // adjacent quads, shared edge used by only 2 faces
    size_t gn = kernelOnce!extrudeFacesByMask(gm, gmask, 1.0f);
    assert(gn == 2, "disjoint pair extrude: expected 2 faces extruded, got " ~ gn.to!string);
}

unittest {
    import std.math : abs;
    import std.conv : to;

    // base_noop: shift=0, scale=1, thicken=false, single top-face
    // selection on a stock cube. Matches the frozen reference capture
    // (tests/fixtures/smooth_shift.json "base_noop") — 12v/10f, NOT a
    // no-op (see the kernel doc comment on the shift==0 divergence).
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        // Find the top face (all 4 verts at y ≈ +0.5).
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        assert(topFi >= 0, "smoothShiftFacesByMask test: no top face found");
        mask[topFi] = true;
        size_t n = kernelOnce!smoothShiftFacesByMask(m, mask, 0.0f, 1.0f, false);
        assert(n == 1, "smoothShiftFacesByMask base_noop: expected 1 face cloned");
        assert(m.faces.length == 10,
            "smoothShiftFacesByMask base_noop: expected 10 faces, got " ~ m.faces.length.to!string);
        assert(m.vertices.length == 12,
            "smoothShiftFacesByMask base_noop: expected 12 verts, got " ~ m.vertices.length.to!string);
    }

    // shift03_scale05: shift=0.3, scale=0.5 — pins the scale-about-
    // island-centroid law exactly (frozen capture "shift03_scale05").
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        mask[topFi] = true;
        size_t n = kernelOnce!smoothShiftFacesByMask(m, mask, 0.3f, 0.5f, false);
        assert(n == 1, "smoothShiftFacesByMask shift03_scale05: expected 1 face cloned");
        // Expect a new vertex at (-0.25, 0.65, -0.25) (corner (-0.5,0.5,-0.5)
        // shifted+scaled about the top face's centroid (0,0.5,0)).
        bool found = false;
        foreach (v; m.vertices) {
            if (abs(v.x - (-0.25f)) < 1e-3f && abs(v.y - 0.65f) < 1e-3f &&
                abs(v.z - (-0.25f)) < 1e-3f) { found = true; break; }
        }
        assert(found, "smoothShiftFacesByMask shift03_scale05: no cap vert at (-0.25,0.65,-0.25)");
    }

    // thicken_top_only: shift=0.3, thicken=true — retains the original
    // top face as an 11th polygon (frozen capture "thicken_top_only").
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        mask[topFi] = true;
        size_t n = kernelOnce!smoothShiftFacesByMask(m, mask, 0.3f, 1.0f, true);
        assert(n == 1, "smoothShiftFacesByMask thicken_top_only: expected 1 face cloned");
        assert(m.faces.length == 11,
            "smoothShiftFacesByMask thicken_top_only: expected 11 faces, got " ~ m.faces.length.to!string);
        assert(m.vertices.length == 12,
            "smoothShiftFacesByMask thicken_top_only: expected 12 verts, got " ~ m.vertices.length.to!string);
        // The retained face's 4 verts must all still be at y ≈ 0.5 (unmoved).
        int retainedCount = 0;
        foreach (fi; 0 .. m.faces.length) {
            if (m.faces[fi].length != 4) continue;
            bool allOrigTop = true;
            foreach (vid; m.faces[fi])
                if (abs(m.vertices[vid].y - 0.5f) > 1e-3f) { allOrigTop = false; break; }
            if (allOrigTop) ++retainedCount;
        }
        assert(retainedCount >= 1,
            "smoothShiftFacesByMask thicken_top_only: no retained (unmoved) top face found");
    }
}

unittest { // extendEdgesByMask: wire-edge / no-op — mask selecting nothing returns 0
    Mesh m = makeCube();
    auto v0 = m.vertices.length;
    auto f0 = m.faces.length;
    auto mut0 = m.mutationVersion;
    bool[] empty; empty.length = m.edges.length;   // all false
    auto n = kernelOnce!extendEdgesByMask(m, empty, 0.1f, 0.2f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 0, "no-op returns 0");
    assert(m.vertices.length == v0 && m.faces.length == f0, "no-op: mesh unchanged");
    assert(m.mutationVersion == mut0, "no-op: no version bump");
}

// extrudeVerticesByMask (task 0360 cone/ring kernel rewrite): cube corner 0
// at (-0.5,-0.5,-0.5), width=0.2, shift=0. Corner 0 (valence 3) gets a
// stationary apex + a 6-vertex/6-face ring (2 new verts + 2 new faces per
// incident edge — see the kernel's own doc-comment for the full law).
// Selection is untouched (still vertex 0 — the apex never moves or gets
// re-indexed).
unittest {
    import std.math : abs;
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.selectVertex(0);
    const size_t oldV = m.vertices.length; // 8
    const size_t oldF = m.faces.length;    // 6

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;  // corner (-0.5,-0.5,-0.5)
    size_t processed = kernelOnce!extrudeVerticesByMask(m, mask, 0.0f, 0.2f);

    assert(processed == 1,                "extrudeVerticesByMask: should process 1 vertex");
    assert(m.vertices.length == oldV + 6, "extrudeVerticesByMask: expected +6 verts");
    assert(m.faces.length    == oldF + 6, "extrudeVerticesByMask: expected +6 faces");

    // Apex (vertex 0) unmoved.
    Vec3 apex = m.vertices[0];
    assert(abs(apex.x - (-0.5f)) < 1e-5f &&
           abs(apex.y - (-0.5f)) < 1e-5f &&
           abs(apex.z - (-0.5f)) < 1e-5f,
           "extrudeVerticesByMask: apex must stay at its original position");

    // Three ring points at exactly width=0.2 along each incident edge.
    Vec3[3] expectedRing = [Vec3(-0.3f, -0.5f, -0.5f),
                            Vec3(-0.5f, -0.3f, -0.5f),
                            Vec3(-0.5f, -0.5f, -0.3f)];
    foreach (e; expectedRing) {
        bool found = false;
        foreach (v; m.vertices) {
            Vec3 d = v - e;
            if (d.x*d.x + d.y*d.y + d.z*d.z < 1e-8f) { found = true; break; }
        }
        assert(found, "extrudeVerticesByMask: ring point not found");
    }

    // Selection untouched: vertex 0 (the apex) is still the only selected vert.
    assert(m.isVertexSelected(0), "extrudeVerticesByMask: apex must remain selected");
}

// extrudeVerticesByMask: width=0 is a no-op regardless of shift (confirmed
// reference law, task 0360 — shift alone never moves anything).
unittest {
    auto m = makeCube();
    m.buildLoops();
    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t processed = kernelOnce!extrudeVerticesByMask(m, mask, 0.5f, 0.0f);
    assert(processed == 0,          "extrudeVerticesByMask: width=0 must be no-op");
    assert(m.vertices.length == 8,  "extrudeVerticesByMask: width=0 must not add verts");
    assert(m.faces.length    == 6,  "extrudeVerticesByMask: width=0 must not add faces");
}

// Task 0724 / audit-4 M6 — the settled-mesh precondition on
// extrudeVerticesByMask is LIVE, i.e. it CAN fail. That is the whole
// question the rollout had to answer for each site, and for the two mesh_ops
// kernels the answer is demonstrable rather than argued: `addFaceFast` fills
// `edges` while deliberately leaving `edgeIndexMap` stale (it takes the
// caller's scratch lookup and defers the canonical map to a terminal
// buildLoops), and that is not a synthetic state — it is exactly how every
// importer assembles a mesh (io/scene_ir.d, io/native.d, remesh). Those all
// call buildLoops() before anyone can run a kernel on the result, which is
// why no caller trips this today; drop that call and the kernel would read
// `edgeIndexMap[edgeKey(...)]` off a map built for a different topology.
//
// Wrapped in `debug` because the assertion it exercises is `debug assert` —
// stripped from -release, so the throw only exists in the builds that
// actually carry the check (dub test / dub build; not the shipped binary).
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;

        Mesh m;
        uint[ulong] scratch;
        m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
        m.addFaceFast(scratch, [0u, 1u, 2u, 3u]);
        assert(m.edges.length == 4,
            "setup: addFaceFast must still append the quad's four edges");
        assert(!m.edgeMapUsable(),
            "setup: addFaceFast defers the canonical map, so it must read unusable");

        bool[] mask = new bool[](m.vertices.length);
        mask[0] = true;
        assertThrown!AssertError(kernelOnce!extrudeVerticesByMask(m, mask, 0.0f, 0.1f),
            "extrudeVerticesByMask must refuse a mesh whose edgeIndexMap was "
            ~ "never rebuilt -- if this stops throwing, the precondition has "
            ~ "become decoration");

        // ...and the SAME call is fine once the caller settles the mesh, so
        // the assert is discriminating between two states, not refusing the
        // kernel outright.
        m.buildLoops();
        assert(m.edgeMapUsable(), "setup: buildLoops must restore the map");
        kernelOnce!extrudeVerticesByMask(m, mask, 0.0f, 0.1f);
    }
}

// ===========================================================================
// Task 1902 Stage D — value-carry witnesses for the four extrude.d
// face-rewrite sites migrated onto mesh_planes.rewriteFaces. None of the
// existing structural tests in tests/test_edge_extrude*.d / test_face_extrude*
// / test_smooth_shift*.d assert a surviving/created face's faceMaterial or
// facePart BY VALUE after the op (plan §8's "no existing test asserts extrude
// material by value") — they check coincidence/orphan/winding/repeated-corner
// invariants, which are satisfied identically whether or not a plane's carry
// is byte-correct. These four are the missing witnesses, one per site.
// ===========================================================================

// Site 14 — extrudeEdgesByMask's degenerate-collapse COMPACTION branch
// (`if (anyDrop) { … rewriteFaces(this, keptFaces, FaceSource.fromOldToNew(
// faceRemap, keptFaces.length)); … }`). This branch only runs when a
// far-vertex overshoot clamp collapses some face to <3 corners — the
// ordinary (non-overshooting) extrude path never reaches it. Fixture: the
// fuzz-0321b trapezoid (test 18, tests/test_edge_extrude.d) — an isosceles-
// trapezoid frustum whose -X side face's four cap-miter corners mutually
// converge to ONE point (its own centroid) when all four of its own edges
// are selected with a large overshoot width, collapsing THAT ONE selected
// face to a single vertex and dropping it. The other 5 original faces are
// untouched by the collapse and must survive, in construction order, with
// their OWN material/part — not the compacted array's zero-filled default,
// and not a neighbour's value shifted in by a front-truncated slice (task
// 0921's class).
unittest {
    import std.conv : to;

    Mesh m;
    uint v0 = m.addVertex(Vec3(-0.5, -0.5, -0.5));
    uint v1 = m.addVertex(Vec3( 0.5, -0.5, -0.5));
    uint v2 = m.addVertex(Vec3( 0.5,  0.5, -0.5));
    uint v3 = m.addVertex(Vec3(-0.5,  0.5, -0.5));
    uint v4 = m.addVertex(Vec3(-0.15, -0.15, 0.5));
    uint v5 = m.addVertex(Vec3( 0.15, -0.15, 0.5));
    uint v6 = m.addVertex(Vec3( 0.15,  0.15, 0.5));
    uint v7 = m.addVertex(Vec3(-0.15,  0.15, 0.5));
    m.addFace([v0, v3, v2, v1]);   // face 0 — bottom
    m.addFace([v4, v5, v6, v7]);   // face 1 — top
    m.addFace([v0, v4, v7, v3]);   // face 2 — -X side (collapses and drops)
    m.addFace([v1, v2, v6, v5]);   // face 3 — +X side
    m.addFace([v3, v7, v6, v2]);   // face 4 — +Y side
    m.addFace([v0, v1, v5, v4]);   // face 5 — -Y side
    m.resetSelection();

    static immutable uint[6] wantMat  = [1000, 1001, 1002, 1003, 1004, 1005];
    static immutable uint[6] wantPart = [2000, 2001, 2002, 2003, 2004, 2005];
    foreach (fi; 0 .. 6) {
        m.faceMaterial[fi] = wantMat[fi];
        m.facePart[fi]     = wantPart[fi];
    }

    uint e04 = m.edgeIndex(v0, v4), e47 = m.edgeIndex(v4, v7);
    uint e73 = m.edgeIndex(v7, v3), e30 = m.edgeIndex(v3, v0);
    assert(e04 != ~0u && e47 != ~0u && e73 != ~0u && e30 != ~0u,
        "trapezoid: -X side-face edges not found");
    bool[] mask = new bool[](m.edges.length);
    mask[e04] = mask[e47] = mask[e73] = mask[e30] = true;

    size_t n = kernelOnce!extrudeEdgesByMask(m, mask, 0.0f, 10.0f);
    assert(n == 4, "trapezoid: expected 4 edges extruded, got " ~ n.to!string);

    // Face 2 (the mutually-converging -X side) must have collapsed and
    // dropped via the anyDrop compaction: 5 surviving originals + 8
    // bridge/cap faces (2 per extruded edge).
    assert(m.faces.length == 5 + 4 * 2,
        "trapezoid: expected 5 surviving originals + 8 bridge/cap faces, got "
        ~ m.faces.length.to!string);

    // The 5 survivors keep their CONSTRUCTION order in the compacted array
    // (Mesh.extrudeEdgesByMask's cleanup pass iterates faceIndices in order,
    // skipping only the dropped index) — faces 0,1,3,4,5, landing at output
    // positions 0..4.
    static immutable uint[5] survivingMat  = [1000, 1001, 1003, 1004, 1005];
    static immutable uint[5] survivingPart = [2000, 2001, 2003, 2004, 2005];
    foreach (i; 0 .. 5) {
        assert(m.faceMaterial[i] == survivingMat[i],
            "trapezoid: surviving face at position " ~ i.to!string ~ " must "
            ~ "keep its OWN material through the degenerate-collapse "
            ~ "compaction (got " ~ m.faceMaterial[i].to!string ~ ", want "
            ~ survivingMat[i].to!string ~ ")");
        assert(m.facePart[i] == survivingPart[i],
            "trapezoid: surviving face at position " ~ i.to!string ~ " must "
            ~ "keep its OWN part through the degenerate-collapse compaction "
            ~ "(got " ~ m.facePart[i].to!string ~ ", want "
            ~ survivingPart[i].to!string ~ ")");
    }
}

// Site 15 — extrudeVerticesByMask's single rebuild pass: identity head
// (every substituted/surviving face keeps its own old index) + `nf.srcFi`
// tail (every freshly created rim/fan face inherits material/part/marks
// from the ORIGINAL face it was cut from) flattened into one total
// `oldOfNew`. faceSelectionOrder is the one plane that does NOT follow this
// rule — a rim/fan face must start unselected (order 0) regardless of its
// source's own order stamp, patched back right after the primitive call.
unittest {
    import std.conv : to;

    Mesh m = makeGridPlane(3);   // 3x3 grid, 9 quads; vertex 5 is interior (valence 4)
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(1000 + fi);
        m.facePart[fi]     = cast(uint)(2000 + fi);
    }
    // A non-zero order stamp on ONE of vertex 5's four incident faces (face
    // 4), so a bug that inherits faceSelectionOrder on the tail (instead of
    // zeroing it) is observable rather than coincidentally already 0.
    m.faceSelectionOrder[4] = 77;

    bool[] mask = new bool[](m.vertices.length);
    mask[5] = true;   // interior vertex shared by faces 0, 1, 3, 4

    size_t n = kernelOnce!extrudeVerticesByMask(m, mask, 0.0f, 0.1f);
    assert(n == 1, "grid vertex-extrude: expected 1 accepted vertex, got " ~ n.to!string);
    assert(m.faces.length == 9 + 4 * 2,
        "grid vertex-extrude: expected 9 substituted + 8 rim/fan faces, got "
        ~ m.faces.length.to!string);

    // Head: every substituted/surviving original keeps its OWN material/part
    // at its OWN old index.
    foreach (fi; 0 .. 9) {
        assert(m.faceMaterial[fi] == 1000 + fi,
            "grid vertex-extrude: original face " ~ fi.to!string ~ " lost its material");
        assert(m.facePart[fi] == 2000 + fi,
            "grid vertex-extrude: original face " ~ fi.to!string ~ " lost its part");
    }

    // Tail: each rim/fan face inherits material/part from ITS OWN source
    // face (one of 0, 1, 3, 4 — the four faces incident to vertex 5), and
    // starts unselected regardless of that source's own order stamp.
    foreach (fi; 9 .. m.faces.length) {
        immutable uint mat = m.faceMaterial[fi];
        assert(mat == 1000 || mat == 1001 || mat == 1003 || mat == 1004,
            "grid vertex-extrude: rim/fan face " ~ fi.to!string ~ " material "
            ~ "must inherit from one of its 4 incident source faces (got "
            ~ mat.to!string ~ ")");
        assert(m.facePart[fi] == mat - 1000 + 2000,
            "grid vertex-extrude: rim/fan face " ~ fi.to!string ~ " part must "
            ~ "come from the SAME source face as its material");
        assert(m.faceSelectionOrder[fi] == 0,
            "grid vertex-extrude: rim/fan face " ~ fi.to!string ~ " must "
            ~ "start UNSELECTED (order 0), never inheriting its source's own "
            ~ "order stamp (face 4's is 77)");
    }
}

// Site 16 — extrudeFacesByMask's [non-selected originals] + [cap clones] +
// [wall quads] rebuild. Cap clones and wall quads inherit material/part/
// marks (including Subpatch) from their source face via `oldOfNew`, but —
// like site 15 — must start unselected (order 0), patched back right after
// the primitive call; the cap's own reselect loop (`selectFace`) then
// re-stamps ONLY the cap range, so a wall quad's order is what actually
// discriminates the override.
unittest {
    import std.conv : to;

    Mesh m = makeGridPlane(3);
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(1000 + fi);
        m.facePart[fi]     = cast(uint)(2000 + fi);
    }
    m.faceSelectionOrder[4] = 77;
    m.setSubpatch(4, true);

    bool[] mask = new bool[](m.faces.length);
    mask[4] = true;   // the grid's centre face

    size_t n = kernelOnce!extrudeFacesByMask(m, mask, 0.3f);
    assert(n == 1, "grid face-extrude: expected 1 face extruded, got " ~ n.to!string);
    // 8 non-selected originals + 1 cap + 4 wall quads (face 4 has 4 boundary
    // edges once removed from the otherwise-untouched grid).
    assert(m.faces.length == 8 + 1 + 4,
        "grid face-extrude: expected 8 originals + 1 cap + 4 walls, got "
        ~ m.faces.length.to!string);

    // The 8 non-selected originals keep their construction order (faces
    // 0,1,2,3,5,6,7,8 — skipping the selected face 4), landing at output
    // positions 0..7, each with its OWN material/part.
    static immutable uint[8] survivingMat =
        [1000, 1001, 1002, 1003, 1005, 1006, 1007, 1008];
    static immutable uint[8] survivingPart =
        [2000, 2001, 2002, 2003, 2005, 2006, 2007, 2008];
    foreach (i; 0 .. 8) {
        assert(m.faceMaterial[i] == survivingMat[i],
            "grid face-extrude: non-selected face at position " ~ i.to!string
            ~ " must keep its OWN material (got " ~ m.faceMaterial[i].to!string
            ~ ", want " ~ survivingMat[i].to!string ~ ")");
        assert(m.facePart[i] == survivingPart[i],
            "grid face-extrude: non-selected face at position " ~ i.to!string
            ~ " must keep its OWN part (got " ~ m.facePart[i].to!string
            ~ ", want " ~ survivingPart[i].to!string ~ ")");
    }

    // The cap (position 8) and the 4 wall quads (positions 9..12) all
    // inherit face 4's material/part/Subpatch.
    foreach (i; 8 .. 13) {
        assert(m.faceMaterial[i] == 1004,
            "grid face-extrude: cap/wall at position " ~ i.to!string
            ~ " must inherit face 4's material (got " ~ m.faceMaterial[i].to!string ~ ")");
        assert(m.facePart[i] == 2004,
            "grid face-extrude: cap/wall at position " ~ i.to!string
            ~ " must inherit face 4's part (got " ~ m.facePart[i].to!string ~ ")");
        assert(m.isFaceSubpatch(i),
            "grid face-extrude: cap/wall at position " ~ i.to!string
            ~ " must inherit face 4's Subpatch bit");
    }
    // The wall quads specifically must NOT inherit face 4's order stamp
    // (77) — only the cap's own reselect loop stamps an order, and it never
    // reaches the walls.
    foreach (i; 9 .. 13)
        assert(m.faceSelectionOrder[i] == 0,
            "grid face-extrude: wall quad at position " ~ i.to!string
            ~ " must start UNSELECTED (order 0), not inherit face 4's own "
            ~ "order stamp (77)");
}

// Site 17 — smoothShiftFacesByMask's [non-selected originals] + [cap
// clones] + [thicken-retained originals] + [wall quads] rebuild. Same
// per-plane shape as site 16 (material/part/marks inherit via `oldOfNew`,
// faceSelectionOrder is forced to 0 on every created face and patched back
// after the call), exercised here with `thicken: true` so the third,
// site-17-only range is covered too.
unittest {
    import std.conv : to;

    Mesh m = makeGridPlane(3);
    m.resetSelection();
    foreach (fi; 0 .. m.faces.length) {
        m.faceMaterial[fi] = cast(uint)(1000 + fi);
        m.facePart[fi]     = cast(uint)(2000 + fi);
    }
    m.faceSelectionOrder[4] = 77;
    m.setSubpatch(4, true);

    bool[] mask = new bool[](m.faces.length);
    mask[4] = true;

    size_t n = kernelOnce!smoothShiftFacesByMask(m, mask, 0.3f, 1.0f, true /* thicken */);
    assert(n == 1, "grid smooth-shift: expected 1 face processed, got " ~ n.to!string);
    // 8 non-selected originals + 1 cap + 1 thicken skin + 4 wall quads.
    assert(m.faces.length == 8 + 1 + 1 + 4,
        "grid smooth-shift: expected 8 originals + 1 cap + 1 thicken skin + "
        ~ "4 walls, got " ~ m.faces.length.to!string);

    static immutable uint[8] survivingMat =
        [1000, 1001, 1002, 1003, 1005, 1006, 1007, 1008];
    static immutable uint[8] survivingPart =
        [2000, 2001, 2002, 2003, 2005, 2006, 2007, 2008];
    foreach (i; 0 .. 8) {
        assert(m.faceMaterial[i] == survivingMat[i],
            "grid smooth-shift: non-selected face at position " ~ i.to!string
            ~ " must keep its OWN material");
        assert(m.facePart[i] == survivingPart[i],
            "grid smooth-shift: non-selected face at position " ~ i.to!string
            ~ " must keep its OWN part");
    }

    // Cap (8), thicken skin (9) and the 4 walls (10..13) all inherit face
    // 4's material/part/Subpatch, and none inherit its order stamp (77)
    // except the cap's own reselect stamp.
    foreach (i; 8 .. 14) {
        assert(m.faceMaterial[i] == 1004,
            "grid smooth-shift: created face at position " ~ i.to!string
            ~ " must inherit face 4's material (got " ~ m.faceMaterial[i].to!string ~ ")");
        assert(m.facePart[i] == 2004,
            "grid smooth-shift: created face at position " ~ i.to!string
            ~ " must inherit face 4's part (got " ~ m.facePart[i].to!string ~ ")");
        assert(m.isFaceSubpatch(i),
            "grid smooth-shift: created face at position " ~ i.to!string
            ~ " must inherit face 4's Subpatch bit");
    }
    foreach (i; 9 .. 14)
        assert(m.faceSelectionOrder[i] == 0,
            "grid smooth-shift: thicken skin / wall quad at position "
            ~ i.to!string ~ " must start UNSELECTED (order 0), not inherit "
            ~ "face 4's own order stamp (77)");
}


// ===========================================================================
// TASK 1903 STAGE H — RECORDING BLOCKS.
//
// The op-log is measured, not assumed. Two shapes below, matching the K-audit
// rows plan §5.3 already carries for this family:
//
//   * TRACKER-TRAFFIC ops (extrudeEdgesByMask / extendEdgesByMask, the
//     kernels behind `mesh.edge_extrude` / `mesh.edge_extend` — two of the
//     FOUR commands whose delta-undo is DEFAULT-ON in production, CLAUDE.md's
//     Undo/redo paragraph): these already carry `editRecorder_.record*` calls
//     (now `ed.rec().recordXxx(...)`), converted BYTE-IDENTICALLY — measured
//     against the pre-conversion body via a temporary `*Old` probe during
//     this stage's own development (памятка 14 — the probe does not ship;
//     see the task card for the old-vs-new kind/byteSize/payload table). The
//     blocks below pin what the CONVERTED body produces, standing alone.
//   * The THREE LATENT ops (extrudeVerticesByMask / extrudeFacesByMask /
//     smoothShiftFacesByMask) have NO `editRecorder_` traffic of their own
//     (§5.3's K table: "already records via: nothing | arm? yes" for all
//     three) — DISARMED is what ships (no production caller opens a
//     RECORDING batch on any of the three today), and `revert()` THROWS on
//     every one of them. Arming `wantsFaceReindex` (Stage K/L8's job, not
//     H's) fixes the throw but does not make the delta complete — pinned
//     here so Stage K/L8 inherits a measured starting point, not a guess.
// ===========================================================================

private Mesh gridStand4_() { Mesh m = makeGridPlane(4); m.buildLoops(); m.resetSelection(); return m; }
private Mesh cubeStandL_() { Mesh m = makeCube(); m.buildLoops(); m.resetSelection(); return m; }

unittest { // RECORDING: extrudeEdgesByMask op-log kinds + byteSize (cube, one edge)
    import mesh_edit_delta : MeshEditScope;
    import std.conv : to;
    Mesh m = cubeStandL_();
    bool[] mask = new bool[](m.edges.length);
    foreach (i, ref e; m.edges) {
        auto va = m.vertices[e[0]], vb = m.vertices[e[1]];
        if (((va - Vec3(-0.5f,0.5f,0.5f)).length < 1e-4f && (vb - Vec3(0.5f,0.5f,0.5f)).length < 1e-4f) ||
            ((va - Vec3(0.5f,0.5f,0.5f)).length < 1e-4f && (vb - Vec3(-0.5f,0.5f,0.5f)).length < 1e-4f))
            mask[i] = true;
    }
    auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
    immutable n = ed.extrudeEdgesByMask(mask, 0.2f, 0.1f);
    auto delta = ed.close();
    assert(n == 1, "one selected edge must extrude");
    assert(delta.log.length == 7,
        "extrudeEdgesByMask (cube, one interior edge): expected exactly 7 "
      ~ "op-log entries (AddVerts, ReshapeFaces x2, AddFaces, RemoveVerts, "
      ~ "Reindex, EdgeSelByEnds); got " ~ delta.log.length.to!string);
    // 3600 -> 4496 at task 1903 Stage L1-P1, and the whole difference is
    // structural: `Kind.MapValueDelta`'s payload added ten fields to
    // `MeshOpEntry`, whose `sizeof` went 432 -> 560 B (MEASURED, both numbers).
    // `byteSize` charges that struct once per entry (accounting rule 5), and
    // this log has seven entries: 7 x 128 = 896, and 3600 + 896 = 4496 exactly.
    // NOT a payload change -- this delta carries no map entry and none of its
    // arrays moved. The cost is the one the plan priced: every entry of every
    // OTHER kind grows by the same amount.
    //
    // 4496 -> 4832 at task 1903 Stage L5-b, structural for the SAME reason a
    // second time: `Kind.RemoveVerts` gained the selection-set payload
    // (`vertSetMaskBefore` + `edgeSetKeys` + `edgeSetWords`), three
    // dynamic arrays at 16 B of header apiece, so `MeshOpEntry.sizeof` went
    // 560 -> 608 B (MEASURED, both numbers). Seven entries: 7 x 48 = 336, and
    // 4496 + 336 = 4832 exactly. The PAYLOAD itself contributes 0 B here: this
    // stand's compaction drops vertices that carry no selection-set membership
    // and the recorder stores nothing for an all-zero capture, which is the
    // property that keeps this number derivable from the sizeof alone.
    assert(delta.byteSize == 4832,
        "extrudeEdgesByMask (cube, one interior edge): op-log byteSize "
      ~ "changed from the measured 4832 -- got " ~ delta.byteSize.to!string);

    Mesh pre = cubeStandL_();
    immutable ok = delta.revert(m);
    assert(ok, "extrudeEdgesByMask: revert() must succeed on a recording batch");
    import tests.unit.mesh_ops.seam_differential : meshPlaneDiffs;
    auto diffs = meshPlaneDiffs(pre, m);
    // PINNED DOWN TO ZERO at task 1903 Stage L2-c (2026-08-28), which is what
    // this row's own message told whoever closed the gap to do. The single
    // residual used to be `vertexSetMask.length`, left grown to the post-op
    // length by `finalizeTopologyEdit`'s resize while
    // `MeshEditDelta.finalize`'s blanket length sync simply did not name that
    // plane — the same hole task 1060's review had closed for `faceSetMask`.
    // The frozen parity oracle caught it on `mesh.split_edge` (a named
    // selection SET silently lost its membership on Ctrl+Z, because
    // `selSetMembersVertex` walks the MASK and an out-of-range entry makes the
    // `.v3d` loader drop the whole set), the line was added, and this revert
    // now round-trips every plane.
    assert(diffs.length == 0,
        "extrudeEdgesByMask: revert() left " ~ diffs.length.to!string
      ~ " residual plane(s), expected NONE: " ~ diffs.to!string
      ~ " -- a residual here is a regression, and `vertexSetMask.length` in "
      ~ "particular means MeshEditDelta.finalize's length sync lost that plane "
      ~ "again.");
}

unittest { // RECORDING: extendEdgesByMask op-log kinds (cube, one edge)
    import mesh_edit_delta : MeshEditScope;
    import std.conv : to;
    Mesh m = cubeStandL_();
    bool[] mask = new bool[](m.edges.length);
    foreach (i, ref e; m.edges) {
        auto va = m.vertices[e[0]], vb = m.vertices[e[1]];
        if (((va - Vec3(-0.5f,0.5f,0.5f)).length < 1e-4f && (vb - Vec3(0.5f,0.5f,0.5f)).length < 1e-4f) ||
            ((va - Vec3(0.5f,0.5f,0.5f)).length < 1e-4f && (vb - Vec3(-0.5f,0.5f,0.5f)).length < 1e-4f))
            mask[i] = true;
    }
    auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
    immutable n = ed.extendEdgesByMask(mask, 0.1f, 0.15f, Vec3(0,0,0), Vec3(0,0,0), Vec3(1,1,1), 1, Vec3(0,0,0));
    auto delta = ed.close();
    assert(n == 1, "one selected edge must extend");
    assert(delta.log.length == 3,
        "extendEdgesByMask (cube, one edge): expected exactly 3 op-log "
      ~ "entries (AddVerts, AddFaces, EdgeSelByEnds); got "
      ~ delta.log.length.to!string);
    // 1368 -> 1752 at task 1903 Stage L1-P1, structural for the same reason as
    // the sibling pin above: `MeshOpEntry.sizeof` went 432 -> 560 B and this
    // log has three entries -- 3 x 128 = 384, and 1368 + 384 = 1752 exactly.
    // No array on this delta moved.
    //
    // 1752 -> 1896 at task 1903 Stage L5-b, same shape again: `sizeof` went
    // 560 -> 608 B for `Kind.RemoveVerts`' three-array selection-set payload,
    // and this log has three entries -- 3 x 48 = 144, and 1752 + 144 = 1896
    // exactly. This family is pure-add and records no `RemoveVerts` at all, so
    // the new arrays are empty here by construction; the growth is the struct
    // term alone, charged once per entry of EVERY kind.
    assert(delta.byteSize == 1896,
        "extendEdgesByMask (cube, one edge): op-log byteSize changed from "
      ~ "the measured 1896 -- got " ~ delta.byteSize.to!string);

    Mesh pre = cubeStandL_();
    immutable ok = delta.revert(m);
    assert(ok, "extendEdgesByMask: revert() must succeed -- this family is "
              ~ "pure-add (never removes/reindexes), so it is far closer to "
              ~ "fully invertible than the other four kernels in this family");
    import tests.unit.mesh_ops.seam_differential : meshPlaneDiffs;
    auto diffs = meshPlaneDiffs(pre, m);
    // MEASURED, not assumed: revert() succeeds but leaves ONE residual plane
    // — `vertexSetMask` grown to the post-op length (8 -> 10) and not
    // truncated back. The SAME class of gap `extrudeEdgesByMask`'s own
    // recording block above measures (also `vertexSetMask.length`), so this
    // is a property of the set-mask resize path shared by the family, not
    // something `extendEdgesByMask` introduces on its own.
    // PINNED DOWN TO ZERO at task 1903 Stage L2-c — see the sibling
    // `extrudeEdgesByMask` block above for the plane, the fix and the
    // user-visible half.
    assert(diffs.length == 0,
        "extendEdgesByMask: revert() left " ~ diffs.length.to!string
      ~ " residual plane(s), expected NONE: " ~ diffs.to!string
      ~ " -- `vertexSetMask.length` in particular means "
      ~ "MeshEditDelta.finalize's length sync lost that plane again.");
}

unittest { // RECORDING: the three extrude kernels Stage K ARMED, and what their revert restores
    import mesh_edit_delta : MeshEditScope, MeshOpEntry, MeshEditDelta;
    import std.conv : to;
    import std.format : format;

    // THIS BLOCK ASSERTED THE OPPOSITE UNTIL STAGE K (2026-08-27), and its own
    // messages named the flip: disarmed, each of these kernels logged its
    // vertex appends and NOTHING about the faces it rewrote, and `revert()`
    // THREW an `ArrayIndexError` out of `buildLoops` over windings that
    // referenced vertices the reverse had just removed. Stage K wrapped each
    // kernel's `mesh_planes.rewriteFaces` call in its own `faceReindexScope()`,
    // so the face change is now in the log and the throw is gone.
    //
    // The assertions are REPLACED, not relaxed: each cell now pins the armed
    // shape (one `FaceReindex`, no throw, geometry restored byte-for-byte), so
    // a regression that disarms a scope reddens here instead of quietly
    // reverting to the weaker law. What the armed revert does NOT restore is
    // measured per family in `tests/unit/face_reindex_arming_test.d`, on a
    // stand that carries every plane; these stands carry no per-corner map, so
    // no `MeshMapDelta` payload is recorded — asserted below, because "the
    // payload is absent" and "the payload is empty" must not read alike.

    static string geom(ref Mesh m) {
        string t = format("V=%d F=%d E=%d", m.vertices.length, m.faces.length,
                          m.edges.length);
        foreach (i, v; m.vertices) t ~= format(" v%d(%a,%a,%a)", i, v.x, v.y, v.z);
        foreach (i, f; m.faces)    t ~= format(" f%d%s", i, f.to!string);
        return t;
    }

    static size_t nKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
        size_t n; foreach (ref e; d.log) if (e.kind == k) ++n; return n;
    }

    static string kinds(ref MeshEditDelta d) {
        string t; foreach (ref e; d.log) t ~= " " ~ e.kind.to!string; return "[" ~ t ~ " ]";
    }

    // extrudeVerticesByMask — armed: [AddVerts, SetPos, FaceReindex].
    // `SetPos` is Stage H's own §5.7 migration of the raw apex-shift write and
    // is independent of the arming; it is named here so a future reader does
    // not read the third entry as having replaced it.
    {
        Mesh m = gridStand4_();
        immutable string pre = geom(m);
        bool[] mask = new bool[](m.vertices.length);
        mask[2 * 5 + 2] = true;   // interior vertex of a 4x4 grid (5x5 verts)
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        immutable n = ed.extrudeVerticesByMask(mask, 0.1f, 0.15f);
        auto delta = ed.close();
        assert(n == 1, "the stand extruded nothing — the cell would be vacuous");
        assert(delta.log.length == 3
            && delta.log[0].kind == MeshOpEntry.Kind.AddVerts
            && delta.log[1].kind == MeshOpEntry.Kind.SetPos
            && delta.log[2].kind == MeshOpEntry.Kind.FaceReindex,
            "extrudeVerticesByMask armed: expected [AddVerts, SetPos, "
          ~ "FaceReindex], got " ~ kinds(delta));
        assert(nKind(delta, MeshOpEntry.Kind.MeshMapDelta) == 0,
            "this stand carries no PolyVertex map, so no corner payload should "
          ~ "be recorded; one here means the payload is being written "
          ~ "unconditionally and its cost is no longer paid only where there "
          ~ "is something to save");
        assert(delta.revert(m),
            "extrudeVerticesByMask armed: revert() refused the delta");
        assert(geom(m) == pre,
            format("extrudeVerticesByMask armed: revert did not restore the "
                 ~ "geometry.\n  pre : %s\n  post: %s", pre, geom(m)));
    }
    // extrudeFacesByMask — armed: [AddVerts, FaceReindex]. This is one of the
    // two `&rw` sites, so its arming depended on Stage J's corner carry.
    {
        Mesh m = cubeStandL_();
        immutable string pre = geom(m);
        bool[] mask = new bool[](m.faces.length);
        mask[0] = true;
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        immutable n = ed.extrudeFacesByMask(mask, 0.3f);
        auto delta = ed.close();
        assert(n == 1, "the stand extruded nothing — the cell would be vacuous");
        assert(delta.log.length == 2
            && delta.log[0].kind == MeshOpEntry.Kind.AddVerts
            && delta.log[1].kind == MeshOpEntry.Kind.FaceReindex,
            "extrudeFacesByMask armed: expected [AddVerts, FaceReindex], got "
          ~ kinds(delta));
        assert(delta.revert(m), "extrudeFacesByMask armed: revert() refused");
        assert(geom(m) == pre,
            format("extrudeFacesByMask armed: revert did not restore the "
                 ~ "geometry.\n  pre : %s\n  post: %s", pre, geom(m)));
    }
    // smoothShiftFacesByMask — armed: [AddVerts, FaceReindex], on a WHOLE-mesh
    // mask, so the rewrite replaces every face rather than a handful.
    {
        Mesh m = gridStand4_();
        immutable string pre = geom(m);
        bool[] mask = new bool[](m.faces.length);
        mask[] = true;
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry | MeshEditScope.Marks);
        immutable n = ed.smoothShiftFacesByMask(mask, 0.2f, 0.8f, true);
        auto delta = ed.close();
        assert(n == 16, "the stand shifted nothing — the cell would be vacuous");
        assert(delta.log.length == 2
            && delta.log[0].kind == MeshOpEntry.Kind.AddVerts
            && delta.log[1].kind == MeshOpEntry.Kind.FaceReindex,
            "smoothShiftFacesByMask armed: expected [AddVerts, FaceReindex], "
          ~ "got " ~ kinds(delta));
        assert(delta.revert(m), "smoothShiftFacesByMask armed: revert() refused");
        assert(geom(m) == pre,
            format("smoothShiftFacesByMask armed: revert did not restore the "
                 ~ "geometry.\n  pre : %s\n  post: %s", pre, geom(m)));
    }
}
