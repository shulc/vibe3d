// Shared fixtures for module unittests (task 0706).
//
// One copy of the small mesh helpers that every extracted test block used to
// carry inline. Only put something here once it is used by more than one test
// module and its contract is written down -- a fixture layer that accumulates
// one-off helpers is just a second god-file.
module tests.unit.fixtures;

import mesh;
import math;

/// Index in `m.edges[]` of the edge joining `a` and `b`, or **-1** when there
/// is none. Vertex order does not matter.
///
/// WHY THIS IS NOT `Mesh.edgeIndex`. `Mesh` already answers this question, and
/// answers it in O(1): `edgeIndex(a, b)` looks `a`/`b` up in `edgeIndexMap`.
/// The 36 inline copies this function replaces all chose the O(E) scan
/// instead, and merging them onto the fast one would be a behaviour change in
/// two separate ways:
///
///  1. **Different sentinel, and the difference is silent.** `edgeIndex`
///     returns `uint` and reports "no such edge" as `~0u`. Every one of the
///     copies returns `int` and tests the result with `>= 0` -- which is
///     vacuously true for a `uint`, so a mechanical swap would turn "not
///     found" into "found edge 4294967295" and index out of bounds one line
///     later, in a test whose whole job is to notice that kind of thing.
///  2. **Different precondition.** `edgeIndexMap` is derived state carrying an
///     explicit `Stale` / `Valid` / `DeliberatelyEmpty` status stamped against
///     `structVersion`; `Mesh` even ships `assertEdgeMapValid()` for readers
///     that must be settled. `edgeIndex` reads the map unguarded, so on a mesh
///     whose topology a kernel has just rewritten it can answer from stale
///     data. A scan over `m.edges[]` has no such precondition, and asserting
///     on a freshly mutated mesh is exactly what these tests do.
///
/// So the scan is kept deliberately. It is a fixture, not a hot path: O(E) on
/// meshes with tens of edges is free, and being independent of derived state
/// is the property that makes it safe to call anywhere in a test.
int findEdge(ref Mesh m, uint a, uint b)
{
    foreach (i; 0 .. m.edges.length)
    {
        uint x = m.edges[i][0], y = m.edges[i][1];
        if ((x == a && y == b) || (x == b && y == a)) return cast(int) i;
    }
    return -1;
}

/// Triangle-fan disk: a hub vertex at the origin plus `n` rim vertices on the
/// unit circle in the z=0 plane, joined by `n` triangles wound hub-first.
/// Vertex 0 is the hub; rim vertex `i` is index `1 + i`.
///
/// Loops and selection are built before returning, so the result is a settled
/// mesh a kernel can be pointed at directly.
Mesh makeDisk(int n)
{
    import std.math : cos, sin, PI;

    Mesh m;
    m.vertices ~= Vec3(0, 0, 0);
    foreach (i; 0 .. n)
    {
        immutable float a = 2.0f * PI * i / n;
        m.vertices ~= Vec3(cos(a), sin(a), 0);
    }
    foreach (i; 0 .. n)
        m.addFace([0u, cast(uint)(1 + i), cast(uint)(1 + (i + 1) % n)]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

// ---------------------------------------------------------------------------
// The fixtures' own contracts. These are what the 36 + 13 inline copies agreed
// on; pinning them here is what makes replacing the copies a refactor rather
// than a rewrite.
// ---------------------------------------------------------------------------

unittest // findEdge: symmetric in its arguments, and -1 (not ~0u) when absent
{
    auto m = makeCube();

    int ei = findEdge(m, 6, 7);
    assert(ei >= 0, "cube edge (6,7) must exist");
    assert(findEdge(m, 7, 6) == ei, "findEdge must not care about vertex order");

    uint x = m.edges[ei][0], y = m.edges[ei][1];
    assert((x == 6 && y == 7) || (x == 7 && y == 6),
           "findEdge must return the index of the edge it was asked for");

    // The sentinel is the whole reason this is not Mesh.edgeIndex: it must be
    // negative, so the `>= 0` test every caller writes actually discriminates.
    int missing = findEdge(m, 0, 6);   // a cube face diagonal — not an edge
    assert(missing == -1, "absent edge must report -1");
    assert(missing < 0, "the sentinel must fail a `>= 0` test");
    assert(m.edgeIndex(0, 6) == ~0u,
           "Mesh.edgeIndex reports absence as ~0u — which PASSES `>= 0`, "
           ~ "which is why these two are not interchangeable");
}

unittest // makeDisk: hub-first fan, n triangles, n+1 verts, all rim on the unit circle
{
    import std.math : abs, sqrt;

    foreach (n; [3, 4, 6, 12])
    {
        auto m = makeDisk(n);
        assert(m.vertices.length == n + 1, "disk: one hub plus n rim verts");
        assert(m.faces.length == n,        "disk: one triangle per rim segment");
        assert(m.vertices[0].x == 0 && m.vertices[0].y == 0 && m.vertices[0].z == 0,
               "disk: vertex 0 is the hub at the origin");

        foreach (i; 1 .. m.vertices.length)
        {
            auto v = m.vertices[i];
            assert(abs(sqrt(v.x * v.x + v.y * v.y) - 1.0f) < 1e-5f,
                   "disk: rim vertices sit on the unit circle");
            assert(v.z == 0, "disk: the fan is planar in z=0");
        }

        foreach (fi; 0 .. m.faces.length)
        {
            assert(m.faces[fi].length == 3, "disk: every face is a triangle");
            assert(m.faces[fi][0] == 0,     "disk: every triangle is wound hub-first");
        }

        // Boundary: the rim is open, so every rim edge borders exactly one face.
        assert(m.edges.length == 2 * n,
               "disk: n spokes + n rim edges");
    }
}
