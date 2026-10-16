module vibe3d.mesh.ops.tests.unit.mesh_ops.edge_fixture;
import vibe3d.mesh.core.mesh : Mesh;

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
