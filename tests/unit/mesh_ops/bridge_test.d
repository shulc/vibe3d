// Module unittests for `mesh_ops.bridge`, moved verbatim out of source/mesh_ops/bridge.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.bridge_test;

import mesh;
import math;
import mesh_ops.bridge;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, MeshOpEntry;

// TASK 1903 Stage D3 — the five bridge entry points are free functions over
// `ref MeshEditBatch` now, so a test cannot call one on a bare `Mesh` any more:
// that is the point of the receiver, and it is why every call site in this file
// goes through the helper below. One helper for all five kernels, so there is
// ONE place that says why the batch is `unrecorded` — nothing here reads an
// op-log, and track 1 is the conversion axis only (the two production callers,
// `commands/mesh/bridge.d` and `tools/edit/bridge_tool.d`, open theirs the same
// way; see mesh_ops/bridge.d's header). The `RECORDING` block at the bottom of
// this file is the one deliberate exception.
private size_t bridgeOnce(alias kernel, Args...)(ref Mesh m, auto ref Args args) {
    auto ed = MeshEditBatch.unrecorded(m, kBridgeEditScope);
    const n = kernel(ed, args);
    ed.close();
    return n;
}

// ---------------------------------------------------------------------------
// Unit tests -- co-located with the family they exercise (moved verbatim
// from mesh.d alongside the kernels above).
// ---------------------------------------------------------------------------
unittest { // bridgeLoops: two parallel square rings → 4 quads, no new verts
    // Two coaxial unit squares: A at z=0, B at z=1, both CCW.
    // A: 0(0,0,0), 1(1,0,0), 2(1,1,0), 3(0,1,0)
    // B: 4(0,0,1), 5(1,0,1), 6(1,1,1), 7(0,1,1)
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    assert(m.vertices.length == 8);
    assert(m.faces.length == 0);

    size_t added = bridgeOnce!bridgeLoops(m, [0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(added == 4, "expected 4 quads");
    assert(m.faces.length == 4, "face count");
    assert(m.vertices.length == 8, "no new verts");

    // All faces must be quads.
    foreach (f; m.faces) assert(f.length == 4, "all quads");

    // Every new face's vertices are within the original 8.
    foreach (f; m.faces)
        foreach (vi; f) assert(vi < 8, "vertex index in range");
}

unittest { // bridgeLoops: mismatch rejection + too-short rejection
    Mesh m;
    foreach (i; 0 .. 8) m.addVertex(Vec3(cast(float)i, 0, 0));

    // Unequal lengths → 0 faces added.
    size_t r1 = bridgeOnce!bridgeLoops(m, [0u,1u,2u,3u], [4u,5u,6u]);
    assert(r1 == 0, "unequal length must be rejected");
    assert(m.faces.length == 0, "no faces added on mismatch");

    // Length 2 → too short → 0.
    size_t r2 = bridgeOnce!bridgeLoops(m, [0u,1u], [4u,5u]);
    assert(r2 == 0, "length<3 must be rejected");
}

unittest { // bridgeLoopsSpans: spans=1 degenerates EXACTLY to bridgeLoops
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = bridgeOnce!bridgeLoopsSpans(m, [0u,1u,2u,3u], [4u,5u,6u,7u], false, 1, 0.0f);
    assert(added == 4, "spans=1: expected 4 quads");
    assert(m.faces.length == 4, "spans=1: face count");
    assert(m.vertices.length == 8, "spans=1: no new verts");
    foreach (f; m.faces) assert(f.length == 4, "spans=1: all quads");
}

unittest { // bridgeLoopsSpans: segments law (twist=0) — closed-form, exact
    // Same two-coaxial-unit-squares fixture as bridgeLoops' own test.
    // Task 0357 Segments law: spans=3 -> 2 interior rings at t=1/3, 2/3,
    // linearly interpolated between the paired loop corners (identity
    // pairing here, verified by the bridgeLoops test just above using the
    // SAME fixture). Golden numbers hand-derived from that closed form,
    // not borrowed from any external capture.
    import std.math : abs;
    import std.format : format;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = bridgeOnce!bridgeLoopsSpans(m, [0u,1u,2u,3u], [4u,5u,6u,7u], false, 3, 0.0f);
    assert(added == 12, format("spans=3: expected 12 quads (3 spans * 4), got %d", added));
    assert(m.faces.length == 12, "spans=3: face count");
    assert(m.vertices.length == 16, "spans=3: 8 orig + 8 new (2 rings * 4)");
    foreach (f; m.faces) assert(f.length == 4, "spans=3: all quads");

    // New verts are indices 8..15: ring1 (t=1/3) then ring2 (t=2/3), each
    // in loop-corner order [corner0..corner3] matching loopA/loopB's own
    // vertex order (0,1,2,3 / 4,5,6,7).
    static immutable Vec3[8] expected = [
        Vec3(0.0f, 0.0f, 1.0f/3.0f), Vec3(1.0f, 0.0f, 1.0f/3.0f),
        Vec3(1.0f, 1.0f, 1.0f/3.0f), Vec3(0.0f, 1.0f, 1.0f/3.0f),
        Vec3(0.0f, 0.0f, 2.0f/3.0f), Vec3(1.0f, 0.0f, 2.0f/3.0f),
        Vec3(1.0f, 1.0f, 2.0f/3.0f), Vec3(0.0f, 1.0f, 2.0f/3.0f),
    ];
    foreach (i, e; expected) {
        Vec3 got = m.vertices[8 + i];
        assert(abs(got.x - e.x) < 1e-5f && abs(got.y - e.y) < 1e-5f && abs(got.z - e.z) < 1e-5f,
            format("spans=3 vert %d: expected (%.6f,%.6f,%.6f), got (%.6f,%.6f,%.6f)",
                   8+i, e.x, e.y, e.z, got.x, got.y, got.z));
    }
}

unittest { // bridgeLoopsSpans: twist law, |twist|=1 — VERIFIED EXACT regime
    // Task 0357's dense reference re-capture: twist in {-1,0,1} is exact at
    // every interior ring (two independent loop shapes, max err ~3e-8).
    // Golden numbers here are computed from the SAME verified closed form
    // (f(t) = smoothstep(t) = 3t^2-2t^3, slide toward the next corner) on
    // the two-coaxial-unit-squares fixture — cross-checked by hand against
    // the reference capture's own f(1/3)=7/27, f(2/3)=20/27 values (private
    // doc) before being reproduced here.
    import std.math : abs;
    import std.format : format;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = bridgeOnce!bridgeLoopsSpans(m, [0u,1u,2u,3u], [4u,5u,6u,7u], false, 3, 1.0f);
    assert(added == 12, "twist=1: expected 12 quads");
    assert(m.vertices.length == 16, "twist=1: 8 orig + 8 new");

    enum float f1 = 7.0f/27.0f;   // smoothstep(1/3)
    enum float f2 = 20.0f/27.0f;  // smoothstep(2/3)
    static immutable Vec3[8] expected = [
        // Ring 1 (t=1/3): slide toward the NEXT corner (k+1) by f1.
        Vec3(f1, 0.0f, 1.0f/3.0f), Vec3(1.0f, f1, 1.0f/3.0f),
        Vec3(1.0f - f1, 1.0f, 1.0f/3.0f), Vec3(0.0f, 1.0f - f1, 1.0f/3.0f),
        // Ring 2 (t=2/3): slide by f2.
        Vec3(f2, 0.0f, 2.0f/3.0f), Vec3(1.0f, f2, 2.0f/3.0f),
        Vec3(1.0f - f2, 1.0f, 2.0f/3.0f), Vec3(0.0f, 1.0f - f2, 2.0f/3.0f),
    ];
    foreach (i, e; expected) {
        Vec3 got = m.vertices[8 + i];
        assert(abs(got.x - e.x) < 1e-5f && abs(got.y - e.y) < 1e-5f && abs(got.z - e.z) < 1e-5f,
            format("twist=1 vert %d: expected (%.6f,%.6f,%.6f), got (%.6f,%.6f,%.6f)",
                   8+i, e.x, e.y, e.z, got.x, got.y, got.z));
    }
}

unittest { // bridgeLoopsSpans: DoS defense — huge spans clamps to maxBridgeSpans
    import std.format : format;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = bridgeOnce!bridgeLoopsSpans(m, [0u,1u,2u,3u], [4u,5u,6u,7u], false,
                                      100_000_000u, 0.0f);
    assert(added == maxBridgeSpans * 4,
        format("huge spans must clamp to maxBridgeSpans, got %d (expected %d)",
               added, maxBridgeSpans * 4));
    assert(m.faces.length == maxBridgeSpans * 4, "clamped face count");
}

unittest { // bridgeOpenRows: equal-length spans=1 strip, spans=2 midpoint
           // ring, and proximity-based orientation (not chain-walk order)
    import std.conv : to;
    import std.math : abs;

    // (1) spans=1: two disjoint 3-vertex rows → 2 quads, no new verts.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(2,1,0));
        size_t vertsBefore = m.vertices.length;

        size_t added = bridgeOnce!bridgeOpenRows(m, [0u,1u,2u], [3u,4u,5u], false, 1u, 0.0f);
        assert(added == 2, "spans=1: expected 2 quads (N-1), got " ~ added.to!string);
        assert(m.faces.length == 2, "spans=1: expected 2 faces total");
        assert(m.vertices.length == vertsBefore, "spans=1: no new verts on existing-vert strip");
    }

    // (2) spans=2: one interior ring lerped at t=0.5.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(2,1,0));
        size_t vertsBefore = m.vertices.length;

        size_t added = bridgeOnce!bridgeOpenRows(m, [0u,1u,2u], [3u,4u,5u], false, 2u, 0.0f);
        assert(added == 4, "spans=2: expected 4 quads (2 spans * (N-1)), got " ~ added.to!string);
        assert(m.vertices.length == vertsBefore + 3,
            "spans=2: expected exactly 3 new interior-ring verts, got "
            ~ (m.vertices.length - vertsBefore).to!string);
        // Every new vertex must sit at y=0.5 (lerp midpoint between y=0 and y=1 rows).
        foreach (vi; vertsBefore .. m.vertices.length)
            assert(abs(m.vertices[vi].y - 0.5f) < 1e-5f,
                "spans=2: interior vertex not at the t=0.5 lerp y-coordinate");
    }

    // (3) Proximity orientation: chain B built/walked in SPATIALLY REVERSED
    // order relative to chain A must still pair by nearest endpoint, not
    // raw index — mirrors the fixture's pairing_proximity_not_selection_order
    // discriminating case. A naive index-pair rule collapses all 3 interior
    // verts onto x=1; proximity pairing keeps them at x=0,1,2.
    {
        Mesh m;
        // Row A: x=0,1,2 (natural order).
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        // Row B: SAME x positions but walked in reverse (b0 at x=2, b2 at x=0).
        m.addVertex(Vec3(2,1,0)); m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
        size_t vertsBefore = m.vertices.length;

        size_t added = bridgeOnce!bridgeOpenRows(m, [0u,1u,2u], [3u,4u,5u], false, 2u, 0.0f);
        assert(added == 4, "proximity case: expected 4 quads, got " ~ added.to!string);
        assert(m.vertices.length == vertsBefore + 3, "proximity case: expected 3 new interior verts");

        bool[3] sawX;   // x=0,1,2
        foreach (vi; vertsBefore .. m.vertices.length) {
            float x = m.vertices[vi].x;
            assert(abs(m.vertices[vi].y - 0.5f) < 1e-5f, "proximity case: interior verts at y=0.5");
            foreach (xi; 0 .. 3)
                if (abs(x - cast(float)xi) < 1e-5f) sawX[xi] = true;
        }
        assert(sawX[0] && sawX[1] && sawX[2],
            "proximity case: interior ring must land on 3 DISTINCT x positions (0,1,2), "
            ~ "not collapse onto x=1 — a raw index-pair rule would fail this");
    }

    // (4) Rejections: either chain shorter than 2 verts.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
        assert(bridgeOnce!bridgeOpenRows(m, [0u], [1u], false, 1u, 0.0f) == 0,
            "single-vertex chain must be rejected");
    }
}

unittest { // bridgeOpenRows: unequal-length fan/triangulate — captured 3:1
           // EXACT face set (task 0395 phase 2, highest-risk piece), and
           // its 1:3 mirror produces the identical fan regardless of which
           // argument position holds the longer chain.
    import std.conv : to;

    Mesh makeFanMesh() {
        Mesh m;
        // Long row: x=0,1,2,3 at y=0 (indices 0..3). Short row: x=0,3 at y=1
        // (indices 4,5) — same total span as the reference capture.
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
        m.addVertex(Vec3(2,0,0)); m.addVertex(Vec3(3,0,0));
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(3,1,0));
        return m;
    }

    void assertCapturedFan(ref Mesh m, size_t vertsBefore, size_t added) {
        assert(added == 3,
            "3:1 fan: expected 3 faces (2 tri + 1 quad), got " ~ added.to!string);
        assert(m.faces.length == 3, "3:1 fan: expected exactly 3 faces total");
        assert(m.vertices.length == vertsBefore, "3:1 fan: zero new verts");
        assert(m.faces[0] == [0u,1u,4u], "3:1 fan: leading tri must be [a0,a1,b0]");
        assert(m.faces[1] == [1u,2u,5u,4u], "3:1 fan: middle quad must be [a1,a2,b1,b0]");
        assert(m.faces[2] == [2u,3u,5u], "3:1 fan: trailing tri must be [a2,a3,b1]");
    }

    // (1) 3:1 — long chain passed as chainA.
    {
        Mesh m = makeFanMesh();
        size_t vertsBefore = m.vertices.length;
        size_t added = bridgeOnce!bridgeOpenRows(m, [0u,1u,2u,3u], [4u,5u], false, 1u, 0.0f);
        assertCapturedFan(m, vertsBefore, added);
    }

    // (2) 1:3 mirror — long chain passed as chainB; must produce the
    // IDENTICAL fan (dispatch normalizes by actual length, not argument
    // position).
    {
        Mesh m = makeFanMesh();
        size_t vertsBefore = m.vertices.length;
        size_t added = bridgeOnce!bridgeOpenRows(m, [4u,5u], [0u,1u,2u,3u], false, 1u, 0.0f);
        assertCapturedFan(m, vertsBefore, added);
    }
}

unittest { // bridgeOpenRows: unequal-length fan — DDA formula (task 0395
           // rr-refinement, static-disassembly-verified bit-exact on 3:1,
           // 4:2, 5:2, 5:3, 6:3) beyond the captured 3:1 ratio: 5:2 (N=5
           // long edges, M=2 short edges). r(i)=ceil(i*M/N-0.5) round-half-
           // DOWN gives r=[0,0,1,1,2,2] for i=0..5, which the DDA (QUAD when
           // r steps up, else TRIANGLE apexed at shortC[r(i)]) turns into
           // tri,quad,tri,quad,tri — 3 triangles + 2 quads = N = 5 faces,
           // asserted here as an EXACT face set (index-for-index, not just
           // a count), the same rigor as the 3:1 case above.
    import std.conv : to;

    Mesh m;
    // Long row: x=0..5 at y=0 (indices 0..5, 5 edges). Short row: x=0,2.5,5
    // at y=1 (indices 6,7,8, 2 edges) — same total span.
    foreach (i; 0 .. 6) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(2.5,1,0)); m.addVertex(Vec3(5,1,0));

    size_t vertsBefore = m.vertices.length;
    size_t added = bridgeOnce!bridgeOpenRows(m, [0u,1u,2u,3u,4u,5u], [6u,7u,8u], false, 1u, 0.0f);

    assert(added == 5, "5:2 fan: expected 5 faces (N), got " ~ added.to!string);
    assert(m.faces.length == 5, "5:2 fan: expected exactly 5 faces total");
    assert(m.vertices.length == vertsBefore, "5:2 fan: zero new verts");

    assert(m.faces[0] == [0u,1u,6u],    "5:2 fan: face 0 must be tri[a0,a1,b0], r=[0,0]");
    assert(m.faces[1] == [1u,2u,7u,6u], "5:2 fan: face 1 must be quad[a1,a2,b1,b0], r=[0,1]");
    assert(m.faces[2] == [2u,3u,7u],    "5:2 fan: face 2 must be tri[a2,a3,b1], r=[1,1]");
    assert(m.faces[3] == [3u,4u,8u,7u], "5:2 fan: face 3 must be quad[a3,a4,b2,b1], r=[1,2]");
    assert(m.faces[4] == [4u,5u,8u],    "5:2 fan: face 4 must be tri[a4,a5,b2], r=[2,2]");
}

unittest { // bridgeStripPaired / bridgeOpenRows: INTRA-STRIP mixed-pinning
           // winding propagation (task 0395 winding-consistency follow-up,
           // review gap). Chain A's FIRST edge (0,1) borders a pre-existing
           // face F0 — orientFaceConsistent must flip the FIRST bridge quad
           // to stay consistent with F0. Chain A's SECOND edge (1,4) is a
           // free wire with no neighbor of its own — before this fix,
           // orientFaceConsistent for the SECOND quad voted only against a
           // STATIC pre-existing snapshot (blind to the first quad, added
           // moments earlier in the SAME loop), saw a 0-0 tie, and kept its
           // default winding — which then shared the rung edge {1,6} with
           // the FIRST (flipped) quad in the SAME direction: a corrupt
           // half-edge fan. The live-registration fix (`registerNewFaceEdges`
           // feeding a mutable `liveEdgeFaces` that grows within the loop)
           // makes the second quad's vote see its already-placed sibling
           // and propagate the flip.
    import std.conv : to;

    Mesh m;
    // Pre-existing face F0 = [0,1,2,3] (index 0); chain A starts on its
    // edge (0,1) and continues past vertex 1 to a brand-new vertex 4 — edge
    // (1,4) borders nothing pre-existing (the "free wire" half of the row).
    m.addVertex(Vec3(0,0,0));  m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0));  m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(2,0,0));
    // Chain B: entirely disconnected row — no pre-existing neighbor anywhere.
    m.addVertex(Vec3(0,-1,0)); m.addVertex(Vec3(1,-1,0)); m.addVertex(Vec3(2,-1,0));
    m.addFace([0u,1u,2u,3u]);   // F0 — face index 0
    m.buildLoops();

    size_t facesBefore = m.faces.length;   // 1 (F0 only)
    size_t added = bridgeOnce!bridgeOpenRows(m, [0u,1u,4u], [5u,6u,7u], false, 1u, 0.0f);
    assert(added == 2, "mixed-pinning strip: expected 2 bridge quads, got " ~ added.to!string);
    assert(m.faces.length == facesBefore + 2, "mixed-pinning strip: expected 3 faces total");

    // Global winding-consistency check across the WHOLE mesh (same style as
    // the owner-repro assert in tools/bridge_tool.d): no two faces may
    // traverse a shared edge in the same direction.
    bool sharesEdgeSameDirection(const(uint)[] a, const(uint)[] b) {
        foreach (i; 0 .. a.length) {
            uint u = a[i], v = a[(i + 1) % a.length];
            foreach (k; 0 .. b.length) {
                uint p = b[k], q = b[(k + 1) % b.length];
                if (u == p && v == q) return true;
            }
        }
        return false;
    }
    foreach (fi; 0 .. m.faces.length)
        foreach (fj; fi + 1 .. m.faces.length)
            assert(!sharesEdgeSameDirection(m.faces[fi], m.faces[fj]),
                "mixed-pinning strip: face " ~ fi.to!string ~ " and face " ~ fj.to!string
                ~ " traverse a shared edge in the SAME direction (half-edge corruption)");

    // Precise propagation check: quad 0 (bordering F0) must flip, AND quad 1
    // (bordering nothing of its own) must flip IN SYNC with it — proving the
    // live sibling vote actually fired, not merely that no corruption
    // happened to occur.
    assert(m.faces[facesBefore]     == [5u,6u,1u,0u],
        "mixed-pinning strip: quad 0 must flip against F0's (0,1) edge");
    assert(m.faces[facesBefore + 1] == [6u,7u,4u,1u],
        "mixed-pinning strip: quad 1 must flip in sync with quad 0 via the shared rung "
        ~ "(sibling propagation) — this is the exact assertion that fails without the "
        ~ "live-edgeFaces fix");
}

unittest { // bridgeLoopsPaired: exact-correspondence quad emission
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t n = bridgeOnce!bridgeLoopsPaired(m, [0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(n == 4, "bridgeLoopsPaired: expected 4 quads");
    assert(m.faces.length == 4, "bridgeLoopsPaired: face count");
    foreach (f; m.faces) assert(f.length == 4, "bridgeLoopsPaired: all quads");

    // bridgeLoops still produces the same count (its tail now calls bridgeLoopsPaired).
    Mesh m2;
    m2.addVertex(Vec3(0,0,0)); m2.addVertex(Vec3(1,0,0));
    m2.addVertex(Vec3(1,1,0)); m2.addVertex(Vec3(0,1,0));
    m2.addVertex(Vec3(0,0,1)); m2.addVertex(Vec3(1,0,1));
    m2.addVertex(Vec3(1,1,1)); m2.addVertex(Vec3(0,1,1));
    size_t n2 = bridgeOnce!bridgeLoops(m2, [0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(n2 == 4, "bridgeLoops via bridgeLoopsPaired: expected 4 quads");
    assert(m2.faces.length == 4, "bridgeLoops: face count unchanged after refactor");
}

// ---------------------------------------------------------------------------
// Task 0901 — corner-provenance obligation (task 0830's vocabulary). Bridge's
// five entry points bottom out in `bridgeLoopsPaired` / `bridgeStripPaired` /
// `bridgeFanRows`, all of which only ever call `addFace` — never a bare
// `faces ~=` — so a bridge is the tail-APPEND shape, not a drop: it does not
// touch a single corner outside the faces it adds. These blocks pin that,
// against a face the bridge never touches, so a regression to
// `CornerDrop.SweptSurfaceNoLaw` (which would zero the WHOLE map) is
// distinguishable from the correct behaviour.
// ---------------------------------------------------------------------------

// Face 0 = [0,1,2,3], a quad with no relationship to the vertices any of the
// blocks below bridge — its four corners are the "did the operation touch
// something it shouldn't have" probe. Values are keyed 1000+corner so a
// dropped (zeroed) value is unambiguous.
private Mesh meshWithUnrelatedUvQuad() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0, 1, 2, 3]);
    m.buildLoops();

    MeshMap uv;
    uv.name   = "uv";
    uv.dim    = 2;
    uv.domain = MapDomain.PolyVertex;
    uv.data.length = m.loops.length * 2;
    foreach (li; 0 .. m.loops.length) {
        uv.data[li * 2]     = 1000.0f + li;
        uv.data[li * 2 + 1] = 2000.0f + li;
    }
    m.meshMaps ~= uv;
    return m;
}

private const(float)[] uvDataOf(ref Mesh m) {
    foreach (ref mm; m.meshMaps)
        if (mm.domain == MapDomain.PolyVertex) return mm.data;
    return null;
}

unittest { // bridgeLoopsPaired (closed loop): unrelated face's UV survives byte-for-byte
    Mesh m = meshWithUnrelatedUvQuad();
    const float[] before = uvDataOf(m)[0 .. 8].dup;   // face 0's 4 corners * dim 2

    // A separate coaxial-squares pair, disjoint from face 0's vertices 0..3.
    foreach (p; [Vec3(0,0,1), Vec3(1,0,1), Vec3(1,1,1), Vec3(0,1,1),
                 Vec3(0,0,2), Vec3(1,0,2), Vec3(1,1,2), Vec3(0,1,2)])
        m.addVertex(p);
    size_t added = bridgeOnce!bridgeLoops(m, [4u,5u,6u,7u], [8u,9u,10u,11u]);
    assert(added == 4, "expected 4 bridge quads");
    m.buildLoops();

    const(float)[] after = uvDataOf(m);
    assert(after.length == m.loops.length * 2, "map stays length-correct");
    assert(after[0 .. 8] == before,
           "an untouched face's UV must survive a bridge byte-for-byte — a "
           ~ "SweptSurfaceNoLaw-style whole-map drop would zero this");
    // The 4 new bridge quads' corners have no measured law — honest zero,
    // not a guess.
    foreach (v; after[8 .. $])
        assert(v == 0.0f, "a bridge quad's own corners are the honest zero");
}

unittest { // bridgeStripPaired / bridgeOpenRows: same guarantee on the open-row path
    Mesh m = meshWithUnrelatedUvQuad();
    const float[] before = uvDataOf(m)[0 .. 8].dup;

    foreach (p; [Vec3(2,0,0), Vec3(3,0,0), Vec3(4,0,0),
                 Vec3(2,1,0), Vec3(3,1,0), Vec3(4,1,0)])
        m.addVertex(p);
    size_t added = bridgeOnce!bridgeOpenRows(m, [4u,5u,6u], [7u,8u,9u], false, 1u, 0.0f);
    assert(added == 2, "expected 2 bridge quads on the open-row path");
    m.buildLoops();

    const(float)[] after = uvDataOf(m);
    assert(after.length == m.loops.length * 2, "map stays length-correct");
    assert(after[0 .. 8] == before,
           "bridgeOpenRows must not touch a face outside the two chains it bridges");
    foreach (v; after[8 .. $])
        assert(v == 0.0f, "a bridged strip quad's own corners are the honest zero");
}

unittest { // bridgeFanRows (unequal-length open rows): same guarantee
    Mesh m = meshWithUnrelatedUvQuad();
    const float[] before = uvDataOf(m)[0 .. 8].dup;

    // Long chain (4 verts, 3 edges) vs short chain (2 verts, 1 edge) — the
    // captured 3:1 fan case (tri/quad/tri).
    foreach (p; [Vec3(2,0,0), Vec3(3,0,0), Vec3(4,0,0), Vec3(5,0,0),
                 Vec3(2,1,0), Vec3(5,1,0)])
        m.addVertex(p);
    size_t added = bridgeOnce!bridgeOpenRows(m, [4u,5u,6u,7u], [8u,9u], false, 1u, 0.0f);
    assert(added == 3, "expected 3 faces (2 tri + 1 quad) on the fan path");
    m.buildLoops();

    const(float)[] after = uvDataOf(m);
    assert(after.length == m.loops.length * 2, "map stays length-correct");
    assert(after[0 .. 8] == before,
           "bridgeFanRows must not touch a face outside the two chains it fans");
    foreach (v; after[8 .. $])
        assert(v == 0.0f, "a fanned face's own corners are the honest zero");
}


// ===========================================================================
// THE RECORDING BATCH — the only lane in the tree that can see what this
// family DECLARES and what it RECORDS (task 1903 Stage D3; the obligation is
// Stage D2 review memo item 9, "every mutating family owes its ops test one
// recording block").
//
// Every production caller opens an UNRECORDED batch (§5.1: track 1 is the
// conversion axis, undo still goes through a whole-mesh `MeshSnapshot` at
// `commands/mesh/bridge.d` and through `MeshSessionEdit` at `BridgeTool`), so
// `kBridgeEditScope` reaches nothing but `MeshEditTracker.declare`, and
// `pushEditFrame` only calls that when a recorder exists. A constant no test
// can read is a constant that can drift to anything — measured at D2, where
// setting the reduce family's scope to 0 left 275 modules and its suite test
// green.
//
// Mutations:
//   * `enum uint kBridgeEditScope = 0;` (mesh_ops/bridge.d) → assertion (a)
//   * drop the `ed.addVertex(...)` interior-ring write for a raw
//     `ed.vertices ~= …`                                     → assertion (b)
//   * make any kernel move an EXISTING vertex                → assertion (c)
//   * break the `AddFaces` recording in `Mesh.addFace`       → assertion (b)
// ===========================================================================

private string dumpMeshState(ref Mesh m) {
    import std.conv : to;
    import std.format : format;
    string s = format("V=%d F=%d", m.vertices.length, m.faces.length);
    // `%a` — the HEX float form, so this compares BITS. `%g` would let a
    // `-0.0`/`+0.0` pair read as equal, which is the exact cell Stage D2 had to
    // build a special stand for.
    foreach (i, v; m.vertices) s ~= format(" v%d(%a,%a,%a)", i, v.x, v.y, v.z);
    foreach (i, f; m.faces)    s ~= format(" f%d%s", i, f.to!string);
    s ~= " marks" ~ m.faceMarks.to!string;
    return s;
}

/// Two coaxial unit squares, each an actual FACE, and the far cap carries the
/// Subpatch bit. The bit is not decoration: `bridgeLoopsPaired` inherits
/// Subpatch from the pre-existing adjacent faces of its bridged edges, so a
/// stand of eight loose vertices (which every block above uses) would leave the
/// whole Marks channel of the revert untested.
private Mesh twoCappedRings() {
    Mesh m;
    foreach (z; [0.0f, 1.0f])
        foreach (p; [[0.0f, 0.0f], [1.0f, 0.0f], [1.0f, 1.0f], [0.0f, 1.0f]])
            m.addVertex(Vec3(p[0], p[1], z));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.resizeSubpatch();
    m.setFaceSubpatch(1, true);
    m.buildLoops();
    return m;
}

unittest // a recording bridge declares kBridgeEditScope, logs AddVerts/AddFaces
{        // and reverts COMPLETELY — measured, not assumed
    import std.format : format;

    foreach (spans; [1u, 3u]) {
        Mesh m = twoCappedRings();
        immutable string preState = dumpMeshState(m);
        immutable size_t preV = m.vertices.length;
        immutable size_t preF = m.faces.length;

        MeshEditDelta d;
        size_t n;
        {
            auto ed = MeshEditBatch(m, kBridgeEditScope);   // RECORDING
            n = ed.bridgeLoopsSpans([0u, 1u, 2u, 3u], [4u, 5u, 6u, 7u],
                                    false, spans, 0.0f);
            d = ed.close();
        }

        // Anti-vacuity: a rejected bridge would satisfy (a) and (d) trivially
        // and could not exhibit (b) at all.
        assert(n == 4 * spans,
            format("spans=%d: the stand bridged %d faces, expected %d — every "
                 ~ "assertion below would be vacuous on it", spans, n, 4 * spans));
        assert(m.faces.length == preF + 4 * spans,
            format("spans=%d: face count went %d -> %d", spans, preF, m.faces.length));

        // (a) THE DECLARED SCOPE, spelled out from the enum and NOT compared
        //     against `kBridgeEditScope` itself.
        //
        //     `d.scope_` IS `kBridgeEditScope` fed through
        //     `MeshEditTracker.declare`, so `d.scope_ == kBridgeEditScope` is
        //     the measurement judging itself: set the constant to 0 and that
        //     equality is still true (measured at Stage D2 on the reduce
        //     family, where exactly that draft stayed green). The expectation
        //     below is written from what the kernels DO: they append faces
        //     (Polygons), append interior-ring vertices on a multi-span path
        //     (Points) and stamp the inherited Subpatch bit (Marks).
        //     `MeshEditDelta.finalize` reads `scope_` back on a revert to
        //     decide what to bump and rebuild, so a wrong constant is a wrong
        //     invalidation, not a cosmetic mismatch.
        immutable uint kExpectedScope = MeshEditScope.Points | MeshEditScope.Polygons
                                      | MeshEditScope.Marks;
        assert(cast(uint)d.scope_ == kExpectedScope,
            format("spans=%d: a recording bridge declared scope 0x%x, expected "
                 ~ "0x%x (Points|Polygons|Marks). Missing: 0x%x. Unexpected: "
                 ~ "0x%x. (task 1903 Stage D3)",
                   spans, cast(uint)d.scope_, kExpectedScope,
                   kExpectedScope & ~cast(uint)d.scope_,
                   cast(uint)d.scope_ & ~kExpectedScope));

        //     …and THEN the link: the constant is what the callers pass and
        //     what reaches the delta. This one cannot see a wrong constant (see
        //     above); it sees a broken `declare`/`close` path.
        assert(cast(uint)d.scope_ == kBridgeEditScope,
            format("spans=%d: the delta's scope_ (0x%x) is not the "
                 ~ "kBridgeEditScope the batch was opened with (0x%x) — the "
                 ~ "declared scope is not reaching MeshEditDelta.scope_ at all",
                   spans, cast(uint)d.scope_, kBridgeEditScope));

        // (b) THE OP-LOG SHAPE. `addFace` coalesces a run of appends into ONE
        //     `AddFaces` range entry, and `addVertex` likewise — so the counts
        //     below are 1, not `4*spans` and `spans-1`, and a kernel that
        //     appended through a bare `faces ~= …` / `vertices ~= …` instead of
        //     the hooked mutators would drop to 0.
        size_t addFaces, addVerts, setPos;
        foreach (ref e; d.log) {
            if (e.kind == MeshOpEntry.Kind.AddFaces) ++addFaces;
            if (e.kind == MeshOpEntry.Kind.AddVerts) ++addVerts;
            if (e.kind == MeshOpEntry.Kind.SetPos)   ++setPos;
        }
        assert(addFaces == 1,
            format("spans=%d: the op-log carries %d Kind.AddFaces entries, "
                 ~ "expected exactly 1 — every bridge quad must go through "
                 ~ "Mesh.addFace, which is the hooked appender; a bare "
                 ~ "`faces ~= …` compiles inside a recording batch "
                 ~ "(`alias mesh this`) and records nothing",
                   spans, addFaces));
        immutable size_t kExpectedAddVerts = (spans > 1) ? 1 : 0;
        assert(addVerts == kExpectedAddVerts,
            format("spans=%d: the op-log carries %d Kind.AddVerts entries, "
                 ~ "expected %d — a multi-span bridge creates spans-1 interior "
                 ~ "rings through Mesh.addVertex and a single-span one creates "
                 ~ "no vertex at all", spans, addVerts, kExpectedAddVerts));

        // (c) NO POSITION WRITE, EVER. This is the behavioural half of the
        //     claim `kBridgeEditScope`'s doc comment makes ("NOT Position") and
        //     of this family's §5.7 count being 0 rather than a retired
        //     allow-entry: no bridge kernel moves an EXISTING vertex, every
        //     coordinate it produces belongs to a vertex it created in the same
        //     call and travels in the AddVerts entry. If a later edit makes a
        //     kernel move one, this reddens and `kBridgeEditScope` needs
        //     `MeshEditScope.Position` added in the same change.
        assert(setPos == 0,
            format("spans=%d: the op-log carries %d Kind.SetPos entries, "
                 ~ "expected 0 — a bridge kernel now moves an EXISTING vertex. "
                 ~ "That is a real behaviour change: add MeshEditScope.Position "
                 ~ "to kBridgeEditScope and rewrite its doc comment, or take "
                 ~ "the write back out (task 1903 §5.7)", spans, setPos));

        // (d) THE REVERT IS COMPLETE — MEASURED FOR THIS FAMILY, and the
        //     measurement is why this is an equality and not a
        //     KNOWN-INCOMPLETE. Stage D2's decimate family reverts its vertex
        //     side and only HALF its faces, because its face drops leave
        //     through `mesh_planes.rewriteFaces` with `FaceReindex` disarmed.
        //     Bridge never reindexes: it only ever APPENDS, so `AddFaces` /
        //     `AddVerts` reverse cleanly and the whole state — windings,
        //     coordinate BITS and the faceMarks Subpatch word — comes back.
        //     Measured on this stand at both span counts before this assertion
        //     was written (memo item 10: open the batch, call revert(), compare
        //     BOTH lengths, do not assert the constructor flip is a one-liner).
        //
        //     What this does NOT say: that `mesh.bridge`'s undo is a
        //     constructor flip. That command deletes the cap faces AFTER the
        //     batch closes, and that deletion is a separate op with its own
        //     face-side question.
        const bool reverted = d.revert(m);
        assert(reverted,
            format("spans=%d: revert() refused the delta outright", spans));
        assert(m.vertices.length == preV && m.faces.length == preF,
            format("spans=%d: revert restored V=%d F=%d, expected V=%d F=%d — "
                 ~ "an append-only delta must come back whole",
                   spans, m.vertices.length, m.faces.length, preV, preF));
        immutable string postState = dumpMeshState(m);
        assert(postState == preState,
            format("spans=%d: revert restored the counts but not the state.\n"
                 ~ "  pre : %s\n  post: %s", spans, preState, postState));
    }
}
