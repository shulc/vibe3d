// mesh_edge_slice_test -- the `edgeSlice` / `edgeSliceEx` family -- cuts, reuse, the true no-op, and the guards.
//
// Nine cells: selection inherited onto BOTH halves, index sharing without a
// T-junction, a cut across one shared face, endpoint reuse, the mixed
// endpoint/interior pair, the KEPT degenerate-chain split, the TRUE no-op
// with its rollback, the out-of-range guards, and the points-only arm. Task
// 2910 step 3 moves the CODE to `source/mesh_edge_slice.d`; these tests are
// already where they will still belong.
//
// These blocks stood in the body of `struct Mesh` until task 3160 -- step 1
// of `doc/tasks/work/2910-mesh-struct-seams.md`, which took fifty `unittest`
// blocks out of a 16 782-line struct body. They are HERE rather than at
// module scope in `mesh.d` because they compile against `Mesh`'s PUBLIC API
// alone: the criterion `tests/unit/README.md` states and task 0706 set. The
// eighteen blocks that read a `private` name stayed behind under the same
// rule, at module scope in `mesh.d`. Bodies are byte-identical to what stood
// in the struct, dedented by four columns; the only edit is the member enum
// `Marks`, which is spelled `Mesh.Marks` outside the body.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_edge_slice_test;

import mesh;
import math : Vec3;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

// ---------------------------------------------------------------------------
// rebuildFacesWithChordSplits: keep-selection unittests (cut-keep-split-faces
// -selected task) — the shared kernel now INHERITS each parent face's
// Marks.Select bit onto every emitted slot (whole-copy AND both split
// halves) instead of unconditionally clearing it. Asserted by GEOMETRY /
// count, not fixed index — a split appends the second half right after the
// first, shifting later face indices.
// ---------------------------------------------------------------------------


unittest { // edgeSlice (splitPolygons=true path): selected parent → BOTH halves selected
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    m.selectFace(0);

    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(2, 3);
    assert(eA != ~0u && eB != ~0u, "both edges must exist on the quad");

    size_t n = m.edgeSlice(eA, eB, 0.5f, 0.5f, /*splitPolygons*/true);

    assert(n == 1, "single-face edgeSlice chords once");
    assert(m.faces.length == 2, "2 sub-faces after the slice");
    assert(m.isFaceSelected(0) && m.isFaceSelected(1),
           "edgeSlice split path: both halves of a selected parent must stay selected");
}

// ---------------------------------------------------------------------------
// edgeSlice unittests
// ---------------------------------------------------------------------------

unittest { // edgeSlice: 3×1 quad strip — index-share (no T-junction) + 6 faces / 12 verts
    // Grid:
    //  4--5--6--7
    //  |  |  |  |
    //  0--1--2--3
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0), Vec3(3,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0), Vec3(3,1,0),
    ];
    m.addFace([0u,1u,5u,4u]);
    m.addFace([1u,2u,6u,5u]);
    m.addFace([2u,3u,7u,6u]);
    m.buildLoops();
    m.resetSelection();

    uint eLeft  = m.edgeIndexOfVerts(0, 4);
    uint eRight = m.edgeIndexOfVerts(3, 7);
    assert(eLeft  != ~0u, "edge(0,4) must exist");
    assert(eRight != ~0u, "edge(3,7) must exist");

    size_t nSplit = m.edgeSlice(eLeft, eRight);

    assert(nSplit == 3, "3 quads split → nSplit==3");
    assert(m.faces.length  == 6,  "3×2 = 6 faces after strip cut");
    assert(m.vertices.length == 12, "8 + 4 cut-points = 12 verts");

    // No orphan vertices.
    import std.conv : to;
    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "vertex " ~ i.to!string ~ " is orphaned after edgeSlice");

    // No degenerate faces.
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate face after edgeSlice");

    // Index-share: the cut point on interior edge (1,5) must be referenced
    // by exactly 2 sub-faces with the SAME vertex index (no T-junction).
    uint cutMid15 = ~0u;
    foreach (vi; 0 .. cast(uint)m.vertices.length) {
        auto v = m.vertices[vi];
        if (v.x > 0.99f && v.x < 1.01f &&
            v.y > 0.49f && v.y < 0.51f && v.z == 0)
            cutMid15 = vi;
    }
    assert(cutMid15 != ~0u, "cut point on edge(1,5) must exist");
    int cnt15 = 0;
    foreach (face; m.faces) foreach (vi; face) if (vi == cutMid15) cnt15++;
    // v9 is shared by both sub-faces of face0 AND both sub-faces of face1
    // (it is the entry point of one and exit point of the other across the
    // shared half-edge).  4 references = 1 unique index across all 4 users.
    assert(cnt15 == 4,
        "interior cut vertex (1,5 mid) must appear in exactly 4 sub-faces (index-share)");

    // Likewise for interior edge (2,6).
    uint cutMid26 = ~0u;
    foreach (vi; 0 .. cast(uint)m.vertices.length) {
        auto v = m.vertices[vi];
        if (v.x > 1.99f && v.x < 2.01f &&
            v.y > 0.49f && v.y < 0.51f && v.z == 0)
            cutMid26 = vi;
    }
    assert(cutMid26 != ~0u, "cut point on edge(2,6) must exist");
    int cnt26 = 0;
    foreach (face; m.faces) foreach (vi; face) if (vi == cutMid26) cnt26++;
    // Same reasoning: v10 is shared by both sub-faces of face1 AND face2.
    assert(cnt26 == 4,
        "interior cut vertex (2,6 mid) must appear in exactly 4 sub-faces (index-share)");
}

unittest { // edgeSlice: single shared face (cube bottom) — 7 faces, 10 verts
    auto m = makeCube();
    // Face 5 = [0,1,5,4] (bottom).  Edge(0,1) and edge(4,5) are both on it.
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(4,5) must exist on cube");

    size_t nSplit = m.edgeSlice(eA, eB);

    assert(nSplit == 1, "single shared face: 1 split");
    assert(m.faces.length  == 7,  "6 faces → 7 after single split");
    assert(m.vertices.length == 10, "8 + 2 cut-points = 10 verts");

    foreach (face; m.faces) assert(face.length >= 3, "no degenerate faces");

    import std.conv : to;
    bool[] refd2 = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd2[vi] = true;
    foreach (i, r; refd2) assert(r, "vertex " ~ i.to!string ~ " orphaned after single-face edgeSlice");
}

unittest { // edgeSlice: endpoint cut (t=0/1) reuses the corner, no new vertex — F1, task 0295
    auto m = makeCube();
    // Face 5 = [0,1,5,4] (bottom) — same face as the "single shared face"
    // unittest above. Edge(0,1) and edge(4,5) are non-adjacent on it; their
    // DIAGONAL corner combination is {0,5} (the other combination, {1,4}, is
    // also a valid diagonal — {0,4}/{1,5} are the two ADJACENT/existing-edge
    // pairs and would hit rebuildFacesWithChordSplits' adjacent-hit guard,
    // i.e. a no-op). Read the stored edge direction to pick tA/tB so the cut
    // lands on {0,5} regardless of edges[e][0]/[1]'s (opaque, dedup-order)
    // storage direction.
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(4,5) must exist on cube");

    size_t origVerts = m.vertices.length;
    size_t origEdges = m.edges.length;
    size_t origFaces = m.faces.length;

    float tA = (m.edges[eA][0] == 0) ? 0.0f : 1.0f; // lands on vertex 0
    float tB = (m.edges[eB][0] == 5) ? 0.0f : 1.0f; // lands on vertex 5

    size_t nSplit = m.edgeSlice(eA, eB, tA, tB, /*splitPolygons*/true);

    assert(nSplit == 1, "single shared face chorded once");
    assert(m.faces.length == origFaces + 1, "6 -> 7 faces (one chord split)");
    assert(m.vertices.length == origVerts,
        "endpoint cut reuses BOTH corners — vertex count UNCHANGED (the F1 discriminator)");
    assert(m.edges.length == origEdges + 1,
        "only the new chord is a new edge — neither named edge is itself split");

    foreach (face; m.faces) assert(face.length >= 3, "no degenerate face after endpoint edgeSlice");

    // No coincident-position duplicate vertices (the "insert-then-weld"
    // approach this stage deliberately avoids would leave one here).
    foreach (i; 0 .. m.vertices.length)
        foreach (j; i + 1 .. m.vertices.length)
            assert((m.vertices[i] - m.vertices[j]).length() > 1e-6f,
                "endpoint cut must not create a coincident duplicate vertex");

    // The chord connects the two REUSED corners (0, 5) directly.
    assert(m.edgeIndexOfVerts(0, 5) != ~0u, "chord edge (0,5) must exist after endpoint cut");
}

unittest { // edgeSliceEx: mixed endpoint (t=0, reuse) + interior (t=0.5, new vert) — F1, task 0295
    auto m = makeCube();
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u); assert(eB != ~0u);

    size_t origVerts = m.vertices.length;
    float tA = (m.edges[eA][0] == 0) ? 0.0f : 1.0f; // reuse vertex 0

    auto r = m.edgeSliceEx(eA, eB, tA, 0.5f, /*splitPolygons*/true);

    assert(r.facesSplit == 1, "single shared face chorded once");
    assert(m.vertices.length == origVerts + 1,
        "one endpoint (reused) + one interior (new) => +1 vertex only");
    assert(r.cutVertA == 0, "cutVertA must be the REUSED corner (vertex 0), not a fresh index");
    assert(r.cutVertB == origVerts, "cutVertB must be the newly appended interior vertex");
}

unittest { // edgeSliceEx: KEPT degenerate-chain edge-split, RE-DERIVED
           // (mesh-robustness batch) — this is an INTENTIONAL REVERSAL of
           // the 0303 always-rollback fix, re-derived from a frozen
           // reference capture. It previously asserted the OLD (over-
           // rollback) behaviour as correct — that encoded the bug this
           // batch fixes. Do NOT read this as test-fitting.
    //
    // edge(0,1)@t=0.5 (genuine interior insert) chained to edge(1,5)@t=1.0
    // (F1 endpoint-reuse landing on the SHARED corner, vertex 1). Both edges
    // border face 5 ([0,1,5,4]); the interior cut vertex is spliced in
    // immediately next to the reused corner in that face's winding, so the
    // two cut positions are ADJACENT there — rebuildFacesWithChordSplits'
    // adjacent-hit guard correctly refuses to CHORD-SPLIT it (facesSplit ==
    // 0). But Pass 1 (insertEdgePoint) already spliced a REAL new vertex
    // into both faces incident to edge(0,1) (faces 0 and 5) — that is a
    // legitimate degenerate-chain edge-split (matches the reference: cube
    // V8/E12/F6 -> V9/E13/F6, chi stays 2), and must be KEPT + finalized,
    // not rolled back. Before this fix that insert was unconditionally
    // discarded (over-rollback, task 0303's own fix — too broad).
    import std.conv : to;
    auto m = makeCube();
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(1, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(1,5) must exist on cube");

    size_t origVerts = m.vertices.length;
    size_t origEdges = m.edges.length;
    size_t origFaces = m.faces.length;

    float tB = (m.edges[eB][0] == 1) ? 0.0f : 1.0f; // land on the shared corner, vertex 1

    auto r = m.edgeSliceEx(eA, eB, 0.5f, tB, /*splitPolygons*/true);

    assert(r.facesSplit == 0,
        "adjacent cut positions on the shared face must not CHORD-SPLIT any face");
    assert(r.meshChanged,
        "a kept degenerate-chain insert must report meshChanged == true");
    assert(r.cutVertA == cast(uint)origVerts,
        "cutVertA must be the newly inserted interior vertex on edge(0,1)");
    assert(r.cutVertB == 1,
        "cutVertB must be the REUSED shared corner (vertex 1), not a sentinel");

    assert(m.vertices.length == origVerts + 1,
        "kept insert: exactly one new vertex (the edge(0,1) interior cut)");
    assert(m.edges.length == origEdges + 1,
        "kept insert: edge(0,1) splits into two edges — net +1 edge");
    assert(m.faces.length == origFaces,
        "kept insert: no face is added or removed, only re-wound");
    assert(cast(long)m.vertices.length - cast(long)m.edges.length + cast(long)m.faces.length == 2,
        "Euler characteristic must stay 2 after a kept degenerate-chain insert");

    // edge(0,1) itself is gone; the two half-edges (0,newV) and (newV,1) exist.
    assert(m.edgeIndexOfVerts(0, 1) == ~0u,
        "edge(0,1) must no longer exist as a single edge after the split");
    assert(m.edgeIndexOfVerts(0, r.cutVertA) != ~0u,
        "half-edge (0, newVert) must exist after the kept split");
    assert(m.edgeIndexOfVerts(r.cutVertA, 1) != ~0u,
        "half-edge (newVert, 1) must exist after the kept split");

    // Manifold: every undirected edge used by at most 2 faces.
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
            "kept degenerate-chain insert: non-manifold edge used by " ~
            count.to!string ~ " faces");
}

unittest { // edgeSliceEx: TRUE no-op (both cuts reuse existing ADJACENT
           // corners, nothing spliced in) must still roll back byte-
           // identical — sibling of the KEPT-insert case above, guarding
           // the regression requirement (mesh-robustness batch).
    //
    // edge(0,1)@t=0 (reuse vertex 0) chained to edge(1,5)@t=1 (reuse vertex
    // 1). Both land on EXISTING corners that are already adjacent in face 5's
    // winding ([0,1,5,4]) — the adjacent-hit guard refuses to split, and
    // since NEITHER cut inserted anything new, vertices.length is untouched:
    // a genuinely empty operation.
    import std.conv : to;
    auto m = makeCube();
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(1, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(1,5) must exist on cube");

    size_t origVerts = m.vertices.length;
    size_t origEdges = m.edges.length;
    size_t origFaces = m.faces.length;
    uint[][] origFaceWindings = m.faces._store.dup;

    float tA = (m.edges[eA][0] == 0) ? 0.0f : 1.0f; // reuse vertex 0
    float tB = (m.edges[eB][0] == 1) ? 0.0f : 1.0f; // reuse vertex 1

    auto r = m.edgeSliceEx(eA, eB, tA, tB, /*splitPolygons*/true);

    assert(r.facesSplit == 0,
        "adjacent reused corners on the shared face must be a no-op (adjacent-hit guard)");
    assert(!r.meshChanged,
        "a true no-op (nothing spliced in) must report meshChanged == false");
    assert(r.cutVertA == ~0u && r.cutVertB == ~0u,
        "a true no-op result must not surface stale cut-vertex indices");
    assert(m.vertices.length == origVerts,
        "true no-op must not add any vertex — both cuts were pure corner reuse");
    assert(m.edges.length == origEdges, "true no-op must not touch edges[]");
    assert(m.faces.length == origFaces, "true no-op must not touch face count");
    foreach (fi; 0 .. origFaces)
        assert(m.faces[fi] == origFaceWindings[fi],
            "true no-op must not leave any winding change in face " ~ fi.to!string);
    assert(cast(long)m.vertices.length - cast(long)m.edges.length + cast(long)m.faces.length == 2,
        "Euler characteristic must stay 2 after a true no-op cut");
}

unittest { // edgeSlice: no-op guards — same edge, out-of-bounds index → returns 0
    auto m = makeCube();
    size_t origFaces = m.faces.length;
    size_t origVerts = m.vertices.length;

    uint e0 = m.edgeIndexOfVerts(0, 1);

    // Same edge: always a no-op.
    assert(m.edgeSlice(e0, e0) == 0, "same edge must return 0");
    assert(m.faces.length    == origFaces, "mesh unchanged after same-edge no-op");
    assert(m.vertices.length == origVerts, "mesh unchanged after same-edge no-op");

    // Out-of-bounds edge index: no-op.
    uint oob = cast(uint)m.edges.length;
    assert(m.edgeSlice(oob, e0) == 0, "oob edgeA must return 0");
    assert(m.edgeSlice(e0, oob) == 0, "oob edgeB must return 0");
    assert(m.faces.length    == origFaces, "mesh unchanged after oob no-op");
    assert(m.vertices.length == origVerts, "mesh unchanged after oob no-op");
}

unittest { // edgeSlice: splitPolygons=false — points only, no chord, no face split
    import std.conv : to;
    auto m = makeCube();
    // Face 5 = [0,1,5,4] (bottom).  Edge(0,1) and edge(4,5) are both on it,
    // but are NOT adjacent (mirrors the shared-face unittest above).
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(4,5) must exist on cube");

    size_t origEdges = m.edges.length;
    assert(origEdges == 12, "cube starts with 12 edges");

    size_t n = m.edgeSlice(eA, eB, 0.5f, 0.5f, /*splitPolygons*/false);

    assert(n == 2, "points-only branch returns 2 (nonzero success marker)");
    assert(m.faces.length == 6, "face count UNCHANGED with splitPolygons=false");
    assert(m.vertices.length == 10, "8 + 2 cut-points = 10 verts");
    // The discriminator for the finalize bug: a missing rebuildEdges() would
    // leave edges.length at 12 (the two new half-edges never registered) even
    // though face==6 / verts==10 / no-orphans / no-degenerate all still pass.
    assert(m.edges.length == 14,
        "edge count must be 12 -> 14 (two non-shared edges each split once); got "
        ~ m.edges.length.to!string);

    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "vertex " ~ i.to!string ~ " orphaned after points-only edgeSlice");
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate face after points-only edgeSlice");
}
