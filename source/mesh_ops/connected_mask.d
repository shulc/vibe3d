module mesh_ops.connected_mask;

// ---------------------------------------------------------------------------
// The connected-mask family: the connected-component vertex mask
// (`connectedComponentMask`) and the element-centroid edge anchor
// (`edgeCentroid`). Extracted from source/tools/transform/xfrm_transform.d
// (xfrm Phase B — the BFS body of `updateConnectMask` and the edge-midpoint
// anchor of `takeEdge`; the stage writes / ACEN notifies stayed in the tool),
// first as `mixin template MeshConnectedMaskOps` mixed into `struct Mesh`.
//
// Converted to module-level FREE FUNCTIONS by task 1903 Stage D1
// (`doc/mesh_edit_seam_plan.md` §4, §5.2 row D1). Function BODIES are
// unchanged — every edit is an `m.` prefix — and the `mixin
// MeshConnectedMaskOps;` line left `struct Mesh` in the SAME change: a member
// reachable on the receiver BEATS a same-name UFCS free function, so a
// surviving mixin would silently keep answering every call and the conversion
// would change nothing (plan Revision 2 caveat 1; measured as Stage C's
// M-C-MIX″). `tests/unit/commit_seam_census_test.d` holds that as a check, and
// the `static assert` block at the bottom of this file holds the same fact at
// `dub build` time.
//
// TWO RECEIVERS, AND WHY THEY DIFFER — the thing D1 adds to Stage C's memo.
// §4.1 offers two shapes: `ref MeshEditBatch ed` for a mutating op,
// `ref const(Mesh) m` for a read-only one. This family needs a THIRD cell:
//
//   * `edgeCentroid` was a `const` member and is `ref const(Mesh) m` — the
//     ordinary read-only case.
//   * `connectedComponentMask` was NOT a `const` member and cannot become one.
//     It writes nothing: no vertex, no face, no mark, no selection, no
//     `commitChange` — but it calls `Mesh.vertexAdjacencyCSR`, which is a
//     MEMOIZING provider (it rebuilds `_adjCsrOffset` / `_adjCsrNeighbors`
//     in place when `mutationVersion` moved) and is therefore a non-`const`
//     method. So the receiver is a plain `ref Mesh m`, and this family opens
//     NO `MeshEditBatch`: a batch here would be a lie, it would defer and
//     publish a change for a query that changes nothing observable. The
//     boundary that matters for the seam is "does it write mesh DATA", not
//     "is it callable through `const`".
//
// HOW THE CALL SITES REACH THESE. `source/mesh.d` carries
// `public import mesh_ops.connected_mask;`, so every non-selective
// `import mesh;` re-exports both names and `mesh.edgeCentroid(ei)` /
// `mesh.connectedComponentMask(vi)` keep the spelling they always had. A
// SELECTIVE `import mesh : …` does not pick up a re-export — such a site must
// list the names (Stage C measured this). A POINTER receiver does not survive
// either: UFCS does not auto-dereference, so a `Mesh* mesh` site spells
// `(*mesh).connectedComponentMask(vi)`. MEASURED for D1: `xfrm_transform.d`
// imports `mesh` non-selectively, so the re-export half costs nothing — but
// `Tool.mesh` returns a `Mesh*`, so BOTH production call sites needed the
// deref. Every family in track 1 will meet this seam; commands hold
// `Mesh* mesh` too.
// ---------------------------------------------------------------------------
import mesh;
import math;

/// Connected-component BFS seeded at `seedVi`, over the CSR vert→vert
/// adjacency (relation D, edge-based) — same provider as smooth.d /
/// smoothSubdivide. Returns an order-independent visited set (`true` for
/// every vertex reachable from the seed), so (unlike the two smooth
/// kernels) the CSR neighbor order carries no bit-stability requirement
/// here.
///
/// An out-of-range `seedVi` returns the NULL mask. The seed bounds used to
/// be the caller's job — true while this was a private helper with exactly
/// one caller (XfrmTransformTool.updateConnectMask, which still guards) —
/// but the extraction made it a public entry point, so the guard belongs
/// here where every caller gets it. `null` is the same value that caller
/// already writes to FalloffStage.connectMask for an out-of-range seed, so
/// the contract downstream is unchanged.
///
/// The receiver is `ref Mesh`, NOT `ref const(Mesh)`, and NOT a
/// `MeshEditBatch`: see the two-receivers note at the top of this file.
bool[] connectedComponentMask(ref Mesh m, size_t seedVi) {
    size_t n = m.vertices.length;
    if (seedVi >= n) return null;
    const(size_t)[] adjOff;
    const(uint)[]   adjNbrs;
    m.vertexAdjacencyCSR(adjOff, adjNbrs);
    bool[] visited = new bool[](n);
    size_t[] queue;
    queue ~= seedVi;
    visited[seedVi] = true;
    while (queue.length > 0) {
        size_t v = queue[$ - 1];
        queue.length -= 1;
        foreach (nb; adjNbrs[adjOff[v] .. adjOff[v + 1]])
            if (!visited[nb]) { visited[nb] = true; queue ~= nb; }
    }
    return visited;
}

/// Edge midpoint (centroid of the two endpoints) — the click-independent
/// element-falloff edge anchor, formerly computed inline in
/// xfrm_transform.d:takeEdge.
// `@safe` is the substantive attribute: dmd keeps the bounds check on
// `m.edges[ei]` under -release in @safe code, so an out-of-range edge is a
// RangeError, not an out-of-bounds read — the extraction made this a public
// entry point, same law as connectedComponentMask's guard above (D1 review).
Vec3 edgeCentroid(ref const(Mesh) m, uint ei) @safe pure nothrow @nogc {
    auto edge = m.edges[ei];
    Vec3 a = m.vertices[edge[0]];
    Vec3 b = m.vertices[edge[1]];
    return (a + b) * 0.5f;
}

// ===========================================================================
// Module unittests.
// ===========================================================================
// (None here — task 0706 moved this family's blocks to
// tests/unit/mesh_ops/connected_mask_test.d, and they stayed there through the
// D1 conversion.)

// ---------------------------------------------------------------------------
// The gate that outlives the text census (task 1903 Stage C review, MAJOR-1 —
// compile-time, not a unittest). A member of `Mesh` BEATS a same-name UFCS
// free function silently — no ambiguity, no warning — so anything that puts
// one of these names back on the struct (`mixin MeshConnectedMaskOps;`,
// `mixin ...!();`, a named mixin, a hand-written method with the old body)
// rebinds every call site to it and this module becomes dead code. The regex
// census in tests/unit/commit_seam_census_test.d sees only the literal
// spelling; this sees the fact, and at `dub build` time, not only under
// --config=tests.
// ---------------------------------------------------------------------------
static foreach (n; ["connectedComponentMask", "edgeCentroid"])
    static assert(!__traits(hasMember, Mesh, n),
        "`Mesh." ~ n ~ "` is a MEMBER again. A member BEATS a same-name UFCS free "
      ~ "function silently, so every call site binds back to it and task 1903 "
      ~ "Stage D1 means nothing. Whatever re-added it — `mixin MeshConnectedMaskOps;`, "
      ~ "`mixin ...!();`, a named mixin, or a hand-written method — must go.");
