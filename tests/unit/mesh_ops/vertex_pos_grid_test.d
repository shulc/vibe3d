// Module unittests for `mesh_ops.extrude.VertexPosGrid` (task 1331).
//
// The grid replaced a full linear scan of `vertices` in edge_extrude's ridge
// reselect — the scan that carried ~95% of that command's 27.4 s on a 100K-face
// mesh. The replacement is only admissible if it answers IDENTICALLY, so these
// blocks pin the two halves of that claim separately:
//
//   * VALUE — `findMin` returns exactly what the scan returned, including the
//     tie rule (the LOWEST matching index), the treatment of non-finite
//     coordinates, and coordinates far from the origin, where a bit-packed cell
//     key would have aliased.
//   * COST — the query examines O(1) candidates, not O(V). Nothing else can see
//     the difference: a scan and the grid return the same index, so every
//     value-based assertion stays green if someone "simplifies" the grid away.
//     `g_vertexPosGridCandidates` is the only instrument that can tell them
//     apart, and the block below is the only thing holding the fix in place.
module tests.unit.mesh_ops.vertex_pos_grid_test;

import mesh;
import math;
import mesh_ops.extrude : VertexPosGrid, g_vertexPosGridCandidates;
import std.conv : to;
import std.algorithm : sort;

// The predicate the grid must reproduce, written out here independently of the
// implementation so a change to one does not silently follow into the other.
private int scanRef(Vec3 p, const(Vec3)[] verts) {
    foreach (i, ref v; verts)
        if ((v - p).length < 1e-5f) return cast(int)i;
    return -1;
}

unittest { // VertexPosGrid: the tie goes to the LOWEST index, in every cell layout
    // Three vertices inside one 1e-5 ball, deliberately straddling cell
    // boundaries so the matches do NOT share a cell: the answer must not depend
    // on which bucket the walk reaches first.
    Vec3[] verts = [
        Vec3(0.0f, 0.0f, 0.0f),          // far decoy
        Vec3(1.0f, 2.0f, 3.0f),          // index 1 — the expected answer
        Vec3(1.0f + 3e-6f, 2.0f, 3.0f),  // index 2 — same ball
        Vec3(1.0f - 3e-6f, 2.0f + 3e-6f, 3.0f), // index 3 — same ball, other cell
        Vec3(5.0f, 5.0f, 5.0f),          // far decoy
    ];
    VertexPosGrid g;
    g.build(verts);

    // Query each of the three coincident-ish points: all three must answer 1.
    foreach (qi; [1, 2, 3]) {
        immutable got = g.findMin(verts[qi]);
        assert(got == 1, "findMin must return the LOWEST matching index, got " ~ got.to!string);
        assert(got == scanRef(verts[qi], verts), "grid disagrees with the linear scan");
    }

    // A point with no match at all.
    assert(g.findMin(Vec3(-9.0f, -9.0f, -9.0f)) == -1);
    assert(scanRef(Vec3(-9.0f, -9.0f, -9.0f), verts) == -1);
}

unittest { // VertexPosGrid: exhaustive agreement with the scan on a dense cloud
    // A deterministic cloud whose spacing brackets the 1e-5 radius from both
    // sides, so queries land just inside and just outside the match band and on
    // both sides of a cell boundary. Every query is cross-checked against the
    // reference scan — this is the block that would catch a wrong neighbourhood,
    // a wrong hash, or an off-by-one in the bucket offsets.
    Vec3[] verts;
    uint seed = 12345;
    float rnd() { seed = seed * 1664525u + 1013904223u; return cast(float)(seed >> 8) / cast(float)(1 << 24); }

    foreach (k; 0 .. 400) {
        // Base points on a coarse lattice…
        immutable float bx = -1.0f + 2.0f * rnd();
        immutable float by = -1.0f + 2.0f * rnd();
        immutable float bz = -1.0f + 2.0f * rnd();
        verts ~= Vec3(bx, by, bz);
        // …each with a companion at a spacing swept across the 1e-5 radius,
        // including exactly-coincident duplicates (which the extrude kernel
        // mints on purpose in its saturated regime).
        immutable float d = (k % 5) * 5e-6f;   // 0, 5e-6, 1e-5, 1.5e-5, 2e-5
        verts ~= Vec3(bx + d, by, bz);
    }

    VertexPosGrid g;
    g.build(verts);

    size_t mismatches = 0;
    foreach (i, ref v; verts) {
        if (g.findMin(v) != scanRef(v, verts)) ++mismatches;
        // Also probe just off each vertex, on each axis, inside and outside.
        foreach (off; [-1.2e-5f, -9e-6f, -3e-6f, 3e-6f, 9e-6f, 1.2e-5f]) {
            auto q = Vec3(v.x + off, v.y, v.z);
            if (g.findMin(q) != scanRef(q, verts)) ++mismatches;
            auto q2 = Vec3(v.x, v.y + off, v.z);
            if (g.findMin(q2) != scanRef(q2, verts)) ++mismatches;
            auto q3 = Vec3(v.x, v.y, v.z + off);
            if (g.findMin(q3) != scanRef(q3, verts)) ++mismatches;
        }
    }
    assert(mismatches == 0, "VertexPosGrid disagreed with the linear scan");
}

unittest { // VertexPosGrid: far from the origin — where a packed cell key aliases
    // A 21-bit-per-axis packed key at a 1e-5 cell overflows above roughly ±10
    // units. These coordinates are 1e5 and 1e6 units out (a model authored in
    // millimetres, or this command's own octahedron-at-width-50 fixture scaled
    // up), and the answers must still be the scan's.
    foreach (origin; [Vec3(0, 0, 0), Vec3(50, -50, 50), Vec3(1.0e5f, 1.0e5f, -1.0e5f),
                      Vec3(1.0e6f, -1.0e6f, 1.0e6f)]) {
        Vec3[] verts;
        foreach (k; 0 .. 32) {
            immutable float t = cast(float)k;
            verts ~= Vec3(origin.x + t * 0.25f, origin.y, origin.z);
            verts ~= Vec3(origin.x + t * 0.25f + 4e-6f, origin.y, origin.z); // in-band twin
        }
        VertexPosGrid g;
        g.build(verts);
        foreach (i, ref v; verts)
            assert(g.findMin(v) == scanRef(v, verts),
                   "far-from-origin query diverged from the linear scan");
    }
}

unittest { // VertexPosGrid: beyond kSafeQuery the LINEAR SCAN answers — and is reached
    // `linearScan` is reachable ONLY through the `kSafeQuery` guard in `findMin`
    // (or an empty array), and until this block NOTHING reached it: the
    // "far from origin" block above stops at 1e6, three orders below the 1e9
    // bound, so deleting all three `kSafeQuery` comparisons left every block in
    // this file green (verified by mutation, task 1331 review). The declared
    // fallback was asserted by comment only — and it is precisely the path that
    // silently restores the O(V) behaviour this task removed.
    //
    // 2e9 is also past `kMaxCoord` (1e9), so the far vertex is DROPPED at build
    // time: without the guard the grid would answer -1 here, having examined a
    // handful of near-origin candidates. Both halves are asserted — the COUNT
    // (the fallback ran) and the VALUE (it still answers the scan's index).
    enum size_t N = 4096;
    Vec3[] verts;
    verts.length = N;
    foreach (i; 0 .. N - 1) {
        immutable float t = cast(float)i;
        verts[i] = Vec3(t * 0.01f, (t % 89) * 0.17f, (t % 37) * 0.23f);
    }
    // 2e9 is exactly representable in float (15 625 000 x 2^7), so the query is
    // bit-equal to the stored vertex and the distance is exactly 0. It sits LAST
    // so a scan has to walk the whole array — that is what makes the candidate
    // count O(V) rather than O(1) by luck.
    immutable Vec3 far = Vec3(2.0e9f, -2.0e9f, 2.0e9f);
    verts[N - 1] = far;

    VertexPosGrid g;
    g.build(verts);

    g_vertexPosGridCandidates = 0;
    immutable got = g.findMin(far);
    immutable cand = g_vertexPosGridCandidates;

    // THE pin on the fallback: O(V) candidates, not O(1). The grid path cannot
    // produce this number, so a deleted guard cannot go green here.
    assert(cand == N,
           "the kSafeQuery fallback did not run: " ~ cand.to!string
           ~ " candidates examined, a full scan of this array is " ~ N.to!string);
    assert(got == cast(int)(N - 1),
           "out-of-range query must still find its match, got " ~ got.to!string);
    assert(got == scanRef(far, verts), "out-of-range query diverged from the linear scan");

    // The same query one ulp INSIDE the guard is answered by the grid, so the
    // count above is about the guard and not about the magnitude as such.
    immutable Vec3 inside = Vec3(1.0e8f, 1.0e8f, 1.0e8f);
    verts[N - 2] = inside;
    g.build(verts);
    g_vertexPosGridCandidates = 0;
    assert(g.findMin(inside) == cast(int)(N - 2));
    assert(g_vertexPosGridCandidates < 64,
           "a query inside kSafeQuery must go through the grid, not the scan");
}

unittest { // VertexPosGrid: non-finite coordinates match nothing, on both sides
    // `cast(long)(float.nan * 1e5f)` is undefined in D, and degenerate meshes
    // from the fuzz corpus do reach this kernel. Both the stored vertex and the
    // query are exercised.
    Vec3[] verts = [
        Vec3(float.nan, 0.0f, 0.0f),
        Vec3(0.0f, float.infinity, 0.0f),
        Vec3(1.0f, 1.0f, 1.0f),
        Vec3(-float.infinity, 2.0f, 2.0f),
    ];
    VertexPosGrid g;
    g.build(verts);

    // A finite query never matches a non-finite vertex — same as the scan.
    assert(g.findMin(Vec3(1.0f, 1.0f, 1.0f)) == 2);
    assert(g.findMin(Vec3(1.0f, 1.0f, 1.0f)) == scanRef(Vec3(1.0f, 1.0f, 1.0f), verts));

    // A non-finite query matches NOTHING, including the identically-non-finite
    // vertex: `NaN < 1e-5f` is false, so the scan returned -1 too.
    foreach (q; [Vec3(float.nan, 0.0f, 0.0f), Vec3(0.0f, float.infinity, 0.0f),
                 Vec3(float.nan, float.nan, float.nan)]) {
        assert(g.findMin(q) == -1);
        assert(scanRef(q, verts) == -1);
    }
}

unittest { // VertexPosGrid: the predicate is the SQRT form, not the squared one
    // `(v - p).length < 1e-5f` and the tempting rewrite `dot(d,d) < 1e-10f` are
    // NOT the same predicate: `float((1e-5f)^2)` is 9.999999440e-11, which is
    // BELOW `1e-10f` (1.000000013e-10), so the squared form accepts a band the
    // sqrt form rejects. This block sits exactly in that band — it is the only
    // thing that can catch the rewrite, because no realizable extrude fixture
    // lands a ridge lookup there (measured: swapping the forms leaves all 14
    // byte-comparison fixtures identical).
    Vec3[] verts = [ Vec3(0.0f, 0.0f, 0.0f), Vec3(1e-5f, 0.0f, 0.0f) ];
    VertexPosGrid g;
    g.build(verts);

    // Distance between them is EXACTLY 1e-5f, and the comparison is strict, so
    // neither matches the other — each query must answer with itself.
    assert(g.findMin(verts[1]) == 1,
           "the squared-distance rewrite would answer 0 here");
    assert(g.findMin(verts[1]) == scanRef(verts[1], verts));
    assert(g.findMin(verts[0]) == 0);
    assert(g.findMin(verts[0]) == scanRef(verts[0], verts));
}

unittest { // VertexPosGrid: the COST guard — O(1) candidates per query, not O(V)
    // Without this block nothing in the suite can tell the grid from the scan
    // it replaced: they return the same index by construction. This is the only
    // assertion that fails if the O(V) scan comes back.
    enum size_t N = 20_000;
    Vec3[] verts;
    verts.length = N;
    foreach (i; 0 .. N) {
        immutable float t = cast(float)i;
        verts[i] = Vec3(t * 0.01f, (t % 97) * 0.13f, (t % 31) * 0.29f);
    }

    VertexPosGrid g;
    g.build(verts);

    // Query the LAST vertices — the worst case for a scan, which would examine
    // ~N candidates each.
    enum size_t Q = 200;
    g_vertexPosGridCandidates = 0;
    foreach (i; N - Q .. N)
        assert(g.findMin(verts[i]) == cast(int)i);
    immutable perQuery = g_vertexPosGridCandidates / Q;

    // The linear scan averaged ~N (here 20 000) candidates per query on this
    // access pattern. A generous ceiling of 32 still separates the two by three
    // orders of magnitude, so this cannot go green on an accidental scan.
    assert(perQuery <= 32,
           "VertexPosGrid examined too many candidates per query — the O(V) scan is back");
}

unittest { // VertexPosGrid: `findMin` CANNOT be pointed at a different array
    // Before SHOULD-FIX 2 (task 1331 review) the signature was
    // `findMin(Vec3 p, const(Vec3)[] verts)`, and `g.build(long); g.findMin(p,
    // short);` was a perfectly sayable out-of-bounds read: `buckets` holds
    // indices into the array `build` walked, and the `perf` buildType is
    // `releaseMode`, so the bounds check is stripped exactly where this kernel
    // is measured. The prose invariant on `build` covered MUTATION of the array
    // and not SUBSTITUTION of a different one. The repair is structural: the
    // grid holds the slice, `findMin` takes none, and the bad call does not
    // compile.
    //
    // A COMPILE-TIME refutation is the only instrument that can see this, and
    // that is a measured claim, not a preference: a value-level version of this
    // block — build over 3, append a 4th, assert the grid cannot see it — stays
    // GREEN under the mutation that restores the parameter (M9), because
    // `buckets` already bounds the answer to the built extent whichever array is
    // handed in. An assertion that cannot fail is not a check, so it is not here.
    Vec3[] built = [ Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0), Vec3(3,0,0), Vec3(4,0,0) ];
    Vec3[] shorter = [ Vec3(0,0,0) ];
    VertexPosGrid g;
    g.build(built);
    assert(g.findMin(Vec3(4,0,0)) == 4);
    assert(g.findMin(Vec3(0,0,0)) == 0);

    // Negative first, deliberately: dmd abandons a unittest body at its first
    // static-assert error, so whichever comes first is the one a mutation
    // actually reports. The negative is the load-bearing half.
    static assert(!__traits(compiles, g.findMin(Vec3(0,0,0), shorter)),
        "findMin must take NO array: re-adding the parameter re-opens the "
        ~ "out-of-bounds read at verts[vi] that SHOULD-FIX 2 closed structurally");
    static assert(__traits(compiles, g.findMin(Vec3(0,0,0))));
}

unittest { // edge_extrude end to end: the ridge reselect elects the ridge AND stamps it
    // The grid's caller. A 4x4 grid plane with every edge selected runs the full
    // kernel; the product selection must be exactly one edge per extruded edge,
    // each stamped ONCE, the stamps forming a contiguous run.
    //
    // The run starts wherever the counter already stood, NOT at 0:
    // `edgeSelectionOrderCounter` is a monotone global and
    // `clearEdgeSelectionResize` deliberately leaves it alone ("the counter is
    // left alone", mesh.d). So `counter == n` would assert a property of the
    // FIXTURE'S HISTORY — it holds only because `makeGridPlane` hands back a
    // mesh whose counter is still 0 and the mask here is a raw `bool[]` rather
    // than a `selectEdge` call. The counter is seeded below precisely so that is
    // no longer true, and every assertion is on the DELTA (task 1331 review).
    Mesh m = makeGridPlane(4);
    m.resizeEdgeSelection();                            // the factory leaves the mark arrays empty
    foreach (i; 0 .. 3) m.selectEdge(cast(int)i);       // a selection history
    immutable int before = m.edgeSelectionOrderCounter;
    assert(before == 3, "fixture must carry a non-zero selection history, got " ~ before.to!string);

    auto mask = new bool[m.edges.length];
    mask[] = true;
    immutable n = m.extrudeEdgesByMask(mask, 0.2f, 0.05f);
    assert(n > 0);

    int[] stamps;
    foreach (i; 0 .. m.edges.length)
        if (m.edgeMarks[i] & Mesh.Marks.Select) stamps ~= m.edgeSelectionOrder[i];
    assert(stamps.length == n, "one selected ridge edge per extruded edge");

    // Exactly `n` NEW selections were stamped — no ridge edge fell out of the
    // position lookup, and none was elected twice (`selectEdge` bumps the
    // counter only on a 0 -> 1 transition, so a double election would show up
    // as a SHORTFALL here).
    assert(m.edgeSelectionOrderCounter == before + cast(int)n,
           "ridge reselect must advance the order counter by exactly the ridge count: +"
           ~ (m.edgeSelectionOrderCounter - before).to!string ~ " for " ~ n.to!string ~ " edges");

    // ...and the stamps are the contiguous run (before, before + n], i.e. the
    // reselect is the only thing that stamped between those two reads.
    stamps.sort();
    foreach (k, st; stamps)
        assert(st == before + cast(int)k + 1,
               "ridge stamps must run contiguously from the pre-existing counter; at k="
               ~ k.to!string ~ " got " ~ st.to!string ~ ", expected " ~ (before + cast(int)k + 1).to!string);
}
