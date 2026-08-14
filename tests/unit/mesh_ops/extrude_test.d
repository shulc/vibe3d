// Module unittests for `mesh_ops.extrude`, moved verbatim out of source/mesh_ops/extrude.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.extrude_test;

import mesh;
import math;
import std.math : sqrt;
import std.algorithm : sort;
import mesh_ops.extrude;

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
    size_t n = m.extrudeEdgesByMask(mask, 0.0f, 0.3f);
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
        mShiftInset.extrudeEdgesByMask(mask, 0.2f, 0.1f);
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
        mInsetOnly.extrudeEdgesByMask(mask, 0.0f, 0.1f);
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
        mShiftOnly.extrudeEdgesByMask(mask, 0.2f, 0.0f);
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
        m.extrudeEdgesByMask(mask, -0.15f, 0.1f);
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
        m.extrudeEdgesByMask(mask, -0.15f, 0.1f);
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
        size_t n = m.extrudeFacesByMask(mask, 0.5f);
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
        size_t n = m.extrudeFacesByMask(mask, 0.0f);
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
        size_t n = m.extrudeFacesByMask(mask, 0.5f);
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
        size_t n = m.extrudeFacesByMask(mask, 0.5f, true);
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
        size_t n = m.extrudeFacesByMask(mask, 0.5f, true);
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
    size_t n = m.extrudeFacesByMask(mask, 1.0f);
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
    size_t n = m.extrudeFacesByMask(mask, 1.0f);
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
    size_t gn = gm.extrudeFacesByMask(gmask, 1.0f);
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
        size_t n = m.smoothShiftFacesByMask(mask, 0.0f, 1.0f, false);
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
        size_t n = m.smoothShiftFacesByMask(mask, 0.3f, 0.5f, false);
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
        size_t n = m.smoothShiftFacesByMask(mask, 0.3f, 1.0f, true);
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
    auto n = m.extendEdgesByMask(empty, 0.1f, 0.2f,
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
    size_t processed = m.extrudeVerticesByMask(mask, 0.0f, 0.2f);

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
    size_t processed = m.extrudeVerticesByMask(mask, 0.5f, 0.0f);
    assert(processed == 0,          "extrudeVerticesByMask: width=0 must be no-op");
    assert(m.vertices.length == 8,  "extrudeVerticesByMask: width=0 must not add verts");
    assert(m.faces.length    == 6,  "extrudeVerticesByMask: width=0 must not add faces");
}

